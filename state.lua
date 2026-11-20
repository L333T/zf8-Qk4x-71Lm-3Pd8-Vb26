-- ============================================================================
-- Master Farmer - Zygor Forever
-- Shared runtime state (no leaked globals)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local state = {
    note = "",
    note_head = "",
    cached_pos = nil,
    cached_now = 0,
    last_action = "Idle",
}

state.grind = {
    step = 1,
    move = 1,
    finished = false,        -- 2.151.0: a non-loop profile reached its last node
    scan_until = 0,
    black_until = 0,
    killed = {},
    killed_order = {},
    killed_reset = 0,
}

state.target = {
    unit = nil,
    guid = nil,
    x = nil,
    y = nil,
    z = nil,
    kind = nil,
}

state.dead = {
    released_at = 0,
    waiting = false,
    corpse = nil,
    retrieve_at = 0,
}

state.combat = {
    -- kiting is owned by movement.lua's combat controller, not by the rotation
    nova_at = 0,
    face_at = 0,
    unreachable = {},
}

state.quest = {
    id = nil,
    step = 1,
    interact_until = 0,
    skipped = {},
}

state.vendor = {
    active = false,
    repaired = false,
    sold = 0,
    interact_until = 0,
    done_until = 0,
    lack_gold = 0,
    wait_npc = 0,
    tries = 0,
}

local last_printed_note = ""
local last_printed_action = ""

local function console_on()
    local ok, gui = pcall(require, "gui")
    if not ok or not gui or type(gui.is_on) ~= "function" then
        return false
    end
    return true               -- 1.75.0: the action log records every action (no console toggle any more)
end

local function console_print(text)
    local ok, al = pcall(require, "actlog")
    if ok and type(al) == "table" and type(al.action) == "function" then pcall(al.action, text) end
end

-- The General tab toggle. A repeat of the same line is not printed again.
function state.report_action(text)
    if type(text) ~= "string" or text == "" then
        return
    end
    if not console_on() then
        last_printed_action = ""
        return
    end
    if text == last_printed_action then
        return
    end
    last_printed_action = text
    console_print(text)
end

local NOTE_REPEAT_S = 5
local note_history, note_history_n = {}, 0
function state.set_note(head, text)
    -- 1.75.0: when the status line last CHANGED (a stale status is a stall signature in the action log)
    local nh, nt = head or "", text or ""
    if nh ~= state.note_head or nt ~= state.note then
        local okt, tt = pcall(function() return core.time() end)
        state.note_t = okt and tonumber(tt) or state.note_t
    end
    state.note_head = head or ""
    state.note = text or ""
    local line
    if state.note_head ~= "" and state.note ~= "" then
        line = state.note_head .. ": " .. state.note
    elseif state.note ~= "" then
        line = state.note
    else
        line = state.note_head
    end
    if line == "" then
        return
    end
    if not console_on() then
        last_printed_note = ""
        return
    end
    if line == last_printed_note then
        return
    end
    -- 2026-10-25 (chat log: "Load: Waiting for spellbook 5.0s ... 0.1s", 50 lines; "Walking
    -- to corpse 17y ... 4y"; "approaching 55 yd"): a line that differs from the last one
    -- printed only in its numbers (a countdown) is printed at most every NOTE_REPEAT_S s
    local shape = line:gsub("%d+%.?%d*", "#")
    local t_now = 0
    pcall(function() t_now = core.time() end)
    local previous = note_history[shape]
    if previous and t_now >= previous and (t_now - previous) < NOTE_REPEAT_S then
        last_printed_note = line
        return
    end
    if not previous then note_history_n = note_history_n + 1 end
    if note_history_n > 128 then note_history, note_history_n = {}, 1 end
    note_history[shape] = t_now
    last_printed_note = line
    console_print(line)
end

-- ONE CURRENT TARGET (2.143.0). state.target is the authority. Other
-- copies (combat.lua's hold latch) register here so clearing the target
-- clears them too - a target an engine dropped (unreachable, released) was
-- otherwise still held by the latch and could be picked up again by a caller
-- that passes no target (Rotation Only).
state.on_target_reset = {}

function state.reset_target()
    state.target.unit = nil
    state.target.guid = nil
    state.target.x = nil
    state.target.y = nil
    state.target.z = nil
    state.target.kind = nil
    for i = 1, #state.on_target_reset do
        pcall(state.on_target_reset[i])
    end
end

local KILLED_MAX = 48

local function guid_key(guid)
    if guid == nil then
        return nil
    end
    local t = type(guid)
    if t == "string" then
        if guid == "" then
            return nil
        end
        return guid
    end
    if t == "number" then
        return tostring(guid)
    end
    local ok, text = pcall(tostring, guid)
    if ok and type(text) == "string" and text ~= "" then
        return text
    end
    return nil
end

function state.mark_killed(guid)
    local key = guid_key(guid)
    if not key then
        return
    end
    local killed = state.grind.killed
    if killed[key] then
        return
    end
    killed[key] = true
    local order = state.grind.killed_order
    if type(order) ~= "table" then
        order = {}
        state.grind.killed_order = order
    end
    order[#order + 1] = key
    while #order > KILLED_MAX do
        local old = table.remove(order, 1)
        if old then
            killed[old] = nil
        end
    end
end

-- Mobs the bot has targeted to kill, GUID -> when (2.48.0). The loot scan
-- treats a corpse from this list as the bot's own kill.
state.engaged = {}
local ENGAGED_TTL = 300

function state.note_engaged(guid)
    local key = guid_key(guid)
    if not key then
        return
    end
    local now = 0
    pcall(function() now = core.time() end)
    state.engaged[key] = now
    -- Keep it small: drop anything older than the TTL now and then.
    local n = 0
    for _ in pairs(state.engaged) do n = n + 1 end
    if n > 64 then
        for k, t in pairs(state.engaged) do
            if (now - t) > ENGAGED_TTL then
                state.engaged[k] = nil
            end
        end
    end
end

function state.was_engaged(guid)
    local key = guid_key(guid)
    local t = key and state.engaged[key]
    if not t then
        return false
    end
    local now = 0
    pcall(function() now = core.time() end)
    return (now - t) <= ENGAGED_TTL
end

function state.was_killed(guid)
    local key = guid_key(guid)
    if not key then
        return false
    end
    return state.grind.killed[key] == true
end

local UNREACH_TTL = 45.0

local function now_s()
    local ok, t = pcall(function()
        return core.time()
    end)
    if ok and type(t) == "number" then
        return t
    end
    return 0
end

function state.mark_unreachable(guid)
    local key = guid_key(guid)
    if not key then
        return
    end
    if type(state.combat.unreachable) ~= "table" then
        state.combat.unreachable = {}
    end
    -- 3.0.0: bounded - a long session marks many mobs; past 200 start over
    local u = state.combat.unreachable
    if u[key] == nil then
        state.unreachable_n = (state.unreachable_n or 0) + 1
        if state.unreachable_n > 200 then
            for k in pairs(u) do u[k] = nil end
            state.unreachable_n = 1
        end
    end
    u[key] = now_s()
end

function state.is_unreachable(guid)
    local key = guid_key(guid)
    if not key then
        return false
    end
    local bag = state.combat.unreachable
    if type(bag) ~= "table" then
        return false
    end
    local stamped = bag[key]
    if type(stamped) ~= "number" then
        return false
    end
    if (now_s() - stamped) > UNREACH_TTL then
        bag[key] = nil
        return false
    end
    return true
end

return state
