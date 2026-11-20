-- ============================================================================
-- Master Farmer - Zygor Forever
-- Class spell catalog (TBC) - what the Spells tab lists and the rotation casts
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- ONE LIST PER CLASS (2.64.0)
--   Every DPS, healing and tanking spell of the class, by the name the client
--   gives it. After the spellbook scan, the Spells tab shows the entries the
--   character actually knows - so it never lists another class's spells, a
--   profession, a passive or a spell not learned yet - and smart.lua builds the
--   rotation from the ones that are ticked. The best known rank is cast.
--
--   The ORDER of a class list is its priority: within a role the first entry
--   that can be cast wins. The roles themselves run in the order smart.lua
--   gives (heal, defensive, interrupt, ... damage, filler).
--
-- FIELDS
--   [1]    spell name, exactly as the client reports it
--   [2]    role:
--            buff      kept up on the player, in and out of combat
--            cbuff     kept up in combat only (Holy Shield, Ice Barrier...)
--            form      shapeshift / stance / presence, kept up
--            seal      paladin seal: only while actually attacking a target
--            imbue     shaman weapon imbue (checked on the main hand)
--            pet       summon (hunter / warlock); pets.lua does the upkeep
--            petheal   Mend Pet / Health Funnel
--            heal      self heal below the "Self-heal below %" slider
--            defensive below the "Defensives below %" slider
--            interrupt a casting enemy
--            resource  mana / rage generation (Life Tap, Evocation, Bloodrage)
--            opener    only before the fight has started (Charge)
--            execute   target below 20% (or `thp`)
--            control   Frost Nova, War Stomp-like: a mob in melee range
--            debuff    DoT / debuff kept on the target
--            totem     dropped once per `recast` seconds in combat
--            cooldown  burst, on a healthy target or a pack
--            aoe       with enough enemies (the "AoE when" slider or `n`)
--            finisher  combo-point spender
--            damage    the main rotation, in list order
--            filler    wand / auto shot, last
--   on       ticked by default (false = listed but unticked)
--   g        exclusive group: only the FIRST ticked, known member is used
--            (one aura, one seal, one armor, one stance, one pet...)
--   melee    needs melee range; `min` = minimum yards (hunter dead zone)
--   form     druid form / warrior stance the spell needs (string or list)
--   self     cast on the player (default for buff / heal / defensive ...)
--   enemy    cast on the target although the role is a self one (Drain Life)
--   ground   cast at the target's position (Blizzard, Flamestrike...)
--   center   "self" or "target" for an AoE count (default "target")
--   r        AoE radius (default 10); n = enemies needed
--   cone     2.248.0: a cone in front of the player (`angle` degrees, default
--            60) - predict.lua predicts its hits with spell_prediction
--   thp      execute: target health below; debuff/cooldown: target above
--   hp       heal / defensive threshold override (percent)
--   cp       finisher: combo points needed
--   hot      heal-over-time: skipped while its buff is on the player
--   ctype    target creature types it works on ("UNDEAD", "DEMON")
--   when     function(c) -> bool, the spell-specific condition (see smart.lua
--            for what `c` offers)
--   recast   totem: seconds before it is dropped again
--   tip      tooltip in the Spells tab
-- ============================================================================

local W = {}

local function t(list)
    return list
end

-- Shared conditions --------------------------------------------------------
local function mana_below(p)
    return function(c) return c.mana() < p end
end

local function rage_at_least(r)
    return function(c) return c.rage() >= r end
end

-- 2.303.0: a rage DUMP - `full` rage while other melee specials want the
-- rage, `alone` when this is the only one (c.specials() == 0, low level).
local function rage_dump(full, alone)
    return function(c)
        local n = type(c.specials) == "function" and c.specials() or 1
        return c.rage() >= (n > 0 and full or alone)
    end
end

-- ============================================================================
-- WARRIOR
-- ============================================================================
W.WARRIOR = t({
    { "Battle Stance",     "form", on = true,  g = "stance", tip = "The stance this rotation fights in. Only one stance is kept." },
    { "Defensive Stance",  "form", on = false, g = "stance" },
    { "Berserker Stance",  "form", on = false, g = "stance" },
    { "Battle Shout",      "buff", on = true,  g = "shout" },
    { "Commanding Shout",  "buff", on = false, g = "shout" },

    { "Charge",            "opener", on = true, form = "battle",
      when = function(c) return c.dist() >= 8 and c.dist() <= 25 end, tip = "Opens the fight from 8-25 yards." },
    { "Intercept",         "opener", on = true, form = "berserker",
      when = function(c) return c.dist() >= 8 and c.dist() <= 25 end },

    { "Last Stand",        "defensive", on = true },
    { "Shield Wall",       "defensive", on = true, form = "defensive" },
    { "Intimidating Shout","defensive", on = false, enemy = true, when = function(c) return c.near(8) >= 2 end },

    { "Pummel",            "interrupt", on = true, melee = true, form = "berserker" },
    { "Shield Bash",       "interrupt", on = true, melee = true, form = { "battle", "defensive" } },

    { "Bloodrage",         "resource", on = true, self = true,
      when = function(c) return c.rage() < 30 and c.hp() > 50 end },
    { "Berserker Rage",    "resource", on = false, self = true, form = "berserker" },

    { "Victory Rush",      "execute", on = true, melee = true, thp = 101 },
    { "Execute",           "execute", on = true, melee = true, form = { "battle", "berserker" } },

    { "Rend",              "debuff", on = true, melee = true, form = { "battle", "defensive" }, thp = 50,
      when = function(c) return not c.ttype("UNDEAD") and not c.ttype("ELEMENTAL") and not c.ttype("MECHANICAL") end },
    { "Demoralizing Shout","debuff", on = false, self = true, when = function(c) return c.near(10) >= 2 end },
    { "Thunder Clap",      "debuff", on = true, self = true, form = { "battle", "defensive" },
      when = function(c) return c.near(8) >= 2 end },
    { "Sunder Armor",      "debuff", on = false, melee = true },

    { "Death Wish",        "cooldown", on = true, self = true },
    { "Recklessness",      "cooldown", on = false, self = true, form = "berserker" },
    { "Sweeping Strikes",  "cooldown", on = true, self = true, form = { "battle", "berserker" },
      when = function(c) return c.near(8) >= 2 end },

    { "Whirlwind",         "aoe", on = true, center = "self", r = 8, n = 2, form = "berserker" },
    { "Cleave",            "aoe", on = true, melee = true, n = 2, r = 8, when = rage_dump(40, 25) },

    { "Overpower",         "damage", on = true, melee = true, form = "battle" },
    { "Revenge",           "damage", on = true, melee = true, form = "defensive" },
    { "Shield Slam",       "damage", on = true, melee = true },
    { "Mortal Strike",     "damage", on = true, melee = true },
    { "Bloodthirst",       "damage", on = true, melee = true },
    { "Whirlwind",         "damage", on = true, melee = true, form = "berserker" },
    { "Devastate",         "damage", on = true, melee = true },
    { "Slam",              "damage", on = false, melee = true },
    { "Heroic Strike",     "damage", on = true, melee = true, when = rage_dump(50, 20),
      tip = "Rage dump: with 50+ rage while other specials need the rage; with 20+ when it is the only damage special (low level)." },
    { "Hamstring",         "damage", on = false, melee = true },
})

-- ============================================================================
-- PALADIN
-- ============================================================================
local function seal_up(c)
    return c.group_up("seal")
end

W.PALADIN = t({
    { "Devotion Aura",          "form", on = true,  g = "aura", tip = "Only one aura can be active: the first ticked one is kept up." },
    { "Retribution Aura",       "form", on = false, g = "aura" },
    { "Sanctity Aura",          "form", on = false, g = "aura" },
    { "Concentration Aura",     "form", on = false, g = "aura" },
    { "Crusader Aura",          "form", on = false, g = "aura" },
    { "Frost Resistance Aura",  "form", on = false, g = "aura" },
    { "Shadow Resistance Aura", "form", on = false, g = "aura" },
    { "Fire Resistance Aura",   "form", on = false, g = "aura" },

    { "Blessing of Might",      "buff", on = true,  g = "blessing", tip = "One blessing on yourself: the first ticked one." },
    { "Blessing of Wisdom",     "buff", on = true,  g = "blessing" },
    { "Blessing of Kings",      "buff", on = false, g = "blessing" },
    { "Blessing of Sanctuary",  "buff", on = false, g = "blessing" },
    { "Blessing of Light",      "buff", on = false, g = "blessing" },
    { "Righteous Fury",         "buff", on = false, tip = "Tanking: more threat from holy damage." },
    { "Holy Shield",            "cbuff", on = false },

    { "Seal of Righteousness",  "seal", on = true,  g = "seal", tip = "Cast only while actually attacking a target - never on the walk in or out of combat." },
    { "Seal of Command",        "seal", on = false, g = "seal" },
    { "Seal of Blood",          "seal", on = false, g = "seal" },
    { "Seal of Vengeance",      "seal", on = false, g = "seal" },
    { "Seal of the Crusader",   "seal", on = false, g = "seal" },
    { "Seal of Light",          "seal", on = false, g = "seal" },
    { "Seal of Wisdom",         "seal", on = false, g = "seal" },

    { "Flash of Light",         "heal", on = true },
    { "Holy Light",             "heal", on = true, when = function(c) return c.hp() < c.heal_pct() - 15 end },
    { "Holy Shock",             "heal", on = true },
    { "Lay on Hands",           "defensive", on = true, hp = 15 },
    { "Divine Shield",          "defensive", on = true, hp = 20 },
    { "Divine Protection",      "defensive", on = true },

    { "Hammer of Justice",      "interrupt", on = true },

    { "Hammer of Wrath",        "execute", on = true },

    { "Avenging Wrath",         "cooldown", on = true, self = true },

    { "Consecration",           "aoe", on = false, self = true, center = "self", r = 8, tip = "Off by default: expensive, and pulls adds when soloing." },
    { "Holy Wrath",             "aoe", on = false, self = true, center = "self", r = 20, ctype = { "UNDEAD", "DEMON" } },

    { "Judgement",              "damage", on = true, when = seal_up, tip = "Only with a seal up - judging with none wastes the cooldown." },
    { "Crusader Strike",        "damage", on = true, melee = true },
    { "Avenger's Shield",       "damage", on = false },
    { "Exorcism",               "damage", on = true, ctype = { "UNDEAD", "DEMON" } },
})

-- ============================================================================
-- HUNTER
-- ============================================================================
W.HUNTER = t({
    { "Aspect of the Hawk",     "form", on = true,  g = "aspect", tip = "One aspect at a time: the first ticked one you know." },
    { "Aspect of the Monkey",   "form", on = true,  g = "aspect" },
    { "Aspect of the Viper",    "form", on = false, g = "aspect" },
    { "Trueshot Aura",          "buff", on = true },

    { "Call Pet",               "pet",  on = true, tip = "Summons, revives and heals the pet out of combat." },
    { "Mend Pet",               "petheal", on = true },

    { "Deterrence",             "defensive", on = true },
    { "Intimidation",           "interrupt", on = true },

    { "Hunter's Mark",          "debuff", on = true, min = 11 },
    { "Serpent Sting",          "debuff", on = true, min = 11, g = "sting", thp = 40 },
    { "Viper Sting",            "debuff", on = false, min = 11, g = "sting" },

    { "Bestial Wrath",          "cooldown", on = true, self = true },
    { "Rapid Fire",             "cooldown", on = true, self = true },


    -- Melee (2.120.0): Wing Clip first, so a mob that closed in is slowed.
    -- MELEE BAND (2.222.0): at or inside 11 yd the Hunter closes to 3 yd and
    -- fights in melee; every shot carries min = 11.
    { "Wing Clip",              "control", on = true, melee = true,
      when = function(c) return c.dist() <= 5 and not c.debuff("Wing Clip") and not c.debuff("Concussive Shot") end,
      tip = "In melee (11 yd or closer): slow the mob." },
    -- Shots before melee swings. A shot inside its minimum range (11 yd) is
    -- skipped, so in the melee band Raptor Strike is the one that lands.
    { "Arcane Shot",            "damage", on = true, min = 11 },
    -- 2.242.0: Multi-Shot (2643 and every rank) is a DAMAGE shot on the
    -- target, not an AoE spell - it no longer waits for 2+ enemies.
    { "Multi-Shot",             "damage", on = true, min = 11 },
    { "Steady Shot",            "damage", on = true, min = 11 },
    { "Kill Command",           "damage", on = true, when = function(c) return c.dist() > 5 end },
    { "Concussive Shot",        "damage", on = false, min = 11, when = function(c) return c.dist() <= 16 end },
    { "Raptor Strike",          "damage", on = true, melee = true },
    { "Mongoose Bite",          "damage", on = true, melee = true },

    { "Auto Shot",              "filler", on = true, min = 11 },
})

-- ============================================================================
-- ROGUE
-- ============================================================================
W.ROGUE = t({
    -- 2.224.0: pull with a thrown weapon (smart.lua ROGUE THROW), then wait
    -- for the mob to come into melee. Not part of the combat order.
    -- 2.228.0: Stealth opener (smart.lua ROGUE STEALTH OPENER): stealth near
    -- the target, sneak behind it, open with Backstab. Comes before Throw.
    { "Stealth",                "stealth", on = true,
      tip = "Stealth before a pull, sneak behind the target and open with Backstab (Sinister Strike if it cannot get behind)." },
    -- 2.277.0: Sap (6770, needs Stealth, humanoids out of combat, 25 s).
    -- Not in the catalog before, so the Spells tab never listed it (an
    -- uncatalogued spell needs Stealth to be "usable"). Used by the Stealth
    -- opener (smart.lua ROGUE SAP): a second humanoid of the pack, near the
    -- target and in melee reach while sneaking in, is sapped once.
    { "Sap",                    "sap", on = true, id = 6770, melee = true,
      tip = "While sneaking in: saps a second humanoid next to the target (not in combat, within reach) so the fight is one at a time." },
    -- 3.1.0: STEALTH OPENERS (smart.lua ROGUE STEALTH OPENER) - with a dagger
    -- in the main hand Ambush from behind (Backstab when Ambush is not known),
    -- without one Cheap Shot (no positioning); a dagger opener that cannot get
    -- behind opens with Cheap Shot from the front.
    { "Ambush",                 "stealth_opener", on = true, melee = true, id = 8676,
      tip = "Stealth opener with a dagger in the main hand: from behind the target." },
    { "Cheap Shot",             "stealth_opener", on = true, melee = true, id = 1833,
      tip = "Stealth opener without a dagger (or when it cannot get behind the target): stuns 4 s." },
    { "Throw",                  "pull", on = true,
      tip = "With a throwing weapon equipped: throw at the target from up to 30 yd, then wait for it to reach melee." },
    { "Evasion",                "defensive", on = true, when = function(c) return c.near(8) >= 2 or c.hp() < c.def_pct() end, hp = 101 },
    { "Cloak of Shadows",       "defensive", on = true },
    { "Kick",                   "interrupt", on = true, melee = true },
    -- 2.276.0: Sprint (2983, +50% run speed 15 s, keeps Stealth) was not in
    -- the catalog, and as an uncatalogued spell it is listed only once the
    -- game has called it usable - never while on its 5 min cooldown. The id
    -- is hard-coded so a scan that misses the name still finds it. Used to
    -- catch a fleeing mob: in combat, target under 35 %, moving, past 8 yd.
    { "Sprint",                 "resource", on = true, self = true, id = 2983,
      when = function(c) return c.thp() < 35 and c.tmoving() and c.dist() > 8 end,
      tip = "Catches a fleeing mob: cast when the target is under 35 % health, moving and more than 8 yd away." },
    -- 3.1.0: opening without Stealth (or already in combat) with a dagger:
    -- Gouge, step behind the incapacitated target, Backstab (smart.lua ROGUE
    -- GOUGE). Without a dagger the fight goes straight to the builder.
    { "Gouge",                  "gouge", on = true, melee = true, id = 1776,
      tip = "Dagger build, no Stealth opener: Gouge, step behind the target and Backstab." },

    { "Adrenaline Rush",        "cooldown", on = true, self = true },
    { "Blade Flurry",           "cooldown", on = true, self = true, when = function(c) return c.near(8) >= c.aoe_n() end },
    { "Cold Blood",             "cooldown", on = true, self = true, when = function(c) return c.cp() >= 4 end },

    -- 3.1.0: Slice and Dice only against tougher mobs (elite / rare / boss,
    -- or a higher level than the player); normal leveling mobs get Eviscerate.
    { "Slice and Dice",         "finisher", on = true, self = true, cp = 2, thp = 30,
      when = function(c) return c.tough() and not c.buff("Slice and Dice") end,
      tip = "Against tougher mobs (elite, rare, boss or a higher level than you): kept up from 2 combo points." },
    { "Rupture",                "finisher", on = false, melee = true, cp = 4, thp = 50,
      when = function(c) return not c.debuff("Rupture") end },
    { "Envenom",                "finisher", on = false, melee = true, cp = 4 },
    -- 2.229.0: id 2098 hard-coded. 3.1.0: the main finisher from 3 combo points.
    { "Eviscerate",             "finisher", on = true, melee = true, cp = 3, id = 2098,
      tip = "Main finisher: at 3+ combo points (earlier on a dying target)." },

    -- 2.244.0: Eureka! (WoW Forever, 1259812) - cast every time it is off
    -- cooldown in a fight. First damage entry, so nothing else goes ahead of
    -- it; target first, then the player (`either`), whichever it takes.
    { "Eureka!",                "damage", on = true, id = 1259812, either = true,
      tip = "Used whenever it is off cooldown in a fight." },
    { "Riposte",                "damage", on = true, melee = true },
    { "Ghostly Strike",         "damage", on = true, melee = true },
    { "Mutilate",               "damage", on = true, melee = true },
    { "Hemorrhage",             "damage", on = true, melee = true },
    -- 3.1.0: THE BUILDER - Backstab with a dagger from behind the target,
    -- else Sinister Strike (Backstab cannot be used from the front).
    { "Backstab",               "damage", on = true, melee = true,
      when = function(c) return c.dagger() and c.behind() end,
      tip = "Combo builder with a dagger in the main hand, from behind the target (Sinister Strike otherwise)." },
    { "Sinister Strike",        "damage", on = true, melee = true,
      tip = "Combo builder (from the front, or without a dagger)." },
})

-- ============================================================================
-- PRIEST
-- ============================================================================
local function not_shadowform(c)
    return not c.buff("Shadowform")
end

W.PRIEST = t({
    { "Power Word: Fortitude",  "buff", on = true },
    { "Inner Fire",             "buff", on = true },
    { "Divine Spirit",          "buff", on = true },
    { "Shadow Protection",      "buff", on = false },
    { "Fear Ward",              "buff", on = false },
    { "Touch of Weakness",      "buff", on = true },
    { "Shadowguard",            "buff", on = true },
    { "Shadowform",             "form", on = false, tip = "Shadow priests: blocks holy spells, so heals stop while it is up." },

    { "Power Word: Shield",     "heal", on = true, hp = 101,
      when = function(c) return c.in_combat() and c.hp() < 90 and not c.self_debuff_id(6788) end,
      tip = "Kept up in combat (not while Weakened Soul is on you)." },
    { "Flash Heal",             "heal", on = true, when = not_shadowform },
    { "Renew",                  "heal", on = true, hot = true, when = not_shadowform },
    { "Greater Heal",           "heal", on = true, when = function(c) return not_shadowform(c) and c.hp() < c.heal_pct() - 15 end },
    { "Heal",                   "heal", on = true, when = function(c) return not_shadowform(c) and c.hp() < c.heal_pct() - 15 end },
    { "Lesser Heal",            "heal", on = true, when = not_shadowform },
    { "Desperate Prayer",       "defensive", on = true },
    { "Psychic Scream",         "defensive", on = true, when = function(c) return c.near(8) >= 1 end },

    { "Silence",                "interrupt", on = true },

    { "Shadowfiend",            "resource", on = true, enemy = true, when = mana_below(50) },
    { "Shadow Word: Death",     "execute", on = true, when = function(c) return c.hp() > 40 end },

    { "Vampiric Touch",         "debuff", on = true, thp = 30 },
    { "Shadow Word: Pain",      "debuff", on = true, thp = 25 },
    { "Devouring Plague",       "debuff", on = true, thp = 30 },
    { "Vampiric Embrace",       "debuff", on = true, thp = 40 },

    { "Inner Focus",            "cooldown", on = true, self = true },

    { "Holy Nova",              "aoe", on = false, self = true, center = "self", r = 10 },

    { "Mind Blast",             "damage", on = true },
    { "Holy Fire",              "damage", on = false, when = not_shadowform },
    { "Mind Flay",              "damage", on = true },
    { "Smite",                  "damage", on = true, when = not_shadowform },
    -- Racial priest spells (2.207.0): Night Elf Starshards (channelled), Dwarf Chastise.
    { "Starshards",             "damage", on = true },
    { "Chastise",               "damage", on = false },

    -- 2.197.0: the wand, as for the mage - only with a wand equipped.
    { "Shoot",                  "filler", on = true, tip = "Wand (needs one equipped), once mana drops below the wand slider." },
})

-- ============================================================================
-- SHAMAN
-- ============================================================================
W.SHAMAN = t({
    -- 1.2.24 (Wowhead Forever shaman leveling guide, Spellhance): Water Shield (spell 408510) is the mana-efficient
    -- shield and is kept up first; Lightning Shield (10432) is the fallback until it is trained.
    -- Flametongue Weapon (16342) is the all-round strongest imbue (scales with spell power) and pairs with the
    -- Windfury Totem; Windfury Weapon (16362) is only worth it with a very slow two-hander, so it is off by default.
    { "Water Shield",           "buff", on = true,  g = "shield" },
    { "Lightning Shield",       "buff", on = true,  g = "shield" },
    { "Flametongue Weapon",     "imbue", on = true, g = "imbue", tip = "One main-hand imbue: the first ticked one you know." },
    { "Windfury Weapon",        "imbue", on = false, g = "imbue", tip = "Only worth it with a very slow two-handed weapon; Flametongue + Windfury Totem is stronger." },
    { "Frostbrand Weapon",      "imbue", on = false, g = "imbue" },
    { "Rockbiter Weapon",       "imbue", on = true, g = "imbue" },

    { "Lesser Healing Wave",    "heal", on = true },
    { "Healing Wave",           "heal", on = true },

    { "Shamanistic Rage",       "defensive", on = true },
    { "Earth Shock",            "interrupt", on = true },

    -- TOTEMS (1.76.0), by element slot (1 Fire, 2 Earth, 3 Water, 4 Air - the order of
    -- core.spell_book.get_totem_info) and PURPOSE. One totem per slot; the first entry below whose rule
    -- passes is considered by rotations/shaman.lua; situation and availability choose the slot winner,
    -- emergency -> defense in the earth slot, mana -> heal in the water slot, melee buffs in the air slot.
    -- purpose: damage (Searing), aoe (Magma, 2+ mobs), burst (Fire Nova), spell (caster buff), defense
    -- (armour / absorb, mobs on you), emergency (low health, mobs on you), mana, heal, buff (melee
    -- group buffs in melee), resist / control / utility / cleanse (opt-in combat coverage).
    { "Searing Totem",          "totem", on = true,  slot = 1, purpose = "damage", recast = 50,
      tip = "Fire slot: Searing Totem at the start of a fight worth it (not trivial), target within 25 yd, not while moving." },
    { "Magma Totem",            "totem", on = true,  slot = 1, purpose = "aoe", recast = 20,
      tip = "Fire slot: 2 or more enemies within 8 yd." },
    { "Totem of Wrath",         "totem", on = true,  slot = 1, purpose = "spell", recast = 110 },
    { "Flametongue Totem",      "totem", on = false, slot = 1, purpose = "spell", recast = 110,
      tip = "Fire slot: spell power for casters in a fight worth it. Off by default: Searing is better for solo leveling." },
    { "Fire Nova Totem",        "totem", on = true,  slot = 1, purpose = "burst", recast = 15,
      tip = "Fire slot: dropped first at the start of a fight (it explodes after a few seconds), and later when 3 or more enemies are within 8 yd. Not while a crowd-controlled enemy is near." },
    { "Frost Resistance Totem", "totem", on = false, slot = 1, purpose = "resist" },
    { "Stoneclaw Totem",        "totem", on = true,  slot = 2, purpose = "emergency", recast = 20,
      tip = "Earth slot: health below 45% with an enemy on you - it taunts and absorbs damage." },
    { "Stoneskin Totem",        "totem", on = true,  slot = 2, purpose = "defense", recast = 110,
      tip = "Earth slot: armour while enemies hit you (melee range) in a fight worth it." },
    { "Strength of Earth Totem","totem", on = true,  slot = 2, purpose = "buff", recast = 110,
      tip = "Earth slot: strength - enemy in melee range." },
    { "Earthbind Totem",        "totem", on = true, slot = 2, purpose = "control",
      tip = "Earth slot: dropped at the start of a fight (target within 25 yd, not already slowed or immune), and as a caster defense below 60% health. Preserves a live utility totem." },
    { "Tremor Totem",           "totem", on = false, slot = 2, purpose = "utility" },
    { "Mana Tide Totem",        "totem", on = true,  slot = 3, purpose = "mana_emergency", recast = 120,
      tip = "Water slot: mana below 25% in a fight (Restoration talent)." },
    { "Healing Stream Totem",   "totem", on = true,  slot = 3, purpose = "heal", recast = 60,
      tip = "Water slot: health at or below 70% with an enemy on you." },
    { "Mana Spring Totem",      "totem", on = true,  slot = 3, purpose = "mana", recast = 110,
      tip = "Water slot: mana at or below 65% in a fight worth it." },
    { "Poison Cleansing Totem", "totem", on = false, slot = 3, purpose = "cleanse" },
    { "Disease Cleansing Totem","totem", on = false, slot = 3, purpose = "cleanse" },
    { "Fire Resistance Totem",  "totem", on = false, slot = 3, purpose = "resist" },
    { "Windfury Totem",         "totem", on = true,  slot = 4, purpose = "buff", recast = 110,
      tip = "Air slot: Windfury - enemy in melee range." },
    { "Grace of Air Totem",     "totem", on = true,  slot = 4, purpose = "buff", recast = 110,
      tip = "Air slot: agility - enemy in melee range." },
    { "Wrath of Air Totem",     "totem", on = true,  slot = 4, purpose = "spell", recast = 110 },
    { "Grounding Totem",        "totem", on = false, slot = 4, purpose = "control" },
    { "Nature Resistance Totem","totem", on = false, slot = 4, purpose = "resist" },
    { "Windwall Totem",         "totem", on = false, slot = 4, purpose = "utility" },
    { "Sentry Totem",           "totem", on = false, slot = 4, purpose = "utility" },
    { "Tranquil Air Totem",     "totem", on = false, slot = 4, purpose = "utility" },

    { "Flame Shock",            "debuff", on = true, thp = 5 },

    { "Elemental Mastery",      "cooldown", on = true, self = true },
    { "Bloodlust",              "cooldown", on = false, self = true },
    { "Heroism",                "cooldown", on = false, self = true },

    { "Chain Lightning",        "aoe", on = true, n = 2, when = function(c) return c.elemental() or c.dist() > c.melee_yards() end },
    -- Fire Nova uses the single slot-aware totem entry above on clients where it is a totem (TBC). 1.2.24: WoW Forever has it
    -- as a SPELL named "Fire Nova" (408345) that explodes from the Fire totem you have out, so it needs a fire totem standing,
    -- and an enemy next to you. It was listed under "Other known spells" and never cast. The opening Searing Totem comes first.
    { "Fire Nova",              "damage", on = true, when = function(c)
        local ok, info = pcall(function() return core.spell_book.get_totem_info(1) end)
        if not ok or type(info) ~= "table" or info.have_totem ~= true then return false end
        local near = c.near(8)
        return near >= 3 or (near >= 1 and c.mana() >= 45)
    end, tip = "Forever: needs a Fire totem out (Searing / Magma) and an enemy within 8 yd; 45% mana, or 3 enemies." },

    -- Elemental keeps casting lightning even in melee; other builds retain
    -- their existing close-range damage selection.
    -- 1.2.23 DPS: Lightning Bolt is also the filler in melee range with mana to spare (40 %+) - the log showed "nothing cast"
    -- gaps of 3-5 s next to a mob whenever Earth Shock was on its cooldown.
    -- 1.2.56 (user 2026-11-19): in melee the instants (Earth Shock, Flame Shock) and the weapon swings do the work; a 2 s
    -- Lightning Bolt next to a bruiser stops the swings and the log showed 50 bolts, many at 3-4 yd. Lightning Bolt is cast at
    -- 10+ yd, at a caster (a mana user / one that is casting) and at a fleeing target (shoot it, then chase and melee).
    { "Lightning Bolt",         "damage", on = true, when = function(c)
        local fleeing = c.tfleeing()
        return c.elemental() or c.dist() >= 10 or fleeing == true or c.tcaster() == true
    end },
    { "Stormstrike",            "damage", on = true, melee = true,
      tip = "Melee only, once the mob has closed inside the melee distance." },
    { "Earth Shock",            "damage", on = true, when = function(c) return c.elemental() or c.dist() < 10 end },   -- 1.2.56: the instant fills 0-10 yd, Lightning Bolt 10+
    { "Frost Shock",            "damage", on = false, elemental_on = true, when = function(c) return c.elemental() or c.dist() <= c.melee_yards() end },
})

-- ============================================================================
-- MAGE
-- ============================================================================
local function target_frozen(c)
    return c.tdebuff_any({ 122, 865, 6131, 10230, 27088, 12494, 33395 })
end

W.MAGE = t({
    { "Molten Armor",           "buff", on = false, g = "armor", tip = "One armor at a time: the first ticked one you know." },
    { "Mage Armor",             "buff", on = false, g = "armor" },
    { "Ice Armor",              "buff", on = true,  g = "armor" },
    { "Frost Armor",            "buff", on = true,  g = "armor" },
    { "Arcane Intellect",       "buff", on = true },
    { "Ice Barrier",            "buff", on = true },

    { "Summon Water Elemental", "cooldown", on = true, self = true },

    { "Mana Shield",            "defensive", on = false, when = function(c) return c.mana() > 30 end },
    { "Ice Block",              "defensive", on = false, hp = 15 },

    { "Counterspell",           "interrupt", on = true },

    { "Evocation",              "resource", on = true, self = true,
      when = function(c) return c.mana() < 15 and c.near(10) == 0 end },

    { "Frost Nova",             "control", on = true, self = true,
      when = function(c) return c.near(6) >= 1 end,
      tip = "When an enemy is within 6 yards - then the mage backs off for 2.5 seconds." },
    -- 1.8.5 (user): ticked -> the highest rank the character owns (the spellbook
    -- rebinds every entry to its best rank) whenever the target is within 8 yd
    -- AND in the cone in front of the player (c.facing: spell_helper:
    -- is_spell_within_angle). A self-centred cone: cast on the player, like
    -- Frost Nova. "control" runs in combat ahead of the adaptive damage order.
    -- 1.20.2 (user): Cone of Cold (10161 = rank 6, the highest owned rank is cast) whenever
    -- it is known and off the GCD / its 10 s cooldown (smart's cast gate), the target within
    -- 10 yd and in the 90 degree arc in front of the player. On by default.
    { "Cone of Cold",           "control", on = true, self = true, cone = true, angle = 90,
      when = function(c) return c.dist() <= 10 and c.facing(120, 45) end,
      tip = "When the target is within 10 yards and in the 90 degree arc in front of you." },
    { "Blast Wave",             "aoe", on = true, self = true, center = "self", r = 8, n = 2 },
    { "Dragon's Breath",        "aoe", on = true, center = "self", r = 8, n = 2, cone = true, angle = 60 },
    { "Arcane Explosion",       "aoe", on = true, self = true, center = "self", r = 10 },
    -- 1.7.25: cast by rotations/mage.lua (mage.aoe) - 3+ enemies, predicted spot
    { "Blizzard",               "aoe", on = false, ground = true, r = 8, n = 3, module = true,   -- 1.9.2: 8 yd radius
      tip = "3 or more enemies: cast where spell prediction hits the most (3+)." },
    { "Flamestrike",            "aoe", on = false, ground = true },

    -- 1.7.12 (user): ticked -> whenever it is off cooldown in combat (not only
    -- at a fresh target or 2+ enemies, the cooldown role's rule)
    { "Icy Veins",              "cooldown", on = true, self = true, any_time = true,
      when = function(c) return c.in_combat() and not c.buff("Icy Veins") end,
      tip = "Whenever it is off cooldown in combat." },
    { "Arcane Power",           "cooldown", on = false, self = true },
    { "Presence of Mind",       "cooldown", on = true, self = true },
    { "Combustion",             "cooldown", on = true, self = true },
    -- 1.7.12 (user): ticked -> off cooldown and NEEDED: it resets the Frost
    -- cooldowns, so only when one the rotation wants is down - Icy Veins (ticked,
    -- learned, not up, 20+ s left), Frost Nova with an enemy within 6 yd, or
    -- Ice Barrier (not up) below 40 % health
    { "Cold Snap",              "cooldown", on = false, self = true, any_time = true,
      when = function(c)
          if not c.in_combat() then return false end
          if c.ticked("Icy Veins", true) and c.known("Icy Veins") and not c.buff("Icy Veins")
              and c.cd_left("Icy Veins") > 20 then return true end
          if c.ticked("Frost Nova", true) and c.near(6) >= 1 and c.cd_left("Frost Nova") > 3 then return true end
          if c.hp() < 40 and c.known("Ice Barrier") and not c.buff("Ice Barrier")
              and c.cd_left("Ice Barrier") > 3 then return true end
          return false
      end,
      tip = "Only when needed: Icy Veins is on cooldown, Frost Nova is on cooldown with an enemy in melee, or Ice Barrier is on cooldown below 40% health." },

    { "Ice Lance",              "damage", on = true, when = target_frozen, tip = "Only on a frozen target." },
    { "Fire Blast",             "damage", on = true },
    { "Frostbolt",              "damage", on = true },
    { "Fireball",               "damage", on = true },
    { "Arcane Blast",           "damage", on = false },
    { "Arcane Missiles",        "damage", on = false },
    { "Scorch",                 "damage", on = false },
    { "Pyroblast",              "damage", on = false },

    { "Shoot",                  "filler", on = true, tip = "Wand (needs one equipped), once mana drops below the wand slider." },
})

-- ============================================================================
-- WARLOCK
-- ============================================================================
W.WARLOCK = t({
    { "Fel Armor",              "buff", on = true, g = "armor", tip = "One armor at a time: the first ticked one you know." },
    { "Demon Armor",            "buff", on = true, g = "armor" },
    { "Demon Skin",             "buff", on = true, g = "armor" },

    { "Summon Felguard",        "pet", on = true,  g = "pet", tip = "One demon: the first ticked one you know." },
    { "Summon Voidwalker",      "pet", on = true,  g = "pet" },
    { "Summon Felhunter",       "pet", on = false, g = "pet" },
    { "Summon Succubus",        "pet", on = false, g = "pet" },
    { "Summon Imp",             "pet", on = true,  g = "pet" },
    { "Health Funnel",          "petheal", on = true },

    { "Drain Life",             "heal", on = true, enemy = true },
    { "Death Coil",             "defensive", on = true, enemy = true },
    { "Howl of Terror",         "defensive", on = false, when = function(c) return c.near(10) >= 2 end },

    { "Spell Lock",             "interrupt", on = true },

    { "Life Tap",               "resource", on = true, self = true,
      when = function(c) return c.mana() < 40 and c.hp() > 60 end },
    { "Dark Pact",              "resource", on = false, self = true, when = mana_below(40) },

    { "Shadowburn",             "execute", on = true },
    { "Drain Soul",             "execute", on = false, thp = 25 },

    { "Curse of Agony",         "debuff", on = true,  g = "curse", thp = 40 },
    -- WoW Forever names (2.207.0, RXPGuides DB/forever/spells.lua): Curse of
    -- Agony / Doom became Bane of Agony / Doom - a group of their own, so a
    -- bane and a curse can both be up.
    { "Bane of Agony",          "debuff", on = true,  g = "bane", thp = 40 },
    { "Bane of Doom",           "debuff", on = false, g = "bane", thp = 60 },
    { "Curse of the Elements",  "debuff", on = false, g = "curse" },
    { "Curse of Recklessness",  "debuff", on = false, g = "curse" },
    { "Curse of Weakness",      "debuff", on = false, g = "curse" },
    { "Curse of Tongues",       "debuff", on = false, g = "curse" },
    { "Curse of Doom",          "debuff", on = false, g = "curse", thp = 60 },
    { "Unstable Affliction",    "debuff", on = true, thp = 40 },
    { "Corruption",             "debuff", on = true, thp = 30 },
    { "Siphon Life",            "debuff", on = true, thp = 40 },
    { "Immolate",               "debuff", on = true, thp = 40 },

    { "Amplify Curse",          "cooldown", on = true, self = true },

    { "Seed of Corruption",     "aoe", on = true },
    { "Rain of Fire",           "aoe", on = false, ground = true },
    { "Hellfire",               "aoe", on = false, self = true, center = "self", r = 10, tip = "Burns you too." },

    { "Conflagrate",            "damage", on = true, when = function(c) return c.debuff("Immolate") end },
    { "Shadow Bolt",            "damage", on = true },
    { "Incinerate",             "damage", on = false },
    { "Searing Pain",           "damage", on = false },
    { "Soul Fire",              "damage", on = false },

    -- 2.197.0: the wand - only with a wand equipped.
    { "Shoot",                  "filler", on = true, tip = "Wand (needs one equipped), once mana drops below the wand slider." },
})

-- ============================================================================
-- DRUID
-- ============================================================================
local CASTER = { "caster", "moonkin" }

W.DRUID = t({
    { "Mark of the Wild",       "buff", on = true, form = "caster" },
    { "Thorns",                 "buff", on = true, form = "caster" },
    { "Omen of Clarity",        "buff", on = true, form = "caster" },
    { "Moonkin Form",           "form", on = false, g = "form", tip = "One form: the first ticked one. Cat and Bear are taken when a fight starts." },
    { "Tree of Life",           "form", on = false, g = "form" },
    { "Cat Form",               "form", on = false, g = "form" },
    { "Dire Bear Form",         "form", on = false, g = "form" },
    { "Bear Form",              "form", on = false, g = "form" },

    { "Regrowth",               "heal", on = true, form = { "caster", "tree" }, hot = true },
    { "Rejuvenation",           "heal", on = true, form = { "caster", "tree" }, hot = true },
    { "Lifebloom",              "heal", on = false, form = { "caster", "tree" }, hot = true },
    { "Swiftmend",              "heal", on = false, form = { "caster", "tree" } },
    { "Healing Touch",          "heal", on = true, form = { "caster", "tree" },
      when = function(c) return c.hp() < c.heal_pct() - 15 end },

    { "Barkskin",               "defensive", on = true },
    { "Frenzied Regeneration",  "defensive", on = true, form = "bear" },

    { "Bash",                   "interrupt", on = true, melee = true, form = "bear" },

    { "Innervate",              "resource", on = true, self = true, when = mana_below(20) },
    { "Enrage",                 "resource", on = true, self = true, form = "bear", when = function(c) return c.rage() < 20 end },

    { "Faerie Fire (Feral)",    "debuff", on = true, form = { "cat", "bear" } },
    { "Faerie Fire",            "debuff", on = false, form = CASTER },
    { "Moonfire",               "debuff", on = true, form = CASTER, thp = 30 },
    { "Insect Swarm",           "debuff", on = true, form = CASTER, thp = 40 },
    { "Demoralizing Roar",      "debuff", on = true, self = true, form = "bear", when = function(c) return c.near(10) >= 1 end },
    { "Rake",                   "debuff", on = true, melee = true, form = "cat", thp = 40 },
    { "Lacerate",               "debuff", on = true, melee = true, form = "bear" },

    { "Tiger's Fury",           "cooldown", on = true, self = true, form = "cat" },

    { "Swipe",                  "aoe", on = true, melee = true, form = "bear", n = 2, r = 8 },
    { "Hurricane",              "aoe", on = false, ground = true, form = CASTER },

    { "Rip",                    "finisher", on = true, melee = true, form = "cat", cp = 4, thp = 40,
      when = function(c) return not c.debuff("Rip") end },
    { "Ferocious Bite",         "finisher", on = true, melee = true, form = "cat", cp = 4 },

    { "Mangle (Cat)",           "damage", on = true, melee = true, form = "cat" },
    -- WoW Forever lists a plain "Mangle" (33982) for druids (2.207.0).
    { "Mangle",                 "damage", on = true, melee = true, form = "cat" },
    { "Shred",                  "damage", on = false, melee = true, form = "cat", tip = "Needs to be behind the target." },
    { "Claw",                   "damage", on = true, melee = true, form = "cat" },
    { "Mangle (Bear)",          "damage", on = true, melee = true, form = "bear" },
    { "Maul",                   "damage", on = true, melee = true, form = "bear", when = rage_dump(30, 15) },
    { "Starfire",               "damage", on = false, form = CASTER },
    { "Wrath",                  "damage", on = true, form = CASTER },
})

-- ============================================================================
-- DISPLAY
-- ============================================================================
-- The Spells tab groups rows by these headings, in this order.
local SECTIONS = {
    { key = "buffs",     label = "Buffs, Auras & Forms", roles = { buff = true, cbuff = true, form = true, seal = true, imbue = true, stealth = true } },
    { key = "pet",       label = "Pet",                  roles = { pet = true, petheal = true } },
    { key = "damage",    label = "Damage",               roles = { damage = true, execute = true, opener = true, finisher = true, filler = true } },
    { key = "debuff",    label = "Damage over Time & Debuffs", roles = { debuff = true } },
    -- 1.2.24: totems have their own heading (one per element slot: Fire, Earth, Water, Air), with the slot and purpose beside each.
    { key = "totem",     label = "Totems (one per element)", roles = { totem = true } },
    { key = "aoe",       label = "Area of Effect",       roles = { aoe = true, control = true, sap = true } },
    { key = "cooldown",  label = "Cooldowns & Resources", roles = { cooldown = true, resource = true } },
    { key = "heal",      label = "Healing",              roles = { heal = true } },
    { key = "defensive", label = "Defensive",            roles = { defensive = true } },
    { key = "interrupt", label = "Interrupts",           roles = { interrupt = true } },
    { key = "racial",    label = "Racial",               roles = { racial = true } },
    -- 2.242.0: spells the book has that this catalog does not list, split by
    -- what their description says they do - damage or healing. Never AoE.
    { key = "other_dps",  label = "Other DPS spells (not in the catalog)",     roles = { other_dps = true } },
    { key = "other_heal", label = "Other healing spells (not in the catalog)", roles = { other_heal = true } },
    -- 2.194.0: every other spell the book has (not in this catalog).
    { key = "other",     label = "Other known spells",   roles = { other = true } },
}

local M = {}
M.sections = SECTIONS

-- Keyed on the SDK's own class ids rather than hard-coded numbers.
local CLASS_KEY = {}
do
    local ok, enums = pcall(require, "common/enums")
    local ids = ok and type(enums) == "table" and enums.class_id or nil
    if type(ids) == "table" then
        for key in pairs(W) do
            if type(ids[key]) == "number" then
                CLASS_KEY[ids[key]] = key
            end
        end
    end
end

--- The catalog for a class id (the client's own numbering), or an empty list.
function M.for_class(class_id)
    local key = CLASS_KEY[class_id]
    return key and W[key] or {}
end

function M.class_key(class_id)
    return CLASS_KEY[class_id]
end

--- The Spells tab section a role belongs to.
function M.section_of(role)
    for i = 1, #SECTIONS do
        if SECTIONS[i].roles[role] then
            return SECTIONS[i].key
        end
    end
    return "damage"
end

return M
