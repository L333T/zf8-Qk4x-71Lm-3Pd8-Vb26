-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/mount.lua - mount for travel (the 1-60 product's way)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- ============================================================================
-- Port of the 1-60 Grinding product's nav.lua mount_step (itself the AWM
-- Run() mount block), Core API only. Used by movement/nav before every
-- out-of-combat walk of MIN_WALK yd or more (questing, grinding and the
-- gathering patrol - gather/mount.lua is a thin wrapper).
--
-- WHICH MOUNT (looked up again every 10 s), in order:
--   1. a class mount spell the player knows (data/mounts: Summon Charger /
--      Warhorse for paladins, Summon Dreadsteed / Felsteed for warlocks)
--   2. a mount item in the bags: data/mounts item ids, or any item whose
--      item info (core.quests.get_item_info) is class 15 subclass 5 "Mount",
--      swift mounts first, min_level <= the player's level
--   3. the game's mount list (core.spell_book.get_mount_count /
--      get_mount_info(i).is_usable -> core.input.mount(i))
--   A druid shifts into Travel Form instead (never also mounts).
--   1.2.59: a shaman who knows Ghost Wolf (spell 2645) casts it as the mount (from level 20, the spell's own level);
--   it is cancelled (core.input.cancel_buff) for a fight or an enemy target within ENEMY_YD, like a dismount.
-- WHEN: not mounted, level >= MIN_LEVEL (or Travel Form known), not a ghost,
--   not in combat, not swimming, outdoors, not casting, the GUI box on, not
--   suppressed (gather: near a node), not backed off.
-- HOW: the walk is stopped and the player stands HOLD s for the cast (the
--   caller gives the tick up while step() is true). VERIFY s without a mount
--   counts a failed try; 5 tries -> no mounting for 15 s; no mount anywhere ->
--   walk, look again in a minute.
-- BACK-OFFS from the game's error messages (events.lua UI_ERROR_MESSAGE,
--   as the 1-60 product's events.lua): "can't mount" / "mount here" / "only
--   use outside" / "in combat" 25 s, "swimming" / "underwater" 60 s, "not
--   ready yet" 15 s, "while moving" 1.5 s.
-- Dismounting stays where it was: combat.dismount (40 yd from a target),
-- resting, gather at a node.
-- 1.29.1 (user): ENEMY DISMOUNT - mounted (not on a flight) with an enemy
-- target within ENEMY_YD: the dismount is sent (once a second) and mounting is
-- held off while one is near. An enemy target = the bot's kill target, a mob
-- fighting the player or the pet, or the Zygor step's own targets (kill /
-- collect mobs, an xp step's XP-worthy enemies - quest/engine sets enemy_fn).
-- ============================================================================

local R = require("movement/core")

local M = {}

M.MIN_WALK = 100              -- yd: 1.2.63 (user) - a destination 100 yd or nearer is walked (was 30)
M.COMMIT_S = 15              -- 1.2.71: s the mount cast is carried on after the foot rule fired
M.FOOT_YD = 15                -- yd: 1.2.63 - the walk starts on foot; the mount is cast once the player has moved this far
M.MIN_LEVEL = 30
local HOLD = 5.0              -- s the player stands for a mount cast
local VERIFY = 3.0            -- s: no mount by then = a failed try
local CACHE_S = 10            -- s between two looks for a mount
-- 1.2.82: class ids from enums.class_id (WARLOCK 9, DRUID 11, SHAMAN 7), the numbers only as the fallback
local CLASS_WARLOCK, CLASS_DRUID, CLASS_SHAMAN = 9, 11, 7
do
    local okc, ce = pcall(require, "common/enums")
    local K = okc and type(ce) == "table" and ce.class_id or nil
    if type(K) == "table" then
        if type(K.WARLOCK) == "number" then CLASS_WARLOCK = K.WARLOCK end
        if type(K.DRUID) == "number" then CLASS_DRUID = K.DRUID end
        if type(K.SHAMAN) == "number" then CLASS_SHAMAN = K.SHAMAN end
    end
end
local BUFF_WAIT = 10.0       -- 1.2.62: s the walk waits for the ticked buffs to be cast before a mount
local GHOST_WOLF_ID = 2645       -- 1.2.59 (user): a shaman who knows Ghost Wolf uses it as the mount
local WOLF_VERIFY = 4.5          -- s: Ghost Wolf is a 3 s cast
M.ENEMY_YD = 40               -- 1.29.1: an enemy target this close -> off the mount
local ENEMY_SCAN_S = 0.25     -- s between two enemy looks
local ENEMY_HOLD = 3.0        -- s no mounting after an enemy was seen near
local DISMOUNT_GAP = 1.0      -- s between two dismount sends

local okd, DATA = pcall(require, "data/mounts")
if not okd or type(DATA) ~= "table" then DATA = { class_spells = {}, items = {}, rank = {} } end

local st = { usable_at = 0, suppress_until = 0, tried_at = 0, tries = 0, hold_until = 0, pending_at = nil,
    logged = false, auto = nil, auto_t = -1e9, last_shift = 0,
    enemy_t = -1e9, enemy_u = nil, enemy_why = nil, dismount_t = -1e9 }
M.stats = { mounts = 0, shifts = 0, backoffs = 0 }

--- Set by movement.lua: function() -> the GUI "Use Mount" state for this mode.
M.enabled_fn = nil
--- 1.29.1: set by quest/engine: function(player, yards) -> the step's enemy target within yards, or nil.
M.enemy_fn = nil

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function spellbook() return package.loaded["spellbook"] or safe(require, "spellbook") end
local function spellcheck() return package.loaded["spellcheck"] or safe(require, "spellcheck") end

local function family(name)
    local sb = spellbook()
    if type(sb) ~= "table" or type(sb.family) ~= "function" then return nil end
    return safe(sb.family, name)
end

local function cast_self(fam, player, label)
    local sc = spellcheck()
    if not fam or not fam.id or type(sc) ~= "table" or type(sc.cast_safe) ~= "function" then return false end
    return safe(sc.cast_safe, fam.id, player, label) == true
end

--- Is one of the family's spell ids (Travel Form ranks) an aura on the player? (get_buffs)
local function has_aura(player, fam)
    local ids = {}
    for _, id in ipairs(fam.ranks or {}) do ids[id] = true end
    if fam.id then ids[fam.id] = true end
    local list = safe(player.get_buffs, player)
    if type(list) ~= "table" then return false end
    for _, b in ipairs(list) do
        if type(b) == "table" and (ids[b.buff_id] or b.buff_name == fam.name) then return true end
    end
    return false
end

--- 1.2.59: Ghost Wolf (spell 2645) as the shaman's mount. The family when the spell is known, else nil.
local function ghost_wolf(player)
    if safe(player.get_class, player) ~= CLASS_SHAMAN then return nil end
    local fam = family("Ghost Wolf")
    if type(fam) ~= "table" then return nil end
    if fam.id == GHOST_WOLF_ID then return fam end
    for _, id in ipairs(fam.ranks or {}) do if id == GHOST_WOLF_ID then return fam end end
    return nil
end
M.ghost_wolf = ghost_wolf

--- The Ghost Wolf aura table on the player (the table get_buffs handed out - cancel_buff needs that very table), or nil.
local function wolf_aura(player)
    local list = safe(player.get_buffs, player)
    if type(list) ~= "table" then return nil end
    for _, b in ipairs(list) do
        if type(b) == "table" and (b.buff_id == GHOST_WOLF_ID or b.buff_name == "Ghost Wolf") then return b end
    end
    return nil
end

--- Hold mounting off for `seconds` (gather: a node is close).
function M.suppress(seconds)
    local t = R.now() + (seconds or 10)
    if t > st.suppress_until then st.suppress_until = t end
end

-- 2026-10-28 (user: "Always dismount when attempting to enter doorways"): the ray
-- helpers call this when the entrance ahead is too low for the mounted body. The
-- suppression is the point of the hold - without it M.step remounts us straight
-- back into the same doorway on the next pulse.
local door_t = 0
M.DOOR_HOLD = 8                  -- s of no mounting after a doorway dismount

--- Off the mount, and no mounting for `hold_s`. false when not mounted, or when
--- the last dismount was under a second ago.
function M.dismount(player, why, hold_s)
    if not player or safe(player.is_mounted, player) ~= true then return false end
    local t = R.now()
    if t - door_t < 1.0 then return false end
    door_t = t
    do local fr = package.loaded["flightrec"] if fr then fr.note("dismount") end end 
    safe(core.input.dismount)
    M.suppress(hold_s or M.DOOR_HOLD)
    R.trail("move", "mount: dismount - %s (no mounting for %.0f s)",
        tostring(why or "asked to"), hold_s or M.DOOR_HOLD)
    return true
end

--- No mounting for `seconds` (a game error message said why).
function M.backoff(seconds, why)
    local t = R.now() + (seconds or 15)
    if t > st.usable_at then st.usable_at = t end
    st.hold_until, st.pending_at = 0, nil
    M.stats.backoffs = M.stats.backoffs + 1
    if why then R.trail("move", "mount: %s - no mounting for %.0f s", tostring(why), seconds or 15) end
end

function M.reset()
    st.usable_at, st.suppress_until, st.tried_at, st.tries, st.hold_until, st.pending_at = 0, 0, 0, 0, 0, nil
    st.logged, st.auto, st.auto_t, st.last_shift = false, nil, -1e9, 0
    st.wolf_on, st.wolf_pending = false, false
    st.arm, st.foot_t, st.commit = nil, -1e9, nil
    st.enemy_t, st.enemy_u, st.enemy_why, st.dismount_t = -1e9, nil, nil, -1e9
end

--- The game's error text -> a back-off (events.lua UI_ERROR_MESSAGE).
function M.on_error(text)
    if type(text) ~= "string" or text == "" then return end
    local s = text:lower()
    local function has(x) return s:find(x, 1, true) ~= nil end
    if has("can't mount") or has("cannot mount") or has("mount here") or (has("too far away") and has("mount")) then
        M.backoff(25, text)
    elseif has("only use outside") or has("only be used outside") or has("can only use outside") then
        M.backoff(25, text)
    elseif has("you are in combat") then
        M.backoff(25, text)
    elseif has("while swimming") or has("underwater") or has("above water") then
        M.backoff(60, text)
    elseif has("not ready yet") then
        M.backoff(15, text)
    elseif has("while moving") and st.pending_at then
        M.backoff(1.5, text)
    end
end

-- ----------------------------------------------------------------------------
-- 1.29.1: enemy targets near -> no mount
-- ----------------------------------------------------------------------------
local function alive_within(player, u, yards)
    if u == nil or safe(u.is_valid, u) ~= true or safe(u.is_dead_or_ghost, u) == true then return false end
    local d = safe(player.distance_to, player, u)
    return type(d) == "number" and d <= yards
end

--- The nearest enemy target within ENEMY_YD: unit, why - or nil. Looked up
--- every ENEMY_SCAN_S at most (the step's targets read every object).
function M.enemy_near(player, t)
    t = t or R.now()
    if t - st.enemy_t < ENEMY_SCAN_S then return st.enemy_u, st.enemy_why end
    st.enemy_t, st.enemy_u, st.enemy_why = t, nil, nil
    if not player then return nil end
    local yards = M.ENEMY_YD
    local state = package.loaded["state"]
    local tg = type(state) == "table" and type(state.target) == "table" and state.target or nil
    if tg and tg.kind == "kill" and alive_within(player, tg.unit, yards) then
        st.enemy_u, st.enemy_why = tg.unit, "kill target"
        return st.enemy_u, st.enemy_why
    end
    local targeting = package.loaded["targeting"]
    if type(targeting) == "table" and type(targeting.threats) == "function" then
        local list = safe(targeting.threats, player, yards)
        if type(list) == "table" and list[1] ~= nil then
            st.enemy_u, st.enemy_why = list[1], "attacking"
            return st.enemy_u, st.enemy_why
        end
    end
    if type(M.enemy_fn) == "function" then
        local u = safe(M.enemy_fn, player, yards)
        if u ~= nil and alive_within(player, u, yards) then
            st.enemy_u, st.enemy_why = u, "step target"
        end
    end
    return st.enemy_u, st.enemy_why
end

--- 1.2.61 (user: "check for enemy targets nearby before mounting"): any HOSTILE living mob within HOSTILE_YD of the player,
--- seen or not by the step - a mount cast takes a stand-still and 3 s, and a pack ahead turns it into a pull while mounted.
--- Used before a mount / Ghost Wolf / Travel Form cast only (riding past a mob does not dismount; dismount_tick keeps ENEMY_YD).
M.HOSTILE_YD = 30
local hostile = { t = -1e9, u = nil }
function M.hostile_near(player, t)
    t = t or R.now()
    if t - hostile.t < ENEMY_SCAN_S then return hostile.u end
    hostile.t, hostile.u = t, nil
    local tg = package.loaded["targeting"]
    if not player or type(tg) ~= "table" or type(tg.scan_enemies) ~= "function" then return nil end
    local attack, avoid = safe(tg.scan_enemies, player)
    local best, best_d = nil, M.HOSTILE_YD + 1
    for _, list in ipairs({ attack or {}, avoid or {} }) do
        for i = 1, #list do
            local u = list[i]
            if type(u) == "table" and safe(u.is_valid, u) == true and safe(u.is_dead_or_ghost, u) ~= true
                and safe(u.is_dummy, u) ~= true and safe(u.is_enemy_with, u, player) == true then
                local d = safe(player.distance_to, player, u)
                if type(d) == "number" and d <= M.HOSTILE_YD and d < best_d then best, best_d = u, d end
            end
        end
    end
    hostile.u = best
    return best
end

local function in_flight(player)
    if safe(player.is_flying, player) == true then return true end
    local tr = package.loaded["quest/travel"]
    return type(tr) == "table" and type(tr.in_flight) == "function" and safe(tr.in_flight, player) == true
end

--- Every pulse (movement.pulse): mounted with an enemy target within ENEMY_YD
--- -> dismount. True while it acts.
function M.dismount_tick(player, t)
    if not player then return false end
    if safe(player.is_mounted, player) ~= true then
        -- 1.2.59: Ghost Wolf is not a mount to the game; leave the form for a fight like a mount
        if st.wolf_on and ghost_wolf(player) then
            local fight = safe(player.is_in_combat, player) == true
            local u, why
            if not fight then u, why = M.enemy_near(player, t or R.now()) end
            if fight or u ~= nil then
                M.suppress(ENEMY_HOLD)
                local now = t or R.now()
                if now - st.dismount_t >= DISMOUNT_GAP then
                    st.dismount_t = now
                    local aura = wolf_aura(player)
                    if aura then
                        safe(core.input.cancel_buff, aura)
                        R.trail("move", "mount: Ghost Wolf cancelled - %s",
                            fight and "in combat" or (tostring(why) .. " " .. tostring(safe(u.get_name, u) or "?") .. " within " .. M.ENEMY_YD .. " yd"))
                    else
                        st.wolf_on = false
                    end
                end
                return true
            end
        end
        return false
    end
    t = t or R.now()
    if in_flight(player) then return false end
    local u, why = M.enemy_near(player, t)
    if u == nil then return false end
    M.suppress(ENEMY_HOLD)
    if t - st.dismount_t >= DISMOUNT_GAP then
        st.dismount_t = t
        do local fr = package.loaded["flightrec"] if fr then fr.note("dismount") end end 
        safe(core.input.dismount)
        R.trail("move", "mount: dismount - %s %s within %d yd", tostring(why),
            tostring(safe(u.get_name, u) or "?"), M.ENEMY_YD)
    end
    return true
end

-- ----------------------------------------------------------------------------
-- which mount
-- ----------------------------------------------------------------------------
local function bag_mount(level)
    local okb, bags = pcall(require, "bags")
    if not okb or type(bags) ~= "table" or type(bags.list) ~= "function" then return nil end
    local list = safe(bags.list) or {}
    local best, best_rank = nil, math.huge
    for _, it in ipairs(list) do
        local id = it.item_id
        if type(id) == "number" and id > 0 then
            local info = safe(core.quests.get_item_info, id)
            local listed = DATA.rank[id] ~= nil
            local is_mount = listed or (type(info) == "table" and info.class_id == 15 and info.subclass_id == 5)
            local min_level = type(info) == "table" and tonumber(info.min_level) or 0
            if is_mount and min_level <= level then
                local r = DATA.rank[id] or (#DATA.items + 1)
                if r < best_rank then
                    best, best_rank = { id = id, name = type(info) == "table" and info.name or nil }, r
                end
            end
        end
    end
    return best
end

local function journal_mount()
    local n = safe(core.spell_book.get_mount_count)
    if type(n) ~= "number" or n <= 0 then return nil end
    for i = 1, n do
        local info = safe(core.spell_book.get_mount_info, i)
        if type(info) == "table" and info.is_usable == true then return i, info.mount_name end
    end
    return nil
end

--- The mount to use: { kind = "spell"|"item"|"journal", value, label } or nil.
function M.find(player, t)
    t = t or R.now()
    if t - st.auto_t < CACHE_S then return st.auto end
    st.auto_t, st.auto = t, nil
    local class_id = safe(player.get_class, player)
    local level = safe(player.get_level, player) or 0
    local it = bag_mount(level)
    for _, name in ipairs(DATA.class_spells[class_id] or {}) do
        local fam = family(name)
        if fam and fam.id then
            -- 2026-10-25 (Desktop\Helper mounts.lua): a slow class mount (Warhorse,
            -- Felsteed) gives way to a swift mount item in the bags
            local swift_item = it and DATA.SWIFT_LAST and DATA.rank and DATA.rank[it.id]
                and DATA.rank[it.id] <= DATA.SWIFT_LAST
            if not (DATA.slow_class and DATA.slow_class[name] and swift_item) then
                st.auto = { kind = "spell", value = fam, label = name }
                return st.auto
            end
        end
    end
    if it then
        st.auto = { kind = "item", value = it.id, label = it.name or ("item " .. it.id) }
        return st.auto
    end
    local idx, name = journal_mount()
    if idx then st.auto = { kind = "journal", value = idx, label = name or ("mount " .. idx) } end
    return st.auto
end

-- ----------------------------------------------------------------------------
-- the step before a walk
-- ----------------------------------------------------------------------------
local function enabled(explicit)
    if explicit ~= nil then return explicit == true end
    if type(M.enabled_fn) ~= "function" then return true end
    local ok, v = pcall(M.enabled_fn)
    return not ok or v ~= false
end

--- Mount (or shift) before travel. True while it holds the walk: the caller
--- gives the tick up (the player stands for the cast). `on` overrides the GUI
--- switch (gather passes its own box).
function M.step(player, on)
    if not player then return false end
    local t = R.now()
    if safe(player.is_mounted, player) == true then
        st.tries, st.pending_at, st.hold_until, st.buff_t0 = 0, nil, 0, nil
        return false
    end
    local wolf = ghost_wolf(player)
    if wolf and wolf_aura(player) then            -- 1.2.59: already running as a wolf
        st.tries, st.pending_at, st.hold_until, st.wolf_on = 0, nil, 0, true
        return false
    end
    -- 1.2.72 (user): Ghost Wolf is the shaman's mount UNLESS a better mount exists - a class mount, a mount item in the bags or a
    -- usable mount from the game's list, at the level mounts are used from (MIN_LEVEL). A better mount wins; below that level,
    -- or with none, the wolf stays.
    if wolf and not wolf_aura(player) and (safe(player.get_level, player) or 0) >= M.MIN_LEVEL and M.find(player, t) then
        wolf = nil
    end
    if st.pending_at then
        if t - st.pending_at < (st.wolf_pending and WOLF_VERIFY or VERIFY) then return true end
        st.pending_at = nil
        st.tries = st.tries + 1
        if st.tries > 5 then
            st.tries = 0
            M.backoff(15, "5 mount tries failed")
            return false
        end
    end
    if t < st.hold_until then return true end
    if not enabled(on) or t < st.usable_at or t < st.suppress_until then return false end

    local level = safe(player.get_level, player) or 0
    local class_id = safe(player.get_class, player)
    local travel = (class_id == CLASS_DRUID) and family("Travel Form") or nil
    if class_id == CLASS_WARLOCK and level <= 40 and not M.find(player, t) then
        st.usable_at = t + 120
        return false
    end
    if not travel and not wolf and level < M.MIN_LEVEL then return false end
    if safe(player.is_ghost, player) == true then return false end
    if safe(player.is_in_combat, player) == true then return false end
    if M.enemy_near(player, t) ~= nil then                -- 1.29.1: walk to / past enemy targets
        M.suppress(ENEMY_HOLD)
        return false
    end
    local hu = M.hostile_near(player, t)                 -- 1.2.61: any hostile mob close by
    if hu ~= nil then
        M.suppress(ENEMY_HOLD)
        if not st.hostile_said or t - st.hostile_said > 30 then
            st.hostile_said = t
            R.trail("move", "mount: not mounting - hostile %s within %d yd", tostring(safe(hu.get_name, hu) or "?"), M.HOSTILE_YD)
        end
        return false
    end
    if safe(core.character.is_swimming) == true then return false end
    -- 1.2.62: every ticked buff is cast before the mount (smart.upkeep casts them; this only waits, BUFF_WAIT s at most)
    do
        local sm = package.loaded["smart"]
        local nm = type(sm) == "table" and type(sm.buffs_pending) == "function" and safe(sm.buffs_pending, player) or nil
        if nm then
            st.buff_t0 = st.buff_t0 or t
            if t - st.buff_t0 < BUFF_WAIT then
                if not st.buff_said or t - st.buff_said > 30 then
                    st.buff_said = t
                    R.trail("move", "mount: waiting for the buff %s before mounting", tostring(nm))
                end
                return true
            end
        else
            st.buff_t0 = nil
        end
    end
    if safe(player.is_outdoors, player) == false then
        st.usable_at = t + 20                 -- the 1-60 rule: indoors, look again in 20 s
        return false
    end
    if safe(player.is_casting_spell, player) == true or safe(player.is_channelling_spell, player) == true then return true end

    -- Druid: Travel Form, never a mount.
    if travel then
        local fam = travel
        if has_aura(player, fam) or (t - st.last_shift) < 1 then return false end
        local nav = package.loaded["movement/nav"]
        if nav and type(nav.stop) == "function" then pcall(nav.stop, "travel form") end
        if cast_self(fam, player, "MF travel form") then
            st.last_shift = t
            M.stats.shifts = M.stats.shifts + 1
            R.trail("move", "mount: Travel Form")
        end
        return false
    end

    if wolf then
        local nav = package.loaded["movement/nav"]
        if nav and type(nav.stop) == "function" then pcall(nav.stop, "ghost wolf") end
        if safe(player.is_moving, player) == true then
            st.hold_until = t + 0.5
            return true
        end
        local sent = cast_self(wolf, player, "MF ghost wolf")
        st.pending_at, st.hold_until, st.tried_at, st.wolf_pending = t, t + WOLF_VERIFY, t, true
        st.wolf_on = true
        M.stats.mounts = M.stats.mounts + 1
        R.trail("move", "mount: Ghost Wolf (spell %d)%s", GHOST_WOLF_ID, sent and "" or " - not sent")
        return true
    end

    local m = M.find(player, t)
    if not m then
        if not st.logged then
            st.logged = true
            R.log("Mount: no mount found (class spell, bags or mount list) - walking")
        end
        st.usable_at = t + 60
        return false
    end
    st.logged = false
    -- a mount cast fails on the move: stop first, cast standing
    local nav = package.loaded["movement/nav"]
    if nav and type(nav.stop) == "function" then pcall(nav.stop, "mounting") end
    if safe(player.is_moving, player) == true then
        st.hold_until = t + 0.5
        return true
    end
    local sent
    if m.kind == "spell" then
        sent = cast_self(m.value, player, "MF mount")
    elseif m.kind == "item" then
        local sc = spellcheck()
        sent = type(sc) == "table" and type(sc.use_item) == "function" and safe(sc.use_item, m.value) == true
    else
        do local fr = package.loaded["flightrec"] if fr then fr.note("mount") end end 
        sent = safe(core.input.mount, m.value) ~= false
    end
    st.pending_at, st.hold_until, st.tried_at, st.wolf_pending = t, t + HOLD, t, false
    M.stats.mounts = M.stats.mounts + 1
    R.trail("move", "mount: %s (%s)%s", tostring(m.label), m.kind, sent and "" or " - not sent")
    return true
end

--- 1.2.63: mounted, or in the form that is this class's mount (Ghost Wolf, Travel Form).
function M.riding(player)
    if not player then return false end
    if safe(player.is_mounted, player) == true then return true end
    local cls = safe(player.get_class, player)
    if cls == CLASS_SHAMAN then return ghost_wolf(player) ~= nil and wolf_aura(player) ~= nil end
    if cls == CLASS_DRUID then
        local fam = family("Travel Form")
        return fam ~= nil and has_aura(player, fam)
    end
    return false
end

--- 1.2.63 (user: "start moving the player towards the destination before using the mount; once the player has moved 15 yards
--- without combat, use the mount"). Called by movement/nav in place of step() before a walk of M.MIN_WALK+ yd: arms the foot
--- trigger and lets the walk start on foot. A mount cast already going (hold / verify) is carried on with step(). True = hold the walk.
function M.begin(player, gx, gy)
    if not player then return false end
    if M.riding(player) then st.arm, st.commit = nil, nil return false end
    local t = R.now()
    if st.pending_at or t < st.hold_until then return M.step(player) end
    -- 1.2.71 (log 15:47-15:51: stop / start every 3-4 s): the foot rule stopped the walk to cast and held 0.5 s, and the guide's next
    -- ask ARMED a fresh walk instead of finishing the cast - the walk restarted, 15 yd later the foot rule stopped it again, for ever.
    -- Once the foot rule has decided, the cast is carried on (COMMIT_S s) until it is made or step() says no.
    if st.commit and t - st.commit < M.COMMIT_S then
        if M.step(player) then return true end
        st.commit = nil
    end
    local hx, hy = R.here()
    if hx then
        local a = st.arm
        if not (a and math.abs(a.gx - gx) < 3 and math.abs(a.gy - gy) < 3 and (t - a.t) < 60) then
            st.arm = { x = hx, y = hy, gx = gx, gy = gy, t = t }
        end
    end
    return false
end

--- Every pulse: the armed walk, once 15 yd on foot without combat -> the mount step. True while it holds the walk.
function M.foot_tick(player, t)
    local a = st.arm
    if not a or not player then return false end
    t = t or R.now()
    if t - a.t > 180 then st.arm = nil return false end
    if t - (st.foot_t or -1e9) < 0.5 then return false end
    st.foot_t = t
    if M.riding(player) or safe(player.is_in_combat, player) == true then st.arm = nil return false end
    local hx, hy = R.here()
    if not hx or R.dist2(hx, hy, a.x, a.y) < M.FOOT_YD then return false end
    if R.dist2(hx, hy, a.gx, a.gy) <= M.MIN_WALK then st.arm = nil return false end     -- nearer than the minimum now
    -- 1.2.71: only for the walk that armed it - another walk (a patrol ring, a route) is never stopped for a mount
    local nav = package.loaded["movement/nav"]
    -- 1.2.79b (log 17:16:46: a staged leg stopped 0.2 s after it started): never over a detour / staged leg
    if nav and type(nav.detour_active) == "function" and nav.detour_active() then return false end
    if nav and type(nav.destination) == "function" then
        local dx, dy = nav.destination()
        if not dx or R.dist2(dx, dy, a.gx, a.gy) > 3 then st.arm = nil return false end
    end
    local held = M.step(player)
    if held then st.arm, st.commit = nil, t end
    return held
end

--- Should a walk of `yards` mount first? (no state change)
function M.wants(yards) return type(yards) == "number" and yards >= M.MIN_WALK end
--- 1.9.0: a mount cast is being made (the player stands for it).
function M.casting() return st.pending_at ~= nil and (R.now() - st.pending_at) < (st.wolf_pending and WOLF_VERIFY or VERIFY) end

return M
