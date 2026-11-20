-- ============================================================================
-- Master Farmer - Zygor Forever
-- esp.lua - the ESP: a 360-degree, 100 yd scan of everything around the player (1.2.73)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.2.73
-- ============================================================================
-- ONE scan, many users. Twice a second (GAP) the shared visible-object list (targeting.visible_objects - no extra native
-- list) is walked ONCE; everything within RADIUS yd of the player on the ground plane, in every direction, is sorted into:
--
--   ENEMIES   living attackable units: level, elite, hostile, in combat, and how many other hostile mobs stand within LINK_YD
--             (the "pack" that comes with a pull), whether an elite or a mob 5+ levels above stands within DANGER_YD.
--   QUEST     what the current Zygor goal wants: a world object whose name matches the goal's targets (guide.object_wanted) and
--             any unit the game marks as a quest unit. REMEMBERED (MEMORY_S s) with its position, so a goal whose waypoint is
--             missing can still be walked to after the object streamed out of view.
--   NODES     herbs and ore (data/esp_nodes.lua, by name), remembered the same way.
--
-- USERS (all read-only data; nothing here moves the player or casts):
--   * quest/guide find_mob: a mob with a pack, an elite or a much higher level next to it is ranked FARTHER (penalty), so the
--     closest SAFE mob of the goal's own is pulled first - never excluded, a lone candidate is still taken.
--   * quest/engine no_waypoint: the remembered position of the goal's object is walked to (Sentinel plans the path).
--   * the fight snapshot and a once-per-30 s "esp" log line: what is around.
--   * the overlay (General tab "ESP Overlay"): drawn in the render callback from the stored data only.
--
-- TASK GATING (1.2.74). The scan is the same, but WHAT it works on follows the task at hand, so the memory stays focused:
--
--   combat   radius 60 yd, every 0.25 s: the enemies and their packs around the fight; no quest / node work.
--   resting  radius 45 yd, every 0.5 s: the hostiles that could walk up while sitting (away_vector picks the way to rest).
--   looting  radius 45 yd, every 0.4 s: what stands near the corpses (corpse_risk decides whether a corpse is worth the walk).
--   pathing  radius 100 yd, every 0.5 s: enemies as HAZARDS for the path (packs of 4+, elites, much higher levels: hazards()),
--            quest targets and nodes ahead.
--   idle     radius 100 yd, every 1.0 s: everything.
--
-- The task is read from the bot's own state (in combat > resting > looting > walking > idle). A higher task takes over at
-- once; a lower one only after HOLD_S s, so a flicker never changes the focus. Quest memory is kept for the CURRENT STEP only
-- (entries of another step are dropped), node memory for MEMORY_S s.
--
-- Handles are never kept between scans (only guid, name, position and numbers): every stored unit would be a native read of
-- freed memory once the game frees it.
-- ============================================================================

local M = {}

M.RADIUS = 100
M.GAP = 0.5
M.LINK_YD = 10
M.DANGER_YD = 12
M.HIGH_LEVELS = 5
M.MEMORY_S = 900
M.MAX_MEM = 200
M.MAX_PAIRS = 120
M.REPORT_S = 30
M.HOLD_S = 1.5
M.HAZARD_MEM = 60            -- remembered hazards (camps, elites, much higher levels)
M.HAZARD_MERGE = 15
M.BYPASS_MARGIN = 8          -- yd beyond a hazard's radius a bypass point is put
M.CORRIDOR_YD = 24           -- a hazard this close to the straight line is "on the way"
M.PACK_HAZARD = 3            -- linked mobs (4 in all) that make a camp a path hazard
-- radius yd, gap s, quest / nodes: whether this task keeps the long memory up to date
M.PROFILES = {
    combat  = { radius = 60,  gap = 0.25, quest = false, nodes = false },
    resting = { radius = 45,  gap = 0.5,  quest = false, nodes = false },
    looting = { radius = 45,  gap = 0.4,  quest = false, nodes = false },
    pathing = { radius = 100, gap = 0.5,  quest = true,  nodes = true },
    idle    = { radius = 100, gap = 1.0,  quest = true,  nodes = true },
}
local PRIO = { idle = 0, pathing = 1, looting = 2, resting = 3, combat = 4 }

local state = { t = -1e9, enemies = {}, by_guid = {}, quest = {}, nodes = {}, counts = { enemies = 0, elite = 0, high = 0, quest = 0, nodes = 0 },
    hmem = {},
    task = "idle", task_cand = nil, task_since = 0, radius = 100, step = nil,
    px = nil, py = nil, pz = nil, level = 1, report_t = -1e9, sig = nil, node_said = {}, said_n = 0, said_t = 0, scans = 0 }
M._state = state

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function call(fn, a, b)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, a, b)
    if ok then return v end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local okn, v = pcall(izi.now)
        if okn and type(v) == "number" then return v end
    end
    return 0
end

-- 1.2.82: unit classification ids from enums.classification (UNKNOWN -1, NORMAL 0, ELITE 1, RARE_ELITE 2, WORLD_BOSS 3, RARE 4,
-- TRIVIAL 5, MINUS 6 - the game_object doc), the numbers only as the fallback when the enum cannot be read
local CLASSES = nil
local function classes()
    if CLASSES then return CLASSES end
    local ok, enums = pcall(require, "common/enums")
    local e = ok and type(enums) == "table" and enums.classification or nil
    local function pick(name, n) return (type(e) == "table" and type(e[name]) == "number") and e[name] or n end
    CLASSES = { ELITE = pick("ELITE", 1), RARE_ELITE = pick("RARE_ELITE", 2), WORLD_BOSS = pick("WORLD_BOSS", 3),
        RARE = pick("RARE", 4), TRIVIAL = pick("TRIVIAL", 5), MINUS = pick("MINUS", 6) }
    return CLASSES
end
M._classes = classes

local function mod(name)
    local m = package.loaded[name]
    if type(m) == "table" then return m end
    local ok, v = pcall(require, name)
    if ok and type(v) == "table" then return v end
    return nil
end

local function flat(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function gui_on(id, default)
    local g = package.loaded["gui"]
    if type(g) == "table" and type(g.is_on) == "function" then
        local ok, v = pcall(g.is_on, id)
        if ok and v ~= nil then return v == true end
    end
    return default
end

--- 1.2.76 (user): the ESP data is gathered ALWAYS; the one General tab box, "ESP Test" (mfz_esp), only shows the drawing.
function M.enabled() return true end

-- ----------------------------------------------------------------------------
-- the task at hand
-- ----------------------------------------------------------------------------
local function read_task(player)
    if safe(player.is_in_combat, player) == true then return "combat" end
    local mv = package.loaded["movement"]
    if type(mv) == "table" and type(mv.in_combat_movement) == "function" and safe(mv.in_combat_movement) == true then return "combat" end
    local hl = package.loaded["healing"]
    if type(hl) == "table" and type(hl.is_resting) == "function" and safe(hl.is_resting) == true then return "resting" end
    local lt = package.loaded["loot"]
    if type(lt) == "table" and type(lt.working) == "function" and safe(lt.working) == true then return "looting" end
    if type(mv) == "table" and type(mv.is_moving) == "function" and safe(mv.is_moving) == true then return "pathing" end
    return "idle"
end

--- The current task: combat > resting > looting > pathing > idle. A higher one at once, a lower one after HOLD_S s.
function M.task(player, t)
    t = t or now()
    local want = player and read_task(player) or state.task
    if want == state.task then
        state.task_cand = nil
    elseif PRIO[want] > PRIO[state.task] then
        state.task, state.task_cand = want, nil
    else
        if state.task_cand ~= want then state.task_cand, state.task_since = want, t end
        if t - state.task_since >= M.HOLD_S then state.task, state.task_cand = want, nil end
    end
    return state.task
end

function M.current_task() return state.task end

-- ----------------------------------------------------------------------------
-- the scan
-- ----------------------------------------------------------------------------
local function prune(t)
    for _, store in ipairs({ state.quest, state.nodes }) do
        local n = 0
        for guid, e in pairs(store) do
            n = n + 1
            if t - e.t > M.MEMORY_S then store[guid] = nil n = n - 1 end
        end
        if n > M.MAX_MEM then
            local oldest, og = nil, nil
            for guid, e in pairs(store) do
                if not oldest or e.t < oldest then oldest, og = e.t, guid end
            end
            if og then store[og] = nil end
        end
    end
end

local function goal_names()
    local guide = mod("quest/guide")
    if not guide or type(guide.goal) ~= "function" or type(guide.targets) ~= "function" then return nil, nil, nil end
    local goal = safe(guide.goal)
    if type(goal) ~= "table" then return nil, nil, nil end
    local ok, ids, names = pcall(guide.targets, goal)
    if not ok or type(names) ~= "table" then return goal, nil, nil end
    return goal, ids, names
end

local function name_in_goal(name, names)
    if not names or type(name) ~= "string" or name == "" then return false end
    local guide = mod("quest/guide")
    if guide and type(guide.object_wanted) == "function" then
        local ok, v = pcall(guide.object_wanted, name, names)
        return ok and v == true
    end
    return names[name] == true
end

local function say_node(e, d)
    local t = now()
    if t - state.said_t > 60 then state.said_t, state.said_n = t, 0 end
    if state.node_said[e.guid] or state.said_n >= 6 then return end
    state.node_said[e.guid] = true
    state.said_n = state.said_n + 1
    local ok, actlog = pcall(require, "actlog")
    if ok and type(actlog) == "table" and type(actlog.event) == "function" then
        pcall(actlog.event, "esp", "node", string.format("%s (%s) %.0f yd", e.name, e.kind, d),
            { x = e.x, y = e.y, z = e.z, kind = e.kind })
    end
end

--- Walk the visible objects once. `player` is the local player. Returns true when a scan ran.
function M.tick(player)
    if not player or not M.enabled() then return false end
    local t = now()
    local task = M.task(player, t)
    local prof = M.PROFILES[task] or M.PROFILES.idle
    if t - state.t < prof.gap then return false end
    state.t = t
    local RADIUS = prof.radius
    state.radius = RADIUS
    local tg = mod("targeting")
    local list = tg and type(tg.visible_objects) == "function" and safe(tg.visible_objects) or nil
    local pos = safe(player.get_position, player)
    if type(list) ~= "table" or type(pos) ~= "table" then return false end
    state.px, state.py, state.pz = pos.x, pos.y, pos.z
    state.level = tonumber(safe(player.get_level, player)) or 1
    state.scans = state.scans + 1
    local goal, _, names = goal_names()
    local goal_key = goal and tostring(goal.index) or nil
    if not prof.quest then names = nil end
    -- quest memory belongs to the CURRENT STEP: another step's entries are dropped
    local gd = mod("quest/guide")
    local step = gd and type(gd.step_num) == "function" and safe(gd.step_num) or nil
    if step ~= state.step then
        if state.step ~= nil then state.quest = {} end
        state.step = step
    end
    local enemies, by_guid = {}, {}
    local q_n, node_n = 0, 0
    local my_guid = safe(player.get_guid, player)
    for i = 1, #list do
        local o = list[i]
        if type(o) == "table" or type(o) == "userdata" then
            if call(o.is_valid, o) == true then
                local p = call(o.get_position, o)
                if type(p) == "table" then
                    local d = flat(p.x, p.y, pos.x, pos.y)
                    if d <= RADIUS then
                        if call(o.is_unit, o) == true then
                            if call(o.is_player, o) ~= true and call(o.is_dead_or_ghost, o) ~= true then
                                local guid = call(o.get_guid, o)
                                local attack = safe(player.can_attack, player, o)
                                if attack == true and guid ~= nil and guid ~= my_guid then
                                    local cls = tonumber(call(o.get_classification, o)) or 0
                                    local K = classes()
                                    local e = { guid = guid, name = call(o.get_name, o), level = tonumber(call(o.get_level, o)) or 1,
                                        elite = (cls == K.ELITE or cls == K.RARE_ELITE or cls == K.WORLD_BOSS), x = p.x, y = p.y, z = p.z, d = d,
                                        hostile = safe(o.is_enemy_with, o, player) == true, combat = call(o.is_in_combat, o) == true,
                                        trivial = (cls == K.TRIVIAL or cls == K.MINUS) }
                                    enemies[#enemies + 1] = e
                                    by_guid[guid] = e
                                end
                                if prof.quest and call(o.is_quest_unit, o) == true and guid ~= nil then
                                    state.quest[guid] = { guid = guid, name = call(o.get_name, o), kind = "unit", x = p.x, y = p.y, z = p.z,
                                        t = t, goal = goal_key }
                                    q_n = q_n + 1
                                end
                            end
                        elseif call(o.is_basic_object, o) == true and call(o.is_item, o) ~= true then
                            local name = call(o.get_name, o)
                            local guid = call(o.get_guid, o)
                            if guid ~= nil and type(name) == "string" then
                                local kind = nil
                                local nodes = prof.nodes and mod("data/esp_nodes") or nil
                                if nodes and type(nodes.kind) == "function" then kind = nodes.kind(name) end
                                if kind then
                                    local e = { guid = guid, name = name, kind = kind, x = p.x, y = p.y, z = p.z, t = t }
                                    state.nodes[guid] = e
                                    node_n = node_n + 1
                                    say_node(e, d)
                                elseif name_in_goal(name, names) then
                                    state.quest[guid] = { guid = guid, name = name, kind = "object", x = p.x, y = p.y, z = p.z, t = t,
                                        goal = goal_key, usable = call(o.can_be_used, o) == true }
                                    q_n = q_n + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- packs: hostile mobs standing together (a pull brings them all), an elite or a much higher level beside one
    table.sort(enemies, function(a, b) return a.d < b.d end)
    local n = math.min(#enemies, M.MAX_PAIRS)
    local elite, high = 0, 0
    for i = 1, #enemies do
        local e = enemies[i]
        e.link, e.elite_near, e.high_near = 0, false, false
        if e.elite then elite = elite + 1 end
        if e.level >= state.level + M.HIGH_LEVELS then high = high + 1 end
    end
    for i = 1, n do
        local a = enemies[i]
        for j = i + 1, n do
            local b = enemies[j]
            local d = flat(a.x, a.y, b.x, b.y)
            if d <= M.DANGER_YD then
                if b.hostile and not b.trivial and d <= M.LINK_YD then a.link = a.link + 1 end
                if a.hostile and not a.trivial and d <= M.LINK_YD then b.link = b.link + 1 end
                if b.elite then a.elite_near = true end
                if a.elite then b.elite_near = true end
                if b.level >= state.level + M.HIGH_LEVELS then a.high_near = true end
                if a.level >= state.level + M.HIGH_LEVELS then b.high_near = true end
            end
        end
    end
    state.enemies, state.by_guid = enemies, by_guid
    -- HAZARD MEMORY (1.2.78): camps, elites and much higher levels are remembered where they were seen, so a route planned
    -- 300 yd ahead still knows about them (the live scan only reaches RADIUS); an entry inside the area scanned that was
    -- not seen again is dropped (the mob died or walked off).
    do
        local mem = state.hmem
        for i = 1, #enemies do
            local e = enemies[i]
            if e.hostile and not e.trivial then
                local high = e.level >= state.level + M.HIGH_LEVELS
                local camp = e.link >= M.PACK_HAZARD
                if e.elite or high or camp then
                    local hit
                    for j = 1, #mem do
                        if flat(mem[j].x, mem[j].y, e.x, e.y) <= M.HAZARD_MERGE then hit = mem[j] break end
                    end
                    if not hit then
                        if #mem >= M.HAZARD_MEM then table.remove(mem, 1) end
                        hit = {}
                        mem[#mem + 1] = hit
                    end
                    hit.x, hit.y, hit.z, hit.t, hit.level, hit.name = e.x, e.y, e.z, t, e.level, e.name
                    hit.elite = e.elite
                    hit.pack = camp
                    hit.r = (e.elite or high) and 20 or 14
                end
            end
        end
        local keep = {}
        for j = 1, #mem do
            local h = mem[j]
            local inside = flat(h.x, h.y, pos.x, pos.y) <= RADIUS * 0.8
            if (t - h.t) <= M.MEMORY_S and not (inside and h.t < t - 0.01 and (t - h.t) > 3) then keep[#keep + 1] = h end
        end
        state.hmem = keep
    end
    local nq, nn = 0, 0
    for _ in pairs(state.quest) do nq = nq + 1 end
    for _ in pairs(state.nodes) do nn = nn + 1 end
    state.counts = { enemies = #enemies, elite = elite, high = high, quest = nq, nodes = nn, seen_quest = q_n, seen_nodes = node_n }
    prune(t)
    M.report(t)
    return true
end

--- One log line when the picture changed (at most every REPORT_S s).
function M.report(t)
    if t - state.report_t < M.REPORT_S then return end
    local c = state.counts
    local sig = string.format("%d|%d|%d|%d|%d", c.enemies, c.elite, c.high, c.quest, c.nodes)
    if sig == state.sig then return end
    state.report_t, state.sig = t, sig
    local ok, actlog = pcall(require, "actlog")
    if ok and type(actlog) == "table" and type(actlog.event) == "function" then
        pcall(actlog.event, "esp", "scan", string.format("%s, %d yd: %d enemies (%d elite, %d higher level), %d quest, %d nodes",
            state.task, state.radius, c.enemies, c.elite, c.high, c.quest, c.nodes), { task = state.task, radius = state.radius,
            enemies = c.enemies, elite = c.elite, high = c.high, quest = c.quest, nodes = c.nodes })
    end
end

-- ----------------------------------------------------------------------------
-- reading it
-- ----------------------------------------------------------------------------
--- Enemies within `yards` (default RADIUS), nearest first (data tables; do not keep them).
function M.enemies(yards)
    yards = tonumber(yards) or M.RADIUS
    local out = {}
    for i = 1, #state.enemies do
        if state.enemies[i].d <= yards then out[#out + 1] = state.enemies[i] end
    end
    return out
end

--- Hostile mobs standing within `r` yd of (x, y): count, plus whether an elite / a much higher level is among them.
function M.pack_at(x, y, r)
    r = tonumber(r) or M.LINK_YD
    local n, elite, high = 0, false, false
    for i = 1, #state.enemies do
        local e = state.enemies[i]
        if e.hostile and not e.trivial and flat(e.x, e.y, x, y) <= r then
            n = n + 1
            if e.elite then elite = true end
            if e.level >= state.level + M.HIGH_LEVELS then high = true end
        end
    end
    return n, elite, high
end

--- A ranking penalty in yards for pulling `unit`: each other hostile mob linked to it, an elite / a much higher level beside it.
--- 0 for a lone mob or one the scan has not seen. Returns penalty, reason.
function M.penalty(unit)
    if not unit then return 0, nil end
    local guid = call(unit.get_guid, unit)
    local e = guid ~= nil and state.by_guid[guid] or nil
    if not e then return 0, nil end
    local pen, why = 0, {}
    if e.elite then pen = pen + 40 why[#why + 1] = "elite" end
    if e.link > 0 then pen = pen + math.min(24, 6 * e.link) why[#why + 1] = e.link .. " linked" end
    if e.elite_near then pen = pen + 40 why[#why + 1] = "elite near" end
    if e.high_near then pen = pen + 30 why[#why + 1] = "much higher level near" end
    return pen, table.concat(why, ", ")
end

--- The remembered quest object / unit of the CURRENT goal nearest the player, or nil:
--- { x, y, z, name, kind, seen_ago, visible, guid, d }. `skip` is an optional guid set.
function M.goal_target(goal, skip)
    local _, _, names = goal_names()
    if not names then return nil end
    local best, best_d
    for guid, e in pairs(state.quest) do
        if not (skip and skip[guid]) and name_in_goal(e.name, names) then
            local d = state.px and flat(e.x, e.y, state.px, state.py) or 0
            if not best_d or d < best_d then best, best_d = e, d end
        end
    end
    if not best then return nil end
    return { x = best.x, y = best.y, z = best.z, name = best.name, kind = best.kind, guid = best.guid, d = best_d,
        seen_ago = now() - best.t, visible = best.t >= state.t - 0.01 }
end

--- Remembered gathering nodes: kind "herb" / "ore" / nil (both), within `yards` of the player, nearest first.
function M.nodes(kind, yards)
    yards = tonumber(yards) or M.RADIUS
    local out = {}
    for _, e in pairs(state.nodes) do
        if not kind or e.kind == kind then
            local d = state.px and flat(e.x, e.y, state.px, state.py) or 0
            if d <= yards then out[#out + 1] = { x = e.x, y = e.y, z = e.z, name = e.name, kind = e.kind, guid = e.guid, d = d } end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

--- PATHING: enemies that make the ground a hazard - an elite, a mob 5+ levels above, or a camp (PACK_HAZARD+ linked mobs).
--- { x, y, r, level, elite, pack, name } - data for the path audit (nav N.danger_at); nothing is excluded here.
function M.hazards()
    local out = {}
    local t = now()
    for _, h in ipairs(state.hmem) do
        out[#out + 1] = { x = h.x, y = h.y, z = h.z, r = h.r, level = h.level, elite = h.elite, pack = h.pack, name = h.name,
            seen_ago = t - h.t }
    end
    return out
end

-- ----------------------------------------------------------------------------
-- NAVIGATION DATA (1.2.78): what the path generation (movement/nav + Sentinel plan_route) asks the ESP
-- ----------------------------------------------------------------------------
--- Hazards within `width` yd of the straight line (sx, sy) -> (gx, gy), nearest the start first:
--- { x, y, r, name, elite, pack, level, along (yd from the start), off (yd to the LEFT of the line, negative = right) }.
function M.corridor(sx, sy, gx, gy, width)
    width = tonumber(width) or M.CORRIDOR_YD
    local dx, dy = gx - sx, gy - sy
    local len = math.sqrt(dx * dx + dy * dy)
    local out = {}
    if len < 1 then return out, len end
    local ux, uy = dx / len, dy / len
    for _, h in ipairs(state.hmem) do
        local hx, hy = h.x - sx, h.y - sy
        local along = hx * ux + hy * uy
        local off = -hx * uy + hy * ux
        if along > -h.r and along < len + h.r and math.abs(off) <= width + h.r then
            out[#out + 1] = { x = h.x, y = h.y, z = h.z, r = h.r, name = h.name, elite = h.elite, pack = h.pack, level = h.level,
                along = along, off = off }
        end
    end
    table.sort(out, function(a, b) return a.along < b.along end)
    return out, len
end

--- Is (x, y) inside a hazard's circle (+ margin)? Returns the hazard or nil.
function M.inside(x, y, margin)
    margin = tonumber(margin) or 0
    for _, h in ipairs(state.hmem) do
        if flat(h.x, h.y, x, y) <= h.r + margin then return h end
    end
    return nil
end

--- (x, y) moved out of any hazard circle (+ BYPASS_MARGIN) along the line from the hazard's centre; the point itself when clear.
function M.push_out(x, y)
    local h = M.inside(x, y, M.BYPASS_MARGIN)
    if not h then return x, y, false end
    local dx, dy = x - h.x, y - h.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.5 then dx, dy, d = 1, 0, 1 end
    local need = h.r + M.BYPASS_MARGIN
    return h.x + dx / d * need, h.y + dy / d * need, true
end

--- Bypass points for the hazards ON THE WAY (corridor): one point per hazard, BYPASS_MARGIN yd beyond its radius on the side
--- AWAY from the hazard's own side of the line (the line passes left of it -> the point goes right), hazards closer than 25 yd
--- to each other share one. { x, y, along, why }, nearest the start first, at most `max` (default 3).
function M.bypass(sx, sy, gx, gy, max)
    max = tonumber(max) or 3
    local list, len = M.corridor(sx, sy, gx, gy)
    local out = {}
    if #list == 0 then return out end
    local ux, uy = (gx - sx) / len, (gy - sy) / len
    local nx, ny = -uy, ux                          -- the line's left normal
    for _, h in ipairs(list) do
        if #out >= max then break end
        local need = h.r + M.BYPASS_MARGIN
        if math.abs(h.off) < need then
            local side = (h.off >= 0) and -1 or 1       -- hazard on the left -> pass on the right
            local px = sx + ux * h.along + nx * (h.off + side * need)
            local py = sy + uy * h.along + ny * (h.off + side * need)
            local dup = false
            for _, o in ipairs(out) do if flat(o.x, o.y, px, py) < 25 then dup = true break end end
            if not dup then
                out[#out + 1] = { x = px, y = py, along = h.along, why = string.format("%s%s (level %s)", tostring(h.name or "?"),
                    h.pack and ", a camp" or "", tostring(h.level)) }
            end
        end
    end
    return out
end

--- One table for the path generation: the hazards on the way, the bypass points, whether the way is clear.
function M.nav_data(sx, sy, gx, gy)
    local hz, len = M.corridor(sx, sy, gx, gy)
    local via = M.bypass(sx, sy, gx, gy)
    return { hazards = hz, via = via, clear = (#via == 0), length = len, remembered = #state.hmem }
end

--- RESTING: the unit vector (dx, dy) pointing away from the hostile mobs within `yards` of (x, y), nearer ones weighing more
--- (1 / d). nil when none stands there. The way to walk before sitting down.
function M.away_vector(x, y, yards)
    yards = tonumber(yards) or 40
    local sx, sy, n = 0, 0, 0
    for i = 1, #state.enemies do
        local e = state.enemies[i]
        if (e.hostile or e.combat) and not e.trivial then
            local d = flat(e.x, e.y, x, y)
            if d <= yards and d > 0.1 then
                local w = 1 / d
                sx, sy, n = sx + (x - e.x) / d * w, sy + (y - e.y) / d * w, n + 1
            end
        end
    end
    if n == 0 then return nil end
    local len = math.sqrt(sx * sx + sy * sy)
    if len < 1e-6 then return nil end
    return sx / len, sy / len, n
end

--- LOOTING: is a corpse at (x, y) worth the walk? Hostile mobs near it (not trivial, not the corpse itself): count, elite,
--- much higher level. risky = 2+ of them, an elite or a much higher level.
function M.corpse_risk(x, y, r)
    r = tonumber(r) or 12
    local n, elite, high = 0, false, false
    for i = 1, #state.enemies do
        local e = state.enemies[i]
        if e.hostile and not e.trivial and flat(e.x, e.y, x, y) <= r then
            n = n + 1
            if e.elite then elite = true end
            if e.level >= state.level + M.HIGH_LEVELS then high = true end
        end
    end
    return { n = n, elite = elite, high = high, risky = (n >= 2 or elite or high) }
end

--- COMBAT: what stands with the target - hostile mobs within LINK_YD of it (not counting it): n, elite, high.
function M.fight_summary(unit)
    if not unit then return nil end
    local guid = call(unit.get_guid, unit)
    local e = guid ~= nil and state.by_guid[guid] or nil
    if not e then return nil end
    return { adds = e.link, elite_near = e.elite_near, high_near = e.high_near }
end

--- One short string for the fight snapshot.
function M.brief()
    local c = state.counts
    return string.format("esp %s %d en (%d elite, %d high), %d quest, %d nodes", state.task, c.enemies, c.elite, c.high, c.quest, c.nodes)
end

function M.counts() return state.counts end

function M.reset()
    state.enemies, state.by_guid, state.quest, state.nodes, state.hmem = {}, {}, {}, {}, {}
    state.counts = { enemies = 0, elite = 0, high = 0, quest = 0, nodes = 0 }
    state.t, state.sig, state.node_said = -1e9, nil, {}
end

-- ----------------------------------------------------------------------------
-- the overlay (render callback: drawing only, from the stored data)
-- ----------------------------------------------------------------------------
local vec3_mod
local function v3(x, y, z)
    if vec3_mod == nil then
        local ok, m = pcall(require, "common/geometry/vector_3")
        vec3_mod = (ok and type(m) == "table") and m or false
    end
    if vec3_mod then return vec3_mod.new(x, y, z) end
    return { x = x, y = y, z = z }
end

local colors
local function col(name)
    if not colors then
        local ok, c = pcall(require, "common/color")
        colors = {}
        if ok and type(c) == "table" and type(c.new) == "function" then
            colors.ring = c.new(90, 160, 255, 70)
            colors.ok = c.new(80, 220, 120, 230)
            colors.warn = c.new(255, 210, 60, 230)
            colors.bad = c.new(255, 70, 70, 240)
            colors.quest = c.new(70, 230, 255, 255)
            colors.herb = c.new(120, 255, 90, 255)
            colors.ore = c.new(255, 150, 50, 255)
        end
    end
    return colors[name]
end

local MAX_DRAW = 40

--- Draw the ring, the enemies (green = ordinary, yellow = a pack or a higher level, red = an elite / much higher level near),
--- the quest targets and the nodes. Graphics calls only; nothing is scanned here.
function M.draw()
    if not gui_on("mfz_esp", false) or not state.px then return end
    local g = core and core.graphics
    if type(g) ~= "table" then return end
    local c_ring = col("ring")
    if not c_ring then return end
    if type(g.circle_3d) == "function" then
        pcall(g.circle_3d, v3(state.px, state.py, state.pz), state.radius or M.RADIUS, c_ring, 1.0, 1.0)
    end
    local drawn = 0
    for i = 1, #state.enemies do
        if drawn >= MAX_DRAW then break end
        local e = state.enemies[i]
        if e.hostile or e.combat then
            local c = col("ok")
            if e.elite_near or e.elite or e.level >= state.level + M.HIGH_LEVELS then c = col("bad")
            elseif e.link > 0 or e.level > state.level + 2 then c = col("warn") end
            local label = string.format("%s %d%s %.0f", tostring(e.name or "?"), e.level, e.elite and "+" or "", e.d)
            if type(g.circle_3d) == "function" then pcall(g.circle_3d, v3(e.x, e.y, e.z), 0.8, c, 1.5, 1.0) end
            if type(g.text_3d) == "function" and e.d <= 60 then pcall(g.text_3d, label, v3(e.x, e.y, e.z + 2.2), 12, c, true) end
            drawn = drawn + 1
        end
    end
    for _, e in pairs(state.quest) do
        local c = col("quest")
        if type(g.circle_3d) == "function" then pcall(g.circle_3d, v3(e.x, e.y, e.z), 1.2, c, 2.0, 1.0) end
        if type(g.text_3d) == "function" then pcall(g.text_3d, "Quest: " .. tostring(e.name or "?"), v3(e.x, e.y, e.z + 2.0), 13, c, true) end
    end
    local shown = 0
    for _, e in pairs(state.nodes) do
        if shown >= 20 then break end
        local c = col(e.kind == "ore" and "ore" or "herb")
        if type(g.circle_3d) == "function" then pcall(g.circle_3d, v3(e.x, e.y, e.z), 1.0, c, 2.0, 1.0) end
        if type(g.text_3d) == "function" then pcall(g.text_3d, tostring(e.name), v3(e.x, e.y, e.z + 1.6), 12, c, true) end
        shown = shown + 1
    end
end

return M
