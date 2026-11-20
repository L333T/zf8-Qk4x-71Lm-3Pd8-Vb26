-- ============================================================================
-- Master Farmer - Zygor Forever
-- Action log: one JSON object per line, written for Claude to read
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Folder: Zygor_Forever
-- ============================================================================
-- This replaces errorlog's text log, debuglog's debug file and every logging
-- checkbox. Everything the bot does that is worth knowing is an EVENT:
--
--     {"n":42,"t":812.31,"ts":"09:14:02","cat":"quest","ev":"goal","msg":"kill 5/6 ...","d":{...}}
--
--   n    sequence number inside the session (gaps never happen; a dropped
--        event is reported by a "dropped" event instead)
--   t    game seconds (core.time) - the same clock every module uses
--   ts   local wall time, to line a log up with a screenshot or the console
--   cat  which part of the bot: nav, quest, combat, loot, rest, vendor, death,
--        gui, guide, log, error, ...
--   ev   what happened inside that part (goal, walk, stuck, accept, error, ...)
--   msg  a one-line sentence for humans
--   d    structured detail (numbers, ids, names) - the part to compute on
--
-- File: scripts_log/mfz_actions/session_<date>_<time>.jsonl. Line 1 is the
-- header (schema, product, version, how to read the file), the last line is
-- the "session_end" summary. A session rolls into _part2, _part3 ... after
-- MAX_LINES lines, so a long run never goes quiet.
--
-- FOR CLAUDE: give it the whole file (or the lines around an "error" /
-- "stuck" / "stall" / "mark" event). Every error event carries the traceback,
-- the bot's context snapshot (position, map, step, goal, target, hp/mana) and
-- the last stages it passed through; every 15 s a "state" event repeats the
-- snapshot so the timeline can be rebuilt without guessing.
--
-- COST. Lines are buffered and written together at most every FLUSH_GAP
-- seconds (one native call), an error flushes at once, repeated identical
-- events collapse into a count, and each category is rate limited. Nothing
-- here throws: a failed write turns the log off for the session.
-- ============================================================================

local actlog = {}

local FOLDER = "mfz_actions"
local SCHEMA = 1
local MAX_LINES = 6000          -- lines per file
local FLUSH_GAP = 2.0           -- seconds between writes
local STATE_GAP = 15.0          -- seconds between "state" snapshots while running
local DUP_WINDOW = 2.0          -- identical events inside this collapse into a count
local RATE_PER_S = 25           -- events per category per second before dropping
local MAX_DEPTH, MAX_ITEMS, MAX_STR = 4, 40, 400
local STAGES = 48               -- probe stages kept for error snapshots

local state = {
    opened = false, disabled = false, path = nil, base = nil, part = 1, lines = 0,
    seq = 0, buf = {}, buf_n = 0, last_flush = -1e9, last_state = -1e9,
    dup = nil,                 -- { key, count, cat, ev, msg, first_t }
    rate = {},                 -- cat -> { sec, n, dropped }
    counts = {}, errors = 0, warns = 0, marks = 0,
    seen_err = {}, seen_err_n = 0,
    stage_ring = {}, stage_n = 0, stage_head = 0,
    ctx_fn = nil, env_fn = nil, extra_fn = nil,
    meta = {}, started_t = nil,
    stopped = false,
}

-- ----------------------------------------------------------------------------
-- small helpers (nothing here may throw)
-- ----------------------------------------------------------------------------
local function now_s()
    local ok, t = pcall(function() return core.time() end)
    if ok and type(t) == "number" then return t end
    return 0
end

local function wall()
    local ok, t = pcall(function() return core.get_local_time() end)
    if ok and type(t) == "table" then
        return string.format("%02d:%02d:%02d", tonumber(t.hour) or 0, tonumber(t.minute) or 0, tonumber(t.second) or 0),
            string.format("%04d-%02d-%02d", tonumber(t.year) or 0, tonumber(t.month) or 0, tonumber(t.day) or 0)
    end
    return "??:??:??", "????-??-??"
end

--- Text without WoW escape codes (colours, textures, links), so a line reads as plain text.
local function clean(s)
    if type(s) ~= "string" then return s end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[%w_]+:", "")
    s = s:gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h", ""):gsub("|h", "")
    return s
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function jstr(s)
    s = clean(s)
    if #s > MAX_STR then s = s:sub(1, MAX_STR) .. "..." end
    s = s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end)
    return '"' .. s .. '"'
end

local function jnum(n)
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
    local s = string.format("%.3f", n)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s
end

local encode
encode = function(v, depth)
    local t = type(v)
    if t == "string" then return jstr(v) end
    if t == "number" then return jnum(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "nil" then return "null" end
    if t == "table" then
        if depth >= MAX_DEPTH then return '"<depth>"' end
        local n = #v
        local out, count = {}, 0
        if n > 0 then
            for i = 1, math.min(n, MAX_ITEMS) do
                out[#out + 1] = encode(v[i], depth + 1)
            end
            if n > MAX_ITEMS then out[#out + 1] = jstr("<+" .. (n - MAX_ITEMS) .. " more>") end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do
            if type(k) == "string" or type(k) == "number" then keys[#keys + 1] = tostring(k) end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            count = count + 1
            if count > MAX_ITEMS then out[#out + 1] = jstr("_more") .. ":true" break end
            local val = v[k]
            if val == nil then val = v[tonumber(k)] end
            if type(val) ~= "function" and type(val) ~= "userdata" and type(val) ~= "thread" then
                out[#out + 1] = jstr(k) .. ":" .. encode(val, depth + 1)
            end
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return jstr("<" .. t .. ">")
end
actlog.encode = function(v) return encode(v, 0) end

-- ----------------------------------------------------------------------------
-- file
-- ----------------------------------------------------------------------------
local function open()
    if state.opened then return state.path ~= nil end
    state.opened = true
    if type(core) ~= "table" or type(core.write_log_file) ~= "function" then
        state.disabled = true
        return false
    end
    pcall(function() core.create_log_folder(FOLDER) end)
    local ts, date = wall()
    local stamp = (date .. "_" .. ts):gsub(":", "-")
    state.base = FOLDER .. "/session_" .. stamp
    state.path = state.base .. ".jsonl"
    pcall(function() core.create_log_file(state.path) end)
    return true
end

local function write_raw(text)
    if state.disabled or not text or text == "" then return end
    if not open() then return end
    local ok = pcall(core.write_log_file, state.path, text)
    if not ok then state.disabled = true end
end

local function roll_over()
    state.part = state.part + 1
    local nxt = state.base .. "_part" .. state.part .. ".jsonl"
    local ok = pcall(function() core.create_log_file(nxt) end)
    if not ok then return false end
    write_raw(encode({ n = state.seq, cat = "log", ev = "continues", d = { file = nxt } }, 0) .. "\n")
    state.path = nxt
    state.lines = 0
    return true
end

local function flush(force)
    if state.buf_n == 0 then return end
    local t = now_s()
    if not force and (t - state.last_flush) < FLUSH_GAP and t >= state.last_flush then return end
    state.last_flush = t
    local body = table.concat(state.buf, "\n", 1, state.buf_n) .. "\n"
    state.buf, state.buf_n = {}, 0
    write_raw(body)
end
actlog.flush = flush

local function push(line)
    if state.disabled then return end
    if state.lines >= MAX_LINES then
        flush(true)
        if not roll_over() then return end
    end
    state.lines = state.lines + 1
    state.buf_n = state.buf_n + 1
    state.buf[state.buf_n] = line
end

-- ----------------------------------------------------------------------------
-- switches (the GUI owns them; no gui yet = on, quiet)
-- ----------------------------------------------------------------------------
local function gui_flag(id, default)
    local g = package.loaded["gui"]
    if type(g) == "table" and type(g.is_on) == "function" then
        local ok, v = pcall(g.is_on, id)
        if ok and v ~= nil then return v == true end
    end
    return default
end

--- The action log is on unless the GUI box says otherwise.
function actlog.enabled() return not state.disabled and gui_flag("actlog", true) end
--- Verbose adds the per-tick stage trail and the debug lines of the movement / rest gates.
function actlog.verbose() return actlog.enabled() and gui_flag("actlog_verbose", false) end

-- ----------------------------------------------------------------------------
-- events
-- ----------------------------------------------------------------------------
local function emit_line(cat, ev, msg, d, extra)
    state.seq = state.seq + 1
    local ts = wall()
    local o = { n = state.seq, t = tonumber(string.format("%.2f", now_s())), ts = ts, cat = cat, ev = ev }
    if msg ~= nil then o.msg = msg end
    if d ~= nil then o.d = d end
    if extra then for k, v in pairs(extra) do o[k] = v end end
    -- fixed key order for the first fields keeps lines easy to scan
    local head = string.format('{"n":%d,"t":%s,"ts":%s,"cat":%s,"ev":%s', o.n, jnum(o.t), jstr(ts), jstr(cat), jstr(ev))
    if o.msg ~= nil then head = head .. ',"msg":' .. jstr(tostring(o.msg)) end
    if o.d ~= nil then head = head .. ',"d":' .. encode(o.d, 1) end
    if extra then
        local keys = {}
        for k in pairs(extra) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do head = head .. "," .. jstr(k) .. ":" .. encode(extra[k], 1) end
    end
    push(head .. "}")
    state.counts[cat] = (state.counts[cat] or 0) + 1
end

local function close_dup()
    local d = state.dup
    if d and d.count > 1 then
        emit_line("log", "repeated", d.msg, { of = d.cat .. "/" .. d.ev, times = d.count, first_t = d.first_t })
    end
    state.dup = nil
end

local function rate_ok(cat)
    local r = state.rate[cat]
    local sec = math.floor(now_s())
    if not r or r.sec ~= sec then
        if r and r.dropped > 0 then
            emit_line("log", "dropped", nil, { cat = cat, count = r.dropped, second = r.sec })
        end
        r = { sec = sec, n = 0, dropped = 0 }
        state.rate[cat] = r
    end
    r.n = r.n + 1
    if r.n > RATE_PER_S then
        r.dropped = r.dropped + 1
        return false
    end
    return true
end

--- Record one event. cat / ev are short lowercase words; msg is one sentence; d is a table of detail.
function actlog.event(cat, ev, msg, d)
    if state.disabled or not actlog.enabled() then return end
    cat, ev = tostring(cat or "log"), tostring(ev or "event")
    if msg ~= nil and type(msg) ~= "string" then msg = tostring(msg) end
    local t = now_s()
    local key = cat .. "|" .. ev .. "|" .. tostring(msg)
    local dup = state.dup
    if dup and dup.key == key and (t - dup.last_t) <= DUP_WINDOW and d == nil then
        dup.count, dup.last_t = dup.count + 1, t
        return
    end
    close_dup()
    local critical = cat == "error" or cat == "user" or cat == "quest" or cat == "skip"
        or (cat == "nav" and (ev == "request" or ev == "arrived" or ev == "walk_failed"))
    if not critical and not rate_ok(cat) then return end
    state.dup = d == nil and { key = key, count = 1, cat = cat, ev = ev, msg = msg, first_t = t, last_t = t } or nil
    emit_line(cat, ev, msg, d)
    if cat == "error" then flush(true) else flush(false) end
end

--- printf-style convenience for the many text call sites.
function actlog.eventf(cat, ev, fmt, ...)
    if state.disabled then return end
    local ok, text = pcall(string.format, fmt, ...)
    actlog.event(cat, ev, ok and text or tostring(fmt))
end

function actlog.warn(cat, msg, d)
    state.warns = state.warns + 1
    actlog.event(cat, "warn", msg, d)
end

-- ----------------------------------------------------------------------------
-- context and errors
-- ----------------------------------------------------------------------------
function actlog.set_context(fn) state.ctx_fn = fn end
function actlog.set_env(fn) state.env_fn = fn state.env_pending = fn ~= nil end

--- What the game reports about itself, read on the first tick when no product env was supplied.
local function default_env()
    local function g(f) local ok, v = pcall(f) if ok then return v end return nil end
    local env = {
        game_version = g(function() return core.get_game_version() end),
        exact_version = g(function() return core.get_exact_game_version() end),
        map_id = g(function() return core.get_map_id() end),
        map = g(function() return core.get_map_name() end),
        sentinel = g(function() return require("movement/sentinel").version() end),   -- the adapter is the only reader of the library
    }
    local me = g(function() return require("common/izi_sdk").me() end)
    if me then
        env.class_id = g(function() return me:get_class() end)
        env.race_id = g(function() return me:get_race_id() end)
        env.level = g(function() return me:get_level() end)
        env.name = g(function() return me:get_name() end)
    end
    return env
end
function actlog.set_extra(fn) state.extra_fn = fn end

local function snapshot()
    local out = {}
    if type(state.ctx_fn) == "function" then
        local ok, ctx = pcall(state.ctx_fn)
        if ok and type(ctx) == "table" then out = ctx else out = { ctx_error = tostring(ctx) } end
    end
    return out
end

local function recent_stages()
    local out = {}
    local n = math.min(state.stage_n, STAGES)
    for i = 1, n do
        local idx = ((state.stage_head - i) % STAGES) + 1
        out[#out + 1] = state.stage_ring[idx]
    end
    return out
end

--- Remember the stage the bot just entered (cheap: a ring slot). Errors carry the last ones.
function actlog.stage(tag)
    state.stage_head = (state.stage_head % STAGES) + 1
    state.stage_ring[state.stage_head] = tag
    if state.stage_n < STAGES then state.stage_n = state.stage_n + 1 end
end

--- A Lua error. `where` names the call that threw; tb is a traceback string.
function actlog.error(where, err, tb)
    if state.disabled then return end
    local key = tostring(where) .. "|" .. tostring(err):gsub("%d+", "#")
    local n = (state.seen_err[key] or 0) + 1
    if state.seen_err[key] == nil then
        state.seen_err_n = state.seen_err_n + 1
        if state.seen_err_n > 500 then state.seen_err, state.seen_err_n = {}, 1 end
    end
    state.seen_err[key] = n
    state.errors = state.errors + 1
    -- the same error is written in full once, then every 50th time as a count
    if n > 1 and n % 50 ~= 0 then return end
    close_dup()
    if n > 1 then
        emit_line("error", "repeat", tostring(err), { where = where, times = n })
        flush(true)
        return
    end
    local trace = {}
    for l in tostring(tb or err):gmatch("[^\n]+") do
        trace[#trace + 1] = l
        if #trace >= 24 then break end
    end
    emit_line("error", "lua_error", tostring(err), { where = where, trace = trace },
        { ctx = snapshot(), stages = recent_stages() })
    flush(true)
    pcall(function()
        core.log_error("[Master Farmer - Zygor Forever] " .. tostring(where) .. ": " .. tostring(err)
            .. "  (action log: scripts_log/" .. tostring(state.path) .. ")")
    end)
end

local function traceback(err)
    local dbg = rawget(_G, "debug")
    if type(dbg) == "table" and type(dbg.traceback) == "function" then
        local ok, tb = pcall(dbg.traceback, tostring(err), 2)
        if ok and type(tb) == "string" then return tb end
    end
    return tostring(err)
end

--- Run fn(...) and record anything it throws. Returns ok, first result.
function actlog.guard(where, fn, ...)
    local args = { n = select("#", ...), ... }
    local tb = nil
    local unpack = table.unpack or unpack
    local ok, res = xpcall(function() return fn(unpack(args, 1, args.n)) end, function(e)
        tb = traceback(e)
        return e
    end)
    if not ok then actlog.error(where, res, tb) end
    return ok, res
end

--- A moment the person at the keyboard wants Claude to look at ("it got stuck here").
function actlog.mark(note)
    state.marks = state.marks + 1
    close_dup()
    emit_line("user", "mark", tostring(note or "marked"), nil, { ctx = snapshot(), stages = recent_stages() })
    flush(true)
end


-- ----------------------------------------------------------------------------
-- console lines (the old core.log / log_warning / log_error calls)
-- ----------------------------------------------------------------------------
-- Every message the product used to print is still printed, and is now also an event
-- (cat "console", or the word before the first colon: "rest: ...", "guide: ...").
local function console_event(level, text)
    text = tostring(text or "")
    local body = text:gsub("^%[Master Farmer[^%]]*%]%s*", "")
    local cat, rest = body:match("^(%l[%l_]*):%s+(.*)$")
    if not cat or #cat > 12 then cat, rest = "console", body end
    if level == "info" then
        actlog.event(cat, "log", rest)
    elseif level == "warn" then
        state.warns = state.warns + 1
        actlog.event(cat, "warn", rest)
    else
        state.errors = state.errors + 1
        actlog.event(cat, "error", rest)
    end
end

function actlog.console(text)
    pcall(core.log, text)
    pcall(console_event, "info", text)
end
function actlog.console_warn(text)
    pcall(core.log_warning, text)
    pcall(console_event, "warn", text)
end
function actlog.console_error(text)
    pcall(core.log_error, text)
    pcall(console_event, "error", text)
end

--- The action the bot is performing (state.report_action): an event only, never a console line.
function actlog.action(text)
    actlog.event("action", "do", text)
end

-- ----------------------------------------------------------------------------
-- session
-- ----------------------------------------------------------------------------
local HOW_TO_READ = "JSON Lines: one event per line. n=sequence, t=game seconds, ts=local time, cat=part of the bot "
    .. "(nav quest combat loot rest vendor death gui guide log error user), ev=what happened, msg=one sentence, "
    .. "d=detail. error/lua_error and user/mark events carry ctx (position, map, step, goal, target, hp, mana) and "
    .. "stages (last code stages, newest first). 'state' events every 15 s repeat ctx so the timeline can be rebuilt. "
    .. "log/repeated means the same event happened N times in a row; log/dropped means a category exceeded "
    .. "25 events/s. To diagnose: find the first error, stuck, stall, held or mark event near the symptom, read the "
    .. "~40 lines before it, then follow cat/ev back to the module (cat names match source files: nav=movement/nav.lua, "
    .. "quest=quest/engine.lua, guide=quest/guide.lua, rest=resting.lua, vendor=vendor.lua)."

--- Open the session file and write its header. meta = { product, version, ... }.
function actlog.start(meta)
    if state.stopped then
        state.stopped = false
    end
    if not state.env_fn then state.env_fn, state.env_pending = default_env, true end
    if state.started_t then return end
    if not open() then return end
    state.meta = type(meta) == "table" and meta or {}
    state.started_t = now_s()
    local ts, date = wall()
    local env = {}
    if type(state.env_fn) == "function" then
        local ok, e = pcall(state.env_fn)
        if ok and type(e) == "table" then env = e end
    end
    local header = { schema = SCHEMA, kind = "master_farmer_action_log", date = date,
        product = state.meta.product or "Zygor Forever", version = state.meta.version,
        how_to_read = HOW_TO_READ, env = env }
    state.seq = state.seq + 1
    push(string.format('{"n":%d,"t":%s,"ts":%s,"cat":"log","ev":"header","d":%s}', state.seq, jnum(now_s()), jstr(ts), encode(header, 1)))
    flush(true)
end

--- Periodic work from the update tick: state snapshot, flush.
function actlog.tick(now)
    if state.disabled or not actlog.enabled() then return end
    local t = type(now) == "number" and now or now_s()
    if state.env_pending and state.started_t and type(state.env_fn) == "function" and (t - state.started_t) >= 1 then
        -- the environment (game version, class, race, level, map) is read on the first tick, when the
        -- player exists; the header is written before that
        state.env_pending = false
        local ok, e = pcall(state.env_fn)
        if ok and type(e) == "table" then emit_line("log", "env", nil, e) end
    end
    if (t - state.last_state) >= STATE_GAP then
        state.last_state = t
        close_dup()
        local extra = nil
        if type(state.extra_fn) == "function" then
            local ok, e = pcall(state.extra_fn)
            if ok and type(e) == "table" then extra = e end
        end
        local kb = nil
        local okg, c = pcall(collectgarbage, "count")
        if okg and type(c) == "number" then kb = c end
        local ctx = snapshot()
        emit_line("log", "state", nil, { heap_kb = kb and math.floor(kb) or nil, extra = extra }, { ctx = ctx })
        -- Movement between samples is progress even if the status text is identical.
        local progressed = false
        local prev = state.progress_ctx
        if type(ctx) == "table" then
            if prev and type(prev.pos) == "table" and type(ctx.pos) == "table" then
                local a, b = prev.pos, ctx.pos
                if type(a.x) == "number" and type(b.x) == "number" and type(a.y) == "number" and type(b.y) == "number" then
                    progressed = (a.x - b.x)^2 + (a.y - b.y)^2 + ((a.z or 0) - (b.z or 0))^2 >= 4
                end
            end
            if prev and (ctx.guide ~= prev.guide or ctx.step ~= prev.step or ctx.goal ~= prev.goal) then progressed = true end
            state.progress_ctx = ctx
        end
        if progressed or not prev then state.last_progress = t end
        -- A running bot whose status line has not changed for STALE_S seconds is stalled or doing work nothing
        -- logs: flag it once per STALE_GAP so the timeline shows where the gap is.
        if type(ctx) == "table" and ctx.started == true and type(ctx.status_age) == "number" and ctx.status_age >= 20
            and ctx.moving ~= true and ctx.in_combat ~= true and not progressed
            and (t - (state.last_progress or t)) >= 20
            and (t - (state.last_stale or -1e9)) >= 30 then
            state.last_stale = t
            emit_line("stall", "status_stale", string.format("status unchanged for %d s: %s", ctx.status_age, tostring(ctx.status)),
                nil, { ctx = ctx, stages = recent_stages() })
        end
    end
    flush(false)
end

--- Session summary (Stop / unload). Safe to call more than once.
function actlog.stop(why)
    if state.stopped or not state.started_t then return end
    state.stopped = true
    close_dup()
    for cat, r in pairs(state.rate) do
        if r.dropped > 0 then
            emit_line("log", "dropped", nil, { cat = cat, count = r.dropped, second = r.sec })
            r.dropped = 0
        end
    end
    local cats = {}
    for k, v in pairs(state.counts) do cats[k] = v end
    emit_line("log", "session_end", tostring(why or "stop"), { events = state.seq, errors = state.errors,
        warnings = state.warns, marks = state.marks, categories = cats,
        seconds = math.floor(now_s() - state.started_t) }, { ctx = snapshot() })
    flush(true)
    state.started_t = nil
end

function actlog.path() return state.path and ("scripts_log/" .. state.path) or nil end
function actlog.count() return state.seq end
function actlog.error_count() return state.errors end

--- For tests.
function actlog._reset()
    for k in pairs(state) do state[k] = nil end
    state.opened, state.disabled, state.part, state.lines, state.seq = false, false, 1, 0, 0
    state.buf, state.buf_n, state.last_flush, state.last_state = {}, 0, -1e9, -1e9
    state.rate, state.counts, state.errors, state.warns, state.marks = {}, {}, 0, 0, 0
    state.seen_err, state.seen_err_n, state.stage_ring, state.stage_n, state.stage_head = {}, 0, {}, 0, 0
    state.meta, state.stopped = {}, false
end

return actlog
