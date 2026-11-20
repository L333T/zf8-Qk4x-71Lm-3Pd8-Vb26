-- ============================================================================
-- Master Farmer - Zygor Forever
-- Header — load gate
-- ============================================================================
-- Purpose: WoW Forever only + IZI gate. Not class-locked.
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua (the return table below)
-- Folder: Zygor_Forever
-- ============================================================================

local identity = require("version")

local plugin = {}
plugin["name"] = identity.name
plugin["short_tag"] = identity.short_tag
plugin["version"] = identity.version
plugin["author"] = identity.authors
plugin["load"] = true

-- LOADS ONLY ON WOW FOREVER: core.get_game_version() "Forever" (the Forever
-- beta answers "Forever" too; its exact build is "wow_forever_beta_us"),
-- read through gamever.lua - the one module that reads the game version.
-- Forever is not TBC. Not on Titan (Zygor is not released there:
-- core.addons.zygor.is_loaded() is always false).
-- No HTTP to the navigation engine port; the load line is logged only.

local function call(fn, ...)
    if type(fn) ~= "function" then return false, "missing" end
    return pcall(fn, ...)
end

-- audit V2: gamever.lua is the only reader of the game version
local okg, gv = pcall(require, "gamever")
local okv, version = false, "unknown"
local oke, exact = false, "unknown"
if okg and type(gv) == "table" then
    okv, version = call(gv.version)
    oke, exact = call(gv.exact)
end
local load = okg and type(gv) == "table" and type(gv.is_forever) == "function" and gv.is_forever() == true

local line = string.format("Zygor Forever %s header: load=%s game_version=%s exact=%s",
    plugin["version"], tostring(load), tostring(version), tostring(oke and exact or exact))
call(core.log, "[Master Farmer - Zygor Forever] " .. line)

if not load then
    call(core.log, "[Zygor Forever] not loaded: this product runs on WoW Forever only (game version "
        .. tostring(version) .. ")")
    plugin["load"] = false
    return plugin
end

local izi_ok, izi = pcall(require, "common/izi_sdk")
if (not izi_ok) or type(izi) ~= "table" then
    core.log_error("[Master Farmer - Zygor Forever] common/izi_sdk is unavailable - plugin not loaded.")
    plugin["load"] = false
    return plugin
end

local required_izi = {
    "spell",
    "item",
    "enemies",
    "me",
    "now",
}
local missing = {}
for i = 1, #required_izi do
    local field = required_izi[i]
    if type(izi[field]) ~= "function" then
        missing[#missing + 1] = field
    end
end
if #missing > 0 then
    core.log_error("[Master Farmer - Zygor Forever] izi_sdk missing: " .. table.concat(missing, ", "))
    plugin["load"] = false
    return plugin
end

_G.ZygorForever = _G.ZygorForever or {}
local NS = _G.ZygorForever
NS.meta = {
    name = identity.name,
    version = identity.version,
    author = identity.authors,
    description = identity.description,
}
NS._sessions = NS._sessions or {}
NS._sessions[identity.folder] = (NS._sessions[identity.folder] or 0) + 1

return plugin
