-- ============================================================================
-- Master Farmer - Zygor Forever
-- swingtimer.lua - the player's melee swing timer
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- 1.9.2 (ported from Forever 1.0.9; user: "Create intelligent Swingtimer code to ensure Melee classes
-- attack correctly").
--
-- WHERE A SWING IS SEEN, best first:
--   1. the COMBAT LOG - SWING_DAMAGE / SWING_MISSED with the player as the
--      source (core.register_on_game_event_callback: COMBAT_LOG_EVENT_UNFILTERED
--      args are CombatLogGetCurrentEventInfo() flattened - [2] sub event,
--      [4] source guid; the off-hand flag is [21] on SWING_DAMAGE, [13] on
--      SWING_MISSED). Every real swing, main and off hand. The event handler
--      (events.lua) only stores the time - nothing is clicked from it.
--   2. the Swing Timer addon (core.addons.swing_timer.get_player_mainhand_info /
--      get_player_offhand_info: last_swing, expiration_time, swing_speed), used
--      when it is loaded and its times are on core.time()'s clock (checked).
--   3. auto_attack_helper:get_next_attack_core_time / get_last_attack_core_time
--      - on this client its "last attack" also moves when the Attack command
--      goes out (2.293.0), so it is the last resort.
-- The weapon speed is game_object:get_attack_speed() (main hand); the off hand
-- is learned from its own swings (or the addon's swing_speed).
--
-- WHAT THE ROTATION ASKS:
--   ST.next_in(player)        s to the next main-hand swing (nil = not known)
--   ST.cast_ok(player, ct)    a cast of ct s now does not push a swing back:
--                             right after a swing, or it ends before the next
--   ST.queue_ok(player, t)    a next-swing ability (Heroic Strike, Cleave, Maul,
--                             Raptor Strike) last pressed at t may be pressed:
--                             once per swing, in the QUEUE_WINDOW before it
--   ST.swung_since(t)         a real main-hand swing seen after t (the melee watch)
-- ============================================================================

local ST = {}

ST.QUEUE_WINDOW = 0.9       -- s before the next swing a next-swing ability is queued
ST.JUST_SWUNG = 0.4         -- s after a swing a cast-time spell goes out at once
ST.CAST_SLACK = 0.1         -- s a cast must end before the next swing
ST.STALE = 1.5              -- s past the expected swing that the timer is stale

local MH = { last = nil, obs = nil, n = 0, src = nil }
local OH = { last = nil, obs = nil, n = 0 }
local guid = nil
ST._mh, ST._oh = MH, OH

local function now()
    local ok, t = pcall(function() return core.time() end)
    return (ok and tonumber(t)) or 0
end

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local helper = nil
local function aa()
    if helper == nil then
        local ok, h = pcall(require, "common/utility/auto_attack_helper")
        helper = (ok and type(h) == "table") and h or false
    end
    return helper or nil
end

local function record(h, t)
    if h.last then
        local dt = t - h.last
        -- a learned interval: one swing to the next, a sane weapon speed
        if dt > 0.8 and dt < 5.0 then h.obs = h.obs and (h.obs * 0.7 + dt * 0.3) or dt end
    end
    h.last, h.n = t, h.n + 1
end

--- The player's guid, read on the update tick (ST.tick) - never from the event.
function ST.tick(player)
    if player then
        local g = safe(function() return player:get_guid() end)
        if type(g) == "string" and g ~= "" then guid = g end
    end
end

--- COMBAT_LOG_EVENT_UNFILTERED handler body (events.lua): store the swing time.
--- `args` may have nil holes: only fixed indexes are read.
function ST.on_combat_log(args)
    if type(args) ~= "table" or not guid then return end
    local sub = args[2]
    if sub ~= "SWING_DAMAGE" and sub ~= "SWING_MISSED" then return end
    if args[4] ~= guid then return end
    local off
    if sub == "SWING_DAMAGE" then off = args[21] else off = args[13] end
    record((off == true or off == 1) and OH or MH, now())
end

--- The Swing Timer addon's hand info when it is loaded and on core.time()'s
--- clock: last_swing, expiration_time, swing_speed.
local function addon_hand(which)
    local sw = safe(function() return core.addons.swing_timer end)
    if type(sw) ~= "table" and type(sw) ~= "userdata" then return nil end
    if safe(function() return sw.is_loaded() end) ~= true then return nil end
    local info = (which == "off") and safe(function() return sw.get_player_offhand_info() end)
        or safe(function() return sw.get_player_mainhand_info() end)
    if type(info) ~= "table" and type(info) ~= "userdata" then return nil end
    local last = tonumber(safe(function() return info.last_swing end))
    local exp = tonumber(safe(function() return info.expiration_time end))
    local spd = tonumber(safe(function() return info.swing_speed end))
    local t = now()
    -- the clock check: an expiration more than 10 s away is another clock
    if exp and math.abs(exp - t) > 10 then return nil end
    if last and (last > t + 1 or t - last > 600) then last = nil end
    return { last = last, exp = exp, speed = spd }
end

--- Main-hand weapon speed (s).
function ST.speed(player)
    local s = player and tonumber(safe(function() return player:get_attack_speed() end)) or nil
    if not s or s <= 0 or s > 10 then
        local a = addon_hand("main")
        s = a and a.speed or MH.obs or 2.6
    end
    return s
end

--- Off-hand weapon speed (s), or nil when there is no off hand seen.
function ST.offhand_speed()
    local a = addon_hand("off")
    return (a and a.speed) or OH.obs
end

--- The last main-hand swing time (core.time) and where it was seen.
function ST.last_swing(player)
    local best, src = MH.last, MH.last and "combat log" or nil
    local a = addon_hand("main")
    if a and a.last and (not best or a.last > best) then best, src = a.last, "swing timer addon" end
    if not best then
        local h = aa()
        local l = h and player and tonumber(safe(function() return h:get_last_attack_core_time(player) end)) or nil
        if l and l > 0 then best, src = l, "auto attack helper" end
    end
    return best, src
end

--- s to the next main-hand swing (0 = due now), nil when not known.
function ST.next_in(player)
    local t = now()
    local a = addon_hand("main")
    if a and a.exp and a.exp > t - ST.STALE then return math.max(0, a.exp - t), "swing timer addon" end
    local last, src = ST.last_swing(player)
    if last and src ~= "auto attack helper" then
        local nx = last + ST.speed(player) - t
        if nx > -ST.STALE then return math.max(0, nx), src end
        return nil                                   -- stale: no swing for a while
    end
    local h = aa()
    local nx = h and player and tonumber(safe(function() return h:get_next_attack_core_time(player) end)) or nil
    if nx and nx > t - ST.STALE then return math.max(0, nx - t), "auto attack helper" end
    return nil
end

local function attacking(player)
    return player ~= nil and safe(function() return player:is_auto_attacking() end) == true
end

--- May a cast of `ct` s go out now without pushing the next melee swing back?
--- Not auto attacking, an instant, or the timer unknown: yes.
function ST.cast_ok(player, ct)
    ct = tonumber(ct) or 0
    if ct <= 0 or not attacking(player) then return true end
    local nx = ST.next_in(player)
    if not nx then return true end
    local last = ST.last_swing(player)
    if last and (now() - last) <= ST.JUST_SWUNG then return true end     -- just swung: the whole window is free
    if nx >= ct + ST.CAST_SLACK then return true end                     -- ends before the next swing
    if nx > ST.speed(player) + ST.STALE then return true end            -- a stale answer: do not wait on it
    return false
end

--- May a next-swing ability (last pressed at `pressed_t`, core.time) be
--- pressed now? Once per swing: not again until a swing has landed since the
--- press; and in the QUEUE_WINDOW before the next swing when the timer knows it
--- (a press long before the swing just holds the rage).
function ST.queue_ok(player, pressed_t)
    local last = ST.last_swing(player)
    if pressed_t and last and pressed_t > last then return false, "queued for the next swing" end
    if pressed_t and not last and (now() - pressed_t) < ST.speed(player) then return false, "queued for the next swing" end
    local nx = ST.next_in(player)
    if nx and nx > ST.QUEUE_WINDOW and attacking(player) then return false, "waiting for the swing window" end
    return true
end

--- A real main-hand swing seen after `t` (the combat log or the addon).
function ST.swung_since(t)
    if MH.last and MH.last >= t then return true end
    local a = addon_hand("main")
    return a ~= nil and a.last ~= nil and a.last >= t
end

--- One line for the log / GUI.
function ST.describe(player)
    local nx, src = ST.next_in(player)
    return string.format("swing %.2fs (%s), next in %s, main %d / off %d seen", ST.speed(player), tostring(src or "-"),
        nx and string.format("%.2fs", nx) or "?", MH.n, OH.n)
end

function ST._reset() MH.last, MH.obs, MH.n, OH.last, OH.obs, OH.n, guid = nil, nil, 0, nil, nil, 0, nil end
function ST._set_guid(g) guid = g end

return ST
