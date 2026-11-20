-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/nav.lua - travel through Sentinel Navigation
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- 1.10.0 SENTINEL PORT (docs/SENTINEL_PORT_GUIDE.md; the reference is
-- restedXP_questing 4.7.0 movement/nav.lua). Sentinel Navigation / Sentinel are
-- gone from this layer: no the Sentinel client, no the Sentinel UI (input driver,
-- stuck window), no query.find_path(s), no exact 5 yd / 15 yd window walk
-- (movement/guide_path is retired), no straight-line fallback walker. Every
-- Sentinel call goes through movement/sentinel.lua (S.*). Sentinel walks its
-- own path: this layer hands it destinations and reads how they end.
--
-- WALK = move_to(target, cb(success, reason)). A new destination while a walk
-- runs is another move_to - Sentinel re-plans without stopping (0.12 s,
-- recorded) - at most every RETARGET_GAP s (combat COMBAT_GAP s): one path
-- request a second, never per frame. The same destination (within SAME_DEST
-- yd) while walking is a no-op, so callers can ask every tick.
--
-- WALKS ARE OURS TO TRACK: a walk replaced by a newer move_to, or stopped,
-- gets NO callback (recorded). Each walk carries a token (cur.id); a newer
-- walk or a stop retires it and its callback, should one ever come, is
-- ignored. A walk the Sentinel UI ended (no callback) is closed by the pulse
-- from get_state().
--
-- HEIGHTS: an off-mesh target costs ~6 s of library retries before Sentinel
-- snaps it (recorded), so an out-of-combat walk of FLOOR_FIRST yd or more asks
-- the navmesh floors there first (get_all_heights, one request per spot,
-- nearest the guess) and walks at that height. A walk that still ends
-- "unreachable" tries the next floor (retry_at_ground). The height found is
-- kept (N.reach_z).
--
-- HOLDS: Sentinel has no pause / resume. A hold (a cast, loot, a mana gem)
-- stops the walk and remembers where it went; when the last hold lifts the
-- same destination is walked again.
--
-- STOPS: never on a walk still waiting for its path or younger than
-- FRESH_LEG s (the 2.181.0 / 3.7.1 crash pattern). Such a stop is deferred to
-- the pulse (after the path is ready); a new walk meanwhile replaces it.
--
-- FAILURES: the reason of the last failed walk is kept (last_fail_reason /
-- last_fail_offmesh). "unreachable" twice at one spot in FAIL_WINDOW s
-- blacklists it (movement/zones); "server_timeout" backs off SERVER_BACKOFF s.
-- A walk that ENDED max_stuck_exceeded / unreachable confirms the player's spot
-- as a black point of movement/memory (bookkeeping kept from 1.9.x; it goes to
-- this session's zones too, so the spot is refused at once).
--
-- ZYGOR SURFACE (what movement.lua / quest/engine call), mapped on Sentinel:
--   waypoint_walk(dest, key)  1.20.0: a guide nav_to (key ignored, no per-key
--                             gate); the quest walker walks RestedXP's chain
--   step_into(pos)            the last yards into a portal: move_direct (doc)
--   path_ahead(yards)         Sentinel's get_current_path from get_path_index
--   replan_fresh / rejoin     the current destination issued again (a fresh
--                             Sentinel path from here, no stop)
--   detour(pt) / detour_active  walk pt, then the destination again
--   all_heights(pos, cb)      get_all_heights through the adapter
--   steep_at(points)          slope check of a path's own points (pure)
--   mem_black(rec, why)       a movement/memory black point -> session zones
--
-- NO SENTINEL (library missing, no maps for this game version): no movement
-- at all, and the reason is logged (once per reason).
-- ============================================================================

local R = require("movement/core")
local Z = require("movement/zones")
local MT = require("movement/mount")         -- 3.8.0: mount for travel (the 1-60 way)
local MEM = require("movement/memory")       -- 1.9.0: black points (bookkeeping)
local S = require("movement/sentinel")       -- 1.10.0: every Sentinel call
local EL = require("movement/elevator")      -- 1.22.0 / 1.66.0: Telredor and Aldor Rise lifts
local BT = require("movement/boat")          -- 1.2.32: Stormwind Harbor <-> Auberdine boat
local FR = require("movement/front")         -- 1.2.34: Simple Movement facing / keeping enemies in front
local AS = require("movement/astar")         -- 1.30.0: local A* fallback (opt-in, off by default)

local N = {}

local SAME_DEST = 2.0          -- yd: the same destination
local SAME_DEST_GUIDE = 6.0    -- 1.67.0: guide / npc walks retarget less (talk/accept jitter)
local RETARGET_GAP = 1.0       -- s between two travel retargets (one path request a second)
local COMBAT_GAP = 0.5         -- s between two combat retargets (a moving target)
local UNDERFOOT = 1.0          -- yd: a destination this close is reached
local QUIET_STOP = 0.3         -- s callers wait after a real stop (is_quiet)
-- 1.20.1: was 40 - the 1.20.0 patrol ring puts points 25 yd off a lone waypoint at the
-- CENTRE's height; on uneven ground those were off-mesh targets (Sentinel retries one
-- ~6 s, then snaps it and ends the walk "arrived" short of it)
local FLOOR_FIRST = 20         -- yd: farther travel walks ask the floors there first
N.FLOOR_LAYER = 8              -- 1.67.0: a mesh floor farther than this from the measured height is another layer
local HEIGHT_SAME = 2.0        -- yd: a height this close to a tried one is the same
-- 1.73.0 / 1.74.0: dest this far ABOVE the player is a flyer / cliff mesh
-- (Naphthal'ar at z 79 while the thicket is at 12) - walk the player's floor,
-- not up the mountain. Dest this far BELOW the player still asks the mesh
-- floors so the walk is on walkable terrain (Sentinel move_to), not a flyer /
-- lake-bed Z. Off-mesh dests snap to the nearest reachable point.
local CLIMB_ABOVE = 45
local DIVE_BELOW = 12
local DIVE_MAX = 45
local HEIGHT_SCAN_HOLD = 10.0  -- s: a floor query with no answer holds new walks there no longer
local FAIL_WINDOW, FAIL_BLACKLIST = 120, 2
local REACH_TTL, REACH_TTL_BAD, REACH_GAP = 120, 45, 0.25
local REACH_TRUST_FAR = 150    -- yd: farther answers are guesses, never "unreachable"
local FRESH_LEG = 1.0          -- s: a leg younger than this is never stopped (3.7.1)
local LOST_WALK = 2.0          -- s: an idle client this long after our walk began = it ended
local DETOUR_MAX_S = 15        -- 1.7.23: a detour leg ends after this at the latest
local DETOUR_MAX_YD = 40       -- audit N2: farther detour points are refused

-- Sentinel failure reasons (doc): unreachable, server_timeout,
-- max_stuck_exceeded, max_repath_exceeded
local OFFMESH = { unreachable = true }
local SERVER_CODES = { server_timeout = true, server_down = true, map_not_loaded = true }
local SERVER_BACKOFF = 3.5
local GIVE_UP_CODES = { max_stuck_exceeded = true, max_repath_exceeded = true }
local HEIGHT_RETRY = { unreachable = true }
-- 1.2.40: the server's HTTP 422 "Position not on navmesh" is a wrong-height destination, like "unreachable":
-- the floors at the spot are tried (log 2026-11-18: 7 walks in a row to z 311 under a z 406 hill, 20 s each)
local function mesh_code(code) return type(code) == "string" and code:find("navmesh", 1, true) ~= nil end

-- the walk this layer asked for
local cur = { id = 0, x = nil, y = nil, z = nil, mode = nil, t = 0, route = nil, done = false }
local fail = { reason = nil, offmesh = false, t = 0 }
local fails_at = {}            -- dest key -> { n, t }
local zfix = {}                -- dest key -> corrected z
local zscan = {}               -- dest key -> { tried = { z, ... }, t, list, asking }
local stats = { issued = 0, refused = 0, floors = 0, deferred_stops = 0 }
N.stats = stats
local stop_req = nil           -- { t, reason } a stop waiting for a safe moment
local held = { reasons = {}, dest = nil }
local det = nil                -- 1.7.23: { x, y, z, dest = { x, y, z, mode, route }, id, until_t }

-- fails_at / zfix / zscan are keyed per destination and would grow for a whole
-- session; past CACHE_MAX keys each is emptied (all are re-learnt).
local CACHE_MAX = 256
local cache_n = { fails = 0, zfix = 0, zscan = 0 }
local function cache_put(tbl, which, k, v)
    if tbl[k] == nil then
        cache_n[which] = cache_n[which] + 1
        if cache_n[which] > CACHE_MAX then
            for key in pairs(tbl) do tbl[key] = nil end
            cache_n[which] = 1
        end
    end
    tbl[k] = v
end

-- ----------------------------------------------------------------------------
-- the client
-- ----------------------------------------------------------------------------
local request_warned = nil
local warned = nil             -- the last "no navigation" reason logged

--- Sentinel's shared client, or nil: the library is missing, or this game
--- version has no maps on the server (the launcher says so in MASTER_FARMER.nav).
function N.client()
    local info = S.info()
    local why = nil
    if info.kind ~= "sentinel" then
        why = "not loaded through Master Farmer's Sentinel entry - the bot will not move"
    elseif not info.supported then
        why = "Sentinel navigation has no maps for this game version - the bot will not move"
    end
    local c = nil
    if not why then
        c = S.client()
        if not c then why = "the Sentinel Navigation library is not loaded - enable it and reload" end
    end
    if why then
        if warned ~= why then
            warned = why
            R.log(why)
        end
        return nil
    end
    warned = nil
    return c
end

--- Why the bot cannot navigate now (for the GUI), or nil.
function N.unavailable() return S.unavailable() end

-- Legacy input-driver compatibility: Sentinel has no driver setting and
-- its UI owns the tuning - kept as no-ops so gui Start / Stop, mapwalk and
-- unload stay as they are.
function N.want_input_driver(_) end
function N.driver_claimed() return false end
function N.release_driver_now() end

local function key_of(x, y)
    return string.format("%d|%d", math.floor(x / 4), math.floor(y / 4))
end

-- ----------------------------------------------------------------------------
-- gates: who may start a walk now
-- ----------------------------------------------------------------------------
--- Why travel is refused now, or nil. Combat owns the player while a fight
--- asks for it every tick (movement/combat sets R.combat_until); a rest or a
--- backpedal holds everything.
function N.transport_blocked()
    local c = S.client()
    return c and S.request_blocked(c) or nil
end

--- 1.2.51: Sentinel is still planning this walk's path (the server is slow, not
--- the walk stuck). The quest stall clock waits for it, within a cap.
function N.awaiting_path()
    local c = S.client()
    return c ~= nil and S.path_pending(c) or false
end

function N.refusal()
    -- 1.67.0: HTTP 414 is an oversized zone / check_path payload, not a
    -- travel refusal. move_to / replan still run; add_zone / find_path /
    -- check_path stay gated in the adapter.
    if EL.riding() then return "elevator" end            -- 1.22.0: on / stepping onto the lift
    if BT.riding() then return "boat" end                -- 1.2.32: boarding / riding / leaving the ship
    if FR.active() then return "front" end               -- 1.2.34: a Simple Movement turn / kite owns the keys
    if R.resting then return "resting" end
    if R.backpedal_until then return "backpedal" end
    if (R.combat_until or 0) > R.now() then return "combat" end
    -- 3.0.2: standing at an NPC (movement.interact) - its window / gossip /
    -- purchase gets NPC_HOLD s before any walk starts again
    if (R.npc_until or 0) > R.now() then
        -- the game answered "too far away": nothing opened, the caller walks
        -- up to the NPC - the hold is lifted for that walk
        local ev = package.loaded["events"]
        if R.npc_ev_t and type(ev) == "table" and type(ev.too_far_since) == "function"
            and ev.too_far_since(R.npc_ev_t) == true then
            R.npc_until, R.npc_ev_t = nil, nil
            return nil
        end
        return "npc"
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- state
-- ----------------------------------------------------------------------------
--- Sentinel is navigating (is_moving: true only while "navigating").
function N.busy()
    local c = N.client()
    return c ~= nil and S.moving(c)
end

--- The walk's own goal (a detour keeps the real goal here), or nil.
function N.destination()
    if cur.x and N.busy() then return cur.x, cur.y, cur.z end
    return nil
end

function N.mode() return N.busy() and cur.mode or nil end

--- Sentinel's dotted state, or nil.
function N.full_state()
    local c = N.client()
    return c and S.full_state(c) or nil
end

--- Sentinel's own stuck recovery runs (navigating.recovering.*).
function N.recovering()
    local c = N.client()
    return c ~= nil and S.recovering(c)
end

--- The path Sentinel follows (vec3[]) and the index being walked to, or nil.
function N.path_points()
    local c = N.client()
    return c and S.current_path(c) or nil
end
function N.path_index()
    local c = N.client()
    return c and S.path_index(c) or nil
end

-- 1.9.0: a black point (movement/memory) also goes to this session's zones at
-- its radius, so the walk refuses the spot at once; the file is the copy that
-- survives a reload
local function mem_black(rec, why)
    if rec and MEM.active(rec) then
        Z.blacklist_area({ x = rec.cx, y = rec.cy, z = rec.cz }, rec.radius, "stuck here (" .. tostring(why) .. ")")
    end
    return rec
end
N.mem_black = mem_black                  -- 1.9.2: movement.lua's stuck-episode confirm

--- `walked`: a walk ENDED with `code` (a move_to / follow_path callback), not a
--- planning answer - only then can the player's spot be a black point.
local function record_fail(code, x, y, z, walked)
    if walked then
        local px, py, pz = R.here()
        if px and MEM.BLACK_CODES[code] then
            mem_black(MEM.confirm_stuck(px, py, pz, code), code)   -- 1.9.2: once per cell per episode
        elseif px and code == "max_repath_exceeded" and (x or cur.x) then
            mem_black(MEM.note_replan(px, py, pz, x or cur.x, y or cur.y), code)
        end
    end
    fail.reason, fail.offmesh, fail.t = tostring(code or "failed"), OFFMESH[code] == true, R.now()
    if SERVER_CODES[code] then fail.server_until = R.now() + SERVER_BACKOFF end
    fail.give_up = GIVE_UP_CODES[code] == true
    if not x then return end
    local k = key_of(x, y)
    local e = fails_at[k]
    local t = R.now()
    if not e or (t - e.t) > FAIL_WINDOW then e = { n = 0, t = t } cache_put(fails_at, "fails", k, e) end
    e.n, e.t = e.n + 1, t
    if e.n >= FAIL_BLACKLIST and fail.offmesh then
        Z.blacklist_area({ x = x, y = y, z = z }, 6, "no path there (" .. fail.reason .. ")")
        fails_at[k] = nil
    end
end

-- ----------------------------------------------------------------------------
-- fresh legs (3.7.1, crash logs 2026-10-16 17:30 - 18:06)
-- ----------------------------------------------------------------------------
local FALSE_ARRIVAL = 5.0      -- yd: an "arrived" farther from the goal is not one
-- 1.20.1 RAPID WALKS (crash 2026-10-25 14:54, 1.20.0, ~2 s into a fresh walk after a walk
-- that ended "arrived" 5 yd short): 1.20.0 dropped the 1.5.0 one-walk-per-waypoint gate,
-- and nav_to paced retargets only WHILE Sentinel walks. A goal Sentinel snaps (off the
-- navmesh) ends "arrived" short at once; the quest walker, still short of it, asked
-- again the next tick - a loop of sub-second walks (the 2.181.0 / 3.7.1 crash pattern).
--   * START_GAP: a new walk never starts within START_GAP s of the last one (combat
--     COMBAT_START_GAP), Sentinel busy or not - at most one walk a second;
--   * SHORT: an "arrived" SHORT_OK yd or less short of the goal is where the navmesh
--     ends - N.reached_short(pos) says so for SHORT_HOLD s (quest/engine near() counts
--     it as there); farther short is a failure of the place ("arrived_short", off-mesh).
local START_GAP, COMBAT_START_GAP = 1.0, 0.5
local STORM = { key = nil, ts = {}, until_t = -1e9, N = 5, S = 12, GAP = 4.0, HOLD = 30 }   -- 1.2.58
N.STORM = STORM
local SHORT_OK, SHORT_HOLD = 15, 10
local short = { key = nil, t = -1e9 }
N.START_GAP, N.SHORT_OK = START_GAP, SHORT_OK

--- Seconds since the running leg started (huge when none runs).
function N.leg_age()
    if not cur.leg_t or not N.busy() then return 1e9 end
    return R.now() - cur.leg_t
end
function N.leg_fresh() return N.leg_age() < FRESH_LEG end

--- An "arrived" far from the goal is not counted (logged once per leg).
function N.false_arrival(x, y)
    local hx, hy = R.here()
    if not hx or not x then return false end
    local d = R.dist2(hx, hy, x, y)
    if d <= FALSE_ARRIVAL then return false end
    R.trail("nav", "walk ended as 'arrived' %.0f yd short of (%.0f, %.0f) - not counted", d, x, y)
    return true, d
end

-- ----------------------------------------------------------------------------
-- heights: the navmesh floors at a spot
-- ----------------------------------------------------------------------------
local function swimming()
    local ok, v = pcall(function() return core.character.is_swimming() end)
    return ok and v == true
end

--- The floors at (x, y), asked once per spot per FAIL_WINDOW s: cb(list).
--- True when the list is known or the query went out.
local function floors_for(c, k, x, y, z, cb)
    local st = zscan[k]
    if st and (R.now() - st.t) > FAIL_WINDOW then st = nil end
    if not st then
        st = { tried = {}, t = R.now(), list = nil, asking = false, waiting = {} }
        cache_put(zscan, "zscan", k, st)
    end
    if st.list then cb(st.list, st) return true end
    st.waiting[#st.waiting + 1] = cb
    if st.asking then return true end
    st.asking = true
    stats.floors = stats.floors + 1
    local sent = S.floors(c, { x = x, y = y, z = z }, function(list)
        st.asking, st.list = false, list
        local w = st.waiting
        st.waiting = {}
        for i = 1, #w do pcall(w[i], list, st) end
    end)
    if not sent then
        st.asking, st.list, st.waiting = false, {}, {}
        cb(st.list, st)
    end
    return true
end
N._floors_for = floors_for     -- tests

local function untried(st)
    for i = 1, #(st.list or {}) do
        local v, fresh = st.list[i], true
        for j = 1, #st.tried do
            if math.abs(v - st.tried[j]) <= HEIGHT_SAME then fresh = false break end
        end
        if fresh then return v end
    end
    return nil
end

-- 1.30.0 LOCAL A* FALLBACK (movement/astar, opt-in): a walk Sentinel ends
-- "arrived" short of its goal or "unreachable", with the goal within AS.MAX_YD of
-- the player, is handed to the local grid search; its path is walked leg by leg
-- (N.astar_leg, Sentinel move_direct). Its failure is the old outcome (as close
-- as the navmesh goes / the recorded failure).
local function astar_try(x, y, z, mode, code)
    if mode == "combat" or mode == "astar" or mode == "swim" or mode == "portal" then return false end
    -- 1.67.0: talk / accept / turn-in off-mesh still searches when the GUI
    -- box is off (AS.ON remains the kill switch).
    local force = (mode == "guide" or mode == "npc")
    return AS.start({ x = x, y = y, z = z }, function(ok, why)
        if ok then
            fail.reason, fail.offmesh = nil, false
            short.key = nil
            return
        end
        if code == "arrived_short" then
            short.key, short.t = key_of(x, y), R.now()          -- as close as the mesh goes, as before
        else
            record_fail(code, x, y, z, false)
        end
    end, force)
end

-- ----------------------------------------------------------------------------
-- issuing walks
-- ----------------------------------------------------------------------------
local issue_walk
local detour_done

--- "unreachable" at (x, y, z): walk again at the next floor found there.
--- True when a retry is under way (it reports the failure itself).
local function retry_at_ground(c, id, x, y, z, code, mode)
    if swimming() then return false end          -- R9.2 (the floor query answers the bed)
    local k = key_of(x, y)
    cur.scanning, cur.scan_t = id, R.now()
    floors_for(c, k, x, y, z, function(list, st)
        if cur.scanning == id then cur.scanning = nil end
        st.tried[#st.tried + 1] = z
        if cur.id ~= id then return end           -- superseded meanwhile (the list is kept)
        local hz = untried(st)
        if hz then
            cache_put(zfix, "zfix", k, hz)
            R.trail("nav", "(%.0f, %.0f): %s at z %.1f - walking again at a floor there, z %.1f (%d found)",
                x, y, tostring(code), z, hz, #list)
            issue_walk(c, x, y, hz, mode, true)
        else
            zfix[k] = nil                         -- no floor worked: no height is kept for the route
            if not st.spent then
                st.spent = true
                R.trail("nav", "(%.0f, %.0f): no floor with a path found (%d found) - %s", x, y, #list, tostring(code))
            end
            if astar_try(x, y, z, mode, code) then return end                  -- 1.30.0
            record_fail(code, x, y, z, mode ~= "combat")
        end
    end)
    return true
end

-- PRECOMPUTED PATHS (ported from Forever Questing 1.29.0). A move_to makes Sentinel go
-- awaiting_path and ask its server AFTER the walk is issued; here the path is planned
-- FIRST with the declared plan_route (planning only - nothing walks, the player keeps
-- running the old walk meanwhile, so a retarget never stops) and only then handed to
-- Sentinel as follow_path(waypoints), a path it already has.
--   * anything the plan cannot answer (no path, an error, WAIT_S with no reply, no
--     plan_route in the library, a plan that ends END_YD short of the goal) is a plain
--     move_to, exactly as before - Sentinel plans that walk itself;
--   * walks of MIN_YD or more in the "move" and "guide" modes only; short hops, combat,
--     NPC, corpse, portal, swim, A*, elevator and recorded-route walks are not touched;
--   * steep ground on the plan becomes an avoidance zone (N.zone_span) and the path is planned
--     again, up to PRE.TRIES times; the zone call is the adapter's guarded add_zone.
N.PRECOMPUTE = true
local SEG = { key = nil, last = nil, n = 0 }     -- audited-prefix segments walked toward one goal
local SIDE_BATCH = 3                              -- 1.2.84: both sides of this many nearest offsets are asked together
local SIDE_OFFSETS = { 15, 30, 55, 90, 140 }      -- 1.2.39: yd beside a steep span, nearest ring first
local PRE = { MIN_PREFIX = 12, MAX_SEGMENTS = 80, MIN_YD = 15, WAIT_S = 2.0, END_YD = 6, TRIES = 2, REGEN_GAP = 1.5, MODES = { move = true, guide = true } }
N.PRE = PRE

-- 1.2.19 THE SAME STEEP SPAN, AGAIN AND AGAIN. A route whose plan crosses ground this layer judges impassable was planned,
-- walked up to the span, planned again (the same span), for ever: the log shows 8 audited-prefix segments toward one inn and
-- Sentinel hand-offs that ended "navigating.recovering". The third time the same span (within SB_SPAN yd) blocks the same
-- goal inside SB_TTL s, the goal is given up for a while (the area blacklist every caller already honours) instead of tried
-- again. A ghost on a corpse run is never given up on: it must get to the body.
local SB = { key = nil, x = nil, y = nil, n = 0, t = -1e9 }
local SB_SPAN, SB_MAX, SB_TTL = 25, 2, 600
local function steep_block(x, y, z, sx, sy, force)
    if type(N.ghost_now) == "function" and N.ghost_now() then return false end
    local now = R.now()
    local k = key_of(x, y)
    if SB.key ~= k or now - SB.t > SB_TTL or not SB.x or R.dist2(SB.x, SB.y, sx, sy) > SB_SPAN then
        SB.key, SB.x, SB.y, SB.n = k, sx, sy, 0
    end
    SB.n, SB.t = SB.n + 1, now
    if force then SB.n = SB_MAX end
    if SB.n < SB_MAX then return false end
    SB.key, SB.n = nil, 0
    Z.blacklist_area({ x = x, y = y, z = z }, 8, "the route crosses steep ground (blocked " .. SB_MAX .. " times)")
    stats.steep_giveups = (stats.steep_giveups or 0) + 1
    R.trail("nav", "the route to (%.0f, %.0f) crosses ground too steep to walk - giving this destination up for a while", x, y)
    return true
end
N._steep_block = steep_block

--- The planned points from the one nearest the player on (the point the player already
--- stands on is dropped), as plain {x, y, z}.
local function pre_trim(points)
    local hx, hy = R.here()
    local first = 1
    if hx then
        local best, bd = 1, math.huge
        for i = 1, #points do
            local d = R.dist2(hx, hy, points[i].x, points[i].y)
            if d < bd then best, bd = i, d end
        end
        first = (bd < 2 and best < #points) and best + 1 or best
    end
    local out = {}
    for i = first, #points do
        local p = points[i]
        if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then
            out[#out + 1] = { x = p.x, y = p.y, z = p.z or 0 }
        end
    end
    return out
end

-- 1.2.75 LONG ROUTES AND SPLICED RE-PLANS (user: "paths should be able to be generated for long distances, 500+ yards at a time,
-- while regenerating while the player is running without stopping, by looking ahead").
--
--   ANCHORED PLANS. Sentinel's server answers a SHORT query fast and may never answer a very long one (a 1213 yd and a 5389 yd
--   query got no reply in the logs). plan_route takes a LIST of nodes and plans leg by leg, so a goal more than LONG.MIN_YD
--   away is planned as start -> anchor -> anchor -> goal: anchors every LONG.SEG_YD yd along the line, each snapped to a
--   real mesh floor (floors_for, the floor nearest the interpolated height). One request, one reply, 500+ yd of path.
--   An anchor without a floor is dropped; an anchored plan that fails is asked again plainly (st.no_anchor), then the old ladder.
--   PARTIAL PLANS. A plan that ends short of the goal but gets LONG.PARTIAL_GAIN yd closer is walked as far as it goes and the
--   rolling horizon (LA, 150 yd for a partial path) plans the next stretch while the player is still running.
--   SPLICED RE-PLANS. The horizon's re-plan starts at a SPLICE POINT on the running path, speed x (latency + 1 s) yd ahead of the
--   player (25 - 70 yd), not at the player: when the reply comes the running path up to the splice point is kept and the new
--   plan continues from it, so the player never backtracks or stops. A failed splice leaves the running path alone.
-- 1.2.77 PLAN LATENCY, HEDGED PLANS, NEXT-LEG PREFETCH (user: "watch the logs for the time Sentinel takes to create paths; find a
-- quicker method of generating and regenerating paths to the Zygor waypoints").
--   LOGS (222 sessions, 983 plan requests, 2026-11-09..19): when the server answers it answers FAST - median 0.05 s, p90 0.10 s,
--   independent of the path's length (0-400 points: 0.04-0.05 s). 55 requests (about 7 %) got NO reply in 3 s, and what followed
--   was slow: 35 ended in a walk-loop blacklist after 12-105 s, 9 got a plan after 22-97 s, only 5 recovered at once. The cost
--   is the tail, not the typical plan.
--   HEDGED PLANS: a plan with no reply after HEDGE_AT[1] s (10x the median) is not waited for - a second request goes out at once,
--   a third at HEDGE_AT[2]: a far goal (300+ yd) gets a short first leg (a partial plan the horizon continues), a near goal
--   another mesh floor of the goal. The first valid reply wins, later replies are ignored, a failed reply waits for the others.
--   PREFETCH: while a leg runs, the path to the guide's NEXT waypoint (N.hint_next) is planned from this leg's end and kept; when
--   the guide asks for that waypoint the path is already there (no wait at all at a waypoint change).
local PS = { n = 0, lat = {}, hedged = 0, hedge_wins = 0, prefetch_asked = 0, prefetch_used = 0, no_reply = 0, t0 = nil }
N._PS = PS
local HEDGE_AT = { 0.3, 0.8 }        -- 1.2.79: was { 0.5, 1.3 }
local PF = { NEAR = 140, MAX_AGE = 120, plan = nil, asking = false, key = nil }
N._PF = PF

local function ps_report(now)
    PS.t0 = PS.t0 or now
    if now - PS.t0 < 120 then return end
    local n = #PS.lat
    if n > 0 or PS.hedged > 0 then
        local a = {}
        for i = 1, n do a[i] = PS.lat[i] end
        table.sort(a)
        R.trail("nav", "plan stats (%.0f s): %d plan(s), median %.2f s, p90 %.2f s, max %.2f s; hedged %d (won %d), prefetch %d asked / %d used",
            now - PS.t0, n, n > 0 and a[math.ceil(n * 0.5)] or 0, n > 0 and a[math.max(1, math.ceil(n * 0.9))] or 0, n > 0 and a[n] or 0,
            PS.hedged, PS.hedge_wins, PS.prefetch_asked, PS.prefetch_used)
    end
    PS.lat, PS.hedged, PS.hedge_wins, PS.prefetch_asked, PS.prefetch_used, PS.t0 = {}, 0, 0, 0, 0, now
end
N._ps_report = ps_report

-- 1.2.79 LEG-LIMITED PLANNING (user: "build it" after the 17:05 log): plans of up to ~200 yd answer in 0.01-0.06 s, but 500-840 yd
-- queries (one anchor, or none) got NO reply 14 times in one trip, and every spliced re-plan asked for the whole remaining goal, so
-- the re-plans failed the same way. Replies are instant or never, so the server is now never asked for more than LEG.YD yd: a goal
-- farther than LEG.DIRECT is planned as start -> (bypass points) -> a floor-snapped LEG POINT LEG.YD yd along the way; the plan is
-- walked as a partial path and the horizon plans the next leg from a splice point 150 yd before this one ends. A leg that gets
-- no reply or no path is asked again at once with a shorter leg (LEG.HEDGE yd), and a far goal that cannot be planned at all is
-- walked as a short leg (N.detour) instead of being handed to Sentinel's own long plan (10-66 s of awaiting_path in the logs).
local UG = { seen = {}, under = {}, n = 0 }          -- 1.2.80: goals asked about / flagged underground
function N.is_underground(x, y) return UG.under[key_of(x, y)] == true end
local NR = { N = 3, TTL = 600, RADIUS = 20, by = {} }          -- 1.2.79c: unanswered plans per goal
-- 1.2.90 SATURATED SERVER (log 18:40-18:55: 86 of 120 leg plans got no reply; the server runs query_pool_size 3, so each bot plan that
-- fired two hedges on top of the first filled the pool and everything behind it waited). SAT counts plans in a row that got no reply
-- (any goal); while SAT.n >= SAT.MIN and the last one is younger than SAT.TTL s, no HEDGE request is sent - the plan is asked once,
-- and a reply of any plan clears the count.
local SAT = { n = 0, t = -1e9, MIN = 2, TTL = 45, skipped = 0 }
N._SAT = SAT
local function sat_active() return SAT.n >= SAT.MIN and R.now() - SAT.t < SAT.TTL end
N._NR = NR
local LEG = { YD = 300, DIRECT = 380, HEDGE = { 150, 80 }, WAIT_S = 2.0, NEAR_LEG_MIN = 180 }
N.LEG = LEG

local LONG = { MIN_YD = 450, SEG_YD = 320, LAST_YD = 150, MAX_ANCHORS = 6, FLOOR_DZ = 60, PARTIAL_GAIN = 120, PARTIAL_SHORT = 80, WAIT_S = 6.0,
    AHEAD_MIN = 25, AHEAD_MAX = 70, PARTIAL_H = 150 }
N.LONG = LONG

--- Anchor points along the line start -> goal: { x, y, z0 } every SEG_YD yd, none within LAST_YD of the goal.
function LONG.anchors(sx, sy, sz, gx, gy, gz)
    local dx, dy = gx - sx, gy - sy
    local len = math.sqrt(dx * dx + dy * dy)
    local out = {}
    if len <= LONG.MIN_YD then return out end
    local d = LONG.SEG_YD
    local ES = package.loaded["esp"]
    while d <= len - LONG.LAST_YD and #out < LONG.MAX_ANCHORS do
        local f = d / len
        local ax, ay = sx + dx * f, sy + dy * f
        -- 1.2.78: an anchor never sits inside a remembered camp / elite / much higher level mob's circle
        if type(ES) == "table" and type(ES.push_out) == "function" then
            local okp, px, py = pcall(ES.push_out, ax, ay)
            if okp and type(px) == "number" then ax, ay = px, py end
        end
        out[#out + 1] = { x = ax, y = ay, z0 = sz + ((gz or sz) - sz) * f }
        d = d + LONG.SEG_YD
    end
    return out
end

--- 1.2.78 ESP BYPASS POINTS (user: the ESP returns navigation data for the Sentinel plan generation): hazards on the way (camps of
--- 4+, elites, much higher levels - remembered as well as seen) become VIA nodes of the very first plan_route request, one point
--- beside each on the side away from it, so the plan is made around them instead of through them and audited afterwards.
--- { x, y, z0, why } nearest the start first; empty when the way is clear or the ESP knows nothing.
function LONG.hazard_vias(sx, sy, sz, gx, gy, gz)
    local ES = package.loaded["esp"]
    if type(ES) ~= "table" or type(ES.bypass) ~= "function" then return {} end
    local ok, list = pcall(ES.bypass, sx, sy, gx, gy)
    if not ok or type(list) ~= "table" then return {} end
    local len = R.dist2(sx, sy, gx, gy)
    local out = {}
    for _, v in ipairs(list) do
        local f = len > 0 and math.min(1, math.max(0, (v.along or 0) / len)) or 0
        out[#out + 1] = { x = v.x, y = v.y, z0 = sz + ((gz or sz) - sz) * f, why = v.why, along = v.along or 0 }
    end
    return out
end

--- The leg point `yd` along the line start -> goal (pushed out of a remembered hazard circle): { x, y, z0 }.
function LEG.point(sx, sy, sz, gx, gy, gz, yd)
    local dx, dy = gx - sx, gy - sy
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return nil end
    local f = math.min(1, yd / len)
    local lx, ly = sx + dx * f, sy + dy * f
    local ES = package.loaded["esp"]
    if type(ES) == "table" and type(ES.push_out) == "function" then
        local okp, px, py = pcall(ES.push_out, lx, ly)
        if okp and type(px) == "number" then lx, ly = px, py end
    end
    return { x = lx, y = ly, z0 = sz + ((gz or sz) - sz) * f }
end

--- Snap each anchor to a mesh floor (all asked at once); cb(list of { x, y, z }) - anchors without a floor are dropped.
function LONG.resolve(c, anchors, cb)
    local n, done, out = #anchors, 0, {}
    if n == 0 then return cb({}) end
    local function one_done()
        done = done + 1
        if done < n then return end
        local list = {}
        for i = 1, n do if out[i] then list[#list + 1] = out[i] end end
        cb(list)
    end
    for i = 1, n do
        local a = anchors[i]
        local asked = floors_for(c, key_of(a.x, a.y), a.x, a.y, a.z0, function(fl)
            local best, bd = nil, nil
            for _, h in ipairs(fl or {}) do
                local dz = math.abs(h - a.z0)
                if dz <= LONG.FLOOR_DZ and (not bd or dz < bd) then best, bd = h, dz end
            end
            -- 1.2.79: an EMPTY answer is "floors unknown" (the query failed): the interpolated height is used and a shorter leg follows
            -- when the plan has no path; floors that exist but none near the height drop the point
            if not best and (not fl or #fl == 0) then best = a.z0 end
            if best then out[i] = { x = a.x, y = a.y, z = best } end
            one_done()
        end)
        if not asked then one_done() end
    end
end

--- A point on the RUNNING path `ahead` yd beyond the player (the splice point): { x, y, z } or nil.
function N.splice_point(c)
    local pts, idx = S.current_path(c), S.path_index(c)
    if type(pts) ~= "table" or #pts < 2 or not idx then return nil end
    idx = math.max(1, math.min(#pts, math.floor(idx)))
    local hx, hy = R.here()
    if not hx then return nil end
    local ahead = math.max(LONG.AHEAD_MIN, math.min(LONG.AHEAD_MAX, (N.LA and N.LA.speed or 7) * ((N.LA and N.LA.latency or 0.3) + 1.0)))
    local acc = R.dist2(hx, hy, pts[idx].x, pts[idx].y)
    local k = idx
    while acc < ahead and k < #pts do
        acc = acc + R.dist2(pts[k].x, pts[k].y, pts[k + 1].x, pts[k + 1].y)
        k = k + 1
    end
    -- 1.2.78: a splice point never sits inside a remembered hazard: the next path point out of every circle is taken
    local ES = package.loaded["esp"]
    if type(ES) == "table" and type(ES.inside) == "function" then
        local tries = 0
        while k < #pts and tries < 40 do
            local okh, hz = pcall(ES.inside, pts[k].x, pts[k].y, 0)
            if not okh or not hz then break end
            k, tries = k + 1, tries + 1
        end
    end
    local p = pts[k]
    if type(p) ~= "table" or not tonumber(p.x) then return nil end
    return { x = p.x, y = p.y, z = p.z or 0 }
end

--- The running path from the player's index up to the point nearest `sp` (within 4 yd), as {x,y,z}; nil when the splice point
--- is no longer ahead on that path.
local function running_to(c, sp)
    local pts, idx = S.current_path(c), S.path_index(c)
    if type(pts) ~= "table" or not idx then return nil end
    idx = math.max(1, math.min(#pts, math.floor(idx)))
    local found
    for k = idx, #pts do
        if R.dist2(pts[k].x, pts[k].y, sp.x, sp.y) <= 4 then found = k break end
    end
    if not found then return nil end
    local out = {}
    for k = idx, found do out[#out + 1] = { x = pts[k].x, y = pts[k].y, z = pts[k].z or 0 } end
    return out
end

--- Start walk `id` to (x, y, z) as plan -> audit -> follow_path. True when the plan request
--- went out (its reply starts the walk, or falls back to move_to); false when this walk is not
--- eligible and the caller issues the move_to.
--- 1.2.77: once per session the Sentinel settings that every plan_route now carries are written to the log, so the log says which
--- in-game settings (string pulling, partial paths, off-mesh snapping, wall clearance ...) the plans were made with.
local function log_sentinel_options(c)
    if N._opts_logged then return end
    N._opts_logged = true
    local opts = S.path_opts(c)
    if type(opts) ~= "table" then
        R.trail("nav", "Sentinel path options: none (the client has no get_path_opts) - plans use the server defaults")
        return
    end
    local keys = {}
    for k, v in pairs(opts) do
        local t = type(v)
        if type(k) == "string" and (t == "number" or t == "boolean" or t == "string") then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for i = 1, math.min(#keys, 40) do parts[#parts + 1] = keys[i] .. "=" .. tostring(opts[keys[i]]) end
    R.trail("nav", "Sentinel path options (the in-game settings, passed with every plan_route): %s",
        #parts > 0 and table.concat(parts, ", ") or "(no scalar fields)")
end

-- 1.2.88 COMBAT PAUSE (user: "pause pathing if the player enters combat, use the same route that was calculated after combat has
-- ended"): when a fight displaces or stops a travel walk, the not-yet-walked part of its path is kept here; the next travel walk to
-- the same destination (after the fight, within TTL s, player within NEAR yd of the path) walks the SAME path again instead of
-- asking Sentinel for a new plan. Functions are defined below start_blocked.
local CP = { TTL = 240, NEAR = 90, snap = nil }
-- 1.2.88 FLATTEST TERRAIN (user: "choosing the flattest terrain regardless if it adds more distance"): a plan whose path climbs / drops
-- more than TRIGGER yd per yd walked (total |dz| steps over the length) is walked at once, and the via routes round it are asked;
-- the FLATTEST one (least total |dz|, not the shortest) that is at most GAIN of the plan's roughness replaces it.
local FLAT = { TRIGGER = 0.10, MIN_YD = 40, MAX_YD = 450, GAIN = 0.8, MOVED_YD = 30 }
local function roughness(list)
    local rg, ln, worst, wd = 0, 0, 1, 0
    for i = 2, #list do
        local a, b = list[i - 1], list[i]
        local dz = math.abs((tonumber(b.z) or 0) - (tonumber(a.z) or 0))
        if dz < 0.05 then dz = 0 end
        rg = rg + dz
        ln = ln + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        if dz > wd then wd, worst = dz, i - 1 end
    end
    return rg, ln, worst
end
local function pre_start(c, id, x, y, z, finished)
    if not N.PRECOMPUTE or not PRE.MODES[cur.mode or "move"] or swimming() then return false end
    log_sentinel_options(c)
    local hx, hy = R.here()
    if not hx or R.dist2(hx, hy, x, y) < PRE.MIN_YD then return false end
    local goal = { x = x, y = y, z = z }
    local st = { id = id, done = false, started = false, planning = false, tries = 0, t0 = R.now(), regen_t = -1e9 }
    -- 1.2.75: the horizon asked for the NEXT stretch of the walk that is running to this very goal - spliced, not from the player
    local req = N._splice_req
    N._splice_req = nil
    if req and R.now() - req.t < 1.0 and R.dist2(req.x, req.y, x, y) < 3 and S.moving(c) and not S.path_pending(c) then
        st.splice = N.splice_point(c)
    end
    local request
    local function fallback(why)
        if st.done or cur.id ~= id then return end
        st.done = true
        if st.splice then
            -- 1.2.75: a spliced re-plan that found nothing. A LONG goal (the server may never answer a plain query for it) keeps
            -- the running path - it is walked to its end and the horizon asks again; a nearer goal falls back to Sentinel's own plan
            local fx0, fy0 = R.here()
            if fx0 and R.dist2(fx0, fy0, x, y) > LONG.MIN_YD then
                stats.splice_fails = (stats.splice_fails or 0) + 1
                R.trail("nav", "spliced re-plan unavailable (%s) - the running path stays", tostring(why))
                return
            end
        end
        if cur.scanning == id then cur.scanning = nil end
        stats.pre_fallbacks = (stats.pre_fallbacks or 0) + 1
        if st.sent_any and not st.winner then SAT.n, SAT.t = SAT.n + 1, R.now() end
        if st.sent_any and not st.winner then pcall(S.log_unanswered, c, tostring(why), x, y, st.sent_t and st.sent_t[1]) end
        -- 1.2.79c NEGATIVE MEMORY (log 17:16-17:22: the same goal got no answer in 5 asks, 60 s of awaiting_path each time): a goal whose
        -- plan has gone unanswered NR.N times within NR.TTL s is not handed to Sentinel again - it is given up at once (the area
        -- blacklist every caller honours; the guide moves on)
        -- 1.2.89: counted BEFORE the short-leg fallback (log 18:40-18:45: the leg fallback returned first, so 8 walks and a
        -- 55 s walk loop passed before the goal was given up). Each unanswered ask now counts at once.
        if st.sent_any then
            local nk = key_of(x, y)
            local e = NR.by[nk]
            local tnow = R.now()
            if not e or tnow - e.t > NR.TTL then e = { n = 0, t = tnow } NR.by[nk] = e end
            e.n, e.t = e.n + 1, tnow
            if e.n >= NR.N then
                NR.by[nk] = nil
                stats.pre_nr_giveups = (stats.pre_nr_giveups or 0) + 1
                R.trail("nav", "no plan for (%.0f, %.0f) was ever answered (%d asks in %.0f min) - giving the goal up for a while instead of waiting for Sentinel",
                    x, y, NR.N, NR.TTL / 60)
                S.log_unanswered(c, "give-up", x, y, st.sent_t and st.sent_t[1])
                record_fail("no_path", x, y, z, false)
                Z.blacklist_area({ x = x, y = y, z = z }, NR.RADIUS, "no plan answered " .. NR.N .. " times")
                cur.done = true
                return
            end
        end
        -- 1.2.79: a FAR goal is never handed to Sentinel as one long plan (10-66 s of awaiting_path in the logs): a short leg is
        -- walked (N.detour: the leg, then the real goal again, planned from there)
        local fx0, fy0, fz0 = R.here()
        if fx0 and st.sent_any and R.dist2(fx0, fy0, x, y) > LEG.NEAR_LEG_MIN and not st.leg_fallback then
            st.leg_fallback = true
            local lp = LEG.point(fx0, fy0, fz0, x, y, z, LEG.HEDGE[1])
            if lp then
                R.trail("nav", "plan unavailable (%s) for a goal %.0f yd away - walking a short leg (%d yd) instead of a long Sentinel plan",
                    tostring(why), R.dist2(fx0, fy0, x, y), LEG.HEDGE[1])
                local asked = floors_for(c, key_of(lp.x, lp.y), lp.x, lp.y, lp.z0, function(fl)
                    if cur.id ~= id then return end
                    local best, bd = nil, nil
                    for _, h in ipairs(fl or {}) do
                        local dz = math.abs(h - lp.z0)
                        if dz <= LONG.FLOOR_DZ and (not bd or dz < bd) then best, bd = h, dz end
                    end
                    if best then
                        cur.done = false
                        if N.detour({ x = lp.x, y = lp.y, z = best }, "no plan for a far goal", { max_yd = LEG.YD + 80, max_s = 70, label = "short leg" }) then
                            return
                        end
                    end
                    local sent2 = S.move_to(c, goal, finished)
                    if not sent2 then cur.done = true end
                end)
                if asked then return end
            end
        end
        R.trail("nav", "precomputed path unavailable (%s) - Sentinel plans this walk itself", tostring(why))
        local sent = S.move_to(c, goal, finished)
        if not sent then cur.done = true end
    end
    st.fallback = fallback
    local launch
    st.launch_saved = function(list)
        if not S.follow_path(c, list, finished) then CP.snap = nil return false end
        st.started = true
        cur.leg_t = R.now()
        if st.partial then cur.pre_partial = id end
        stats.pre_walks = (stats.pre_walks or 0) + 1
        return true
    end
    function launch(list)
        if not S.follow_path(c, list, finished) then
            if st.started then return end
            return fallback("follow_path refused")
        end
        local first = not st.started
        st.started = true
        cur.leg_t = R.now()
        if st.partial then cur.pre_partial = id end
        if first then
            stats.pre_walks = (stats.pre_walks or 0) + 1
            R.trail("nav", "precomputed path: %d points planned in %.2f s, walked with follow_path", #list, R.now() - st.t0)
        else
            stats.pre_regens = (stats.pre_regens or 0) + 1
        end
    end
    -- 1.2.39 ROUTE AROUND STEEP GROUND, EITHER DIRECTION. The zone replans (PRE.TRIES) can leave a steep span on the plan
    -- (Darkshore: ~2 "too steep" give-ups per 4 min). Before the audited prefix / give-up, Sentinel is asked for routes THROUGH
    -- a via point beside the span, on BOTH sides (left = +1, right = -1; WoW x is north, y is west; perpendicular to the climb, SIDE_OFFSETS yd out, nearest ring first). Each
    -- answer is audited like any plan; at a ring the shorter clean route wins and is walked with follow_path. Nothing here
    -- walks: Sentinel plans (plan_route with a via node), this layer only picks. `after(false)` hands back to the old ladder.
    local function try_sides(audit, i, e, after)
        local a = audit[i]
        local b = audit[e or i + 1] or a
        local dx, dy = b.x - a.x, b.y - a.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 0.5 then
            dx, dy = x - audit[1].x, y - audit[1].y
            len = math.sqrt(dx * dx + dy * dy)
        end
        if len < 0.5 then return after(false) end
        local px, py = -dy / len, dx / len
        local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
        local ring = 0
        local function plan_len(list)
            local d, qx, qy = 0, audit[1].x, audit[1].y
            for k = 1, #list do d = d + R.dist2(qx, qy, list[k].x, list[k].y) qx, qy = list[k].x, list[k].y end
            return d
        end
        -- 1.2.87: a PARTIAL plan (a 300 yd leg of a long walk) is re-routed to the END OF THE LEG, never to the far goal: the via
        -- routes were asked as start -> via -> (goal 1680 yd away) - a long query, which Sentinel never answers (log 18:17: 7
        -- plan_route calls a second, no reply, a restart storm, then a 150 yd short leg)
        local tgt = (st.partial and audit[#audit]) or goal
        local next_ring
        local why_n = { noplan = 0, short = 0, steep = 0 }      -- 1.2.44: why the via routes were unusable (logged when none was)
        local function ask(sign, off, done)
            local via = { x = mx + px * sign * off, y = my + py * sign * off, z = a.z or audit[1].z or 0 }
            if not st.flat then st.planning, st.plan_t = true, R.now() end
            local sent = S.plan_route(c, { { x = audit[1].x, y = audit[1].y, z = audit[1].z }, via, { x = tgt.x, y = tgt.y, z = tgt.z } }, function(ok, data)
                if st.done or cur.id ~= id or cur.done or (st.started and not st.flat) then return end
                local pts = (ok == true and type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
                local last = pts and pts[#pts]
                if not pts or #pts < 2 then why_n.noplan = why_n.noplan + 1 return done(nil) end
                if type(last) ~= "table" or not tonumber(last.x) or not tonumber(last.y)
                    or R.dist2(last.x, last.y, tgt.x, tgt.y) > PRE.END_YD then
                    why_n.short = why_n.short + 1
                    return done(nil)
                end
                local list = pre_trim(pts)
                if #list == 0 then return done(nil) end
                local chk = { { x = audit[1].x, y = audit[1].y, z = audit[1].z } }
                for _, q in ipairs(list) do chk[#chk + 1] = q end
                if N.steep_at(chk) or (st.danger_mode and N.danger_at(chk, st.danger_list)) then why_n.steep = why_n.steep + 1 return done(nil) end
                local rgh = roughness(chk)
                if st.flat and rgh > st.flat.base * FLAT.GAIN then why_n.steep = why_n.steep + 1 return done(nil) end
                return done({ list = list, len = plan_len(list), rough = rgh })
            end)
            if not sent then st.planning = false why_n.noplan = why_n.noplan + 1 return done(nil) end
        end
        -- 1.2.84 PARALLEL VIA ROUTES. Both sides of the first SIDE_BATCH offsets are asked AT ONCE (6 plan_route calls), later offsets
        -- one ring (both sides) at a time. The nearest ring that has a clean route still wins (the shorter side of it): as the answers
        -- arrive the rings are judged in order, and a ring is decided as soon as its two sides are both answered and every nearer ring
        -- has been. (Measured: left-then-right ring by ring took 0.45 s per plan; replies are instant or never, so asking together
        -- costs one reply time, not six.)
        next_ring = function()
            local first = ring + 1
            if not SIDE_OFFSETS[first] then
                R.trail("nav", "plan audit: no way around the steep span at (%.0f, %.0f): %d via routes asked out to %d yd - no plan %d, ended short %d, still steep %d",
                    mx, my, 2 * #SIDE_OFFSETS, SIDE_OFFSETS[#SIDE_OFFSETS], why_n.noplan, why_n.short, why_n.steep)
                return after(false)
            end
            local last = first == 1 and math.min(SIDE_BATCH, #SIDE_OFFSETS) or first
            ring = last
            local res, left_n, settled = {}, 0, false
            for r = first, last do res[r] = { pending = 2 } end
            local function judge()
                if settled then return end
                for r = first, last do
                    local q = res[r]
                    if q.pending > 0 then return end                   -- a nearer ring is not decided yet
                    local best, best_side = q.l, "left"
                    if q.r and (not best or (st.flat and q.r.rough < best.rough) or (not st.flat and q.r.len < best.len)) then best, best_side = q.r, "right" end
                    if best then
                        settled = true
                        if st.flat then
                            local px0, py0 = R.here()
                            if st.done or cur.id ~= id or not px0 or R.dist2(px0, py0, audit[1].x, audit[1].y) > FLAT.MOVED_YD then return end
                            stats.pre_flat = (stats.pre_flat or 0) + 1
                            R.trail("nav", "flat terrain: a flatter route on the %s (%d yd out) - %.0f yd of climbing instead of %.0f, %.0f yd walk instead of the plan's",
                                best_side, SIDE_OFFSETS[r], best.rough, st.flat.base, best.len)
                            return launch(best.list)
                        end
                        stats.pre_sides = (stats.pre_sides or 0) + 1
                        R.trail("nav", "plan audit: %s at (%.0f, %.0f) - routed around it on the %s (%d yd out, %d points, %.0f yd walk)",
                            st.danger_mode and "an excluded enemy" or "steep span", mx, my, best_side, SIDE_OFFSETS[r], #best.list, best.len)
                        st.planning = false
                        return launch(best.list)
                    end
                end
                settled = true
                st.planning = false
                return next_ring()
            end
            for r = first, last do
                for _, side in ipairs({ 1, -1 }) do
                    if settled then break end
                    ask(side, SIDE_OFFSETS[r], function(rr)
                        if settled then return end
                        local q = res[r]
                        q.pending = q.pending - 1
                        if side == 1 then q.l = rr else q.r = rr end
                        judge()
                    end)
                end
            end
        end
        next_ring()
    end

    request = function(initial)
        st.tries = st.tries + 1
        local fx, fy, fz = R.here()
        if not fx then return fallback("no position") end
        st.planning, st.plan_t = true, R.now()
        if initial then cur.scanning, cur.scan_t = id, R.now() end      -- before the call: a reply may be synchronous
        -- 1.2.75: where the plan starts - the splice point ahead on the running path, else the player
        local sx, sy, sz = fx, fy, fz
        if st.splice then sx, sy, sz = st.splice.x, st.splice.y, st.splice.z end
        -- 1.2.77: a fresh race of plan requests (the first valid reply wins)
        st.winner, st.inflight, st.serial, st.sent_t, st.hedge_n, st.hedge_busy = nil, 0, 0, {}, 0, false
        local handle
        handle = function(ok, data)
            if st.done or cur.id ~= id or cur.done then return end
            st.planning = false
            if initial and cur.scanning == id then cur.scanning = nil end
            local function unusable(why)
                if st.started then return end              -- a swap that found nothing: the old path runs on
                return fallback(why)
            end
            local pts = (ok == true and type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
            -- 1.2.75: an anchored plan that failed is asked again plainly (the anchors may sit on a disconnected island)
            if (not pts or #pts < 2) and st.anchored and not st.started and not st.no_anchor then
                st.no_anchor, st.anchored = true, false
                R.trail("nav", "anchored plan to (%.0f, %.0f) got no path - asking the plain plan", x, y)
                return request(initial)
            end
            if not pts or #pts < 2 then return unusable("no plan") end
            local last = pts[#pts]
            local end_short = type(last) ~= "table" or not tonumber(last.x) or not tonumber(last.y)
                or R.dist2(last.x, last.y, x, y) > PRE.END_YD
            -- 1.2.75 PARTIAL PLAN: ends short but gets well closer - walked as far as it goes, the horizon plans the rest
            if end_short and type(last) == "table" and tonumber(last.x) then
                local gain = R.dist2(sx, sy, x, y) - R.dist2(last.x, last.y, x, y)
                if gain >= LONG.PARTIAL_GAIN and R.dist2(last.x, last.y, x, y) >= LONG.PARTIAL_SHORT then
                    st.partial = true
                    stats.pre_partials = (stats.pre_partials or 0) + 1
                    R.trail("nav", "partial plan: %d points, ends %.0f yd short of the goal, %.0f yd closer - walked, the next stretch is planned while running",
                        #pts, R.dist2(last.x, last.y, x, y), gain)
                    end_short = false
                end
            end
            if end_short then
                if st.anchored and not st.started and not st.no_anchor then
                    st.no_anchor, st.anchored = true, false
                    R.trail("nav", "anchored plan ends short of the goal - asking the plain plan")
                    return request(initial)
                end
                return unusable("plan ends short of the goal")
            end
            -- 1.2.75 SPLICE: keep the running path up to the splice point, continue with this plan from it
            if st.splice then
                local tail = {}
                for _, p in ipairs(pts) do
                    if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then tail[#tail + 1] = { x = p.x, y = p.y, z = p.z or 0 } end
                end
                if #tail > 0 and R.dist2(tail[1].x, tail[1].y, st.splice.x, st.splice.y) <= 3 then table.remove(tail, 1) end
                if #tail == 0 then return unusable("empty tail") end
                local chk = { { x = st.splice.x, y = st.splice.y, z = st.splice.z } }
                for _, q in ipairs(tail) do chk[#chk + 1] = q end
                if N.steep_at(chk) then
                    R.trail("nav", "spliced re-plan crosses steep ground - the running path stays")
                    st.done = true
                    return
                end
                local old = running_to(c, st.splice)
                local list = {}
                if old then for _, q in ipairs(old) do list[#list + 1] = q end end
                for _, q in ipairs(tail) do list[#list + 1] = q end
                stats.pre_splices = (stats.pre_splices or 0) + 1
                R.trail("nav", "spliced re-plan: %d yd of the running path kept (%d points), %d new points from %.0f, %.0f%s", old and #old or 0,
                    old and #old or 0, #tail, st.splice.x, st.splice.y, st.partial and " (partial)" or "")
                st.splice_done = true
                return launch(list)
            end
            local list = pre_trim(pts)
            if #list == 0 then return unusable("empty plan") end
            -- audit: a steep span on the plan becomes an avoidance zone and the path is planned again
            st.in_reply = true
            local zoned = false
            -- Include the connector from the player, before trimming away its
            -- first point: otherwise the initial climb can escape the audit.
            local audit = {{x=fx,y=fy,z=fz}}
            for _, point in ipairs(list) do audit[#audit+1] = point end
            local i, e = N.steep_at(audit)
            if i and st.tries <= PRE.TRIES then
                zoned = N.zone_span(audit[i], audit[e or i + 1], "unsafe slope") == "new"
                if zoned then
                    R.trail("nav", "plan audit: steep span (rise %.1f / run %.1f) - zone, planning again",
                        (audit[e or i + 1].z or 0) - (audit[i].z or 0), R.dist2(audit[i].x, audit[i].y, audit[e or i + 1].x, audit[e or i + 1].y))
                end
            elseif i then
                R.trail("nav", "plan audit: steep span at point %d of %d, no zone left to try", i, #list)
            end
            st.in_reply = false
            if zoned then return request(initial) end
            if i and not st.sides_tried and not st.started then
                st.sides_tried = true
                return try_sides(audit, i, e, function(found)
                    if found == false then
                        -- 1.2.46 A SHORT MESH RAMP IS NOT A WALL. Every side route crossed the same span (log 2026-11-18 09:34: rise 3.2 over
                        -- 2.8 yd, grade 1.14, 10/10 via routes still steep): it is the only way out, the navmesh calls it walkable (the
                        -- client's own limit is ~50 deg = 1.19) and the old ladder then walked only the 29 yd before it and gave the
                        -- destination up. A plan whose steep spans are all short, under that limit, and few is walked as planned.
                        if N.tolerable_steep(audit) and not st.started then
                            stats.pre_tolerated = (stats.pre_tolerated or 0) + 1
                            R.trail("nav", "plan audit: no way around the steep span at point %d - it is a short mesh ramp (under the %.2f client limit), walking the plan as Sentinel made it", i, N.RAMP_MAX)
                            return launch(list)
                        end
                        st.tries = PRE.TRIES + 1 return handle(ok, data)      -- no clean side route: the old ladder
                    end
                end)
            end
            if not i and not st.danger_tried and not st.started and cur.mode ~= "combat" then
                st.danger_tried = true
                local di, de, dl, dd = N.danger_at(audit)
                if di then
                    st.danger_mode, st.danger_list = true, dl
                    stats.pre_danger = (stats.pre_danger or 0) + 1
                    R.trail("nav", "plan audit: the path enters the aggro circle of %s (level %s, %.0f yd) at point %d of %d - asking for a route round it",
                        tostring(dd and dd.unit and select(2, pcall(function() return dd.unit:get_name() end)) or (dd and dd.name and (dd.name .. (dd.pack and " (a camp)" or ""))) or "an excluded enemy"),
                        tostring(dd and dd.level), (dd and dd.r) or 0, di, #audit)
                    return try_sides(audit, di, de, function(found)
                        if found == false then
                            R.trail("nav", "plan audit: no clean route round the excluded enemy - the plan is walked as planned")
                            return launch(list)
                        end
                    end)
                end
            end
            -- 1.2.88: a hilly plan (no span steep enough to reject) is walked, and flatter routes round it are asked
            if not i and not st.sides_tried and not st.started and not st.splice and (cur.mode == "guide" or cur.mode == "move") then
                local rg, ln, wi = roughness(audit)
                if ln >= FLAT.MIN_YD and ln <= FLAT.MAX_YD and rg / ln > FLAT.TRIGGER and audit[wi + 1] then
                    st.sides_tried = true
                    st.flat = { base = rg }
                    R.trail("nav", "flat terrain: the plan climbs / drops %.0f yd over %.0f yd (%.2f per yd) - walking it, flatter via routes are asked", rg, ln, rg / ln)
                    launch(list)
                    return try_sides(audit, wi, wi + 1, function() end)
                end
            end
            if i then
                -- LONG PATHS (action log 2026-11-15 17:02, a 1510 yd corpse run): any steep span anywhere on a long plan
                -- rejected the WHOLE plan, the walk never started and the player stood still for ever. The steep span
                -- is never walked, but the audited part BEFORE it is: follow that prefix, then plan again from where it
                -- ends (the next plan is audited the same way; a plan whose first steep span is near the start is still
                -- rejected, so a real wall is never walked at).
                local prefix, plen, px, py = {}, 0, fx, fy
                for k = 2, i do                         -- audit[1] is the player, audit[2..i] are safe points
                    local q = audit[k]
                    prefix[#prefix + 1] = { x = q.x, y = q.y, z = q.z }
                    plen = plen + R.dist2(px, py, q.x, q.y)
                    px, py = q.x, q.y
                end
                if not st.started and steep_block(x, y, z, audit[i].x, audit[i].y) then
                    st.done, cur.done = true, true
                    record_fail("unsafe_slope", x, y, z, false)
                    fail.give_up, fail.t = true, R.now()
                    return
                end
                SEG.key = SEG.key == key_of(x, y) and SEG.key or key_of(x, y)
                if SEG.key ~= SEG.last then SEG.last, SEG.n = SEG.key, 0 end
                if #prefix >= 1 and plen >= PRE.MIN_PREFIX and SEG.n < PRE.MAX_SEGMENTS and not st.started then
                    SEG.n = SEG.n + 1
                    local sb = audit[e or i + 1] or audit[i]
                    R.trail("nav", "plan audit: steep span at point %d of %d (rise %.1f over %.1f yd, grade %.2f, at %.0f, %.0f) - walking the audited %.0f yd before it (segment %d), then planning again",
                        i, #list, (sb.z or 0) - (audit[i].z or 0), R.dist2(audit[i].x, audit[i].y, sb.x, sb.y),
                        ((sb.z or 0) - (audit[i].z or 0)) / math.max(R.dist2(audit[i].x, audit[i].y, sb.x, sb.y), 0.01),
                        audit[i].x, audit[i].y, plen, SEG.n)
                    local function prefix_finished(success, reason)
                        if cur.id ~= id then return end
                        if success then
                            cur.done = true
                            return issue_walk(c, x, y, z, cur.mode or "move")
                        end
                        return finished(success, reason)
                    end
                    if S.follow_path(c, prefix, prefix_finished) then
                        st.started = true
                        cur.prefix_id = id
                        cur.leg_t = R.now()
                        stats.pre_walks = (stats.pre_walks or 0) + 1
                        return
                    end
                end
                -- A rejected plan must never fall through to follow_path or
                -- blind move_to of the same goal. Keep a prior audited path
                -- during regeneration; otherwise report a bounded refusal.
                -- 1.2.13 NEVER STAND STILL ON A LONG WALK. The 17:38 log: 107 yd walked, then "plan rejected: unsafe
                -- slope within 0 yd of the start" and the corpse run (428 yd) stood still for ever. The audit is this
                -- layer's own extra caution; Sentinel's mesh plan is walkable by construction and Sentinel steers and
                -- recovers on its own. So a steep span at the start hands the walk to Sentinel (move_to), and the
                -- rolling horizon / replan keep asking for the next stretch until the destination is reached.
                if not st.started then
                    -- 1.2.22: a living player is NOT handed a route that starts on steep ground (the 19:27 log: Sentinel walked 340 yd
                    -- of "recovering", stuck at a cliff). Only a ghost on a corpse run is handed to Sentinel (it falls for free).
                    if steep_block(x, y, z, fx, fy, true) then
                        st.done, cur.done = true, true
                        record_fail("unsafe_slope", x, y, z, false)
                        fail.give_up, fail.t = true, R.now()
                        return
                    end
                    R.trail("nav", "plan audit: steep span within %.0f yd of the start - Sentinel plans and walks this leg itself", plen)
                    return fallback("steep span at the start")
                end
                R.trail("nav", "plan audit: steep span within %.0f yd of the start - the running path stays", plen)
                return
            end
            launch(list)
        end
        local function race_cb(sn)
            return function(ok, data)
                if st.done or cur.id ~= id or cur.done then return end
                if st.winner and st.winner ~= sn then return end             -- a later reply of a lost race
                st.inflight = math.max(0, (st.inflight or 1) - 1)
                local valid = ok == true and type(data) == "table" and type(data.waypoints) == "table" and #data.waypoints >= 2
                if not valid and st.inflight > 0 then return end             -- the others are still out
                -- 1.2.79: a leg with no path: the next shorter leg at once (no waiting for the clock)
                if not valid and st.leg and (st.hedge_n or 0) < #LEG.HEDGE and not st.started and st.do_hedge then
                    st.hedge_n = (st.hedge_n or 0) + 1
                    R.trail("nav", "leg plan got no path - asking a shorter leg (%d yd)", LEG.HEDGE[st.hedge_n])
                    pcall(st.do_hedge, st.hedge_n)
                    return
                end
                local lat = R.now() - (st.sent_t[sn] or st.plan_t or R.now())
                if valid then
                    PS.lat[#PS.lat + 1] = lat
                    PS.n = PS.n + 1
                    st.winner = sn
                    NR.by[key_of(x, y)] = nil          -- 1.2.89: an answered goal is not an unanswered one
                    SAT.n = 0
                    if sn > 1 then
                        PS.hedge_wins = PS.hedge_wins + 1
                        R.trail("nav", "hedged plan won: request %d answered in %.2f s (the first had no reply)", sn, lat)
                        if st.alt_floor and st.alt_floor[sn] then
                            cache_put(zfix, "zfix", key_of(x, y), st.alt_floor[sn])
                        end
                    end
                end
                return handle(ok, data)
            end
        end
        local function send(nodes, is_hedge, alt_z)
            if st.done or cur.id ~= id or cur.done then return false end
            st.serial = st.serial + 1
            local sn = st.serial
            st.sent_t[sn] = R.now()
            if not is_hedge then st.plan_t = R.now() end
            if alt_z then st.alt_floor = st.alt_floor or {} st.alt_floor[sn] = alt_z end
            st.inflight = (st.inflight or 0) + 1
            local sent = S.plan_route(c, nodes, race_cb(sn))
            if sent then st.sent_any = true end
            if not sent then
                st.inflight = math.max(0, st.inflight - 1)
                if is_hedge then return false end
                st.planning = false
                if st.started then return false end
                fallback("plan not sent")
                return false
            end
            return true
        end
        --- A second / third request while the first has no reply (pre_watch asks for them at HEDGE_AT s).
        st.do_hedge = function(n)
            if st.done or cur.id ~= id or cur.done or st.started or st.winner then return end
            if sat_active() then
                SAT.skipped = SAT.skipped + 1
                if SAT.skipped % 5 == 1 then
                    R.trail("nav", "plan: %d plans in a row got no reply - no hedge request (the server is probably saturated); skipped %d", SAT.n, SAT.skipped)
                end
                return
            end
            local dist = R.dist2(sx, sy, x, y)
            local start0 = { x = sx, y = sy, z = sz }
            PS.hedged = PS.hedged + 1
            if n == 1 then PS.no_reply = PS.no_reply + 1 end
            if dist > LEG.DIRECT then
                local leg = LEG.HEDGE[n] or LEG.HEDGE[#LEG.HEDGE]
                local f = leg / dist
                local ax, ay, az0 = sx + (x - sx) * f, sy + (y - sy) * f, sz + ((z or sz) - sz) * f
                R.trail("nav", "plan: no reply in %.1f s - a hedge request for the first %d yd of the way", HEDGE_AT[n], leg)
                floors_for(c, key_of(ax, ay), ax, ay, az0, function(fl)
                    if st.done or cur.id ~= id or cur.done or st.started or st.winner then return end
                    local best, bd = nil, nil
                    for _, h in ipairs(fl or {}) do
                        local dz = math.abs(h - az0)
                        if dz <= LONG.FLOOR_DZ and (not bd or dz < bd) then best, bd = h, dz end
                    end
                    if best then
                        send({ start0, { x = ax, y = ay, z = best } }, true)
                    elseif n >= #LEG.HEDGE and (st.inflight or 0) == 0 then
                        -- 1.2.79: no floor for any leg point and nothing out: do not wait for the clock
                        fallback("no mesh floor for any leg point")
                    end
                end)
            else
                R.trail("nav", "plan: no reply in %.1f s - a hedge request at another floor of the goal", HEDGE_AT[n])
                floors_for(c, key_of(x, y), x, y, z, function(fl)
                    if st.done or cur.id ~= id or cur.done or st.started or st.winner then return end
                    local alts = {}
                    for _, h in ipairs(fl or {}) do
                        if math.abs(h - z) > HEIGHT_SAME then alts[#alts + 1] = h end
                    end
                    local pick = alts[n] or alts[1]
                    if pick and not (n >= 2 and dist >= LEG.NEAR_LEG_MIN) then
                        send({ start0, { x = x, y = y, z = pick } }, true, pick)
                    elseif n >= 2 and dist >= LEG.NEAR_LEG_MIN then
                        -- 1.2.79b: no other floor and still no reply: the goal itself may be unreachable (log 17:16, Darkshore
                        -- 54,33: 5 asks, no answer, while a 175 yd leg was planned at once) - a leg TOWARD it, so the player
                        -- gets close and arrives short instead of standing
                        local lp = LEG.point(sx, sy, sz, x, y, z, LEG.HEDGE[1])
                        if lp then
                            R.trail("nav", "plan: still no reply - a hedge request for a %d yd leg toward the goal", LEG.HEDGE[1])
                            floors_for(c, key_of(lp.x, lp.y), lp.x, lp.y, lp.z0, function(fl2)
                                if st.done or cur.id ~= id or cur.done or st.started or st.winner then return end
                                local best, bd = nil, nil
                                for _, h in ipairs(fl2 or {}) do
                                    local dz = math.abs(h - lp.z0)
                                    if dz <= LONG.FLOOR_DZ and (not bd or dz < bd) then best, bd = h, dz end
                                end
                                if not best and (not fl2 or #fl2 == 0) then best = lp.z0 end
                                if best then send({ start0, { x = lp.x, y = lp.y, z = best } }, true) end
                            end)
                        end
                    end
                end)
            end
        end
        local start = { x = sx, y = sy, z = sz }
        -- 1.2.77 PREFETCH HIT: the path to this waypoint was planned while the previous leg ran - no request at all
        if not st.splice and not st.prefetch_tried then
            st.prefetch_tried = true
            local pf = PF.plan
            if pf and R.now() - pf.t < PF.MAX_AGE and R.dist2(pf.tx, pf.ty, x, y) < 3 and R.dist2(sx, sy, pf.fx, pf.fy) < 35 then
                PF.plan = nil
                PS.prefetch_used = PS.prefetch_used + 1
                R.trail("nav", "prefetched path used: %d points planned while the last leg ran - no wait", #pf.pts)
                st.winner = 1
                return handle(true, { waypoints = pf.pts })
            end
        end
        -- 1.2.78 / 1.2.79: the ESP's bypass points (hazards on the way), and for a far goal a LEG - never a query longer than LEG.YD
        local dist_goal = R.dist2(sx, sy, x, y)
        if not st.no_anchor and dist_goal > 60 and type(c.plan_route) == "function" then
            local vias = LONG.hazard_vias(sx, sy, sz, x, y, z)
            local far = dist_goal > LEG.DIRECT
            local leg = far and LEG.point(sx, sy, sz, x, y, z, LEG.YD) or nil
            if far and not leg then far = false end
            if far or #vias > 0 then
                local items = {}
                for _, v in ipairs(vias) do
                    if not far or (v.along or 0) < LEG.YD - 20 then items[#items + 1] = v end
                end
                if far then
                    leg.along = LEG.YD
                    items[#items + 1] = leg
                end
                table.sort(items, function(p, q) return (p.along or 0) < (q.along or 0) end)
                st.anchored, st.leg, st.wait = true, far, LEG.WAIT_S
                local nvia = #vias
                return LONG.resolve(c, items, function(list)
                    if st.done or cur.id ~= id or cur.done then return end
                    if far and (#list == 0 or math.abs(list[#list].x - leg.x) > 0.5 or math.abs(list[#list].y - leg.y) > 0.5) then
                        -- the leg point has no mesh floor: the shorter leg is asked instead
                        st.hedge_n = (st.hedge_n or 0) + 1
                        R.trail("nav", "leg point (%.0f, %.0f) has no mesh floor - asking a shorter leg", leg.x, leg.y)
                        if st.hedge_n <= #LEG.HEDGE then return pcall(st.do_hedge, st.hedge_n) end
                        return fallback("no floor for a leg point")
                    end
                    local nodes = { start }
                    for _, a in ipairs(list) do nodes[#nodes + 1] = a end
                    if not far then nodes[#nodes + 1] = goal end
                    stats.pre_legs = (stats.pre_legs or 0) + (far and 1 or 0)
                    if far then
                        R.trail("nav", "leg route: %.0f yd to the goal, planned %d yd of it%s (a leg, never a long query)", dist_goal, LEG.YD,
                            nvia > 0 and string.format(" around %d hazard(s)", nvia) or "")
                    else
                        local why = {}
                        for _, v in ipairs(vias) do why[#why + 1] = v.why end
                        R.trail("nav", "ESP: %d hazard(s) on the way (%s) - planned through %d point(s) around them", nvia, table.concat(why, "; "), #list)
                    end
                    send(nodes)
                end)
            end
        end
        send({ start, goal })
    end
    --- re-generation (a zone, a hazard): a fresh path from where the player stands, swapped in
    st.again = function(why)
        if st.done or not st.started or st.in_reply or cur.id ~= id then return false end
        if st.planning and R.now() - (st.plan_t or 0) < PRE.WAIT_S then return false end
        if R.now() - st.regen_t < PRE.REGEN_GAP then return false end
        st.regen_t, st.tries = R.now(), 0
        R.trail("nav", "path re-generated while walking (%s)", tostring(why))
        request(false)
        return true
    end
    cur.pre = st
    -- 1.2.88: the route that was calculated before the fight, walked again
    do
        local list, partial, info = CP.take(x, y)
        if list then
            st.partial = partial
            st.planning = false
            R.trail("nav", "combat over: walking the SAME route as before the fight - %s", info)
            stats.cp_resumed = (stats.cp_resumed or 0) + 1
            st.t0 = R.now()
            return st.launch_saved(list)
        end
    end
    request(true)
    return true
end

--- Called every pulse: a first plan with no reply after WAIT_S becomes a plain move_to.
local function pre_watch()
    local st = cur.pre
    -- 1.2.77: hedged requests while the first plan has no reply
    if st and st.id == cur.id and st.planning and not st.started and not st.done and st.do_hedge and not st.winner and (st.inflight or 0) > 0 then
        local n = (st.hedge_n or 0) + 1
        local at = HEDGE_AT[n]
        if at and (R.now() - (st.plan_t or R.now())) > at then
            st.hedge_n = n
            pcall(st.do_hedge, n)
        end
    end
    local wait = st and st.wait or PRE.WAIT_S                        -- 1.2.75: an anchored (long) plan gets longer
    if st and st.id == cur.id and st.planning and not st.started and not st.done
        and (R.now() - (st.plan_t or R.now())) > wait then
        st.planning = false
        st.fallback("no reply in " .. tostring(wait) .. " s")
    end
end

-- NEXT-WAYPOINT HINT (ported from Forever Questing 1.29.0). The engine says which point it
-- will walk after the current one (N.hint_next, cheap, every route tick). While the player
-- walks a guide leg and that point is FLOOR_FIRST yd or more away, its floors are asked
-- once, so the chain-ahead retarget finds the floor already known and issues its walk
-- (and its precomputed path) without a floor query first.
local hint = nil
local HINT_TTL = 3.0
function N.hint_next(pos, key)
    local x, y, z = R.xyz(pos)
    if not x or not key then return false end
    if not hint or hint.key ~= key then
        hint = { key = key, x = x, y = y, z = z, floors = false }
    end
    hint.t = R.now()
    return true
end

local function prefetch_floor(c, x, y, z)
    local k = key_of(x, y)
    if zfix[k] then return end
    local st = zscan[k]
    if st and st.checked and (R.now() - st.t) <= FAIL_WINDOW then return end
    floors_for(c, k, x, y, z, function(list, st2)
        if #list >= 2 then return end          -- stacked floors: the normal walk picks by reachability
        st2.checked = true
        if #list == 1 then cache_put(zfix, "zfix", k, list[1]) end
    end)
end

local function hint_tick()
    if not hint or hint.floors or R.now() - hint.t > HINT_TTL then return end
    if (cur.mode ~= "guide" and cur.mode ~= "move") or not cur.x or cur.done or swimming() then return end
    local c = N.client()
    if not c or not S.moving(c) then return end
    local hx, hy = R.here()
    if not hx or R.dist2(cur.x, cur.y, hint.x, hint.y) < 3 then return end
    if R.dist2(hx, hy, hint.x, hint.y) >= FLOOR_FIRST then
        hint.floors = true
        prefetch_floor(c, hint.x, hint.y, hint.z)
    end
end

--- 1.2.77 PREFETCH: while the running leg has less than PF.NEAR yd of path left, the path from this leg's goal to the guide's next
--- waypoint (the hint) is planned once and kept (PF.plan); request() uses it when the guide asks for that waypoint.
local function pf_tick(c)
    if PF.asking or not hint or R.now() - hint.t > HINT_TTL then return end
    if cur.mode ~= "guide" or not cur.x or cur.done or det or swimming() or not S.moving(c) or S.path_pending(c) then return end
    if R.dist2(cur.x, cur.y, hint.x, hint.y) < 20 then return end
    local pf = PF.plan
    if pf and R.dist2(pf.tx, pf.ty, hint.x, hint.y) < 3 and R.dist2(pf.fx, pf.fy, cur.x, cur.y) < 3 then return end   -- already have it
    local key = string.format("%d|%d|%d|%d", math.floor(cur.x), math.floor(cur.y), math.floor(hint.x), math.floor(hint.y))
    if PF.key == key then return end
    local left = N.LA and N.LA.path_left and N.LA.path_left() or nil
    if not left or left > PF.NEAR then return end
    PF.key, PF.asking = key, true
    PS.prefetch_asked = PS.prefetch_asked + 1
    local fx, fy, fz, tx, ty, tz = cur.x, cur.y, cur.z or 0, hint.x, hint.y, hint.z or zfix[key_of(hint.x, hint.y)] or cur.z or 0
    local sent = S.plan_route(c, { { x = fx, y = fy, z = fz }, { x = tx, y = ty, z = tz } }, function(ok, data)
        PF.asking = false
        if ok == true and type(data) == "table" and type(data.waypoints) == "table" and #data.waypoints >= 2 then
            local pts = {}
            for _, p in ipairs(data.waypoints) do
                if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then pts[#pts + 1] = { x = p.x, y = p.y, z = p.z or 0 } end
            end
            local last = pts[#pts]
            if last and R.dist2(last.x, last.y, tx, ty) <= PRE.END_YD then
                PF.plan = { fx = fx, fy = fy, tx = tx, ty = ty, pts = pts, t = R.now() }
            end
        end
    end)
    if not sent then PF.asking = false end
end

local function preserve_height(mode)
    return mode == "interaction" or mode == "indoor"
end

-- 1.2.43 WALK LOOP BREAKER. Log 2026-11-18 09:03-09:06: a supply run to an inn 1,100 yd away was re-issued every second, 100+ times,
-- while the player stood on one spot (-5516, -4061) for over two minutes. No walk ever ran long enough to fail or be reported (a
-- replaced walk gets no callback), the stuck ladder and the 5-minute hearth rule both need a RUNNING walk, and Auto Load saw "has
-- not moved for 5 minutes" and reloaded. The same destination asked LOOP_N times within a window while the player has not moved
-- LOOP_MOVE yd is a loop: the Sentinel state is logged, the destination is blacklisted for a while (the area blacklist every caller
-- honours) and the walk is refused, so the trip / goal gives up or picks another instead of standing still for ever.
local LP = { key = nil, n = 0, t0 = 0, x = nil, y = nil }
local LOOP_N, LOOP_MIN_S, LOOP_MOVE = 8, 6.0, 4.0
local function walk_loop(c, x, y, z, mode)
    if mode == "combat" or mode == "elevator" or mode == "boat" or mode == "swim" or mode == "portal" or mode == "astar" then return false end
    local hx, hy = R.here()
    if not hx then return false end
    local now = R.now()
    local k = key_of(x, y)
    if LP.key ~= k or not LP.x or R.dist2(hx, hy, LP.x, LP.y) > LOOP_MOVE or (now - LP.t0) > 60 then
        LP.key, LP.n, LP.t0, LP.x, LP.y = k, 1, now, hx, hy
        return false
    end
    LP.n = LP.n + 1
    if LP.n < LOOP_N or (now - LP.t0) < LOOP_MIN_S then return false end
    local state = c and S.full_state(c) or nil
    R.trail("nav", "walk loop: %d walks to (%.0f, %.0f) in %.0f s and the player moved %.1f yd (Sentinel state %s, mode %s) - giving this destination up for a while",
        LP.n, x, y, now - LP.t0, R.dist2(hx, hy, LP.x, LP.y), tostring(state), tostring(mode))
    stats.walk_loops = (stats.walk_loops or 0) + 1
    LP.key, LP.n = nil, 0
    -- 1.2.60: a goal 900+ yd away that Sentinel will not plan (log 14:06: 5389 yd, state idle, 8 walks) is walked in staged legs
    if N.NP and N.NP.far_mark(x, y, hx, hy) then
        R.trail("nav", "walk loop: the goal (%.0f, %.0f) is %.0f yd away - Sentinel plans no path that long, walking it in staged legs", x, y, R.dist2(hx, hy, x, y))
        return "stage"
    end
    Z.blacklist_area({ x = x, y = y, z = z }, NR.RADIUS, "the same walk was re-issued " .. LOOP_N .. " times without moving")
    record_fail("walk_loop", x, y, z, false)
    return true
end
N._walk_loop = walk_loop

issue_walk = function(c, x, y, z, mode, keep_z)
    if mode == "combat" and cur.mode ~= "combat" and cur.x and not cur.done then pcall(CP.save, c, "the fight's first step") end
    if N.NP and N.NP.far_gate(c, x, y, mode) then return false end         -- 1.2.60
    local wl = walk_loop(c, x, y, z, mode)
    if wl == "stage" then
        if N.NP.far_gate(c, x, y, mode) then return false end
        wl = true
    end
    if wl then cur.done = true return false end
    -- 1.73.0: combat / a floor pick can still hand us a cliff z; keep the walk
    -- on the player's floor so check_path does not keep re-issuing z 79.
    -- 1.2.40: keep_z = the height IS a mesh floor read at this spot (walk_at_floor / retry_at_ground): never
    -- clamped back to the player's own, there is no floor there (HTTP 422 "Position not on navmesh").
    local zf_cached = zfix[key_of(x, y)]
    if zf_cached and math.abs(zf_cached - z) <= HEIGHT_SAME then keep_z = true end      -- 1.2.40: a cached mesh floor
    if mode ~= "elevator" and not preserve_height(mode) and not keep_z then
        local hx, hy, hz = R.here()
        if hz and (z - hz) > CLIMB_ABOVE then
            R.trail("nav", "(%.0f, %.0f): dest z %.1f is %.0f yd above the player - walking at z %.1f (not up the mountain)",
                x, y, z, z - hz, hz)
            z = hz
        end
    end
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), mode or "move", nil, false
    cur.leg_t = R.now()
    stop_req = nil                                -- a new walk replaces a pending stop
    cur.scanning = nil                            -- audit 1.19.0: a new walk ends any floor scan (a stale one blocked the lost-walk check)
    cur.pre = nil
    stats.issued = stats.issued + 1
    pcall(function()
        require("actlog").event("nav", "request", nil, { operation = id, mode = mode or "move", x = x, y = y, z = z })
    end)
    -- 1.20.1: each new destination is logged (a crash log shows the walks before it)
    local wk = key_of(x, y)
    if wk ~= cur.logged_key then
        cur.logged_key = wk
        local hx, hy, hz = R.here()
        R.trail("nav", "move_to (%s) %.0f %.0f %.0f, %.0f yd", tostring(mode or "move"), x, y, z,
            hx and R.dist3(hx, hy, hz, x, y, z) or -1)
    end
    local finished = function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        if success and preserve_height(mode) then
            local px, py, pz = R.here()
            local wrong_floor = not px or not pz or math.abs(pz - z) > 2.5
            if wrong_floor or (mode == "interaction" and R.dist3(px, py, pz, x, y, z) > 4) then
                success, reason = false, mode == "interaction" and "interaction_out_of_reach" or "wrong_floor"
                pcall(function()
                    require("actlog").event("nav", "floor_mismatch", reason,
                        { operation=id, target_z=z, player_z=pz, mode=mode })
                end)
            end
        end
        if success then
            local fa, sd = N.false_arrival(x, y)
            if fa then
                MEM.walk_ended(false)
                if sd and sd <= SHORT_OK then
                    short.key, short.t = key_of(x, y), R.now()            -- 1.20.1: as close as the mesh goes
                    return
                end
                if not preserve_height(mode) and astar_try(x, y, z, mode, "arrived_short") then return end   -- 1.30.0
                record_fail("arrived_short")                          -- 1.20.1: off-mesh, no blacklist
                fail.offmesh = true
                return
            end
            fail.reason, fail.offmesh = nil, false
            MEM.walk_ended(true)                      -- 1.9.0: the black points passed count ok
            pcall(function()
                require("actlog").event("nav", "arrived", nil, { x = math.floor(x), y = math.floor(y), z = math.floor(z),
                    operation = id, mode = mode or "move", secs = tonumber(string.format("%.1f", R.now() - (cur.t or R.now()))) })
            end)
            return
        end
        local code = reason or "failed"
        if not preserve_height(mode) and (HEIGHT_RETRY[code] or mesh_code(code)) and retry_at_ground(c, id, x, y, z, code, mode) then return end
        R.trail("nav", "walk to (%.0f, %.0f, %.0f) ended: %s", x, y, z, tostring(code))
        pcall(function()
            require("actlog").event("nav", "walk_failed", tostring(code), { x = math.floor(x), y = math.floor(y), z = math.floor(z),
                operation = id, mode = mode or "move", secs = tonumber(string.format("%.1f", R.now() - (cur.t or R.now()))) })
        end)
        if not preserve_height(mode) and (OFFMESH[code] or mesh_code(code)) and astar_try(x, y, z, mode, code) then MEM.walk_ended(false) return end   -- 1.30.0
        record_fail(code, x, y, z, mode ~= "combat")  -- 1.9.0: a short combat step is no black point
        MEM.walk_ended(false)
    end
    if not preserve_height(mode) and pre_start(c, id, x, y, z, finished) then return true end
    local sent = S.move_to(c, { x = x, y = y, z = z }, finished)
    if not sent then cur.done = true end
    return sent
end

--- Out of combat and FLOOR_FIRST yd or more away with an unchecked height:
--- the floors there first, then the walk at the nearest one. True while it runs.
local function walk_at_floor(c, x, y, z, mode)
    local k = key_of(x, y)
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), mode or "move", nil, false
    cur.scanning, cur.scan_t = id, R.now()
    stop_req = nil
    return floors_for(c, k, x, y, z, function(list, st)
        if cur.scanning == id then cur.scanning = nil end
        st.checked = true
        if cur.id ~= id then return end
        local hz = list[1]
        local px, py, pz = R.here()
        -- a cliff / flyer floor far above the player: take the floor nearest us
        if pz and hz and (hz - pz) > CLIMB_ABOVE then
            local best = hz
            for i = 1, #list do
                if math.abs(list[i] - pz) < math.abs(best - pz) then best = list[i] end
            end
            if best ~= hz then
                R.trail("nav", "(%.0f, %.0f): mesh floor %.1f is a mountain - walking the player's floor %.1f", x, y, hz, best)
            end
            hz = best
        end
        if hz and math.abs(hz - z) > HEIGHT_SAME then
            cache_put(zfix, "zfix", k, hz)
            R.trail("nav", "(%.0f, %.0f): walking at the floor there, z %.1f (guess %.1f, %d floor(s))", x, y, hz, z, #list)
            issue_walk(c, x, y, hz, mode, true)
        else
            issue_walk(c, x, y, z, mode)
        end
    end)
end

local function event_flags()
    local ev = package.loaded["events"]
    return type(ev) == "table" and type(ev.navflags) == "table" and ev.navflags or nil
end

local function in_fight()
    local nf = event_flags()
    local me0 = R.me()
    local okc, fighting = pcall(function() return me0 and me0:is_in_combat() == true end)
    return (nf and nf.in_combat) or (okc and fighting == true) or false
end
CP.in_fight = in_fight
local TRAVEL = { guide = true, move = true }
--- Keep the unwalked rest of the running travel path (called as a fight displaces / stops the walk).
function CP.save(c, why)
    if not c or not cur.x or cur.done or not TRAVEL[cur.mode or "move"] or cur.route then return end
    if det or S.path_pending(c) then return end
    local pts = S.current_path(c)
    local idx = tonumber(S.path_index(c)) or 1
    if type(pts) ~= "table" or #pts < 2 then return end
    idx = math.max(1, math.min(#pts, math.floor(idx)))
    local rem = {}
    for i = idx, #pts do
        local q = pts[i]
        local qx, qy, qz = R.xyz(q)
        if qx then rem[#rem + 1] = { x = qx, y = qy, z = qz or 0 } end
    end
    if #rem < 2 then return end
    local len = 0
    for i = 2, #rem do len = len + R.dist2(rem[i - 1].x, rem[i - 1].y, rem[i].x, rem[i].y) end
    if len < 15 then return end
    CP.snap = { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, pts = rem, partial = cur.pre_partial == cur.id, t = R.now() }
    stats.cp_saved = (stats.cp_saved or 0) + 1
    R.trail("nav", "combat pause (%s): %d points / %.0f yd of the planned route kept for after the fight", tostring(why), #rem, len)
end
--- The kept route for a travel walk to (x, y), cut at the point nearest the player; nil when none fits.
function CP.take(x, y)
    local sn = CP.snap
    if not sn then return nil end
    if R.now() - sn.t > CP.TTL or R.dist2(sn.x, sn.y, x, y) > 4 or in_fight() then
        if R.now() - sn.t > CP.TTL then CP.snap = nil end
        return nil
    end
    local hx, hy = R.here()
    if not hx then return nil end
    local k, kd = nil, 1e9
    for i = 1, #sn.pts do
        local d = R.dist2(hx, hy, sn.pts[i].x, sn.pts[i].y)
        if d < kd then k, kd = i, d end
    end
    if not k or kd > CP.NEAR or k >= #sn.pts then CP.snap = nil return nil end
    local list = {}
    for i = k, #sn.pts do list[#list + 1] = sn.pts[i] end
    CP.snap = nil
    return list, sn.partial, string.format("%d points, %.0f yd from the path", #list, kd)
end
function CP.clear() CP.snap = nil end
N.CP = CP

--- Why a NEW walk may not start now, or nil. A walk already running is a
--- retarget, not a new start. A cast is no reason: Sentinel defers a walk
--- asked for while casting by itself (navigating.deferred, doc).
local function start_blocked(c, mode)
    -- 1.7.5: no new travel walk in combat - only the fight's own walks (mode "combat")
    if mode ~= "combat" then
        local nf = event_flags()
        local me0 = R.me()
        local okc, fighting = pcall(function() return me0 and me0:is_in_combat() == true end)
        if (nf and nf.in_combat) or (okc and fighting == true) then return "in combat" end
    end
    if not S.server_up(c) then
        fail.server_until = R.now() + SERVER_BACKOFF
        return "server down"
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- 1.7.23 detours (movement.lua's stuck fan): a walk to a checked point beside
-- the blocked stretch, then the real goal again. While a detour runs the
-- walk's destination (cur.x) stays the real goal, so the guide asking for the
-- same goal every tick leaves the detour alone; another goal ends it.
-- ----------------------------------------------------------------------------
--- The guide asks for `x, y` while a detour runs: the same goal - leave the
--- detour alone (true); another goal - the detour is over (false).
local function detour_owns(x, y)
    if not det then return false end
    if x and R.dist2(x, y, det.dest.x, det.dest.y) <= 8 then return true end
    det = nil
    return false
end

--- The walk's own goal walked again from here (a fresh Sentinel path; a
--- running walk is re-planned by the new move_to, never stopped).
local function walk_again(c, d, why)
    if d.route and type(d.route) == "table" then
        N.follow_route(d.route, true)
    else
        issue_walk(c, d.x, d.y, d.z, d.mode or "move")
    end
    R.trail("nav", "a fresh path to (%.0f, %.0f, %.0f) - %s", d.x, d.y, d.z, tostring(why))
end

detour_done = function(reason)
    local d = det
    if not d then return end
    det = nil
    local c = N.client()
    if c then walk_again(c, d.dest, "after a detour (" .. tostring(reason) .. ")") end
end

-- ----------------------------------------------------------------------------
-- holds (Sentinel has no pause / resume)
-- ----------------------------------------------------------------------------
function N.holding() return next(held.reasons) ~= nil end

--- Walk to `dest`. True when a walk there is running or was started (also
--- when `dest` is underfoot, or remembered for after a hold); false when
--- refused (combat / rest / backpedal, a blacklisted area, the same spot just
--- failed, no Sentinel). Safe to call every tick.
function N.nav_to(dest, direct, mode)
    local x, y, z = R.xyz(dest)
    if not x then return false end
    -- Indoors, another reachable floor is not an alternative destination.
    -- Exact interactions already have their own mode and observed height.
    if mode == nil or mode == "guide" or mode == "npc" then
        local me = R.me()
        local ok, indoors = pcall(function()
            return me and me:is_valid() and me:is_indoors()
        end)
        if ok and indoors == true then mode = "indoor" end
    end
    -- 1.22.0 / 1.66.0 LIFTS (movement/elevator): a walk that crosses Telredor's cap
    -- or Shattrath's Aldor Rise is the matching lift run; the run's own legs are mode "elevator"
    if mode ~= "elevator" then
        -- an imported Zygor NPC (repairer / innkeeper / flight master: merchants.lua
        -- from_zygor) has no height - the player's own stands in; under the cap it is
        -- the town's. Guide points are corrected in quest/guide.lua to_world; real
        -- unit positions, corpses and combat walks keep their height.
        local okz, fz = pcall(function() return dest.from_zygor end)
        if okz and fz == true then
            local cz = EL.cap_z(x, y, z)
            if cz then z = cz end
        end
        if EL.riding() then return true end                 -- nothing moves the player on the lift (combat too)
        if BT.riding() and mode ~= "boat" then return true end    -- 1.2.32: nor on the ship
        if mode ~= "combat" then
            local hx, hy, hz = R.here()
            local dir = EL.wants(hx, hy, hz, x, y, z)
            if dir then return EL.run(dir, { x = x, y = y, z = z }) end
        end
    end
    -- 1.2.80 UNDERGROUND CHECK (user: "player not entering cave"; log 17:25: the Death Cap object at z 69.7 sat 20 yd below the mesh floor
    -- at its xy (89.9), the walk stayed in awaiting_path 40 s, three times): once per goal, 40+ yd away, the mesh floors under it are
    -- asked and the answer is LOGGED - no floor / a floor far above / on the mesh - so a cave interior (a goal Sentinel's mesh has no
    -- layer for) is named instead of guessed at. A goal 6+ yd below its nearest floor is flagged underground: its no-path ladder runs
    -- at half the waits (N.is_underground).
    if preserve_height(mode) then      -- interaction / indoor walks never ask the floors themselves; the others do
        local hx0, hy0 = R.here()
        local ugk = key_of(x, y)
        if hx0 and R.dist2(hx0, hy0, x, y) > 40 and UG.seen[ugk] == nil and not zfix[ugk] then
            local cc = N.client()
            if cc then
                UG.seen[ugk] = true
                if UG.n > 200 then UG.seen, UG.under, UG.n = {}, {}, 0 end
                UG.n = UG.n + 1
                floors_for(cc, ugk, x, y, z, function(list)
                    local best, bd = nil, nil
                    for _, h in ipairs(list or {}) do
                        local dz = math.abs(h - z)
                        if not bd or dz < bd then best, bd = h, dz end
                    end
                    if not best then
                        R.trail("nav", "underground check (%.0f, %.0f, z %.1f): the mesh has NO floor there - Sentinel cannot plan a path to it (off the mesh)", x, y, z)
                    elseif z < best - 6 then
                        UG.under[ugk] = true
                        R.trail("nav", "underground check (%.0f, %.0f, z %.1f): %.0f yd BELOW the nearest mesh floor (z %.1f) - underground (a cave): the mesh has no layer at its height", x, y, z, best - z, best)
                    else
                        R.trail("nav", "underground check (%.0f, %.0f, z %.1f): on the mesh (nearest floor z %.1f, %.1f yd off)", x, y, z, best, bd)
                    end
                end)
            end
        end
    end
    -- 1.73.0: do not path up a mountain to a flyer / cliff mesh
    -- (Naphthal'ar at z 79 while the thicket is at 12). Elevator dests already
    -- returned above. A lake dest is decided after the mesh floors are known.
    if mode ~= "elevator" and not preserve_height(mode) then
        local hx, hy, hz = R.here()
        if hz and (z - hz) > CLIMB_ABOVE then
            R.trail("nav", "(%.0f, %.0f): dest z %.1f is %.0f yd above the player - walking at z %.1f (not up the mountain)",
                x, y, z, z - hz, hz)
            z = hz
        end
    end
    -- 1.30.0: the local A* search / walk to this goal runs; another walk ends it
    if AS.active() then
        if not preserve_height(mode) and mode ~= "combat" and AS.for_goal({ x = x, y = y }) then return true end
        AS.cancel(mode == "combat" and "a combat walk" or "a new destination")
    end
    if not preserve_height(mode) and detour_owns(x, y) then return true end           -- 1.7.23: a stuck detour runs
    -- 3.7.1: a sharp turn is being made - the next leg starts after it
    if R.turning and mode ~= "combat" then
        if held.dest then held.dest = { x = x, y = y, z = z, mode = mode, direct = direct } end
        stats.refused = stats.refused + 1
        return true
    end
    local why = N.refusal()
    -- combat walks always go; an NPC approach (movement.interact) goes
    -- through its own NPC hold
    if why and mode ~= "combat" and not (mode == "npc" and why == "npc") and not (mode == "boat" and why == "boat") and not (mode == "combat" and why == "front") then
        stats.refused = stats.refused + 1
        return false
    end
    if not preserve_height(mode) then
        local fz = zfix[key_of(x, y)]
        if fz then
            local _, _, pz = R.here()
            -- 1.2.41: a cached floor was picked on purpose (walk_at_floor takes the floor nearest the player; retry_at_ground
            -- the next one when that failed), so it is used however far above the player it is. 1.2.40 only trusted a lone
            -- floor: with two found, every guide tick clamped the walk back to the player's z and Sentinel answered 422 again.
            z = fz
        end
    end
    local hx, hy, hz = R.here()
    if hx and R.dist2(hx, hy, x, y) <= UNDERFOOT and math.abs(hz - z) < 3 then
        return true
    end
    if not direct and mode ~= "combat" and Z.blocked_xy(x, y) then
        record_fail("blacklisted")
        return false
    end
    if not direct and mode ~= "combat" and MEM.goal_blocked(x, y, z) then   -- 1.9.0: a black goal cell
        record_fail("blacklisted")
        return false
    end
    local k = key_of(x, y)
    local fe = fails_at[k]
    if fe and fe.n > 0 and (R.now() - fe.t) < 5 and (fail.offmesh or fail.give_up) then return false end
    local c = N.client()
    if not c then return false end
    -- server back-off, then is_server_available()
    if fail.server_until then
        if R.now() < fail.server_until then
            stats.refused = stats.refused + 1
            return false
        end
        if not S.server_up(c) then
            fail.server_until = R.now() + SERVER_BACKOFF
            stats.refused = stats.refused + 1
            return false
        end
        fail.server_until = nil
    end
    -- a hold (cast, loot, mana gem): remembered, walked when it lifts
    if N.holding() then
        held.dest = { x = x, y = y, z = z, mode = mode, direct = direct }
        return true
    end
    local busy = S.moving(c)
    local same = (mode == "guide" or mode == "npc") and SAME_DEST_GUIDE or SAME_DEST
    if busy and cur.x and R.dist2(cur.x, cur.y, x, y) <= same
        and (not preserve_height(mode) or (cur.mode == mode and math.abs((cur.z or z) - z) <= 1)) then
        if cur.mode ~= "route" then return true end
        -- a saved / planned route already walking this dest
        if cur.route then return true end
    end
    -- its floors are being asked for (walk_at_floor / retry_at_ground)
    if cur.scanning and cur.scanning == cur.id and (R.now() - (cur.scan_t or 0)) < HEIGHT_SCAN_HOLD
        and cur.x and R.dist2(cur.x, cur.y, x, y) <= SAME_DEST
        and (not preserve_height(mode) or math.abs((cur.z or z) - z) <= 1) then
        return true
    end
    if busy and (R.now() - cur.t) < (mode == "combat" and COMBAT_GAP or RETARGET_GAP) then return true end
    -- Exact object approaches retain their observed Z; Sentinel owns routing and recovery.
    -- 1.20.1: at most one walk START a second (combat two), busy or not
    -- 1.2.58 WALK RESTART STORM. A stop / start loop (the 12:29-12:30 danger hold: one walk start a second for over a minute, each a
    -- stop, a path query and a follow_path) passed this gate every second. Five starts toward one goal in STORM.S s limit
    -- the starts to one per STORM.GAP s for STORM.HOLD s - a legitimate re-plan is a few a minute, never five in 12 s.
    local start_gap = (mode == "combat" and COMBAT_START_GAP or START_GAP)
    if mode ~= "combat" then
        local now = R.now()
        if STORM.key ~= k then STORM.key, STORM.ts, STORM.until_t = k, {}, -1e9 end
        if now < STORM.until_t then start_gap = STORM.GAP end
    end
    if cur.leg_t and (R.now() - cur.leg_t) < start_gap then
        stats.paced = (stats.paced or 0) + 1
        return true
    end
    if mode ~= "combat" then
        local now = R.now()
        local ts = STORM.ts
        ts[#ts + 1] = now
        while #ts > 0 and now - ts[1] > STORM.S do table.remove(ts, 1) end
        if #ts >= STORM.N and now >= STORM.until_t then
            STORM.until_t = now + STORM.HOLD
            stats.storms = (stats.storms or 0) + 1
            R.trail("nav", "walk restart storm: %d starts toward (%.0f, %.0f) in %d s - starts limited to one per %.0f s for %d s",
                #ts, x, y, STORM.S, STORM.GAP, STORM.HOLD)
        end
    end
    if not busy then
        local blocked = start_blocked(c, mode)
        if blocked then stats.refused = stats.refused + 1 return false end
    end
    -- 3.8.0: before an out-of-combat walk of MIN_WALK yd or more starts, mount
    -- (or Travel Form) first - the player stands for the cast meanwhile
    if not busy and mode ~= "combat" and mode ~= "npc" and hx and MT.wants(R.dist2(hx, hy, x, y)) then
        if MT.begin(R.me(), x, y) then return true end         -- 1.2.63: walk on foot first, mount after 15 yd
    end
    -- 1.67.0: a stored valid / good path to this dest is walked as follow_path
    -- (Sentinel does not re-query the mesh). Same dest while a route runs is
    -- already a no-op above.
    if mode ~= "combat" and not preserve_height(mode) and hx and not swimming() then
        local saved = MEM.find_good(x, y, z, hx, hy, N._pickup_index)
        if not saved then saved = MEM.find_valid(nil, hx, hy, x, y, N._pickup_index) end
        if type(saved) == "table" and #saved >= 2 then
            return N.follow_route(saved, true)
        end
    end
    -- 1.67.0: last yards of a narrow recorded corridor: move_direct (the mesh
    -- snaps a door / portal walk). Widths from get_corridor_widths; missing
    -- table = no opinion.
    if not busy and (mode == "guide" or mode == "npc") and hx and R.dist2(hx, hy, x, y) <= 8 then
        local widths = S.corridor_widths(c)
        local w = nil
        if type(widths) == "table" and #widths > 0 then
            local idx = S.path_index(c)
            w = (type(idx) == "number" and widths[idx]) or widths[#widths]
        end
        if type(w) == "number" and w > 0 and w < 2.5 then
            return N.step_into({ x = x, y = y, z = z })
        end
    end
    -- 1.67.0: guide / npc walks ask the floors at any distance (talk / accept
    -- a few yards off a landing used to skip the query). Combat and zfix stay,
    -- except a dest in the lake-depth band under the player still asks so the
    -- walk is issued at the walkable mesh floor (not the underwater dest z).
    local dive_band = hx and hz and (hz - z) > DIVE_BELOW and (hz - z) < DIVE_MAX
    local need_floor = not preserve_height(mode) and hx and not zfix[k] and not swimming()
        and (dive_band or (mode ~= "combat" and (mode == "guide" or mode == "npc" or R.dist2(hx, hy, x, y) >= FLOOR_FIRST)))
    if need_floor then
        local st = zscan[k]
        -- audit 1.19.0: a floor query unanswered HEIGHT_SCAN_HOLD s no longer
        -- holds the walk (it re-queued on the stuck query until FAIL_WINDOW)
        local stale = st and st.asking and (R.now() - st.t) >= HEIGHT_SCAN_HOLD
        if not stale and not (st and st.checked and (R.now() - st.t) <= FAIL_WINDOW) then
            return walk_at_floor(c, x, y, z, mode)
        end
    end
    return issue_walk(c, x, y, z, mode)
end

--- 1.20.0: the 1.4.0 / 1.5.0 "one walk per Zygor waypoint key, rechecked every
--- 5 s" gate is gone - the guide is one continuous Sentinel walk (RestedXP's
--- chain in quest/engine). Kept for the movement surface: a guide nav_to (same
--- destination while moving = no-op, a new one = one retarget, no stop); the
--- key is ignored. Its refusals stay: a black goal cell (1.9.0), a give-up /
--- server back-off (audit S3).
function N.waypoint_walk(dest, key)
    local x, y, z = R.xyz(dest)
    if not x then return false end
    if AS.active() then                                  -- 1.30.0: the local A* walk to this goal runs
        if AS.for_goal({ x = x, y = y }) then return true end
        AS.cancel("a new guide destination")
    end
    if detour_owns(x, y) then return true end           -- 1.7.23: a stuck detour runs
    if MEM.goal_blocked(x, y, z) then                    -- 1.9.0: the goal cell is a black point
        record_fail("blacklisted")
        return false
    end
    -- audit S3: a give-up (max_stuck / max_repath) or a server back-off is not
    -- retried at once - the same 5 s give-up window nav_to uses
    local now = R.now()
    if (fail.give_up and (now - (fail.t or 0)) < 5) or (fail.server_until and now < fail.server_until) then
        return false
    end
    return N.nav_to(dest, true, "guide")
end

function N.waypoint_forget() end                    -- 1.20.0: nothing kept per key

--- 1.7.9: the running walk's own path from the point being walked, up to
--- `yards` along it (the player's position first): Sentinel's
--- get_current_path from get_path_index. {} plus the player when idle.
function N.path_ahead(yards)
    yards = tonumber(yards) or 40
    local out = {}
    local hx, hy, hz = R.here()
    if hx then out[1] = { x = hx, y = hy, z = hz } end
    local c = N.client()
    if not c or not S.moving(c) then return out end
    local pts = S.current_path(c)
    if type(pts) ~= "table" then return out end
    local idx = S.path_index(c)
    idx = (type(idx) == "number" and idx >= 1) and math.floor(idx) or 1
    local walked, px, py, pz = 0, hx, hy, hz
    for i = idx, #pts do
        local p = pts[i]
        local okp, x, y, z = pcall(function() return p.x, p.y, p.z end)
        if okp and type(x) == "number" and type(y) == "number" then
            local span = px and R.dist2(px, py, x, y) or 0
            if px and span > 0 and walked + span > yards then
                local f=math.max(0,(yards-walked)/span)
                out[#out+1]={x=px+(x-px)*f,y=py+(y-py)*f,
                    z=type(pz)=="number" and type(z)=="number" and pz+(z-pz)*f or z}
                break
            end
            walked=walked+span
            out[#out + 1] = { x = x, y = y, z = z }
            px, py, pz = x, y, z
            if walked >= yards then break end
        end
    end
    return out
end

--- 1.74.0: kept on the surface. Travel is Sentinel move_to on walkable floors.
function N.swim_to(pos)
    return N.nav_to(pos)
end

--- 1.30.0: one leg of the local A* path (movement/astar) - Sentinel's
--- move_direct, a single waypoint (as the swim / portal step), never a key. One
--- leg start a second at most (START_GAP); holds and the lift are respected.
function N.astar_leg(x, y, z)
    if EL.riding() or R.resting or R.backpedal_until then return false end
    local c = N.client()
    if not c or N.holding() or stop_req then return false end
    if cur.leg_t and (R.now() - cur.leg_t) < START_GAP then return false end
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), "astar", nil, false
    cur.leg_t = R.now()
    cur.scanning = nil
    stats.issued = stats.issued + 1
    R.trail("nav", "move_direct (astar leg) %.1f %.1f %.1f", x, y, z)
    local ok = S.move_direct(c, { x = x, y = y, z = z }, function()
        if cur.id ~= id then return end
        cur.done = true
    end)
    if not ok then cur.done = true end
    return ok
end
AS.leg_fn = N.astar_leg

--- 1.7.7: the last yards INTO a portal. The portal is not on the navmesh (a
--- move_to would be snapped back onto it), so this is Sentinel's move_direct -
--- a single waypoint, no pathfinding (doc v0.0.8). The loading screen ends it.
function N.step_into(pos)
    local x, y, z = R.xyz(pos)
    if not x then return false end
    local c = N.client()
    if not c then return false end
    if S.moving(c) then return true end            -- this step, or the walk to the entry, still runs
    if start_blocked(c, "portal") then return false end
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), "portal", nil, false
    cur.leg_t = R.now()
    stop_req = nil
    cur.scanning = nil                      -- audit 1.19.0: as issue_walk
    stats.issued = stats.issued + 1
    R.trail("nav", "stepping into the portal: straight walk to (%.0f, %.0f, %.0f)", x, y, z)
    local ok = S.move_direct(c, { x = x, y = y, z = z }, function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        R.trail("nav", "portal step ended: %s", success and "arrived" or tostring(reason))
    end)
    if not ok then cur.done = true end
    return ok
end

-- 1.7.22 PICK UP THE PATH WHERE THE PLAYER IS: the point nearest the player
-- within [lo, hi]; when the player is already past it (nearer the next point
-- than it is), the next one.
local function pickup_index(pts, lo, hi)
    if type(pts) ~= "table" or #pts == 0 then return 1 end
    lo = math.max(1, math.floor(lo or 1))
    hi = math.min(#pts, math.floor(hi or #pts))
    local x, y = R.here()
    if not x or lo > hi then return lo end
    local best, bd = nil, nil
    for i = lo, hi do
        local p = pts[i]
        if type(p) == "table" and p.x then
            local d = R.dist2(x, y, p.x, p.y)
            if bd == nil or d < bd then best, bd = i, d end
        end
    end
    if not best then return lo end
    local p, n = pts[best], pts[best + 1]
    if n and R.dist2(x, y, n.x, n.y) < R.dist2(p.x, p.y, n.x, n.y) then best = best + 1 end
    return best
end
N._pickup_index = pickup_index

--- Walk a recorded route (array of {x,y,z}) with follow_path, picked up at
--- its point nearest the player, black points left out. The same table while
--- it runs is a no-op unless `replace`. True when accepted.
function N.follow_route(list, replace)
    if type(list) ~= "table" or #list < 1 then return false end
    if N.refusal() then return false end
    local c = N.client()
    if not c then return false end
    if N.holding() then
        held.dest = { route = list }
        return true
    end
    if not replace and cur.route == list and S.moving(c) then return true end
    local all = {}
    for i = 1, #list do
        local x, y, z = R.xyz(list[i])
        if not x then return false end
        all[i] = { x = x, y = y, z = z }
    end
    local from = pickup_index(all, 1, #all)
    local pts = {}
    for i = from, #all do pts[#pts + 1] = all[i] end
    if from > 1 then R.trail("nav", "route picked up at point %d of %d (the nearest)", from, #all) end
    local dropped
    pts, dropped = MEM.filter(pts)                           -- 1.9.0: no point in a black point
    if dropped > 0 then R.trail("nav", "route: %d point(s) in black points left out", dropped) end
    if #pts < 1 or (#pts < 2 and #all >= 2 and dropped > 0) then
        record_fail("black_point")
        return false
    end
    local hx, hy, hz = R.here()
    local audit = {}
    if hx then audit[1] = {x=hx,y=hy,z=hz} end
    for _, point in ipairs(pts) do audit[#audit+1] = point end
    if N.steep_at(audit) then
        record_fail("unsafe_slope")
        R.trail("nav", "recorded route rejected: unsafe slope")
        return false
    end
    cur.id = cur.id + 1
    local id = cur.id
    local last = pts[#pts]
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = last.x, last.y, last.z, R.now(), "route", list, false
    cur.leg_t = R.now()
    stop_req = nil
    cur.scanning = nil                      -- audit 1.19.0: as issue_walk
    stats.issued = stats.issued + 1
    local ok = S.follow_path(c, pts, function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        if success then MEM.walk_ended(true) return end
        R.trail("nav", "route walk ended: %s", tostring(reason))
        record_fail(reason or "failed", nil, nil, nil, true)
        MEM.walk_ended(false)
    end)
    if not ok then cur.done = true end
    return ok
end

--- 1.7.22: the running walk picks the path up again from where the player
--- is: Sentinel plans from the player on every move_to, so the current
--- destination is issued again (a recorded route from its nearest point).
function N.rejoin(why)
    local c = N.client()
    if not c or not cur.x or not S.moving(c) then return false end
    if S.path_pending(c) then return true end                -- its path is being planned anyway
    R.trail("nav", "walk picked up from here%s", why and (" - " .. tostring(why)) or "")
    walk_again(c, { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }, why or "rejoin")
    return true
end

--- A fresh path from where the player stands to the walk's own goal: the
--- same destination issued again (another move_to re-plans without a stop).
function N.replan_fresh(why)
    local c = N.client()
    if not c or not cur.x then return false end
    -- audit N6: no new walk in combat (out-of-combat walks), with the server
    -- down or mid-pivot
    if start_blocked(c, cur.mode) or R.turning then return false end
    local d = { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }
    -- 1.9.0: the second stuck re-plan of the same corridor is a black point
    if type(why) == "string" and why:find("stuck", 1, true) then
        local px, py, pz = R.here()
        if px then mem_black(MEM.note_replan(px, py, pz, d.x, d.y), "re-planned twice") end
    end
    det = nil
    -- 1.67.0: a running walk to this dest is client:replan(reason) (recorded;
    -- no invented {soft=true}). A recorded route / idle walk still re-issues.
    if S.moving(c) and not d.route and not S.path_pending(c)
        and (R.now() - (cur.leg_t or 0)) >= FRESH_LEG then
        if S.soft_replan(c, why or "stuck") then
            cur.leg_t = R.now()
            stats.issued = stats.issued + 1
            R.trail("nav", "a fresh path to (%.0f, %.0f, %.0f) - %s", d.x, d.y, d.z, tostring(why or "stuck"))
            return true
        end
    end
    walk_again(c, d, why or "stuck")
    return true
end

--- Walk to `pt` (a checked detour point), then on to the walk's own goal.
function N.detour(pt, why, opts)
    local c = N.client()
    if not c or not cur.x or type(pt) ~= "table" or not pt.x then return false end
    if start_blocked(c, cur.mode) or R.turning then return false end          -- audit N6
    local hx, hy = R.here()
    if not hx or R.dist2(hx, hy, pt.x, pt.y) > ((opts and opts.max_yd) or DETOUR_MAX_YD) then return false end   -- audit N2
    local dest = { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }
    cur.id = cur.id + 1
    local id = cur.id
    cur.route, cur.done = nil, false                 -- cur.x stays the real goal
    cur.t, cur.leg_t = R.now(), R.now()
    stop_req = nil
    cur.scanning = nil                      -- audit 1.19.0: as issue_walk
    stats.issued = stats.issued + 1
    det = { x = pt.x, y = pt.y, z = pt.z, dest = dest, id = id, until_t = R.now() + ((opts and opts.max_s) or DETOUR_MAX_S) }
    R.trail("nav", "%s to (%.0f, %.0f) - %s", (opts and opts.label) or "stuck re-navigation: detour", pt.x, pt.y, tostring(why))
    local ok = S.move_to(c, { x = pt.x, y = pt.y, z = pt.z }, function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        if not det or det.id ~= id then return end
        detour_done(success and "reached" or tostring(reason))
    end)
    if not ok then det, cur.done = nil, true return false end
    return true
end

function N.detour_active() return det ~= nil end

--- 1.7.24: every navmesh floor under `pos` (Sentinel get_all_heights, nearest
--- pos.z first) -> cb(list of heights). False when it could not be asked.
function N.all_heights(pos, cb)
    local c = N.client()
    if not c or type(pos) ~= "table" or type(cb) ~= "function" then return false end
    return S.floors(c, { x = pos.x, y = pos.y, z = pos.z or 0 }, function(list) pcall(cb, list) end)
end

-- 1.7.29 / 1.7.30 STEEP GROUND: a path's own points (Sentinel find_path
-- waypoints carry their z) checked for a climb over UP (35 deg) or a drop over
-- DOWN (55 deg), or a STEP_DZ wall in under a yard. Pure geometry - the stuck
-- fan (movement.lua) refuses a detour over steep ground. Sentinel plans its
-- own walks; this layer no longer re-routes them.
-- STEEP GROUND: the shared terrain model (movement/core R.TERRAIN), ported from Forever Questing.
local function indoors()
    local me = R.me()
    local ok, inside = pcall(function() return me and me:is_indoors() end)
    return ok and inside == true
end

local TM = R.TERRAIN                      -- the shared terrain model (movement/core)
local ST = { UP = R.TERRAIN.UP, UP_IN = R.TERRAIN.UP_IN, DOWN = R.TERRAIN.DOWN, MIN_RUN = R.TERRAIN.MIN_RUN,
    STEP_DZ = R.TERRAIN.STEP_DZ }
N.STEEP = ST

-- 1.28.146 GHOSTS FALL FOR FREE. A dead player takes no fall damage, so a
-- steep descent or a drop is no hazard on a corpse run (log 2026-11-06: 7 of
-- 38 slope vetoes were descents, each costing a recovery cycle). Every ASCENT
-- limit stays: a ghost cannot climb a wall. Read at most twice a second -
-- ST.grade / ST.first_steep run over whole point lists.
local ghost_cache = { t = -1e9, v = false }
local function ghost_now()
    local t = R.now()
    if t - ghost_cache.t >= 0.5 or t < ghost_cache.t then
        ghost_cache.t = t
        local ok, v = pcall(function() return R.me():is_ghost() end)
        ghost_cache.v = ok and v == true
    end
    return ghost_cache.v
end
N.ghost_now = ghost_now

function ST.grade(a, b, inside)
    if inside == nil then inside = indoors() end
    local up = inside and ST.UP_IN or ST.UP
    local run = R.dist2(a.x, a.y, b.x, b.y)
    local dz = (b.z or 0) - (a.z or 0)
    if run >= ST.MIN_RUN then
        local g = dz >= 0 and dz / run or (-dz / run) * (ST.UP / ST.DOWN)
        return g, dz >= 0 and dz/run > up
            or (dz < -ST.STEP_DZ and -dz/run > ST.DOWN and not ghost_now())
    end
    if dz > ST.STEP_DZ or (dz < -ST.STEP_DZ and not ghost_now()) then return 99, true end   -- a wall to climb, not a step
    return 0, false
end
--- The first steep stretch of `points`: its index (points[i] -> points[i+1]), or nil.
function ST.first_steep(points, inside, progress_check)
    if type(points) ~= "table" then return nil end
    if inside == nil then inside = indoors() end
    -- Indoor risers are judged across three yards of stair treads. Keep
    -- immediate vertical-wall and downhill checks; never relax cliff drops.
    -- Keep enough dense nodes to detect a sustained descent after allowing
    -- an isolated <=2 yard step; a one-yard window could hide that descent.
    local window,up = 3, inside and ST.UP_IN or ST.UP
    local ghost = ghost_now()
    local first,run = 1,0
    for i=1,#points-1 do
        local a,b=points[i],points[i+1]
        if type(a)=="table" and type(b)=="table" and a.z and b.z then
            local edge=R.dist2(a.x,a.y,b.x,b.y)
            local dz=b.z-a.z
            local _,steep=ST.grade(a,b,inside)
            if steep and (not inside or dz<=0 or edge>=window
                or (edge<ST.MIN_RUN and dz>ST.STEP_DZ)) then return i,i+1 end
            run=run+edge
            while first<i do
                local p,q=points[first],points[first+1]
                local n=R.dist2(p.x,p.y,q.x,q.y)
                if run-n<window then break end
                run,first=run-n,first+1
            end
            local rise=b.z-points[first].z
            if ((run>=window and rise>up*run)
                or (not ghost and run>=ST.MIN_RUN and -rise>ST.STEP_DZ and -rise>ST.DOWN*run)
                or (run<ST.MIN_RUN and (rise>ST.STEP_DZ or (not ghost and -rise>ST.STEP_DZ)))
                or (i==#points-1 and run>=ST.MIN_RUN and rise>up*run))
                then return first,i+1 end
        else first,run=i+1,0 end
    end
    return nil
end
N.steep_at = ST.first_steep

-- 1.2.58 DANGER AUDIT (no avoidance zones on the live stub): the first stretch of a plan inside the aggro circle of an
-- enemy the rules avoid (an elite at the player's level or above, a mob 5+ levels above: targeting.danger_mobs) is judged
-- like a steep span - the via routes of try_sides (15 .. 140 yd either side) are asked and audited, the clean shorter one is
-- walked. A player already standing inside a circle is not held to it. Returns i, e (first / last point index of the stretch),
-- dangers or nil.
local function seg_dist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
    local qx, qy = ax + t * dx, ay + t * dy
    return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
end
function N.danger_at(points, dangers)
    if type(points) ~= "table" or #points < 2 then return nil end
    if dangers == nil then
        local TG = package.loaded["targeting"]
        local me = R.me()
        if type(TG) ~= "table" or type(TG.danger_mobs) ~= "function" or not me then return nil end
        local ok, list = pcall(TG.danger_mobs, me, TG.PATH_SCAN or 90, TG.DANGER_LEVELS or 5, true, true)
        dangers = ok and list or {}
        -- 1.2.74 ESP (pathing): camps of 4+ linked mobs, elites and much higher levels are hazards for the path as well
        local ES = package.loaded["esp"]
        if type(ES) == "table" and type(ES.hazards) == "function" then
            local okh, hz = pcall(ES.hazards)
            if okh and type(hz) == "table" then
                local merged = {}
                for _, d in ipairs(dangers) do merged[#merged + 1] = d end
                for _, h in ipairs(hz) do
                    local dup = false
                    for _, d in ipairs(dangers) do
                        if d.x and R.dist2(d.x, d.y, h.x, h.y) < 12 then dup = true break end
                    end
                    if not dup then merged[#merged + 1] = h end
                end
                dangers = merged
            end
        end
    end
    local first, last, hit
    for _, d in ipairs(dangers) do
        local r = (d.r or 20) + 4
        if R.dist2(points[1].x, points[1].y, d.x, d.y) > r then
            for k = 1, #points - 1 do
                local a, b = points[k], points[k + 1]
                if seg_dist(d.x, d.y, a.x, a.y, b.x, b.y) <= r then
                    if not first or k < first then first, hit = k, d end
                    break
                end
            end
        end
    end
    if not first then return nil end
    last = first
    for k = first + 1, #points - 1 do
        if seg_dist(hit.x, hit.y, points[k].x, points[k].y, points[k + 1].x, points[k + 1].y) <= (hit.r or 20) + 4 then last = k else break end
    end
    return first, last + 1, dangers, hit
end

-- 1.2.46 Short, walkable-by-mesh steep spans: run <= RAMP_RUN yd, climb grade <= RAMP_MAX (the client's ~50 deg limit),
-- a drop of at most RAMP_DROP yd, at most RAMP_SPANS of them. Anything longer / steeper / more numerous stays a wall.
N.RAMP_MAX, N.RAMP_RUN, N.RAMP_DROP, N.RAMP_SPANS = 1.19, 6, 3, 3
function N.tolerable_steep(points)
    local k, spans = 1, 0
    while k < #points do
        local sub = {}
        for n = k, #points do sub[#sub + 1] = points[n] end
        local i, e = ST.first_steep(sub)
        if not i then return true end
        e = e or i + 1
        local a, b = sub[i], sub[e]
        local run = R.dist2(a.x, a.y, b.x, b.y)
        local dz = (b.z or 0) - (a.z or 0)
        if run > N.RAMP_RUN or run < 0.5 then return false end
        if dz >= 0 then
            if dz / run > N.RAMP_MAX then return false end
        elseif -dz > N.RAMP_DROP then
            return false
        end
        spans = spans + 1
        if spans > N.RAMP_SPANS then return false end
        k = k + e - 1
    end
    return true
end

--- A stop may go out now: the walk follows its path and is not fresh.
local function safe_to_stop(c)
    if S.path_pending(c) then return false end
    return (R.now() - (cur.leg_t or 0)) >= FRESH_LEG
end

--- Stop the walk this layer started. Cheap when idle. A walk still waiting
--- for its path or younger than FRESH_LEG s is stopped by the pulse later
--- unless `force` (Stop / GUI close / unload: callbacks will not pulse again).
-- 1.2.70 STOP TRACE (user: "pathing is stopping and starting", log 15:47: a new walk to the same goal every 3-4 s, "Nav settle"
-- after each stop, and no line saying who stopped it): every stop of a running walk is logged once with its reason, the walk's
-- age, whether it was forced and the calling file:line (the debug library when the sandbox has it).
local STOP_LOG_T = -1e9
local function stop_callers()
    local dbg = rawget(_G, "debug")
    if type(dbg) ~= "table" or type(dbg.getinfo) ~= "function" then return "?" end
    local out = {}
    for lvl = 3, 7 do
        local ok, info = pcall(dbg.getinfo, lvl, "Sl")
        if not ok or type(info) ~= "table" then break end
        local src = tostring(info.short_src or "?"):match("([^/" .. string.char(92) .. "]+)$") or "?"
        out[#out + 1] = src .. ":" .. tostring(info.currentline or "?")
        if #out >= 3 then break end
    end
    return table.concat(out, " < ")
end

local STOP_IDLE_T = -1e9
function N.stop(reason, force)
    do
        local cs = N.client()
        if cs and CP.in_fight and CP.in_fight() and cur.x and not cur.done then pcall(CP.save, cs, reason) end
    end
    -- 1.2.83: a stop with nothing to stop (no walk, no pending path, no detour, no deferred stop, nothing held) is a no-op at most
    -- every 0.5 s - the loot wait called it ten times a second (flight recorder: nav_stop x10 per heartbeat)
    do
        local c0 = N.client()
        local busy0 = c0 ~= nil and (S.moving(c0) or S.path_pending(c0))
        if not busy0 and not det and not stop_req and held.dest == nil and cur.done ~= false and R.now() - STOP_IDLE_T < 0.5 then return end
        if not busy0 then STOP_IDLE_T = R.now() end
    end
    do
        local fr = package.loaded["flightrec"]
        if fr then fr.note("nav_stop", tostring(reason)) end
        local nowt = R.now()
        if cur.x and not cur.done and nowt - STOP_LOG_T >= 0.5 then
            STOP_LOG_T = nowt
            R.trail("nav", "walk stop requested: %s%s - walk %.1f s old, mode %s, from %s", tostring(reason),
                force == true and " (forced)" or "", nowt - (cur.t or nowt), tostring(cur.mode), stop_callers())
        end
    end
    held.dest = nil -- a later cast/loot release must not restart a cancelled walk
    S.invalidate()
    if N._node_reset then N._node_reset() end           -- 1.2.71: the dropped plan reply must not leave the patrol "pending"
    det = nil                               -- 1.7.23
    if cur.mode ~= "astar" or reason ~= "astar leg" then AS.cancel(reason or "stop") end   -- 1.30.0
    local c = N.client()
    local was = c ~= nil and (S.moving(c) or S.path_pending(c))
    if c and was then
        if force == true or safe_to_stop(c) then
            S.stop(c)
            stop_req = nil
        else
            stop_req = { t = R.now(), reason = reason }
            stats.deferred_stops = stats.deferred_stops + 1
        end
    end
    MEM.walk_ended(false)                   -- 1.9.0
    cur.id = cur.id + 1                     -- the stopped walk's callback, if any, is ignored
    cur.x, cur.mode, cur.route, cur.done = nil, nil, nil, true
    cur.t = -1e9                            -- the next walk is not a retarget: it goes at once (and replaces a deferred stop)
    cur.scanning = nil
    -- 3.7.1: a deliberate stop also ends a sharp turn in progress
    if R.turning then R.turn_cancel, R.turning = true, false end
    if was then R.quiet_until = R.now() + QUIET_STOP end
end

--- Hold the walk for `reason` (a cast, loot, a mana gem): stopped, its
--- destination remembered.
function N.pause(reason)
    reason = reason or "hold"
    MEM.on_pause(reason)                    -- 1.9.0: a loot / conjure / cast pause holds the memory
    local first = not N.holding()
    held.reasons[reason] = true
    if first and cur.x and N.busy() then
        local dest = { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route, direct = true }
        local turning = R.turning
        N.stop("hold " .. reason)
        held.dest = dest -- only a deliberate pause may restore this destination
        R.turning = turning                     -- a sharp-turn hold keeps its turn
        R.turn_cancel = false
    end
end

--- Lift `reason`; when no hold is left the remembered destination is walked again.
function N.resume(reason)
    reason = reason or "hold"
    MEM.on_resume(reason)
    held.reasons[reason] = nil
    if N.holding() then return end
    local d = held.dest
    held.dest = nil
    if not d then return end
    if d.nodes then
        N.follow_nodes(d.nodes)
    elseif d.route then
        N.follow_route(d.route, true)
    else
        N.nav_to(d, d.direct, d.mode)
    end
end

-- 1.40.0 CHECK_PATH (user: "check_path (running-path validation)"): while a walk of
-- ours runs, the path Sentinel is following is validated every CHECK_GAP s, and an
-- unambiguous "no longer valid" takes a FRESH path at once instead of waiting for the
-- walk to stall into the stuck ladder. Never on a fresh leg or while a path request is
-- in flight (the crash rule), never through a hold or a pending stop, and never over
-- the local A* legs. The adapter answers nil for any shape it cannot read, and nil
-- never re-plans - a spurious re-plan is worse than a late one.
-- 1.2.78 (user: "lengthen our path check to avoid duplicating Sentinel's"): Sentinel's own Path Validation (Movement tab) checks the
-- running path every 5 s and repaths on a bad answer (2 retries, a budget of 3), so a check of ours every 3 s asked the server
-- the same question twice as often and could start a second re-plan over Sentinel's. Ours now runs every 10 s - twice Sentinel's
-- interval, so it only catches what Sentinel's pass missed - and never while Sentinel itself is repathing (the state tests below).
local CHECK_GAP = 10.0
local check_t, check_logged = -1e9, false
local check_replan = nil
local function check_running_path(c, t)
    if t - check_t < CHECK_GAP then return end
    if not cur.x or cur.done or stop_req or N.holding() then return end
    if cur.mode == "astar" then return end
    if not S.moving(c) or S.path_pending(c) or S.recovering(c) then return end
    if (t - (cur.leg_t or 0)) < FRESH_LEG then return end
    local pts = S.current_path(c)
    if type(pts) ~= "table" or #pts < 2 then return end
    local hx, hy, hz = R.here()
    if not hx then return end
    check_t = t
    local checked_id = cur.id
    local first = math.max(1, math.floor(tonumber(S.path_index(c)) or 1))
    if first > #pts then return end
    local ahead = {{x=hx, y=hy, z=hz}}
    local last = pts[#pts]
    -- player + remaining-path samples + the dest: 8 points bound
    local room = S.CHECK_POINTS - 2
    if room < 1 then room = 1 end
    for i = first, math.min(#pts, first + room - 1) do
        ahead[#ahead + 1] = pts[i]
    end
    if last and type(last.x) == "number" then
        local e = ahead[#ahead]
        if not (e and e.x == last.x and e.y == last.y) then
            if #ahead >= S.CHECK_POINTS then
                ahead[S.CHECK_POINTS] = last
            else
                ahead[#ahead + 1] = last
            end
        end
    end
    S.check_path(c, { x = hx, y = hy, z = hz }, ahead, function(verdict, shape)
        if cur.id ~= checked_id or cur.done or stop_req or S.client() ~= c or S.path_pending(c) then return end
        if not check_logged then
            check_logged = true
            R.trail("nav", "check_path first answer: %s", tostring(shape))
        end
        if verdict ~= false or S.recovering(c) then return end
        -- Reissuing an identical route every three seconds resets Sentinel's
        -- stuck recovery. One validation replan per stationary destination;
        -- physical progress or a different destination permits another.
        if check_replan then
            local dx,dy,dz=hx-check_replan.x,hy-check_replan.y,hz-check_replan.z
            local gx,gy=(cur.x or 0)-check_replan.gx,(cur.y or 0)-check_replan.gy
            if dx*dx+dy*dy+dz*dz < 16 and gx*gx+gy*gy < 16 then return end
        end
        check_replan = {x=hx,y=hy,z=hz,gx=cur.x or 0,gy=cur.y or 0}
        R.trail("nav", "check_path: the running path is no longer valid - taking a fresh one")
        N.replan_fresh("check_path: the path is no longer valid")
    end)
end

--- Per frame: event-flag stops, the deferred stop, walks ended without a
--- callback, the detour timeout, the nav memory.
-- ----------------------------------------------------------------------------
-- ZONES FOR HAZARD SPANS, PATH RE-GENERATION (ported from Forever Questing 1.29.0)
-- ----------------------------------------------------------------------------
--- Re-generate the running walk's path (a zone, a hazard, a loop): a precomputed walk plans a
--- fresh path from the player's spot and swaps it in; any other walk asks Sentinel to re-plan softly.
function N.regen(c, reason)
    local st = cur.pre
    if st and st.id == cur.id and not st.done and st.started and cur.x and not cur.done then
        return st.again(reason) == true
    end
    return S.soft_replan(c, reason)
end

--- A hazard point as one avoidance zone. Not placed on the player or on the goal (that would
--- trap the walk). "new" when a zone was just added, true when one already covers it.
function N.zone_point(p, r, kind)
    local px, py = R.here()
    if not px or R.dist2(px, py, p.x, p.y) <= r + 1 then return false end
    if cur.x and R.dist2(cur.x, cur.y, p.x, p.y) <= r + 2 then return false end
    local was = N.avoided(p.x, p.y)
    if not N.avoid_area(p, r, kind) then return false end
    return was and true or "new"
end

--- A hazard span a -> b (steep ground / a drop) as one zone at its middle: radius from its length
--- (2.5 .. 6 yd, 3.5+ for a drop).
function N.zone_span(a, b, kind)
    local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
    local r = math.max(2.5, math.min(6, R.dist2(a.x, a.y, b.x, b.y) / 2 + 1.5))
    if kind == "unsupported ground / drop" then r = math.max(r, 3.5) end
    return N.zone_point({ x = mx, y = my, z = ((a.z or 0) + (b.z or 0)) / 2 }, r, kind)
end

-- ROLLING PATH HORIZON (ported from Forever Questing 1.29.0; user: "calculates and creates
-- pathing 20 yards ahead of the player ... the player movement isn't waiting on a generated
-- path"). A walk never lets its planned path run out under the player: while Sentinel walks, the
-- path left ahead is measured every LA.GAP s, and when it is shorter than the horizon (LA.H = 20
-- yd at least) while the goal is still farther than the path's end, the walk is issued AGAIN at
-- once - a precomputed walk plans a fresh path while the old one is still walked, any other walk
-- is a second move_to, which Sentinel re-plans without stopping. The horizon grows with the
-- measured path latency and walking speed (speed * (latency + 0.5 s)), capped at LA.H_MAX.
-- Guard: needs 4 yd of progress toward the goal between two asks, at most LA.MAX per goal chain.
-- Off for combat, NPC, portal, swim, A*, elevator, corpse and recorded-route walks and while a
-- detour runs. Sentinel does the planning; this only decides WHEN to ask.
local LA = { REFRESH_S = 25, REFRESH_YD = 60, REFRESH_MOVED = 15, H = 20, H_MAX = 40, GAP = 0.25, SHORT_YD = 3.0, MIN_GOAL = 25, PROGRESS = 4.0, MAX = 12, CHAIN_S = 60,
    speed = 7, latency = 0.3, last_t = -1e9, id = -1, lat_done = true, pos = nil, pos_t = 0,
    key = nil, n = 0, goal_d = nil, chain_t = -1e9 }
N.LA = LA
local LA_SKIP = { combat = true, npc = true, portal = true, swim = true, astar = true, route = true, corpse = true,
    elevator = true, boat = true }

--- The walk running may be replaced now: it follows its path and is not fresh.
local function replaceable(c)
    if S.path_pending(c) then return false end
    return (R.now() - (cur.leg_t or 0)) >= FRESH_LEG
end

--- The horizon in yards for the speed and path latency measured so far.
function LA.horizon()
    return math.max(LA.H, math.min(LA.H_MAX, LA.speed * (LA.latency + 0.5)))
end

--- Yards of planned path left ahead of the player and the path's last point.
function LA.path_left()
    local pts = N.path_ahead(300)
    if #pts < 2 then return nil end
    local len = 0
    for i = 2, #pts do len = len + R.dist2(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y) end
    return len, pts[#pts]
end

-- 1.2.57 NO PATH GENERATED. Log 12:15-12:21 (Stormwind -> Goldshire, 1213 yd): the precomputed plan got no reply in 3 s,
-- Sentinel sat in navigating.awaiting_path with the player standing, and nothing ever looked at that wait: the walk ended
-- 40 s later "stuck", a back-off detour re-asked the SAME long query, and the loop ran for 8 minutes (walks 1-3 refused / no
-- reply, distance to the goal 1212-1215 yd the whole time). A walk that waits for its path longer than it should climbs a ladder:
--   rung 1 (NP.WAIT[1] s)  the goal's other floors (retry_at_ground: the floor guess picks the one nearest the PLAYER's z,
--                          which means nothing 1200 yd away; the next floor is asked, or the local A*);
--   rung 2 (NP.WAIT[2] s)  a STAGED LEG: a shorter query to a point NP.ANCHORS[1] yd along the way, checked with
--                          validate_destination (reachable + the server's path distance) so a long query that the server
--                          cannot finish becomes two it can; then the real goal again from there;
--   rung 3 (NP.WAIT[3] s)  the same with the shorter anchor NP.ANCHORS[2];
--   rung 4 (NP.WAIT[4] s)  the goal is recorded as "no_path", its area blacklisted, the walk stopped - the guide moves on.
-- Staged legs per goal are capped (NP.MAX_STAGES); the ladder starts again after NP.RESET_S s without a wait.
local NP = { WAIT = { 10, 24, 40, 58 }, ANCHORS = { 380, 150 }, MAX_STAGES = 3, RESET_S = 600, GAP = 3.0, MAX_STAGE_S = 70,
    key = nil, t0 = nil, seen = -1e9, rung = 0, stages = 0, stage_t = -1e9, asking = false }
N.NP = NP
local NP_SKIP = { combat = true, swim = true, astar = true, boat = true, elevator = true, portal = true, route = true }

--- Candidate anchor points along the line to the goal (and 45 yd either side of it).
function NP.candidates(hx, hy, gx, gy, yd)
    local dx, dy = gx - hx, gy - hy
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 40 then return {} end
    local f = math.min(yd, len * 0.6)
    local ux, uy = dx / len, dy / len
    local ax, ay = hx + ux * f, hy + uy * f
    local px, py = -uy * 45, ux * 45
    return { { x = ax, y = ay }, { x = ax + px, y = ay + py }, { x = ax - px, y = ay - py } }
end

local function np_stage(c, yd, why, far)
    local hx, hy, hz = R.here()
    if not hx or NP.asking then return false end
    if not far and NP.stages >= NP.MAX_STAGES then return false end
    local list = NP.candidates(hx, hy, cur.x, cur.y, yd)
    if #list == 0 then return false end
    NP.asking = true
    local id = cur.id
    local i = 0
    local function try_next()
        i = i + 1
        if cur.id ~= id or (cur.done and not far) then NP.asking = false return end
        local cand = list[i]
        if not cand then
            NP.asking = false
            NP.last_fail = R.now()
            R.trail("nav", "no path generated: no reachable anchor %.0f yd along the way (%s)", yd, tostring(why))
            return
        end
        floors_for(c, key_of(cand.x, cand.y), cand.x, cand.y, hz, function(fl)
            if cur.id ~= id or (cur.done and not far) then NP.asking = false return end
            local z = fl and fl[1]
            if not z then return try_next() end
            local pt = { x = cand.x, y = cand.y, z = z }
            local sent = S.validate(c, pt, function(ok, reason, distance)
                if cur.id ~= id or (cur.done and not far) then NP.asking = false return end
                local walk_d = tonumber(distance)
                if ok ~= true or (walk_d and walk_d > yd * 3) then
                    R.trail("nav", "no path generated: anchor (%.0f, %.0f) %s%s", pt.x, pt.y, tostring(reason or "not reachable"),
                        walk_d and string.format(" (path %.0f yd)", walk_d) or "")
                    return try_next()
                end
                NP.asking = false
                if not far then NP.stages = NP.stages + 1 end
                NP.stage_t = R.now()
                cur.done = false
                stats.np_stages = (stats.np_stages or 0) + 1
                if not N.detour(pt, string.format("no path for the whole way (%s): a staged leg, path %s yd", tostring(why),
                        walk_d and string.format("%.0f", walk_d) or "?"), { max_yd = yd + 80, max_s = NP.MAX_STAGE_S,
                        label = "staged leg" }) then
                    R.trail("nav", "no path generated: the staged leg to (%.0f, %.0f) could not start", pt.x, pt.y)
                end
            end)
            if not sent then NP.asking = false try_next() end
        end)
    end
    try_next()
    return true
end

-- 1.2.60 FAR GOALS. Log 2026-11-19 14:05-14:06 (Ironforge -> Redridge, 5389 yd): the whole-route query gets no path (Sentinel idle,
-- 8 walks, "walk loop"), and the goal's area was blacklisted. A goal NP.FAR_MIN yd away that failed so is walked in staged legs:
-- each leg an anchor NP.FAR_ANCHOR yd along the way, checked with validate_destination (reachable, path <= 3x the leg), then the
-- real goal is asked again from there. Within NP.FAR_MIN yd the whole route is asked as usual.
NP.far, NP.FAR_MIN, NP.FAR_ANCHOR, NP.FAR_S, NP.last_fail = {}, 900, 450, 900, -1e9

--- Mark the goal as far when the player is NP.FAR_MIN yd or more from it. True when marked.
function NP.far_mark(x, y, hx, hy)
    if not hx or R.dist2(hx, hy, x, y) < NP.FAR_MIN then return false end
    NP.far[key_of(x, y)] = R.now()
    return true
end

--- A goal marked far, still NP.FAR_MIN yd away: ask the next staged leg. True while a leg is asked / walked
--- (the caller does not issue the whole walk).
function NP.far_gate(c, x, y, mode)
    if mode == "combat" or NP_SKIP[mode or "move"] or det or stop_req then return false end
    if not cur.x or cur.x ~= x or cur.y ~= y then return false end
    local k = key_of(x, y)
    local t = NP.far[k]
    if not t then return false end
    local now = R.now()
    local hx, hy = R.here()
    if now - t > NP.FAR_S or not hx or R.dist2(hx, hy, x, y) < NP.FAR_MIN then NP.far[k] = nil return false end
    if NP.asking then return true end
    if now - NP.last_fail < 20 then return false end
    stats.far_stages = (stats.far_stages or 0) + 1
    return np_stage(c, NP.FAR_ANCHOR, string.format("far goal, %.0f yd", R.dist2(hx, hy, x, y)), true) == true
end

function NP.tick(c, now)
    if not cur.x or cur.done or NP_SKIP[cur.mode or "move"] or stop_req or N.holding() or det or R.turning then
        if not det then NP.t0 = nil end
        return
    end
    if not S.path_pending(c) then
        if NP.t0 and now - NP.seen > NP.GAP then NP.t0, NP.rung = nil, 0 end
        return
    end
    local key = key_of(cur.x, cur.y)
    if NP.key ~= key or now - NP.seen > NP.RESET_S then
        NP.key, NP.t0, NP.rung, NP.stages = key, nil, 0, 0
    end
    NP.seen = now
    if not NP.t0 then NP.t0 = now end
    local waited = now - NP.t0
    local next_rung = NP.rung + 1
    local need = NP.WAIT[next_rung]
    if need and UG.under[key] then need = need * 0.5 end              -- 1.2.80: an underground goal gives up at half the waits
    if not need or waited < need then return end
    NP.rung = next_rung
    stats.np_rungs = (stats.np_rungs or 0) + 1
    local px, py = R.here()
    R.trail("nav", "no path generated: Sentinel has been awaiting a path for %.0f s (rung %d), goal %.0f yd away", waited, next_rung,
        px and R.dist2(px, py, cur.x, cur.y) or -1)
    if next_rung == 1 then
        if not retry_at_ground(c, cur.id, cur.x, cur.y, cur.z, "no_path", cur.mode) then np_stage(c, NP.ANCHORS[1], "rung 1 skipped") end
    elseif next_rung == 2 then
        if not np_stage(c, NP.ANCHORS[1], "awaiting a path " .. string.format("%.0f", waited) .. " s") then NP.rung = 2 end
    elseif next_rung == 3 then
        if not np_stage(c, NP.ANCHORS[2], "awaiting a path " .. string.format("%.0f", waited) .. " s") then NP.rung = 3 end
    else
        stats.np_giveups = (stats.np_giveups or 0) + 1
        record_fail("no_path", cur.x, cur.y, cur.z, false)
        Z.blacklist_area({ x = cur.x, y = cur.y, z = cur.z }, 8, "no path generated in " .. string.format("%.0f", waited) .. " s")
        R.trail("nav", "no path generated for %.0f s - giving the goal (%.0f, %.0f) up for a while", waited, cur.x, cur.y)
        NP.t0, NP.rung = nil, 0
        N.stop("no path generated", true)   -- forced: a walk that awaits its path is otherwise stopped "later"
    end
end

function LA.tick(c)
    local now = R.now()
    if now - LA.last_t < LA.GAP then return end
    LA.last_t = now
    if not cur.x or cur.done or LA_SKIP[cur.mode or "move"] or det or stop_req or N.holding() or R.turning
        or not S.moving(c) then
        LA.pos, LA.still_t, LA.still_logged = nil, nil, false
        return
    end
    local px, py = R.here()
    if not px then return end
    -- walking speed (only while actually moving) and a stall log: the player stands on a running walk
    if LA.pos and now > LA.pos_t then
        local v = R.dist2(px, py, LA.pos.x, LA.pos.y) / (now - LA.pos_t)
        if v > 1 and v < 40 then LA.speed = LA.speed * 0.8 + v * 0.2 end
        if v < 0.5 then
            LA.still_t = LA.still_t or now
            if not LA.still_logged and now - LA.still_t >= 0.6 then
                LA.still_logged = true
                stats.stalls = (stats.stalls or 0) + 1
                R.trail("nav", "stall: standing %.1f s on a running walk - state %s, leg %.1f s old, mode %s, last ask: %s",
                    now - LA.still_t, tostring(S.full_state(c)), now - (cur.leg_t or now), tostring(cur.mode),
                    tostring(LA.last_ask or "-"))
            end
        else
            LA.still_t, LA.still_logged = nil, false
        end
    end
    LA.pos, LA.pos_t = { x = px, y = py }, now
    pcall(NP.tick, c, now)          -- 1.2.57: a path that never comes
    if LA.id ~= cur.id then
        LA.id, LA.lat_done = cur.id, false
        LA.ref_t, LA.ref_x, LA.ref_y = cur.t, px, py          -- 1.2.20: the rolling re-plan measures progress from the walk's start
    end
    if S.path_pending(c) then return end
    -- 1.2.12: an audited-prefix segment is a short path BY DESIGN (it ends before a steep span) and its own
    -- finish handler plans the next one. The horizon used to see "12 yd of path left, want 20" at once and
    -- replace the segment mid-walk (log 17:31:58-17:32:53: a new path every 1-2 s, 21 + 12 + 3 yd walked).
    if cur.prefix_id == cur.id then return end
    if not LA.lat_done then
        LA.lat_done = true
        LA.latency = LA.latency * 0.7 + math.max(0, math.min(5, now - cur.t)) * 0.3
    end
    local fs = S.full_state(c) or ""
    if fs:find("recovering", 1, true) or fs:find("repathing", 1, true) then return end
    local goal_d = R.dist2(px, py, cur.x, cur.y)
    if goal_d < LA.MIN_GOAL or not replaceable(c) then return end
    -- 1.2.13 ROLLING RE-PLAN: a long walk is planned again from where the player stands every REFRESH_S seconds, whatever
    -- path is left, so a plan that went stale (a door, a steep span met on the way, a stuck stretch) never leaves the
    -- player on a dead path. Not for a short remainder, and not while the walk is only a few seconds old.
    if goal_d >= LA.REFRESH_YD and (now - (LA.ref_t or cur.t or now)) >= LA.REFRESH_S then
        -- 1.2.20: a walk that is getting somewhere is left alone. Replacing a healthy walk every 25 s made Sentinel stop and
        -- "recover" each time (log 18:50-18:58); only a walk that moved under REFRESH_MOVED yd in REFRESH_S s is planned again.
        local rx, ry = LA.ref_x, LA.ref_y
        local moved = rx and R.dist2(px, py, rx, ry) or 0
        local age = now - (LA.ref_t or cur.t or now)
        LA.ref_t, LA.ref_x, LA.ref_y = now, px, py
        if rx and moved >= LA.REFRESH_MOVED then return end
        LA.n = 0
        stats.refreshes = (stats.refreshes or 0) + 1
        R.trail("nav", "rolling re-plan: %.0f yd to the goal, only %.0f yd covered in %.0f s - planning again from here", goal_d, moved, age)
        LA.last_ask = "rolling re-plan"
        walk_again(c, { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }, "rolling re-plan")
        return
    end
    local key = key_of(cur.x, cur.y)
    if LA.key ~= key or now - LA.chain_t > LA.CHAIN_S then LA.key, LA.n, LA.goal_d = key, 0, nil end
    if LA.n >= LA.MAX then return end
    if LA.goal_d and goal_d > LA.goal_d - LA.PROGRESS then return end      -- no progress since the last ask
    local left, last = LA.path_left()
    local H = LA.horizon()
    if cur.pre_partial == cur.id then H = math.max(H, LONG.PARTIAL_H) end   -- 1.2.75: a partial path is extended 150 yd before its end
    if not left or left >= H then return end
    if R.dist2(last.x, last.y, cur.x, cur.y) <= LA.SHORT_YD then return end   -- the path reaches the goal
    LA.n, LA.goal_d, LA.chain_t = LA.n + 1, goal_d, now
    stats.horizon = (stats.horizon or 0) + 1
    R.trail("nav", "horizon: %.0f yd of path left (want %.0f: speed %.1f, latency %.2f s), goal %.0f yd away - next path requested while walking",
        left, H, LA.speed, LA.latency, goal_d)
    LA.last_ask = "path horizon"
    N._splice_req = { x = cur.x, y = cur.y, t = now }      -- 1.2.75: the next stretch is spliced onto the running path
    walk_again(c, { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }, "path horizon")
end

function N.pulse()
    -- 1.2.88: a fight pauses a travel walk (its route kept); nothing here starts one in combat (start_blocked)
    do
        local cc = N.client()
        if cc and cur.x and not cur.done and TRAVEL[cur.mode or "move"] and not cur.route and CP.in_fight() and S.moving(cc)
            and not S.path_pending(cc) and (R.now() - (cur.leg_t or 0)) >= FRESH_LEG then
            CP.save(cc, "combat started")
            N.stop("combat pause")
        end
    end
    pre_watch()
    hint_tick()
    do local cpf = N.client() if cpf then pcall(pf_tick, cpf) end end        -- 1.2.77
    ps_report(R.now())
    pcall(LA.tick, N.client())
    -- death or a loading screen flagged by the event callback: the walk stops
    -- here, on the update tick (Sentinel does not stop on death / loading)
    local nf = event_flags()
    if nf and nf.stop then
        local why = nf.stop
        nf.stop = nil
        held.reasons, held.dest = {}, nil
        N.stop(why)
        R.trail("nav", "walk stopped: %s", why)
    end
    local c = N.client()
    if not c then return end
    local blocked = S.request_blocked(c)
    if blocked then
        -- 1.67.0: do not stop a running walk on 414. Oversized zone / check_path
        -- payloads stay gated; travel (move_to / replan) continues.
        if request_warned ~= blocked then request_warned = blocked R.log(blocked) end
        if not N.leg_fresh() and not S.moving(c) and S.recover_request(c) then
            request_warned = nil
            R.log("Sentinel avoidance request rebuilt; resuming guide travel")
        end
    else
        request_warned = nil
        N.restore_stuck_zones()
        N.flush_avoidance(c)
        check_running_path(c, R.now())            -- 1.40.0: the running path validated
        -- 1.67.0: a partial path_received means the mesh stopped short - ask
        -- the floors at the dest once so the next issue_walk is at ground.
        local info = S.path_info()
        if info and info.partial == true and cur.x and not cur.done
            and cur.mode ~= "combat" and not preserve_height(cur.mode) and cur.partial_id ~= cur.id
            and (info.t or 0) >= (cur.t or 0) then
            cur.partial_id = cur.id
            local pk = key_of(cur.x, cur.y)
            if not zfix[pk] and not swimming() then
                R.trail("nav", "path_received partial to (%.0f, %.0f) - asking floors", cur.x, cur.y)
                walk_at_floor(c, cur.x, cur.y, cur.z or 0, cur.mode or "move")
            end
        end
    end
    if stop_req then
        if not S.moving(c) and not S.path_pending(c) then
            stop_req = nil
        -- audit 1.19.0: never while the path request is in flight (port guide
        -- rule 5); a timeout never bypasses the safe stop conditions
        elseif not S.path_pending(c) and ((R.now() - (cur.leg_t or 0)) >= FRESH_LEG) then
            S.stop(c)
            R.trail("nav", "deferred stop sent (%s)", tostring(stop_req.reason))
            stop_req = nil
        end
    end
    -- a walk of ours that Sentinel ended without a callback (its UI stopped it,
    -- another consumer took over): closed here
    if cur.x and not cur.done and not cur.scanning and (R.now() - cur.t) >= LOST_WALK then
        local st = S.state(c)
        if st == "idle" or st == "arrived" then
            cur.done = true
            R.trail("nav", "walk to (%.0f, %.0f) ended without a callback (state %s)", cur.x, cur.y, st)
        elseif st == "failed" then
            cur.done = true
            record_fail("failed", cur.x, cur.y, cur.z)
        end
    end
    -- 1.7.23: a detour leg that ended (any way) or took too long: the goal again
    if det and (cur.done or R.now() > det.until_t) then
        detour_done(cur.done and "ended" or "took too long")
    end
    -- 1.9.0: the memory loads with the first client; a walk past a black
    -- point counts; changed snapshots are written (every 10 s at most)
    MEM.load()
    if cur.mode ~= "combat" and S.moving(c) then MEM.tick(R.here()) end
    MEM.flush()
end

-- ----------------------------------------------------------------------------
-- failures
-- ----------------------------------------------------------------------------
function N.last_fail_reason() return fail.reason end
--- 1.20.1: the last walk to `pos` ended "arrived" up to SHORT_OK yd short of it (the
--- navmesh ends there) within SHORT_HOLD s - as close as Sentinel can get.
function N.reached_short(pos)
    local x, y = R.xyz(pos)
    if x and AS.for_goal(pos) then return false end                     -- 1.30.0: the local walk runs
    return x ~= nil and short.key == key_of(x, y) and (R.now() - short.t) < SHORT_HOLD
end
function N.last_fail_offmesh() return fail.offmesh == true end
function N.clear_fail() fail.reason, fail.offmesh = nil, false end

--- A walk is being planned or its floors are being asked for - not a stand
--- (quest/engine's route watchdog waits for it).
function N.pending()
    if AS.searching() then return true end                -- 1.30.0: the local A* search (the player stands)
    local c = N.client()
    if c and cur.x and not cur.done and S.path_pending(c) then return true end
    return cur.scanning ~= nil and cur.scanning == cur.id and (R.now() - (cur.scan_t or 0)) < HEIGHT_SCAN_HOLD
end

--- A failure reason that is the server's, not the place's.
function N.server_trouble(code) return SERVER_CODES[code] == true end

-- ----------------------------------------------------------------------------
-- reachability (validate_destination, cached; never blocks the caller)
-- ----------------------------------------------------------------------------
local reach, reach_n, reach_next = {}, 0, 0

--- false only once Sentinel said "not reachable" (also at the floors there);
--- true while pending, unknown, far, or with no server.
function N.reachable(pos)
    local x, y, z = R.xyz(pos)
    if not x then return true end
    local hx, hy = R.here()
    local far = not hx or R.dist2(hx, hy, x, y) > REACH_TRUST_FAR
    local k = key_of(x, y)
    local t = R.now()
    local e = reach[k]
    if e and (t - e.t) < ((e.ok == false) and REACH_TTL_BAD or REACH_TTL) then
        return e.ok ~= false or far
    end
    local c = N.client()
    if not c or t < reach_next then return true end
    reach_next = t + REACH_GAP
    if reach_n > 300 then reach, reach_n = {}, 0 end
    if not e then reach_n = reach_n + 1 end
    e = { ok = nil, t = t, z = nil }
    reach[k] = e
    S.validate(c, { x = x, y = y, z = z }, function(ok)
        e.t = R.now()
        if ok == true then e.ok = true return end
        if far then e.ok = true return end
        -- the height may be the guess: ask at the floors there before saying no
        floors_for(c, k, x, y, z, function(list)
            local gz = nil
            for i = 1, #list do if math.abs(list[i] - z) > HEIGHT_SAME then gz = list[i] break end end
            if not gz then e.ok, e.t = false, R.now() return end
            S.validate(c, { x = x, y = y, z = gz }, function(ok2)
                e.ok, e.t = ok2 == true, R.now()
                if ok2 == true then e.z = gz cache_put(zfix, "zfix", k, gz) end
            end)
        end)
    end)
    return true
end

function N.node_reachable(pos) return N.reachable(pos) end

--- The ground height found at (x, y) when the given one was wrong, or nil.
function N.reach_z(pos)
    local x, y = R.xyz(pos)
    if not x then return nil end
    local z = zfix[key_of(x, y)]
    if R.finite(z) then return z end
    return nil
end

function N.reach_forget(pos)
    local x, y = R.xyz(pos)
    if not x then return end
    local k = key_of(x, y)
    if reach[k] then reach[k] = nil end
end

--- One path query for movement/sight and the stuck fan: cb(points|nil, ok,
--- info). False when there is no client to ask.
function N.path_probe(from, to, cb)
    local c = N.client()
    if not c then return false end
    -- 1.2.79b (log 17:16: `sn_plan_route x1` every second for 8-10 s while a plan to the same goal had no reply): a probe is one
    -- more path query for the server to chew on; none is sent while a plan of ours is unanswered or Sentinel awaits its path
    local pre = cur.pre
    if S.path_pending(c) or (pre and pre.id == cur.id and pre.planning and not pre.started and not pre.done) then
        stats.probes_held = (stats.probes_held or 0) + 1
        return false
    end
    return S.find_path(c, R.point(from), R.point(to), cb)
end

--- validate_destination through the adapter. cb(reachable, reason, distance).
function N.validate(pos, cb)
    local c = N.client()
    if not c or type(cb) ~= "function" then return false end
    local p = R.point(pos)
    if not p then return false end
    return S.validate(c, p, cb)
end

--- 1.67.0: navmesh raycast (nav_client:raycast). cb(ok, hit, t). False when
--- the client has no raycast.
function N.raycast(from, to, cb)
    local c = N.client()
    if not c or type(cb) ~= "function" then return false end
    local a, b = R.point(from), R.point(to)
    if not a or not b then return false end
    return S.raycast(c, a, b, cb)
end

--- The height found at (x, y) is this floor: skip a second get_all_heights.
function N.remember_floor(x, y, z)
    z = tonumber(z)
    if not x or not y or not z then return end
    cache_put(zfix, "zfix", key_of(x, y), z)
end

--- false until validate_destination (and its floor retry) has answered.
function N.reach_settled(pos)
    local x, y = R.xyz(pos)
    if not x then return true end
    local e = reach[key_of(x, y)]
    return e ~= nil and e.ok ~= nil
end

--- 1.67.0: plan_route then follow_path of the ordered nodes (not start_route,
--- which is unrecorded on v0.24). True while the plan is in flight or the
--- route is walking.
local node_job = { key = nil, pending = false }
-- 1.2.71 (log 15:51-15:56, 4 minutes standing at "patrolling for Redridge Mystic, Redridge Brute (7 points)", 0 walks issued, 0
-- refused): follow_nodes sets node_job.pending while its plan_route is in flight and clears it in the reply. A stop in between
-- (N.stop -> S.invalidate) makes the reply guard DROP that reply, so pending stayed true for ever and every later follow_nodes
-- answered "already planning" - the engine patrolled nothing. A stop now clears the job, and a plan unanswered for NODE_WAIT s
-- is given up (asked again).
local NODE_WAIT = 8.0
function N._node_reset() node_job.key, node_job.pending, node_job.retry_at = nil, false, nil end
function N.follow_nodes(list)
    if type(list) ~= "table" or #list < 2 then return false end
    if N.refusal() then return false end
    local c = N.client()
    if not c then return false end
    local nodes = {}
    for i = 1, #list do
        local x, y, z = R.xyz(list[i])
        if not x then return false end
        nodes[i] = { x = x, y = y, z = z }
    end
    local last = nodes[#nodes]
    local key = string.format("%d|%d|%d|%d", #nodes, math.floor(last.x), math.floor(last.y), math.floor(nodes[1].x))
    if node_job.key == key and node_job.retry_at and R.now() < node_job.retry_at then return false end
    if node_job.pending and node_job.t and R.now() - node_job.t > NODE_WAIT then
        node_job.pending = false
        R.trail("nav", "patrol plan: no reply in %.0f s - asking again", NODE_WAIT)
    end
    if node_job.key == key and (node_job.pending or (cur.route and S.moving(c))) then
        return true
    end
    if N.holding() then
        held.dest = { nodes = nodes }
        node_job.key, node_job.pending = key, false
        return true
    end
    node_job.key, node_job.pending, node_job.retry_at, node_job.t = key, true, nil, R.now()
    local ok = S.plan_route(c, nodes, function(okp, data)
        if node_job.key ~= key then return end
        node_job.pending = false
        if not okp or type(data) ~= "table" or type(data.waypoints) ~= "table"
            or #data.waypoints < 2 then
            node_job.retry_at = R.now() + 5
            record_fail("no_planned_path")
            R.trail("nav", "route refused: planning returned no walkable waypoints")
            return
        end
        if not N.follow_route(data.waypoints, true) then node_job.retry_at = R.now() + 5 end
    end)
    if not ok then
        node_job.pending, node_job.retry_at = false, R.now() + 5
        record_fail("no_planned_path")
        return false
    end
    return true
end
N.plan_and_follow = N.follow_nodes

--- 1.67.0: walk a scored path as the stuck detour (follow_path), then the
--- real goal. Falls back to a single-point detour when the list is short.
function N.detour_path(pts, why)
    if type(pts) ~= "table" or #pts < 2 then
        local p = type(pts) == "table" and pts[#pts] or pts
        return N.detour(p, why)
    end
    local c = N.client()
    if not c or not cur.x then return false end
    if start_blocked(c, cur.mode) or R.turning then return false end
    local dest = { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }
    local list = {}
    for i = 1, #pts do
        local x, y, z = R.xyz(pts[i])
        if x then list[#list + 1] = { x = x, y = y, z = z } end
    end
    if #list < 2 then return N.detour(pts[#pts], why) end
    if N.steep_at(list) then return false end
    local endp = list[#list]
    local hx, hy = R.here()
    if not hx or R.dist2(hx, hy, endp.x, endp.y) > DETOUR_MAX_YD then return false end
    cur.id = cur.id + 1
    local id = cur.id
    cur.route, cur.done = nil, false
    cur.t, cur.leg_t = R.now(), R.now()
    stop_req = nil
    cur.scanning = nil
    stats.issued = stats.issued + 1
    det = { x = endp.x, y = endp.y, z = endp.z, dest = dest, id = id, until_t = R.now() + DETOUR_MAX_S }
    R.trail("nav", "stuck re-navigation: detour path %d pts to (%.0f, %.0f) - %s", #list, endp.x, endp.y, tostring(why))
    local ok = S.follow_path(c, list, function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        if not det or det.id ~= id then return end
        detour_done(success and "reached" or tostring(reason))
    end)
    if not ok then det, cur.done = nil, true return false end
    return true
end

function N.nav_ready()
    local c = N.client()
    return c ~= nil and S.server_up(c)
end

--- 1.12.0 KITE: a ranged retreat point from Sentinel's nav_client:kite (a path
--- round the target at KITE.RADIUS yd; the walk goes to its last point).
--- cb(point | nil). The FIRST answer of an unexpected shape switches kiting
--- off for the session (logged with what came back) - the call was read from
--- the v0.0.6 source, so its v0.24 answer is checked live. True when asked.
local KITE = { RADIUS = 15, off = false, said = false }
N.KITE = KITE
function N.kite(from, target, cb)
    if KITE.off then return false end
    local c = N.client()
    if not c then return false end
    return S.kite(c, R.point(from), R.point(target), KITE.RADIUS, function(pts, ok, info)
        if info and info.shape_bad then
            KITE.off = true
            if not KITE.said then
                KITE.said = true
                R.log("Sentinel kite answered in an unknown shape (" .. tostring(info.got) .. ") - kiting off for this session")
            end
            pcall(cb, nil)
            return
        end
        local last = pts and pts[#pts] or nil
        local x, y, z                          -- (not `last and R.xyz(last)`: that keeps one value)
        if last then x, y, z = R.xyz(last) end
        if x then
            stats.kites = (stats.kites or 0) + 1
            pcall(cb, { x = x, y = y, z = z })
        else
            if info and info.error then R.trail("nav", "kite: no point (%s)", info.error) end
            pcall(cb, nil)
        end
    end)
end

--- 1.16.0 FLEE (improvement 3 of the API-dump review): a path AWAY from every
--- threat from Sentinel's nav_client:flee, FLEE.DISTANCE yd long. cb(point |
--- nil) - the path's last point. Like kite, the first answer of another shape
--- switches fleeing off for the session (logged). True when asked.
local FLEE = { DISTANCE = 30, off = false, said = false }
N.FLEE = FLEE
function N.flee(from, threats, cb)
    if FLEE.off or type(threats) ~= "table" or #threats < 1 then return false end
    local c = N.client()
    if not c then return false end
    local list = {}
    for i = 1, #threats do list[#list + 1] = R.point(threats[i]) end
    return S.flee(c, R.point(from), list, FLEE.DISTANCE, function(pts, ok, info)
        if info and info.shape_bad then
            FLEE.off = true
            if not FLEE.said then
                FLEE.said = true
                R.log("Sentinel flee answered in an unknown shape (" .. tostring(info.got) .. ") - fleeing off for this session")
            end
            pcall(cb, nil)
            return
        end
        local last = pts and pts[#pts] or nil
        local x, y, z
        if last then x, y, z = R.xyz(last) end
        if x then
            stats.flees = (stats.flees or 0) + 1
            pcall(cb, { x = x, y = y, z = z })
        else
            if info and info.error then R.trail("nav", "flee: no point (%s)", info.error) end
            pcall(cb, nil)
        end
    end)
end

--- 1.16.0 LIVE SENTINEL STATUS (improvements 5 and 11): the walk's progress,
--- the recorded route's progress, the distance to the destination, the
--- avoidance zone count and the consecutive path failures. Read at most every
--- STATUS.GAP s, on the update tick only (movement.lua's snapshot) - the GUI
--- reads the cached table. nil without a client.
local STATUS = { GAP = 0.5, t = -1e9, v = nil }
function N.status()
    local now = R.now()
    if (now - STATUS.t) < STATUS.GAP then return STATUS.v end
    STATUS.t = now
    local c = N.client()
    if not c then STATUS.v = nil return nil end
    local v = { progress = S.progress(c), route = S.route_progress(c), zones = S.zone_count(c),
        failures = S.failures(c), state = S.state(c) }
    local d = S.destination(c)
    local hx, hy, hz = R.here()
    if d and hx then v.dest_yd = R.dist3(hx, hy, hz, d.x, d.y, tonumber(d.z) or hz) end
    STATUS.v = v
    return v
end

--- One line for the GUI from a status table (no game call).
function N.status_text(v)
    if type(v) ~= "table" then return nil end
    local parts = {}
    local pr = v.progress
    if v.state == "navigating" and pr and pr.total and pr.total > 0 then
        parts[#parts + 1] = string.format("%.0f%% (wp %d/%d)", pr.percent or 0, pr.index or 0, pr.total)
    end
    if v.dest_yd then parts[#parts + 1] = string.format("%.0f yd to go", v.dest_yd) end
    if v.route and v.route.percent then parts[#parts + 1] = string.format("route %.0f%%", v.route.percent) end
    if v.zones and v.zones > 0 then parts[#parts + 1] = string.format("%d zone%s", v.zones, v.zones == 1 and "" or "s") end
    if v.failures and v.failures > 0 then parts[#parts + 1] = string.format("%d failed path%s", v.failures, v.failures == 1 and "" or "s") end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- ----------------------------------------------------------------------------
-- built-in grind zones (not recorded paths): a short visiting order
-- ----------------------------------------------------------------------------
local plan = { src = nil, order = nil, pending = false }

function N.plan_grind_route(coords)
    if type(coords) ~= "table" or coords == plan.src or plan.pending then return end
    local c = N.client()
    if not c then return end
    local nodes = {}
    if type(coords[1]) == "number" then
        for i = 1, math.floor(#coords / 3) do
            local k = (i - 1) * 3
            nodes[i] = { x = coords[k + 1], y = coords[k + 2], z = coords[k + 3] }
        end
    else
        for i = 1, #coords do nodes[i] = R.point(coords[i]) or { x = 0, y = 0, z = 0 } end
    end
    plan.src, plan.order, plan.pending = coords, nil, true
    local ok = S.plan_route(c, nodes, function(okp, res)
        plan.pending = false
        if okp and type(res) == "table" and type(res.visit_order) == "table" then plan.order = res.visit_order end
    end)
    if not ok then plan.pending = false end
end

function N.grind_visit_order() return plan.order end

-- tests
-- ----------------------------------------------------------------------------
-- 1.11.0 AVOID AREAS (user: never walk into the threat range of a mob 3+ levels
-- above the player or an elite - "path-threat avoidance through Sentinel
-- avoidance zones + soft re-path"). N.avoid_area(pos, radius, why): a
-- Sentinel avoidance zone of `radius` yd there (S.add_zone - every path
-- request after it plans round it) and a SOFT re-path of the walk that runs
-- (S.soft_replan - no stop), at most one re-path every AV.REPLAN_GAP s. A spot
-- already zoned (within AV.SAME yd) is trusted for 110 seconds, below the
-- default 120-second lifetime. The adapter caps admissions over 125 seconds.
-- ----------------------------------------------------------------------------
local AV = { zones = {}, replan_t = -1e9, REPLAN_GAP = 3.0, SAME = 4.0, TTL = 110, dirty = false }
N.AV = AV

function N.avoided(x, y)
    local t = R.now()
    for i = #AV.zones, 1, -1 do
        local z = AV.zones[i]
        if (t - z.t) > AV.TTL then table.remove(AV.zones, i)
        elseif R.dist2(z.x, z.y, x, y) <= AV.SAME then return true end
    end
    return false
end

function N.avoid_area(p, radius, why)
    local x, y, z = R.xyz(p)
    if not x then return false end
    if N.avoided(x, y) then return true end
    if #AV.zones >= S.ZONE_LIMIT then return false end
    local c = N.client()
    if not c or not S.add_zone(c, { x = x, y = y, z = z }, radius) then return false end
    AV.zones[#AV.zones + 1] = { x = x, y = y, t = R.now(), r = radius }
    stats.zones = (stats.zones or 0) + 1
    AV.dirty = true
    R.trail("nav", "avoid %s: Sentinel zone %.0f yd at (%.0f, %.0f); replan pending", tostring(why), radius, x, y)
    -- 1.67.0: the next path request must include the zone. replan(reason)
    -- now (recorded equivalent of avoid-and-generate); FRESH_LEG still
    -- protects a walk waiting for its first path.
    N.flush_avoidance(c)
    return true
end

-- Reapply persisted black points after reload and after Sentinel's zone TTL.
-- Wait until outside the disk so avoidance cannot enclose the escaping player.
local restore_t = -1e9
function N.restore_stuck_zones()
    local t = R.now()
    if t - restore_t < 2 or type(MEM.active_points) ~= "function" then return end
    restore_t = t
    local x,y,z = R.here()
    if not x then return end
    for _, r in ipairs(MEM.active_points()) do
        local d = R.dist2(x,y,r.cx,r.cy)
        local radius = math.max(6,r.radius)
        if d > radius + 2 and d < 120 and math.abs((z or 0)-r.cz) <= 8 then
            N.avoid_area({x=r.cx,y=r.cy,z=r.cz},radius,"saved stuck position")
        end
    end
end

-- Batch all zones observed in a scan into one paced replan on the next pulse.
function N.flush_avoidance(c)
    if not AV.dirty or cur.mode == "combat" or stop_req or next(held.reasons) or R.resting then return end
    local t = R.now()
    if not cur.x or cur.done or not S.moving(c) or S.path_pending(c)
        or t - (cur.leg_t or t) < FRESH_LEG or t - AV.replan_t < AV.REPLAN_GAP then return end
    AV.replan_t = t
    if S.soft_replan(c, "mf_path_threat") then
        AV.dirty = false
        stats.soft_replans = (stats.soft_replans or 0) + 1
    end
end

function N._reset()
    cur = { id = 0, x = nil, y = nil, z = nil, mode = nil, t = 0, route = nil, done = false }
    fail = { reason = nil, offmesh = false, t = 0 }
    fails_at, zfix, zscan, reach, reach_n = {}, {}, {}, {}, 0
    cache_n = { fails = 0, zfix = 0, zscan = 0 }
    stop_req, held, det = nil, { reasons = {}, dest = nil }, nil
    warned = nil
    short.key, short.t = nil, -1e9                                      -- 1.20.1
    node_job = { key = nil, pending = false }
    AV.zones, AV.replan_t, AV.dirty = {}, -1e9, false
    check_t, check_logged, check_replan = -1e9, false, nil
    AS.reset()                                                          -- 1.30.0
end

return N
