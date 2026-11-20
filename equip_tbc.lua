-- ============================================================================
-- Master Farmer - Zygor Forever
-- equip_tbc.lua - Zygor's TBC item score (stat weights) for equip.lua
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- 1.8.0 (user spec: "if the existing score does not match Item-ItemScore.lua,
-- fix the TBC module only"). equip.lua compared item level and quality; Zygor
-- on TBC (Item-ItemScore.lua GetItemScore 519-615) ignores item level and sums
-- tooltip stat x the spec's weight:
--   * weights: Zygor's Data-TBC/Item-Statweights.lua, imported LOCALLY by
--     tools/import_zygor_npcs.py into scripts_data/zfb/zygor_statweights.txt
--     (no Zygor data in the product); missing file = no score, equip.lua's
--     item-level rule stands;
--   * the spec: the talent tab with the most points (Druid: tab 2 = Feral
--     DPS, tab 3 = Restoration); under 10 points the levelling default below;
--   * stats: read from core.game_ui.get_hyperlink_tooltip(link) (documented;
--     empty on a client without C_TooltipInfo = no score) with patterns
--     written from the TBC tooltip text; set and socket-bonus lines skipped;
--   * a capped stat (caps) counts half on an item not worn while the player
--     is below 70 (548-554); ARMOR / DAMAGE_PER_SECOND without a weight count
--     0.1 x the spec's lowest positive weight (182-191, 566-574);
--   * upgrade = strictly higher score (Item-Upgrades.lua 299-301).
-- Loaded by equip.lua only when gamever.is_tbc().
-- ============================================================================

local M = {}

M.FILE = "mfzb/zygor_statweights.txt"
M.MAX_LEVEL = 70
local CLASS_TOKEN = { [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
    [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID" }
-- under 10 talent points: the usual levelling spec
local DEFAULT_SPEC = { WARRIOR = 1, PALADIN = 3, HUNTER = 1, ROGUE = 2, PRIEST = 3, SHAMAN = 2, MAGE = 3,
    WARLOCK = 1, DRUID = 2 }
local DRUID_TAB = { [1] = 1, [2] = 2, [3] = 4 }

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local rules = nil        -- CLASS -> spec # -> { name, stats, caps }
local function kv(s)
    local t = {}
    for k, v in tostring(s or ""):gmatch("([%u_]+)=(%-?[%d%.]+)") do t[k] = tonumber(v) end
    return t
end
function M.load(body)
    rules = {}
    if body == nil then body = safe(function() return core.read_data_file(M.FILE) end) end
    if type(body) ~= "string" then return 0 end
    local n = 0
    for line in body:gmatch("[^\n]+") do
        local cls, num, name, stats, caps = line:match("^(%u+)\t(%d+)\t([^\t]*)\tstats ([^\t]*)\tcaps ([^\t]*)")
        if cls then
            rules[cls] = rules[cls] or {}
            rules[cls][tonumber(num)] = { name = name, stats = kv(stats), caps = kv(caps) }
            n = n + 1
        end
    end
    return n
end
function M.available()
    if rules == nil then M.load() end
    return next(rules) ~= nil
end

--- The spec rule for `player` and its name, or nil.
local spec_cache = { t = -1e9, cls = nil, n = nil }
function M.spec(player)
    if rules == nil then M.load() end
    local cid = safe(function() return player:get_class() end)
    local cls = CLASS_TOKEN[cid]
    if not cls or not rules[cls] then return nil end
    local t = safe(function() return core.time() end) or 0
    if spec_cache.cls ~= cls or t - spec_cache.t > 30 then
        local best, best_pts = nil, 0
        for tab = 1, 3 do
            local info = safe(function() return core.game_ui.get_talent_tab_info(tab) end)
            local pts = type(info) == "table" and tonumber(info.points_spent) or 0
            if pts > best_pts then best, best_pts = tab, pts end
        end
        local n = (best and best_pts >= 10) and (cls == "DRUID" and DRUID_TAB[best] or best) or DEFAULT_SPEC[cls]
        spec_cache.t, spec_cache.cls, spec_cache.n = t, cls, n
    end
    local r = rules[cls][spec_cache.n] or rules[cls][DEFAULT_SPEC[cls]]
    return r
end

-- tooltip text -> stats. First matching pattern per line (more specific first).
local LINE = {
    { "Increases healing done by up to (%d+) and damage done by up to (%d+)", "SPELL_HEALING_DONE", "SPELL_DAMAGE_DONE" },
    { "damage and healing done by magical spells and effects by up to (%d+)", "SPELL_DAMAGE_DONE", nil, "SPELL_HEALING_DONE" },
    { "healing done by spells and effects by up to (%d+)", "SPELL_HEALING_DONE" },
    { "Increases healing done by up to (%d+)", "SPELL_HEALING_DONE" },
    { "damage done by Shadow spells and effects by up to (%d+)", "SPELL_DAMAGE_DONE_SHADOW" },
    { "damage done by Fire spells and effects by up to (%d+)", "SPELL_DAMAGE_DONE_FIRE" },
    { "damage done by Frost spells and effects by up to (%d+)", "SPELL_DAMAGE_DONE_FROST" },
    { "damage done by Arcane spells and effects by up to (%d+)", "SPELL_DAMAGE_DONE_ARCANE" },
    { "damage done by Nature spells and effects by up to (%d+)", "SPELL_DAMAGE_DONE_NATURE" },
    { "damage done by Holy spells and effects by up to (%d+)", "SPELL_DAMAGE_DONE_HOLY" },
    { "attack power by (%d+) in Cat", "FERAL_ATTACK_POWER" },
    { "ranged attack power by (%d+)", "RANGED_ATTACK_POWER" },
    { "attack power by (%d+)", "ATTACK_POWER" },
    { "spell critical strike rating by (%d+)", "CRIT_SPELL" },
    { "critical strike rating by (%d+)", "CRIT" },
    { "spell hit rating by (%d+)", "HIT_SPELL" },
    { "hit rating by (%d+)", "HIT" },
    { "spell haste rating by (%d+)", "HASTE" },
    { "haste rating by (%d+)", "HASTE" },
    { "expertise rating by (%d+)", "EXPERTISE" },
    { "armor penetration rating by (%d+)", "ARMOR_PENETRATION" },
    { "ignore (%d+) of your opponent's armor", "ARMOR_PENETRATION" },
    { "spell penetration by (%d+)", "SPELL_PENETRATION" },
    { "defense rating by (%d+)", "DEFENSE_SKILL" },
    { "dodge rating by (%d+)", "DODGE" },
    { "parry rating by (%d+)", "PARRY" },
    { "block value of your shield by (%d+)", "BLOCK_VALUE" },
    { "shield block rating by (%d+)", "BLOCK" },
    { "block rating by (%d+)", "BLOCK" },
    { "Restores (%d+) mana per 5 sec", "MANA_REGENERATION" },
    { "(%d+) mana every 5 sec", "MANA_REGENERATION" },
    { "%(([%d%.]+) damage per second%)", "DAMAGE_PER_SECOND" },
    { "^(%d+) Armor$", "ARMOR" },
}
-- "+12 Stamina", "+10 Spell Damage and Healing" ... (base stats, enchants, gems)
local PLUS = {
    ["Strength"] = "STRENGTH", ["Agility"] = "AGILITY", ["Stamina"] = "STAMINA", ["Intellect"] = "INTELLECT",
    ["Spirit"] = "SPIRIT", ["Attack Power"] = "ATTACK_POWER", ["Hit Rating"] = "HIT", ["Critical Strike Rating"] = "CRIT",
    ["Spell Critical Strike Rating"] = "CRIT_SPELL", ["Spell Hit Rating"] = "HIT_SPELL", ["Healing"] = "SPELL_HEALING_DONE",
    ["Spell Damage"] = "SPELL_DAMAGE_DONE", ["Defense Rating"] = "DEFENSE_SKILL", ["Dodge Rating"] = "DODGE",
    ["Haste Rating"] = "HASTE", ["Expertise Rating"] = "EXPERTISE",
}
local SKIP = { "^Set:", "^Socket Bonus", "^Use:", "^Chance on hit", "^%(%d+%) Set" }

--- Stats read from one item's tooltip lines.
function M.stats_of(lines)
    local s = {}
    for i = 2, #(lines or {}) do                          -- line 1 is the name
        local l = lines[i]
        local text = type(l) == "table" and l.left_text or l
        if type(text) == "string" and text ~= "" then
            local skip = false
            for k = 1, #SKIP do if text:find(SKIP[k]) then skip = true break end end
            if not skip then
                local hit = false
                for k = 1, #LINE do
                    local p = LINE[k]
                    local a, b = text:match(p[1])
                    if a then
                        s[p[2]] = (s[p[2]] or 0) + tonumber(a)
                        if p[3] and b then s[p[3]] = (s[p[3]] or 0) + tonumber(b) end
                        if p[4] then s[p[4]] = (s[p[4]] or 0) + tonumber(a) end
                        hit = true
                        break
                    end
                end
                if not hit then
                    local v, what = text:match("^%+(%d+) (.+)$")
                    if v then
                        if what == "Spell Damage and Healing" then
                            s.SPELL_DAMAGE_DONE = (s.SPELL_DAMAGE_DONE or 0) + tonumber(v)
                            s.SPELL_HEALING_DONE = (s.SPELL_HEALING_DONE or 0) + tonumber(v)
                        elseif PLUS[what] then
                            s[PLUS[what]] = (s[PLUS[what]] or 0) + tonumber(v)
                        end
                    end
                end
            end
        end
    end
    return s
end

--- Zygor's score of stats `s` for spec rule `r`; `worn` (the item is on the
--- player) and `level` decide the cap halving.
function M.score(s, r, worn, level)
    if type(r) ~= "table" then return nil end
    local low = nil
    for _, w in pairs(r.stats) do if w > 0 and (low == nil or w < low) then low = w end end
    local white = (low or 1) * 0.1
    local total = 0
    for stat, v in pairs(s or {}) do
        local w = r.stats[stat]
        if w == nil and (stat == "ARMOR" or stat == "DAMAGE_PER_SECOND") then w = white end
        if w then
            if r.caps[stat] and not worn and (tonumber(level) or M.MAX_LEVEL) < M.MAX_LEVEL then w = w * 0.5 end
            total = total + v * w
        end
    end
    return total
end

-- audit P7: a link's tooltip stats are read once and cached by link (like
-- equip.lua's red_cache); a link names the exact item, so its stats never change
local stats_cache, stats_n = {}, 0
local function link_stats(link)
    local c = stats_cache[link]
    if c ~= nil then return c or nil end
    local lines = safe(function() return core.game_ui.get_hyperlink_tooltip(link) end)
    local st = (type(lines) == "table" and #lines >= 2) and M.stats_of(lines) or false
    stats_n = stats_n + 1
    if stats_n > 300 then stats_cache, stats_n = {}, 0 end
    stats_cache[link] = st
    return st or nil
end
local function link_score(player, link, worn, r)
    if type(link) ~= "string" or link == "" then return nil end
    local st = link_stats(link)
    if not st then return nil end
    return M.score(st, r, worn, safe(function() return player:get_level() end))
end

--- Score of a candidate (bag link) minus the worn item's (slot link): > 0 is
--- an upgrade. nil when it cannot be told (no weights, no tooltip data).
function M.delta(player, cand_link, worn_link)
    if not M.available() then return nil end
    local r = M.spec(player)
    if not r then return nil end
    local c = link_score(player, cand_link, false, r)
    if c == nil then return nil end
    if worn_link == nil then return c end
    local u = link_score(player, worn_link, true, r)
    if u == nil then return nil end
    return c - u
end

--- Score of one item link (for slot picking / rewards); nil when unknown.
function M.link_score(player, link, worn)
    if not M.available() then return nil end
    local r = M.spec(player)
    return r and link_score(player, link, worn, r) or nil
end

M._reset = function() rules, spec_cache.cls, stats_cache, stats_n = nil, nil, {}, 0 end
return M
