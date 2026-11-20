-- ============================================================================
-- Master Farmer - Zygor Forever
-- errorlog: the call surface every module already uses, now writing the
-- JSON-Lines action log (actlog.lua) instead of a text file
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Folder: Zygor_Forever
-- ============================================================================
-- Replaced in 1.75.0 (user: "replace all of the logging options with a new
-- logging method that records actions in a format that can be fed into Claude").
-- The old text log, its three recorders (full, light, crash capture), the heartbeat
-- and the memory/CPU lines are gone; the ~120 call sites keep working because
-- they still call errorlog.trail / info / warn / error / guard / probe ... and
-- those now record structured events:
--
--   errorlog.trail(tag, fmt, ...)  -> event cat=<tag> ev=trail   (only when the
--                                     text changed since the last one of that tag)
--   errorlog.info / warn           -> cat=log ev=info / warn
--   errorlog.error / guard         -> cat=error ev=lua_error with traceback, the
--                                     context snapshot and the last stages
--   errorlog.probe(tag)            -> the stage ring buffer (every error carries
--                                     the last 48); verbose mode also writes them
--   errorlog.arm / arm_light       -> nothing (the ring buffer replaces the recorders)
--   errorlog.tick_begin / end      -> verbose: one "beat" event per bot tick
--
-- NOTHING HERE MAY THROW: it runs inside the error path.
-- ============================================================================

local actlog = require("actlog")

local errorlog = {}

local last_trail = {}
local beat_on, beat_tags, beat_n = false, {}, 0
local beat_last_body, beat_last_t, beat_same = nil, 0, 0
local beat_extra = nil
local BEAT_SAME = 2.0
local mem_extra = nil

local function fmt(f, ...)
    local ok, text = pcall(string.format, f, ...)
    return ok and text or tostring(f)
end

function errorlog.start(version)
    actlog.start({ product = "Zygor Forever", version = version })
end

function errorlog.set_context(fn) actlog.set_context(fn) end
function errorlog.set_env(fn) actlog.set_env(fn) end
function errorlog.set_beat_extra(fn) beat_extra = fn end
function errorlog.set_mem_extra(fn) mem_extra = fn actlog.set_extra(fn and function()
    local ok, s = pcall(fn)
    return ok and { mem = s } or nil
end or nil) end

function errorlog.error(where, err, tb) actlog.error(where, err, tb) end
function errorlog.warn(f, ...) actlog.warn("log", fmt(f, ...)) end
function errorlog.info(f, ...) actlog.event("log", "info", fmt(f, ...)) end

--- A breadcrumb. Written only when it differs from the previous one with the same tag.
function errorlog.trail(tag, f, ...)
    local text = fmt(f, ...)
    tag = tostring(tag)
    if last_trail[tag] == text then return end
    last_trail[tag] = text
    -- ev = the first word of the text ("queued", "looting", "engage", "move_to", "arrived" ...), so a log can be
    -- filtered by what happened; "trail" when the text does not start with a word
    local ev = text:match("^(%a[%w_]*)")
    ev = (ev and #ev <= 18) and ev:lower() or "trail"
    actlog.event(tag, ev, text)
end

function errorlog.guard(where, fn, ...) return actlog.guard(where, fn, ...) end

-- Recorders: replaced by the stage ring buffer every error event carries.
function errorlog.arm(why) end
function errorlog.arm_light(seconds, why) end
function errorlog.frame() end
function errorlog.spike_begin(group) end
function errorlog.spike_end() end

function errorlog.probe(tag)
    tag = tostring(tag)
    if tag == "-" then return end
    actlog.stage(tag)
    if beat_on and beat_n < 48 then
        beat_n = beat_n + 1
        beat_tags[beat_n] = (tag:gsub("^u:", ""))
    end
end

function errorlog.tick_begin()
    beat_on = true
    beat_n = 0
end

function errorlog.tick_end()
    if not beat_on then return end
    beat_on = false
    if not actlog.verbose() then return end
    local extra = ""
    if type(beat_extra) == "function" then
        local ok, s = pcall(beat_extra)
        if ok and type(s) == "string" then extra = s end
    end
    local body = table.concat(beat_tags, ">", 1, beat_n) .. " | " .. extra
    local now = 0
    pcall(function() now = core.time() end)
    if body == beat_last_body and (now - beat_last_t) < BEAT_SAME then
        beat_same = beat_same + 1
        return
    end
    local same = beat_same
    beat_last_body, beat_last_t, beat_same = body, now, 0
    actlog.event("tick", "beat", body, same > 0 and { same_as_before = same } or nil)
end

function errorlog.tick(now) actlog.tick(now) end
function errorlog.path() return actlog.path() end
function errorlog.stop(why) actlog.stop(why) end

return errorlog
