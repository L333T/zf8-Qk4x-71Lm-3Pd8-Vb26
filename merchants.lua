-- ============================================================================
-- Master Farmer - Zygor Forever
-- merchants.lua - remembered repair NPCs and innkeepers
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- ============================================================================
-- The user (2.318.0): "Grinding path should vendor at repair NPC or INN if
-- bags are full". A grind route without its own merchant record had only the
-- zone merchant table (few zones), a vendor in sight, the Hearthstone and the
-- Alliance Eastern Kingdoms inn list - full bags elsewhere had nowhere to go.
--
-- Every NPC the bot sees that the game flags as a repairer (npc flag 0x1000)
-- or an innkeeper (0x10000) is remembered: npc id, name, position, continent.
-- Scanned every SCAN_EVERY s from the visible objects; kept per continent in
-- scripts_data/zfb/merchants.txt so it survives reloads and sessions.
-- merchants.nearest(player, want_repair) gives the nearest one on the
-- player's continent as a merchant record { npc_id, name, x, y, z } - the
-- shape vendor.lua already walks to and talks to.
--
-- 1.9.2 ZYGOR VENDOR SPOTS (Forever 1.0.14's guide vendors, from the live
-- Zygor step - no guide book is imported): every vendor / buy goal of the
-- current step (quest/guide guide.vendor_goals: npc_id, npc name, the step
-- waypoint converted by guide.to_world) is cached in
-- scripts_data/zfb/zygor_vendors.txt (at most GV_MAX, the oldest dropped),
-- so a vendor the guide passed is still usable when the bags fill on a later
-- step. M.nearest ranks them with the remembered book: a repairer first when
-- want_repair (a guide vendor repairs only when the book knows its npc as a
-- repairer), else by distance on the player's continent. One with neither id
-- nor name is a SPOT (vendor.lua: the vendor-flagged NPC nearest that point).
-- One that was missing / did not open is skipped BAD_S s (M.mark_bad); the
-- remembered repairer book is never touched by that.
-- ============================================================================

local M = {}

local FOLDER = "mfzb"
local FILE = FOLDER .. "/merchants.txt"
local NPC_REPAIR, NPC_INNKEEPER = 0x1000, 0x10000
local SCAN_EVERY = 5.0
local SAVE_GAP = 15.0
local MAX_KEEP = 400
local MAX_DIST = 3000          -- yd: farther than this is not "the nearest" any more

M.NPC_REPAIR, M.NPC_INNKEEPER = NPC_REPAIR, NPC_INNKEEPER

local book = {}                -- "cont|npc" -> { cont, npc, x, y, z, repair, inn, name }
local book_n = 0
local loaded = false
local dirty, next_save = false, 0
local next_scan = -1e9

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function now()
    return safe(core.time) or 0
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "merchants", fmt, ...) end
end

local function has_flag(v, bit)
    return type(v) == "number" and v > 0 and math.floor(v / bit) % 2 == 1
end

--- The continent the player is on (0 / 1 / 530), else the raw map id.
local function continent(pos)
    local ok, gv = pcall(require, "gamever")
    if ok and type(gv) == "table" and type(gv.continent_of) == "function" then
        local c, raw = gv.continent_of(pos)
        if c ~= nil then return c end
        if raw ~= nil then return raw end
    end
    return safe(function() return core.get_map_id() end) or -1
end

local function load()
    loaded = true
    local body = safe(function() return core.read_data_file(FILE) end)
    if type(body) ~= "string" or body == "" then return end
    for line in body:gmatch("[^\n]+") do
        local cont, npc, x, y, z, rep, inn, name =
            line:match("^(%-?%d+) (%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%d) (%d) (.*)$")
        cont, npc, x, y, z = tonumber(cont), tonumber(npc), tonumber(x), tonumber(y), tonumber(z)
        if cont and npc and x and y and z then
            local key = cont .. "|" .. npc
            if not book[key] then book_n = book_n + 1 end
            book[key] = { cont = cont, npc = npc, x = x, y = y, z = z, repair = rep == "1", inn = inn == "1",
                name = (name or "?"):gsub("_", " ") }
        end
    end
    trail("loaded %d repair NPC(s) / innkeeper(s)", book_n)
end

local function save()
    dirty = false
    local out = {}
    for _, e in pairs(book) do
        out[#out + 1] = string.format("%d %d %.1f %.1f %.1f %d %d %s", e.cont, e.npc, e.x, e.y, e.z,
            e.repair and 1 or 0, e.inn and 1 or 0, (tostring(e.name or "?"):gsub("%s", "_")))
    end
    pcall(function() core.create_data_folder(FOLDER) end)
    -- write_data_file APPENDS: empty the file first (deathzones.lua)
    pcall(function() core.create_data_file(FILE) end)
    pcall(function() core.write_data_file(FILE, table.concat(out, "\n") .. "\n") end)
end

--- Remember one NPC (exposed for the tests).
function M.remember(cont, npc, x, y, z, repair, inn, name)
    if not loaded then load() end
    if type(npc) ~= "number" or npc <= 0 or type(x) ~= "number" then return false end
    local key = cont .. "|" .. npc
    local e = book[key]
    if e and math.abs(e.x - x) < 3 and math.abs(e.y - y) < 3 and e.repair == repair and e.inn == inn then
        return false
    end
    if not e then
        if book_n >= MAX_KEEP then return false end
        book_n = book_n + 1
        trail("%s %s (npc %d) at (%.0f, %.0f)", repair and "repairer" or "innkeeper", tostring(name), npc, x, y)
    end
    book[key] = { cont = cont, npc = npc, x = x, y = y, z = z, repair = repair, inn = inn, name = name }
    dirty = true
    return true
end

-- audit 1.19.0: declared here, defined with the Zygor vendor spots below -
-- M.scan read them as (nil) globals, so the 1.9.2 spots were never noted or saved
local gv_dirty, gv_save, gv_note = false, nil, nil

--- Note every repairer / innkeeper in sight (every SCAN_EVERY s).
function M.scan(player)
    if not loaded then load() end
    local t = now()
    if dirty and t >= next_save then
        next_save = t + SAVE_GAP
        save()
    end
    if gv_dirty and t >= next_save then               -- 1.9.2: the Zygor vendor spots
        next_save = t + SAVE_GAP
        gv_save()
    end
    if t < next_scan or not player then return end
    next_scan = t + SCAN_EVERY
    pcall(gv_note, player)                            -- 1.9.2
    local okt, targeting = pcall(require, "targeting")
    if not okt or type(targeting) ~= "table" or type(targeting.visible_objects) ~= "function" then return end
    local list = safe(function() return targeting.visible_objects() end)
    if type(list) ~= "table" then return end
    local here = safe(function() return player:get_position() end)
    local cont = continent(here)
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= true then
            local flags = safe(function() return u:get_npc_flags() end)
            local rep, inn = has_flag(flags, NPC_REPAIR), has_flag(flags, NPC_INNKEEPER)
            if rep or inn then
                local p = safe(function() return u:get_position() end)
                local npc = safe(function() return u:get_npc_id() end)
                if p and npc then
                    M.remember(cont, npc, p.x, p.y, p.z, rep, inn, safe(function() return u:get_name() end))
                end
            end
        end
    end
end

-- 1.7.19 ZYGOR'S REPAIR NPCs (user: "build the local Zygor NPC import and use
-- it in the repair search"). tools/import_zygor_npcs.py reads the ["Repair"]
-- list of the Zygor add-on installed on this machine and writes
-- scripts_data/zfb/zygor_repair.txt ("<npc> <A|H|B> <ui_map> <x 0-1> <y 0-1>
-- <Name>"); nothing of Zygor's is in the product itself. Each line becomes a
-- world point once (core.game_ui.get_world_pos_from_map_pos: world x / y and
-- the continent), kept for the player's faction (B = both), and offered to
-- M.nearest beside the repairers the bot has seen - never in place of one
-- with the same npc id. No height in the data: the player's own z stands in
-- (the walk finds the ground; the NPC is talked to by its npc id).
local ZY_FILE = FOLDER .. "/zygor_repair.txt"
local zy = nil                 -- { { cont, npc, x, y, side, name } ... } once read
-- 1.7.27: one reader for every local Zygor list (repairers, flight masters)
local function zy_read(file, what, bundled)
    local out = {}
    local body = safe(function() return core.read_data_file(file) end)
    local src = "the local Zygor import"
    -- 1.28.0 (user: "get ALL repair vendors from Zygor and save them into the project"):
    -- no live import in this install - the product's own copy (data/zygor_repair.lua,
    -- tools/import_zygor_npcs.py --project); a live import, when there is one, wins
    if (type(body) ~= "string" or body == "") and bundled then
        local okb, b = pcall(require, bundled)
        if okb and type(b) == "string" then body, src = b, bundled end
    end
    if type(body) ~= "string" or body == "" then return out end
    local okv, vec2 = pcall(require, "common/geometry/vector_2")
    local okg, gv = pcall(require, "gamever")
    for line in body:gmatch("[^\n]+") do
        local npc, side, map, x, y, name = line:match("^(%d+) ([ABH]) (%d+) ([%d%.]+) ([%d%.]+) (.*)$")
        npc, map, x, y = tonumber(npc), tonumber(map), tonumber(x), tonumber(y)
        if npc and map and x and y and okv and type(vec2) == "table" and vec2.new then
            local mp = vec2.new(x, y)
            local ok, w, cont = pcall(core.game_ui.get_world_pos_from_map_pos, map, mp)
            local wx = ok and type(w) == "table" and tonumber(w.x) or (ok and w and tonumber(w.x)) or nil
            local wy = ok and w and tonumber(w.y) or nil
            cont = tonumber(cont)
            if cont == nil and okg and type(gv) == "table" and type(gv.continent_of_uimap) == "function" then
                cont = gv.continent_of_uimap(map)
            end
            if wx and wy and not (wx == 0 and wy == 0) and cont then
                out[#out + 1] = { cont = cont, npc = npc, x = wx, y = wy, side = side,
                    name = (name ~= "?" and name or (what .. " " .. npc)):gsub("_", " ") }
            end
        end
    end
    trail("loaded %d %s(s) from %s", #out, what, src)
    return out
end
local function zy_load() zy = zy_read(ZY_FILE, "repairer", "data/zygor_repair") end

local function my_side(player)
    local ok, f = pcall(require, "data/factions")
    if ok and type(f) == "table" and type(f.of_player) == "function" then
        local k = safe(function() return f.of_player(player) end)
        if type(k) == "string" then
            k = k:lower()
            if k:find("alliance", 1, true) then return "A" end
            if k:find("horde", 1, true) then return "H" end
        end
    end
    return nil
end
function M.zygor_count()
    if zy == nil then zy_load() end
    return #zy
end

-- 1.7.27 ZYGOR'S FLIGHT MASTERS (user: "get all taxi NPCs from the Zygor
-- addon"): scripts_data/zfb/zygor_flight.txt from the same import (the
-- ["Flight master"] block), same line format. M.nearest_flight: the nearest
-- one of the player's faction (B = both) on the player's continent, as
-- { npc_id, name, x, y, z (the player's - no height in the data) }, distance.
-- `skip` (npc id -> true): flight masters already tried.
local FLY_FILE = FOLDER .. "/zygor_flight.txt"
local zfly = nil
function M.flight_count()
    if zfly == nil then zfly = zy_read(FLY_FILE, "flight master") end
    return #zfly
end
function M.nearest_flight(player, skip)
    if zfly == nil then zfly = zy_read(FLY_FILE, "flight master") end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local cont = continent(me)
    local side = my_side(player)
    local best, best_d = nil, nil
    for _, list in ipairs({ zfly }) do
        for i = 1, #list do
            local e = list[i]
            if e.cont == cont and (e.side == "B" or side == nil or e.side == side) and not (skip and skip[e.npc]) then
                local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
                if d <= MAX_DIST and (best_d == nil or d < best_d) then best, best_d = e, d end
            end
        end
    end
    if not best then return nil end
    return { npc_id = best.npc, name = best.name, x = best.x, y = best.y, z = me.z, from_zygor = true }, best_d
end

-- ----------------------------------------------------------------------------
-- 1.9.2 Zygor vendor spots (header)
-- ----------------------------------------------------------------------------
local GV_FILE = FOLDER .. "/zygor_vendors.txt"
local GV_MAX = MAX_KEEP
local BAD_S = 1800
local gv = nil                 -- { key -> { cont, npc, x, y, z, name, seen, spot } } once read
local gv_n = 0
local gv_bad = {}              -- key -> skip until (core.time)
local gv_step = nil            -- the Zygor step whose goals were read last
local function gv_key(e) return string.format("%s|%.0f|%.0f", tostring(e.npc or e.name or "spot"), e.x, e.y) end
local function gv_load()
    gv, gv_n = {}, 0
    local body = safe(function() return core.read_data_file(GV_FILE) end)
    if type(body) ~= "string" or body == "" then return end
    for line in body:gmatch("[^\n]+") do
        local cont, npc, x, y, z, seen, name = line:match("^(%-?%d+) (%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%d+) (.*)$")
        cont, npc, x, y, z, seen = tonumber(cont), tonumber(npc), tonumber(x), tonumber(y), tonumber(z), tonumber(seen)
        if cont and npc and x and y and z and seen then
            name = (name ~= nil and name ~= "_" and name ~= "") and name:gsub("_", " ") or nil
            local e = { cont = cont, npc = npc > 0 and npc or nil, x = x, y = y, z = z, seen = seen, name = name }
            e.spot = e.npc == nil and e.name == nil
            local k = gv_key(e)
            if not gv[k] then gv_n = gv_n + 1 end
            gv[k] = e
        end
    end
    trail("loaded %d Zygor vendor spot(s)", gv_n)
end
gv_save = function()
    gv_dirty = false
    local out = {}
    for _, e in pairs(gv or {}) do
        out[#out + 1] = string.format("%d %d %.1f %.1f %.1f %d %s", e.cont, e.npc or 0, e.x, e.y, e.z or 0,
            math.floor(e.seen or 0), e.name and (tostring(e.name):gsub("%s", "_")) or "_")
    end
    table.sort(out)
    pcall(function() core.create_data_folder(FOLDER) end)
    pcall(function() core.create_data_file(GV_FILE) end)
    if #out > 0 then pcall(function() core.write_data_file(GV_FILE, table.concat(out, "\n") .. "\n") end) end
end
--- Read the vendor / buy goals of the current Zygor step into the cache
--- (merchants.scan, every SCAN_EVERY s, once per step).
gv_note = function(player)
    if gv == nil then gv_load() end
    local g = package.loaded["quest/guide"]
    if type(g) ~= "table" or type(g.vendor_goals) ~= "function" or type(g.step) ~= "function" then return end
    local step = safe(function() return g.step() end)
    local num = type(step) == "table" and step.num or nil
    if num == nil or num == gv_step then return end
    local list = safe(function() return g.vendor_goals() end)
    if type(list) ~= "table" then return end
    gv_step = num
    if #list == 0 then return end
    local here = safe(function() return player:get_position() end)
    local cont = continent(here)
    local t = math.floor(safe(function() return core.get_server_time() end) or now())
    for i = 1, #list do
        local v = list[i]
        if type(v) == "table" and type(v.x) == "number" and type(v.y) == "number" then
            local e = { cont = cont, npc = tonumber(v.npc_id), x = v.x, y = v.y, z = tonumber(v.z) or 0,
                name = type(v.name) == "string" and v.name ~= "" and v.name or nil, seen = t }
            e.spot = e.npc == nil and e.name == nil
            local k = gv_key(e)
            if not gv[k] then
                if gv_n >= GV_MAX then
                    local ok_k, os = nil, nil
                    for kk, ee in pairs(gv) do if os == nil or ee.seen < os then ok_k, os = kk, ee.seen end end
                    if ok_k then gv[ok_k] = nil gv_n = gv_n - 1 end
                end
                gv_n = gv_n + 1
                trail("Zygor %s goal (step %s): %s at (%.0f, %.0f)", tostring(v.action), tostring(num),
                    e.spot and "vendor spot" or (tostring(e.name or "?") .. (e.npc and (" npc " .. e.npc) or "")), e.x, e.y)
            end
            gv[k] = e
            gv_dirty = true
        end
    end
end
M._gv_note = gv_note

--- A Zygor vendor that was not there / did not open: skipped BAD_S s.
function M.mark_bad(rec)
    if type(rec) == "table" and rec.gv_key then
        gv_bad[rec.gv_key] = now() + BAD_S
        trail("Zygor vendor %s skipped for %d s - missing or did not open", tostring(rec.name), BAD_S)
    end
end

--- The nearest cached Zygor vendor on the player's continent: record,
--- distance, rank (2 = not known to repair while want_repair).
function M.nearest_guide(player, want_repair)
    if gv == nil then gv_load() end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    if not loaded then load() end
    local cont = continent(me)
    local t = now()
    local best, best_d, best_rank, best_k = nil, nil, nil, nil
    for k, e in pairs(gv) do
        if e.cont == cont and t >= (gv_bad[k] or 0) then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            local seen = e.npc and book[cont .. "|" .. e.npc] or nil
            local repairs = seen ~= nil and seen.repair == true
            local rank = (want_repair and not repairs) and 2 or 1
            if d <= MAX_DIST and (best_rank == nil or rank < best_rank or (rank == best_rank and d < best_d)) then
                best, best_d, best_rank, best_k = e, d, rank, k
            end
        end
    end
    if not best then return nil end
    local seen = best.npc and book[cont .. "|" .. best.npc] or nil
    return { npc_id = best.npc, name = best.name or string.format("vendor spot (%.0f, %.0f)", best.x, best.y),
        x = best.x, y = best.y, z = best.z ~= 0 and best.z or me.z, repair = seen ~= nil and seen.repair == true,
        inn = false, from_guide = true, spot = best.spot, gv_key = best_k }, best_d, best_rank
end

--- The nearest merchant for a vendor trip: the remembered book (repairers,
--- innkeepers, Zygor's imported repairers) and 1.9.2 the Zygor step's vendor
--- spots, ranked together - a repairer first when want_repair, then distance.
function M.nearest(player, want_repair)
    local rec, d, rank = M.nearest_book(player, want_repair)
    local grec, gd, grank = M.nearest_guide(player, want_repair)
    if grec and (not rec or grank < rank or (grank == rank and gd < d)) then return grec, gd end
    return rec, d
end

--- The nearest remembered repairer or innkeeper on the player's continent,
--- as a merchant record { npc_id, name, x, y, z, repair, inn }, its flat
--- distance and rank. want_repair: a repairer is taken over a nearer innkeeper.
function M.nearest_book(player, want_repair)
    if not loaded then load() end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local cont = continent(me)
    local best, best_d, best_rank = nil, nil, nil
    for _, e in pairs(book) do
        if e.cont == cont then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            local rank = (want_repair and not e.repair) and 2 or 1
            if d <= MAX_DIST and (best_rank == nil or rank < best_rank or (rank == best_rank and d < best_d)) then
                best, best_d, best_rank = e, d, rank
            end
        end
    end
    -- 1.7.19: Zygor's repairers (the local import) - the player's faction, this
    -- continent, an npc the bot has not recorded itself
    if zy == nil then zy_load() end
    local side = my_side(player)
    local zbest, zbest_d = nil, nil
    for _, list in ipairs({ zy }) do
        for i = 1, #list do
            local e = list[i]
            if e.cont == cont and (e.side == "B" or side == nil or e.side == side) and not book[cont .. "|" .. e.npc] then
                local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
                if d <= MAX_DIST and (zbest_d == nil or d < zbest_d) then zbest, zbest_d = e, d end
            end
        end
    end
    if zbest and (not best or best_rank == 2 or zbest_d < best_d) then
        return { npc_id = zbest.npc, name = zbest.name, x = zbest.x, y = zbest.y, z = me.z,
            repair = true, inn = false, from_zygor = true }, zbest_d, 1
    end
    if not best then return nil end
    return { npc_id = best.npc, name = best.name, x = best.x, y = best.y, z = best.z,
        repair = best.repair, inn = best.inn, from_book = true }, best_d, best_rank
end

--- 1.2.36: the nearest REMEMBERED innkeeper on the player's continent as
--- { x, y, z, name }, its flat distance - or nil. A food / water run on
--- Kalimdor knew no inn at all (supplies.nearest_inn read only the Eastern
--- Kingdoms list): Darkshore, out of water, "no inn or innkeeper known here".
function M.nearest_inn(player)
    if not loaded then load() end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local cont = continent(me)
    local best, best_d = nil, nil
    for _, e in pairs(book) do
        if e.cont == cont and e.inn then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            if best_d == nil or d < best_d then best, best_d = e, d end
        end
    end
    if not best then return nil end
    return { x = best.x, y = best.y, z = best.z, name = best.name }, best_d
end

function M.count()
    if not loaded then load() end
    return book_n
end

-- ============================================================================
-- ROUTE VENDOR (3.0.0): the user picks the NPC a route sells / repairs at.
-- "Save Target as Route Vendor" (Vendor tab) stores the targeted NPC for the
-- loaded / selected route: npc id, name, position, whether it repairs. A
-- grind route with a saved vendor goes there for full bags and worn gear
-- (vendor.lua path_merchant), before anything the bot finds on its own.
-- Kept in scripts_data/zfb/route_vendors.txt, one line per route id.
-- The menu button only records the click (the render pass must not touch
-- the game); M.tick carries it out on the update tick.
-- ============================================================================
local RV_FILE = FOLDER .. "/route_vendors.txt"
local NPC_VENDOR = 0x80
local rv, rv_loaded = {}, false
local pending = nil            -- "save" | "clear"

local function rv_load()
    rv_loaded = true
    local body = safe(function() return core.read_data_file(RV_FILE) end)
    if type(body) ~= "string" or body == "" then return end
    for line in body:gmatch("[^\n]+") do
        -- audit 1.19.0: the key is a route id = its file name, which may hold
        -- spaces ("My Route"); (%S+) dropped such a route's saved vendor on load.
        -- The six fields after it are fixed and the name has no spaces (rv_save).
        local key, npc, x, y, z, rep, name = line:match("^(.+) (%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%d) (%S*)%s*$")
        npc, x, y, z = tonumber(npc), tonumber(x), tonumber(y), tonumber(z)
        if key and npc and x and y and z then
            rv[key] = { npc_id = npc, x = x, y = y, z = z, repair = rep == "1",
                name = (name or "?"):gsub("_", " "), route_vendor = true }
        end
    end
end

local function rv_save()
    local out = {}
    for key, e in pairs(rv) do
        out[#out + 1] = string.format("%s %d %.1f %.1f %.1f %d %s", key, e.npc_id, e.x, e.y, e.z,
            e.repair and 1 or 0, (tostring(e.name or "?"):gsub("%s", "_")))
    end
    pcall(function() core.create_data_folder(FOLDER) end)
    pcall(function() core.create_data_file(RV_FILE) end)
    pcall(function() core.write_data_file(RV_FILE, table.concat(out, "\n") .. "\n") end)
end

--- The saved vendor of route `key` (path.id), or nil.
function M.route_vendor(key)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or key == "" then return nil end
    return rv[key]
end

--- Menu click (render pass): only recorded.
function M.request(kind)
    pending = kind
end

--- Store `unit` as the vendor of route `key`. Returns ok, message.
function M.save_route_vendor(key, unit, player)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or key == "" then return false, "load or select a route first" end
    if not unit then return false, "target the vendor NPC first" end
    if safe(function() return unit:is_player() end) == true then return false, "the target is a player" end
    local flags = safe(function() return unit:get_npc_flags() end)
    local sells, repairs = has_flag(flags, NPC_VENDOR), has_flag(flags, NPC_REPAIR)
    if not sells and not repairs then return false, "the target is not a vendor" end
    if player and safe(function() return player:can_attack(unit) end) == true then
        return false, "the target is hostile"
    end
    local p = safe(function() return unit:get_position() end)
    local npc = safe(function() return unit:get_npc_id() end)
    if not p or not npc then return false, "the target has no position / npc id" end
    local name = safe(function() return unit:get_name() end) or "?"
    rv[key] = { npc_id = npc, x = p.x, y = p.y, z = p.z, repair = repairs, name = name, route_vendor = true }
    rv_save()
    return true, string.format("%s (npc %d%s) saved as the vendor of route %s", name, npc,
        repairs and ", repairs" or "", key)
end

function M.clear_route_vendor(key)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or rv[key] == nil then return false, "no saved vendor for this route" end
    rv[key] = nil
    rv_save()
    return true, "route vendor cleared for " .. key
end

--- Update tick: carry out a menu click. `route_key` = the loaded / selected route id.
function M.tick(player, route_key)
    local kind = pending
    if not kind then return end
    pending = nil
    local ok, msg
    if kind == "save" then
        local target = player and safe(function() return player:get_target() end)
        ok, msg = M.save_route_vendor(route_key, target, player)
    else
        ok, msg = M.clear_route_vendor(route_key)
    end
    local line = "[Master Farmer - Zygor Forever] Route vendor: " .. tostring(msg)
    if ok then pcall(require("actlog").console, line) else pcall(require("actlog").console_warn, line) end
    trail("%s", tostring(msg))
end

--- Test hook.
function M._reset()
    book, book_n, loaded, dirty, next_scan = {}, 0, true, false, -1e9
    gv, gv_n, gv_dirty, gv_bad, gv_step = nil, 0, false, {}, nil
end

return M
