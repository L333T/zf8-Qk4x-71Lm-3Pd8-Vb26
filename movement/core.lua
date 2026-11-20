-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/core.lua - shared state and helpers of the movement layer
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- 3.0.0 MOVEMENT RECODE (1.10.0: on Sentinel Navigation). Every walk is the
-- Sentinel client's (_G.SentinelNavClient.client, reached only through the
-- adapter movement/sentinel.lua and looked up at use time in movement/nav.lua):
-- it paths on the navmesh, steers, avoids objects and recovers from being
-- stuck. This layer only decides WHERE to go and WHEN to stand still; it never
-- drives simple_movement while a Sentinel walk runs. It casts no ray of its own.
--
-- Modules (all small, one job each):
--   core    shared state R, positions, distances, logging
--   zones   blacklisted areas and danger circles (pure bookkeeping)
--   nav     Sentinel travel: move_to / follow_path / stop / holds,
--           failures, reachability cache, route-height fix
--   combat  closing on a target and standing in range (Sentinel seamless
--           re-paths), retreat (nav_client:kite), flee, the in-position latch
--   locks   rest / cast / channel / loot holds, backpedal
--   range   facing, line of sight, arrival and fight range
--   leash   the recorded-path corridor path_runner keeps to
--   sight   reachable / underground / in sight from the navmesh (no ray)
-- ============================================================================

local R = {}

R.TAG = "[Master Farmer - Zygor Forever]"

-- ONE TERRAIN MODEL (ported from Forever Questing 1.29.0). Every slope / step / clearance /
-- drop number the movement layer judges a path by lives here, so the plan audit (nav.lua),
-- the local A* (astar.lua) and the ray helpers (trace.lua) cannot disagree.
-- rise / run are in yd per yd. UP_LOCAL is deliberately below UP: the local A* builds its own
-- path on unproven ground, the audit only judges Sentinel's.
R.TERRAIN = {
    UP = 0.9,            -- steepest climb accepted outdoors (~42 deg)
    UP_IN = 1.1,         -- ... indoors (stairs)
    DOWN = 1.0,          -- steepest descent (~45 deg)
    STEP_DZ = 2.0,       -- a climb / drop this big inside MIN_RUN is a wall, not a step
    MIN_RUN = 1.0,
    UP_LOCAL = 0.6,      -- the local A* step rule
    KNEE = 0.9, CHEST = 1.8, HEAD = 2.2,   -- ray heights above the feet
    HALF_W = 0.35,       -- half the on-foot body width
    BODY_W = 0.7,        -- on-foot body width (2 * HALF_W)
    MOUNT_W = 1.6,       -- mounted body width (an estimate)
    DROP_MAX = 6.0,      -- yd of fall still accepted behind a hop
    EDGE_DROP = 4.0,     -- ground this far below the path within EDGE_SIDE yd sideways = a ledge
    EDGE_SIDE = 1.5,
}

-- shared runtime state (one table; modules read and write their own keys)
R.debug_on = false
R.resting = false
R.quiet_until = 0            -- a stop just happened: callers wait (is_quiet)
R.last_spell_id, R.last_spell_target, R.last_spell_t = nil, nil, 0

local sqrt = math.sqrt
local LIMIT = 20000

function R.now()
    local ok, t = pcall(core.time)
    if ok and type(t) == "number" then return t end
    return 0
end

local function finite(n)
    return type(n) == "number" and n == n and n > -LIMIT and n < LIMIT
end
R.finite = finite

--- x, y, z of a vec3, a {x,y,z} table or a positional {x, y, z} row; nil when
--- any is missing or not finite.
function R.xyz(p)
    if p == nil then return nil end
    local ok, x, y, z = pcall(function()
        local a, b, c = p.x, p.y, p.z
        if a == nil and type(p) == "table" then a, b, c = p[1], p[2], p[3] end
        return a, b, c
    end)
    if not ok or not finite(x) or not finite(y) or not finite(z) then return nil end
    return x, y, z
end

function R.point(p)
    local x, y, z = R.xyz(p)
    if not x then return nil end
    return { x = x, y = y, z = z }
end

--- The local player (valid) or nil.
function R.me()
    local ok, p = pcall(function() return core.object_manager.get_local_player() end)
    if not ok or not p then return nil end
    local okv, v = pcall(p.is_valid, p)
    if okv and v == false then return nil end
    return p
end

--- Leave a Shaman's facing and combat movement alone throughout a cast.
-- Includes manually started heals; checking every cast avoids name/rank gaps.
function R.shaman_casting()
    local p = R.me()
    if not p then return false end
    local ok, active = pcall(function()
        return p:is_valid() == true and p:get_class() == 7
            and (p:is_casting_spell() == true or p:is_channelling_spell() == true)
    end)
    return ok and active == true
end

--- The player's x, y, z or nil.
function R.here()
    local me = R.me()
    if not me then return nil end
    local ok, pos = pcall(me.get_position, me)
    if not ok then return nil end
    return R.xyz(pos)
end

function R.dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

function R.dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return sqrt(dx * dx + dy * dy + dz * dz)
end

--- Is `u` a live game object (valid, not dead)?
function R.alive(u)
    if u == nil then return false end
    local okv, v = pcall(u.is_valid, u)
    if not okv or v ~= true then return false end
    local okd, d = pcall(u.is_dead, u)
    return not (okd and d == true)
end

function R.guid(u)
    if u == nil then return nil end
    local ok, g = pcall(u.get_guid, u)
    if ok then return g end
    return nil
end

-- ----------------------------------------------------------------------------
-- logging: errorlog trail (always) and the debug console (move_debug on)
-- ----------------------------------------------------------------------------
local el = nil
function R.trail(tag, fmt, ...)
    if el == nil then
        local ok, m = pcall(require, "errorlog")
        el = (ok and type(m) == "table" and type(m.trail) == "function") and m or false
    end
    if el then pcall(el.trail, tag, fmt, ...) end
end

function R.log(text)
    pcall(require("actlog").console, R.TAG .. " " .. tostring(text))
end

function R.dlog(tag, text)
    if not R.debug_on then return end
    pcall(function() require("actlog").event("nav", "debug", "[" .. tostring(tag) .. "] " .. tostring(text)) end)
end

-- ONE RAY-HEALTH FLAG (1.2.68). The local A* (astar.lua) and the ray helpers (trace.lua) both cast game rays
-- (core.graphics.trace_line). A failed self-check or a trace_line / height error is the CLIENT, not the place: every ray user
-- must stop together (auto_bg 2.54.0 - two independent switches kept one module casting after the other had seen the client
-- fail, the 10-27 mid-match native crash). Both modules count their errors here and read ray_ok() before any ray.
R.RAY = { dead = false, why = nil, errors = 0, LIMIT = 3 }
function R.ray_ok() return R.RAY.dead ~= true end
--- A failed call (a ray or a height query). True when this error switched every ray user off.
function R.ray_error(what)
    local r = R.RAY
    r.errors = r.errors + 1
    if r.errors >= r.LIMIT and not r.dead then
        R.ray_kill(tostring(what) .. " calls fail (" .. r.errors .. " errors, all ray users)")
        return true
    end
    return r.dead
end
--- Switch every ray user off for the session (a failed self-check, no collision flags, too many errors). Logged once.
function R.ray_kill(why)
    local r = R.RAY
    if r.dead then return end
    r.dead, r.why = true, tostring(why)
    if R.log then R.log("Ray users (A* and ray helpers) switched off for this session: " .. r.why) end
    if R.trail then R.trail("ray", "all ray users off: %s", r.why) end
end
--- Test / reload: healthy again.
function R.ray_reset() R.RAY.dead, R.RAY.why, R.RAY.errors = false, nil, 0 end

return R
