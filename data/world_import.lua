-- ============================================================================
-- Master Farmer - Zygor Forever
-- data/world_import.lua - OPTIONAL local import of Forever world tables (flight
-- points, trainers, dangerous mobs), read from
-- scripts_data/zf_data/<Alliance|Horde>/<table>.txt. NOT a guide source: every
-- quest step comes from Zygor (quest/guide.lua); without the import the
-- tables are empty and every caller pcall-guards that.
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- ============================================================================
-- tools/import_rxp_forever.py writes the files on this PC from the installed
-- RXPGuides addon (DB\shared.lua + DB\forever\*.lua: FPDB, FPbyZone, taxiPos,
-- SpiritHealerWorld, dangerousMobs, rares, statWeights, quest*Items,
-- defaultSpellList, mapId / mapIdToName, mountIDs, emergencyItems / Spells,
-- dungeon* ...) and, 1.0.5, the Forever guides read as text (guideSteps,
-- guideQuests) and CptStadicsVendorTreasures (vendorTreasures). RXPGuides is
-- CC BY-NC-SA 4.0: the data is never shipped in
-- the product - without the import every table is empty.
--
-- Line format: <key path> TAB <type> TAB <value>; the key path is
-- "s:<string>" / "n:<number>" joined by "/"; type s / n / b; "%", "/", TAB and
-- newlines are %XX-escaped. A table is read once (core.read_data_file, one
-- call per table, on first use) and kept.
-- ============================================================================

local M = {}

M.FOLDER = "zf_data"

local cache = {}          -- "<faction>/<name>" -> table (false when missing)
local faction_key = nil

local function unesc(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parse_key(k)
    local t, v = k:sub(1, 2), k:sub(3)
    if t == "n:" then return tonumber(v) end
    return unesc(v)
end

--- Parse one table file's text into a nested table.
function M.parse(text)
    local root = {}
    if type(text) ~= "string" or text == "" then return root end
    for line in text:gmatch("[^\n]+") do
        local path, vt, val = line:match("^([^\t]*)\t([snb])\t(.*)$")
        if path then
            local v
            if vt == "n" then v = tonumber(val) elseif vt == "b" then v = val == "1" else v = unesc(val) end
            if path == "" then
                root.__value = v
            else
                local node = root
                local keys = {}
                for part in path:gmatch("[^/]+") do keys[#keys + 1] = parse_key(part) end
                for i = 1, #keys - 1 do
                    local k = keys[i]
                    if type(node[k]) ~= "table" then node[k] = {} end
                    node = node[k]
                end
                if #keys > 0 and keys[#keys] ~= nil then node[keys[#keys]] = v end
            end
        end
    end
    return root
end

--- "Alliance" / "Horde" for the player (data/factions), or nil.
function M.faction()
    if faction_key then return faction_key end
    local okf, factions = pcall(require, "data/factions")
    local ok_i, izi = pcall(require, "common/izi_sdk")
    if not (okf and ok_i and type(factions) == "table" and type(izi) == "table") then return nil end
    local okm, me = pcall(izi.me)
    if not okm or not me then return nil end
    local ok, key = pcall(factions.of_player, me)
    if not ok then return nil end
    if key == factions.ALLIANCE then faction_key = "Alliance" elseif key == factions.HORDE then faction_key = "Horde" end
    return faction_key
end

--- The data table `name` for the player's faction, or {} when it was not
--- imported (or the faction is not known yet).
function M.get(name)
    local f = M.faction()
    if not f or type(name) ~= "string" then return {} end
    local k = f .. "/" .. name
    local hit = cache[k]
    if hit ~= nil then return hit or {} end
    local text = nil
    if type(core) == "table" and type(core.read_data_file) == "function" then
        local ok, s = pcall(core.read_data_file, M.FOLDER .. "/" .. k .. ".txt")
        if ok and type(s) == "string" then text = s end
    end
    if not text or text == "" then
        cache[k] = false
        return {}
    end
    local t = M.parse(text)
    cache[k] = t
    return t
end

--- Is the import there (index.txt for the player's faction)?
function M.imported()
    local f = M.faction()
    if not f then return false end
    local ok, s = pcall(core.read_data_file, M.FOLDER .. "/" .. f .. "/index.txt")
    return ok and type(s) == "string" and s ~= ""
end

-- ----------------------------------------------------------------------------
-- dangerousMobs: zone name -> mob name -> { { MinLevel, MaxLevel,
-- Classification, Movement, Notes, Location }, ... } for the player's faction
-- ----------------------------------------------------------------------------
local danger_names = nil
--- Every dangerous mob name RXPGuides lists for the player's faction (a set).
function M.dangerous_names()
    if danger_names then return danger_names end
    local t = M.get("dangerousMobs")
    local set = {}
    for _, mobs in pairs(t) do
        if type(mobs) == "table" then
            for name in pairs(mobs) do if type(name) == "string" then set[name] = true end end
        end
    end
    if next(t) ~= nil then danger_names = set end
    return set
end

-- ----------------------------------------------------------------------------
-- guideQuests (1.0.5): [quest id][accept|turnin|complete] = rows { npcs, mobs,
-- gotos, guide, step, cond } read from the Forever guide text by the importer
-- ----------------------------------------------------------------------------
--- The guide rows of a quest action ({} when none / not imported).
function M.quest_rows(kind, quest_id)
    local q = M.get("guideQuests")[tonumber(quest_id) or -1]
    local rows = type(q) == "table" and q[kind] or nil
    return type(rows) == "table" and rows or {}
end

local function list_of(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for i = 1, #t do out[#out + 1] = t[i] end
    return out
end

--- The NPC a guide names (.target) for accepting / turning in a quest, and
--- the place (the step's last .goto). nil when the guides do not say.
function M.quest_npc(kind, quest_id)
    local best = nil
    for _, row in ipairs(M.quest_rows(kind, quest_id)) do
        local npcs = list_of(row.npcs)
        if #npcs > 0 or (type(row.object)=="string" and row.object~="") then
            local gotos = list_of(row.gotos)
            if not best or (#gotos > 0 and #list_of(best.gotos) == 0) then best = row end
        end
    end
    if not best then return nil end
    local gotos = list_of(best.gotos)
    return best.object or list_of(best.npcs)[1], gotos[#gotos], best
end

--- The place of a quest action (the step's last .goto), with or without an NPC.
function M.quest_point(kind, quest_id)
    for _, row in ipairs(M.quest_rows(kind, quest_id)) do
        local gotos = list_of(row.gotos)
        if #gotos > 0 then return gotos[#gotos], row end
    end
    return nil
end

--- 1.0.8: the item a guide's ".collect item,count,quest" step gathers for a
--- quest: item id, count, row - nil when the guides do not say.
function M.quest_collect(quest_id)
    for _, row in ipairs(M.quest_rows("collect", quest_id)) do
        if tonumber(row.item) then return tonumber(row.item), tonumber(row.count) or 1, row end
    end
    return nil
end

-- Explicit objective-local .mob + names, imported from the user's addon.
function M.collect_mobs(quest_id, item_id)
    local out, seen = {}, {}
    for _, row in ipairs(M.quest_rows("collect", quest_id)) do
        if tonumber(row.item) == tonumber(item_id) then
            for _, name in ipairs(row.item_mobs or {}) do
                if type(name)=="string" and not seen[name] then
                    seen[name]=true; out[#out+1]=name
                end
            end
        end
    end
    return out
end

--- 1.0.8: an item that STARTS a quest - the ".use" item of the guide step that
--- accepts it (the Nibbled-On Book 247834 for 91741), or the collected item.
function M.accept_item(quest_id)
    for _, row in ipairs(M.quest_rows("accept", quest_id)) do
        local uses = list_of(row.uses)
        if #uses > 0 then return tonumber(uses[1]) end
    end
    return nil
end

--- 1.0.24: a GROUND PICKUP - the object a Forever guide step names with
--- "|cRXP_PICK_<name>|r" on a quest's .complete / .collect step: name, the
--- step's last .goto, and that step's .collect item id (or nil). nil when no
--- step of the quest picks anything up (mob loot, a vendor buy).
function M.quest_pick(quest_id)
    for _, kind in ipairs({ "complete", "collect" }) do
        for _, row in ipairs(M.quest_rows(kind, quest_id)) do
            if type(row.pick) == "string" and row.pick ~= "" then
                local gotos = list_of(row.gotos)
                local item = tonumber(row.item)
                if not item then
                    for _, c in ipairs(M.quest_rows("collect", quest_id)) do
                        if c.step == row.step and c.guide == row.guide and tonumber(c.item) then item = tonumber(c.item) end
                    end
                end
                return row.pick, gotos[#gotos], item, row
            end
        end
    end
    return nil
end

--- Every mob name the guides' .complete (and, 1.0.8, .collect) steps of a quest list (.mob).
function M.quest_mobs(quest_id)
    local set, out = {}, {}
    local rows = {}
    for _, row in ipairs(M.quest_rows("complete", quest_id)) do rows[#rows + 1] = row end
    for _, row in ipairs(M.quest_rows("collect", quest_id)) do rows[#rows + 1] = row end
    for _, row in ipairs(rows) do
        for _, n in ipairs(list_of(row.mobs)) do
            if type(n) == "string" and not set[n] then set[n] = true out[#out + 1] = n end
        end
    end
    return out
end

function M._reset() cache, faction_key, danger_names = {}, nil, nil end

return M
