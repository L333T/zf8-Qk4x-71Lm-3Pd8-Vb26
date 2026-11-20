-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/memory.lua - stuck-area memory (black points) and known-good paths
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- ============================================================================
-- 1.9.0. movement/nav.lua is the only caller; this module only chooses point
-- lists and remembers outcomes - the library keeps the legs, the stuck ladder
-- and the keys.
-- 1.10.0 SENTINEL: Sentinel plans and walks its own paths (move_to), so the
-- point lists chosen here (M.find_valid / M.find_good, the black-point
-- filter of a server path) are no longer walked - nav.lua only filters a
-- recorded route (M.filter) and refuses a black goal cell (M.goal_blocked).
-- The BOOKKEEPING runs as before: black points confirmed from failed walks
-- and stuck episodes (mirrored to the session's zones), credits for walks
-- that got through, valid-path capture, the files.
--
-- A BLACK POINT is a small disk on the navmesh where a walk got stuck: the
-- player's own position when a walk ended max_stuck_exceeded / unreachable /
-- end_off_mesh, or where the same corridor was re-planned a second time. Not a
-- death (deathzones.lua), not a mob, not the far goal. One record per 4 yd cell
-- of (map, instance, indoors); radius 3..7 yd, growing with fail and shrinking
-- with ok; ok > fail deletes it. "Active" = fail > ok.
--
-- A GOOD PATH is the point list of a follow_path that arrived (not a false
-- arrival), kept per goal cell: at most 40 points about 8 yd apart.
--
-- 1.9.2 (ported from Forever 1.0.14) STUCK AREAS. A black point is confirmed (M.confirm_stuck) only from the
-- library's own give-up (record_fail: max_stuck_exceeded / unreachable /
-- end_off_mesh after a walk that ran), from the stuck episode of movement.lua
-- (M.confirm_episode: its origin, once, at the fresh-path rung or when the
-- fan gives up) and from the twice re-planned corridor (note_replan). Never
-- while quiet, swimming, resting, backing up, in a portal walk or a detour
-- (M.hold_record); one record per cell per stuck episode (M.episode).
--
-- 1.9.2 (Forever 1.0.14) VALID PATHS. A VALID PATH is the stretch the player actually walked
-- past an active stuck area: captured in M.tick while a non-combat walk runs
-- (Sentinel's get_current_path / get_path_index, through movement/nav), started
-- when the player or the path ahead (25 yd) comes within radius + 8 yd of the
-- area, committed once the player is radius + 6 yd clear of it and 8 yd nearer
-- the walk's goal (or the walk arrived). Kept per stuck cell + approach bin (8
-- compass slots), at most 32 per set; nav.lua walks one past the area instead
-- of planning round it (M.find_valid). Bookkeeping only: nothing here moves.
--
-- 1.9.2 (Forever 1.0.17) INDOORS (the set with indoors = 1, M.ctx): a growing map of the
-- building. A stuck area is a SMALL disk - radius IN_R (2) yd on an IN_CELL (2)
-- yd cell - that never grows (a repeat only refreshes seen), is never capped,
-- and is REFUSED when a stored indoor valid path has a point inside it (the
-- player is on a route that works). Every indoor walk is captured from its
-- start: the stretch past a stuck area is kept once cleared, and the whole
-- walked route once the follow_path arrives (not a false arrival). Indoor
-- valid paths are NEVER removed - no prune, no drop, no cap, no TTL; the same
-- route again (the same 2 yd cells) keeps the stored one, a new one is
-- appended. M.find_valid gives the stored route nearest the player that
-- reaches toward the goal; nav.lua tries it before find_path. Indoor good
-- paths are not pruned either. Outdoors nothing changed.
--
-- Files (scripts_data/mfz_nav, one snapshot pair per instance + map, the
-- indoors flag inside the lines), replaced whole: create_data_file then one
-- write_data_file, at most every 10 s and only after a change.
--   black: v1|map|instance|indoors|cx|cy|cz|fail|ok|seen|radius
--   path:  v1|map|instance|indoors|cx|cy|cz|seen|n|x,y,z;x,y,z;...
--   valid: v1|map|instance|indoors|cx|cy|cz|bin|seen|n|x,y,z;x,y,z;...   (1.0.14,
--          mfz_nav/valid_<instance>_<map>.txt; outdoors)
--          v2|map|instance|1|cx|cy|cz|bin|seen|n|x,y,z;x,y,z;...   (1.0.17, the
--          same file; indoors - written whatever seen is, never expired)
-- API (Core_Api Generated_Lua_API_Database): core.get_map_id,
-- core.get_instance_id, core.get_server_time, core.time, core.create_data_folder,
-- core.create_data_file, core.write_data_file, core.read_data_file,
-- game_object:is_indoors / is_casting_spell / is_channelling_spell,
-- core.character.is_swimming; 1.10.0: the walk read through movement/nav
-- (N.busy, N.path_points, N.path_index - Sentinel is_moving / get_current_path /
-- get_path_index, every call in movement/sentinel.lua).
-- ============================================================================

local R = require("movement/core")

local M = {}

M.CELL = 4
M.R_MIN, M.R_MAX = 3, 7
M.MAX_BLACK = 64               -- per map + instance + indoors
M.MAX_PATHS = 32
M.MAX_POINTS = 40
M.POINT_GAP = 8                -- yd between kept points of a good path
M.GOAL_NEAR = 8                -- yd: a good path's goal cell this near the asked goal
M.START_NEAR = 10              -- yd: the saved path must pass this near the player
M.PASS_R2 = 9                  -- a walk within 3 yd (squared) of a black cell passes it
M.PROGRESS = 3                 -- yd past the cell that count as getting through it
M.CORRIDOR = 2                 -- yd: two re-plans with midpoints this close = the same corridor
M.OFF_YD = 5                   -- yd beyond a black disk for the detour point
M.WRITE_GAP = 10               -- s (core.time) between two writes
M.TTL = 7 * 86400              -- s of server time a record is kept unseen
M.FOLDER = "mfz_nav"
M.BLACK_CODES = { max_stuck_exceeded = true, unreachable = true, end_off_mesh = true }
-- 1.0.14 stuck areas / valid paths
M.EP_SAME_S = 30               -- s: outside a stuck episode, the same cell is confirmed once in this time
M.VALID_NEAR = 8               -- yd beyond a stuck radius that count as nearing it
M.VALID_AHEAD = 25             -- yd of the path ahead checked for nearing
M.VALID_DZ = 10                -- yd of height that still count as the same area
M.VALID_BACK = 20              -- yd: the corridor's first point at most this far before the near point
M.VALID_CLEAR = 6              -- yd beyond the radius that count as cleared
M.VALID_GAIN = 8               -- yd nearer the goal that count as past it
M.VALID_PICKUP = 20            -- yd: a corridor's point this near the player to be taken
M.MAX_VALID = 32               -- corridors per map + instance + indoors
M.MAX_RAW = 400                -- samples kept while a corridor is captured
-- 1.0.23 (user): a valid path keeps its walked points VALID_GAP yd apart (no
-- M.thin, the gap never widened) and is walked resampled at that spacing; the
-- part of a server path near an active stuck disk is resampled at it too
M.VALID_GAP = 2
local PAUSE_QUIET = { "cast", "loot", "conjure" }   -- pause reasons that hold the memory
local PAUSE_MAX = 30           -- s: a pause never resumed stops counting after this

local black = {}               -- set key -> { cell key -> rec }
local paths = {}               -- set key -> { rec, ... }
local loaded = {}              -- file key "instance_map" -> true
local dirty = {}               -- file key -> { map, inst }
local folder_ok = false
local last_write = -1e9
local paused = {}              -- pause reason -> core.time it started
local indoor = { t = -1e9, v = 0 }
local corridor = nil           -- the last re-plan: { set, mx, my }
local passing = {}             -- rec -> true while the player is inside its 3 yd
local valid = {}               -- set key -> { corridor rec, ... }  (1.0.14)
local vbuf = nil               -- the corridor being captured (1.0.14)
local ep_token, ep_cells = nil, {}   -- the stuck episode (movement.lua) and the cells it confirmed
local recent = {}              -- full cell key -> R.now() of its last confirm outside an episode
local keep_v2 = {}             -- 1.0.17: file key -> v2 lines of the file not loaded (kept as they are)
local NO_SET = {}              -- 1.9.2: read-only empty set (the capture tick allocates no table)

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------
local function num(f, ...)
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, ...)
    if ok then return tonumber(v) end
    return nil
end

function M.server_time()
    return num(core and core.get_server_time) or 0
end

function M.cell(v) return math.floor(v / M.CELL) * M.CELL + 2 end
-- 1.0.17: indoor stuck areas - a 2 yd cell, a fixed 2 yd radius
M.IN_CELL, M.IN_R = 2, 2
function M.cell_in(v) return math.floor(v / M.IN_CELL) * M.IN_CELL + 1 end
local function cell_for(ind) return ind == 1 and M.cell_in or M.cell end

local function clamp_r(fail, ok)
    local r = M.R_MIN + (fail - 1) - ok
    if r < M.R_MIN then r = M.R_MIN elseif r > M.R_MAX then r = M.R_MAX end
    return r
end

local function set_key(map, inst, ind) return map .. "|" .. inst .. "|" .. ind end
local function cell_key(cx, cy, cz) return cx .. "|" .. cy .. "|" .. cz end
local function file_key(map, inst) return inst .. "_" .. map end

--- map, instance, indoors (0 / 1; is_indoors read at most once a second)
function M.ctx()
    local map = num(core and core.get_map_id) or 0
    local inst = num(core and core.get_instance_id) or 0
    local t = R.now()
    if t - indoor.t >= 1 then
        indoor.t = t
        local me = R.me()
        local ok, v = false, nil
        if me then ok, v = pcall(function() return me:is_indoors() end) end
        indoor.v = (ok and v == true) and 1 or 0
    end
    return map, inst, indoor.v
end

--- True while a cast, a channel, a mount cast, or a loot / conjure / cast pause
--- holds the walk: nothing is counted and nothing is written then.
function M.quiet()
    local me = R.me()
    if me then
        local ok, c = pcall(function() return me:is_casting_spell() == true or me:is_channelling_spell() == true end)
        if ok and c == true then return true end
    end
    local okm, MT = pcall(require, "movement/mount")
    if okm and type(MT) == "table" and type(MT.casting) == "function" then
        local okc, mc = pcall(MT.casting)
        if okc and mc == true then return true end
    end
    local t = R.now()
    for r, t0 in pairs(paused) do
        if t - t0 > PAUSE_MAX then paused[r] = nil
        else
            local s = string.lower(tostring(r))
            for i = 1, #PAUSE_QUIET do if s:find(PAUSE_QUIET[i], 1, true) then return true end end
        end
    end
    return false
end
function M.on_pause(reason)
    if reason == nil then return end
    paused[reason] = R.now()
    -- 1.0.14: a loot / conjure / cast pause is not progress past a stuck area
    local s = string.lower(tostring(reason))
    for i = 1, #PAUSE_QUIET do
        if vbuf and s:find(PAUSE_QUIET[i], 1, true) then
            R.trail("nav", "nav memory: %s not kept - %s pause", vbuf.rec
                and string.format("valid path past (%d, %d)", vbuf.rec.cx, vbuf.rec.cy) or "indoor route", s)
            vbuf = nil
            break
        end
    end
end
function M.on_resume(reason) if reason ~= nil then paused[reason] = nil end end

local function mark(map, inst) dirty[file_key(map, inst)] = { map = map, inst = inst } end

local function black_set(map, inst, ind)
    local k = set_key(map, inst, ind)
    black[k] = black[k] or {}
    return black[k]
end
local function path_set(map, inst, ind)
    local k = set_key(map, inst, ind)
    paths[k] = paths[k] or {}
    return paths[k]
end
local function valid_set(map, inst, ind)
    local k = set_key(map, inst, ind)
    valid[k] = valid[k] or {}
    return valid[k]
end

--- The movement/nav module once it is loaded (it requires this one).
local function nav() return package.loaded["movement/nav"] end

--- 1.0.14: why no stuck area may be recorded now, or nil: quiet (M.quiet),
--- swimming, resting, backing up, a portal walk or a detour.
function M.hold_record()
    if M.quiet() then return "quiet" end
    local oks, sw = pcall(function() return core.character.is_swimming() == true end)
    if oks and sw == true then return "swimming" end
    if R.resting then return "resting" end
    if R.backpedal_until then return "backpedal" end
    local N = nav()
    if type(N) == "table" then
        if type(N.mode) == "function" then
            local okm, m = pcall(N.mode)
            if okm and m == "portal" then return "portal" end
        end
        if type(N.detour_active) == "function" then
            local okd, d = pcall(N.detour_active)
            if okd and d == true then return "detour" end
        end
    end
    return nil
end

--- 1.0.14: the 8 compass slots of (x, y) seen from the cell (cx, cy).
function M.bin(x, y, cx, cy)
    local a = (math.atan2 or math.atan)(y - cy, x - cx)
    return math.floor((a + math.pi) / (math.pi / 4)) % 8
end

-- ----------------------------------------------------------------------------
-- files
-- ----------------------------------------------------------------------------
local function black_name(inst, map) return M.FOLDER .. "/black_" .. inst .. "_" .. map .. ".txt" end
local function paths_name(inst, map) return M.FOLDER .. "/paths_" .. inst .. "_" .. map .. ".txt" end
local function valid_name(inst, map) return M.FOLDER .. "/valid_" .. inst .. "_" .. map .. ".txt" end

local function ensure_folder()
    if folder_ok then return true end
    if type(core) ~= "table" or type(core.create_data_folder) ~= "function" then return false end
    folder_ok = pcall(core.create_data_folder, M.FOLDER) == true
    return folder_ok
end

local function split(s, sep)                -- plain split (gmatch "[^|]*" adds empty matches in 5.1)
    local out, i = {}, 1
    while true do
        local j = string.find(s, sep, i, true)
        if not j then out[#out + 1] = s:sub(i) return out end
        out[#out + 1] = s:sub(i, j - 1)
        i = j + 1
    end
end
local function lines(text)
    local out = {}
    for ln in string.gmatch(text or "", "[^\r\n]+") do out[#out + 1] = ln end
    return out
end

local function read(name)
    if type(core) ~= "table" or type(core.read_data_file) ~= "function" then return "" end
    local ok, s = pcall(core.read_data_file, name)
    return (ok and type(s) == "string") and s or ""
end

--- Parse one black line; nil when it is not a v1 line of 11 fields.
function M.parse_black(ln)
    if ln:sub(1, 3) ~= "v1|" then return nil end
    local f = split(ln, "|")
    if #f ~= 11 then return nil end
    local v = {}
    for i = 2, 11 do v[i] = tonumber(f[i]) if v[i] == nil then return nil end end
    return { map = v[2], inst = v[3], ind = v[4], cx = v[5], cy = v[6], cz = v[7],
        fail = v[8], ok = v[9], seen = v[10], radius = v[11] }
end

--- Parse one path line; nil when it is not a v1 line of 10 fields.
function M.parse_path(ln)
    if ln:sub(1, 3) ~= "v1|" then return nil end
    local f = split(ln, "|")
    if #f ~= 10 then return nil end
    local v = {}
    for i = 2, 9 do v[i] = tonumber(f[i]) if v[i] == nil then return nil end end
    local pts = {}
    for trip in string.gmatch(f[10], "[^;]+") do
        local c = split(trip, ",")
        local x, y, z = tonumber(c[1]), tonumber(c[2]), tonumber(c[3])
        if #c ~= 3 or not (x and y and z) then return nil end
        pts[#pts + 1] = { x = x, y = y, z = z }
    end
    if #pts < 2 or #pts ~= v[9] then return nil end
    return { map = v[2], inst = v[3], ind = v[4], cx = v[5], cy = v[6], cz = v[7], seen = v[8], points = pts }
end

--- 1.0.14: parse one valid-path line; nil when it is not a v1 line of 11
--- fields (map ... n whole numbers, bin 0..7, n = the number of x,y,z triples).
function M.parse_valid(ln)
    local ver = ln:sub(1, 3)
    if ver ~= "v1|" and ver ~= "v2|" then return nil end      -- 1.0.17: v2 = an indoor line
    local f = split(ln, "|")
    if #f ~= 11 then return nil end
    local v = {}
    for i = 2, 10 do
        v[i] = tonumber(f[i])
        if v[i] == nil or v[i] ~= math.floor(v[i]) then return nil end
    end
    if v[8] < 0 or v[8] > 7 then return nil end
    if ver == "v2|" and v[4] ~= 1 then return nil end          -- a v2 line is always indoors
    local pts = {}
    for trip in string.gmatch(f[11], "[^;]+") do
        local c = split(trip, ",")
        local x, y, z = tonumber(c[1]), tonumber(c[2]), tonumber(c[3])
        if #c ~= 3 or not (x and y and z) then return nil end
        pts[#pts + 1] = { x = x, y = y, z = z }
    end
    if #pts < 2 or #pts ~= v[10] then return nil end
    return { map = v[2], inst = v[3], ind = v[4], cx = v[5], cy = v[6], cz = v[7], bin = v[8], seen = v[9],
        points = pts }
end

--- Load the current map + instance files once.
function M.load(map, inst)
    if map == nil then map, inst = M.ctx() end
    local fk = file_key(map, inst)
    if loaded[fk] then return end
    loaded[fk] = true
    if not ensure_folder() then return end
    local now = M.server_time()
    local function fresh(seen) return now <= 0 or (now - seen) <= M.TTL end
    local nb, np, nv = 0, 0, 0
    for _, ln in ipairs(lines(read(black_name(inst, map)))) do
        local r = M.parse_black(ln)
        if r and r.map == map and r.inst == inst and fresh(r.seen) then
            r.ind = (r.ind == 1) and 1 or 0
            black_set(map, inst, r.ind)[cell_key(r.cx, r.cy, r.cz)] = r
            nb = nb + 1
        end
    end
    for _, ln in ipairs(lines(read(paths_name(inst, map)))) do
        local p = M.parse_path(ln)
        if p and p.map == map and p.inst == inst and fresh(p.seen) then
            p.ind = (p.ind == 1) and 1 or 0
            local s = path_set(map, inst, p.ind)
            s[#s + 1] = p
            np = np + 1
        end
    end
    keep_v2[fk] = {}
    for _, ln in ipairs(lines(read(valid_name(inst, map)))) do
        local p = M.parse_valid(ln)
        -- 1.0.17: an indoor valid path is never expired
        if p and p.map == map and p.inst == inst and (p.ind == 1 or fresh(p.seen)) then
            p.ind = (p.ind == 1) and 1 or 0
            local s = valid_set(map, inst, p.ind)
            s[#s + 1] = p
            nv = nv + 1
        elseif ln:sub(1, 3) == "v2|" then
            local kv = keep_v2[fk]
            kv[#kv + 1] = ln                                -- 1.0.17: written back as it is
        end
    end
    if nb + np + nv > 0 then
        R.trail("nav", "nav memory: map %d instance %d - %d black point(s), %d good path(s), %d valid path(s) loaded",
            map, inst, nb, np, nv)
    end
end

local function snapshot_text(map, inst)
    local b, p = {}, {}
    for k, set in pairs(black) do
        for _, r in pairs(set) do
            if r.map == map and r.inst == inst and r.seen > 0 then
                b[#b + 1] = string.format("v1|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d", r.map, r.inst, r.ind, r.cx, r.cy, r.cz,
                    r.fail, r.ok, r.seen, r.radius)
            end
        end
    end
    for k, set in pairs(paths) do
        for _, r in ipairs(set) do
            if r.map == map and r.inst == inst and r.seen > 0 then
                local t = {}
                for i, q in ipairs(r.points) do t[i] = string.format("%.1f,%.1f,%.1f", q.x, q.y, q.z) end
                p[#p + 1] = string.format("v1|%d|%d|%d|%d|%d|%d|%d|%d|%s", r.map, r.inst, r.ind, r.cx, r.cy, r.cz,
                    r.seen, #r.points, table.concat(t, ";"))
            end
        end
    end
    local v = {}
    for k, set in pairs(valid) do
        for _, r in ipairs(set) do
            -- 1.0.17: every indoor valid path (v2, whatever its seen); outdoor v1 as before
            if r.map == map and r.inst == inst and (r.ind == 1 or r.seen > 0) then
                local t = {}
                for i, q in ipairs(r.points) do t[i] = string.format("%.1f,%.1f,%.1f", q.x, q.y, q.z) end
                v[#v + 1] = string.format("%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s", r.ind == 1 and "v2" or "v1", r.map,
                    r.inst, r.ind, r.cx, r.cy, r.cz, r.bin, r.seen, #r.points, table.concat(t, ";"))
            end
        end
    end
    for _, ln in ipairs(keep_v2[file_key(map, inst)] or {}) do v[#v + 1] = ln end
    table.sort(b) table.sort(p) table.sort(v)
    return table.concat(b, "\n"), table.concat(p, "\n"), table.concat(v, "\n")
end

local function replace(name, text)
    if pcall(core.create_data_file, name) ~= true then return false end
    if #text > 0 then pcall(core.write_data_file, name, text .. "\n") end
    return true
end

--- Write the changed snapshots: at most every WRITE_GAP s, never while quiet;
--- `force` (movement.halt) skips the gap.
function M.flush(force)
    if next(dirty) == nil then return false end
    local t = R.now()
    if not force and (t - last_write) < M.WRITE_GAP then return false end
    if M.quiet() then return false end
    if type(core) ~= "table" or type(core.create_data_file) ~= "function"
        or type(core.write_data_file) ~= "function" or not ensure_folder() then return false end
    last_write = t
    for fk, d in pairs(dirty) do
        M.load(d.map, d.inst)                               -- 1.0.17: the file's lines are in before it is replaced
        local bt, pt, vt = snapshot_text(d.map, d.inst)
        replace(black_name(d.inst, d.map), bt)
        replace(paths_name(d.inst, d.map), pt)
        replace(valid_name(d.inst, d.map), vt)              -- 1.0.14
        dirty[fk] = nil
    end
    return true
end

-- ----------------------------------------------------------------------------
-- black points
-- ----------------------------------------------------------------------------
local function active(r) return r.fail > r.ok end
M.active = active

local function inside(r, x, y)
    local dx, dy = r.cx - x, r.cy - y
    return dx * dx + dy * dy <= r.radius * r.radius
end

--- Delete the good paths of a set that pass through an active black point.
local function prune_paths(map, inst, ind, r)
    if ind == 1 then return end                            -- 1.0.17: nothing is removed indoors
    local s = path_set(map, inst, ind)
    for i = #s, 1, -1 do
        for _, q in ipairs(s[i].points) do
            if inside(r, q.x, q.y) then
                R.trail("nav", "nav memory: good path to (%d, %d) dropped - it passes a black point at (%d, %d)",
                    s[i].cx, s[i].cy, r.cx, r.cy)
                table.remove(s, i)
                mark(map, inst)
                break
            end
        end
    end
end

--- 1.0.14: delete the valid paths of a set that enter an active stuck disk.
local function prune_valid(map, inst, ind, r)
    if ind == 1 then return end                            -- 1.0.17: an indoor valid path is never removed
    local s = valid_set(map, inst, ind)
    for i = #s, 1, -1 do
        for _, q in ipairs(s[i].points) do
            if inside(r, q.x, q.y) then
                R.trail("nav", "nav memory: valid path past (%d, %d) bin %d dropped - it enters the stuck area at (%d, %d)",
                    s[i].cx, s[i].cy, s[i].bin, r.cx, r.cy)
                table.remove(s, i)
                mark(map, inst)
                break
            end
        end
    end
end

--- 1.0.17: the stored indoor valid path with a point inside the 2 yd disk
--- at (cx, cy), or nil.
local function on_valid_path(map, inst, cx, cy)
    local disk = { cx = cx, cy = cy, radius = M.IN_R }
    for _, v in ipairs(valid_set(map, inst, 1)) do
        for _, q in ipairs(v.points) do
            if inside(disk, q.x, q.y) then return v end
        end
    end
    return nil
end

--- 1.0.17: an INDOOR stuck area - a 2 yd disk on a 2 yd cell, refused when a
--- stored indoor valid path runs through it; a repeat refreshes seen only.
local function note_stuck_in(map, inst, px, py, pz, code)
    local s = black_set(map, inst, 1)
    local cx, cy, cz = M.cell_in(px), M.cell_in(py), M.cell_in(pz)
    local k = cell_key(cx, cy, cz)
    local now = M.server_time()
    local r = s[k]
    if r then
        if now > 0 then r.seen = now mark(map, inst) end
        R.trail("nav", "nav memory: indoor stuck area (%d, %d, %d) seen again - %s", cx, cy, cz, tostring(code))
        return r
    end
    local v = on_valid_path(map, inst, cx, cy)
    if v then
        R.trail("nav", "nav memory: indoor stuck area (%d, %d, %d) refused - the valid path (%d, %d) bin %d runs through it (%s)",
            cx, cy, cz, v.cx, v.cy, v.bin, tostring(code))
        return nil
    end
    r = { map = map, inst = inst, ind = 1, cx = cx, cy = cy, cz = cz, fail = 1, ok = 0, seen = now > 0 and now or 0,
        radius = M.IN_R }
    s[k] = r
    if r.seen > 0 then mark(map, inst) end
    R.trail("nav", "nav memory: indoor stuck area (%d, %d, %d) r %d - %s", cx, cy, cz, r.radius, tostring(code))
    return r
end

--- A walk got stuck at the player's position (px, py, pz) with `code`.
--- Returns the black record (nil when not counted).
function M.note_stuck(px, py, pz, code)
    if not (R.finite(px) and R.finite(py) and R.finite(pz)) then return nil end
    if M.hold_record() then return nil end                 -- 1.0.14 (was M.quiet only)
    local map, inst, ind = M.ctx()
    M.load(map, inst)
    if ind == 1 then return note_stuck_in(map, inst, px, py, pz, code) end      -- 1.0.17
    local s = black_set(map, inst, ind)
    local cx, cy, cz = M.cell(px), M.cell(py), M.cell(pz)
    local k = cell_key(cx, cy, cz)
    local now = M.server_time()
    local r = s[k]
    if r then
        r.fail = r.fail + 1
        if now > 0 then r.seen = now end
    else
        r = { map = map, inst = inst, ind = ind, cx = cx, cy = cy, cz = cz, fail = 1, ok = 0, seen = now > 0 and now or 0 }
        local n, oldest, ok_k = 0, nil, nil
        for kk, rr in pairs(s) do
            n = n + 1
            if oldest == nil or rr.seen < oldest then oldest, ok_k = rr.seen, kk end
        end
        if n >= M.MAX_BLACK and ok_k then s[ok_k] = nil end
        s[k] = r
    end
    r.radius = clamp_r(r.fail, r.ok)
    if r.seen > 0 then mark(map, inst) end
    R.trail("nav", "nav memory: black point (%d, %d, %d) r %d - %s (fail %d, ok %d)", cx, cy, cz, r.radius,
        tostring(code), r.fail, r.ok)
    if active(r) then
        prune_paths(map, inst, ind, r)
        prune_valid(map, inst, ind, r)                     -- 1.0.14
    end
    return r
end

--- 1.0.14: the stuck episode of movement.lua (its start time, nil when none
--- runs): a cell is confirmed once per episode.
function M.episode(token)
    if token ~= ep_token then ep_token, ep_cells = token, {} end
end

--- 1.0.14: a CONFIRMED stuck area at the player's feet (px, py, pz) - record_fail's
--- library give-up, or the stuck episode's origin. Once per cell per episode
--- (outside an episode: once per EP_SAME_S s). The black record, or nil.
function M.confirm_stuck(px, py, pz, code)
    if not (R.finite(px) and R.finite(py) and R.finite(pz)) then return nil end
    local hold = M.hold_record()
    if hold then return nil end
    local map, inst, ind = M.ctx()
    local cf = cell_for(ind)                                -- 1.0.17: 2 yd cells indoors
    local fk = set_key(map, inst, ind) .. "|" .. cell_key(cf(px), cf(py), cf(pz))
    if ep_token ~= nil then
        if ep_cells[fk] then return nil end
        ep_cells[fk] = true
    else
        local t0 = recent[fk]
        if t0 and R.now() - t0 < M.EP_SAME_S then return nil end
    end
    recent[fk] = R.now()
    return M.note_stuck(px, py, pz, code)
end

--- 1.0.14: the stuck episode's origin (x, y, z = the player's when it began),
--- from outdoor_unstick on the update tick. The black record, or nil.
function M.confirm_episode(x, y, z, why)
    local r = M.confirm_stuck(x, y, z, why or "stuck episode")
    if r then
        R.trail("nav", "nav memory: stuck area confirmed at (%d, %d, %d) - %s", r.cx, r.cy, r.cz, tostring(why))
    end
    return r
end

--- A re-plan of the walk from (px, py, pz) to (gx, gy): the second re-plan of
--- the same corridor (midpoints within CORRIDOR yd) is a black point.
function M.note_replan(px, py, pz, gx, gy)
    if not (R.finite(px) and R.finite(py) and R.finite(gx) and R.finite(gy)) then return nil end
    if M.quiet() then return nil end
    local map, inst, ind = M.ctx()
    local sk = set_key(map, inst, ind)
    local mx, my = (px + gx) / 2, (py + gy) / 2
    local c = corridor
    if c and c.set == sk and R.dist2(c.mx, c.my, mx, my) <= M.CORRIDOR then
        corridor = nil
        return M.note_stuck(px, py, pz, "the same corridor re-planned twice")
    end
    corridor = { set = sk, mx = mx, my = my }
    return nil
end

local function credit(map, inst, ind, k, r, why)
    r.ok = r.ok + 1
    local now = M.server_time()
    if now > 0 then r.seen = now end
    passing[r] = nil
    if r.ok > r.fail then
        black_set(map, inst, ind)[k] = nil
        R.trail("nav", "nav memory: black point (%d, %d, %d) cleared - %s", r.cx, r.cy, r.cz, why)
    else
        r.radius = clamp_r(r.fail, r.ok)
    end
    if r.seen > 0 then mark(map, inst) end
end

local valid_tick                 -- 1.0.14 (below)

--- On the update tick while a (non-combat) walk runs: a walk that comes within
--- 3 yd of a black cell and then gets PROGRESS yd past it counts ok; 1.0.14:
--- a walk past an active stuck area is captured as a valid path.
function M.tick(px, py, pz)
    if not (R.finite(px) and R.finite(py)) then return end
    if M.quiet() then return end
    local map, inst, ind = M.ctx()
    valid_tick(px, py, pz)
    if ind == 1 then return end                            -- 1.0.17: an indoor stuck area stays
    local s = black[set_key(map, inst, ind)]
    if not s then return end
    for k, r in pairs(s) do
        local dx, dy = r.cx - px, r.cy - py
        local d2 = dx * dx + dy * dy
        if d2 < M.PASS_R2 then
            passing[r] = true
        elseif passing[r] and d2 >= (3 + M.PROGRESS) * (3 + M.PROGRESS) then
            credit(map, inst, ind, k, r, "a walk got through it")
        end
    end
end

local commit_valid               -- 1.0.14 (below)

--- The walk ended: arrived (the black points it passed count ok) or not.
--- 1.0.14: an arrived walk keeps the valid path being captured; any other end
--- (a BLACK code, a server code, N.stop) drops it.
function M.walk_ended(arrived)
    if vbuf then
        if arrived and not M.quiet() then
            local px, py, pz = R.here()
            if px then vbuf.raw[#vbuf.raw + 1] = { x = px, y = py, z = pz } end
            commit_valid("the walk arrived")
        else
            vbuf = nil
        end
    end
    if arrived and not M.quiet() then
        local map, inst, ind = M.ctx()
        local s = ind ~= 1 and black[set_key(map, inst, ind)] or nil     -- 1.0.17: indoor areas stay
        if s then
            for k, r in pairs(s) do if passing[r] then credit(map, inst, ind, k, r, "a walk past it arrived") end end
        end
    end
    passing = {}
end

--- The active black points of the current set (a list).
local function active_list()
    local map, inst, ind = M.ctx()
    M.load(map, inst)
    local out = {}
    for _, r in pairs(black[set_key(map, inst, ind)] or {}) do if active(r) then out[#out + 1] = r end end
    return out
end
M.active_points = active_list -- bounded, current map/instance/indoor context only
local function hit(list, x, y)
    for i = 1, #list do if inside(list[i], x, y) then return list[i] end end
    return nil
end

--- The active black point under (x, y) in the current set, or nil.
function M.black_at(x, y) return hit(active_list(), x, y) end

--- True when the goal's own cell is an active black point.
function M.goal_blocked(x, y, z)
    if not (R.finite(x) and R.finite(y) and R.finite(z)) then return false end
    local map, inst, ind = M.ctx()
    M.load(map, inst)
    local s = black[set_key(map, inst, ind)]
    local cf = cell_for(ind)                                -- 1.0.17
    local r = s and s[cell_key(cf(x), cf(y), cf(z))]
    return r ~= nil and active(r)
end

--- `points` without the waypoints inside an active black point (the first
--- point - where the player stands - and the last, the goal, are kept); the
--- number dropped.
--- 1.0.23: `except` - the stuck disk a valid path was saved for (its walked
--- line through that disk is kept; other disks still drop their points).
function M.filter(points, except)
    if type(points) ~= "table" then return points, 0 end
    local out, dropped = {}, 0
    local A = active_list()
    if except then
        local B2 = {}
        for i = 1, #A do if A[i] ~= except then B2[#B2 + 1] = A[i] end end
        A = B2
    end
    if #A == 0 then return points, 0 end
    for i, q in ipairs(points) do
        if i > 1 and i < #points and type(q) == "table" and q.x and hit(A, q.x, q.y) then
            dropped = dropped + 1
        else
            out[#out + 1] = q
        end
    end
    return out, dropped
end

--- The first active black point the list passes through (past its start, short
--- of its goal): rec, index.
function M.first_black(points)
    if type(points) ~= "table" then return nil end
    local A = active_list()
    if #A == 0 then return nil end
    for i = 2, #points - 1 do
        local q = points[i]
        if type(q) == "table" and q.x then
            local r = hit(A, q.x, q.y)
            if r then return r, i end
        end
    end
    return nil
end

--- A point OFF_YD beyond the black disk, square to the path at index i.
function M.off_point(r, points, i)
    local a = points[math.max(1, i - 1)]
    local b = points[math.min(#points, i + 1)]
    local dx, dy = b.x - a.x, b.y - a.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.01 then dx, dy, len = 1, 0, 1 end
    local nx, ny = -dy / len, dx / len
    local d = r.radius + M.OFF_YD
    return { x = r.cx + nx * d, y = r.cy + ny * d, z = points[i].z }
end

-- ----------------------------------------------------------------------------
-- valid paths (1.0.14)
-- ----------------------------------------------------------------------------
--- 1.10.0: a movement/nav read (N.busy / N.path_points / N.path_index), or nil.
local function nread(name)
    local N = nav()
    if type(N) ~= "table" or type(N[name]) ~= "function" then return nil end
    local ok, v = pcall(N[name])
    if ok then return v end
    return nil
end
local function finite_pt(q)
    return type(q) == "table" and R.finite(q.x) and R.finite(q.y) and R.finite(q.z)
end
--- The walk's goal (N.destination) and the flat distance from (px, py) to it.
local function goal_of(px, py)
    local N = nav()
    if type(N) ~= "table" or type(N.destination) ~= "function" then return nil end
    local ok, dx, dy, dz = pcall(N.destination)
    if not ok or not (R.finite(dx) and R.finite(dy)) then return nil end
    return R.dist2(px, py, dx, dy), dx, dy, dz
end
local function nears(r, x, y, z)
    return R.dist2(r.cx, r.cy, x, y) <= r.radius + M.VALID_NEAR
        and math.abs((tonumber(z) or r.cz) - r.cz) <= M.VALID_DZ
end
local function add_raw(b, q)
    local raw = b.raw
    local last = raw[#raw]
    if last and R.dist2(last.x, last.y, q.x, q.y) < 1 then return end
    if #raw >= M.MAX_RAW then table.remove(raw, 2) end    -- the first point stays
    raw[#raw + 1] = { x = q.x, y = q.y, z = q.z }
end

--- Keep the captured corridor: thinned (M.thin), no point in an active stuck
--- disk, keyed by the stuck cell + the approach bin of its first point.
--- 1.0.17: the same 2 yd cells, point for point.
local function same_cells(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if M.cell_in(a[i].x) ~= M.cell_in(b[i].x) or M.cell_in(a[i].y) ~= M.cell_in(b[i].y) then return false end
    end
    return true
end

--- Keep a walked point list as a valid path keyed by the cell (cx, cy, cz) +
--- the approach bin of its first point: thinned (M.thin), no point in an
--- active stuck disk, at least 2 points. Outdoors the same cell + bin is
--- replaced and the set capped; 1.0.17 indoors the list is APPENDED (the same
--- cells as a stored one keep the stored one) and nothing is evicted.
--- 1.0.23: the walked samples VALID_GAP yd apart, the first and last kept,
--- the gap never widened (a corridor is short).
local function space_valid(raw)
    local out = { { x = raw[1].x, y = raw[1].y, z = raw[1].z } }
    local last = raw[1]
    for i = 2, #raw - 1 do
        local q = raw[i]
        if R.dist2(last.x, last.y, q.x, q.y) >= M.VALID_GAP then
            out[#out + 1] = { x = q.x, y = q.y, z = q.z }
            last = q
        end
    end
    local q = raw[#raw]
    out[#out + 1] = { x = q.x, y = q.y, z = q.z }
    return out
end
M._space_valid = space_valid

local function store_valid(map, inst, ind, raw, cx, cy, cz, why, what)
    if type(raw) ~= "table" or #raw < 2 then return nil end
    local pts = space_valid(raw)                           -- 1.0.23: no M.thin (8 yd) for a valid path
    -- 1.0.23: the disk this path was saved for (the stuck cell) keeps its
    -- points - the walked line through it; other active disks drop theirs
    local own = (black[set_key(map, inst, ind)] or {})[cell_key(cx, cy, cz)]
    local A = {}
    for _, r in pairs(black[set_key(map, inst, ind)] or {}) do if active(r) and r ~= own then A[#A + 1] = r end end
    local kept = {}
    for _, q in ipairs(pts) do if not hit(A, q.x, q.y) then kept[#kept + 1] = q end end
    if #kept < 2 then
        R.trail("nav", "nav memory: %s (%d, %d) not kept - fewer than 2 points outside stuck areas", what, cx, cy)
        return nil
    end
    local bin = M.bin(kept[1].x, kept[1].y, cx, cy)
    local s = valid_set(map, inst, ind)
    if ind == 1 then
        for _, v in ipairs(s) do
            if same_cells(v.points, kept) then
                R.trail("nav", "nav memory: %s (%d, %d) bin %d - the same route is stored, kept as it is", what, cx, cy, bin)
                return v
            end
        end
    else
        for i = #s, 1, -1 do
            local v = s[i]
            if v.cx == cx and v.cy == cy and v.cz == cz and v.bin == bin then table.remove(s, i) end
        end
        if #s >= M.MAX_VALID then
            local oi, os = 1, nil
            for i, v in ipairs(s) do if os == nil or v.seen < os then oi, os = i, v.seen end end
            table.remove(s, oi)
        end
    end
    local now = M.server_time()
    local rec = { map = map, inst = inst, ind = ind, cx = cx, cy = cy, cz = cz, bin = bin,
        seen = now > 0 and now or 0, points = kept }
    s[#s + 1] = rec
    if ind == 1 or rec.seen > 0 then mark(map, inst) end
    R.trail("nav", "nav memory: %s (%d, %d, %d) bin %d kept - %d points (%s)", what, cx, cy, cz, bin, #kept, tostring(why))
    return rec
end

commit_valid = function(why)
    local b = vbuf
    vbuf = nil
    if not b or #b.raw < 2 then return nil end
    if b.kind == "route" then
        -- 1.0.17: an indoor walk that arrived - the whole walked route, keyed by its goal cell
        return store_valid(b.map, b.inst, 1, b.raw, M.cell_in(b.dx), M.cell_in(b.dy), M.cell_in(b.dz or 0), why,
            "indoor route to")
    end
    local r = b.rec
    return store_valid(b.map, b.inst, b.ind, b.raw, r.cx, r.cy, r.cz, why, "valid path past the stuck area")
end

--- 1.0.17: the INDOOR capture - every indoor walk from its start; each stuck
--- area it nears and then clears is kept as a corridor of its own, the whole
--- route when the walk arrives (M.walk_ended).
local function indoor_tick(px, py, pz, path, idx, d, dx, dy, dz, here, map, inst)
    local b = vbuf
    if b and b.kind ~= "route" then vbuf, b = nil, nil end
    if b and R.dist2(b.dx, b.dy, dx, dy) > M.VALID_GAIN then
        R.trail("nav", "nav memory: indoor route not kept - the walk's goal changed")
        vbuf, b = nil, nil
    end
    if not b then
        if not R.finite(pz) then return end
        vbuf = { kind = "route", d0 = d, dx = dx, dy = dy, dz = R.finite(dz) and dz or pz, idx = idx, raw = {},
            map = map, inst = inst, ind = 1, near = {} }
        add_raw(vbuf, here)
        return
    end
    if idx < b.idx then b.idx = idx end
    for i = b.idx, idx - 1 do
        if finite_pt(path[i]) then add_raw(b, path[i]) end
    end
    b.idx = idx
    if R.finite(pz) then add_raw(b, here) end
    for _, r in pairs(black[set_key(map, inst, 1)] or NO_SET) do
        if active(r) then
            local nr = b.near[r]
            if nr == nil then
                if d > R.dist2(r.cx, r.cy, dx, dy) and nears(r, px, py, pz) then
                    -- the corridor starts at a walked point outside the disk, VALID_BACK yd before
                    local i0 = #b.raw
                    for i = #b.raw, 1, -1 do
                        local q = b.raw[i]
                        if R.dist2(q.x, q.y, px, py) > M.VALID_BACK then break end
                        if not inside(r, q.x, q.y) then i0 = i end
                    end
                    b.near[r] = { i0 = i0, d0 = d }
                    R.trail("nav", "nav memory: indoors, nearing the stuck area (%d, %d, %d) - capturing the way past it",
                        r.cx, r.cy, r.cz)
                end
            elseif nr and R.dist2(r.cx, r.cy, px, py) >= r.radius + M.VALID_CLEAR
                and d < R.dist2(r.cx, r.cy, dx, dy) and d <= nr.d0 - M.VALID_GAIN then
                local sub = {}
                for i = math.min(nr.i0, #b.raw), #b.raw do sub[#sub + 1] = b.raw[i] end
                store_valid(map, inst, 1, sub, r.cx, r.cy, r.cz, "cleared the area", "valid path past the stuck area")
                b.near[r] = false
            end
        end
    end
end

local here_buf = { x = 0, y = 0, z = 0 }      -- 1.0.27: valid_tick's player point (refilled each call)

--- The capture, on the update tick (M.tick) while a non-combat walk runs.
valid_tick = function(px, py, pz)
    local N = nav()
    if type(N) == "table" and type(N.mode) == "function" then
        local okm, m = pcall(N.mode)
        if okm and m == "combat" then vbuf = nil return end
    end
    if nread("busy") ~= true then return end
    local path = nread("path_points")
    if type(path) ~= "table" then path = {} end
    local idx = tonumber(nread("path_index"))
    idx = (idx and idx >= 1) and math.floor(idx) or 1
    local d, dx, dy, dz = goal_of(px, py)
    if not d then return end
    -- 1.0.27 (audit): one reused point, not a table per frame - add_raw copies
    -- its fields and nothing keeps `here` itself
    local here = here_buf
    here.x, here.y, here.z = px, py, pz
    local map0, inst0, ind0 = M.ctx()
    if ind0 == 1 then return indoor_tick(px, py, pz, path, idx, d, dx, dy, dz, here, map0, inst0) end   -- 1.0.17
    if vbuf and vbuf.kind == "route" then vbuf = nil end   -- out of the building: the indoor route ends
    local b = vbuf
    if b then
        -- another goal: not the walk that is getting past the area
        if R.dist2(b.dx, b.dy, dx, dy) > M.VALID_GAIN then
            R.trail("nav", "nav memory: valid path past (%d, %d) not kept - the walk's goal changed", b.rec.cx, b.rec.cy)
            vbuf = nil
            return
        end
        if idx < b.idx then b.idx = idx end                -- a fresh path: its index starts again
        for i = b.idx, idx - 1 do
            if finite_pt(path[i]) then add_raw(b, path[i]) end
        end
        b.idx = idx
        if R.finite(pz) then add_raw(b, here) end
        local r = b.rec
        -- cleared: radius + VALID_CLEAR yd from the cell, PAST it (nearer the goal
        -- than the cell is) and VALID_GAIN yd nearer the goal than at the start
        if R.dist2(r.cx, r.cy, px, py) >= r.radius + M.VALID_CLEAR and d < R.dist2(r.cx, r.cy, dx, dy)
            and d <= b.d0 - M.VALID_GAIN then
            commit_valid("cleared the area")
        end
        return
    end
    if not R.finite(pz) then return end
    -- 1.9.2: the set itself, not an active_list() table per frame
    for _, r in pairs(black[set_key(map0, inst0, ind0)] or NO_SET) do
        local near_at = nil
        if not active(r) then
            -- an inactive black point is no stuck area
        elseif d < R.dist2(r.cx, r.cy, dx, dy) then
            -- already past this area (nearer the goal than it is): not an approach
        elseif nears(r, px, py, pz) then
            near_at = here
        else
            local walked, lx, ly = 0, px, py
            for i = idx, #path do
                local q = path[i]
                if finite_pt(q) then
                    walked = walked + R.dist2(lx, ly, q.x, q.y)
                    if walked > M.VALID_AHEAD then break end
                    lx, ly = q.x, q.y
                    if nears(r, q.x, q.y, q.z) then near_at = q break end
                end
            end
        end
        if near_at then
            -- the first point: a walked one outside the disk, within VALID_BACK
            -- yd before the near point; else the player
            local first = nil
            for i = idx - 1, 1, -1 do
                local q = path[i]
                if finite_pt(q) then
                    if R.dist2(q.x, q.y, near_at.x, near_at.y) > M.VALID_BACK then break end
                    if not inside(r, q.x, q.y) then first = q break end
                end
            end
            local map, inst, ind = M.ctx()
            vbuf = { rec = r, d0 = d, dx = dx, dy = dy, idx = idx, raw = {}, map = map, inst = inst, ind = ind }
            add_raw(vbuf, first or here)
            add_raw(vbuf, here)
            R.trail("nav", "nav memory: nearing the stuck area (%d, %d, %d) r %d - capturing the way past it",
                r.cx, r.cy, r.cz, r.radius)
            return
        end
    end
end

--- 1.0.14: a valid path past the first active stuck area that `points` (or,
--- with no points, the straight line from the player (px, py) to the goal
--- (gx, gy)) passes: the same stuck cell, the approach bin of the player seen
--- from the cell (M.bin, as the key), clean of active disks, a point within
--- VALID_PICKUP yd of the player. Returns the trimmed point list (`pickup` =
--- nav's pickup_index), the corridor record and the stuck record.
--- 1.0.17 INDOORS: the stored indoor valid path the player stands near
--- (a point within START_NEAR yd) that, from there, reaches toward the goal -
--- its end within GOAL_NEAR yd of it, or VALID_GAIN yd nearer than the player
--- is - and has no point in an active stuck disk. The nearest end to the goal
--- wins (the newer on a tie). Returns the trimmed list, the record, the record.
local function find_valid_in(s, px, py, gx, gy, pickup)
    if not (R.finite(gx) and R.finite(gy)) then return nil end
    local A = active_list()
    local dp = R.dist2(px, py, gx, gy)
    local best, best_e = nil, nil
    local bset = black[set_key(M.ctx())] or {}
    for _, v in ipairs(s) do
        -- 1.0.23: the disk it was saved for does not reject it
        local own = bset[cell_key(v.cx, v.cy, v.cz)]
        local clean = true
        for _, q in ipairs(v.points) do
            local h = hit(A, q.x, q.y)
            if h and h ~= own then clean = false break end
        end
        if clean then
            local ni, nd = nil, nil
            for i, q in ipairs(v.points) do
                local dd = R.dist2(px, py, q.x, q.y)
                if nd == nil or dd < nd then ni, nd = i, dd end
            end
            local last = v.points[#v.points]
            local de = R.dist2(last.x, last.y, gx, gy)
            if nd and nd <= M.START_NEAR and ni < #v.points and (de <= M.GOAL_NEAR or de <= dp - M.VALID_GAIN)
                and (best == nil or de < best_e or (de == best_e and v.seen > best.seen)) then
                best, best_e = v, de
            end
        end
    end
    if not best then return nil end
    local from = 1
    -- 1.0.21: `pickup` here is nav's front_index (the waypoint in front); the
    -- stored path itself is never changed - only where follow_path begins
    if type(pickup) == "function" then from = pickup(best.points, 1, #best.points) end
    local out = {}
    for i = from, #best.points do
        local q = best.points[i]
        out[#out + 1] = { x = q.x, y = q.y, z = q.z }
    end
    if #out < 2 then return nil end
    -- 1.0.23: the third return is the stuck disk it was saved for (nil: a route)
    local own = bset[cell_key(best.cx, best.cy, best.cz)]
    return out, best, (own and active(own)) and own or nil
end

--- 1.0.21: `front` (nav's front_index) trims an INDOOR saved path; outdoors
--- `pickup` (pickup_index) as before.
function M.find_valid(points, px, py, gx, gy, pickup, front)
    if not (R.finite(px) and R.finite(py)) then return nil end
    local map, inst, ind = M.ctx()
    M.load(map, inst)
    local s = valid[set_key(map, inst, ind)]
    if not s or #s == 0 then return nil end
    if ind == 1 then return find_valid_in(s, px, py, gx, gy, front or pickup) end     -- 1.0.17 / 1.0.21
    local A = active_list()
    if #A == 0 then return nil end
    local r = nil
    if type(points) == "table" then r = M.first_black(points) end
    if not r and type(points) ~= "table" and R.finite(gx) and R.finite(gy) then
        local vx, vy = gx - px, gy - py
        local L = vx * vx + vy * vy
        local bd = nil
        for _, a in ipairs(A) do
            local t = L > 0 and (((a.cx - px) * vx + (a.cy - py) * vy) / L) or 0
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local ex, ey = px + t * vx - a.cx, py + t * vy - a.cy
            if ex * ex + ey * ey <= a.radius * a.radius and (bd == nil or t < bd) then r, bd = a, t end
        end
    end
    if not r then return nil end
    local want = M.bin(px, py, r.cx, r.cy)
    local best, bd = nil, nil
    for _, v in ipairs(s) do
        if v.cx == r.cx and v.cy == r.cy and v.cz == r.cz and v.bin == want then
            -- 1.0.23: its own disk (r) does not reject it; another active disk does
            local clean = true
            for _, q in ipairs(v.points) do
                local h = hit(A, q.x, q.y)
                if h and h ~= r then clean = false break end
            end
            if clean then
                local nd = nil
                for _, q in ipairs(v.points) do
                    local dd = R.dist2(px, py, q.x, q.y)
                    if nd == nil or dd < nd then nd = dd end
                end
                if nd and nd <= M.VALID_PICKUP and (best == nil or v.seen > best.seen or (v.seen == best.seen and nd < bd)) then
                    best, bd = v, nd
                end
            end
        end
    end
    if not best then return nil end
    local from = 1
    if type(pickup) == "function" then from = pickup(best.points, 1, #best.points) end
    local out = {}
    for i = from, #best.points do
        local q = best.points[i]
        out[#out + 1] = { x = q.x, y = q.y, z = q.z }
    end
    if #out < 2 then return nil end
    return out, best, r
end

--- 1.0.23: does the leg a-b come within radius + VALID_NEAR yd of an active
--- stuck disk of the current set?
function M.near_stuck(ax, ay, bx, by)
    local A = active_list()
    for _, r in ipairs(A) do
        local vx, vy = bx - ax, by - ay
        local L = vx * vx + vy * vy
        local t = L > 0 and (((r.cx - ax) * vx + (r.cy - ay) * vy) / L) or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local dx, dy = ax + t * vx - r.cx, ay + t * vy - r.cy
        local R2 = r.radius + M.VALID_NEAR
        if dx * dx + dy * dy <= R2 * R2 then return true end
    end
    return false
end

--- 1.0.14: forget a valid path (its follow_path ended with a BLACK code).
function M.drop_valid(rec)
    if type(rec) ~= "table" then return end
    if rec.ind == 1 then                                   -- 1.0.17: an indoor valid path is never removed
        R.trail("nav", "nav memory: indoor valid path (%d, %d) bin %d failed this walk - kept (indoor paths are never dropped)",
            rec.cx, rec.cy, rec.bin)
        return
    end
    local s = valid[set_key(rec.map, rec.inst, rec.ind)]
    if not s then return end
    for i = #s, 1, -1 do
        if s[i] == rec then
            table.remove(s, i)
            mark(rec.map, rec.inst)
            R.trail("nav", "nav memory: valid path past (%d, %d) bin %d dropped - it failed", rec.cx, rec.cy, rec.bin)
        end
    end
end

--- 1.0.14: is a corridor being captured (tests / diagnostics)?
function M.capturing() return vbuf ~= nil end

-- ----------------------------------------------------------------------------
-- good paths
-- ----------------------------------------------------------------------------
--- Thin the walked list: the point nearest `start`, then about POINT_GAP yd
--- apart, then the goal; at most MAX_POINTS.
function M.thin(points, start)
    local n = #points
    local first = 1
    if start and start.x then
        local bd
        for i = 1, n do
            local d = R.dist2(start.x, start.y, points[i].x, points[i].y)
            if bd == nil or d < bd then first, bd = i, d end
        end
    end
    if first >= n then first = math.max(1, n - 1) end
    local function pass(gap)
        local out = { points[first] }
        local last = points[first]
        for i = first + 1, n - 1 do
            if R.dist2(last.x, last.y, points[i].x, points[i].y) >= gap then
                out[#out + 1] = points[i]
                last = points[i]
            end
        end
        out[#out + 1] = points[n]
        return out
    end
    local gap, out = M.POINT_GAP, nil
    repeat
        out = pass(gap)
        gap = gap * 1.5
    until #out <= M.MAX_POINTS
    local copy = {}
    for i, q in ipairs(out) do copy[i] = { x = q.x, y = q.y, z = q.z } end
    return copy
end

--- A follow_path to `goal` arrived (not a false arrival): remember `points`
--- (the list handed to follow_path); `start` = the player at the walk's start.
function M.note_good(goal, points, start)
    local gx, gy, gz = R.xyz(goal)
    if not gx or type(points) ~= "table" or #points < 2 then return nil end
    if M.quiet() then return nil end
    for _, q in ipairs(points) do
        if type(q) ~= "table" or not (R.finite(q.x) and R.finite(q.y) and R.finite(q.z)) then return nil end
    end
    local map, inst, ind = M.ctx()
    M.load(map, inst)
    local pts = M.thin(points, start)
    if #pts < 2 then return nil end
    local A = active_list()
    for _, q in ipairs(pts) do if hit(A, q.x, q.y) then return nil end end
    local now = M.server_time()
    local cx, cy, cz = M.cell(gx), M.cell(gy), M.cell(gz)
    local s = path_set(map, inst, ind)
    -- the same goal cell from about the same start: replaced
    for i = #s, 1, -1 do
        local p = s[i]
        if p.cx == cx and p.cy == cy and p.cz == cz
            and R.dist2(p.points[1].x, p.points[1].y, pts[1].x, pts[1].y) <= M.GOAL_NEAR then
            table.remove(s, i)
        end
    end
    if #s >= M.MAX_PATHS then
        local oi, os = 1, nil
        for i, p in ipairs(s) do if os == nil or p.seen < os then oi, os = i, p.seen end end
        table.remove(s, oi)
    end
    local rec = { map = map, inst = inst, ind = ind, cx = cx, cy = cy, cz = cz, seen = now > 0 and now or 0, points = pts }
    s[#s + 1] = rec
    if rec.seen > 0 then mark(map, inst) end
    return rec
end

--- A good path for the goal (x, y, z) from the player at (px, py): its goal
--- cell within GOAL_NEAR yd, no point in an active black point, passing within
--- START_NEAR yd of the player. Returns the trimmed point list (from the point
--- nearest the player, as pickup_index trims a route) and the record.
function M.find_good(x, y, z, px, py, pickup)
    if not (R.finite(x) and R.finite(y) and R.finite(px) and R.finite(py)) then return nil end
    local map, inst, ind = M.ctx()
    M.load(map, inst)
    local s = paths[set_key(map, inst, ind)]
    if not s then return nil end
    local best, bd, bi = nil, nil, nil
    local A = active_list()
    for _, p in ipairs(s) do
        if R.dist2(p.cx, p.cy, x, y) <= M.GOAL_NEAR and math.abs(p.cz - (z or p.cz)) <= M.GOAL_NEAR then
            local clean = true
            for _, q in ipairs(p.points) do if hit(A, q.x, q.y) then clean = false break end end
            if clean then
                local ni, nd = nil, nil
                for i, q in ipairs(p.points) do
                    local d = R.dist2(px, py, q.x, q.y)
                    if nd == nil or d < nd then ni, nd = i, d end
                end
                if nd and nd <= M.START_NEAR and (bd == nil or nd < bd) then best, bd, bi = p, nd, ni end
            end
        end
    end
    if not best then return nil end
    local from = bi
    if type(pickup) == "function" then from = pickup(best.points, 1, #best.points) end
    local out = {}
    for i = from, #best.points do
        local q = best.points[i]
        out[#out + 1] = { x = q.x, y = q.y, z = q.z }
    end
    if #out < 2 then return nil end
    return out, best
end

--- Forget a good path (it failed with a black-point code).
function M.drop_path(rec)
    if type(rec) ~= "table" then return end
    local s = paths[set_key(rec.map, rec.inst, rec.ind)]
    if not s then return end
    for i = #s, 1, -1 do
        if s[i] == rec then
            table.remove(s, i)
            mark(rec.map, rec.inst)
            R.trail("nav", "nav memory: good path to (%d, %d) dropped - it failed", rec.cx, rec.cy)
        end
    end
end

--- Tests / diagnostics.
function M.counts()
    local map, inst, ind = M.ctx()
    local nb = 0
    for _ in pairs(black[set_key(map, inst, ind)] or {}) do nb = nb + 1 end
    return nb, #(paths[set_key(map, inst, ind)] or {}), #(valid[set_key(map, inst, ind)] or {})
end
function M.reset_all()
    black, paths, loaded, dirty, passing, paused, corridor = {}, {}, {}, {}, {}, {}, nil
    valid, vbuf, ep_token, ep_cells, recent = {}, nil, nil, {}, {}
    keep_v2 = {}
    folder_ok, last_write = false, -1e9
    indoor.t = -1e9
end

return M
