-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/swim.lua - 1.74.0: no swimming travel
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- Travel is Sentinel move_to on walkable navmesh floors (movement/nav.lua).
-- This module only answers whether the player is in the water so product
-- hops / sit / backpedal keys do not become a swim-up.
-- ============================================================================

local SW = {}

local st = {
    rising = false, last_land = nil, land_why = nil, land_miss = false, surface_z = nil,
}
SW._st = st

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

--- The player is in the water (swim physics).
function SW.swimming()
    local ch = core and core.character
    return type(ch) == "table" and call(ch.is_swimming) == true
end

--- No product jump now (in the water a jump is a swim up).
function SW.no_jump() return SW.swimming() end

function SW.breathing_buff() return false end

function SW.surface_z() return nil end

function SW.request_land() return false end

function SW.land_wanted() return false end

function SW.water_breathing_combat() return false end

--- 1.74.0: water targets use the same navmesh walk as land targets.
function SW.water_targets() return false end

function SW.rising() return false end

function SW.tick()
end

function SW.reset()
    st.rising, st.land_why, st.land_miss = false, nil, false
end

return SW
