-- ============================================================================
-- Master Farmer - Zygor Forever
-- Shaman grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- WEAPON IMBUES - THE BUG NOT COPIED
--   The reference bot tests MainHand_Enchant once, then casts EVERY enabled
--   imbue in sequence without re-checking. Enable two and they overwrite each
--   other on every tick, so the Shaman spends the whole fight re-imbuing and
--   never attacks. Here the imbue is a single CHOICE (a dropdown), and it is
--   only cast when unit:item_has_enchant reports the main hand is bare.
--
--   unit:item_has_enchant is what makes this checkable at all - it was the
--   blocker that kept Shaman out of earlier versions.
--
-- SPELL IDS
--   Highest rank first; mfz_shaman_debug prints what resolved.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")

local shaman = {}

local function make(ids, track_buff, track_debuff)
    local spell = izi.spell(ids)
    if not spell then return nil end
    if track_buff and spell.track_buff then spell:track_buff(ids) end
    if track_debuff and spell.track_debuff then spell:track_debuff(ids) end
    return spellbook.watch(spell, ids, track_buff, track_debuff)
end

local lightning_bolt = make({ 25449, 25448, 15208, 15207, 10392, 10391, 6041, 943, 915, 548, 529, 403 })

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function shaman.class_id() return enums.class_id.SHAMAN end
function shaman.label() return "Shaman" end

function shaman.is_melee(player)
    return false
end

--- Stand at Lightning Bolt range. Melee spells fire on their own once the
--- mob is inside the melee distance; the approach does not walk in to get there.
function shaman.engage_range(player, target)
    -- 1.2.17 OUT OF MANA: no spell to cast, so stand in melee and keep there. A fleeing mob is chased; combat movement
    -- closes to this distance every tick, so the weapon swings (and Rockbiter / Earth Shock when mana returns) keep landing.
    if shaman.out_of_mana(player) then return 4 end
    local reach = nil
    if lightning_bolt and type(lightning_bolt.maximum_range) == "number"
        and lightning_bolt.maximum_range > 8 then
        reach = lightning_bolt.maximum_range - 1
    end
    if type(reach) ~= "number" or reach < 8 then reach = 30 end
    return reach
end

function shaman.combat_range(player)
    return shaman.engage_range(player, nil)
end

--- How far out to look for something to fight.
---
--- Melee has to walk into contact and then stand still, so a wide scan just
--- drags extra mobs into a fight it cannot kite out of. At range the pull
--- starts from where the bot is already standing, so the extra warning is
--- free. This class does both, so the scan follows the same toggle its
--- combat range does.
-- (2.151.0) These read an "enhancement" GUI toggle removed with the old
-- class checkboxes in 2.142.0; is_melee is the one answer now.
function shaman.scan_range(player)
    if shaman.is_melee(player) then
        return 20
    end
    return 35
end

function shaman.combat_profile()
    local melee = shaman.is_melee(nil)
    return {
        name         = "shaman",
        melee_danger = melee and 0 or 8,
        melee_safe   = melee and 0 or 12,
        -- Enhancement wants to BE in melee, so it never retreats. Elemental has
        -- no snare worth the global, so kiting costs more cast time than it saves.
        should_retreat = function() return false end,
    }
end

-- ----------------------------------------------------------------------------
-- COMBAT
-- ----------------------------------------------------------------------------
-- Elemental PvE policy: smart.lua retains cast checks, interrupts, facing,
-- action pacing and user spell toggles. This module only decides priorities.
local spec_at, elemental = -1e9, false
local slots = { ["Totem of Wrath"]=1, ["Searing Totem"]=1, ["Stoneskin Totem"]=2,
    ["Strength of Earth Totem"]=2, ["Mana Spring Totem"]=3, ["Wrath of Air Totem"]=4,
    ["Windfury Totem"]=4, ["Grace of Air Totem"]=4 }
local placed, slot_cache, slot_at = {}, {}, -1e9
local function native(unit, method)
    if not unit then return nil end
    local ok, valid = pcall(function() return unit:is_valid() end)
    if not ok or not valid then return nil end
    local good, value = pcall(function() return unit[method](unit) end)
    if good then return value end
    return nil
end
function shaman.elemental()
    local now = izi.now()
    if now >= spec_at and now - spec_at < 5 then return elemental end
    spec_at, elemental = now, false
    local best, points = nil, 0
    for i=1,3 do
        local ok, tab = pcall(function() return core.game_ui.get_talent_tab_info(i) end)
        local n = ok and type(tab)=="table" and tonumber(tab.points_spent) or 0
        if n and n > points then best, points = i, n end
    end
    elemental = best == 1
    return elemental
end
-- Combat-log evidence is scoped to our current target, never a creature name.
local combat_source, combat_target, nature_until
function shaman.on_combat_log(args)
    if type(args) ~= "table" or args[4] ~= combat_source or args[8] ~= combat_target
        or not combat_source or not combat_target then return end
    if args[2] == "SPELL_MISSED" and args[15] == "IMMUNE" and args[14] == 8 then
        nature_until = izi.now() + 60
    elseif args[2] == "SPELL_DAMAGE" and args[14] == 8 then
        nature_until = nil
    end
end
shaman.MANA_FLOOR = 20
shaman.MANA_RESUME = 35            -- hysteresis: casting resumes once mana is back above this
local floored = false
local function floor_update(m)
    if type(m) ~= "number" then return floored end
    if m < shaman.MANA_FLOOR then floored = true elseif m >= shaman.MANA_RESUME then floored = false end
    return floored
end
function shaman.mana_low(c)
    return floor_update(c.mana())
end
--- 1.2.17: out of mana (below the floor, until it is back above the resume line), read from the power module so it is
--- right outside the spell cascade too (the engage distance asks it).
function shaman.out_of_mana(player)
    local ok, pw = pcall(require, "power")
    if not ok or type(pw) ~= "table" or type(pw.mana_pct) ~= "function" then return floored end
    local okp, m = pcall(pw.mana_pct, player)
    if not okp then return floored end
    return floor_update(m)
end
function shaman.allow(e, player, c, target)
    local source, dest = native(player,"get_guid"), native(target,"get_guid")
    if source ~= combat_source or dest ~= combat_target then nature_until = nil end
    combat_source, combat_target = source, dest
    local nature_immune = nature_until and izi.now() < nature_until

    -- 1.2.11 MANA FLOOR: the log showed casts at 1-15% mana, then a death at 4% HP while
    -- "Wait: Casting". Below the floor a damage spell is left to melee (weapon swings cost
    -- no mana) unless the target is nearly dead; heals are never blocked by it.
    if e.role == "damage" and shaman.mana_low(c) and c.thp() > 20 then return false end

    if not shaman.elemental() then return true end
    if nature_immune and (e.name == "Lightning Bolt" or e.name == "Chain Lightning"
        or e.name == "Earth Shock") then return false end
    if e.name == "Frost Shock" then return nature_immune == true end
    if e.name == "Stormstrike" then return false end
    if e.name == "Elemental Mastery" then return native(player,"is_moving") ~= true end
    if e.name == "Flame Shock" then
        return nature_immune == true or (native(player,"is_moving") == true and c.mana() >= 30 and c.thp() >= 40)
    end
    if e.name == "Earth Shock" and e.role == "damage" then
        return native(player,"is_moving") == true or c.thp() <= 15
    end
    if e.name == "Chain Lightning" then return c.mana() >= 40 end
    return true
end
function shaman.totem_cast(e, player, c)
    local slot = (e.def and e.def.slot) or slots[e.name]
    if not slot then return end
    local p = native(player,"get_position")
    placed[slot] = {name=e.name,t=izi.now(),pos=p and {x=p.x,y=p.y,z=p.z} or nil}
    slot_at = -1e9
    pcall(function()
        require("actlog").event("totem", "cast", e.name, {slot=slot, purpose=e.def and e.def.purpose,
            hp=c and c.hp(), mana=c and c.mana(), target_hp=c and c.thp(),
            moving=native(player,"is_moving"), pos=p and {x=p.x,y=p.y,z=p.z} or nil})
    end)
end
-- ----------------------------------------------------------------------------
-- TOTEMS BY PURPOSE (1.76.0)
-- ----------------------------------------------------------------------------
-- data/class_spells.lua gives every totem a SLOT (1 Fire, 2 Earth, 3 Water, 4 Air - the index of
-- core.spell_book.get_totem_info) and a PURPOSE. One totem lives in a slot; the catalog order is the
-- priority inside it. Each purpose has a rule over the situation: how hard the fight is, how many
-- enemies are on the player, health, mana, distance, and the talent build.
local MELEE_RANGE = 10          -- an enemy this close is "in melee" for the group buffs
local TOTEM_RANGE = 25          -- Searing and most totems act within about this distance of where they stand
local RELOCATE = 25             -- a placed totem further than this from the player is as good as gone

local build_at, build_cache = -1e9, "leveling"
--- "elemental", "enhancement", "restoration", or "leveling" (fewer than 10 talent points spent).
function shaman.build()
    local now = izi.now()
    if now >= build_at and now - build_at < 5 then return build_cache end
    build_at, build_cache = now, "leveling"
    local best, points, total = nil, 0, 0
    for i = 1, 3 do
        local ok, tab = pcall(function() return core.game_ui.get_talent_tab_info(i) end)
        local n = ok and type(tab) == "table" and tonumber(tab.points_spent) or 0
        total = total + (n or 0)
        if n and n > points then best, points = i, n end
    end
    if total >= 10 then build_cache = ({ "elemental", "enhancement", "restoration" })[best] or "leveling" end
    return build_cache
end

-- 1.2.17 THE OPENING TOTEM: the first seconds of every fight drop one enabled totem, whatever the mob (no "worth it" test, only
-- a small mana floor), so a fight never starts without its totem. fight.t0 is the start of the current fight: a gap of
-- more than FIGHT_GAP s between two asks, or a fight that was not in combat, starts a new one.
shaman.OPENING_S = 8.0
local FIGHT_GAP = 5.0
local fight = { t0 = nil, last = -1e9, was = false }
local function fight_age(c)
    local now = izi.now()
    local in_combat = type(c.in_combat) ~= "function" or c.in_combat() == true
    if not in_combat then fight.was = false fight.last = now return nil end
    if not fight.was or now - fight.last > FIGHT_GAP then fight.t0 = now end
    fight.was, fight.last = true, now
    return now - fight.t0
end
shaman._fight_age = fight_age

local function situation(c)
    local x = { mana = c.mana(), thp = c.thp(), hp = type(c.hp) == "function" and c.hp() or 100,
        near8 = c.near(8), near10 = c.near(10), dist = c.dist(),
        tough = type(c.tough) == "function" and c.tough() == true or false,
        gap = type(c.tlevel_gap) == "function" and c.tlevel_gap() or 0 }
    x.build = shaman.build()
    x.melee = x.build == "enhancement"
    -- a fight worth a totem's mana: a tougher mob, a pack, or an even-level mob with most of its health
    x.worth = x.tough or x.near10 >= 2 or (x.gap >= -1 and x.thp >= 50)
    local age = fight_age(c)
    x.opening = age ~= nil and age < shaman.OPENING_S and x.thp >= 70
    return x
end

local RULE = {}
RULE.damage = function(x) return x.worth and x.thp >= 60 and x.dist <= TOTEM_RANGE and x.mana >= 35 end
RULE.aoe = function(x) return x.near8 >= 2 and x.thp >= 40 and x.mana >= 40 end
RULE.burst = function(x) return x.near8 >= 3 and x.mana >= 45 end
RULE.spell = function(x) return not x.melee and x.worth and x.thp >= 50 and x.mana >= 40 end
RULE.defense = function(x) return x.worth and x.near8 >= 1 and (x.hp < 85 or x.near8 >= 2 or x.tough) and x.mana >= 30 end
RULE.emergency = function(x) return x.hp < 45 and x.near10 >= 1 and x.mana >= 20 end
-- 1.2.26: not on a nearly dead mob (a Strength of Earth Totem went down with the Murloc at 40 %, mana 80 -> 43 %)
RULE.buff = function(x) return x.worth and x.thp >= 55 and x.dist <= MELEE_RANGE and x.mana >= 40 end
RULE.mana = function(x) return x.mana <= 65 and x.mana >= 12 and x.worth and x.thp >= 50 end
RULE.mana_emergency = function(x) return x.mana < 25 and x.thp >= 30 end
RULE.heal = function(x) return x.hp <= 70 and x.near10 >= 1 and x.mana >= 15 end
-- These are opt-in through the GUI. Selecting one requests proactive combat
-- coverage; do not infer an enemy school or debuff from unavailable metadata.
RULE.resist = function(x) return x.worth and x.mana >= 35 end
RULE.utility = function(x) return x.worth and x.mana >= 35 end
RULE.cleanse = function(x) return x.worth and x.mana >= 35 end
RULE.control = function(x) return x.worth and x.mana >= 35 end
shaman._RULE = RULE

local function named(info_name, name)
    -- GetTotemInfo names carry the rank ("Searing Totem V")
    return type(info_name) == "string" and info_name:sub(1, #name) == name
end

local function slot_state(slot)
    local now = izi.now()
    if now < slot_at or now - slot_at >= .25 then
        slot_at, slot_cache = now, {}
        for i = 1, 4 do
            local ok, info = pcall(function() return core.spell_book.get_totem_info(i) end)
            slot_cache[i] = ok and type(info) == "table" and info or false
        end
    end
    return slot_cache[slot]
end

-- Choose from learned, enabled and currently usable totems, not catalog order.
-- The smart cast gate still owns rank, mana cost, cooldown, GCD and casting.
local totem_defs = {}
for _, d in ipairs(require("data/class_spells").for_class(7)) do
    if d[2] == "totem" then totem_defs[d[1]] = d end
end
local priorities = { emergency=100, mana_emergency=95, heal=85, defense=75, burst=60,
    aoe=65, spell=55, mana=50, damage=40, buff=30, resist=80, utility=80, cleanse=80, control=80 }
local function available(name, d, c)
    if type(c.totem_available) == "function" then return c.totem_available(name) == true end
    if type(c.known) ~= "function" or c.known(name) ~= true then return false end
    if type(c.ticked) == "function" and not c.ticked(name, d.on) then return false end
    if type(c.cd_left) == "function" and c.cd_left(name) > 0 then return false end
    if type(d.when) == "function" and not d.when(c) then return false end
    return true
end
-- 1.2.21 THE OPENING SET: Fire Nova (fire slot) and Earthbind (earth slot) lead the fight, then the opening totem of the water /
-- air slots follows. They outrank the other purposes of their slot for the opening window only.
local OPENING_FIRST = { ["Fire Nova Totem"] = 90, ["Earthbind Totem"] = 85 }
shaman.OPENING_FIRST = OPENING_FIRST
local function score(name, d, x, c)
    if name == "Earthbind Totem" and x.opening and x.mana >= 50 and x.dist <= TOTEM_RANGE
        and (type(c.totem_control_safe) ~= "function" or c.totem_control_safe() == true) then
        return OPENING_FIRST[name]          -- 1.2.21: Earthbind is part of the opening set; 1.2.25: with 50 %+ mana (it cost ~15 % each pull)
    end
    if name == "Earthbind Totem" then
        -- 1.2.16: 60 (was 90). At 90 it outranked Stoneskin (75) and Stoneclaw's slot-mate Strength of Earth every time
        -- health fell under 60 %, so the earth slot held Earthbind for 45 s and the enabled defensive totems never
        -- went down. Earthbind now only fills the slot when no enabled defense / emergency totem is wanted.
        return not x.melee and x.hp < 60 and x.near10 >= 1 and x.mana >= 15
            and type(c.totem_control_safe) == "function" and c.totem_control_safe() == true and 60 or 0
    end
    local rule = RULE[d.purpose]
    -- the opening totem: damage / defense / buff / spell / aoe-less purposes pass at the start of a fight with 15 % mana
    local opening = x.opening and x.mana >= shaman.MANA_FLOOR and x.dist <= TOTEM_RANGE
        and (d.purpose == "damage" or d.purpose == "defense" or d.purpose == "buff" or d.purpose == "spell"
             or d.purpose == "mana" and x.mana <= 90 or OPENING_FIRST[name] ~= nil)
    if not opening and (not rule or not rule(x)) then return 0 end
    if x.hp < 45 and (d.purpose == "damage" or d.purpose == "aoe" or d.purpose == "spell" or d.purpose == "buff") then return 0 end
    if (d.purpose == "aoe" or d.purpose == "burst")
        and type(c.totem_aoe_safe) == "function" and c.totem_aoe_safe() ~= true then return 0 end
    local value = priorities[d.purpose] or 0
    if opening and OPENING_FIRST[name] then value = OPENING_FIRST[name] end
    if d.purpose == "heal" and x.hp < 40 then value = 110 end
    if name == "Totem of Wrath" and x.build == "elemental" then value = 60 end
    if name == "Windfury Totem" then value = value + 1 end
    return value
end
local function slot_allows(name, d, player, x)
    local now, slot = izi.now(), d.slot
    local previous, info = placed[slot], slot_state(slot)
    if previous and now - previous.t >= 0 and now - previous.t < 3 then return false end
    -- Unreadable state never justifies a blind overwrite, even after a timer.
    if not info or type(info.have_totem) ~= "boolean" then return false end
    if info.have_totem ~= true then return true end
    local remaining = tonumber(info.remaining)
    if remaining == nil then return false end
    if remaining <= 0 then return true end
    if remaining <= 3 and named(info.totem_name, name) then return true end
    local p = native(player, "get_position")
    local owned = previous and previous.pos and p and named(info.totem_name, previous.name)
    if owned then
        local dx,dy,dz=p.x-previous.pos.x,p.y-previous.pos.y,(p.z or 0)-(previous.pos.z or 0)
        if dx*dx+dy*dy+dz*dz > RELOCATE*RELOCATE then return true end
    end
    if named(info.totem_name, name) then return false end
    -- Emergency totems may replace a catalog totem of ours that is not itself an emergency one. 1.2.16: the totem in
    -- the slot is recognised by NAME as well as by what we remember placing (a reload forgets it), and Earthbind /
    -- control / spell / aoe totems count as routine - the log shows Stoneclaw never dropped at 4 % health because
    -- Earthbind (control) sat in the earth slot and was not "routine". Elementals and unknown totems stay preserved.
    local old = owned and totem_defs[previous.name] or nil
    if not old then
        for known, kd in pairs(totem_defs) do
            if named(info.totem_name, known) then old = kd break end
        end
    end
    local KEEP = { emergency = true, heal = true, mana_emergency = true }
    local MANUAL = { utility = true, resist = true, cleanse = true }       -- opt-in totems are never overwritten unless we placed them
    local routine = old and not KEEP[old.purpose] and (owned or not MANUAL[old.purpose])
    return routine and ((d.purpose == "emergency" and x.hp < 45)
        or (d.purpose == "mana_emergency" and x.mana < 25)
        or (d.purpose == "heal" and x.hp < 40)) or false
end

function shaman.totem_needed(e, player, c)
    local d = totem_defs[e.name]
    if not d or native(player, "is_valid") ~= true then return false end
    local moving = native(player, "is_moving")
    if moving == nil then return false end
    if type(c.in_combat) == "function" and c.in_combat() ~= true then return false end
    local x = situation(c)
    if not available(e.name, d, c) or score(e.name, d, x, c) <= 0 then return false end
    local best, best_score = nil, 0
    for name, candidate in pairs(totem_defs) do
        if available(name, candidate, c) then
            local value = score(name, candidate, x, c)
            -- Survival must win across element slots, not just within one slot.
            -- Routine setup still waits until stationary; emergency instant casts
            -- use smart's normal castability/GCD checks without claiming movement.
            local urgent = candidate.purpose == "emergency" or candidate.purpose == "heal"
                or candidate.purpose == "mana_emergency" or name == "Earthbind Totem"
            if moving and not urgent then value = 0 end
            if value > 0 and (candidate.slot == d.slot or urgent) and slot_allows(name, candidate, player, x)
                and (value > best_score or value == best_score and (best == nil or name < best)) then
                best, best_score = name, value
            end
        end
    end
    return best == e.name
end

-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink. The thresholds are this class's to choose; the
--- machinery lives in resting.lua so a fix lands once rather than nine times.
function shaman.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return shaman
