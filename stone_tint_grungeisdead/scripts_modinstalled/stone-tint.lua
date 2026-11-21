-- Tint natural stone and soil floors (and the edges they hang over open
-- ground), engraved floors, stairs and ramps by their actual material.
--@ module = true

-- ==========================================
-- A COMMAND WHILE THE OVERLAY IS RUNNING
-- ==========================================
-- A console command runs this whole file again, in the same environment the
-- overlay's module uses (dfhack.run_script_with_env keeps one environment per
-- script), and defclass updates an existing class in place rather than making
-- a new one (class.lua). So the overlay already on screen took the new copy of
-- onRenderFrame, and with it a fresh, empty copy of every local below: its
-- caches, its sentinel, its frame counter. Read in DFHack's dfhack.lua and
-- class.lua 2026-11-15. Each `stone-tint status` or `stone-tint` made the next
-- frames learn the whole screen again, every material and every picture, and
-- counted as a "texture reset": the one reset per status seen in every test
-- that day, none of them DF's. So once the module has loaded, a command is
-- answered by the copy already running (stone_tint_command, at the end), and
-- the rest of this file is not run again. A changed file takes effect at the
-- next full recycle, as with any module.
if not dfhack_flags.module and stone_tint_command then
    return stone_tint_command(...)
end

local overlay = require('plugins.overlay')
local tile_material = require('tile-material')
local gui = require('gui')
local widgets = require('gui.widgets')

-- Above 50 for the Keep texture style (THE TINT), which keeps the picture's
-- texture whole at any strength.
local STRENGTHS = {0, 10, 15, 20, 25, 30, 40, 50, 60, 75, 100}
-- The tint styles (THE TINT): in the window's order as {value, label}, and
-- each value as a key, to check a saved or typed one.
local TINT_STYLES = {{'keep', 'Keep texture'}, {'smooth', 'Smooth'}, {'classic', 'Classic'},
    keep=true, smooth=true, classic=true}
local GLOBAL_KEY = 'stone-tint'
local CELL_PX = 32
-- New textures made per frame at most. The first sight of a material makes one
-- texture per kind of tile it covers; a z-level full of new materials would
-- otherwise make them all in one frame and stall it. A tile waiting its turn
-- keeps DF's own picture for a frame or two.
local NEW_TEXTURES_PER_FRAME = 12

-- ==========================================
-- THE ART
-- ==========================================
-- Vanilla's floor, stair and ramp art as Lua data, written by
-- build_stone_tint_art.py. Each pixel carries its key column, the palette
-- column its tint blends toward. Tiles are now tinted from the picture DF
-- actually drew (THE ART AS DRAWN), so this is what engraved floors are drawn
-- from, what a picture that cannot be read falls back to, and where ramp cells
-- are worked out from the walls (RAMP_CELL). It is still required: without it
-- nothing is tinted.
local ok_art, art = pcall(reqscript, 'stone-tint/art-vanilla')
if not ok_art or type(art) ~= 'table' or not art.CELLS then
    dfhack.printerr('stone-tint: could not load stone-tint/art-vanilla.lua; nothing will be tinted')
    art = nil
end

-- ==========================================
-- KINDS OF TILE
-- ==========================================
-- Every picture stone-tint can draw gets an id: its art cell, the switch group
-- that turns it on, and the kind it is counted as in `stone-tint status`.
-- Groups: a soil tile needs both "Include soil" and the switch for its shape.
local G_ROUGH, G_SMOOTH, G_STAIRS, G_RAMPS = 1, 2, 3, 4
local G_SOIL_FLOORS, G_SOIL_STAIRS, G_SOIL_RAMPS = 5, 6, 7
local G_ENGRAVED = 8
local K_FLOOR, K_STAIR, K_RAMP, K_ENGRAVED = 1, 2, 3, 4

local ART_CELL, ART_GROUP, ART_KIND = {}, {}, {}
local function add_art(cell, group, kind)
    local id = #ART_CELL + 1
    ART_CELL[id], ART_GROUP[id], ART_KIND[id] = cell, group, kind
    return id
end

-- 1 to 13: stone floors, in the order of VARIANTS below.
local FLOOR_SUFFIXES = {'1', '2', '3', '4', '5', '6', '7', '8', '9', '5b', '5c', '5d'}
for _, n in ipairs(FLOOR_SUFFIXES) do add_art('stone_floor_' .. n, G_ROUGH, K_FLOOR) end
add_art('smooth_floor', G_SMOOTH, K_FLOOR)
-- 14 to 25: soil floors, the same twelve on the dirt rows.
local FIRST_SOIL_FLOOR = #ART_CELL + 1
for _, n in ipairs(FLOOR_SUFFIXES) do add_art('soil_floor_' .. n, G_SOIL_FLOORS, K_FLOOR) end
-- 26 and 27: the engraved floor, as vanilla draws it and with the face carved
-- out. The "Engraving faces" switch picks which (ENGRAVED FLOORS, below).
local ENGRAVED_FACE = add_art('engraved_floor', G_ENGRAVED, K_ENGRAVED)
local ENGRAVED_PLAIN = add_art('engraved_floor_plain', G_ENGRAVED, K_ENGRAVED)

-- Stairs and ramps, by family ('stone' or 'soil'): STAIR_ART[family][shape]
-- and RAMP_ART[family][ramp cell].
local STAIR_ART, RAMP_ART = {stone={}, soil={}}, {stone={}, soil={}}
for _, family in ipairs({'stone', 'soil'}) do
    local group = family == 'stone' and G_STAIRS or G_SOIL_STAIRS
    for _, shape in ipairs({'updown', 'up', 'down'}) do
        STAIR_ART[family][shape] = add_art(family .. '_stair_' .. shape, group, K_STAIR)
    end
end
if art then
    local ramp_cells, seen = {}, {}
    for walls = 0, 255 do
        local c = art.RAMP_CELL[walls]
        if c and not seen[c] then seen[c] = true ramp_cells[#ramp_cells + 1] = c end
    end
    table.sort(ramp_cells)
    for _, family in ipairs({'stone', 'soil'}) do
        local group = family == 'stone' and G_RAMPS or G_SOIL_RAMPS
        for _, c in ipairs(ramp_cells) do
            RAMP_ART[family][c] = add_art(family .. '_ramp_' .. c, group, K_RAMP)
        end
    end
end
local ART_COUNT = #ART_CELL

-- ==========================================
-- FLOORS: LOOKED UP ON THE TILE PAGES
-- ==========================================
-- DF draws floors straight off their tile page, so their texposes are found by
-- page and cell. This order must match ids 1 to 13 above.
local VARIANTS = {
    {'DETAILED_FLOORS', 0, 3}, {'DETAILED_FLOORS', 1, 3}, {'DETAILED_FLOORS', 2, 3},
    {'DETAILED_FLOORS', 0, 4}, {'DETAILED_FLOORS', 1, 4}, {'DETAILED_FLOORS', 2, 4},
    {'DETAILED_FLOORS', 0, 5}, {'DETAILED_FLOORS', 1, 5}, {'DETAILED_FLOORS', 2, 5},
    {'DETAILED_ALT_FLOORS', 7, 4}, {'DETAILED_ALT_FLOORS', 7, 5}, {'DETAILED_ALT_FLOORS', 7, 6},
    {'FLOORS', 6, 3},
}
local VANILLA_VARIANTS = {
    {'FLOORS', 0, 3}, {'FLOORS', 1, 3}, {'FLOORS', 2, 3},
    {'FLOORS', 0, 4}, {'FLOORS', 1, 4}, {'FLOORS', 2, 4},
    {'FLOORS', 0, 5}, {'FLOORS', 1, 5}, {'FLOORS', 2, 5},
    {'ALT_FLOORS', 7, 4}, {'ALT_FLOORS', 7, 5}, {'ALT_FLOORS', 7, 6},
}
-- Detailed Landscapes 2.3 and later (Rounded Hills) draws STONE_FLOOR_* and
-- DIRT_FLOOR_* off pages of its own, at the same cells as vanilla's: its
-- graphics_tiles_rounded_hills.txt names FLOORS_ROUND_DETAILED 0:3 to 2:8 and
-- ALT_FLOORS_ROUND_DETAILED 7:4 to 7:9. Its DETAILED_FLOORS pages now carry
-- only GRASS_* tokens, so the DETAILED_ entries in VARIANTS above match
-- nothing DF draws, and stone and soil floors went untinted. Read off DL 2.4's
-- raws 2026-11-15. Stone floors match ids 1 to 12, soil floors 14 to 25.
local ROUND_VARIANTS = {
    {'FLOORS_ROUND_DETAILED', 0, 3}, {'FLOORS_ROUND_DETAILED', 1, 3}, {'FLOORS_ROUND_DETAILED', 2, 3},
    {'FLOORS_ROUND_DETAILED', 0, 4}, {'FLOORS_ROUND_DETAILED', 1, 4}, {'FLOORS_ROUND_DETAILED', 2, 4},
    {'FLOORS_ROUND_DETAILED', 0, 5}, {'FLOORS_ROUND_DETAILED', 1, 5}, {'FLOORS_ROUND_DETAILED', 2, 5},
    {'ALT_FLOORS_ROUND_DETAILED', 7, 4}, {'ALT_FLOORS_ROUND_DETAILED', 7, 5},
    {'ALT_FLOORS_ROUND_DETAILED', 7, 6},
}
local ROUND_SOIL_VARIANTS = {
    {'FLOORS_ROUND_DETAILED', 0, 6}, {'FLOORS_ROUND_DETAILED', 1, 6}, {'FLOORS_ROUND_DETAILED', 2, 6},
    {'FLOORS_ROUND_DETAILED', 0, 7}, {'FLOORS_ROUND_DETAILED', 1, 7}, {'FLOORS_ROUND_DETAILED', 2, 7},
    {'FLOORS_ROUND_DETAILED', 0, 8}, {'FLOORS_ROUND_DETAILED', 1, 8}, {'FLOORS_ROUND_DETAILED', 2, 8},
    {'ALT_FLOORS_ROUND_DETAILED', 7, 7}, {'ALT_FLOORS_ROUND_DETAILED', 7, 8},
    {'ALT_FLOORS_ROUND_DETAILED', 7, 9},
}
-- DIRT_FLOOR_1 to 9 and 5B to 5D, matching ids 14 to 25. Sand has pages of its
-- own (FLOOR_SAND), so sand floors never match these and keep DF's look.
local SOIL_VARIANTS = {
    {'FLOORS', 0, 6}, {'FLOORS', 1, 6}, {'FLOORS', 2, 6},
    {'FLOORS', 0, 7}, {'FLOORS', 1, 7}, {'FLOORS', 2, 7},
    {'FLOORS', 0, 8}, {'FLOORS', 1, 8}, {'FLOORS', 2, 8},
    {'ALT_FLOORS', 7, 7}, {'ALT_FLOORS', 7, 8}, {'ALT_FLOORS', 7, 9},
}

-- ==========================================
-- ENGRAVED FLOORS: LOOKED UP ON THEIR PAGES
-- ==========================================
-- Vanilla has two one-cell pages for an engraved stone floor.
-- FLOOR_STONE_ENGRAVED_PALETTE is drawn in four colours that are all palette
-- row 0 keys (columns 12 to 15), the mark of art DF recolours by palette.
-- FLOOR_STONE_ENGRAVED_NON_PALETTE is seven fixed blue-greys, none of them a
-- row 0 key, so no stone's colour can reach it. It was cut into vanilla's
-- smooth floor: outside the carving, every pixel is the smooth floor's own
-- (FLOORS 6:3, 468 of 1024 equal). Seen in play 2026-10-21: an engraved
-- claystone floor (CHOCOLATE) showed NON_PALETTE's blue-greys, 104,110,114 the
-- commonest pixel, beside an engraved claystone wall in the stone's brown. So
-- DF drew that natural engraved floor in the fixed art, not its stone's
-- colour, and it read as plain blue next to tinted floors.
--
-- stone-tint draws the NON_PALETTE cell in its place, keyed by luminance like
-- every other floor so it tints the same way as the floor around it, or the
-- same cell with the face carved out (engraved_floor_plain.png, see
-- build_stone_tint_art.py), as the "Engraving faces" switch says.
--
-- NOT YET MEASURED (2026-10-21): that DF puts the engraved page tile in
-- screentexpos_background, the way it does the smooth floor, rather than
-- drawing it over the floor from a flag, the way the ramp overlays come (RAMP
-- OVERLAYS). `stone-tint status` counts the engraved tiles drawn: none while
-- engraved floors are on screen means it does not. Both pages are looked up,
-- in case DF ever draws the PALETTE cell unswapped.
local ENGRAVED_PAGES = {
    {'FLOOR_STONE_ENGRAVED_NON_PALETTE', 0, 0},
    {'FLOOR_STONE_ENGRAVED_PALETTE', 0, 0},
}
-- Marks an engraved floor's page tile in floor_texpos and known_texpos. Not an
-- art id: whether the tile is natural stone is checked once per tile
-- (natural_engraved), and which picture it gets is the switch, read per frame.
local ENGRAVED = -2

-- ==========================================
-- STAIRS AND RAMPS: LEARNED FROM THE MAP
-- ==========================================
-- DF does not draw natural stairs or ramps off a tile page, so they cannot be
-- looked up the way floors are. Measured with stone-tint-stair-probe and
-- stone-tint-ramp-probe: every stone, mineral and soil stair and every stone
-- and mineral ramp held a texture in screentexpos_background that is on no
-- tile page, one per material and shape (every pyrite up-stair on screen shared
-- one; three tetrahedrite ramps against different walls had three), and no
-- other layer held anything for them. Grass stairs alone came straight off the
-- STAIRS page. The run-time textures were renumbered between runs along with
-- the pages. So the overlay learns them from the map instead (natural_art and
-- the render loop) and draws vanilla's art in their place: STAIRS rows 1 and 2
-- for stairs, STONE_RAMPS and SOIL_RAMPS for ramps.
--
-- A ramp's picture depends on which of its 8 neighbours are walls. DF works
-- that out itself and leaves it in screentexpos_ramp_flag, bits 8 to 15 in the
-- order N, W, E, S, NW, NE, SW, SE (the layout devel/inspect-screen decodes),
-- so the overlay reads DF's own answer rather than working it out again, and
-- art.RAMP_CELL turns it into the vanilla cell. The probe's ramps decoded as a
-- column against a west wall: N_W, W, S_W. The probe found nothing of the ramp
-- overlays or shadows (vanilla's or Dark Depths') in any texpos layer, and in
-- play Dark Depths' ramp overlay drew on top of our tinted ramps: DF draws
-- those from the flags after the background. The overlay is hidden separately
-- (RAMP OVERLAYS, below); the shadows stay.
local STAIR_SHAPES = {
    [df.tiletype_shape.STAIR_UPDOWN] = 'updown',
    [df.tiletype_shape.STAIR_UP] = 'up',
    [df.tiletype_shape.STAIR_DOWN] = 'down',
}
-- Natural stone, as with floors. Soil is its own family; ice, grass and
-- constructed tiles keep DF's own picture.
local STONE_MATERIALS = {
    [df.tiletype_material.STONE] = true,
    [df.tiletype_material.MINERAL] = true,
    [df.tiletype_material.FEATURE] = true,
    [df.tiletype_material.LAVA_STONE] = true,
}
-- Marks a texture DF drew on a natural stair or ramp in known_texpos (below).
local LEARNED = -1

-- ==========================================
-- THE LEVELS BELOW
-- ==========================================
-- Levels seen from above through open space (a ramp's top, a shaft, a cliff
-- edge) are not drawn in the main viewport. Measured with
-- stone-tint-depth-probe: DF keeps eight more viewports, gps.lower_viewport[0]
-- to [7], each the size of the main viewport and indexed the same way, and
-- [0] held the level just below the camera. [1] to [7] are taken to be the
-- levels below that, in order: DFHack's smooth-movement plugin draws them
-- deepest first, [7] up to [0], then the main viewport. A ramp seen from its
-- top sat in lower_viewport[0] with the same kind of run-time texture and
-- ramp flags it has on its own level, so it showed DF's untinted ramp. The
-- depth shading sat in that viewport's own screentexpos_interface layer,
-- which is drawn over its background, so it stays on top of a tint written
-- underneath. With Dark Depths that shading is its DARK_DEPTHS_Z page: the
-- same alpha as vanilla's MULTILEVEL_OVERLAY, in black where vanilla's is
-- light blue, at most 48 of 255 on a ramp.
--
-- On the probe's screen the main viewport held a background in 917 of its 920
-- cells and lower_viewport[0] held one in exactly the other 3. So the loop
-- walks down only through cells the level above left empty, and stops at the
-- first level where none are left, which on most screens is the first.
local LOWER_LEVELS = 8

-- ==========================================
-- STATE
-- ==========================================
-- texpos of a pristine game floor sprite -> art id, or ENGRAVED for an
-- engraved floor's page tile. Small (<= 39 entries).
local floor_texpos = {}
-- How many of ENGRAVED_PAGES were found on a loaded page, for `stone-tint status`.
local engraved_found = 0
-- Every texpos the floor buffers have shown since the last reset, filed once:
-- a floor art id, LEARNED, ENGRAVED, or false for anything that is not ours. One table
-- for every level, since a texture means the same thing at any depth, so the
-- common cell costs one lookup. Rebuilt from the floor sprites on every z
-- change, and when the floor sprites or our textures move, because DF
-- renumbers its run-time textures when it reloads them.
local known_texpos = {}
local cached_z
-- Per level, since the levels below are drawn too. Both are kept while their
-- level is near the view (change_level) and emptied on a map load.
local color_cache = {}          -- [z] = {[world_x] = {[world_y] = colour code}}
-- [z] = {[world_x] = {[world_y] = {texpos=, id=}}}: what a learned stair or
-- ramp tile is, or whether an engraved floor is natural stone (ENGRAVED or
-- false), checked against the texture DF drew there, so a tile goes back to
-- the map only when its picture changes.
local tile_checks = {}
local map_max_x, map_max_y      -- tile bounds, refreshed on map load
local state = {strength=50, style='keep', rough=true, smooth=true, stairs=true, ramps=true, soil=true,
               hide_overlays=true, engraved=true, faces=true, black_shadows=true}
local view

-- Running stone-tint from the console re-executes this whole file in the same
-- environment: every local above starts over, while the overlay keeps drawing.
-- What has to survive that lives in environment globals instead: the counts
-- the console reads back, and the textures already made, so a console command
-- never makes a second set.
stone_tint_stats = stone_tint_stats or {floors=0, engraved=0, stairs=0, ramps=0, below=0,
    textures=0}
-- [strength] = {[source id] = {[colour code] = handle, or false}}. A source is
-- the picture a texture is tinted from (THE ART AS DRAWN): a positive id for a
-- picture read off DF, or an art id negated for our stored art (engraved
-- floors, and any picture that cannot be read).
stone_tint_textures = stone_tint_textures or {}
if stone_tint_textures.art_count ~= ART_COUNT or not stone_tint_textures.by_source then
    stone_tint_textures = {art_count=ART_COUNT, by_source=true}
    -- Source ids name textures in the set just thrown away: start them over too.
    stone_tint_sources = nil
end
-- The pictures read off DF, kept beside the textures made from them so a
-- console re-run cannot hand an id already used to another picture: the next
-- id, each source's pixels by id, and which texpos showed which source.
stone_tint_sources = stone_tint_sources or {next_id=1, data={}, by_texpos={}, by_hash={}}
-- by_hash: a picture's content hash -> its id (THE ART AS DRAWN), so the same
-- picture under a new texpos keeps its id and its textures.
stone_tint_sources.by_hash = stone_tint_sources.by_hash or {}

-- Resolved texposes for the strength in use: [source id] = {[colour code] =
-- texpos, or false for "nothing to draw"}. Thrown away when the strength
-- changes or our sentinel texture's texpos moves (DF reset its textures).
local tint_cache = {}
local tint_sentinel, tint_strength, tint_style
-- FLOOR EDGES (below). piece_sets: the texpos of every picture in a floor
-- page's set -> that set, {first_id=, texpos={[1 to 12]=}}, so a floor's edge
-- pieces are drawn from the set the floor came from. Rebuilt with floor_texpos.
local piece_sets = {}
local edge = {
    info = {},      -- a tinted floor's texpos -> {set=, code=, sid=}: whose pieces it drops
    made = {},      -- a stack of pieces (stack_texpos's key) -> texpos, or false
    ours = {},      -- every stack's texpos -> true, to know one of ours in background_two
    count = 0,      -- open cells given tinted edges this frame, for `stone-tint status`
}
-- Every tinted texpos held here goes at once: a floor's texture is filed in
-- edge.info only as paint_cell makes it, so the two are thrown away together.
-- moved: DF renumbered its textures (or the map changed), so the stacks'
-- numbers go too. A change of strength or style moves nothing, so a stack of
-- the old one is still known as ours (paint_edges).
local function reset_tints(moved)
    tint_cache = {}
    edge.info, edge.made = {}, {}
    if moved then edge.ours = {} end
end

-- Scratch tables reused every frame so the render loop allocates nothing.
local group_enabled = {}
local frame_counts = {0, 0, 0, 0}
-- Cell indices the level above left empty, for the next level down. Two lists
-- that swap roles level by level; only the first n entries of each are live.
local see_through, see_next = {}, {}

-- ==========================================
-- TIMING AND THE FRAME'S WORK CAP
-- ==========================================
-- os.clock is the C clock: wall time on Windows, in whole milliseconds.
local clock = os.clock
-- Every map read (a tile's material, what a texture is, a stair or ramp's
-- shape) and every picture read off DF is done only while the frame has spent
-- less than WORK_MS on them; a tile left over keeps DF's own picture this
-- frame and is done in a later one. Picture reads and new textures keep their
-- own counts as well (READS_PER_FRAME, NEW_TEXTURES_PER_FRAME). Until
-- 2026-11-15 the map reads had no cap: a new level, or a relearn, looked up
-- every tile on screen in one frame.
local WORK_MS = 8
local work_until = 0              -- the clock time this frame's costly work stops at
local function can_work() return clock() < work_until end
-- This frame's costly work, for THE SLOW FRAME REPORT: how many of each, and
-- the seconds they took. Started over at the top of each frame. One table,
-- not a local each: Lua allows at most 200 locals at the top of a file, and
-- this file came within 9 of it (2026-11-15). New state goes into tables.
local this_frame = {
    colours = 0, colour_s = 0,     -- tile materials looked up
    maps = 0, map_s = 0,           -- textures filed and tiles checked on the map
    checks = 0, check_s = 0,       -- pictures looked at (16 pixels)
    reads = 0, read_s = 0,         -- pictures read whole
    made = 0, made_s = 0,          -- textures made
    waited = 0,                    -- tiles left for a later frame by the cap
}

-- ==========================================
-- DETAILED WEATHER
-- ==========================================
-- Detailed Weather (its colour.lua) recolours the ground for the weather by
-- pointing DF's texture tables (gps.texture_indices1 to 11) at its own copies
-- of every ground texture whenever its look is not the neutral one. DF then
-- draws a floor with the copy's texpos, which floor_texpos does not hold, so
-- the floor went untinted. Underground it is worse: Detailed Weather puts DF's
-- original back after we have drawn (its put_back_underground), so fort floors
-- showed plain vanilla. Read in its code 2026-11-15; not yet seen in play.
--
-- It records every copy it points the tables at in the global
-- detailed_weather_pointed_from (copy texpos -> DF's own texpos), and its
-- copy_of(original) answers which copy is showing now. A copy is filed as its
-- floor only while copy_of still returns it: DF hands a freed texture's number
-- to the next texture it makes (Detailed Weather's grass.lua notes this), and
-- Detailed Weather frees a look's copies once the look moves on, so a stale
-- entry could name a ramp or a tree. For the same reason every copy filed this
-- way is forgotten when the look changes (dw_check_look, once a frame).
--
-- Its restore underground only swaps back textures it knows as its own copies,
-- and ours is not one, so what we draw stays. Which picture we tint follows
-- what it means to show (paint_cell): outdoors its copy, so the floor keeps the
-- weather's colouring under the tint; on a subterranean tile DF's own, which is
-- what it puts back there itself.
local dw_colour            -- its colour module; nil not looked up yet, false not running
local dw_look              -- the look key it showed when last checked
local dw_filed = {}        -- copy texpos -> DF's own texpos, for each copy filed in known_texpos

-- BOTH DETAILED WEATHERS (2026-11-20). copy_of and shown_look are grungeisdead's copy's own; Poss's
-- releases (1.4, 1.5) have neither, so with his every call failed (in pcall), no copy was ever filed,
-- and floors went untinted whenever his look wasn't the game's own. Both keep the same state, read
-- here when the functions aren't there: state.shown, the key of the look showing (nil: the game's
-- own), and state.copies[key][original] = {handle, texpos}, its copy (colour.lua in both).
-- The texpos showing for DF's own `original` now: its copy in the look showing, or itself.
local function dw_live_copy(mod, original)
    if type(mod.copy_of) == 'function' then return mod.copy_of(original) end
    local st = mod.state
    local set = st and st.shown and st.copies and st.copies[st.shown]
    local copy = set and set[original]
    return copy and copy.texpos or original
end
-- The key of the look showing (false: the game's own, or none known).
local function dw_shown_key(mod)
    if type(mod.shown_look) == 'function' then
        local _, key = mod.shown_look()
        return key or false
    end
    local st = mod.state
    return st and st.shown or false
end

-- Detailed Weather's colour module, or false. Looked up only once its global
-- table exists, so nothing of it is loaded when it is not installed.
local function dw_module()
    if dw_colour == nil then
        if not rawget(_G, 'detailed_weather_pointed_from') then return false end
        local ok, mod = pcall(reqscript, 'internal/detailed_weather/colour')
        dw_colour = ok and mod or false
    end
    return dw_colour
end

-- The floor art id (or ENGRAVED) for a texpos that is Detailed Weather's live
-- copy of one of our floor sprites, or nil.
local function dw_floor(drawn)
    local from = rawget(_G, 'detailed_weather_pointed_from')
    local original = from and from[drawn]
    if not original then return nil end
    local id = floor_texpos[original]
    if id == nil then return nil end
    local mod = dw_module()
    if not mod then return nil end
    local ok, live = pcall(dw_live_copy, mod, original)
    if not ok or live ~= drawn then return nil end
    dw_filed[drawn] = original
    return id
end

-- Once a frame: when Detailed Weather's look has changed, forget the copies
-- filed under the old one, so their freed numbers are filed afresh.
local function dw_check_look()
    local mod = dw_colour
    if not mod then return end   -- not looked up or not running: nothing filed
    local ok, key = pcall(dw_shown_key, mod)
    key = ok and key or false
    if key == dw_look then return end
    dw_look = key
    for texpos in pairs(dw_filed) do known_texpos[texpos] = nil end
    dw_filed = {}
end

-- ==========================================
-- COLOUR
-- ==========================================
-- A material's state_color.Solid is a PATTERN index (descriptors.patterns),
-- not a colour index; the colour DF draws with is the pattern's first. Read as
-- a colour index it only lines up for vanilla's own colours, while a mod's
-- colours sit at the end of the pattern list (found in Refinish Metal's
-- refinish-sprite-art). Every colour carries its palette row live, as
-- palette.color: 18 colours, 54 bytes. The old sheets looked rows up on
-- palettes.png by colour index + 1, but that image has two rows no colour uses
-- (52 and 116), so 83 of vanilla's 134 colours wore a neighbour's row (slate
-- gray stone got sky blue's) and a mod's colours had no row at all.
local palettes = {}             -- [colour index] = flat 54 bytes, or false

local function material_colour(m)
    local idx
    pcall(function() idx = m.state_color.Solid end)
    if not idx or idx < 0 then return nil end
    local ci
    pcall(function()
        local p = df.global.world.raws.descriptors.patterns[idx]
        if p and #p.colors > 0 then ci = p.colors[0] end
    end)
    return ci
end

local function palette_of(ci)
    local pal = palettes[ci]
    if pal ~= nil then return pal end
    pal = false
    pcall(function()
        local bytes = df.global.world.raws.descriptors.colors[ci].palette.color
        local t, any = {}, false
        for i = 0, 53 do
            t[i + 1] = bytes[i]
            if bytes[i] > 0 then any = true end
        end
        -- A colour with every byte zero has no palette row: nothing to tint with.
        if any then pal = t end
    end)
    palettes[ci] = pal
    return pal
end

-- The colour code for a tile: its colour index + 1, or 0 for none.
local function colour_code(x, y, z)
    local ok, matinfo = pcall(tile_material.GetTileMat, x, y, z)
    if not ok or not matinfo then
        local ok2, fallback = pcall(tile_material.GetLayerMat, x, y, z)
        matinfo = ok2 and fallback or nil
    end
    local ci = matinfo and matinfo.material and material_colour(matinfo.material)
    return ci and ci + 1 or 0
end

-- ==========================================
-- FAST MATERIALS
-- ==========================================
-- colour_code asks DFHack's tile-material for a tile's material. Read in
-- DFHack's tile-material.lua and LuaApi.cpp 2026-11-15: every call builds a
-- coordinate table and hands it to four or five map functions, each of which
-- has DFHack copy that table into a coordinate field by field, and a vein
-- tile walks every event in its block (veins, blood, mud, grass) through the
-- Lua bridge. The lookups below get the same answer from what tile-material
-- works it out from, read once and kept for the map:
--   stone and soil  GetLayerMat: the stone of layer geolayer_index in the
--                   region getTileBiomeRgn names. Tiles sharing those three
--                   numbers share their stone, so each set is looked up once.
--                   The same for roots, ash, campfires, driftwood and brook
--                   and pool beds, which GetTileMat answers with their layer
--                   too (LAYER_MATS).
--   vein tiles      GetVeinMat: of the block's mineral events whose bitmask
--                   holds the tile (bit x & 15 of bits[y & 15], as DFHack's
--                   getassignment), the last of the highest priority:
--                   cluster 1, vein 2, small cluster 3, single tile 4, else
--                   5. A block's mineral events are read once. A vein tile no
--                   event covers gets its layer's stone, as colour_code's
--                   fallback gives it.
--   anything else   colour_code, as before.
-- Checked against colour_code on the first FAST_CHECKS lookups and every
-- FAST_CHECK_EVERY after that: one difference turns these off for the
-- session, and `stone-tint status` reports it with the tile.
local MAT_SOIL = df.tiletype_material.SOIL
local MAT_MINERAL = df.tiletype_material.MINERAL
local FAST_CHECKS = 256
local FAST_CHECK_EVERY = 64

-- The tiletype materials whose colour is their layer's, and the kind each
-- tiletype material is counted as in `stone-tint status`. Tiles with a plant
-- on them (grass, shrubs, saplings, trees) are not layer tiles: GetTileMat
-- answers them with the plant's own material, and they keep that colour.
-- Giving them their layer's colour instead (2026-11-15, to skip GetTileMat's
-- search of every plant in the world) changed the ground under every tree
-- from grass to dirt in play, and was taken back the same day.
local LAYER_MATS, KIND_OF = {}, {}
for name, kind in pairs({STONE='stone', SOIL='soil', MINERAL='vein',
        GRASS_LIGHT='plants', GRASS_DARK='plants', GRASS_DRY='plants', GRASS_DEAD='plants',
        PLANT='plants', TREE='plants', MUSHROOM='plants',
        ROOT='other ground', CAMPFIRE='other ground', FIRE='other ground', ASHES='other ground',
        DRIFTWOOD='other ground', POOL='other ground', BROOK='other ground',
        FEATURE='feature', LAVA_STONE='obsidian'}) do
    local m = df.tiletype_material[name]
    if m then
        KIND_OF[m] = kind
        if kind == 'stone' or kind == 'soil' or kind == 'other ground' then LAYER_MATS[m] = true end
    end
end
local KIND_ORDER = {'stone', 'soil', 'vein', 'plants', 'other ground', 'feature', 'obsidian', 'other'}

-- tiletype -> its material class and shape, read off df.tiletype.attrs once
-- per tiletype. WHAT A TILE IS uses them too.
local tt_material, tt_shape = {}, {}
local function tile_attrs(tt)
    local m = tt_material[tt]
    if m == nil then
        local attrs = df.tiletype.attrs[tt]
        m = attrs.material
        tt_material[tt], tt_shape[tt] = m, attrs.shape
    end
    return m, tt_shape[tt]
end

-- What has been worked out on this map: colour codes by layer and by
-- inorganic index, and each block's mineral events. Emptied on a map load.
local layer_codes, inorganic_codes, mineral_blocks = {}, {}, {}
local function reset_material_caches()
    layer_codes, inorganic_codes, mineral_blocks = {}, {}, {}
end

-- A material's colour code, made as colour_code makes it.
local function material_code(matinfo)
    local ci = matinfo and matinfo.material and material_colour(matinfo.material)
    return ci and ci + 1 or 0
end

-- Stone and soil: the colour code of the tile's layer, or nil.
local function layer_code(x, y, z)
    local rx, ry = dfhack.maps.getTileBiomeRgn(x, y, z)
    if not ry then return nil end
    local des = dfhack.maps.getTileFlags(x, y, z)
    if not des then return nil end
    -- Region coordinates offset, so a -1 at a world edge cannot share a key.
    local key = ((rx + 1024) * 4096 + ry + 1024) * 16 + des.geolayer_index
    local code = layer_codes[key]
    if code == nil then
        local ok, matinfo = pcall(tile_material.GetLayerMat, x, y, z)
        code = material_code(ok and matinfo or nil)
        layer_codes[key] = code
    end
    return code
end

-- Vein tiles: the colour code of the vein that wins the tile, or nil when no
-- vein covers it or its material cannot be decoded (colour_code then falls
-- back to the layer too).
local function vein_code(x, y, z)
    local bkey = ((x >> 4) * 4096 + (y >> 4)) * 4096 + z
    local events = mineral_blocks[bkey]
    if not events then
        events = {}
        local block = dfhack.maps.getTileBlock(x, y, z)
        if block then
            for _, event in ipairs(block.block_events) do
                if getmetatable(event) == 'block_square_event_mineralst' then
                    local bits, rows = event.tile_bitmask.bits, {}
                    for r = 0, 15 do rows[r] = bits[r] end
                    local f, prio = event.flags, 5
                    if f.cluster then prio = 1
                    elseif f.vein then prio = 2
                    elseif f.cluster_small then prio = 3
                    elseif f.cluster_one then prio = 4 end
                    events[#events + 1] = {rows=rows, prio=prio, mat=event.inorganic_mat}
                end
            end
        end
        mineral_blocks[bkey] = events
    end
    -- GetVeinMat's choice: walking the covering veins in block order, a vein
    -- of the same or higher priority replaces the one held.
    local lx, ly = x & 15, y & 15
    local winner
    for _, e in ipairs(events) do
        if ((e.rows[ly] >> lx) & 1) == 1 and (not winner or e.prio >= winner.prio) then
            winner = e
        end
    end
    if not winner then return nil end
    local code = inorganic_codes[winner.mat]
    if code == nil then
        local ok, matinfo = pcall(dfhack.matinfo.decode, 0, winner.mat)
        code = (ok and matinfo) and material_code(matinfo) or false
        inorganic_codes[winner.mat] = code
    end
    return code or nil
end

-- The fast lookup for a tile of tiletype material m, or nil to use
-- colour_code.
local function fast_colour_code(x, y, z, m)
    if m == MAT_MINERAL then return vein_code(x, y, z) or layer_code(x, y, z) end
    return layer_code(x, y, z)
end

-- How the checks on the fast lookups stand, for `stone-tint status`: on
-- (false once one differed), calls and checks so far, the first difference,
-- colour_code's own lookups timed while checking (full_n, full_s), and every
-- lookup by kind (KIND_OF) as {count, seconds}.
local fast = {on=true, calls=0, checked=0, note=nil, full_n=0, full_s=0, kinds={}}

-- A tile's colour code: the fast lookup, checked against colour_code now and
-- then, or colour_code itself.
local function lookup_colour(x, y, z)
    local t0 = clock()
    local m
    local tt = dfhack.maps.getTileType(x, y, z)
    if tt then
        local ok_m, mm = pcall(tile_attrs, tt)
        if ok_m then m = mm end
    end
    local code = nil
    if fast.on and (m == MAT_MINERAL or LAYER_MATS[m]) then
        local ok
        ok, code = pcall(fast_colour_code, x, y, z, m)
        if not ok then code = nil end
        if code ~= nil then
            fast.calls = fast.calls + 1
            if fast.calls <= FAST_CHECKS or fast.calls % FAST_CHECK_EVERY == 0 then
                local t1 = clock()
                local full = colour_code(x, y, z)
                fast.full_n, fast.full_s = fast.full_n + 1, fast.full_s + clock() - t1
                fast.checked = fast.checked + 1
                if full ~= code then
                    fast.on = false
                    fast.note = ('tile %d,%d,%d: fast %d, tile-material %d')
                        :format(x, y, z, code, full)
                    code = full
                end
            end
        end
    end
    if code == nil then code = colour_code(x, y, z) end
    local kind = KIND_OF[m] or 'other'
    local c = fast.kinds[kind]
    if not c then c = {0, 0} fast.kinds[kind] = c end
    c[1], c[2] = c[1] + 1, c[2] + clock() - t0
    return code
end

-- Sand is soil to the map, but DF draws it with art of its own (sand floors,
-- stairs and ramps), so it keeps that look.
local function is_sand(x, y, z)
    local sand = false
    pcall(function()
        local matinfo = tile_material.GetTileMat(x, y, z)
        sand = matinfo and matinfo.inorganic and matinfo.inorganic.flags.SOIL_SAND or false
    end)
    return sand
end

-- ==========================================
-- THE TINT
-- ==========================================
-- A material's palette row is 18 colours, one for each key column of
-- palettes.png row 0 (KEY_RGB): dark to light twice, warm columns 0 to 8 and
-- cool columns 9 to 17. Three ways to move a picture toward it, picked in the
-- window (Tint style):
--   classic  The maths the old sheets were baked with, measured off them: each
--            pixel moves toward the palette colour of its key column (the key
--            nearest its brightness) by the strength, rounded halves to even.
--                out = round(pixel + strength * (palette[key] - pixel))
--            Doubles in the same order as the Python that made the sheets, so
--            a colour whose row the sheets got right comes out bit for bit the
--            same. On art not drawn in key colours it can scramble the
--            picture: Landscapes draws its stone floor as blue stones
--            (brightness 115 to 117) against grey cracks (109), and on
--            chalk's row the cracks' key (warm 5, 152,133,111) is lighter
--            than the stones' (cool 13, 134,110,90), so the cracks came out
--            lighter than the stones and the pattern was lost. Reproduced to
--            the pixel off a screenshot 2026-11-15.
--   smooth   Each pixel moves toward the palette colour at its own
--            brightness, read along the row without steps (palette_target).
--            A brighter pixel always gets a brighter target, so nothing trades
--            places, but colour differences at one brightness are evened out
--            by the strength.
--   keep     The picture's mean colour moves toward the palette colour at its
--            mean brightness, and every pixel moves with it by the same
--            amount, so every difference between pixels stays as drawn. At
--            100% the mean is the material's colour, the texture untouched.
-- KEY_RGB is palettes.png row 0, read off vanilla's 2026-11-15; KEY_LUMA its
-- brightness by column, Rec.601 weights (THE ART AS DRAWN keys pixels by it).
local KEY_RGB = {
    {47, 48, 56}, {70, 62, 61}, {78, 71, 67}, {86, 79, 73}, {96, 88, 82}, {116, 106, 99},
    {148, 135, 126}, {179, 165, 158}, {215, 211, 210}, {47, 48, 56}, {60, 62, 70}, {73, 76, 84},
    {90, 94, 101}, {107, 112, 118}, {138, 144, 145}, {165, 166, 165}, {199, 196, 180}, {255, 255, 255},
}
local KEY_LUMA = {}
for k, c in ipairs(KEY_RGB) do KEY_LUMA[k] = c[1] * 0.299 + c[2] * 0.587 + c[3] * 0.114 end

local function rint(v)
    local f = math.floor(v)
    local d = v - f
    if d > 0.5 then return f + 1 end
    if d < 0.5 then return f end
    return (f % 2 == 0) and f or f + 1
end

-- ALPHABET character -> its 0-based place; a cell names each pixel with two.
local DIGIT = {}
if art then
    for i = 1, #art.ALPHABET do DIGIT[art.ALPHABET:byte(i)] = i - 1 end
end
local decoded = {}              -- cell name -> 1024 PIXELS indices

local function decode(cell)
    local idx = decoded[cell]
    if idx then return idx end
    local s = art and art.CELLS[cell]
    if not s then return nil end
    idx = {}
    for i = 1, CELL_PX * CELL_PX do
        idx[i] = DIGIT[s:byte(2 * i - 1)] * 64 + DIGIT[s:byte(2 * i)] + 1
    end
    decoded[cell] = idx
    return idx
end

-- Every entry of art.PIXELS tinted toward one palette at one strength, packed
-- for createTileset. The art has a few hundred distinct pixels shared by every
-- cell, so a colour's entries are worked out once and each of its cells is then
-- 1024 lookups rather than 1024 blends. Packing is ABGR,
-- (a << 24) | (b << 16) | (g << 8) | r, confirmed in Refinish Metal by a test
-- card: the obvious 0xRRGGBBAA renders as ghostly negatives because alpha ends
-- up tracking red.
-- The helpers live in a block, so only tinted_entries is a file-level local.
local tinted_entries
do
local function clamp8(v)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return v
end

-- One half of a palette row (columns first to last, darkest first) read at
-- brightness y: between the two columns either side of y, held at the ends.
-- pal is the row's 54 bytes, 1-based: column c at pal[3c + 1] to pal[3c + 3].
local function half_at(pal, y, first, last)
    if y <= KEY_LUMA[first + 1] then
        return pal[first * 3 + 1], pal[first * 3 + 2], pal[first * 3 + 3]
    end
    for c = first + 1, last do
        local hy = KEY_LUMA[c + 1]
        if y <= hy then
            local ly = KEY_LUMA[c]
            local t = (y - ly) / (hy - ly)
            local a, b = (c - 1) * 3, c * 3
            return pal[a + 1] + t * (pal[b + 1] - pal[a + 1]),
                pal[a + 2] + t * (pal[b + 2] - pal[a + 2]),
                pal[a + 3] + t * (pal[b + 3] - pal[a + 3])
        end
    end
    return pal[last * 3 + 1], pal[last * 3 + 2], pal[last * 3 + 3]
end

-- The palette colour at brightness y: the warm half and the cool half, averaged.
local function palette_target(pal, y)
    local r1, g1, b1 = half_at(pal, y, 0, 8)
    local r2, g2, b2 = half_at(pal, y, 9, 17)
    return (r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2
end

-- list: a picture's own pixel entries (THE ART AS DRAWN), art.PIXELS if none.
-- idx: the picture's 1024 indices into list, which keep needs for the mean;
-- without it keep cannot be worked out and smooth is used.
-- mean_list, mean_idx: another picture to take keep's mean from, so a floor's
-- edge piece moves by its floor's own shift and the two match (FLOOR EDGES).
tinted_entries = function(pal, strength, list, idx, mean_list, mean_idx)
    list = list or art.PIXELS
    local s = strength / 100.0
    local style = state.style
    local out = {}
    if style == 'keep' and idx then
        local ml, mi = mean_list or list, mean_idx or idx
        local sr, sg, sb, n = 0, 0, 0, 0
        for i = 1, #mi do
            local e = ml[mi[i]]
            if e[4] > 0 then sr, sg, sb, n = sr + e[1], sg + e[2], sb + e[3], n + 1 end
        end
        if n == 0 then n = 1 end
        local mr, mg, mb = sr / n, sg / n, sb / n
        local tr, tg, tb = palette_target(pal, mr * 0.299 + mg * 0.587 + mb * 0.114)
        -- One shift for the whole picture.
        local dr, dg, db = s * (tr - mr), s * (tg - mg), s * (tb - mb)
        for i, e in ipairs(list) do
            local a = e[4]
            if a == 0 then
                out[i] = 0
            else
                local r = clamp8(rint(e[1] + dr))
                local g = clamp8(rint(e[2] + dg))
                local b = clamp8(rint(e[3] + db))
                out[i] = (a << 24) | (b << 16) | (g << 8) | r
            end
        end
    elseif style == 'classic' then
        for i, e in ipairs(list) do
            local a = e[4]
            if a == 0 then
                out[i] = 0
            else
                local k = e[5] * 3
                local r = rint(e[1] + s * (pal[k + 1] - e[1]))
                local g = rint(e[2] + s * (pal[k + 2] - e[2]))
                local b = rint(e[3] + s * (pal[k + 3] - e[3]))
                out[i] = (a << 24) | (b << 16) | (g << 8) | r
            end
        end
    else
        for i, e in ipairs(list) do
            local a = e[4]
            if a == 0 then
                out[i] = 0
            else
                local tr, tg, tb = palette_target(pal, e[1] * 0.299 + e[2] * 0.587 + e[3] * 0.114)
                local r = clamp8(rint(e[1] + s * (tr - e[1])))
                local g = clamp8(rint(e[2] + s * (tg - e[2])))
                local b = clamp8(rint(e[3] + s * (tb - e[3])))
                out[i] = (a << 24) | (b << 16) | (g << 8) | r
            end
        end
    end
    return out
end
end

local function cell_pixels(cell, entries)
    local idx = decode(cell)
    if not idx then return nil end
    local out = {}
    for i = 1, CELL_PX * CELL_PX do out[i] = entries[idx[i]] end
    return out
end

-- One cell tinted with a palette (54 bytes, 1-based) at a strength. Module-level
-- so a test can call it; the overlay goes through colour_entries' cache instead.
function tint_pixels(cell, pal, strength)
    return cell_pixels(cell, tinted_entries(pal, strength, nil, decode(cell)))
end

-- [colour index] = tinted_entries for the strength and style in use, or false
-- when the colour has no palette. Emptied with tint_cache when either changes.
-- Smooth and classic only: keep works from each picture's own mean.
local entry_cache = {}

local function colour_entries(ci, strength)
    local entries = entry_cache[ci]
    if entries == nil then
        local pal = palette_of(ci)
        entries = pal and tinted_entries(pal, strength) or false
        entry_cache[ci] = entries
    end
    return entries
end

-- A new texture for one cell in one colour. Dynamic range: there will be
-- hundreds, too many for the reserved range, and DFHack gives each a handle
-- that survives DF wiping its textures. Never deleted: deleting texture handles
-- on the way out of a world took DF down in Refinish Metal (measured twice), so
-- they are kept for the session and reused by every later request.
-- idx: a picture's 1024 indices into entries, row by row.
local function make_texture(idx, entries)
    if not idx then return false end
    local pixels = {}
    for i = 1, CELL_PX * CELL_PX do pixels[i] = entries[idx[i]] end
    local ok, handles = pcall(dfhack.textures.createTileset, pixels, CELL_PX, CELL_PX,
        CELL_PX, CELL_PX)
    if ok and handles and handles[1] then return handles[1] end
    return false
end

-- ==========================================
-- THE ART AS DRAWN
-- ==========================================
-- Each tile is tinted from the picture DF actually drew there, read back off
-- the texture, not from our stored copy of vanilla's art. So Detailed
-- Landscapes' rounded ramps and floors keep their look under the tint, and so
-- do Detailed Weather's weather-coloured floors; with vanilla graphics DF draws
-- vanilla's art and the result is as before. Measured with
-- stone-tint-pixel-probe 2026-11-15: enabler.textures.raws[texpos] is the
-- texture's SDL surface, w, h and pitch the int32s at 4, 5 and 6 and the pixel
-- pointer the uint64 at 4 (Detailed Weather's grass.lua reads it the same way),
-- bytes in R, G, B, A order; vanilla's FLOORS 0:3 read back 1024 of 1024 equal
-- to our stored copy of it. Each pixel is read whole, as one uint32 (surface).
--
-- Engraved floors keep the stored art: DF draws them in fixed blue-greys no
-- tint can reach, and the "Engraving faces" switch picks between two pictures
-- of ours. A picture that cannot be read (no surface, not 32x32) falls back to
-- the stored art for its art id.
--
-- Each pixel is keyed as build_stone_tint_art.py keys the stored art: the
-- column of palettes.png row 0 nearest it in luminance, Rec.601 weights, ties
-- to the first. KEY_RGB is that row (THE TINT), so the maths is the same and
-- only the source pixels change.
--
-- DF gives a freed texture's number to the next texture it makes (Detailed
-- Weather's grass.lua notes this for trees, workshops and ramps), so a texpos
-- read once is checked again every SOURCE_CHECK_MS against a few of its pixels
-- and its surface's address, and read afresh if either moved. Reading a
-- picture is 1024 pixels, so at most READS_PER_FRAME are read a frame; a tile
-- waiting its turn keeps DF's own picture for a frame or two.
local READS_PER_FRAME = 3
local CHECKS_PER_FRAME = 32       -- known pictures checked again a frame (16 pixels each)
local SOURCE_CHECK_MS = 2000
local frame_reads = 0             -- reads left this frame
local frame_checks = 0            -- checks left this frame
-- Bumped each frame. waiting[texpos] = the frame it was turned away in, so the
-- other cells showing it that frame are answered from the table and touch no
-- texture: lagged every map action hard while a texture waiting its turn was
-- looked at again for every cell that showed it (seen in play 2026-11-15).
local frame_id = 0
local waiting = {}
local source_round = 0            -- bumped every SOURCE_CHECK_MS: sources are checked once a round
local source_round_at = 0
-- The 16 pixels a picture is recognised by, spread over the tile.
local SIG_POINTS = {}
for k = 0, 15 do SIG_POINTS[#SIG_POINTS + 1] = (k * 389) % (CELL_PX * CELL_PX) end

-- The palette column (0 to 17) a pixel's tint blends toward. Kept by colour,
-- since the same colours come up picture after picture.
local key_memo = {}
local function key_of(r, g, b)
    local rgb = (b << 16) | (g << 8) | r
    local best = key_memo[rgb]
    if best then return best end
    local l = r * 0.299 + g * 0.587 + b * 0.114
    local best_d = math.huge
    best = 0
    for k = 1, #KEY_LUMA do
        local d = math.abs(l - KEY_LUMA[k])
        if d < best_d then best, best_d = k - 1, d end
    end
    key_memo[rgb] = best
    return best
end

-- A texture's pixels as a uint32 pointer, its row length in pixels and the
-- pixels' address, or nil when it has no 32x32 surface. A pixel's bytes R, G,
-- B, A, read as one little-endian uint32, are (a << 24) | (b << 16) |
-- (g << 8) | r: the packing createTileset takes, in one read through the Lua
-- bridge where reading the bytes took four.
local function surface(texpos)
    local ok, px, pitch, addr = pcall(function()
        local s = df.global.enabler.textures.raws[texpos]
        if not s then return nil end
        local ints = df.reinterpret_cast('int32_t', s)
        if ints:_displace(4)[0] ~= CELL_PX or ints:_displace(5)[0] ~= CELL_PX then return nil end
        local pitch_bytes = ints:_displace(6)[0]
        if pitch_bytes % 4 ~= 0 then return nil end
        local address = df.reinterpret_cast('uint64_t', s):_displace(4)[0]
        return df.reinterpret_cast('uint32_t', address), pitch_bytes // 4, address
    end)
    if not ok then return nil end
    return px, pitch, addr
end

local function signature(px, pitch)
    local sum = 0
    for _, n in ipairs(SIG_POINTS) do
        sum = (sum * 31 + px[(n // CELL_PX) * pitch + n % CELL_PX]) % 2147483647
    end
    return sum
end

-- A picture's pixels in the stored art's form: its distinct pixels as
-- {r, g, b, a, key} (entry 1 the clear pixel) and its 1024 indices into them.
local function read_source(px, pitch)
    local list, idx, seen = {{0, 0, 0, 0, 0}}, {}, {}
    local hash = 0
    for n = 0, CELL_PX * CELL_PX - 1 do
        local packed = px[(n // CELL_PX) * pitch + n % CELL_PX]
        local i = 1
        if packed >> 24 > 0 then
            i = seen[packed]
            if not i then
                local r, g, b = packed & 0xFF, (packed >> 8) & 0xFF, (packed >> 16) & 0xFF
                list[#list + 1] = {r, g, b, packed >> 24, key_of(r, g, b)}
                i = #list
                seen[packed] = i
            end
            hash = (hash * 31 + packed + n) % 9007199254740881
        end
        idx[n + 1] = i
    end
    return {list=list, idx=idx, hash=hash}
end

-- The source id for the picture a texpos shows: a positive id, false when it
-- cannot be read (use the stored art), or nil when it waits for a later frame.
-- Nothing is read off the texture unless this frame's budget allows: a new
-- picture waits for a read, and a known one due its check keeps its last id
-- until a check is free.
local function source_for(texpos)
    local srcs = stone_tint_sources
    local s = srcs.by_texpos[texpos]
    if s and s.round == source_round then return s.id end
    if waiting[texpos] == frame_id then return s and s.id or nil end
    if s then
        if frame_checks <= 0 then
            waiting[texpos] = frame_id
            return s.id
        end
        frame_checks = frame_checks - 1
        stone_tint_stats.checks = (stone_tint_stats.checks or 0) + 1
    elseif frame_reads <= 0 or not can_work() then
        waiting[texpos] = frame_id
        return nil
    end
    local t0 = clock()
    local px, pitch, addr = surface(texpos)
    if not px then
        srcs.by_texpos[texpos] = {id=false, round=source_round}
        return false
    end
    local sig = signature(px, pitch)
    this_frame.checks, this_frame.check_s = this_frame.checks + 1, this_frame.check_s + clock() - t0
    -- The same 16 pixels is the same picture, even if DF has moved it.
    if s and s.id and s.sig == sig then
        s.round, s.addr = source_round, addr
        return s.id
    end
    if frame_reads <= 0 or not can_work() then
        waiting[texpos] = frame_id
        return s and s.id or nil
    end
    frame_reads = frame_reads - 1
    stone_tint_stats.reads = (stone_tint_stats.reads or 0) + 1
    -- A picture already read under another texpos (DF reused a number, or
    -- moved its textures on a world load) keeps its id, and with it every
    -- texture made from it: without this every relearn made every tinted
    -- texture again (seen 2026-11-15: 401 textures, then 466).
    t0 = clock()
    local data = read_source(px, pitch)
    this_frame.reads, this_frame.read_s = this_frame.reads + 1, this_frame.read_s + clock() - t0
    local id = srcs.by_hash[data.hash]
    if not id then
        id = srcs.next_id
        srcs.next_id = id + 1
        srcs.data[id] = data
        srcs.by_hash[data.hash] = id
        stone_tint_stats.sources = (stone_tint_stats.sources or 0) + 1
    end
    srcs.by_texpos[texpos] = {id=id, addr=addr, sig=sig, round=source_round}
    return id
end

-- A source's tinted pixel entries for a colour and its index array, or false
-- when the colour has no palette.
local function source_pixels(sid, ci, strength)
    if sid < 0 then
        local idx = decode(ART_CELL[-sid])
        if not idx then return false end
        -- Stored art: keep's entries are made per cell, from the cell's mean;
        -- the other styles share one set per colour.
        if state.style == 'keep' then
            local pal = palette_of(ci)
            if not pal then return false end
            return tinted_entries(pal, strength, art.PIXELS, idx), idx
        end
        return colour_entries(ci, strength), idx
    end
    local data = stone_tint_sources.data[sid]
    if not data then return false end
    local pal = palette_of(ci)
    if not pal then return false end
    return tinted_entries(pal, strength, data.list, data.idx), data.idx
end

-- The texpos for one source in one colour (code: colour index + 1) at a
-- strength, making the texture if this is its first request. Returns texpos,
-- false (nothing to draw), or nil (not this frame: out of budget, or DF still
-- loading), plus the budget left.
local function tint_texpos(sid, code, strength, budget)
    -- One store per style and strength: a set made for one is kept while
    -- another shows, and used again when it comes back.
    local skey = state.style .. strength
    local store = stone_tint_textures[skey]
    if not store then store = {} stone_tint_textures[skey] = store end
    local per = store[sid]
    if not per then per = {} store[sid] = per end
    local handle = per[code]
    if handle == nil then
        if budget <= 0 or not can_work() then return nil, budget end
        budget = budget - 1
        local t0 = clock()
        local entries, idx = source_pixels(sid, code - 1, strength)
        handle = entries and make_texture(idx, entries) or false
        this_frame.made, this_frame.made_s = this_frame.made + 1, this_frame.made_s + clock() - t0
        per[code] = handle
        if handle then stone_tint_stats.textures = stone_tint_stats.textures + 1 end
    end
    if not handle then return false, budget end
    local t = dfhack.textures.getTexposByHandle(handle)
    -- 0 means DFHack is holding the texture until DF finishes loading.
    if t and t > 0 then return t, budget end
    return nil, budget
end

-- One transparent texture whose texpos is watched every frame: if it moves, DF
-- reset its textures and every texpos stone-tint holds is stale. Made on first
-- need, on a loaded map, and kept with the other textures.
local function sentinel_texpos()
    if stone_tint_sentinel == nil then
        local blank = {}
        for i = 1, CELL_PX * CELL_PX do blank[i] = 0 end
        local ok, handles = pcall(dfhack.textures.createTileset, blank, CELL_PX, CELL_PX,
            CELL_PX, CELL_PX)
        stone_tint_sentinel = ok and handles and handles[1] or false
    end
    if not stone_tint_sentinel then return nil end
    return dfhack.textures.getTexposByHandle(stone_tint_sentinel)
end

-- ==========================================
-- RAMP OVERLAYS
-- ==========================================
-- DF draws a ramp overlay (the OVERLAY_RAMP_WITH_WALL_* tokens: vanilla's
-- RAMP_OVERLAY page, or Dark Depths' DARK_RAMP_OVERLAY) over every ramp's
-- background, picked by the same walls as the ramp. Seen in play: it covers
-- our tinted ramps. It is in no per-cell texpos layer, so it cannot be skipped
-- cell by cell. DF looks a token's texture up in its tables of token texposes,
-- gps.texture_indices1 to 11, as it draws: Making Fuel's hide sprite already
-- writes DF's ITEM_LIQUID entry there, and globs follow it live. So hiding the
-- overlay means pointing every overlay token's entry at one blank texture, and
-- showing it again means writing the old values back. The entries are found by
-- value: whichever hold a texpos off either overlay page. That is global, so
-- every ramp loses its overlay, not only the ones stone-tint draws. The shadows
-- are other tokens (SHADOWS_RAMP and SHADOWS_WALL, or Dark Depths' DARK_ ones)
-- and are left alone.
--
-- The blank is a RESERVED texture: these entries hold raw texposes, not
-- handles, and the dynamic range gets wiped and renumbered. The entries and
-- their old values live in an environment global, so a console command
-- re-running this file cannot lose what is needed to put them back.
stone_tint_overlays = stone_tint_overlays or {hidden=false}
-- Detailed Landscapes' RAMP_OVERLAY_ROUND_DETAILED is deliberately not here:
-- it carries most of the rounded hills' shape, and hiding it left ramps square
-- (seen in play 2026-11-15). Vanilla's and Dark Depths' overlays are angular,
-- and are still hidden while ramps are tinted.
local OVERLAY_PAGES = {RAMP_OVERLAY=true, DARK_RAMP_OVERLAY=true}
local TEXTURE_TABLES = {}
for i = 1, 11 do TEXTURE_TABLES[i] = 'texture_indices' .. i end

local function blank_reserved_texpos()
    local ov = stone_tint_overlays
    if ov.blank_handle == nil then
        local blank = {}
        for i = 1, CELL_PX * CELL_PX do blank[i] = 0 end
        local ok, handles = pcall(dfhack.textures.createTileset, blank, CELL_PX, CELL_PX,
            CELL_PX, CELL_PX, true)
        ov.blank_handle = ok and handles and handles[1] or false
    end
    if not ov.blank_handle then return nil end
    local t = dfhack.textures.getTexposByHandle(ov.blank_handle)
    return t and t > 0 and t or nil
end

-- {table name, index, old value} for every token entry holding an overlay
-- texture. One pass over the tables, about 52,000 entries, so it runs only
-- when the overlays are hidden, never per frame.
local function find_overlay_slots()
    local wanted, any = {}, false
    local pages = df.global.texture.page
    for pi = 0, #pages - 1 do
        local page = pages[pi]
        if page.loaded and OVERLAY_PAGES[page.token] then
            for j = 0, #page.texpos - 1 do
                local t = page.texpos[j]
                if t > 0 then wanted[t], any = true, true end
            end
            for j = 0, #page.texpos_gs - 1 do
                local t = page.texpos_gs[j]
                if t > 0 then wanted[t] = true end
            end
        end
    end
    local slots = {}
    if not any then return slots end
    -- (BOTH DETAILED WEATHERS, 2026-11-20) while Detailed Weather shows a look of its own, an overlay's
    -- entries hold its copy, which no overlay page holds: found through its record of what each copy
    -- it points the tables at was made from (detailed_weather_pointed_from, in both its versions).
    -- Only Detailed Weather writes its copies into these tables, so a match is always one of its own.
    local from = rawget(_G, 'detailed_weather_pointed_from')
    local gps = df.global.gps
    for _, name in ipairs(TEXTURE_TABLES) do
        local ok, arr = pcall(function() return gps[name] end)
        if ok and arr then
            for i = 0, #arr - 1 do
                local v = arr[i]
                if wanted[v] or (from and from[v] and wanted[from[v]]) then slots[#slots + 1] = {name, i, v} end
            end
        end
    end
    return slots
end

local function hide_ramp_overlays()
    local ov = stone_tint_overlays
    local blank = blank_reserved_texpos()
    if not blank then return end
    local slots = find_overlay_slots()
    local gps = df.global.gps
    for _, s in ipairs(slots) do gps[s[1]][s[2]] = blank end
    -- Marked hidden even when nothing was found, so the tables are not
    -- searched again every frame; status reports the count.
    ov.slots, ov.blank, ov.hidden = slots, blank, true
end

local function show_ramp_overlays()
    local ov = stone_tint_overlays
    if not ov.hidden then return end
    local gps = df.global.gps
    for _, s in ipairs(ov.slots or {}) do
        -- Only an entry still holding our blank: one DF has written since is its own.
        pcall(function()
            if gps[s[1]][s[2]] == ov.blank then gps[s[1]][s[2]] = s[3] end
        end)
    end
    ov.slots, ov.hidden = nil, false
end

-- Keep the overlays the way the settings ask: hidden while ramps are tinted
-- and "Hide ramp overlays" is on, back otherwise. While hidden, one entry is
-- read each frame: DF rebuilding its tables (a graphics reload) writes all of
-- them back with new values, and then they are found and hidden again rather
-- than "restored" to values that no longer mean anything.
-- When DF has written its own values back, or the blank's texpos has moved:
-- the entries already found, pointed at the blank again, keeping DF's new
-- value as the one to put back. The tables are not searched again: DF keeps
-- each token at its index. Written 2026-11-15 to stop a search on every zoom,
-- when the resets seen in testing were taken to be DF's; they were console
-- commands (A COMMAND WHILE THE OVERLAY IS RUNNING), and DF does not reset
-- its textures on a zoom.
local function refresh_overlays(blank)
    local ov = stone_tint_overlays
    local gps = df.global.gps
    for _, s in ipairs(ov.slots) do
        pcall(function()
            local arr = gps[s[1]]
            local v = arr[s[2]]
            if v ~= ov.blank then s[3] = v end
            arr[s[2]] = blank
        end)
    end
    ov.blank = blank
end
function update_ramp_overlays()
    local ov = stone_tint_overlays
    local want = art ~= nil and state.strength > 0 and state.ramps and state.hide_overlays
    if ov.hidden then
        if not want then
            show_ramp_overlays()
        elseif ov.slots and ov.slots[1] then
            local s = ov.slots[1]
            local ok, v = pcall(function() return df.global.gps[s[1]][s[2]] end)
            local blank = blank_reserved_texpos()
            if not ok or not blank then
                ov.slots, ov.hidden = nil, false
            elseif v ~= ov.blank or blank ~= ov.blank then
                refresh_overlays(blank)
            end
        end
    end
    if want and not ov.hidden then hide_ramp_overlays() end
end

-- ==========================================
-- SHADOWS AND FOG
-- ==========================================
-- Black shadows and depth fog, as Bourbon's Dark Depths gives, done here so
-- they follow whatever graphics are loaded and nothing has to be installed or
-- loaded in any order. Measured 2026-11-15: Dark Depths' three sheets
-- (dark_shadows_wall, dark_shadows_ramp, dark_depths_z) have exactly vanilla's
-- alpha (shadows_wall, shadows_ramp, multilevel_overlay), every pixel, with the
-- colour set to black. So each shadow and fog texture DF draws through its
-- token tables is read back (THE ART AS DRAWN), redrawn with the same alpha in
-- black, and the table entries pointed at the copy, the way RAMP OVERLAYS
-- points the overlays at a blank.
--
-- Shadows: pixels darker than SHADE_MAX_LUMA go black; lighter ones stay, so
-- the light rim Detailed Landscapes draws along its rounded slopes' shadows is
-- kept (vanilla's shadows are all one dark blue, 0,31,52 and 0,57,101, and go
-- black whole). Fog: every pixel black. With Detailed Landscapes' rounded ramps
-- loaded, the fog over a ramp seen from above is also filled flat at its own
-- average darkness: the fog's ramp cells are cut for vanilla's angled ramps,
-- and drew angled shapes over rounded ones (seen in play 2026-11-15). Open air
-- is one flat darkness already.
--
-- Pages are matched by token, so vanilla's, Detailed Landscapes' rounded
-- shadows and Dark Depths' own (already black) are all found if loaded:
-- SHADOWS_WALL and SHADOWS_RAMP in the token for shadows, MULTILEVEL or
-- DEPTHS_Z for fog. The copies are RESERVED textures, as the overlay blank is:
-- these entries hold raw texposes, and the dynamic range gets renumbered. The
-- state lives in an environment global so a console re-run can put the
-- entries back. Applied once, then one entry is checked each frame, as the
-- overlays are.
stone_tint_shades = stone_tint_shades or {applied=false}
local SHADE_MAX_LUMA = 128

-- The black copies made here and below (FOG BELOW), kept by their content:
-- [hash .. range] = handle, or false. DF reuses texture numbers as it draws,
-- and the fog below is worked out again after every relearn, so a copy with
-- the same pixels is made once and its handle reused rather than a new
-- texture made each time. Handles survive a world load moving the textures;
-- the texpos is asked for each time. Forgotten with the other textures when a
-- world unloads.
stone_tint_copies = stone_tint_copies or {}

local function pixels_hash(px)
    local h = 0
    for i = 1, #px do h = (h * 31 + px[i] + i) % 9007199254740881 end
    return h
end

-- The texpos of a copy with these pixels, made the first time it is asked for;
-- reserved: in the range DF never wipes. nil if it cannot be made.
local function copy_texpos(px, reserved)
    local key = pixels_hash(px) .. (reserved and 'r' or 'd')
    local handle = stone_tint_copies[key]
    if handle == nil then
        local ok, h = pcall(dfhack.textures.createTile, px, CELL_PX, CELL_PX, reserved)
        handle = ok and h or false
        stone_tint_copies[key] = handle
    end
    if not handle then return nil end
    local t = dfhack.textures.getTexposByHandle(handle)
    if t and t > 0 then return t, handle end
    return nil
end

local function shade_kind(token)
    if token:find('MULTILEVEL') or token:find('DEPTHS_Z') then return 'fog' end
    if token:find('SHADOWS_WALL') or token:find('SHADOWS_RAMP') then return 'shadow' end
    return nil
end

-- texpos -> 'shadow' or 'fog' for every texture on a loaded shadow or fog
-- page, and whether Detailed Landscapes' rounded ramps are loaded.
local function shade_textures()
    local kinds, rounded = {}, false
    local pages = df.global.texture.page
    for pi = 0, #pages - 1 do
        local page = pages[pi]
        if page.loaded then
            if page.token == 'STONE_RAMPS_ROUND_DETAILED' then rounded = true end
            local kind = shade_kind(page.token)
            if kind then
                for j = 0, #page.texpos - 1 do
                    local t = page.texpos[j]
                    if t > 0 then kinds[t] = kind end
                end
                for j = 0, #page.texpos_gs - 1 do
                    local t = page.texpos_gs[j]
                    if t > 0 then kinds[t] = kind end
                end
            end
        end
    end
    return kinds, rounded
end

-- One shadow or fog texture redrawn, packed for createTile, or nil when it
-- cannot be read.
local function shaded_pixels(texpos, kind, flatten)
    local px, pitch = surface(texpos)
    if not px then return nil end
    local out, sum = {}, 0
    for n = 0, CELL_PX * CELL_PX - 1 do
        local p = px[(n // CELL_PX) * pitch + n % CELL_PX]
        local a = p >> 24
        -- Black keeps the pixel's alpha: a << 24.
        if kind == 'fog' or (p & 0xFF) * 0.299 + ((p >> 8) & 0xFF) * 0.587
                + ((p >> 16) & 0xFF) * 0.114 < SHADE_MAX_LUMA then
            p = a << 24
        end
        out[n + 1] = p
        sum = sum + a
    end
    if kind == 'fog' and flatten then
        -- A ramp's fog cell filled flat at its own mean alpha, in black.
        local mean = (sum + 512) // 1024
        for i = 1, CELL_PX * CELL_PX do out[i] = mean << 24 end
    end
    return out
end

-- Points every shadow and fog entry in DF's token tables at a black copy.
-- {table name, index, old value, copy, texpos written} is kept for each, to put
-- them back and to follow DF's texture resets (refresh_shades).
local function apply_shades()
    local sh = stone_tint_shades
    local kinds, rounded = shade_textures()
    local made, slots = {}, {}
    local gps = df.global.gps
    for _, name in ipairs(TEXTURE_TABLES) do
        local ok, arr = pcall(function() return gps[name] end)
        if ok and arr then
            for i = 0, #arr - 1 do
                local v = arr[i]
                local kind = kinds[v]
                if kind then
                    local copy = made[v]
                    if copy == nil then
                        copy = false
                        local px = shaded_pixels(v, kind, rounded)
                        local t, handle
                        if px then t, handle = copy_texpos(px, true) end
                        if t then copy = {texpos=t, handle=handle} end
                        made[v] = copy
                    end
                    if copy then
                        arr[i] = copy.texpos
                        -- [5]: the texpos written here, to tell DF's own from ours
                        slots[#slots + 1] = {name, i, v, copy, copy.texpos}
                    end
                end
            end
        end
    end
    -- Marked applied even when nothing was found, so the tables are not
    -- searched again every frame; status reports the count. flat: whether
    -- ramp fog is filled flat, for the fog DF builds below (FOG BELOW).
    sh.slots, sh.applied, sh.flat = slots, true, rounded
end

local function remove_shades()
    local sh = stone_tint_shades
    if not sh.applied then return end
    local gps = df.global.gps
    for _, s in ipairs(sh.slots or {}) do
        -- Only an entry still holding our copy: one DF has written since is its own.
        pcall(function()
            if gps[s[1]][s[2]] == s[5] then gps[s[1]][s[2]] = s[3] end
        end)
    end
    sh.slots, sh.applied = nil, false
end

-- Keep the shadows the way the settings ask, as update_ramp_overlays does the
-- overlays: one entry read each frame, and all found again if DF rebuilt its
-- tables.
-- When DF has written its own values back, or a copy's texpos has moved: the
-- entries already found, pointed at the same copies again, as
-- refresh_overlays does, with no search.
local function refresh_shades()
    local gps = df.global.gps
    for _, s in ipairs(stone_tint_shades.slots) do
        local copy = s[4]
        local t = dfhack.textures.getTexposByHandle(copy.handle)
        if t and t > 0 then copy.texpos = t end
        pcall(function()
            local arr = gps[s[1]]
            local v = arr[s[2]]
            if v ~= s[5] then s[3] = v end   -- DF wrote its own again: the new one to put back
            arr[s[2]] = copy.texpos
            s[5] = copy.texpos
        end)
    end
end
function update_shades()
    local sh = stone_tint_shades
    local want = state.black_shadows
    if sh.applied then
        if not want then
            remove_shades()
        elseif sh.slots and sh.slots[1] then
            local s = sh.slots[1]
            local ok, v = pcall(function() return df.global.gps[s[1]][s[2]] end)
            local t = dfhack.textures.getTexposByHandle(s[4].handle)
            if not ok then
                sh.slots, sh.applied = nil, false
            elseif v ~= s[5] or (t and t > 0 and t ~= s[5]) then
                refresh_shades()
            end
        end
    end
    if want and not sh.applied then apply_shades() end
end

-- ==========================================
-- FOG BELOW
-- ==========================================
-- The tables only reach the first level down. Measured with
-- stone-tint-fog-probe 2026-11-15, looking down through several levels of open
-- ground: DF draws the fog for every level below into one layer,
-- lower_viewport[0].screentexpos_interface (lower_viewport[1] to [7] held
-- nothing). Most of it was our black copies (open air alone on 2190 cells),
-- the rest textures DF builds as it draws (texpos 160952 and up, on 384, 252,
-- 210, 130, 79 and 50 cells), which showed as vanilla's sky blue on the deeper
-- levels: DF builds the deeper fog from its own fog art, not through the
-- tables. So each frame that layer is read, and a texture DF built is swapped
-- for a black copy with the same alpha, worked out once and kept.
--
-- Only a texture whose every visible pixel is vanilla's fog blue
-- (multilevel_overlay.png: 89,146,172 and 90,147,172, within FOG_TOLERANCE) is
-- treated as fog; anything else in the layer is left alone, and so is
-- everything already black. As with the pictures read for the tint (THE ART AS
-- DRAWN), DF hands freed numbers to new textures, so each is checked again
-- every SOURCE_CHECK_MS against a few pixels and its surface's address, and at
-- most FOG_READS_PER_FRAME new ones are read a frame. With Detailed
-- Landscapes' rounded ramps loaded, the copies are filled flat at their mean
-- alpha, as the first level's are (SHADOWS AND FOG).
local FOG_RGB = {89, 146, 172}
local FOG_TOLERANCE = 8
local FOG_READS_PER_FRAME = 4
local fog_copies = {}             -- texpos -> {copy=texpos or false, addr=, sig=, round=}
local fog_reads = 0

-- A fog texture's black copy, packed for createTile, or nil when it is not
-- fog (a visible pixel not vanilla's fog blue).
local function black_fog_pixels(px, pitch, flatten)
    local out, sum, any = {}, 0, false
    for n = 0, CELL_PX * CELL_PX - 1 do
        local p = px[(n // CELL_PX) * pitch + n % CELL_PX]
        local a = p >> 24
        if a > 0 then
            if math.abs((p & 0xFF) - FOG_RGB[1]) > FOG_TOLERANCE
                    or math.abs(((p >> 8) & 0xFF) - FOG_RGB[2]) > FOG_TOLERANCE
                    or math.abs(((p >> 16) & 0xFF) - FOG_RGB[3]) > FOG_TOLERANCE then
                return nil
            end
            any = true
        end
        out[n + 1] = a << 24
        sum = sum + a
    end
    if not any then return nil end
    if flatten then
        local mean = (sum + 512) // 1024
        for i = 1, CELL_PX * CELL_PX do out[i] = mean << 24 end
    end
    return out
end

-- The black copy for a texture in the fog layer: a texpos, false when it is
-- not fog, or nil when it waits for a later frame.
local function fog_copy(t)
    local c = fog_copies[t]
    if c and c.round == source_round then return c.copy end
    -- As source_for: nothing read off a texture without a read to spend.
    if fog_reads <= 0 then return c and c.copy or nil end
    local px, pitch, addr = surface(t)
    if not px then
        fog_copies[t] = {copy=false, round=source_round}
        return false
    end
    local sig = signature(px, pitch)
    fog_reads = fog_reads - 1
    if c and c.sig == sig then
        c.round, c.addr = source_round, addr
        return c.copy
    end
    local copy = false
    local black = black_fog_pixels(px, pitch, stone_tint_shades.flat)
    if black then copy = copy_texpos(black, false) or false end
    fog_copies[t] = {copy=copy, addr=addr, sig=sig, round=source_round}
    return copy
end

-- Each frame: the fog layer of the levels below, made black.
local function paint_fog()
    if not state.black_shadows or not stone_tint_shades.applied then return end
    local lvp = df.global.gps.lower_viewport[0]
    if not lvp or not lvp.flag.active then return end
    fog_reads = FOG_READS_PER_FRAME
    local layer = lvp.screentexpos_interface
    for i = 0, lvp.dim_x * lvp.dim_y - 1 do
        local t = layer[i]
        if t ~= 0 then
            local copy = fog_copy(t)
            if copy then layer[i] = copy end
        end
    end
end

-- ==========================================
-- WHAT A TILE IS
-- ==========================================
-- The art id for a revealed natural stair or ramp of stone or soil (sand
-- excepted), or false for any other tile. flag is the tile's
-- screentexpos_ramp_flag, which picks a ramp's cell. Map reads, so the render
-- loop calls it only for a texture it has not seen since the last reset and
-- for a stair or ramp tile it has not checked, never per cell per frame.
local function natural_art(x, y, z, flag)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return false end
    local material, tshape = tile_attrs(tt)
    local family
    if STONE_MATERIALS[material] then
        family = 'stone'
    elseif material == MAT_SOIL then
        family = 'soil'
    else
        return false
    end
    local id
    local shape = STAIR_SHAPES[tshape]
    if shape then
        id = STAIR_ART[family][shape]
    elseif tshape == df.tiletype_shape.RAMP and art then
        local bits = flag and math.tointeger(flag)
        local cell = bits and art.RAMP_CELL[(bits >> 8) & 0xFF]
        id = cell and RAMP_ART[family][cell]
    end
    if not id then return false end
    local des = dfhack.maps.getTileFlags(x, y, z)
    if des and des.hidden then return false end
    if family == 'soil' and is_sand(x, y, z) then return false end
    return id
end

-- Whether a tile DF drew its engraved floor picture on is one stone-tint draws:
-- a revealed natural stone floor. ENGRAVED or false. Map reads, so the render
-- loop calls it once per tile, kept against the texture like a learned stair
-- (paint_cell).
local function natural_engraved(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return false end
    local material, shape = tile_attrs(tt)
    if not STONE_MATERIALS[material] or shape ~= df.tiletype_shape.FLOOR then
        return false
    end
    local des = dfhack.maps.getTileFlags(x, y, z)
    if des and des.hidden then return false end
    return ENGRAVED
end

-- Whether a tile is subterranean (Detailed Weather's test for underground).
local function is_subterranean(x, y, z)
    local des = dfhack.maps.getTileFlags(x, y, z)
    return des and des.subterranean or false
end

-- ==========================================
-- SETTINGS AND CACHES
-- ==========================================
local function load_state()
    if not dfhack.isMapLoaded() then return end
    local saved = dfhack.persistent.getSiteData(GLOBAL_KEY, {})
    if tonumber(saved.strength) then state.strength = tonumber(saved.strength) end
    if TINT_STYLES[saved.style] then state.style = saved.style end
    for _, k in ipairs({'rough', 'smooth', 'stairs', 'ramps', 'soil', 'hide_overlays', 'black_shadows',
                        'engraved', 'faces'}) do
        if saved[k] ~= nil then state[k] = saved[k] end
    end
end

local function save_state()
    if dfhack.isMapLoaded() then dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
end

-- Forget every learned texture; keep only the floor sprites.
local function reset_known()
    known_texpos = {}
    dw_filed = {}
    for texpos, id in pairs(floor_texpos) do known_texpos[texpos] = id end
end

local function reset_cache(z)
    cached_z = z
    color_cache = {}
    tile_checks = {}
    reset_known()
end

-- The view moved to another level. The textures filed are forgotten, since DF
-- may renumber its run-time textures as it draws another level, but each
-- level's colours and tile checks are kept while it is within KEEP_LEVELS of
-- the view: a tile's material does not change with the camera, and every tile
-- check is kept against the texture DF drew, so a changed tile is read again
-- anyway. A tile whose stone changes in play (obsidian cast over it, then
-- mined) keeps its old colour until its level leaves that range, the map is
-- reloaded or `stone-tint clear-cache` is run. Until 2026-11-15 all of it was
-- thrown away on every change of level, and every tile on screen, the levels
-- below included, was looked up again in one frame.
local KEEP_LEVELS = 16
local function change_level(z)
    cached_z = z
    for lz in pairs(color_cache) do
        if math.abs(lz - z) > KEEP_LEVELS then color_cache[lz] = nil end
    end
    for lz in pairs(tile_checks) do
        if math.abs(lz - z) > KEEP_LEVELS then tile_checks[lz] = nil end
    end
    reset_known()
end

-- One level's colour and tile check tables, made on first need.
local function level_caches(z)
    local colours = color_cache[z]
    if not colours then colours = {} color_cache[z] = colours end
    local checks = tile_checks[z]
    if not checks then checks = {} tile_checks[z] = checks end
    return colours, checks
end

local function refresh_map_bounds()
    if not dfhack.isMapLoaded() then
        map_max_x, map_max_y = nil, nil
        return
    end
    local ok, x, y = pcall(dfhack.maps.getTileSize)
    if ok then map_max_x, map_max_y = x, y end
end

-- Repaint immediately after a settings change rather than waiting for DF to
-- decide the screen is stale.
local function force_repaint()
    df.global.gps.force_full_display_count = 1
end

local function set_strength(strength)
    state.strength = strength
    save_state()
    update_ramp_overlays()
    force_repaint()
    return true
end

local function set_style(style)
    if not TINT_STYLES[style] then return false end
    state.style = style
    save_state()
    force_repaint()
    return true
end

-- Only the pristine floor texposes need rediscovering; they move when the game
-- reloads graphics. Cheap: at most 39 findGraphicsTile calls. Learned
-- textures are dropped only when a floor texpos actually moved (or force), so
-- the periodic refresh does not throw away what the loop has learned.
local function refresh_texpos_maps(force)
    local fresh = {}
    local fresh_sets = {}
    local function add(list, first_id)
        -- The list's first twelve pictures (pieces 1 to 9, then 5B to 5D) are
        -- one set for FLOOR EDGES; VARIANTS' thirteenth, the smooth floor,
        -- drops no edge pieces.
        local set = {first_id=first_id, texpos={}}
        for i, spec in ipairs(list) do
            local texpos = dfhack.screen.findGraphicsTile(spec[1], spec[2], spec[3])
            if texpos and texpos >= 0 then
                fresh[texpos] = first_id + i - 1
                if i <= 12 then
                    set.texpos[i] = texpos
                    fresh_sets[texpos] = set
                end
            end
        end
    end
    add(VARIANTS, 1)
    -- Also recognize vanilla rough-floor pages. This lets the same script run
    -- standalone or alongside Detailed Landscapes.
    add(VANILLA_VARIANTS, 1)
    add(SOIL_VARIANTS, FIRST_SOIL_FLOOR)
    -- Detailed Landscapes' own floor pages (ROUND_VARIANTS). A page that is
    -- not loaded finds nothing, so this is harmless without it.
    add(ROUND_VARIANTS, 1)
    add(ROUND_SOIL_VARIANTS, FIRST_SOIL_FLOOR)
    -- Engraved floors file as ENGRAVED, not an art id (ENGRAVED FLOORS).
    engraved_found = 0
    for _, spec in ipairs(ENGRAVED_PAGES) do
        local texpos = dfhack.screen.findGraphicsTile(spec[1], spec[2], spec[3])
        if texpos and texpos >= 0 then
            fresh[texpos] = ENGRAVED
            engraved_found = engraved_found + 1
        end
    end
    local changed = force
    for texpos, id in pairs(fresh) do
        if floor_texpos[texpos] ~= id then changed = true end
    end
    for texpos in pairs(floor_texpos) do
        if fresh[texpos] == nil then changed = true end
    end
    floor_texpos = fresh
    piece_sets = fresh_sets
    -- A floor picture that moved leaves every tinted floor's filed set stale.
    if changed then
        reset_known()
        reset_tints()
    end
end

-- ==========================================
-- THE OVERLAY
-- ==========================================
StoneTintOverlay = defclass(StoneTintOverlay, overlay.OverlayWidget)
StoneTintOverlay.ATTRS{
    desc='Tint natural stone and soil floors, engraved floors, stairs and ramps by their material.',
    viewscreens='dwarfmode',
    default_enabled=true,
}

function StoneTintOverlay:init()
    load_state()
    refresh_texpos_maps(true)
    refresh_map_bounds()
    reset_cache(nil)
end

-- Per-frame values paint_cell reads, set at the top of each frame.
-- frame_engraved is the art id an engraved floor gets this frame.
local frame_strength, frame_budget, frame_engraved = 0, 0, ENGRAVED_FACE

-- One cell DF drew with a texture that may be ours (its known_texpos entry is
-- not false): works out which art it is, if any, and writes the tinted texture
-- over DF's. bg and flags are the arrays of the viewport the cell is in, z its
-- level, colours and checks that level's caches. Returns the kind of tile it
-- tinted, for the counts, or nil. One function for the level you are on and
-- the levels below, so both tint the same way. Every map read and material
-- lookup in here waits for a later frame once this frame's work is spent
-- (THE FRAME'S WORK CAP), and the cell keeps DF's own picture until then.
local function paint_cell(bg, flags, index, drawn, wx, wy, z, colours, checks)
    local id = known_texpos[drawn]
    if id == nil then
        -- First sight of this texture since the last reset. Detailed
        -- Weather's live copy of a floor sprite is that floor (DETAILED
        -- WEATHER); anything else takes one map read, which files it for
        -- every cell after this.
        if not can_work() then this_frame.waited = this_frame.waited + 1 return nil end
        local t0 = clock()
        id = dw_floor(drawn)
        if id == nil then
            id = natural_art(wx, wy, z, flags[index]) and LEARNED or false
        end
        known_texpos[drawn] = id
        this_frame.maps, this_frame.map_s = this_frame.maps + 1, this_frame.map_s + clock() - t0
    end
    if id == LEARNED then
        -- A texture DF drew on a natural stair or ramp. Which shape this tile
        -- is, and for a ramp which walls it meets, is read once and kept
        -- against the texture, so a changed tile is read again.
        local ccol = checks[wx]
        if not ccol then ccol = {} checks[wx] = ccol end
        local check = ccol[wy]
        if not check or check.texpos ~= drawn then
            if not can_work() then this_frame.waited = this_frame.waited + 1 return nil end
            local t0 = clock()
            check = {texpos=drawn, id=natural_art(wx, wy, z, flags[index])}
            ccol[wy] = check
            this_frame.maps, this_frame.map_s = this_frame.maps + 1, this_frame.map_s + clock() - t0
        end
        id = check.id
    elseif id == ENGRAVED then
        -- DF's engraved floor picture (ENGRAVED FLOORS). Whether this tile is
        -- natural stone is read once and kept against the texture, as above;
        -- which picture it gets is the "Engraving faces" switch.
        local ccol = checks[wx]
        if not ccol then ccol = {} checks[wx] = ccol end
        local check = ccol[wy]
        if not check or check.texpos ~= drawn then
            if not can_work() then this_frame.waited = this_frame.waited + 1 return nil end
            local t0 = clock()
            check = {texpos=drawn, id=natural_engraved(wx, wy, z)}
            ccol[wy] = check
            this_frame.maps, this_frame.map_s = this_frame.maps + 1, this_frame.map_s + clock() - t0
        end
        id = check.id and frame_engraved
    end
    if not id or not group_enabled[ART_GROUP[id]] then return nil end
    local col = colours[wx]
    if not col then col = {} colours[wx] = col end
    local code = col[wy]
    if not code then
        if not can_work() then this_frame.waited = this_frame.waited + 1 return nil end
        local t0 = clock()
        code = lookup_colour(wx, wy, z)
        col[wy] = code
        this_frame.colours, this_frame.colour_s = this_frame.colours + 1, this_frame.colour_s + clock() - t0
    end
    if code == 0 then return nil end
    -- Which picture to tint (THE ART AS DRAWN): the one DF drew, or the stored
    -- art for an engraved floor.
    local sid
    if ART_KIND[id] == K_ENGRAVED then
        sid = -id
    else
        local src = drawn
        -- Detailed Weather's copy of a floor (DETAILED WEATHER): its weather
        -- colouring outdoors, DF's own picture on a subterranean tile, read
        -- once per tile and kept against the texture like a learned stair.
        local original = dw_filed[drawn]
        if original then
            local ccol = checks[wx]
            if not ccol then ccol = {} checks[wx] = ccol end
            local check = ccol[wy]
            if not check or check.texpos ~= drawn then
                if not can_work() then this_frame.waited = this_frame.waited + 1 return nil end
                local t0 = clock()
                check = {texpos=drawn, under=is_subterranean(wx, wy, z)}
                ccol[wy] = check
                this_frame.maps, this_frame.map_s = this_frame.maps + 1, this_frame.map_s + clock() - t0
            end
            if check.under then src = original end
        end
        sid = source_for(src)
        if sid == nil then return nil end   -- not read yet: DF's own picture this frame
        if not sid then sid = -id end       -- cannot be read: the stored art
    end
    local per = tint_cache[sid]
    if not per then per = {} tint_cache[sid] = per end
    local texpos = per[code]
    if texpos == nil then
        texpos, frame_budget = tint_texpos(sid, code, frame_strength, frame_budget)
        -- nil: not this frame, so not cached; asked again next frame
        if texpos ~= nil then per[code] = texpos end
        -- FLOOR EDGES: a floor's tinted texture is filed with what its edge
        -- pieces need, its set, colour and picture, as it is made.
        if texpos and ART_KIND[id] == K_FLOOR then
            local set = piece_sets[dw_filed[drawn] or drawn]
            if set then edge.info[texpos] = {set=set, code=code, sid=sid} end
        end
    end
    if not texpos then return nil end
    bg[index] = texpos
    return ART_KIND[id]
end

-- ==========================================
-- FLOOR EDGES
-- ==========================================
-- A floor's art is a 3x3 set: the floor itself in the middle (piece 5, or 5B
-- to 5D) and eight small pieces round it that hang over its edges into the
-- next cells (vanilla's FLOORS 0:3 to 2:5, Landscapes' FLOORS_ROUND_DETAILED
-- at the same cells, soil on the dirt rows below). Where a floor meets open
-- ground (a channel, a ramp's top, a cliff) DF draws those pieces on the open
-- cell in the art's own colours, so every tinted floor kept a grey lip round
-- a channel (seen in play 2026-11-15).
--
-- They are not in any picture layer: stone-tint-cell-probe found no picture in
-- Landscapes' stone colours in any texpos layer on the rim's cells. DF draws
-- them as it renders, from screentexpos_floor_flag: one byte per side, S, W, E
-- and N from the lowest (devel/inspect-screen's layout), each the edging ID of
-- the floor on that side, 0 for none, and a special texture in bits 32 to 34.
-- Measured with stone-tint-edge-probe 2026-11-15: every open cell round a 4x4
-- channel in mineral floors had 9 on each side that met a floor, and nothing
-- else set. Matched pixel for pixel against a screenshot of that channel: each
-- side with edging got its floor's piece for that side (N 8, S 2, W 6, E 4,
-- the names Detailed Weather's grass.lua gives them), and each corner where
-- two sides had edging also got the diagonal floor's corner piece (NW 9, NE 7,
-- SW 3, SE 1). A cell with edging on one side only got no corner piece, though
-- its diagonals were floors too.
--
-- Not only open cells take edging. Seen in play 2026-11-15 after round 14:
-- the channel's rim was tinted, but grey lips stayed round stone and clay
-- floors along a river, and stone-tint-edge-probe on that screen found a
-- picture in screentexpos_background on all 510 cells, river included, with
-- edging on 356 of them (grass over grass, grass over stone floors, and
-- more). So every cell DF draws on a level is looked at, whatever its own
-- background, whenever that level has floors of ours.
--
-- So on every cell with edging, each side whose floor stone-tint tinted this
-- frame gets that floor's piece, tinted as the floor is (keep moves it by the
-- floor's own shift), and each corner between two sides carrying the same
-- edging ID, one of them ours, gets the diagonal floor's corner piece in the
-- diagonal's tint (a side's, when the diagonal is not one of ours). Corners
-- were measured only where both sides held 9; where the two sides hold
-- different IDs (a grass edge beside a stone one) what DF draws is not known,
-- so no corner is added there. The pieces are stacked into
-- one texture in the cell's screentexpos_background_two, which DF draws over
-- the edging (Detailed Weather's snow_ramps.lua covers DF's corner pieces the
-- same way). DF's own pieces stay in floor_flag, covered rather than cleared:
-- each tinted piece is the same picture, so it hides DF's exactly, and DF's
-- choice of corners is left alone.
--
-- Not done yet, and left as DF draws them: an edge whose floor is not drawn in
-- the same viewport (off the edge of the screen, or under the level above in
-- a deeper shaft), a cell whose background_two is already in use (a shrub or
-- a boulder on it), a cell with the special texture bits set (none seen), and
-- a corner piece from a floor that only touches the cell diagonally (not yet
-- measured).
local paint_edges
do
-- floor_flag's side bytes, lowest first, each with the floor that drops its
-- edge there (dx, dy in cells) and the piece of that floor's set that lands.
local SIDES = {
    {shift=0,  dx=0,  dy=1,  piece=2},     -- S
    {shift=8,  dx=-1, dy=0,  piece=6},     -- W
    {shift=16, dx=1,  dy=0,  piece=4},     -- E
    {shift=24, dx=0,  dy=-1, piece=8},     -- N
}
-- The corners: the two sides (SIDES index) that meet there, north or south
-- first, the diagonal floor's offset and the corner piece it drops.
local CORNERS = {
    {a=4, b=2, dx=-1, dy=-1, piece=9},     -- NW
    {a=4, b=3, dx=1,  dy=-1, piece=7},     -- NE
    {a=1, b=2, dx=-1, dy=1,  piece=3},     -- SW
    {a=1, b=3, dx=1,  dy=1,  piece=1},     -- SE
}
-- Scratch, reused for every cell: each side's floor (edge.info's entry, or
-- false), and the pieces to stack, bottom first: picture, colour code, the
-- floor's picture (keep's mean), and the parts of the stack's key.
local taken = {}
local p_sid, p_code, p_fsid, parts = {}, {}, {}, {}

-- A source's pixel list and 1024 indices: a picture read off DF, or for a
-- negative id our stored art (THE ART AS DRAWN). nil if it has none.
local function source_data(sid)
    if sid < 0 then
        local idx = decode(ART_CELL[-sid])
        if not idx then return nil end
        return art.PIXELS, idx
    end
    local data = stone_tint_sources.data[sid]
    if not data then return nil end
    return data.list, data.idx
end

-- Puts one piece of a floor's set (f, an edge.info entry) on top of the stack
-- of n. Returns the new count, or nil while the piece's picture waits for a
-- read: then the cell keeps DF's own edges this frame.
local function add_piece(n, f, piece)
    local texpos = f.set.texpos[piece]
    if not texpos then return nil end
    local sid = source_for(texpos)
    if sid == nil then return nil end
    -- Cannot be read: our stored copy of that piece.
    if not sid then sid = -(f.set.first_id + piece - 1) end
    n = n + 1
    p_sid[n], p_code[n], p_fsid[n] = sid, f.code, f.sid
    return n
end

-- The stack as one texture's pixels, each piece tinted and laid over the ones
-- before it. Every floor piece in vanilla's and Landscapes' sets is fully
-- opaque where it is drawn (checked 2026-11-15), so a visible pixel simply
-- replaces the one under it. Returns a handle, or false.
local function stack_texture(n, strength)
    local out = {}
    for j = 1, CELL_PX * CELL_PX do out[j] = 0 end
    for i = 1, n do
        local list, idx = source_data(p_sid[i])
        local pal = palette_of(p_code[i] - 1)
        if not list or not pal then return false end
        local mlist, midx = source_data(p_fsid[i])
        local entries = tinted_entries(pal, strength, list, idx, mlist, midx)
        for j = 1, CELL_PX * CELL_PX do
            local v = entries[idx[j]]
            if v >> 24 > 0 then out[j] = v end
        end
    end
    local ok, handles = pcall(dfhack.textures.createTileset, out, CELL_PX, CELL_PX,
        CELL_PX, CELL_PX)
    if ok and handles and handles[1] then return handles[1] end
    return false
end

-- The texpos for the stack of n, made on its first request within the frame's
-- texture budget, as tint_texpos does a floor's. Returns texpos, false
-- (nothing to draw) or nil (not this frame).
local function stack_texpos(n)
    -- Keep's result depends on the floor's picture too; the others' do not.
    local keep = state.style == 'keep'
    for i = 1, n do
        parts[i] = keep and (p_sid[i] .. ':' .. p_code[i] .. ':' .. p_fsid[i])
            or (p_sid[i] .. ':' .. p_code[i])
    end
    local key = table.concat(parts, ' ', 1, n)
    local texpos = edge.made[key]
    if texpos ~= nil then return texpos end
    -- The handles live with the floors' textures, one store per style and
    -- strength, so they go when those do and a console re-run keeps them.
    local stores = stone_tint_textures.edges
    if not stores then stores = {} stone_tint_textures.edges = stores end
    local skey = state.style .. frame_strength
    local store = stores[skey]
    if not store then store = {} stores[skey] = store end
    local handle = store[key]
    if handle == nil then
        if frame_budget <= 0 or not can_work() then return nil end
        frame_budget = frame_budget - 1
        local t0 = clock()
        handle = stack_texture(n, frame_strength)
        this_frame.made, this_frame.made_s = this_frame.made + 1, this_frame.made_s + clock() - t0
        store[key] = handle
        if handle then stone_tint_stats.textures = stone_tint_stats.textures + 1 end
    end
    if not handle then
        edge.made[key] = false
        return false
    end
    local t = dfhack.textures.getTexposByHandle(handle)
    -- 0 means DFHack is holding the texture until DF finishes loading.
    if t and t > 0 then
        edge.made[key], edge.ours[t] = t, true
        return t
    end
    return nil
end

-- One open cell's stack: the texpos for its edging (flag) at screen cell sx,
-- sy, or nil when no side's floor is ours or a piece waits for a read.
local function cell_stack(flag, sx, sy, bg, dim_x, dim_y, info)
    -- Each side with edging: is the floor that drops it one of ours?
    local any = false
    for s = 1, 4 do
        local side = SIDES[s]
        local f = false
        if (flag >> side.shift) & 0xFF ~= 0 then
            local nx, ny = sx + side.dx, sy + side.dy
            if nx >= 0 and nx < dim_x and ny >= 0 and ny < dim_y then
                f = info[bg[nx * dim_y + ny]] or false
                if f then any = true end
            end
        end
        taken[s] = f
    end
    if not any then return nil end
    -- Corners first, so the sides lie over them.
    local np = 0
    for c = 1, 4 do
        local corner = CORNERS[c]
        local a, b = corner.a, corner.b
        local id = (flag >> SIDES[a].shift) & 0xFF
        if np and (taken[a] or taken[b]) and id ~= 0
                and (flag >> SIDES[b].shift) & 0xFF == id then
            local f
            local nx, ny = sx + corner.dx, sy + corner.dy
            if nx >= 0 and nx < dim_x and ny >= 0 and ny < dim_y then
                f = info[bg[nx * dim_y + ny]]
            end
            np = add_piece(np, f or taken[a] or taken[b], corner.piece)
        end
    end
    for s = 1, 4 do
        if np and taken[s] then np = add_piece(np, taken[s], SIDES[s].piece) end
    end
    if not np or np == 0 then return nil end
    return stack_texpos(np) or nil
end

-- One level's cells (cells, 1 to n: indices into port's buffers, or nil for
-- every index 0 to n - 1; bg its screentexpos_background): each with edging
-- gets its tinted pieces.
paint_edges = function(port, bg, cells, n, dim_x, dim_y)
    if n == 0 then return end
    local ff, bg2 = port.screentexpos_floor_flag, port.screentexpos_background_two
    if not ff or not bg2 then return end
    local info, ours = edge.info, edge.ours
    for k = 1, n do
        local cell = cells and cells[k] or k - 1
        local flag = ff[cell]
        if flag ~= 0 then
            local held = bg2[cell]
            -- A stack of ours from an earlier frame still in place would mean
            -- DF does not draw background_two afresh each frame, as it does
            -- the background. Not yet measured, so it is counted for
            -- `stone-tint status`, and the cell is redone as if empty, and
            -- emptied if it gets nothing now, so a lip never sticks.
            local stale = held ~= 0 and ours[held]
            if stale then
                stone_tint_stats.edges_kept = (stone_tint_stats.edges_kept or 0) + 1
                held = 0
            end
            local texpos
            if held == 0 and flag >> 32 == 0 then
                local sx = cell // dim_y
                texpos = cell_stack(flag, sx, cell - sx * dim_y, bg, dim_x, dim_y, info)
            end
            if texpos then
                bg2[cell] = texpos
                edge.count = edge.count + 1
            elseif stale then
                bg2[cell] = 0
            end
        end
    end
end
end

-- DF rebuilds screentexpos_background from scratch every rendered frame. This
-- was measured, not assumed: writing a sentinel into the buffer and reading it
-- back 1, 5 and 60 frames later found it gone every time (see probe.lua). Two
-- consequences shape this function:
--
--   * The scan cannot be skipped on quiet frames. There is no persistent state
--     to keep dirty -- skip a frame and DF's untinted floor is what shows.
--   * Nothing needs restoring. When the tint is switched off or a floor falls
--     out of scope we simply decline to write, and DF's own sprite stands.
--
-- So the work went into making each cell nearly free instead. Per cell in the
-- common case (not one of our floors, stairs or ramps) this is one array read
-- and one hash lookup, with no allocation and no C call; an empty cell is one
-- read and a note for the level below. Map reads happen only to file a texture
-- the loop has not seen since the last reset and to check a stair or ramp tile
-- once; material lookups once per tile per z-level, kept while the level is
-- near the view; texture making at most NEW_TEXTURES_PER_FRAME times a frame;
-- and all of it within WORK_MS a frame (THE FRAME'S WORK CAP). The levels
-- below cost nothing more than the cells the level above left empty (THE
-- LEVELS BELOW).
-- TIMING, for `stone-tint status`: each frame's cost in ms, as a running
-- average over the last few dozen frames (frame_ms) and the worst since status
-- last showed it (worst_ms), the overlays, shadows and fog's share (fog_ms),
-- and running totals of the costly paths: texture resets (the sentinel
-- moved), pictures read and checked, materials looked up, map reads. Added
-- 2026-11-15 when every map action lagged with the tint on and nothing showed
-- where the time went.
local function timed_average(old, value) return (old or value) + (value - (old or value)) * 0.05 end

-- THE SLOW FRAME REPORT. A frame that takes SLOW_FRAME_MS or more is kept as
-- one line: when it was (seconds since DF started), what moved (the level, the
-- view, a relearn after a map load), each costly path's count and time this
-- frame, and the rest last: the scan itself and anything not timed. `stone-tint
-- status` prints them and starts over; the last SLOW_KEEP are kept.
local SLOW_FRAME_MS = 40
local SLOW_KEEP = 12
local last_win_x, last_win_y

local function ms(seconds) return math.floor(seconds * 1000 + 0.5) end

-- Running totals of each costly path, {count, seconds} in stone_tint_stats.cost,
-- so status can show what one of each costs on average.
local function add_cost(name, n, s)
    if n == 0 then return end
    local cost = stone_tint_stats.cost
    if not cost then cost = {} stone_tint_stats.cost = cost end
    local c = cost[name]
    if not c then c = {0, 0} cost[name] = c end
    c[1], c[2] = c[1] + n, c[2] + s
end

local function record_slow_frame(took, upkeep, relearn, level_from, z, moved, scanned)
    local slow = stone_tint_stats.slow
    if not slow then slow = {} stone_tint_stats.slow = slow end
    local what = {}
    if level_from then what[#what + 1] = ('level %d to %d'):format(level_from, z) end
    if moved then what[#what + 1] = 'view moved' end
    if relearn > 0 then what[#what + 1] = 'relearn after a map load' end
    if #what == 0 then what[1] = 'nothing moved' end
    local timed = ms(this_frame.colour_s + this_frame.map_s + this_frame.check_s + this_frame.read_s + this_frame.made_s)
    slow[#slow + 1] = ('%d ms at %d s (%s): materials %d in %d ms, map reads %d in %d ms, '
        .. 'pictures looked at %d in %d ms and read %d in %d ms, textures %d in %d ms, '
        .. 'overlays, shadows and fog %d ms, relearn %d ms, the rest %d ms (%d cells '
        .. 'scanned); %d tiles left for later'):format(
        math.floor(took + 0.5), dfhack.getTickCount() // 1000, table.concat(what, ', '),
        this_frame.colours, ms(this_frame.colour_s), this_frame.maps, ms(this_frame.map_s), this_frame.checks, ms(this_frame.check_s),
        this_frame.reads, ms(this_frame.read_s), this_frame.made, ms(this_frame.made_s), math.floor(upkeep + 0.5),
        math.floor(relearn + 0.5), math.floor(took - upkeep - relearn - timed + 0.5),
        scanned, this_frame.waited)
    if #slow > SLOW_KEEP then table.remove(slow, 1) end
end

function StoneTintOverlay:onRenderFrame(dc, rect)
    StoneTintOverlay.super.onRenderFrame(self, dc, rect)

    if not dfhack.screen.inGraphicsMode() or not dfhack.isMapLoaded() then return end
    local started = clock()
    -- Before the strength check, so turning the tint off puts the overlays back.
    -- The shadows go with neither the tint nor its strength (SHADOWS AND FOG).
    update_ramp_overlays()
    update_shades()
    paint_fog()
    local upkeep = (clock() - started) * 1000
    stone_tint_stats.fog_ms = timed_average(stone_tint_stats.fog_ms, upkeep)
    stone_tint_stats.upkeep_worst_ms = math.max(stone_tint_stats.upkeep_worst_ms or 0, upkeep)
    local strength = state.strength
    if strength == 0 or not art then return end
    -- THE FRAME'S WORK CAP runs from here, after the upkeep above, and this
    -- frame's counts start at nothing.
    work_until = clock() + WORK_MS / 1000
    this_frame.colours, this_frame.colour_s, this_frame.maps, this_frame.map_s = 0, 0, 0, 0
    this_frame.checks, this_frame.check_s, this_frame.reads, this_frame.read_s = 0, 0, 0, 0
    this_frame.made, this_frame.made_s, this_frame.waited = 0, 0, 0

    local gps = df.global.gps
    local vp = gps.main_viewport
    if not vp then return end
    local dim_x, dim_y = vp.dim_x, vp.dim_y
    if dim_x <= 0 or dim_y <= 0 then return end

    if not map_max_x then
        refresh_map_bounds()
        if not map_max_x then return end
    end

    local z = df.global.window_z
    local level_from
    if z ~= cached_z then
        level_from = cached_z
        if cached_z then change_level(z) else reset_cache(z) end
    end

    -- One C call per frame instead of one per cell: if the sentinel's texpos
    -- has moved, DF reset its textures, every texpos held here is stale, and
    -- the floor sprites and learned textures have moved with it. DFHack moves
    -- its dynamic textures only when a world loads or a new game starts (the
    -- reset points in its Textures.cpp, read 2026-11-15), never on a zoom or a
    -- change of level, so in play this runs once per map load.
    local relearn = 0
    local sentinel = sentinel_texpos()
    if sentinel ~= tint_sentinel then
        local t0 = clock()
        tint_sentinel = sentinel
        stone_tint_stats.resets = (stone_tint_stats.resets or 0) + 1
        reset_tints(true)
        -- Every texpos moved: which picture each showed is read again, and
        -- the fog below is worked out again (FOG BELOW).
        stone_tint_sources.by_texpos = {}
        fog_copies = {}
        refresh_texpos_maps(true)
        relearn = (clock() - t0) * 1000
    end
    -- THE ART AS DRAWN: this frame's reads, and a new round of checks now and then.
    frame_reads, frame_checks = READS_PER_FRAME, CHECKS_PER_FRAME
    frame_id = frame_id + 1
    local now = dfhack.getTickCount()
    if now - source_round_at >= SOURCE_CHECK_MS then
        source_round, source_round_at = source_round + 1, now
    end
    if strength ~= tint_strength or state.style ~= tint_style then
        tint_strength, tint_style = strength, state.style
        reset_tints()
        entry_cache = {}
    end

    -- Which groups are in scope this frame. Only cells already found to be ours
    -- ask, so the common cell never touches this.
    local enabled = group_enabled
    local soil = state.soil
    enabled[G_ROUGH], enabled[G_SMOOTH] = state.rough, state.smooth
    enabled[G_STAIRS], enabled[G_RAMPS] = state.stairs, state.ramps
    enabled[G_SOIL_FLOORS] = soil and state.rough
    enabled[G_SOIL_STAIRS] = soil and state.stairs
    enabled[G_SOIL_RAMPS] = soil and state.ramps
    enabled[G_ENGRAVED] = state.engraved
    if not (state.rough or state.smooth or state.stairs or state.ramps or state.engraved) then
        return
    end

    -- Detailed Weather's look moved on: its old copies' numbers may be reused.
    dw_check_look()

    -- Taken after the z, sentinel and strength checks above, any of which can
    -- replace them.
    local bg = vp.screentexpos_background
    local ramp_flags = vp.screentexpos_ramp_flag
    local known = known_texpos
    local win_x, win_y = df.global.window_x, df.global.window_y
    local moved = last_win_x ~= nil and (win_x ~= last_win_x or win_y ~= last_win_y)
    last_win_x, last_win_y = win_x, win_y
    local max_x, max_y = map_max_x, map_max_y
    local counts = frame_counts
    counts[K_FLOOR], counts[K_STAIR], counts[K_RAMP], counts[K_ENGRAVED] = 0, 0, 0, 0
    edge.count = 0
    frame_strength, frame_budget = strength, NEW_TEXTURES_PER_FRAME
    frame_engraved = state.faces and ENGRAVED_FACE or ENGRAVED_PLAIN
    local colours, checks = level_caches(z)
    local open, n_open = see_through, 0
    local scanned = dim_x * dim_y         -- cells looked at this frame, for the report

    -- The level you are on. index = sx * dim_y + sy, so iterating sy innermost
    -- lets it just increment.
    local index = 0
    for sx = 0, dim_x - 1 do
        local wx = win_x + sx
        if wx < 0 or wx >= max_x then
            index = index + dim_y
        else
            for sy = 0, dim_y - 1 do
                local drawn = bg[index]          -- the texpos DF drew here this frame
                if drawn == 0 then
                    -- Nothing drawn here: the level below shows through.
                    n_open = n_open + 1
                    open[n_open] = index
                elseif known[drawn] ~= false then
                    local wy = win_y + sy
                    if wy >= 0 and wy < max_y then
                        local kind = paint_cell(bg, ramp_flags, index, drawn, wx, wy, z,
                            colours, checks)
                        if kind then counts[kind] = counts[kind] + 1 end
                    end
                end
                index = index + 1
            end
        end
    end

    -- FLOOR EDGES on this level, every cell, and only when it has floors of
    -- ours to drop them.
    local floors_so_far = counts[K_FLOOR]
    if floors_so_far > 0 then paint_edges(vp, bg, nil, dim_x * dim_y, dim_x, dim_y) end

    -- The levels below, one at a time, through the cells left empty above
    -- (see THE LEVELS BELOW). A cell empty again on this level goes on the
    -- list for the next one down.
    local below = 0
    local lower = gps.lower_viewport
    local next_open = see_next
    for i = 0, LOWER_LEVELS - 1 do
        local lz = z - i - 1
        if n_open == 0 or lz < 0 then break end
        local lvp = lower and lower[i]
        if not lvp or not lvp.flag.active or lvp.dim_x ~= dim_x or lvp.dim_y ~= dim_y then break end
        local lbg, lflags = lvp.screentexpos_background, lvp.screentexpos_ramp_flag
        if not lbg or not lflags then break end
        scanned = scanned + n_open
        colours, checks = level_caches(lz)
        local n_next = 0
        for k = 1, n_open do
            local cell = open[k]
            local drawn = lbg[cell]
            if drawn == 0 then
                n_next = n_next + 1
                next_open[n_next] = cell
            elseif known[drawn] ~= false then
                local sx = cell // dim_y
                local wy = win_y + cell - sx * dim_y
                if wy >= 0 and wy < max_y then
                    local kind = paint_cell(lbg, lflags, cell, drawn, win_x + sx, wy, lz,
                        colours, checks)
                    if kind then
                        counts[kind] = counts[kind] + 1
                        below = below + 1
                    end
                end
            end
        end
        -- This level's floor edges, as on the level above: every cell of it
        -- that shows (open, the list it was walked through).
        if counts[K_FLOOR] > floors_so_far then
            paint_edges(lvp, lbg, open, n_open, dim_x, dim_y)
            floors_so_far = counts[K_FLOOR]
        end
        open, next_open, n_open = next_open, open, n_next
    end

    stone_tint_stats.floors = counts[K_FLOOR]
    stone_tint_stats.engraved = counts[K_ENGRAVED]
    stone_tint_stats.stairs = counts[K_STAIR]
    stone_tint_stats.ramps = counts[K_RAMP]
    stone_tint_stats.below = below
    stone_tint_stats.edges = edge.count
    local took = (clock() - started) * 1000
    stone_tint_stats.frame_ms = timed_average(stone_tint_stats.frame_ms, took)
    stone_tint_stats.worst_ms = math.max(stone_tint_stats.worst_ms or 0, took)
    add_cost('materials', this_frame.colours, this_frame.colour_s)
    add_cost('maps', this_frame.maps, this_frame.map_s)
    add_cost('looks', this_frame.checks, this_frame.check_s)
    add_cost('reads', this_frame.reads, this_frame.read_s)
    add_cost('made', this_frame.made, this_frame.made_s)
    if took >= SLOW_FRAME_MS then
        record_slow_frame(took, upkeep, relearn, level_from, z, moved, scanned)
    end
end

function StoneTintOverlay:overlay_onupdate()
    -- Graphics can be reloaded without changing texture handles. Refresh only the
    -- texpos values that identify the game's original floor sprites.
    refresh_texpos_maps(false)
end

-- Module state outlives a world: DFHack caches script environments, and the
-- overlay framework rebuilds widgets on SC_WORLD_LOADED without clearing
-- anything here. Without this, loading a second fort whose camera happens to
-- start on the same z-level as the last one leaves cached_z matching and paints
-- the previous fort's stone colours.
dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        -- Detailed Weather is looked up again for each map (DETAILED WEATHER).
        dw_colour, dw_look, dw_filed = nil, nil, {}
        palettes = {}
        entry_cache = {}
        reset_tints(true)
        reset_material_caches()
        refresh_map_bounds()
        load_state()
        refresh_texpos_maps(true)
        reset_cache(nil)
    elseif sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        -- Put DF's ramp overlays and shadows back; the next map redoes them.
        show_ramp_overlays()
        remove_shades()
        fog_copies = {}
        reset_cache(nil)
        map_max_x, map_max_y = nil, nil
        palettes = {}
        entry_cache = {}
        reset_tints(true)
        reset_material_caches()
        if sc == SC_WORLD_UNLOADED then
            -- Colour indices belong to a world. The textures are not deleted
            -- (see make_texture); they are only forgotten.
            stone_tint_textures = {art_count=ART_COUNT, by_source=true}
            stone_tint_sources = {next_id=1, data={}, by_texpos={}, by_hash={}}
            stone_tint_copies = {}
        else
            -- The next map's textures may sit at other numbers.
            stone_tint_sources.by_texpos = {}
        end
    end
end

-- ==========================================
-- THE WINDOW
-- ==========================================
TintWindow = defclass(TintWindow, widgets.Window)
TintWindow.ATTRS{
    frame_title='Stone Tint',
    -- Height is the body plus 4 (border and inset, top and bottom). The body
    -- runs to the Close line at row 28, so 29 rows.
    frame={w=44, h=33},
    resizable=false,
    autoarrange_subviews=true,
    autoarrange_gap=1,
}

local function toggle(label, key, field)
    return widgets.ToggleHotkeyLabel{
        label=label, key=key, initial_option=state[field],
        -- update_ramp_overlays here as well as per frame, so the overlays come back
        -- even with the stone-tint.map widget switched off.
        on_change=function(value)
            state[field]=value save_state() update_ramp_overlays() update_shades() force_repaint()
        end,
    }
end

function TintWindow:init()
    local strength_options = {}
    for i, strength in ipairs(STRENGTHS) do
        strength_options[i] = {label=strength == 0 and 'Off' or strength .. '%', value=i}
    end
    local initial_idx = 1
    for i, strength in ipairs(STRENGTHS) do
        if strength == state.strength then initial_idx = i break end
    end
    local style_options = {}
    for i, st in ipairs(TINT_STYLES) do style_options[i] = {label=st[2], value=st[1]} end
    self:addviews{
        widgets.Label{text='Tint strength:'},
        widgets.CycleHotkeyLabel{
            view_id='strength', label='Strength:', key='CUSTOM_SHIFT_S',
            options=strength_options, initial_option=initial_idx,
            on_change=function(idx) set_strength(STRENGTHS[idx]) end,
        },
        widgets.Slider{
            frame={l=1, w=38}, num_stops=#STRENGTHS,
            get_idx_fn=function() return self.subviews.strength:getOptionValue() end,
            on_change=function(idx) self.subviews.strength:setOption(idx, true) end,
        },
        -- How the tint is worked out (THE TINT). Classic is the original look.
        widgets.CycleHotkeyLabel{
            view_id='style', label='Tint style:', key='CUSTOM_K',
            options=style_options, initial_option=state.style,
            on_change=function(value) set_style(value) end,
        },
        widgets.Divider{frame={h=1}, frame_style_l=false, frame_style_r=false},
        toggle('Tint rough floors:', 'CUSTOM_R', 'rough'),
        toggle('Tint smooth floors:', 'CUSTOM_M', 'smooth'),
        toggle('Tint engraved floors:', 'CUSTOM_E', 'engraved'),
        -- Vanilla's engraving, or the same tile with the face carved out. Only
        -- while engraved floors are tinted: stone-tint draws them or nothing.
        toggle('Engraving faces:', 'CUSTOM_F', 'faces'),
        toggle('Tint stairs:', 'CUSTOM_T', 'stairs'),
        toggle('Tint ramps:', 'CUSTOM_A', 'ramps'),
        -- Soil rides on the switches above: a soil floor, stair or ramp needs
        -- this and the switch for its shape.
        toggle('Include soil:', 'CUSTOM_O', 'soil'),
        -- Global: every ramp's overlay goes, see RAMP OVERLAYS. Only while
        -- ramps are tinted.
        toggle('Hide ramp overlays:', 'CUSTOM_H', 'hide_overlays'),
        -- Black shadows and depth fog, whatever graphics are loaded (SHADOWS
        -- AND FOG). Independent of the tint.
        toggle('Black shadows and fog:', 'CUSTOM_B', 'black_shadows'),
        widgets.Label{frame={t=28}, text={{key='LEAVESCREEN', text=': Close'}}},
    }
end

TintScreen = defclass(TintScreen, gui.ZScreen)
TintScreen.ATTRS{focus_path='stone-tint', pass_movement_keys=true}
function TintScreen:init() self:addviews{TintWindow{}} end
function TintScreen:onDismiss() view=nil end

function show_gui()
    if not dfhack.isMapLoaded() then qerror('stone-tint needs a loaded fortress map') end
    view = view and view:raise() or TintScreen{}:show()
end

function set_preset(strength)
    return set_strength(strength)
end

function clear_material_cache()
    reset_cache(nil)
    reset_material_caches()
    stone_tint_sources.by_texpos = {}
    palettes = {}
    entry_cache = {}
    reset_tints()
    refresh_map_bounds()
end

function get_state()
    return state
end

-- For `stone-tint status`: whether the art loaded, the counts the overlay
-- keeps in stone_tint_stats, the ramp overlay entries hidden, how many of the
-- engraved floor pages were found, and whether the art has the engraved cells
-- (an art-vanilla.lua older than this file does not, and then engraved floors
-- keep DF's picture).
function get_report()
    local ov = stone_tint_overlays
    local engraved_art = art ~= nil and art.CELLS.engraved_floor ~= nil
        and art.CELLS.engraved_floor_plain ~= nil
    local sh = stone_tint_shades
    return art ~= nil, stone_tint_stats, ov.hidden and #(ov.slots or {}) or nil,
        engraved_found, #ENGRAVED_PAGES, engraved_art, sh.applied and #(sh.slots or {}) or nil
end


-- Initialize module state independently of widget construction. DFHack can preserve
-- widget class objects across development rescans without calling init() again.
load_state()
refresh_texpos_maps(true)
refresh_map_bounds()

OVERLAY_WIDGETS = {map=StoneTintOverlay}

-- ==========================================
-- COMMANDS
-- ==========================================
-- The console's commands. Defined in the module, so a command is answered by
-- the copy of this file already running (A COMMAND WHILE THE OVERLAY IS
-- RUNNING, at the top) and touches none of the overlay's caches.
function stone_tint_command(...)
    local args = {...}
    if not args[1] or args[1] == 'gui' then
        show_gui()
    elseif args[1] == 'clear-cache' then
        clear_material_cache()
        print('stone-tint: material cache cleared')
    elseif args[1] == 'status' then
        print(('stone-tint: overlay is %s'):format(
            overlay.isOverlayEnabled('stone-tint.map') and 'enabled' or 'disabled'))
        print(('stone-tint: strength is %d%%, tint style %s'):format(get_state().strength,
            get_state().style))
        local art_ok, stats, hidden, engraved_found, engraved_pages, engraved_art, shaded =
            get_report()
        if not art_ok then
            print('stone-tint: art data stone-tint/art-vanilla.lua did not load; nothing is tinted')
        end
        print(('stone-tint: tinted in the last drawn frame: %d floor, %d engraved, %d stair, %d ramp '
            .. 'tiles, %d of them on levels below'):format(stats.floors, stats.engraved or 0,
            stats.stairs, stats.ramps, stats.below or 0))
        print(('stone-tint: floor edges over open ground tinted in the last drawn frame: %d cells; '
            .. 'found still in place from an earlier frame, so far: %d'):format(stats.edges or 0,
            stats.edges_kept or 0))
        print(('stone-tint: engraved floor pages found: %d of %d; engraved art %s'):format(
            engraved_found, engraved_pages,
            engraved_art and 'loaded' or 'missing from stone-tint/art-vanilla.lua'))
        print(('stone-tint: textures made this session: %d, from %d pictures read off DF'):format(
            stats.textures, stats.sources or 0))
        print(('stone-tint: frame %.2f ms recent average, worst %.2f ms since last status; '
            .. 'overlays, shadows and fog %.2f ms, worst %.2f ms'):format(stats.frame_ms or 0,
            stats.worst_ms or 0, stats.fog_ms or 0, stats.upkeep_worst_ms or 0))
        print(('stone-tint: so far: %d texture resets, %d pictures read, %d pictures checked')
            :format(stats.resets or 0, stats.reads or 0, stats.checks or 0))
        -- What one of each costly path has cost on average (add_cost).
        local cost = stats.cost or {}
        local function each(name, label)
            local c = cost[name] or {0, 0}
            return ('%s %d at %.3f ms'):format(label, c[1], c[1] > 0 and c[2] * 1000 / c[1] or 0)
        end
        print('stone-tint: cost each, so far: ' .. table.concat({each('materials', 'materials'),
            each('maps', 'map reads'), each('looks', 'pictures looked at'),
            each('reads', 'pictures read'), each('made', 'textures made')}, ', '))
        -- FAST MATERIALS: lookups by kind of tile, then how the checks stand.
        local kinds = {}
        for _, kind in ipairs(KIND_ORDER) do
            local c = fast.kinds[kind]
            if c then
                kinds[#kinds + 1] = ('%s %d at %.3f ms'):format(kind, c[1], c[2] * 1000 / c[1])
            end
        end
        print('stone-tint: materials by kind: ' .. (#kinds > 0 and table.concat(kinds, ', ')
            or 'none yet'))
        print(('stone-tint: fast material lookups %s: %d checked against tile-material '
            .. '(%.3f ms each), %s'):format(fast.on and 'on' or 'OFF', fast.checked,
            fast.full_n > 0 and fast.full_s * 1000 / fast.full_n or 0,
            fast.note and ('differed at ' .. fast.note) or 'none differed'))
        stats.worst_ms, stats.upkeep_worst_ms = 0, 0
        if hidden then
            print(('stone-tint: ramp overlays hidden (%d DF table entries)'):format(hidden))
        else
            print('stone-tint: ramp overlays shown')
        end
        if shaded then
            print(('stone-tint: shadows and fog black (%d DF table entries)'):format(shaded))
        else
            print('stone-tint: shadows and fog as the graphics draw them')
        end
        -- THE SLOW FRAME REPORT, oldest first, then started over.
        local slow = stats.slow or {}
        if #slow == 0 then
            print(('stone-tint: no frame took %d ms or more since last status'):format(SLOW_FRAME_MS))
        else
            print(('stone-tint: frames of %d ms or more since last status, oldest first:')
                :format(SLOW_FRAME_MS))
            for _, line in ipairs(slow) do print('  ' .. line) end
        end
        stats.slow = {}
    elseif args[1] == 'set' then
        local strength = tonumber(args[2])
        local valid = false
        for _, value in ipairs(STRENGTHS) do if value == strength then valid=true break end end
        if not valid then qerror('strength must be one of: ' .. table.concat(STRENGTHS, ', ')) end
        set_preset(strength)
    elseif args[1] == 'style' then
        if not set_style(args[2]) then qerror('style must be one of: keep, smooth, classic') end
    else
        print('Use: stone-tint [gui]')
        print('     overlay enable stone-tint.map')
        print('     overlay disable stone-tint.map')
        print('     stone-tint clear-cache')
        print('     stone-tint status')
        print('     stone-tint set <' .. table.concat(STRENGTHS, '|') .. '>')
        print('     stone-tint style <keep|smooth|classic>')
    end
end

if dfhack_flags.module then return end

-- Only reached by a command run before the module ever loaded.
stone_tint_command(...)