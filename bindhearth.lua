-- ============================================================================
-- Master Farmer - Zygor Forever
-- bindhearth.lua - learn where the Hearthstone is bound; use it when it is the shortcut
-- ============================================================================
-- Log 2026-11-19: the goal was 1270 yd away (Westfall coast -> Sentinel Hill) and Zygor's arrow never
-- carries a hearth leg (always type "way"; fields dist / goal_num / is_manual only).
-- No API reads the bind, but the landing of a hearth shows it. This module:
--   * learns the bind: the position after a jump of 400+ yd while item 6948 is on a fresh cooldown
--     (> 3000 s left), the position at the innkeeper's bind, and - on the first tick after a reload within
--     5 minutes of a hearth - where the player stands; it is saved per character (mfzb/bind_hearth.txt);
--   * M.consider (called by the quest engine before a far walk): hearth when the Hearthstone is ready, the bind
--     is on the goal's continent, the walk is long (>= MIN_WALK) and the bind is at least SAVE yd nearer
--     to the goal than the player. Cast out of combat, standing still; a goal gets 3 tries, then 10 minutes' walk.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local M = {}

M.HEARTH_ID = 6948
M.MIN_WALK = 900        -- yd: shorter trips are walked
M.SAVE = 700            -- yd the bind must be nearer to the goal than the player
M.JUMP_YD = 400         -- a teleport this long is a candidate landing
M.CD_FRESH = 3000       -- s of cooldown left that only a hearth just used can show
M.GAP = 15              -- s between uses
M.TRIES = 3
M.BLOCK_S = 600
M.FOLDER = "mfzb"
M.FILE = "mfzb/bind_hearth.txt"

local st = { bind = nil, last = nil, loaded = false, first = true, key = nil, tries = 0,
    used_t = -1e9, block_until = 0 }
M.st = st

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end
local function trail(fmt, ...)
    local ok, log = pcall(require, "errorlog")
    if ok and type(log) == "table" and type(log.trail) == "function" then
        pcall(log.trail, "travel", "bind hearth: " .. fmt, ...)
    end
end
local function flat(a, b)
    local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end
local function continent(pos)
    local ok, gv = pcall(require, "gamever")
    if not ok or type(gv) ~= "table" or type(gv.continent_of) ~= "function" then return nil end
    local ok2, c = pcall(gv.continent_of, pos)
    return ok2 and tonumber(c) or nil
end
local function guid_of(player)
    local g = tostring(safe(function() return player:get_guid() end) or "?")
    return (g:gsub("%s", "_"))
end
local function cooldown(player)
    local cd = safe(function() return player:get_item_cooldown(M.HEARTH_ID) end)
    return type(cd) == "number" and cd or 0
end

local function load_file(player)
    st.loaded = true
    local body = safe(function() return core.read_data_file(M.FILE) end)
    if type(body) ~= "string" or body == "" then return end
    local g = guid_of(player)
    for line in body:gmatch("[^\n]+") do
        local id, x, y, z, c = line:match("^(%S+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?%d+)")
        if id == g and tonumber(x) and tonumber(y) then
            local cn = tonumber(c)
            st.bind = { x = tonumber(x), y = tonumber(y), z = tonumber(z) or 0, cont = (cn and cn >= 0) and cn or nil }
            trail("loaded - bound near (%.0f, %.0f), continent %s", st.bind.x, st.bind.y, tostring(st.bind.cont))
        end
    end
end

local function save_file(player)
    if not st.bind then return end
    -- one line per character; write_data_file APPENDS, so the file is emptied first (deathzones.lua)
    local lines, g = {}, guid_of(player)
    local body = safe(function() return core.read_data_file(M.FILE) end)
    if type(body) == "string" then
        for line in body:gmatch("[^\n]+") do
            if line:match("^(%S+)") ~= g then lines[#lines + 1] = line end
        end
    end
    lines[#lines + 1] = string.format("%s %.1f %.1f %.1f %d", g, st.bind.x, st.bind.y, st.bind.z or 0, st.bind.cont or -1)
    pcall(function() core.create_data_folder(M.FOLDER) end)
    pcall(function() core.create_data_file(M.FILE) end)
    pcall(function() core.write_data_file(M.FILE, table.concat(lines, "\n") .. "\n") end)
end

--- Record the bind at `pos` (why = text for the log).
function M.learn(player, pos, why)
    if type(pos) ~= "table" or type(pos.x) ~= "number" then return end
    if st.bind and flat(st.bind, pos) < 30 then return end
    st.bind = { x = pos.x, y = pos.y, z = pos.z or 0, cont = continent(pos) }
    trail("learned (%s) - (%.0f, %.0f), continent %s", tostring(why), pos.x, pos.y, tostring(st.bind.cont))
    save_file(player)
end

--- Every update: load the saved bind, watch for a hearth landing.
function M.tick(player)
    if not st.loaded then load_file(player) end
    local here = safe(function() return player:get_position() end)
    if type(here) ~= "table" or type(here.x) ~= "number" then return end
    if st.first then
        st.first = false
        -- reloaded within 5 minutes of a hearth: the player is still at (or near) the bind
        if cooldown(player) > 3300 and not st.bind then M.learn(player, here, "first tick, hearth cooldown fresh") end
    end
    local last = st.last
    st.last = { x = here.x, y = here.y, z = here.z }
    if last and flat(last, here) >= M.JUMP_YD and cooldown(player) > M.CD_FRESH then
        M.learn(player, here, string.format("landed %.0f yd away, Hearthstone on cooldown", flat(last, here)))
    end
end

--- 1.2.54: the quest engine asks before a far walk. True while the Hearthstone use owns the tick.
function M.consider(player, goal, kind, wps, label)
    if kind == "hearth" or kind == "fly" or kind == "fpath" or kind == "confirm" then return false end
    if not st.bind or type(wps) ~= "table" or not wps[1] or type(wps[1].pos) ~= "table" then return false end
    local here = safe(function() return player:get_position() end)
    if type(here) ~= "table" or type(here.x) ~= "number" then return false end
    local gp = wps[1].pos
    local now = izi.now()
    local key = tostring(label)
    if st.key ~= key then st.key, st.tries = key, 0 end
    if now < st.block_until then return false end
    local casting = safe(function() return player:is_casting_spell() end) == true
    if casting and now - st.used_t < 30 then
        require("state").set_note("Travel", "Casting the Hearthstone (bound near the goal)")
        return true
    end
    local d_here, d_bind = flat(here, gp), flat(st.bind, gp)
    if d_here < M.MIN_WALK or (d_here - d_bind) < M.SAVE then
        return false
    end
    local cg = continent(gp)
    if cg == nil or st.bind.cont == nil or cg ~= st.bind.cont then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    if safe(function() return player:is_dead_or_ghost() end) == true then return false end
    local okb, bags = pcall(require, "bags")
    if not okb or type(bags) ~= "table" or bags.count(M.HEARTH_ID) <= 0 then return false end
    if cooldown(player) > 0 then return false end
    if st.tries >= M.TRIES then
        st.tries, st.block_until = 0, now + M.BLOCK_S
        trail("the Hearthstone did not take %d times - walking for %d s", M.TRIES, M.BLOCK_S)
        return false
    end
    local mv = require("movement")
    mv.nav_stop()
    if mv.is_moving() then
        require("state").set_note("Travel", "Stopping to use the Hearthstone")
        return true
    end
    if now - st.used_t >= M.GAP then
        st.used_t, st.tries = now, st.tries + 1
        if bags.use_id(M.HEARTH_ID) then
            trail("goal %.0f yd away, the bind %.0f yd - Hearthstone used (%s)", d_here, d_bind, tostring(label))
        end
    end
    require("state").set_note("Travel", string.format("Hearthstone: goal %.0f yd away, bind %.0f yd", d_here, d_bind))
    return true
end

return M
