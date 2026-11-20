-- ============================================================================
-- Master Farmer - Zygor Forever
-- priority.lua - the user's ROTATION ORDER and the spell sequence recorder
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- 1.9.2 (ported from Forever 1.0.1; user: "Enable the spells to be used in the rotation, beside the
-- enabled spells have an option to set the rotation order by numeric value";
-- the Spell Sequence Debugger example as the model).
--
-- ORDER NUMBERS. Every Spells-tab row (class spell, racial, other castable
-- spell) has a number 1..10: the user's, else a DEFAULT taken from the role
-- order smart.lua has always used (COMBAT_ORDER: heal 1, defensive 2, interrupt 3, racials 4,
-- buffs / forms 5, seal 6 ... damage / filler 10) - so the list opens in the
-- order the bot already fought in. With "Use My Rotation Order" (mfz_rotation_order, default off)
-- on, smart.combat tries the ENABLED rows lowest number first, one callback
-- per spell, the first that casts wins the tick (the example's waterfall).
-- Each callback keeps the spell's own checks (its role condition, buff
-- missing, range, resource, GCD - smart.lua try()).
--
-- RECORDER (no external library - the example's FBR SpellDebugger is not
-- used). While "Record Spell Sequence" (mfz_record_rotation) is on, every waterfall tick is kept:
-- the callbacks invoked, true / false, why each one failed (smart.lua's
-- why_not reason), the winner, and the spells that were ready but lost on
-- priority. M.tick writes scripts_data/zf/spell_sequence.txt as a Lua table (only while it records)
-- (tick_snapshots, cast_events, failed_casts, skipped_available,
-- registered_callbacks) - the report to hand back for tuning the order.
-- ============================================================================

local M = {}

-- 1.0.2 (user: "Min. 1 Max 10"): an order number is 1..10. The defaults put
-- the built-in role order into that range (one number per role group, the
-- same order as before); spells with the same number keep their list order.
M.MIN, M.MAX = 1, 10
M.ROLE_RANK = {
    heal = 1, other_heal = 1, defensive = 2, interrupt = 3, racial = 4,
    form = 5, buff = 5, cbuff = 5, imbue = 5, seal = 6,
    resource = 7, opener = 7, execute = 7, control = 7,
    debuff = 8, totem = 8, cooldown = 8,
    aoe = 9, finisher = 9,
    damage = 10, other_dps = 10, filler = 10, other = 10,
}

local order = {}               -- spell name -> the user's number
local function clock()
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local ok2, t = pcall(izi.now)
        if ok2 and type(t) == "number" then return t end
    end
    local ok3, t3 = pcall(function() return core.time() end)
    return ok3 and tonumber(t3) or 0
end

local function dirty()
    local ok, settings = pcall(require, "settings")
    if ok and type(settings) == "table" and type(settings.mark_dirty) == "function" then settings.mark_dirty() end
end

local function clamp(n)
    n = math.floor(tonumber(n) or M.MAX)
    if n < M.MIN then return M.MIN end
    if n > M.MAX then return M.MAX end
    return n
end
M.clamp = clamp

--- The default number of a row: its role group's place in the built-in order.
function M.default_of(row, index)
    local r = M.ROLE_RANK[tostring(row and row.role or "")] or M.ROLE_RANK[tostring(row and row.section or "")] or M.MAX
    return clamp(r)
end

--- The number shown / used for a row: the user's, else its default (always 1..10).
function M.number(row, index)
    local n = row and order[row.name]
    if type(n) == "number" then return clamp(n) end
    return M.default_of(row, index)
end

function M.is_custom(name) return type(order[name]) == "number" end

function M.set(name, n)
    if type(name) ~= "string" or name == "" then return end
    order[name] = clamp(n)
    dirty()
end

function M.clear(name)
    if order[name] ~= nil then order[name] = nil dirty() end
end

function M.reset_all()
    order = {}
    dirty()
end

--- The rows in rotation order: lowest number first, list order among equals.
--- `rows` is smart.rows(); `enabled(row)` filters (nil = all rows).
function M.sorted(rows, enabled)
    local tmp = {}
    for i, row in ipairs(rows or {}) do
        if not enabled or enabled(row) then
            tmp[#tmp + 1] = { row = row, n = M.number(row, i), i = i }
        end
    end
    table.sort(tmp, function(a, b)
        if a.n ~= b.n then return a.n < b.n end
        return a.i < b.i
    end)
    local out = {}
    for i = 1, #tmp do out[i] = tmp[i].row end
    return out
end

-- name=number;name=number ("%", "=", ";" escaped)
local function esc(s) return (tostring(s):gsub("[%%=;]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
function M.serialise()
    local parts = {}
    for name, n in pairs(order) do parts[#parts + 1] = esc(name) .. "=" .. tostring(n) end
    table.sort(parts)
    return table.concat(parts, ";")
end
function M.deserialise(text)
    order = {}
    if type(text) ~= "string" then return end
    for item in text:gmatch("[^;]+") do
        local k, v = item:match("^(.-)=(%-?%d+)$")
        if k and v then order[unesc(k)] = clamp(v) end      -- an older save (up to 999) is clamped to 1..10
    end
end

-- ============================================================================
-- THE SPELL SEQUENCE RECORDER
-- ============================================================================
local MAX_SNAPS, MAX_EVENTS = 400, 400
local rec = { on = false, t0 = 0, snaps = {}, casts = {}, failed = {}, skipped = {}, callbacks = {}, cur = nil }
M.rec = rec

function M.recording() return rec.on end

function M.start()
    rec.on, rec.t0 = true, clock()
    rec.snaps, rec.casts, rec.failed, rec.skipped, rec.callbacks, rec.cur = {}, {}, {}, {}, {}, nil
end
function M.stop() rec.on = false end

local function push(list, v, max)
    list[#list + 1] = v
    if #list > max then table.remove(list, 1) end
end

--- A waterfall tick begins (action list name).
function M.begin_tick(action_list)
    if not rec.on then return end
    rec.cur = { time = clock() - rec.t0, action_list = action_list or "core", invocations = {} }
end

--- One callback ran: name, spell id, result, why it failed, whether it was
--- ready (its checks before the cast passed).
function M.invoke(name, spell_id, result, why, ready)
    if not rec.on or not rec.cur then return end
    rec.callbacks[name] = spell_id
    local inv = { name = name, spell_id = spell_id, result = result == true, why = why, ready = ready == true }
    rec.cur.invocations[#rec.cur.invocations + 1] = inv
    if result ~= true and why and not ready then
        push(rec.failed, { time = rec.cur.time, name = name, spell_id = spell_id, why = why }, MAX_EVENTS)
    end
end

--- The tick ended with `winner` (nil = nothing cast); the target's name.
function M.end_tick(winner, target_name)
    local cur = rec.cur
    if not rec.on or not cur then return end
    rec.cur = nil
    if #cur.invocations == 0 then return end
    cur.winner = winner
    push(rec.snaps, cur, MAX_SNAPS)
    if winner then
        for _, inv in ipairs(cur.invocations) do
            if inv.name == winner then
                push(rec.casts, { time = cur.time, name = winner, spell_id = inv.spell_id, target_name = target_name }, MAX_EVENTS)
            end
        end
    end
end

--- Spells that were ready this tick but lower in the order than the winner.
function M.note_skipped(name, spell_id, winner)
    if not rec.on then return end
    push(rec.skipped, { time = clock() - rec.t0, name = name, spell_id = spell_id, winner = winner }, MAX_EVENTS)
end

local function lua_str(s) return string.format("%q", tostring(s)) end

--- The report as Lua table text (the example's export layout).
function M.report_text()
    local out = {}
    local function w(s) out[#out + 1] = s end
    local dur = clock() - rec.t0
    w(string.format("-- Master Farmer - Zygor Forever spell sequence - session %.1fs", dur))
    w(string.format("-- Casts: %d | Failed: %d | Skipped: %d", #rec.casts, #rec.failed, #rec.skipped))
    w("return {")
    w(string.format("    session_duration = %.2f,", dur))
    w("    tick_snapshots = {")
    for _, s in ipairs(rec.snaps) do
        w(string.format("        { time = %.2f, action_list = %s, winner = %s, invocations = {", s.time,
            lua_str(s.action_list), s.winner and lua_str(s.winner) or "nil"))
        for _, inv in ipairs(s.invocations) do
            w(string.format("            { name = %s, spell_id = %s, result = %s%s },", lua_str(inv.name),
                tostring(inv.spell_id), tostring(inv.result), inv.why and (", why = " .. lua_str(inv.why)) or ""))
        end
        w("        } },")
    end
    w("    },")
    w("    cast_events = {")
    for _, c in ipairs(rec.casts) do
        w(string.format("        { time = %.2f, name = %s, spell_id = %s, target_name = %s },", c.time, lua_str(c.name),
            tostring(c.spell_id), lua_str(c.target_name or "-")))
    end
    w("    },")
    w("    failed_casts = {")
    for _, f in ipairs(rec.failed) do
        w(string.format("        { time = %.2f, name = %s, spell_id = %s, why = %s },", f.time, lua_str(f.name),
            tostring(f.spell_id), lua_str(f.why)))
    end
    w("    },")
    w("    skipped_available = {")
    for _, k in ipairs(rec.skipped) do
        w(string.format("        { time = %.2f, name = %s, spell_id = %s, winner = %s },", k.time, lua_str(k.name),
            tostring(k.spell_id), lua_str(k.winner or "-")))
    end
    w("    },")
    w("    registered_callbacks = {")
    local names = {}
    for n in pairs(rec.callbacks) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
        w(string.format("        { name = %s, spell_id = %s, order = %s },", lua_str(n), tostring(rec.callbacks[n]),
            tostring(order[n] or "default")))
    end
    w("    },")
    w("}")
    return table.concat(out, "\n") .. "\n"
end

M.EXPORT_FOLDER, M.EXPORT_FILE = "mfz", "mfz/spell_sequence.txt"
--- Write the report (replaced whole: create_data_file, then one write).
function M.export()
    if type(core) ~= "table" or type(core.create_data_file) ~= "function" or type(core.write_data_file) ~= "function" then
        return false, "no file API"
    end
    if type(core.create_data_folder) == "function" then pcall(core.create_data_folder, M.EXPORT_FOLDER) end
    if not pcall(core.create_data_file, M.EXPORT_FILE) then return false, "create failed" end
    local ok = pcall(core.write_data_file, M.EXPORT_FILE, M.report_text())
    return ok, ok and ("scripts_data/" .. M.EXPORT_FILE) or "write failed"
end

-- 1.9.2: the recorder follows the "Record Spell Sequence" box (mfz_record_rotation,
-- gui.lua's update tick) and writes the report itself - every WRITE_GAP s
-- while it records and something new was kept; never while the box is off.
M.WRITE_GAP = 10
local written = { t = -1e9, n = -1 }
function M.tick(record_on)
    if record_on and not rec.on then M.start() written.n = -1
    elseif not record_on and rec.on then M.stop() end
    if not rec.on then return end
    local t = clock()
    local n = #rec.snaps + #rec.casts + #rec.failed + #rec.skipped
    if n == written.n or (t - written.t) < M.WRITE_GAP then return end
    written.t, written.n = t, n
    M.export()
end

return M
