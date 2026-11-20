-- ============================================================================
-- Master Farmer - Automated Zygor Forever
-- Guide adapter - Zygor Guides (core.addons.zygor)
-- ============================================================================
-- Forked from the Questing & Grinding guide adapter (Grindbot 4.0.0). The
-- RestedXP reads are gone: NO core.addons.rested_xp call is made anywhere in
-- this product. The engine still asks the same questions (what is the goal,
-- what kind, which targets, which waypoints), answered from Zygor.
--
-- THE SEVEN ZYGOR READS (documented, core.addons.zygor):
--   is_loaded() -> boolean           gate for everything below
--   has_current_step() -> boolean    false = no guide / guide finished
--   get_current_step() -> table      { num, is_complete, goals[] }
--     goal = { action, quest_id, npc_id, target_id, target, npc, is_complete }
--   get_current_stickies() -> table[]  same step shape, kept beside the step
--   get_objectives() -> (number|string)[]  every target id / name-only click
--     of the step + stickies, in order, not de-duplicated
--   get_current_waypoint() -> { map_id, x, y (0-1), dist, title, type,
--     goal_num, is_manual }
--   get_step_waypoints() -> the same, every waypoint of the step
--
-- GOAL ACTIONS (the user's reading of Zygor's Parser.lua / Goal.lua, 2026-10-17):
--   talk, clicknpc, vendor, trainer, stablemaster - npc / npc_id
--   gossip - no NPC in this API: the step's talk goal's NPC is used
--   accept, turnin - quest_id, usually no NPC
--   kill, from - target / target_id (first id) + get_objectives ids
--   avoid - never a target
--   get (= collect), click (world object, by name), goal, quest (q)
--   use - an ITEM: target_id is the item id
--   goto, at, gotonpc - walk the waypoint
--   level (= ding) - grind
--   text - commentary, not work
--   Anything else is "unknown": the engine PAUSES and prompts (never guesses).
--
-- SKIP: core.addons.zygor.skip_current_step (core 2.173+) is the last rung (guide.skip_current).
-- A goal the bot cannot finish is first HELD locally (mark_goal_done); when every goal of the step is marked
-- and the step is still incomplete, the engine waits / prompts. Zygor's own
-- step completion moves the guide on.
--
-- EVERYTHING IS OPTIONAL: the addon may be missing; every call is wrapped
-- and every accessor answers "nothing to do" rather than throwing.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local geometry = require("geometry")

local MAX_RANGE = 300

local targeting_mod = nil
local function visible_objects()
    if targeting_mod == nil then
        local ok, mod = pcall(require, "targeting")
        targeting_mod = (ok and type(mod) == "table") and mod or false
    end
    if targeting_mod and type(targeting_mod.visible_objects) == "function" then
        local ok, list = pcall(targeting_mod.visible_objects)
        if ok and type(list) == "table" then
            return list
        end
        return nil
    end
    local ok, list = pcall(function() return core.object_manager.get_visible_objects() end)
    return (ok and type(list) == "table") and list or nil
end

local guide = {}

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

local function indexable(v)
    local t = type(v)
    return t == "table" or t == "userdata"
end

local function call(fn, a, b)
    local ok, result = pcall(fn, a, b)
    if ok then
        return result
    end
    return nil
end

-- ============================================================================
-- READING THE ADDON (plain copies only - a bound userdata result never leaks)
-- ============================================================================

local function index_of(o, k)
    return o[k]
end

local function is_obj(v)
    local t = type(v)
    return t == "table" or t == "userdata"
end

local function get(o, k)
    if not is_obj(o) then
        return nil
    end
    local ok, v = pcall(index_of, o, k)
    if ok then
        return v
    end
    return nil
end

local function length_of(o)
    return #o
end

local MAX_LIST = 512
local function to_list(v)
    local out = {}
    if not is_obj(v) then
        return out
    end
    local ok, n = pcall(length_of, v)
    if ok and type(n) == "number" and n > 0 then
        for i = 1, math.min(n, MAX_LIST) do
            out[#out + 1] = get(v, i)
        end
        return out
    end
    for i = 1, MAX_LIST do
        local item = get(v, i)
        if item == nil then
            break
        end
        out[#out + 1] = item
    end
    return out
end

local function as_bool(v)
    return v == true or v == 1
end

--- Text without WoW escape codes (colours, textures, links).
local function clean_text(s)
    if type(s) ~= "string" or s == "" then
        return s
    end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|T.-|t", "")
    s = s:gsub("|A.-|a", "")
    s = s:gsub("|H.-|h", "")
    s = s:gsub("|h", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end
guide.clean_text = clean_text

local function as_str(v)
    if type(v) == "string" and v ~= "" then
        return v
    end
    return nil
end

local function as_id(v)
    local n = tonumber(v)
    if n and n > 0 then
        return n
    end
    return nil
end

local function plain_goal(raw)
    if not is_obj(raw) then
        return nil
    end
    return {
        action = string.lower(as_str(get(raw, "action")) or ""),
        quest_id = as_id(get(raw, "quest_id")),
        npc_id = as_id(get(raw, "npc_id")),
        target_id = as_id(get(raw, "target_id")),
        target = clean_text(as_str(get(raw, "target"))),
        npc = clean_text(as_str(get(raw, "npc"))),
        is_complete = as_bool(get(raw, "is_complete")),
    }
end

local function plain_step(raw)
    if not is_obj(raw) then
        return nil
    end
    local num = tonumber(get(raw, "num"))
    if not num or num < 1 or num % 1 ~= 0 or not is_obj(get(raw, "goals")) then return nil end
    local goals = {}
    local raw_goals = to_list(get(raw, "goals"))
    for i = 1, #raw_goals do
        local g = plain_goal(raw_goals[i])
        if g then
            goals[#goals + 1] = g
        end
    end
    return {
        num = tonumber(get(raw, "num")) or 0,
        is_complete = as_bool(get(raw, "is_complete")),
        goals = goals,
    }
end

local function plain_waypoint(raw)
    if not is_obj(raw) then
        return nil
    end
    return {
        map_id = tonumber(get(raw, "map_id")) or 0,
        x = tonumber(get(raw, "x")),
        y = tonumber(get(raw, "y")),
        dist = tonumber(get(raw, "dist")),
        title = clean_text(as_str(get(raw, "title"))),
        type = string.lower(as_str(get(raw, "type")) or "way"),   -- Zygor defaults a missing type to "way"
        goal_num = tonumber(get(raw, "goal_num")),
        is_manual = as_bool(get(raw, "is_manual")),
    }
end

--- The addon namespace, or nil when this build has no core.addons.zygor.
local function api()
    local addons = get(rawget(_G, "core"), "addons")
    local ns = get(addons, "zygor")
    if not is_obj(ns) then
        return nil
    end
    return ns
end

local errorlog_mod = nil
local function probe(tag)
    if errorlog_mod == nil then
        local ok, mod = pcall(require, "errorlog")
        errorlog_mod = (ok and type(mod) == "table") and mod or false
    end
    if errorlog_mod then
        errorlog_mod.probe(tag)
    end
end

-- READS ONLY FROM THE UPDATE CALLBACK: main.lua opens the window around
-- on_update; render / GUI only ever see the last snapshot.
local reads_ok = false

local update_id = 0                      -- 1.4.0: one fresh Zygor read per update callback
function guide.allow_reads(on)
    reads_ok = on == true
    if reads_ok then update_id = update_id + 1 end
end

local function ns_call(name, ...)
    if not reads_ok then
        return nil, "outside the update callback"
    end
    local ns = api()
    if not ns then
        return nil, "core.addons.zygor missing"
    end
    local fn = get(ns, name)
    if fn == nil then
        return nil, name .. " missing"
    end
    probe("zygor:" .. name)
    local ok, res = pcall(fn, ...)
    if not ok then
        return nil, tostring(res)
    end
    return res, nil
end

-- ONE READ PER UPDATE: every Zygor call happens in refresh(), memoised for
-- the update callback that made it (allow_reads in main.lua) - so Zygor is
-- read every update, including in combat. (WINDOW / player_in_combat /
-- quest_event_pending below are not used by refresh any more.)
local WINDOW = 0.25

local snap = {
    t = -1,
    loaded = false,
    ready = false,
    step = nil,
    stickies = {},
    wp = nil,
    step_wps = {},
    objectives = {},          -- quest id -> plain objective list (quest log)
    zobj_ids = {},            -- get_objectives() numbers (set)
    zobj_names = {},          -- get_objectives() strings (set)
    memo = {},
}

-- Structural identities exclude completion flags; sticky slots survive reordering.
local identity = { context = nil, epoch = 0, slots = {}, next_slot = 0 }
function guide.step_identity(step)
    local parts = { tostring(step and step.num or 0) }
    for _, g in ipairs(step and step.goals or {}) do
        for _, k in ipairs({"action", "quest_id", "npc_id", "target_id", "target", "npc"}) do
            local v = tostring(g[k] or "")
            parts[#parts + 1] = #v .. ":" .. v
        end
    end
    return table.concat(parts, "|")
end
function guide.context_key()
    return tostring(identity.epoch) .. ":" .. tostring(identity.context)
end
function guide.goal_key(goal)
    return guide.context_key() .. "|" .. tostring(goal and goal.index)
end
local step_cache = { key = nil, wps = {}, wp = nil }

local function clock()
    local ok, t = pcall(izi.now)
    if ok and type(t) == "number" then
        return t
    end
    return 0
end

local function player_in_combat()
    local ok, me = pcall(izi.me)
    if not ok or not me then
        return false
    end
    local ok2, c = pcall(me.is_in_combat, me)
    return ok2 and c == true
end

local EVENT_GAP = 0.1
local events_mod = nil
local ev_seen = nil

local function quest_event_pending(now)
    if events_mod == nil then
        local ok, m = pcall(require, "events")
        events_mod = (ok and type(m) == "table" and type(m.quest_change_at) == "function") and m or false
    end
    if not events_mod then return false end
    local at = events_mod.quest_change_at()
    if type(at) ~= "number" or (ev_seen and at <= ev_seen) then return false end
    if snap.t >= 0 and (now - snap.t) < EVENT_GAP then return false end
    ev_seen = at
    return true
end

-- Waypoint types that are a place to go (Zygor Pointer.set_waypoints): way =
-- a step goal marker, path / farm = waypaths. route = a travel leg, used only
-- as the arrow. manual / corpse / ant / poi are never a guide destination.
local GOAL_WP_TYPES = { way = true, path = true, farm = true }
-- 1.34.2: "taxi" too - a flight leg reported by its node type (user 2026-10-27: the
-- arrow "is set to use flight path 'taxi'" at Telredor); it was dropped as unknown
local ARROW_WP_TYPES = { way = true, path = true, farm = true, route = true, taxi = true }
guide.GOAL_WP_TYPES = GOAL_WP_TYPES
-- 1.34.2: every change of the arrow is logged (type + title), the travel legs too
local arrow_said = nil
-- audit F7: quest/diag.lua - logging only, never consulted by a decision.
-- Lazy, so it cannot affect this file's load order, and nil-safe throughout.
local diag_mod = nil
local function diag()
    if diag_mod == nil then
        local ok, m = pcall(require, "quest/diag")
        diag_mod = (ok and type(m) == "table") and m or false
    end
    return diag_mod or nil
end
guide.diag = diag
-- One closure, not one per read: resolved through the guide table so it does
-- not depend on where the hold test is declared in this file.
local function held_test(i, g)
    if type(guide.goal_held) ~= "function" then return false end
    return guide.goal_held(i, g) == true
end

local function log_arrow(a)
    local key = a and string.format("%s|%s|%.3f|%.3f", tostring(a.type), tostring(a.title), a.x or 0, a.y or 0) or "none"
    if key == arrow_said then return end
    arrow_said = key
    local ok, log = pcall(require, "errorlog")
    if not ok or type(log) ~= "table" or type(log.trail) ~= "function" then return end
    if not a then return log.trail("zygor", "arrow: none") end
    -- audit F6: "type not used" read like a defect. It is not. corpse / manual
    -- / ant / poi are map markers, not places the guide is sending us: a corpse
    -- arrow in particular is answered by death.lua, which corpse-runs from
    -- core.game_ui.get_corpse_position (the real body) and never reads the
    -- guide. The reason is spelled out now so nobody re-raises it.
    log.trail("zygor", "arrow: type %s '%s' map %s (%.4f, %.4f)%s", tostring(a.type),
        (tostring(a.title or ""):gsub("[\r\n]+", " / ")), tostring(a.map_id), a.x or 0, a.y or 0,
        ARROW_WP_TYPES[a.type] and "" or " - not a destination type (marker only)")
    -- 1.2.53: every field the arrow table carries (a hearth leg's pathnode / mode / item
    -- would show here), so the next log says what Zygor really hands over
    local keys = {}
    for k, v in pairs(a) do
        if k ~= "map_id" and k ~= "x" and k ~= "y" and k ~= "title" and k ~= "type" then
            keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    table.sort(keys)
    if #keys > 0 then log.trail("zygor", "  arrow fields: %s", table.concat(keys, ", ")) end
end

local function refresh()
    if not reads_ok then
        return
    end
    local now = clock()
    -- 1.4.0 (user spec: "Do not cache a step number across updates"): read once
    -- per update callback - in combat too (the step and its goals are never stale)
    if snap.read_id == update_id and snap.t >= 0 then return end
    snap.read_id = update_id
    snap.t = now
    local loaded, load_error = ns_call("is_loaded")
    snap.problem = load_error and ("is_loaded: " .. load_error) or nil
    snap.loaded = as_bool(loaded)
    snap.ready = false
    snap.step = nil
    snap.stickies = {}
    snap.wp = nil
    snap.step_wps = {}
    snap.objectives = {}
    snap.zobj_ids, snap.zobj_names = {}, {}
    snap.memo = {}
    if not snap.loaded then
        identity.context = nil
        return
    end
    -- has_current_step() before get_current_step() (documented order)
    local has_step, step_error = ns_call("has_current_step")
    if not as_bool(has_step) then
        snap.problem = step_error and ("has_current_step: " .. step_error) or nil
        if not step_error then identity.context = nil end
        return
    end
    local raw_step, read_error = ns_call("get_current_step")
    local step = plain_step(raw_step)
    if not step then
        snap.problem = "get_current_step: " .. (read_error or "incomplete snapshot; retrying next update")
        return
    end
    snap.ready = true
    snap.step = step
    local context = guide.step_identity(step)
    if identity.context ~= context then
        -- 1.2.11: A -> B -> A inside 5 s is Zygor flip-flopping between steps (log 16:43:19-22: 197, 194,
        -- 197, 198, 197); logged with both identities so the cause can be read from the action log
        local fl = identity.flip or { prev = nil, prev2 = nil, t = -1e9 }
        identity.flip = fl
        if fl.prev2 == context and (now - fl.t) < 5 then
            pcall(function()
                require("actlog").event("guide", "step_flip", "step flip-flop " .. tostring(fl.prev) .. " <-> " .. tostring(context),
                    { a = tostring(context), b = tostring(fl.prev), num = step.num })
            end)
        end
        fl.prev2, fl.prev, fl.t = fl.prev, context, now
        identity.context, identity.epoch = context, identity.epoch + 1
        identity.slots, identity.next_slot = {}, 0
    end
    do                                   -- audit F7: step transitions (log only)
        local d = diag()
        if d then pcall(d.step, step, held_test) end
    end

    local active_slots = {}
    local list = to_list((ns_call("get_current_stickies")))
    for i = 1, #list do
        local st = plain_step(list[i])
        if st then
            local key = guide.step_identity(st)
            if not identity.slots[key] then
                identity.next_slot = identity.next_slot + 1
                identity.slots[key] = identity.next_slot
            end
            active_slots[key] = identity.slots[key]
            st.slot = identity.slots[key]
            snap.stickies[#snap.stickies + 1] = st
        end
    end
    identity.slots = active_slots
    local objs = to_list((ns_call("get_objectives")))
    for i = 1, #objs do
        local v = objs[i]
        if type(v) == "number" and v > 0 then
            snap.zobj_ids[v] = true
        elseif type(v) == "string" and v ~= "" then
            snap.zobj_names[clean_text(v)] = true
        end
    end
    local arrow = plain_waypoint((ns_call("get_current_waypoint")))
    local live_arrow = arrow and (arrow.map_id or 0) ~= 0 and arrow or nil
    log_arrow(live_arrow)
    do                                   -- audit F7: the arrow tally (log only)
        local d = diag()
        if d then
            pcall(d.arrow, live_arrow and live_arrow.type or nil,
                live_arrow ~= nil and ARROW_WP_TYPES[live_arrow.type] == true or nil)
        end
    end
    if arrow and (arrow.map_id or 0) ~= 0 and not arrow.is_manual and ARROW_WP_TYPES[arrow.type] then
        snap.wp = arrow
    end
    local wps = to_list((ns_call("get_step_waypoints")))
    for i = 1, #wps do
        local wp = plain_waypoint(wps[i])
        if wp and (wp.map_id or 0) ~= 0 and not wp.is_manual and GOAL_WP_TYPES[wp.type] then
            snap.step_wps[#snap.step_wps + 1] = wp
        end
    end
    -- 1.4.0: no per-step cache - an empty read means no waypoint this update
end

local function memo(key, fn)
    refresh()
    local v = snap.memo[key]
    if v == nil and not reads_ok then
        v = fn()
        if v == false then
            return nil
        end
        return v
    end
    if v == nil then
        v = fn()
        if v == nil then
            v = false
        end
        snap.memo[key] = v
    end
    if v == false then
        return nil
    end
    return v
end

-- ============================================================================
-- AVAILABILITY / THE CURRENT STEP
-- ============================================================================

function guide.is_loaded()
    refresh()
    return snap.loaded
end

function guide.read_problem()
    refresh()
    return snap.problem
end

function guide.ready()
    refresh()
    return snap.ready
end

local diag_wanted = false

function guide.update()
    refresh()
    if diag_wanted then
        diag_wanted = false
        guide.diagnose()
        diag_wanted = false
    end
end

function guide.step()
    refresh()
    return snap.step
end

function guide.stickies()
    refresh()
    return snap.stickies
end

--- get_objectives() as two sets: ids (numbers) and names (strings).
function guide.zygor_objectives()
    refresh()
    return snap.zobj_ids, snap.zobj_names
end

local diag_cache, diag_t = nil, -1
local DIAG_PENDING = {
    addons = "-", namespace = "-", missing = {}, is_loaded = "(reading)",
    has_step = "(reading)", step_type = "-", step_num = 0, goal_count = 0,
    waypoint = "(reading)", step_waypoints = 0, objectives = 0,
}

function guide.diagnose()
    diag_wanted = true
    if not reads_ok then
        return diag_cache or DIAG_PENDING
    end
    local now = clock()
    if diag_cache and now >= diag_t and (now - diag_t) < 1.0 then
        return diag_cache
    end
    diag_t = now
    local out = {}
    local addons = get(rawget(_G, "core"), "addons")
    out.addons = type(addons)
    local ns = get(addons, "zygor")
    out.namespace = type(ns)
    local fns = { "is_loaded", "has_current_step", "get_current_step",
        "get_current_stickies", "get_objectives", "get_current_waypoint",
        "get_step_waypoints" }
    local missing = {}
    for i = 1, #fns do
        if get(ns, fns[i]) == nil then
            missing[#missing + 1] = fns[i]
        end
    end
    out.missing = missing
    local loaded, lerr = ns_call("is_loaded")
    out.is_loaded = tostring(loaded) .. (lerr and (" (" .. lerr .. ")") or "")
    local has, herr = ns_call("has_current_step")
    out.has_step = tostring(has) .. (herr and (" (" .. herr .. ")") or "")
    local step = nil
    if as_bool(loaded) and as_bool(has) then
        local raw, serr = ns_call("get_current_step")
        out.step_type = type(raw) .. (serr and (" (" .. serr .. ")") or "")
        step = plain_step(raw)
    else
        out.step_type = "-"
    end
    out.step_num = step and step.num or 0
    out.goal_count = step and #step.goals or 0
    if not step then                     -- 1.4.0: no further reads without a step
        out.waypoint, out.step_waypoints, out.objectives = "none", 0, 0
        diag_cache = out
        return out
    end
    local wp = plain_waypoint((ns_call("get_current_waypoint")))
    out.waypoint = wp and string.format("map %d  %.3f,%.3f  %s  [%s]",
        wp.map_id, wp.x or 0, wp.y or 0, tostring(wp.title or "-"), tostring(wp.type))
        or "none"
    out.step_waypoints = #to_list((ns_call("get_step_waypoints")))
    out.objectives = #to_list((ns_call("get_objectives")))
    diag_cache = out
    return out
end

-- ============================================================================
-- GOALS
-- ============================================================================

-- Zygor action -> engine kind. Only what the user's Zygor reading defines.
local ACTIONS = {
    accept       = "accept",
    turnin       = "turnin",
    talk         = "talk",
    clicknpc     = "talk",
    vendor       = "talk",
    trainer      = "talk",
    stablemaster = "talk",
    gossip       = "talk",
    kill         = "kill",
    from         = "kill",
    get          = "collect",
    click        = "object",
    goal         = "objective",
    quest        = "objective",
    q            = "objective",
    use          = "item",
    useany       = "item",       -- 1.4.0: "use any of" - an item use too
    openskill    = "manual",     -- 1.4.0 (Zygor spec): a profession goal - not a quest move, left to you
    create       = "manual",
    ["goto"]     = "goto",
    at           = "goto",
    gotonpc      = "goto",
    level        = "xp",
    text         = "text",       -- commentary: nothing to act on
    avoid        = "avoid",      -- never a target
    -- 1.1.0 (user's Zygor reading, 2026-10-17)
    fly          = "fly",        -- landing node = the step waypoint (title = node name)
    fpath        = "fpath",      -- discover a flight path (Zygor's taxi db completes it)
    ferry        = "fpath",      -- discover a ferry: same fields / completion as fpath
    home         = "talk",       -- bind: the innkeeper is the step's talk goal
    hearth       = "hearth",     -- Hearthstone (6948); done when the zone matches
    walk         = "goto",       -- force_walk only
    zombiewalk   = "goto",
    confirm      = "confirm",    -- completes only when clicked in Zygor: the user clicks it
    -- 1.2.0 (user's retail Zygor reading)
    buy          = "buy",        -- target_id = item id, vendor = the step's talk NPC, no quantity
    equip        = "equip",      -- target_id = item id; complete once worn
    equipped     = "equip",
    unequip      = "manual",     -- take an item off: no API in the reference
    unequipped   = "manual",
    learnspell   = "manual",     -- the spell id never reaches the goal table
    learn        = "manual",     -- recipe id never reaches it
    cast         = "manual",     -- castspell / id cleared off the goal
    petaction    = "manual",     -- only the action arrives
    info         = "text",       -- 1.8.0: display only (Goal.lua: passive) - passed over
    havebuff     = "wait",
    nobuff       = "wait",
    invehicle    = "wait",
    outvehicle   = "wait",
    ontaxi       = "wait",
    offtaxi      = "wait",
    skill        = "wait",       -- reachskill arrives as "skill"
    skillmax     = "wait",
    -- 1.8.0 (user spec; ZygorGuidesViewerClassicTBCAnniv Goal.lua, every
    -- GOALTYPES key - the same meaning on TBC and Retail). Client-specific keys
    -- are added by quest/zygor_tbc.lua (Tbc) / quest/zygor_midnight.lua (Midnight).
    -- display-only and modifier keys: no-ops, passed over
    mapmarker    = "text", image = "text", webinfo = "text", webheader = "text", webimage = "text",
    debugvar     = "text", debugevent = "text", popuptext = "text", devmsg = "text", goldtracker = "text",
    grind        = "text", itemname = "text", count = "text", notinsticky = "text", onlyinsticky = "text",
    oncomplete   = "text", polish = "text", subzone = "text", nexttab = "text",
    achievetext  = "text",       -- display (Retail achievement text): a no-op on every client
    noquest      = "text",       -- a daily-quest check Zygor ticks itself (click_to_complete)
    -- item counts (GetItemCount >= count): the collect kind
    farm         = "collect",    -- = GOALTYPES['get']
    collect      = "collect",    -- sets action "get"; kept for a goal that still says collect
    goldcollect  = "collect",
    expcollect   = "collect",
    repcollect   = "collect",
    ding         = "xp",         -- the parser's string alias of "level"
    discover     = "goto",       -- complete on the zone-explored message: walk the waypoint
    countremains = "objective",  -- a quest objective count
    multiq       = "objective",
    bosshp       = "kill",       -- the boss down to a health level
    reachskill   = "wait",       -- arrives as "skill"
    turninany    = "wait",       -- its quest list (multiquests) is not in the API goal table
    activepet    = "wait", petding = "wait", phase = "wait", rep = "wait", playertitle = "wait",
    condition    = "wait", complete = "wait",
    learnpetspell = "manual",    -- the spell id never reaches the goal table
    findcity     = "manual",     -- Zygor picks the NPC at run time (WhoWhere)
    talknpcs     = "manual",
    guideflag    = "confirm",    -- a Zygor click (click_to_complete)
    loadguide    = "confirm",    -- a Zygor click: loads another guide
    reload       = "confirm",    -- a Zygor click: ReloadUI
}
guide.ACTIONS = ACTIONS
-- NOT WORK: passed over by compute_goal (still the fallback when nothing else is left).
-- 1.68.0: wait (havebuff / taxi / vehicle / skill...) is current-step work.
local NOT_WORK = { text = true, avoid = true }
local TALK_ACTIONS = { talk = true, clicknpc = true, vendor = true, trainer = true, stablemaster = true }
-- goals whose target_id is an ITEM id (1.2.0)
local ITEM_GOALS = { use = true, buy = true, equip = true, equipped = true, unequip = true, unequipped = true }
guide.ITEM_GOALS = ITEM_GOALS

-- 1.8.0: the client's own action module - quest/zygor_tbc on "Tbc",
-- quest/zygor_midnight on "Midnight", none on any other client (Forever,
-- Vanilla). Registered once, the first time it is asked for.
local VM = nil
function guide.version_module()
    if VM == nil then
        VM = false
        local okg, gv = pcall(require, "gamever")
        if okg and type(gv) == "table" then
            local name = nil
            if type(gv.is_tbc) == "function" and gv.is_tbc() then
                name = "quest/zygor_tbc"
            elseif type(gv.version) == "function" and gv.version() == "Midnight" then
                name = "quest/zygor_midnight"
            end
            local okm, m = false, nil
            if name then okm, m = pcall(require, name) end
            if okm and type(m) == "table" then
                pcall(m.register, ACTIONS, ITEM_GOALS)
                VM = m
            end
        end
    end
    return VM or nil
end
function guide._reset_version_module() VM = nil end

local function shape_goal(g, index, step_goals)
    if type(g) ~= "table" then
        return nil
    end
    local npc_id, npc = g.npc_id, g.npc
    -- a gossip / home / buy goal has no NPC: the step's talk goal is the NPC
    -- to speak to (Zygor's gossip handler pairs them the same way)
    -- 1.7.11 (log 12:43, step 19 "talk Dumphry##21209 / turnin Waste Not, Want
    -- Not##10055 / accept ##10078"): a turnin / accept goal with no NPC of its
    -- own borrows the step's talk NPC too - Zygor writes the quest NPC once,
    -- on the talk line; without it the hand-in (and its reward choice) never
    -- found anyone to talk to
    if (g.action == "gossip" or g.action == "home" or g.action == "buy" or g.action == "turnin"
        or g.action == "accept") and not npc_id and type(step_goals) == "table" then
        for i = 1, #step_goals do
            local o = step_goals[i]
            if type(o) == "table" and TALK_ACTIONS[o.action] and (o.npc_id or o.npc) then
                npc_id, npc = o.npc_id, o.npc
                break
            end
        end
    end
    local item_id = ITEM_GOALS[g.action] and g.target_id or nil
    return {
        action = g.action or "",
        quest_id = g.quest_id,
        npc_id = npc_id,
        npc = npc,
        target_id = (not item_id) and g.target_id or nil,
        target = g.target,
        item_id = item_id,
        -- the name the engine / GUI show and match: the target, else the NPC
        text = g.target or ((g.action ~= "accept" and g.action ~= "turnin") and npc or nil),
        text_only = NOT_WORK[ACTIONS[g.action] or ""] == true,
        is_complete = g.is_complete == true,
        index = index,
        ids = nil,
    }
end

local function skipped(quest_id)
    if type(quest_id) ~= "number" then
        return false
    end
    local ok, state = pcall(require, "state")
    if not ok or type(state) ~= "table" or type(state.quest) ~= "table" then
        return false
    end
    local bag = state.quest.skipped
    return type(bag) == "table" and bag[quest_id] == true
end
guide.skipped = skipped

function guide.step_num()
    local step = guide.step()
    return step and tonumber(step.num) or 0
end

-- Goals the bot finished itself (Zygor has no skip): keyed "step|index",
-- forgotten when the step changes.
local done_goals = {}
local done_step = nil

-- 1.4.0 (user spec rule 2: work the first goal whose is_complete is false):
-- the bot never marks a goal done. A goal it cannot do is HELD - it stays the
-- current goal and the engine waits with a note until Zygor completes it (or
-- the user acts in the Zygor window). Held goals are keyed "step|index".
local held_why = {}
function guide.mark_goal_done(step_num, index, why)
    if step_num ~= guide.step_num() then return end
    if done_step ~= guide.context_key() then
        done_goals, held_why = {}, {}
        done_step = guide.context_key()
    end
    local k = guide.context_key() .. "|" .. tostring(index)
    done_goals[k] = true
    held_why[k] = why or held_why[k] or "the bot cannot do this goal - finish it, or skip it in the Zygor window"
    snap.memo = {}
end
guide.hold_goal = guide.mark_goal_done

--- core.addons.zygor.skip_current_step() (declared on the live stub, core 2.173+; Zygor's own
--- next-step call): true when Zygor moved past the current step. False when Zygor is not
--- loaded, has no step, follows a party sync leader, or the core has no such function.
--- The engine calls it as the last rung (a trainer that taught nothing, an unresponsive giver,
--- no progress after the recoveries twice); the bot never marks a goal done itself.
function guide.skip_current(why)
    local r, err = ns_call("skip_current_step")
    guide.invalidate()
    local okl, elogmod = pcall(require, "errorlog")
    local function say(fmt, ...)
        if okl and type(elogmod) == "table" and type(elogmod.trail) == "function" then pcall(elogmod.trail, "skip", fmt, ...) end
    end
    if r == true then
        pcall(function() require("quest/diag").skip_requested(why) end)
        say("Zygor step skipped: %s", tostring(why or "-"))
        return true
    end
    if err then say("skip_current_step unavailable: %s", tostring(err)) end
    return false
end

--- audit F7 (2026-10-28): is this goal one the bot is HOLDING (mark_goal_done
--- / hold_goal)? Zygor never marks it complete, so quest/diag would otherwise
--- count every held goal as an open one and read a step that waits on the user
--- as a step that moved on its own. Index-and-goal, so diag needs nothing of
--- this file's internals.
function guide.goal_held(index, goal)
    if type(goal) ~= "table" then return false end
    local step = snap.step
    if type(step) ~= "table" or done_step ~= guide.context_key() then return false end
    return done_goals[guide.context_key() .. "|" .. tostring(index)] == true
end

function guide.has_local_done()
    return false                         -- 1.4.0: the bot holds goals, it never completes them
end

function guide.forget_local_done()
    done_goals, held_why = {}, {}            -- 1.4.3: Start lets held goals be tried again
    snap.memo = {}
end

--- Every quest id a goal names (Zygor: one, quest_id).
function guide.goal_quest_ids(goal)
    local out = {}
    if type(goal) == "table" and tonumber(goal.quest_id) and goal.quest_id > 0 then
        out[1] = goal.quest_id
    end
    return out
end

function guide.invalidate()
    snap.t, snap.read_id = -1, nil
    snap.memo = {}
end

-- 1.8.6 (log 2026-10-19 20:34, step 89 "kill Deranged Helboars / get Tainted
-- Helboar Meat 23270 / use / get Purified Helboar Meat |q 9361"): the use goal
-- (Purification Mixture 23268 - the API gives no item id) went out with no
-- meat in the bags. A use goal that follows a `get` goal of the same step
-- uses that item: the INGREDIENT. Not in the bags: the use goal is passed over
-- (the kills that drop it are worked) and is not moved ahead in the ActionBar
-- order.
local function bag_count(id)
    local ok, bags = pcall(require, "bags")
    if not ok or type(bags) ~= "table" or type(bags.count) ~= "function" then return nil end
    local okc, n = pcall(bags.count, id)
    return okc and tonumber(n) or nil
end
--- The ingredient of a use goal: the nearest earlier get / collect goal of the
--- step with an item id - id, name - or nil.
function guide.use_ingredient(goal, goals)
    if type(goal) ~= "table" or (goal.action ~= "use" and goal.action ~= "useany") then return nil end
    goals = goals or (guide.step() or {}).goals
    if type(goals) ~= "table" then return nil end
    local idx = tonumber(goal.index)
    if not idx or idx > #goals then return nil end
    for j = idx - 1, 1, -1 do
        local o = goals[j]
        if type(o) == "table" and (o.action == "get" or o.action == "collect") and tonumber(o.target_id) then
            return tonumber(o.target_id), o.target
        end
    end
    return nil
end
--- True when the use goal has an ingredient and it is not in the bags.
function guide.use_missing_ingredient(goal, goals)
    local id = guide.use_ingredient(goal, goals)
    if not id then return false end
    local n = bag_count(id)
    return n ~= nil and n <= 0
end

-- Installed Nagrand/Sha'tar guide: Lump is subdued, then interrogated.
-- Its bare kill/talk lines share the quest objective's live waypoint.
local function lump_objective(goals)
    for i,g in ipairs(goals or {}) do
        if g.action == "q" and tonumber(g.quest_id) == 9918 then return i,g end
    end
end
local function lump_surrendered(goal, goals)
    if goal.action ~= "kill" or tonumber(goal.target_id or goal.npc_id) ~= 18351
        or not lump_objective(goals) then return false end
    local _,q = lump_objective(goals)
    if q.is_complete == true then return true end
    local player = safe(function() return izi.me() end)
    if not player or call(player.is_valid,player) ~= true then return false end
    for _,unit in ipairs(visible_objects() or {}) do
        if call(unit.is_valid,unit) == true and call(unit.get_npc_id,unit) == 18351
            and call(unit.is_dead_or_ghost,unit) == false
            and call(player.can_attack,player,unit) == false
            and call(player.is_enemy_with,player,unit) == false then return true end
    end
    return false
end

-- Positive completion evidence only. A ready turn-in still needs its dialog;
-- accepted repeatable quests still need their new objectives.
function guide.goal_completed(goal)
    if type(goal) ~= "table" then return false end
    if goal.is_complete == true then return true end
    local qid = tonumber(goal.quest_id)
    if not qid or qid <= 0 then return false end
    local on = safe(function() return core.quests.is_on_quest(qid) end)
    local done = safe(function() return core.quests.is_quest_flagged_completed(qid) end) == true
    if goal.action == "accept" then return on == true or done and on == false end
    if done and on == false then return true end
    if on == true and (goal.action == "kill" or goal.action == "get" or goal.action == "collect" or goal.action == "complete") then
        return safe(function() return core.quests.is_quest_complete(qid) end) == true
    end
    return false
end

function guide.release_goal(index)
    local k = guide.context_key() .. "|" .. tostring(index)
    done_goals[k], held_why[k] = nil, nil
    snap.memo = {}
end

local function compute_goal()
    local step = guide.step()
    if not step or step.is_complete == true then
        return nil
    end
    if done_step ~= guide.context_key() then
        done_goals, held_why = {}, {}
        done_step = guide.context_key()
    end
    local goals = step.goals
    if type(goals) ~= "table" then
        return nil
    end
    -- 1.4.1 (log 23:20, step 11 goal 2: action '' with no waypoint of its own): a
    -- goal with no action and no step waypoint carries nothing to do - it is
    -- passed over like text (still the fallback when nothing else is left)
    local has_wp = {}
    for _, wp in ipairs(snap.step_wps or {}) do
        local gn = tonumber(type(wp) == "table" and wp.goal_num or nil)
        if gn then has_wp[gn] = true end
    end
    local arrow_goal = snap.wp and tonumber(snap.wp.goal_num)
    if arrow_goal then has_wp[arrow_goal] = true end
    -- Conditional goto lines remain incomplete in the Core snapshot even when
    -- Zygor hides their marker. Defer only with live evidence of later work;
    -- never complete the goal, borrow another goal's coordinates, or skip on
    -- an empty snapshot. A returning marker makes the goto active again.
    local function inactive_goto(sg)
        if sg.action ~= "goto" or has_wp[sg.index] then return false end
        for j = sg.index + 1, #goals do
            if has_wp[j] and goals[j].is_complete ~= true then return true end
        end
        return false
    end
    -- 1.6.0 (Zygor's own Goal.lua: talk / clicknpc / click / use / useany / gossip /
    -- text goals are PASSIVE - Zygor never sets them complete; the step completes
    -- through its q / accept / turnin goals): a goal the bot has done or cannot do
    -- is PASSED OVER while a later goal of the step still has work; it is the
    -- held fallback ("WAITING for Zygor") only when nothing else is left.
    local fallback, held_fb = nil, nil
    -- 1.7.11: a talk goal whose NPC is the NPC of an open turnin / accept goal
    -- of the same step is that quest dialog - the talk itself is passive
    -- (Zygor never ticks it) and only got the window opened and stalled; the
    -- turnin / accept goal does the work, the talk is passed over
    local function quest_partner(sg)
        -- 1.17.0: a click on an OBJECT that gives / takes the step's quest
        -- ("click Scourge Cauldron" / turnin Target: Dalson's Tears##5219): the
        -- click has no quest of its own and the turnin / accept goal with no
        -- NPC uses that object (engine find_giver) - the click is passed over
        if sg.action == "click" and not sg.quest_id then
            for j = 1, #goals do
                local o = goals[j]
                if type(o) == "table" and o.is_complete ~= true and (o.action == "turnin" or o.action == "accept")
                    and o.npc_id == nil then
                    return true
                end
            end
            return false
        end
        if sg.action ~= "talk" or not sg.npc_id then return false end
        for j = 1, #goals do
            local o = goals[j]
            if type(o) == "table" and o.is_complete ~= true and (o.action == "turnin" or o.action == "accept")
                and (o.npc_id == nil or o.npc_id == sg.npc_id) then
                return true
            end
        end
        return false
    end
    -- 1.7.17 (log 15:04, step 29 "kill Subjugator Shi'aziv, Wrathguard, ... /
    -- collect 4 Demonic Rune Stone |n / click Portal Kaalez / Disrupt Portal Grimh
    -- |q 10144/1"): a bare kill (no quest of its own) is passive - Zygor never
    -- ticks it - and the bot killed on for ever. Once every collect ('get')
    -- goal of the step is complete (Zygor counts the items), the kill is done:
    -- passed over to the click / q goals that use the items.
    local gets, gets_done = 0, 0
    for j = 1, #goals do
        local o = goals[j]
        if type(o) == "table" and (o.action == "get" or o.action == "collect") then
            gets = gets + 1
            if guide.goal_completed(o) then gets_done = gets_done + 1 end
        end
    end
    local function kill_collected(sg)
        return sg.action == "kill" and not sg.quest_id and gets > 0 and gets_done == gets
    end
    -- 1.8.0: the client module's goal order (TBC: Zygor's ActionBar order -
    -- usable actions before NPC actions, quest/zygor_tbc.lua goal_order)
    local vm = guide.version_module()
    local order = nil
    if vm and type(vm.goal_order) == "function" then
        local okord, o = pcall(vm.goal_order, goals, function(g0, i0)
            local sg0 = shape_goal(g0, i0, goals)
            if sg0 == nil or guide.use_missing_ingredient(sg0, goals) then return false end   -- 1.8.6
            return guide.find_bag_item(sg0) ~= nil
        end)
        if okord and type(o) == "table" then order = o end
    end
    for n = 1, #goals do
        local i = order and order[n] or n
        local g = goals[i]
        if type(g) == "table" and not guide.goal_completed(g) then
            local sg = shape_goal(g, i, goals)
            if (g.action == nil or g.action == "") and not has_wp[i] then sg.text_only = true end
            if not sg.text_only and (inactive_goto(sg) or quest_partner(sg) or kill_collected(sg) or lump_surrendered(sg, goals)
                or guide.use_missing_ingredient(sg, goals)) then                    -- 1.8.6
                fallback = fallback or sg                  -- 1.7.11: passed over
            elseif not sg.text_only then
                local k = guide.context_key() .. "|" .. tostring(i)
                if done_goals[k] then sg.held = held_why[k] or "held" end
                if skipped(tonumber(g.quest_id)) then
                    sg.held = "quest skipped in the bot - skip it in the Zygor window"
                end
                if not sg.held then return sg end
                held_fb = held_fb or sg
            else
                fallback = fallback or sg
            end
        end
    end
    -- 1.4.0 (rule 9): the stickies are real work - their first incomplete goal,
    -- after the step's own goals (index 1000 * sticky + goal: Zygor's goal_num
    -- only counts the step's goals)
    for s = 1, #snap.stickies do
        local st = snap.stickies[s]
        local sgl = type(st) == "table" and st.goals or nil
        if type(sgl) == "table" then
            for i = 1, #sgl do
                local g = sgl[i]
                if type(g) == "table" and not guide.goal_completed(g) then
                    local sg = shape_goal(g, 1000 * st.slot + i, sgl)
                    if sg and not sg.text_only then
                        sg.sticky = true
                        local k = guide.context_key() .. "|" .. tostring(sg.index)
                        if done_goals[k] then sg.held = held_why[k] or "held" end
                        if not sg.held then return sg end
                        held_fb = held_fb or sg
                    end
                end
            end
        end
    end
    return held_fb or fallback
end

function guide.goal()
    local g = memo("goal", compute_goal)
    do                                   -- audit F7: goal transitions (log only)
        local d = diag()
        if d then pcall(d.goal, g) end
    end
    return g
end

function guide.goals()
    guide.version_module()            -- audit V5: the client's keys registered before shape_goal reads ACTIONS
    return memo("goals", function()
        local out = {}
        local step = guide.step()
        if not step or type(step.goals) ~= "table" then
            return out
        end
        for i = 1, #step.goals do
            local g = shape_goal(step.goals[i], i, step.goals)
            if g then
                out[#out + 1] = g
            end
        end
        return out
    end)
end

-- ============================================================================
-- WHAT THE ENGINE SHOULD DO
-- ============================================================================

-- Quest objective type (core.quests.get_quest_objectives) -> kind, for a
-- goal / quest / get line whose verb does not say how.
local OBJECTIVE_KIND = {
    monster = "kill",
    item    = "collect",
    object  = "object",
    event   = "wait", -- scripted objective: Zygor remains the completion authority
}

--- The unfinished quest-log objective a goal refers to, or nil (matched on
--- the goal's target name, else the sole unfinished one).
function guide.goal_objective(goal)
    if type(goal) ~= "table" or not goal.quest_id then
        return nil
    end
    local list = guide.objectives(goal.quest_id)
    local first, count, matched, matches = nil, 0, nil, 0
    local want = goal.text and string.lower(goal.text) or nil
    for i = 1, #list do
        local o = list[i]
        if not o.finished then
            first = first or o
            count = count + 1
            local head = o.text and string.lower(o.text:match("^(.-):%s*%d+%s*/%s*%d+%s*$") or o.text)
            if want and head and head ~= "" and (string.find(head, want, 1, true) or string.find(want, head, 1, true)) then
                matched, matches = o, matches + 1
            end
        end
    end
    if matches == 1 then return matched end
    if matches == 0 and count == 1 then return first end
    return nil
end

local classify_raw

function guide.classify(goal)
    if type(goal) ~= "table" then
        return "goto"
    end
    return classify_raw(goal)            -- 1.4.0: classified every tick (no cache on the goal)
end

classify_raw = function(goal)
    local a = goal.action
    if type(a) ~= "string" or a == "" then
        return "goto"                      -- a coordinates-only line is "goto" in Zygor
    end
    local vm = guide.version_module()
    if vm and type(vm.classify) == "function" then
        local special = vm.classify(goal)
        if special then return special end
    end
    local kind = ACTIONS[a]
    if kind == nil then
        return "unknown"                   -- never guessed: the engine pauses and prompts
    end
    if kind == "objective" or kind == "collect" then
        local o = guide.goal_objective(goal)
        local t = o and o.type and string.lower(o.type) or nil
        if t and OBJECTIVE_KIND[t] then
            return OBJECTIVE_KIND[t]
        end
        if kind == "objective" then
            -- 1.2.38: the quest is in the log with every objective finished: nothing is
            -- unknown, Zygor just has not ticked the line yet - wait for it, do not pause
            if not o and goal.quest_id then
                local objs = guide.objectives(goal.quest_id)
                if type(objs) == "table" and #objs > 0 then
                    local all = true
                    for i = 1, #objs do
                        if not objs[i].finished then all = false end
                    end
                    if all then return "wait" end
                end
            end
            return "unknown"
        end
    end
    return kind
end

--- The raw goal for the "unknown action" prompt (GUI / log).
function guide.unknown_goal()
    local g = guide.goal()
    if g and guide.classify(g) == "unknown" then
        return g
    end
    return nil
end

-- ============================================================================
-- OBJECTIVE PROGRESS - from the quest log (Zygor gives no per-quest progress)
-- ============================================================================

--- { text, type, num_required, num_fulfilled, finished } for one quest, from
--- core.quests.get_quest_objectives(quest_id) (documented fields: text, type,
--- finished, fulfilled, required).
function guide.objectives(quest_id)
    local out = {}
    quest_id = tonumber(quest_id)
    if not quest_id then
        return out
    end
    refresh()
    local hit = snap.objectives[quest_id]
    if hit then
        return hit
    end
    if not reads_ok then
        return out
    end
    local list = safe(function() return core.quests.get_quest_objectives(quest_id) end)
    list = to_list(list)
    for i = 1, #list do
        local o = list[i]
        if is_obj(o) then
            out[#out + 1] = {
                text = clean_text(as_str(get(o, "text"))),
                type = as_str(get(o, "type")),
                num_required = tonumber(get(o, "required")) or 0,
                num_fulfilled = tonumber(get(o, "fulfilled")) or 0,
                finished = as_bool(get(o, "finished")),
            }
        end
    end
    snap.objectives[quest_id] = out
    return out
end

function guide.needs_progress(quest_id)
    local objectives = guide.objectives(quest_id)
    if #objectives == 0 then
        return false
    end
    for i = 1, #objectives do
        if not objectives[i].finished then
            return true
        end
    end
    return false
end

local log_cache = {}
local LOG_TTL = 1.0
local headers_expanded = false

local function strip_progress(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local head = text:match("^(.-):%s*%d+%s*/%s*%d+%s*$")
    if head and head ~= "" then
        return head
    end
    return text
end
guide.strip_progress = strip_progress

local function log_index_of(quest_id)
    if not headers_expanded then
        headers_expanded = true
        pcall(function() core.quests.expand_quest_header(0) end)
    end
    local n = safe(function() return core.quests.get_num_quest_log_entries() end)
    if type(n) ~= "number" then
        return nil
    end
    for i = 1, n do
        local info = safe(function() return core.quests.get_quest_log_title(i) end)
        if type(info) == "table" and info.is_header ~= true
            and tonumber(info.quest_id) == quest_id then
            return i, info
        end
    end
    return nil
end

function guide.log_title(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return nil
    end
    local _, info = log_index_of(quest_id)
    if type(info) == "table" and type(info.title) == "string" and info.title ~= "" then
        return info.title
    end
    return nil
end

--- Names of the unfinished objectives of a quest, as the client words them.
function guide.objective_names(quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return {}
    end
    local now = safe(function() return izi.now() end) or 0
    local hit = log_cache[quest_id]
    if hit and (now - hit.t) < LOG_TTL then
        return hit.names
    end
    local names = {}
    local list = guide.objectives(quest_id)
    for i = 1, #list do
        if not list[i].finished then
            local name = strip_progress(list[i].text)
            if name then
                names[#names + 1] = name
            end
        end
    end
    if reads_ok then
        log_cache[quest_id] = { names = names, t = now }
    end
    return names
end

-- ============================================================================
-- TARGETS
-- ============================================================================
-- For the goal being worked its own npc_id / target_id / name come first;
-- get_objectives() (step + stickies) is the wider wanted set for fight /
-- collect goals - minus every id / name an avoid goal names.
local compute_targets
local TARGET_KINDS = { kill = true, collect = true, object = true, item = true }

function guide.targets(goal, primary)
    goal = goal or guide.goal()
    local key = "targets:" .. tostring(goal and goal.index or 0) .. (primary and ":own" or "")
    local pair = memo(key, function()
        local i, n = compute_targets(goal, primary)
        return { i, n }
    end)
    return pair[1], pair[2]
end

-- No guide-file data in this product (RestedXP-only helpers answer nothing).
function guide.rxp_step_for() return nil end
function guide.gossip_option(unit, rows)
    local vm = guide.version_module()
    if vm and type(vm.gossip_option)=="function" then
        return vm.gossip_option(unit, (guide.step() or {}).goals, rows)
    end
end

function guide.rxp_item_for() return nil end
function guide.rxp_quest_givers() return {} end
function guide.rxp_quest_mobs() return {} end

--- The avoid lines of the step: ids and names never to fight.
local function avoided()
    return memo("avoid", function()
        local ids, names = {}, {}
        local function scan(step)
            if type(step) ~= "table" or type(step.goals) ~= "table" then return end
            for i = 1, #step.goals do
                local g = step.goals[i]
                if type(g) == "table" and g.action == "avoid" then
                    if g.target_id then ids[g.target_id] = true end
                    if g.target then
                        for n in g.target:gmatch("[^,]+") do
                            names[n:match("^%s*(.-)%s*$")] = true
                        end
                    end
                end
            end
        end
        scan(guide.step())
        local st = guide.stickies()
        for i = 1, #st do scan(st[i]) end
        return { ids, names }
    end)
end
function guide.avoided()
    local a = avoided()
    return a[1], a[2]
end

--- The names of the step's other unfinished kill goals (the kill fallback / log).
function guide.step_target_names()
    return memo("step_targets", function()
        local set = {}
        local step = guide.step()
        if step and type(step.goals) == "table" then
            for i = 1, #step.goals do
                local g = step.goals[i]
                if type(g) == "table" and g.is_complete ~= true and ACTIONS[g.action] == "kill" and g.target then
                    set[g.target] = true
                end
            end
        end
        local out = {}
        for n in pairs(set) do out[#out + 1] = n end
        table.sort(out)
        return out
    end)
end

compute_targets = function(goal, primary)
    local ids, names = {}, {}
    if type(goal) ~= "table" then
        return ids, names
    end
    local kind = guide.classify(goal)
    -- 1.4.0 (Zygor spec): an NPC by get_npc_id only - never by the displayed name
    if kind == "talk" or kind == "accept" or kind == "turnin" then
        if goal.npc_id then ids[goal.npc_id] = true end
        return ids, names
    end
    if kind == "item" then
        if goal.item_id then ids[goal.item_id] = true end
        if goal.target then names[goal.target] = true end
        return ids, names
    end
    -- the goal's own target first: a kill / get by its id, an object by its exact
    -- name (no quest-log objective text as names)
    if kind == "kill" and goal.action ~= "get" and goal.action ~= "collect" and goal.target_id then ids[goal.target_id] = true end
    -- 1.5.1 (log 23:58, step 17: one target_id, nine mob names "Voidborn Reserve,
    -- Voidfront Conjurer, ..."): a kill goal's own target list names every mob it
    -- takes - each name in it is a target too (exact get_name() match)
    if (kind == "kill" or kind == "collect") and type(goal.target) == "string" then
        for part in goal.target:gmatch("[^,]+") do
            local n = part:gsub("^%s+", ""):gsub("%s+$", "")
            if n ~= "" then names[n] = true end
        end
    end
    if kind == "object" and goal.target then names[goal.target] = true end
    -- The flattened bridge list has no action/owner; never promote it to targets.
    -- Explicit kill/from siblings are the only wider combat sources.
    if not primary and (kind == "kill" or kind == "collect") and not goal.sticky then
        for _, g in ipairs((guide.step() or {}).goals or {}) do
            if not g.is_complete and (g.action == "kill" or g.action == "from") then
                if g.target_id then ids[g.target_id] = true end
                for n in (g.target or ""):gmatch("[^,]+") do
                    names[n:match("^%s*(.-)%s*$")] = true
                end
            end
        end
    end
    local aid, aname = guide.avoided()
    for id in pairs(aid) do ids[id] = nil end
    for n in pairs(aname) do names[n] = nil end
    return ids, names
end

function guide.target_ids(goal)
    local ids = guide.targets(goal)
    local out = {}
    for id in pairs(ids) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
end

--- Does a unit or object name match the target names?
---
--- Exact first, then the name occurring inside a candidate - the candidates
--- are objective lines and guide sentences, which carry more than the name.
local function name_wanted(name, names)
    if type(name) ~= "string" or name == "" then
        return false
    end
    -- 1.4.0 (Zygor spec): exact get_name() matches only
    return names[name] == true
end

-- Object names against objective names, both ways round (2.79.0): an
-- objective names the ITEM, the object holding it is often longer or plural
-- ("Crate of ...", "... Candles"). A significant word of 4+ letters in common
-- also counts.
local function singular(n)
    n = string.lower(n)
    if n:sub(-3) == "ies" then return n:sub(1, -4) .. "y" end
    if n:sub(-2) == "es" and n:sub(-3, -3):match("[sxz]") then return n:sub(1, -3) end
    if n:sub(-1) == "s" and n:sub(-2) ~= "ss" then return n:sub(1, -2) end
    return n
end
local function object_wanted(name, names)
    -- 1.4.0 (Zygor spec): the object whose get_name() IS the string objective
    if type(name) ~= "string" or name == "" then return false end
    if names[name] then return true end
    local c = clean_text(name)
    if c ~= nil and names[c] == true then return true end
    -- 1.6.0 (audit: Zygor labels the objects in the plural - "Healing Salves",
    -- "Lightspire Spears" - the game names one "Healing Salve"): the same name
    -- up to case and a plural ending
    local one = singular(name)
    for n in pairs(names) do
        if type(n) == "string" and singular(n) == one then return true end
    end
    return false
end

guide.object_wanted = object_wanted          -- 1.2.73: esp.lua matches world objects the same way

-- ============================================================================
-- FINDING THINGS IN THE WORLD
-- ============================================================================

--- The nearest visible game object this goal wants, or nil.
---
--- Objects are not units: the mob scan will never return a chest or a herb,
--- so this walks the visible-object list itself.
local kind_logged = {}                       -- 1.7.17
function guide.find_object(player, range, goal, skip)
    if not player then
        return nil, nil
    end
    range = math.min(tonumber(range) or 30, MAX_RANGE)

    local ids, names = guide.targets(goal)
    -- Nothing named means nothing to look for. Returning the nearest object
    -- of any kind would have the bot clicking scenery.
    if next(ids) == nil and next(names) == nil then
        return nil, nil
    end

    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end

    local me = safe(function() return player:get_position() end)
    if not me then
        return nil, nil
    end

    -- ZYGOR (user, 2026-10-17): a world object is matched by NAME - no
    -- documented game_object call returns its entry id (get_npc_id is
    -- NPC-only), so the click goal's target_id never matches. Kept: basic
    -- objects (not a unit, not an item) the client will use (can_be_used);
    -- several with the name -> the one nearest this goal's own waypoint.
    local anchor = nil
    local gw = goal and guide.goal_waypoints(goal) or nil
    if type(gw) == "table" and gw[1] and gw[1].pos then anchor = gw[1].pos end
    local best, best_d, best_key = nil, nil, nil
    for i = 1, #list do
        local o = list[i]
        if indexable(o) and call(o.is_valid, o) ~= false then
            if call(o.is_basic_object, o) == true and call(o.is_unit, o) ~= true
                and call(o.is_item, o) ~= true and call(o.can_be_used, o) == true
                and not (skip and skip[call(o.get_guid, o) or false]) then
                if object_wanted(call(o.get_name, o), names) then
                    local pos = call(o.get_position, o)
                    if pos then
                        local d = call(player.distance_to, player, o)
                        if type(d) ~= "number" then
                            d = geometry.distance(me, pos)
                        end
                        local k = anchor and geometry.distance(anchor, pos) or d
                        if d <= range and (best_key == nil or k < best_key) then
                            best, best_d, best_key = o, d, k
                        end
                    end
                end
            end
        end
    end
    -- 1.7.17 (step 29: Zygor's text says "click Portal Kaalez" on the Portal
    -- Grimh step): nothing of that name - a usable object of the same KIND (the
    -- name's first word, "Portal") standing within KIND_YD of this goal's own
    -- waypoint is the one meant (logged once per object)
    if not best and anchor then
        local kind = nil
        for n in pairs(names) do
            if type(n) == "string" then
                local w = n:match("^(%a+)%s")
                if w and #w >= 4 then kind = string.lower(w) end
            end
        end
        if kind then
            local KIND_YD = 20
            for i = 1, #list do
                local o = list[i]
                if indexable(o) and call(o.is_valid, o) ~= false and call(o.is_basic_object, o) == true
                    and call(o.is_unit, o) ~= true and call(o.is_item, o) ~= true and call(o.can_be_used, o) == true
                    and not (skip and skip[call(o.get_guid, o) or false]) then
                    local on = call(o.get_name, o)
                    local w = type(on) == "string" and on:match("^(%a+)") or nil
                    local pos = call(o.get_position, o)
                    if w and string.lower(w) == kind and pos then
                        local k = geometry.distance(anchor, pos)
                        local d = call(player.distance_to, player, o) or geometry.distance(me, pos)
                        if k <= KIND_YD and d <= range and (best_key == nil or k < best_key) then
                            best, best_d, best_key = o, d, k
                        end
                    end
                end
            end
            if best then
                local g = call(best.get_guid, best)
                if g and not kind_logged[g] then
                    kind_logged[g] = true
                    local ok_l, log = pcall(require, "errorlog")
                    if ok_l and type(log) == "table" and type(log.trail) == "function" then
                        log.trail("guide", "no object named for this goal at its waypoint - using %s (same kind, %.0f yd from the waypoint)",
                            tostring(call(best.get_name, best)), best_key or -1)
                    end
                end
            end
        end
    end
    return best, best_d
end

local function tap_denied(u)
    local v = call(u.is_tap_denied, u)
    return v == true or (type(v) == "number" and v ~= 0)
end

--- Can the bot fight this unit? Alive, not a player, attackable.
local function fightable(player, u)
    if not (indexable(u) and call(u.is_valid, u) == true
        and call(u.is_unit, u) == true
        and call(u.is_dead_or_ghost, u) ~= true
        and call(u.is_player, u) ~= true
        and not tap_denied(u)                -- audit 2026-10-17: is_tap_denied returns a number
        and call(player.can_attack, player, u) ~= false) then
        return false
    end
    -- 1.2.30: "Avoid other player targets" - a mob another player is fighting
    do
        local okt, tgm = pcall(require, "targeting")
        if okt and type(tgm) == "table" and type(tgm.fought_by_other_player) == "function"
            and tgm.fought_by_other_player(player, u) == true then
            return false
        end
    end
    -- ZYGOR avoid lines: never fought
    local aid, aname = guide.avoided()
    local nid = call(u.get_npc_id, u)    -- (u is a unit: checked above)
    if (type(nid) == "number" and aid[nid]) or aname[call(u.get_name, u) or false] then
        return false
    end
    -- Never more than 5 levels above the player (2.95.0).
    local my_lvl = call(player.get_level, player)
    local lvl = call(u.get_level, u)
    if type(my_lvl) == "number" and type(lvl) == "number" and lvl > my_lvl + 5 then
        return false
    end
    -- Not one movement has given up on (2.84.0, the re-pathing ladder).
    local ok_s, st = pcall(require, "state")
    if ok_s and st and type(st.is_unreachable) == "function"
        and st.is_unreachable(call(u.get_guid, u)) then
        return false
    end
    -- Not in an area the player died in repeatedly (deathzones.lua, 2.247.0).
    local ok_t, tg = pcall(require, "targeting")
    if ok_t and type(tg) == "table" and type(tg.in_death_zone) == "function" and tg.in_death_zone(u) then
        return false
    end
    -- Not behind a wall, down a mine under the player or on a ledge overhead
    -- (2.81.0) - targeting.can_see, cached per mob.
    local t = targeting_mod
    if t == nil then
        local ok, m = pcall(require, "targeting")
        t = (ok and type(m) == "table") and m or false
        targeting_mod = t
    end
    if t and type(t.can_see) == "function" then
        return t.can_see(player, u) == true
    end
    return true
end

--- The nearest unit this goal wants to fight, or nil.
---
--- Name-matched against RestedXP's objective names, because its mob and
--- target steps carry names rather than creature ids. An id is used when the
--- guide happens to supply one.
function guide.find_mob(player, range, goal, primary)
    if not player then
        return nil, nil
    end
    range = math.min(tonumber(range) or 40, MAX_RANGE)

    local ids, names = guide.targets(goal, primary)
    if next(ids) == nil and next(names) == nil then
        return nil, nil
    end

    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end

    local aid, aname = guide.avoided()
    local best, best_d, best_sc = nil, nil, nil
    local esp = package.loaded["esp"]            -- 1.2.73: the ESP ranks a mob with a pack / an elite beside it farther
    for i = 1, #list do
        local u = list[i]
        -- Cheap filters first, fightable last (2.145.0): the id / name and the
        -- distance rule out most units without fightable's native calls.
        if indexable(u) and call(u.is_valid, u) == true and call(u.is_unit, u) == true
            and call(u.is_player, u) ~= true then
            -- 1.4.0 (Zygor spec): get_npc_id (NPCs only) against the goal's ids
            local uid = call(u.get_npc_id, u)
            local want = (type(uid) == "number" and ids[uid] == true)
                or name_wanted(call(u.get_name, u), names)          -- 1.5.1: the goal's own mob names
            if want and not aid[uid] and not aname[call(u.get_name, u)] then
                local d = call(player.distance_to, player, u)
                if type(d) == "number" and d <= range then
                    local pen = (type(esp) == "table" and type(esp.penalty) == "function") and (select(1, call(esp.penalty, u)) or 0) or 0
                    local sc = d + pen
                    if (best_sc == nil or sc < best_sc) and fightable(player, u) then
                        best, best_d, best_sc = u, d, sc
                    end
                end
            end
        end
    end
    return best, best_d
end

--- 2.287.0: the nearest mob named by ANOTHER unfinished kill goal of the
--- current RestedXP step (each by its own targets: line + objectives), or
--- nil. Replaces the step's generic target lines as the kill fallback: in
--- Northshire they listed Young Wolf for a Kobold Vermin step and a wolf was
--- always within reach, so the bot fought wolves instead of the quest.
function guide.find_other_goal_mob(player, range, goal)
    local step = guide.step()
    if not step or type(step.goals) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #step.goals do
        local g = shape_goal(step.goals[i], i)
        -- .target / .unitscan lines only set RestedXP's target macro: not a
        -- kill directive (.mob / .rare and quest objectives are)
        local act = string.lower(tostring(g and g.action or ""))
        if g and g.is_complete ~= true and (not goal or g.index ~= goal.index)
            and act ~= "target" and act ~= "unitscan"
            and guide.classify(g) == "kill" then
            local u, d = guide.find_mob(player, range, g, true)
            if u and (best_d == nil or (d or 1e9) < best_d) then best, best_d = u, d or 1e9 end
        end
    end
    return best, best_d
end

--- The nearest level-appropriate hostile near a point, or nil.
---
--- The closest fightable unit with this npc id, within `range` (2.139.0).
--- Returns unit, distance, how many of that id are in range.
-- duplicate (audit D6): NPC by id -> targeting.find_npc is the copy to keep
function guide.find_npc_mob(player, range, npc_id)
    if not player or type(npc_id) ~= "number" or npc_id <= 0 then
        return nil, nil, 0
    end
    range = math.min(tonumber(range) or 40, MAX_RANGE)
    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil, 0
    end
    local best, best_d, n = nil, nil, 0
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true and call(u.is_unit, u) == true
            and call(u.get_npc_id, u) == npc_id then
            local d = call(player.distance_to, player, u)
            if type(d) == "number" and d <= range and fightable(player, u) then
                n = n + 1
                if best_d == nil or d < best_d then
                    best, best_d = u, d
                end
            end
        end
    end
    return best, best_d, n
end

--- For an item objective whose drop source RestedXP does not name: its
--- waypoints sit on the camp that drops it, so what stands there is what to
--- fight. Kept to within LEVEL_GAP levels below the player, so critters and
--- grey wildlife around the camp are left alone.
local LEVEL_GAP = 4
-- A camp is judged from its waypoint, but the mob chosen must also be near the
-- PLAYER: one at the far edge of a 45-yard camp could be 90 yards off, which
-- sends the bot on a long pull-in across broken ground for a random mob.
local CAMP_REACH = 40

-- Never a camp target: nothing about these drops quest items.
local NOT_CAMP = nil
local function camp_excluded(u)
    if NOT_CAMP == nil then
        NOT_CAMP = {}
        local ok, enums = pcall(require, "common/enums")
        local ct = ok and type(enums) == "table" and enums.creature_type or nil
        if type(ct) == "table" then
            for _, k in ipairs({ "CRITTER", "NON_COMBAT_PET", "WILD_PET", "TOTEM", "GAS_CLOUD" }) do
                if type(ct[k]) == "number" then
                    NOT_CAMP[ct[k]] = true
                end
            end
        end
    end
    local t = call(u.get_creature_type, u)
    return type(t) == "number" and NOT_CAMP[t] == true
end

function guide.find_camp_mob(player, center, radius)
    if not player or not center then
        return nil, nil
    end
    radius = math.min(tonumber(radius) or 40, MAX_RANGE)
    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end
    local my_level = call(player.get_level, player) or 1
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true then
            local lvl = call(u.get_level, u) or 0
            local pos = call(u.get_position, u)
            if lvl >= my_level - LEVEL_GAP and pos and geometry.distance(center, pos) <= radius then
                local d = call(player.distance_to, player, u)
                if type(d) == "number" and d <= CAMP_REACH and (best_d == nil or d < best_d)
                    and not camp_excluded(u) and fightable(player, u) then
                    best, best_d = u, d
                end
            end
        end
    end
    return best, best_d
end

-- ============================================================================
-- DROP SOURCES FROM THE ITEM NAME (2.24.0)
-- ============================================================================
-- RestedXP names the ITEM a collect objective wants - "Tough Wolf Meat" - but
-- not the creature that drops it, and no unit is called "Tough Wolf Meat". The
-- bot used to fall straight back to fighting whatever stood at the waypoint:
-- troggs, boars and rabbits for wolf meat, and the quest never moved.
--
-- Item names almost always carry the dropper's name: Tough WOLF Meat, BOAR
-- Meat, KOBOLD Candle, WENDIGO Mane, Crag BOAR Rib. So the words of the item
-- name, minus the generic ones, are matched against the words of each unit's
-- name. Plurals are folded to one form on both sides (wolves -> wolf).
local GENERIC = {}
for w in ([[
    a an the of and or in on with for from to
    tough small large big young old fresh rotten raw cured fine coarse thick
    thin heavy light broken torn ragged pristine intact whole
    meat flesh flank rib ribs shank chop steak leg legs haunch loin
    hide hides pelt pelts skin skins leather fur scale scales feather feathers
    fang fangs tooth teeth claw claws talon talons tusk tusks horn horns hoof
    hooves paw paws tail tails ear ears eye eyes heart hearts head heads skull
    skulls bone bones blood venom sac sacs gland glands wing wings mane manes
    spine spines stinger stingers carapace shell shells egg eggs gizzard
    tongue brain liver kidney essence dust powder sample samples shard shards
    fragment fragments piece pieces chunk chunks scrap scraps bundle bundles
    sack sacks bag bags crate crates box boxes pouch pouches satchel bottle
    note letter orders package parcel token tokens badge insignia ring charm
    slain killed defeated destroyed collected gathered
]]):gmatch("%a+") do
    GENERIC[w] = true
end

local function fold(w)
    w = string.lower(w)
    if #w > 4 and w:sub(-3) == "ves" then
        return w:sub(1, -4) .. "f"           -- wolves -> wolf
    end
    if #w > 4 and w:sub(-3) == "ies" then
        return w:sub(1, -4) .. "y"
    end
    if #w > 3 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then
        return w:sub(1, -2)                  -- troggs -> trogg
    end
    return w
end

--- The meaningful words of the goal's objective names, as a set, or nil.
local function source_words(goal)
    local names = guide.objective_names(goal and goal.quest_id)
    local text = goal and strip_progress(goal.text)
    local set, any = {}, false
    local function take(s)
        if type(s) ~= "string" then
            return
        end
        for w in s:gmatch("%a+") do
            local f = fold(w)
            if #f >= 3 and not GENERIC[f] and not GENERIC[string.lower(w)] then
                set[f] = true
                any = true
            end
        end
    end
    for i = 1, #names do
        take(names[i])
    end
    take(text)
    return any and set or nil
end

--- Does the goal's item name give any clue to its drop source?
function guide.has_source_words(goal)
    return memo("srcw:" .. tostring(goal and goal.index or 0), function()
        return source_words(goal) and true or false
    end) == true
end

--- The nearest fightable unit whose name shares a meaningful word with the
--- item the goal collects, or nil.
function guide.find_source_mob(player, range, goal)
    if not player then
        return nil, nil
    end
    local words = memo("srcset:" .. tostring(goal and goal.index or 0), function()
        return source_words(goal)
    end)
    if not words then
        return nil, nil
    end
    range = math.min(tonumber(range) or 50, MAX_RANGE)
    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true then
            local name = call(u.get_name, u)
            if type(name) == "string" then
                local hit = false
                for w in name:gmatch("%a+") do
                    if words[fold(w)] then
                        hit = true
                        break
                    end
                end
                if hit then
                    local d = call(player.distance_to, player, u)
                    if type(d) == "number" and d <= range and (best_d == nil or d < best_d)
                        and not camp_excluded(u) and fightable(player, u) then
                        best, best_d = u, d
                    end
                end
            end
        end
    end
    return best, best_d
end

--- The nearest unit RestedXP has marked with a raid-target icon (2.53.0).
---
--- The guide puts raid markers (star ... skull, get_target_marker_index 1-8)
--- on the NPC a step wants spoken to and the mobs it wants killed. `want` is
--- "friendly" (an NPC to talk to - not attackable) or "hostile" (a mob to
--- fight - fightable). `exclude` is a GUID set to skip.
function guide.find_marked(player, range, want, exclude)
    if not player then
        return nil, nil
    end
    range = math.min(tonumber(range) or 60, MAX_RANGE)
    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true and call(u.is_unit, u) == true then
            local mark = call(u.get_target_marker_index, u)
            if type(mark) == "number" and mark >= 1 and mark <= 8
                and call(u.is_player, u) ~= true
                and call(u.is_dead_or_ghost, u) ~= true
                and not (exclude and exclude[call(u.get_guid, u) or ""]) then
                local ok
                if want == "hostile" then
                    ok = fightable(player, u)
                else
                    ok = call(player.can_attack, player, u) == false
                end
                if ok then
                    local d = call(player.distance_to, player, u)
                    if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then
                        best, best_d = u, d
                    end
                end
            end
        end
    end
    return best, best_d
end

--- The best hostile mob to clear on the way to `dest`, or nil (2.51.0).
---
--- Hostile (is_enemy_with the player, or already in combat), fightable -
--- alive, attackable, not a player, not tapped by someone else - not a
--- critter / pet / totem, within `range` of the player, within `cone`
--- degrees of the direction of travel (so the bot does not turn back for
--- mobs behind it), and between `below` levels under and `above` levels over
--- the player (no greys, no dangerous elites). Nearest wins.
function guide.find_path_mob(player, dest, range, cone, below, above)
    if not player or not dest then
        return nil, nil
    end
    local me = call(player.get_position, player)
    if not me then
        return nil, nil
    end
    local hx, hy = dest.x - me.x, dest.y - me.y
    local hlen = math.sqrt(hx * hx + hy * hy)
    if hlen < 1 then
        return nil, nil
    end
    hx, hy = hx / hlen, hy / hlen
    local cos_cone = math.cos(math.rad(cone or 70))
    local my_level = call(player.get_level, player) or 1
    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end
    local best, best_d = nil, nil
    local count = 0              -- 2.119.0: hostiles in range
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true then
            local d = call(player.distance_to, player, u)
            local hostile = type(d) == "number" and d <= (range or 20)
                and (call(u.is_enemy_with, u, player) == true or call(u.is_in_combat, u) == true)
            local lvl = hostile and (call(u.get_level, u) or 0) or 0
            -- 2.268.0: a path pull is never an elite (targeting.too_strong)
            local tg = hostile and targeting_mod or nil
            local strong = tg and type(tg.too_strong) == "function" and tg.too_strong(player, u)
            if hostile and not strong and lvl >= my_level - (below or 4) and lvl <= my_level + (above or 3)
                and not camp_excluded(u) and fightable(player, u) then
                local pos = call(u.get_position, u)
                if pos then
                    local ux, uy = pos.x - me.x, pos.y - me.y
                    local ul = math.sqrt(ux * ux + uy * uy)
                    -- Right beside the player counts whatever the angle.
                    if ul < 5 or (ux * hx + uy * hy) / ul >= cos_cone then
                        count = count + 1
                        if best_d == nil or d < best_d then
                            best, best_d = u, d
                        end
                    end
                end
            end
        end
    end
    return best, best_d, count
end

--- The npc id of whatever is currently targeted, or nil.
---
--- get_target is a UNIT method, not an object_manager one. An id of 0 means
--- "not a creature" - a player, a pet, an object - and is rejected.
---
--- Returns id, unit.
function guide.target_npc_id(player)
    if not player then
        return nil, nil
    end
    local target = safe(function() return player:get_target() end)
    if not target then
        return nil, nil
    end
    if safe(function() return target:is_valid() end) ~= true then
        return nil, nil
    end
    local id = geometry.object_id(target)
    if not id then
        return nil, target
    end
    return id, target
end

-- ============================================================================
-- LEARNING NPC IDS
-- ============================================================================
-- RestedXP never names the NPC behind an accept or turnin, so one can only be
-- read off a unit. Two pairings are kept:
--
--   quest title -> npc id   learned whenever a gossip frame is open with the
--                           NPC targeted: that NPC gives what the frame lists.
--   accept/turnin + quest id -> npc id
--                           learned when a dialog the bot opened with a unit
--                           actually accepted or handed in that quest.
--
-- Either lets the next visit go straight to a verified unit instead of
-- guessing by proximity. Persisted per character through settings.lua.
--
-- Staleness is handled rather than feared: an id that no longer matches
-- anything simply finds no unit, and the proximity path takes over.
local learned = {}           -- quest title -> npc id
local by_quest = {}          -- "a<quest id>" / "t<quest id>" -> npc id

local function mark_dirty()
    local ok, settings = pcall(require, "settings")
    if ok and settings and type(settings.mark_dirty) == "function" then
        settings.mark_dirty()
    end
end

-- RIGHT NPC ONLY (2.185.0). This saved every title in an open gossip frame
-- against the player's TARGET - and the target is not always the NPC whose
-- frame is open: a vendor trip targets the merchant, so "Investigate Echo
-- Ridge" was learned for Dermot Johns (a vendor), and every later turn-in
-- went to him ("via learned id 190"), stalled three times and skipped the
-- goal. A title is learned now only for a target standing at talking range
-- that the game flags as a quest giver (npc flag 0x2; not checked where the
-- client reports no flags).
local LEARN_RANGE = 6.0
local QUESTGIVER_FLAG = 0x2

--- Does this unit give quests? true / false, or nil when flags are unreadable.
function guide.gives_quests(u)
    local f = safe(function() return u:get_npc_flags() end)
    if type(f) ~= "number" then return nil end
    return math.floor(f / QUESTGIVER_FLAG) % 2 == 1
end

--- Record the targeted npc as the giver of whatever the gossip frame lists.
function guide.learn_npc_id(player)
    if safe(function() return core.quests.is_gossip_frame_shown() end) ~= true then
        return nil
    end
    local id, target = guide.target_npc_id(player)
    if not id or not target then
        return nil
    end
    local d = safe(function() return player:distance_to(target) end)
    if type(d) ~= "number" or d > LEARN_RANGE then
        return nil
    end
    if guide.gives_quests(target) == false then
        return nil
    end

    local changed = false
    local function record(list)
        if type(list) ~= "table" then
            return
        end
        for i = 1, #list do
            local q = list[i]
            if type(q) == "table" and type(q.title) == "string" and q.title ~= "" then
                if learned[q.title] ~= id then
                    learned[q.title] = id
                    changed = true
                end
            end
        end
    end
    record(safe(function() return core.quests.get_gossip_active_quests() end))
    record(safe(function() return core.quests.get_gossip_available_quests() end))

    -- Only ask for a write when something actually changed: this runs on
    -- every tick that has a gossip frame open.
    if changed then
        mark_dirty()
    end
    return id
end

local function quest_key(kind, quest_id)
    quest_id = tonumber(quest_id)
    if not quest_id then
        return nil
    end
    if kind == "accept" then
        return "a" .. quest_id
    end
    if kind == "turnin" then
        return "t" .. quest_id
    end
    return nil
end

--- Remember which NPC took an accept or a turnin for a quest.
function guide.learn_quest_npc(kind, quest_id, npc_id)
    local key = quest_key(kind, quest_id)
    npc_id = tonumber(npc_id)
    if not key or not npc_id or npc_id <= 0 then
        return
    end
    if by_quest[key] ~= npc_id then
        by_quest[key] = npc_id
        mark_dirty()
    end
end

--- Forget a learned NPC for a quest (2.185.0): it refused the quest, stalled
--- the goal, or is not a quest giver. Clears the quest-keyed pairing and any
--- title pairing that points at that NPC for this quest.
function guide.forget_quest_npc(kind, quest_id, npc_id, text)
    local changed = false
    local key = quest_key(kind, quest_id)
    if key and by_quest[key] and (npc_id == nil or by_quest[key] == npc_id) then
        by_quest[key] = nil
        changed = true
    end
    local title = guide.log_title(quest_id)
    for t, id in pairs(learned) do
        if (npc_id == nil or id == npc_id)
            and (t == title or (type(text) == "string" and string.find(text, t, 1, true))) then
            learned[t] = nil
            changed = true
        end
    end
    if changed then mark_dirty() end
    return changed
end

--- The NPC learned for an accept or turnin of a quest, or nil.
---
--- The quest-keyed pairing is tried first. A title learned from a gossip
--- frame is the fallback, matched against the quest's log title and the
--- goal's text.
function guide.known_quest_npc(kind, quest_id, text)
    local key = quest_key(kind, quest_id)
    if key and by_quest[key] then
        return by_quest[key]
    end
    local title = guide.log_title(quest_id)
    if title and learned[title] then
        return learned[title]
    end
    if type(text) == "string" and text ~= "" then
        for t, id in pairs(learned) do
            if string.find(text, t, 1, true) then
                return id
            end
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- PERSISTENCE
-- ----------------------------------------------------------------------------
-- settings.lua stores one line per provider as key=value and escapes the
-- value, so anything may be put in it. The inner format is one entry per line:
--
--     <npc id>=<quest title>       from a gossip frame
--     a<quest id>=<npc id>         the NPC that took an accept
--     t<quest id>=<npc id>         the NPC that took a turnin
--
-- A title line leads with its numeric id, so the first "=" is always the
-- separator and a title containing one cannot break the parse. The quest
-- lines lead with a letter, which an older build's parser skips.
local ENTRY_SEP = "\n"

--- Everything learned, for settings.lua to write out.
function guide.serialise()
    local lines = {}
    for title, id in pairs(learned) do
        if type(title) == "string" and title ~= "" and type(id) == "number" then
            lines[#lines + 1] = string.format("%d=%s", id, title)
        end
    end
    for key, id in pairs(by_quest) do
        if type(key) == "string" and type(id) == "number" then
            lines[#lines + 1] = string.format("%s=%d", key, id)
        end
    end
    -- Sorted so the file does not churn between sessions that learned the
    -- same things in a different order.
    table.sort(lines)
    return table.concat(lines, ENTRY_SEP)
end

--- Load what a previous session learned.
function guide.deserialise(text)
    learned = {}
    by_quest = {}
    if type(text) ~= "string" or text == "" then
        return
    end
    for line in text:gmatch("[^\n]+") do
        local qkey, qnpc = line:match("^([at]%d+)=(%d+)$")
        if qkey then
            local n = tonumber(qnpc)
            if n and n > 0 then
                by_quest[qkey] = n
            end
        else
            local id, title = line:match("^(%d+)=(.+)$")
            id = tonumber(id)
            if id and id > 0 and type(title) == "string" and title ~= "" then
                learned[title] = id
            end
        end
    end
end

--- Forget everything. Used by the tests and on a settings reset.
function guide.forget_npc_ids()
    learned = {}
    by_quest = {}
end

--- The npc id learned for a quest title, or nil.
function guide.known_npc_id(title)
    if type(title) ~= "string" or title == "" then
        return nil
    end
    return learned[title]
end

local CENTER_DZ = 30

--- The nearest NPC that can be spoken to.
---
--- Once the bot is standing where the guide sent it, the nearest unit it
--- cannot attack is a quest giver, a vendor or a guard rather than a mob.
--- Deliberately short ranged: it is a guess, and a guess is only reasonable
--- once standing where the guide pointed.
-- QUEST GIVERS ONLY (2.165.0). An accept / turn-in that the first NPC
-- refused went on to "the nearest friendly unit at the waypoint" - in the
-- 12:40 log Marryk Nurribit, Wren Darkspring and a player's Imp Minion. With
-- `quest_only` a unit must carry the quest-giver npc flag (0x2); a client
-- that reports no flags at all (nil) is not filtered.
local NPC_QUESTGIVER = 0x2

local function gives_quests(u)
    local f = call(u.get_npc_flags, u)
    if type(f) ~= "number" then return true end
    return math.floor(f / NPC_QUESTGIVER) % 2 == 1
end

function guide.nearest_talkable(player, range, center, exclude, quest_only)
    if not player then
        return nil, nil
    end
    range = math.min(tonumber(range) or 8, MAX_RANGE)

    local list = visible_objects()
    if type(list) ~= "table" then
        return nil, nil
    end

    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true
            and call(u.is_unit, u) == true
            and call(u.is_dead_or_ghost, u) ~= true
            and call(u.is_player, u) ~= true then
            if call(player.can_attack, player, u) == false
                and not (exclude and exclude[call(u.get_guid, u) or ""])
                and (not quest_only or gives_quests(u)) then
                local d
                if center then
                    -- Flat (2.134.0): a waypoint's height is the terrain
                    -- under it, which indoors is the ground outside, not the
                    -- floor the NPC stands on. CENTER_DZ keeps a unit on a
                    -- floor far above or below out.
                    local pos = call(u.get_position, u)
                    d = pos and geometry.distance_flat(center, pos) or nil
                    if d and type(center.z) == "number" and type(pos.z) == "number"
                        and math.abs(center.z - pos.z) > CENTER_DZ then
                        d = nil
                    end
                else
                    d = call(player.distance_to, player, u)
                end
                if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then
                    best, best_d = u, d
                end
            end
        end
    end
    return best, best_d
end

-- ============================================================================
-- FINDING THINGS IN THE BAGS
-- ============================================================================

--- The bag entry for an item this goal wants, or nil.
---
--- Returns the entry as core.inventory.get_items_in_bag gives it - the object
--- and its slot - because core.input.use_item wants the object, not an id.
-- 1.29.2 (user: "interact with items in bags at Zygor set locations"): Zygor's
-- API sends a use goal with no item id and no target (log 20:45, step 43 "use
-- Ironvine Seeds##24355 / Disable the Umbrafen Lake Pump Controls |q 9720/1").
-- data/zygor_use_items.lua (tools/import_zygor_use_items.py) holds every use
-- line of the TBC guides with its step's quest ids: the step's quests name it.
-- 1.29.3: the rows live in questitems.lua (QI.rows)
local function use_table()
    local ok, qi = pcall(require, "questitems")
    if ok and type(qi) == "table" and type(qi.rows) == "function" then return qi.rows() end
    return {}
end

--- 1.29.3: the quest ids of the current step's goals (plus `goal`'s own) - a set.
function guide.step_quests(goal)
    local quests = {}
    local gl = guide.goals()
    for i = 1, #gl do
        local q = tonumber(gl[i].quest_id)
        if q and q > 0 then quests[q] = true end
    end
    local gq = type(goal) == "table" and tonumber(goal.quest_id) or nil
    if gq and gq > 0 then quests[gq] = true end
    return quests
end

--- 1.35.0: the item ids the current step names - its get / collect goals' targets
--- and its item goals' ids - the goals before `goal` first, nearest first.
function guide.step_item_ids(goal)
    local gl = guide.goals()
    local at = type(goal) == "table" and tonumber(goal.index) or 0
    local before, after, seen = {}, {}, {}
    for i = 1, #gl do
        local g = gl[i]
        local id = tonumber(g.item_id)
        if not id and (g.action == "get" or g.action == "collect" or g.action == "goldcollect") then
            id = tonumber(g.target_id)
        end
        if id and id > 0 and not seen[id] and (tonumber(g.index) or i) ~= at then
            seen[id] = true
            if (tonumber(g.index) or i) < at then table.insert(before, 1, id) else after[#after + 1] = id end
        end
    end
    for i = 1, #after do before[#before + 1] = after[i] end
    return before
end

--- 1.35.0: the quests the current step accepts that are not in the log yet - a set.
function guide.step_open_accepts()
    local out = {}
    local gl = guide.goals()
    for i = 1, #gl do
        local g = gl[i]
        local q = tonumber(g.quest_id)
        if g.action == "accept" and q and q > 0 and g.is_complete ~= true
            and safe(function() return core.quests.is_on_quest(q) end) ~= true then
            out[q] = true
        end
    end
    return out
end

--- The item ids Zygor's guide uses on this goal's step (the step's quest ids),
--- the one in this use goal's place first. {} when none.
function guide.use_item_ids(goal)
    local out = {}
    if type(goal) ~= "table" then return out end
    local quests, n_use, any = {}, 0, false
    local gl = guide.goals()
    for i = 1, #gl do
        local g = gl[i]
        local q = tonumber(g.quest_id)
        if q and q > 0 then quests[q], any = true, true end
        if (g.action == "use" or g.action == "useany") and (tonumber(g.index) or 0) <= (tonumber(goal.index) or 0) then
            n_use = n_use + 1
        end
    end
    local gq = tonumber(goal.quest_id)
    if gq and gq > 0 then quests[gq], any = true, true end
    if not any then return out end
    local rest, seen = {}, {}
    local rows = use_table()
    for i = 1, #rows do
        local r = rows[i]
        if not seen[r.item] then
            for q in pairs(r.quests) do
                if quests[q] then
                    seen[r.item] = true
                    if r.n == n_use then out[#out + 1] = r.item else rest[#rest + 1] = r.item end
                    break
                end
            end
        end
    end
    for i = 1, #rest do out[#out + 1] = rest[i] end
    return out
end

local function bag_entry_of(item_id)
    for bag = 0, 4 do
        local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
        if type(items) == "table" then
            for i = 1, #items do
                local entry = items[i]
                if type(entry) == "table" and entry.object
                    and safe(function() return entry.object:get_item_id() end) == item_id then
                    entry.item_id = item_id
                    return entry
                end
            end
        end
    end
    return nil
end

function guide.find_bag_item(goal)
    -- ZYGOR: a use goal's target_id is the ITEM id (shape_goal: item_id).
    -- Bags are matched by that id first (get_item_id on a bag item), the
    -- target name second (core.quests.get_item_info(id).name).
    local want_id = type(goal) == "table" and tonumber(goal.item_id) or nil
    local _, names = guide.targets(goal, true)
    if not want_id and (names == nil or next(names) == nil) then
        -- A single quest starter in this step, with one open accept, is supported.
        -- General usable items without an association are never inferred from bags.
        if type(goal) == "table" and (goal.action == "use" or goal.action == "useany") and not goal.sticky then
            local accepts, naccept = guide.step_open_accepts(), 0
            for _ in pairs(accepts) do naccept = naccept + 1 end
            if naccept == 1 then
                local ok, bs = pcall(require, "quest/bagstart")
                local candidate, ambiguous = nil, false
                for _, id in ipairs(guide.step_item_ids(goal)) do
                    local f = ok and bs.facts(id) or {}
                    if f.quest and not f.spell and bs.has(id) then
                        if candidate and candidate ~= id then ambiguous = true end
                        candidate = id
                    end
                end
                if candidate and not ambiguous then return bag_entry_of(candidate) end
            end
        end
        -- Only an explicit, unique quest association may supply a missing item.
        local qu = guide.quest_use_item(goal)
        if qu then return qu end
        -- 1.2.27 (log 03:35-08:40, step 12 "use" with no item id, 5 h paused with
        -- "Well Water Sample Kit" in the bags): a use goal with no item id and
        -- exactly ONE usable quest item in the bags uses that item. Two or more
        -- stay ambiguous and are never guessed.
        if type(goal) == "table" and (goal.action == "use" or goal.action == "useany") and not goal.sticky then
            local okq, qi = pcall(require, "questitems")
            local list = okq and type(qi) == "table" and type(qi.list) == "function" and qi.list() or {}
            local only, n = nil, 0
            for _, e in ipairs(list) do
                if not e.buff_only then n = n + 1 only = e end
            end
            -- never when the bundled data already names an item for this step's
            -- quests (that item is missing: using another one would be wrong)
            local known = false
            local sq = guide.step_quests(goal)
            if okq and type(sq) == "table" and type(qi.rows) == "function" then
                for _, row in ipairs(qi.rows() or {}) do
                    for q in pairs(row.quests or {}) do
                        if sq[q] then known = true end
                    end
                end
            end
            if n == 1 and only and not known then return bag_entry_of(only.item_id) end
        end
        return nil
    end
    for bag = 0, 4 do
        local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
        if type(items) == "table" then
            for i = 1, #items do
                local entry = items[i]
                if type(entry) == "table" and entry.object then
                    local iid = safe(function() return entry.object:get_item_id() end)
                    if type(iid) == "number" and want_id and iid == want_id then
                        entry.item_id = iid
                        return entry
                    end
                    if not want_id and type(iid) == "number" and names and next(names) ~= nil then
                        local info = safe(function() return core.quests.get_item_info(iid) end)
                        local iname = (type(info) == "table" and type(info.name) == "string")
                            and info.name or nil
                        if name_wanted(iname, names) then
                            entry.item_id = iid
                            return entry
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- Missing item IDs require a unique verified quest association. No bag cycling.
function guide.quest_use_item(goal, only)
    if type(goal) ~= "table" or only then return nil end
    local ok, qi = pcall(require, "questitems")
    if not ok or type(qi.for_quests) ~= "function" then return nil end
    local list = qi.for_quests(guide.step_quests(goal), false) or {}
    local chosen = nil
    for _, e in ipairs(list) do
        if e.item_id and e.item_id ~= guide.use_ingredient(goal) then
            if chosen and chosen.item_id ~= e.item_id then return nil end
            chosen = e
        end
    end
    return chosen
end

--- Use a bag item by id - the documented calls only:
---   core.input.use_item(item_id)                  no target
---   core.input.use_item_target(item_id, target)   on a unit / object
--- Returns true when a use was issued.
function guide.use_bag_item(entry, target)
    if type(entry) ~= "table" then
        return false
    end
    local iid = tonumber(entry.item_id)
    if not iid and entry.object then
        iid = safe(function() return entry.object:get_item_id() end)
    end
    if type(iid) ~= "number" then
        return false
    end
    if target then
        local ok, res = pcall(function() return core.input.use_item_target(iid, target) end)
        return ok and res ~= false
    end
    local ok, res = pcall(function() return core.input.use_item(iid) end)
    return ok and res ~= false
end
-- ============================================================================
-- WAYPOINTS
-- ============================================================================
-- Zygor waypoints are map coordinates: x, y in 0-1 on map_id.
-- core.game_ui.get_world_pos_from_map_pos(map_id, vec2) -> vec2, continent
-- converts them without touching terrain (no ray). The second return is the
-- continent (instance map id, 0 when unknown): a point on another continent
-- than the player's is refused - Zygor has no wrong_continent field.
-- The height is measured in to_world: within 150 yd of the player it IS
-- coords_helper:map_to_world (1.7.13, pcall'd; it casts from the player's own
-- floor - the old Grindbot crash came from casts far from the player), else
-- core.get_height_for_position; then the mesh floor (get_all_heights).
local WORLD_LIMIT = 20000
local CONV_MAX = 400

local vec2_mod = nil
local conv = {}
local conv_n = 0
local conv_retry = {}
local CONV_RETRY = 5.0
local wrong_continent_seen = false

local function vec2_new(x, y)
    if vec2_mod == nil then
        local ok, mod = pcall(require, "common/geometry/vector_2")
        vec2_mod = (ok and type(mod) == "table") and mod or false
    end
    if vec2_mod and type(vec2_mod.new) == "function" then
        local ok, v = pcall(vec2_mod.new, x, y)
        if ok and v ~= nil then
            return v
        end
    end
    return nil
end

local function elog()
    local ok, mod = pcall(require, "errorlog")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function finite(n)
    return type(n) == "number" and n == n and n > -WORLD_LIMIT and n < WORLD_LIMIT
end

local function convert(map_id, x, y)
    local mp = vec2_new(x, y)
    if not mp then
        return nil
    end
    local gui = safe(function() return core.game_ui end)
    if gui and type(gui.get_world_pos_from_map_pos) == "function" then
        local ok, w, cont = pcall(gui.get_world_pos_from_map_pos, map_id, mp)
        if ok and w ~= nil then
            local wx, wy = tonumber(get(w, "x")), tonumber(get(w, "y"))
            if finite(wx) and finite(wy) and not (wx == 0 and wy == 0) then
                return { x = wx, y = wy, z = nil, final = false, continent = tonumber(cont) or 0 }
            end
        end
    end
    return nil
end

-- 1.4.1 (log 23:20, Isle of Quel'Danas: every waypoint "on another continent"):
-- the conversion said continent 2858 for map 2432 while core.get_map_id()
-- answered 2432 (the zone's UI map) and core.get_instance_id() 2537 - three
-- numbering schemes. The player's continent is now asked the SAME way as the
-- waypoint's: get_world_pos_from_map_pos on the player's own UI map
-- (core.game_ui.get_current_map_id). get_map_id / get_instance_id only when
-- the conversion cannot answer. Cached CONT_TTL s.
local CONT_TTL = 2.0
local my_cont = { t = -1e9, id = 0, ui = nil }
-- 1.7.7 (log 2026-10-18 12:00: through the Dark Portal, in Hellfire Peninsula,
-- the bot still read "player 0" and walked back to the Blasted Lands portal):
-- core.get_instance_id() is the continent's map id on the open world (nav log
-- "instance_id 530 ... Outland"). When it names one of these continents and
-- the UI-map conversion disagrees (a stale or missing UI map after a loading
-- screen), it wins. A dungeon / another client's numbering (Quel'Danas 2537,
-- 1.4.1) is not in the list and leaves the conversion alone.
local WORLD_CONTINENTS = { [0] = true, [1] = true, [530] = true, [571] = true }
local function instance_continent()
    local ok, id = pcall(function() return core.get_instance_id() end)
    if ok and type(id) == "number" and id ~= 0 and WORLD_CONTINENTS[id] then return id end   -- 0 may mean "unknown"
    return nil
end
local function player_ui_map()
    local gui = safe(function() return core.game_ui end)
    -- 1.7.26 (game_ui doc): with the world map open get_current_map_id is the
    -- zone being browsed, not the player's - nil, the last good continent stands
    if gui and type(gui.is_map_open) == "function" and safe(function() return gui.is_map_open() end) == true then
        return nil
    end
    if gui and type(gui.get_current_map_id) == "function" then
        local ok, id = pcall(gui.get_current_map_id)
        if ok and type(id) == "number" and id > 0 then return id end
    end
    return nil
end
local function my_continent()
    -- 1.6.0 (audit: after a UI reload the UI map read nil, the fallback stored
    -- core.get_map_id()'s ZONE map 2432 / 2565 as "the continent" and every
    -- waypoint (continent 2858) was refused for minutes): the continent is only
    -- ever a CONVERTED value - the UI map, else core.get_map_id(), is converted;
    -- when that fails the last good continent stands (0 = unknown, not refused)
    local now = clock()
    if now - my_cont.t < CONT_TTL and my_cont.known then return my_cont.id, my_cont.ui end
    my_cont.t = now
    local ui = player_ui_map()
    if not ui then
        local ok, id = pcall(function() return core.get_map_id() end)
        if ok and type(id) == "number" and id > 0 then ui = id end
    end
    my_cont.ui = ui
    local inst = instance_continent()                     -- 1.7.7
    if ui then
        local e = convert(ui, 0.5, 0.5)
        if e then                            -- a converted map: its continent is known (0 = Eastern Kingdoms)
            local c = tonumber(e.continent) or 0
            if inst ~= nil and WORLD_CONTINENTS[c] and c ~= inst then
                c = inst                     -- 1.7.7: a stale UI map after a portal
                my_cont.ui = nil
            end
            my_cont.id, my_cont.known = c, true
            return my_cont.id, my_cont.ui
        end
    end
    if inst ~= nil then                      -- 1.7.7: no usable UI map: the instance's continent
        my_cont.id, my_cont.known, my_cont.ui = inst, true, nil
        return my_cont.id, nil
    end
    return my_cont.id, ui                    -- the last converted continent (or unknown)
end

--- 1.4.1: is a converted waypoint (map map_id, continent cont) where the player is?
local function same_continent(cont, map_id)
    -- 1.31.2 (log 2026-10-25 23:43, step 64 "talk Elsharin", Stormwind City 36,81 from
    -- Zangarmarsh): the conversion answers 0 for the Eastern Kingdoms - the same 0 as
    -- "unknown" - so every EK waypoint was taken as local: a move_to 8425 yd to
    -- (-9006, 885) on the Outland mesh, HTTP 422 "not on navmesh" for minutes. 0 / nil:
    -- the UI map's own continent (gamever.continent_of_uimap: 1453 -> 0) decides.
    if (cont or 0) == 0 then
        local okg, gv = pcall(require, "gamever")
        local by_map = okg and type(gv) == "table" and type(gv.continent_of_uimap) == "function"
            and gv.continent_of_uimap(map_id) or nil
        if by_map == nil then return true end         -- unknown: not refused
        cont = by_map
        local here0 = my_continent()
        if my_cont.known then return by_map == here0 end
        return true
    end
    local here, ui = my_continent()
    if not my_cont.known then return true end               -- 1.6.0: ours unknown: not refused
    if cont == here then return true end
    if map_id and ui and map_id == ui then return true end   -- the player's own map
    return false
end
guide.same_continent = same_continent

local function usable(wp)
    if type(wp) ~= "table" then
        return false
    end
    local map_id = tonumber(wp.map_id)
    return map_id ~= nil and map_id ~= 0
end

-- 1.7.14 MESH FLOOR PICK (user): every mesh floor under a point. 1.10.0:
-- Sentinel get_all_heights, asked through movement/nav N.all_heights (the
-- adapter movement/sentinel.lua; cb(list of heights)). A waypoint within 150 yd asks once (on the update tick,
-- FLOOR_GAP s apart, cached FLOOR_TTL s, a miss again after FLOOR_BAD_TTL) and
-- takes the mesh floor CLOSEST to the height already picked (the Coords
-- Helper's floor of the player) - a stair landing, a bridge or a cave under it
-- is told apart from the one the player is on. No answer yet: that height stands.
local FLOOR_TTL, FLOOR_BAD_TTL, FLOOR_GAP, FLOOR_MAX = 60, 10, 1.0, 200   -- 1.19.1: GAP 0.5 -> 1.0 (Sentinel <= 1 request/s)
-- 1.7.31 (log 2026-10-18 20:38:54: the waypoint (315, 1442) flipped from z 1 to
-- z -1190 - the only mesh floor answered there, picked as the "closest"): a
-- floor more than FLOOR_DZ yd from the measured height is not this spot's.
-- 1.67.0: was 60 (a cave under a hill counted as the same spot). Matches
-- movement/nav N.FLOOR_LAYER (8). movement/nav's no-path height search tries
-- the others.
local FLOOR_DZ = 8
local floors, floors_n, floor_next = {}, 0, -1e9
local function floor_value(v)
    if type(v) == "table" then v = v.z end
    v = tonumber(v)
    if v and v == v and v > -WORLD_LIMIT and v < WORLD_LIMIT then return v end
    return nil
end
local function floor_pick(key, x, y, z, max_delta)
    local t = clock()
    local e = floors[key]
    if e and e.values and (t - e.t) < FLOOR_TTL then
        local best = nil
        for i = 1, #e.values do
            local v = floor_value(e.values[i])
            if v and math.abs(v - z) <= (max_delta or FLOOR_DZ) and (best == nil or math.abs(v - z) < math.abs(best - z)) then best = v end
        end
        if best and not e.logged then
            e.logged = true
            local log = elog()
            if log then
                log.trail("waypoint", "mesh floors %d under (%.1f, %.1f): %.1f picked (closest to %.1f)",
                    #e.values, x, y, best, z)
            end
        end
        return best, e.values                         -- 1.9.2: the cached floors too (cave_floor)
    end
    if e and e.pending and (t - e.t) < 5 then return nil end
    if e and not e.pending and not e.values and (t - e.t) < FLOOR_BAD_TTL then return nil end
    if not reads_ok or t < floor_next then return nil end
    local nav = package.loaded["movement/nav"]
    if type(nav) ~= "table" or type(nav.all_heights) ~= "function" then return nil end
    floor_next = t + FLOOR_GAP
    if floors_n >= FLOOR_MAX then floors, floors_n = {}, 0 end
    if not e then floors_n = floors_n + 1 end
    local rec = { t = t, pending = true }
    floors[key] = rec
    local okc, sent = pcall(nav.all_heights, { x = x, y = y, z = z }, function(vals)
        rec.pending, rec.t = false, clock()
        if type(vals) == "table" and #vals > 0 then rec.values = vals end
    end)
    if not (okc and sent == true) then rec.pending = false end
    return nil
end
guide._test_floor_pick = floor_pick

-- 1.9.2 (Forever 1.0.22) THE CAVE FLOOR. Outdoors the probe_up 1000 surface
-- sample is the first solid from above - over a cave, its roof - and the mesh
-- floor nearest it is the hill. From floor_pick's CACHED mesh floors
-- (get_all_heights - not asked more often): when one lies at least CAVE_BELOW
-- yd under the surface sample and within CAVE_NEAR yd of the player's own z,
-- the player stands at the mouth - that floor is the waypoint's z (several:
-- the one nearest the player). The player within CAVE_BELOW yd of the surface
-- (on the hill, a bridge), a single floor, or a lower floor far from the
-- player (not a mouth): the floor picked as before. Not indoors, not swimming.
local CAVE_BELOW, CAVE_NEAR = 8, 6
local cave_logged = nil
local function cave_floor(values, z_surface, mz)
    if type(values) ~= "table" or #values < 2 or not finite(z_surface) or not finite(mz) then return nil end
    if math.abs(mz - z_surface) <= CAVE_BELOW then return nil end
    local best = nil
    for i = 1, #values do
        local v = floor_value(values[i])
        if v and v <= z_surface - CAVE_BELOW and math.abs(v - mz) <= CAVE_NEAR
            and (best == nil or math.abs(v - mz) < math.abs(best - mz)) then
            best = v
        end
    end
    return best
end
guide._cave_floor = cave_floor

local function to_world(wp)
    if not usable(wp) then
        return nil
    end
    local map_id = tonumber(wp.map_id)
    local x = tonumber(wp.x)
    local y = tonumber(wp.y)
    if not x or not y or x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 then
        return nil
    end
    if x == 0 and y == 0 then
        return nil
    end
    local key = string.format("%d|%.4f|%.4f", map_id, x, y)
    local e = conv[key]
    if e == false then
        if clock() < (conv_retry[key] or 0) then return nil end
        e = nil
    end
    if e == nil then
        if conv_n >= CONV_MAX then
            conv, conv_n, conv_retry = {}, 0, {}
        end
        e = convert(map_id, x, y)
        conv[key] = e or false
        conv_retry[key] = not e and (clock() + CONV_RETRY) or nil
        conv_n = conv_n + 1
        local log = elog()
        if log then
            if e then
                log.trail("waypoint", "map %d (%.4f, %.4f) -> world (%.1f, %.1f) continent %d",
                    map_id, x, y, e.x, e.y, e.continent or 0)
            else
                log.warn("waypoint map %d (%.4f, %.4f) could not be converted", map_id, x, y)
            end
        end
        if not e then
            return nil
        end
    end
    if not same_continent(e.continent, map_id) then
        wrong_continent_seen = true
        return nil
    end
    -- 1.4.0 (user spec): Z is measured - core.get_height_for_position from 1000 yd
    -- up on open ground; indoors the probe starts just above the player (a high
    -- ray hits the ceiling). A miss (0) keeps the player's own height.
    local z = e.z
    local swim = safe(function() return core.character.is_swimming() end) == true     -- 1.7.2: R9.2
    -- audit P2: a measured height is kept on the point for 5 s while the
    -- player stays within 20 yd of where it was measured (e.final is never
    -- set - not waited on) - no height query, coords_helper or reach_z per tick
    local me0 = (not swim) and safe(function() return izi.me():get_position() end) or nil
    local t_now = safe(function() return izi.now() end) or 0
    if not swim and e.mz and (t_now - (e.mz_t or -1e9)) < 5 and me0 and type(me0.x) == "number"
        and type(me0.z) == "number" and e.mz_pz and math.abs(me0.z - e.mz_pz) <= 2.5
        and ((me0.x - e.mz_px) ^ 2 + (me0.y - e.mz_py) ^ 2) <= 20 * 20 then
        return vec3.new(e.x, e.y, e.mz)
    end
    if not e.final and not swim then
        local me = me0
        local mz = tonumber(get(me, "z"))
        local p = safe(function() return izi.me() end)
        local indoors = p and safe(function() return p:is_indoors() end) == true
        -- 1.7.13 (user: "apply the height change"): the Coords Helper first -
        -- coords:map_to_world(ui_map, vec2) casts from the PLAYER's own floor
        -- (extra_height nil = 4 yd above the player), so a point near the player
        -- gets this floor's height, not a roof / an arch / a canopy above it. Only
        -- within COORDS_RANGE yd: farther away (another hill) a ray from the
        -- player's height can start under the ground there. A miss (0 away from
        -- 0, R9.1) or no helper: the 1.4.0 probes below.
        local cz = nil
        local px, py = tonumber(get(me, "x")), tonumber(get(me, "y"))
        local near = px and py and ((e.x - px) ^ 2 + (e.y - py) ^ 2) <= 150 * 150
        if near then
            local okc, ch = pcall(require, "common/utility/coords_helper")
            local mp = vec2_new(x, y)
            if okc and type(ch) == "table" and type(ch.map_to_world) == "function" and mp then
                local okw, w = pcall(ch.map_to_world, ch, map_id, mp)
                local wz = okw and type(w) == "table" and tonumber(w.z) or nil
                if wz and wz == wz and (wz ~= 0 or (mz and math.abs(mz) < 8)) then cz = wz end
            end
        end
        local ok_h, h
        if cz then
            ok_h, h = true, cz
        elseif indoors and mz then
            ok_h, h = pcall(core.get_height_for_position, vec3.new(e.x, e.y, mz), { probe_up = 4 })
        else
            ok_h, h = pcall(core.get_height_for_position, vec3.new(e.x, e.y, 0), { probe_up = 1000 })
        end
        -- 1.7.2 (R9.1): a miss returns 0, which is also a real height - 0 counts
        -- only when the player stands near 0 too
        if ok_h and type(h) == "number" and (h ~= 0 or (mz and math.abs(mz) < 8)) then z = h elseif mz then z = mz end
        -- 1.22.0: a Zygor point under Telredor's mushroom cap is the town on top
        -- (movement/elevator EL.cap_z): looked for at the town's height, so the
        -- floor pick below takes the cap's floor, not the marsh under it
        do
            local EL = package.loaded["movement/elevator"]
            local capz = type(EL) == "table" and type(EL.cap_z) == "function" and safe(function() return EL.cap_z(e.x, e.y, z) end) or nil
            if type(capz) == "number" then z = capz end
        end
        -- 1.7.14: the mesh floor closest to that height (near the player only)
        local settled = true
        if near and z then
            local z_surface = z
            local fz, vals = floor_pick(key, e.x, e.y, z, indoors and 2.5 or nil)
            if fz then
                z = fz
                -- 1.67.0: nav reuses this height (no second get_all_heights).
                local nv = package.loaded["movement/nav"]
                if type(nv) == "table" and type(nv.remember_floor) == "function" then
                    pcall(nv.remember_floor, e.x, e.y, fz)
                end
            else
                settled = false
            end   -- floors still being asked: not cached yet
            -- 1.9.2: outdoors, the probe_up 1000 sample at a cave mouth - the cave
            -- floor, not the roof (map_to_world, cast from the player's floor, stays)
            if not cz and not indoors and ok_h and h == z_surface then
                local cfz = cave_floor(vals, z_surface, mz)
                if cfz and math.abs(cfz - z) > 0.5 then
                    if cave_logged ~= key then
                        cave_logged = key
                        local log = elog()
                        if log then
                            log.trail("waypoint", "(%.0f, %.0f): surface z %.1f is a roof %.0f yd above the player - "
                                .. "the cave floor z %.1f", e.x, e.y, z_surface, z_surface - mz, cfz)
                        end
                    end
                    z = cfz
                end
            end
        end
        -- 1.7.31: a height movement/nav found a path at, after no path at this one
        local nav = package.loaded["movement/nav"]
        if not indoors and type(nav) == "table" and type(nav.reach_z) == "function" then
            local zf = safe(function() return nav.reach_z({ x = e.x, y = e.y, z = z or 0 }) end)
            if type(zf) == "number" then z = zf end
        end
        if settled and z and me and type(me.x) == "number" then    -- audit P2: kept for 5 s
            e.mz, e.mz_t, e.mz_px, e.mz_py, e.mz_pz = z, t_now, me.x, me.y, me.z
        end
    end
    return vec3.new(e.x, e.y, z or 0)
end
guide.to_world = to_world

local function raw_waypoint()
    refresh()
    return snap.wp
end

local function raw_step_waypoints()
    refresh()
    return snap.step_wps
end

--- Where Zygor's arrow points now, in world coordinates: pos, dist, title.
function guide.waypoint()
    local wp = raw_waypoint()
    local pos = to_world(wp)
    if not pos then
        return nil
    end
    return pos, tonumber(wp.dist), (type(wp.title) == "string" and wp.title ~= "") and wp.title or nil
end

--- The arrow's waypoint type (way / path / farm / route), or nil.
function guide.waypoint_type()
    local wp = raw_waypoint()
    return type(wp) == "table" and wp.type or nil
end

local compute_goal_waypoints

--- The waypoints of one goal as { pos, title, map_id, mx, my }: the step
--- waypoints whose goal_num is this goal's index (type way / path / farm);
--- the current arrow only when the goal has none.
function guide.goal_waypoints(goal)
    local key = "wps:" .. tostring(type(goal) == "table" and goal.index or 0)
    local wps = memo(key, function() return compute_goal_waypoints(goal) end)
    -- audit P3: no second compute in the same call when there are none
    return type(wps) == "table" and wps or {}
end

--- 1.7.20: does the step (or Zygor's arrow) have ANY waypoint, usable here or
--- not (another continent)? A use goal is only used on the spot when it has none.
function guide.step_has_waypoint()
    local list = raw_step_waypoints()
    if type(list) == "table" and #list > 0 then return true end
    return type(raw_waypoint()) == "table"
end

-- Goals a bare kill line may be scanned THROUGH on its way to the collection block that owns the camp
-- (action log 2026-11-15, step 137: kill Frostmane Seers / click Shimmerweed Baskets / goto / goto /
-- get Shimmerweed - the click line stopped the scan, the kill had no waypoint and the bot stood at the
-- previous NPC for 2 minutes). Anything that starts other work (accept, turnin, talk, use ...) still stops it.
local BORROW_PASS = { [""] = true, kill = true, text = true, click = true, clicknpc = true, goto = true, at = true,
    mapmarker = true, avoid = true, info = true, confirm = true }

-- 1.2.38: forward borrow tables (see compute_goal_waypoints); one local, the file is near the 60-local limit
local FWD = {
    origin = { talk = true, gossip = true, accept = true, turnin = true, click = true, clicknpc = true,
        vendor = true, trainer = true, stablemaster = true, home = true, buy = true, bank = true },
    source = { q = true, collect = true, get = true, accept = true, turnin = true, fpath = true, ferry = true,
        home = true, buy = true, bank = true, ["goto"] = true, at = true, [""] = true },
    new_npc = { talk = true, gossip = true, clicknpc = true, vendor = true, trainer = true, stablemaster = true },
    pass = { text = true, info = true, mapmarker = true, avoid = true, confirm = true },
}

compute_goal_waypoints = function(goal)
    local out = {}
    local index = type(goal) == "table" and goal.index or nil
    -- Stickies are not in get_step_waypoints; the live arrow below is used
    -- when this sticky is the work Zygor currently has the bot doing.
    if not (type(goal) == "table" and goal.sticky) then
    if index then
        local list = raw_step_waypoints()
        for i = 1, #list do
            local wp = list[i]
            if type(wp) == "table" and tonumber(wp.goal_num) == index then
                local pos = to_world(wp)
                if pos then
                    out[#out + 1] = {
                        pos = pos,
                        title = (type(wp.title) == "string" and wp.title ~= "") and wp.title or nil,
                        map_id = tonumber(wp.map_id), mx = tonumber(wp.x), my = tonumber(wp.y),
                        wtype = wp.type, own = true,
                    }
                end
            end
        end
    end
    if #out == 0 and index and goal.action == "kill"
        and tonumber(goal.target_id or goal.npc_id) == 18351 then
        local step = guide.step()
        local qi,q = lump_objective(step and step.goals)
        if qi and q.is_complete ~= true then
            local shared = compute_goal_waypoints(shape_goal(q,qi,step.goals))
            for _,wp in ipairs(shared) do
                out[#out+1]={pos=wp.pos,title=wp.title,map_id=wp.map_id,mx=wp.mx,my=wp.my,
                    wtype=wp.wtype,own=false,source_goal=qi}
            end
        end
    end
    -- Zygor writes a drop-source kill line before the collect lines that own
    -- its camp coordinates (e.g. Zangarmarsh step 124). Only a bare kill may
    -- share the following collection block; never borrow another task's point.
    if #out == 0 and index and goal.action == "kill" and not goal.quest_id then
        local step = guide.step()
        local goals = step and step.goals or {}
        for j = index + 1, #goals do
            local g = goals[j]
            local action = g.action
            if action == "get" or action == "collect" then
                if g.is_complete ~= true then
                    local shared = compute_goal_waypoints(shape_goal(g, j, goals))
                    if #shared > 0 then
                        for _, wp in ipairs(shared) do
                            out[#out + 1] = {pos=wp.pos, title=wp.title, map_id=wp.map_id,
                                mx=wp.mx, my=wp.my, wtype=wp.wtype, own=false, source_goal=j}
                        end
                        break
                    end
                end
            elseif not BORROW_PASS[action or ""] then
                break
            end
        end
    end
    -- A talk/gossip block can keep its location on the following quest response
    -- (Elder Kuruti). Require one named NPC and stop at any unrelated action.
    if #out == 0 and index and (goal.action == "talk" or goal.action == "gossip") and goal.npc_id then
        local step = guide.step()
        local goals = step and step.goals or {}
        local one_npc = true
        for _, g in ipairs(goals) do
            if g.action == "talk" and g.npc_id and g.npc_id ~= goal.npc_id then one_npc = false break end
        end
        if one_npc then
            for j = index + 1, #goals do
                local g = goals[j]
                if g.action == "q" and g.is_complete ~= true then
                    local shared = compute_goal_waypoints(shape_goal(g, j, goals))
                    for _, wp in ipairs(shared) do
                        out[#out + 1] = {pos=wp.pos,title=wp.title,map_id=wp.map_id,
                            mx=wp.mx,my=wp.my,wtype=wp.wtype,own=false,source_goal=j}
                    end
                    break
                elseif g.action ~= "gossip" and g.action ~= "text" and g.action ~= "" and g.action ~= nil then
                    break
                end
            end
        end
    end
    -- A verified use item may share its own quest objective's live location.
    -- Zygor often puts |goto on the following |q line, not on the use line.
    if #out == 0 and index and (goal.action == "use" or goal.action == "useany") then
        local entry = guide.find_bag_item(goal)
        local ok, qi = pcall(require, "questitems")
        local quests = ok and entry and qi.quests_of(entry.item_id) or {}
        local step = guide.step()
        local goals = step and step.goals or {}
        for j = index + 1, #goals do
            local g = goals[j]
            if g.action == "use" or g.action == "useany" then break end
            if (g.action == "q" or g.action == "havebuff") and g.is_complete ~= true and quests[tonumber(g.quest_id)] then
                local shared = compute_goal_waypoints(shape_goal(g, j, goals))
                if #shared > 0 then
                    for _, wp in ipairs(shared) do
                        out[#out + 1] = {pos=wp.pos,title=wp.title,map_id=wp.map_id,
                            mx=wp.mx,my=wp.my,wtype=wp.wtype,own=false,source_goal=j}
                    end
                    break
                end
            end
        end
    end
    -- 1.2.38 FORWARD BORROW. Zygor puts the step's |goto on ONE line; the other goals on the
    -- same NPC / object get no waypoint (log audit 2026-11-18, 312 sessions: every click goal,
    -- every talk goal, 17 of 143 turn-ins and 21 of 186 accepts read "0 waypoints" - 994 "no usable
    -- waypoint for Waterlogged Axe" ticks, 120 s waits at "talk Ariena Stormfeather" before an fpath
    -- line and at "talk Innkeeper Allison" before a home line). An NPC / object goal with no point of
    -- its own takes the first later point of the same step; a different NPC starting ends the scan.
    if #out == 0 and index and FWD.origin[goal.action or ""] then
        local step = guide.step()
        local goals = step and step.goals or {}
        for j = index + 1, #goals do
            local g = goals[j]
            local a = g.action or ""
            local same_talk = a == "talk" and goal.action == "talk" and g.npc_id ~= nil and g.npc_id == goal.npc_id
            if FWD.new_npc[a] and not same_talk then break end
            if a == "click" and goal.action == "click" and g.target ~= goal.target then break end
            if FWD.source[a] and g.is_complete ~= true then
                local shared = compute_goal_waypoints(shape_goal(g, j, goals))
                if #shared > 0 then
                    for _, wp in ipairs(shared) do
                        out[#out + 1] = {pos=wp.pos,title=wp.title,map_id=wp.map_id,
                            mx=wp.mx,my=wp.my,wtype=wp.wtype,own=false,source_goal=j}
                    end
                    break
                end
            elseif not FWD.pass[a] and not FWD.source[a] and not same_talk then
                break
            end
        end
    end
    end
    -- 1.68.0: Zygor's live arrow is the current-step destination when this
    -- goal has no point of its own. The arrow is used when it names this
    -- goal, or when it names none and this is the work compute_goal() is
    -- performing. An arrow that names another goal stays refused (stale
    -- travel / another continent).
    if #out == 0 and type(goal) == "table" and index and snap.wp then
        local gn = tonumber(snap.wp.goal_num)
        local mine = gn == index
        if not mine and gn == nil then
            local cur = compute_goal()
            mine = cur ~= nil and cur.index == index
        end
        if mine and (goal.sticky or not guide.goal_off_continent(goal)) then
            local pos, _, title = guide.waypoint()
            if pos then
                out[1] = { pos = pos, title = title, wtype = guide.waypoint_type(), own = false }
            end
        end
    end
    return out
end

--- 1.3.1: the continent of a converted map point, or nil when unknown.
local function continent_of(wp)
    if type(wp) ~= "table" then return nil end
    local map_id, x, y = tonumber(wp.map_id), tonumber(wp.x), tonumber(wp.y)
    if not map_id or map_id == 0 or not x or not y then return nil end
    local key = string.format("%d|%.4f|%.4f", map_id, x, y)
    local e = conv[key]
    if e == nil then
        to_world(wp)
        e = conv[key]
    end
    local c = type(e) == "table" and tonumber(e.continent) or nil
    if c == 0 then return nil end          -- 0 = unknown (documented)
    return c
end

--- 1.2.48 IS THIS WAYPOINT ON ANOTHER CONTINENT? continent_of() answers nil for the Eastern Kingdoms (the conversion's 0 is
--- also "unknown"), so a Loch Modan waypoint seen from Darkshore was never "off the continent": offworld_map() was nil, the boat
--- was never asked for and the bot stood in Darkshore for 90 minutes after a hearth (log 2026-11-18 09:44-11:20). A nil / 0
--- continent is judged by the waypoint's own UI map (same_continent -> gamever.continent_of_uimap).
local function wp_off_continent(wp)
    local c = continent_of(wp)
    if c then return not same_continent(c, tonumber(wp.map_id)) end
    local mid = type(wp) == "table" and tonumber(wp.map_id) or nil
    if not mid or mid == 0 then return false end
    return not same_continent(0, mid)
end

--- 1.3.1: is this goal's own step waypoint on another continent than the
--- player? Returns true, map_id, title.
function guide.goal_off_continent(goal)
    if type(goal) == "table" and goal.sticky then return false end
    local index = type(goal) == "table" and goal.index or nil
    if not index then return false end
    local list = raw_step_waypoints()
    for i = 1, #list do
        local wp = list[i]
        if type(wp) == "table" and tonumber(wp.goal_num) == index then
            if wp_off_continent(wp) then return true, tonumber(wp.map_id), wp.title end
        end
    end
    return false
end

--- 1.2.52: the title of Zygor's arrow when it is a travel leg (route / taxi), even when
--- its point is on no continent the bot can place (a hearth leg); nil otherwise.
function guide.route_title()
    local wp = raw_waypoint()
    if type(wp) ~= "table" or (wp.type ~= "route" and wp.type ~= "taxi") then return nil end
    if type(wp.title) ~= "string" or wp.title == "" then return nil end
    return wp.title
end

--- 1.3.1: is Zygor's arrow a travel leg (route) on this continent? pos, title.
function guide.route_leg()
    local wp = raw_waypoint()
    if type(wp) ~= "table" or (wp.type ~= "route" and wp.type ~= "taxi") then return nil end
    local pos = to_world(wp)
    if not pos then return nil end
    return pos, wp.title
end

-- 1.7.6 WALK-IN PORTALS BETWEEN CONTINENTS. Zygor's own travel data
-- (ZygorGuidesViewerClassicTBCAnniv\Libs-TBC\LibRover-1.0\data_transit.lua,
-- {mode:PORTAL} nodes) - "Blasted Lands/0 58.72,59.93 -to- Hellfire
-- Peninsula/0 89.39,50.22" and back "Hellfire Peninsula/0 89.82,50.21 -to-
-- Blasted Lands/0 58.66,59.56". UI maps 1419 = Blasted Lands, 1944 =
-- Hellfire Peninsula (both as the client reports them in the session logs).
-- Boats / zeppelins (a ride, a wait) are not walk-ins and are not here.
-- 1.7.7 (user: "move the step in waypoint closer to the portal"): ax / ay is
-- where Zygor puts a player ARRIVING on this side (the other node's "-to-"
-- point, in front of the portal); the step-in point is STEP_IN yd beyond the
-- entry along arrival -> entry, inside the portal.
local PORTALS = {
    { from = 1419, x = 0.5872, y = 0.5993, ax = 0.5866, ay = 0.5956, to = 1944,
      title = "the Dark Portal (to Hellfire Peninsula)" },
    { from = 1944, x = 0.8982, y = 0.5021, ax = 0.8939, ay = 0.5022, to = 1419,
      title = "the Dark Portal (to the Blasted Lands)" },
}
local STEP_IN = 6.0
local portal_conv = {}                       -- "map|x|y" -> converted point or false
local function conv_cached(map_id, x, y)
    local k = string.format("%d|%.4f|%.4f", map_id, x, y)
    local e = portal_conv[k]
    if e == nil then
        e = convert(map_id, x, y) or false
        portal_conv[k] = e
    end
    return e or nil
end

--- 1.7.6: the walk-in portal from the player's continent to the continent of
--- UI map `dest_map`: world point { x, y } (no height - the caller's) and a
--- title, or nil.
function guide.portal_toward(dest_map)
    dest_map = tonumber(dest_map)
    if not dest_map or dest_map == 0 then return nil end
    local here = my_continent()
    if not my_cont.known then return nil end
    local d = conv_cached(dest_map, 0.5, 0.5)
    if not d then return nil end
    for i = 1, #PORTALS do
        local p = PORTALS[i]
        local a, b = conv_cached(p.from, 0.5, 0.5), conv_cached(p.to, 0.5, 0.5)
        if a and b and (a.continent or 0) == (here or 0) and (b.continent or 0) == (d.continent or 0)
            and (a.continent or 0) ~= (b.continent or 0) then
            local e = conv_cached(p.from, p.x, p.y)
            if e then
                -- 1.7.7: the step-in point, STEP_IN yd past the entry, into the portal
                local r = conv_cached(p.from, p.ax, p.ay)
                local step = nil
                if r then
                    local dx, dy = e.x - r.x, e.y - r.y
                    local l = math.sqrt(dx * dx + dy * dy)
                    if l > 0.5 then step = { x = e.x + dx / l * STEP_IN, y = e.y + dy / l * STEP_IN } end
                end
                return { x = e.x, y = e.y }, p.title, p, step
            end
        end
    end
    return nil
end

--- 1.7.6: the UI map of Zygor's arrow when it points to another continent, or nil.
function guide.offworld_map()
    local wp = raw_waypoint()
    if type(wp) ~= "table" then return nil end
    if wp_off_continent(wp) then return tonumber(wp.map_id), wp.title end
    return nil
end

--- 1.3.1: one line per goal and waypoint of the current step, for the log on
--- every step change (so a stall can be read from the session log).
function guide.dump_step()
    local out = {}
    local step = guide.step()
    if not step then return out end
    out[#out + 1] = string.format("step %d (complete %s), %d goal(s)", step.num, tostring(step.is_complete), #step.goals)
    for i = 1, #step.goals do
        local g = step.goals[i]
        out[#out + 1] = string.format("  goal %d: action '%s' quest %s npc %s (%s) target %s (%s) complete %s -> %s",
            i, tostring(g.action), tostring(g.quest_id), tostring(g.npc_id), tostring(g.npc), tostring(g.target_id),
            tostring(g.target), tostring(g.is_complete), tostring(guide.classify(shape_goal(g, i, step.goals))))
    end
    local here = my_continent()
    local list = raw_step_waypoints()
    for i = 1, #list do
        local wp = list[i]
        out[#out + 1] = string.format("  waypoint goal_num %s: map %s (%.4f, %.4f) type %s '%s' continent %s (player %d)",
            tostring(wp.goal_num), tostring(wp.map_id), tonumber(wp.x) or 0, tonumber(wp.y) or 0, tostring(wp.type),
            tostring(wp.title), tostring(continent_of(wp) or "?"), here)
    end
    local a = raw_waypoint()
    if a then
        out[#out + 1] = string.format("  arrow: map %s (%.4f, %.4f) type %s '%s' goal_num %s continent %s",
            tostring(a.map_id), tonumber(a.x) or 0, tonumber(a.y) or 0, tostring(a.type), tostring(a.title),
            tostring(a.goal_num), tostring(continent_of(a) or "?"))
    end
    return out
end

--- 1.2.55 ARROW PROBE. What the arrow's numbers really are: `dist` (Zygor: yards from the player to the
--- waypoint, said by the user 2026-11-19; the 1.2.53 log read 0 at every arrow change), `goal_num` (the step goal
--- the arrow belongs to) and `is_manual`. Every PROBE_GAP s a line pairs them with what the bot measures itself:
---   arrow dist <Zygor> vs <own flat yards to the arrow point> | goal_num <n> | manual <b> | step waypoints: g<goal>:<type>:<dist>/<own>
--- so a later change can trust (or drop) dist. Logging only; nothing decides on it yet. `pos` = the player's position.
local probe_t = -1e9
local PROBE_GAP = 20
function guide.arrow_probe(pos)
    local now = clock()
    if now - probe_t < PROBE_GAP then return end
    probe_t = now
    local a = raw_waypoint()
    if not a or type(pos) ~= "table" or type(pos.x) ~= "number" then return end
    local ok, log = pcall(require, "errorlog")
    if not ok or type(log) ~= "table" or type(log.trail) ~= "function" then return end
    local function own(wp)
        local w = to_world(wp)
        if not w or type(w.x) ~= "number" then return nil end
        local dx, dy = w.x - pos.x, w.y - pos.y
        return math.sqrt(dx * dx + dy * dy)
    end
    local parts = {}
    local list = raw_step_waypoints() or {}
    for i = 1, math.min(#list, 8) do
        local wp = list[i]
        if type(wp) == "table" then
            local o = own(wp)
            parts[#parts + 1] = string.format("g%s:%s:%s/%s", tostring(wp.goal_num), tostring(wp.type),
                wp.dist and string.format("%.0f", wp.dist) or "-", o and string.format("%.0f", o) or "-")
        end
    end
    local o = own(a)
    pcall(log.trail, "zygor", "arrow probe: dist %s vs own %s | goal_num %s | manual %s | type %s | step waypoints: %s",
        a.dist and string.format("%.0f", a.dist) or "-", o and string.format("%.0f", o) or "-",
        tostring(a.goal_num), tostring(a.is_manual), tostring(a.type),
        #parts > 0 and table.concat(parts, " ") or "none")
end

-- THE ROUTE a kill / collect / xp goal is walked along: the goal's points,
-- else every step point, plus the arrow; a single point becomes a patrol ring.
local ROUTE_RADIUS = 25
local ROUTE_RING = 6
local ROUTE_SAME = 15

local function flat_apart(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

function guide.route(goal, kind, wps)
    wps = wps or guide.goal_waypoints(goal)
    if kind ~= "kill" and kind ~= "collect" and kind ~= "xp" then
        return wps
    end
    local key = "route:" .. tostring(type(goal) == "table" and goal.index or 0) .. ":" .. tostring(kind)
    local r = memo(key, function()
        local out = {}
        for i = 1, #wps do out[#out + 1] = wps[i] end
        if #out == 1 then
            local c = out[1].pos
            for k = 0, ROUTE_RING - 1 do
                local a = k * 2 * math.pi / ROUTE_RING
                out[#out + 1] = {
                    pos = vec3.new(c.x + ROUTE_RADIUS * math.cos(a), c.y + ROUTE_RADIUS * math.sin(a), c.z),
                    title = out[1].title, patrol = true,
                }
            end
        end
        if #out == 0 then return nil end
        return out
    end)
    if type(r) == "table" and #r > 0 then
        return r
    end
    return wps
end

--- Was a waypoint of this step on another continent? (status line)
function guide.wrong_continent()
    refresh()
    if snap.wp and to_world(snap.wp) == nil and wrong_continent_seen then
        return true
    end
    return false
end

function guide.step_waypoints()
    local out = {}
    local list = raw_step_waypoints()
    for i = 1, #list do
        local pos = to_world(list[i])
        if pos then
            out[#out + 1] = pos
        end
    end
    return out
end

-- 1.9.2 ZYGOR VENDOR SPOTS (merchants.lua): the vendor and buy goals of the
-- current step and its stickies as { npc_id, name, x, y, z, action, step }.
-- npc_id / name: the goal's NPC (a buy goal borrows the step's talk NPC, as
-- shape_goal pairs them). The point: the step waypoint whose goal_num is the
-- goal's index, else the waypoint of the step's talk / vendor goal of the same
-- NPC, converted by to_world (get_world_pos_from_map_pos; refused on another
-- continent). Sticky goals have no step waypoint of their own and are left
-- out. A goal with a point but neither id nor name is a spot (merchants.lua).
local function vendor_goal_point(index, npc_id, npc, goals)
    local list = raw_step_waypoints()
    local function point_of(gi)
        for i = 1, #list do
            local wp = list[i]
            if type(wp) == "table" and tonumber(wp.goal_num) == gi then
                local pos = to_world(wp)
                if pos then return pos end
            end
        end
        return nil
    end
    local pos = point_of(index)
    if pos or not (npc_id or npc) then return pos end
    for j = 1, #goals do
        local o = goals[j]
        if j ~= index and type(o) == "table" and TALK_ACTIONS[o.action]
            and ((npc_id and o.npc_id == npc_id) or (npc and o.npc == npc)) then
            pos = point_of(j)
            if pos then return pos end
        end
    end
    return nil
end
function guide.vendor_goals()
    local v = memo("vendor_goals", function()
        local out = {}
        local step = guide.step()
        local goals = type(step) == "table" and step.goals or nil
        if type(goals) ~= "table" then return out end
        for i = 1, #goals do
            local g = goals[i]
            if type(g) == "table" and (g.action == "vendor" or g.action == "buy") then
                local sg = shape_goal(g, i, goals)
                local pos = sg and vendor_goal_point(i, sg.npc_id, sg.npc, goals) or nil
                if pos and type(pos.x) == "number" and type(pos.y) == "number" then
                    out[#out + 1] = { npc_id = sg.npc_id, name = sg.npc, x = pos.x, y = pos.y, z = pos.z,
                        action = g.action, step = step.num }
                end
            end
        end
        return out
    end)
    return type(v) == "table" and v or {}
end

-- ============================================================================
-- STATUS
-- ============================================================================

function guide.describe()
    if not guide.is_loaded() then
        return "Zygor Guides not loaded"
    end
    if not guide.ready() then
        return "Zygor has no active step (no guide loaded, or the guide is finished)"
    end
    local goal = guide.goal()
    if not goal then
        return "Zygor step complete"
    end
    if guide.wrong_continent() then
        return "Zygor waypoint is on another continent"
    end
    local kind = guide.classify(goal)
    if kind == "unknown" then
        return string.format("Zygor action '%s' is not handled yet - paused", tostring(goal.action))
    end
    local what = goal.text or tostring(goal.quest_id or "?")
    return string.format("%s %s", kind, what)
end

local compute_snapshot

function guide.snapshot()
    return memo("snapshot", compute_snapshot)
end

compute_snapshot = function()
    local out = {
        loaded = guide.is_loaded(),
        ready = false,
        step = 0,
        goals = {},
        goal = nil,
        kind = nil,
        objectives = {},
        waypoint = nil,
        wrong_continent = false,
        stickies = 0,
        describe = guide.describe(),
    }
    if not out.loaded then
        return out
    end
    out.ready = guide.ready()
    if not out.ready then
        return out
    end
    out.step = guide.step_num()
    out.goals = guide.goals()
    out.goal = guide.goal()
    if out.goal then
        out.kind = guide.classify(out.goal)
        out.objectives = guide.objectives(out.goal.quest_id)
    end
    local wp = raw_waypoint()
    if type(wp) == "table" and tonumber(wp.map_id) and tonumber(wp.map_id) ~= 0 then
        out.waypoint = {
            title = (type(wp.title) == "string" and wp.title ~= "") and wp.title or nil,
            dist = tonumber(wp.dist),
            map_id = tonumber(wp.map_id),
            type = wp.type,
        }
    end
    out.wrong_continent = guide.wrong_continent()
    out.stickies = #guide.stickies()
    return out
end

-- ============================================================================
-- SKIPPING - guide.skip_current (above) is Zygor's own skip_current_step. The inactive-step
-- escape of the RestedXP engine has no Zygor counterpart and answers false.
-- ============================================================================
function guide.skip_inactive() return false end
function guide.inactive_step() return nil end

return guide
