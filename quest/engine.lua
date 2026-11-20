-- ============================================================================
-- Master Farmer - Zygor Forever
-- Quest engine - driven entirely by the Zygor Guides addon. Never runs grind.
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- Zygor is the single source of quest information:
--
--   which quest, and what to do with it   the current step's first open goal
--   where to go                           the goal's own step waypoints, then
--                                         the arrow
--   who to talk to                        the waypoint title, an NPC learned
--                                         on an earlier visit, or the nearest
--                                         friendly unit at the waypoint
--   what to kill / collect / click        the quest's Zygor objectives:
--                                         their text names the target and
--                                         their type says which of the three
--   when it is done                       Zygor's own completion flags
--
-- This file does the doing, with the dialog helpers in quest/npc and the same
-- fight / walk primitives grind mode uses. quest/guide only reads the addon.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")
local gamever = require("gamever")

local gossip = require("gossip")

local gui = require("gui")
local state = require("state")
local npc = require("quest/npc")
local rotation = require("rotation")
local targeting = require("targeting")
local movement = require("movement")
local healing = require("healing")
local geometry = require("geometry")
local guide = require("quest/guide")
local loot = nil
do
    local ok, mod = pcall(require, "loot")
    if ok and type(mod) == "table" then
        loot = mod
    end
end
local events = nil
do
    local ok, mod = pcall(require, "events")
    if ok and type(mod) == "table" then
        events = mod
    end
end

local quest = {}

local SCAN_GAP = 0.8          -- seconds between target scans
local KILL_TIMEOUT = 60.0     -- give up on one mob after this
local ARRIVE = 3.0            -- yards: standing on a waypoint
local TALK_REACH = 2.0        -- yards: close enough to interact (2.297.0: 2 yd, was 4)
local TALK_SEARCH = 12.0      -- yards around the waypoint to look for a giver
local TALK_SEARCH_FAR = 40.0  -- yards: search from the door of a building
local TALK_ARRIVE = 8.0       -- yards: at the door is close enough to stop walking
local STEP_INSIDE = 6.0       -- yards toward the waypoint, at the player's height
local ACT_GAP = 1.5           -- seconds between interacts / item uses
local MOB_RANGE = 300         -- 1.5.0 (user): the step's targets are searched to 300 yd (was 100)
local OBJECT_RANGE = 300      -- 1.5.0 (user): quest objects to 300 yd (was 40)
local CAMP_RADIUS = 45        -- yards around a waypoint for unnamed drop sources

-- Walk state for the current goal. Zygor owns WHICH goal; these only track
-- where the bot is in walking to it, and reset when the goal changes.
local g_key = nil
local g_move = 1
local g_scan_until = 0
local g_act_until = 0
local g_cur_kind = nil         -- 2.125.0: kind of the goal being worked
local g_kill_until = 0
-- Collect goals: when the search for a mob named like the item began coming
-- up empty. 0 while one is in sight.
local g_nosource_since = 0
local SOURCE_PATIENCE = 30.0  -- seconds of walking before any camp mob will do
local g_armed_engage = false
local g_loot_wait = false
local g_label = "fighting"
-- Talk goals: when the NPC's frame first showed open. 0 while it is not.
local g_talk_opened = 0
-- 2.204.0: a ".vendor" step's gossip -> vendor option tries on the current NPC.
-- 2.206.0 gsel: the guide file's gossip choice, made once per opened frame;
-- GOSSIP_AFTER: Zygor's own gossip automation acts on GOSSIP_SHOW first.
-- (One table, 2.210.0: the chunk's 200-local limit.)
-- 2.215.0 gid: the goal's IDENTIFIED NPC (guide id / learned id / raid marker /
-- waypoint title / guide giver name, standing at the goal's waypoint) - tried =
-- its name once a dialog with one began, refused = { name, npc } once one of
-- them said the quest is not on offer. Cleared with the goal (reset_gid).
local TK = { vend = { guid = nil, tries = 0, next_t = 0 }, VEND_TRIES = 3, NPC_VENDOR = 0x80,
    gsel = { key = nil }, GOSSIP_AFTER = 1.0, gid = { tried = nil, refused = nil } }
local g_in_dialog = false      -- the last tick was spent on an NPC dialog goal
local g_in_travel = false      -- the last tick was spent walking to a waypoint
local TALK_DONE = 2.0         -- seconds a frame is left open before the goal counts
-- Every candidate NPC ruled out: when, so the list can be retried later.
local g_bad_since = 0
local BAD_GIVER_RETRY = 20.0
-- Where the bot was last sent to reach the giver, to re-route when it moves.
local g_giver_walk = nil

-- ARRIVAL IS FLAT (2.134.0). A Zygor waypoint's height is the terrain
-- under it, and indoors that is the ground outside, not the floor the NPC
-- stands on: a 3D "within 3 yards" never came true inside a building, so the
-- bot circled the spot forever. Within ARRIVE_DZ of the guessed height is
-- arrival outdoors; indoor and observed interaction targets require the same floor.
local ARRIVE_DZ = 12

-- NO-PROGRESS CHECK (2.134.0). An accept / turn-in / talk goal that makes no
-- progress for STALL_AFTER seconds - no yard gained on the NPC, no dialog
-- stage advanced, no quest-log change - is recovered: frames closed, the
-- guide re-read, the giver searched for again and a fresh path requested.
-- STALL_MAX recoveries in a row skip the goal. The 5-minute watchdog stays
-- as the last line behind it.
local STALL_AFTER = 30.0
local STALL_MAX = 3
local STALL_GAIN = 2.0        -- yards closer that count as progress
local g_stall = { t = 0, seen = 0, best = nil, reach = false, npc_seq = nil, log = nil, recoveries = 0 }
local g_unreach = { key = nil, t0 = 0, seen = 0 }      -- 1.2.48: how long the same target has been unreachable
local g_force_path = false    -- next walk drops the old path and asks for a new one

-- The NPC refused an interact (a UI error): close in before the next one.
local CLOSE_REACH = 1.5         -- 2.297.0: inside TALK_REACH (was 2.5)
local g_close_in = false

-- The NPC lists the quest as not complete: wait, then ask once more.
local NOT_READY_HOLD = 10.0
local NOT_READY_MAX = 2

--- 1.76.2 (user: "edit the timer the player waits at the NPC"): the General / Questing tab slider "Wait at NPC for an
--- unfinished task (s)" - how long the bot stays at an NPC (or at a goal whose NPC / object is not in sight) before it
--- gives the goal up. The bot never sits the full time out: the wait ends the moment the task is complete.
local function npc_wait_s()
    local ok, v = pcall(function() return gui.slider("npc_wait", 20) end)
    v = ok and tonumber(v) or 20
    if v < 5 then v = 5 elseif v > 120 then v = 120 end
    return v
end
local g_not_ready = 0
local g_hold_until = 0
local g_hold_qid = nil            -- the quest a not-complete hold is waiting on (released when it completes)

-- An innkeeper for a ".home" goal: the bind option was selected.
local g_bind_asked = false
-- Talk goals: when the last interact went out.
local g_talk_interact_t = 0

-- The NPC the bot opened a dialog with, remembered until the goal changes so
-- it can be recorded as that quest's giver once the accept or turnin lands.
local g_pending = nil

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- Breadcrumbs for scripts_log/MASTER_FARMER_ERRORS. errorlog.trail writes a
-- line only when it differs from the previous one with the same tag, so these
-- can sit on per-frame paths.
local errorlog = nil
do
    local ok, mod = pcall(require, "errorlog")
    if ok and type(mod) == "table" then
        errorlog = mod
    end
end

local last_walk_x, last_walk_y = nil, nil
local last_aim_x, last_aim_y = nil, nil
local last_note = nil

local function trail(tag, fmt, ...)
    if errorlog then
        errorlog.trail(tag, fmt, ...)
    end
end

local function probe(tag)
    if errorlog then
        errorlog.probe(tag)
    end
end

local dbg_last, dbg_at = nil, 0

local function debug(fmt, ...)
    -- Quest detail is part of "Detailed session log" (2.188.0).
    if not gui.is_on("session_detail") then
        return
    end
    local text = string.format(fmt, ...)
    -- The same line every tick flooded the console (2.108.0): once per 5 s.
    local t = izi.now()
    if text == dbg_last and (t - dbg_at) < 5 then
        return
    end
    dbg_last, dbg_at = text, t
    local ok, dbg = pcall(require, "debuglog")
    if ok and dbg and type(dbg.line) == "function" then
        dbg.line("guide", "%s", text)
    end
end

local function release_combat()
    if movement and type(movement.nav_stop) == "function" then
        movement.nav_stop()
    end
    if movement and type(movement.combat_release) == "function" then
        movement.combat_release()
    end
    state.reset_target()
end

local function combat_yards(player)
    local yards = 30
    if type(rotation.combat_range) == "function" then
        yards = rotation.combat_range(player)
    end
    if type(yards) ~= "number" or yards < 1 then
        yards = 30
    end
    return yards
end

--- Fight the current kill target. Returns false once there is nothing left to
--- fight - dead, gone, unreachable or timed out.
local APPROACH_BAND = 15       -- hand over to combat movement this far outside the engage distance
local APPROACH_WAIT = 3.0      -- 2.155.0: seconds an approach waits for its path leg
local g_appr = { guid = nil, since = 0, off = false, released = false }

local function fight_unit(player, unit, note)
    local now = izi.now()
    -- VALID FIRST, ALWAYS (2.32.0). The unit is held across ticks; once the
    -- game frees the object behind it, any other method is a native read of
    -- freed memory - pcall cannot catch that, the game dies. 2.31.0 asked
    -- is_dead before is_valid. An engaged target that has gone invalid most
    -- likely died and was cleaned up, so it is recorded as a kill from the
    -- saved GUID, never by touching the object.
    if not unit or safe(function() return unit:is_valid() end) ~= true then
        if state.target.kind == "kill" and state.target.guid then
            state.mark_killed(state.target.guid)
            -- No handle left to read: queue the corpse from what was saved.
            local ok_l, lt = pcall(require, "loot")
            if ok_l and type(lt) == "table" and type(lt.note_kill_guid) == "function" then
                lt.note_kill_guid(state.target.guid,
                    state.target.x and { x = state.target.x, y = state.target.y, z = state.target.z } or nil)
            end
        end
        release_combat()
        return false
    end
    if safe(function() return unit:is_dead() end) == true
        or safe(function() return unit:is_dead_or_ghost() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        trail("act", "killed %s", tostring(safe(function() return unit:get_name() end)))
        -- Queue the corpse now, in this tick, so loot.has_work is already
        -- true when the engine next looks for something to pull.
        if loot and type(loot.note_kill) == "function" then
            loot.note_kill(unit)
        end
        release_combat()
        return false
    end
    -- Surrendered quest NPCs remain alive: release the combat lock without
    -- recording a kill or queuing loot, then defend against remaining enemies.
    if safe(function() return player:can_attack(unit) end) == false then
        release_combat()
        return false
    end
    if g_kill_until > 0 and now > g_kill_until and state.target.kind == "kill" then
        state.mark_killed(state.target.guid)
        release_combat()
        return false
    end
    if safe(function() return unit:is_dead_or_ghost() end) == true or safe(function() return unit:is_dead() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        release_combat()
        return false
    end
    local dist = safe(function() return player:distance_to(unit) end) or 99
    if dist > targeting.MAX_RANGE then
        release_combat()
        return false
    end
    probe("f:set_target")
    targeting.ensure_target(player, unit)
    probe("f:combat_range")
    local yards = combat_yards(player)
    -- No way closer (behind a mountain): blacklisted, the guide goes on (2.230.0).
    if type(targeting.approach_stuck) == "function" and targeting.approach_stuck(player, unit, yards) then
        release_combat()
        state.set_note("Quest", "Skip unreachable")
        return false
    end
    -- FAR TARGET: WALK IN ON A PATH (2.139.0). Combat hops stall from 35 yd
    -- (00:52 log: no progress at 32 yd). Stay on the Sentinel Navigation walk until
    -- inside the GUI engage distance + APPROACH_BAND, then combat movement
    -- finishes the close.
    --
    -- NO RELEASE / RE-TAKE LOOP (2.155.0). This released combat movement
    -- (a stop), asked navigation for the leg - refused, the move gap after a
    -- stop had not passed - then fell through to combat_engage, which took
    -- COMBAT back and could not move for the same gap; next tick, release
    -- again. The 00:49 session stood 70 s at "engage Ragged Young Wolf", and
    -- the 01:00 one dropped three boars at 30-37 yd as "unreachable" with no
    -- "approaching" line. Now combat movement is released once per target,
    -- the approach waits APPROACH_WAIT for its leg instead of falling
    -- through, and only then is the target closed on by combat movement.
    local guid_a = safe(function() return unit:get_guid() end)
    if g_appr.guid ~= guid_a then
        g_appr.guid, g_appr.since, g_appr.off, g_appr.released = guid_a, now, false, false
    end
    -- 2.240.0: a gap since the last approach tick (a rest held the cascade)
    -- restarts the wait. Without it APPROACH_WAIT had run out during the rest
    -- and the first tick after it gave up the path - "no path leg ... closing
    -- directly" at a mob 64 yd away. Same target, so `off` is cleared too.
    if (now - (g_appr.seen or now)) > 1.0 then
        g_appr.since, g_appr.off = now, false
    end
    g_appr.seen = now
    if not g_appr.off and dist > (yards + APPROACH_BAND)
        and safe(function() return player:is_in_combat() end) ~= true then
        local up = safe(function() return unit:get_position() end)
        if up then
            if not g_appr.released and type(movement.in_combat_movement) == "function"
                and movement.in_combat_movement() and type(movement.combat_release) == "function" then
                movement.combat_release()
            end
            g_appr.released = true
            if type(movement.set_approach_target) == "function" then
                movement.set_approach_target(guid_a)
            end
            -- 2.316.0: only a walk headed at the target counts as approaching.
            -- 19:37 log: a route leg to the guide point (started 0.4 s before
            -- the engage) counted, and the character walked AWAY from a
            -- Young Nightsaber - 50 -> 110 yd - until that leg ended.
            local walking = movement.is_moving()
                and not (type(movement.in_combat_movement) == "function" and movement.in_combat_movement())
                and (type(movement.headed_to) ~= "function" or movement.headed_to(up, 15))
            -- 1.25.0: in the water a straight swim at the enemy (movement.approach_to)
            local go = type(movement.approach_to) == "function" and movement.approach_to or movement.nav_to
            if walking or go(up) then
                if not walking then
                    trail("act", "approach %s on a path (%.0f yd)",
                        tostring(safe(function() return unit:get_name() end)), dist)
                end
                g_appr.since = now
                state.set_note("Quest", string.format("%s (approaching %d yd)", note or "Closing", math.floor(dist / 5) * 5))
                return true
            end
            if (now - g_appr.since) < APPROACH_WAIT then
                state.set_note("Quest", string.format("%s (approaching %d yd)", note or "Closing", math.floor(dist / 5) * 5))
                return true
            end
            g_appr.off = true
            local why = type(movement.last_fail_reason) == "function" and movement.last_fail_reason() or nil
            -- 1.2.45: the route gave this spot up as steep ground ("blacklisted"): closing "directly" walks into the
            -- cliff. Log 09:19-09:28: ONE Mountain Buzzard ridge, 11 give-ups in 9 minutes at 4/6. The unit is marked
            -- unreachable (state, 45 s - find_mob skips it) and the next scan picks another.
            if why == "blacklisted" or tostring(why or ""):find("steep", 1, true) then
                if guid_a and type(state.mark_unreachable) == "function" then state.mark_unreachable(guid_a) end
                trail("act", "%s is on ground the route cannot climb (%s) - skipped for a while, picking another",
                    tostring(safe(function() return unit:get_name() end)), tostring(why))
                release_combat()
                state.set_note("Quest", "Skip: target on steep ground")
                return false
            end
            trail("act", "no path leg to %s in %.0fs (%s%s) - closing directly",
                tostring(safe(function() return unit:get_name() end)), APPROACH_WAIT,
                tostring(why or "no reason given"),
                (type(movement.in_combat_movement) == "function" and movement.in_combat_movement())
                    and ", combat movement owns" or "")
        end
    end
    -- Inside the approach band: combat movement owns it, the tag is done.
    if type(movement.set_approach_target) == "function" then
        movement.set_approach_target(nil)
    end
    probe("f:combat_engage")
    if not movement.combat_engage(player, unit, yards) then
        if state.is_unreachable and state.is_unreachable(state.target.guid) then
            release_combat()
            state.set_note("Quest", "Skip unreachable")
            return false
        end
        -- 3.0.3: closing - walk into melee / casting range first; no cast
        -- or swing until there (a cast pauses the walk short of range)
        probe("f:face (closing)")
        movement.face(unit)
        state.set_note("Quest", note or "Closing")
        return true
    end
    -- in range: swing / auto shot, then the rotation casts
    probe("f:start_auto_attack")
    targeting.start_auto_attack(player, unit)
    probe("f:face")
    movement.face(unit)
    state.set_note("Quest", note or "Killing")
    probe("f:combat_scan")
    local pack = targeting.combat_scan(player, yards)
    probe("f:rotation.tick")
    rotation.tick(player, unit, { enemies = pack, no_move = true })
    probe("f:rotation.tick done")
    return true
end

local function engage(player, unit, note)
    -- The first fight after Start is where every crash happened; one burst
    -- there is enough. Arming on every engage wrote 15,000 lines in five
    -- minutes of normal play.
    trail("act", "engage %s (%s)", tostring(safe(function() return unit:get_name() end)), tostring(note))
    pcall(function()
        require("actlog").event("combat", "engage", tostring(note), {
            name = safe(function() return unit:get_name() end), level = safe(function() return unit:get_level() end),
            hp_pct = safe(function() return unit:get_health_percentage() end) })
    end)
    targeting.set_current(unit, "kill")
    g_kill_until = izi.now() + KILL_TIMEOUT
    fight_unit(player, unit, note)
end

--- Anything already fighting us comes first, whatever the goal is: walking on
--- to a quest giver with three mobs on your back is how a character dies.
--- THE COMBAT LOCK (2.39.0). Returns true while the fight owns the tick; the
--- quest goal and its waypoint only get the tick back once nothing is left.
---
---   1. a mob attacking the player or the pet that is not the current target
---      -> switch to the nearest one
---   2. the current kill target, while it lives -> keep fighting it
---   3. any attacker at all (the current one proved unreachable, say)
---      -> engage the nearest
---   4. still in combat but nothing in view -> hold position, up to 8 s
---
--- Attackers are looked for out to THREAT_RANGE (40 yd), not combat range
--- + 10, so a caster hitting a melee character from range counts.
-- ON THE WAY TO AN NPC (2.216.0). In combat or being attacked while a
-- turn-in / accept / talk goal is being walked, the walk always waits and the
-- fight comes first:
--   * "being attacked" counts as combat - a mob targeting the player or the
--     pet (targeting.attackers) is fought even while the player's own combat
--     flag has dropped for a moment (a fled or evading mob coming back); the
--     flag alone used to hand the tick back to the walk then.
--   * in combat with nothing in view, the hold before walking on is
--     NPC_GOAL_HOLD s instead of targeting's 8 s.
-- (A field of the existing TK table: the chunk's 200-local limit.)
TK.NPC_GOAL = { turnin = true, accept = true, talk = true }
TK.NPC_GOAL_HOLD = 30.0

local function fight_back(player, label)
    local range = targeting.THREAT_RANGE or 40
    local cur_guid = (state.target.kind == "kill") and state.target.guid or nil
    local in_combat = safe(function() return player:is_in_combat() end) == true
    local attacked = type(targeting.attackers) == "function" and targeting.attackers(player) > 0
    local attacker = targeting.attacker_to_switch(player, cur_guid, range)
    if not attacker and attacked and not in_combat
        and not (state.target.kind == "kill" and type(targeting.engaged) == "function"
            and targeting.engaged(state.target.unit)) then
        -- attacker_to_switch reads the combat flag; the attack itself is the
        -- evidence here. Never while the current kill is being fought (2.226.0).
        attacker = targeting.nearest(player, targeting.threats(player, range))
        if attacker and cur_guid ~= nil
            and safe(function() return attacker:get_guid() end) == cur_guid then
            attacker = nil                   -- already on it: step 2 keeps fighting it
        end
    end
    if attacker then
        targeting.combat_active()
        trail("act", "switch to attacker %s", tostring(safe(function() return attacker:get_name() end)))
        engage(player, attacker, "Guide: defending")
        return true
    end
    local unit = state.target.unit
    if unit and state.target.kind == "kill" then
        if fight_unit(player, unit, "Guide: " .. label) then
            targeting.combat_active()
            return true
        end
    end
    if not in_combat and not attacked then
        targeting.combat_hold(player)        -- resets the hold window
        return false
    end
    local nearest = targeting.nearest(player, targeting.threats(player, range))
    if nearest then
        targeting.combat_active()
        engage(player, nearest, "Guide: defending")
        return true
    end
    local npc_goal = TK.NPC_GOAL[g_cur_kind or ""] == true
    if targeting.combat_hold(player, npc_goal and TK.NPC_GOAL_HOLD or nil) then
        movement.nav_stop()
        state.set_note("Quest", npc_goal and ("Guide: in combat - " .. tostring(g_cur_kind) .. " waits")
            or "Guide: holding - combat not over")
        return true
    end
    return false
end

-- KILL MOBS ON THE WAY was removed in 2.188.0 with its Questing-tab box.
-- Mobs that attack are still fought (fight_back), and "Grind to XP" steps
-- still pull the nearest XP-worthy enemy (xp_goal, nearest_xp_enemy below).

local XP_GREY_GAP = 5
local CRITTER_TYPE = nil
local function xp_critter(u)
    if CRITTER_TYPE == nil then
        local ok, enums = pcall(require, "common/enums")
        CRITTER_TYPE = (ok and type(enums) == "table" and type(enums.creature_type) == "table"
            and enums.creature_type.CRITTER) or false
    end
    if not CRITTER_TYPE then return false end
    return safe(function() return u:get_creature_type() end) == CRITTER_TYPE
end

--- The nearest enemy within `range` worth XP (2.158.0): no critters, no greys.
local function nearest_xp_enemy(player, range)
    local list = targeting.find_mobs(player, nil, range, true)
    local keep = {}
    local my_level = safe(function() return player:get_level() end) or 1
    for i = 1, #(list or {}) do
        local u = list[i]
        local lvl = safe(function() return u:get_level() end) or my_level
        if not xp_critter(u) and lvl >= my_level - XP_GREY_GAP then
            keep[#keep + 1] = u
        end
    end
    local unit = targeting.nearest(player, keep)
    local d = unit and safe(function() return player:distance_to(unit) end) or nil
    return unit, d
end

local CHAIN_WP = 12

local function approach_kind()
    local kind = g_cur_kind
    if kind == "accept" or kind == "turnin" or kind == "talk" or kind == "fly" then
        return "npc"
    end
    if kind == "kill" or kind == "collect" or kind == "xp" then
        return "enemy"
    end
    return nil
end

--- Standing within `yards` of `pos`, measured flat (see ARRIVE_DZ).
-- INDOORS (2.263.0): an NPC or object position has a REAL height. Flat
-- distance with ARRIVE_DZ (12 yd, for guide waypoints whose height is a
-- terrain estimate) let the bot "arrive" under an upstairs quest giver
-- (Mountaineer Stormpike, Thelsamar, 10:11 log: three refused interacts).
-- `exact` targets need the same floor: within EXACT_DZ.
local EXACT_DZ = 2.5

local function indoors()
    local p = safe(function() return izi.me() end)
    return p and safe(function() return p:is_valid() and p:is_indoors() end) == true
end

local function near(pos, yards, exact)
    exact = exact or indoors()
    local me = safe(function() return izi.me():get_position() end)
    if not me or not pos then
        return false
    end
    local d = geometry.distance_flat(me, pos)
    -- 1.20.1: Sentinel ended its walk "arrived" a few yards short (the navmesh ends
    -- there): as near as it gets - not asked again every tick (a loop of instant walks)
    if type(d) == "number" and d > yards and not exact and type(movement.reached_short) == "function"
        and movement.reached_short(pos) then
        return true
    end
    if type(d) ~= "number" or d > yards then
        return false
    end
    if exact then
        return type(me.z) == "number" and type(pos.z) == "number"
            and math.abs(me.z - pos.z) <= EXACT_DZ
    end
    if type(me.z) ~= "number" or type(pos.z) ~= "number" or math.abs(me.z - pos.z) <= ARRIVE_DZ then
        return true
    end
    return not movement.is_moving()
end

local function walk_to(pos, note, arrive, exact)
    local indoor = indoors()
    local floor_required = exact or indoor
    arrive = arrive or ARRIVE
    if near(pos, arrive, exact) then
        return false
    end
    -- 1.20.0: no "one move_to per Zygor waypoint" branch (1.4.0) any more -
    -- guide travel is Zygor's walk: the same destination while moving is a
    -- no-op, a new one one retarget (nudge / nav_to), never a stop first.
    -- Movement treats 5 yards as arrived and stops. Asking it for another
    -- 2 yards at a building door is the stall both Kharanos sessions showed:
    -- "no progress toward the nav for 4s (7 yd) - steering".
    if arrive >= TALK_ARRIVE then
        local me = safe(function() return izi.me():get_position() end)
        local d = me and geometry.distance_flat(me, pos)
        if type(d) == "number" and d <= TALK_ARRIVE
            and not (floor_required and type(me.z) == "number" and type(pos.z) == "number"
                and math.abs(me.z - pos.z) > EXACT_DZ) then
            return false
        end
    end
    if g_force_path then
        -- A stall recovery: whatever path is running got the bot nowhere.
        g_force_path = false
        last_walk_x, last_walk_y, last_aim_x, last_aim_y = nil, nil, nil, nil
    end
    -- Only when the destination moves to a new yard: formatting the line
    -- every frame just to have errorlog throw it away is what this avoids.
    local wx, wy = math.floor(pos.x), math.floor(pos.y)
    local moved = wx ~= last_walk_x or wy ~= last_walk_y
    if moved then
        last_walk_x, last_walk_y = wx, wy
        local me = safe(function() return izi.me():get_position() end)
        trail("walk", "to (%.0f, %.0f, %.0f) %.0fy away for %s", pos.x, pos.y, pos.z,
            me and geometry.distance(me, pos) or -1, tostring(note))
    end
    local blocked_area = movement.is_blocked(pos)
    if blocked_area or movement.last_fail_offmesh() then
        movement.clear_fail()
        local me = safe(function() return izi.me():get_position() end)
        local d = me and geometry.distance_flat(me, pos)
        -- Close enough to search for the NPC instead of walking forever.
        if not floor_required and type(d) == "number" and d <= TALK_SEARCH_FAR then
            return false
        end
        -- 2.281.0: told to the guide-mismatch check (quest/mismatch.lua)
        local mm = package.loaded["quest/mismatch"]
        if type(mm) == "table" then pcall(mm.note_unreachable) end
        state.set_note("Quest", "Guide: cannot reach " .. note)
        -- 1.2.48 NOT FOR EVER: the same unreachable target for UNREACH_HOLD_S (log: "cannot reach Moonwell Water Tube",
        -- 108 stale statuses) holds its goal as blocked; the 2-minute blocked-goal rule then asks for a step skip.
        local nowu = izi.now()
        local ukey = tostring(note)
        if g_unreach.key ~= ukey or nowu < g_unreach.t0 or nowu - g_unreach.seen > 20 then
            g_unreach.key, g_unreach.t0 = ukey, nowu
        end
        g_unreach.seen = nowu
        -- 1.2.89 (log 18:40-18:45: 5 minutes standing at 3190,175 - 180 s per goal, and the next goal sat on the same point):
        -- a goal whose area is BLACKLISTED (no plan answered / walk loop) is held after 25 s, so the guide moves to the next goal
        -- or step at once; the off-mesh case keeps its 180 s.
        if nowu - g_unreach.t0 >= (blocked_area and 25 or 180) then
            local cg = guide.goal()
            if cg and not cg.held then
                trail("quest", "%s: unreachable for %d s - holding this goal", ukey, math.floor(nowu - g_unreach.t0))
                guide.hold_goal(guide.step_num(), cg.index, "blocked: cannot reach " .. ukey)
            end
            g_unreach.t0 = nowu
        end
        return true
    end
    if movement.is_quiet() or movement.in_combat_movement() then
        state.set_note("Quest", "Nav settle")
        return true
    end
    state.set_note("Quest", "Guide: " .. note)
    g_in_travel = true
    -- 2.266.0: the recorded inn / flight-path roads are gone - the
    -- destination itself is navigated (Sentinel windows).
    local target = pos
    local tx = math.floor(target.x or 0)
    local ty = math.floor(target.y or 0)
    local aim_moved = tx ~= last_aim_x or ty ~= last_aim_y
    if aim_moved then
        last_aim_x, last_aim_y = tx, ty
    end
    if type(movement.keep_path) == "function" then
        movement.keep_path(true)
    end
    if type(movement.set_approach) == "function" then
        -- A short road hop is not "closing on the NPC". Wall checks still run.
        -- The last yards use the real destination, so the NPC approach returns.
        local approach = approach_kind()
        movement.set_approach(approach)
    end
    if floor_required and type(movement.approach_to) == "function" then
        movement.approach_to(target, true, exact and "interaction" or "indoor")
        return true
    end
    if movement.is_moving() then
        -- The arrow moved, the next waypoint is up, or the road point advanced.
        -- One retarget, no stop.
        if (moved or aim_moved) and type(movement.nudge) == "function" then
            movement.nudge(target)
        end
    elseif type(movement.guide_to) == "function" then
        movement.guide_to(target)        -- 3.7.0: the exact server path, 5 yd waypoints, checked 15 yd ahead
    else
        movement.nav_to(target, true)
    end
    return true
end

--- The quest title the NPC's frames will list, for selecting it.
---
--- The quest log has it for a turnin. An accept is not in the log yet, so the
--- guide line is used with its verb stripped; quest/npc also takes a lone
--- entry without any title match, which covers most givers.
local function quest_title(goal, kind, qid)
    qid = qid or goal.quest_id
    local title = qid and guide.log_title(qid) or nil
    if title then
        return title
    end
    -- A multi-quest goal's line names several quests: no single title.
    if qid ~= goal.quest_id then
        return nil
    end
    local vm = guide.version_module()
    if vm and type(vm.quest_title) == "function" then
        local known = vm.quest_title(qid)
        if known then return known end
    end
    local text = goal.text
    if type(text) ~= "string" then
        return nil
    end
    if kind == "accept" then
        text = text:gsub("^[Aa]ccept%s+", "")
    elseif kind == "turnin" then
        text = text:gsub("^[Tt]urn%s*[Ii]n%s+", "")
    end
    return text
end

-- ----------------------------------------------------------------------------
-- BUY STEPS (2.167.0)
-- ----------------------------------------------------------------------------
-- Zygor ".buy" ("Buy 2 stacks of Light Shot") was mapped to "collect",
-- which went looking for a mob to kill. Now: the item name and amount are
-- read from the goal text, the bot walks to the step's waypoint, opens the
-- vendor there (the waypoint's named NPC, else the nearest NPC flagged
-- vendor), finds the item on the vendor by name and buys until the bags hold
-- the amount. buy_item's quantity is measured, not assumed: the first
-- purchase is one unit, and what arrives decides the size of the next.
-- Vendor item info does not exist on WoW Forever - the step is skipped there.
local BUY_TIMEOUT = 120
local BUY_GAP = 0.9
local BUY_TALK_GAP = 1.5
local BUY_FAILS = 3
local g_buy = { key = nil }
-- Known ids (2.169.0): the bags are counted before walking to a vendor, so a
-- step already done is not walked to. Lower-case name -> item id.
local BUY_IDS = {
    ["light shot"] = 2516, ["rough arrow"] = 2512, ["sharp arrow"] = 2515, ["heavy shot"] = 2519,
    ["small ammo pouch"] = 2102, ["light quiver"] = 2101,
}

local function strip_codes(t)
    t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cRXP_[%u_]-_", ""):gsub("|r", ""):gsub("|T.-|t", "")
    t = t:gsub("[%[%]]", "")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- item name, stacks (or nil), count (or nil) from "Buy 2 stacks of X" /
--- "Buy 20 X" / "Buy X".
local function parse_buy(text)
    if type(text) ~= "string" then return nil end
    local t = strip_codes(text)
    -- 2.191.0: "Buy and equip a [Small Throwing Knife]" (a Zygor vendor
    -- step) is a buy of ONE item; equip.lua wears it once the window closes.
    t = t:gsub("^([Bb]uy)%s+and%s+equip%s+", "%1 ")
    local one = t:match("^[Bb]uy%s+an?%s+(.+)$")
    if one then return one, nil, 1 end
    local n, name = t:match("^[Bb]uy%s+(%d+)%s+stacks?%s+of%s+(.+)$")
    if n then return name, tonumber(n), nil end
    n, name = t:match("^[Bb]uy%s+(%d+)x?%s+(.+)$")
    if n then return name, nil, tonumber(n) end
    name = t:match("^[Bb]uy%s+(.+)$")
    if name then return name, 1, nil end
    return nil
end

local function vendor_find(name)
    local want = string.lower(name)
    local n = safe(function() return core.game_ui.get_vendor_item_count() end) or 0
    local best = nil
    for i = 1, n do
        local info = safe(function() return core.game_ui.get_vendor_item_info(i) end)
        local iname = type(info) == "table" and type(info.item_name) == "string" and string.lower(info.item_name) or nil
        if iname and iname ~= "" then
            if iname == want then return i, info end
            if not best and (iname:find(want, 1, true) or want:find(iname, 1, true)) then best = { i, info } end
        end
    end
    if best then return best[1], best[2] end
    return nil
end

local function bag_count(item_id)
    local ok_b, bags = pcall(require, "bags")
    if not ok_b or type(bags) ~= "table" or type(bags.count) ~= "function" then return 0 end
    return bags.count(item_id) or 0
end

local function merchant_up()
    local ok_v, vendor = pcall(require, "vendor")
    return ok_v and type(vendor) == "table" and type(vendor.merchant_open) == "function" and vendor.merchant_open() == true
end

-- duplicate (audit D6): NPC by id -> targeting.find_npc is the copy to keep
local function buy_vendor_unit(player, wps)
    for i = 1, #wps do
        local title = wps[i].title
        if title then
            local u = targeting.find_named(player, title, nil, 60)
            if u and not g_buy.bad[safe(function() return u:get_guid() end) or ""] then return u end
        end
    end
    local list = targeting.visible_objects and targeting.visible_objects() or nil
    if type(list) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= true then
            local f = safe(function() return u:get_npc_flags() end)
            local g = safe(function() return u:get_guid() end)
            if type(f) == "number" and math.floor(f / 0x80) % 2 == 1 and not g_buy.bad[g or ""] then
                local d = safe(function() return player:distance_to(u) end)
                if type(d) == "number" and d <= 60 and (best_d == nil or d < best_d) then best, best_d = u, d end
            end
        end
    end
    return best
end

local function buy_done(goal, why)
    trail("act", "buy step: %s", why)
    pcall(function() core.input.close_merchant() end)
    g_buy = { key = nil }
    local ok_e, equip = pcall(require, "equip")
    if ok_e and type(equip) == "table" and type(equip.invalidate) == "function" then
        pcall(equip.invalidate)
    end
    guide.mark_goal_done(guide.step_num(), goal.index)
    return true
end

-- ITEM STEPS (2.209.0) - Zygor ".destroy <item>" and ".equip <slot>,<item>".
-- Both gate their step (RXPGuides functions.lua): .destroy until the item is
-- gone from the bags, .equip (with text) until that item is in that slot. The
-- bot walked to the waypoint and waited. The item comes from the goal text's
-- [name] through data/rxp_targets M.items; the API's container calls do the
-- work (destroy_container_item, equip_container_item). The Hearthstone is
-- never destroyed - vendor trips hearth home.
-- One file-level table (2.210.0): quest/engine.lua sits at Lua's limit of
-- 200 locals in a chunk - 2.209.0 crossed it and the file stopped compiling.
local IS = { step = { key = nil, t = 0, tries = 0 }, GAP = 1.0, TRIES = 5, NEVER_DESTROY = { [6948] = true } }
IS.prof = require("professions")   -- 2.285.0: which professions the character has (Profession API)

function IS.equipped_id(player, slot)
    local info = safe(function() return player:get_item_at_inventory_slot(slot) end)
    local obj = type(info) == "table" and info.object or nil
    return obj and safe(function() return obj:get_item_id() end) or nil
end

-- ZYGOR equip / equipped (1.2.0): target_id = the item id; complete once it
-- is worn. In the bags: core.input.use_container_item(bag, slot) (documented:
-- using armour or a weapon equips it). Not in the bags: impossible - the goal
-- is marked done here and the step retry / hold rule takes over.
IS.BUY_ZYGOR_MAX = 20
function IS.zygor_equip(player, goal, label)
    if safe(function() return player:is_in_combat() end) == true then return false end
    local now = izi.now()
    if IS.step.key ~= g_key then IS.step = { key = g_key, t = 0, tries = 0 } end
    local s = IS.step
    local ok_b, bags = pcall(require, "bags")
    local list = ok_b and type(bags) == "table" and bags.list(player) or {}
    local entry = nil
    for i = 1, #list do
        if list[i].item_id == goal.item_id then entry = list[i] break end
    end
    if not entry or s.tries >= IS.TRIES then
        trail("act", "equip step (Zygor): item %d %s - next goal", goal.item_id,
            not entry and "not in the bags (cannot be worn)" or "would not equip")
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if (now - s.t) < IS.GAP then return true end
    -- audit 2026-10-17 (H5): use_container_item SELLS while a merchant is open -
    -- close the window and wear the item on a later pass
    if merchant_up() then
        pcall(function() core.input.close_merchant() end)
        s.t = now
        return true
    end
    s.t, s.tries = now, s.tries + 1
    movement.nav_stop()
    pcall(function() require("bags").invalidate() end)   -- audit P6
    local done = safe(function() return core.input.use_container_item(entry.bag, entry.slot) end)
    state.quest_equip_id = goal.item_id      -- 1.8.0: auto-equip never swaps it out (equip.lua quest_worn)
    trail("act", "equip step (Zygor): item %d from bag %d slot %d (%s)", goal.item_id, entry.bag, entry.slot, tostring(done))
    local ok_e, eq = pcall(require, "equip")
    if ok_e and type(eq) == "table" and type(eq.invalidate) == "function" then pcall(eq.invalidate) end
    state.set_note("Quest", "Guide: equipping " .. tostring(label))
    return true
end

function IS.goal(player, goal, label)
    local a = type(goal.action) == "string" and string.lower(goal.action) or ""
    if (a == "equip" or a == "equipped") and goal.item_id then return IS.zygor_equip(player, goal, label) end
    if a ~= "destroy" and a ~= "equip" then return false end
    if type(guide.rxp_item_for) ~= "function" then return false end
    local rec = guide.rxp_item_for(goal.text or label)
    if not rec then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    local now = izi.now()
    if IS.step.key ~= g_key then IS.step = { key = g_key, t = 0, tries = 0 } end
    local s = IS.step
    local ok_b, bags = pcall(require, "bags")
    local list = ok_b and type(bags) == "table" and bags.list(player) or {}
    local entry = nil
    for i = 1, #list do
        if list[i].item_id == rec.id then entry = list[i] break end
    end
    if a == "equip" and rec.slot and IS.equipped_id(player, rec.slot) == rec.id then
        trail("act", "equip step: item %d already in slot %d", rec.id, rec.slot)
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if not entry or (a == "destroy" and IS.NEVER_DESTROY[rec.id]) or s.tries >= IS.TRIES then
        trail("act", "%s step: item %d %s - next goal", a, rec.id,
            not entry and "not in the bags" or (IS.NEVER_DESTROY[rec.id] and "is kept (Hearthstone)" or "would not move"))
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if (now - s.t) < IS.GAP then return true end
    s.t, s.tries = now, s.tries + 1
    movement.nav_stop()
    -- duplicate (audit D2): destroy a bag item -> vendor.destroy_slot is the copy to keep
    if a == "destroy" then
        pcall(function() require("bags").invalidate() end)   -- audit P6
        local done = safe(function() return core.input.destroy_container_item(entry.bag, entry.slot) end) == true
        trail("act", "destroy step: item %d (bag %d slot %d) %s", rec.id, entry.bag, entry.slot,
            done and "deleted" or "refused")
        state.set_note("Quest", "Guide: deleting " .. tostring(label))
    else
        local slot = rec.slot or 16
        local done = safe(function() return core.input.equip_container_item(entry.bag, entry.slot, slot) end) == true
        if not done then
            -- A bind-on-equip prompt holds the item; answer it (equip.lua does the same).
            local pending = safe(function() return core.game_ui.get_pending_equip_slot() end)
            if type(pending) == "number" and pending > 0 then
                pcall(function() core.input.equip_pending_item(pending) end)
            end
        end
        trail("act", "equip step: item %d into slot %d %s", rec.id, slot, done and "sent" or "pending / refused")
        local ok_e, eq = pcall(require, "equip")
        if ok_e and type(eq) == "table" and type(eq.invalidate) == "function" then pcall(eq.invalidate) end
        state.set_note("Quest", "Guide: equipping " .. tostring(label))
    end
    return true
end

--- Drive a ".buy" goal. True while it holds the tick.
-- duplicate (audit D3): buy loop -> supplies.lua is the copy to keep
local function buy_goal(player, goal, wps, label)
    local a = type(goal.action) == "string" and string.lower(goal.action) or ""
    if a ~= "buy" then
        -- 2.191.0: a ".vendor" step reading "Buy and equip a [X]" was only
        -- talked to - nothing bought, Zygor never moved on.
        if a ~= "vendor" or not parse_buy(goal.text or label) then return false end
    end
    local now = izi.now()
    if g_buy.key ~= g_key and goal.item_id and goal.target then
        -- ZYGOR buy (1.2.0): item id + name from the goal, the vendor is the
        -- step's talk NPC, the quantity never arrives - one lot at a time
        -- while Zygor's goal stays incomplete (its completion is the bag count)
        g_buy = { key = g_key, name = goal.target, item_id = goal.item_id, zygor = true, bought = 0,
            target = nil, since = now, pending = nil, fails = 0, talk_t = -1e9, bad = {} }
        trail("act", "buy step (Zygor): %s (item %d), one lot at a time", goal.target, goal.item_id)
    end
    if g_buy.key ~= g_key then
        local name, stacks, count = parse_buy(goal.text or label)
        if not name then return false end
        g_buy = { key = g_key, name = name, stacks = stacks, count = count, since = now,
            item_id = BUY_IDS[string.lower(name)], target = nil, unit_per_call = nil, pending = nil, fails = 0,
            talk_t = -1e9, bad = {} }
        if g_buy.item_id then
            local lname = string.lower(name)
            local per = (lname:find("shot", 1, true) or lname:find("arrow", 1, true)) and 200 or 1
            g_buy.target = count or ((stacks or 1) * per)
        end
        trail("act", "buy step: %s x%s", name, stacks and (tostring(stacks) .. " stack(s)") or tostring(count or 1))
    end
    local b = g_buy
    if gamever.is_forever() then
        return buy_done(goal, "vendor items cannot be read on WoW Forever - skipped")
    end
    if (now - b.since) > BUY_TIMEOUT then
        return buy_done(goal, "gave up after " .. BUY_TIMEOUT .. " s")
    end
    if b.item_id and b.target and bag_count(b.item_id) >= b.target then
        return buy_done(goal, string.format("have %d %s", bag_count(b.item_id), b.name))
    end

    if merchant_up() then
        movement.nav_stop()
        local idx, info = vendor_find(b.name)
        if not idx then
            local u = state.target and state.target.unit
            local g = u and safe(function() return u:is_valid() and u:get_guid() or nil end)
            if g then b.bad[g] = true end
            trail("act", "buy step: this vendor does not sell %s - trying another", b.name)
            pcall(function() core.input.close_merchant() end)
            return true
        end
        if b.zygor and not b.target then
            b.target = math.huge                     -- Zygor decides when it is enough
            b.lot = (type(info.quantity) == "number" and info.quantity > 0) and info.quantity or 1
        end
        if b.zygor and b.bought >= IS.BUY_ZYGOR_MAX then
            return buy_done(goal, string.format("bought %d lots of %s and Zygor still wants more - stopping", b.bought, b.name))
        end
        if not b.target then
            b.item_id = info.item_id
            local lot = (type(info.quantity) == "number" and info.quantity > 0) and info.quantity or 1
            -- A stack of ammo is 200; anything else sold by the lot counts the lot.
            local per_stack = (lot > 1) and math.max(lot, 20) or 20
            if lot >= 100 or b.name:lower():find("shot", 1, true) or b.name:lower():find("arrow", 1, true) then
                per_stack = 200
            end
            b.lot = lot
            b.target = b.count or ((b.stacks or 1) * per_stack)
            trail("act", "buy step: %s is vendor item %d (id %s, %d per purchase, %dc) - want %d",
                b.name, idx, tostring(b.item_id), lot, info.cost or 0, b.target)
        end
        local have = bag_count(b.item_id)
        if b.pending then
            if (now - b.pending.t) < BUY_GAP then return true end
            local got = have - b.pending.before
            if got > 0 then
                if not b.unit_per_call then b.unit_per_call = got / b.pending.q end
                b.fails = 0
            else
                b.fails = b.fails + 1
            end
            b.pending = nil
            if b.fails >= BUY_FAILS then
                return buy_done(goal, string.format("the vendor would not sell %s (gold %s)", b.name,
                    tostring(safe(function() return core.inventory.get_gold() end))))
            end
        end
        if have >= b.target then
            return buy_done(goal, string.format("have %d %s", have, b.name))
        end
        local cost = type(info.cost) == "number" and info.cost or 0
        local gold = safe(function() return core.inventory.get_gold() end) or 0
        if cost > 0 and gold < cost then
            return buy_done(goal, string.format("not enough gold for %s (%dc, have %dc)", b.name, cost, gold))
        end
        local q = 1
        if b.unit_per_call and b.unit_per_call > 0 then
            q = math.ceil((b.target - have) / b.unit_per_call)
            local per_call_cap = (b.unit_per_call <= 1) and 200 or 1
            q = math.max(1, math.min(q, per_call_cap))
            if cost > 0 then q = math.max(1, math.min(q, math.floor(gold / cost))) end
        end
        if b.zygor then q = 1 b.bought = b.bought + 1 end
        b.pending = { before = have, q = q, t = now }
        trail("act", "buy step: buy_item(%d, %d) - %d/%d %s", idx, q, have, b.target, b.name)
        pcall(function() require("bags").invalidate() end)   -- audit P6
        pcall(function() core.input.buy_item(idx, q) end)
        state.set_note("Quest", string.format("Guide: buying %s  %d/%d", b.name, have, b.target))
        return true
    end

    -- Not at the vendor yet: find it at the waypoint and open it (Zygor: the
    -- step's talk NPC by id first).
    local unit = goal.npc_id and targeting.find_npc(player, goal.npc_id, 60) or nil
    if unit and g_buy.bad[safe(function() return unit:get_guid() end) or ""] then unit = nil end
    unit = unit or buy_vendor_unit(player, wps)
    if not unit then
        if #wps > 0 then
            if g_move > #wps then g_move = 1 end
            if walk_to(wps[g_move].pos, label, TALK_ARRIVE) then return true end
        end
        state.set_note("Quest", "Guide: looking for the vendor - " .. tostring(label))
        return true
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > 5 then
        local up = safe(function() return unit:get_position() end)
        if up and walk_to(up, label, 4, true) then return true end
    end
    movement.nav_stop()
    if (now - b.talk_t) >= BUY_TALK_GAP then
        b.talk_t = now
        targeting.set_current(unit, "vendor")
        -- audit Q6: one action per tick - the gossip's vendor option when it is
        -- open, else the interact (never both)
        if gossip.is_open() then
            -- duplicate (audit D4): vendor gossip -> vendor.select_vendor_gossip is the copy to keep
            gossip.select({ icon = "VENDOR", icon_num = 1, type = "vendor",
                words = { "browse your goods", "let me browse", "your wares", "buy from you" } })
        else
            pcall(function() require("movement").interact(unit) end)
        end
    end
    state.set_note("Quest", "Guide: opening the vendor for " .. tostring(b.name))
    return true
end

-- QUEST TRAINER STEPS (2.149.0). The state of the train goal in progress.
local TRAIN_WAIT = 20          -- seconds at the waypoint with no trainer before moving on
local STEP_RETRY = 30          -- 2.150.0: seconds on "step complete" (our marks only) before retrying
local g_complete_since = 0
local g_train = { key = nil, at_wp = 0 }

local function is_train_action(goal)
    local a = type(goal.action) == "string" and string.lower(goal.action) or ""
    return a == "train" or a == "trainer"
end

-- PROFESSION TRAINER STEPS (2.191.0). "Train [Mining]" is a ".trainer" step
-- too, but the class trainer does not teach it: the bot looked 20 s for a
-- class trainer, marked the goal, Zygor never moved on and it retried
-- every 30 s for good ("Train [Blacksmithing]" was even "done" at the rogue
-- trainer). Now a profession step goes to a profession trainer (the
-- waypoint's title, else the nearest unit flagged 0x40 profession trainer),
-- opens its window and buys that profession's service. trainer.lua is held
-- off meanwhile so it does not spend at a profession window.
local PROFESSIONS = {
    mining = true, blacksmithing = true, herbalism = true, skinning = true, engineering = true,
    alchemy = true, tailoring = true, leatherworking = true, enchanting = true, jewelcrafting = true,
    ["first aid"] = true, cooking = true, fishing = true,
}
local NPC_PROF_TRAINER = 0x40
local PROF_TIMEOUT = 60         -- seconds for the whole profession step
local PROF_TALK_GAP = 2.5
local PROF_VERIFY = 1.5
local PROF_VERIFY_MAX = 5.0     -- 2.285.0: seconds the new skill line may take to show
local g_prof = { key = nil }
local g_prof_failed = {}        -- profession -> true: gave up this session, no re-walk on retry

--- The profession a train goal names ("Train [Mining]" -> "mining"), or nil.
local function goal_profession(goal, label)
    local t = type(goal.text) == "string" and goal.text or label
    if type(t) ~= "string" then return nil end
    t = string.lower(strip_codes(t))
    local name = t:match("^train%s+(.+)$") or t
    name = name:gsub("^apprentice%s+", ""):gsub("%s+$", "")
    if PROFESSIONS[name] then return name end
    return nil
end

local function prof_hold(on)
    local ok_x, tx = pcall(require, "trainer")
    if ok_x and type(tx) == "table" and type(tx.hold) == "function" then tx.hold(on) end
end

local function prof_done(goal, prof, why, failed)
    trail("quest", "profession step (%s): %s", prof, why)
    if failed then g_prof_failed[prof] = true end
    pcall(function() core.quests.close_trainer() end)
    pcall(function() core.quests.close_gossip() end)
    prof_hold(false)
    g_prof = { key = nil }
    guide.mark_goal_done(guide.step_num(), goal.index)
    return true
end

local function prof_has_flag(v)
    return type(v) == "number" and v > 0 and math.floor(v / NPC_PROF_TRAINER) % 2 == 1
end

local function prof_trainer_unit(player, wps, bad)
    for i = 1, #wps do
        local title = wps[i].title
        if type(title) == "string" and title ~= "" then
            local u = targeting.find_named(player, title, nil, 80)
            if u and not bad[safe(function() return u:get_guid() end) or ""] then return u end
        end
    end
    local list = targeting.visible_objects and targeting.visible_objects() or nil
    if type(list) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_player() end) ~= true
            and prof_has_flag(safe(function() return u:get_npc_flags() end))
            and safe(function() return player:can_attack(u) end) ~= true then
            local g = safe(function() return u:get_guid() end)
            local d = safe(function() return player:distance_to(u) end)
            if not bad[g or ""] and type(d) == "number" and d <= 60 and (best_d == nil or d < best_d) then
                best, best_d = u, d
            end
        end
    end
    return best
end

--- The open trainer window's row for this profession: (index, available, cost) or nil.
local function prof_service(prof)
    local n = safe(function() return core.quests.get_num_trainer_services() end) or 0
    if type(n) ~= "number" then return nil end
    for i = 1, math.min(n, 400) do
        local info = safe(function() return core.quests.get_trainer_service_info(i) end)
        local sname = type(info) == "table" and type(info.spell_name) == "string" and string.lower(info.spell_name) or ""
        if sname == prof then
            local cat = type(info.category) == "string" and string.lower(info.category) or ""
            local c = safe(function() return core.quests.get_trainer_service_cost(i) end)
            local cost = type(c) == "table" and type(c.service_cost) == "number" and c.service_cost or 0
            return i, (cat == "" or cat == "available"), cost
        end
    end
    return nil
end

--- Drive a profession ".trainer" goal. True while it holds the tick.
local function prof_goal(player, goal, wps, label)
    if not is_train_action(goal) then
        if g_prof.key then prof_hold(false) g_prof = { key = nil } end
        return false
    end
    local prof = goal_profession(goal, label)
    if not prof then
        if g_prof.key then prof_hold(false) g_prof = { key = nil } end
        return false
    end
    local now = izi.now()
    if g_prof.key ~= g_key then
        g_prof = { key = g_key, since = now, talk_t = -1e9, bad = {}, pending = nil, opened = nil }
        if g_prof_failed[prof] then
            return prof_done(goal, prof, "no profession trainer earlier this session - skipped")
        end
        -- 2.285.0 (Profession API): no trip for a profession already known,
        -- nor for a third primary profession (the trainer refuses it)
        local known, rank, max_rank = IS.prof.known(prof)
        if known then
            return prof_done(goal, prof, string.format("already known (skill %d/%d)", rank or 0, max_rank or 0))
        end
        local can, why_not_learn = IS.prof.can_learn(prof)
        if not can then
            require("actlog").console_warn("[Master Farmer - Zygor Forever] Cannot learn " .. prof .. ": " .. tostring(why_not_learn) .. ".")
            return prof_done(goal, prof, tostring(why_not_learn), true)
        end
        prof_hold(true)
        trail("quest", "profession step: looking for a %s trainer for %s", prof, tostring(label))
    end
    local p = g_prof
    if (now - p.since) > PROF_TIMEOUT then
        return prof_done(goal, prof, "gave up after " .. PROF_TIMEOUT .. " s", true)
    end

    local n_serv = safe(function() return core.quests.get_num_trainer_services() end) or 0
    if type(n_serv) == "number" and n_serv > 0 then
        movement.nav_stop()
        p.opened = p.opened or now
        pcall(function() core.skill.expand_trainer_skill_line(0) end)
        local idx, avail, cost = prof_service(prof)
        if p.pending then
            -- 2.285.0: learned = the profession's skill line is there now
            local known, rank, max_rank = IS.prof.known(prof)
            if known then
                return prof_done(goal, prof, string.format("learned (skill %d/%d)", rank or 0, max_rank or 0))
            end
            if (now - p.pending) < PROF_VERIFY then return true end
            -- no skill line yet: a moment more while the row still offers it
            if idx and avail and (now - p.pending) < PROF_VERIFY_MAX then return true end
            p.pending = nil
            if not idx or not avail then
                return prof_done(goal, prof, "learned")
            end
            return prof_done(goal, prof, "the trainer would not teach it (gold "
                .. tostring(safe(function() return core.inventory.get_gold() end)) .. ")", true)
        end
        if not idx then
            -- The window lists other things (another profession's trainer,
            -- or rows still loading): give it a moment, then try another NPC.
            if (now - p.opened) < 2 then return true end
            local u = state.target and state.target.unit
            local g = u and safe(function() return u:is_valid() and u:get_guid() or nil end)
            if g then p.bad[g] = true end
            trail("quest", "profession step: this trainer does not teach %s - trying another", prof)
            pcall(function() core.quests.close_trainer() end)
            p.opened = nil
            return true
        end
        if not avail then
            return prof_done(goal, prof, "already known (or not offered yet)")
        end
        local gold = safe(function() return core.inventory.get_gold() end) or 0
        if cost > 0 and gold < cost then
            return prof_done(goal, prof, string.format("not enough gold (%dc, have %dc)", cost, gold), true)
        end
        trail("quest", "profession step: buying %s (service %d, %dc)", prof, idx, cost)
        pcall(function() core.quests.buy_trainer_service(idx) end)
        p.pending = now
        state.set_note("Quest", "Guide: learning " .. prof)
        return true
    end
    p.opened = nil

    local unit = prof_trainer_unit(player, wps, p.bad)
    if not unit then
        if #wps > 0 then
            if g_move > #wps then g_move = 1 end
            if walk_to(wps[g_move].pos, label, TALK_ARRIVE) then return true end
        end
        state.set_note("Quest", "Guide: looking for the " .. prof .. " trainer")
        return true
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > 5 then
        local up = safe(function() return unit:get_position() end)
        if up and walk_to(up, label, 4, true) then return true end
    end
    movement.nav_stop()
    if (now - p.talk_t) >= PROF_TALK_GAP then
        p.talk_t = now
        targeting.set_current(unit, "trainer")
        if gossip.is_open() then
            if not gossip.select({ icon = "TRAINER", icon_num = 3, type = "trainer",
                    words = { "train", "teach", "learn" } }) then
                local g = safe(function() return unit:get_guid() end)
                if g then p.bad[g] = true end
                trail("quest", "profession step: %s offers no training - trying another",
                    tostring(safe(function() return unit:get_name() end)))
                pcall(function() core.quests.close_gossip() end)
            end
        else
            pcall(function() require("movement").interact(unit) end)
        end
    end
    state.set_note("Quest", "Guide: opening the " .. prof .. " trainer")
    return true
end

-- ZYGOR TRAINER (1.3.0, 2026-10-17 log: "doesn't move to the NPC and train
-- mining"). A Zygor `trainer` goal names its NPC (npc_id / npc) but never the
-- profession, and trainer.lua buys CLASS spells only (a service with a
-- profession cost is skipped) - at Gelman Stonehand it would learn nothing.
-- This visit walks to Zygor's trainer by id (its exact position, inside the
-- building), opens its window and learns every service it offers that is
-- available and affordable: no talent-cost rows; a row with a profession cost
-- only when IS.prof.can_learn says a profession slot is free. Done when
-- nothing more can be learned (or ZT_TIMEOUT); Zygor ticks its own goals.
IS.ZT = { key = nil, TIMEOUT = 90, BUY_GAP = 1.5 }
--- A trainer visit: a Zygor `trainer` goal with its NPC, or a `talk` goal
--- whose step also wants a skill learned (skill / skillmax unfinished).
function IS.is_zygor_trainer(goal)
    if not goal.npc_id then return false end
    if goal.action == "trainer" then return true end
    if goal.action ~= "talk" then return false end
    local goals = guide.goals()
    for i = 1, #goals do
        local a = goals[i].action
        if (a == "skill" or a == "skillmax") and goals[i].is_complete ~= true then return true end
    end
    return false
end

function IS.zygor_trainer(player, goal, wps, label)
    if not IS.is_zygor_trainer(goal) then return false end
    local zt = IS.ZT
    local now = izi.now()
    if zt.key ~= g_key then
        zt.key, zt.since, zt.talk_t, zt.buy_t, zt.tried, zt.learned = g_key, now, -1e9, -1e9, {}, {}
        prof_hold(true)
        trail("quest", "trainer step (Zygor): npc %d %s", goal.npc_id, tostring(goal.npc))
    end
    local function finish(why)
        trail("quest", "trainer step (Zygor) done: %s%s", why,
            #zt.learned > 0 and (" - learned " .. table.concat(zt.learned, ", ")) or "")
        pcall(function() core.quests.close_trainer() end)
        pcall(function() core.quests.close_gossip() end)
        prof_hold(false)
        zt.key = nil
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if (now - zt.since) > zt.TIMEOUT then return finish("gave up after " .. zt.TIMEOUT .. " s") end
    local n = safe(function() return core.quests.get_num_trainer_services() end) or 0
    if type(n) == "number" and n > 0 then
        movement.nav_stop()
        pcall(function() core.skill.expand_trainer_skill_line(0) end)
        if (now - zt.buy_t) < zt.BUY_GAP then return true end
        local gold = safe(function() return core.inventory.get_gold() end) or 0
        for i = 1, n do
            local info = safe(function() return core.quests.get_trainer_service_info(i) end)
            local cost = safe(function() return core.quests.get_trainer_service_cost(i) end)
            local name = type(info) == "table" and info.spell_name or nil
            local cat = type(info) == "table" and type(info.category) == "string" and string.lower(info.category) or ""
            if type(name) == "string" and name ~= "" and cat == "available" and type(cost) == "table"
                and (cost.talent_cost or 0) == 0 and not zt.tried[name] then
                local price = tonumber(cost.service_cost) or 0
                local ok_prof = true
                if (cost.profession_cost or 0) ~= 0 then
                    local can = IS.prof.can_learn(string.lower(name))
                    ok_prof = can == true
                end
                if ok_prof and price <= gold then
                    zt.tried[name], zt.buy_t = true, now
                    zt.learned[#zt.learned + 1] = name
                    trail("act", "trainer (Zygor): learning %s (%dc)", name, price)
                    pcall(function() core.quests.buy_trainer_service(i) end)
                    state.set_note("Quest", "Guide: learning " .. name)
                    return true
                end
                zt.tried[name] = true
            end
        end
        return finish("nothing more to learn here")
    end
    local unit = targeting.find_npc(player, goal.npc_id, 100)
    if not unit then return false end                  -- walk the goal's route toward it
    if gossip.is_open() then
        if (now - zt.talk_t) >= PROF_TALK_GAP then
            zt.talk_t = now
            if not gossip.select({ icon = "TRAINER", icon_num = 3, type = "trainer",
                    words = { "train", "teach", "learn" } }) then
                pcall(function() core.quests.close_gossip() end)
            end
        end
        state.set_note("Quest", "Guide: opening the trainer - " .. tostring(label))
        return true
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > TALK_REACH then
        local up = safe(function() return unit:get_position() end)
        if up and walk_to(up, label, TALK_REACH - 0.5, true) then return true end
    end
    movement.nav_stop()
    if (now - zt.talk_t) >= PROF_TALK_GAP then
        zt.talk_t = now
        targeting.set_current(unit, "trainer")
        pcall(function() require("movement").interact(unit) end)
    end
    state.set_note("Quest", "Guide: talking to the trainer " .. tostring(goal.npc or ""))
    return true
end

-- ZYGOR GOTO HAND-OFF (1.3.0). A goto is positioning for the step's other
-- goals (Stormwind 60,36 = the door of the mining trainer's building). The
-- bot stood within ARRIVE of the converted point and Zygor never ticked the
-- goto (its own radius), so the step's trainer goal was never reached. Once
-- at the point GOTO_SETTLE s, with another unfinished goal of the step to work
-- on, the goto is counted done locally and that goal is next - an NPC goal
-- then walks to the NPC itself.
IS.GOTO_SETTLE = 2.0
IS.NOT_WORK_KINDS = { text = true, avoid = true, ["goto"] = true }
IS.goto_at = { key = nil, t = 0 }
function IS.goto_hand_off(goal, label)
    local now = izi.now()
    if IS.goto_at.key ~= g_key then IS.goto_at.key, IS.goto_at.t = g_key, now end
    if (now - IS.goto_at.t) < IS.GOTO_SETTLE then return false end
    local goals = guide.goals()
    for i = 1, #goals do
        local g = goals[i]
        if g.index ~= goal.index and g.is_complete ~= true and not IS.NOT_WORK_KINDS[guide.classify(g)] then
            trail("quest", "at %s - Zygor has not ticked the goto; moving on to goal %d (%s %s)",
                tostring(label), g.index, tostring(g.action), tostring(g.text or g.quest_id or ""))
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
    end
    return false
end

--- Drive a ".train" / ".trainer" goal. True while it holds the tick.
local function train_goal(player, goal, wps, label)
    if goal_profession(goal, label) then return false end
    if not is_train_action(goal) then
        if g_train.key then
            g_train.key = nil
            local ok_x, tx = pcall(require, "trainer")
            if ok_x and type(tx) == "table" and type(tx.quest_visit) == "function" then
                tx.quest_visit(false)
            end
        end
        return false
    end
    local ok_tr, tr = pcall(require, "trainer")
    if not ok_tr or type(tr) ~= "table" or type(tr.quest_visit) ~= "function" then
        return false
    end
    if gui.is_on("train") ~= true then
        trail("quest", "trainer goal skipped - Train Spells is off")
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if g_train.key ~= g_key then
        g_train.key, g_train.at_wp = g_key, 0
        local title = nil
        for i = 1, #wps do
            if type(wps[i].title) == "string" and wps[i].title ~= "" then title = wps[i].title break end
        end
        -- 2.206.0: the guide file's ".trainer <npc>" id, when it names one.
        -- ZYGOR: a trainer goal names its NPC (npc_id / npc)
        local tid = goal.npc_id
        if goal.npc and goal.npc ~= "" then title = goal.npc end
        tr.quest_visit(false)
        tr.quest_visit(true, title, tid)
        trail("quest", "trainer step: visiting the class trainer for %s%s%s", tostring(label),
            title and (" (" .. title .. ")") or "", tid and (" npc " .. tostring(tid)) or "")
    end
    if tr.quest_visit_done() then
        trail("quest", "trainer step done - %s", tostring(label))
        tr.quest_visit(false)
        g_train.key = nil
        g_train.done_step, g_train.done_t = guide.step_num(), izi.now()
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    -- 2.292.0: TRAINED ALL WE COULD, ZYGOR STILL ON THE STEP. A ".train"
    -- step completes only when the spell is learned; with "1 more need more
    -- gold" (Train [Battle Shout] at Sten Stoutarm, 23:52 session) the bot
    -- re-opened the trainer every 30 s for minutes, the trainer NPC's quests
    -- waiting meanwhile. After the visit hold this goal with the trainer's answer;
    -- the trainer is visited again by
    -- the every-3-levels check once there is gold.
    if g_train.done_step == guide.step_num() and g_train.done_t
        and (izi.now() - g_train.done_t) >= 3 then
        g_train.done_step, g_train.done_t = nil, nil
        local why = (type(tr.last_msg) == "string" and tr.last_msg ~= "") and tr.last_msg or "nothing more to train"
        guide.hold_goal(guide.step_num(), goal.index, "blocked: " .. why)
        return true
    end
    -- trainer.tick runs earlier in the cascade and walks to / talks to a
    -- trainer in sight; while it does, the quest engine waits.
    if (type(tr.busy) == "function" and tr.busy()) or tr.in_sight(player) then
        state.set_note("Quest", "Guide: training - " .. tostring(label))
        return true
    end
    -- No trainer in sight yet: walk the step's waypoints.
    if #wps > 0 then
        if g_move > #wps then g_move = 1 end
        if walk_to(wps[g_move].pos, label, TALK_ARRIVE) then
            g_train.at_wp = 0
            return true
        end
    end
    local now = izi.now()
    if g_train.at_wp == 0 then g_train.at_wp = now end
    if (now - g_train.at_wp) >= TRAIN_WAIT then
        trail("quest", "trainer step: no class trainer found in %ds - next goal", TRAIN_WAIT)
        tr.quest_visit(false)
        g_train.key = nil
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    state.set_note("Quest", "Guide: looking for the trainer - " .. tostring(label))
    return true
end

--- Find the NPC for an accept, a turnin or a talk goal.
---
--- In order of how certain the answer is:
---   1. an NPC learned for this exact quest on an earlier visit
---   2. the waypoint's title, which Zygor sets to the NPC it points at
---   3. the player's own target, when it is a friendly creature
---   4. the nearest friendly unit standing at the waypoint
-- NPCs that did not offer this goal's quest, or ran out of tries (2.50.0).
-- GUID -> true; cleared when the goal changes. find_giver skips them, so a
-- guard picked as "nearest at the waypoint" is not retried until the
-- watchdog steps in.
local g_bad_givers = {}

local function npc_id_of_unit(u)
    local id = u and safe(function() return u:get_npc_id() end) or nil
    if type(id) == "number" and id > 0 then return id end
    return nil
end
local g_giver_learned = nil   -- 2.185.0: { kind, qid, npc, text } when the giver came from a learned id

-- 2.297.0: NPC BLACKLIST. An NPC whose interaction still failed after a
-- retry and a UI reload is left alone for BLACK_FOR seconds (by guid and npc
-- id). Kept in TK (engine.lua is at Lua's 200-local limit).
TK.black = {}                  -- "g:<guid>" / "id:<npc id>" -> until
TK.RELOAD_WAIT = 30
TK.GOSSIP_WAIT = 6             -- 1.6.0: s a gossip frame stays open for Zygor's auto-gossip
TK.CLICK_DONE = 2.0            -- 1.6.0: s after a clicknpc interact (no window) it counts as clicked
TK.PASSIVE_WAIT = 20           -- 1.6.0: s at a passive goal's waypoint with nothing of it in sight
TK.BLACK_FOR = 1800
local function blacklisted(unit)
    if not unit then return false end
    local now = izi.now()
    local g = safe(function() return unit:get_guid() end)
    local id = npc_id_of_unit(unit)
    -- audit 1.19.0: ipairs stopped at a nil guid key, so the npc-id entry was
    -- never checked for a unit whose guid could not be read
    local keys = { g and ("g:" .. g) or false, id and ("id:" .. id) or false }
    for i = 1, 2 do
        local k = keys[i]
        if k and TK.black[k] then
            if TK.black[k] > now then return true end
            TK.black[k] = nil
        end
    end
    return false
end

--- g_bad_givers plus the blacklisted guids, for the guide's searches.
function TK.excl()
    local now, set = izi.now(), {}
    for g, v in pairs(g_bad_givers) do set[g] = v end
    for k, t in pairs(TK.black) do
        if t > now and k:sub(1, 2) == "g:" then set[k:sub(3)] = true end
    end
    return set
end

local function bad(unit)
    local g = unit and safe(function() return unit:get_guid() end)
    return (g ~= nil and g_bad_givers[g] == true) or blacklisted(unit)
end

-- AT THE GOAL (2.215.0). A name, a learned id or the player's target only
-- identifies the NPC when it stands at the goal's waypoint - Zygor's
-- .goto for a dialog step is the NPC's own spot. Searched around the PLAYER,
-- a turn-in picked Grelin Whitebeard 6 yd away while the guide pointed
-- 200 yd off. No waypoint: anywhere in range, as before.
local function at_goal(unit, wps)
    if #wps == 0 then return true end
    local up = safe(function() return unit:get_position() end)
    if not up then return false end
    for i = 1, #wps do
        local p = wps[i].pos
        local d = p and geometry.distance_flat(up, p)
        if type(d) == "number" and d <= TALK_SEARCH_FAR then return true end
    end
    return false
end

--- 1.5.2: the nearest valid, living unit with this NPC id that is not "bad"
--- (talked to already on this goal / blacklisted), within `range`.
-- duplicate (audit D6): NPC by id -> targeting.find_npc is the copy to keep
local function nearest_npc_by_id(player, npc_id, range)
    local list = targeting.visible_objects and targeting.visible_objects() or nil
    if type(list) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true and safe(function() return u:is_unit() end) == true
            and safe(function() return u:get_npc_id() end) == npc_id
            and safe(function() return u:is_dead() end) ~= true and not bad(u) then
            local d = safe(function() return player:distance_to(u) end)
            if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then best, best_d = u, d end
        end
    end
    return best
end

local function find_giver(player, goal, kind, wps, qid)
    qid = qid or goal.quest_id
    -- 1.4.0 (Zygor spec): the NPC is found ONLY by get_npc_id == goal.npc_id (a
    -- gossip / home / buy goal borrows the step's talk NPC id). Not visible:
    -- the caller walks to the goal's waypoint and waits - no name, learned id,
    -- raid marker, waypoint title, player target or nearest-NPC guess.
    if goal.npc_id then
        -- 1.5.0: 300 yd; 1.5.2: the nearest one not talked to yet (a goal with
        -- several NPCs of the id - six Scared Civilians - takes them in turn)
        local unit = nearest_npc_by_id(player, goal.npc_id, 300)
        if unit then
            return unit, "zygor npc id " .. tostring(goal.npc_id)
        end
        return nil, nil
    end
    -- 1.17.0 (user: "Player not interacting with objects to turn in quests"):
    -- no talk NPC - the step's click goal names the OBJECT that gives / takes
    -- the quest ("click Scourge Cauldron" / turnin Target: Dalson's Tears##5219,
    -- "click Mrs. Dalson's Diary" / accept ##5058). Found by name, nearest the
    -- click goal's waypoint (guide.find_object), opened with use_object
    -- (movement.interact).
    if kind == "accept" or kind == "turnin" then
        local shaped = guide.goals() or {}
        for i = 1, #shaped do
            local sg = shaped[i]
            if type(sg) == "table" and sg.action == "click" and not sg.quest_id then
                local o = guide.find_object(player, 300, sg)
                if o and not bad(o) then
                    return o, "zygor click object '" .. tostring(safe(function() return o:get_name() end)) .. "'"
                end
            end
        end
    end
    return nil, nil
end

--- A goal changed: if the previous one was a dialog the bot drove and it
--- landed, record the NPC as that quest's giver or taker.
local function commit_pending()
    -- The goal's identified-NPC state goes with the goal (2.215.0). Reset here,
    -- not in tick_inner's goal-change block that calls this (2.218.0): one more
    -- upvalue there (TK) made tick_inner 61 upvalues, past the client Lua's
    -- limit of 60, and quest/engine.lua stopped compiling in game.
    TK.gid.tried, TK.gid.refused = nil, nil
    local p = g_pending
    g_pending = nil
    if not p or not p.npc_id or not p.quest_id then
        return
    end
    local on = safe(function() return core.quests.is_on_quest(p.quest_id) end) == true
    -- A turn-in is proven by the hand-in, not by the quest being gone
    -- (2.215.0): a timed quest that expired is gone too, and Grelin
    -- Whitebeard was learned as the taker of Scalding Mornbrew that way.
    local turned = npc.was_turned_in(p.quest_id)
        or safe(function() return core.quests.is_quest_flagged_completed(p.quest_id) end) == true
    local landed = (p.kind == "accept" and on) or (p.kind == "turnin" and not on and turned)
    if landed then
        guide.learn_quest_npc(p.kind, p.quest_id, p.npc_id)
        debug("learned %s npc %d for quest %d", p.kind, p.npc_id, p.quest_id)
    end
end

-- ----------------------------------------------------------------------------
-- GOAL HANDLERS
-- ----------------------------------------------------------------------------

--- The quest this accept / turn-in goal is about right now (2.134.0).
---
--- Zygor names it in quest_id, or in ids for a multi-quest goal
--- (acceptmultiple / turninmultiple), which used to fall through to the
--- generic talk path: the bot opened a frame, called the goal done after two
--- seconds and never handed anything in. The first id still to do wins:
--- an accept not yet in the log and never completed, a turn-in in the log and
--- not handed in this session.
---
--- Returns (quest_id) to work on, or (nil, why) when every id the goal names
--- is already satisfied - Zygor's snapshot can lag a tick, or the player
--- did it by hand (2.63.0) - or the goal names none.
local function resolve_quest(goal, kind)
    local ids = guide.goal_quest_ids(goal)
    if #ids == 0 then
        return nil, "names no quest"
    end
    local skipped = type(state.quest.skipped) == "table" and state.quest.skipped or {}
    for i = 1, #ids do
        local id = ids[i]
        -- 2.286.0: the quest log by id list and title too (npc.in_log)
        local on = npc.in_log(id, quest_title(goal, kind, id))
        local done = IS.DONE.done(id)                 -- 1.13.0: the completed-quest set
        if kind == "accept" then
            if on ~= true and not done and not skipped[id] then
                return id
            end
        elseif on == true and not npc.was_turned_in(id) then
            return id
        elseif on == nil and not done and not npc.was_turned_in(id) then
            -- The build cannot say: try it, the NPC's list decides.
            return id
        end
    end
    if kind == "accept" then
        return nil, "already accepted or completed"
    end
    return nil, "no quest of this goal is in the log (handed in, or never taken)"
end

--- Anything the quest log says about the goal's quests, as one string, so
--- a change between ticks counts as progress.
local function log_signature(goal)
    local ids = guide.goal_quest_ids(goal)
    local parts = {}
    for i = 1, #ids do
        local id = ids[i]
        local on = safe(function() return core.quests.is_on_quest(id) end) == true
        local done = safe(function() return core.quests.is_quest_flagged_completed(id) end) == true
        parts[#parts + 1] = (on and "1" or "0") .. (done and "1" or "0")
    end
    return table.concat(parts, ",")
end

local function stall_reset(now)
    g_stall.t, g_stall.seen, g_stall.best, g_stall.reach = now, now, nil, false
    g_stall.npc_seq, g_stall.log, g_stall.recoveries, g_stall.pos, g_stall.talked = nil, nil, 0, nil, nil
    g_stall.giver = nil
end

--- Record this tick's progress. `d` is the distance to what the bot is
--- walking to (the NPC, or the waypoint while no NPC is found). Returns true
--- when STALL_AFTER seconds have passed without any.
local function stalled(now, goal, d)
    -- A transport error is not a failed NPC interaction or an impossible goal.
    if movement.transport_blocked and movement.transport_blocked() then
        g_stall.t, g_stall.seen = now, now
        return false
    end
    -- 1.2.51: a walk still waiting for Sentinel's path is the server being slow
    -- (Stormwind waited 36 s; the 30 s rule restarted it and reset the wait).
    -- Wait up to 90 s for it; after that it counts as no progress again.
    if movement.awaiting_path and movement.awaiting_path() then
        g_stall.await0 = g_stall.await0 or now
        if (now - g_stall.await0) < 90 then
            g_stall.t, g_stall.seen = now, now
            return false
        end
    else
        g_stall.await0 = nil
    end
    -- 2.281.0: a held guide mismatch is not a stall (recoveries would skip
    -- one guide goal after another).
    local mm = package.loaded["quest/mismatch"]
    if type(mm) == "table" and mm.held() then
        g_stall.t, g_stall.seen = now, now
        return false
    end
    -- Ticks spent fighting, resting or looting are not this goal's time.
    if (now - g_stall.seen) > 1.0 then
        g_stall.t = now
    end
    g_stall.seen = now
    local moved = false
    if type(d) == "number" then
        -- Circling a door at 5-8 yards looks like 2-yard gains. Once we are
        -- that close, only reaching the NPC (or a dialog / log change) counts.
        local was_far = g_stall.best == nil or g_stall.best > TALK_ARRIVE
        if g_stall.best == nil or d < g_stall.best - STALL_GAIN then
            if was_far or d <= TALK_REACH then
                g_stall.best = d
                moved = true
            elseif d < g_stall.best then
                g_stall.best = d
            end
        end
        local in_reach = d <= TALK_REACH
        if in_reach and not g_stall.reach then
            moved = true
        end
        g_stall.reach = in_reach
    end
    local ns = npc.progress_seq()
    if ns ~= g_stall.npc_seq then
        g_stall.npc_seq = ns
        moved = true
    end
    local sig = log_signature(goal)
    if sig ~= g_stall.log then
        g_stall.log = sig
        moved = true
    end
    if g_talk_opened ~= 0 and g_stall.talked ~= true then
        g_stall.talked = true
        moved = true
    end
    if moved then
        g_stall.t = now
        return false
    end
    return (now - g_stall.t) >= STALL_AFTER
end

--- The recovery sequence for a stalled NPC goal. Returns true when the goal
--- was given up on.
local function recover_stall(now, goal, label)
    -- A stall at a learned NPC (2.185.0): the pairing is suspect - forget it.
    if g_giver_learned and g_giver_learned.npc then
        trail("act", "%s: stalled at learned npc %d - forgotten", tostring(label), g_giver_learned.npc)
        guide.forget_quest_npc(g_giver_learned.kind, g_giver_learned.qid, g_giver_learned.npc, g_giver_learned.text)
        g_giver_learned = nil
    end
    g_stall.recoveries = g_stall.recoveries + 1
    -- 2.297.0: THE LADDER for an NPC that was found: 1st stall - retry the
    -- interaction; 2nd - retry; 3rd -
    -- blacklist the NPC for 30 minutes and move on.
    local gv = g_stall.giver
    local step_txt = ({ "retrying the interaction", "retrying again", "blacklisting the NPC" })[g_stall.recoveries]
    trail("act", "%s: no progress for %.0f s - recovery %d of %d%s", tostring(label),
        STALL_AFTER, g_stall.recoveries, STALL_MAX,
        (gv and step_txt) and (" (" .. tostring(gv.name) .. ": " .. step_txt .. ")") or "")
    npc.close()
    movement.nav_stop()
    guide.invalidate()
    g_giver_walk = nil
    g_talk_opened = 0
    g_act_until = 0
    g_hold_until = 0
    g_close_in = false
    g_bind_asked = false
    g_bad_givers = {}
    g_bad_since = 0
    TK.gid.tried, TK.gid.refused = nil, nil
    g_force_path = true
    g_stall.t, g_stall.best, g_stall.reach = now, nil, false
    -- 1.6.0 (audit: after the ladder's UI reload Zygor read "no active step" and the
    -- continent broke): no UI reload - the 2nd rung is a plain retry
    if gv and g_stall.recoveries >= STALL_MAX then
        local until_t = now + TK.BLACK_FOR
        if gv.guid then TK.black["g:" .. gv.guid] = until_t end
        if gv.id then TK.black["id:" .. gv.id] = until_t end
        require("actlog").console_warn(string.format(
            "[Master Farmer - Zygor Forever] %s: %s did not respond after two retries - blacklisted for 30 minutes.",
            tostring(label), tostring(gv.name)))
        g_stall.giver = nil
        g_stall.recoveries = 0
        guide.hold_goal(guide.step_num(), goal.index, "blocked: " .. tostring(gv.name) .. " did not respond")
        return true
    end
    if g_stall.recoveries >= STALL_MAX then
        -- Hold only this goal. The step watchdog owns the final extended-stall skip.
        local key = (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index)))
        TK.gave_up = key
        g_stall.recoveries = 0
        require("actlog").console_warn(string.format(
            "[Master Farmer - Zygor Forever] Quest goal '%s': no progress after %d recoveries - holding this goal.",
            tostring(label), STALL_MAX))
        guide.hold_goal(guide.step_num(), goal.index, "blocked: no progress after interaction retries")
        return true
    end
    return false
end

-- FAILED QUESTS (2.162.0). A timed quest (Scalding Mornbrew Delivery: a hot
-- drink to deliver in minutes) that runs out cannot be handed in - the NPC
-- simply does not list it, and the 12:24 session "tried another NPC" at
-- every unit near the trainer. The quest log says so (is_complete == -1):
-- the quest is abandoned, the bot walks back to where it was accepted,
-- takes it again, and the turn-in goal carries on. Where each quest was
-- accepted is remembered (npc id + position), saved with the settings.
local g_accept_at = {}       -- quest id -> { npc = id, x, y, z }
local g_redo = nil           -- { qid, title, npc, pos, since }
local REDO_TIMEOUT = 180

do
    local ok_s, settings = pcall(require, "settings")
    if ok_s and type(settings) == "table" and type(settings.register) == "function" then
        settings.register("accept_at", function()
            local parts = {}
            for qid, a in pairs(g_accept_at) do
                parts[#parts + 1] = string.format("%d:%d:%.1f:%.1f:%.1f", qid, a.npc, a.x, a.y, a.z)
            end
            return #parts > 0 and table.concat(parts, ";") or nil
        end, function(v)
            if type(v) ~= "string" then return end
            for qid, id, x, y, z in v:gmatch("(%d+):(%d+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+)") do
                g_accept_at[tonumber(qid)] = { npc = tonumber(id), x = tonumber(x), y = tonumber(y), z = tonumber(z) }
            end
        end)
    end
end

local function remember_accept(qid, npc_id, unit)
    local p = unit and safe(function() return unit:get_position() end)
    if type(qid) ~= "number" or type(npc_id) ~= "number" or not p then return end
    g_accept_at[qid] = { npc = npc_id, x = p.x, y = p.y, z = p.z }
    local ok_s, settings = pcall(require, "settings")
    if ok_s and type(settings) == "table" and type(settings.mark_dirty) == "function" then
        settings.mark_dirty()
    end
end

--- Walk back to the giver of a failed quest and take it again. True while
--- it holds the tick.
local function redo_accept(player, goal, label)
    local r = g_redo
    if not r then return false end
    local now = izi.now()
    if safe(function() return core.quests.is_on_quest(r.qid) end) == true then
        trail("act", "quest %d taken again - back to the turn-in", r.qid)
        g_redo = nil
        return false
    end
    if (now - r.since) > REDO_TIMEOUT then
        trail("act", "could not take quest %d again in %ds - skipping the turn-in", r.qid, REDO_TIMEOUT)
        g_redo = nil
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    local unit = targeting.find_npc(player, r.npc, 40)
    local up = unit and safe(function() return unit:get_position() end)
    local d = up and geometry.distance_flat(safe(function() return player:get_position() end) or up, up)
    if not unit or (type(d) == "number" and d > TALK_ARRIVE) then
        local dest = up or r.pos
        if walk_to(dest, "take " .. tostring(r.title) .. " again", TALK_ARRIVE) then
            state.set_note("Quest", "Guide: going back to take " .. tostring(r.title) .. " again")
            return true
        end
        if not unit then
            state.set_note("Quest", "Guide: looking for the giver of " .. tostring(r.title))
            return true
        end
    end
    movement.nav_stop()
    local result = npc.accept(player, r.qid, r.title, r.npc, unit)
    if result == "done" or result == "skipped" then
        npc.close_frames()
        trail("act", "quest %d taken again - back to the turn-in", r.qid)
        g_redo = nil
        return true                    -- audit Q7: the close is this tick's action
    end
    if result == "not_offered" or result == "gave_up" or result == "bags_full" then
        npc.close()
        trail("act", "the giver would not offer quest %d again (%s) - skipping the turn-in", r.qid, tostring(result))
        g_redo = nil
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    state.set_note("Quest", "Guide: taking " .. tostring(r.title) .. " again")
    return true
end

-- 1.29.4: a quest started by a bag item (data/quest_items S: Zygor ".use id
-- >> to start the quest", Zygor "use X / accept X"): the item is used, the
-- quest panel it opens accepted - no NPC to find. TK.START_TRIES uses.
TK.START_TRIES, TK.START_GAP = 3, 3.0
function TK.item_accept(player, qid, label, goal)
    local ok_qi, qi = pcall(require, "questitems")
    local item = ok_qi and type(qi) == "table" and qi.starter_for(qid) or nil
    if not item then return TK.bag_start(qid, label, goal) end
    if safe(function() return core.quests.is_on_quest(qid) end) == true then return false end
    local okb, bags = pcall(require, "bags")
    if not (okb and type(bags) == "table" and (tonumber(bags.count(item)) or 0) > 0) then return false end
    local now = izi.now()
    TK.start = (TK.start and TK.start.qid == qid) and TK.start or { qid = qid, tries = 0, t = -1e9 }
    local panel = npc.open_panel()
    if panel and (panel.quest_id == qid or panel.quest_id == 0) then
        pcall(core.quests.accept_quest)
        pcall(core.quests.confirm_accept_quest)
        trail("act", "quest %d accepted from item %d", qid, item)
        TK.start.t = now
        return true
    end
    if TK.start.tries >= TK.START_TRIES then return false end
    if now - TK.start.t < TK.START_GAP then
        state.set_note("Quest", "Guide: " .. tostring(label) .. " - starting it from the item")
        return true
    end
    TK.start.tries, TK.start.t = TK.start.tries + 1, now
    movement.nav_stop()
    local used = guide.use_bag_item({ item_id = item }, nil)
    trail("act", "quest %d starts from item %d - used (try %d)%s", qid, item, TK.start.tries, used and "" or " - refused")
    state.set_note("Quest", "Guide: " .. tostring(label) .. " - starting it from the item")
    return true
end

-- 1.35.0 (log 14:17, step 93 "use "Count" Ungula's Mandible / accept 9911"):
-- no data names the item - an accept goal with no NPC whose step uses an item
-- (or holds a quest-starter loot item) is started from the bags (quest/bagstart:
-- the step's own items first, then every quest item with no use spell), the
-- panel it opens accepted. nil from bagstart: nothing left to try - the NPC
-- lookup carries on.
function TK.bag_start(qid, label, goal)
    local gl = guide.goals()
    local cur = type(goal) == "table" and goal or nil
    if cur and (cur.npc_id or cur.npc) then return false end
    local uses = false
    for i = 1, #gl do
        if gl[i].action == "use" or gl[i].action == "useany" then uses = true break end
    end
    local okb, bs = pcall(require, "quest/bagstart")
    if not okb then return false end
    local prefer = guide.step_item_ids(cur)
    local own = false
    for i = 1, #prefer do if bs.has(prefer[i]) then own = true break end end
    if not uses and not own then return false end
    local r = bs.start(qid, prefer)
    if r == "accepted" then
        guide.invalidate()
        state.set_note("Quest", "Guide: " .. tostring(label) .. " - accepted from the item")
        return true
    end
    if r == "using" then
        movement.nav_stop()
        state.set_note("Quest", "Guide: " .. tostring(label) .. " - starting it from the item")
        return true
    end
    return false
end

-- A turn-in whose quest is in the log but NOT complete (game: is_quest_complete false) used to stop the bot
-- for ever: "not ready to hand in yet (quest log), waiting" (log 2026-11-15: step 116 "turn in Beer Basted
-- Boar Ribs", 300 yd from the NPC, the player stood still until it was stopped). Nothing the bot does while
-- it waits can finish the quest. Ladder, once per goal: say WHAT is missing (the quest's objectives) in the
-- action log; after NOT_READY_WAIT s hold this goal so the step's other goals are worked. Returns true when it handled this tick.
TK.notready = nil
function TK.turnin_not_ready(goal, qid, label, st, ready)
    local now = izi.now()
    local NOT_READY_WAIT = npc_wait_s()
    local key = (guide.goal_key and guide.goal_key(goal)) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index))
    local w = TK.notready
    if not w or w.key ~= key then
        w = { key = key, t = now, done = false }
        TK.notready = w
        local objs = {}
        if type(guide.objectives) == "function" then
            local list = safe(function() return guide.objectives(qid) end)
            if type(list) == "table" then
                for i = 1, math.min(#list, 8) do
                    local o = list[i]
                    objs[#objs + 1] = { text = o.text, done = o.finished, have = o.num_fulfilled, need = o.num_required }
                end
            end
        end
        pcall(function()
            require("actlog").event("quest", "turnin_not_ready", string.format("%s: quest %s is in the log but not complete", tostring(label), tostring(qid)),
                { quest = qid, log_state = st, is_complete = ready, objectives = objs, waits_s = NOT_READY_WAIT })
        end)
    end
    local left = NOT_READY_WAIT - (now - w.t)
    if left > 0 then
        state.set_note("Quest", string.format("Guide: %s - quest not complete yet, checking again (%.0f s)", tostring(label), left))
        return true
    end
    if w.done then return false end
    w.done = true
    local why = "quest " .. tostring(qid) .. " is not complete and the bot cannot finish it from here"
    guide.hold_goal(guide.step_num(), goal.index, "blocked: " .. why)
    trail("quest", "%s: held locally; remaining goals stay available (%s)", tostring(label), why)
    return true
end

local function dialog_goal(player, goal, kind, wps, label)
    local now = izi.now()
    local qid = nil
    if kind == "accept" or kind == "turnin" then
        local why
        qid, why = resolve_quest(goal, kind)
        if not qid then
            trail("act", "%s goal %d: %s - next goal", kind, goal.index or 0, tostring(why))
            if why ~= "names no quest" then
                guide.mark_goal_done(guide.step_num(), goal.index)
                return true
            end
            -- No quest id at all: an NPC to speak to is all that is known.
        end
    end
    if kind == "accept" and qid and TK.item_accept(player, qid, label, goal) then return true end   -- 1.29.4
    if kind == "turnin" and qid then
        if g_redo and g_redo.qid == qid then
            if redo_accept(player, goal, label) then return true end
        elseif npc.quest_log_state(qid) == "failed" then
            local title = quest_title(goal, kind, qid)
            local a = g_accept_at[qid] or nil
            require("actlog").console_warn(string.format("[Master Farmer - Zygor Forever] Quest %s has FAILED (its timer ran out)%s.",
                tostring(title or qid), a and " - abandoning it and taking it again" or " - abandoning it"))
            npc.close()
            if not npc.abandon(qid) then
                g_hold_until = now + 2           -- audit Q4: a refused abandon is not sent again next tick
                return true
            end
            if a then
                trail("act", "quest %d failed - abandoned, back to npc %d to take it again", qid, a.npc)
                g_redo = { qid = qid, title = title or tostring(qid), npc = a.npc,
                    pos = { x = a.x, y = a.y, z = a.z }, since = now }
                return true
            end
            trail("act", "quest %d failed - abandoned; its giver is not known, skipping the turn-in", qid)
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
    end
    -- 1.4.0 (Zygor spec): hand in only when the log says ready - get_quest_log_title
    -- is_complete == 1 or core.quests.is_quest_complete(quest_id)
    if kind == "turnin" and qid then
        local st = npc.quest_log_state(qid)
        local ready = npc.quest_ready(qid)
        if ready ~= true and st ~= "complete" and not (st == nil and ready == nil) then
            movement.nav_stop()
            if TK.turnin_not_ready(goal, qid, label, st, ready) then return true end
            state.set_note("Quest", "Guide: " .. tostring(label) .. " - not ready to hand in yet (quest log), waiting")
            return true
        end
    end
    if now < g_hold_until and g_hold_qid and kind == "turnin" and qid == g_hold_qid then
        -- the task finished while we waited: carry on at once
        if npc.quest_ready(qid) == true or npc.quest_log_state(qid) == "complete" then
            trail("act", "turn in %d: complete now - not waiting out the hold", qid)
            g_hold_until, g_hold_qid = 0, nil
        end
    end
    if now < g_hold_until then
        state.set_note("Quest", string.format("Guide: waiting - %s not complete at the NPC (%.0f s)", tostring(label), g_hold_until - now))
        return true
    end

    -- 2.297.0: after the ladder's UI reload, wait before the retry
    if TK.reload_hold then
        if now < TK.reload_hold then
            g_stall.t, g_stall.seen = now, now
            state.set_note("Quest", string.format("Guide: UI reloaded - retrying %s in %.0f s", tostring(label), TK.reload_hold - now))
            return true
        end
        TK.reload_hold = nil
        trail("act", "%s: UI reload wait over - retrying the interaction", tostring(label))
    end

    local unit, how = find_giver(player, goal, kind, wps, qid)
    if unit and safe(function() return unit:is_valid() end) ~= true then unit = nil end
    if unit then
        g_stall.giver = { guid = safe(function() return unit:get_guid() end), id = npc_id_of_unit(unit),
            name = safe(function() return unit:get_name() end) or "the NPC" }
    end
    g_giver_learned = nil
    if unit and type(how) == "string" and how:find("^learned id") then
        g_giver_learned = { kind = kind, qid = goal.quest_id, npc = tonumber(how:match("(%d+)$")), text = goal.text }
    end

    -- Distance to what the bot is working toward, for the stall check.
    -- Live targets use 3D reach; guessed guide waypoints still use flat progress.
    local me = safe(function() return player:get_position() end)
    local track_d
    local wp_t = (#wps > 0) and wps[math.min(g_move, #wps)].pos or nil
    if unit then
        local up = safe(function() return unit:get_position() end)
        track_d = me and up and geometry.distance(me, up) or nil
        -- An NPC picked away from the waypoint (2.158.0): the 11:28 turn-in
        -- chose Balir by the previous step's waypoint, then walked 354 yd to
        -- the real one - away from Balir - and the stall check fired at 30 s
        -- on a walk that was going fine. Track the waypoint then.
        local off = up and wp_t and geometry.distance_flat(up, wp_t)
        if type(off) == "number" and off > TALK_SEARCH_FAR then
            track_d = me and geometry.distance_flat(me, wp_t) or track_d
        end
    elseif wp_t then
        track_d = me and geometry.distance_flat(me, wp_t) or nil
    end
    if stalled(now, goal, track_d) then
        if unit and type(track_d) == "number" and track_d > TALK_REACH then
            guide.hold_goal(guide.step_num(), goal.index, "blocked: cannot reach the target's interaction range or floor")
            trail("quest", "%s: target remains %.1f yd away in 3D; holding goal without blacklisting the target", tostring(label), track_d)
            movement.nav_stop()
            return true
        end
        recover_stall(now, goal, label)
        return true
    end

    if not unit and TK.gid.refused and qid then
        -- The goal's own NPC listed no such quest (2.215.0). Nothing else in
        -- reach is evidence of a better one, so the goal is set aside here and
        -- Zygor's own state decides what comes next - the guide steps back
        -- for a failed timed quest (Scalding Mornbrew Delivery, 5 min), the
        -- set-aside goal is asked again on "step complete" (30 s).
        local r = TK.gid.refused
        trail("act", "%s %d: %s (npc %s), the guide's NPC for it at the waypoint, does not offer it - "
            .. "on quest %s, completed %s - setting the goal aside, no other NPC tried",
            kind, qid, tostring(r.name), tostring(r.npc),
            tostring(safe(function() return core.quests.is_on_quest(qid) end)),
            tostring(safe(function() return core.quests.is_quest_flagged_completed(qid) end)))
        -- TK.gid stays until the goal changes (its reset), so a tick that
        -- still lands on this goal cannot fall through to the nearest NPC.
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if not unit and TK.gid.tried then
        -- The identified NPC timed out (gave_up): it gets the BAD_GIVER_RETRY
        -- second chance below, not a walk through every other NPC here.
        if next(g_bad_givers) ~= nil then
            if g_bad_since == 0 then
                g_bad_since = now
            elseif (now - g_bad_since) >= BAD_GIVER_RETRY then
                trail("act", "%s: asking %s again", kind, tostring(TK.gid.tried))
                g_bad_givers = {}
                g_bad_since = 0
            end
        end
        state.set_note("Quest", "Guide: waiting to ask " .. tostring(TK.gid.tried) .. " again")
        return true
    end
    if not unit then
        -- Every NPC here was ruled out. Give them another chance after a
        -- while (2.63.0): a giver that timed out once - lag, a frame that
        -- opened late - is usually fine the second time, and until now the
        -- list was only cleared when the goal changed, i.e. by the watchdog.
        if next(g_bad_givers) ~= nil then
            if g_bad_since == 0 then
                g_bad_since = now
            elseif (now - g_bad_since) >= BAD_GIVER_RETRY then
                trail("act", "%s: retrying every NPC at the waypoint", kind)
                g_bad_givers = {}
                g_bad_since = 0
            end
        end
        -- At the door of a building the 12-yard search misses the NPC inside,
        -- and walking to the outdoor-terrain z never enters. Search farther,
        -- then walk a few yards in at the player's own height.
        local at_door = false
        for i = 1, #wps do
            if near(wps[i].pos, TALK_ARRIVE) then
                at_door = true
                break
            end
        end
        -- 1.5.2 (log 00:16: "talk with Rescued Civilian ... via inside the building"
        -- for a Scared Civilian goal): no nearest-NPC guess - the goal's NPC id only
        at_door = false
        if at_door then
            for i = 1, #wps do
                unit = guide.nearest_talkable(player, TALK_SEARCH_FAR, wps[i].pos, TK.excl(), kind == "accept" or kind == "turnin")
                if unit then
                    how = "inside the building"
                    break
                end
            end
            if not unit then
                unit = guide.nearest_talkable(player, TALK_SEARCH_FAR, nil, TK.excl(), kind == "accept" or kind == "turnin")
                if unit then
                    how = "nearest nearby"
                end
            end
        end
        if not unit then
            if at_door and me and #wps > 0 then
                local dest = wps[1].pos
                local dx = dest.x - me.x
                local dy = dest.y - me.y
                local len = math.sqrt(dx * dx + dy * dy)
                if len > 1 then
                    local step = math.min(STEP_INSIDE, len)
                    local inside = {
                        x = me.x + dx / len * step,
                        y = me.y + dy / len * step,
                        z = me.z,
                    }
                    trail("act", "%s: at the door, no giver - stepping inside", kind)
                    walk_to(inside, label, 2)
                    return true
                end
            end
            if at_door then
                trail("act", "%s: at the door, no giver within %.0f yd", kind, TALK_SEARCH_FAR)
            end
            return false
        end
    end
    g_bad_since = 0
    local d = track_d or 99
    -- An interact the NPC refused (out of range, a UI error): the next one
    -- is made from closer.
    if npc.take_refused() and not g_close_in then
        g_close_in = true
        trail("act", "%s: the NPC refused the interaction - closing in", tostring(label))
    end
    local reach = g_close_in and CLOSE_REACH or TALK_REACH
    local same_floor = false
    -- 2.263.0: the reach is 3D - flat, an NPC one floor up was "in reach"
    do
        local mp = safe(function() return player:get_position() end)
        local np = safe(function() return unit:get_position() end)
        same_floor = mp and np and type(mp.z) == "number" and type(np.z) == "number" and math.abs(mp.z - np.z) <= EXACT_DZ
        local d3 = mp and np and geometry.distance(mp, np)
        if type(d3) == "number" then d = d3 end
        -- 1.6.0 (audit, step 20: walk / talk flip-flopped 5 times in 1 s): the same
        -- measure movement.interact uses (distance_to) - the larger of the two
        local dt = safe(function() return player:distance_to(unit) end)
        if type(dt) == "number" and type(d) == "number" and dt > d then d = dt end
    end
    -- 2.296.0: AN NPC BEHIND A COUNTER. Tannok Frosthammer (Supplies to
    -- Tannok, 01:57 session) stands behind the bar: the character cannot get
    -- within the 4 yd 3D reach, kept walking at the counter and never spoke
    -- to him (23 minutes). No yard gained for GIVER_STALL s within
    -- GIVER_COUNTER yd (inside the game's own interact range): interact from
    -- where the character stands. A refusal closes in as before.
    local GIVER_STALL, GIVER_COUNTER = 3.0, 6.0
    if same_floor and d > reach and g_giver_walk and not g_close_in and d <= GIVER_COUNTER
        and g_giver_walk.t and (now - g_giver_walk.t) >= GIVER_STALL then
        if not g_giver_walk.forced then
            g_giver_walk.forced = true
            trail("act", "%s: %s %.1f yd away, no closer in %.0f s (a counter?) - interacting from here",
                kind, tostring(safe(function() return unit:get_name() end)), d, GIVER_STALL)
        end
        d = 0
    end
    if d > reach then
        local p = safe(function() return unit:get_position() end)
        if p then
            -- Re-route when the giver is not where the bot is already
            -- heading (2.63.0): walk_to does not re-issue while moving, so a
            -- walk begun toward the waypoint carried on to it before turning
            -- to an NPC standing somewhere else - or one walking a patrol.
            if g_giver_walk == nil or geometry.distance(g_giver_walk, p) > 5 then
                g_giver_walk = { x = p.x, y = p.y, z = p.z, best = d, t = now }
                -- Retarget through Sentinel without stopping the active path.
                -- 2.296.0: logged - the 01:57 Tannok stall left no trace of it
                local mp = safe(function() return player:get_position() end)
                trail("act", "%s: walking to %s (%.1f yd flat, %.1f yd 3D, its z %.1f, ours %.1f, via %s)",
                    kind, tostring(safe(function() return unit:get_name() end)),
                    mp and geometry.distance_flat(mp, p) or -1, d, p.z or -1, mp and mp.z or -1, tostring(how))
            end
            if d < (g_giver_walk.best or 1e9) - 0.3 then
                g_giver_walk.best, g_giver_walk.t = d, now
            end
            walk_to(p, label, math.max(reach - 1.0, 1.5), true)
            return true
        end
        return false
    end
    g_giver_walk = nil
    movement.nav_stop()

    local npc_id = geometry.object_id(unit)
    local uname = safe(function() return unit:get_name() end)
    trail("act", "%s with %s npc %s via %s", kind, tostring(uname), tostring(npc_id), tostring(how))
    -- Identified, not guessed (2.215.0): see TK.gid and find_giver.
    local identified = type(how) == "string" and (how:find("^guide") or how:find("^learned id")
        or how:find("^zygor npc id")                    -- 1.6.0: the goal's own NPC id
        or how == "raid marker" or how:find("^waypoint title")) ~= nil
    if identified and qid then
        TK.gid.tried = tostring(uname or npc_id)
    end
    if qid then
        g_pending = { kind = kind, quest_id = qid, npc_id = npc_id }
        state.quest.id = qid
        local title = quest_title(goal, kind, qid)
        local result
        if kind == "accept" then
            state.set_note("Quest", "Guide: accept " .. tostring(title or qid))
            result = npc.accept(player, qid, title, npc_id, unit)
        else
            state.set_note("Quest", "Guide: turn in " .. tostring(title or qid))
            result = npc.turn_in(player, qid, title, npc_id, unit, goal.reward)   -- 2.258.0: Zygor reward choice
        end
        if result == "done" and kind == "accept" then
            remember_accept(qid, npc_id, unit)
        end
        if result == "done" or result == "skipped" then
            -- Landed and proven by quest/npc. Close the windows once and move
            -- on: the dialog keeps answering "done" for this quest, so nothing
            -- re-interacts while Zygor catches up. A multi-quest goal comes
            -- back here for its next id rather than being counted done.
            trail("act", "%s quest %d: %s", kind, qid, result)
            npc.close_frames()
            guide.invalidate()
            g_not_ready = 0
            g_close_in = false
            if resolve_quest(goal, kind) == nil then
                guide.mark_goal_done(guide.step_num(), goal.index)
            end
            return true
        end
        if result == "not_ready" then
            -- The NPC has the quest but will not take it yet. Re-reading the
            -- guide once more covers an objective that finished a moment ago;
            -- a second refusal means Zygor is ahead of the server.
            g_not_ready = g_not_ready + 1
            npc.close()
            guide.invalidate()
            if g_not_ready >= NOT_READY_MAX then
                require("actlog").console_warn(string.format(
                    "[Master Farmer - Zygor Forever] Quest %s: Zygor says turn it in, the NPC says it is not complete - skipping the goal.",
                    tostring(title or qid)))
                guide.mark_goal_done(guide.step_num(), goal.index)
                g_not_ready = 0
            else
                local hold = math.max(3, npc_wait_s() / NOT_READY_MAX)
                trail("act", "turn in %d: not complete at the NPC - holding up to %.0f s (ends the moment it is complete)", qid, hold)
                g_hold_until = now + hold
                g_hold_qid = qid
            end
            return true
        end
        if result == "bags_full" then
            -- The quest was offered and Accept did not land (2.160.0): full
            -- bags. Sell first; the giver is not ruled out, and the accept
            -- is tried again once the trip is over.
            npc.close()
            g_pending = nil
            g_close_in = false
            local ok_vd, vnd = pcall(require, "vendor")
            local going = ok_vd and type(vnd) == "table" and type(vnd.request_bag_trip) == "function"
                and vnd.request_bag_trip("accept " .. tostring(title or qid) .. " failed - bags full", player)
            if going then
                trail("act", "accept %d: bags full - selling first, then back to this quest", qid)
                g_hold_until = now + 2
                return true
            end
            result = "gave_up"
        end
        if kind == "turnin" and (result == "not_offered" or result == "gave_up")
            and npc.quest_log_state(qid) == "failed" then
            -- Not the NPC's fault: the quest failed. The check at the top of
            -- dialog_goal abandons it and takes it again next tick.
            npc.close()
            g_pending = nil
            return true
        end
        if (result == "not_offered" or result == "gave_up") and type(how) == "string" and how:find("^learned id") then
            guide.forget_quest_npc(kind, qid, npc_id, goal.text)
            trail("act", "%s: learned npc %s refused quest %d - forgotten", kind, tostring(npc_id), qid)
        end
        if result == "not_offered" and identified then
            TK.gid.refused = { name = tostring(uname), npc = npc_id }
        end
        if result == "not_offered" or result == "gave_up" then
            -- Not this NPC: rule it out and let find_giver pick the next.
            local g = safe(function() return unit:get_guid() end)
            if g then
                g_bad_givers[g] = true
            end
            trail("act", "%s: %s does not have quest %d (%s) - trying another NPC", kind,
                tostring(safe(function() return unit:get_name() end)), qid, result)
            npc.close()
            g_pending = nil
            g_close_in = false
        end
        debug("%s quest %d at %s (npc %s)", kind, qid, tostring(how), tostring(npc_id))
        return true
    end

    -- Talk / trainer / vendor / flight master: open the frame, and let the
    -- trainer, vendor and dialog modules act on it. Rate limited, because
    -- re-interacting tears down the frame that just opened.
    --
    -- DONE ONCE THE FRAME HAS OPENED (2.42.0). This interacted every ACT_GAP
    -- unless a GOSSIP frame was open - a merchant window is not one - and
    -- Zygor does not tick every vendor / trainer / flight step off by
    -- itself, so the bot stood at the NPC re-interacting after the vendor had
    -- long finished. Now: once any NPC frame is open (gossip, merchant,
    -- trainer) and the vendor trip is over, the goal counts as done after
    -- TALK_DONE and the bot moves on.
    local gossip_open = safe(function() return core.quests.is_gossip_frame_shown() end) == true
    -- ".home" (2.134.0): the innkeeper's bind option, picked by its icon from
    -- this frame's own options. The confirmation popup is answered by
    -- events.lua (CONFIRM_BINDER).
    if gossip_open and not g_bind_asked and string.lower(goal.action or "") == "home" then
        local bind = gossip.find({ icon = "BINDER", type = "binder" })
        if bind then
            g_bind_asked = true
            pcall(bind)
            g_talk_opened = now
            trail("act", "asked %s to bind the hearthstone", tostring(safe(function() return unit:get_name() end)))
            pcall(function() require("bindhearth").learn(player, safe(function() return player:get_position() end), "innkeeper bind") end)
            state.set_note("Quest", "Guide: binding the hearthstone")
            return true
        end
    end
    local ok_v, vendor = pcall(require, "vendor")
    local merchant = ok_v and type(vendor) == "table" and type(vendor.merchant_open) == "function"
        and vendor.merchant_open() == true

    -- VENDOR STEPS NEED THE MERCHANT WINDOW (2.204.0). Zygor ticks a
    -- ".vendor" step off on MERCHANT_SHOW. The bot talked to the nearest NPC
    -- at the waypoint (npc 1694, a quest giver), counted the open GOSSIP as
    -- done, and the step retried every 30 s for two hours (17:46-19:53 log).
    -- Now: an NPC the game does not flag as a vendor (0x80) is skipped; a
    -- gossip gets its vendor option selected; an NPC that will not open a
    -- merchant after TK.VEND_TRIES tries is ruled out and the next one is tried.
    if string.lower(goal.action or "") == "vendor" and not merchant then
        local g = safe(function() return unit:get_guid() end)
        if g ~= TK.vend.guid then TK.vend = { guid = g, tries = 0, next_t = 0 } end
        local flags = safe(function() return unit:get_npc_flags() end)
        local not_vendor = type(flags) == "number" and flags > 0 and math.floor(flags / TK.NPC_VENDOR) % 2 == 0
        if not_vendor or TK.vend.tries >= TK.VEND_TRIES then
            if g then g_bad_givers[g] = true end
            trail("act", "vendor step: npc %s %s - trying another NPC", tostring(npc_id_of_unit(unit)),
                not_vendor and "is not a vendor" or "opened no merchant window")
            pcall(function() core.quests.close_gossip() end)
            g_talk_opened = 0
            TK.vend = { guid = nil, tries = 0, next_t = 0 }
            return true
        end
        if gossip_open then
            if now >= TK.vend.next_t then
                TK.vend.next_t = now + 1.5
                TK.vend.tries = TK.vend.tries + 1
                -- duplicate (audit D4): vendor gossip -> vendor.select_vendor_gossip is the copy to keep
                local picked = gossip.select({ icon = "VENDOR", icon_num = 1, type = "vendor",
                    words = { "browse your goods", "let me browse", "your wares", "buy from you", "buy something" } })
                trail("act", "vendor step: gossip - %s (try %d)", picked and "vendor option selected"
                    or "no vendor option", TK.vend.tries)
                if not picked then TK.vend.tries = TK.VEND_TRIES end
            end
            state.set_note("Quest", "Guide: opening the merchant - " .. label)
            return true
        end
    end
    if gossip_open and kind == "talk" and type(guide.gossip_option)=="function" then
        local rows = safe(function() return core.quests.get_gossip_options() end)
        local choice = guide.gossip_option(unit, rows)
        if choice then
            if now-g_talk_opened >= 1 then
                pcall(function() core.quests.select_gossip_option(choice) end)
                g_talk_opened=now
                trail("act", "Zygor interrogation: selected offered option %d", choice)
            end
            return true
        end
    end
    -- GUIDE GOSSIP CHOICE (2.206.0). Zygor picks a step's gossip option
    -- itself (.gossipoption / .skipgossipid by gossip option id, .skipgossip
    -- by npc id + option number) when its gossip automation is on. When the
    -- frame is still open TK.GOSSIP_AFTER later, the bot makes the same
    -- choice from the guide files (data/rxp_targets M.steps), once per frame.
    if gossip_open and kind == "talk" and type(guide.rxp_step_for) == "function" then
        if g_talk_opened == 0 then g_talk_opened = now end
        local st = guide.rxp_step_for(wps)
        local key = tostring(safe(function() return unit:get_guid() end)) .. ":" .. tostring(g_talk_opened)
        if st and (st.g or st.s) and TK.gsel.key ~= key and (now - g_talk_opened) >= TK.GOSSIP_AFTER then
            TK.gsel.key = key
            local rows = safe(function() return core.quests.get_gossip_options() end)
            local picked = nil
            -- 2.258.0: guide-file option ids are real ids; on a build whose
            -- gossip_option_id is a ROW INDEX (npc.gossip_ids_are_rows) they
            -- are never compared - the positional st.s choice below decides.
            if type(rows) == "table" and st.g and not npc.gossip_ids_are_rows() then
                for i = 1, #rows do
                    local id = type(rows[i]) == "table" and rows[i].gossip_option_id or nil
                    for k = 1, #st.g do
                        if id == st.g[k] then picked = id break end
                    end
                    if picked then break end
                end
            end
            if not picked and type(rows) == "table" and st.s then
                local quests_n = #(safe(function() return core.quests.get_gossip_available_quests() end) or {})
                    + #(safe(function() return core.quests.get_gossip_active_quests() end) or {})
                local want = nil
                if #st.s == 0 then
                    want = 1
                elseif st.s[1] == npc_id_of_unit(unit) then
                    want = st.s[2] or 1
                elseif #st.s == 1 and st.s[1] <= 9 then
                    want = st.s[1]
                end
                local row = want and rows[want] or nil
                if quests_n == 0 and type(row) == "table" then
                    picked = (type(row.gossip_option_id) == "number" and row.gossip_option_id ~= 0)
                        and row.gossip_option_id or want
                end
            end
            if picked then
                trail("act", "guide gossip choice: option %s", tostring(picked))
                pcall(function() core.quests.select_gossip_option(picked) end)
                g_talk_opened = now
                return true
            end
        end
    end
    local trainer_n = safe(function() return core.quests.get_num_trainer_services() end)
    local trainer = type(trainer_n) == "number" and trainer_n > 0
    -- A flight master's map counts as its frame (2.95.0): talking to it is
    -- what learns the flight path (".fp"), and the map is what opens.
    local taxi_n = safe(function() return core.taxi.num_nodes() end)
    local taxi = type(taxi_n) == "number" and taxi_n > 0
    -- audit Q8: the closing finished (no frame open) - the hold decided on the
    -- tick the goal was done runs now, on a later tick than any close
    if TK.closing == g_key and not (gossip_open or merchant or trainer or taxi) then
        TK.closing = nil
        g_talk_opened = 0
        local h = TK.hold_next
        TK.hold_next = nil
        if h and (not guide.context_key or h.context == guide.context_key()) then guide.hold_goal(h.s, h.i, h.why) end
        return true
    end
    if gossip_open or merchant or trainer or taxi then
        if g_talk_opened == 0 then
            g_talk_opened = now
        end
        local busy = ok_v and type(vendor) == "table" and type(vendor.is_busy) == "function" and vendor.is_busy()
        -- A trainer still buying ranks keeps the goal open (2.75.0): it used to
        -- count as done 2 s after the frame opened and the gossip was closed
        -- mid-training.
        if not busy then
            local ok_tr, tr = pcall(require, "trainer")
            busy = ok_tr and type(tr) == "table" and type(tr.busy) == "function" and tr.busy() == true
        end
        -- 1.6.0 (Zygor Goal.lua: gossip goals are picked by Zygor itself on
        -- GOSSIP_SHOW, by gossip option id - not exposed to us): with a gossip goal
        -- on the step the frame stays open GOSSIP_WAIT s for Zygor to choose
        local wait_s = TALK_DONE
        if gossip_open then
            for _, sg in ipairs(guide.goals() or {}) do
                if sg.action == "gossip" and sg.is_complete ~= true then wait_s = TK.GOSSIP_WAIT break end
            end
        end
        if not busy and (now - g_talk_opened) >= wait_s then
            -- 1.4.0 (Zygor spec): not marked done - the window is closed and the goal
            -- waits for Zygor's own is_complete
            -- 1.5.2: this NPC is done for the goal; another of the same id in sight
            -- is talked to next - only with none left the goal waits for Zygor
            if TK.closing ~= g_key then
                local tg = safe(function() return unit:get_guid() end)
                if tg then g_bad_givers[tg] = true end
                local nxt = goal.npc_id and nearest_npc_by_id(player, goal.npc_id, 300) or nil
                if nxt then
                    trail("act", "talked to %s - next %s of this goal", tostring(safe(function() return unit:get_name() end)),
                        tostring(safe(function() return nxt:get_name() end)))
                else
                    -- 1.6.0: a talk goal is passive in Zygor (never ticked): done here, the
                    -- step's next goal is worked (passed over, not a wait) - audit Q8: on
                    -- a later tick, once every frame is closed
                    trail("act", "talked to %s - the step's next goal", tostring(safe(function() return unit:get_name() end)))
                    TK.hold_next = { context = guide.context_key and guide.context_key(), s = guide.step_num(), i = goal.index, why = "talked to every NPC of the goal in sight" }
                end
                TK.closing = g_key
            end
            -- audit Q8: ONE frame closed per tick, in this order: gossip, merchant,
            -- trainer, taxi. Zygor completes a ".vendor" step on MERCHANT_CLOSED
            -- and ".trainer" on TRAINER_CLOSED (2.205.0); a flight master's map is
            -- closed too (2.280.0).
            if gossip_open then
                pcall(function() core.quests.close_gossip() end)
            elseif merchant then
                pcall(function() core.input.close_merchant() end)
            elseif trainer then
                pcall(function() core.quests.close_trainer() end)
            elseif taxi then
                pcall(function() core.taxi.close() end)
            end
            return true
        end
        state.set_note("Quest", "Guide: at " .. label)
        return true
    end
    -- 1.6.0 (audit: "clicknpc" Injured Citizens / Empowered Dragonhawk open no
    -- window - the bot clicked the same unit until the stall ladder gave up): a
    -- clicknpc unit counts as clicked TK.CLICK_DONE s after its interact; the
    -- next unit of the id is clicked, with none left the step's next goal
    if string.lower(goal.action or "") == "clicknpc" and g_talk_interact_t > 0
        and (now - g_talk_interact_t) >= TK.CLICK_DONE and TK.click_guid == safe(function() return unit:get_guid() end) then
        local tg = TK.click_guid
        if tg then g_bad_givers[tg] = true end
        g_talk_interact_t, TK.click_guid = 0, nil
        local nxt = goal.npc_id and nearest_npc_by_id(player, goal.npc_id, 300) or nil
        if nxt then
            trail("act", "clicked %s - next %s", tostring(safe(function() return unit:get_name() end)),
                tostring(safe(function() return nxt:get_name() end)))
        else
            trail("act", "clicked %s - the step's next goal", tostring(safe(function() return unit:get_name() end)))
            guide.hold_goal(guide.step_num(), goal.index, "clicked every NPC of the goal in sight")
        end
        return true
    end
    if now >= g_act_until then
        -- The last interact drew a UI error instead of a window: the next is
        -- made from closer, not repeated from the same spot.
        if g_talk_interact_t > 0 and not g_close_in and events
            and type(events.since) == "function" and events.since("UI_ERROR_MESSAGE", g_talk_interact_t) then
            g_close_in = true
            trail("act", "%s: the NPC refused the interaction - closing in", tostring(label))
            return true
        end
        g_act_until = now + ACT_GAP
        g_talk_interact_t = now
        TK.click_guid = safe(function() return unit:get_guid() end)      -- 1.6.0: the unit clicked
        pcall(function() require("movement").interact(unit) end)
        debug("talk to %s", tostring(how))
    end
    state.set_note("Quest", "Guide: talk to " .. label)
    return true
end

-- ============================================================================
-- FLIGHT / FAR TRAVEL - quest/travel.lua (2.307.0: moved out, audit LUA-5)
-- ============================================================================
local TR = require("quest/travel")
TR.init({
    walk_to = walk_to,
    find_giver = find_giver,
    ACT_GAP = ACT_GAP,
    TALK_REACH = TALK_REACH,
    act_until = function() return g_act_until end,
    set_act_until = function(v) g_act_until = v end,
})
quest.in_flight = TR.in_flight


-- ZYGOR "use": the item is used where the goal's waypoint is (the walk
-- comes first, ITEM_AT yd), on - in order - the current target, the step's
-- click goal object (matched by name, user 2026-10-17), the step's kill goal
-- mob, a raid-marked hostile; with none of them, without a target.
local ITEM_AT = 30
-- 1.2.27 (log 21:05-03:12 step 298 "no actionable goals", 03:35-08:40 step 12 "no
-- verified item": 11 h standing still): a step the bot can do nothing on for 30 s is
-- skipped with Zygor's own skip_current_step (last rung), retried every 60 s; when
-- Zygor refuses (end of the guide) the note says to load the next guide.
IS.stuck_skip = function(why)
    local now = izi.now()
    local num = guide.step_num()
    local w = IS.stuck_w
    if not w or w.num ~= num or now - w.seen > 5 or now < w.seen then
        w = { num = num, t0 = now, seen = now, next = now + 30 }
        IS.stuck_w = w
    end
    w.seen = now
    if now < w.next then return false end
    w.next = now + 60
    w.tries = (w.tries or 0) + 1
    trail("quest", "step %s: %s for %d s - requesting step skip (try %d)", tostring(num), why, math.floor(now - w.t0), w.tries)
    if guide.skip_current(why) then
        IS.stuck_w = nil
        movement.nav_stop()
        state.set_note("Quest", "Guide: skipped step " .. tostring(num) .. " (" .. why .. ")")
        return true
    end
    state.set_note("Quest", "WAITING for Zygor: step " .. tostring(num) .. " - " .. why
        .. "; Zygor would not skip it (end of the guide?) - load the next guide in Zygor")
    return false
end
local function item_target(player, goal, item_id)
    -- 1.29.4: the mobs / objects the guides use this item on (data/quest_items)
    local ok_qi, qi = pcall(require, "questitems")
    local names = (item_id and ok_qi and type(qi) == "table") and qi.targets(item_id) or {}
    for i = 1, #names do
        local u = targeting.find_named(player, names[i], nil, 40)
        if u and safe(function() return u:is_dead_or_ghost() end) ~= true then return u end
    end
    local on = state.target.unit
    -- 1.29.2: never a corpse left from the last fight
    if on and safe(function() return on:is_valid() end) == true
        and safe(function() return on:is_dead_or_ghost() end) ~= true then return on end
    local step = guide.step()
    local goals = step and step.goals or {}
    for i = 1, #goals do
        local g = goals[i]
        if i ~= goal.index and type(g) == "table" and g.is_complete ~= true and g.action == "click" then
            local sg = guide.goals()[i]
            local o = sg and guide.find_object(player, 300, sg) or nil
            if o then return o end
        end
    end
    for i = 1, #goals do
        local g = goals[i]
        if i ~= goal.index and type(g) == "table" and g.is_complete ~= true
            and (g.action == "kill" or g.action == "from") then
            local sg = guide.goals()[i]
            local u = sg and guide.find_mob(player, 300, sg, true) or nil
            if u then return u end
        end
    end
    return guide.find_marked(player, 30, "hostile")
end

local function item_goal(player, goal, label, wps)
    -- 1.35.0: the item opened the step's quest panel (an item that starts a
    -- quest): accepted here - the use is done
    local okb, bs = pcall(require, "quest/bagstart")
    if okb and bs.accept_open(guide.step_open_accepts()) then
        guide.invalidate()
        state.set_note("Quest", "Guide: " .. label .. " - quest accepted")
        return true
    end
    local entry = guide.find_bag_item(goal)
    if not entry then
        movement.nav_stop()
        state.set_note("Quest", "PAUSED: no verified item for this Zygor goal; use it in Zygor or supply its item ID")
        IS.stuck_skip("no verified item for this goal")
        return true
    end
    wps = wps or guide.goal_waypoints(goal)
    -- 1.7.20 (log 15:57, step 35 "use Smoke Beacon / Mark the Northern Tower |q
    -- 10895/1 |goto Hellfire Peninsula 68,66" with the player in the Blasted
    -- Lands): no usable waypoint, but the step / Zygor's arrow HAS one (on
    -- another continent, not converted here) - the item is not used here; the
    -- route (and its portal) is walked first. Only a step with no waypoint at
    -- all uses its item where the player stands.
    if #wps == 0 and type(guide.step_has_waypoint) == "function" and guide.step_has_waypoint() then
        return false
    end
    if #wps > 0 then
        local me = safe(function() return player:get_position() end)
        local near = false
        for i = 1, #wps do
            local d = me and wps[i].pos and geometry.distance_flat(me, wps[i].pos)
            if type(d) == "number" and d <= ITEM_AT then near = true break end
        end
        if not near then return false end      -- walk the route first
    end
    -- 1.29.2: never over the item's own cast; TK.USE_MAX uses of one goal with
    -- its step still open, then it is held and the step's next goal is worked
    if safe(function() return player:is_channeling_or_casting() end) == true then
        state.set_note("Quest", "Guide: use " .. label)
        return true
    end
    local uk = (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index)))
    TK.use_n = TK.use_n or {}
    if (TK.use_n[uk] or 0) >= TK.USE_MAX then
        trail("quest", "%s: item %s used %d times, the step still open - the step's next goal", tostring(label),
            tostring(entry.item_id), TK.USE_MAX)
        TK.use_n[uk] = nil
        guide.hold_goal(guide.step_num(), goal.index, "item used, the step still open")
        return false
    end
    local now = izi.now()
    if now >= g_act_until then
        g_act_until = now + ACT_GAP
        local on = item_target(player, goal, tonumber(entry.item_id))
        if guide.use_bag_item(entry, on) then
            TK.use_n[uk] = (TK.use_n[uk] or 0) + 1
            trail("act", "use item %s for %s (use %d)", tostring(entry.item_id), tostring(label), TK.use_n[uk])
            state.set_note("Quest", "Guide: use " .. label)
            return true
        end
        state.set_note("Quest", "Guide: could not use " .. label)
        return true
    end
    state.set_note("Quest", "Guide: use " .. label)
    return true
end

-- 1.29.2 (user: "interact with items in bags at Zygor set locations"): a
-- step's objective with nothing to kill or click ("Disable the Umbrafen Lake
-- Pump Controls |q 9720/1" next to "use Ironvine Seeds##24355") is done with the
-- step's use item: at the objective's waypoint (ITEM_AT) the item is used.
TK.USE_MAX = 8
function TK.step_use(player, goal, label)
    -- only when the last scan found no mob for this objective
    if TK.kill_none ~= (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index))) then return false end
    local gl = guide.goals()
    for i = 1, #gl do
        local g = gl[i]
        if g.index ~= goal.index and (g.action == "use" or g.action == "useany") and g.is_complete ~= true then
            local wps = guide.goal_waypoints(goal)
            if #wps == 0 then wps = guide.goal_waypoints(g) end
            if #wps > 0 and guide.find_bag_item(g) and item_goal(player, g, label, wps) then
                return true
            end
        end
    end
    -- 1.29.3: no use goal in the step: a bag quest item Zygor's guides use for
    -- this objective's quest (questitems.lua), used at its waypoint
    local q = tonumber(goal.quest_id)
    local ok_qi, qi = pcall(require, "questitems")
    if q and q > 0 and ok_qi and type(qi) == "table" then
        local wps = guide.goal_waypoints(goal)
        local list = qi.for_quests({ [q] = true }, false)
        if #wps > 0 and #list == 1 and not list[1].buff_only then
            TK.qi_goal = TK.qi_goal or {}
            local key = (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index))) .. "|" .. list[1].item_id
            local g = TK.qi_goal[key]
            if not g then
                g = { action = "use", item_id = list[1].item_id, index = 1000 + goal.index, quest_id = q }
                TK.qi_goal = { [key] = g }
            end
            if item_goal(player, g, label .. " (" .. tostring(list[1].name) .. ")", wps) then return true end
        end
    end
    return false
end

-- QUEST OBJECTS ON THE GROUND (2.79.0)
--   * use_object, not interact_with_object: the SDK documents use_object as
--     THE entry point for world objects (chests, nodes, quest crates) and
--     interact_with_object as not covering everything.
--   * A "Collecting" cast is left alone - re-clicking every ACT_GAP
--     interrupted it.
--   * The loot window the object opens is emptied and closed.
--   * Reach is measured generously (a big object's centre can be several
--     yards inside it), and once the walk has stopped next to it the bot
--     clicks from up to OBJECT_CLICK.
--   * An object used OBJECT_TRIES times with nothing to show is skipped for
--     OBJECT_SKIP seconds, so the next one is tried.
local OBJECT_REACH = 5.0
-- 2.263.0: 6, not 8 - a use from 8 yd is out of range and burnt one of the
-- OBJECT_TRIES; a retry is made from OBJECT_CLOSE after walking in.
local OBJECT_CLICK = 6.0
local OBJECT_CLOSE = 3.0
local OBJECT_TRIES = 4
local OBJECT_SKIP = 60
local g_obj = { guid = nil, uses = 0 }
local g_obj_skip = {}          -- guid -> until

-- 2.296.0: CLOSING IN GIVES UP. The 01:21 warrior session asked for 2 yd of a
-- Basic Campfire from 3.3 yd and never got there (the fire's centre is not
-- walkable): "closer to" for 5 minutes, then the travel watchdog used the
-- Hearthstone and the bot walked 1019 yd back. No yard gained for
-- CLOSER_STALL s: the object is used from where the character stands.
local OX = { CLOSER_STALL = 6.0, SIT_NEAR = 4.0, SIT_WAIT = 5.0, SIT_TRIES = 4,
    sit = { guid = nil, tries = 0, next_t = 0, sit_at = nil } }   -- one local: engine.lua is at Lua's 200

-- 2.296.0: "SIT NEAR THE CAMPFIRE" (The Great Outdoors): an emote objective,
-- not a click - the bot used the campfire 4 times a minute for 35 minutes.
-- A goal whose text has the word "sit": walk within OX.SIT_NEAR yd of the
-- object, stop, and sit (core.input.descend_start: on the ground it is the
-- game's SitStandOrDescend). No tick after OX.SIT_WAIT s: jump (stands up), sit
-- again; OX.SIT_TRIES sits, then the object is skipped like a dead click.

-- 2.299.0: SPELL FOCUS OBJECTS ARE NEVER USED. use_object on a Forge
-- (02:30, a Rumbleshot's Ammo name match) and on a Basic Campfire (02:39,
-- "Gain the Boosted Rest buff" right after the sit) was followed within 3 s
-- by the player object gone and map 0, and the game crashed. A forge, anvil
-- or fire has no use of its own: a rest / buff / sit goal sits near it,
-- anything else skips it.
OX.FOCUS = { "forge", "anvil", "campfire", "camp fire", "cooking fire", "bonfire", "brazier" }
function OX.is_focus(obj)
    local n = string.lower(tostring(safe(function() return obj:get_name() end) or ""))
    for i = 1, #OX.FOCUS do
        if n:find(OX.FOCUS[i], 1, true) then return true end
    end
    return false
end
function OX.is_rest_goal(label)
    local l = " " .. tostring(label):lower() .. " "
    return l:find("[^%a]rest[^%a]") ~= nil or l:find("[^%a]buff[^%a]") ~= nil or l:find("[^%a]warm") ~= nil
end

function OX.is_sit_goal(label)
    return (" " .. tostring(label):lower() .. " "):find("[^%a]sit[^%a]") ~= nil
end

--- Walk to within `arrive` of `pos`, unless that has stalled (OX.CLOSER_STALL).
--- true while walking; false once there or given up.
function OX.close_in(obj, odist, label, arrive)
    if g_obj.no_closer or type(odist) ~= "number" then return false end
    local now = izi.now()
    if not g_obj.closer_t or odist < (g_obj.closer_best or 1e9) - 0.5 then
        g_obj.closer_t, g_obj.closer_best = now, odist
    elseif now - g_obj.closer_t > OX.CLOSER_STALL then
        g_obj.no_closer = true
        trail("act", "quest object %s: no closer than %.1f yd in %.0f s - using it from here",
            tostring(safe(function() return obj:get_name() end)), odist, OX.CLOSER_STALL)
        return false
    end
    local cp = safe(function() return obj:get_position() end)
    if cp and not movement.is_blocked(cp) and walk_to(cp, label, arrive, true) then
        state.set_note("Quest", "Guide: closer to " .. label)
        return true
    end
    return false
end

function OX.sit_near(player, obj, guid, odist, label)
    if OX.sit.guid ~= guid then OX.sit.guid, OX.sit.tries, OX.sit.next_t, OX.sit.sit_at = guid, 0, 0, nil end
    if type(odist) == "number" and odist > OX.SIT_NEAR and OX.close_in(obj, odist, label, OX.SIT_NEAR - 1.0) then
        return true
    end
    movement.nav_stop()
    if movement.is_moving() then return true end
    local now = izi.now()
    if OX.sit.sit_at and now >= OX.sit.sit_at then
        OX.sit.sit_at = nil
        pcall(core.input.descend_start)
        pcall(core.input.descend_stop)
        trail("act", "sit near %s (%.1f yd, try %d)",
            tostring(safe(function() return obj:get_name() end)), tonumber(odist) or -1, OX.sit.tries)
    elseif not OX.sit.sit_at and now >= OX.sit.next_t then
        if OX.sit.tries >= OX.SIT_TRIES then
            if guid then g_obj_skip[guid] = now + OBJECT_SKIP end
            trail("act", "sat near %s %d times, objective not ticked - trying another",
                tostring(safe(function() return obj:get_name() end)), OX.sit.tries)
            OX.sit.guid = nil
            return true
        end
        if OX.sit.tries > 0 then
            if not (type(movement.no_jump) == "function" and movement.no_jump()) then   -- 1.23.0: never in water
                pcall(core.input.jump)             -- stand up first: the sit key toggles
                pcall(core.input.ascend_stop)      -- 2.306.0 (audit CORE-A-5): jump is JumpOrAscendStart
            end
            OX.sit.sit_at = now + 1.5
        else
            OX.sit.sit_at = now
        end
        OX.sit.tries = OX.sit.tries + 1
        OX.sit.next_t = now + OX.SIT_WAIT + 1.5
    end
    state.set_note("Quest", "Guide: sitting - " .. label)
    return true
end

local function loot_window_open()
    local n = safe(function() return core.game_ui.get_loot_item_count() end)
    return type(n) == "number" and n > 0, n
end

local function object_skip_set()
    local now = izi.now()
    local set = {}
    for g, t in pairs(g_obj_skip) do
        if t > now then set[g] = true else g_obj_skip[g] = nil end
    end
    return set
end

-- duplicate (audit D5): loot window -> loot.lua is the copy to keep
local function object_goal(player, goal, label)
    -- 1. The object's loot window: take everything, close it.
    local open, n = loot_window_open()
    if open then
        for _, i in ipairs(require("lootorder").order(n)) do   -- quest items first (lootorder.lua)
            pcall(function() core.input.loot_item(i) end)
        end
        pcall(function() core.input.close_loot() end)
        g_obj.uses = 0
        trail("act", "looted %d slot(s) from a quest object", n)
        state.set_note("Quest", "Guide: looting " .. label)
        return true
    end
    -- 2. Mid "Collecting" / "Opening" cast: wait for it.
    if safe(function() return player:is_channeling_or_casting() end) == true then
        state.set_note("Quest", "Guide: using " .. label)
        return true
    end

    local obj, odist = guide.find_object(player, OBJECT_RANGE, goal, object_skip_set())
    if not obj then
        return false
    end
    local guid = safe(function() return obj:get_guid() end)
    if guid ~= g_obj.guid then
        g_obj.guid, g_obj.uses, g_obj.used_t, g_obj.need = guid, 0, nil, nil
        g_obj.closer_t, g_obj.closer_best, g_obj.no_closer = nil, nil, nil
    end
    if OX.is_sit_goal(label) then
        return OX.sit_near(player, obj, guid, odist, label)
    end
    if OX.is_focus(obj) then
        if OX.is_rest_goal(label) then
            return OX.sit_near(player, obj, guid, odist, label)
        end
        if guid then g_obj_skip[guid] = izi.now() + OBJECT_SKIP * 10 end
        trail("act", "quest object %s is a crafting / cooking spot (no use action) - not used, skipped for %s",
            tostring(safe(function() return obj:get_name() end)), tostring(label))
        g_obj.guid, g_obj.uses = nil, 0
        return true
    end
    local standing = not movement.is_moving()
    -- 2.264.0: the use was refused as too far (UI_ERROR_MESSAGE) - it does
    -- not count as a try, and the next one is made from 2 yd
    if g_obj.used_t and events and type(events.too_far_since) == "function"
        and events.too_far_since(g_obj.used_t) then
        g_obj.used_t = nil
        g_obj.uses = math.max(0, g_obj.uses - 1)
        g_obj.need = 2.0
        trail("act", "quest object %s: too far to use - closing in",
            tostring(safe(function() return obj:get_name() end)))
    end
    -- 2.263.0: a use that brought nothing is retried from closer
    if (g_obj.uses >= 1 or g_obj.need) and type(odist) == "number" and odist > (g_obj.need or OBJECT_CLOSE) then
        if OX.close_in(obj, odist, label, OBJECT_CLOSE - 1.0) then
            return true
        end
    end
    if type(odist) == "number" and (odist <= OBJECT_REACH or (standing and odist <= OBJECT_CLICK)
        or (g_obj.no_closer and odist <= OBJECT_CLICK + 2)) then
        movement.nav_stop()
        local now = izi.now()
        if now >= g_act_until then
            if g_obj.uses >= OBJECT_TRIES then
                if guid then
                    -- 1.2.26: each give-up on the same object skips it 5x longer (60 s, 5 min, 25 min, ...). The Duskwood
                    -- Waterlogged Toolbox (underwater, interaction_out_of_reach) was retried every minute for 17+ minutes.
                    IS.obj_fails = IS.obj_fails or {}
                    IS.obj_fails[guid] = (IS.obj_fails[guid] or 0) + 1
                    g_obj_skip[guid] = now + OBJECT_SKIP * (5 ^ math.min(IS.obj_fails[guid] - 1, 3))
                end
                trail("act", "quest object %s gave nothing after %d uses - trying another",
                    tostring(safe(function() return obj:get_name() end)), g_obj.uses)
                g_obj.guid, g_obj.uses = nil, 0
                return true
            end
            g_act_until = now + ACT_GAP
            g_obj.uses = g_obj.uses + 1
            g_obj.used_t = now
            g_obj.need = nil
            -- 1.4.0 (Zygor spec): a click goal is use_object only (no interact fallback)
            safe(function() return core.input.use_object(obj) end)
            trail("act", "use quest object %s (%.1f yd, use %d)",
                tostring(safe(function() return obj:get_name() end)), odist, g_obj.uses)
        end
        state.set_note("Quest", "Guide: click " .. label)
        return true
    end
    local opos = safe(function() return obj:get_position() end)
    if opos and not movement.is_blocked(opos) then
        walk_to(opos, label, nil, true)
        return true
    end
    return false
end

local function camp_mob(player, wps)
    for i = 1, #wps do
        local unit = guide.find_camp_mob(player, wps[i].pos, CAMP_RADIUS)
        if unit then
            return unit
        end
    end
    return nil
end

-- CLOSEST OF THE QUEST'S MOB (2.139.0). The raid-marked unit used to win
-- outright however far away it was: every log of 2026-09-29 engaged a marked
-- Ragged Young Wolf 43-67 yd off ("no progress toward the combat", "target
-- unreachable") with others of the same wolf much closer. The mark, a name
-- match or a drop-source match now only says WHICH mob the step wants (its
-- npc id); the closest fightable unit with that id is the one attacked, and
-- the id is kept for the rest of the goal. The camp fallback (a guess) never
-- sets it.
local g_goal_npc = {}            -- "step|goal" -> npc id the goal is killing

local function npc_id_of(unit)
    local id = unit and safe(function() return unit:get_npc_id() end) or nil
    if type(id) == "number" and id > 0 then return id end
    return nil
end

local g_rxp_targets_logged = nil

local function kill_goal(player, goal, kind, wps, label)
    local now = izi.now()
    if now < g_scan_until then
        return false
    end
    g_scan_until = now + SCAN_GAP
    -- 1.4.0 (Zygor spec, kill / get): progress is core.quests.get_quest_objectives -
    -- every objective finished: stop and wait for Zygor to tick the goal off
    local q = tonumber(goal.quest_id)
    if q and q > 0 and type(guide.objectives) == "function" then
        local objs = guide.objectives(q)
        if type(objs) == "table" and #objs > 0 then
            local all = true
            for i = 1, #objs do if not objs[i].finished then all = false break end end
            if all then
                state.set_note("Quest", "Guide: " .. tostring(label) .. " - objectives finished, waiting for Zygor")
                return true
            end
        end
    end
    -- the closest LIVING unit whose get_npc_id is the goal's target_id or a number
    -- of get_objectives() (never an avoid id) - read fresh every tick, no memory
    -- 1.6.0 (audit): a "q" goal with no target of its own names no mob - the
    -- step's objective ids then include its talk / clicknpc NPCs: own targets only
    local own_only = goal.target_id == nil and (goal.target == nil or goal.target == "")
    local unit, d = guide.find_mob(player, MOB_RANGE, goal, own_only)
    TK.kill_none = (unit == nil) and ((guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index)))) or nil   -- 1.29.2
    if unit then
        trail("act", "closest %s (npc %s) at %.0f yd for %s", tostring(safe(function() return unit:get_name() end)),
            tostring(npc_id_of(unit)), d or -1, tostring(label))
        engage(player, unit, "Guide: " .. label)
        return true
    end
    return false
end

-- 1.29.1 (user): the step's enemy target within `yards` - kill / collect mobs,
-- an xp step's XP-worthy enemies. movement/mount dismounts for it.
function TK.enemy_target(player, yards)
    local goal, kind = TK.cur_goal, g_cur_kind
    if type(goal) ~= "table" or not player then return nil end
    if kind == "kill" or kind == "collect" then
        local own_only = goal.target_id == nil and (goal.target == nil or goal.target == "")
        return (guide.find_mob(player, yards, goal, own_only))
    elseif kind == "xp" then
        return (nearest_xp_enemy(player, yards))
    end
    return nil
end
do
    local ok_mt, mt = pcall(require, "movement/mount")
    if ok_mt and type(mt) == "table" then mt.enemy_fn = TK.enemy_target end
end

-- Zygor ".xp" / "Grind to N xp": pull the nearest valid enemy within
-- ENEMY_SCAN yards of the player, then walk the grind waypoints when none
-- are in range. Sitting "waiting at" never gained the XP (01:11 log).
local function xp_goal(player, goal, wps, label)
    local now = izi.now()
    if now < g_scan_until then
        return false
    end
    g_scan_until = now + SCAN_GAP
    -- 3.0.3: the GUI Pull Radius around the player (was ENEMY_SCAN, 100 yd)
    local range = gui.slider("pull_radius", 20)
    local unit, d = nearest_xp_enemy(player, range)
    if not unit then
        return false
    end
    trail("act", "xp grind: %s at %.0f yd (within %.0f yd of the player)",
        tostring(safe(function() return unit:get_name() end)), d or -1, range)
    engage(player, unit, "Guide: " .. (label or "grinding"))
    return true
end

-- ----------------------------------------------------------------------------
-- TICK
-- ----------------------------------------------------------------------------

local function goal_label(goal, wps)
    local o = guide.goal_objective(goal)
    if o and o.text then
        return o.text
    end
    if goal.text then
        return goal.text
    end
    if wps[1] and wps[1].title then
        return wps[1].title
    end
    return tostring(goal.quest_id or goal.action or "?")
end

-- CONTINUOUS ROUTE WALKING (2.241.0; 1.20.0: Zygor's chain again, the
-- 1.4.0 / 1.5.0 one-walk-per-waypoint spec is retired). Replaces the end of
-- tick_inner, which walked one waypoint at a time and stood still at a
-- single-waypoint goal.
--   * kill / collect / xp goals walk guide.route: every step waypoint, the
--     arrow, and a patrol ring around a lone point - looped, never "waiting at";
--   * the next point is handed to the path CHAIN_WP yards before the current
--     one is reached (a seamless retarget), moving or not, so the walk never
--     stops on a point;
--   * back from a fight, loot or rest (the route was not walked for
--     IS.rt.GAP s) the walk resumes at the NEAREST route point, not the stale
--     one it was heading for before the fight;
--   * a point the path reports unreachable / off the mesh is skipped for the
--     next one instead of standing on "cannot reach".
-- Accept / turn-in / talk / fly goals keep their own waypoints and arrival.
-- Kept on IS, outside tick_inner: tick_inner sits at the 60-upvalue limit.
IS.rt = { t = 0, GAP = 1.0 }

-- 2.298.0: NOT MOVING WHILE WALKING. The 02:31 and 02:32 sessions asked
-- Sentinel for a Rumbleshot's Ammo route point 153 yd away, got
-- "no_path (no height at that spot)" once, and then stood still with
-- "Guide: 0/1 Rumbleshot's Ammo" - no new request, no next point, until the
-- 5-minute watchdog. Two nets: a route point whose path failed (any reason,
-- not only off-mesh) is skipped for the next one; and STILL_S seconds
-- without STILL_YD yards of movement while the bot means to walk forces a
-- fresh path (and the next point on a route), logged with the movement state.
IS.still = { x = nil, y = nil, t = 0, seen = 0, S = 6.0, YD = 2.0 }   -- 2.319.0: S was 10

-- 2.319.0: WHERE EACH QUEST'S WORK IS. A kill / collect goal records its
-- goal and waypoints by quest id, so a turn-in that the game says is not
-- ready (is_quest_complete false, the quest in the log) goes back there and
-- finishes the objectives first (20:20 log: a Webwood Venom turn-in with
-- 1/10 sacs - "NOT confirmed - still on the quest", three times).
IS.qwork = {}
IS.remember_work = function(goal, kind, wps)
    if (kind ~= "kill" and kind ~= "collect") or type(wps) ~= "table" or #wps == 0 then return end
    local ids = type(guide.goal_quest_ids) == "function" and guide.goal_quest_ids(goal) or nil
    if type(ids) ~= "table" or #ids == 0 then ids = { goal.quest_id } end
    for i = 1, #ids do
        local q = tonumber(ids[i])
        if q and q > 0 then IS.qwork[q] = { goal = goal, kind = kind, wps = wps, t = izi.now() } end
    end
end
--- An unfinished turn-in: the work goal to do instead (goal, kind, wps, label), or nil.
IS.finish_first = function(goal, kind)
    if kind ~= "turnin" then return nil end
    local q = tonumber(goal and goal.quest_id)
    if not q or q <= 0 then return nil end
    local okn, npcm = pcall(require, "quest/npc")
    if not okn or type(npcm) ~= "table" then return nil end
    local in_log = type(npcm.in_log) == "function" and npcm.in_log(q, nil) or nil
    -- audit 1.19.0: `f() or nil` turned quest_ready's false into nil
    local ready = nil
    if type(npcm.quest_ready) == "function" then ready = npcm.quest_ready(q) end
    if in_log ~= true or ready ~= false then return nil end
    if type(guide.needs_progress) == "function" and guide.needs_progress(q) ~= true then return nil end
    local w = IS.qwork[q]
    if not w then
        if IS.finish_logged ~= q then
            IS.finish_logged = q
            trail("quest", "turn-in of quest %d: objectives not done, and no gathering spot known - turning in as the guide says", q)
        end
        return nil
    end
    if IS.finish_logged ~= q then
        IS.finish_logged = q
        local objs = type(guide.objectives) == "function" and guide.objectives(q) or {}
        local parts = {}
        for i = 1, #objs do parts[#parts + 1] = tostring(objs[i].text or objs[i].description or "?") end
        trail("quest", "turn-in of quest %d not ready (%s) - back to finish it first",
            q, #parts > 0 and table.concat(parts, "; ") or "objectives not done")
    end
    return w.goal, w.kind, w.wps, "finish before turn-in: " .. tostring(w.goal and w.goal.text or q)
end

-- 2.311.0: route points are no longer moved to a terrain height (2.300.0 /
-- 2.308.0 IS.fix_z, a terrain ray per point) - they keep the guide's height
-- and Sentinel finds the ground there.

IS.watch_still = function(pts, must_do, label)
    local now = izi.now()
    local me = safe(function() return izi.me():get_position() end)
    local w = IS.still
    if not me then return end
    -- ticks spent fighting / resting / looting are not this walk's time
    if not w.x or (now - w.seen) > 2.0
        or geometry.distance_flat(me, { x = w.x, y = w.y, z = me.z }) > w.YD then
        w.x, w.y, w.t = me.x, me.y, now
    end
    w.seen = now
    -- 1.7.18 (user: outdoors, alive or dead, the outdoor unstick - left / right
    -- with 3 jumps, movement.lua - is the ONLY stuck logic): no fresh-path stop
    -- here outdoors; it would end an unstick try mid-way
    if safe(function() return izi.me():is_indoors() end) ~= true then
        w.t = now
        return
    end
    local target = pts[math.min(g_move, #pts)].pos
    local d = geometry.distance_flat(me, target)
    if type(d) ~= "number" or d <= (must_do and TALK_ARRIVE or ARRIVE) + 2 then
        w.t = now                    -- there: standing is fine
        return
    end
    if (now - w.t) < w.S then return end
    w.t = now
    trail("route", "no movement for %.0f s toward point %d of %d (%.0f yd) for %s - moving %s, owner %s, state %s, last fail %s - fresh path%s",
        w.S, g_move, #pts, d, tostring(label), tostring(movement.is_moving()),
        tostring(safe(movement.owner)), tostring(safe(movement.state)),
        tostring(movement.last_fail_reason()), (#pts > 1 and not must_do) and ", next point" or "")
    movement.clear_fail()
    g_force_path = true
    if #pts > 1 and not must_do and not indoors() then IS.next_wp(#pts) end
end

IS.next_wp = function(n)
    g_move = g_move + 1
    if g_move > n then
        g_move = 1
    end
end

-- GUIDE MISMATCH (2.281.0, quest/mismatch.lua): a step in another zone with
-- no path on foot - the guide for another race / start zone is loaded. The
-- bot holds with a note instead of walking at it forever.
IS.mm = require("quest/mismatch")

IS.DONE = require("quest/done")               -- 1.13.0: the completed-quest set
IS.done_said = {}
--- 1.13.0: a goal for quests this character has completed (and none in the
--- log) is skipped at once, with one line; the step it belongs to is noted
--- (IS.done_step) so the step-complete branch can skip it in the guide.
IS.done_skip = function(goal, kind)
    local yes, ids = IS.DONE.skip(goal, kind)
    if not yes then return false end
    local key = (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index)))
    if not IS.done_said[key] then
        IS.done_said[key] = true
        trail("quest", "step %d goal %d: quest %s already completed - goal skipped", guide.step_num(),
            goal.index or 0, table.concat(ids, ", "))
    end
    guide.mark_goal_done(guide.step_num(), goal.index)
    IS.done_step = guide.step_num()
    state.set_note("Quest", "Guide: quest already completed - skipped")
    return true
end
-- ZYGOR HEARTH (user, 2026-10-17): item Hearthstone 6948, used out of
-- combat while standing still; Zygor completes the goal when the zone
-- matches its param (not in the API goal table). On cooldown / not carried:
-- the bot waits here and says why (no guessing at another way there).
IS.HEARTH_ID = 6948
IS.HEARTH_GAP = 15
IS.hearth = { key = nil, used_t = -1e9 }
IS.hearth_goal = function(player, goal, label)
    local key = (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index)))
    if IS.hearth.key ~= key then IS.hearth.key, IS.hearth.used_t = key, -1e9 end
    local now = izi.now()
    if safe(function() return player:is_casting_spell() end) == true then
        state.set_note("Quest", "Guide: casting Hearthstone")
        return true
    end
    local okb, bags = pcall(require, "bags")
    if not okb or type(bags) ~= "table" or bags.count(IS.HEARTH_ID) <= 0 then
        state.set_note("Quest", "PAUSED: Zygor wants the Hearthstone used (step " .. guide.step_num()
            .. ") but none is in the bags - hearth yourself or skip the step in Zygor")
        return true
    end
    local cd = safe(function() return player:get_item_cooldown(IS.HEARTH_ID) end)
    if type(cd) == "number" and cd > 0 then
        state.set_note("Quest", string.format("Guide: Hearthstone on cooldown (%.0f s) - waiting", cd))
        return true
    end
    movement.nav_stop()
    if movement.is_moving() then
        state.set_note("Quest", "Guide: stopping to use the Hearthstone")
        return true
    end
    if now - IS.hearth.used_t >= IS.HEARTH_GAP then
        IS.hearth.used_t = now
        local okb2, bg = pcall(require, "bags")
        if okb2 and bg.use_id(IS.HEARTH_ID) then
            trail("act", "Hearthstone used - %s", tostring(label))
        end
    end
    state.set_note("Quest", "Guide: Hearthstone - " .. tostring(label))
    return true
end

-- ZYGOR CONFIRM: completes only when clicked in Zygor's own window, which no
-- API can click - the bot holds and asks the user to click it.
IS.confirm_goal = function(player, goal)
    movement.nav_stop()
    state.set_note("Quest", "PAUSED: Zygor step " .. guide.step_num()
        .. " has a confirm button - click it in the Zygor window to carry on")
    return true
end

IS.mismatch = function(player, goal, wps)
    local me = safe(function() return player:get_position() end)
    local key = guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal and goal.index))
    local held, text = IS.mm.check(key, wps, me)
    if held then
        movement.nav_stop()
        state.set_note("Quest", text)
        return true
    end
    return false
end

-- 1.7.6: another continent with a walk-in portal (Zygor's data, quest/guide
-- PORTALS): the portal is walked like a waypoint (1.20.0: a plain walk_to) at
-- the player's own height (the server snaps the end to the mesh), then stepped
-- into; the loading screen and the new continent end it. True while handled.
-- 1.2.32 BOAT (movement/boat): Stormwind Harbor <-> Auberdine. A goal on the other continent
-- (Darkshore from the Eastern Kingdoms, or back) is the boat run: dock, wait for the ship, board,
-- ride, get off. True while the run is handled.
IS.walk_boat = function(player, dest_map)
    if type(movement.boat_wants) ~= "function" then return false end
    if not (type(movement.boat_active) == "function" and movement.boat_active()) then
        local route = movement.boat_wants(dest_map)
        if not route then return false end
        if not movement.boat_start(route) then return false end
    end
    state.set_note("Quest", "Boat: " .. tostring(type(movement.boat_status) == "function" and movement.boat_status() or "-"))
    return true
end

IS.walk_portal = function(player, dest_map)
    if type(guide.portal_toward) ~= "function" then return false end
    local p, title, node, step = guide.portal_toward(dest_map)
    if not p then return false end
    local me = safe(function() return player:get_position() end)
    if not me then return false end
    local pos = require("common/geometry/vector_3").new(p.x, p.y, me.z or 0)
    if walk_to(pos, "walking to " .. tostring(title), 1.5, false) then return true end
    -- 1.7.7: at the entry: a straight walk STEP_IN yd on, into the portal
    IS.portal_t = IS.portal_t or safe(function() return core.time() end) or 0
    local t = safe(function() return core.time() end) or 0
    if step and type(movement.step_into) == "function" then
        pcall(movement.step_into, require("common/geometry/vector_3").new(step.x, step.y, me.z or 0))
    end
    if t - IS.portal_t > 8 then
        state.set_note("Quest", "PAUSED: at " .. tostring(title) .. " - step into it; the bot carries on on the other side")
    else
        state.set_note("Quest", "Stepping into " .. tostring(title))
    end
    return true
end

-- 1.7.9: while a walk of a Zygor step runs (out of combat, not resting, not
-- at an NPC / in a dialog), the path ahead (PATH_AHEAD yd) is checked every
-- PATH_GAP s for eligible hostiles whose estimated threat radius it enters.
-- The first boundary along the route is engaged; combat uses lowest HP
-- among actual attackers, then quest travel resumes.
IS.PATH_AHEAD, IS.PATH_GAP, IS.path_t = 40, 0.5, -1e9
local IS_AVOID_SAID = {}       -- 1.11.0: "walked round" logged once per mob
IS.path_threat = function(player)
    if type(targeting.path_threats) ~= "function" or type(movement.path_ahead) ~= "function" then return false end
    if not (type(movement.is_navigating) == "function" and movement.is_navigating()) then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    if type(movement.npc_holding) == "function" and movement.npc_holding() then return false end
    local now = izi.now()
    if now - IS.path_t < IS.PATH_GAP then return false end
    IS.path_t = now
    -- Elites, guide-avoided units and +/-10 levels receive Sentinel avoidance
    -- zones before ordinary route threats are considered for combat.
    local ahead = movement.path_ahead(IS.PATH_AHEAD)
    if type(targeting.path_dangers) == "function" and type(movement.avoid_area) == "function" then
        local dangers = targeting.path_dangers(player, ahead) or {}
        local zoned = 0
        for i = 1, #dangers do
            local d = dangers[i]
            local nm = tostring(safe(function() return d.unit:get_name() end))
            local why = string.format("%s (level %s%s), aggro %.0f yd", nm, tostring(d.level),
                d.elite and ", elite" or "", d.r)
            local avoided = movement.avoid_area({ x = d.x, y = d.y, z = d.z }, d.r + 6, why)
            if not avoided then
                -- 1.2.58 (log 12:29-12:30, 1.2.56): the live stub declares no obstacle:add_zone, so avoid_area is always false.
                -- This branch STOPPED the walk every 0.5 s and the guide started it again each second - a stop, a plan_route
                -- and a follow_path per second for over a minute (and a path query to the server each time). Nothing is held
                -- now: the plan audit (movement/nav N.danger_at) already asks for a route round the danger before it is walked.
                local nk = "na" .. nm .. math.floor(d.x / 10)
                if now - (IS_AVOID_SAID[nk] or -1e9) > 60 then
                    IS_AVOID_SAID[nk] = now
                    trail("act", "%s is on the path: no avoidance zone available - the route planner walks round it, nothing is held", why)
                end
            else
                zoned = zoned + 1
                if not IS_AVOID_SAID[nm .. d.x] then
                    IS_AVOID_SAID[nm .. d.x] = true
                    trail("act", "%s is on the path: walked round (Sentinel avoidance zone)", why)
                end
            end
        end
        if zoned > 0 then
            state.set_note("Quest", "Guide: Sentinel routing around excluded enemies")
            return true -- do not pull an ordinary mob using the route being replaced
        end
    end
    local list = targeting.path_threats(player, ahead)
    local u = list[1]
    if not u then return false end
    trail("act", "%s (level %s) - its threat range is on the path: kill it first",
        tostring(safe(function() return u:get_name() end)), tostring(safe(function() return u:get_level() end)))
    targeting.combat_active()
    engage(player, u, "Guide: clearing the path")
    return true
end

-- 1.68.0: later incomplete Zygor work of this step (or a sticky after it).
local function later_zygor_work(goal)
    if type(goal) ~= "table" then return false end
    local function is_work(g)
        return type(g) == "table" and g.is_complete ~= true
            and g.action ~= nil and g.action ~= "" and g.action ~= "text" and g.action ~= "info"
    end
    local idx = tonumber(goal.index) or 0
    if not goal.sticky then
        local gl = (guide.step() or {}).goals or {}
        for j = idx + 1, #gl do
            if is_work(gl[j]) then return true end
        end
    end
    local stickies = type(guide.stickies) == "function" and (guide.stickies() or {}) or {}
    for s = 1, #stickies do
        local st = stickies[s]
        local sgl = type(st) == "table" and st.goals or {}
        local st_slot = type(st) == "table" and tonumber(st.slot) or s
        for i = 1, #sgl do
            if (1000 * st_slot + i) > idx and is_work(sgl[i]) then return true end
        end
    end
    return false
end

-- A goal with no waypoint at all and nothing to act on (log 2026-11-15, step 57 "click Felix's Box",
-- 0 waypoints: "no usable waypoint" every tick for a minute, never ending). Zygor hides a waypoint
-- that belongs to a conditional line, and the object was not in the object list. Ladder, once per
-- goal: look for the named object across the whole object list and walk to it (the 2026-11-15 log shows the box
-- resolving itself after ~75 s, once streamed in, so the wait is long); after NOWP_WAIT s
-- with neither, hold the goal locally so the step's other goals remain available.
IS.nowp = IS.nowp or {}
local NOWP_WAIT = 120 -- Streaming/search timeout, independent of the NPC interaction wait.
function IS.no_waypoint(player, goal, kind, label)
    local key = (guide.goal_key and guide.goal_key(goal)) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index))
    local st = IS.nowp[key]
    local now = izi.now()
    if not st then
        IS.nowp = { [key] = { t = now } }
        st = IS.nowp[key]
        trail("act", "%s (%s): no waypoint and nothing in sight - searching for up to %d s before holding this goal", tostring(label), tostring(kind), NOWP_WAIT)
    end
    if kind == "object" or kind == "collect" or kind == "item" then
        local obj = guide.find_object(player, 300, goal, object_skip_set())
        if obj then
            local opos = safe(function() return obj:is_valid() and obj:get_position() end)
            if opos and walk_to(opos, label, ARRIVE, true) then
                st.t = now
                return
            end
        end
        -- 1.2.73 ESP MEMORY: the object was seen within 100 yd earlier and has streamed out of view - walk to where it was
        -- (Sentinel plans the path); the real object is found again on arrival.
        local es = package.loaded["esp"]
        local mem = type(es) == "table" and type(es.goal_target) == "function" and es.goal_target(goal, object_skip_set()) or nil
        if mem and walk_to({ x = mem.x, y = mem.y, z = mem.z }, label, ARRIVE, true) then
            st.t = now
            if not st.esp_said then
                st.esp_said = true
                trail("act", "%s: ESP remembers %s %.0f yd away (seen %.0f s ago%s) - walking there", tostring(label), tostring(mem.name),
                    mem.d or -1, mem.seen_ago or -1, mem.visible and ", in view" or "")
            end
            return
        end
    end
    -- 1.2.11 CAMP MEMORY: a kill / collect goal that had waypoints earlier this run (IS.qwork, by quest id)
    -- and has none now goes back to the nearest of them and patrols there (log 16:43-17:01: "no usable
    -- waypoint for Dark Iron Spies" 55 times while the camp was known).
    if kind == "kill" or kind == "collect" then
        local w = IS.qwork[tonumber(goal and goal.quest_id) or -1]
        local me = w and safe(function() return izi.me():get_position() end)
        if w and me and type(w.wps) == "table" then
            local best, best_d = nil, nil
            for i = 1, #w.wps do
                local d = w.wps[i].pos and geometry.distance_flat(me, w.wps[i].pos)
                if type(d) == "number" and (not best_d or d < best_d) then best, best_d = w.wps[i], d end
            end
            if best and best_d > ARRIVE and walk_to(best.pos, label, ARRIVE) then
                if not st.camp_said then
                    st.camp_said = true
                    trail("act", "%s: no point now - walking back to the camp remembered from earlier", tostring(label))
                end
                st.t = now
                return
            end
        end
    end
    -- Zygor's live arrow is the step's destination even when it names a later goal (action log 2026-11-15, step
    -- 137: the kill had no point, the arrow pointed at the step's camp 550 yd away and the bot stood still).
    -- Work goals walk to it; accept / turn-in / talk goals do not (that would be another task's NPC).
    if kind == "kill" or kind == "collect" or kind == "xp" or kind == "object" or kind == "item" then
        local apos = type(guide.waypoint) == "function" and guide.waypoint() or nil
        if apos and walk_to(apos, label, ARRIVE) then
            if not st.arrow_said then
                st.arrow_said = true
                trail("act", "%s: no point of its own - walking to Zygor's arrow", tostring(label))
            end
            st.t = now
            return
        end
    end
    if (now - st.t) >= NOWP_WAIT and not st.done then
        st.done = true
        local why = "no waypoint and nothing to act on for " .. NOWP_WAIT .. " s"
        guide.hold_goal(guide.step_num(), goal.index, "blocked: " .. why)
        trail("quest", "%s: held locally; remaining goals stay available (%s)", tostring(label), why)
    end
end

IS.walk_route = function(player, goal, kind, wps, label)
    -- 1.3.1 (log 15:09: step 2 in Un'Goro, player in Stormwind): a goal whose
    -- own point is on another continent. Zygor's arrow, when it is a travel
    -- leg (route) on this continent, is walked; otherwise the bot pauses -
    -- boats / zeppelins / portals cannot be taken through the documented API.
    if #wps == 0 and type(guide.goal_off_continent) == "function" then
        local off, map_id, title = guide.goal_off_continent(goal)
        if off then
            local leg, leg_title = guide.route_leg()
            if leg then
                if walk_to(leg, "travel leg " .. tostring(leg_title or ""), ARRIVE) then return end
                state.set_note("Quest", "PAUSED: at Zygor's travel point " .. tostring(leg_title or "")
                    .. " - take the boat / zeppelin / portal there; the bot carries on when you arrive")
                return
            end
            if IS.walk_boat(player, map_id) then return end            -- 1.2.32
            if IS.walk_portal(player, map_id) then return end          -- 1.7.6
            movement.nav_stop()
            state.set_note("Quest", string.format("PAUSED: Zygor step %d is on another continent (%s, map %s) - travel there "
                .. "(boat / zeppelin / portal); the bot carries on when you arrive", guide.step_num(),
                tostring(title or "?"), tostring(map_id)))
            return
        end
    end
    if #wps == 0 then
        if guide.wrong_continent() then
            -- 1.7.6: Zygor's arrow on another continent (a goal with no point of
            -- its own, e.g. "talk Sid Limbardi" in Honor Hold): its portal
            local om = type(guide.offworld_map) == "function" and guide.offworld_map() or nil
            if om and IS.walk_boat(player, om) then return end         -- 1.2.32
            if om and IS.walk_portal(player, om) then return end
            IS.portal_t = nil
            state.set_note("Quest", "Guide: target is on another continent")
        else
            state.set_note("Quest", "Guide: no usable waypoint for " .. label)
            IS.no_waypoint(player, goal, kind, label)
        end
        return
    end
    local must_do = kind == "accept" or kind == "turnin" or kind == "talk" or kind == "fly"
    -- 1.20.0: Zygor's chain - kill / collect / xp goals walk guide.route
    -- (step waypoints, the arrow, a patrol ring around a lone point); accept /
    -- turn-in / talk / fly keep Zygor's own waypoints
    local pts = wps
    if not must_do and type(guide.route) == "function" then
        pts = guide.route(goal, kind, wps) or wps
    end
    IS.remember_work(goal, kind, wps)          -- 2.319.0
    -- audit P4: no second reach_z pass here - guide.to_world already measured
    -- each point's height (and applied nav.reach_z) for this goal's waypoints
    if g_move > #pts then
        g_move = 1
    end
    local now = izi.now()
    -- Back on the route after a fight / loot / rest: the nearest point.
    if not must_do and #pts > 1 and now - IS.rt.t > IS.rt.GAP then
        local me = safe(function() return izi.me():get_position() end)
        if me then
            local best, best_d = g_move, nil
            for i = 1, #pts do
                local d = geometry.distance_flat(me, pts[i].pos)
                if type(d) == "number" and (not best_d or d < best_d) then best, best_d = i, d end
            end
            -- 2.308.0: standing on the nearest point (within CHAIN_WP) means it
            -- is done - resume at the NEXT one. Resuming at it undid the chain
            -- step every time a tick was missed: the 15:22 session flipped
            -- between point 8 (7 yd) and point 1 (148 yd) once a second, and
            -- the character ran in circles until it was stopped.
            if best_d and best_d <= CHAIN_WP then
                best = best % #pts + 1
            end
            if best ~= g_move then
                trail("route", "resume at point %d of %d (%.0f yd) for %s", best, #pts, best_d or -1, tostring(label))
            end
            g_move = best
        end
    end
    IS.rt.t = now
    -- REACHABILITY FIRST (2.59.0): the Sentinel Navigation client's reachability
    -- answer (movement.reachable), cached.
    -- A waypoint it reports unreachable is skipped for the next one; when
    -- every waypoint of the goal is unreachable the goal is skipped with a log
    -- line, instead of walking into the 5-minute stuck watchdog.
    -- Never for an accept / turn-in / talk goal (2.71.0): the guide cannot
    -- move on without it, so skipping it left the bot idle on "step complete"
    -- with the quest never taken. Those keep walking to their waypoint.
    if type(movement.reachable) == "function" and not must_do and not indoors() then
        local tried = 0
        -- 1.67.0: skip only after validate_destination (and its floor retry)
        -- has answered. A pending height query is not "unreachable".
        while tried < #pts do
            local pos = pts[g_move].pos
            if type(movement.reach_settled) == "function" and movement.reach_settled(pos) ~= true then
                break
            end
            if movement.reachable(pos) ~= false then break end
            IS.next_wp(#pts)
            tried = tried + 1
        end
        -- 2.319.0: NEVER SKIP UNFINISHED QUEST WORK FOR "UNREACHABLE". The
        -- answers were asked at guessed heights; the quest still needs these
        -- kills / items (a skipped step reached the turn-in with 1/10 sacs).
        -- The points' answers are dropped, and the walk itself (with its
        -- height search) is tried for UNREACH_RETRY s before any skip.
        if tried >= #pts then
            local q = tonumber(goal.quest_id)
            local unfinished = q and q > 0 and type(guide.needs_progress) == "function" and guide.needs_progress(q) == true
            local key = (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index)))
            IS.unreach_first = IS.unreach_first or {}
            local first = IS.unreach_first[key]
            if not first then first = now IS.unreach_first[key] = now end
            if unfinished and (now - first) < 180 then
                if type(movement.reach_forget) == "function" then
                    for i = 1, #pts do pcall(movement.reach_forget, pts[i].pos) end
                end
                trail("quest", "every waypoint of goal %d read unreachable, but quest %d is not done - walking there anyway",
                    goal.index or 0, q)
                tried = 0
            end
        end
        if tried >= #pts then
            -- Preserve siblings until the extended step watchdog decides to skip.
            local sk = (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index)))
            IS.unreach_key = sk
            trail("quest", "every waypoint of goal %d is unreachable - skipping it", goal.index or 0)
            require("actlog").console_warn("[Master Farmer - Zygor Forever] Quest goal '" .. tostring(label)
                .. "': Sentinel Navigation reports every waypoint unreachable - holding this goal.")
            guide.hold_goal(guide.step_num(), goal.index, "blocked: every waypoint unreachable")
            return
        end
    end
    -- DEATH ZONES (2.247.0): route points inside an area the player died in 3
    -- times are skipped; with every point inside, the goal waits outside.
    if not must_do then
        local ok_dz, dz = pcall(require, "deathzones")
        if ok_dz and type(dz) == "table" and type(dz.zone_at_pos) == "function" then
            local tried = 0
            while tried < #pts and dz.zone_at_pos(pts[g_move].pos) do
                IS.next_wp(#pts)
                tried = tried + 1
            end
            if tried >= #pts then
                local zn = dz.zone_at_pos(pts[g_move].pos)
                state.set_note("Quest", string.format("Guide: avoiding the %s area (died there %d times)",
                    tostring(zn and zn.name or "?"), zn and zn.deaths or 3))
                return
            end
        end
    end
    -- 1.67.0: a kill / collect / xp patrol ring is one Sentinel plan_route +
    -- follow_path, not a chain of move_to at the centre's height.
    if not must_do and #pts >= 3 and type(movement.follow_nodes) == "function" then
        local npat = 0
        for i = 1, #pts do
            if pts[i].patrol == true then npat = npat + 1 end
        end
        if npat >= 3 then
            local nodes = {}
            for i = 1, #pts do
                local p = pts[i].pos
                if type(p) == "table" then nodes[#nodes + 1] = p end
            end
            if #nodes >= 3 and not indoors() and movement.follow_nodes(nodes) then
                -- 1.75.0 (action log 2026-11-15: 50 s with the status stuck on "Looting" and no event): the
                -- patrol is a real activity - say so in the status line and the log
                state.set_note("Quest", string.format("Guide: patrolling for %s (%d points)", tostring(label), #nodes))
                trail("act", "patrol %d points for %s", #nodes, tostring(label))
                IS.watch_still(pts, must_do, label)
                return
            end
        end
    end
    if #pts > 1 and not must_do and not indoors() then
        -- A route point the path could not reach: the next one, not a stand.
        -- 2.298.0: any failed path (a "no height at that spot" no_path too),
        -- not only off-mesh, moves on to the next point
        local why = movement.last_fail_reason()
        local cp = pts[g_move].pos
        -- 1.20.0 (Zygor 4.0.8): the nav server timed out / is down - the
        -- point is not unreachable: keep it (movement backs off and asks again)
        if why and movement.server_trouble(why) then
            movement.clear_fail()
            trail("route", "point %d of %d: nav server trouble (%s) - kept, asking again", g_move, #pts, tostring(why))
            why = nil
        end
        if movement.is_blocked(cp) or why then
            movement.clear_fail()
            trail("route", "point %d of %d unreachable (%s) - next point", g_move, #pts, tostring(why or "blocked"))
            IS.next_wp(#pts)
        end
        -- 1.20.0: chain ahead - the next point before this one is reached
        if near(pts[g_move].pos, CHAIN_WP) then
            IS.next_wp(#pts)
        end
    elseif #pts > 1 and movement.is_moving() and near(pts[g_move].pos, CHAIN_WP) then
        IS.next_wp(#pts)
    end
    -- 3.0.6: FLIP-FLOP GUARD. Two points stacked one over the other (a mine
    -- under a hill) made the walker swap between them every tick for a
    -- minute (log 2026-10-12 10:39). Three swaps back and forth within
    -- FLIP_WINDOW s hold the current point for FLIP_HOLD s.
    do
        local fl = IS.flip
        if not fl then fl = { last = nil, prev = nil, t = 0, n = 0, lock = nil, lock_until = 0 } IS.flip = fl end
        if fl.lock and now < fl.lock_until and fl.lock <= #pts then
            g_move = fl.lock
        elseif g_move ~= fl.last then
            if g_move == fl.prev and (now - fl.t) < 4 then fl.n = fl.n + 1 else fl.n = 0 end
            fl.prev, fl.last, fl.t = fl.last, g_move, now
            if fl.n >= 3 then
                fl.lock, fl.lock_until, fl.n = g_move, now + 10, 0
                trail("route", "points %s / %d flip-flopping - holding point %d for 10 s",
                    tostring(fl.prev), g_move, g_move)
            end
        end
    end
    -- Zygor Forever: tell the movement layer which point follows this one (Forever
    -- Questing's next-waypoint hint) so its floors are known before the chain retarget.
    if type(movement.hint_next) == "function" then
        local nx = g_move % #pts + 1
        local np = #pts > 1 and pts[nx] and pts[nx].pos or nil
        local hkey
        if np and nx ~= g_move then
            hkey = string.format("%s|%s|%d", tostring(guide.step_num()), tostring(goal.index or 0), nx)
        elseif #pts <= 1 or nx == g_move then
            -- 1.2.84: a goal with ONE waypoint (accept / turn-in / talk / most kills) hints the waypoint of the NEXT open goal of the
            -- step, so its floors and its path are fetched while this goal is still being walked (no wait at the goal change)
            local okg, goals = pcall(guide.goals)
            if okg and type(goals) == "table" and type(guide.goal_waypoints) == "function" then
                local from = tonumber(goal.index) or 0
                for _, g2 in ipairs(goals) do
                    local gi = tonumber(g2.index)
                    if gi and gi > from and g2.is_complete ~= true then
                        local okw, w2 = pcall(guide.goal_waypoints, g2)
                        local p2 = okw and type(w2) == "table" and w2[1] and w2[1].own and w2[1].pos or nil
                        if p2 then np, hkey = p2, string.format("%s|goal%d", tostring(guide.step_num()), gi) break end
                    end
                end
            end
        end
        if np and hkey then pcall(movement.hint_next, np, hkey) end
    end
    local arrive = must_do and TALK_ARRIVE or ARRIVE
    if walk_to(pts[g_move].pos, label, arrive) then
        IS.watch_still(pts, must_do, label)
        return
    end
    -- Standing on this waypoint with nothing to do. A kill, collect or xp
    -- loop moves on to the next of its waypoints; anything else waits here
    -- for the addon to tick the goal off.
    if #pts > 1 then
        IS.next_wp(#pts)
        walk_to(pts[g_move].pos, label, arrive)
        return
    end
    if kind == "xp" then
        state.set_note("Quest", "Guide: grinding - scanning for enemies")
        return
    end
    -- 1.8.1 (log 2026-10-19 16:13, step 74 "goto 52,62 / talk Foreman Biggums /
    -- turnin 10099"): the goto had no waypoint of its own (the step's one is the
    -- turnin's, goal_num 3) - the bot walked Zygor's arrow there, stood next to
    -- Biggums and "waited at 52,62" for 4 min: Zygor never ticks a goto that is
    -- not the step's last (Goal.lua default_not_completable). Arrived at the
    -- arrow's point (own or not), the step's next goal is worked.
    if kind == "goto" and pts[g_move] and IS.goto_hand_off(goal, label) then
        return
    end
    -- 1.6.0 (Zygor Goal.lua: talk / click / use goals are passive - never ticked):
    -- at the goal's waypoint with nothing of it in sight for TK.PASSIVE_WAIT s,
    -- the step's next goal is worked (the goal is passed over, not waited on)
    if kind == "object" or kind == "item" or kind == "talk" then
        local wk = (guide.goal_key and guide.goal_key(goal) or (tostring(guide.step_num()) .. "|" .. tostring(goal.index)))
        TK.wait_at = TK.wait_at or {}
        local first = TK.wait_at[wk]
        if not first then first = now TK.wait_at[wk] = now end
        if (now - first) >= npc_wait_s() then
            if later_zygor_work(goal) then
                trail("quest", "%s: nothing of it in sight at its waypoint for %d s - the step's next goal", tostring(label),
                    npc_wait_s())
                guide.hold_goal(guide.step_num(), goal.index, "nothing of it in sight at its waypoint")
                return
            end
            trail("quest", "%s: nothing of it in sight - last Zygor work, keep performing the current step",
                tostring(label))
        end
    end
    state.set_note("Quest", "Guide: waiting at " .. label)
end

-- Whole-step skipping is the final recovery, after five active minutes without
-- objective progress or getting closer to the destination. Short failures hold
-- individual goals, so siblings are attempted first. Combat/rest gaps do not age it.
function IS.step_watchdog(player)
    local now = izi.now()
    local key = guide.context_key()
    local parts, seen = {}, {}
    local goals = guide.goals() or {}
    for i = 1, #goals do
        local g = goals[i]
        parts[#parts + 1] = tostring(g.index or i) .. ":" .. tostring(g.is_complete == true or guide.goal_completed(g))
        local q = tonumber(g.quest_id)
        if q and not seen[q] then
            seen[q] = true
            for _, o in ipairs(guide.objectives(q) or {}) do
                parts[#parts + 1] = tostring(q) .. ":" .. tostring(o.text) .. ":" .. tostring(o.num_fulfilled) .. ":" .. tostring(o.finished)
            end
        end
    end
    local signature = table.concat(parts, "|")
    local w = IS.step_watch
    if not w or w.key ~= key then w = { key = key, t = now, seen = now, sig = signature } IS.step_watch = w end
    if now - w.seen > 2 or now < w.seen or signature ~= w.sig then w.t = now end
    w.seen, w.sig = now, signature
    local dest = guide.waypoint()
    local pos = safe(function() return player:is_valid() and player:get_position() end)
    if dest and pos then
        local d = geometry.distance(pos, dest)
        if not w.dest or geometry.distance(w.dest, dest) > 5 then
            w.dest, w.best, w.t = {x=dest.x,y=dest.y,z=dest.z}, d, now
        elseif d < (w.best or d) - 2 then
            w.best, w.t = d, now
        end
    end
    if movement.transport_blocked and movement.transport_blocked() then w.t = now return false end
    if movement.boat_active and movement.boat_active() then w.t = now return false end      -- 1.2.32: waiting for / riding the ship is no stall
    if now - w.t < 300 or now < (w.retry or 0) then return false end
    w.retry = now + 30
    local reason = "no objective or destination progress for 300 active seconds"
    trail("quest", "step %s: %s; requesting final step skip", tostring(guide.step_num()), reason)
    if guide.skip_current(reason) then
        IS.step_watch = nil
        movement.nav_stop()
        state.set_note("Quest", "Guide: skipped stalled step after 5 minutes without progress")
        return true
    end
    return false
end

local tick_inner

--- The tick, plus a breadcrumb whenever the status line changes - the finest
--- grained record of what the bot was doing that is cheap enough to keep on.
function quest.tick(player)
    tick_inner(player)
    -- (1.75.0: the status line is recorded once, as an action event, by state.set_note)
    last_note = state.note
end

local g_step_retried, g_step_hold_logged, g_unknown_logged = nil, nil, nil

tick_inner = function(player)
    g_in_dialog = false
    g_in_travel = false
    if type(movement.keep_path) == "function" then
        movement.keep_path(false)
    end
    -- FIGHT FIRST (2.38.0). Anything attacking the player, and the fight
    -- already under way, come before every other branch of this tick. The
    -- early returns below (Zygor not loaded, no active step, step
    -- complete, resting) used to come first, and the first two also released
    -- combat movement every tick - a mob could hit the bot with no answer.
    -- Loot a finished kill before fight_back's "combat not over" sit and
    -- before the next pull. The 00:52 log queued every corpse, then the
    -- next wolf was engaged and each corpse timed out with 0 attempts.
    do
        local u = state.target.unit
        local live = u and state.target.kind == "kill"
            and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_dead() end) ~= true
        local attacked = type(targeting.attackers) == "function" and targeting.attackers(player) > 0
        if not live and not attacked and loot and type(loot.has_work) == "function" and loot.has_work(player) then
            if not g_loot_wait then
                g_loot_wait = true
                movement.nav_stop()
                if type(movement.combat_release) == "function" then
                    movement.combat_release()
                end
            end
            state.set_note("Quest", "Guide: looting before the next pull")
            return
        end
    end
    probe("q:fight_back")
    if fight_back(player, g_label) then
        if type(targeting.attackers) == "function" and targeting.attackers(player) > 0 then
            g_loot_wait = false
        end
        return
    end

    -- 1.7.9: a hostile mob within 3 levels whose threat range the walk is about
    -- to run into is killed first; the walk goes on afterwards
    probe("q:path_threat")
    if IS.path_threat(player) then return end

    local read_problem = guide.read_problem and guide.read_problem()
    if read_problem then
        release_combat()
        movement.nav_stop()
        state.set_note("Quest", "Zygor API read pending: " .. tostring(read_problem))
        return
    end
    if not guide.is_loaded() then
        release_combat()
        trail("quest", "Zygor not loaded")
        state.set_note("Quest", "Zygor Guides is not loaded - enable the Zygor Guides addon")
        return
    end
    if not guide.ready() then
        release_combat()
        trail("quest", "Zygor has no active step")
        state.set_note("Quest", "Zygor: no active step - load a guide in Zygor (or the guide is finished)")
        return
    end

    if guide.context_key and IS.context ~= guide.context_key() then
        IS.context = guide.context_key()
        TK.hold_next, TK.closing, TK.cur_goal = nil, nil, nil
        TK.wait_at, TK.kill_none = {}, nil
        IS.done_step, IS.dumped_step, IS.flip = nil, nil, nil
        local ok_bs, bs = pcall(require, "quest/bagstart")
        if ok_bs and type(bs.reset) == "function" then bs.reset() end
    end
    if IS.step_watchdog(player) then return end
    probe("q:learn_npc_id")
    guide.learn_npc_id(player)

    probe("q:goal")
    local goal = guide.goal()
    -- 1.68.0: a local hold is not a skip of Zygor's current step. Confirm /
    -- manual / unknown and a user skip still pause; every other held goal is
    -- still walked / talked / killed until Zygor marks it complete.
    if goal and goal.held then
        local kind0 = guide.classify(goal)
        local why = tostring(goal.held)
        local pause = kind0 == "confirm" or kind0 == "manual" or kind0 == "unknown"
            or why:find("skipped", 1, true) ~= nil or why:find("blocked:", 1, true) == 1
        if pause and kind0 == "turnin" and goal.quest_id
            and (npc.quest_ready(goal.quest_id) == true or npc.quest_log_state(goal.quest_id) == "complete") then
            guide.release_goal(goal.index)
            goal.held, pause, TK.notready = nil, false, nil
        end
        if pause then
            movement.nav_stop()
            state.set_note("Quest", "WAITING for Zygor: step " .. tostring(guide.step_num()) .. " - " .. tostring(goal.held))
            -- 1.2.48 A BLOCKED GOAL DOES NOT WAIT FOR EVER (action log 2026-11-18: 312 stale "WAITING for Zygor ... blocked: no
            -- progress after interaction retries" statuses). After BLOCKED_SKIP_S on the same held goal the step is skipped through
            -- the same request the no-actionable-goal path uses (Zygor may refuse it at the end of a guide).
            if why:find("blocked:", 1, true) == 1 then
                local bk = tostring(guide.step_num()) .. "|" .. tostring(goal.index)
                local nowb = izi.now()
                if IS.blocked_since == nil or IS.blocked_key ~= bk or nowb < IS.blocked_since then
                    IS.blocked_key, IS.blocked_since = bk, nowb
                end
                if nowb - IS.blocked_since >= 120 then IS.stuck_skip("goal blocked for 2 min (" .. why .. ")") end
            end
            return
        end
    end
    if not goal then
        -- Every goal of the step is done and the addon has not moved on yet.
        -- Standing still is right: inventing work here would fight whatever
        -- it does next.
        commit_pending()
        -- STEP COMPLETE ONLY ON OUR SIDE (2.150.0). Goals the bot marked done
        -- itself (a trainer not found, a talk that timed out) do not move
        -- Zygor on; standing here waited for ever. After STEP_RETRY the
        -- marks are forgotten and the goals are tried again.
        -- ZYGOR (no skip-step API, user 2026-10-17): goals the bot marked done
        -- itself do not move Zygor on. After STEP_RETRY they are forgotten ONCE
        -- and tried again; if the same step is still incomplete after that,
        -- the bot stops here with the step number (the marks stay, so the
        -- goals are not redone) until Zygor moves on or the user steps in.
        -- 1.4.0 (rule 10): the step is done - wait for Zygor to move get_current_step().num
        local now_c = izi.now()
        if guide.has_local_done() then
            -- 1.13.0: goals of this step were skipped as already completed
            -- (IS.done_skip): the guide moves on now, not after STEP_RETRY
            if IS.done_step == guide.step_num() and type(guide.skip_current) == "function"
                and guide.skip_current("every quest of this step is already completed") then
                IS.done_step = nil
                state.set_note("Quest", "Guide: skipped a step of completed quests")
                return
            end
            local num = guide.step_num()
            if g_step_retried == num then
                state.set_note("Quest", string.format(
                    "PAUSED: Zygor step %d is still incomplete after a retry - finish or skip it in Zygor", num))
                if g_step_hold_logged ~= num then
                    g_step_hold_logged = num
                    trail("quest", "step %d: still incomplete after its goals were retried - holding (Zygor has no skip)", num)
                end
                return
            end
            if g_complete_since == 0 then g_complete_since = now_c end
            if (now_c - g_complete_since) >= STEP_RETRY then
                g_complete_since = 0
                g_step_retried = num
                trail("quest", "step %d: Zygor did not move on in %ds - retrying its goals once",
                    num, STEP_RETRY)
                guide.forget_local_done()
                return
            end
        else
            g_complete_since = 0
        end
        state.set_note("Quest", "WAITING for Zygor: step " .. tostring(guide.step_num()) .. " has no actionable goals; advance or review it in Zygor")
        IS.stuck_skip("step has no actionable goals")
        return
    end
    g_complete_since = 0

    -- A rest outranks the guide.
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then
        movement.nav_stop()
        pcall(function() core.input.stop_attack() end)
        return
    end

    probe("q:classify")
    local kind = guide.classify(goal)
    if IS.done_skip(goal, kind) then return end      -- 1.13.0: completed quests
    -- ZYGOR: an action nobody has defined is never guessed at - pause and
    -- prompt with the raw goal (log + note) until it is defined.
    if kind == "unknown" then
        movement.nav_stop()
        local raw = string.format("action '%s'  quest %s  npc %s (%s)  target %s (%s)", tostring(goal.action),
            tostring(goal.quest_id), tostring(goal.npc_id), tostring(goal.npc), tostring(goal.target_id or goal.item_id),
            tostring(goal.target))
        state.set_note("Quest", string.format("PAUSED: Zygor step %d goal %d - %s is not handled yet. Tell Master Farmer what it does.",
            guide.step_num(), goal.index or 0, raw))
        local k = guide.step_num() .. "|" .. tostring(goal.index) .. "|" .. tostring(goal.action)
        if g_unknown_logged ~= k then
            g_unknown_logged = k
            trail("quest", "UNKNOWN ZYGOR ACTION step %d goal %d: %s", guide.step_num(), goal.index or 0, raw)
        end
        return
    end
    probe("q:goal_waypoints")
    local wps = guide.goal_waypoints(goal)
    local label = goal_label(goal, wps)
    -- An accept / turn-in is labelled by its quest (2.63.0): goal_label gave
    -- the quest's objective line, so a turn-in read "Objective Complete" and
    -- an accept "Ice Claw Bear slain: 0/6".
    if kind == "accept" or kind == "turnin" then
        local title = quest_title(goal, kind)
        if title then
            label = (kind == "accept" and "accept " or "turn in ") .. title
        end
    end

    local key = string.format("%d|%d|%s|%s|%s", guide.step_num(), goal.index or 0,
        tostring(goal.quest_id), kind, tostring(goal.action))
    key = (guide.goal_key and guide.goal_key(goal) or key) .. "|" .. tostring(kind)
    if key ~= g_key then
        commit_pending()
        g_key = key
        g_move = 1
        g_scan_until = 0
        g_act_until = 0
        g_kill_until = 0
        g_nosource_since = 0
        g_talk_opened = 0
        g_bad_givers = {}
        g_bad_since = 0
        g_obj.guid, g_obj.uses = nil, 0
        TR.reset_goal()
        g_giver_walk = nil
        g_close_in = false
        g_not_ready = 0
        g_hold_until = 0
        g_bind_asked = false
        g_talk_interact_t = 0
        g_force_path = false
        stall_reset(izi.now())
        -- A step change mid-fight keeps the fight; only an idle target is
        -- dropped.
        if safe(function() return player:is_in_combat() end) ~= true then
            state.reset_target()
        end
        trail("quest", "step %d goal %d: %s [%s] %s (quest %s, %d waypoint%s)",
            guide.step_num(), goal.index or 0, tostring(goal.action), kind, tostring(label),
            tostring(goal.quest_id), #wps, #wps == 1 and "" or "s")
        -- 1.3.1: the whole step once per step (goals, waypoints, continents)
        if IS.dumped_step ~= guide.step_num() and type(guide.dump_step) == "function" then
            IS.dumped_step = guide.step_num()
            for _, line in ipairs(guide.dump_step()) do trail("zygor", "%s", line) end
        end
        debug("step %d goal %d: %s %s (quest %s, %d waypoint%s)",
            guide.step_num(), goal.index or 0, tostring(goal.action), tostring(label),
            tostring(goal.quest_id), #wps, #wps == 1 and "" or "s")
    end

    g_label = label

    -- A corpse of ours to loot comes before the next pull (2.25.0). Stop our
    -- own walk once, so loot.tick's walk to the corpse is not swallowed by
    -- navigation's "already moving" answer, then wait for it to finish.
    if loot and loot.has_work(player) then
        if not g_loot_wait then
            g_loot_wait = true
            movement.nav_stop()
        end
        state.set_note("Quest", "Guide: looting before the next pull")
        return
    end
    g_loot_wait = false
    -- 2.319.0: a turn-in the game says is not ready finishes its quest first
    -- 1.4.0 (Zygor spec rule 2): the first incomplete goal is worked as it is -
    -- no redirect to another goal (IS.finish_first is not used)
    probe("q:act " .. kind)
    g_cur_kind = kind
    TK.cur_goal = goal                       -- 1.29.1: the step's targets for the enemy dismount

    -- 1.34.0: Zygor's travel router says to fly (its arrow: "Talk to <npc> / Fly to
    -- <node>") - the flight master, the map, the flight; the goal goes on after landing
    if TR.route_flight(player, goal, kind, label) then
        return
    end
    -- 1.2.52: Zygor's route says use the Hearthstone (6948)
    if TR.route_hearth(player, goal, kind, label) then
        return
    end
    -- 1.2.54: the learned bind is the shortcut (Zygor's arrow never carries a hearth leg)
    do
        local okbh, BH = pcall(require, "bindhearth")
        if okbh and type(BH) == "table" and BH.consider(player, goal, kind, wps, label) then
            return
        end
    end
    -- A far goal: fly most of the way (2.115.0). A fly / hearth goal's
    -- waypoint is its destination elsewhere by design - no mismatch hold.
    if kind ~= "fly" and kind ~= "hearth" and kind ~= "confirm" and IS.mismatch(player, goal, wps) then
        return
    end
    -- 1.34.3 (user 2026-10-27, Telredor -> Chieftain Mummaki 2367 yd: "never attempted
    -- to use flightmaster"): a goal over FAR_TRAVEL yd away is flown toward - the
    -- nearest flight master, the known node landing closest. Zygor's router flight leg
    -- never reaches the API (its arrow stays the 'way' destination). Was "fly" goals
    -- only, which far_travel itself refuses - it never ran.
    if kind ~= "fly" and kind ~= "hearth" and kind ~= "confirm" and kind ~= "fpath"
        and TR.far_travel(player, goal, kind, wps, label) then
        return
    end

    -- QUEST TRAINER STEPS (2.149.0): questing follows the step. A Zygor
    -- ".train" / ".trainer" goal asks trainer.lua for a visit now (the
    -- every-3-levels rule is only for visits the bot decides on itself),
    -- walks to the step's waypoint until the class trainer is in sight, and
    -- is done when the visit finishes - or when Zygor ticks it off first.
    if IS.goal(player, goal, label) then
        return
    end
    -- 1.3.0: a Zygor trainer goal is never the class-trainer visit - its NPC
    -- not in sight yet: walk the goal's route toward it
    if IS.is_zygor_trainer(goal) then
        if not IS.zygor_trainer(player, goal, wps, label) then
            IS.walk_route(player, goal, kind, wps, label)
        end
        return
    end
    if prof_goal(player, goal, wps, label) then
        return
    end
    if train_goal(player, goal, wps, label) then
        return
    end
    if buy_goal(player, goal, wps, label) then
        return
    end

    -- BELOW LEVEL 2 (2.150.0): a ".vendor" step is still followed - Zygor
    -- ticks it off when the merchant window opens, and skipping it on our
    -- side left the guide on that step for good ("step complete", standing
    -- at the vendor). vendor.tick sells and buys nothing below level 2.

    -- 1.8.0: the client's own actions (quest/zygor_tbc on Tbc, quest/zygor_midnight
    -- on Midnight) - one action per tick, dispatched from here
    do
        local vm = guide.version_module()
        if vm and vm.handles(kind) then
            if vm.run(player, goal, kind, { guide = guide, state = state, movement = movement, wps = wps, label = label, walk_to = walk_to }) then
                return
            end
        end
    end
    if kind == "accept" or kind == "turnin" or kind == "talk" then
        if dialog_goal(player, goal, kind, wps, label) then
            g_in_dialog = true
            return
        end
    elseif kind == "fly" then
        if TR.fly_goal(player, goal, wps, label) then
            g_in_dialog = true
            return
        end
    elseif kind == "fpath" then
        if TR.fpath_goal(player, goal, wps, label) then
            g_in_dialog = true
            return
        end
    elseif kind == "hearth" then
        if IS.hearth_goal(player, goal, label) then
            return
        end
    elseif kind == "confirm" then
        if IS.confirm_goal(player, goal) then
            return
        end
    elseif kind == "wait" then
        if #wps > 0 then
            IS.walk_route(player, goal, kind, wps, label)
            if movement.is_moving() then IS.complete_wait = nil return end
        else
            movement.nav_stop()
        end
        local condition = tostring(goal.action) .. " " .. tostring(goal.target or "")
        if goal.action == "complete" and goal.quest_id then
            local objs = guide.objectives(goal.quest_id) or {}
            local missing = {}
            for i = 1, #objs do
                if not objs[i].finished then missing[#missing + 1] = tostring(objs[i].text or "unfinished objective") end
            end
            condition = "quest " .. tostring(goal.quest_id) .. ": " .. (#missing > 0 and table.concat(missing, "; ") or "awaiting Zygor confirmation")
            local key = guide.goal_key(goal) .. "|" .. condition
            if not IS.complete_wait or IS.complete_wait.key ~= key then IS.complete_wait = { key = key, t = izi.now() } end
            if izi.now() - IS.complete_wait.t >= 120 then
                guide.hold_goal(guide.step_num(), goal.index, "blocked: no completion progress for 120 s; " .. condition)
                return
            end
        end
        state.set_note("Quest", "Guide: waiting for " .. condition)
        return
    elseif kind == "manual" then
        -- 1.2.0: Zygor wants a learn / cast / pet action / unequip, and the
        -- spell / item it needs never reaches the API goal table
        movement.nav_stop()
        state.set_note("Quest", string.format("PAUSED: Zygor step %d wants '%s' %s - the API does not say which spell / item; do it yourself, then the bot carries on",
            guide.step_num(), tostring(goal.action), tostring(goal.target or "")))
        return
    elseif kind == "item" then
        if item_goal(player, goal, label) then
            return
        end
    elseif kind == "object" then
        if object_goal(player, goal, label) then
            return
        end
    elseif kind == "kill" then
        if kill_goal(player, goal, kind, wps, label) or TK.step_use(player, goal, label) then
            return
        end
    elseif kind == "collect" then
        -- Could be on the ground or a drop: look for the object first.
        if object_goal(player, goal, label) or kill_goal(player, goal, kind, wps, label)
            or TK.step_use(player, goal, label) then
            return
        end
    elseif kind == "xp" then
        if xp_goal(player, goal, wps, label) then
            return
        end
    end

    -- Nothing to act on here yet: walk the goal's route (2.241.0).
    IS.walk_route(player, goal, kind, wps, label)
end

-- ----------------------------------------------------------------------------
-- STATUS
-- ----------------------------------------------------------------------------

--- Was the last tick spent walking toward a waypoint? Read by the watchdog.
function quest.in_travel()
    return g_in_travel == true
end

--- Was the last tick spent on an accept / turn in / talk goal at an NPC?
--- Read by the NPC-stuck watchdog.
--- The kind of the goal being worked ("accept", "turnin", "talk", ...), or
--- nil. trainer.lua asks, so a class trainer's quest dialog is not
--- replaced by its training window (2.125.0).
function quest.current_kind()
    return g_cur_kind
end

function quest.in_npc_interaction()
    return g_in_dialog == true
end

--- Count the current guide goal as done - the watchdog's way out of an NPC
--- the bot has been stuck at.
function quest.skip_current_goal()
    local goal = guide.goal()
    if goal and goal.index then
        guide.mark_goal_done(guide.step_num(), goal.index)
    end
    g_talk_opened = 0
    g_key = nil
end

function quest.is_ready(player)
    return player ~= nil and guide.is_loaded()
end

-- tests/test_zygor_engine.lua: the step handlers and the goal key
--- 1.2.15: the path-threat check for walks the quest engine does not own (loot walk, vendor trip).
function quest.path_threat(player)
    return IS.path_threat(player) == true
end

quest._test = { IS = IS, stalled = stalled, set_key = function(k) g_key = k end,
    find_giver = find_giver,                                    -- 1.5.2
    item_goal = item_goal,                                      -- 1.7.20
    turnin_not_ready = function(...) return TK.turnin_not_ready(...) end,   -- 1.76.1
    walk_to = walk_to, dialog_goal = dialog_goal, recover_stall = recover_stall,
    npc_wait_s = function() return npc_wait_s() end,                          -- 1.76.2
    talked = function(u) local g = u and u:get_guid() if g then g_bad_givers[g] = true end end }

function quest.status_text()
    return guide.describe()
end

--- What the Questing tab shows.
-- audit 2026-10-17: built in the update callback (quest.refresh_snapshot from
-- main.lua, inside the read window); the Questing tab draws the stored copy
local last_snap = { loaded = false, ready = false, step = 0, stickies = 0 }
local last_snap_t = -1

function quest.refresh_snapshot()
    local now = izi.now()
    if last_snap_t >= 0 and now >= last_snap_t and (now - last_snap_t) < 0.25 then return end
    last_snap_t = now
    local ok, snap = pcall(guide.snapshot)
    if ok and type(snap) == "table" then last_snap = snap end
end

function quest.snapshot()
    last_snap.note = state.note or ""
    return last_snap
end

return quest
