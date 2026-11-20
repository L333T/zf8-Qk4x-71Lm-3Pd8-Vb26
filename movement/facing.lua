-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/facing.lua - combat enemy facing with the Movement Handler (1.2.81)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.2.81
-- ============================================================================
-- (user: "create combat enemy facing logic using this API" - common/utility/movement_handler, colon API, all declared on the live
-- stub: look_at_target / look_at_position / unlock_look_at / pause_movement_light / on_render / get_state.)
--
-- The Movement Handler is the combat micro-adjustment tool: it locks the camera / facing onto a target for a number of seconds and
-- can hold movement for a cast. It sends NO movement key. Until now the product turned onto a target with a Simple Movement
-- "face" walk (movement/front.lua: a 1.2 yd walk toward the target = key presses, one per second at most). F.face now asks this
-- module first; the old walk stays only as the fallback when the handler cannot be loaded.
--
-- WHEN IT FACES (all checked here, nothing is cast, nothing moves the player to a place):
--   * only in a fight the caller already decided is on (movement/combat + the quest engine call F.face when the target is in range);
--   * the target is alive, attackable, within FACE_RANGE yd; the player is not resting and not backpedalling (kiting owns the keys);
--   * the target is more than TURN_DEG off the player's facing, OR the client just refused a swing / cast for facing
--     ("Target needs to be in front of you", "You are facing the wrong way": events.face_error_since) - then at once, any angle;
--   * a lock is not asked again while the same target's lock still has more than REFRESH seconds to run (no spam), and never faster
--     than GAP seconds;
--   * the lock length follows the turn: LOCK_MIN s for a small correction up to LOCK_MAX s for a half turn; a cast of a known cast
--     time asks for cast_time + 0.2 s (FA.for_cast: the handler's "safe cast" recipe), a light movement pause included when the
--     player is still moving.
--   WHO IT FACES: the fight's target when it is valid; when it is not (dead, gone) the nearest hostile that is attacking the player
--   (targeting.threats), so a mob that runs up behind the player while the target dies is turned on at once.
--   WHEN IT LETS GO: FA.release (the fight is over, a combat release, a halt, a rest) calls unlock_look_at, so the camera is the
--   player's again; the pump (FA.pump -> handler:on_render) runs once per render frame from main's render callback, as the
--   handler needs for its delays and auto-resume.
-- ============================================================================

local R = require("movement/core")

local FA = {}

FA.TURN_DEG = 40             -- off the facing by more than this: face
FA.FACE_RANGE = 45           -- yd
FA.GAP = 0.25                -- s between two lock requests
FA.REFRESH = 0.15            -- a lock with this much left is renewed (same target, still off)
FA.LOCK_MIN, FA.LOCK_MAX = 0.5, 1.2
FA.STEP_DEG = 60             -- 1.2.83: a turn larger than this is made in steps of this size (never a single snap)
FA.STEP_LOCK = 0.3           -- s each step's look-at position is held
FA.ERR_S = 4                 -- s a client facing refusal keeps the "face at once" mode
FA.stats = { locks = 0, refused_fast = 0, casts = 0, releases = 0 }

local lock = nil             -- { guid, until_t, t }
local last_req = -1e9
local said_t = -1e9
local handler, handler_tried = nil, false

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

--- The Movement Handler, or nil when it cannot be loaded here.
local function mh()
    if handler_tried then return handler end
    handler_tried = true
    local ok, m = pcall(require, "common/utility/movement_handler")
    if ok and type(m) == "table" then handler = m end
    return handler
end

function FA.available() return mh() ~= nil end

--- Once per render frame (main's render callback): the handler processes its delays and auto-resume.
function FA.pump()
    local h = mh()
    if not h or type(h.on_render) ~= "function" then return false end
    return pcall(h.on_render, h) == true
end

local function casting(player)
    return safe(player.is_casting_spell, player) == true or safe(player.is_channelling_spell, player) == true
end

local function off_angle(player, x, y)
    local pp = safe(player.get_position, player)
    local rot = safe(player.get_rotation, player)
    local px, py = R.xyz(pp)
    if not px or type(rot) ~= "number" then return nil end
    local diff = math.abs(((math.atan2(y - py, x - px) - rot + math.pi) % (2 * math.pi)) - math.pi)
    return math.deg(diff)
end

--- Did the client refuse a swing / cast for facing in the last ERR_S seconds?
local function face_refused()
    local EV = package.loaded["events"]
    if type(EV) ~= "table" or type(EV.face_error_since) ~= "function" then return false end
    local ok, izi = pcall(require, "common/izi_sdk")
    local now = (ok and type(izi) == "table" and type(izi.now) == "function") and safe(izi.now) or R.now()
    return safe(EV.face_error_since, now - FA.ERR_S) == true
end

--- Who to face: the fight's target when valid, else the nearest hostile attacking the player (or nil).
function FA.pick(player, target)
    if target and R.alive(target) and safe(player.can_attack, player, target) ~= false then return target end
    local tg = package.loaded["targeting"]
    if type(tg) == "table" and type(tg.threats) == "function" then
        local list = safe(tg.threats, player, 25)
        if type(list) == "table" then
            for i = 1, #list do
                if R.alive(list[i]) then return list[i] end
            end
        end
    end
    return nil
end

local function trail(fmt, ...)
    local t = R.now()
    if t - said_t < 1.0 then return end
    said_t = t
    R.trail("front", fmt, ...)
end

local function lock_for(angle)
    local f = math.min(1, math.max(0, (angle or 0) / 180))
    return FA.LOCK_MIN + (FA.LOCK_MAX - FA.LOCK_MIN) * f
end

--- Face the fight's target (or the nearest attacker when it is gone). True when a lock was asked or is running; false when nothing
--- was needed (already facing it) or it is not possible. `seconds` forces the lock length.
function FA.face(player, target, seconds)
    local h = mh()
    if not h or not player then return false end
    if R.resting or R.backpedal_until then return false end
    local unit = FA.pick(player, target)
    if not unit then return false end
    local t = R.now()
    local tp = safe(unit.get_position, unit)
    local tx, ty = R.xyz(tp)
    local pp = safe(player.get_position, player)
    local px, py = R.xyz(pp)
    if not tx or not px then return false end
    local d = R.dist2(px, py, tx, ty)
    if d > FA.FACE_RANGE then return false end
    local ang = off_angle(player, tx, ty)
    local refused = face_refused()
    if not ang then return false end
    if ang <= FA.TURN_DEG and not refused then
        return lock ~= nil and t < lock.until_t                      -- already facing it: nothing to ask
    end
    local guid = safe(unit.get_guid, unit)
    -- a lock for this target that still has time left is not asked again
    if lock and lock.guid == guid and (lock.until_t - t) > FA.REFRESH and not refused then return true end
    if (t - last_req) < FA.GAP then return lock ~= nil and t < lock.until_t end
    local len = tonumber(seconds) or lock_for(ang)
    -- 1.2.83 STEPPED TURNS (log 17:37:50: a 118 degree look-at snap + a cast in the same frame, the last thing before the connection
    -- dropped - the 8th disconnect of the day, three of them within a second of a large turn + a cast): a turn over STEP_DEG is not
    -- one instant rotation but a look-at toward a point STEP_DEG round from the player's CURRENT heading, held STEP_LOCK s; the
    -- next request (GAP s later) sees the new heading and steps again, so a half turn takes about three steps (0.75 s)
    if ang > FA.STEP_DEG and not refused then
        local rot = safe(player.get_rotation, player)
        if type(rot) == "number" then
            local want = math.atan2(ty - py, tx - px)
            local diff = ((want - rot + math.pi) % (2 * math.pi)) - math.pi
            local lim = math.rad(FA.STEP_DEG)
            local stepd = math.max(-lim, math.min(lim, diff))
            local hd = rot + stepd
            local okv, vec3 = pcall(require, "common/geometry/vector_3")
            local pt = { x = px + math.cos(hd) * 10, y = py + math.sin(hd) * 10, z = (pp and pp.z) or 0 }
            if okv and type(vec3) == "table" and type(vec3.new) == "function" then pt = vec3.new(pt.x, pt.y, pt.z) end
            local oks = pcall(h.look_at_position, h, FA.STEP_LOCK, 0, pt)
            if oks then
                last_req = t
                lock = { guid = guid, until_t = t + FA.STEP_LOCK, t = t, stepped = true }
                FA.stats.steps = (FA.stats.steps or 0) + 1
                trail("facing %s: turning %.0f degrees in steps of %d (%.0f yd)", tostring(safe(unit.get_name, unit) or "the target"), ang,
                    FA.STEP_DEG, d)
                local fr = package.loaded["flightrec"]
                if fr and type(fr.note) == "function" then fr.note("face_step", string.format("%.0f", ang)) end
                return true
            end
        end
    end
    local ok = pcall(h.look_at_target, h, len, 0, unit)
    if not ok then return false end
    last_req = t
    lock = { guid = guid, until_t = t + len, t = t }
    FA.stats.locks = FA.stats.locks + 1
    if refused then FA.stats.refused_fast = FA.stats.refused_fast + 1 end
    trail("facing %s (%.0f degrees off, %.0f yd) - look-at lock %.1f s%s", tostring(safe(unit.get_name, unit) or "the target"), ang, d, len,
        refused and ", the client refused a swing / cast for facing" or "")
    local fr = package.loaded["flightrec"]
    if fr and type(fr.note) == "function" then fr.note("face_lock", string.format("%.0f", ang)) end
    return true
end

--- A cast of `cast_time` s at `target`: the handler's "safe cast" recipe - face the target for the cast (+0.2 s) and, when the player
--- is still moving, a light movement pause. True when the lock was asked. Call it right before the cast is sent.
function FA.for_cast(player, target, cast_time)
    local h = mh()
    if not h or not player or not target then return false end
    cast_time = tonumber(cast_time) or 0
    if cast_time <= 0 then return FA.face(player, target) end
    local len = cast_time + 0.2
    local ok = pcall(h.look_at_target, h, len, 0, target)
    if not ok then return false end
    last_req = R.now()
    lock = { guid = safe(target.get_guid, target), until_t = last_req + len, t = last_req }
    FA.stats.casts = FA.stats.casts + 1
    if safe(player.is_moving, player) == true and type(h.pause_movement_light) == "function" then
        pcall(h.pause_movement_light, h, len)
    end
    return true
end

--- The fight is over / a combat release / a halt / a rest: the camera is the player's again.
function FA.release(why)
    if not lock then return false end
    lock = nil
    local h = mh()
    if h and type(h.unlock_look_at) == "function" then pcall(h.unlock_look_at, h) end
    FA.stats.releases = FA.stats.releases + 1
    return true
end

function FA.locked() return lock ~= nil and R.now() < lock.until_t end

function FA.state()
    local h = mh()
    if h and type(h.get_state) == "function" then return safe(h.get_state, h) end
    return nil
end

function FA.reset()
    lock, last_req, said_t = nil, -1e9, -1e9
    FA.stats = { locks = 0, refused_fast = 0, casts = 0, releases = 0 }
end

return FA
