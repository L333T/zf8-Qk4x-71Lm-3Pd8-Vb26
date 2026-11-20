-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/front.lua - face the target and keep enemies in front (Simple Movement)
-- ============================================================================
-- 1.2.34 (user: "Use Sylvanas Simple Movement API for all player classes, for facing targets
-- and keeping enemy position in front of player"). Every class, in a fight:
--   FACE  The target is more than TURN_DEG off the player's facing -> a short walk
--         (STEP_YD) toward it with the Simple Movement look_at system turns the player
--         onto it. At most one per TURN_GAP s; never while casting.
--   KITE  A fighting enemy is behind the player (movement/combat front_check) -> a
--         walk of up to KITE_YD toward the point Sentinel's flee path gave (away from
--         them all); the followers then trail in front when the player faces them.
-- Simple Movement (common/utility/simple_movement, colon API) is a walker with no
-- "face" call, so a face is a very short walk. :process() runs every frame while a
-- move is active (movement.pulse -> F.tick); a move ends on arrival, after RUN_MAX s,
-- on a cast, a rest, combat release or a halt, and :stop() / :clear_navigation() always
-- follow. Travel stays with Sentinel; while a move runs Sentinel is stopped and
-- nav refuses other walks (N.refusal "front"), so one system owns the keys at a time.
-- API: simple_movement:move_to_position / process / stop / clear_navigation /
-- set_use_look_at / set_threshold / set_final_threshold / set_turn_speed (all declared
-- on the live stub), game_object:get_rotation / get_position / is_casting_spell /
-- is_channelling_spell.
-- ============================================================================

local R = require("movement/core")

local F = {}

local TURN_DEG, TURN_GAP = 40, 1.0
local STEP_YD = 1.2
local KITE_YD = 6.0
local RUN_MAX = 2.5
local FACE_RANGE = 45          -- yd: only targets this close are turned on

local st = nil                 -- { kind, t0, dead, x, y }
local face_t = -1e9
local sm_obj, sm_tried = nil, false

local function sm()
    if sm_tried then return sm_obj end
    sm_tried = true
    local ok, m = pcall(require, "common/utility/simple_movement")
    if ok and type(m) == "table" then
        sm_obj = m
        pcall(m.set_use_look_at, m, true)
        pcall(m.set_threshold, m, 1.5)
        pcall(m.set_final_threshold, m, 0.8)
        pcall(m.set_turn_speed, m, 0.3)
    end
    return sm_obj
end

local function casting(player)
    local a = select(2, pcall(player.is_casting_spell, player))
    local b = select(2, pcall(player.is_channelling_spell, player))
    return a == true or b == true
end

local function finish(why)
    local m = sm()
    if m then
        pcall(m.stop, m)
        pcall(m.clear_navigation, m)
    end
    if st and why then R.trail("front", "%s ended: %s", st.kind, why) end
    st = nil
end

function F.active() return st ~= nil end
--- Is Simple Movement loadable here?
function F.available() return sm() ~= nil end

--- The player's heading off `x, y` in degrees (0 = straight ahead), or nil.
function F.off_angle(player, x, y)
    local okp, pp = pcall(player.get_position, player)
    local okr, rot = pcall(player.get_rotation, player)
    local px, py = R.xyz(okp and pp or nil)
    if not px or not okr or type(rot) ~= "number" then return nil end
    local diff = math.abs(((math.atan2(y - py, x - px) - rot + math.pi) % (2 * math.pi)) - math.pi)
    return math.deg(diff)
end

local function go(kind, x, y, z, hold)
    local m = sm()
    if not m then return false end
    do local fr = package.loaded["flightrec"] if fr then fr.note("sm_" .. tostring(kind)) end end 
    local ok, r = pcall(m.move_to_position, m, { x = x, y = y, z = z })
    if not ok or r == false then return false end
    st = { kind = kind, t0 = R.now(), dead = R.now() + (hold or RUN_MAX) }
    return true
end

--- Turn the player onto `unit` (any class). True when a turn was started or
--- one is already running; false when nothing was needed or possible.
function F.face(player, unit)
    -- 1.2.81: the Movement Handler faces the target (look-at lock, no key press); the Simple Movement walk below is the fallback
    local okf, FA = pcall(require, "movement/facing")
    if okf and type(FA) == "table" and FA.available() and not st then
        return FA.face(player, unit)
    end
    if st then return st.kind == "face" end
    if not player or not unit or not R.alive(unit) then return false end
    if R.resting or R.backpedal_until then return false end
    if casting(player) then return false end
    local t = R.now()
    if (t - face_t) < TURN_GAP then return false end
    local okt, tp = pcall(unit.get_position, unit)
    local okp, pp = pcall(player.get_position, player)
    local tx, ty, tz = R.xyz(okt and tp or nil)
    local px, py, pz = R.xyz(okp and pp or nil)
    if not tx or not px then return false end
    local d = R.dist2(px, py, tx, ty)
    if d > FACE_RANGE then return false end
    local ang = F.off_angle(player, tx, ty)
    if not ang or ang <= TURN_DEG then return false end
    face_t = t
    local step = math.min(STEP_YD, math.max(d - 0.5, 0.4))
    local ux, uy = (tx - px) / math.max(d, 0.01), (ty - py) / math.max(d, 0.01)
    if go("face", px + ux * step, py + uy * step, pz, 1.5) then
        R.trail("front", "turning onto the target (%.0f degrees off, %.0f yd)", ang, d)
        return true
    end
    return false
end

--- Walk up to KITE_YD toward `point` (a Sentinel flee point), away from the
--- enemies behind the player. True when started.
function F.kite(player, point)
    if st or not player then return false end
    if R.resting or R.backpedal_until or casting(player) then return false end
    local px, py, pz = R.xyz(select(2, pcall(player.get_position, player)))
    local gx, gy = R.xyz(point)
    if not px or not gx then return false end
    local d = R.dist2(px, py, gx, gy)
    if d < 1 then return false end
    local len = math.min(KITE_YD, d)
    if go("kite", px + (gx - px) / d * len, py + (gy - py) / d * len, pz, RUN_MAX) then
        R.trail("front", "kiting %.0f yd so the enemies trail in front", len)
        return true
    end
    return false
end

--- Every frame (movement.pulse): the active move's process() and its end.
function F.tick()
    if not st then return end
    local m = sm()
    local me = R.me()
    if not m or not me then return finish("no player / Simple Movement") end
    if R.now() > st.dead then return finish("time") end
    if R.resting or R.backpedal_until then return finish("rest") end
    if casting(me) then return finish("cast") end
    local ok, reached = pcall(m.process, m)
    if not ok then return finish("process error") end
    if reached == true then return finish("arrived") end
end

--- The fight is over / the bot halts: let go of the keys.
function F.release()
    if st then finish("released") end
    local FA = package.loaded["movement/facing"]
    if type(FA) == "table" and type(FA.release) == "function" then pcall(FA.release, "released") end    -- 1.2.81
end

function F.reset() st, face_t = nil, -1e9 end

return F
