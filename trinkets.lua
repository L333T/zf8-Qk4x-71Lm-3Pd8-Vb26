-- ============================================================================
-- Master Farmer - Zygor Forever
-- trinkets.lua - on-use trinkets (1.7.12)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Folder: Zygor_Forever
-- ============================================================================
-- User (2026-10-18): "use trinkets, add an enable / disable option, get the
-- trinket information from the slot and decide how to use it."
--
-- READ (every SCAN_GAP s, Core API only - no izi):
--   player:get_item_at_inventory_slot(13 / 14)   (1-based: 13 = trinket 1, 14 = 2)
--     .object:get_item_id() / get_name()
--   core.quests.get_item_spell(id)              the "Use:" spell; none = passive (skipped)
--   core.spell_book.get_spell_description(sid)  its tooltip text, which decides
--                                               the KIND below (empty at first for
--                                               an item not loaded yet: read again)
-- KIND (from the tooltip):
--   escape   removes stun / fear / charm / polymorph / movement impairing effects
--            -> only while the player is under loss of control
--   heal     restores / heals health           -> health under HEAL_PCT, in combat
--   mana     restores mana                     -> mana under MANA_PCT, in combat
--   defense  absorbs / reduces damage / armor / dodge / damage taken
--            -> health under DEFENSE_PCT, in combat
--   attack   deals / inflicts damage to a target -> at the live target in range
--            (core.spell_book.is_item_in_range), core.input.use_item_target
--   burst    anything else (a stat / damage / haste buff) -> in combat with a
--            live target above BURST_TARGET_PCT health, or 2+ enemies on the player
-- USE: off cooldown (player:get_item_cooldown), usable (core.spell_book.is_item_usable),
-- in combat, alive, not mounted, not channelling, not resting; self kinds with
-- core.input.use_item, attack with core.input.use_item_target. One try per slot
-- every USE_GAP s.
-- ============================================================================

local M = {}

M.SLOTS = { 13, 14 }
M.HEAL_PCT, M.MANA_PCT, M.DEFENSE_PCT, M.BURST_TARGET_PCT = 45, 35, 60, 40
local SCAN_GAP, USE_GAP = 2.0, 0.5

local info = {}            -- slot -> { id, name, spell_id, kind } or false
local last_scan, last_try, logged = -1e9, {}, {}

local function call(obj, name, ...)
    local f = obj and obj[name]
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, obj, ...)
    if ok then return r end
    return nil
end
local function now()
    local ok, t = pcall(core.time)
    return ok and type(t) == "number" and t or 0
end
local function trail(fmt, ...)
    local ok, elog = pcall(require, "errorlog")
    if ok and type(elog) == "table" and type(elog.trail) == "function" then pcall(elog.trail, "trinket", fmt, ...) end
end

--- The kind of use for a "Use:" tooltip text (lower case read).
function M.kind_of(text)
    local t = string.lower(tostring(text or ""))
    if t == "" then return nil end
    if t:find("removes", 1, true) and (t:find("stun", 1, true) or t:find("fear", 1, true) or t:find("charm", 1, true)
        or t:find("polymorph", 1, true) or t:find("movement impairing", 1, true) or t:find("loss of control", 1, true)) then
        return "escape"
    end
    if (t:find("restores", 1, true) or t:find("regenerate", 1, true)) and t:find("mana", 1, true)
        and not t:find("health", 1, true) then
        return "mana"
    end
    -- a heal on the player - not "increases healing done" (a healer's burst buff)
    if not t:find("healing done", 1, true) and not t:find("increases healing", 1, true)
        and (t:find("heals you", 1, true) or t:find("heal you", 1, true) or t:find("instantly heals", 1, true)
            or (t:find("restores", 1, true) and t:find("health", 1, true))) then
        return "heal"
    end
    if t:find("absorb", 1, true) or t:find("damage taken", 1, true) or t:find("armor", 1, true)
        or t:find("dodge", 1, true) or t:find("reduces damage", 1, true) or t:find("block", 1, true) then
        return "defense"
    end
    if (t:find("damage to", 1, true) or t:find("deals", 1, true) or t:find("inflicts", 1, true))
        and (t:find("target", 1, true) or t:find("enemy", 1, true)) and not t:find("increases", 1, true) then
        return "attack"
    end
    return "burst"
end

local function read_slot(p, slot)
    local row = call(p, "get_item_at_inventory_slot", slot)
    local obj = type(row) == "table" and row.object or nil
    if not obj then return false end
    local id = tonumber(call(obj, "get_item_id")) or 0
    if id <= 0 then return false end
    local ok, sp = pcall(core.quests.get_item_spell, id)
    local sid = (ok and type(sp) == "table") and tonumber(sp.spell_id) or 0
    if not sid or sid <= 0 then return false end                  -- passive: no "Use:"
    local okd, desc = pcall(core.spell_book.get_spell_description, sid)
    local kind = M.kind_of(okd and desc or "")
    local name = call(obj, "get_name")
    local e = { id = id, name = (type(name) == "string" and name ~= "") and name or ("item " .. id), spell_id = sid,
        kind = kind, text = okd and desc or "" }
    if kind and logged[slot] ~= id then
        logged[slot] = id
        trail("slot %d: %s - on use (%s): %s", slot, e.name, kind, string.sub(tostring(e.text), 1, 90))
    end
    return e
end

--- Re-read both slots (throttled); a kind not known yet (tooltip not loaded) is read again.
function M.scan(p, t, force)
    if not p then return end
    if not force and (t - last_scan) < SCAN_GAP then return end
    last_scan = t
    for _, slot in ipairs(M.SLOTS) do info[slot] = read_slot(p, slot) end
end

function M.at(slot) return info[slot] or nil end

local function pct(cur, max)
    cur, max = tonumber(cur), tonumber(max)
    if not cur or not max or max <= 0 then return 100 end
    return cur / max * 100
end
local function health_pct(u)
    local v = tonumber(call(u, "get_health_percentage"))
    if v then return v <= 1 and v * 100 or v end
    return pct(call(u, "get_health"), call(u, "get_max_health"))
end
local function mana_pct(p)
    local ok, power = pcall(require, "power")
    if ok and type(power) == "table" and type(power.mana_pct) == "function" then
        local okm, v = pcall(power.mana_pct, p)
        if okm and type(v) == "number" then return v end
    end
    return 100
end

--- Should the trinket of `kind` be used now? (pure decision, ctx from tick)
function M.wanted(kind, ctx)
    if kind == "escape" then return ctx.controlled == true end
    if not ctx.in_combat then return false end
    if kind == "heal" then return ctx.hp < M.HEAL_PCT end
    if kind == "mana" then return ctx.has_mana and ctx.mana < M.MANA_PCT end
    if kind == "defense" then return ctx.hp < M.DEFENSE_PCT end
    if kind == "attack" then return ctx.target_live == true and ctx.target_in_range == true end
    if kind == "burst" then
        return (ctx.target_live == true and (ctx.target_hp or 0) > M.BURST_TARGET_PCT) or (ctx.enemies or 0) >= 2
    end
    return false
end

--- Every bot tick (main.lua): use what the moment calls for.
function M.tick(p, target, enemies)
    if not p then return end
    local t = now()
    M.scan(p, t)
    if call(p, "is_dead") == true or call(p, "is_ghost") == true or call(p, "is_mounted") == true then return end
    if call(p, "is_channelling_spell") == true then return end
    local healing = package.loaded["healing"]
    if type(healing) == "table" and type(healing.is_resting) == "function" and healing.is_resting() == true then return end
    local loc = call(p, "get_loss_of_control_info")
    local ctx = {
        in_combat = call(p, "is_in_combat") == true,
        controlled = type(loc) == "table" and loc.valid == true,
        hp = health_pct(p),
        mana = mana_pct(p),
        has_mana = (function() local ok, pw = pcall(require, "power")
            return ok and type(pw) == "table" and type(pw.has_mana) == "function" and pw.has_mana(p) == true end)(),
        enemies = tonumber(enemies) or 0,
        target_live = target ~= nil and call(target, "is_valid") == true and call(target, "is_dead_or_ghost") ~= true,
    }
    if ctx.target_live then ctx.target_hp = health_pct(target) end
    for _, slot in ipairs(M.SLOTS) do
        local tr = info[slot]
        if tr and tr.kind and (t - (last_try[slot] or -1e9)) >= USE_GAP then
            if tr.kind == "attack" and ctx.target_live then
                local okr, inr = pcall(core.spell_book.is_item_in_range, tr.id, target)
                ctx.target_in_range = not okr or inr ~= false
            end
            if M.wanted(tr.kind, ctx) then
                last_try[slot] = t
                local cd = tonumber(call(p, "get_item_cooldown", tr.id)) or 0
                local oku, usable = pcall(core.spell_book.is_item_usable, tr.id)
                if cd <= 0 and not (oku and usable == false) then
                    local ok
                    if tr.kind == "attack" then
                        ok = select(2, pcall(core.input.use_item_target, tr.id, target))
                    else
                        ok = select(2, pcall(core.input.use_item, tr.id))
                    end
                    if ok == true then
                        trail("used %s (slot %d, %s) - hp %.0f%%, mana %.0f%%", tr.name, slot, tr.kind, ctx.hp, ctx.mana)
                        return true                        -- audit Q2: at most one trinket per tick
                    end
                end
            end
        end
    end
    return false
end

function M._reset() info, last_scan, last_try, logged = {}, -1e9, {}, {} end

return M
