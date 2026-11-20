-- ============================================================================
-- Master Farmer - Zygor Forever
-- Quest items in the bags (1.29.3)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Folder: Zygor_Forever
-- ============================================================================
-- 1.29.3 (user: "Find all quest items in bag to use in completing quests").
-- Every bag item with a use spell (core.quests.get_item_spell spell_id > 0)
-- that is a quest item: item class 12 / item type "Quest"
-- (core.quests.get_item_info), or one of Zygor's guide use items
-- (data/zygor_use_items.lua, tools/import_zygor_use_items.py). Each carries
-- the quests Zygor's guides use it for, so a step names its item by quest id.
--   QI.rows()            the bundled use lines { item, n, quests = { [q] = true } }
--   QI.quests_of(id)     the quests the guides use item `id` for (a set)
--   QI.list()            the usable quest items in the bags (QI.TTL s cache)
--   QI.for_quests(set)   those whose guide quests meet `set`, the rest after
-- 1.29.4 (user: "Extract itemID's that goes with any quest ID's in Zygor, along
-- with any other useful data ... RXPGuides"): data/quest_items.lua
-- (tools/import_quest_items.py - Zygor's TBC guides + RestedXP's guides and
-- quest DB) adds, per item: U the quests it is used for, S the quests it
-- starts, C the quests that ask for it, and the mobs / objects to use it on.
--   QI.starts(id) / QI.starter_for(quest)   item-started quests
--   QI.targets(id)                         names to use the item on
--   QI.wanted_by(id)                       quests that ask for the item (C)
-- Nothing here is cast: quest/guide and quest/engine use the item at the
-- step's waypoint (item_goal) with the documented use_item calls.
-- ============================================================================

local QI = {}

QI.TTL = 2.0                    -- s between two bag reads
local CLASS_QUEST = 12

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function clock()
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then return izi.now() end
    return 0
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "act", fmt, ...) end
end

-- 1.32.2 (user: "zygor_forever freezing on quest pickup, remove all added questing
-- data tables from all projects"): data/zygor_use_items, data/quest_items and the
-- Master Farmer database are gone - their megabytes of string were decoded by the
-- build's string obfuscation on first load (the freeze). Keep only small verified
-- associations below; the bag
-- scan below keeps finding quest items by their item type.
-- Verified in the installed ClassicTBCAnniv alliance Zangarmarsh guide:
-- use Ironvine Seeds##24355; Disable the Serpent Lake Controls |q 9720/3.
-- Small explicit associations only; no restored bulk guide database.
local VERIFIED_USE = {
    {item=24355, n=1, quests={[9720]=true}},
    -- Zangarmarsh step 136: use Ahuurn's Elixir, then havebuff 32038 |q 9803.
    -- A transformation, not an item to use on the later Kuruti response goal.
    {item=24428, n=1, quests={[9803]=true}, buff_only=true},
}
local NONE = {}
function QI.rows() return VERIFIED_USE end
function QI.quests_of(id)
    for _, r in ipairs(VERIFIED_USE) do if r.item == id then return r.quests end end
    return NONE
end
function QI.buff_only(id)
    for _, r in ipairs(VERIFIED_USE) do if r.item == id then return r.buff_only == true end end
    return false
end
function QI.in_guides(id) return next(QI.quests_of(id)) ~= nil end
function QI.starts() return NONE end
function QI.starter_for() return nil end
function QI.targets() return NONE end
function QI.wanted_by() return NONE end

-- ----------------------------------------------------------------------------
-- the bags
-- ----------------------------------------------------------------------------
local cache = { t = -1e9, list = {}, sig = "" }
local info_memo = {}            -- item id -> { quest = bool, spell = id|nil, name }

local function item_facts(id)
    local f = info_memo[id]
    if f then return f end
    local info = safe(core.quests.get_item_info, id)
    local sp = safe(core.quests.get_item_spell, id)
    local spell_id = type(sp) == "table" and tonumber(sp.spell_id) or nil
    local is_quest = type(info) == "table" and (tonumber(info.class_id) == CLASS_QUEST or info.item_type == "Quest")
    f = {
        quest = is_quest == true,
        spell = (spell_id and spell_id > 0) and spell_id or nil,
        name = type(info) == "table" and type(info.name) == "string" and info.name or nil,
    }
    -- a nil answer (item not cached by the client yet) is asked again later
    if type(info) == "table" then info_memo[id] = f end
    return f
end

local function bag_ids()
    local ids, seen = {}, {}
    for bag = 0, 4 do
        local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
        if type(items) == "table" then
            for i = 1, #items do
                local e = items[i]
                local id = type(e) == "table" and e.object and safe(function() return e.object:get_item_id() end)
                if type(id) == "number" and id > 0 and not seen[id] then
                    seen[id] = true
                    ids[#ids + 1] = id
                end
            end
        end
    end
    return ids
end

--- The usable quest items in the bags: { item_id, name, spell_id, quests, guide }.
function QI.list()
    local now = clock()
    if now - cache.t < QI.TTL then return cache.list end
    cache.t = now
    local out = {}
    local ids = bag_ids()
    for i = 1, #ids do
        local id = ids[i]
        local f = item_facts(id)
        local guide_item = QI.in_guides(id)
        if f.spell and (f.quest or guide_item) and id ~= 6948 then        -- never the Hearthstone
            out[#out + 1] = { item_id = id, name = f.name or ("item " .. id), spell_id = f.spell,
                quests = QI.quests_of(id), guide = guide_item, buff_only = QI.buff_only(id) }
        end
    end
    table.sort(out, function(a, b) return a.item_id < b.item_id end)
    local parts = {}
    for i = 1, #out do parts[i] = string.format("%s (%d)", out[i].name, out[i].item_id) end
    local sig = table.concat(parts, ", ")
    if sig ~= cache.sig then
        cache.sig = sig
        trail("quest items in the bags: %s", sig ~= "" and sig or "none")
    end
    cache.list = out
    return out
end

--- The bag's quest items for the quest set `quests`: those Zygor's guides use
--- for one of them first, then (with `all`) every other quest item.
function QI.for_quests(quests, all)
    local hit, rest = {}, {}
    local list = QI.list()
    for i = 1, #list do
        local e = list[i]
        local match = false
        if type(quests) == "table" then
            for q in pairs(e.quests) do
                if quests[q] then match = true break end
            end
        end
        if match then hit[#hit + 1] = e elseif all then rest[#rest + 1] = e end
    end
    for i = 1, #rest do hit[#hit + 1] = rest[i] end
    return hit
end

function QI.reset()
    cache.t, cache.list, cache.sig = -1e9, {}, ""
    info_memo = {}
end

return QI
