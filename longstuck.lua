-- ============================================================================
-- Master Farmer - Zygor Forever
-- longstuck.lua - stuck for 5 minutes: Hearthstone, or log out when dead
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: see version.lua
-- Folder: Zygor_Forever
-- ============================================================================
-- 1.7.33 (user: "if stuck for more than 5 mins use hearth stone, if player is
-- dead then logout"). The stuck ladder in movement.lua (strafes, fresh paths,
-- the detour fan, steep-free reroutes) keeps trying; this is the last resort
-- above it.
--
-- STUCK = a walk is running (the nav client has a destination) and the
-- player has come no closer than PROGRESS_YD to it for STUCK_S seconds.
-- Fighting, eating / drinking, a cast and a flight do not count (the clock
-- is held, not reset). The clock resets on real progress, on a new
-- destination more than NEW_DEST_YD from the last one, on a jump of JUMP_YD
-- in one tick (a flight, portal, hearth or resurrect), and after IDLE_S
-- seconds with no walk at all.
--
-- THEN
--   alive  Hearthstone (6948): the walk is stopped, the player stands still,
--          out of combat, and core.input.use_item(6948) is sent every
--          HEARTH_GAP s until the cast is under way; the bot holds while it
--          casts. No Hearthstone in the bags, or on cooldown: the destination is
--          given up (1.2.47: never a logout while alive).
--   dead   log out (a ghost cannot hearth): core.login.logout() (in the world
--          only; 20 s countdown outside a rest area), else core.input.logout().
--          The bot is stopped first so nothing walks or fights the countdown.
-- core.login.logout / core.input.logout / core.input.use_item: Core_Api
-- sylvanas_api docs (documented_only).
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local M = {}

M.STUCK_S = 300
M.PROGRESS_YD = 20
M.NEW_DEST_YD = 60
M.JUMP_YD = 100
M.IDLE_S = 20
M.HEARTH_ID = 6948
M.HEARTH_GAP = 3.0
M.HEARTH_CAST_S = 12        -- 10 s cast + a little; after this a failed hearth logs out

local st = { t0 = nil, best = nil, dest = nil, last = nil, last_t = nil, idle_t = nil,
    acting = nil, act_t = 0, sent_t = -1e9, cast_seen = false }

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "move", fmt, ...) end
end

local function note(text)
    local ok, state = pcall(require, "state")
    if ok and type(state) == "table" and type(state.set_note) == "function" then pcall(state.set_note, "Stuck", text) end
end

local function flat(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

local function reset(now)
    st.t0, st.best, st.dest, st.idle_t = now, nil, nil, nil
end

--- Seconds the player has been stuck (0 when not).
function M.stuck_for()
    if not st.t0 or not st.best then return 0 end
    return math.max(0, izi.now() - st.t0)
end

local function busy_elsewhere(player)
    if safe(function() return player:is_in_combat() end) == true then return true end
    if safe(function() return player:is_casting_spell() == true or player:is_channelling_spell() == true end) == true then
        return true
    end
    if safe(function() return player:is_flying() end) == true then return true end
    local R = package.loaded["movement/core"]
    if type(R) == "table" and R.resting then return true end
    local hl = package.loaded["healing"]
    if type(hl) == "table" and type(hl.is_resting) == "function" and safe(hl.is_resting) == true then return true end
    local qe = package.loaded["quest/engine"]
    if type(qe) == "table" and type(qe.in_flight) == "function" and safe(function() return qe.in_flight(player) end) == true then
        return true
    end
    return false
end

-- 1.2.48 THE BIND'S CONTINENT. No API reads the Hearthstone's bind, but the first hearth shows it: where the player lands is the
-- bind. After a hearth that crossed continents (09:43 log: Loch Modan -> Darkshore, 12,785 yd, then 90 minutes stranded), a later
-- stuck hearth from another continent is refused - the destination is given up instead.
local function continent(player)
    local ok, gv = pcall(require, "gamever")
    if not ok or type(gv) ~= "table" or type(gv.continent_of) ~= "function" then return nil end
    local okp, pos = pcall(function() return player:get_position() end)
    local ok2, c = pcall(gv.continent_of, okp and pos or nil)
    return ok2 and tonumber(c) or nil
end
M.continent = continent

local function dead(player)
    return safe(function() return player:is_dead_or_ghost() end) == true
        or safe(function() return player:is_ghost() end) == true
end

--- 1.2.47 A LIVING PLAYER IS NEVER LOGGED OUT. No Hearthstone / on cooldown / the cast did not take: the stuck destination is
--- blacklisted for a while, the walk is stopped and the clock restarts, so the guide picks something else. Only a ghost logs out.
local function give_up(now, why)
    trail("stuck for %.0f min (%s) - giving this destination up, staying logged in", M.STUCK_S / 60, why or "")
    pcall(function() require("movement").nav_stop() end)
    local Z = package.loaded["movement/zones"]
    if st.dest and type(Z) == "table" and type(Z.blacklist_area) == "function" then
        pcall(Z.blacklist_area, { x = st.dest.x, y = st.dest.y, z = 0 }, 8, "stuck 5 min, no way out (" .. tostring(why) .. ")")
    end
    st.acting = nil
    reset(now)
    st.last, st.last_t = nil, nil
    note("Stuck 5 min - destination given up")
    return false
end

local function log_out(why)
    trail("stuck for %.0f min%s - logging out", M.STUCK_S / 60, why and (" (" .. why .. ")") or "")
    pcall(function()
        local mv = require("movement")
        mv.nav_stop()
    end)
    local okg, gui = pcall(require, "gui")
    if okg and type(gui) == "table" and type(gui.stop) == "function" then
        pcall(gui.stop, "stuck for 5 minutes - logged out")
    end
    local ok_l, done = false, nil
    if type(core.login) == "table" and type(core.login.logout) == "function" then
        ok_l, done = pcall(core.login.logout)
    end
    if not (ok_l and done ~= false) and type(core.input.logout) == "function" then
        pcall(core.input.logout)
    end
    st.acting = "logout"
end

--- One tick. True while it owns the tick (a hearth being cast, a logout).
function M.tick(player)
    if not player then return false end
    local now = izi.now()
    local okg, gui = pcall(require, "gui")
    if okg and type(gui) == "table" and type(gui.is_started) == "function" and not gui.is_started() then
        st.acting = nil
        reset(now)
        return false
    end
    local here = safe(function() return player:get_position() end)
    if not here or type(here.x) ~= "number" then return false end

    -- acting: the hearth cast under way
    if st.acting == "hearth" then
        if safe(function() return player:is_casting_spell() end) == true then
            st.cast_seen = true
            note("Stuck 5 min - casting Hearthstone")
            return true
        end
        if st.last and flat(st.last, here) >= M.JUMP_YD then  -- landed at the inn
            trail("stuck: Hearthstone done - %.0f yd from the stuck spot", flat(st.last, here))
            st.bind_cont = continent(player) or st.bind_cont
            st.acting = nil
            reset(now)
            st.last, st.last_t = here, now
            return false
        end
        if now - st.act_t > M.HEARTH_CAST_S + (st.cast_seen and 0 or 3) then
            return give_up(now, "the Hearthstone did not take the player away")
        end
        if now - st.sent_t >= M.HEARTH_GAP and not st.cast_seen then
            st.sent_t = now
            pcall(function() require("movement").nav_stop() end)
            local okb, bags = pcall(require, "bags")
            if okb and type(bags) == "table" and type(bags.use_id) == "function" then pcall(bags.use_id, M.HEARTH_ID) end
        end
        note("Stuck 5 min - using the Hearthstone")
        return true
    end
    if st.acting == "logout" then
        note("Stuck 5 min - logging out")
        return true
    end

    -- a jump (flight, portal, resurrect): a new start
    if st.last and flat(st.last, here) >= M.JUMP_YD then reset(now) end
    st.last, st.last_t = here, now

    local okn, N = pcall(require, "movement/nav")
    local dx, dy = nil, nil
    if okn and type(N) == "table" and type(N.destination) == "function" then dx, dy = N.destination() end
    if not dx then
        st.idle_t = st.idle_t or now
        if now - st.idle_t >= M.IDLE_S then reset(now) end
        return false
    end
    st.idle_t = nil
    if busy_elsewhere(player) then
        if st.t0 then st.t0 = st.t0 + (now - (st.held_t or now)) end
        st.held_t = now
        return false
    end
    st.held_t = now
    local dest = { x = dx, y = dy }
    if not st.dest or flat(st.dest, dest) > M.NEW_DEST_YD then
        st.t0, st.best, st.dest = now, nil, dest
    end
    local d = flat(here, dest)
    if not st.best or d < st.best - M.PROGRESS_YD then
        st.best, st.t0 = d, now
        return false
    end
    if now - st.t0 < M.STUCK_S then return false end

    -- STUCK FOR 5 MINUTES
    if dead(player) then
        log_out("dead - a ghost cannot use the Hearthstone")
        return true
    end
    local okb, bags = pcall(require, "bags")
    local have = okb and type(bags) == "table" and type(bags.count) == "function" and bags.count(M.HEARTH_ID) > 0
    local cd = safe(function() return player:get_item_cooldown(M.HEARTH_ID) end)
    if not have then
        return give_up(now, "no Hearthstone in the bags")
    end
    if type(cd) == "number" and cd > 0 then
        return give_up(now, string.format("the Hearthstone is on cooldown for %.0f min", cd / 60))
    end
    local here_c = continent(player)
    if st.bind_cont ~= nil and here_c ~= nil and st.bind_cont ~= here_c then
        return give_up(now, "the Hearthstone is bound on another continent")
    end
    trail("stuck for %.0f min (%.0f yd from the goal, no closer) - using the Hearthstone", (now - st.t0) / 60, d)
    st.acting, st.act_t, st.sent_t, st.cast_seen = "hearth", now, -1e9, false
    pcall(function() require("movement").nav_stop() end)
    return true
end

M._st = st
return M
