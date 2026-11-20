-- ============================================================================
-- Master Farmer - Zygor Forever
-- equip.lua - auto-equip upgrades from the bags
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- Ported from the reference bot's Auto_Equip / Check_Equip.
--
-- THE MECHANISM
--   core.input.use_container_item(bag, slot) is the same call vendor.lua uses
--   to sell. With a merchant open it sells; with no merchant open the client
--   equips an equippable item. So equipping needs no new API - but it does mean
--   this must NEVER run while a vendor window is open, or it sells the upgrade
--   instead of wearing it. That guard is the first thing tick() checks.
--
-- WHAT IS DELIBERATELY DIFFERENT FROM THE SOURCE
--
--   1. Armour type is a RANGE, not one type. The source matches a single
--      armour subclass per class, so a level 12 Hunter (who cannot wear Mail
--      until 40) would never equip anything. Here a class may wear its best
--      type and everything lighter, which is how levelling actually works.
--
--   2. Rings and trinkets check BOTH slots. The source only ever looked at
--      FINGER2 and TRINKET1, so it could not fill an empty finger 1 and would
--      compare against the wrong trinket.
--
--   3. Weapons are OFF by default here. The proficiency data that was missing
--      is now supplied by CLASS_WEAPONS below, keyed on the numeric
--      subclass_id that quest_item_info exposes, and equip.usable_by applies
--      it - the quest reward picker relies on exactly that. equip.tick keeps
--      the toggle off all the same: knowing a Mage MAY hold a one-handed
--      sword does not make swapping its staff for one a good idea, and that
--      judgement needs stat weights this API still does not expose.
--
--   4. It never downgrades. See `better_than` for how the comparison degrades
--      when the API does not expose an item level.
--
--   5. It confirms the bind-on-equip prompt. Equipping a BoE item raises a
--      "this will bind to you" dialog and the equip does not complete until it
--      is answered. Without that step the bot re-issues the same equip forever
--      and never wears the upgrade. core.game_ui.get_pending_equip_slot detects
--      the prompt and core.input.equip_pending_item answers it.
--
--   6. Bags are equipped even when Auto Equip is off. An ordinary bag in the
--      bags fills an empty bag slot; a bigger one replaces the smallest
--      ordinary bag only when that bag is empty. Ammo pouches, quivers and
--      soul bags are never equipped. The destination is
--      core.inventory.get_bag_inventory_slot, passed to
--      core.input.equip_container_item.
--
--   7. 1.9.2 (Forever 1.0.20, "Auto equip bags when looted"): a looted bag
--      goes on at once - equip.bag_tick runs right after loot (main.lua, after
--      loot.tick) for BAG_LOOT_S s after every LOOT_CLOSED (events.lua's
--      stamp; without game events, the loot window's item count going to 0),
--      scanning every BAG_LOOT_GAP s instead of BAG_SCAN_GAP. A bag is known
--      by its id / name tables, or by core.quests.get_item_info's equip_loc
--      ("INVTYPE_BAG"; "INVTYPE_QUIVER" never), or - when the client gives no
--      class_id nor equip_loc - by a bag word in its name (BAG_WORDS); such a
--      "maybe" bag only ever fills an EMPTY bag slot, never replaces one, and
--      a refused equip is skipped after MAX_FAILS like any other. Mounted is
--      fine on this path only (the gear scan keeps its mounted refusal).
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local bags = require("bags")
local state = require("state")

local equip = {}

local SCAN_GAP = 10.0        -- seconds between bag scans
local ACT_GAP  = 1.5         -- seconds between equip attempts
local VERIFY_GAP = 1.5        -- seconds after an attempt before checking it took
local MAX_FAILS = 2           -- failed attempts before an item is skipped
local attempt = nil           -- { bag, slot, item_id, label, t }
local fail_count = {}         -- item id -> failed attempts
local rejected_logs = {} -- one diagnostic per item/reason, not every scan
-- 1.2.48: kept across a plugin reload (the log showed the same Barbed Club failing twice in every one of ~20 sessions):
-- the table lives in the shared namespace the reload keeps, so an item that would not equip is not tried again until the game restarts.
local failed_ids = {}         -- item id -> true: skipped until the game restarts
do
    local ns = rawget(_G, "MasterFarmer_Zygor")
    if type(ns) == "table" then
        ns.equip_failed = type(ns.equip_failed) == "table" and ns.equip_failed or {}
        failed_ids = ns.equip_failed
    end
end
local function last_client_error()
    local ok, ev = pcall(require, "events")
    if not ok or type(ev) ~= "table" or type(ev.last_ui_error) ~= "function" then return "no client error" end
    local text = ev.last_ui_error()
    return type(text) == "string" and text ~= "" and ("last client error: " .. text) or "no client error"
end
-- After any weapon-slot equip, no other for WEAPON_COOLDOWN (2.35.0): a
-- belt-and-braces stop on main-hand / off-hand oscillation.
-- 1.2.14: 8 s (was 30): a main hand and a wand are two upgrades, and the second waited half a minute
local WEAPON_COOLDOWN = 8.0
local weapon_until = 0

-- Far in the past, not 0: the first tick must be able to act regardless of what
-- izi.now() happens to be, instead of sitting out the gap once at startup.
local last_scan = -1e9
local last_act  = -1e9
local last_bag_scan = -1e9
local bag_attempt = nil
local debug_done = false

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- SLOTS
-- ----------------------------------------------------------------------------
-- Equipment slot numbering 1-19, confirmed by targeting.lua (RANGED_SLOT = 18).
local SLOT = {
    HEAD = 1, NECK = 2, SHOULDER = 3, BODY = 4, CHEST = 5, WAIST = 6,
    LEGS = 7, FEET = 8, WRIST = 9, HAND = 10, FINGER1 = 11, FINGER2 = 12,
    TRINKET1 = 13, TRINKET2 = 14, BACK = 15, MAINHAND = 16, OFFHAND = 17,
    RANGED = 18, TABARD = 19,
}

-- equip_loc -> candidate slots. More than one slot means "pick the empty one,
-- else the weaker one".
local LOC_SLOTS = {
    INVTYPE_HEAD            = { SLOT.HEAD },
    INVTYPE_NECK            = { SLOT.NECK },
    INVTYPE_SHOULDER        = { SLOT.SHOULDER },
    INVTYPE_BODY            = { SLOT.BODY },
    INVTYPE_CHEST           = { SLOT.CHEST },
    INVTYPE_ROBE            = { SLOT.CHEST },
    INVTYPE_WAIST           = { SLOT.WAIST },
    INVTYPE_LEGS            = { SLOT.LEGS },
    INVTYPE_FEET            = { SLOT.FEET },
    INVTYPE_WRIST           = { SLOT.WRIST },
    INVTYPE_HAND            = { SLOT.HAND },
    INVTYPE_FINGER          = { SLOT.FINGER1, SLOT.FINGER2 },
    INVTYPE_TRINKET         = { SLOT.TRINKET1, SLOT.TRINKET2 },
    INVTYPE_CLOAK           = { SLOT.BACK },
    INVTYPE_TABARD          = { SLOT.TABARD },
}

-- Weapon / ranged locations, gated behind the weapons toggle (see header note 3).
local WEAPON_SLOTS = {
    INVTYPE_WEAPON          = { SLOT.MAINHAND },
    INVTYPE_2HWEAPON        = { SLOT.MAINHAND },
    INVTYPE_WEAPONMAINHAND  = { SLOT.MAINHAND },
    INVTYPE_WEAPONOFFHAND   = { SLOT.OFFHAND },
    INVTYPE_SHIELD          = { SLOT.OFFHAND },
    INVTYPE_HOLDABLE        = { SLOT.OFFHAND },
    INVTYPE_RANGED          = { SLOT.RANGED },
    INVTYPE_RANGEDRIGHT     = { SLOT.RANGED },
    INVTYPE_THROWN          = { SLOT.RANGED },
}

-- ----------------------------------------------------------------------------
-- ARMOUR
-- ----------------------------------------------------------------------------
-- Heaviest armour each class may wear. A class may also wear everything
-- lighter, which is what makes levelling work - see header note 1.
local ARMOUR_RANK = { cloth = 1, leather = 2, mail = 3, plate = 4 }

local CLASS_ARMOUR = {
    [enums.class_id.MAGE]    = 1,
    [enums.class_id.WARLOCK] = 1,
    [enums.class_id.PRIEST]  = 1,
    [enums.class_id.ROGUE]   = 2,
    [enums.class_id.DRUID]   = 2,
    [enums.class_id.HUNTER]  = 3,
    [enums.class_id.SHAMAN]  = 3,
    [enums.class_id.WARRIOR] = 4,
    [enums.class_id.PALADIN] = 4,
}

-- ----------------------------------------------------------------------------
-- NUMERIC ITEM CLASSES
-- ----------------------------------------------------------------------------
-- quest_item_info carries class_id / subclass_id, which are numbers and so
-- survive a non-English client. item_sub_type is a localised string and only
-- works on an English one, so the numeric path is tried first everywhere below.
local ITEM_CLASS = { ARMOR = 4, WEAPON = 2 }

local ARMOR_SUB = { MISC = 0, CLOTH = 1, LEATHER = 2, MAIL = 3, PLATE = 4,
                    SHIELD = 6, LIBRAM = 7, IDOL = 8, TOTEM = 9 }

local ARMOUR_RANK_BY_SUB = {
    [ARMOR_SUB.CLOTH] = 1, [ARMOR_SUB.LEATHER] = 2,
    [ARMOR_SUB.MAIL] = 3, [ARMOR_SUB.PLATE] = 4,
}

local W = { AXE1 = 0, AXE2 = 1, BOW = 2, GUN = 3, MACE1 = 4, MACE2 = 5,
            POLEARM = 6, SWORD1 = 7, SWORD2 = 8, STAFF = 10, FIST = 13,
            MISC = 14, DAGGER = 15, THROWN = 16, CROSSBOW = 18, WAND = 19,
            FISHING = 20 }

-- What each class may train in TBC, ignoring talents. Closes header note 3:
-- the proficiency data the API does not expose is static and well known, so a
-- table is the honest way to supply it rather than guessing from the name.
local CLASS_WEAPONS = {
    [enums.class_id.WARRIOR] = { [W.AXE1]=1,[W.AXE2]=1,[W.MACE1]=1,[W.MACE2]=1,[W.SWORD1]=1,[W.SWORD2]=1,
                                 [W.POLEARM]=1,[W.STAFF]=1,[W.DAGGER]=1,[W.FIST]=1,
                                 [W.BOW]=1,[W.GUN]=1,[W.CROSSBOW]=1,[W.THROWN]=1 },
    [enums.class_id.PALADIN] = { [W.AXE1]=1,[W.AXE2]=1,[W.MACE1]=1,[W.MACE2]=1,[W.SWORD1]=1,[W.SWORD2]=1,
                                 [W.POLEARM]=1 },
    [enums.class_id.HUNTER]  = { [W.AXE1]=1,[W.AXE2]=1,[W.SWORD1]=1,[W.SWORD2]=1,[W.POLEARM]=1,
                                 [W.STAFF]=1,[W.DAGGER]=1,[W.FIST]=1,
                                 [W.BOW]=1,[W.GUN]=1,[W.CROSSBOW]=1,[W.THROWN]=1 },
    [enums.class_id.ROGUE]   = { [W.DAGGER]=1,[W.SWORD1]=1,[W.MACE1]=1,[W.FIST]=1,[W.AXE1]=1,
                                 [W.BOW]=1,[W.GUN]=1,[W.CROSSBOW]=1,[W.THROWN]=1 },
    [enums.class_id.PRIEST]  = { [W.MACE1]=1,[W.DAGGER]=1,[W.STAFF]=1,[W.WAND]=1 },
    [enums.class_id.SHAMAN]  = { [W.AXE1]=1,[W.AXE2]=1,[W.MACE1]=1,[W.MACE2]=1,[W.STAFF]=1,
                                 [W.DAGGER]=1,[W.FIST]=1 },
    [enums.class_id.MAGE]    = { [W.SWORD1]=1,[W.DAGGER]=1,[W.STAFF]=1,[W.WAND]=1 },
    [enums.class_id.WARLOCK] = { [W.SWORD1]=1,[W.DAGGER]=1,[W.STAFF]=1,[W.WAND]=1 },
    [enums.class_id.DRUID]   = { [W.MACE1]=1,[W.MACE2]=1,[W.STAFF]=1,[W.DAGGER]=1,[W.FIST]=1,[W.POLEARM]=1 },
}

-- Shields, and the class-specific relic subclasses.
local CLASS_SHIELD = {
    [enums.class_id.WARRIOR] = true, [enums.class_id.PALADIN] = true,
    [enums.class_id.SHAMAN]  = true,
}
local CLASS_RELIC = {
    [enums.class_id.PALADIN] = ARMOR_SUB.LIBRAM,
    [enums.class_id.DRUID]   = ARMOR_SUB.IDOL,
    [enums.class_id.SHAMAN]  = ARMOR_SUB.TOTEM,
}

-- Classes that move up an armour weight at MAIL_LEVEL (2.34.0): in TBC a
-- Warrior or Paladin wears mail below 40 and learns plate at 40, and a Hunter
-- or Shaman wears leather below 40 and learns mail at 40. CLASS_ARMOUR is the
-- level-40 cap; below it these classes are one rank lower.
local MAIL_LEVEL = 40
local ARMOUR_STEP_AT_40 = {
    [enums.class_id.WARRIOR] = true, [enums.class_id.PALADIN] = true,
    [enums.class_id.HUNTER]  = true, [enums.class_id.SHAMAN]  = true,
}

--- Heaviest armour rank this class may wear at this level.
local function max_armour_for(class_id, level)
    local cap = CLASS_ARMOUR[class_id]
    if not cap then
        return nil
    end
    if ARMOUR_STEP_AT_40[class_id] and type(level) == "number" and level < MAIL_LEVEL then
        return cap - 1
    end
    return cap
end

--- Armour rank of an item, or nil when it is not armour we gate on.
--- Numeric subclass first, localised name only as a fallback.
local function armour_rank(info)
    if type(info.class_id) == "number" and info.class_id == ITEM_CLASS.ARMOR
        and type(info.subclass_id) == "number" then
        return ARMOUR_RANK_BY_SUB[info.subclass_id]
    end
    local sub = info.item_sub_type
    if type(sub) ~= "string" then
        return nil
    end
    return ARMOUR_RANK[string.lower(sub)]
end

-- ----------------------------------------------------------------------------
-- ITEM INFO
-- ----------------------------------------------------------------------------
local function item_info(item_id)
    if type(item_id) ~= "number" or item_id <= 0 then
        return nil
    end
    local info = safe(function() return core.quests.get_item_info(item_id) end)
    if type(info) ~= "table" then
        return nil
    end
    return info
end

--- Item level, if this build exposes it under any of the plausible names.
--- Returns nil when unavailable, which downgrades the comparison - see
--- `better_than`. Guessing a field name that does not exist would read nil and
--- silently compare nothing, so every candidate is checked explicitly.
local function item_level(info)
    local v = info.item_level or info.level or info.ilvl or info.item_lvl
    if type(v) == "number" and v > 0 then
        return v
    end
    return nil
end

local function required_level(info)
    local v = info.required_level or info.req_level or info.min_level
    if type(v) == "number" then
        return v
    end
    return nil
end

local function quality_of(info)
    local q = info.quality
    if type(q) == "number" then
        return q
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- COMPARISON
-- ----------------------------------------------------------------------------
--- Is `cand` a real upgrade over `cur`? `cur` nil means the slot is empty.
---
--- When the API exposes an item level this mirrors the source's rules: higher
--- level at no worse quality, or higher quality at no worse level, or a level
--- gap wide enough to outweigh a quality drop.
---
--- When it does NOT expose one, the only safe move is to fill empty slots and
--- to replace strictly on quality. Anything else risks swapping a good item for
--- a worse one every ten seconds, which is far more damaging than equipping
--- nothing at all.
local function better_than(cand, cur)
    if not cur then
        return true, "empty slot"
    end

    local cq, uq = quality_of(cand), quality_of(cur)
    local cl, ul = item_level(cand), item_level(cur)

    if not cl or not ul then
        if cq and uq and cq > uq then
            return true, "better quality (no item level available)"
        end
        return false
    end

    if cl > ul and (not cq or not uq or cq >= uq) then
        return true, "higher item level"
    end
    if cq and uq and cq > uq and cl >= ul then
        return true, "better quality"
    end
    if (cl - ul) >= 3 and cq and cq >= 1 then
        return true, "item level gap >= 3"
    end
    if (cl - ul) >= 5 then
        return true, "item level gap >= 5"
    end
    return false
end

-- ----------------------------------------------------------------------------
-- EQUIPPED STATE
-- ----------------------------------------------------------------------------
local function equipped_info(player, slot)
    local at = safe(function() return player:get_item_at_inventory_slot(slot) end)
    if type(at) ~= "table" or not at.object then
        return nil
    end
    local id = safe(function() return at.object:get_item_id() end)
    if type(id) ~= "number" or id <= 0 then
        return nil
    end
    return item_info(id)
end

--- equip_loc of whatever is worn in `slot`, or nil when the slot is empty.
local function equipped_loc(player, slot)
    local info = equipped_info(player, slot)
    return info and info.equip_loc or nil
end

local OFFHAND_LOCS = {
    INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true, INVTYPE_WEAPONOFFHAND = true,
}
local WEAPON_SLOT_SET = { [SLOT.MAINHAND] = true, [SLOT.OFFHAND] = true, [SLOT.RANGED] = true }

--- Would equipping an item of `loc` make the game swap another hand out?
---
--- A shield / off-hand / held item unequips a worn two-hander, and a
--- two-hander unequips whatever is in the off-hand. find_upgrade judged each
--- slot on its own, so it equipped a shield (two-hander goes to the bags),
--- then saw an empty main hand and equipped the two-hander (shield goes to
--- the bags), and so on - the swap the 21:20 crash happened on.
local function hands_conflict(player, loc)
    if OFFHAND_LOCS[loc] then
        return equipped_loc(player, SLOT.MAINHAND) == "INVTYPE_2HWEAPON"
    end
    if loc == "INVTYPE_2HWEAPON" then
        return equipped_info(player, SLOT.OFFHAND) ~= nil
    end
    return false
end

-- 1.8.0 TBC ITEM SCORE: Zygor's stat-weight score (equip_tbc.lua) decides an
-- upgrade, a slot and a quest reward when the client is TBC and both items'
-- tooltips can be read; otherwise the item-level rule below stands.
local tbc_scorer_mod = nil
function equip.tbc_scorer()
    if tbc_scorer_mod == nil then
        tbc_scorer_mod = false
        local okg, gv = pcall(require, "gamever")
        if okg and type(gv) == "table" and type(gv.is_tbc) == "function" and gv.is_tbc() then
            local ok, m = pcall(require, "equip_tbc")
            if ok and type(m) == "table" then tbc_scorer_mod = m end
        end
    end
    if tbc_scorer_mod and tbc_scorer_mod.available() then return tbc_scorer_mod end
    return nil
end
-- audit P7: the worn item's link is read once per slot per update, not once
-- per candidate
local slot_link_memo = { t = nil, links = {} }
local function slot_link(slot)
    local t = safe(function() return izi.now() end)
    if slot_link_memo.t ~= t then slot_link_memo.t, slot_link_memo.links = t, {} end
    local l = slot_link_memo.links[slot]
    if l == nil then
        l = safe(function() return core.inventory.get_inventory_item_link(slot) end) or false
        slot_link_memo.links[slot] = l
    end
    return l or nil
end
-- 1.8.0 (Item-Upgrades.lua 105-106, 340-341: a guide "equipped" item scores
-- 999999): the item a Zygor equip step put on is never swapped out
local function quest_worn(player, slot)
    local qid = state.quest_equip_id
    if not qid then return false end
    local at = safe(function() return player:get_item_at_inventory_slot(slot) end)
    local id = type(at) == "table" and at.object and safe(function() return at.object:get_item_id() end) or nil
    return id == qid
end

--- Best target slot for a candidate: an empty one if there is any, otherwise
--- the one holding the weakest item (1.8.0 TBC: the lowest Zygor score).
local function pick_slot(player, slots)
    local sc = equip.tbc_scorer()
    if sc and #slots > 1 then
        local low_slot, low = nil, nil
        for i = 1, #slots do
            local s = slots[i]
            if not equipped_info(player, s) then return s, nil end
            if not quest_worn(player, s) then
                local v = sc.link_score(player, slot_link(s), true)
                if v == nil then low_slot = nil break end
                if low == nil or v < low then low_slot, low = s, v end
            end
        end
        if low_slot then return low_slot, equipped_info(player, low_slot) end
    end
    local weakest_slot, weakest_info = nil, nil
    for i = 1, #slots do
        local s = slots[i]
        local cur = equipped_info(player, s)
        if not cur then
            return s, nil
        end
        if not weakest_slot then
            weakest_slot, weakest_info = s, cur
        else
            local swap = better_than(weakest_info, cur)
            if swap then
                weakest_slot, weakest_info = s, cur
            end
        end
    end
    return weakest_slot, weakest_info
end

-- ----------------------------------------------------------------------------
-- DIAGNOSTIC
-- ----------------------------------------------------------------------------
-- The comparison quality depends entirely on whether get_item_info exposes an
-- item level. This prints the real keys of one item's info table, once, so that
-- can be established instead of guessed.
local function debug_dump(info, item_id)
    if debug_done or not require("actlog").verbose() then
        return
    end
    debug_done = true
    -- 1.75.0: one action-log event with the field names and types (was 25 console lines on every Start)
    local fields = {}
    for k, v in pairs(info) do
        local ty = type(v)
        fields[tostring(k)] = (ty == "string" or ty == "number" or ty == "boolean") and v or ty
    end
    require("actlog").event("equip", "item_info_fields", "get_item_info(" .. tostring(item_id) .. ")",
        { item_id = item_id, fields = fields, level_readable = item_level(info) and true or false })
end

-- ----------------------------------------------------------------------------
-- SCAN
-- ----------------------------------------------------------------------------
--- Find the first genuine upgrade in the bags.
--- Returns bag, slot, label, item_id - bag / slot as use_container_item takes
--- them (bags.lua), never the raw get_items_in_bag slot_id.
---
--- Every candidate must pass equip.usable_by: armour weight for the class AND
--- level, weapon type, shield, relic, required level. find_upgrade used to gate
--- armour weight only.
-- ----------------------------------------------------------------------------
-- PROFESSION TOOLS ARE NOT WEAPONS (1.76.0)
-- ----------------------------------------------------------------------------
-- A Mining Pick, Skinning Knife, Blacksmith Hammer, Arclight Spanner or fishing pole is classed as a
-- weapon by the client and carries an equip location, so a class that may use the weapon type (and any
-- empty weapon slot) saw it as an upgrade: "Attempting to equip Mining Pick as weapon". They are never
-- worn by the auto-equip, and the quest reward picker rates them as not equippable. Matched by name
-- (what the client reports) and by the ids of the well-known ones.
local TOOL_NAMES = { "mining pick", "skinning knife", "blacksmith hammer", "arclight spanner", "fishing pole",
    "angler fc", "jeweler's kit", "runed copper rod" }
local TOOL_IDS = { [2901] = true, [7005] = true, [5956] = true, [6219] = true, [6256] = true, [6365] = true,
    [6366] = true, [6367] = true, [19022] = true, [19970] = true }

--- True for a profession tool that must never be equipped as a weapon.
function equip.is_tool(info, item_id)
    if tonumber(item_id) and TOOL_IDS[tonumber(item_id)] then return true end
    local id = type(info) == "table" and tonumber(info.item_id or info.id) or nil
    if id and TOOL_IDS[id] then return true end
    local name = type(info) == "table" and type(info.name) == "string" and info.name:lower() or nil
    if name then
        for i = 1, #TOOL_NAMES do
            if name:find(TOOL_NAMES[i], 1, true) then return true end
        end
    end
    return false
end

local function find_upgrade(player)
    local allow_weapons = gui.is_on("equip_weapons")
    local list = bags.list(player)
    for i = 1, #list do
        local entry = list[i]
        local item_id = entry.item_id
        if item_id and not failed_ids[item_id] and not TOOL_IDS[item_id] then
            local info = item_info(item_id)
            if info and not equip.is_tool(info, item_id) then
                debug_dump(info, item_id)
                local loc = info.equip_loc
                local slots = nil
                if type(loc) == "string" then
                    slots = LOC_SLOTS[loc]
                    if not slots and allow_weapons then
                        slots = WEAPON_SLOTS[loc]
                    end
                end
                local weapon_slot = slots and WEAPON_SLOT_SET[slots[1]] == true
                if slots and weapon_slot and (izi.now() < weapon_until or hands_conflict(player, loc)) then
                    slots = nil
                end
                if slots then
                    local usable, _, why_not = equip.usable_by(player, info)
                    if usable then
                        local red = equip.tooltip_block(entry.bag, entry.slot)
                        if red then usable, why_not = false, "tooltip: " .. red end
                    end
                    if usable then
                        local slot, cur = pick_slot(player, slots)
                        if slot and quest_worn(player, slot) then slot = nil end     -- 1.8.0
                        if slot then
                            local ok, why = better_than(info, cur)
                            local sc = equip.tbc_scorer()
                            if sc then
                                local d = sc.delta(player,
                                    safe(function() return core.inventory.get_container_item_link(entry.bag, entry.slot) end),
                                    cur and slot_link(slot) or nil)
                                if d ~= nil then ok, why = d > 0, string.format("Zygor stat score %+.1f", d) end
                            end
                            if ok then
                                local name = info.name or ("item " .. tostring(item_id))
                                return entry.bag, entry.slot, name .. " (" .. tostring(why) .. ")", item_id, weapon_slot
                            elseif weapon_slot then
                                -- 1.2.14: a usable weapon that is NOT an upgrade says so once (item level / quality of both)
                                local key = tostring(item_id) .. ">" .. tostring(cur and (cur.item_id or cur.name) or "-")
                                if rejected_logs[key] == nil then
                                    rejected_logs[key] = true
                                    require("actlog").event("equip", "keep", string.format("%s kept out: not better than %s",
                                        tostring(info.name or item_id), tostring(cur and cur.name or "the empty slot")),
                                        { item_id = item_id, cand_ilvl = item_level(info), cand_q = quality_of(info),
                                          cur_ilvl = cur and item_level(cur) or nil, cur_q = cur and quality_of(cur) or nil, slot = slot })
                                end
                            end
                        end
                    elseif rejected_logs[item_id] ~= why_not then
                        rejected_logs[item_id] = why_not
                        -- an action-log event, once per item and reason (no console line)
                        require("actlog").event("equip", "skip", string.format("%s: %s",
                            tostring(info.name or item_id), tostring(why_not)), { item_id = item_id })
                    end
                end
            end
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- BAGS (always, not gated by Auto Equip)
-- ----------------------------------------------------------------------------
-- Classic / TBC ordinary bags. Slot counts are the classic ones (a later
-- expansion changed a few quest bags). Ammo, quivers, soul bags and
-- profession bags are absent on purpose.
local BAG_SIZE = {
    [805] = 6, [828] = 6, [4496] = 6, [5571] = 6, [5572] = 6,
    [4238] = 6, [5762] = 6, [5081] = 6, [4957] = 6, [6756] = 6,
    [11845] = 4, [23389] = 4, [20474] = 4, [22976] = 4, [23852] = 6,
    [856] = 8, [2657] = 8, [3233] = 8, [4240] = 8, [4241] = 8,
    [4498] = 8, [5573] = 8, [5574] = 8, [5763] = 8,
    [857] = 10, [932] = 10, [933] = 10, [1470] = 10, [4245] = 10,
    [4497] = 10, [5575] = 10, [5576] = 10, [5764] = 10, [5765] = 10,
    [6446] = 10,
    [1725] = 12, [4499] = 12, [10050] = 12, [10051] = 12, [19291] = 12,
    [1685] = 14, [3914] = 14, [9587] = 14, [11324] = 14, [14046] = 14,
    [30744] = 14,
    [4500] = 16, [14155] = 16, [20400] = 16, [21841] = 16,
    [17966] = 18, [21843] = 18, [27680] = 18, [33117] = 18,
    [21876] = 20, [34067] = 20, [34845] = 20, [35516] = 20,
    [38082] = 22,
}
local BAG_NAME = {
    ["small brown pouch"] = 6, ["small red pouch"] = 6, ["small blue pouch"] = 6,
    ["small black pouch"] = 6, ["small green pouch"] = 6, ["linen bag"] = 6,
    ["red linen bag"] = 6, ["kodo hide bag"] = 6, ["old moneybag"] = 6,
    ["jewelry box"] = 6, ["nolkai's bag"] = 6, ["handmade leather bag"] = 4,
    ["empty draenei supply pouch"] = 4, ["sunstrider book satchel"] = 4,
    ["magister's pouch"] = 4, ["brown leather satchel"] = 8, ["woolen bag"] = 8,
    ["green woolen bag"] = 8, ["red woolen bag"] = 8, ["blue leather bag"] = 8,
    ["red leather bag"] = 8, ["green leather bag"] = 8, ["white leather bag"] = 8,
    ["gnoll hide sack"] = 8, ["heavy brown bag"] = 10, ["small silk pack"] = 10,
    ["green silk pack"] = 10, ["black silk pack"] = 10, ["large red sack"] = 10,
    ["large green sack"] = 10, ["large brown sack"] = 10, ["murloc skin bag"] = 10,
    ["large rucksack"] = 10, ["fel steed saddlebags"] = 10, ["snakeskin bag"] = 10,
    ["huge brown sack"] = 12, ["large knapsack"] = 12, ["mageweave bag"] = 12,
    ["red mageweave bag"] = 12, ["darkmoon storage box"] = 12,
    ["journeyman's backpack"] = 14, ["runecloth bag"] = 14, ["troll-hide bag"] = 14,
    ["explorer's knapsack"] = 14, ["thawpelt sack"] = 14, ["draenic leather pack"] = 14,
    ["traveler's backpack"] = 16, ["mooncloth bag"] = 16, ["pumpkin bag"] = 16,
    ["netherweave bag"] = 16, ["onyxia hide backpack"] = 18,
    ["imbued netherweave bag"] = 18, ["halaani bag"] = 18, ["jack-o'-lantern"] = 18,
    ["primal mooncloth bag"] = 20, ["tattered hexcloth sack"] = 20,
    ["pit lord's satchel"] = 20, ["sun touched satchel"] = 20,
    ["\"gigantique\" bag"] = 22,
}
-- Quivers, ammo pouches and soul bags. Never auto-equipped.
local BAG_SPECIAL = {}
for _, id in ipairs({
    2101, 2102, 2662, 2663, 3573, 3574, 3604, 3605, 5439, 5441, 7278, 7279,
    7371, 7372, 8217, 8218, 11362, 11363, 18714, 19319, 19320,
    21340, 21341, 21342, 22243, 22244, 21872,
    29143, 29144, 34100, 34105, 34106,
    22246, 22248, 22249, 22250, 22251, 22252,
    30745, 30746, 30747, 30748, 34490,
}) do BAG_SPECIAL[id] = true end
local BAG_SPECIAL_WORDS = {
    "quiver", "ammo pouch", "shot pouch", "bandolier", "soul pouch", "soul bag",
    "felcloth bag", "box of souls", "ebon shadowbag", "herb", "enchant",
    "mining", "gem pouch", "toolbox", "inscription",
}
local BAG_SCAN_GAP = 2.0
-- 1.9.2: right after loot
local BAG_LOOT_S, BAG_LOOT_GAP = 3.0, 0.5
-- 1.9.2: names that read as a bag when the client has no item info for it
local BAG_WORDS = { "bag", "pouch", "sack", "satchel", "knapsack", "backpack", "rucksack", "saddlebag" }

local function bag_text_size(name, info)
    local blob = ""
    if type(name) == "string" then blob = name end
    if type(info) == "table" and type(info.description) == "string" then
        blob = blob .. " " .. info.description
    end
    local n = string.lower(blob):match("(%d+)%s*slot")
    if n then
        local v = tonumber(n)
        if type(v) == "number" and v >= 4 and v <= 32 then return v end
    end
    if type(name) == "string" then
        return BAG_NAME[string.lower(name)]
    end
    return nil
end

local function bag_is_special(item_id, info, name)
    if type(item_id) == "number" and BAG_SPECIAL[item_id] then return true end
    if type(info) == "table" and info.equip_loc == "INVTYPE_QUIVER" then return true end   -- 1.9.2
    if type(info) == "table" then
        if info.class_id == 11 then return true end
        if info.class_id == 1 and type(info.subclass_id) == "number" and info.subclass_id ~= 0 then
            return true
        end
    end
    local low = type(name) == "string" and string.lower(name) or ""
    if low == "" and type(info) == "table" and type(info.name) == "string" then
        low = string.lower(info.name)
    end
    for i = 1, #BAG_SPECIAL_WORDS do
        if low:find(BAG_SPECIAL_WORDS[i], 1, true) then return true end
    end
    return false
end

local function bag_slots_of(item_id, info, name)
    if type(item_id) == "number" and type(BAG_SIZE[item_id]) == "number" then
        return BAG_SIZE[item_id]
    end
    local named = type(name) == "string" and BAG_NAME[string.lower(name)] or nil
    if type(named) == "number" then return named end
    if type(info) == "table" and type(info.name) == "string" then
        named = BAG_NAME[string.lower(info.name)]
        if type(named) == "number" then return named end
    end
    return bag_text_size(name or (type(info) == "table" and info.name), info)
end

local function bag_is_ordinary(item_id, info, name)
    if bag_is_special(item_id, info, name) then return false end
    if bag_slots_of(item_id, info, name) then return true end
    -- 1.9.2: the client's own equip location
    if type(info) == "table" and info.equip_loc == "INVTYPE_BAG" then return true end
    if type(info) == "table" and info.class_id == 1 and (info.subclass_id or 0) == 0 then
        return true
    end
    return false
end

local function worn_bag(player, bag)
    local inv = safe(function() return core.inventory.get_bag_inventory_slot(bag) end)
    if type(inv) ~= "number" then return nil end
    local cap = safe(function() return core.inventory.get_num_bag_slots(bag + 1) end)
    local row = safe(function() return player:get_item_at_inventory_slot(inv) end)
    local obj = type(row) == "table" and row.object or nil
    local valid = obj and safe(function() return obj:is_valid() end) == true
    if not valid then
        local empty = type(cap) ~= "number" or cap <= 0
        if not empty then return nil end
        return { bag = bag, inv = inv, empty = true, size = 0, known_empty = true, special = false }
    end
    local item_id = safe(function() return obj:get_item_id() end)
    local name = safe(function() return obj:get_name() end)
    local info = item_info(item_id)
    local ok_items, items = pcall(core.inventory.get_items_in_bag, bag)
    local known_empty = ok_items and type(items) == "table" and #items == 0
    local size = (type(cap) == "number" and cap > 0) and cap or bag_slots_of(item_id, info, name)
    return {
        bag = bag, inv = inv, empty = false, item_id = item_id, name = name,
        size = size or 0, known_empty = known_empty,
        special = bag_is_special(item_id, info, name),
    }
end

--- 1.9.2: no item info from the client (no class_id nor equip_loc), but the
--- name reads as a bag (and as none of the special ones) - only ever put into
--- an EMPTY bag slot.
local function bag_maybe(item_id, info, name)
    if type(info) == "table" and (info.class_id ~= nil or info.equip_loc ~= nil) then return false end
    if type(name) ~= "string" or name == "" then return false end
    if bag_is_special(item_id, info, name) then return false end
    local low = string.lower(name)
    for i = 1, #BAG_WORDS do
        if low:find(BAG_WORDS[i], 1, true) then return true end
    end
    return false
end
equip._bag_maybe, equip._bag_is_ordinary = bag_maybe, bag_is_ordinary        -- tests

--- One bag equip, or false when nothing should move. `gap` (1.9.2): the scan
--- gap to use (BAG_LOOT_GAP right after loot).
local function equip_one_bag(player, gap)
    local now = izi.now()
    if bag_attempt and (now - bag_attempt.t) >= VERIFY_GAP then
        local still = bags.item_at(player, bag_attempt.bag, bag_attempt.slot)
        if still == bag_attempt.item_id then
            local n = (fail_count[bag_attempt.item_id] or 0) + 1
            fail_count[bag_attempt.item_id] = n
            if n >= MAX_FAILS then
                failed_ids[bag_attempt.item_id] = true
                require("actlog").console_warn(string.format(
                    "[Master Farmer - Zygor Forever] Bag equip: %s would not equip after %d tries - skipping it this session.",
                    tostring(bag_attempt.label), n))
            end
        else
            fail_count[bag_attempt.item_id] = nil
        end
        bag_attempt = nil
        last_bag_scan = 0
    end
    if bag_attempt then return false end
    if (now - last_bag_scan) < (gap or BAG_SCAN_GAP) then return false end
    last_bag_scan = now

    local empty_slot = nil
    local smallest = nil
    for bag = 1, 4 do
        local w = worn_bag(player, bag)
        if w and w.empty and not empty_slot then
            empty_slot = w
        elseif w and not w.empty and not w.special and w.known_empty and w.size > 0 then
            if not smallest or w.size < smallest.size then smallest = w end
        end
    end

    local avoid = (not empty_slot and smallest) and smallest.bag or nil
    local best, best_size = nil, -1
    local list = bags.list(player)
    for i = 1, #list do
        local entry = list[i]
        local item_id = entry.item_id
        if item_id and not failed_ids[item_id] and entry.bag ~= avoid then
            local info = item_info(item_id)
            local name = type(info) == "table" and info.name or nil
            if type(name) ~= "string" and entry.item then
                local ok_n, got = pcall(entry.item.get_name, entry.item)
                if ok_n and type(got) == "string" then name = got end
            end
            local ordinary = bag_is_ordinary(item_id, info, name)
            -- 1.9.2: a "maybe" bag (no item info, a bag name) only into an empty slot
            local maybe = not ordinary and empty_slot ~= nil and bag_maybe(item_id, info, name)
            if ordinary or maybe then
                local size = bag_slots_of(item_id, info, name) or 0
                local label = name or ("bag " .. tostring(item_id))
                if best == nil or size > best_size or (best.maybe and ordinary) then
                    best = { bag = entry.bag, slot = entry.slot, item_id = item_id, size = size, label = label,
                        maybe = maybe }
                    best_size = size
                end
            end
        end
    end
    if not best then return false end

    local dest = nil
    if empty_slot then
        dest = empty_slot
    elseif smallest and best.size > smallest.size and not best.maybe then
        dest = smallest
    end
    if not dest or best.bag == dest.bag then return false end

    local where = dest.empty and "an empty bag slot" or ("the " .. tostring(dest.size) .. "-slot bag")
    local slots = best.size > 0 and string.format(" (%d slots)", best.size) or ""
    bag_attempt = { bag = best.bag, slot = best.slot, item_id = best.item_id, label = best.label, t = now }
    state.set_note("Equip", "Equipping " .. best.label)
    require("actlog").console(string.format("[Master Farmer - Zygor Forever] Bag equip: %s%s into %s",
        best.label, slots, where))
    local ok, equipped = pcall(core.input.equip_container_item, best.bag, best.slot, dest.inv)
    local pending = safe(function() return core.game_ui.get_pending_equip_slot() end)
    if type(pending) == "number" and pending >= 0 then
        pcall(core.input.equip_pending_item, pending)
    elseif not (ok and equipped == true) then
        if safe(function() return core.game_ui.has_cursor_item() end) == true then
            pcall(core.input.clear_cursor)
        end
    end
    return true
end

-- ----------------------------------------------------------------------------
-- PUBLIC
-- ----------------------------------------------------------------------------
--- 1.9.2 BAGS WHEN LOOTED (main.lua, right after loot.tick): for BAG_LOOT_S s
--- after a loot window closed, a bag in the bags is equipped at once (a scan
--- every BAG_LOOT_GAP s) - between corpses too, mounted too. Never while a
--- merchant window is open, in combat or dead. True when it acted.
local loot_seen_t, loot_bag_until, loot_was_open = -1e9, -1e9, false
function equip.bag_tick(player)
    if not player then return false end
    local now = izi.now()
    if loot_seen_t < 0 then loot_seen_t = now end          -- a loot before this load is not "just looted"
    -- events.lua's LOOT_CLOSED stamp; else (a core that sends no game
    -- events) the loot window's item count going back to 0
    local closed = false
    local ok_e, ev = pcall(require, "events")
    if ok_e and type(ev) == "table" and type(ev.since) == "function" then
        closed = ev.since("LOOT_CLOSED", loot_seen_t) == true
    end
    local n = safe(function() return core.game_ui.get_loot_item_count() end)
    local open = type(n) == "number" and n > 0
    if loot_was_open and not open then closed = true end
    loot_was_open = open
    if closed then
        loot_seen_t = now + 0.001
        loot_bag_until = now + BAG_LOOT_S
        last_bag_scan = -1e9
    end
    if now > loot_bag_until then return false end
    local n_vendor = safe(function() return core.game_ui.get_vendor_item_count() end)
    if type(n_vendor) == "number" and n_vendor > 0 then return false end
    if safe(function() return core.inventory.can_merchant_repair() end) == true then return false end   -- audit 1.19.0
    if safe(function() return player:is_in_combat() end) == true then return false end
    if safe(function() return player:is_dead_or_ghost() end) == true then return false end
    if equip_one_bag(player, BAG_LOOT_GAP) then
        loot_bag_until = now + BAG_LOOT_S                 -- another bag may follow
        return true
    end
    return false
end

--- Called from the main cascade. Returns true when it acted this tick.
---
--- VERIFIED, NOT ASSUMED (2.34.0). An attempt is checked VERIFY_GAP later: if
--- the item is still sitting in the same bag slot, the equip did not take.
--- After MAX_FAILS such attempts the item is skipped for the rest of the
--- session and said so in the log. The cascade is no longer held while an
--- attempt lands - that 1.5 s hold, repeated every scan, was the "Equipping
--- Ragged Leather Gloves" loop that stopped questing mid-approach. The only
--- hold left is answering a bind-on-equip prompt.
function equip.tick(player)
    if not player then
        return false
    end

    -- use_container_item SELLS while a merchant is open. Never scan then.
    local n_vendor = safe(function() return core.game_ui.get_vendor_item_count() end)
    if type(n_vendor) == "number" and n_vendor > 0 then
        return false
    end
    -- audit 1.19.0: a merchant with an empty / unreadable item list is still a
    -- merchant (vendor.merchant_open's second test) - use_item / use_container_item
    -- would sell the upgrade there
    if safe(function() return core.inventory.can_merchant_repair() end) == true then
        return false
    end

    if safe(function() return player:is_in_combat() end) == true then
        return false
    end
    if safe(function() return player:is_mounted() end) == true then
        return false
    end
    if safe(function() return player:is_dead_or_ghost() end) == true then
        return false
    end
    -- Only between fights (2.35.0). The in-combat check alone let it swap a
    -- shield in while closing on a wolf at 2.8 yards - not yet "in combat",
    -- but the rotation already starting auto-attack. No equip while there is
    -- a live kill target, while combat movement owns the player, or while a
    -- corpse is waiting to be looted.
    local tgt = state.target and state.target.unit
    if tgt and state.target.kind == "kill"
        and safe(function() return tgt:is_valid() end) == true
        and safe(function() return tgt:is_dead() end) ~= true then
        return false
    end
    local ok_m, movement = pcall(require, "movement")
    if ok_m and movement and type(movement.in_combat_movement) == "function"
        and movement.in_combat_movement() then
        return false
    end
    local ok_l, loot = pcall(require, "loot")
    if ok_l and loot and type(loot.has_work) == "function" and loot.has_work(player) then
        return false
    end

    local now = izi.now()

    -- A bind-on-equip item raises a confirmation prompt and the equip stalls
    -- until it is answered.
    local pending_slot = safe(function() return core.game_ui.get_pending_equip_slot() end)
    if type(pending_slot) == "number" and pending_slot >= 0 then
        state.set_note("Equip", "Confirming bind-on-equip")
        pcall(function() core.input.equip_pending_item(pending_slot) end)
        last_act = now
        return true
    end

    -- Bags are not behind the Auto Equip checkbox. One bag per scan, then
    -- the gear pass below still runs on a later tick.
    if equip_one_bag(player) then
        return true
    end
    if not gui.is_on("auto_equip") then
        return false
    end

    -- Judge the last attempt once it has had time to land.
    if attempt and (now - attempt.t) >= VERIFY_GAP then
        local still = bags.item_at(player, attempt.bag, attempt.slot)
        if still == attempt.item_id then
            local n = (fail_count[attempt.item_id] or 0) + 1
            fail_count[attempt.item_id] = n
            if n >= MAX_FAILS then
                failed_ids[attempt.item_id] = true
                require("actlog").console_warn(string.format(
                    "[Master Farmer - Zygor Forever] Auto-equip: %s would not equip after %d tries - skipping it until the game restarts (%s).",
                    tostring(attempt.label), n, last_client_error()))
            end
        else
            fail_count[attempt.item_id] = nil
        end
        attempt = nil
        last_scan = 0            -- look for the next upgrade straight away
    end
    if attempt then
        return false             -- still landing; do not hold the cascade
    end

    if (now - last_scan) < SCAN_GAP then
        return false
    end
    last_scan = now

    local bag, slot, label, item_id, weapon_slot = find_upgrade(player)
    if not bag then
        return false
    end
    if weapon_slot then
        weapon_until = now + WEAPON_COOLDOWN
    end

    last_act = now
    attempt = { bag = bag, slot = slot, item_id = item_id, label = label, t = now }
    state.set_note("Equip", "Equipping " .. tostring(label))
    require("actlog").console("[Master Farmer - Zygor Forever] Auto-equip: " .. tostring(label))
    -- By item id (2.80.0): the bag-slot pair is wrong for the backpack on
    -- this client (see bags.use_id). The slot is the fallback only when the
    -- id is unknown.
    if not (type(item_id) == "number" and bags.use_id(item_id)) then
        bags.use(bag, slot)
    end
    return true
end

--- Force the next tick to rescan. Call after looting so an upgrade is picked up
--- without waiting out the scan gap.
-- ----------------------------------------------------------------------------
-- SHARED RATING  (used by the quest reward picker)
-- ----------------------------------------------------------------------------
--- Item info for an item id OR an item link. Quest rewards only ever hand out
--- links, and core.quests.get_item_info takes integer|string.
function equip.info_of(id_or_link)
    if type(id_or_link) == "number" then
        return item_info(id_or_link)
    end
    if type(id_or_link) ~= "string" or id_or_link == "" then
        return nil
    end
    local info = safe(function() return core.quests.get_item_info(id_or_link) end)
    if type(info) ~= "table" then
        return nil
    end
    return info
end

--- Can this character actually equip and use `info`?
---
--- Returns (usable, slots, why). `slots` is the candidate inventory slot list
--- when the item is equippable, nil otherwise. `why` explains a refusal and is
--- meant for the debug log.
-- 1.7.26 (game_ui doc): the tooltip the client would show holds the red
-- "cannot equip" lines (an untrained armour / weapon skill, a class or level
-- restriction) that get_item_info does not. core.inventory.
-- get_container_item_link -> core.game_ui.get_hyperlink_tooltip; a red left
-- line (r > 0.9, g and b < 0.2) blocks the equip. Empty table (no
-- C_TooltipInfo on this client): nothing blocks. Cached per link.
local red_cache, red_n = {}, 0
function equip.tooltip_block(bag, slot)
    local link = safe(function() return core.inventory.get_container_item_link(bag, slot) end)
    if type(link) ~= "string" or link == "" then return nil end
    local c = red_cache[link]
    if c ~= nil then return c or nil end
    local lines = safe(function() return core.game_ui.get_hyperlink_tooltip(link) end)
    local red = false
    if type(lines) == "table" then
        for i = 2, #lines do                                   -- line 1 is the item name
            local l = lines[i]
            if type(l) == "table" and type(l.left_text) == "string" and l.left_text ~= ""
                and tonumber(l.left_r) and l.left_r > 0.9 and (tonumber(l.left_g) or 1) < 0.2 and (tonumber(l.left_b) or 1) < 0.2 then
                red = l.left_text
                break
            end
        end
    end
    red_n = red_n + 1
    if red_n > 200 then red_cache, red_n = {}, 0 end
    red_cache[link] = red
    return red or nil
end

function equip.usable_by(player, info)
    if type(info) ~= "table" then
        return false, nil, "no item info"
    end

    local loc = info.equip_loc
    if type(loc) ~= "string" or loc == "" or loc == "INVTYPE_NON_EQUIP" then
        return false, nil, "not equippable"
    end
    if equip.is_tool(info) then
        return false, nil, "profession tool, not a weapon"
    end
    local slots = LOC_SLOTS[loc] or WEAPON_SLOTS[loc]
    if loc == "INVTYPE_RELIC" then
        slots = { SLOT.RANGED }
    end
    if not slots then
        return false, nil, "unknown equip location " .. loc
    end

    local lvl = safe(function() return player:get_level() end)
    local req = required_level(info)
    if type(lvl) == "number" and type(req) == "number" and req > lvl then
        return false, slots, string.format("needs level %d, character is %d", req, lvl)
    end

    local class_id = safe(function() return player:get_class() end)

    if not CLASS_ARMOUR[class_id] or type(lvl) ~= "number" or lvl <= 0 then
        return false, slots, "waiting for character class and level"
    end

    -- Armour: the class may wear its own weight and anything lighter.
    local rank = armour_rank(info)
    if rank then
        local max_rank = max_armour_for(class_id, lvl)
        if max_rank and rank > max_rank then
            return false, slots, "armour too heavy for this class at this level"
        end
        return true, slots, nil
    end

    local cls, sub = info.class_id, info.subclass_id
    if type(cls) == "number" and type(sub) == "number" then
        if cls == ITEM_CLASS.WEAPON then
            local allowed = CLASS_WEAPONS[class_id]
            if allowed and not allowed[sub] then
                return false, slots, "class cannot use this weapon type"
            end
            return true, slots, nil
        end
        if cls == ITEM_CLASS.ARMOR then
            if sub == ARMOR_SUB.SHIELD then
                if not CLASS_SHIELD[class_id] then
                    return false, slots, "class cannot use shields"
                end
                return true, slots, nil
            end
            if sub == ARMOR_SUB.LIBRAM or sub == ARMOR_SUB.IDOL or sub == ARMOR_SUB.TOTEM then
                if CLASS_RELIC[class_id] ~= sub then
                    return false, slots, "relic belongs to another class"
                end
                return true, slots, nil
            end
            -- ARMOR_SUB.MISC: rings, necks, trinkets, cloaks. Anyone may wear them.
            return true, slots, nil
        end
    end

    -- Missing metadata must not permit an equip attempt on unknown gear.
    return false, slots, "waiting for item class data"
end

--- Rate a candidate for the quest reward picker.
---
--- tier 3  a usable upgrade over what is worn
--- tier 2  usable, but not better than what is worn
--- tier 1  not equippable at all - a bag, a consumable, a stack of reagents
--- tier 0  equippable but this class cannot use it
---
--- Ties inside a tier break on item level, then quality, then vendor price, so
--- "best usable item" means the strongest thing the character can actually
--- wear, and only falls back to raw value when nothing is wearable.
function equip.rate(player, info, link)
    if type(info) ~= "table" then
        return nil
    end
    local score_delta = nil
    local usable, slots, why = equip.usable_by(player, info)
    local tier, reason

    if not slots then
        tier, reason = 1, why or "not equippable"
    elseif not usable then
        tier, reason = 0, why or "unusable"
    else
        local cur_slot = pick_slot(player, slots)
        local cur = cur_slot and equipped_info(player, cur_slot) or nil
        local better, note = better_than(info, cur)
        -- 1.8.0 TBC: the reward with the biggest Zygor score gain (Item-Quest.lua 97-105)
        local sc = equip.tbc_scorer()
        if sc and link then
            local d = sc.delta(player, link, cur and slot_link(cur_slot) or nil)
            if d ~= nil then
                score_delta = d
                better, note = d > 0, string.format("Zygor stat score %+.1f", d)
            end
        end
        if better then
            tier, reason = 3, note or "upgrade"
        else
            tier, reason = 2, "usable, not an upgrade"
        end
    end

    return {
        tier = tier,
        reason = reason,
        item_level = item_level(info) or 0,
        quality = quality_of(info) or 0,
        sell_price = (type(info.sell_price) == "number" and info.sell_price) or 0,
        name = info.name,
        score_delta = score_delta,
    }
end

--- True when `a` is a strictly better reward than `b`.
function equip.rating_beats(a, b)
    if not b then return a ~= nil end
    if not a then return false end
    if a.tier ~= b.tier then return a.tier > b.tier end
    if a.score_delta and b.score_delta and a.score_delta ~= b.score_delta then
        return a.score_delta > b.score_delta                -- 1.8.0 TBC: the bigger score gain
    end
    if a.item_level ~= b.item_level then return a.item_level > b.item_level end
    if a.quality ~= b.quality then return a.quality > b.quality end
    return a.sell_price > b.sell_price
end

function equip.invalidate()
    last_scan = 0
    last_bag_scan = 0
end

function equip.register_gui(menu)
    menu:checkbox("mfz_auto_equip", true, {
        label = "Auto Equip Upgrades",
        tab = "settings",
        tooltip = "Equip better armour from your bags out of combat. Never downgrades.",
    })
    menu:checkbox("mfz_equip_weapons", true, {
        label = "Auto Equip Weapons",
        tab = "settings",
        tooltip = "Equip a better weapon, shield, held item or wand from your bags out of combat. Only types the class can "
            .. "use (and never one the tooltip shows in red); never a downgrade, never a profession tool.",
    })
    menu:checkbox("mfz_equip_debug", false, {
        label = "Log item info fields",
        tab = "settings",
        tooltip = "Prints once what get_item_info actually returns. Use this to confirm whether "
            .. "an item level is available - without one, only empty slots are filled.",
    })
end

return equip
