-- ============================================================================
-- Master Farmer - Zygor Forever
-- flightrec.lua - flight recorder for the disconnect hunt (1.2.69)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.2.69
-- ============================================================================
-- 2026-11-19: five realm disconnects in 36 minutes ("Killing connection ... Client disconnected" in the client's
-- General.log), each in the same second as the bot's last logged event, four different kinds of action. The action log
-- records WHAT the bot decided, not the native calls it sent or how fast. This module notes every native call the product
-- makes at its call sites (a Sentinel call, a cast, a loot request, a turn / strafe key, a target change, a jump, a mount,
-- an item use, an interaction) in a ring buffer, and once a second - only while something was sent - writes ONE line:
--
--   {"cat":"rec","ev":"hb","msg":"11 calls: loot_object x6, sn_move_to x2, ...","d":{n, by, last[{ms, k, d}], pos, ...}}
--
-- `last` lists the last calls newest first with the milliseconds before the heartbeat, so the final heartbeat before a
-- disconnect shows the exact tail. The line is flushed to disk at once (actlog.flush(true)). A second with BURST_N or
-- more calls is also written as ev "burst". Pure bookkeeping: no game call except the player's position / flags.
-- Read it: grep '"cat":"rec"' in the session log and compare its time with General.log's "Client disconnected".
-- ============================================================================

local M = {}

M.RING = 48
M.BURST_N = 25
M.LAST_N = 12
local SEC = 1.0

local ring, head, count = {}, 0, 0
local win = { t0 = nil, n = 0, by = {} }
local last_hb = nil
M.stats = { notes = 0, heartbeats = 0, bursts = 0 }

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local okn, v = pcall(izi.now)
        if okn and type(v) == "number" then return v end
    end
    return 0
end

--- Note one native call. `kind` is a short word; `detail` an optional number / short string.
function M.note(kind, detail)
    local t = now()
    M.stats.notes = M.stats.notes + 1
    head = head % M.RING + 1
    local e = ring[head]
    if not e then e = {} ring[head] = e end
    e.t, e.k, e.d = t, kind, detail
    if count < M.RING then count = count + 1 end
    if not win.t0 then win.t0 = t end
    win.n = win.n + 1
    win.by[kind] = (win.by[kind] or 0) + 1
end

local function summary(by, n)
    local keys = {}
    for k in pairs(by) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) if by[a] ~= by[b] then return by[a] > by[b] end return a < b end)
    local parts = {}
    for i = 1, math.min(#keys, 6) do parts[#parts + 1] = keys[i] .. " x" .. by[keys[i]] end
    return string.format("%d call(s): %s", n, table.concat(parts, ", "))
end

local function tail(t_now)
    local out = {}
    local i, c = head, 0
    while c < math.min(count, M.LAST_N) do
        local e = ring[i]
        if e and e.t then
            out[#out + 1] = { ms = math.floor((t_now - e.t) * 1000 + 0.5), k = e.k, d = e.d }
        end
        i = i - 1
        if i < 1 then i = M.RING end
        c = c + 1
    end
    return out
end

local function r1(v) return type(v) == "number" and math.floor(v * 10 + 0.5) / 10 or nil end

local function context(player)
    local d = {}
    if player then
        local ok, p = pcall(player.get_position, player)
        if ok and type(p) == "table" then d.x, d.y, d.z = r1(p.x), r1(p.y), r1(p.z) end
        local function flag(name)
            local okf, v = pcall(player[name], player)
            return okf and v == true or nil
        end
        d.moving, d.combat, d.mounted = flag("is_moving"), flag("is_in_combat"), flag("is_mounted")
    end
    return d
end

--- Every update tick (main.lua). Writes the heartbeat once a second while calls were noted.
function M.tick(player)
    if not win.t0 then return end
    local t = now()
    if t - win.t0 < SEC then return end
    local n, by = win.n, win.by
    win.t0, win.n, win.by = nil, 0, {}
    local ok, actlog = pcall(require, "actlog")
    if not ok or type(actlog) ~= "table" or type(actlog.event) ~= "function" then return end
    local d = context(player)
    d.n, d.by, d.last = n, by, tail(t)
    d.gap = last_hb and r1(t - last_hb) or nil
    last_hb = t
    local burst = n >= M.BURST_N
    M.stats.heartbeats = M.stats.heartbeats + 1
    if burst then M.stats.bursts = M.stats.bursts + 1 end
    pcall(actlog.event, "rec", burst and "burst" or "hb", summary(by, n), d)
    if type(actlog.flush) == "function" then pcall(actlog.flush, true) end
end

function M.reset()
    ring, head, count = {}, 0, 0
    win = { t0 = nil, n = 0, by = {} }
    last_hb = nil
end

return M
