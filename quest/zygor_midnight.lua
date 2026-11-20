-- ============================================================================
-- Master Farmer - Zygor Forever
-- quest/zygor_midnight.lua - Zygor goal actions that exist only on Retail
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- 1.8.0 (user spec: Midnight-only behaviour in a module that runs only when
-- gamever.version() == "Midnight"; never registered on "Tbc", never folded
-- into Forever or Vanilla). These keys rely on systems TBC Classic does not
-- have (Goal.lua): scenarios, achievements, the Encounter Journal, garrison
-- buildings / followers / talents, housing, transmog appearances / sets,
-- toys, battle pets, player choices, world-quest queues, ExtraActionButton
-- and C_TradeSkillUI crafting; and the Retail meaning of learnmount /
-- learnpet / earn (spell, pet journal, currency - on TBC they count items,
-- quest/zygor_tbc.lua).
-- Zygor completes every one of them from its own checks; the goal table the
-- API gives (action, quest_id, npc_id, target_id, target, npc, is_complete)
-- carries none of their ids (scenario criteria, achievement, encounter...),
-- so the bot holds with the reason and Zygor's own is_complete moves on.
-- "text" keys are passed over like Zygor's display lines.
-- ============================================================================

local M = {}

local WAIT = {
    achieve = "an achievement", scenariobonus = "a scenario bonus objective", scenarioend = "the scenario to end",
    scenariogoal = "a scenario objective", scenariostage = "a scenario stage", scenariostart = "a scenario to start",
    killboss = "a dungeon boss (Encounter Journal)", havebuilding = "a garrison building", follower = "a garrison follower",
    specialtalent = "a class hall talent", specialtalentactive = "a class hall talent", houselevel = "the house level",
    petlevel = "a battle pet level", petspecies = "a battle pet", learnmount = "a mount spell",
    learnpet = "a pet journal pet", earn = "a currency amount",
}
local MANUAL = {
    appearance = "collect a transmog appearance", itemset = "collect a transmog set", furniture = "get a house decor item",
    toy = "learn a toy", playerchoice = "pick a player choice", questchoice = "pick a quest choice",
    extraaction = "press the extra action button", craft = "craft an item (profession window)",
    firstcraft = "make a first craft",
}
local TEXT = { worldquestqueue = true }     -- audit V7: achievetext is "text" in the base table

M.KINDS = { retail_wait = true, retail_manual = true }

function M.register(actions)
    for k in pairs(WAIT) do actions[k] = "retail_wait" end
    for k in pairs(MANUAL) do actions[k] = "retail_manual" end
    for k in pairs(TEXT) do actions[k] = "text" end
end

function M.handles(kind) return M.KINDS[kind] == true end

--- `C` = { guide, state, movement }. Holds with the reason (Zygor completes it).
function M.run(player, goal, kind, C)
    local guide, state, movement = C.guide, C.state, C.movement
    movement.nav_stop()
    local a = tostring(goal.action)
    if kind == "retail_manual" then
        state.set_note("Quest", string.format("PAUSED: Zygor step %d wants you to %s (%s) - do it yourself, then the bot carries on",
            guide.step_num(), MANUAL[a] or a, tostring(goal.target or "")))
    else
        state.set_note("Quest", string.format("Guide: waiting for Zygor - %s (%s %s)", WAIT[a] or a, a, tostring(goal.target or "")))
    end
    return true
end

M._WAIT, M._MANUAL = WAIT, MANUAL
return M
