-- ============================================================================
-- Master Farmer - Zygor Forever
-- Main — update cascade
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- Folder: Zygor_Forever
-- Standalone IZI. 1.10.0: the walker is Sentinel Navigation
-- (_G.SentinelNavClient, configured by the launcher - MASTER_FARMER.nav),
-- owned by movement/nav.lua through the adapter movement/sentinel.lua; with no
-- Sentinel (or no maps for this game) nothing moves. Sentinel Navigation /
-- Sentinel are not used. movement_handler is not the facing owner
-- (movement/locks.lua faces). Sentinel owns automated travel.
-- Tick (the order the update callback runs): stale check -> deferred menu work
-- -> callbacks -> keybinds -> movement.pulse -> loot.frame; then every BOT_TICK:
-- settings -> spellbook -> trinkets -> Rotation Only -> guide update -> Start
-- gate -> watchdog -> deathzones -> racials (escape) -> longstuck -> death ->
-- managems -> flight / periodic reload -> loot -> conjure -> healing / rest ->
-- buffs -> trainer -> vendor -> equip -> grind XOR quest (combat inside them).
-- ============================================================================

local PLUGIN_MODULES = {
    "spellbook",
    "spell_range",
    "geometry",
    "deathzones",
    "predict",
    "castq",
    "spellcheck",
    "auras",
    "picks",
    "combat",
    "conjure",
    "swingtimer",                                  -- 1.9.2: the melee swing timer
    "priority",                                    -- 1.9.2: the rotation order + sequence recorder
    "quest/guide", "quest/import_probe", "data/guide_prototype",
    "quest/diag",                                  -- audit F7: step automation diagnostics (log only)
    "quest/zygor_tbc", "quest/zygor_midnight",   -- 1.8.0: the client action modules
    "debuglog",
    "actlog",                                      -- 1.75.0: the JSON-Lines action log (errorlog / debuglog write through it)
    "errorlog",
    "watchdog",
    "bags",
    "questitems",                                  -- 1.29.3: quest items in the bags
    "pets",
    "ui",
    "version",
    "state",
    "path_format",
    "data/consumables",
    "loader",
    "gui",
    "targeting",
    "movement",
    -- 3.0.0: the movement layer modules (fresh code on a reload)
    "movement/core", "movement/zones", "movement/sentinel", "movement/mount", "movement/memory", "movement/elevator", "movement/boat", "movement/front", "movement/swim", "movement/astar", "movement/trace", "movement/nav", "movement/locks",
    "movement/range", "movement/combat", "movement/leash", "movement/sight",
    "loot",
    "path_runner",
    "rotations/mage",
    "rotations/warrior",
    "rotation",
    "death",
    "longstuck",
    "bindhearth",                                  -- 1.2.54: learned Hearthstone bind
    "managems",                                    -- 1.8.2: Mage mana gems
    "healing",
    "vendor",
    "trinkets",
    "mapwalk",
    "gossip",
    "supplies",
    "equip",
    "equip_tbc",                                   -- 1.8.0: the TBC item score
    "trainer",
    "resting",
    "racials",
    "stoneform",
    "flightrec",
    "esp",
    "data/esp_nodes",
    "movement/facing",
    "movement/flags",
    "data/racials",
    "data/factions",
    "events",
    "buffs",
    "smart",
    "data/class_spells",
    "settings",
    "data/spell_categories",
    "strafe",
    "merchants",        -- 2.318.0: remembered repair NPCs / innkeepers
    -- audit E2: modules that hold other modules' tables - a reload outside the
    -- launcher must not keep their old copies
    "quest", "quest/engine", "quest/npc", "quest/done", "quest/travel", "quest/mismatch", "quest/bagstart",
    "movement/pivot", "combat", "callbacks", "adapt", "gamever", "power",
    -- audit P1: the grind/ path indexes are gone - there is no grind/ folder
}

for i = 1, #PLUGIN_MODULES do
    package.loaded[PLUGIN_MODULES[i]] = nil
end

---@type izi_api
local izi = require("common/izi_sdk")

local identity = require("version")

-- First, so everything after it can be guarded. Required with pcall: a
-- logger that fails to load must not take the plugin with it.
local errorlog = nil
do
    local ok, mod = pcall(require, "errorlog")
    if ok and type(mod) == "table" then
        errorlog = mod
        errorlog.start(identity.version)
    end
end

--- A flight-recorder probe point (see errorlog.lua). Free when not armed.
local function probe(tag)
    if errorlog then
        errorlog.probe(tag)
    end
end

--- Run fn under the error log, or under a bare pcall without one.
local function guarded(where, fn, ...)
    if errorlog then
        return errorlog.guard(where, fn, ...)
    end
    return pcall(fn, ...)
end

_G.MasterFarmer_Zygor = _G.MasterFarmer_Zygor or {}
local NS = _G.MasterFarmer_Zygor
NS.meta = NS.meta or {
    name = identity.name,
    version = identity.version,
    author = identity.authors,
}
NS._sessions = NS._sessions or {}
if type(NS._sessions[identity.folder]) ~= "number" then
    NS._sessions[identity.folder] = 1
end
local MY_SESSION = NS._sessions[identity.folder]

local function is_stale()
    return NS._sessions[identity.folder] ~= MY_SESSION
end

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function load_mod(name)
    local ok, mod = pcall(require, name)
    if ok then
        return mod
    end
    local oka, al = pcall(require, "actlog")
    if oka and type(al) == "table" then al.console_error("[Master Farmer - Zygor Forever] require failed (" .. name .. "): " .. tostring(mod))
    else core.log_error("[Master Farmer - Zygor Forever] require failed (" .. name .. "): " .. tostring(mod)) end
    if errorlog then
        errorlog.error("require " .. name, mod)
    end
    return nil
end

local gui = load_mod("gui")
if not gui then
    local oka, al = pcall(require, "actlog")
    if oka and type(al) == "table" then al.console_error("[Master Farmer - Zygor Forever] GUI module failed - window will not appear.")
    else core.log_error("[Master Farmer - Zygor Forever] GUI module failed - window will not appear.") end
else
    core.register_on_render_window_callback(function()
        if is_stale() then
            return
        end
        probe("gui.draw")
        guarded("gui.draw", gui.draw)
        probe("-")
    end)
    require("actlog").console(string.format("[Master Farmer - Zygor Forever] v%s GUI ready", identity.version))
end

local state = load_mod("state")
local spellbook = load_mod("spellbook")
local targeting = load_mod("targeting")
local movement = load_mod("movement")
local loot = load_mod("loot")
local rotation = load_mod("rotation")
local death = load_mod("death")
local healing = load_mod("healing")
local conjure = load_mod("conjure")
local picks = load_mod("picks")
local vendor = load_mod("vendor")
local trinkets = load_mod("trinkets")                 -- 1.7.12
local mapwalk = load_mod("mapwalk")                   -- 1.7.13
local equip = load_mod("equip")
local trainer = load_mod("trainer")

-- Game events. Registered once per SESSION, not once per load: the callback
-- cap is per plugin and this file re-runs on every hot reload. events.install
-- keeps the guard on the shared namespace and refreshes the handler table, so
-- a reload picks up new handler code without registering a second callback.
local buffs = load_mod("buffs")
local pets = load_mod("pets")
local debuglog = load_mod("debuglog")
local settings = load_mod("settings")

-- What gets remembered per character.
--
-- Only state held in plain Lua tables is registered here. Every core.menu
-- element already persists against its own id, so a checkbox or slider
-- written here would be stored twice and the two copies would disagree the
-- moment one of them changed.
if settings then
    -- The route as an ID, not an index. An index means a different route
    -- after the catalog gains entries or the faction changes.
    settings.register("route",
        function()
            return gui and type(gui.selected_route_id) == "function" and gui.selected_route_id() or nil
        end,
        function(value)
            if gui and type(gui.select_route_id) == "function" then
                gui.select_route_id(value)
            end
        end)

    -- The Spells tab picks - buff toggles and rotation choices alike. These
    -- only exist after the spellbook scan and so could never have had a menu
    -- element behind them. The key stays "buffs" so a settings file written
    -- by 2.3.0 still loads; picks.deserialise reads that older one-line form
    -- as "these were all switched on", which is what it meant.
    settings.register("buffs",
        function()
            return picks and type(picks.serialise) == "function" and picks.serialise() or nil
        end,
        function(value)
            if picks and type(picks.deserialise) == "function" then
                picks.deserialise(value)
            end
        end)

    -- 1.9.2: the Spells tab rotation order numbers (priority.lua)
    settings.register("spell_order",
        function()
            local okp, prio = pcall(require, "priority")
            return okp and type(prio) == "table" and prio.serialise() or nil
        end,
        function(value)
            local okp, prio = pcall(require, "priority")
            if okp and type(prio) == "table" then prio.deserialise(value) end
        end)

    -- Quest givers learned at a gossip frame, kept per character so an NPC
    -- met in one session is known in the next. Required lazily: quest/guide
    -- is only meaningful when the guide addon is present, and main should not
    -- fail to load because it is not.
    settings.register("npc_ids",
        function()
            local ok, guide = pcall(require, "quest/guide")
            if ok and guide and type(guide.serialise) == "function" then
                return guide.serialise()
            end
            return nil
        end,
        function(value)
            local ok, guide = pcall(require, "quest/guide")
            if ok and guide and type(guide.deserialise) == "function" then
                guide.deserialise(value)
            end
        end)
end
local events = load_mod("events")
if events and type(events.install) == "function" then
    pcall(events.install)
end
-- 2.271.0: IZI callbacks - combat finished, spell cancelled (callbacks.lua)
local izi_callbacks = load_mod("callbacks")
-- 2.274.0: the adaptive rotation reads every spell the player casts (adapt.lua)
local adapt_mod = load_mod("adapt")
if adapt_mod and type(adapt_mod.install) == "function" then
    pcall(adapt_mod.install)
end
if izi_callbacks and type(izi_callbacks.install) == "function" then
    pcall(izi_callbacks.install)
end
local supplies = load_mod("supplies")
local loader = load_mod("loader")
local path_runner = load_mod("path_runner")
local modes = gui and gui.modes or { GRIND = "grind", QUEST = "quest" }

if gui and supplies and type(supplies.register_gui) == "function" then
    pcall(supplies.register_gui, gui.get_menu())
end

if gui and trainer and type(trainer.register_gui) == "function" then
    pcall(trainer.register_gui, gui.get_menu())
end
if gui and equip and type(equip.register_gui) == "function" then
    pcall(equip.register_gui, gui.get_menu())
end

-- The class and racial checkboxes are gone (2.64.0): the Spells tab lists
-- the known class spells and racials itself, and smart.lua builds the
-- rotation from the ones ticked there.
local racials = load_mod("racials")
-- Rogue "Strafe Combat" (2.212.0): micro-strafes while combat movement is in
-- position. Updated once per frame, after the cascade - see the callback.
local strafe = load_mod("strafe")

local nav_halted = false
local move_debug_on = false

local function halt_bot_movement()
    if nav_halted then
        return
    end
    nav_halted = true
    if path_runner then
        path_runner.stop()
    end
    if movement then
        movement.halt()
    end
end

local function allow_bot_movement()
    nav_halted = false
end

--- How far out to look for something to fight.
---
--- The class decides: melee scans tighter than a caster, because melee has to
--- close the distance and then stand still, and every extra mob inside the
--- scan is one more thing arriving during that. The path may ask for a wider
--- scan through its `pull` value, and that still wins - a route author who
--- says "pull from 50 yards here" knows the terrain better than the class
--- default does.
local function scan_yards(player)
    local yards = 30
    if rotation and type(rotation.scan_range) == "function" then
        local ok, n = pcall(rotation.scan_range, player)
        if ok and type(n) == "number" and n >= 5 then
            yards = n
        end
    end
    local current = path_runner.current_path and path_runner.current_path() or nil
    local pull = current and tonumber(current.pull)
    if type(pull) == "number" and pull > yards then
        yards = pull
    end
    if yards > 80 then
        yards = 80
    end
    return yards
end

local function player_is_busy(player)
    if not player then
        return false
    end
    if safe(function() return player:is_channeling_or_casting() end) == true then
        return true
    end
    if safe(function() return player:is_casting_spell() end) == true then
        return true
    end
    if safe(function() return player:is_casting() end) == true then
        return true
    end
    if safe(function() return player:is_channeling() end) == true then
        return true
    end
    return false
end

local function tick_rotation_only(player)
    if not player or not rotation then
        return
    end

    -- The same guard the Play path has had all along.
    --
    -- That check lives at the bottom of on_update, AFTER this branch returns,
    -- so Rotation Only never had it: the rotation was driven every single
    -- frame whether or not a cast was already in flight. On an instant-cast
    -- class that is merely wasteful; on a caster it is fatal, because
    -- Frostbolt takes seconds and the next frame started the decision over
    -- before it could land. "The rotation does not run" is what a caster that
    -- never finishes a cast looks like.
    -- Dead is the one thing that stops Rotation Only outright. Everything
    -- else - no target, out of combat, standing still - is a normal state in
    -- which buffs should still be kept up.
    if safe(function() return player:is_dead_or_ghost() end) == true
        or safe(function() return player:is_dead() end) == true then
        state.set_note("Rotation", "Rotation Only - dead")
        return
    end

    if player_is_busy(player) then
        state.set_note("Rotation", "Rotation Only - casting")
        return
    end

    -- Buff upkeep runs BEFORE the target check, and therefore with or without
    -- an enemy selected.
    --
    -- buffs.lua has always returned true from bot_is_working() when
    -- rotation_only is set - it was written expecting to be called here. It
    -- never was: on_update returns at the Rotation Only branch, and
    -- buffs.tick sits below that, in the Play path. So a Mage in Rotation
    -- Only kept no Armour, no Arcane Intellect and no Mana Shield unless it
    -- happened to have an enemy targeted, and out of combat nothing ran at
    -- all.
    --
    -- Returning after a cast is the same one-action-per-tick rule the rest of
    -- the cascade follows; the buff has a global cooldown to serve.
    if buffs and type(buffs.tick) == "function" and buffs.tick(player) then
        state.set_note("Rotation", "Rotation Only - buffing")
        return
    end
    if rotation.buffs_ooc(player) then
        state.set_note("Rotation", "Rotation Only - buffing")
        return
    end

    local target = safe(function() return player:get_target() end)
    if not target or safe(function() return target:is_valid() end) ~= true then
        state.set_note("Rotation", "Rotation Only - buffs up, select a target")
        return
    end
    if safe(function() return target:is_dead_or_ghost() end) == true or safe(function() return target:is_dead() end) == true then
        state.set_note("Rotation", "Rotation Only - target dead")
        return
    end
    -- Only assert the target when it is not already ours. This ran every
    -- tick on the unit the player had just been read FROM, so it was at best
    -- redundant and at worst a re-target that clipped the cast it had started
    -- the frame before.
    local have = safe(function() return player:get_target() end)
    local same = false
    if have then
        local a = safe(function() return have:get_guid() end)
        local b = safe(function() return target:get_guid() end)
        same = (a ~= nil and a == b)
    end
    if not same then
        do local fr = package.loaded["flightrec"] if fr then fr.note("set_target") end end
        pcall(function()
            core.input.set_target(target)
        end)
    end

    local pack = {}
    if targeting then
        pack = targeting.combat_scan(player, scan_yards(player))
    end
    state.set_note("Rotation", "Rotation Only")
    rotation.tick(player, target, { enemies = pack, no_move = true })
end

-- Incremental collection help, every frame. The host's collector runs on
-- its own schedule; a small step here keeps the heap near what is actually
-- live instead of letting a frame's garbage pile up until the next cycle.
-- Cheap: a step this size does a little marking and sweeping, never a full
-- collection.
local GC_STEP = 16

-- BOT TICK (2.28.0). The Plugin Monitor put Master Farmer at 93 ms of Lua time
-- a frame. Every frame ran the whole decision cascade - death, conjure,
-- healing, the loot scan, buffs, trainer, vendor, equip, then the mode tick
-- with its target scans, combat movement and the class rotation - dozens of
-- native calls and object scans, 60+ times a second, for decisions a bot
-- needs about ten times a second. The cascade now runs every BOT_TICK
-- seconds. What must stay per frame stays per frame: the stale check, izi's
-- own update, keybinds, and movement.pulse (movement.lua: Lk.tick, N.pulse,
-- the stuck watchdog, the pivot - Sentinel itself walks) between decisions.
local BOT_TICK = 0.1
local next_bot_tick = 0
-- audit P8: the per-tick modules are looked up once (an upvalue cache), not
-- pcall(require) on every bot tick; a failed require is not retried each tick
local need_cache = {}
local function need(name)
    local m = need_cache[name]
    if m == nil then
        local ok, mod = pcall(require, name)
        m = (ok and type(mod) == "table") and mod or false
        need_cache[name] = m
    end
    if m then return true, m end
    return false, nil
end

-- ============================================================================
-- PERIODIC UI RELOAD - REMOVED (audit F1, 2026-10-28)
-- ============================================================================
-- 2.189.0 reloaded the game UI every 30 minutes at a safe moment. The call it
-- used, core.reload_game_ui, is declared in NO local stub: it is absent from
-- all nine .api copies under Documents (2026-10-16 .. 2026-10-27), from
-- sylvanas_api/.api and from BLIZZ_PROJECTS/.api, and so are
-- core.reload_plugins and core.reload_scripts. Per AGENTS.md section 2 it does
-- not exist, so the whole block - the 30-minute timer and the fifteen safety
-- checks that guarded it - never did anything but cost a check per frame.
-- Removed rather than left as a guarded call to a function that is nowhere.
-- If a build ever declares a UI-reload API, add it back from this comment.
-- ============================================================================

local function on_update()
    if is_stale() then
        return
    end
    probe("u:begin")
    -- 3.0.0: menu clicks queued while drawing run here, never in the render pass
    if gui and type(gui.run_deferred) == "function" then
        pcall(gui.run_deferred)
    end
    if errorlog then
        errorlog.frame()
    end
    pcall(collectgarbage, "step", GC_STEP)
    if errorlog then
        errorlog.tick(safe(function() return izi.now() end))
    end
    -- 2.315.0: NO izi.on_update. IZI's per-frame engine ran every frame, the
    -- bot started or not, to serve five subscriptions: two hotkey watchers,
    -- combat start / finish, spell success / cancel and izi.after timers -
    -- each one reading the player's (and IZI's tracked units') combat and
    -- cast state through IZI every frame. Three of six crashed sessions on
    -- 2026-10-11 ended with the bot stopped, when nothing but this, the menu
    -- and the idle movement pulse ran. Replaced by core-API polling of the
    -- player only (callbacks.tick), core key polling (gui.process_keybinds)
    -- and the movement pulse's own timers (movement/locks.lua).
    probe("u:callbacks")
    if izi_callbacks and type(izi_callbacks.tick) == "function" then
        pcall(izi_callbacks.tick)
    end
    if not gui then
        return
    end
    probe("u:keybinds")
    gui.process_keybinds()
    if movement then
        local want_debug = gui.is_on("move_debug") == true
        if want_debug ~= move_debug_on then
            move_debug_on = want_debug
            movement.set_debug(want_debug)
        end
        -- The movement state machine ticks before anything else reads its state,
        -- so every consumer this frame sees one consistent owner and state.
        probe("u:movement.pulse")
        pcall(movement.pulse)
    end
    -- 2.198.0: the loot burst runs every frame (attempts one frame apart).
    if loot and type(loot.frame) == "function" then
        probe("u:loot.frame")
        pcall(loot.frame)
    end

    -- Everything below is a decision, and decisions run at BOT_TICK.
    local now_t = safe(function() return izi.now() end) or 0
    if now_t < next_bot_tick and (next_bot_tick - now_t) <= BOT_TICK then
        probe("-")
        return
    end
    next_bot_tick = now_t + BOT_TICK
    if errorlog then
        errorlog.tick_begin()
    end

    local player = safe(function() return izi.me() end)
    if not player or safe(function() return player:is_valid() end) ~= true then
        return
    end
    gui.sync_player(player)
    -- 3.0.0: what the windows show is read here, not while drawing
    pcall(gui.refresh_view, player)
    -- 3.0.0: pet_handler's delayed-command queue (moved off the render pass)
    if pets and type(pets.on_render) == "function" then
        pcall(pets.on_render)
    end
    -- Load once for this character, then flush changes on a debounce. Runs
    -- before the cascade so a restored route is in place for the first tick
    -- that could use it.
    probe("u:settings")
    if settings and type(settings.tick) == "function" then
        pcall(settings.tick, player)
    end
    if targeting then
        targeting.cache_player(player)
    end
    do                                              -- 1.9.2: the swing timer knows whose swings to count
        local ok_st, st = need("swingtimer")
        if ok_st and type(st) == "table" and type(st.tick) == "function" then pcall(st.tick, player) end
    end

    if spellbook then
        spellbook.tick()
        if not spellbook.ready() then
            local left = spellbook.wait_left()
            if state then
                state.set_note("Load", string.format("Waiting for spellbook  %.1fs", left))
            end
            return
        end
    end

    -- 1.7.12: on-use trinkets while the bot (or Rotation Only) runs
    if trinkets and gui.is_on("use_trinkets") and (gui.is_on("enable") or gui.is_on("rotation_only")) then
        probe("u:trinkets")
        local tgt = (state and state.target and state.target.unit) or safe(function() return player:get_target() end)
        local n = (targeting and type(targeting.attackers) == "function") and targeting.attackers(player) or 0
        local ok_tr, used = pcall(trinkets.tick, player, tgt, n)
        if ok_tr and used == true then return end      -- audit Q2: a trinket use is the tick's action
    end

    if gui.is_on("rotation_only") then
        halt_bot_movement()
        if vendor then
            vendor.reset()
        end
        tick_rotation_only(player)
        return
    end

    -- Questing enabled: keep the guide snapshot current from here, the update
    -- callback, so the Questing tab has live data without reading RestedXP
    -- from the render hook - started or not.
    if modes and gui.mode() == modes.QUEST then
        local ok_g, g = need("quest/guide")                -- audit P8
        if ok_g and type(g) == "table" and type(g.update) == "function" then
            pcall(g.update)
        end
        -- audit F7: one summary line every 2 min while something is changing.
        -- Logging only - quest/diag decides nothing and is read by nothing.
        local dg = package.loaded["quest/diag"]
        if type(dg) == "table" and type(dg.tick) == "function" then pcall(dg.tick) end
    end

    if not gui.is_started() then
        -- audit 1.19.0: the watchdog's travel / NPC clocks were never reset on Stop, so a
        -- restart near the old anchor could hearth at once on a stale 5-minute timer
        do
            local wd = package.loaded["watchdog"]
            if type(wd) == "table" and type(wd.reset) == "function" then pcall(wd.reset) end
        end
        -- 1.7.13: a minimap click walk (mapwalk.lua) runs while the bot is stopped
        local map_walking = false
        if mapwalk and gui.is_on("minimap_walk") then
            probe("u:mapwalk")
            local okw, w = pcall(mapwalk.tick, player)
            map_walking = okw and w == true
        elseif mapwalk and mapwalk.active() then
            pcall(mapwalk.stop, "option off")
        end
        if not map_walking then halt_bot_movement() end
        -- 2.257.0: the death-zone Target Selector session ends with Stop
        do
            local dz = package.loaded["deathzones"]
            if type(dz) == "table" and type(dz.release) == "function" then pcall(dz.release) end
        end
        -- audit F7: the diagnostics counters belong to one run
        do
            local dg = package.loaded["quest/diag"]
            if type(dg) == "table" and type(dg.reset) == "function" then pcall(dg.reset) end
        end
        if vendor then
            vendor.reset()
        end
        -- The spellbook wait is the last note written before this return.
        -- Once the scan has finished, leave it there and the status line
        -- stays on "Waiting for spellbook  0.0s" for the whole idle session.
        if state and state.note_head == "Load" then
            state.set_note("Idle", "Idle")
        end
        return
    end
    if mapwalk and mapwalk.active() then pcall(mapwalk.forget) end      -- 1.7.13: Start takes over
    allow_bot_movement()
    -- audit E3: a bind / equip confirmation the event callback flagged is
    -- answered here, while started - one per tick, and that is the tick's action
    do
        local ok_ev, ev = need("events")
        if ok_ev and type(ev.answer_pending) == "function" then
            local ok_a, answered = pcall(ev.answer_pending)
            if ok_a and answered == true then return end
        end
    end

    -- NPC-stuck watchdog: 5 minutes at an NPC resets all NPC state and walks
    -- away (the API cannot reload the game). It claims the tick it acts on.
    local ok_w, watchdog = need("watchdog")             -- audit P8
    if ok_w and type(watchdog) == "table" and type(watchdog.tick) == "function"
        and watchdog.tick(player) then
        return
    end
    if not state or not movement or not death or not rotation or not healing then
        return
    end

    -- 2.247.0: death zones - expiry, navigation zones, Target Selector pulls
    probe("u:deathzones")
    do
        local ok_dz, dz = need("deathzones")            -- audit P8
        if ok_dz and type(dz) == "table" and type(dz.tick) == "function" then pcall(dz.tick) end
    end
    -- 2.255.0: Escape Artist the moment the player is rooted, stunned or sapped
    do
        local ok_r, rc = need("racials")                 -- audit P8
        if ok_r and type(rc) == "table" and type(rc.escape_tick) == "function" then
            probe("u:escape")
            local ok_e, cast = pcall(rc.escape_tick, player)
            if ok_e and cast == true then return end      -- audit Q1: the escape is the tick's action
        end
    end
    -- 1.2.55: what the arrow's dist / goal_num / is_manual really are (log only)
    do
        local ok_g, gd = pcall(require, "quest/guide")
        if ok_g and type(gd) == "table" and type(gd.arrow_probe) == "function" then
            local okp, pp = pcall(function() return player:get_position() end)
            pcall(gd.arrow_probe, okp and pp or nil)
        end
    end
    -- 1.2.73: the ESP scan (360 degrees, 100 yd), twice a second inside
    do
        local ok_es, es = need("esp")
        if ok_es and type(es) == "table" and type(es.tick) == "function" then pcall(es.tick, player) end
    end
    -- 1.2.69: the flight recorder's once-a-second heartbeat (disconnect hunt)
    do
        local ok_fr, fr = need("flightrec")
        if ok_fr and type(fr) == "table" and type(fr.tick) == "function" then pcall(fr.tick, player) end
    end
    -- 1.2.54: learn where the Hearthstone is bound (a hearth landing, the innkeeper's bind)
    do
        local ok_bh, bh = need("bindhearth")
        if ok_bh and type(bh) == "table" and type(bh.tick) == "function" then pcall(bh.tick, player) end
    end
    -- 1.7.33: stuck for 5 minutes - Hearthstone, or log out when dead
    do
        local ok_ls, ls = need("longstuck")              -- audit P8
        if ok_ls and type(ls) == "table" and type(ls.tick) == "function" then
            probe("u:longstuck")
            local ok_t, own = pcall(ls.tick, player)
            if ok_t and own == true then return end
        end
    end
    probe("u:death")
    if death.tick(player) then
        return
    end
    -- 1.8.2: Mage mana gems - one action per update; a tick that conjures or
    -- uses a gem ends here (the quest step does not advance on it)
    do
        local ok_mg, mg = need("managems")               -- audit P8
        if ok_mg and type(mg) == "table" and type(mg.tick) == "function" then
            probe("u:managems")
            local ok_t, acted = pcall(mg.tick, player)
            if ok_t and acted == true then return end
        end
    end
    -- On a flight path (2.95.0): nothing to steer, fight or loot until it lands.
    -- 2.106.0: also the quest engine's own flight tracking (position based),
    -- since is_flying is not proven true on a taxi.
    local on_flight = safe(function() return player:is_flying() end) == true
    if not on_flight then
        local qe = package.loaded["quest/engine"]
        if type(qe) == "table" and type(qe.in_flight) == "function" then
            on_flight = safe(function() return qe.in_flight(player) end) == true
        end
    end
    if on_flight then
        state.set_note("Travel", "On a flight")
        return
    end
    -- The 360-degree enemy scan (2.95.0): attack list + avoid list / danger map.
    if targeting and type(targeting.scan_enemies) == "function" then
        pcall(targeting.scan_enemies, player)
    end
    -- Rest outranks looting. Looting used to come first, and because
    -- loot.tick returns true on every tick while a lootable corpse is in
    -- range, healing.tick was never reached - the bot would sit at 30% mana
    -- working through corpses and never drink. Resting also hard-locks
    -- movement, so loot.tick below cannot walk off mid-drink.
    -- Ahead of healing on purpose. A mage with an empty bag needs to conjure
    -- BEFORE the rest logic goes looking for water, or the rest finds nothing,
    -- reports empty bags, and the bot stands at low mana next to a spell that
    -- would have fixed it. conjure.tick refuses to fire mid-meal, so it cannot
    -- interrupt a rest that is already under way.
    -- LOOT FIRST (2.46.0): once a mob is dead its corpse is looted before
    -- any other action - conjuring, eating and drinking, buffs, trainer,
    -- vendor, equip, the next pull. loot.tick still steps aside for anything
    -- attacking the player.
    probe("u:loot")
    if loot and loot.tick(player) then
        return
    end
    -- 1.9.2: a bag just looted goes on at once (equip.bag_tick)
    probe("u:bags")
    if equip and type(equip.bag_tick) == "function" and equip.bag_tick(player) then
        return
    end
    probe("u:conjure")
    if conjure and type(conjure.tick) == "function" and conjure.tick(player) then
        return
    end
    probe("u:healing")
    -- REST PROBE (2.193.0): time this call; a slow one writes a SPIKE line.
    if errorlog and type(errorlog.spike_begin) == "function" then errorlog.spike_begin("u:healing") end
    local rested = healing.tick(player)
    if errorlog and type(errorlog.spike_end) == "function" then errorlog.spike_end() end
    if rested then
        return
    end
    -- Self-buff upkeep. Sits with the class buffs because it answers the
    -- same question, and after healing.tick so a rest is never interrupted
    -- to refresh something.
    probe("u:buffs")
    if buffs and type(buffs.tick) == "function" and buffs.tick(player) then
        return
    end
    probe("u:buffs_ooc")
    if rotation.buffs_ooc(player) then
        return
    end
    probe("u:busy")
    if player_is_busy(player) then
        state.set_note("Wait", "Casting")
        return
    end

    -- Ahead of the vendor trip on purpose: both want the gossip frame, and
    -- selecting the trainer option replaces whatever is open. Training is the
    -- rarer opportunity, and vendor.tick re-opens the merchant by itself.
    probe("u:trainer")
    if trainer and type(trainer.tick) == "function" and trainer.tick(player) then
        return
    end
    -- 1.2.15: a vendor trip that is only WALKING fights what stands in its path, like the quest walk does
    -- (the character ran into a mob's threat range on the way to the inn and never attacked)
    do
        local qe = package.loaded["quest/engine"]
        if vendor and type(qe) == "table" and type(qe.path_threat) == "function"
            and type(vendor.is_busy) == "function" and vendor.is_busy() == true
            and not (type(vendor.is_interacting) == "function" and vendor.is_interacting() == true) then
            local ok_p, hit = pcall(qe.path_threat, player)
            if ok_p and hit == true then return end
        end
    end
    probe("u:vendor")
    if vendor and vendor.tick(player) then
        return
    end

    -- After vendor on purpose: equipping and selling are the same underlying
    -- call (use_container_item), so this must be unreachable while a merchant
    -- window is open or an upgrade gets sold instead of worn.
    probe("u:equip")
    if equip and type(equip.tick) == "function" and equip.tick(player) then
        return
    end

    if path_runner then
        path_runner.stop()
    end

    local mode = gui.mode()
    if mode == modes.QUEST then
        local quest = loader and loader.ensure_quest() or nil
        if not quest then
            state.set_note("Quest", "Quest pack failed to load")
            return
        end
        if quest.is_ready(player) then
            probe("u:quest.tick")
            quest.tick(player)
            probe("u:quest.tick done")
        else
            state.set_note("Quest", "Zygor Guides is not loaded - enable the Zygor Guides addon")
        end
        return
    end

    -- 4.0.0: gathering moved to the Herbing & Mining product (launcher card 4).

    if mode == modes.GRIND then
        local grind = loader and loader.ensure_grind() or nil
        if not grind then
            state.set_note("Grind", "Grind pack failed to load")
            return
        end
        probe("u:grind.tick")
        grind.tick(player)
        probe("u:grind.tick done")
        return
    end
end

local function on_render()
    -- 2.257.0: a superseded instance does nothing here - this check comes first,
    -- before movement, pets and the debug log below.
    if is_stale() then
        return
    end
    if movement then
        pcall(movement.on_render)
    end
    -- pet_handler queues delayed state changes and moves and only runs them
    -- when it is pumped. A delay that silently never fires is a bad thing to
    -- leave lying around, so this runs whether or not anything uses one yet.
    -- No-op on a build without the handler.
    -- 3.0.0: the pet handler's delayed commands are pumped on the update
    -- tick (main on_update), never here: they send game commands.
    -- Debug lines are buffered and written on a debounce: each flush empties
    -- the file (create_data_file) and writes the whole capped buffer, because
    -- write_data_file appends. Without this they never reach scripts_data.
    if debuglog and type(debuglog.tick) == "function" then
        pcall(debuglog.tick)
    end
    -- 1.2.81: the Movement Handler's pump - once per render frame (its delays and auto-resume need it); no casting, no decisions
    do
        local fa = package.loaded["movement/facing"]
        if type(fa) == "table" and type(fa.pump) == "function" then pcall(fa.pump) end
    end
    -- 1.2.73: the ESP overlay - graphics only, from the stored scan
    do
        local es = package.loaded["esp"]
        if type(es) == "table" and type(es.draw) == "function" then pcall(es.draw) end
    end
    if gui and gui.is_on("draw_path") and path_runner and type(path_runner.draw) == "function" then
        pcall(function()
            path_runner.draw()
        end)
    end
end

-- What the bot was doing, attached to every error in the log.
if errorlog then
    errorlog.set_context(function()
        local ctx = {}
        ctx.mode = gui and gui.mode() or "-"
        ctx.started = gui and gui.is_started() or false
        ctx.status = state and (tostring(state.note_head or "") .. " " .. tostring(state.note or "")) or "-"
        if state and type(state.note_t) == "number" then
            local okt, tt = pcall(function() return core.time() end)
            if okt and type(tt) == "number" then ctx.status_age = math.floor(tt - state.note_t) end
        end
        local me = safe(function() return izi.me() end)
        if me then
            local p = safe(function() return me:get_position() end)
            if p then
                ctx.position = string.format("%.1f, %.1f, %.1f", p.x or 0, p.y or 0, p.z or 0)
                ctx.pos = { x = p.x, y = p.y, z = p.z }
            end
            ctx.level = safe(function() return me:get_level() end)
            ctx.in_combat = safe(function() return me:is_in_combat() end)
            ctx.hp = safe(function() return me:get_health_percentage() end)
            ctx.mounted = safe(function() return me:is_mounted() end)
            ctx.moving = safe(function() return movement and movement.is_moving() end)
            local okp, pw = pcall(require, "power")
            if okp and type(pw) == "table" and type(pw.mana_pct) == "function" then
                ctx.mana = safe(function() return pw.mana_pct(me) end)
            end
            local tu = state and state.target and state.target.unit
            if tu then
                ctx.target_name = safe(function() return tu:get_name() end)
                ctx.target_hp = safe(function() return tu:get_health_percentage() end)
                ctx.target_dist = safe(function() return me:distance_to(tu) end)
            end
        end
        ctx.map_id = safe(function() return core.get_map_id() end)
        ctx.map = safe(function() return core.get_map_name() end)
        if state and state.target then
            ctx.target = state.target.kind
        end
        local ok_g, guide = pcall(require, "quest/guide")
        if ok_g and type(guide) == "table" and type(guide.describe) == "function" then
            ctx.guide = safe(guide.describe)
            if type(guide.step_num) == "function" then ctx.step = safe(guide.step_num) end
        end
        return ctx
    end)
end

-- Sentinel walks asked for since the last MEM line (movement/nav stats).
if errorlog then
    errorlog.set_mem_extra(function()
        local okm, mv = pcall(require, "movement")
        if not okm or type(mv) ~= "table" or type(mv.nav_stats) ~= "function" then
            return nil
        end
        local s = mv.nav_stats()
        if type(s) ~= "table" then return nil end
        local text = string.format("sentinel walks %d issued, %d refused, %d floor queries, %d deferred stops",
            s.issued or 0, s.refused or 0, s.floors or 0, s.deferred_stops or 0)
        s.issued, s.refused, s.floors, s.deferred_stops = 0, 0, 0, 0
        return text
    end)
end

-- RestedXP may only be read inside this callback (quest/guide.lua,
-- allow_reads): never from a render hook.
local quest_guide = nil
do
    local ok, mod = pcall(require, "quest/guide")
    if ok and type(mod) == "table" and type(mod.allow_reads) == "function" then
        quest_guide = mod
    end
end

-- What each BEAT line reports beside the stages: status, health, combat,
-- and the kill target with its distance.
if errorlog then
    errorlog.set_beat_extra(function()
        local me = safe(function() return izi.me() end)
        local hp = me and safe(function() return me:get_health_percentage() end)
        -- Mana too (2.67.0): a rest that never starts is invisible without it.
        local mp = nil
        local ok_pw, pw = pcall(require, "power")
        if me and ok_pw and type(pw) == "table" and pw.has_mana(me) then
            mp = pw.mana_pct(me)
        end
        local cbt = me and safe(function() return me:is_in_combat() end)
        local tgt = "-"
        local u = state and state.target and state.target.unit
        if u and safe(function() return u:is_valid() end) ~= true then
            u = nil
        end
        if u then
            local name = safe(function() return u:get_name() end)
            local d = me and safe(function() return me:distance_to(u) end)
            tgt = string.format("%s %.1fy", tostring(name), tonumber(d) or -1)
        end
        return string.format("%s | hp %s%s%s | tgt %s",
            tostring(state and state.note or ""),
            hp and string.format("%.0f", hp) or "?",
            mp and string.format(" mp %.0f", mp) or "",
            cbt and " combat" or "", tgt)
    end)
end

-- COMPILED DATA CHUNKS (2.220.0). The HTTP loader leaves every module's
-- compiled main chunk in package.preload for the session. For a data file
-- that chunk is the whole table constructor - 800 KB for data/rxp_targets - and
-- once the module is in package.loaded it is never run again. These are
-- released once loaded; nothing unloads them at run time (only grind zone and
-- grind route files are unloaded and re-required, and they are not listed).
-- A host without package.preload (or a local folder load) is unaffected.
local DATA_CHUNKS = {
    "data/ek_inns", "data/class_spells", "data/taxi_nodes",
    "data/forever_spells", "data/spell_categories", "data/consumables", "data/racials",
    "data/factions",
}
local data_chunks_t = -1e9

local function release_data_chunks()
    local pre, loaded = package.preload, package.loaded
    if type(pre) ~= "table" or type(loaded) ~= "table" then return end
    for i = 1, #DATA_CHUNKS do
        local name = DATA_CHUNKS[i]
        if pre[name] ~= nil and type(loaded[name]) == "table" then
            pre[name] = nil
        end
    end
end

core.register_on_update_callback(function()
    -- audit E1: a superseded instance only lets go of its strafe keys - no
    -- guide reads, no snapshot refresh, no data chunks, no errorlog tick
    if is_stale() then
        if strafe then pcall(strafe.stop) end
        return
    end
    if quest_guide then
        quest_guide.allow_reads(true)
    end
    guarded("on_update", on_update)
    if quest_guide then
        local okq, qm = pcall(require, "quest")
        if okq and type(qm) == "table" and type(qm.refresh_snapshot) == "function" then
            guarded("quest_snapshot", qm.refresh_snapshot)
        end
    end
    local ok_rel, t_rel = pcall(core.time)
    t_rel = ok_rel and tonumber(t_rel) or 0
    if (t_rel - data_chunks_t) >= 5 then
        data_chunks_t = t_rel
        pcall(release_data_chunks)
    end
    -- After the cascade on purpose: a combat_engage that just left its band
    -- and issued the chase has its strafe key let go on this same frame. A
    -- superseded instance only ever lets go.
    if strafe then
        if is_stale() then
            pcall(strafe.stop)
        else
            guarded("strafe", strafe.update)
        end
    end
    if quest_guide then
        quest_guide.allow_reads(false)
    end
    if errorlog then
        errorlog.tick_end()
    end
    probe("-")
end)
core.register_on_render_callback(function()
    probe("on_render")
    guarded("on_render", on_render)
    probe("-")
end)

require("actlog").console(string.format("[Master Farmer - Zygor Forever] v%s loaded by %s", identity.version, identity.authors))

-- 2.257.0: UNLOAD. The launcher (Master_Farmer loader.lua) calls on_unload and
-- removes the callbacks it routed for this instance. There is no core API to
-- unregister a callback, so outside the launcher (a folder loaded directly) the old
-- callbacks stay registered: the session counter is bumped so every one of
-- them sees is_stale() and returns at once. _G.MasterFarmer_Zygor stays:
-- header.lua (session counter, meta), events.lua (event handlers, read by
-- the event callback) and gui.lua (session) all read it.
local function on_unload()
    NS._sessions[identity.folder] = (NS._sessions[identity.folder] or MY_SESSION) + 1
    if path_runner then pcall(path_runner.stop) end
    if movement then pcall(movement.halt) end      -- 1.10.0: Sentinel stop
    if strafe then pcall(strafe.stop) end
    do local fa = package.loaded["movement/facing"] if type(fa) == "table" and type(fa.release) == "function" then pcall(fa.release, "unload") end end
    local dz = package.loaded["deathzones"]
    if type(dz) == "table" and type(dz.release) == "function" then pcall(dz.release) end
    pcall(function() core.input.move_forward_stop() end)
    pcall(function() core.input.move_backward_stop() end)
    if izi_callbacks and type(izi_callbacks.uninstall) == "function" then pcall(izi_callbacks.uninstall) end
    if adapt_mod and type(adapt_mod.uninstall) == "function" then pcall(adapt_mod.uninstall) end
    -- audit 2026-10-17 (H2): under the launcher, unload removes the callbacks it
    -- routed for this load - clear the register-once flags so the next load
    -- registers the game-event and spell-cast callbacks again
    if type(MASTER_FARMER) == "table" then
        NS.events_registered = nil
        NS.adapt_cast_cb = nil
    end
    if debuglog and type(debuglog.flush) == "function" then pcall(debuglog.flush, true) end
    local ok_al, al = pcall(require, "actlog")
    if ok_al and type(al) == "table" then pcall(al.stop, "unload") end
end

return { on_unload = on_unload }
