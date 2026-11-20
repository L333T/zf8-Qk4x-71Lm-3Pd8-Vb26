-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/elevator.lua - Telredor (Zangarmarsh) and Aldor Rise (Shattrath)
-- ============================================================================
-- 1.22.0 (user, reviewed draft drafts/zygor_telredor_elevator.lua).
-- 1.66.0 Shattrath Terrace of Light / Aldor Rise elevator (game object 184738),
-- same board / wait / ride / exit machine as Telredor, from the Path Tool
-- routes Shat_ele_up.json / Shat_ele_down.json.
--
-- Telredor's town sits on a giant mushroom cap (z ~120-150); the marsh under it
-- is at z ~20-30. The only way between them on foot is the lift (game object
-- 182410, also 182293). Sentinel's navmesh has no lift, so a walk between the
-- two levels is taken here instead, from the routes recorded with the Path Tool
-- (scripts_data/mf_route_tool/paths T_UP / T_UPX / T_DOWN / T_DOWNX, copied in
-- below - this product does not read the Path Tool's files).
--
-- Shattrath's Terrace of Light sits at z ~4; Aldor Rise at z ~131. The Aldor
-- Rise elevator (184738) is the only on-foot way between them. Zygor "Ride the
-- elevator up |goto Shattrath City/0 41.68,38.61" (Terokkar Forest 63-64 step 8
-- and the same goto in later Aldor legs) is the shaft; the Path Tool's
-- Shat_ele_up wait/platform are the bottom landing, Shat_ele_down the top.
-- The Scryer elevator at 49.96,62.94 is a different shaft and is not this lift.
--
-- UP    approach path[1] (Sentinel move_to) -> follow path to its 1st 'wait'
--       point (the waiting spot beside the shaft) -> WAIT until the lift stands
--       still at the boarding XYZ -> step onto it (the 2nd 'wait' point, the
--       platform) -> RIDE: nothing moves the player -> the lift stopped at the
--       exit platform XYZ -> step off to the first recorded point EXIT_OFF yd
--       from the platform.
-- DOWN  the same in reverse, boarding at the top dock and exiting at the bottom.
--
-- WHEN: movement/nav N.nav_to (every out-of-combat walk: quest goals, NPCs,
-- repair / vendor / inn, trainers, loot, corpse runs, minimap walks) asks
-- EL.wants(here, dest) first. A walk that crosses a lift's levels starts that
-- lift's run and nav_to answers "walking" until it is done; then the same
-- nav_to carries on to the real destination from the lift's exit.
--
-- THE LIFT OBJECT: core.object_manager.get_all_objects() (at most once a second
-- while near the shaft), a non-unit object whose get_npc_id() is that shaft's
-- id - or, if get_npc_id answers nothing for a world object, the entry field of
-- its guid string ("GameObject-0-1-0-0-<entry>-<spawn>", .api core.lua
-- get_object_from_guid). Kept by guid and re-resolved every tick with
-- core.object_manager.get_object_from_guid (never a stored object across
-- ticks). "Stopped" = fresh XYZ samples stay within MOVE_EPS for STOP_S s (the stub
-- documents is_moving for units only).
-- SAFETY: never step toward the platform unless the lift object is seen, stopped
-- and at the recorded boarding XYZ (stepping into an empty shaft is a long fall).
--
-- API: core.object_manager.get_all_objects / get_object_from_guid /
-- get_local_player, game_object:get_npc_id / get_guid / get_position /
-- is_unit / is_valid / is_falling, core.get_map_id, core.time - all in the
-- .api stubs. Walks only through movement/nav (Sentinel): N.nav_to (move_to),
-- N.follow_route (follow_path over the recorded points), N.step_into
-- (move_direct, one straight step - as the portal step-in, 1.7.7).
-- ============================================================================

local R = require("movement/core")

local EL = {}

-- -------------------------------------------------------------- the routes --
-- From the Path Tool's JSON files (map_id 947 in the files = the recorder's UI
-- map; the world map here is 530, Outland). w = a 'wait' action on that point.
local T_UP = {
    { 280.761, 5979.483, 21.524 }, { 280.802, 5976.459, 21.638 }, { 280.928, 5973.446, 21.708 },
    { 281.082, 5970.429, 21.782 }, { 281.231, 5967.512, 22.597 }, { 281.369, 5964.817, 23.929 },
    { 281.513, 5962.000, 24.988 }, { 281.652, 5959.300, 26.338 }, { 281.806, 5956.290, 26.346 },
    { 281.960, 5953.276, 26.378 }, { 282.115, 5950.249, 26.411 }, { 282.269, 5947.236, 26.444 },
    { 282.423, 5944.237, 26.477 }, { 282.577, 5941.224, 26.509 }, { 282.732, 5938.196, 26.542 },
    { 282.887, 5935.183, 26.576 },
    { 284.702, 5930.493, 26.626, w = true },    -- wait spot (bottom)
    { 285.401, 5918.699, 26.165, w = true },    -- the platform (bottom)
}
local T_UPX = {
    { 282.252, 5939.775, 149.414, w = true },   -- the platform (top)
    { 281.217, 5947.088, 149.842, w = true },
    { 280.318, 5952.842, 149.779 }, { 282.081, 5959.688, 149.687 },
}
local T_DOWN = {
    { 282.489, 5965.856, 150.219 }, { 281.098, 5956.583, 149.728 }, { 279.565, 5950.847, 149.804 },
    { 280.231, 5947.083, 149.845, w = true },   -- wait spot (top)
    { 281.197, 5934.252, 149.418, w = true },   -- the platform (top)
}
local T_DOWNX = {
    { 284.147, 5920.406, 26.164, w = true },    -- the platform (bottom)
    { 283.746, 5923.765, 26.162 }, { 284.147, 5933.156, 26.598 }, { 284.886, 5943.228, 26.491 },
    { 284.167, 5954.840, 26.363 }, { 283.716, 5968.759, 22.323 }, { 282.797, 5980.367, 21.537 },
}

-- Shat_ele_up.json: 1st = bottom wait beside the platform, 2nd = bottom platform.
-- Shat_ele_down.json: 1st = top wait beside the platform, 2nd = top platform.
local S_UP = {
    { -1813.62,  5578.007, 3.718,  w = true },  -- wait spot (bottom)
    { -1811.295, 5589.308, 3.73,   w = true },  -- the platform (bottom)
}
local S_UPX = {
    { -1810.871, 5590.083, 130.763, w = true }, -- the platform (top)
    { -1806.047, 5606.56,  130.812, w = true }, -- off the lift (top wait)
}
local S_DOWN = {
    { -1806.047, 5606.56,  130.812, w = true }, -- wait spot (top)
    { -1810.871, 5590.083, 130.763, w = true }, -- the platform (top)
}
local S_DOWNX = {
    { -1811.295, 5589.308, 3.73,  w = true },   -- the platform (bottom)
    { -1813.62,  5578.007, 3.718, w = true },   -- off the lift (bottom wait)
}

local function P(r) return { x = r[1], y = r[2], z = r[3] } end
local function pts(list, a, b)
    local out = {}
    for i = a or 1, b or #list do out[#out + 1] = P(list[i]) end
    return out
end
local function first_wait(list) for i = 1, #list do if list[i].w then return i end end return #list end

-- the point lists handed to N.follow_route are built ONCE: follow_route treats a new
-- table as a new route and would send follow_path again every tick
-- 1.34.5: the exit's first point EXIT_OFF yd or more from the platform (off the lift)
local EXIT_OFF = 8
local function bind_runs(path_up, exit_up, path_down, exit_down)
    local RUN = {
        up   = { path = path_up,   exit = exit_up,   wait_i = first_wait(path_up) },
        down = { path = path_down, exit = exit_down, wait_i = first_wait(path_down) },
    }
    for _, run in pairs(RUN) do
        run.to_wait = pts(run.path, 1, run.wait_i)
        run.exit_pts = pts(run.exit)
        run.off_i = #run.exit
        for i = 2, #run.exit do
            if R.dist2(run.exit[i][1], run.exit[i][2], run.exit[1][1], run.exit[1][2]) >= EXIT_OFF then
                run.off_i = i
                break
            end
        end
    end
    return RUN
end

-- --------------------------------------------------------------- Telredor --
local MAP = 530                       -- Outland
local TOWN = {
    { x1 = 195, x2 = 345, y1 = 6010, y2 = 6115 },   -- the town
    { x1 = 262, x2 = 308, y1 = 5905, y2 = 6015 },   -- the lift's top and the walkway to the town
}
local CAP = { x = 265, y = 6040 }
local CAP_R = 160                     -- the other mushroom top (375, 5880) is 194 yd off
EL.TOWN = TOWN
EL.LIFT_IDS = { [182410] = true, [182293] = true }
EL.CAP, EL.CAP_R = CAP, CAP_R

local function in_town(x, y)
    for i = 1, #TOWN do
        local b = TOWN[i]
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return true end
    end
    return false
end
EL.in_town = in_town

local TELREDOR = {
    name = "Telredor",
    SHAFT = { x = 283.5, y = 5928 },
    TOP_Z = 100,
    TOP_GUESS = 140,
    LIFT_IDS = EL.LIFT_IDS,
    LIFT_NEAR = 20,
    RUN = bind_runs(T_UP, T_UPX, T_DOWN, T_DOWNX),
    DOCK = { top = P(T_DOWN[#T_DOWN]), bottom = P(T_UP[#T_UP]) },
}
EL._RUN = TELREDOR.RUN

function TELREDOR.is_top(x, y, z)
    if not x then return false end
    if z and z >= TELREDOR.TOP_Z and (in_town(x, y) or R.dist2(x, y, CAP.x, CAP.y) <= CAP_R) then
        return true
    end
    return false
end

function TELREDOR.cap_z(x, y, z)
    if not x or (z and z >= TELREDOR.TOP_Z) then return nil end
    if not in_town(x, y) then return nil end
    return TELREDOR.TOP_GUESS
end

-- ---------------------------------------------------------- Aldor Rise --
-- Terrace of Light z ~4, Aldor Rise z ~131. Box covers the recorded landings
-- and the rise north of the shaft, including Ishanah's shrine
-- (Zygor Shattrath City 23,29 / map 1955 0.2396,0.2972 -> -1733, 5822, 176).
-- The 1.66.0 box ended at y=5820, 2 yd short of that shrine, so Terokkar
-- Forest 63-64 step 9 (turn in Ishanah, quest 10554) walked 800 yd without
-- the lift. Lower City (taxi -1837, 5301 / spawn -1903, 5519) stays out.
-- GOTO_R is Zygor's 41.68,38.61 shaft (Terokkar Forest 63-64 step 8).
local ALDOR_RISE = { x1 = -1980, x2 = -1650, y1 = 5565, y2 = 5950 }
local ALDOR = {
    name = "Aldor Rise",
    SHAFT = { x = -1811.08, y = 5589.70 },
    TOP_Z = 80,
    TOP_GUESS = 131,
    LIFT_IDS = { [184738] = true },
    LIFT_NEAR = 20,
    GOTO_R = 35,
    LANDING_R = 45,
    RUN = bind_runs(S_UP, S_UPX, S_DOWN, S_DOWNX),
    DOCK = { top = P(S_DOWN[#S_DOWN]), bottom = P(S_UP[#S_UP]) },
}
EL.ALDOR_LIFT_IDS = ALDOR.LIFT_IDS

local function aldor_in_rise(x, y)
    return x >= ALDOR_RISE.x1 and x <= ALDOR_RISE.x2 and y >= ALDOR_RISE.y1 and y <= ALDOR_RISE.y2
end

function ALDOR.is_top(x, y, z)
    if not x or not z or z < ALDOR.TOP_Z then return false end
    return aldor_in_rise(x, y) or R.dist2(x, y, ALDOR.SHAFT.x, ALDOR.SHAFT.y) <= ALDOR.LANDING_R
end

function ALDOR.cap_z(x, y, z)
    if not x or (z and z >= ALDOR.TOP_Z) then return nil end
    if R.dist2(x, y, ALDOR.SHAFT.x, ALDOR.SHAFT.y) <= ALDOR.GOTO_R then return ALDOR.TOP_GUESS end
    if aldor_in_rise(x, y) then return ALDOR.TOP_GUESS end
    return nil
end

local SHAFTS = { TELREDOR, ALDOR }

-- ------------------------------------------------------------ the timings --
local Z_TOL = 2.0                     -- yd: the lift / a point counts as level with the player
local LIFT_TOL = 4.0                  -- 1.34.3: the lift OBJECT level with the player (a transport's origin
                                      -- need not be its floor; was Z_TOL)
local MOVE_EPS, STOP_S = 0.05, 0.8    -- full XYZ remains within 0.05 yd for 0.8 s
local SAMPLE_MAX_GAP, DOCK_XY = 0.5, 8
local AT_YD = 2.0                     -- yd: at a recorded point
local SCAN_S = 1.0
local LIMIT = { approach = 180, to_wait = 40, wait_lift = 120, board = 10, ride = 60, exit = 40 }
local ABORT_HOLD = 30                 -- s: after an abort the lift is not tried again for this long

-- ------------------------------------------------------------------ state --
local st = nil                        -- the run: { dir, phase, phase_t, t0, goal, shaft }
local lift = { guid = nil, scan_t = -1e9, z = nil, change_t = -1e9, seen_t = -1e9, said = false }
local wanted_shaft = nil
local abort_until = -1e9
EL._st = function() return st end
EL._lift = lift

local function N() return package.loaded["movement/nav"] end
local function here() return R.here() end

local function active_shaft()
    return (st and st.shaft) or wanted_shaft or TELREDOR
end

-- 1.34.2: core.get_map_id() answers the zone's UI map in game (1946 Zangarmarsh,
-- "nav memory: map 1946 instance 530"), never 530 - the lift was never run and the
-- bot walked off the cap. Outland = the instance id, else gamever's UI map table.
local function on_map()
    local oki, inst = pcall(core.get_instance_id)
    if oki and inst == MAP then return true end
    local okm, m = pcall(core.get_map_id)
    if okm and m == MAP then return true end
    local okg, gv = pcall(require, "gamever")
    return okg and type(gv) == "table" and type(gv.continent_of_uimap) == "function" and gv.continent_of_uimap(m) == MAP
end

--- "top" | "bottom" for callers / tests. A point is top if it is on ANY lift's
--- upper landing (Telredor cap or Aldor Rise); everything else is bottom.
function EL.side(x, y, z)
    if not x then return nil end
    for i = 1, #SHAFTS do
        if SHAFTS[i].is_top(x, y, z) then return "top" end
    end
    return "bottom"
end

--- A destination given at ground height on a lift's upper level is that level:
--- the z to look for it at, else nil. Telredor town / Zygor's "Ride the elevator
--- up to Telredor" point, and Shattrath's 41.68,38.61 shaft / Aldor Rise.
function EL.cap_z(x, y, z)
    if not x or not on_map() then return nil end
    for i = 1, #SHAFTS do
        local cz = SHAFTS[i].cap_z(x, y, z)
        if cz then return cz end
    end
    return nil
end

-- --------------------------------------------------------------- the lift --
local function entry_of(o)
    local okn, id = pcall(function() return o:get_npc_id() end)
    if okn and type(id) == "number" and id > 0 then return id end
    local okg, g = pcall(function() return o:get_guid() end)
    if okg and type(g) == "string" then
        local kind, e = g:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
        if kind == "GameObject" or kind == "Transport" then return tonumber(e) end
    end
    return nil
end

-- 1.34.3: the lift is a TRANSPORT in game - guid "Transport-<id>-0000000000000000", id 0,
-- name "Doodad_AncDrae_elevatorPiece02" (API dump 2026-10-25, Shattrath's lift); the
-- GameObject entry parse never matched it, so the lift was never seen (12:22 log). A
-- non-unit object in the shaft (LIFT_NEAR yd) that is a LIFT_IDS entry, a Transport or
-- named "...elevator..." is the lift.
local function name_of(o)
    local ok, n = pcall(function() return o:get_name() end)
    return ok and type(n) == "string" and n or nil
end
local function lift_like(o, shaft)
    local id = entry_of(o)
    if id and shaft.LIFT_IDS[id] then return true end
    local okg, g = pcall(function() return o:get_guid() end)
    if okg and type(g) == "string" and g:find("^Transport%-") then return true end
    local n = name_of(o)
    return n ~= nil and n:lower():find("elevator", 1, true) ~= nil
end
local function pos_of(o)
    local ok, p = pcall(function() return o:get_position() end)
    if ok and type(p) == "table" and R.finite(p.x) and R.finite(p.y) and R.finite(p.z) then return p end
    return nil
end
local function find_lift(t, gap, shaft)
    shaft = shaft or active_shaft()
    if t - lift.scan_t < (gap or SCAN_S) then return lift.found, lift.scan_t end
    lift.scan_t = t
    lift.found = nil
    local ok, list = pcall(core.object_manager.get_all_objects)
    if not ok or type(list) ~= "table" then return nil end
    for i = 1, #list do
        local o = list[i]
        local valid = select(2, pcall(function() return o:is_valid() end)) == true
        local isu = not valid or select(2, pcall(function() return o:is_unit() end))
        if isu ~= true and lift_like(o, shaft) then
            local pos = pos_of(o)
            if pos and R.dist2(pos.x, pos.y, shaft.SHAFT.x, shaft.SHAFT.y) <= shaft.LIFT_NEAR then
                lift.guid = select(2, pcall(function() return o:get_guid() end))
                lift.found = pos
                if not lift.said then
                    lift.said = true
                    R.trail("elevator", "%s lift found: %s '%s' at (%.1f, %.1f, %.1f)", shaft.name,
                        tostring(lift.guid), tostring(name_of(o)), pos.x, pos.y, pos.z)
                end
                return pos, t
            end
        end
    end
    return nil
end

--- 1.34.3: the non-unit objects round the shaft, logged when the lift is not seen.
function EL.log_shaft_objects()
    local shaft = active_shaft()
    local ok, list = pcall(core.object_manager.get_all_objects)
    if not ok or type(list) ~= "table" then return R.trail("elevator", "  get_all_objects failed") end
    local n = 0
    for i = 1, #list do
        local o = list[i]
        local valid = select(2, pcall(function() return o:is_valid() end)) == true
        local isu = not valid or select(2, pcall(function() return o:is_unit() end))
        local pos = isu ~= true and pos_of(o) or nil
        if pos and R.dist2(pos.x, pos.y, shaft.SHAFT.x, shaft.SHAFT.y) <= 40 then
            n = n + 1
            if n <= 25 then
                R.trail("elevator", "  near the shaft: %s '%s' at (%.1f, %.1f, %.1f)",
                    tostring(select(2, pcall(function() return o:get_guid() end))), tostring(name_of(o)), pos.x, pos.y, pos.z)
            end
        end
    end
    R.trail("elevator", "  %d non-unit object(s) within 40 yd of the shaft (of %d objects)", n, #list)
end

--- The lift's z, and whether it stands still (nil, nil when it is not seen).
local function lift_state(t)
    local shaft = active_shaft()
    local pos, sampled = nil, t
    if lift.guid then
        local ok, o = pcall(core.object_manager.get_object_from_guid, lift.guid)
        if ok and o then
            local okv, v = pcall(function() return o:is_valid() end)
            if okv and v then pos = pos_of(o) end
        end
    end
    if not pos then pos, sampled = find_lift(t, lift.guid and 0.25 or SCAN_S, shaft) end
    if not pos or not sampled or t-sampled > SAMPLE_MAX_GAP then
        lift.anchor, lift.samples, lift.sample_t = nil, 0, nil
        if t - lift.seen_t > 3 then lift.guid = nil end
        return nil, false, nil
    end
    if R.dist2(pos.x, pos.y, shaft.SHAFT.x, shaft.SHAFT.y) > shaft.LIFT_NEAR then
        lift.anchor, lift.samples, lift.sample_t = nil, 0, nil
        return nil, false, nil
    end
    if sampled ~= lift.sample_t then
        local a = lift.anchor
        local moved = not a or (pos.x-a.x)^2+(pos.y-a.y)^2+(pos.z-a.z)^2 > MOVE_EPS^2
        if moved or not lift.sample_t or sampled-lift.sample_t > SAMPLE_MAX_GAP then
            lift.anchor = {x=pos.x,y=pos.y,z=pos.z}
            lift.change_t, lift.samples = sampled, 0
        end
        lift.samples, lift.sample_t = (lift.samples or 0)+1, sampled
    end
    lift.seen_t, lift.z = sampled, pos.z
    return pos.z, (lift.samples or 0)>=3 and sampled-lift.change_t>=STOP_S, pos
end
local function docked(pos, still, side, shaft)
    shaft = shaft or active_shaft()
    local dock = shaft.DOCK[side]
    return pos ~= nil and still == true and R.dist2(pos.x, pos.y, dock.x, dock.y) <= DOCK_XY
        and math.abs(pos.z - dock.z) <= LIFT_TOL
end
EL._lift_state = lift_state

-- ---------------------------------------------------------------- the run --
local function shaft_name()
    local s = st and st.shaft
    return (s and s.name) or "Telredor"
end

local function phase(p, why)
    st.phase, st.phase_t = p, R.now()
    R.trail("elevator", "%s lift (%s): %s%s", shaft_name(), st.dir, p, why and (" - " .. why) or "")
end

local function stop_run(why, ok)
    if st then R.trail("elevator", "%s lift (%s): %s", shaft_name(), st.dir, why) end
    if not ok then
        abort_until = R.now() + ABORT_HOLD
        R.log(shaft_name() .. " lift: " .. tostring(why) .. " - not used for " .. ABORT_HOLD .. " s")
    end
    st = nil
    wanted_shaft = nil
end

local function at(p, yd, ztol)
    local x, y, z = here()
    if not x then return false end
    return R.dist2(x, y, p.x, p.y) <= (yd or AT_YD) and math.abs(z - p.z) <= (ztol or Z_TOL)
end

-- Live Zygor step is Aldor Rise work (turn-in / accept / talk at Ishanah and
-- the other Aldor NPCs). Used when the converted waypoint is on the rise XY
-- but still at terrace height (map_to_world casts from the player's floor).
local ALDOR_QUEST = { [10551] = true, [10554] = true, [10021] = true, [10325] = true }
local ALDOR_NPC = { [18538] = true }   -- Ishanah (step 9 npc 18538)
local function zygor_aldor_work()
    local g = package.loaded["quest/guide"]
    if type(g) ~= "table" or type(g.step) ~= "function" then return false end
    local ok, step = pcall(g.step)
    if not ok or type(step) ~= "table" or type(step.goals) ~= "table" then return false end
    for i = 1, #step.goals do
        local goal = step.goals[i]
        if type(goal) == "table" then
            if ALDOR_NPC[tonumber(goal.npc_id) or 0] then return true end
            if ALDOR_QUEST[tonumber(goal.quest_id) or 0] then return true end
            local blob = (tostring(goal.npc or "") .. " " .. tostring(goal.text or "")
                .. " " .. tostring(goal.title or "") .. " " .. tostring(goal.target or "")):lower()
            if blob:find("scryer", 1, true) then
                -- Scryer bank / seer is the other terrace; not this lift
            elseif blob:find("ishanah", 1, true) or blob:find("aldor", 1, true) then
                return true
            end
        end
    end
    return false
end

local function aldor_dest_top(dx, dy, dz)
    if ALDOR.is_top(dx, dy, dz) then return true end
    -- Aldor turn-in / talk: Zygor's NPC coords are the rise even when z is
    -- still the terrace probe.
    return zygor_aldor_work() and aldor_in_rise(dx, dy)
end

local function pick_need(hx, hy, hz, dx, dy, dz)
    for i = 1, #SHAFTS do
        local sh = SHAFTS[i]
        if sh.is_top(hx, hy, hz) and not sh.is_top(dx, dy, dz) then return sh, "down" end
    end
    for i = 1, #SHAFTS do
        local sh = SHAFTS[i]
        local dest_top = sh.is_top(dx, dy, dz)
        if sh == ALDOR and not dest_top then dest_top = aldor_dest_top(dx, dy, dz) end
        if not sh.is_top(hx, hy, hz) and dest_top and not (hz and hz >= sh.TOP_Z) then
            return sh, "up"
        end
    end
    return nil
end

-- Zygor "Ride the elevator up/down" on the live step (Terokkar Forest 63-64
-- step 8 and the later Aldor copies). Telredor / Stormspire / Thunder Bluff
-- lines are other lifts. Dest near 41.68,38.61 still fires through cap_z even
-- when this snapshot is empty.
local function zygor_aldor_ride()
    local g = package.loaded["quest/guide"]
    if type(g) ~= "table" or type(g.step) ~= "function" then return nil end
    local ok, step = pcall(g.step)
    if not ok or type(step) ~= "table" or type(step.goals) ~= "table" then return nil end
    for i = 1, #step.goals do
        local goal = step.goals[i]
        local t = type(goal) == "table" and (goal.text or goal.title) or nil
        if type(t) == "string" then
            local low = t:lower()
            if low:find("ride the elevator", 1, true) then
                if low:find("telredor", 1, true) or low:find("stormspire", 1, true)
                    or low:find("thunder", 1, true) then
                    return nil
                end
                if low:find("down", 1, true) then return "down" end
                return "up"
            end
        end
    end
    return nil
end

local function ride_hint(hx, hy, hz, dx, dy, dz)
    local text_dir = zygor_aldor_ride()
    if not text_dir then return nil end
    local near_goto = R.dist2(dx, dy, ALDOR.SHAFT.x, ALDOR.SHAFT.y) <= ALDOR.GOTO_R
        or aldor_in_rise(dx, dy)
    if text_dir == "up" then
        if ALDOR.is_top(hx, hy, hz) or (hz and hz >= ALDOR.TOP_Z) then return nil end
        if near_goto then return ALDOR, "up" end
    elseif text_dir == "down" then
        if ALDOR.is_top(hx, hy, hz) then return ALDOR, "down" end
    end
    return nil
end

local BOARDED = { board = true, ride = true, exit = true }

--- Should the walk from (hx, hy, hz) to `dest` take a lift? "up" | "down" | nil.
--- 1.22.1: a run not boarded yet follows the destination - a Zygor step that
--- completes while the bot walks to / waits at the lift and points back to the
--- player's own level ends the run (no ride for nothing); a boarded run (on the
--- platform, riding, walking the exit path) always finishes.
function EL.wants(hx, hy, hz, dx, dy, dz)
    if st and BOARDED[st.phase] then return st.dir end
    if not hx or not dx or not on_map() then return st and st.dir or nil end
    local sh, dir = pick_need(hx, hy, hz, dx, dy, dz)
    if not dir then sh, dir = ride_hint(hx, hy, hz, dx, dy, dz) end
    if st then
        if dir == st.dir and (not sh or sh == st.shaft) then return dir end
        local was = st.dir
        R.trail("elevator", "%s lift (%s): the destination changed before boarding - %s", shaft_name(), was,
            dir and ("now " .. dir) or "no lift needed")
        st = nil
        wanted_shaft = nil
        if not dir then
            local nav = N()
            if nav then pcall(nav.stop, "elevator: not needed any more") end
        end
    end
    if R.now() < abort_until then return nil end
    wanted_shaft = sh
    return dir
end

--- Start (or keep) the lift run for `dest`. True while it runs.
function EL.run(dir, dest)
    if not st then
        st = { dir = dir, t0 = R.now(), goal = dest, shaft = wanted_shaft or TELREDOR }
        lift.said = false
        phase("approach", "to " .. string.format("(%.0f, %.0f, %.0f)", dest.x or 0, dest.y or 0, dest.z or 0))
    end
    return true
end

function EL.active() return st ~= nil end
--- The player must not be moved by anything else (on the platform / boarding).
function EL.riding() return st ~= nil and (st.phase == "board" or st.phase == "ride") end

--- Every frame (movement.pulse): the run's next step.
function EL.tick()
    if not st then return end
    local nav = N()
    if not nav then return end
    local t = R.now()
    local shaft = st.shaft or TELREDOR
    local run = shaft.RUN[st.dir]
    if t-st.phase_t>(LIMIT[st.phase] or 60) then
        if st.phase=="wait_lift" or st.phase=="ride" then
            st.phase_t=t
            nav.stop("elevator: still waiting for a stopped platform")
            R.log(shaft.name .. " lift: waiting for the platform to stop at the correct landing")
        elseif st.phase=="board" then
            nav.stop("elevator: boarding timed out")
            return phase("wait_lift", "waiting for the next stationary platform")
        elseif st.phase=="exit" then
            st.phase_t=t
            nav.stop("elevator: exit not yet complete")
        else return stop_run(st.phase .. " took too long", false) end
    end
    local me = R.me()
    local okd, dead = pcall(function() return me and me:is_dead() end)
    if okd and dead == true then return stop_run("player died", false) end
    local x, y, z = here()
    if not x then return end
    local wait_p = P(run.path[run.wait_i])
    local plat_p = P(run.path[run.wait_i + 1])
    local exit_1 = P(run.exit[1])
    local lz, still, lp = lift_state(t)
    local at_start = docked(lp,still,st.dir == "down" and "top" or "bottom", shaft)
    local at_end = docked(lp,still,st.dir == "down" and "bottom" or "top", shaft)

    if st.phase ~= st.logged then             -- each phase once: where the lift was
        st.logged = st.phase
        R.trail("elevator", "  player z %.1f, lift %s", z, lz and string.format("z %.1f %s", lz, still and "still" or "moving") or "not seen")
    end
    if st.phase == "approach" then
        if at(P(run.path[1]), 4) or R.dist2(x, y, wait_p.x, wait_p.y) < R.dist2(run.path[1][1], run.path[1][2], wait_p.x, wait_p.y) then
            return phase("to_wait")
        end
        nav.nav_to(P(run.path[1]), true, "elevator")
    elseif st.phase == "to_wait" then
        if at(wait_p) then nav.stop("elevator: at the waiting spot") return phase("wait_lift") end
        nav.follow_route(run.to_wait)
    elseif st.phase == "wait_lift" then
        if at_start and math.abs(z-plat_p.z)<=Z_TOL then
            return phase("board", "platform stopped at boarding XYZ")
        end
        if not lp and t-st.phase_t>10 and not st.missing_logged then
            st.missing_logged=true
            EL.log_shaft_objects()
            R.log(shaft.name .. " lift: waiting for a visible, stationary platform at the landing")
        end
    elseif st.phase == "board" then
        if at(plat_p, 1.5) and lp and math.abs(lz-z)<=LIFT_TOL then
            nav.stop("elevator: boarded")
            return phase("ride")
        end
        -- the lift left before the player was on it
        if not at_start then
            nav.stop("elevator: the lift left")
            return phase("wait_lift", "platform moved or disappeared before boarding")
        end
        nav.step_into(plat_p)
    elseif st.phase == "ride" then
        if at_end and math.abs(z-exit_1.z)<=Z_TOL
            and R.dist2(x,y,exit_1.x,exit_1.y)<=EXIT_OFF then
            return phase("exit", "platform stopped at destination XYZ")
        end
        -- missed it: still at the start level and the lift is far away from the player
        if lz and math.abs(z - plat_p.z) <= Z_TOL and math.abs(lz - z) > 10 then
            if st.dir == "down" then return phase("to_wait", "the lift went without the player") end
        end
        -- (nothing walks while riding: N.nav_to refuses everything, EL.riding)
    elseif st.phase == "exit" then
        -- 1.34.5: off the platform with straight steps (move_direct, as boarding) - Sentinel's
        -- mesh has no lift, so follow_path from the platform sent nothing for 10 s and the lift
        -- took the player back down. The first recorded point EXIT_OFF yd from the platform.
        local off = P(run.exit[run.off_i])
        if at(off, 3, 3) then return stop_run("done - off the lift, on to the destination", true) end
        -- carried away mid-step: ride on (back up / down again)
        if (not at_end or math.abs(z - exit_1.z) > Z_TOL + 1) and R.dist2(x, y, exit_1.x, exit_1.y) < EXIT_OFF then
            nav.stop("elevator: exit platform moved or disappeared")
            return phase("ride", "the lift moved before the player stepped off")
        end
        nav.step_into(off)
    end
end

function EL.reset()
    st, abort_until, wanted_shaft = nil, -1e9, nil
    lift.guid, lift.found, lift.z, lift.anchor, lift.sample_t = nil, nil, nil, nil, nil
    lift.samples, lift.scan_t, lift.seen_t, lift.said = 0, -1e9, -1e9, false
end

return EL
