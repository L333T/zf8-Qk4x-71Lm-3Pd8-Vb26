-- ============================================================================
-- Master Farmer - Zygor Forever
-- managems.lua - Mage mana gems: conjure between pulls, use in combat
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- 1.8.2 (user, hard-coded). Every call checked in Core_Api
-- Generated_Lua_API_Database (lua/izi/izi_spell.lua, izi_item.lua,
-- izi_game_object_extensions.lua, izi_sdk.lua, core.lua, enums.lua):
--   izi.get_player, izi.spell(id), izi.item(id), spell:is_learned,
--   spell:is_castable, spell:cast_safe(target, message, opts),
--   item:in_inventory, item:count, item:cooldown_up,
--   item:use_self_safe(message, opts), player:get_class, is_dead_or_ghost,
--   is_in_combat, is_casting, is_channeling, mana_pct (1-100),
--   enums.class_id.MAGE. Eating/drinking uses the existing resting module.
--
-- GATE  a Mage, alive. 1.8.3 (user: "remove gate for gem logic"): no
--       game-version gate - it runs on every client.
-- ITEMS Mana Ruby item 8008 / spell 10054, Mana Citrine item 8007 / spell
--       10053 (3864 is the crafting reagent Citrine - never this).
-- CONJURE  alive, out of combat, not eating/drinking, not casting or
--       channelling. Maintain Citrine first when learned and absent;
--       then maintain Ruby when learned and absent.
--       The walk is held for the cast: movement/nav N.pause("conjure") (on
--       Sentinel a stop, the destination kept) before cast_safe,
--       N.resume("conjure") when the cast ends, fails, or combat starts. A walking player is held first
--       (pause) and the cast goes out once standing (is_castable checks
--       movement); no movement keys, no simple_movement.
-- USE   in combat, alive, not casting or channelling. Citrine is preferred
--       at <= 50%; Ruby remains a fallback at <= 35%. Requires the gem in
--       bags and its cooldown ready -> use_self_safe. Never out of combat;
--       no core.input use for the same item.
-- One action per update: tick() returns true when it acted (main.lua then
-- ends the tick - the quest step does not advance on it).
-- ============================================================================

local M = {}

M.RUBY_ITEM, M.RUBY_SPELL = 8008, 10054
M.CITRINE_ITEM, M.CITRINE_SPELL = 8007, 10053
M.RUBY_AT, M.CITRINE_AT = 35, 50
M.HOLD_MAX = 3.0          -- s: a pause waiting for the player to stand still
M.CAST_MAX = 6.0          -- s: a conjure cast (3 s) and its start
M.RETRY_GAP = 10.0        -- s: after a refused conjure, before the next try
M.REASON = "conjure"

local izi_mod, enums_mod = nil, nil
local obj = nil           -- the four izi objects, created once
local st = { paused = false, phase = nil, t = 0, cast_seen = false, block_until = -1e9 }

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "act", fmt, ...) end
end

local function izi()
    if izi_mod == nil then
        local ok, m = pcall(require, "common/izi_sdk")
        izi_mod = (ok and type(m) == "table") and m or false
    end
    return izi_mod or nil
end

local function objects()
    if obj == nil then
        local z = izi()
        if not z then return nil end
        obj = {
            ruby_spell = z.spell(M.RUBY_SPELL),
            citrine_spell = z.spell(M.CITRINE_SPELL),
            ruby_item = z.item(M.RUBY_ITEM),
            citrine_item = z.item(M.CITRINE_ITEM),
        }
    end
    return obj
end

local function mage(player)
    if enums_mod == nil then
        local ok, m = pcall(require, "common/enums")
        enums_mod = (ok and type(m) == "table") and m or false
    end
    local want = enums_mod and enums_mod.class_id and enums_mod.class_id.MAGE or 8
    return safe(function() return player:get_class() end) == want
end

-- 1.8.4 (user: "gems not casting"; log 18:50, v1.8.3: the block ran every
-- tick and never conjured, no trail at all): izi's spell:is_learned answered
-- no - conjure.lua (which conjures food / water fine on this client) reads
-- learned through core.spell_book.has_spell / is_spell_known because one of
-- them answers wrong here. Each check now also asks the core call conjure.lua
-- uses, and a refused izi cast_safe goes out through spellcheck.cast_safe
-- (core API, the path conjure.lua casts with). Why nothing was conjured is
-- logged every DIAG_GAP s.
local function in_bags(item, id)
    if item ~= nil and safe(function() return item:in_inventory() end) == true
        and (safe(function() return item:count() end) or 0) > 0 then
        return true
    end
    local okb, bags = pcall(require, "bags")
    return okb and type(bags) == "table" and type(bags.count) == "function" and (safe(function() return bags.count(id) end) or 0) > 0
end

-- duplicate (audit D1): spell known -> spellbook.id_in_book is the copy to keep
local function learned(spell, id)
    if safe(function() return spell:is_learned() end) == true then return true end
    return safe(function() return core.spell_book.has_spell(id) end) == true
        or safe(function() return core.spell_book.is_spell_known(id) end) == true
        or safe(function() return core.spell_book.is_spell_learned(id) end) == true
end

local function castable(spell, id, player)
    if safe(function() return spell:is_castable() end) == true then return true end
    if safe(function() return player:is_moving() end) == true then return false end
    local ok_s, sc = pcall(require, "spellcheck")
    return ok_s and type(sc) == "table" and type(sc.core_castable) == "function"
        and safe(function() return sc.core_castable(id, nil) end) == true
end

M.DIAG_GAP = 30
local diag_t = -1e9
local function diag(now, fmt, ...)
    if now - diag_t < M.DIAG_GAP then return end
    diag_t = now
    trail("mana gem: " .. fmt, ...)
end

local function busy_casting(player)
    return safe(function() return player:is_casting() end) == true
        or safe(function() return player:is_channeling() end) == true
end

local function nav()
    local ok, n = pcall(require, "movement/nav")
    return (ok and type(n) == "table") and n or nil
end

local function release(why)
    local paused = st.paused
    st.paused, st.phase, st.core_next, st.cast_seen = false, nil, false, false
    if not paused then return end
    local N = nav()
    if N then pcall(N.resume, M.REASON) end
    st.paused, st.phase = false, nil
    trail("mana gem: walk resumed (%s)", tostring(why))
end

local function hold(now)
    if st.paused then return end
    local N = nav()
    if N and type(N.busy) == "function" and N.busy() then
        pcall(N.pause, M.REASON)
        st.paused = true
    end
    st.t = now
end

--- One update. True when it acted (conjured, used a gem, or holds the walk for a conjure).
function M.tick(player)
    local z = izi()
    if not z then return false end
    player = player or safe(function() return z.get_player() end)
    if not player or not mage(player) then release("not a mage") return false end
    if safe(function() return player:is_dead_or_ghost() end) == true then release("dead") return false end
    local o = objects()
    if not o then return false end
    local now = safe(function() return z.now() end) or safe(function() return core.time() end) or 0
    local fighting = safe(function() return player:is_in_combat() end) == true

    if not fighting then
        local ok, rest = pcall(require,"resting")
        if ok and type(rest)=="table" and (safe(function() return rest.is_resting() end)==true
            or safe(function() return rest.is_consuming(player) end)==true) then
            release("eating or drinking")
            return false
        end
    end

    -- a conjure under way: hold until the cast ends, fails, or combat starts
    if st.phase then
        if fighting then release("combat") st.block_until = now + 1
        elseif st.phase == "cast" then
            if busy_casting(player) then st.cast_seen = true return true end
            if st.cast_seen or now - st.t > M.CAST_MAX then release(st.cast_seen and "cast ended" or "cast never started") return false end
            return true
        end
    end

    -- USE (combat only)
    if fighting then
        if busy_casting(player) then return false end
        local mana = tonumber(safe(function() return player:mana_pct() end))
        if not mana then return false end
        if in_bags(o.citrine_item, M.CITRINE_ITEM) and safe(function() return o.citrine_item:cooldown_up() end) == true and mana <= M.CITRINE_AT then
            if safe(function() return o.citrine_item:use_self_safe("Mana Citrine") end) == true then
                trail("mana gem: Mana Citrine used at %.0f%% mana", mana)
                return true
            end
        end
        if in_bags(o.ruby_item, M.RUBY_ITEM) and safe(function() return o.ruby_item:cooldown_up() end) == true and mana <= M.RUBY_AT then
            if safe(function() return o.ruby_item:use_self_safe("Mana Ruby") end) == true then
                trail("mana gem: Mana Ruby used at %.0f%% mana", mana)
                return true
            end
        end
        return false
    end

    -- CONJURE (out of combat, not eating/drinking or casting)
    if now < st.block_until then return false end
    if busy_casting(player) then return false end
    local spell, sid, name = nil, nil, nil
    local ruby_known = learned(o.ruby_spell, M.RUBY_SPELL)
    local citrine_known = learned(o.citrine_spell, M.CITRINE_SPELL)
    local have_ruby, have_citrine = in_bags(o.ruby_item, M.RUBY_ITEM), in_bags(o.citrine_item, M.CITRINE_ITEM)
    if citrine_known and not have_citrine then
        spell, sid, name = o.citrine_spell, M.CITRINE_SPELL, "Conjure Mana Citrine"
    elseif ruby_known and not have_ruby then
        spell, sid, name = o.ruby_spell, M.RUBY_SPELL, "Conjure Mana Ruby"
    end
    if not spell then
        st.block_until = now + 5             -- audit P5: no book / bag scan every tick
        release("no gem to conjure")
        diag(now, "nothing to conjure - Ruby spell %s (in bags %s), Citrine spell %s (in bags %s)",
            ruby_known and "learned" or "not learned", tostring(have_ruby),
            citrine_known and "learned" or "not learned", tostring(have_citrine))
        return false
    end
    if not castable(spell, sid, player) then
        -- moving (is_castable checks it): the walk is held, the cast goes out once standing
        local moving = safe(function() return player:is_moving() end) == true
        if moving and not st.phase then
            hold(now)
            st.phase = "stop"
            return true
        end
        if st.phase == "stop" and moving and now - st.t <= M.HOLD_MAX then return true end
        release("not castable")
        diag(now, "%s not castable now (mana %s%%, moving %s)", name,
            tostring(safe(function() return math.floor(player:mana_pct()) end)), tostring(safe(function() return player:is_moving() end)))
        st.block_until = now + M.RETRY_GAP
        return false
    end
    hold(now)
    -- audit R4: one send per tick - izi cast_safe; when it refuses, the core-API
    -- cast conjure.lua uses goes out on a later tick (never both in one tick)
    local ok
    if st.core_next then
        st.core_next = false
        local ok_s, sc = pcall(require, "spellcheck")
        ok = ok_s and type(sc) == "table" and type(sc.cast_safe) == "function"
            and safe(function() return sc.cast_safe(spell, nil, name) end) == true
    else
        ok = safe(function() return spell:cast_safe(player, name) end) == true
        if not ok then
            st.core_next = true
            st.block_until = now + 0.2
            st.phase = "retry"          -- still held: combat or a refusal on the retry releases the walk
            return true
        end
    end
    if ok then
        st.phase, st.t, st.cast_seen = "cast", now, false
        trail("mana gem: %s", name)
    else
        trail("mana gem: %s refused by izi cast_safe and spellcheck.cast_safe", name)
        release("cast refused")
        st.block_until = now + M.RETRY_GAP
    end
    return true
end

--- Stop / reload: give the walk back.
function M.reset()
    release("reset")
    st.block_until = -1e9
end

M._st = st
M._reset_objects = function() obj, izi_mod, enums_mod = nil, nil, nil end
return M
