-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/combat.lua - closing on a target and standing in range
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- ============================================================================
-- combat_engage(player, unit, yards) is called every tick of a fight.
--   * OWNERSHIP: each call holds travel off for COMBAT_HOLD s
--     (R.combat_until); combat_release() hands the player back at once.
--   * IN POSITION: in sight and within the band - melee (yards <= 5): the
--     GUI melee distance, held to +1 yd; ranged: CHASE_BAND inside the range,
--     held to the full range. The walk stops, the player faces the target,
--     and true is returned (the caller attacks).
--   * CLOSING: Sentinel walks to the target (seamless re-paths as it
--     moves; a unit standing on the goal is never an obstacle there), and
--     false is returned. Out of sight closes in until it is in sight.
--   * NO WAY CLOSER: no CHASE_GAIN yd of progress for CHASE_STALL s while
--     out of position - the target is marked unreachable
--     (state.mark_unreachable), which grind / quest check to drop it.
--   * RETREAT: a class profile's should_retreat(ctx) (mage, priest) sends
--     the player to Sentinel's kite point (nav_client:kite) for RETREAT_TIME s.
--     1.16.0: ctx.approaching (izi is_moving_towards_me) and ctx.slowed /
--     ctx.casting go to the profile too, for an earlier back-off.
--   * FLEE (1.16.0, improvement 3 of the API-dump review): FLEE_HP % health
--     or less with FLEE_N+ enemies inside FLEE_YD yd -> Sentinel's flee path
--     (movement/nav N.flee - away from all of them) for FLEE_TIME s, at most
--     once per FLEE_GAP s; nothing is attacked while it runs.
--   * ENEMIES IN FRONT (1.2.28): in position with a fighting enemy more than
--     BEHIND_DEG degrees off the player's facing (behind it), within BEHIND_YD
--     yd -> Sentinel's flee path away from all of them for FRONT_TIME s (at
--     most once per FRONT_GAP s); the player then turns on its target and the
--     followers trail in front of it.
--   * FLEEING MOB (1.2.28): a melee class (warrior, paladin, rogue, shaman,
--     druid) whose target runs - moving away at FLEE_SPEED yd/s or more, or
--     wounded and moving away - chases at once (no chase gap, re-path at 1 yd)
--     and holds the GUI melee distance (+1 yd), even for a Shaman whose engage
--     distance is Lightning Bolt range.
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")
local Rg = require("movement/range")
local F = require("movement/front")      -- 1.2.34: Simple Movement facing / keeping enemies in front

local C = {}

local COMBAT_HOLD = 1.0
local MELEE_YARDS = 5
local CHASE_BAND = 3
local CHASE_GAIN, CHASE_STALL = 2.0, 10.0
-- 3.0.0.1: the chase re-paths only when the target moved CHASE_REPATH yd
-- from the walk's goal, at most every CHASE_GAP s. (Sentinel era: its walker
-- driver restarted on every new path, and a re-path every 0.25 s made the
-- chase stutter and fall behind - log 01:44, 48 -> 53 yd while "Closing".)
local CHASE_REPATH, CHASE_GAP = 4.0, 0.75
local RETREAT_TIME = 2.5
local FLEE_HP, FLEE_N, FLEE_YD, FLEE_TIME, FLEE_GAP = 20, 3, 10, 5.0, 45.0
C.FLEE_HP, C.FLEE_N = FLEE_HP, FLEE_N
local DEFAULT_MELEE_DANGER = 8
-- 1.2.28: enemies behind the player / a fleeing target
local BEHIND_DEG, BEHIND_YD, FRONT_GAP, FRONT_TIME = 110, 12, 6.0, 2.0
local FLEE_SPEED, FLEE_SPEED_HURT, FLEE_HURT_HP, FLEE_HOLD = 1.5, 0.5, 35, 4.0
local FLEE_CHASE_GAP, FLEE_CHASE_REPATH = 0.25, 1.0
local MELEE_CLASSES = { [1] = true, [2] = true, [4] = true, [7] = true, [11] = true }   -- warrior paladin rogue shaman druid
local PENDING_MAX = 3.0        -- audit 1.19.0: s a kite / flee answer is waited for (a lost callback held it forever)

local st = {
    guid = nil, unit = nil, yards = nil,
    latched = false,
    best = nil, best_t = 0,
    retreat_until = 0, kite_pending = false, kite_t = 0,
    flee_until = 0, flee_t = -1e9, flee_pending = false,
    profile = nil,
    front_t = -1e9, front_pending = false, fl = nil,
}

function C.set_combat_profile(p)
    st.profile = type(p) == "table" and p or nil
end

function C.clear_combat_profile()
    st.profile = nil
end

local function state_mod()
    local ok, s = pcall(require, "state")
    if ok and type(s) == "table" then return s end
    return nil
end

local function want_retreat(player, unit, range)
    local p = st.profile
    if not p or type(p.should_retreat) ~= "function" then return false end
    local enemies = {}
    local oke, list = pcall(player.get_enemies_in_range, player, tonumber(p.melee_danger) or DEFAULT_MELEE_DANGER, false)
    if oke and type(list) == "table" then enemies = list end
    local ck = nil
    do
        local okc, m = pcall(require, "combatcheck")
        if okc and type(m) == "table" then ck = m end
    end
    local ctx = {
        player = player, target = unit, distance = range, melee_count = #enemies, enemies = enemies,
        approaching = ck and ck.approaching(unit, player) == true or false,
        slowed = ck and (ck.slowed(unit) == true or ck.held(unit) == true) or false,
        casting = select(2, pcall(player.is_channeling_or_casting, player)) == true,
        last_spell_id = R.last_spell_id, last_spell_target = R.last_spell_target,
        last_spell_age = R.now() - (R.last_spell_t or 0),
    }
    local ok, v = pcall(p.should_retreat, ctx)
    return ok and v == true
end

local function start_retreat(player, unit)
    if st.kite_pending and (R.now() - st.kite_t) >= PENDING_MAX then st.kite_pending = false end   -- audit 1.19.0
    if st.kite_pending then return end
    -- 1.12.0: Sentinel's kite path (movement/nav N.kite - nav_client:kite, its last
    -- point; the answer's shape is checked live, a wrong one switches kiting off)
    local okp, pp = pcall(player.get_position, player)
    local oku, up = pcall(unit.get_position, unit)
    if not okp or not oku or not pp or not up then return end
    st.kite_pending, st.kite_t = true, R.now()
    local ok = N.kite(R.point(pp), R.point(up), function(point)
        st.kite_pending = false
        if point and N.nav_to(point, true, "combat") then
            st.retreat_until = R.now() + RETREAT_TIME
            R.trail("move", "retreat to the kite point (%.0f, %.0f)", point.x or 0, point.y or 0)
        end
    end)
    if not ok then st.kite_pending = false end
end

--- 1.16.0 FLEE: overwhelmed - low health and a crowd in melee - walk
--- Sentinel's flee path away from all of them. True while fleeing.
local function flee_check(player, t)
    -- audit 1.19.0: an unanswered flee request no longer blocks every attack for good
    if st.flee_pending and (t - st.flee_t) >= PENDING_MAX then st.flee_pending = false end
    if t < st.flee_until or st.flee_pending then return true end
    if (t - st.flee_t) < FLEE_GAP then return false end
    local okh, hp = pcall(player.get_health_percentage, player)
    if not okh or type(hp) ~= "number" or hp > FLEE_HP then return false end
    local oke, list = pcall(player.get_enemies_in_range, player, FLEE_YD, false)
    if not oke or type(list) ~= "table" or #list < FLEE_N then return false end
    local threats = {}
    for i = 1, #list do
        local okp, p = pcall(list[i].get_position, list[i])
        if okp and p then threats[#threats + 1] = R.point(p) end
    end
    local okp, pp = pcall(player.get_position, player)
    if not okp or not pp or #threats < FLEE_N then return false end
    st.flee_t, st.flee_pending = t, true
    local asked = N.flee(R.point(pp), threats, function(point)
        st.flee_pending = false
        if point and N.nav_to(point, true, "combat") then
            st.flee_until = R.now() + FLEE_TIME
            R.trail("move", "flee: %.0f%% health, %d enemies within %d yd - to (%.0f, %.0f)", hp, #threats, FLEE_YD,
                point.x or 0, point.y or 0)
        end
    end)
    if not asked then st.flee_pending = false return false end
    return true
end
C._flee_check = flee_check

local function melee_class(player)
    local ok, cid = pcall(player.get_class, player)
    return ok and MELEE_CLASSES[cid] == true
end

--- The GUI "Melee attack distance" (1-5 yd).
local function melee_yards()
    local ok, g = pcall(require, "gui")
    local v = ok and type(g) == "table" and type(g.slider) == "function" and g.slider("melee_yards", MELEE_YARDS) or nil
    if type(v) ~= "number" then v = MELEE_YARDS end
    if v < 1 then v = 1 elseif v > MELEE_YARDS then v = MELEE_YARDS end
    return v
end

--- 1.2.28: is the target running away? Sampled every 0.25 s; once seen it stays
--- flagged while the target moves and is out of position.
local function target_fleeing(unit, guid, range, t, band)
    local f = st.fl
    if not f or f.guid ~= guid then
        st.fl = { guid = guid, range = range, t = t, on = false }
        return false
    end
    local moving = select(2, pcall(unit.is_moving, unit)) == true
    if f.on then
        if moving and range > band then return true end
        f.on = false
    end
    local dt = t - f.t
    if dt < 0.25 then return false end
    local speed = (range - f.range) / dt
    f.range, f.t = range, t
    if dt > 1.5 or not moving or range <= band then return false end
    local okh, hp = pcall(unit.get_health_percentage, unit)
    local hurt = okh and type(hp) == "number" and hp <= FLEE_HURT_HP
    if speed >= FLEE_SPEED or (hurt and speed >= FLEE_SPEED_HURT) then
        f.on = true
        R.trail("move", "target is fleeing (%.1f yd/s, %.0f yd away) - chasing at once", speed, range)
        return true
    end
    return false
end

--- 1.2.28: a fighting enemy behind the player (not the target) -> flee path away
--- from all of them; the followers then trail in front. True when it started.
local function front_check(player, unit, t)
    if st.front_pending and (t - st.front_t) >= PENDING_MAX then st.front_pending = false end
    if st.front_pending or (t - st.front_t) < FRONT_GAP then return false end
    local okh, hp = pcall(player.get_health_percentage, player)
    if okh and type(hp) == "number" and hp <= FLEE_HP then return false end
    local okp, pp = pcall(player.get_position, player)
    local okr, rot = pcall(player.get_rotation, player)
    local px, py = R.xyz(okp and pp or nil)
    if not px or not okr or type(rot) ~= "number" then return false end
    local oke, list = pcall(player.get_enemies_in_range, player, BEHIND_YD, false)
    if not oke or type(list) ~= "table" then return false end
    local tg = R.guid(unit)
    local threats, behind = {}, 0
    for i = 1, #list do
        local e = list[i]
        if R.alive(e) and select(2, pcall(e.is_in_combat, e)) == true then
            local okq, ep = pcall(e.get_position, e)
            local ex, ey = R.xyz(okq and ep or nil)
            if ex then
                threats[#threats + 1] = { x = ex, y = ey, z = select(3, R.xyz(ep)) }
                if R.guid(e) ~= tg then
                    local diff = math.abs(((math.atan2(ey - py, ex - px) - rot + math.pi) % (2 * math.pi)) - math.pi)
                    if diff > math.rad(BEHIND_DEG) then behind = behind + 1 end
                end
            end
        end
    end
    if behind == 0 or #threats == 0 then return false end
    st.front_t, st.front_pending = t, true
    local asked = N.flee(R.point(pp), threats, function(point)
        st.front_pending = false
        -- 1.2.34: Sentinel only picks the safe point; Simple Movement walks it
        if point and F.available() then
            if N.busy() then N.stop("front: kite") end
            if F.kite(player, point) then
                st.retreat_until = R.now() + FRONT_TIME
                R.trail("move", "%d enemy(ies) behind the player - kiting toward (%.0f, %.0f) so they trail in front",
                    behind, point.x or 0, point.y or 0)
            end
        elseif point and N.nav_to(point, true, "combat") then
            st.retreat_until = R.now() + FRONT_TIME
        end
    end)
    if not asked then st.front_pending = false return false end
    return true
end
C._front_check = front_check
C._target_fleeing = target_fleeing

--- 1.2.65: Sentinel's floor / path answer is still awaited.
local function nav_waiting()
    return (type(N.pending) == "function" and N.pending() == true) or (type(N.awaiting_path) == "function" and N.awaiting_path() == true)
end

--- True when in position to attack `unit` from `yards`; false while closing.
function C.combat_engage(player, unit, yards)
    if R.shaman_casting() then return false end
    if not player or not unit then return false end
    if R.resting or R.backpedal_until then return false end
    if not R.alive(unit) then return false end
    yards = tonumber(yards) or 20
    if yards < 1 then yards = MELEE_YARDS end
    local t = R.now()
    R.combat_until = t + COMBAT_HOLD

    local guid = R.guid(unit)
    if guid == nil or guid ~= st.guid then
        st.guid, st.latched, st.best, st.best_t = guid, false, nil, t
        -- 2026-10-28 (user: "Sentinel Kiting is not being used in combat"): the
        -- retreat used to be thrown away here with the rest of the per-target
        -- state. It is not per-target. The 10-27 21:27 log: the kite walk starts
        -- at t=2124.20, an attacker switch lands at t=2124.45, retreat_until
        -- goes to 0, and the "range <= reach" branch below stops the walk at
        -- t=2125.20 - one second in, every time, which in a multi-mob fight is
        -- continuously. A retreat is about where the PLAYER needs to be, not
        -- about which unit is being hit, so it now outlives the switch and ends
        -- on its own RETREAT_TIME (2.5 s). The band state above still resets.
    end
    st.unit, st.yards = unit, yards

    local okd, range = pcall(player.distance_to, player, unit)
    if not okd or type(range) ~= "number" then return false end
    local los = Rg.has_los(player, unit)
    -- 1.2.28: a melee class chases a running target and holds the melee distance
    local running = false
    if melee_class(player) then
        local my = melee_yards()
        if target_fleeing(unit, guid, range, t, my + 1) then
            running = true
            yards = my
        end
    end
    local melee = yards <= MELEE_YARDS
    local reach = melee and yards or math.max(MELEE_YARDS, yards - CHASE_BAND)
    local hold = melee and (yards + 1) or yards
    local ready = los and range <= hold

    -- 1.16.0: fleeing - the flee walk runs, nothing is attacked
    if flee_check(player, t) then return false end
    -- retreating: the kite walk runs, the caller casts what it can
    if t < st.retreat_until then return ready end
    if want_retreat(player, unit, range) then
        start_retreat(player, unit)
        if t < st.retreat_until or st.kite_pending then return ready end
    end

    -- 1.2.34: a Simple Movement turn / kite owns the keys: no Sentinel chase on top of it
    if F.active() then return ready end

    if los and (range <= reach or (st.latched and range <= hold)) then
        -- 3.0.0.1: ANY running walk stops here, not only the chase - the
        -- route walk kept going through a fight and carried the player out
        -- of range, unable to face the target (log 01:44, 14 -> 48 yd)
        if N.busy() then N.stop("in range") end
        st.latched = true
        st.best, st.best_t = range, t
        if front_check(player, unit, t) then return ready end
        F.face(player, unit)
        return true
    end
    st.latched = false

    -- closing
    if not nav_waiting() then st.pend0 = nil end   -- 1.2.65
    if st.best == nil or range < st.best - CHASE_GAIN then
        st.best, st.best_t = range, t
    elseif nav_waiting() and (t - (st.pend0 or t)) < 60 then
        -- 1.2.65: waiting for Sentinel's floor / path answer is not the target's fault (see targeting.approach_stuck)
        st.pend0 = st.pend0 or t
        st.best_t = t
    elseif (t - st.best_t) >= CHASE_STALL then
        local s = state_mod()
        if s and guid and type(s.mark_unreachable) == "function" then s.mark_unreachable(guid) end
        R.trail("move", "no way closer to %s for %.0f s (%.0f yd%s) - marked unreachable",
            tostring(select(2, pcall(unit.get_name, unit))), t - st.best_t, range, los and "" or ", out of sight")
        st.best, st.best_t = range, t
        return false
    end
    local okp, pos = pcall(unit.get_position, unit)
    if okp and pos then
        local tx, ty = R.xyz(pos)
        local gx, gy = N.destination()
        local chasing = N.mode() == "combat" and N.busy()
        local moved = (not gx or not tx) or R.dist2(gx, gy, tx, ty) > (running and FLEE_CHASE_REPATH or CHASE_REPATH)
        if not chasing or (moved and (t - (st.chase_t or 0)) >= (running and FLEE_CHASE_GAP or CHASE_GAP)) then
            st.chase_t = t
            N.nav_to(pos, true, "combat")
        end
    end
    return false
end

function C.in_combat_movement()
    return (R.combat_until or 0) > R.now()
end

--- The unit being fought, never a freed one.
function C.combat_unit()
    if st.unit and R.alive(st.unit) then return st.unit end
    return nil
end

--- Latched in position against a live target while combat is asked for.
function C.in_position()
    if not st.latched or not C.in_combat_movement() then return false end
    if R.resting or R.backpedal_until or R.now() < st.retreat_until or R.now() < st.flee_until then return false end
    return C.combat_unit() ~= nil
end

--- Give the player back (loot, quest approach, fight over).
function C.combat_release()
    F.release()
    R.combat_until = 0
    st.latched = false
    st.retreat_until, st.flee_until = 0, 0
    if N.mode() == "combat" then N.stop("combat over") end
end

return C
