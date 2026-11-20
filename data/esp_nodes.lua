-- ============================================================================
-- Master Farmer - Zygor Forever
-- data/esp_nodes.lua - gathering node names for the ESP (esp.lua), 1.2.73
-- ============================================================================
-- A world object is a herb or an ore node when its get_name() is one of these (Classic / TBC names). The live API gives no
-- node type, so the NAME decides; a node not listed here is simply not drawn. Add a name to extend it.
-- ============================================================================

local M = {}

M.herb = {
    "Peacebloom", "Silverleaf", "Earthroot", "Mageroyal", "Briarthorn", "Stranglekelp", "Bruiseweed", "Wild Steelbloom",
    "Grave Moss", "Kingsblood", "Liferoot", "Fadeleaf", "Goldthorn", "Khadgar's Whisker", "Wintersbite", "Firebloom",
    "Purple Lotus", "Arthas' Tears", "Sungrass", "Blindweed", "Ghost Mushroom", "Gromsblood", "Golden Sansam", "Dreamfoil",
    "Mountain Silversage", "Plaguebloom", "Icecap", "Black Lotus", "Bloodvine",
    -- TBC
    "Felweed", "Dreaming Glory", "Ragveil", "Terocone", "Ancient Lichen", "Netherbloom", "Nightmare Vine", "Mana Thistle",
    "Flame Cap", "Fel Lotus",
}

M.ore = {
    "Copper Vein", "Tin Vein", "Incendicite Mineral Vein", "Lesser Bloodstone Deposit", "Silver Vein", "Iron Deposit",
    "Indurium Mineral Vein", "Gold Vein", "Mithril Deposit", "Truesilver Deposit", "Dark Iron Deposit", "Small Thorium Vein",
    "Rich Thorium Vein", "Ooze Covered Silver Vein", "Ooze Covered Gold Vein", "Ooze Covered Mithril Deposit",
    "Ooze Covered Truesilver Deposit", "Ooze Covered Thorium Vein", "Ooze Covered Rich Thorium Vein",
    -- TBC
    "Fel Iron Deposit", "Adamantite Deposit", "Rich Adamantite Deposit", "Khorium Vein",
}

local by_name = {}
for _, n in ipairs(M.herb) do by_name[n] = "herb" end
for _, n in ipairs(M.ore) do by_name[n] = "ore" end

--- "herb", "ore" or nil for an object name.
function M.kind(name)
    if type(name) ~= "string" then return nil end
    return by_name[name]
end

return M
