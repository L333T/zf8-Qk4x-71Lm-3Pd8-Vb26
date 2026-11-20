-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/sentinel.lua - the Sentinel Navigation adapter (1.10.0)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- The ONE module that talks to Sentinel Navigation (_G.SentinelNavClient, a
-- Sylvanas library; the player installs and enables it, the Master Farmer
-- launcher points its shared client at the Master Farmer SentinelNavServer and
-- this client's map set). A library update is fixed here and nowhere else.
-- Ported from restedXP_questing 4.7.0 movement/sentinel.lua (the reference
-- port, docs/SENTINEL_PORT_GUIDE.md); its Settings-tab self-test is not
-- carried over.
--
--   * the client is looked up lazily at run time, never in header.lua:
--     rawget(_G, "SentinelNavClient"), then its `client` (a live getter, may
--     be nil);
--   * the game / server come from the launcher (MASTER_FARMER.nav: kind
--     "sentinel", game "tbc" | "forever" | nil, base_url, supported) - this
--     product never writes the server address, never calls update_config /
--     update();
--   * on a client without maps there navigation is unavailable:
--     S.unavailable() says why, and nothing moves.
--
-- Calls and answers: restedXP_questing_sentinel/docs/SENTINEL_API.md (the
-- official v0.0.8 page) and docs/SENTINEL_V024.md (recorded in game on v0.24).
-- Every call is pcall-guarded; callbacks are wrapped so the bot sees one
-- fixed shape.
-- ============================================================================

local S = {}

-- ----------------------------------------------------------------------------
-- the library and the launcher's word on it
-- ----------------------------------------------------------------------------
---_G.SentinelNavClient (or nil).
function S.library()
    local g = rawget(_G, "SentinelNavClient")
    return type(g) == "table" and g or nil
end

---The shared client (or nil): looked up every time - the library may reload.
function S.client()
    local g = S.library()
    if not g then return nil end
    local ok, c = pcall(function() return g.client end)
    if ok and type(c) == "table" then return c end
    return nil
end

---The library's VERSION string ("" when unknown).
function S.version()
    local g = S.library()
    local ok, v = pcall(function() return g and g.VERSION end)
    return (ok and v ~= nil) and tostring(v) or ""
end

---The launcher's MASTER_FARMER table, or nil. It lives in this product's
---environment (the launcher's loader env.MASTER_FARMER), NOT in the real _G:
---read as a plain global, never rawget(_G, ...).
function S.master_farmer()
    local mf = MASTER_FARMER
    return type(mf) == "table" and mf or nil
end

---MASTER_FARMER.nav from the launcher, or a table saying it is missing.
function S.info()
    local mf = S.master_farmer()
    local n = type(mf) == "table" and mf.nav or nil
    if type(n) == "table" and n.kind == "sentinel" then return n end
    return { kind = "none", game = nil, supported = false }
end

---Why Sentinel navigation cannot be used now, or nil when it can.
function S.unavailable()
    local n = S.info()
    if n.kind ~= "sentinel" then return "not loaded through Master Farmer's Sentinel entry" end
    if not n.supported then return "Sentinel navigation has no maps for this game version" end
    local c = S.client()
    if not c then return "the Sentinel Navigation library is not loaded" end
    local ok, up = pcall(function() return c:is_server_available() end)
    if not ok or up ~= true then return "the navigation server is not answering" end
    return nil
end

-- ----------------------------------------------------------------------------
-- runtime calls - the only Sentinel calls the bot makes
-- ----------------------------------------------------------------------------
-- Replies from a replaced library or another world cannot affect this walk.
local reply_generation = 0
-- 1.2.89: replies the guard dropped (a reply that never reaches the bot looks like "no reply"), and when the last plan reply came.
S.drops = { generation = 0, client = 0, world = 0 }
S.last_reply_t = nil
S.plan_sent = 0
S.plan_replied = 0
function S.invalidate() reply_generation = reply_generation + 1 end
local function reply_guard(c)
    local issued_generation = reply_generation
    local map_ok, map = pcall(core.get_map_id)
    local instance_ok, instance = pcall(core.get_instance_id)
    local answered = false
    return function()
        if answered then return false end
        if issued_generation ~= reply_generation then S.drops.generation = S.drops.generation + 1 return false end
        if S.client() ~= c then S.drops.client = S.drops.client + 1 return false end
        local km, current_map = pcall(core.get_map_id)
        local ki, current_instance = pcall(core.get_instance_id)
        if (map_ok and (not km or current_map ~= map))
            or (instance_ok and (not ki or current_instance ~= instance)) then
            S.drops.world = S.drops.world + 1
            return false
        end
        answered = true
        return true
    end
end

local function m(c, name, ...)
    local got, f = pcall(function() return c and c[name] end)
    if not got or type(f) ~= "function" then return false end
    return pcall(f, c, ...)
end

local function pt(p)
    return { x = p.x, y = p.y, z = p.z }
end

-- Request budget. The 414 signal came from a bus event ("nav.server_error") that the live stub does not
-- declare, so nothing subscribes to it: request_blocked answers nil and a refused walk is handled by its own
-- callback reason. The state table stays for the zone bookkeeping below.
S.ZONE_LIMIT = 8
-- Avoidance zones need obstacle:add_zone, which the live stub (.api/third_party/sentinel_nav.lua) does NOT
-- declare. They are OFF. Setting S.UNDECLARED_ZONES = true (a deliberate choice, tests do it) re-enables the
-- guarded calls below; nothing in the product sets it.
S.UNDECLARED_ZONES = false
local requests = setmetatable({}, { __mode = "k" })
function S.request_blocked(c)
    local s = requests[c]
    if not s then s = { until_t = 0, delay = 2, added = {}, zones = {} } requests[c] = s end
    if s.rebuild then return "Sentinel request rebuild pending" end
    if core.time() < s.until_t then return "Sentinel request retry backoff" end
    return nil
end

-- A 414 response means this request has finished, even if Sentinel still
-- reports awaiting_path while scheduling another retry.
function S.take_rejection(c)
    local s = requests[c]
    if not s or not s.rejected then return false end
    s.rejected = false
    return true
end

-- Called only from the navigation update after retiring the failed walk.
-- Clear the oversized transient cache and restore every unexpired zone this
-- product admitted. Persistent stuck memory and threat detection remain active.
-- Zygor Forever 1.0.0: the obstacle list (c.obstacle) is a library internal that the live stub does
-- not declare, so there is nothing to clear or restore. After the 414 back-off the walk is simply
-- asked again; no avoidance zone is ever added (S.add_zone is a no-op).
-- Gated by S.UNDECLARED_ZONES (default false): obstacle:* is not declared on the live stub.
function S.recover_request(c)
    local s = requests[c]
    if not s or not s.rebuild or core.time() < s.until_t then return false end
    if not S.UNDECLARED_ZONES then s.zones, s.rebuild, s.rejected = {}, false, false return true end
    local ok, ob = pcall(function() return c.obstacle end)
    if not ok or type(ob) ~= "table" or type(ob.clear) ~= "function"
        or type(ob.add_zone) ~= "function" then
        s.until_t = core.time() + 15
        return false
    end
    local cleared, result = pcall(ob.clear, ob)
    if not cleared or result == false then s.until_t = core.time() + 15 return false end
    local kept, t = {}, core.time()
    for _, zone in ipairs(s.zones) do
        if t >= zone.t and t - zone.t < 110 then
            local restored, res = pcall(ob.add_zone, ob, zone.pos, zone.radius)
            if not restored or res == false then
                s.until_t = t + 15
                return false
            end
            kept[#kept + 1] = zone
        end
    end
    s.zones, s.rebuild, s.rejected = kept, false, false
    return true
end

-- The path-received bus event ("nav.path_received") is not declared on the live stub: nothing subscribes
-- and S.path_info() is always nil (callers treat that as "no information").
function S.path_info()
    return nil
end
function S.watch_generation(c) end

---Path options from the client's own config (stub: get_path_opts(extra?)).
---No invented keys: extra is passed through only when it is a table.
function S.path_opts(c, extra)
    if type(c) ~= "table" or type(c.get_path_opts) ~= "function" then
        return type(extra) == "table" and extra or nil
    end
    local ok, opts = pcall(c.get_path_opts, c, type(extra) == "table" and extra or nil)
    if ok and type(opts) == "table" then return opts end
    return type(extra) == "table" and extra or nil
end

---Corridor widths per waypoint (stub / recorded present: get_corridor_widths).
function S.corridor_widths(c)
    local ok, v = m(c, "get_corridor_widths")
    return (ok and type(v) == "table") and v or nil
end

---move_to: cb(success, reason, extra?) - reason "unreachable" | "server_timeout" |
---"max_stuck_exceeded" | "max_repath_exceeded" (doc). Arrival on v0.24 is
---cb(true, nil, { code = "arrived", destination }). A walk replaced by a
---newer move_to, or stopped, gets NO callback (recorded on v0.24). A second
---move_to while walking re-plans without stopping (0.12 s, recorded).
---HTTP 414 does not refuse travel: that backoff is for oversized zone /
---find_path / check_path payloads only.
function S.move_to(c, p, cb)
    do local fr = package.loaded["flightrec"] if fr then fr.note("sn_move_to") end end 
    S.watch_generation(c)
    local accept = reply_guard(c)
    local opts = S.path_opts(c)
    local function on_done(success, reason, extra)
        if not accept() then return end
        if cb then pcall(cb, success == true, reason ~= nil and tostring(reason) or nil, extra) end
    end
    local ok, result
    if opts then
        ok, result = m(c, "move_to", pt(p), on_done, opts)
    else
        ok, result = m(c, "move_to", pt(p), on_done)
    end
    return ok and result ~= false
end

---move_direct: a single waypoint, no pathfinding (doc v0.0.8; not run on
---v0.24). Used only for the last yards into a portal (off the navmesh, where
---move_to would snap the target back onto the mesh). cb(success, reason).
---False when the client has no move_direct.
function S.move_direct(c, p, cb)
    do local fr = package.loaded["flightrec"] if fr then fr.note("sn_move_direct") end end 
    local accept = reply_guard(c)
    local ok, result = m(c, "move_direct", pt(p), function(success, reason)
        if not accept() then return end
        if cb then pcall(cb, success == true, reason ~= nil and tostring(reason) or nil) end
    end)
    return ok and result ~= false
end

---follow_path: precomputed waypoints in order; cb(success, reason) (doc).
function S.follow_path(c, points, cb)
    do local fr = package.loaded["flightrec"] if fr then fr.note("sn_follow_path") end end 
    local accept = reply_guard(c)
    local list = {}
    for i = 1, #points do list[i] = pt(points[i]) end
    local ok, result = m(c, "follow_path", list, function(success, reason)
        if not accept() then return end
        if cb then pcall(cb, success == true, reason ~= nil and tostring(reason) or nil) end
    end)
    return ok and result ~= false
end

---stop(): stops all movement (doc); no callback for the stopped walk (v0.24).
function S.stop(c)
    do local fr = package.loaded["flightrec"] if fr then fr.note("sn_stop") end end 
    local ok, result = m(c, "stop")
    return ok and result ~= false
end

---is_moving(): true only while the top-level state is navigating (doc).
function S.moving(c)
    local ok, v = m(c, "is_moving")
    return ok and v == true
end

---get_state(): "idle" | "navigating" | "arrived" | "failed" (doc), or nil.
function S.state(c)
    local ok, v = m(c, "get_state")
    return ok and type(v) == "string" and v or nil
end

---get_full_state(): dotted ("navigating.awaiting_path", ...) or nil.
function S.full_state(c)
    local ok, v = m(c, "get_full_state")
    return ok and type(v) == "string" and v or nil
end

---The walk is still waiting for (or re-requesting) its path.
function S.path_pending(c)
    local f = S.full_state(c) or ""
    return f:find("awaiting_path", 1, true) ~= nil or f:find("repathing", 1, true) ~= nil
        or f:find("deferred", 1, true) ~= nil
end

---Sentinel's own stuck recovery runs (navigating.recovering.*, doc).
function S.recovering(c)
    local f = S.full_state(c) or ""
    return f:find("recovering", 1, true) ~= nil
end

function S.server_up(c)
    local ok, v = m(c, "is_server_available")
    return ok and v == true
end

---get_current_path() -> vec3[] | nil, get_path_index() -> number (doc).
function S.current_path(c)
    local ok, v = m(c, "get_current_path")
    return (ok and type(v) == "table") and v or nil
end
function S.path_index(c)
    local ok, v = m(c, "get_path_index")
    return (ok and type(v) == "number") and v or nil
end

---Every navmesh floor at (x, y): cb(list of heights, nearest `p.z` first).
---v0.24 answers (true, { count, heights = { { height, flags }, ... } }, nil).
---False when the query could not be sent (cb is not called then).
function S.floors(c, p, cb)
    local accept = reply_guard(c)
    local done = false
    local ok = m(c, "get_all_heights", pt(p), function(okh, data)
        if not accept() then return end
        if done then return end
        done = true
        local out = {}
        local hs = (okh == true and type(data) == "table") and data.heights or nil
        for i = 1, #(type(hs) == "table" and hs or {}) do
            local h = hs[i]
            local v = type(h) == "table" and tonumber(h.height) or tonumber(h)
            if v and v == v and math.abs(v) < 20000 then out[#out + 1] = v end
        end
        local z = tonumber(p.z) or 0
        table.sort(out, function(a, b) return math.abs(a - z) < math.abs(b - z) end)
        pcall(cb, out)
    end)
    return ok == true
end

---validate_destination: cb(reachable, reason, distance) (doc, recorded).
function S.validate(c, p, cb)
    local accept = reply_guard(c)
    local ok = m(c, "validate_destination", pt(p), function(reachable, reason, distance)
        if not accept() then return end
        pcall(cb, reachable == true, reason, distance)
    end)
    return ok == true
end

---plan_route: cb(success, data) - data.visit_order on success (doc).
--- plan_route(nodes, cb, opts?) - planning only. 1.2.77 (user: "best use of the in-game Sentinel settings"): the client's OWN path
--- options (get_path_opts: the Pathfinding / Movement tabs - string pulling, partial paths, off-mesh snapping, wall clearance,
--- terrain costs ...) are passed with every plan, exactly as move_to has always done. Without them a precomputed plan (every long
--- walk, the long anchored plans, the hedges, the prefetches) was made with the server's defaults and ignored the settings the
--- player chose. A client that rejects the options is asked without them, and never with them again.
function S.plan_route(c, nodes, cb, extra)
    do local fr = package.loaded["flightrec"] if fr then fr.note("sn_plan_route") end end 
    local accept = reply_guard(c)
    S.plan_sent = S.plan_sent + 1
    -- 1.2.91: the nodes of every plan are logged (the library retries HTTP 422 "Position not on navmesh" for ~6 s with no callback, and the
    -- logs never said WHICH point was off the mesh), and every reply that failed or took 1 s or more.
    local sent_t, sent_n = nil, S.plan_sent
    do
        local R = package.loaded["movement/core"]
        if R and R.now then sent_t = R.now() end
        if R and R.trail and type(nodes) == "table" then
            local parts = {}
            for i = 1, math.min(#nodes, 5) do
                local n = nodes[i]
                parts[#parts + 1] = string.format("(%.0f, %.0f, %.1f)", n.x or 0, n.y or 0, n.z or 0)
            end
            R.trail("nav", "plan #%d nodes: %s%s", sent_n, table.concat(parts, " -> "), #nodes > 5 and (" ... +" .. (#nodes - 5)) or "")
        end
    end
    local function on_done(success, data)
        do
            local R = package.loaded["movement/core"]
            if R and R.now then
                S.last_reply_t = R.now()
                local dt = sent_t and (R.now() - sent_t) or 0
                if R.trail and (success ~= true or dt >= 1.0) then
                    R.trail("nav", "plan #%d reply: ok=%s after %.2f s%s", sent_n, tostring(success == true), dt,
                        (success ~= true and type(data) == "string") and (" (" .. data .. ")") or "")
                end
            end
        end
        S.plan_replied = S.plan_replied + 1
        if not accept() then return end
        pcall(cb, success == true, data)
    end
    local opts = (not S.plan_opts_bad) and S.path_opts(c, extra) or (type(extra) == "table" and extra or nil)
    if type(opts) == "table" and next(opts) ~= nil then
        local ok = m(c, "plan_route", nodes, on_done, opts)
        if ok == true then return true end
        S.plan_opts_bad = true
    end
    local ok = m(c, "plan_route", nodes, on_done)
    return ok == true
end

---1.2.89 (log 18:40-18:45: 8 plan_route calls toward one goal, no callback, the server saw 0 failed requests): one line per
---unanswered plan so the next log says WHY - the server flag, the Sentinel state, how long since ANY reply, requests sent vs
---answered, and how many replies this adapter's own guard dropped (generation / client / world change).
function S.log_unanswered(c, tag, x, y, sent_t)
    local R = package.loaded["movement/core"]
    if not R or not R.trail then return end
    local up = S.server_up(c)
    local now = R.now()
    local ok, state = pcall(function() return S.full_state(c) end)
    R.trail("nav", "plan not answered [%s] goal (%.0f, %.0f): asked %s ago, server_up=%s, state=%s, last reply of any plan %s ago, plans sent %d / replied %d, replies dropped by guard gen %d client %d world %d",
        tostring(tag), x or 0, y or 0, sent_t and string.format("%.1f s", now - sent_t) or "?", tostring(up),
        tostring(ok and state or "?"), S.last_reply_t and string.format("%.0f s", now - S.last_reply_t) or "never",
        S.plan_sent, S.plan_replied, S.drops.generation, S.drops.client, S.drops.world)
end

---One path query, no movement (advanced: client.nav_client:find_path).
---v0.24 answers (true, { waypoints, distance, partial, computation_time_ms }, nil).
---cb(points or nil, ok, info) where info.partial says the path stops short.
-- Zygor Forever 1.0.0: nav_client:find_path is a library internal the live stub does not declare, so it is never called.
-- One path query, no movement, answered by the declared plan_route: cb(points|nil, ok, info).
function S.find_path(c, a, b, cb)
    return S.plan_route(c, { pt(a), pt(b) }, function(ok, data)
        local pts = (ok == true and type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
        pcall(cb, (pts and #pts >= 2) and pts or nil, ok == true, { partial = false })
    end)
end

-- AVOIDANCE ZONE + SOFT RE-PATH (verified on v0.24 by the MF API Dump,
-- 2026-10-24: obstacle:add_zone(pos, radius) 3 args, replan(reason, opts) 3).
-- Every path request after add_zone avoids the zone (Sentinel's path-avoid,
-- cost 100, the zone ages out after its TTL - 120 s in the Sentinel UI);
-- replan with soft = true blends the new path in without stopping.
-- Zygor Forever 1.0.0: obstacle:add_zone is a library internal the live stub does not declare, so it is never called.
-- Gated by S.UNDECLARED_ZONES (default false): obstacle:* is not declared on the live stub.
function S.add_zone(c, p, radius)
    if not S.UNDECLARED_ZONES then return false end
    local count = S.zone_count(c)
    if S.request_blocked(c) or (count and count >= S.ZONE_LIMIT) then return false end
    local s, t = requests[c], core.time()
    for i = #s.added, 1, -1 do
        if t - s.added[i] >= 125 or t < s.added[i] then table.remove(s.added, i) end
    end
    if #s.added >= S.ZONE_LIMIT then return false end
    local oko, ob = pcall(function() return c.obstacle end)
    if not oko or type(ob) ~= "table" or type(ob.add_zone) ~= "function" then return false end
    local ok, result = pcall(ob.add_zone, ob, pt(p), radius)
    if not ok or result == false then return false end
    s.added[#s.added + 1] = t
    for i = #s.zones, 1, -1 do
        if t - s.zones[i].t >= 110 or t < s.zones[i].t then table.remove(s.zones, i) end
    end
    s.zones[#s.zones + 1] = {pos=pt(p), radius=radius, t=t}
    return true
end

function S.soft_replan(c, reason)
    local ok, r = pcall(function() return c:replan(reason) end)
    return ok and r ~= false
end

---nav_client:raycast (recorded v0.24, 5 args including self):
---cb(ok, { hit, t }, nil) - t is FLT_MAX when nothing is hit.
---Product callback: cb(ok, hit, t). False when the client has no raycast.
-- Zygor Forever 1.0.0: nav_client:raycast is a library internal the live stub does not declare, so it is never called.
function S.raycast(c, a, b, cb)
    return false
end

-- KITE (nav_client:kite, present on v0.24 with 5 args - MF API Dump
-- 2026-10-24; its answer read from the readable v0.0.6 source, the same
-- (true, { waypoints, ... }, nil) shape as find_path, which v0.24 confirmed):
--   kite(player_pos, target_pos, cb(ok, { waypoints, waypoint_count }, err), { kite_radius })
-- cb(points | nil, ok, info): info.shape_bad = an answer of another shape
-- (the caller switches kiting off), info.error = the library's error text.
-- Zygor Forever 1.0.0: nav_client:kite is a library internal the live stub does not declare, so it is never called.
function S.kite(c, from, target, radius, cb)
    return false
end


-- 1.16.0 FLEE (nav_client:flee, present on v0.24 - MF API Dump 2026-10-24;
-- argument order from the official page: flee(player_pos, threats, cb, opts)):
--   flee(player_pos, { threat_pos, ... }, cb(ok, { waypoints, ... }, err), { flee_distance })
-- The answer is expected in find_path's shape and checked live like kite's:
-- cb(points | nil, ok, info) - info.shape_bad = another shape (the caller
-- switches fleeing off), info.error = the library's error text.
-- Zygor Forever 1.0.0: nav_client:flee is a library internal the live stub does not declare, so it is never called.
function S.flee(c, from, threats, distance, cb)
    return false
end

-- 1.16.0 LIVE STATUS for the GUI and the route progress (improvements 5 and
-- 11 of the API-dump review). Shapes recorded on v0.24 by the MF Start Dump:
--   get_progress()        { current_index, percent, total_waypoints, waypoints_remaining }
--   get_route_progress()  nothing while no recorded route runs (its shape when
--                         one runs is not recorded: a number or a table with
--                         percent / index / total is read, anything else ignored)
--   get_destination()     vec3 | nothing
--   obstacle:get_zone_count()             number
--   nav_client:get_consecutive_failures() number
-- Read on the update tick only (never on the render path).
local function num(v) v = tonumber(v) if v and v == v then return v end return nil end
function S.progress(c)
    local ok, v = m(c, "get_progress")
    if not ok or type(v) ~= "table" then return nil end
    -- audit 1.19.0: percent is 0..1 (doc / stub) - shown as 0..100 like route_progress
    local pc = num(v.percent)
    if pc and pc <= 1 then pc = pc * 100 end
    return { index = num(v.current_index), percent = pc,
        total = num(v.total_waypoints), left = num(v.waypoints_remaining) }
end
-- Zygor Forever 1.0.0: get_route_progress is a library internal the live stub does not declare, so it is never called.
function S.route_progress(c)
    return nil
end
function S.destination(c)
    local ok, v = m(c, "get_destination")
    if ok and type(v) == "table" and type(v.x) == "number" then return v end
    return nil
end
-- Zygor Forever 1.0.0: obstacle:get_zone_count is a library internal the live stub does not declare, so it is never called.
-- Gated by S.UNDECLARED_ZONES (default false): obstacle:* is not declared on the live stub.
function S.zone_count(c)
    if not S.UNDECLARED_ZONES then return nil end
    local oko, ob = pcall(function() return c.obstacle end)
    if not oko or type(ob) ~= "table" or type(ob.get_zone_count) ~= "function" then return nil end
    local ok, v = pcall(ob.get_zone_count, ob)
    return ok and num(v) or nil
end
-- Zygor Forever 1.0.0: nav_client:get_consecutive_failures is a library internal the live stub does not declare, so it is never called.
function S.failures(c)
    return nil
end


-- 2026-10-27 CHECK_PATH (advanced; user: "check_path (running-path validation)").
-- PRESENT on v0.24 - docs/SENTINEL_V024.md enumerates nav_client:check_path - but its
-- CALLBACK SHAPE IS NOT RECORDED there (only find_path's is), so this is deliberately
-- careful. The shape of every answer is handed back for the caller to log once, and
-- ONLY an unambiguous "this path is bad" (valid == false / blocked == true /
-- reachable == false) asks for a re-plan. A bare `false` is NOT treated as bad: on
-- this client that is also what a server error looks like, and a spurious re-plan is
-- worse than a late one. Anything else is "no opinion" and the walk is left alone.
-- CHECK_ERRORS failed calls, or a library without check_path, switch it off for the
-- session and it is never asked again.
S.CHECK_ERRORS = 3
S.CHECK_POINTS = 8
local check_pending = setmetatable({}, {__mode="k"})
local check_off, check_errs = false, 0

local function check_verdict(a, b)
    local d = (type(b) == "table" and b) or (type(a) == "table" and a) or nil
    if type(d) == "table" then
        if d.valid == false or d.blocked == true or d.reachable == false then return false, "table" end
        if d.valid == true or d.ok == true or d.reachable == true then return true, "table" end
        return nil, "table with no verdict field"
    end
    if a == true and b == nil then return true, "bare true" end
    return nil, "unreadable (" .. type(a) .. ", " .. type(b) .. ")"
end

---check_path: is the path the player is walking still good? cb(verdict, shape):
---verdict true (good) / false (re-plan) / nil (no opinion); shape = a short text
---for the log. Returns false when it could not be asked.
-- Zygor Forever 1.0.0: nav_client:check_path is a library internal the live stub does not declare, so it is never called.
function S.check_path(c, pos, waypoints, cb)
    check_off = true
    return false
end
---True once check_path has been switched off for this session.
function S.check_path_off() return check_off end

return S
