-- ============================================================================
-- Master Farmer - Zygor Forever
-- quest/zygor_tbc.lua - Zygor goal actions that only mean this on TBC Classic
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- 1.8.0 (user spec: TBC-only behaviour in a module that runs only when
-- gamever.is_tbc()). Read from the Anniversary add-on (ZygorGuidesViewer
-- ClassicTBCAnniv, Goal.lua + Code-TBC\Goal.lua, which loads after it):
--   * Code-TBC\Goal.lua:23-35 makes learnmount, learnpet and earn copies of
--     GOALTYPES['get'] (complete when GetItemCount >= count) - on TBC they are
--     item goals, so they are the engine's "collect" kind here. On Retail they
--     are spell / pet-journal / currency checks (quest/zygor_midnight.lua).
--   * abandon: complete when the quests are no longer in the log -
--     core.quests.abandon_quest_by_id (documented; IRREVERSIBLE - only what
--     the guide line itself names).
--   * trash: complete when GetItemCount(item) == 0 - core.input.
--     destroy_container_item, one bag slot per tick, never the Hearthstone.
--   * bank: complete when the item has left the bank for the bags (Zygor
--     moves it at a banker); the API has no bank call - the bot holds and asks.
--   * ActionBar.lua order (SetActionButtonsQueued 178-290): the step's
--     incomplete goals, usable actions (use / useany / cast / equip / openskill /
--     create / petaction) BEFORE npc actions (talk / clicknpc / kill); accept,
--     turnin and goto are not buttons and keep their place. goal_order gives
--     guide.compute_goal that order. A use / equip goal whose item is not in the
--     bags (Zygor's greyed-out icon, count 0) is NOT moved ahead - the kills
--     that drop it come first.
-- Dispatched from quest/engine.lua (one action per tick); registered from
-- quest/guide.lua only on "Tbc".
-- ============================================================================

local M = {}

M.KINDS = { abandon = true, trash = true, bank = true, city_tour = true, allegiance = true }

-- Installed Alliance Terokkar guide: City of Light is a servant escort;
-- both allegiance accepts explicitly carry |or |noautoaccept.
function M.classify(goal)
    local q = tonumber(goal.quest_id)
    if goal.action == "q" and q == 10211 then return "city_tour" end
    if goal.action == "accept" and (q == 10551 or q == 10552) then return "allegiance" end
end

-- Titles verified in the installed Alliance Terokkar guide, not NPC names.
M.QUEST_TITLES = { [10210] = "A'dal", [10211] = "City of Light",
    [10551] = "Allegiance to the Aldor", [10552] = "Allegiance to the Scryers",
    [10554] = "Ishanah", [10325] = "Marks of Kil'jaeden", [10021] = "Restoring the Light" }
function M.quest_title(id) return M.QUEST_TITLES[tonumber(id)] end

-- Verified in installed Guides-TBC/Reputations/ZygorReputationsCommonCLASSIC.lua.
-- Select only a currently offered interrogation option, never a guessed row.
function M.gossip_option(unit, goals, rows)
    local ok,id = pcall(function()
        if unit and unit:is_valid() then return unit:get_npc_id() end
    end)
    if not ok or id ~= 18351 then return nil end
    local active = false
    for _,g in ipairs(goals or {}) do
        if g.action=="q" and tonumber(g.quest_id)==9918 and g.is_complete~=true then active=true break end
    end
    if not active then return nil end
    local allowed = {[117943]=true,[118052]=true,[117962]=true,[117944]=true}
    for _,row in ipairs(type(rows)=="table" and rows or {}) do
        if type(row)=="table" and allowed[row.gossip_option_id] then return row.gossip_option_id end
    end
end

local tour = { t = -1e9, following = false }
function M.city_tour(player, C)
    local ok, targeting = pcall(require, "targeting")
    local unit = ok and targeting.find_named(player, "Khadgar's Servant", nil, 100) or nil
    local valid, live = pcall(function() return unit and unit:is_valid() end)
    local p, me
    if valid and live then
        local good, a, b = pcall(function() return unit:get_position(), player:get_position() end)
        if good then p, me = a, b end
    end
    if not p or not me then
        C.movement.nav_stop()
        tour.following = false
        C.state.set_note("Quest", "Guide: City of Light - waiting for Khadgar's Servant to be visible")
        return true
    end
    local distance = math.sqrt((p.x-me.x)^2+(p.y-me.y)^2+(p.z-me.z)^2)
    local t = core.time()
    if distance <= 8 then
        if tour.following then C.movement.nav_stop() end
        tour.following = false
    elseif distance > 12 and t-tour.t >= 1 then
        tour.t, tour.following = t, true
        C.walk_to({x=p.x,y=p.y,z=p.z}, "Khadgar's Servant", 8)
    end
    C.state.set_note("Quest", "Guide: following Khadgar's Servant - waiting for the tour to finish")
    return true
end

--- The TBC meaning of the keys whose meaning differs by client.
function M.register(actions, item_goals)
    actions.learnmount = "collect"      -- Code-TBC\Goal.lua:23  = GOALTYPES['get']
    actions.learnpet   = "collect"      -- Code-TBC\Goal.lua:24
    actions.earn       = "collect"      -- Code-TBC\Goal.lua:35
    actions.abandon    = "abandon"
    actions.trash      = "trash"
    actions.bank       = "bank"
    if type(item_goals) == "table" then
        item_goals.trash, item_goals.bank = true, true      -- target_id is the item id
    end
end

function M.handles(kind) return M.KINDS[kind] == true end

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "act", fmt, ...) end
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    return (ok and type(izi) == "table" and type(izi.now) == "function") and izi.now() or 0
end

local USABLE = { use = true, useany = true, cast = true, equip = true, equipped = true, openskill = true,
    create = true, petaction = true }
local NPC = { talk = true, clicknpc = true, kill = true }
M.USABLE, M.NPC = USABLE, NPC

--- ActionBar order for the step's goals: an array of goal indices. `have(g)`
--- says whether a use / equip goal's item is in the bags.
function M.goal_order(goals, have)
    local order, slots, usable, npc = {}, {}, {}, {}
    for i = 1, #goals do
        order[i] = i
        local g = goals[i]
        if type(g) == "table" and g.is_complete ~= true then
            local a = g.action
            local ready = USABLE[a] and (a == "cast" or a == "openskill" or a == "create" or a == "petaction"
                or (type(have) == "function" and have(g, i) == true))
            if ready then
                slots[#slots + 1] = i
                usable[#usable + 1] = i
            elseif NPC[a] then
                slots[#slots + 1] = i
                npc[#npc + 1] = i
            end
        end
    end
    if #usable == 0 or #npc == 0 then return order end
    local seq = {}
    for i = 1, #usable do seq[#seq + 1] = usable[i] end
    for i = 1, #npc do seq[#seq + 1] = npc[i] end
    for k = 1, #slots do order[slots[k]] = seq[k] end
    return order
end

-- ----------------------------------------------------------------------------
-- the TBC actions (one per tick)
-- ----------------------------------------------------------------------------
local st = { key = nil, t = -1e9, tries = 0 }
M.GAP, M.TRIES = 2.0, 3
local NEVER_TRASH = { [6948] = true }        -- the Hearthstone

local function step_key(guide, goal)
    if guide.goal_key then return guide.goal_key(goal) end
    return tostring(guide.step_num()) .. "|" .. tostring(goal.index)
end

local function bag_entries(player, item_id)
    local out = {}
    local ok_b, bags = pcall(require, "bags")
    local list = ok_b and type(bags) == "table" and type(bags.list) == "function" and bags.list(player) or {}
    for i = 1, #list do
        if list[i].item_id == item_id then out[#out + 1] = list[i] end
    end
    return out
end

--- Run one TBC action. `C` = { guide, state, movement }. True while it holds the tick.
function M.run(player, goal, kind, C)
    if kind == "city_tour" then return M.city_tour(player, C) end
    if kind == "allegiance" then
        C.movement.nav_stop()
        C.state.set_note("Quest", "Guide: choose Aldor or Scryers at Khadgar; Zygor will resume after acceptance")
        return true
    end
    local guide, state, movement = C.guide, C.state, C.movement
    local key = step_key(guide, goal)
    if st.key ~= key then st.key, st.t, st.tries = key, -1e9, 0 end
    local t = now()
    if kind == "bank" then
        movement.nav_stop()
        state.set_note("Quest", string.format("PAUSED: Zygor step %d wants %s taken out of the bank - the API has no bank call; do it at a banker, then the bot carries on",
            guide.step_num(), tostring(goal.target or goal.item_id or "an item")))
        return true
    end
    if safe(function() return player:is_in_combat() end) == true then return false end
    -- duplicate (audit D7): abandon quest -> npc.abandon is the copy to keep
    if kind == "abandon" then
        local qid = tonumber(goal.quest_id)
        if not qid then
            state.set_note("Quest", "Guide: abandon - the goal names no quest id")
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
        if safe(function() return core.quests.is_on_quest(qid) end) ~= true then
            trail("abandon (Zygor): quest %d is not in the log - done", qid)
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
        if st.tries >= M.TRIES then
            trail("abandon (Zygor): quest %d still in the log after %d tries - next goal", qid, st.tries)
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
        if t - st.t >= M.GAP then
            st.t, st.tries = t, st.tries + 1
            local sent = safe(function() return core.quests.abandon_quest_by_id(qid) end) == true
            trail("abandon (Zygor): quest %d %s (try %d)", qid, sent and "abandoned" or "refused", st.tries)
        end
        state.set_note("Quest", "Guide: abandoning quest " .. tostring(qid))
        return true
    end
    -- duplicate (audit D2): destroy a bag item -> vendor.destroy_slot is the copy to keep
    if kind == "trash" then
        local id = tonumber(goal.item_id or goal.target_id)
        if not id or NEVER_TRASH[id] then
            trail("trash (Zygor): %s - kept, next goal", id and "the Hearthstone" or "no item id")
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
        local list = bag_entries(player, id)
        if #list == 0 then
            trail("trash (Zygor): item %d gone from the bags - done", id)
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
        if st.tries >= M.TRIES * #list + M.TRIES then
            trail("trash (Zygor): item %d would not delete - next goal", id)
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
        if t - st.t >= 1.0 then
            st.t, st.tries = t, st.tries + 1
            movement.nav_stop()
            local e = list[1]
            pcall(function() require("bags").invalidate() end)   -- audit P6
            local done = safe(function() return core.input.destroy_container_item(e.bag, e.slot) end) == true
            trail("trash (Zygor): item %d bag %d slot %d %s", id, e.bag, e.slot, done and "deleted" or "refused")
        end
        state.set_note("Quest", "Guide: deleting " .. tostring(goal.target or id))
        return true
    end
    return false
end

M._st = st
return M
