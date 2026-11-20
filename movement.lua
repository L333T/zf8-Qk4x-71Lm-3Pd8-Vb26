-- ============================================================================
-- Master Farmer - Zygor Forever
-- Movement - public facade
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- Folder: Zygor_Forever
-- ============================================================================
-- 1.10.0 SENTINEL NAVIGATION (docs/SENTINEL_PORT_GUIDE.md). Sentinel does
-- every walk (movement/nav.lua over the adapter movement/sentinel.lua):
-- navmesh paths, steering, its own stuck recovery. Sentinel Navigation /
-- Sentinel are no longer used. This layer presses no keys while a Sentinel
-- walk runs; the stuck watchdog below only issues fresh paths and detours.
-- This layer decides where to go and when to stand still:
--
--   travel   nav_to / follow_route / nav_stop      movement/nav
--   combat   combat_engage / combat_release        movement/combat
--   holds    rest, cast, channel, loot, backpedal  movement/locks
--   sight    facing, line of sight, arrival        movement/range, sight
--   corridor recorded-path leash (path_runner)      movement/leash
--   areas    blacklisted areas                     movement/zones
--
-- The surface below is the one the rest of the bot calls (every name has
-- callers; the 2.x helpers nobody called are gone). Reading a name that does
-- not exist is logged once and answers nil.
-- ============================================================================

local R  = require("movement/core")
local Z  = require("movement/zones")
local N  = require("movement/nav")
local Lk = require("movement/locks")
local Rg = require("movement/range")
local C  = require("movement/combat")
local L  = require("movement/leash")
local Pv = require("movement/pivot")   -- 3.2.0: stop and turn on sharp waypoint turns
local Mt = require("movement/mount")   -- 3.8.0: mount for travel (the 1-60 way)
local EL = require("movement/elevator")   -- 1.22.0 / 1.66.0: Telredor and Aldor Rise lifts
local BT = require("movement/boat")       -- 1.2.32: the Stormwind <-> Auberdine boat
local FR = require("movement/front")      -- 1.2.34: Simple Movement facing / keeping enemies in front
local AS = require("movement/astar")      -- 1.30.0: local A* fallback
local TR = require("movement/trace")      -- 1.32.0: ray helpers (Desktop\Helper trace.lua) for Sentinel walks
-- 1.30.0: the General tab box "Local A* Fallback" (off by default); AS.ON is the code kill switch
AS.enabled_fn = function()
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return false end
    return gui.is_on("mfz_astar") == true
end
local SW = require("movement/swim")       -- 1.74.0: no swim travel; hops skip jump in water

-- 3.8.0: Gathering uses its own "Use Mount" box; questing / grinding the
-- General tab one
Mt.enabled_fn = function()
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return true end
    return gui.is_on("mfz_mount") ~= false
end

-- 3.2.0: the GUI switch (Path tab, "Stop and Turn on Sharp Turns", on by default)
Pv.set_enabled_fn(function()
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return true end
    local v = gui.is_on("sharp_turn_stop")
    return v ~= false
end)

local movement = {}

-- GUI snapshot state (built in movement.pulse, read by debug_snapshot)
local SNAP_EVERY = 0.5
local snap = { state = "idle", owner = "none", quiet = false }
local snap_t = -1e9
local build_snapshot

-- ============================================================================
-- TRAVEL
-- ============================================================================
movement.nav_to       = function(dest, direct) return N.nav_to(dest, direct) end
movement.nudge        = function(dest) return N.nav_to(dest) end
movement.swim_to      = N.swim_to                  -- 1.74.0: Sentinel walk (same as nav_to)
--- 1.74.0: a walk at an enemy / a corpse is Sentinel's path on walkable floors.
movement.approach_to  = function(dest, direct, mode)
    return N.nav_to(dest, direct, mode)
end
-- 3.5.0: RestedXP waypoints / movement instructions: 3-yard, object-checked walks
movement.guide_to     = function(dest) return N.nav_to(dest, true, "guide") end
-- 1.20.0: kept for the surface - a guide nav_to (the 1.4.0 per-key gate is gone)
movement.waypoint_walk = function(dest, key) return N.waypoint_walk(dest, key) end
movement.follow_route = N.follow_route
movement.hint_next = N.hint_next                    -- the walk after the current one (floors asked early)
movement.follow_nodes = N.follow_nodes              -- 1.67.0: plan_route then follow_path
movement.reach_settled = N.reach_settled            -- 1.67.0: skip only after floors answered
movement.want_input_driver = N.want_input_driver      -- 1.7.4 (gui Start / Stop)
movement.step_into = N.step_into                      -- 1.7.7: the last yards into a portal
movement.transport_blocked = N.transport_blocked
movement.awaiting_path = N.awaiting_path            -- 1.2.51: Sentinel still planning the path
movement.nav_pending = N.pending                    -- 1.2.65: floors / path being asked (the target is not to blame)
movement.avoid_area = N.avoid_area                  -- 1.11.0: Sentinel avoidance zone + soft re-path
movement.path_ahead = N.path_ahead                    -- 1.7.9: the walk's path ahead (threat check)
movement.nav_path     = function(points) return N.follow_route(points) end
-- 3.0.4: callers stop every tick once "near" an NPC (4-5 yd); an approach
-- movement.interact started (to NPC_REACH) is not cancelled by that
local npc_walk = { until_t = 0 }
movement.nav_stop     = function()
    if R.now() < npc_walk.until_t and N.mode() == "npc" then return end
    -- 1.8.7: a stopped walk ends a running unstick try (its keys let go, the
    -- "mf_unstick" pause resumed) - it must not carry on into the next walk
    if movement.unstick_stop then pcall(movement.unstick_stop, "the walk stopped") end
    N.stop("Master Farmer")
end
movement.is_moving    = function() return N.busy() or R.backpedal_until ~= nil end
movement.is_navigating = function() return N.busy() and not C.in_combat_movement() end
movement.sentinel_active = N.busy
movement.is_quiet     = function() return R.now() < (R.quiet_until or 0) end
--- 1.2.42: something moved the player within the last `secs` seconds.
movement.recently_moved = function(secs) return R.now() - (R.last_move_t or -1e9) < (tonumber(secs) or 0.3) end

--- The running walk's destination is within `yards` (2D) of `pos`.
function movement.headed_to(pos, yards)
    local dx, dy = N.destination()
    local x, y = R.xyz(pos)
    if not dx or not x then return false end
    return R.dist2(dx, dy, x, y) <= (tonumber(yards) or 15)
end

-- "long travel" / approach hints: Sentinel needs neither (one path to the
-- real destination); kept so the callers' bookkeeping stays simple.
local hints = { keep = false, approach = nil, target = nil }
movement.keep_path           = function(on) hints.keep = on == true end
movement.set_approach        = function(kind) hints.approach = kind end
movement.set_approach_target = function(guid) hints.target = guid end

--- Everything stops: walk, fight, holds, backpedal.
local ou_end                                             -- 1.7.16 (defined with the outdoor unstick)
local OU_probe_stop                                      -- audit S2 (defined with the outdoor unstick)
function movement.halt()
    if ou_end then pcall(ou_end, "halt") end             -- 1.7.16
    if OU_probe_stop then pcall(OU_probe_stop) end       -- audit S2: a probe pause is lifted
    pcall(function() require("managems").reset() end)   -- audit N8: a "conjure" pause too
    Pv.release("halt")
    C.combat_release()
    Lk.clear()
    EL.reset()                                           -- 1.22.0: a lift run ends with the bot
    BT.reset()                                           -- 1.2.32: a boat run too
    FR.release()                                         -- 1.2.34: let go of the Simple Movement keys
    AS.cancel("halt")                                    -- 1.30.0
    TR.reset()                                           -- 1.32.0
    SW.reset()                                           -- 1.74.0: no held swim-up to end
    N.stop("halt", true)                                 -- 1.69.0: Stop / close / unload, not a deferred pulse
    pcall(function() require("movement/memory").flush(true) end)   -- 1.9.0: the nav memory is written
    N.release_driver_now()                               -- 1.7.4 (a no-op on Sentinel)
    pcall(function() core.input.stop_attack() end)       -- 1.69.0: Stop / close also ends auto-attack
end

-- ============================================================================
-- FAILURES
-- ============================================================================
movement.last_fail_reason  = N.last_fail_reason
movement.elevator_active   = EL.active                 -- 1.22.0
movement.boat_active       = BT.active                 -- 1.2.32
movement.boat_wants        = BT.wants
movement.boat_start        = BT.start
movement.boat_status       = BT.status
movement.front_active      = FR.active                 -- 1.2.34
movement.no_jump           = SW.no_jump                -- 1.23.0: in the water no jump (a swim up)
movement.water_breathing_combat = SW.water_breathing_combat   -- 1.24.0: fight in the water as on land
movement.reached_short     = N.reached_short       -- 1.20.1: "arrived" as close as the navmesh goes
movement.server_trouble    = N.server_trouble     -- 1.20.0: a server code, not the place
movement.last_fail_offmesh = N.last_fail_offmesh
movement.clear_fail        = N.clear_fail

-- ============================================================================
-- COMBAT
-- ============================================================================
movement.combat_engage        = C.combat_engage
movement.combat_release       = C.combat_release
movement.in_combat_movement   = C.in_combat_movement
movement.combat_unit          = C.combat_unit
movement.combat_in_position   = C.in_position
movement.set_combat_profile   = C.set_combat_profile
movement.clear_combat_profile = C.clear_combat_profile

-- ============================================================================
-- FACING / SIGHT / RANGE
-- ============================================================================
movement.face           = Rg.face
movement.has_los        = Rg.has_los
movement.in_fight_range = Rg.in_fight_range
movement.arrived        = Rg.arrived
movement.line_blocked   = Rg.line_blocked
movement.can_reach      = Rg.can_reach
--- Ground height: returns its third argument (hint_z) unchanged - no ray or
--- height query of its own (movement/nav asks Sentinel's floors where it walks).
movement.ground_z       = function(_, _, hint_z) return hint_z end

-- ============================================================================
-- AREAS
-- ============================================================================
movement.is_blocked     = Z.is_blocked
movement.blacklist_area = Z.blacklist_area

-- ============================================================================
-- HOLDS
-- ============================================================================
movement.set_resting     = Lk.set_resting
movement.release         = Lk.release
movement.cast_cancelled  = Lk.cast_cancelled
movement.prepare_cast    = Lk.prepare_cast
movement.prepare_channel = Lk.prepare_channel
movement.prepare_ground  = Lk.prepare_ground
movement.pause_for_loot  = Lk.pause_for_loot
movement.backpedal       = Lk.backpedal
movement.backpedaling    = Lk.backpedaling
movement.blink_away      = Lk.blink_away             -- 1.7.15
movement.blinking        = Lk.blinking

-- 3.0.2: AT AN NPC. Every NPC interaction goes through movement.interact:
-- the walk stops and travel is held NPC_HOLD s from the LAST interaction,
-- so a window, gossip, purchase, repair or turn-in completes before the
-- bot walks off (walking away closed trainer / merchant windows). Fights
-- are not held (combat_engage walks regardless).
-- 3.0.4: the player walks to within NPC_REACH yd of the NPC first (the
-- callers stopped at 4-5 yd and the game answered "too far away"), and the
-- hold is NPC_HOLD = 10 s (user: stay long enough for the actions).
local NPC_HOLD = 10.0
local NPC_REACH = 3.0
movement.NPC_REACH = NPC_REACH
local function event_clock()
    -- events.lua stamps UI errors with izi.now(); the too-far check compares
    -- against that clock
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local okn, t = pcall(izi.now)
        if okn and type(t) == "number" then return t end
    end
    return nil
end

function movement.npc_hold(seconds)
    R.npc_until = R.now() + (tonumber(seconds) or NPC_HOLD)
    R.npc_ev_t = event_clock()
    if N.busy() then N.stop("at an NPC") end
end

function movement.npc_holding()
    return (R.npc_until or 0) > R.now()
end

--- Interact with an NPC and hold travel NPC_HOLD s. True when sent.
--- Farther than NPC_REACH: walks up to the NPC instead and answers false
--- (the caller's next attempt interacts from there).
function movement.interact(unit)
    if not unit then return false end
    local me = R.me()
    local d = nil
    if me then
        local okd, v = pcall(me.distance_to, me, unit)
        if okd and type(v) == "number" then d = v end
    end
    if d and d > NPC_REACH then
        local okp, pos = pcall(unit.get_position, unit)
        if okp and pos then
            R.npc_until, R.npc_ev_t = nil, nil
            if N.nav_to(pos, true, "npc") then
                npc_walk.until_t = R.now() + 3.0
                R.trail("move", "NPC %.1f yd away - walking within %.0f yd before interacting", d, NPC_REACH)
                return false
            end
        end
    end
    npc_walk.until_t = 0
    movement.npc_hold()
    -- 1.17.0 (restedXP 4.5.0): a game object that gives / takes a quest (a
    -- cauldron, a diary) is opened with use_object - interact_with_object
    -- does not cover every object
    local okq, is_unit = pcall(unit.is_unit, unit)
    if not okq then return false end           -- audit 1.19.0: unknown kind (freed object) - never interact_with_object
    if is_unit == false then
        -- 1.18.0 (restedXP 4.27.0): use_object ONLY - interact_with_object on a world
        -- object crashed the game (Joseph Redpath's Monument, the Pamela's Doll pieces)
        do local fr = package.loaded["flightrec"] if fr then fr.note("use_object") end end 
        local oku, used = pcall(function() return core.input.use_object(unit) end)
        return oku and used == true
    end
    do local fr = package.loaded["flightrec"] if fr then fr.note("interact") end end 
    local ok = pcall(function() core.input.interact_with_object(unit) end)
    return ok
end

-- ============================================================================
-- RECORDED-PATH CORRIDOR (path_runner)
-- ============================================================================
movement.set_path_leash    = L.set_path_leash
movement.clear_path_leash  = L.clear_path_leash
movement.needs_rejoin      = L.needs_rejoin
movement.rejoin_path       = L.rejoin_path
movement.path_anchor_index = L.path_anchor_index

-- ============================================================================
-- NAVMESH QUERIES
-- ============================================================================
movement.reachable         = N.reachable
movement.node_reachable    = N.node_reachable
movement.reach_z           = N.reach_z
movement.reach_forget      = N.reach_forget
movement.plan_grind_route  = N.plan_grind_route
movement.grind_visit_order = N.grind_visit_order
movement.nav_stats         = function() return N.stats end

-- ============================================================================
-- SPELLS (spellcheck.lua records each cast sent; class retreat rules read it)
-- ============================================================================
function movement.note_spell(id, target)
    R.last_spell_id, R.last_spell_target, R.last_spell_t = id, target, R.now()
end

function movement.last_player_spell()
    return R.last_spell_id, R.last_spell_target, R.last_spell_t
end

-- ============================================================================
-- PER FRAME / DEBUG
-- ============================================================================
-- 1.10.0 SENTINEL: Sentinel steers and recovers on its own (jump / probe /
-- strafe / backtrack, navigating.recovering.*), so this layer presses NO keys
-- while a Sentinel walk runs (docs/SENTINEL_PORT_GUIDE.md rule 4). Retired:
-- the 1.7.8 indoor jump, the 1.9.2 outdoor nudge (jump + strafe right / left),
-- the 1.8.7 slight-turn and back-up rungs and the 1.7.16 forward + strafe
-- tries - each paused the walk ("mf_unstick"), which on Sentinel is a stop()
-- that cuts its own recovery short (restedXP 4.2.1, Eastern Plaguelands log).
--
-- What stays is the NO-PROGRESS WATCHDOG (1.7.21 / 1.7.23 / 1.7.24): "stuck"
-- is no progress along the route - the distance to the walk's destination not
-- PROGRESS_YD shorter (and no MOVE_YD of real movement) for STILL_S - counted
-- only while Sentinel is NOT already recovering, re-planning or waiting for
-- its path. Each stuck window takes the next rung of the episode's ladder.
-- 1.29.0 (user: "black list stuck spots, move back from the stuck area and
-- actively search for the path with least angle and least obstructions"):
--   backoff  the stuck spot is BLACKLISTED - confirmed in movement/memory (its
--            black point, the session zones: no goal there) AND made a
--            Sentinel avoidance zone of AVOID_R yd (N.avoid_area -> obstacle:
--            add_zone + a soft re-path), so every path planned after it goes
--            ROUND it - then the player walks BACK along its own trail
--            (breadcrumbs every CRUMB_YD yd) BACK_YD yd from the spot (a
--            Sentinel walk, N.detour) and the goal is planned again from there;
--   search   an ACTIVE SEARCH round the spot: SEARCH_ANGLES either side of the
--            way to the goal at the round's radius (SEARCH_RADII), one path
--            query per point, at most one every SEARCH_GAP s. Every answer is
--            scored (lower is better) - the steepest stretch (slope), the
--            detour against the straight line and the sharp corners
--            (obstructions), the turn away from the goal (angle); a path that
--            climbs steep ground, runs back through the stuck spot, ends in a
--            blacklisted spot or is over DETOUR_STRAIGHT x the straight line is
--            out. The best one with a clean path on to the goal is walked
--            (N.detour), then the goal. No point: the next round, wider; after
--            the last round the walk stops (longstuck is the backstop).
-- No keys, no pause: the walk goes on while the queries run.
-- The episode ends on real progress (EP_GAIN closer) or EP_RADIUS away from
-- the spot and closer to the goal.
local OU = { STILL_S = 6.0, PROGRESS_YD = 2.0, MOVE_YD = 4.0, IDLE_OK = 1.5, ARRIVED_YD = 4.0,
    EP_RADIUS = 15, EP_GAIN = 8, DETOUR_STRAIGHT = 3.5, ep = nil, probing = false,
    LADDER = { { "backoff" }, { "search" } },          -- 1.29.0 (was repath, fan)
    LADDER_INDOOR = { { "backoff" }, { "search" } },
    -- 1.29.0: the blacklist / back-off / search numbers
    AVOID_R = 6, BACK_YD = 10, CRUMB_YD = 2, CRUMB_MAX = 40,
    SEARCH_ANGLES = { 0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180 }, SEARCH_RADII = { 15, 25, 35 },
    SEARCH_GAP = 1.0, SEARCH_WAIT = 6.0, CORNER_DEG = 35,
    FAN_ANGLES = { 45, -45, 90, -90, 135, -135, 180 }, FAN_RADII = { 15, 30, 50 }, FAN_KEEP_OFF = 6, FAN_DZ = 20, PROBE_MAX_S = 4,
    FAN_GAP = 1.0,             -- audit 1.19.0: s between two fan points
    best = nil, best_t = 0, dest = nil, idle_since = nil, run = nil, tries = 0 }
movement.OU = OU
--- 1.8.7 kept for nav_stop / halt: nothing of ours runs any more (no keys).
--- A halt also forgets the watchdog's window and episode.
ou_end = function(why)
    OU.run, R.unsticking = nil, false
    OU.search = nil -- invalidate all asynchronous detour answers on Stop
    if why == "halt" then OU.best, OU.dest, OU.idle_since, OU.ax, OU.ay, OU.ep = nil, nil, nil, nil, nil, nil end
end
movement.unstick_stop = ou_end
local function probe_start(t) OU.probing, OU.probe_t = true, t end
local function probe_stop() OU.probing = false end
OU_probe_stop = probe_stop
-- 1.9.2 (Forever 1.0.14): the stuck-episode side of the nav memory
-- (movement/memory): the episode token (a cell is confirmed once per episode)
-- and the confirm of the episode's origin, mirrored to the session's zones as
-- record_fail's are. Bookkeeping only.
local function ou_mem(fn, ...)
    local ok, MEM = pcall(require, "movement/memory")
    if ok and type(MEM) == "table" and type(MEM[fn]) == "function" then
        local okc, r = pcall(MEM[fn], ...)
        if okc then return r end
    end
    return nil
end
local function ou_confirm(ep, why)
    if not (R.finite(ep.x) and R.finite(ep.y) and R.finite(ep.z)) then return end
    local rec = ou_mem("confirm_episode", ep.x, ep.y, ep.z, why)
    if rec and type(N.mem_black) == "function" then pcall(N.mem_black, rec, why) end
end

-- 1.29.0 THE TRAIL: where the player has walked, newest last (the back-off walks it back).
local crumbs = {}
OU._crumbs = crumbs
local function crumb(x, y, z)
    local c = crumbs[#crumbs]
    if c and R.dist2(c.x, c.y, x, y) < OU.CRUMB_YD then return end
    -- a jump (a hearth, a flight, a portal, a lift): the old trail is not behind us
    if c and R.dist2(c.x, c.y, x, y) > 15 then
        for i = #crumbs, 1, -1 do crumbs[i] = nil end
    end
    crumbs[#crumbs + 1] = { x = x, y = y, z = z }
    if #crumbs > OU.CRUMB_MAX then table.remove(crumbs, 1) end
end

--- 1.29.0: the point BACK_YD yd back along the trail from the stuck spot (else
--- straight back, away from the goal).
local function back_point(ep, dx, dy)
    local run, px, py = 0, ep.x, ep.y
    for i = #crumbs, 1, -1 do
        local c = crumbs[i]
        run = run + R.dist2(px, py, c.x, c.y)
        px, py = c.x, c.y
        if R.dist2(c.x, c.y, ep.x, ep.y) > OU.BACK_YD * 2 then break end    -- not this stretch of the trail
        if run >= OU.BACK_YD and R.dist2(c.x, c.y, ep.x, ep.y) >= OU.BACK_YD * 0.6 then
            return { x = c.x, y = c.y, z = c.z }, "along the trail"
        end
    end
    local fx, fy = dx - ep.x, dy - ep.y
    local l = math.sqrt(fx * fx + fy * fy)
    if l < 0.1 then return nil end
    return { x = ep.x - fx / l * OU.BACK_YD, y = ep.y - fy / l * OU.BACK_YD, z = ep.z }, "straight back"
end
OU._back_point = back_point

--- 1.29.0: the backoff rung - blacklist the spot (memory + session zone + a
--- Sentinel avoidance zone), then walk back from it.
local function backoff_step(ep, x, y, d, dx, dy)
    if not ep.recorded then
        ep.recorded = true
        ou_confirm(ep, "stuck episode: blacklisted")
    end
    local zoned = type(N.avoid_area) == "function"
        and select(2, pcall(N.avoid_area, { x = ep.x, y = ep.y, z = ep.z }, OU.AVOID_R, "stuck spot")) == true
    local bp, how = back_point(ep, dx, dy)
    R.trail("move", "stuck at (%.0f, %.0f): blacklisted (%s), backing off %s%s (%.0f yd to go)", ep.x, ep.y,
        zoned and "Sentinel avoids it now" or "memory / zones only", tostring(how or "-"),
        bp and string.format(" to (%.0f, %.0f)", bp.x, bp.y) or "", d)
    if bp and N.detour(bp, "stuck: backing off the stuck spot") then
        ep.backed = true
        return
    end
    N.replan_fresh("stuck " .. ep.step)                  -- no way back: a fresh path from here
end

--- 1.29.0: score one search answer (lower is better), or nil + why when it is out.
local function score_path(points, ep, here_x, here_y, bearing)
    if type(points) ~= "table" or #points < 2 then return nil, "no path" end
    local len = 0
    for i = 2, #points do len = len + R.dist2(points[i - 1].x, points[i - 1].y, points[i].x, points[i].y) end
    local e = points[#points]
    local straight = math.max(1, R.dist2(here_x, here_y, e.x, e.y))
    if len > straight * OU.DETOUR_STRAIGHT + 2 then return nil, string.format("%.0f yd for %.0f straight", len, straight) end
    local maxg, corners = 0, 0
    local escaping = R.dist2(here_x, here_y, ep.x, ep.y) <= OU.FAN_KEEP_OFF
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if a.z and b.z and type(N.STEEP) == "table" and type(N.STEEP.grade) == "function" then
            local g, steep = N.STEEP.grade(a, b)
            if steep then return nil, "steep ground" end
            if g > maxg then maxg = g end
        end
        local da, db = R.dist2(a.x,a.y,ep.x,ep.y), R.dist2(b.x,b.y,ep.x,ep.y)
        if escaping then
            if db < da - 0.1 then return nil, "back through the stuck spot" end
            if db > OU.FAN_KEEP_OFF then escaping = false end
        else
            local vx, vy = b.x-a.x, b.y-a.y
            local len2 = vx*vx+vy*vy
            local u = len2 > 0 and math.max(0,math.min(1,((ep.x-a.x)*vx+(ep.y-a.y)*vy)/len2)) or 0
            if R.dist2(a.x+vx*u,a.y+vy*u,ep.x,ep.y) <= OU.FAN_KEEP_OFF then
                return nil, "back through the stuck spot"
            end
        end
        local c = points[i + 1]
        if c then
            local h1 = math.atan2(b.y - a.y, b.x - a.x)
            local h2 = math.atan2(c.y - b.y, c.x - b.x)
            local turn = math.abs(((h2 - h1 + math.pi) % (2 * math.pi)) - math.pi)
            if turn > math.rad(OU.CORNER_DEG) then corners = corners + 1 end
        end
    end
    if escaping then return nil, "still inside the stuck spot" end
    if Z.is_blocked({ x = e.x, y = e.y, z = e.z or ep.z }) then return nil, "a blacklisted spot" end
    local sc = maxg * 20 + (len / straight - 1) * 10 + corners * 3 + math.abs(bearing) * 0.05
    return sc, string.format("slope %.2f, detour x%.2f, %d corner(s), %+d deg", maxg, len / straight, corners, bearing)
end
OU._score_path = score_path

--- 1.29.0: start a search round round the stuck spot.
local function search_start(t, ep, x, y, dx, dy)
    ep.round = (ep.round or 0) + 1
    if ep.round > #OU.SEARCH_RADII then
        R.trail("move", "stuck search: no way round in %d rounds - walk stopped", #OU.SEARCH_RADII)
        OU.ep, OU.search = nil, nil
        ou_mem("episode", nil)
        N.stop("stuck: no way round")
        return
    end
    local fx, fy = dx - x, dy - y
    local l = math.sqrt(fx * fx + fy * fy)
    if l < 0.1 then return end
    fx, fy = fx / l, fy / l
    local yd = OU.SEARCH_RADII[ep.round]
    local _, _, pz = R.here()
    local list = {}
    for _, deg in ipairs(OU.SEARCH_ANGLES) do
        local a = math.rad(deg)
        local vx, vy = fx * math.cos(a) - fy * math.sin(a), fx * math.sin(a) + fy * math.cos(a)
        list[#list + 1] = { x = x + vx * yd, y = y + vy * yd, z = pz or ep.z, deg = deg }
    end
    OU.search = { ep = ep, list = list, i = 0, res = {}, pend = false, last = -1e9, t0 = t, hx = x, hy = y,
        gx = dx, gy = dy, yd = yd, stage = "scan" }
    R.trail("move", "stuck search round %d: %d directions at %.0f yd, scored by slope / obstructions / angle",
        ep.round, #list, yd)
end

--- 1.29.0: one tick of the running search (one query a SEARCH_GAP at most).
local function search_tick(t)
    local sr = OU.search
    if not sr then return end
    local ep = sr.ep
    if sr.pend then
        if t - sr.sent_t < OU.SEARCH_WAIT then return end
        sr.pend = false                                   -- no answer: that one is out
    end
    if t - sr.last < OU.SEARCH_GAP then return end
    if sr.stage == "scan" and sr.i < #sr.list then
        sr.i = sr.i + 1
        local c = sr.list[sr.i]
        sr.pend, sr.sent_t, sr.last = true, t, t
        sr.request = (sr.request or 0) + 1
        local request = sr.request
        local sent = N.path_probe({ x = sr.hx, y = sr.hy, z = c.z }, c, function(points, ok)
            if OU.search ~= sr or not sr.pend or sr.request ~= request then return end
            sr.pend = false
            local sc, why = nil, "no path"
            if ok ~= false then sc, why = score_path(points, ep, sr.hx, sr.hy, c.deg) end
            if sc then
                local e = points[#points]
                sr.res[#sr.res + 1] = { score = sc, x = e.x, y = e.y, z = e.z or c.z, deg = c.deg, why = why,
                    leg = points[2], path = points }      -- 1.67.0: keep the scored path
            end
            R.trail("move", "  %+d deg %.0f yd: %s%s", c.deg, sr.yd, sc and string.format("score %.1f - ", sc) or "out - ",
                tostring(why))
        end)
        if not sent then sr.pend = false end
        return
    end
    -- every direction asked: the best one with a clean path on to the goal
    table.sort(sr.res, function(a, b) return a.score < b.score end)
    sr.stage = "check"
    local best = table.remove(sr.res, 1)
    if not best then
        OU.search = nil
        return search_start(t, ep, sr.hx, sr.hy, sr.gx, sr.gy)
    end
    -- 1.32.0 (Desktop\Helper trace.lua): its first leg against the real geometry - a
    -- doodad / building edge the navmesh misses is what got the walk stuck
    if best.leg and TR.ready() then
        local hx, hy, hz = R.here()
        if hx and TR.leg_blocked({ x = hx, y = hy, z = hz }, best.leg) == true then
            R.trail("move", "  best %+d deg: its first leg is blocked (rays) - the next best", best.deg)
            sr.last = t
            return
        end
    end
    sr.pend, sr.sent_t, sr.last = true, t, t
    sr.request = (sr.request or 0) + 1
    local request = sr.request
    local gz = select(3, N.destination()) or best.z
    local sent = N.path_probe(best, { x = sr.gx, y = sr.gy, z = gz }, function(points, ok)
        if OU.search ~= sr or not sr.pend or sr.request ~= request then return end
        sr.pend = false
        local sc, why = nil, "no path on to the goal"
        if ok ~= false and type(points) == "table" and #points >= 2 then
            sc, why = score_path(points, ep, best.x, best.y, 0)
            if not sc and why and why:find("yd for", 1, true) then sc, why = 0, "long way on" end   -- the way on may be long
        end
        if not sc then
            R.trail("move", "  best %+d deg: %s - the next best", best.deg, tostring(why))
            return
        end
        if N.pending() or N.leg_fresh() then
            sr.res[#sr.res + 1] = best -- wait for Sentinel's in-flight work
            return
        end
        OU.search = nil
        R.trail("move", "stuck search: %+d deg %.0f yd chosen (%s)", best.deg, sr.yd, best.why)
        local started = false
        if type(best.path) == "table" and #best.path >= 2 and type(N.detour_path) == "function" then
            started = N.detour_path(best.path, string.format("stuck search %+d deg", best.deg))
        end
        if not started and not N.detour(best, string.format("stuck search %+d deg", best.deg)) then
            R.trail("move", "stuck search: the detour could not start - next window")
        end
    end)
    if not sent then sr.pend = false end
end
OU._search_tick = search_tick

local function outdoor_unstick(t)
    if OU.probing and t - (OU.probe_t or t) > OU.PROBE_MAX_S then probe_stop() end
    local function reset()
        OU.best, OU.dest, OU.idle_since, OU.ax, OU.ay, OU.ep = nil, nil, nil, nil, nil, nil
        OU.search = nil                                    -- 1.29.0
        ou_mem("episode", nil)                             -- 1.9.2
    end
    if R.resting or R.backpedal_until or Lk.holding() or (R.npc_until or 0) > t or N.mode() == "portal"
        or EL.active()                                   -- 1.22.0: waiting for / riding the lift is no stall
        or BT.active()                                   -- 1.2.32: nor waiting for / riding the ship
        or AS.active() then                              -- 1.30.0: the local A* search / walk
        return reset()
    end
    -- a walk restarting (a repath, a detour handing back) is idle for a moment
    if not N.busy() then
        OU.idle_since = OU.idle_since or t
        if t - OU.idle_since > OU.IDLE_OK then reset() end
        return
    end
    OU.idle_since = nil
    local me = R.me()
    if not me then return reset() end
    local okc, casting = pcall(function() return me:is_casting_spell() == true or me:is_channelling_spell() == true end)
    if okc and casting == true then OU.best_t = t return end      -- a cast holds the walk on purpose
    local oks, swim = pcall(function() return core.character.is_swimming() == true end)
    if oks and swim == true then return reset() end
    local x, y, hz = R.here()
    local dx, dy = N.destination()
    if not x or not dx then return reset() end
    crumb(x, y, hz)                                        -- 1.29.0: the trail
    if OU.search then                                      -- 1.29.0: a search runs - its queries go on
        if R.dist2(x,y,OU.search.hx,OU.search.hy) >= OU.MOVE_YD then
            OU.search, OU.best = nil, nil -- old-origin answers no longer apply
            return
        end
        search_tick(t)
        OU.best_t = t
        return
    end
    local dkey = string.format("%d|%d", math.floor(dx / 8), math.floor(dy / 8))
    if OU.dest ~= dkey then                                -- a new destination: a new count
        if N.detour_active() then
            OU.dest = dkey                                 -- (the detour keeps the goal; not new)
        else
            OU.dest, OU.best, OU.best_t, OU.ax, OU.ay, OU.ep = dkey, nil, t, nil, nil, nil
            ou_mem("episode", nil)                         -- 1.9.2
        end
    end
    -- a detour leg walks somewhere on purpose; a fan query may be out; and
    -- Sentinel's own recovery / re-plan / path request is running: not a
    -- stuck window of ours
    if N.detour_active() or OU.probing then OU.best_t = t return end
    local d = R.dist2(x, y, dx, dy)
    if d <= OU.ARRIVED_YD then OU.best, OU.best_t = d, t return end
    local moved = OU.ax and R.dist2(OU.ax, OU.ay, x, y) >= OU.MOVE_YD
    local ep = OU.ep
    if ep and (d < ep.best - OU.EP_GAIN or (R.dist2(ep.x, ep.y, x, y) > OU.EP_RADIUS and d < ep.best)) then
        R.trail("move", "stuck re-navigation: past the stuck spot after %d step(s) (%.0f yd to go)", ep.step, d)
        OU.ep, ep = nil, nil
        ou_mem("episode", nil)                             -- 1.9.2
        OU.tries = 0
    end
    if not OU.best or d < OU.best - OU.PROGRESS_YD or moved then
        OU.best, OU.best_t, OU.ax, OU.ay = d, t, x, y
        return
    end
    -- Recovery/repath is not progress. Preserve the timer across Sentinel
    -- retries, but never replace a path request while it is in flight.
    if N.leg_fresh() then OU.best_t = t return end
    if N.pending() then return end
    if N.recovering() and t - OU.best_t < OU.STILL_S * 3 then return end
    if t - OU.best_t < OU.STILL_S then return end
    if not ep then
        local oki, ind = pcall(function() return me:is_indoors() == true end)
        local _, _, hz = R.here()
        ep = { x = x, y = y, z = hz, d0 = d, best = d, step = 0, t0 = t, indoors = oki and ind == true }
        OU.ep = ep
        ou_mem("episode", t)
    end
    if d < ep.best then ep.best = d end
    ep.step = ep.step + 1
    OU.tries = OU.tries + 1
    local ladder = ep.indoors and OU.LADDER_INDOOR or OU.LADDER
    local rung = ladder[math.min(ep.step, #ladder)]     -- 1.7.24: the fan rung repeats
    OU.best_t = t                                          -- the next window counts from now
    if rung[1] == "backoff" then
        return backoff_step(ep, x, y, d, dx, dy)           -- 1.29.0
    end
    return search_start(t, ep, x, y, dx, dy)               -- 1.29.0
end

-- 1.32.0: the ray walk assistant's context, one table reused every pulse
local TR_CTX = { avoid = N.avoid_area, jump = function() do local fr = package.loaded["flightrec"] if fr then fr.note("jump") end end pcall(core.input.jump) end }
-- 2026-10-28 (user: "Always dismount when attempting to enter doorways"): the ray
-- helpers call this when the gap ahead admits the player but not the mounted body.
-- Mt.suppress inside Mt.dismount keeps us off the mount long enough to walk through.
TR_CTX.dismount = function() Mt.dismount(R.me(), "an entrance too low for the mount") end


--- Once per frame (main.lua), before anything reads movement state.
function movement.pulse()
    local t = R.now()
    Lk.tick(t)
    N.pulse()
    EL.tick()                     -- 1.22.0 / 1.66.0: Telredor / Aldor Rise lift run
    BT.tick()                     -- 1.2.32: Stormwind <-> Auberdine boat run
    FR.tick()                     -- 1.2.34: Simple Movement process() while a turn / kite runs
    -- 1.2.42: the last moment anything moved the player (a Sentinel walk, a Simple Movement turn / kite, a
    -- back-pedal, the client's own is_moving): a cast-time spell waits a beat after it (spellcheck.core_castable)
    do
        local me0 = R.me()
        if N.busy() or FR.active() or R.backpedal_until ~= nil
            or (me0 ~= nil and select(2, pcall(me0.is_moving, me0)) == true) then
            R.last_move_t = t
        end
    end
    SW.tick(t, N)                 -- 1.74.0: no-op (travel is Sentinel move_to)
    Mt.dismount_tick(R.me(), t)   -- 1.29.1: enemy targets within 40 yd -> off the mount
    Mt.foot_tick(R.me(), t)       -- 1.2.63: 15 yd on foot without combat -> the mount
    AS.tick(t)                    -- 1.30.0: local A* - one ray-budgeted slice a frame
    -- 1.32.0: Sentinel walking with no progress and the way ahead blocked: a low
    -- obstacle is jumped, a wall gets an avoidance zone (Sentinel re-plans round it)
    do
        local mode = N.mode()
        local me = R.me()
        local c = TR_CTX
        c.walking = N.busy() and mode ~= "swim" and mode ~= "portal" and mode ~= "elevator" and mode ~= "boat"
        if c.walking then
            c.no_jump, c.riding = SW.no_jump(), EL.riding()
            c.mounted_flying = me ~= nil and select(2, pcall(me.is_flying, me)) == true
        end
        TR.tick(t, c)
    end
    outdoor_unstick(t)            -- 1.10.0: the no-progress watchdog (no keys)
    Pv.tick(t)                 -- 3.2.0 (1.10.0: no new holds - Sentinel steers)
    Z.prune(t)
    if t - snap_t >= SNAP_EVERY then build_snapshot(t) end
end

function movement.on_render() end

function movement.set_debug(on) R.debug_on = on == true end

function movement.owner()
    if C.in_combat_movement() then return "combat" end
    if N.busy() then return "nav" end
    return "none"
end

function movement.state()
    return N.full_state() or (N.busy() and "navigating" or "idle")     -- 1.10.0: Sentinel, through movement/nav
end

-- The GUI movement panel is drawn on the RENDER path, where no game call
-- may run (Sentinel docs: a game call inside the menu render crashed WoW
-- Forever). The snapshot is built on the update tick (movement.pulse, every
-- SNAP_EVERY s) and the panel only reads this cached table.
build_snapshot = function(t)
    local u = C.combat_unit()
    local d = nil
    if u then
        local me = R.me()
        if me then
            local ok, v = pcall(me.distance_to, me, u)
            if ok and type(v) == "number" then d = v end
        end
    end
    snap = {
        state = movement.state(),
        owner = movement.owner(),
        restriction = R.resting and "resting" or (R.backpedal_until and "backpedal" or nil),
        retreating = false,
        paused = R.resting == true,
        sentinel = N.busy(),
        -- 1.7.2 (R2.4): the server state, read here on the update tick
        nav = N.client() == nil and "missing" or (N.nav_ready() and "ready" or "down"),
        nav_why = N.unavailable(),                        -- 1.10.0: why Sentinel cannot navigate (GUI)
        nav_status = N.status_text(N.status()),           -- 1.16.0: live progress / zones / failures (GUI)
        quiet = t < (R.quiet_until or 0),
        target_dist = d,
    }
    snap_t = t
end

--- For the GUI movement panel: the cached snapshot (no game call).
function movement.debug_snapshot()
    return snap
end

-- ============================================================================
-- STRICT SURFACE
-- ============================================================================
local missing_reported = {}
setmetatable(movement, {
    __index = function(_, key)
        if type(key) == "string" and not missing_reported[key] then
            missing_reported[key] = true
            pcall(require("actlog").console_error, R.TAG .. " movement." .. key .. " does not exist (stale call site)")
        end
        return nil
    end,
})

return movement
