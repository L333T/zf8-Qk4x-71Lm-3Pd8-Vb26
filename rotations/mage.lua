-- ============================================================================
-- Master Farmer - Zygor Forever
-- Mage grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- Spell rank-1 IDs are registered with spellbook.define. The scanner saves the
-- highest known rank and Class-tab toggles feed izi.advanced_sequence.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

-- 2.312.0: common/modules/spell_queue no longer loaded (unused; core API casts)

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type spell_prediction
local spell_prediction = require("common/modules/spell_prediction")

local consumables = require("data/consumables")
local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")
local pets = require("pets")
local targeting = require("targeting")

local mage = {}

-- Highest rank first. Rest eats and drinks these before any other food.
function mage.preferred_food_ids()
    return consumables.CONJURED_FOOD_ITEM_IDS
end

function mage.preferred_drink_ids()
    return consumables.CONJURED_WATER_ITEM_IDS
end

local function make(ids, track_buff, track_debuff)
    local spell = izi.spell(ids)
    if not spell then
        return nil
    end
    if track_buff and spell.track_buff then
        spell:track_buff(ids)
    end
    if track_debuff and spell.track_debuff then
        spell:track_debuff(ids)
    end
    return spellbook.watch(spell, ids, track_buff, track_debuff)
end

local frostbolt = make({ 27072, 27071, 25304, 10181, 10180, 10179, 8408, 8407, 8406, 7322, 837, 205, 116 })
local fireball = make({ 27070, 25306, 10151, 10150, 10149, 10148, 8402, 8401, 8400, 3140, 145, 143, 133 })
local arcane_missiles = make({ 38704, 38699, 27075, 25345, 10212, 10211, 8417, 8416, 5145, 5144, 5143 })
local fire_blast = make({ 27079, 27078, 10199, 10197, 8413, 8412, 2138, 2137, 2136 })
local scorch = make({ 27074, 27073, 10207, 10206, 10205, 8446, 8445, 8444, 2948 })
local pyroblast = make({ 33938, 27132, 18809, 12526, 12525, 12524, 12523, 12522, 12505, 11366 })
local flamestrike = make({ 27086, 10216, 10215, 8423, 8422, 2121, 2120 })
local blizzard = make({ 27085, 10187, 10186, 10185, 8427, 6141, 10 })
local cone_of_cold = make({ 27087, 10161, 10160, 10159, 8492, 120 })
local frost_nova = make({ 27088, 10230, 6131, 865, 122 }, false, true)
local ice_lance = make({ 30455 })
local blast_wave = make({ 11113 })
local dragons_breath = make({ 33043, 33041, 31661 })
-- Ice Barrier, rank 6 down to rank 1. 33405 is the TBC rank.
--
-- The id list was already here and nothing used it - it was left behind when
-- the Class tab checkbox was removed. It is a maintained self buff now, kept
-- up alongside the armour and Arcane Intellect rather than being a rotation
-- toggle.
local ICE_BARRIER_IDS = { 33405, 27134, 13033, 13032, 13031, 11426 }
local ice_barrier = make(ICE_BARRIER_IDS, true, false)
local mana_shield = make({ 27131, 10193, 10192, 10191, 8495, 8494, 1463 }, true, false)
local ice_armor = make({ 27124, 10220, 10219, 7320, 7302 }, true, false)
local frost_armor = make({ 7301, 7300, 168 }, true, false)
local mage_armor = make({ 27125, 22783, 22782, 6117 }, true, false)
local molten_armor = make({ 30482 }, true, false)
local arcane_intellect = make({ 27126, 10157, 10156, 1461, 1460, 1459 }, true, false)
local icy_veins = make({ 12472 }, true, false)
local evocation = make({ 12051 }, true, false)
local counterspell = make({ 2139 })
local presence_of_mind = make({ 12043 }, true, false)
local combustion = make({ 11129 }, true, false)
local arcane_power = make({ 12042 }, true, false)
local water_elemental = make({ 31687 })
local freeze = make({ 33395 })
local cold_snap = make({ 11958 })
local conjure_water = make(consumables.CONJURE_WATER_SPELL_IDS)
local conjure_food = make(consumables.CONJURE_FOOD_SPELL_IDS)

spellbook.define({
    frostbolt = 116,
    ice_barrier = 11426,
    fireball = 133,
    arcane_missiles = 5143,
    fire_blast = 2136,
    scorch = 2948,
    pyroblast = 11366,
    flamestrike = 2120,
    blizzard = 10,
    cone_of_cold = 120,
    frost_nova = 122,
    ice_lance = 30455,
    blast_wave = 11113,
    dragons_breath = 31661,
    mana_shield = 1463,
    ice_armor = 7302,
    frost_armor = 168,
    mage_armor = 6117,
    molten_armor = 30482,
    arcane_intellect = 1459,
    icy_veins = 12472,
    evocation = 12051,
    counterspell = 2139,
    presence_of_mind = 12043,
    combustion = 11129,
    arcane_power = 12042,
    water_elemental = 31687,
    freeze = 33395,
    cold_snap = 11958,
    conjure_water = 5504,
    conjure_food = 587,
})

local function live(key, fallback)
    local sp = spellbook.spell(key)
    if sp then
        return sp
    end
    return fallback
end

function mage.class_id()
    return enums.class_id.MAGE
end

function mage.label()
    return "Mage"
end

function mage.combat_range(player)
    local bolt = live("frostbolt", frostbolt)
    if bolt and type(bolt.maximum_range) == "number" and bolt.maximum_range > 0 then
        return bolt.maximum_range
    end
    local ball = live("fireball", fireball)
    if ball and type(ball.maximum_range) == "number" and ball.maximum_range > 0 then
        return ball.maximum_range
    end
    return 30
end

-- ============================================================================
-- COMBAT MOVEMENT PROFILE
-- ============================================================================
-- Frost Nova ranks + Frostbite. A target carrying one of these is held in
-- place, which is the moment a mage wants to be walking out of melee.
local FROZEN_IDS = { 27088, 10230, 6131, 865, 122, 33395 }
-- Cone of Cold ranks: a successful cast means the pack is snared right now.
local COLD_IDS   = { 27087, 10161, 10160, 10159, 8492, 120 }

local function id_in(list, id)
    if not id then return false end
    for i = 1, #list do
        if list[i] == id then return true end
    end
    return false
end

local function target_frozen(target)
    if not target then return false end
    local ranks = spellbook.ranks("frost_nova")
    if type(ranks) == "table" and #ranks > 0 then
        if auras.debuff_up(target, ranks) then
            return true
        end
    end
    return auras.debuff_up(target, FROZEN_IDS)
end

--- Rules the combat movement controller applies for this class (§17).
--- It decides WHEN to reposition (range bands, prediction, hysteresis); this
--- only answers WHETHER backing out of melee is the right play right now.
--- How far out to look for something to fight.
---
--- A caster opens from where it is already standing, so a wide
--- scan costs nothing and gives the rotation time to start a cast.
function mage.scan_range(player)
    return 35
end

function mage.combat_profile()
    return {
        name         = "mage",
        melee_danger = 8,       -- inside this, a caster is in trouble
        melee_safe   = 12,      -- walk out to here, then stop (hysteresis)
        should_retreat = function(ctx)
            local target = ctx.target
            if not target then return false end
            -- nothing is actually on us: stand and cast
            if ctx.melee_count < 1 and ctx.distance > 8 then return false end
            -- the target is held: this is the window to walk out
            if target_frozen(target) then return true end
            -- 1.16.0 (improvement 10): a slowed / held enemy still walking at
            -- us inside 8 yd - back off now, not once it is in melee
            if ctx.approaching and ctx.slowed and not ctx.casting and (ctx.distance or 99) <= 8 then return true end
            -- Cone of Cold just landed: the pack is snared, same window
            if ctx.last_spell_age and ctx.last_spell_age <= 2.0 then
                if id_in(COLD_IDS, ctx.last_spell_id) then return true end
                if id_in(FROZEN_IDS, ctx.last_spell_id) then return true end
            end
            return false
        end,
    }
end

-- ----------------------------------------------------------------------------
-- 1.7.9 POLYMORPH (user: "if the player is a Mage in combat with 2 or more
-- enemy targets at or above the player's level, always Polymorph (12825) one
-- of them while the other is being killed")
-- ----------------------------------------------------------------------------
-- In the fight's pack (targeting.combat_scan: units in combat targeting the
-- player), 2+ alive at or above the player's level and no sheep yet: one that
-- is NOT the target being killed, a Beast / Humanoid / Critter (the only
-- types Polymorph takes), at or above the player's level first, gets 12825
-- through the core API (spellcheck.core_cast: core.spell_book checks,
-- core.input.cast_target_spell). One try per unit every POLY_RETRY s; the
-- game refuses what it will not cast. targeting leaves the sheep out of the
-- attacker / pack lists while anything else fights (no hits that break it).
-- audit R1: the highest Polymorph rank the character owns (not one fixed id),
-- found the way rank_id finds Blizzard's below
local POLY_IDS = { 12826, 12825, 12824, 118 }
local function poly_rank(spellcheck)
    if type(spellcheck.core_castable) ~= "function" then return nil end
    for i = 1, #POLY_IDS do
        local ok, why = spellcheck.core_castable(POLY_IDS[i], nil, { skip_casting = true, skip_gcd = true })
        if ok or why ~= "not learned" then return POLY_IDS[i] end
    end
    return nil
end
local POLY_RETRY = 4.0
local POLY_TYPES = nil
local poly_try = {}
local function polymorphable(u)
    if POLY_TYPES == nil then
        local ct = type(enums.creature_type) == "table" and enums.creature_type or {}
        POLY_TYPES = { [ct.BEAST or 1] = true, [ct.HUMANOID or 7] = true, [ct.CRITTER or 8] = true }
    end
    local ok, t = pcall(function() return u:get_creature_type() end)
    return ok and POLY_TYPES[t] == true
end
local function guid(u)
    local ok, g = pcall(function() return u:get_guid() end)
    return ok and g or nil
end
local function alive(u)
    local ok, v = pcall(function() return u:is_valid() == true and u:is_dead_or_ghost() ~= true end)
    return ok and v == true
end
local function level(u)
    local ok, v = pcall(function() return u:get_level() end)
    return ok and tonumber(v) or 0
end

-- 1.7.15 BLINK AWAY (option "Blink Away", Class tab): an enemy fighting the
-- player (the target or one of the pack) within BLINK_YD, Blink learned and
-- off cooldown (spellcheck.core_castable), not already running or resting:
-- movement.blink_away runs the turn / run / Blink / stop / face sequence. One
-- start every BLINK_GAP s at most.
local BLINK_YD, BLINK_GAP = 5, 3.0
local blink_t = -1e9
function mage.escape(player, target, pack)
    if not (type(gui.is_on) == "function" and gui.is_on("blink_away")) then return false end
    -- 1.26.0 (user): no Blink Away in the water - attack, kill and loot
    local ok_sw, sw = pcall(function() return core.character.is_swimming() end)
    if ok_sw and sw == true then return false end
    local ok_m, movement = pcall(require, "movement")
    if not ok_m or type(movement) ~= "table" or type(movement.blink_away) ~= "function" then return false end
    if movement.blinking and movement.blinking() then return true end      -- the sequence owns the tick
    if (type(movement.backpedaling) == "function" and movement.backpedaling()) then return false end
    local now = izi.now()
    if now - blink_t < BLINK_GAP then return false end
    local near, near_d = nil, nil
    local function consider(u)
        if not alive(u) then return end
        local ok, d = pcall(function() return player:distance_to(u) end)
        if ok and type(d) == "number" and d <= BLINK_YD and (near_d == nil or d < near_d) then near, near_d = u, d end
    end
    if target then consider(target) end
    for i = 1, #(pack or {}) do consider(pack[i]) end
    if not near then return false end
    local ok_s, spellcheck = pcall(require, "spellcheck")
    if not ok_s or type(spellcheck) ~= "table" or type(spellcheck.core_castable) ~= "function" then return false end
    if spellcheck.core_castable(1953, nil) ~= true then return false end
    blink_t = now
    return movement.blink_away(near) == true
end

-- 1.7.28 WATER ELEMENTAL (user): while the Summon Water Elemental (31687) pet
-- is out and alive, in combat with a target:
--   * sent at the mage's target (pets.attack: assist + core.input.pet_attack,
--     re-sent when the target changes);
--   * Waterbolt (31707) kept going: autocast switched on once per summon
--     (core.spell_book.get_pet_action_info(31707).auto_cast_enabled, else
--     core.input.enable_pet_autocast), and cast by hand
--     (core.input.pet_cast_target_spell) whenever the elemental stands idle;
--   * Freeze (33395, 8 yd, ground) when off cooldown
--     (core.input.pet_cast_position_spell): on the enemy nearest the mage
--     within FREEZE_NEAR yd (the melee threat), else the target - never where
--     it would hit a sheep. Own FREEZE_CD timer (a pet spell's cooldown is
--     not in core.spell_book); the game refuses a cast that is not ready.
-- Pet commands are not the mage's GCD: the hook never takes the tick.
local WE = { BOLT = 31707, FREEZE = 33395, FREEZE_CD = 25, FREEZE_NEAR = 10, FREEZE_R = 8,
    BOLT_GAP = 1.0, AUTO_GAP = 5.0 }
local we_st = { pet = nil, auto_t = -1e9, bolt_t = -1e9, freeze_t = -1e9 }
local function pet_busy(pet)
    local ok, v = pcall(function()
        return pet:is_casting_spell() == true or pet:is_channelling_spell() == true
    end)
    return ok and v == true
end
local function trail_we(fmt, ...)
    local ok_e, elog = pcall(require, "errorlog")
    if ok_e and type(elog) == "table" and type(elog.trail) == "function" then elog.trail("act", fmt, ...) end
end
function mage.pet(player, target, pack)
    local pet = pets.get(player)
    if not pet or not pets.alive(player) then we_st.pet = nil return false end
    local pg = guid(pet)
    if pg ~= we_st.pet then                                   -- a new summon
        we_st.pet, we_st.auto_t, we_st.bolt_t = pg, -1e9, -1e9
    end
    if not target or not alive(target) then return false end
    local ok_c, in_fight = pcall(function() return player:is_in_combat() == true end)
    if not (ok_c and in_fight) then return false end
    local now = izi.now()
    pets.attack(player, target)
    -- Waterbolt autocast on
    if now - we_st.auto_t >= WE.AUTO_GAP then
        we_st.auto_t = now
        local ok_i, info = pcall(core.spell_book.get_pet_action_info, WE.BOLT)
        if not (ok_i and type(info) == "table" and info.auto_cast_enabled == true) then
            pcall(core.input.enable_pet_autocast, WE.BOLT)
        end
    end
    -- Waterbolt by hand when the elemental stands idle
    if not pet_busy(pet) and now - we_st.bolt_t >= WE.BOLT_GAP then
        we_st.bolt_t = now
        pcall(core.input.pet_cast_target_spell, WE.BOLT, target)
    end
    -- Freeze off cooldown
    if now - we_st.freeze_t >= WE.FREEZE_CD then
        local me = player:get_position()
        local spot, spot_d = nil, nil
        for i = 1, #(pack or {}) do
            local u = pack[i]
            if alive(u) and not (targeting.is_polymorphed and targeting.is_polymorphed(u)) then
                local ok_d, d = pcall(function() return player:distance_to(u) end)
                if ok_d and type(d) == "number" and d <= WE.FREEZE_NEAR and (spot_d == nil or d < spot_d) then
                    spot, spot_d = u, d
                end
            end
        end
        local unit = spot or target
        local pos = unit:get_position()
        local sheep_near = false
        for i = 1, #(pack or {}) do
            local u = pack[i]
            if targeting.is_polymorphed and targeting.is_polymorphed(u) then
                local sp = u:get_position()
                if sp and pos and math.sqrt((sp.x - pos.x) ^ 2 + (sp.y - pos.y) ^ 2) <= WE.FREEZE_R + 2 then sheep_near = true end
            end
        end
        if pos and not sheep_near then
            we_st.freeze_t = now
            pcall(core.input.pet_cast_position_spell, WE.FREEZE, pos)
            trail_we("Water Elemental: Freeze on %s%s", tostring(select(2, pcall(function() return unit:get_name() end))),
                spot and string.format(" (%.0f yd from the mage)", spot_d) or "")
        end
    end
    return false
end

-- 1.7.25 BLIZZARD (user, with the example): Blizzard ticked (Spells tab, or
-- the Class-tab option) and as many live enemies fighting as the "Area of
-- effect at enemies" slider asks for (1.46.0; 3 when it cannot be read): the highest learned
-- rank, checked by spell_helper:is_spell_castable(id, player, target, false,
-- false), is aimed by spell_prediction (CIRCLE, MOST_HITS, range 30, radius 8,
-- no cast time - channeled, the area is down at once - from the player) at the target and cast at the predicted
-- cast_position only when it hits 3+ - core API (spellcheck.core_cast_position;
-- spell_queue is not loaded, 2.312.0). The walk is held for the channel.
-- Never next to a sheep (it would break the Polymorph). smart.lua leaves
-- Blizzard to this hook (catalog `module = true`).
-- spell_prediction:new_spell_data / get_cast_position are in the Core_Api
-- database (lua/izi/spell_prediction.lua; audit R6) - the same calls
-- predict.lua has used since 2.248.0.
local BLIZZARD_IDS = { 27085, 10187, 10186, 10185, 8427, 6141, 10 }
-- 1.9.2 (spell data: Persistent Area Aura radius 8 yd; channeled 8 s, a tick every 1 s;
-- no cast time before the area is down): RADIUS 8 (was 6), CAST_T 0 (was 0.2),
-- CHANNEL_S 8 (was 8.2) - the walk is held the channel + HOLD_PAD
local BLIZ = { N = 3, RANGE = 30, RADIUS = 8, CAST_T = 0, CHANNEL_S = 8.0, HOLD_PAD = 0.2, GAP = 1.0, SHEEP_PAD = 2 }
local bliz_t = -1e9          -- the last attempt (GAP)
local bliz_cast_t = -1e9     -- 1.46.0: the last cast that went out (the channel)

--- 1.46.0: the enemy count is the Spells tab's "Area of effect at enemies"
--- slider, the same one COND.aoe in smart.lua uses for every other area
--- spell. BLIZ.N is only the fallback when the slider cannot be read - it
--- used to be the only answer, so moving the slider changed every AoE spell
--- except this one.
local function bliz_need()
    local ok, n = pcall(gui.slider, "sp_aoe", BLIZ.N)
    if ok and type(n) == "number" and n >= 1 then return math.floor(n) end
    return BLIZ.N
end
local function blizzard_on()
    local ok_sm, smart = pcall(require, "smart")
    if ok_sm and type(smart) == "table" and type(smart.is_enabled) == "function" and smart.is_enabled("Blizzard", false) then
        return true
    end
    return type(gui.is_on) == "function" and gui.is_on("blizzard") == true
end
local function rank_id(spellcheck)
    for i = 1, #BLIZZARD_IDS do
        local ok, why = spellcheck.core_castable(BLIZZARD_IDS[i], nil, { skip_casting = true, skip_gcd = true })
        if ok or why ~= "not learned" then return BLIZZARD_IDS[i] end
    end
    return nil
end
function mage.aoe(player, target, pack)
    if not player or not target or type(pack) ~= "table" then return false end
    if not blizzard_on() then return false end
    -- 1.46.0: NEVER over a cast or a channel. rotation.lua calls this hook
    -- before smart.combat, and only smart.combat holds the tick while the
    -- player is channelling - so through Blizzard's own 8 s channel this ran
    -- again every GAP second: it re-held the walk, had the recast refused by
    -- spellcheck.core_castable ("casting"), and then took the failure path
    -- below, which releases the hold. The bot walked out of the Blizzard it
    -- was channelling, one second in.
    local ok_busy, busy = pcall(function()
        return player:is_casting_spell() == true or player:is_channelling_spell() == true
    end)
    if ok_busy and busy == true then return false end
    local live, sheep = 0, {}
    for i = 1, #pack do
        local u = pack[i]
        if alive(u) then
            if targeting.is_polymorphed and targeting.is_polymorphed(u) then sheep[#sheep + 1] = u
            else live = live + 1 end
        end
    end
    if target and alive(target) then
        local listed = false
        for i = 1, #pack do if pack[i] == target then listed = true end end
        if not listed then live = live + 1 end
    end
    local need = bliz_need()
    if live < need then return false end
    local now = izi.now()
    if now - bliz_t < BLIZ.GAP then return false end
    -- the channel is 8 s and nothing else may be cast over it
    if now - bliz_cast_t < BLIZ.CHANNEL_S then return false end
    local ok_s, spellcheck = pcall(require, "spellcheck")
    if not ok_s or type(spellcheck) ~= "table" or type(spellcheck.core_cast_position) ~= "function" then return false end
    local id = rank_id(spellcheck)
    if not id then return false end
    if spell_helper:is_spell_castable(id, player, target, false, false) ~= true then return false end
    local mypos = player:get_position()
    local data = spell_prediction:new_spell_data(id, BLIZ.RANGE, BLIZ.RADIUS, BLIZ.CAST_T, 0.0,
        spell_prediction.prediction_type.MOST_HITS, spell_prediction.geometry_type.CIRCLE, mypos)
    local res = data and spell_prediction:get_cast_position(target, data)
    if type(res) ~= "table" or type(res.amount_of_hits) ~= "number" or res.amount_of_hits < need or not res.cast_position then
        return false
    end
    local pos = res.cast_position
    for i = 1, #sheep do
        local sp = sheep[i]:get_position()
        if sp and math.sqrt((sp.x - pos.x) ^ 2 + (sp.y - pos.y) ^ 2) <= BLIZ.RADIUS + BLIZ.SHEEP_PAD then return false end
    end
    bliz_t = now
    local ok_m, movement = pcall(require, "movement")
    local held = false
    if ok_m and type(movement) == "table" and type(movement.prepare_ground) == "function"
        and not (type(gui.is_on) == "function" and gui.is_on("rotation_only")) then
        movement.prepare_ground(pos, BLIZ.CHANNEL_S + BLIZ.HOLD_PAD)
        held = true
    end
    local ok = spellcheck.core_cast_position(id, pos)
    if ok == true then
        bliz_cast_t = now
        local ok_e, elog = pcall(require, "errorlog")
        if ok_e and type(elog) == "table" and type(elog.trail) == "function" then
            elog.trail("act", "Blizzard (%d) at the predicted spot: %d of %d enemies hit (need %d)",
                id, res.amount_of_hits, live, need)
        end
        return true
    end
    if held and type(movement.release) == "function" then pcall(movement.release) end
    return false
end

function mage.crowd_control(player, target, pack)
    if not player or type(pack) ~= "table" or #pack < 2 then return false end
    local my = level(player)
    local strong, tg = 0, target and guid(target) or nil
    for i = 1, #pack do
        local u = pack[i]
        if alive(u) then
            if targeting.is_polymorphed and targeting.is_polymorphed(u) then return false end   -- one sheep at a time
            if level(u) >= my then strong = strong + 1 end
        end
    end
    if strong < 2 then return false end
    local now = izi.now()
    local pick, pick_rank = nil, -1
    for i = 1, #pack do
        local u = pack[i]
        local g = guid(u)
        if alive(u) and g ~= nil and g ~= tg and polymorphable(u) and (now - (poly_try[g] or -1e9)) >= POLY_RETRY then
            local rank = level(u) >= my and 1 or 0
            if rank > pick_rank then pick, pick_rank = u, rank end
        end
    end
    if not pick then return false end
    poly_try[guid(pick)] = now
    local ok_s, spellcheck = pcall(require, "spellcheck")
    if not ok_s or type(spellcheck) ~= "table" or type(spellcheck.core_cast) ~= "function" then return false end
    local poly_id = poly_rank(spellcheck)
    if not poly_id then return false end
    local ok = spellcheck.core_cast(poly_id, pick)
    if ok == true then
        local ok_e, elog = pcall(require, "errorlog")
        if ok_e and type(elog) == "table" and type(elog.trail) == "function" then
            elog.trail("act", "Polymorph on %s (level %d) - %d enemies at or above level %d",
                tostring(select(2, pcall(function() return pick:get_name() end))), level(pick), strong, my)
        end
        return true
    end
    return false
end

-- ----------------------------------------------------------------------------
-- 1.21.0 OUT OF MANA (user: "at 5% mana or less in combat, Polymorph 12825 the
-- target, then Evocation 12051 when castable and off GCD, then resume the
-- rotation on the polymorphed target"). rotation.tick runs this hook first:
--   arm   mana <= OOM.PCT (power.mana_pct), in combat, a live enemy target, and
--         Evocation learned with its own cooldown over (a sheep with no
--         Evocation after it buys nothing - and the cooldown is minutes long);
--   poly  Polymorph 12825 on the target (the highest rank owned when 12825 is
--         not learned), core API, movement held and the target faced for the
--         cast. A target Polymorph cannot take (not a Beast / Humanoid /
--         Critter), a cast the game refuses (at 5 % mana it may not be
--         affordable), or no sheep after OOM.POLY_WAIT s: on to Evocation;
--   evoc  Evocation 12051 once spellcheck.core_castable says it is castable
--         and off the GCD (no skip_gcd), movement held for the channel;
--   chan  while channelling the tick is ours - nothing else is cast (a cast
--         would end the channel);
--   done  the channel ended (or never started in OOM.EVOC_WAIT s): the hold
--         lifts, the sheep is the target again and the rotation resumes on
--         it (targeting fights a sheep once it is the last enemy).
-- One sequence per OOM.GAP s at most.
-- ----------------------------------------------------------------------------
local OOM = { PCT = 5, POLY_ID = 12825, EVOC_ID = 12051, POLY_WAIT = 3.0, EVOC_WAIT = 4.0,
    CAST_HOLD = 1.8, CHANNEL_HOLD = 8.5, RESEND = 1.0, GAP = 30 }
mage.OOM = OOM
local oom = { phase = nil, t = 0, sheep = nil, sent = -1e9, done_t = -1e9 }
mage._oom = oom

local function oom_trail(fmt, ...)
    local ok_e, elog = pcall(require, "errorlog")
    if ok_e and type(elog) == "table" and type(elog.trail) == "function" then pcall(elog.trail, "act", fmt, ...) end
end

local function busy_casting(u)
    local ok, v = pcall(function() return u:is_casting_spell() == true end)
    return ok and v == true
end
local function channelling(u)
    local ok, v = pcall(function() return u:is_channelling_spell() == true end)
    return ok and v == true
end
local function name_of(u)
    local ok, n = pcall(function() return u:get_name() end)
    return ok and tostring(n) or "?"
end

local function oom_finish(why)
    local ok_m, movement = pcall(require, "movement")
    if ok_m and type(movement) == "table" and type(movement.release) == "function" then pcall(movement.release) end
    local s = oom.sheep
    if s and alive(s) then
        pcall(core.input.set_target, s)                         -- back on the polymorphed target
    end
    oom_trail("out of mana: %s - rotation resumes on %s", tostring(why), s and name_of(s) or "the next enemy")
    oom.phase, oom.sheep, oom.done_t = nil, nil, izi.now()
end

--- True while the sequence owns the tick (rotation.tick casts nothing else).
function mage.oom(player, target, pack)
    if not player then return false end
    local ok_s, spellcheck = pcall(require, "spellcheck")
    if not ok_s or type(spellcheck) ~= "table" or type(spellcheck.core_castable) ~= "function" then return false end
    local now = izi.now()
    if oom.phase == nil then
        if now - oom.done_t < OOM.GAP then return false end
        local okc, fighting = pcall(function() return player:is_in_combat() == true end)
        if not (okc and fighting) then return false end
        local ok_p, power = pcall(require, "power")
        local pct = ok_p and type(power) == "table" and power.mana_pct(player) or 100
        if type(pct) ~= "number" or pct > OOM.PCT then return false end
        if not target or not alive(target) then return false end
        -- Evocation learned and off its own cooldown (the GCD is waited out later)
        local okv, why = spellcheck.core_castable(OOM.EVOC_ID, nil, { skip_gcd = true, skip_casting = true })
        if not okv then return false end
        local okr, cd = pcall(core.spell_book.get_spell_cooldown, OOM.EVOC_ID)
        if okr and tonumber(cd) and tonumber(cd) > 1.6 then return false end
        oom.phase, oom.t, oom.sheep, oom.sent = "poly", now, target, -1e9
        oom_trail("out of mana (%.0f%%) in combat: Polymorph %s, then Evocation", pct, name_of(target))
    end
    if oom.phase == "poly" then
        local s = oom.sheep
        if busy_casting(player) then return true end              -- the Polymorph cast runs
        local sheeped = s and alive(s) and targeting.is_polymorphed and targeting.is_polymorphed(s)
        if sheeped or not s or not alive(s) or not polymorphable(s) or now - oom.t > OOM.POLY_WAIT then
            if not sheeped then
                oom_trail("out of mana: no Polymorph on %s (%s) - Evocation", s and name_of(s) or "?",
                    (s and alive(s) and not polymorphable(s)) and "it cannot be polymorphed" or "not cast")
            end
            oom.phase, oom.t = "evoc", now
        else
            if now - oom.sent >= OOM.RESEND then
                oom.sent = now
                local id = OOM.POLY_ID
                local okl, whyl = spellcheck.core_castable(id, nil, { skip_gcd = true, skip_casting = true })
                if not okl and whyl == "not learned" then id = poly_rank(spellcheck) or id end
                local ok_m, movement = pcall(require, "movement")
                if ok_m and type(movement) == "table" and type(movement.prepare_cast) == "function" then
                    pcall(movement.prepare_cast, s, OOM.CAST_HOLD)
                end
                spellcheck.core_cast(id, s)
            end
            return true
        end
    end
    if oom.phase == "evoc" then
        if channelling(player) then oom.phase = "chan" return true end
        if busy_casting(player) then return true end
        if now - oom.t > OOM.EVOC_WAIT then oom_finish("Evocation did not start") return false end
        if spellcheck.core_castable(OOM.EVOC_ID, nil) then        -- castable and off the GCD
            local ok_m, movement = pcall(require, "movement")
            if ok_m and type(movement) == "table" and type(movement.prepare_channel) == "function" then
                pcall(movement.prepare_channel, nil, OOM.CHANNEL_HOLD)
            end
            if spellcheck.core_cast(OOM.EVOC_ID, nil) then oom_trail("out of mana: Evocation") end
        end
        return true
    end
    if oom.phase == "chan" then
        if channelling(player) then return true end
        oom_finish("Evocation finished")
        return false
    end
    return false
end

-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink. The thresholds are this class's to choose; the
--- machinery lives in resting.lua so a fix lands once rather than nine times.
function mage.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return mage
