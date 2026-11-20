-- ============================================================================
-- Master Farmer - Zygor Forever
-- mapwalk.lua - minimap click to walk (1.7.13)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Folder: Zygor_Forever
-- ============================================================================
-- User (2026-10-18): "apply ... minimap click to walk" (the Coords Helper notes).
-- With the bot STOPPED (questing owns movement while it runs) and "Minimap
-- Click to Walk" ticked: a left-click on the minimap is one goal.
--   * on the update tick only (main.lua), never a menu / render callback;
--   * the click is the press EDGE of core.input.is_key_pressed(0x01) (the key
--     state of the last tick is kept here);
--   * gated by coords:is_cursor_on_minimap() and is_valid_map_coords() on the
--     normalized cursor (the minimap's edge, > 0.99, is ignored);
--   * coords:get_cursor_world_pos() (extra_height nil: the player's own floor)
--     is the goal - the minimap is where the player is, so the continent is
--     the player's;
--   * walked with movement.nav_to - the same walk as the guide's (the exact
--     walk; the 1.7.4 input-driver claim is a no-op on Sentinel,
--     no new walk while casting / in combat, no long plain move_to); asked
--     again at most every REISSUE s while idle short of it;
--   * done within ARRIVE yd, given up after STUCK_S s without a yard of
--     progress, ended by a new click (it replaces the goal) or by Start.
-- ============================================================================

local M = {}

local ARRIVE, STUCK_S, REISSUE = 3.0, 15.0, 2.0
-- 1.7.20 (log 15:57:11: a click at load gave a goal 21,347 yd away): a minimap
-- point is within the minimap's reach - farther answers are ignored
local MAX_CLICK_YD = 500
local VK_LBUTTON = 0x01

local coords_mod = nil
local was_down = false
local goal = nil         -- { x, y, z, best, best_t, sent_t }

local function helper()
    if coords_mod == nil then
        local ok, h = pcall(require, "common/utility/coords_helper")
        coords_mod = (ok and type(h) == "table") and h or false
    end
    return coords_mod or nil
end
local function m(obj, name, ...)
    local f = obj and obj[name]
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, obj, ...)
    if ok then return r end
    return nil
end
local function now()
    local ok, t = pcall(core.time)
    return ok and type(t) == "number" and t or 0
end
local function trail(fmt, ...)
    local ok, elog = pcall(require, "errorlog")
    if ok and type(elog) == "table" and type(elog.trail) == "function" then pcall(elog.trail, "mapwalk", fmt, ...) end
end
local function movement()
    local ok, mv = pcall(require, "movement")
    return ok and type(mv) == "table" and mv or nil
end
local function key_down()
    local ok, v = pcall(function() return core.input.is_key_pressed(VK_LBUTTON) end)
    return ok and v == true
end

function M.active() return goal ~= nil end
function M.goal() return goal end

--- End the walk: the walk stopped (the driver release is a no-op on Sentinel).
function M.stop(why)
    if not goal then return end
    goal = nil
    local mv = movement()
    if mv then
        if type(mv.nav_stop) == "function" then pcall(mv.nav_stop) end
        if type(mv.want_input_driver) == "function" then pcall(mv.want_input_driver, false) end
    end
    trail("minimap walk ended: %s", tostring(why))
end

--- The bot was started: its own walks take over (the driver stays claimed by Start).
function M.forget()
    if goal then
        goal = nil
        trail("minimap walk handed over to the bot")
    end
end

--- The world goal of a minimap click now, or nil (pure read of the helper).
function M.click_goal()
    local h = helper()
    if not h or m(h, "is_cursor_on_minimap") ~= true then return nil end
    local cur = m(h, "get_cursor_normalized")
    if not cur or m(h, "is_valid_map_coords", cur) ~= true then return nil end
    local w = m(h, "get_cursor_world_pos")
    if type(w) ~= "table" or type(w.x) ~= "number" or type(w.y) ~= "number" then return nil end
    return { x = w.x, y = w.y, z = tonumber(w.z) or 0 }
end

--- Every update tick while the bot is stopped. True while a minimap walk runs
--- (main.lua then does not halt movement).
function M.tick(player)
    local down = key_down()
    local edge = down and not was_down
    was_down = down
    local t = now()
    local pp = player and m(player, "get_position") or nil
    if edge then
        local g = M.click_goal()
        if g and pp and math.sqrt((g.x - pp.x) ^ 2 + (g.y - pp.y) ^ 2) > MAX_CLICK_YD then
            trail("minimap click ignored: (%.0f, %.0f) is %.0f yd away - not a minimap point", g.x, g.y,
                math.sqrt((g.x - pp.x) ^ 2 + (g.y - pp.y) ^ 2))
            g = nil
        end
        if g and pp then
            local d = math.sqrt((g.x - pp.x) ^ 2 + (g.y - pp.y) ^ 2)
            goal = { x = g.x, y = g.y, z = g.z, best = d, best_t = t, sent_t = -1e9 }
            local mv = movement()
            if mv and type(mv.want_input_driver) == "function" then pcall(mv.want_input_driver, true) end
            trail("minimap click: walking to (%.0f, %.0f, %.0f), %.0f yd", g.x, g.y, g.z, d)
        end
    end
    if not goal then return false end
    if not pp then return true end
    local d = math.sqrt((goal.x - pp.x) ^ 2 + (goal.y - pp.y) ^ 2)
    if d <= ARRIVE then
        M.stop("arrived")
        return false
    end
    -- 1.7.18: outdoors the outdoor unstick (movement.lua) keeps trying until
    -- the player moves - no give-up there; indoors the 15 s give-up stands
    local outdoors = m(player, "is_indoors") ~= true
    if d < goal.best - 1 or outdoors then
        if d < goal.best - 1 then goal.best = d end
        goal.best_t = t
    elseif t - goal.best_t >= STUCK_S then
        M.stop(string.format("no progress for %.0f s (%.0f yd left)", STUCK_S, d))
        return false
    end
    local mv = movement()
    if not mv or type(mv.nav_to) ~= "function" then return true end
    local busy = type(mv.is_moving) == "function" and mv.is_moving() == true
    if busy or (t - goal.sent_t) >= REISSUE then
        goal.sent_t = busy and goal.sent_t or t
        local okv, v3 = pcall(require, "common/geometry/vector_3")
        local dest = (okv and type(v3) == "table" and v3.new) and v3.new(goal.x, goal.y, goal.z)
            or { x = goal.x, y = goal.y, z = goal.z }
        pcall(mv.nav_to, dest, true)
    end
    return true
end

function M._reset() was_down, goal = false, nil end

return M
