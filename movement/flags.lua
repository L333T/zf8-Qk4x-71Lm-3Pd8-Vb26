-- ============================================================================
-- Master Farmer - Zygor Forever
-- movement/flags.lua - the collision masks for every game ray (1.2.82)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.2.82
-- ============================================================================
-- (user: "check and ensure enum collision, LoS and other enums are being used correctly") enums.collision_flags is a set of bitmask
-- CONSTANTS (the live stub, common/enums.lua: None, DoodadCollision 0x1, WmoCollision 0x10, Terrain 0x100, EntityCollision 0x100000,
-- LineOfSight 0x100010, ... and combine(...names)). One place builds the masks core.graphics.trace_line is given, so the A* (astar.lua)
-- and the ray helpers (trace.lua) cannot disagree:
--
--   WALK    DoodadCollision | WmoCollision        solid STATIC geometry a body walks into at knee / chest height. NO terrain (a ray
--                                                 along a slope would hit the ground), NO entities (a mob or an NPC is not a wall).
--   GROUND  WALK | Terrain                        the floor under a point (rays down).
--   STATIC  = GROUND                              steps, ledges, walls - the world's solid geometry, measured against terrain too.
--   COLLISION = STATIC                            (the old name: it used to ADD EntityCollision, so a standing mob counted as an
--                                                 obstacle - "an obstacle 0.6 yd high ahead" jumped over a gnome - 1.2.82).
--   LOS     LineOfSight, ALONE                    the game's own line-of-sight mask (0x100010). It already holds the WMO bit and the
--                                                 line-of-sight bit; OR-ing DoodadCollision (0x1) on top made thin collision-only
--                                                 doodads (fences, brush) block a line the game itself calls clear.
--   Never EntityRender / Cull / the render flags (raise / crashed classic).
--
-- trace_line answers true for a CLEAR line (1.2.41). Nothing here casts a ray.
-- ============================================================================

local M = {}

local built = nil           -- nil = not built, false = unavailable, table = the masks

local function bit_set(value, bit)
    if type(value) ~= "number" or type(bit) ~= "number" or bit <= 0 then return false end
    return math.floor(value / bit) % 2 == 1
end

local function build()
    local ok, enums = pcall(require, "common/enums")
    local cf = ok and type(enums) == "table" and enums.collision_flags or nil
    if type(cf) ~= "table" or type(cf.combine) ~= "function" then return false end
    local function c(...)
        local names = { ... }
        local okc, v = pcall(function() return cf.combine(unpack(names)) end)
        return okc and type(v) == "number" and v or nil
    end
    local walk = c("DoodadCollision", "WmoCollision")
    local ground = c("DoodadCollision", "WmoCollision", "Terrain")
    -- the game's line-of-sight mask exactly: the constant itself, else combine("LineOfSight") alone
    local los = (type(cf.LineOfSight) == "number" and cf.LineOfSight) or c("LineOfSight")
    if not (walk and ground) then return false end            -- LOS is optional: a client without it has no LOS rays, the A* and the walls still work
    local t = { WALK = walk, GROUND = ground, STATIC = ground, COLLISION = ground, LOS = los }
    -- the entity bit must not be in a WALK / GROUND / STATIC mask (it is in LineOfSight by the game's own definition)
    local ent = type(cf.EntityCollision) == "number" and cf.EntityCollision or nil
    t.entity_in_walk = ent ~= nil and (bit_set(walk, ent) or bit_set(ground, ent))
    t.entity_bit = ent
    return t
end

--- { WALK, GROUND, STATIC, COLLISION, LOS } as numbers, or nil when the enum cannot supply them.
function M.get()
    if built == nil then built = build() end
    return built or nil
end

--- One line for the log: the masks in hex and whether an entity bit leaked into the world masks.
function M.describe()
    local f = M.get()
    if not f then return "collision flags: unavailable (common/enums collision_flags / combine)" end
    return string.format("collision flags: WALK=0x%X GROUND=0x%X STATIC=0x%X LOS=%s (%s)", f.WALK, f.GROUND, f.STATIC,
        f.LOS and string.format("0x%X", f.LOS) or "n/a",
        f.entity_in_walk and "ENTITY bit in a world mask!" or "no entity bit in the world masks")
end

function M.reset() built = nil end

return M
