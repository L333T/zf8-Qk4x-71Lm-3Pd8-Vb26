-- ============================================================================
-- Master Farmer - Zygor Forever
-- debuglog: the debug-line surface (movement gates, resting gates, quest
-- detail), now events in the JSON-Lines action log (actlog.lua)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Folder: Zygor_Forever
-- ============================================================================
-- Replaced in 1.75.0. The scripts_log/mfz/debug.log file and the "Movement Debug
-- Log" / "Log why resting is blocked" boxes are gone; the call sites still call
-- debuglog.line(tag, fmt, ...) behind gui.is_on("move_debug" / "rest_debug" /
-- "session_detail"), which now all mean the action log's VERBOSE box. A line
-- becomes cat=debug ev=<tag>; identical consecutive lines collapse into a
-- "repeated" count, so the old once-a-second "resting - HP 100 MP 71 ..." flood
-- is one event per change.
-- ============================================================================

local actlog = require("actlog")

local debuglog = {}
local count = 0

function debuglog.line(tag, f, ...)
    local text
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, f, ...)
        text = ok and formatted or tostring(f)
    else
        text = tostring(f)
    end
    count = count + 1
    actlog.event("debug", tostring(tag), text)
end

function debuglog.flush(force) actlog.flush(force == true) return true end
function debuglog.tick() end
function debuglog.reset(note)
    count = 0
    if note then debuglog.line("log", tostring(note)) end
end
function debuglog.path() return actlog.path() end
function debuglog.count() return count end

return debuglog
