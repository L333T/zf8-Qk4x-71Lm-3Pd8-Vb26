-- ============================================================================
-- Master Farmer - Zygor Forever
-- quest/travel.lua - flights: RestedXP ".fly" goals and far-goal flight trips
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Zygor_Forever
-- ============================================================================
-- 2.307.0: SPLIT OUT OF quest/engine.lua, which sat at Lua's hard limit of
-- 200 locals per chunk (audit LUA-5) - the next `local` there would have
-- stopped the quest pack compiling. Moved unchanged apart from the engine
-- pieces it shares, which the engine hands over in TR.init (C below):
--   C.walk_to, C.find_giver          the engine's walk / NPC finder
--   C.act_until(), C.set_act_until() the engine's shared interact timer
--   C.ACT_GAP, C.TALK_REACH          the engine's constants
-- Public: TR.init, TR.in_flight (exported by the engine as quest.in_flight),
-- TR.fly_goal, TR.far_travel, TR.reset_goal.
--
-- 1.34.0 (user 2026-10-26: "Correct zygor_forever to correctly interact with taxi
-- flight paths"). The TBC guides have no "fly" lines - Zygor's travel router
-- (LibRover) plans the flights and shows them on the arrow as a route leg titled
-- "Talk to <npc>\nFly to <node>" at the flight master (data_common.lua
-- point_context_templates). The bot walked past that leg, the whole way on foot.
-- Now TR.route_flight takes it: walk to the leg's point, talk to the flight master
-- there, open its map, take <node> (the router names the in-game node), wait out
-- the flight, and carry on with the same goal on landing. A leg that cannot be
-- flown (node unknown / not on the map, no flight master, no take-off) is logged
-- and walked instead for FM.RT.BLOCK_S s.
-- Also: a "fly" goal's landing node is resolved from its waypoint's POSITION
-- (data/taxi_nodes.lua, the in-game names) before its title; the bot dismounts
-- before taking a flight; no game UI reload on landing (that was RestedXP's step
-- refresh - Zygor completes a fly goal itself within 50 yd of the landing).
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")
local gamever = require("gamever")
local gossip = require("gossip")
local state = require("state")
local npc = require("quest/npc")
local targeting = require("targeting")
local movement = require("movement")
local guide = require("quest/guide")

local TR = {}
local C = {}

--- Called once by quest/engine.lua with the pieces this module shares with it.
function TR.init(ctx)
    for k, v in pairs(ctx) do C[k] = v end
end

-- Same contracts as the engine's own helpers.
local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local errorlog = nil
do
    local ok, mod = pcall(require, "errorlog")
    if ok and type(mod) == "table" then
        errorlog = mod
    end
end

local function trail(tag, fmt, ...)
    if errorlog then
        errorlog.trail(tag, fmt, ...)
    end
end

-- ============================================================================
-- FLIGHT (2.95.0) - RestedXP ".fly <destination>"
-- ============================================================================
-- Walk to the flight master (found like any NPC goal), open its map - picking
-- the taxi gossip option when it talks first - find the destination by name
-- (the node list is per flight master, so it is matched by name every time,
-- never by a remembered index) and take it. In the air the bot does nothing.
-- 2.106.0 - FLIGHT MASTER FIXES
--   * A quest window left open at the flight master (Thor at Sentinel Hill
--     is both quest giver and gryphon master) has no taxi option; the bot
--     used to wait on it forever ("gossip has no taxi option"). Now any open
--     frame without a taxi option is closed and the NPC is talked to again.
--   * The taxi option is found through izi.gossip (TAXI icon, "taxi" type,
--     then the option text) and selected with the view's own :select().
--   * RestedXP colour tags (|cRXP_FRIENDLY_...|r) are stripped from the
--     destination before it is matched against the flight map's node names;
--     an exact node name wins, then the part before the comma.
--   * The flight is tracked by position, not only is_flying (not proven true
--     on a taxi): nothing else runs while it travels, a take-off that never
--     leaves the ground is retried, and on landing the goal is closed so the
--     bot heads for the guide's next position.
local g_fly_taken = 0
local g_fly_warned = false
local g_fly_noopt = 0          -- frames opened at the flight master with no taxi option
local g_fly_fails = 0          -- take-offs that never left the ground
local FLY_NOOPT_MAX = 4
local FLY_FAIL_MAX = 3
local FLY_TAKEOFF = 8.0        -- seconds for a take-off to show movement
local FLY_SPEED = 10.0         -- yd/s: faster than this is a flight
local FLY_LANDED = 2.5         -- seconds still before a flight counts as landed

-- { dest, taken, from, last, last_t, still_since, airborne, step, goal }
local g_flight = nil
local g_trip = nil             -- 2.115.0: flight trip toward a far goal (see far_travel)

local function clean_text(text)
    text = type(text) == "string" and text or ""
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cRXP_[%u_]-_", ""):gsub("|r", "")
    return text
end

local function fly_destination(goal)
    local text = clean_text(goal.text or goal.target)
    local dest = text:match("^[Ff]ly%s+to%s+(.+)$") or text:match("^[Ff]ly%s+(.+)$") or text
    dest = dest:gsub("^%s+", ""):gsub("%s*[%.,!]+$", ""):gsub("%s+$", "")
    return dest ~= "" and dest or nil
end

--- The node to fly to for `dest` on the OPEN taxi map: index, node count,
--- and - when the destination is on the map but cannot be taken - its
--- node_type. 2.280.0 (Taxi API): only a REACHABLE node is ever returned;
--- CURRENT is where the character stands, DISTANT is another continent,
--- NONE is undiscovered - take_node does nothing for those, which used to
--- look like a failed take-off three times before the step was skipped.
--- A client that answers "" for the type is trusted (older builds).
local function taxi_node_for(dest)
    local n = safe(function() return core.taxi.num_nodes() end)
    if type(n) ~= "number" or n <= 0 or not dest then return nil, n end
    local want = dest:lower()
    local first = want:match("^([%a']+)")
    local exact, partial, loose = nil, nil, nil
    local blocked = nil            -- node_type of a matching node that cannot be taken
    local exact_blocked = nil      -- ... of the EXACT match: then no looser match is flown to
    for i = 1, n do
        local name = safe(function() return core.taxi.node_name(i) end)
        if type(name) == "string" and name ~= "" and name ~= "INVALID" then
            local low = name:lower()
            local head = low:match("^([^,]+)") or low
            local rank = nil
            if low == want or head == want then
                rank = 1
            elseif low:find(want, 1, true) or want:find(head, 1, true) then
                rank = 2
            elseif first and #first >= 4 and low:find(first, 1, true) then
                rank = 3
            end
            if rank then
                local ntype = safe(function() return core.taxi.node_type(i) end)
                local can = type(ntype) ~= "string" or ntype == "" or ntype == "REACHABLE"
                if can then
                    if rank == 1 and not exact then exact = i
                    elseif rank == 2 and not partial then partial = i
                    elseif rank == 3 and not loose then loose = i end
                else
                    if rank == 1 then exact_blocked = exact_blocked or ntype end
                    blocked = blocked or ntype
                end
            end
        end
    end
    -- The named flight point exists but cannot be flown to: never a
    -- different one that merely shares part of its name.
    if not exact and exact_blocked then return nil, n, exact_blocked end
    local idx = exact or partial or loose
    return idx, n, (not idx) and blocked or nil
end



--- Select the taxi option of the open gossip frame. True when one was chosen.
-- 2.239.0 flight-master helpers, in one table (this file is at Lua's 200-local limit).
local FM = {
    GOSSIP_TRIES = 3,          -- gossip windows without a flight option before the next NPC
    FLAG = 0x2000,             -- UNIT_NPC_FLAG_FLIGHTMASTER
}

--- 2.280.0: the names of the nodes the open map can fly to now (for the log).
function FM.reachable_names(n)
    local names = {}
    for i = 1, n do
        local ntype = safe(function() return core.taxi.node_type(i) end)
        if type(ntype) ~= "string" or ntype == "" or ntype == "REACHABLE" then
            names[#names + 1] = tostring(safe(function() return core.taxi.node_name(i) end))
        end
    end
    return names
end

--- GUIDs as text (2.239.0): on this client get_guid() can be userdata, and
--- two reads of the same GUID need not compare equal.
function FM.guid_text(u)
    local g = safe(function() return u:get_guid() end)
    if g == nil then return nil end
    local ok, s = pcall(tostring, g)
    if ok and type(s) == "string" and s ~= "" then return s end
    return nil
end

--- audit Q12: a quest window left over from the NPC blocks its flight map - it
--- is closed on one tick and the NPC talked to on the next (never both).
FM.qclosed = false
function FM.close_then_interact(unit)
    if not FM.qclosed then
        FM.qclosed = true
        pcall(function() core.quests.close_quest() end)
        return
    end
    FM.qclosed = false
    pcall(function() require("movement").interact(unit) end)
end

function FM.is_flight_master(u)
    local f = safe(function() return u:get_npc_flags() end)
    return type(f) == "number" and f > 0 and math.floor(f / FM.FLAG) % 2 == 1
end

--- One log line with what an open gossip window offers (why no flight option).
function FM.log_gossip_options(who)
    local parts = {}
    local opts = safe(function() return core.quests.get_gossip_options() end)
    if type(opts) == "table" then
        for i = 1, math.min(#opts, 8) do
            local o = opts[i]
            if type(o) == "table" then
                parts[#parts + 1] = string.format("'%s' type=%s icon=%s", tostring(o.name),
                    tostring(o.gossip_type), tostring(o.icon))
            end
        end
    end
    trail("travel", "%s's gossip has no flight option: %s", tostring(who),
        #parts > 0 and table.concat(parts, "; ") or "no options listed")
end

--- ZYGOR: the nearest living friendly NPC flagged flight master (0x2000)
--- within `range` of `center` (default: the player). Returns unit, distance.
function FM.flat(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

function FM.nearest(player, range, center)
    local here = center or safe(function() return player:get_position() end)
    if not here or type(here.x) ~= "number" then return nil end
    local best, best_d = nil, nil
    local list = targeting.visible_objects() or {}
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return u:is_dead() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= true
            and FM.is_flight_master(u) then
            local p = safe(function() return u:get_position() end)
            local d = p and FM.flat(here, p)
            if d and d <= range and (best_d == nil or d < best_d) then best, best_d = u, d end
        end
    end
    return best, best_d
end

local function taxi_gossip()
    -- gossip.lua (2.144.0): izi's TAXI icon, then type "taxi" / wording.
    return (gossip.select({ icon = "TAXI", type = "taxi", words = { "fly", "flight", "ride", "taxi" } }))
end

local function pos_of(player)
    local p = safe(function() return player:get_position() end)
    if p and type(p.x) == "number" then return { x = p.x, y = p.y, z = p.z or 0 } end
    return nil
end

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- On a flight path? Tracked from the take-off: is_flying, or moving faster
--- than a character can run. Ends FLY_LANDED seconds after the movement stops.
function TR.in_flight(player)
    if not g_flight or not player then return false end
    local now = izi.now()
    local here = pos_of(player)
    if not here then return true end
    if safe(function() return player:is_flying() end) == true then
        g_flight.still_since = nil
        g_flight.airborne = true
        g_flight.last, g_flight.last_t = here, now
        return true
    end
    local dt = now - g_flight.last_t
    if dt >= 0.5 then
        local speed = dist3(here, g_flight.last) / dt
        g_flight.last, g_flight.last_t = here, now
        if speed > FLY_SPEED then
            g_flight.airborne = true
            g_flight.still_since = nil
        else
            g_flight.still_since = g_flight.still_since or now
        end
    end
    if not g_flight.airborne then
        -- Still on the ground after the take-off window: the flight never started.
        if now - g_flight.taken >= FLY_TAKEOFF and dist3(here, g_flight.from) < 5 then
            g_fly_fails = g_fly_fails + 1
            trail("act", "flight to %s did not take off (%d/%d)", tostring(g_flight.dest), g_fly_fails, FLY_FAIL_MAX)
            g_flight = nil
            g_fly_taken = 0
            return false
        end
        return true
    end
    if g_flight.still_since and (now - g_flight.still_since) >= FLY_LANDED then
        trail("act", "landed at %s (%.0f yd from take-off)", tostring(g_flight.dest), dist3(here, g_flight.from))
        -- RestedXP normally ticks the fly goal off on landing; close it if it
        -- has not, so the bot heads for the guide's next position.
        -- Not for a travel flight (2.115.0): that one only got the bot
        -- closer, the goal itself still has to be done.
        if g_flight.travel then
            g_trip = nil
            FM.RT.key = nil                  -- 1.34.0: a route flight - the goal itself goes on
        elseif guide.step_num() == g_flight.step then
            pcall(guide.mark_goal_done, g_flight.step, g_flight.goal)
        end
        g_flight = nil
        g_fly_taken = 0
        g_fly_fails = 0
        -- 1.34.0: no game UI reload on landing (RestedXP's 2.107.0 step refresh) -
        -- Zygor's own step state follows the player; a reload only cost seconds
        return false
    end
    return true
end

-- ZYGOR fly (user, 2026-10-17): LibTaxi:FindTaxi puts the landing node's
-- coordinates and name on the goal - the API only shows them as the step
-- waypoint (title = taxi node name). Done within FM.ARRIVE (Zygor's dist 50)
-- of it; the flight master is the nearest flight-master NPC by the player.
FM.ARRIVE = 50
FM.NEAR = 120

-- 1.7.27 (user: "get all taxi NPCs from the Zygor addon"): no flight master in
-- sight - walk to the nearest of Zygor's (merchants.nearest_flight, the local
-- import of its ["Flight master"] list: npc id, faction, map position). Within
-- FM.ZY_THERE yd of it the flagged NPC (FM.nearest) takes over; when none is
-- there (moved, dead, wrong phase), that npc id is skipped for the goal and the
-- next nearest one is walked to. The flight map itself is still read only
-- through core.taxi (names every visit, REACHABLE nodes only, close).
FM.ZY_THERE = 15
FM.zy = { key = nil, skip = {} }
function FM.zygor_walk(player, key, why)
    if FM.zy.key ~= key then FM.zy.key, FM.zy.skip = key, {} end
    local ok_m, merchants = pcall(require, "merchants")
    if not ok_m or type(merchants) ~= "table" or type(merchants.nearest_flight) ~= "function" then return false end
    local fm, d = merchants.nearest_flight(player, FM.zy.skip)
    if not fm then return false end
    if d <= FM.ZY_THERE then
        trail("travel", "Zygor flight master %d (%s) not found at its spot - the next one", fm.npc_id, tostring(fm.name))
        FM.zy.skip[fm.npc_id] = true
        return true
    end
    C.walk_to({ x = fm.x, y = fm.y, z = fm.z }, "flight master " .. tostring(fm.name))
    state.set_note("Quest", string.format("Guide: to Zygor's flight master (%.0f yd) for %s", d, tostring(why)))
    return true
end

-- ----------------------------------------------------------------------------
-- 1.34.0 shared pieces: the landing node by position, the take-off, route legs
-- ----------------------------------------------------------------------------
FM.CAT_YD = 80                 -- a catalog flight point this close to the fly waypoint is its node

--- The in-game name of the flight point at world position `pos` (data/taxi_nodes.lua,
--- TaxiNodes.dbc names), preferring one whose name starts like `hint`; nil when none.
function FM.node_name_at(pos, hint)
    local ok, cat = pcall(require, "data/taxi_nodes")
    if not ok or type(cat) ~= "table" or type(cat.nodes) ~= "table" or not pos then return nil end
    local head = type(hint) == "string" and hint:lower():match("^([^,]+)") or nil
    local best, best_d, named, named_d = nil, nil, nil, nil
    for i = 1, #cat.nodes do
        local n = cat.nodes[i]
        local d = FM.flat(pos, n)
        if d <= FM.CAT_YD then
            if not best_d or d < best_d then best, best_d = n, d end
            local nh = n.name:lower():match("^([^,]+)")
            if head and nh and (nh == head or nh:find(head, 1, true) or head:find(nh, 1, true))
                and (not named_d or d < named_d) then
                named, named_d = n, d
            end
        end
    end
    local n = named or best
    return n and n.name or nil
end

--- Take node `idx` of the open map: dismount first (one tick), then the take-off,
--- tracked by TR.in_flight. `travel` = a leg toward the goal (the goal stays open).
function FM.take(player, idx, dest, goal, travel, now)
    if safe(function() return player:is_mounted() end) == true then
        pcall(function() core.input.dismount() end)
        trail("act", "flight to %s: dismounting first", tostring(dest))
        return true
    end
    local node = tostring(safe(function() return core.taxi.node_name(idx) end))
    movement.nav_stop()
    pcall(function() core.taxi.take_node(idx) end)
    g_fly_taken = now
    local here = pos_of(player) or { x = 0, y = 0, z = 0 }
    g_flight = { dest = dest, taken = now, from = here, last = here, last_t = now,
        step = guide.step_num(), goal = goal and goal.index, travel = travel or nil }
    trail("act", "flight to %s: node %d (%s) taken", tostring(dest), idx, node)
    state.set_note(travel and "Travel" or "Quest", "Taking off to " .. tostring(dest))
    return true
end

-- Zygor's route legs (see the header). key = the destination being flown to;
-- block = destination -> time before which the leg is walked instead.
FM.RT = { key = nil, block = {}, tries = 0, misses = 0, BLOCK_S = 300, AT_YD = 8, NEAR = 40, TRIES = 4 }

--- Zygor's arrow title of a flight leg -> npc name (or nil), destination node name;
--- nil for anything else (a walk, a boat, "Arrive at" / "Pass" while in the air).
function FM.route_taxi(title)
    if type(title) ~= "string" or title == "" then return nil end
    local t = clean_text(title):gsub("[\r\n]+", " | ")
    if t:match("^%s*[Aa]rrive") or t:match("^%s*[Pp]ass ") then return nil end
    local dest = t:match("[Ff]ly to%s+(.-)%s*$") or t:match("[Ff]erry to%s+(.-)%s*$")
    if not dest or dest == "" or dest == "?" or dest:find("|", 1, true) then return nil end
    local npc = t:match("[Tt]alk to%s+(.-),?%s*|")
    if npc == "" or npc == "?" then npc = nil end
    return npc, dest
end

--- The flight master at the leg's point: flagged, within RT.NEAR of it, the
--- router's NPC by name first.
function FM.route_npc(player, pos, npc_name)
    if npc_name then
        local list = targeting.visible_objects() or {}
        for i = 1, #list do
            local u = list[i]
            if u and safe(function() return u:is_valid() end) == true and safe(function() return u:is_dead() end) ~= true
                and safe(function() return u:get_name() end) == npc_name then
                local p = safe(function() return u:get_position() end)
                if p and FM.flat(p, pos) <= FM.RT.NEAR then return u end
            end
        end
    end
    return (FM.nearest(player, FM.RT.NEAR, pos))
end

--- 1.34.0: Zygor's arrow is a flight leg - take it (see the header). True while it
--- owns the tick; false = not a flight leg / blocked / given up (the goal is walked).
function TR.route_flight(player, goal, kind, label)
    if kind == "fly" or kind == "fpath" or kind == "hearth" or kind == "confirm" then return false end
    if g_flight then return TR.in_flight(player) end
    if safe(function() return player:is_in_combat() end) == true then return false end
    local RT = FM.RT
    local pos, title = guide.route_leg()
    local npc_name, dest = FM.route_taxi(title)
    local now = izi.now()
    if not pos or not dest or (RT.block[dest] or 0) > now then
        RT.key = nil
        return false
    end
    if RT.key ~= dest then
        RT.key, RT.tries, RT.misses = dest, 0, 0
        g_fly_fails = 0
        trail("travel", "Zygor's route: '%s' - taking the flight (%s)", (clean_text(title):gsub("[\r\n]+", " / ")),
            tostring(label))
    end
    local function give_up(why)
        RT.block[dest], RT.key = now + RT.BLOCK_S, nil
        trail("travel", "Zygor's route flight to %s: %s - walking instead for %d s", dest, why, RT.BLOCK_S)
        pcall(function() core.taxi.close() end)
        return false
    end
    if g_fly_fails >= FLY_FAIL_MAX then
        g_fly_fails = 0
        return give_up("the flight did not take off")
    end
    -- 1. the flight map is open: the router's node
    local idx, n, blocked = taxi_node_for(dest)
    if type(n) == "number" and n > 0 then
        if not idx then
            return give_up((blocked == "NONE" and "not discovered by this character")
                or (blocked == "CURRENT" and "already at that flight point")
                or (blocked == "DISTANT" and "on another continent")
                or ("not on this flight master's map (can fly to: " .. table.concat(FM.reachable_names(n), ", ") .. ")"))
        end
        return FM.take(player, idx, dest, goal, true, now)
    end
    -- 2. a frame open at the flight master: its taxi option
    if safe(function() return core.quests.is_gossip_frame_shown() end) == true then
        if now >= C.act_until() then
            C.set_act_until(now + C.ACT_GAP)
            if not taxi_gossip() then
                RT.misses = RT.misses + 1
                if RT.misses == 1 then FM.log_gossip_options(npc_name or "the flight master") end
                if RT.misses >= FM.GOSSIP_TRIES then
                    pcall(function() core.quests.close_gossip() end)
                    return give_up("the flight master offered no flight")
                end
            end
        end
        state.set_note("Travel", "Talking to the flight master")
        return true
    end
    -- 3. the flight master at the leg's point
    local unit = FM.route_npc(player, pos, npc_name)
    local here = pos_of(player)
    if not unit then
        if here and FM.flat(here, pos) > RT.AT_YD then
            C.walk_to(pos, "Zygor route: flight master for " .. dest)
            state.set_note("Travel", string.format("Zygor route: to the flight master (%.0f yd) - fly to %s",
                FM.flat(here, pos), dest))
            return true
        end
        return give_up("no flight master at Zygor's route point")
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > C.TALK_REACH then
        local p = safe(function() return unit:get_position() end)
        if not p then return give_up("the flight master has no position") end
        C.walk_to(p, "flight master", C.TALK_REACH - 0.5, true)
        state.set_note("Travel", "To the flight master - fly to " .. dest)
        return true
    end
    movement.nav_stop()
    if now >= C.act_until() then
        if RT.tries >= RT.TRIES then return give_up("the flight map never opened") end
        C.set_act_until(now + C.ACT_GAP)
        RT.tries = RT.tries + 1
        FM.close_then_interact(unit)
        trail("travel", "route flight: talking to %s (try %d)", tostring(safe(function() return unit:get_name() end)), RT.tries)
    end
    state.set_note("Travel", "Talking to the flight master - fly to " .. dest)
    return true
end

local function fly_goal(player, goal, wps, label)
    local now = izi.now()
    -- the title is Zygor's English node name, a HINT: matched with ", ..." stripped
    local dest = (wps[1] and wps[1].title) or fly_destination(goal)
    if type(dest) == "string" then dest = (dest:match("^([^,]+)") or dest):gsub("%s+$", "") end
    -- 1.34.0: the in-game node name at the landing waypoint wins over the title
    dest = (wps[1] and wps[1].pos and FM.node_name_at(wps[1].pos, dest)) or dest
    if wps[1] and wps[1].pos and not g_flight then
        local here = pos_of(player)
        if here and FM.flat(here, wps[1].pos) <= FM.ARRIVE then
            trail("act", "at %s - fly goal done", tostring(dest))
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
    end
    -- In the air (or taking off): nothing to do but wait.
    if TR.in_flight(player) or safe(function() return player:is_flying() end) == true then
        state.set_note("Quest", "Flying to " .. tostring(dest))
        return true
    end
    if g_fly_fails >= FLY_FAIL_MAX then
        trail("act", "flight to %s failed %d times - skipping the step", tostring(dest), g_fly_fails)
        g_fly_fails = 0
        pcall(function() core.taxi.close() end)
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    -- 1. The flight map is open: pick the destination by name.
    local idx, n, blocked = taxi_node_for(dest)
    if type(n) == "number" and n > 0 then
        g_fly_noopt = 0
        if idx then
            return FM.take(player, idx, dest, goal, false, now)      -- 1.34.0: dismount, take, track
        end
        -- 2.280.0: why the destination cannot be taken, from its node_type
        if blocked == "CURRENT" then
            trail("act", "flight to %s: already at that flight point - step done", tostring(dest))
        elseif not g_fly_warned then
            g_fly_warned = true
            local why = (blocked == "NONE" and "not discovered by this character")
                or (blocked == "DISTANT" and "on another continent")
                or "not on this flight master's map"
            trail("act", "no flight to '%s' from here: %s (can fly to: %s) - skipping the step",
                tostring(dest), why, table.concat(FM.reachable_names(n), ", "))
        end
        pcall(function() core.taxi.close() end)
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    -- 2. A frame is open at the flight master: take its taxi option, or - a
    --    quest window, a gossip without one - close it and talk again.
    local gossip_open = safe(function() return core.quests.is_gossip_frame_shown() end) == true
    if gossip_open then
        if now >= C.act_until() then
            C.set_act_until(now + C.ACT_GAP)
            if taxi_gossip() then
                trail("act", "flight master: taxi option selected")
            else
                g_fly_noopt = g_fly_noopt + 1
                if g_fly_noopt == 1 then FM.log_gossip_options("the flight master") end
                trail("act", "flight master frame has no taxi option - closing it and talking again (%d/%d)",
                    g_fly_noopt, FLY_NOOPT_MAX)
                pcall(function() core.quests.close_gossip() end)
                pcall(function() core.quests.close_quest() end)
                pcall(npc.close)
                if g_fly_noopt >= FLY_NOOPT_MAX then
                    g_fly_noopt = 0
                    trail("act", "flight master never offered a flight - skipping the step")
                    guide.mark_goal_done(guide.step_num(), goal.index)
                end
            end
        end
        state.set_note("Quest", "Guide: " .. label)
        return true
    end
    -- 3. Walk to the flight master and talk (Zygor: the nearest flight master,
    --    not one at the destination waypoint).
    local unit = FM.nearest(player, FM.NEAR)
    if not unit then
        -- 1.7.27: none in sight - the nearest of Zygor's flight masters (local import)
        if FM.zygor_walk(player, tostring(guide.step_num()) .. "|" .. tostring(goal.index), "the flight to " .. tostring(dest)) then
            return true
        end
        state.set_note("Quest", "Guide: no flight master in sight for the flight to " .. tostring(dest))
        return false
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > C.TALK_REACH then
        local p = safe(function() return unit:get_position() end)
        if p then
            C.walk_to(p, label, C.TALK_REACH - 0.5, true)   -- 2.297.0: inside the 2 yd reach
            return true
        end
        return false
    end
    movement.nav_stop()
    if now >= C.act_until() then
        C.set_act_until(now + C.ACT_GAP)
        -- A quest window left over from this NPC blocks its flight map.
        FM.close_then_interact(unit)        -- audit Q12: close and interact on separate ticks
    end
    state.set_note("Quest", "Guide: talk to the flight master")
    return true
end

-- ============================================================================
-- FLIGHT TRAVEL TO FAR GOALS (2.115.0)
-- ============================================================================
-- A guide goal thousands of yards away (the Dun Morogh turn-in from Elwynn)
-- was walked in a straight line over mountains, fighting everything on the
-- way. Now, when the goal is more than FAR_TRAVEL yards off and a flight
-- would clearly shorten the trip:
--   1. walk to the nearest flight point of the player's faction on this
--      continent (data/taxi_nodes.lua - positions from TaxiNodes.dbc),
--   2. talk to the friendly NPCs standing there, nearest first, until one
--      opens a flight map (directly or through its taxi gossip option),
--   3. of the flight points ON THAT MAP (only the ones this character knows),
--      take the one closest to the goal - if it really is closer,
--   4. fly (tracked by quest.in_flight, which pauses the whole bot), land,
--      and carry on with the same goal from there.
-- Anything that does not work out - no flight master found, no known flight
-- point closer to the goal, three take-offs that never left the ground - is
-- logged, and the goal is walked as before for TRAVEL_BLOCK seconds.
local FAR_TRAVEL = 1000        -- yards to the goal before a flight is considered
local TRAVEL_GAIN = 0.6        -- the flight must leave at most 60% of the trip to walk
local FM_SEARCH = 30           -- yards around the flight point to look for its master
local FM_TRIES = 2             -- interacts per NPC before trying the next one
local TRAVEL_BLOCK = 300       -- seconds a goal is walked after a failed flight plan

local taxi_nodes = nil
-- g_trip ({ key, start, target, tried, fm_guid, fm_tries }) is declared with g_flight.
local g_trip_block = {}        -- goal key -> time before which no flight is planned
local g_map_logged = false

local function catalog()
    if taxi_nodes == nil then
        local ok, m = pcall(require, "data/taxi_nodes")
        taxi_nodes = (ok and type(m) == "table") and m or false
    end
    return taxi_nodes or nil
end

local function faction_key(player)
    local ok, f = pcall(require, "data/factions")
    if ok and type(f) == "table" and type(f.of_player) == "function" then
        local key = f.of_player(player)
        if type(key) == "string" then return key:lower() end
    end
    return nil
end

local function node_usable(n, map, fkey)
    if n.map ~= map then return false end
    -- Not on this game version (WoW Forever: no Outland, no TBC-added
    -- flight points, 2.124.0).
    local cat = catalog()
    if cat and type(cat.in_game) == "function" and not cat.in_game(n) then return false end
    if fkey == "alliance" then return n.alliance == true end
    if fkey == "horde" then return n.horde == true end
    return n.alliance == true or n.horde == true
end

local function d2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function trip_fail(key, why)
    trail("travel", "no flight: %s - walking the goal instead", why)
    g_trip_block[key] = izi.now() + TRAVEL_BLOCK
    g_trip = nil
    pcall(function() core.taxi.close() end)
    return false
end

--- The flight point on the OPEN map that lands closest to the target.
local function best_map_node(map, fkey, target, start)
    local n = safe(function() return core.taxi.num_nodes() end)
    if type(n) ~= "number" or n <= 0 then return nil end
    local cat = catalog()
    local best_i, best_e, best_d = nil, nil, nil
    for i = 1, n do
        local name = safe(function() return core.taxi.node_name(i) end)
        local list = cat and type(name) == "string" and name ~= "" and name ~= "INVALID" and cat.find(name) or nil
        -- 2.239.0: only a node this character can fly to now (not CURRENT,
        -- DISTANT or undiscovered). "" = the client does not say: allowed.
        local ntype = safe(function() return core.taxi.node_type(i) end)
        if type(ntype) == "string" and ntype ~= "" and ntype ~= "REACHABLE" then list = nil end
        if type(list) == "table" then
            for k = 1, #list do
                local e = list[k]
                if node_usable(e, map, fkey) and d2(e, start) > 50 then
                    local d = d2(e, target)
                    if best_d == nil or d < best_d then
                        best_i, best_e, best_d = i, e, d
                    end
                end
            end
        end
    end
    return best_i, best_e, best_d
end

--- True while a flight trip toward a far goal owns the tick.
local function far_travel(player, goal, kind, wps, label)
    if kind == "fly" or #wps == 0 or g_flight then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    local here = pos_of(player)
    if not here then return false end
    -- The goal's nearest waypoint.
    local target, dist = nil, nil
    for i = 1, #wps do
        local p = wps[i].pos
        if p and type(p.x) == "number" then
            local d = d2(here, p)
            if dist == nil or d < dist then target, dist = p, d end
        end
    end
    local key = tostring(guide.step_num()) .. "|" .. tostring(goal.index)
    if not target or dist <= FAR_TRAVEL then
        if g_trip and g_trip.key == key then g_trip = nil end
        return false
    end
    if (g_trip_block[key] or 0) > izi.now() then return false end
    local cat = catalog()
    local fkey = faction_key(player)
    if not cat then return false end
    -- CONTINENT (2.117.0). The catalog uses continent ids (0 Eastern Kingdoms,
    -- 1 Kalimdor, 530 Outland). core.get_map_id() is only documented as "the
    -- current map"; the 02:18 log refused a 3795 yd trip from Lakeshire with
    -- "no flight point shortens it", which is what a non-continent id gives.
    -- Anything else is replaced by the continent of the nearest flight point.
    local map, raw_map = gamever.continent_of(here)
    if type(map) ~= "number" then return false end
    if not g_map_logged then
        g_map_logged = true
        trail("travel", "core.get_map_id() = %s -> continent %s", tostring(raw_map), tostring(map))
    end

    -- Plan once per goal: nearest start point, and is a flight worth it at all?
    if not g_trip or g_trip.key ~= key then
        local start, sd, near_goal = nil, nil, nil
        for i = 1, #cat.nodes do
            local n = cat.nodes[i]
            if node_usable(n, map, fkey) then
                local d = d2(here, n)
                if sd == nil or d < sd then start, sd = n, d end
                local g = d2(n, target)
                if near_goal == nil or g < near_goal then near_goal = g end
            end
        end
        if not start or near_goal == nil or sd + near_goal > dist * TRAVEL_GAIN then
            return trip_fail(key, string.format(
                "no flight point shortens the %.0f yd trip (continent %s, %s, nearest %s %.0f yd, best landing %.0f yd from goal)",
                dist, tostring(map), tostring(fkey), start and start.name or "none", sd or -1, near_goal or -1))
        end
        g_trip = { key = key, start = start, target = { x = target.x, y = target.y, z = target.z },
            tried = {}, fm_guid = nil, fm_tries = 0, fm_name = nil, gossip_misses = 0 }
        g_fly_fails = 0
        trail("travel", "goal %.0f yd away - flying: walk to %s (%.0f yd)", dist, start.name, sd)
    end
    local trip = g_trip
    if g_fly_fails >= FLY_FAIL_MAX then
        g_fly_fails = 0
        return trip_fail(key, "the flight did not take off")
    end
    local now = izi.now()

    -- 3. Flight map open: take the known flight point closest to the goal.
    local n_nodes = safe(function() return core.taxi.num_nodes() end)
    if type(n_nodes) == "number" and n_nodes > 0 then
        local idx, e, gd = best_map_node(map, fkey, trip.target, trip.start)
        if not idx or gd > dist * TRAVEL_GAIN then
            return trip_fail(key, "no known flight point is closer to the goal")
        end
        trail("travel", "flying to %s (lands %.0f yd from the goal, was %.0f)", e.name, gd, dist)
        return FM.take(player, idx, e.name, goal, true, now)          -- 1.34.0
    end

    -- 2b. A gossip window: its taxi option, else this NPC is not the one.
    if safe(function() return core.quests.is_gossip_frame_shown() end) == true then
        if now >= C.act_until() then
            C.set_act_until(now + C.ACT_GAP)
            if taxi_gossip() then
                trip.gossip_misses = 0
            else
                -- 2.239.0: the options can arrive after the frame; give the
                -- window FM_GOSSIP_TRIES looks, and log what it offered.
                trip.gossip_misses = (trip.gossip_misses or 0) + 1
                if trip.gossip_misses == 1 then FM.log_gossip_options(trip.fm_name or "the NPC") end
                if trip.gossip_misses >= FM.GOSSIP_TRIES then
                    if trip.fm_guid then trip.tried[trip.fm_guid] = true end
                    trip.fm_guid, trip.fm_tries, trip.gossip_misses = nil, 0, 0
                    pcall(function() core.quests.close_gossip() end)
                end
            end
        end
        state.set_note("Travel", "Talking to the flight master")
        return true
    end

    -- 1. Walk to the flight point.
    local sp = trip.start
    local to_start = d2(here, sp)
    if to_start > FM_SEARCH * 0.5 and not trip.fm_guid then
        C.walk_to({ x = sp.x, y = sp.y, z = sp.z }, "flight master at " .. sp.name)
        state.set_note("Travel", string.format("To %s flight master  %.0fy", sp.name, to_start))
        return true
    end

    -- 2. Find its flight master: friendly NPCs near the flight point, nearest first.
    local unit = nil
    if trip.fm_guid then
        local list = targeting.visible_objects() or {}
        for i = 1, #list do
            local u = list[i]
            if u and safe(function() return u:is_valid() end) == true
                and FM.guid_text(u) == trip.fm_guid then
                unit = u
                break
            end
        end
        if not unit then trip.fm_guid = nil end
    end
    if not unit then
        -- 2.239.0: the NPC flagged FLIGHTMASTER first (guards and vendors
        -- stand at flight points too), then the nearest friendly NPC.
        local best_d, best_fm = nil, false
        local any_fm = false
        local list = targeting.visible_objects() or {}
        for i = 1, #list do
            local u = list[i]
            if u and safe(function() return u:is_valid() end) == true
                and safe(function() return u:is_player() end) ~= true
                and safe(function() return u:is_dead() end) ~= true
                and safe(function() return player:can_attack(u) end) ~= true then
                local g = FM.guid_text(u)
                local p = safe(function() return u:get_position() end)
                if p and d2(p, sp) <= FM_SEARCH and FM.is_flight_master(u) then any_fm = true end
                if g ~= nil and not trip.tried[g] and p and d2(p, sp) <= FM_SEARCH then
                    local d = d2(here, p)
                    local fm = FM.is_flight_master(u)
                    if best_d == nil or (fm and not best_fm) or (fm == best_fm and d < best_d) then
                        unit, best_d, best_fm = u, d, fm
                    end
                end
            end
        end
        -- 3.0.6: other NPCs are tried only where NO NPC is flagged flight
        -- master - the 10:32 log asked a boar, a guard and five players' pets
        if unit and not best_fm and any_fm then unit = nil end
        if not unit then
            return trip_fail(key, "no flight master found at " .. sp.name)
        end
        trip.fm_guid = FM.guid_text(unit)
        trip.fm_name = safe(function() return unit:get_name() end)
        trip.fm_tries, trip.gossip_misses = 0, 0
        trail("travel", "flight master candidate %s%s", tostring(trip.fm_name),
            best_fm and " (flight master flag)" or "")
    end
    local ud = safe(function() return player:distance_to(unit) end) or 99
    if ud > C.TALK_REACH then
        local p = safe(function() return unit:get_position() end)
        if p then C.walk_to(p, "flight master", C.TALK_REACH - 0.5, true) end
        state.set_note("Travel", "To the flight master")
        return true
    end
    movement.nav_stop()
    if now >= C.act_until() then
        if trip.fm_tries >= FM_TRIES then
            if trip.fm_guid then trip.tried[trip.fm_guid] = true end   -- audit 1.19.0: a nil guid key threw
            trip.fm_guid, trip.fm_tries = nil, 0
            return true
        end
        C.set_act_until(now + C.ACT_GAP)
        trip.fm_tries = trip.fm_tries + 1
        FM.close_then_interact(unit)        -- audit Q12: close and interact on separate ticks
        trail("travel", "talking to %s (try %d)", tostring(safe(function() return unit:get_name() end)), trip.fm_tries)
    end
    state.set_note("Travel", "Talking to the flight master")
    return true
end

-- ZYGOR fpath / ferry (user, 2026-10-17): discover a flight path / ferry -
-- Zygor completes it from its own taxi database once the node is known, so
-- the bot talks to the flight master there (at the goal's waypoint when the
-- line has one, else by the player) and opens its map, then closes it.
FM.DISCOVER_NEAR = 60
FM.disc = { key = nil, opened = nil }
function TR.fpath_goal(player, goal, wps, label)
    local now = izi.now()
    local key = tostring(guide.step_num()) .. "|" .. tostring(goal.index)
    if FM.disc.key ~= key then FM.disc.key, FM.disc.opened, FM.disc.misses = key, nil, 0 end
    local n = safe(function() return core.taxi.num_nodes() end)
    if type(n) == "number" and n > 0 then
        FM.disc.opened = FM.disc.opened or now
        if now - FM.disc.opened >= 1.5 then
            pcall(function() core.taxi.close() end)
            trail("act", "flight path discovered (taxi map opened) - %s", tostring(label))
            guide.mark_goal_done(guide.step_num(), goal.index)
        end
        state.set_note("Quest", "Guide: discovering the flight path")
        return true
    end
    local center = wps[1] and wps[1].pos or nil
    local unit = FM.nearest(player, FM.DISCOVER_NEAR, center)
    if not unit then
        -- 1.7.27: a discover line with no waypoint - the nearest Zygor flight master
        if not center and FM.zygor_walk(player, key, "discovering the flight path") then return true end
        return false                                   -- walk the goal's route first
    end
    local gossip_open = safe(function() return core.quests.is_gossip_frame_shown() end) == true
    if gossip_open then
        if now >= C.act_until() then
            C.set_act_until(now + C.ACT_GAP)
            if not taxi_gossip() then
                FM.log_gossip_options("the flight master")
                -- audit 2026-10-17: no taxi option N times - talking to the flight
                -- master already discovers the path; close and take the next goal
                FM.disc.misses = (FM.disc.misses or 0) + 1
                if FM.disc.misses >= 4 then
                    FM.disc.misses = 0
                    pcall(function() core.quests.close_gossip() end)
                    trail("act", "flight path step: no taxi option after 4 tries - %s marked done", tostring(label))
                    guide.mark_goal_done(guide.step_num(), goal.index)
                end
            end
        end
        state.set_note("Quest", "Guide: " .. tostring(label))
        return true
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > C.TALK_REACH then
        local p = safe(function() return unit:get_position() end)
        if p then C.walk_to(p, label, C.TALK_REACH - 0.5, true) return true end
        return false
    end
    movement.nav_stop()
    if now >= C.act_until() then
        C.set_act_until(now + C.ACT_GAP)
        FM.close_then_interact(unit)        -- audit Q12: close and interact on separate ticks
    end
    state.set_note("Quest", "Guide: talk to the flight master - " .. tostring(label))
    return true
end

--- A new goal: the flight-master bookkeeping of the last one is dropped.
-- 1.2.52 (user 2026-11-19, Zygor's pointer arrow showed the Hearthstone icon): Zygor's
-- travel router (LibRover, data_common.lua "Hearth to {name}") put a Hearthstone leg on its
-- arrow and the bot walked 1270 yd instead. The leg is used: item 6948 out of combat, once
-- the walk stands still. Not carried / on cooldown / the cast did not take = walk (never a
-- wait), and a failed use blocks the leg for HEARTH_BLOCK_S.
local HEARTH_ID, HEARTH_GAP, HEARTH_BLOCK_S = 6948, 15, 600
local g_hearth = { used_t = -1e9, tries = 0, block_until = 0, map = nil }

function TR.hearth_leg_title(title)
    if type(title) ~= "string" then return false end
    local t = clean_text(title):lower()
    if t:find("garrison", 1, true) or t:find("dalaran", 1, true) then return false end
    return t:find("hearth to", 1, true) ~= nil or t:find("hearthstone", 1, true) ~= nil
end

--- True while the Hearthstone use owns the tick; false = not a hearth leg / cannot / given up.
function TR.route_hearth(player, goal, kind, label)
    if kind == "hearth" or kind == "confirm" then return false end
    local title = guide.route_title()
    if not TR.hearth_leg_title(title) then
        g_hearth.tries = 0
        return false
    end
    local now = izi.now()
    if now < g_hearth.block_until then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    if safe(function() return player:is_dead() end) == true then return false end
    if safe(function() return player:is_casting_spell() end) == true then
        state.set_note("Travel", "Casting the Hearthstone (Zygor's route)")
        return true
    end
    local okb, bags = pcall(require, "bags")
    if not okb or type(bags) ~= "table" or bags.count(HEARTH_ID) <= 0 then return false end
    local cd = safe(function() return player:get_item_cooldown(HEARTH_ID) end)
    if type(cd) == "number" and cd > 0 then return false end
    if g_hearth.tries >= 3 then
        g_hearth.tries, g_hearth.block_until = 0, now + HEARTH_BLOCK_S
        trail("travel", "Zygor's route hearth: the Hearthstone did not take 3 times - walking for %d s", HEARTH_BLOCK_S)
        return false
    end
    movement.nav_stop()
    if movement.is_moving() then
        state.set_note("Travel", "Stopping to use the Hearthstone (Zygor's route)")
        return true
    end
    if now - g_hearth.used_t >= HEARTH_GAP then
        g_hearth.used_t = now
        g_hearth.tries = g_hearth.tries + 1
        if bags.use_id(HEARTH_ID) then
            trail("travel", "Zygor's route: '%s' - Hearthstone used (%s)", (clean_text(title):gsub("[\r\n]+", " / ")),
                tostring(label))
        end
    end
    state.set_note("Travel", "Hearthstone - Zygor's route")
    return true
end

function TR.reset_goal()
    g_fly_taken, g_fly_warned, g_fly_noopt = 0, false, 0
end

TR.fly_goal = fly_goal
TR._FM = FM                                   -- the tests
TR.far_travel = far_travel

return TR
