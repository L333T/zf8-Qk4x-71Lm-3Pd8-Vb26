-- ============================================================================
-- Master Farmer - Zygor Forever
-- stoneform.lua - when the Dwarf racial Stoneform (spell 20594) is used
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.2.67
-- ============================================================================
-- Stoneform removes bleed, poison and disease effects and reduces physical damage for 8 s. It used to go out at the start of
-- every fight (1.2.23); 1.2.67 (user) makes it a SURVIVAL tool. racials.lua asks M.decide(player) for a reason, in this order
-- (each rule is checked only after the gate):
--
--   GATE        not stunned, feared, sapped or otherwise incapacitated (nothing is cast then); not on the global cooldown -
--               except for rule 1, which is the one that saves the character. The cooldown itself is checked by racials.lua.
--   1 emergency   in combat, health below EMERGENCY_HP, and something is attacking the player.
--   2 snare       slowed by a poison (a crippling / snaring poison): at once, whatever the health.
--   3 dot         a bleed, poison or disease on the player and health at or below DOT_HP - in or out of combat.
--   4 multi-pull  in combat, MULTI_N or more enemies attacking the player and health below MULTI_HP: early, for the full 8 s.
--   5 retreat     in combat, the player is moving (not attacking, not casting) while attacked and health below RETREAT_HP.
--
-- WHICH DEBUFF IS A BLEED / POISON / DISEASE: the live API declares no dispel type for an aura (game_object:get_debuffs()
-- gives name, id, count, times and an undocumented `type`), so the debuff NAME decides: the patterns below. A debuff that
-- is not named like one is not counted - Stoneform is then used by the health rules (1, 4, 5) only.
-- ============================================================================

local M = {}

M.EMERGENCY_HP = 35
M.DOT_HP = 50
M.MULTI_HP = 75
M.MULTI_N = 2
M.RETREAT_HP = 50
M.SNARE_SLOW = 0.30           -- is_slowed threshold: 30 % or more
local SCAN_TTL = 0.5

-- name patterns (Lua patterns, case-sensitive, frontier-anchored where a short word could sit inside another)
local BLEED = { "Bleed", "%f[%a]Rend%f[%A]", "Garrote", "Rupture", "Deep Wound", "%f[%a]Rake%f[%A]", "%f[%a]Rip%f[%A]",
    "Lacerat", "Pounce", "Rend Flesh", "Savage Bite" }
local POISON = { "Poison", "Venom", "Serpent Sting", "Viper Sting", "Spider Bite", "Wyvern Sting" }
local DISEASE = { "Disease", "Plague", "Fever", "Infected", "Infection", "Rabies", "Festering", "Putrid", "%f[%a]Rot%f[%A]", "Blight" }

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function matches(name, list)
    if type(name) ~= "string" then return false end
    for i = 1, #list do
        if name:find(list[i]) then return true end
    end
    return false
end

--- What the player's debuffs contain: dot (a bleed / poison / disease), poison (a poison among them), name of the first.
local scan = { t = -1e9, dot = false, poison = false, name = nil }
function M.debuffs(player, now)
    now = now or 0
    if now - scan.t < SCAN_TTL then return scan.dot, scan.poison, scan.name end
    scan.t, scan.dot, scan.poison, scan.name = now, false, false, nil
    local list = player and safe(player.get_debuffs, player)
    if type(list) == "table" then
        for i = 1, #list do
            local b = list[i]
            local nm = type(b) == "table" and (b.buff_name or b.name) or nil
            local isp = matches(nm, POISON)
            if isp or matches(nm, BLEED) or matches(nm, DISEASE) then
                scan.dot = true
                scan.name = scan.name or nm
                if isp then scan.poison = true end
            end
        end
    end
    return scan.dot, scan.poison, scan.name
end

local function health_pct(player)
    local cur, mx = safe(player.get_health, player), safe(player.get_max_health, player)
    if type(cur) == "number" and type(mx) == "number" and mx > 0 then return cur / mx * 100 end
    local p = safe(player.get_health_percentage, player)
    if type(p) == "number" then return p end
    return 100
end

local function incapacitated(player)
    return safe(player.is_stunned, player, 0) == true or safe(player.is_feared, player, 0) == true
        or safe(player.is_sapped, player, 0) == true or safe(player.is_incapacitated, player, 0) == true
end

--- The reason to use Stoneform now (a short string), or nil. `now`: izi.now(); `attackers`: units attacking the player.
function M.decide(player, now, attackers)
    if not player then return nil end
    if incapacitated(player) then return nil end
    local hp = health_pct(player)
    local in_combat = safe(player.is_in_combat, player) == true
    attackers = tonumber(attackers) or 0

    -- 1. emergency: the survival rule goes through the global cooldown
    if in_combat and hp < M.EMERGENCY_HP and attackers >= 1 then
        return string.format("emergency: health %.0f%% under attack (%d)", hp, attackers)
    end
    local gcd = tonumber(safe(player.gcd_remains, player)) or 0
    if gcd > 0.05 then return nil end

    -- 2 / 3: debuffs - only looked at when they could matter
    local slowed = safe(player.is_slowed, player, M.SNARE_SLOW) == true
    if slowed or hp <= M.DOT_HP then
        local dot, poison, name = M.debuffs(player, now)
        if slowed and poison then return string.format("snare poison: %s", tostring(name)) end
        if dot and hp <= M.DOT_HP then return string.format("%s and health %.0f%%", tostring(name), hp) end
    end
    if not in_combat then return nil end

    -- 4. multi-pull: early, for the full 8 seconds
    if attackers >= M.MULTI_N and hp < M.MULTI_HP then
        return string.format("%d enemies attacking, health %.0f%%", attackers, hp)
    end
    -- 5. retreat: moving away while attacked and hurt, not fighting back
    if attackers >= 1 and hp < M.RETREAT_HP and safe(player.is_moving, player) == true
        and safe(player.is_auto_attacking, player) ~= true
        and safe(player.is_casting_spell, player) ~= true and safe(player.is_channelling_spell, player) ~= true then
        return string.format("retreating at health %.0f%% under attack (%d)", hp, attackers)
    end
    return nil
end

return M
