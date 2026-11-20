-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/boat.lua - Stormwind Harbor <-> Auberdine (Darkshore) boat
-- ============================================================================
-- 1.2.32. A Zygor step whose point is on the other continent, with the player
-- on Eastern Kingdoms (Stormwind side) or Kalimdor (Darkshore side), takes the
-- boat: walk to the dock, WAIT for the ship (a game object, guid
-- "Transport-..."), board it when it stands at the dock, RIDE (nothing else
-- moves the player), and get off when it stands at the other dock.
--
--   to_darkshore   Stormwind Harbor -> Auberdine
--   to_stormwind   Auberdine -> Stormwind Harbor (the same machine, reversed)
--
-- WHERE (read from the Forever client's own tables, Forever_MapDump/dbc):
--   Stormwind Harbor   AreaPOI "Stormwind Harbor" (-8573.5, 990.1), map 0
--   Auberdine dock     GameObjects "Boat to Stormwind" (6509.2, 799.2, 8.2), map 1
--                      (the same dock signs say "Boat to Menethil / Teldrassil")
-- The POI is a map icon, not a recorded standing spot: the walk to it is a
-- Sentinel move_to, which snaps an off-mesh point to the nearest walkable one.
--
-- THE SHIP: core.object_manager.get_all_objects(), a non-unit object whose
-- guid starts "Transport-" (as the Telredor / Shattrath lifts, movement/
-- elevator). Several ships use the Auberdine dock (Menethil, Teldrassil,
-- Stormwind); the ship's name / guid is logged on boarding and the arrival
-- point decides afterwards whether it was the right one - a ship that lands
-- elsewhere is left at its dock and the normal walk goes on from there.
-- "Still" = fresh position samples within STILL_EPS for STILL_S s.
-- SAFETY: never step toward a ship that is not seen, still and near the dock
-- (stepping off a dock into the sea is a drowning), and never while it moves.
--
-- Walks: movement/nav only (Sentinel): N.nav_to (move_to) for the dock, N.step_into
-- (move_direct, one straight step - as the portal / lift step) for the deck and the quay.
-- API: core.object_manager.get_all_objects / get_object_from_guid, game_object:get_guid
-- / get_name / get_position / get_rotation / is_unit / is_valid, core.time - all in the
-- .api stubs.
-- ============================================================================

local R = require("movement/core")

local BT = {}

local STORMWIND = { x = -8573.5, y = 990.1 }
local AUBERDINE = { x = 6509.2, y = 799.2, z = 8.2 }

BT.ROUTES = {
    to_darkshore = { key = "to_darkshore", name = "Stormwind Harbor -> Auberdine", from_cont = 0, to_cont = 1,
        wait = STORMWIND, land = AUBERDINE, wait_here = true, here_yd = 800 },
    to_stormwind = { key = "to_stormwind", name = "Auberdine -> Stormwind Harbor", from_cont = 1, to_cont = 0,
        wait = AUBERDINE, land = STORMWIND, wait_here = true },
}

local AT_DOCK = 7           -- yd from the waiting spot: waiting begins
local HERE_YD = 250         -- a route with wait_here waits where the player stands when he is within this of its dock
local SHIP_SCAN = 150       -- yd around the dock / the player a ship is looked for
local DOCK_NEAR = 60        -- a ship this close to the dock (xy) can be the one to board
local DECK_R = 8            -- the player is aboard within this xy of the ship origin (the quay edge is farther out) ...
local DECK_Z = 7            -- ... and this far in z
local STILL_EPS, STILL_S = 0.6, 2.0
local SCAN_GAP = 0.5
local WAIT_MAX = 1500       -- s waiting for a ship before the run is given up
local BOARD_TRY = 6         -- s per aim point while boarding
local RIDE_MAX = 900        -- s riding before the run is given up
local WRONG_YD = 350        -- a landing this far from the planned dock is the wrong ship
local HOLD_AFTER_ABORT = 300
local LIMIT = { approach = 600, wait = WAIT_MAX, board = 60, ride = RIDE_MAX, exit = 40 }
local AIM = { { 0, 0 }, { 4, 0 }, { -4, 0 }, { 0, 3 }, { 0, -3 }, { 7, 0 }, { -7, 0 } }   -- ship-local aim offsets

local st = nil
local abort_until = -1e9
local seen = { guid = nil, pos = nil, still_t = nil, anchor = nil, t = -1e9, scan_t = -1e9, said = false }

local function N()
    local ok, n = pcall(require, "movement/nav")
    if ok and type(n) == "table" then return n end
    return nil
end

local function here()
    local me = R.me()
    if not me then return nil end
    local ok, p = pcall(me.get_position, me)
    if not ok then return nil end
    return R.xyz(p)
end

local function continent()
    local x, y = here()
    local okg, gv = pcall(require, "gamever")
    if okg and type(gv) == "table" and type(gv.continent_of) == "function" and x then
        local ok, c = pcall(gv.continent_of, { x = x, y = y })
        if ok then return c end
    end
    return nil
end

local function ui_continent(map_id)
    local okg, gv = pcall(require, "gamever")
    if okg and type(gv) == "table" and type(gv.continent_of_uimap) == "function" then
        local ok, c = pcall(gv.continent_of_uimap, map_id)
        if ok then return c end
    end
    return nil
end

--- The route that takes the player toward UI map `dest_map`, or nil: the other
--- continent is Darkshore's (Kalimdor) from the Eastern Kingdoms, or the
--- Eastern Kingdoms from Kalimdor.
function BT.wants(dest_map)
    if R.now() < abort_until then return nil end
    local dc = ui_continent(dest_map)
    local hc = continent()
    if dc == nil or hc == nil or dc == hc then return nil end
    if hc == 0 and dc == 1 then return BT.ROUTES.to_darkshore end
    if hc == 1 and dc == 0 then return BT.ROUTES.to_stormwind end
    return nil
end

local function phase(p, why)
    st.phase, st.phase_t = p, R.now()
    R.trail("boat", "%s: %s%s", st.route.name, p, why and (" - " .. why) or "")
end

local function stop_run(why, ok)
    if st then R.trail("boat", "%s: %s", st.route.name, why) end
    if not ok then
        abort_until = R.now() + HOLD_AFTER_ABORT
        R.log("Boat: " .. tostring(why) .. " - not tried again for " .. HOLD_AFTER_ABORT .. " s")
    end
    st = nil
end

-- ----------------------------------------------------------------- ships --
local function is_ship(o)
    if o == nil then return false end
    local okv, valid = pcall(o.is_valid, o)
    if not okv or valid ~= true then return false end
    local oku, unit = pcall(o.is_unit, o)
    if oku and unit == true then return false end
    local okg, g = pcall(o.get_guid, o)
    return okg and type(g) == "string" and g:find("^Transport%-") ~= nil
end

local function ship_info(o)
    local ok, p = pcall(o.get_position, o)
    if not ok then return nil end
    local x, y, z = R.xyz(p)
    if not x then return nil end
    local okg, g = pcall(o.get_guid, o)
    local okn, nm = pcall(o.get_name, o)
    local okr, rot = pcall(o.get_rotation, o)
    return { x = x, y = y, z = z, guid = okg and g or nil, name = okn and nm or nil, rot = okr and tonumber(rot) or 0 }
end

--- Every Transport object within SHIP_SCAN yd of (cx, cy), nearest first.
local function ships_near(cx, cy)
    local out = {}
    local ok, list = pcall(function() return core.object_manager.get_all_objects() end)
    if not ok or type(list) ~= "table" then return out end
    for i = 1, #list do
        local o = list[i]
        if is_ship(o) then
            local info = ship_info(o)
            if info and R.dist2(info.x, info.y, cx, cy) <= SHIP_SCAN then
                info.d = R.dist2(info.x, info.y, cx, cy)
                out[#out + 1] = info
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function by_guid(guid)
    if not guid then return nil end
    local ok, o = pcall(function() return core.object_manager.get_object_from_guid(guid) end)
    if ok and is_ship(o) then return ship_info(o) end
    return nil
end

--- Track `info` (a ship sample): returns still?, moved_from_anchor_yd.
local function track(info, t)
    if not info then return false, nil end
    if seen.guid ~= info.guid or not seen.anchor or (t - seen.t) > 4 then
        seen.guid, seen.anchor, seen.still_t = info.guid, { x = info.x, y = info.y, z = info.z }, t
    end
    seen.t = t
    local moved = R.dist2(info.x, info.y, seen.anchor.x, seen.anchor.y) + math.abs(info.z - seen.anchor.z)
    if moved > STILL_EPS then
        seen.anchor, seen.still_t = { x = info.x, y = info.y, z = info.z }, t
    end
    return (t - seen.still_t) >= STILL_S, moved
end
BT._track = track

local function aboard(info, x, y, z)
    return info ~= nil and R.dist2(x, y, info.x, info.y) <= DECK_R and math.abs(z - info.z) <= DECK_Z
end

local function log_ships(cx, cy)
    local ships = ships_near(cx, cy)
    R.trail("boat", "  %d ship object(s) within %d yd:", #ships, SHIP_SCAN)
    for i = 1, math.min(#ships, 8) do
        local s = ships[i]
        R.trail("boat", "    %s '%s' at (%.1f, %.1f, %.1f)", tostring(s.guid), tostring(s.name), s.x, s.y, s.z)
    end
end

-- ---------------------------------------------------------------- the run --
--- Start (or keep) the boat run for `route`. True while it runs.
function BT.start(route)
    if st then return true end
    if type(route) ~= "table" then return false end
    if R.now() < abort_until then return false end
    st = { route = route, t0 = R.now(), aim = 1, aim_t = R.now(), wait = route.wait }
    seen.guid, seen.anchor, seen.still_t, seen.said = nil, nil, nil, false
    -- 1.2.33 (user: wait for the boat at the player's position in Stormwind): near the harbor the player
    -- waits where he stands, no walk to the map-icon dock
    local hx, hy, hz = here()
    if route.wait_here and hx and R.dist2(hx, hy, route.wait.x, route.wait.y) <= (route.here_yd or HERE_YD) then
        st.wait = { x = hx, y = hy, z = hz }
        phase("wait", string.format("here (%.0f, %.0f) - %.0f yd from the harbor", hx, hy,
            R.dist2(hx, hy, route.wait.x, route.wait.y)))
        return true
    end
    phase("approach", string.format("to the dock (%.0f, %.0f)", route.wait.x, route.wait.y))
    return true
end

function BT.active() return st ~= nil end
--- Nothing else may move the player while he boards, rides or steps off.
function BT.riding() return st ~= nil and (st.phase == "board" or st.phase == "ride" or st.phase == "exit") end
function BT.status()
    if not st then return nil end
    return st.route.name .. " (" .. tostring(st.phase) .. ")"
end

local function wait_point(z)
    local w = st.wait
    return { x = w.x, y = w.y, z = w.z or z }
end

function BT.tick()
    if not st then return end
    local nav = N()
    if not nav then return end
    local t = R.now()
    if t - st.phase_t > (LIMIT[st.phase] or 60) then
        if st.phase == "board" then
            nav.stop("boat: boarding timed out")
            return phase("wait", "boarding did not work - waiting for the next ship")
        end
        return stop_run(st.phase .. " took too long", false)
    end
    local me = R.me()
    local okd, dead = pcall(function() return me and me:is_dead() end)
    if okd and dead == true then return stop_run("player died", false) end
    local x, y, z = here()
    if not x then return end
    local route = st.route

    if st.phase == "approach" then
        if R.dist2(x, y, st.wait.x, st.wait.y) <= AT_DOCK then
            nav.stop("boat: at the dock")
            return phase("wait")
        end
        nav.nav_to(wait_point(z), true, "boat")

    elseif st.phase == "wait" then
        if t - seen.scan_t >= SCAN_GAP then
            seen.scan_t = t
            local ships = ships_near(st.wait.x, st.wait.y)
            if st.wait ~= route.wait then               -- waiting where he stands: the harbor's ships count too
                local more = ships_near(route.wait.x, route.wait.y)
                for i = 1, #more do
                    local dup = false
                    for j = 1, #ships do if ships[j].guid == more[i].guid then dup = true break end end
                    if not dup then ships[#ships + 1] = more[i] end
                end
            end
            if #ships == 0 then
                seen.guid = nil
                -- 1.2.86: waiting where he stands, FAR from the dock (the Stormwind run waits anywhere in the city), and no ship
                -- seen for 60 s: the ship is out of view range - walk to the dock once instead of waiting blind
                if st.wait ~= route.wait and not st.fell_back and t - st.phase_t > 60
                    and R.dist2(x, y, route.wait.x, route.wait.y) > SHIP_SCAN then
                    st.fell_back = true
                    st.wait = route.wait
                    return phase("approach", "no ship in view from here - to the dock")
                end
                if t - st.phase_t > 15 and not seen.said then
                    seen.said = true
                    log_ships(st.wait.x, st.wait.y)
                    R.log("Boat: waiting at the dock for a ship")
                end
            else
                for i = 1, #ships do
                    local s = ships[i]
                    if R.dist2(s.x, s.y, st.wait.x, st.wait.y) <= DOCK_NEAR
                        or R.dist2(s.x, s.y, route.wait.x, route.wait.y) <= DOCK_NEAR then
                        local still = track(s, t)
                        if still then
                            st.ship = s.guid
                            st.dock_xy = { x = s.x, y = s.y, z = s.z }
                            R.trail("boat", "  boarding '%s' %s at (%.1f, %.1f, %.1f)", tostring(s.name), tostring(s.guid), s.x, s.y, s.z)
                            return phase("board", "the ship stands at the dock")
                        end
                        break
                    end
                end
            end
        end

    elseif st.phase == "board" then
        local s = by_guid(st.ship)
        local still = track(s, t)
        if not s then
            nav.stop("boat: the ship is gone")
            return phase("wait", "the ship disappeared before boarding")
        end
        if aboard(s, x, y, z) and still then
            if not st.aboard_t then st.aboard_t = t end
            if t - st.aboard_t >= 1.5 then
                nav.stop("boat: aboard")
                return phase("ride", "aboard '" .. tostring(s.name) .. "'")
            end
            return
        end
        st.aboard_t = nil
        -- the ship left before the player was on it
        if not still and R.dist2(s.x, s.y, st.dock_xy.x, st.dock_xy.y) > 3 and not aboard(s, x, y, z) then
            nav.stop("boat: the ship left")
            return phase("wait", "the ship sailed without the player")
        end
        -- far from the ship: walk to the quay edge nearest to it (Sentinel snaps the off-mesh point), then step on
        if R.dist2(x, y, s.x, s.y) > DECK_R + 6 then
            nav.nav_to({ x = s.x, y = s.y, z = z }, true, "boat")
            return
        end
        if t - st.aim_t >= BOARD_TRY then st.aim, st.aim_t = (st.aim % #AIM) + 1, t end
        local a = AIM[st.aim]
        local c, sn = math.cos(s.rot or 0), math.sin(s.rot or 0)
        nav.step_into({ x = s.x + a[1] * c - a[2] * sn, y = s.y + a[1] * sn + a[2] * c, z = s.z })

    elseif st.phase == "ride" then
        local s = by_guid(st.ship)
        if not s then
            -- a loading screen re-creates the ship: any ship around the player will do
            local ships = ships_near(x, y)
            for i = 1, #ships do
                if aboard(ships[i], x, y, z) then s = ships[i] break end
            end
            if s then st.ship = s.guid end
        end
        local still = track(s, t)
        local cont = continent()
        -- the ship sailed and the player is not on it: back to the dock
        if s and st.dock_xy and cont == route.from_cont and R.dist2(s.x, s.y, st.dock_xy.x, st.dock_xy.y) > 25
            and R.dist2(x, y, s.x, s.y) > DECK_R + 10 then
            return phase("wait", "left behind - waiting for the next ship")
        end
        if cont == route.to_cont and s and still and aboard(s, x, y, z) then
            local d = R.dist2(x, y, route.land.x, route.land.y)
            if d > WRONG_YD then
                R.trail("boat", "  landed %.0f yd from %s - this ship goes elsewhere", d, route.name)
                st.wrong = true
            end
            return phase("exit", st.wrong and "the ship stands at another dock" or "the ship stands at the dock")
        end

    elseif st.phase == "exit" then
        local s = by_guid(st.ship) or ships_near(x, y)[1]
        local land = { x = route.land.x, y = route.land.y, z = route.land.z or z }
        if st.wrong and s then
            -- the quay is where the ship is: the nearest walkable point; the normal walk goes on from there
            land = { x = s.x, y = s.y, z = z }
        end
        local off = (not s) or not aboard(s, x, y, z)
        if off and (R.dist2(x, y, land.x, land.y) <= 12 or t - st.phase_t > 6) then
            nav.stop("boat: ashore")
            return stop_run("done - ashore", true)
        end
        nav.step_into(land)
    end
end

function BT.reset()
    st, abort_until = nil, -1e9
    seen.guid, seen.anchor, seen.still_t, seen.scan_t, seen.said = nil, nil, nil, -1e9, false
end

return BT
