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
-- What "Ramp overlays" can be (RAMP OVERLAYS), in the window's order as
-- {value, label}, and each value as a key.
local OVERLAY_MODES = {{'tinted', 'Tinted'}, {'hidden', 'Hidden'}, {'shown', 'As drawn'},
    tinted=true, hidden=true, shown=true}
local GLOBAL_KEY = 'stone-tint'
local CELL_PX = 32
-- New textures made per frame at most. The first sight of a material makes one
-- texture per kind of tile it covers; a z-level full of new materials would
-- otherwise make them all in one frame and stall it. A tile waiting its turn
-- keeps DF's own picture for a frame or two.
-- (1.3.6) 12 again, from the 32 of 1.3.0. Every overlay draws on the game's
-- own thread (THE QUICK FRAMES), so time spent here is game time lost. At 32 a
-- backlog (a new level, a pan onto new stone, every change of Detailed
-- Weather's look) ran at the whole WORK_MS a frame until it was done; at 12
-- the count stops it sooner and the backlog takes a few frames more.
local NEW_TEXTURES_PER_FRAME = 12

-- ==========================================
-- THE ART
-- ==========================================
-- Vanilla's floor, stair and ramp art as Lua data, written by
-- build_stone_tint_art.py. Each pixel carries its key column, the palette
-- column its tint blends toward. Tiles are tinted from the picture DF actually
-- drew (THE ART AS DRAWN), so this is what a picture that cannot be read falls
-- back to, how vanilla's engraving is known (and drawn without its face:
-- ENGRAVED FLOORS BY THE MAP), and where ramp cells are worked out from the
-- walls (RAMP_CELL). It is still required: without it nothing is tinted.
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
-- TILES BY THE MAP
-- ==========================================
-- (v1.2.0, 2026-11-21) Which tiles are tinted is read off the map, never off
-- a tile page: a revealed natural tile of stone (STONE, MINERAL, FEATURE,
-- LAVA_STONE) or soil (SOIL, sand excepted), shaped as a floor (a boulder's
-- tile too: DF draws its floor under it), a stair or a ramp (WHAT A TILE IS).
-- Whatever picture DF drew in that tile's ground layer is tinted (THE ART AS
-- DRAWN), whichever graphics drew it: vanilla's, Detailed Landscapes', Detailed
-- Weather's look copies, a mod's own floors or engravings. Until v1.1 floors
-- and engraved floors were found by their tile pages, by name (FLOORS,
-- ALT_FLOORS, DETAILED_FLOORS, FLOORS_ROUND_DETAILED and the two engraved
-- floor pages), so graphics drawing them off any other page went untinted.
--
-- A floor is rough, smooth (tiletype special SMOOTH) or engraved (smooth, with
-- an engraving on its floor), each with its own switch. The art id a kind gets
-- picks the switch and the count, and the stored picture drawn when DF's
-- cannot be read: vanilla's main floor (stone_floor_5, soil_floor_5), its
-- smooth floor, or its engraving.
local KIND_ART = {rough_stone = 5, rough_soil = FIRST_SOIL_FLOOR + 4, smooth = 13}

-- ==========================================
-- ENGRAVED FLOORS BY THE MAP
-- ==========================================
-- A natural stone floor is engraved when an engraving (world.event.engravings)
-- is on its floor (flags.floor). The engravings are filed by level, the files
-- made again whenever their number changes (checked once a frame:
-- engravings.refresh).
--
-- Vanilla draws a natural engraved floor with FLOOR_STONE_ENGRAVED_NON_PALETTE,
-- seven fixed blue-greys cut into its smooth floor, not in the stone's colour
-- (seen in play 2026-10-21: an engraved claystone floor showed them, 104,110,114
-- the commonest pixel, beside an engraved claystone wall in the stone's brown).
-- Tinted as drawn like every other picture, it moves toward the stone's colour
-- the way the floor round it does, and so does any graphics' own engraving.
-- The "Engraving faces" switch can only carve the face out of a picture it
-- knows: when DF's picture is vanilla's engraving (all its pixels the same as
-- our stored copy's: engravings.vanilla; read off Detailed Weather's original
-- while one of its looks shows), the switch off draws our copy without the
-- face (engraved_floor_plain.png, see build_stone_tint_art.py). Any other
-- engraving keeps its picture whole.
local ENGRAVED = -2    -- what a natural engraved floor is (its picture: the switch's, per tile)
-- by_level[z][x][y] = true for each engraved floor; count: the engravings
-- filed (-1: none yet); vanilla_hash: read_source's hash of our stored copy of
-- vanilla's engraving (nil: not worked out yet, false: no stored copy).
-- Functions (refresh, at, vanilla) are added below, once what they use exists.
local engravings = {count = -1, by_level = {}}

-- ==========================================
-- STAIRS AND RAMPS: LEARNED FROM THE MAP
-- ==========================================
-- DF does not draw natural stairs or ramps off a tile page. Measured with
-- stone-tint-stair-probe and stone-tint-ramp-probe: every stone, mineral and
-- soil stair and every stone and mineral ramp held a texture in
-- screentexpos_background that is on no tile page, one per material and shape
-- (every pyrite up-stair on screen shared one; three tetrahedrite ramps against
-- different walls had three), and no other layer held anything for them. Grass
-- stairs alone came straight off the STAIRS page. The run-time textures were
-- renumbered between runs along with the pages. They were the first tiles read
-- off the map; since v1.2 every tile is (TILES BY THE MAP). Our stored copies of
-- vanilla's STAIRS rows 1 and 2, STONE_RAMPS and SOIL_RAMPS are their fallback.
--
-- A ramp's picture depends on which of its 8 neighbours are walls. DF works
-- that out itself and leaves it in screentexpos_ramp_flag, bits 8 to 15 in the
-- order N, W, E, S, NW, NE, SW, SE (the layout devel/inspect-screen decodes,
-- and DF's own VIEWPORT_RAMP_FLAG_WALL_*), so the overlay reads DF's answer
-- rather than working it out again, and art.RAMP_CELL turns it into the
-- vanilla cell. The probe's ramps decoded as a column against a west wall:
-- N_W, W, S_W. The probe found nothing of the ramp overlays or shadows
-- (vanilla's or Dark Depths') in any texpos layer, and in play Dark Depths'
-- ramp overlay drew on top of our tinted ramps: DF draws those from the flags
-- after the background. The overlay is drawn into the ramp's picture here
-- instead (RAMP OVERLAYS, below); the shadows stay.
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
-- What any other ramp is (grass, sand, a construction, ice): not tinted, but
-- given its overlay (RAMP OVERLAYS).
local RAMP_OTHER = -3

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
-- walked down only through cells the level above left empty, and stopped at
-- the first level where none were left, which on most screens is the first.
-- (1.3.5) Each level below is now scanned whole instead, every cell DF drew
-- there (diffscan skips the empty ones in C): DF also shows the levels below
-- under a tree's branches and leaves (Detailed Weather's 15P probe), and those
-- cells are not empty on the level above. Since DF fills a level below only
-- where it shows, that costs about what the walk did.
local LOWER_LEVELS = 8

-- ==========================================
-- STATE
-- ==========================================
-- Every texpos the ground layers have shown since the last reset, filed at its
-- first sight by the tile it was on (WHAT A TILE IS): false when no picture on
-- a tile like that one is ever ours (a wall, open space, grass), so it is never
-- looked at again; true otherwise, and every tile showing it is read off the
-- map once (tile_checks). One table for every level, so the common cell costs
-- one lookup. Emptied on every change of level, when DF's textures move and
-- when Detailed Weather's look changes: DF renumbers its run-time textures as
-- it draws, and Detailed Weather frees a look's copies.
local known_texpos = {}
local cached_z
-- Per level, since the levels below are drawn too. Both are kept while their
-- level is near the view (change_level) and emptied on a map load.
local color_cache = {}          -- [z] = {[world_x] = {[world_y] = colour code}}
-- [z] = {[world_x] = {[world_y] = {texpos=, id=, never=, under=}}}: what a
-- tile is (an art id, ENGRAVED, RAMP_OTHER or false, and whether no picture on
-- a tile like it is ever ours: WHAT A TILE IS) and, under one of Detailed
-- Weather's copies, whether it is subterranean, checked against the texture DF
-- drew there (a copy's original), so a tile goes back to the map only when its
-- picture changes.
local tile_checks = {}
local map_max_x, map_max_y      -- tile bounds, refreshed on map load
local state = {strength=50, style='keep', rough=true, smooth=true, stairs=true, ramps=true, soil=true,
               overlays='hidden', engraved=true, faces=true, black_shadows=true, edges='smart'}
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
    -- (PICTURES BY MEMCMP) and the pictures filed under those ids, their pixels freed
    for _, list in pairs(stone_tint_pictures or {}) do
        for _, filed in ipairs(list) do df.delete(filed.buf) end
    end
    stone_tint_pictures = nil
end
-- The pictures read off DF, kept beside the textures made from them so a
-- console re-run cannot hand an id already used to another picture: the next
-- id, each source's pixels by id, and which texpos showed which source.
stone_tint_sources = stone_tint_sources or {next_id=1, data={}, by_texpos={}, by_hash={}}
-- by_hash: a picture's content hash -> its id (THE ART AS DRAWN), so the same
-- picture under a new texpos keeps its id and its textures.
stone_tint_sources.by_hash = stone_tint_sources.by_hash or {}
-- (1.3.7) PICTURES BY MEMCMP, at source_for: every picture read keeps a copy
-- of its pixels, filed by its signature: signature -> list of {buf = the
-- pixels (df.new, freed by hand), at = their address, id = its source id}.
-- Kept and let go with the source ids it answers with.
stone_tint_pictures = stone_tint_pictures or {}

-- Resolved texposes for the strength in use: [source id] = {[colour code] =
-- texpos, or false for "nothing to draw"}. Thrown away when the strength
-- changes or our sentinel texture's texpos moves (DF reset its textures).
local tint_cache = {}
local tint_sentinel, tint_strength, tint_style
-- FLOOR EDGES (below).
local edge = {
    info = {},      -- a tinted floor's texpos -> {code=, sid=}: the colour and picture its pieces take
    made = {},      -- a stack of pieces (stack_texpos's key) -> texpos, or false
    ours = {},      -- every stack's texpos -> true, to know one of ours in background_two
    count = 0,      -- open cells given tinted edges this frame, for `stone-tint status`
    modes = {{'smart', 'Smart'}, {'simple', 'Simple'}, {'off', 'Off'},
             smart=true, simple=true, off=true},
    sources = {},   -- [z][wx][wy] = 9 (stone), 2 (soil), or false: map fallback for off-screen/overhang floors
    fallback = {},  -- code -> {code=, under=false} reused across frames
    piece_px = {},  -- [sid][code] = flat {j, abgr, ...} pre-tinted opaque pixels for one edge piece
    floor_px = {},  -- [sid][code] = 1024 pre-tinted floor pixels for smart edge baking
}
-- DF'S OWN PIECES AND OVERLAYS (below): what DF draws a floor's edge pieces
-- and a ramp's overlay from, found in the graphics raws by token.
-- stone[1 to 9], soil[1 to 9]: the texposes of STONE_FLOOR_1 to 9 and
-- DIRT_FLOOR_1 to 9; overlay[case]: of OVERLAY_RAMP_WITH_WALL_* and
-- OVERLAY_RAMP_OTHER, by the walls' case (case_of_walls); overlay_set: each
-- overlay's texpos -> true; checks: {page, x, y, texpos} for each, to notice
-- DF moving them; rehide: the overlays to be found again; dirs, files, found:
-- what was read, for `stone-tint status`.
local tokens = {stone = {}, soil = {}, pebbles = {}, overlay = {}, overlay_set = {}, checks = {},
                dirs = 0, files = 0, found = 0}
-- THE OVERLAY IN THE RAMP (below): made[sid][ov][code] = the texpos of a ramp's
-- picture with its overlay laid in, or false (code 0: as drawn); laid: ramps
-- given theirs this frame.
local ramp = {made = {}, laid = 0}
-- Every tinted texpos held here goes at once: a floor's texture is filed in
-- edge.info only as paint_cell makes it, so the two are thrown away together.
-- moved: DF renumbered its textures (or the map changed), so the stacks'
-- numbers go too. A change of strength or style moves nothing, so a stack of
-- the old one is still known as ours (paint_edges).
local function reset_tints(moved)
    tint_cache = {}
    edge.info, edge.made, edge.fallback, edge.piece_px, edge.floor_px = {}, {}, {}, {}, {}
    ramp.made = {}
    if moved then edge.ours = {} end
end

-- Scratch tables reused every frame so the render loop allocates nothing.
local group_enabled = {}
local frame_counts = {0, 0, 0, 0}
-- THE QUICK FRAMES (1.3.6): what a full frame wrote down, kept for the quick
-- frames after it, and their counts for `stone-tint status`. One table, as
-- this_frame is below. See the section of that name above onRenderFrame.
--   on        quick frames allowed (`stone-tint replay on|off`, this session)
--   levels    [0 the level you are on, 1 to LOWER_LEVELS below] = what was
--             written down for that level (level_of)
--   key       what the last full frame rested on (keep_key, why_full)
--   fx        this frame's view, for the functions below (set each frame)
--   fog       THE FOG KEPT
--   why       [reason] = full frames it has called since the last status
-- (A console command is answered by the copy already running, A COMMAND
-- WHILE THE OVERLAY IS RUNNING, so all of this lasts the session.)
local rp = {on = true, levels = {}, key = {valid = false}, fx = {}, why = {},
            quick_n = 0, full_n = 0, quick_ms = nil, full_ms = nil,
            edges_kept = 0, edges_redone = 0,
            fog = {valid = false, cap = 0, kept = 0, walked = 0, skipped = 0}}

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
    -- (1.3.6, THE QUICK FRAMES) pend: set by paint_cell when it left a tile for
    -- a later frame (no time left, a picture not read yet, a texture not made
    -- yet), so the tile stays on the quick frames' list and is tried again.
    pend = false,
}

-- ==========================================
-- DETAILED WEATHER
-- ==========================================
-- Detailed Weather (its colour.lua) recolours the ground for the weather by
-- pointing DF's texture tables (gps.texture_indices1 to 11) at its own copies
-- of every ground texture whenever its look is not the neutral one. DF then
-- draws a floor with the copy, which is tinted as drawn (TILES BY THE MAP), so
-- the floor keeps the weather's colouring under the tint. Underground it puts
-- DF's original back after we have drawn (its put_back_underground), so on a
-- subterranean tile the copy's original is tinted instead: what it shows there
-- itself. Read in its code 2026-11-15. Its restore underground only swaps back
-- textures it knows as its own copies, and ours is not one, so what we draw
-- stays.
--
-- It records every copy it points the tables at in the global
-- detailed_weather_pointed_from (copy texpos -> DF's own texpos), and its
-- copy_of(original) answers which copy is showing now. A copy is taken for its
-- original only while copy_of still returns it: DF hands a freed texture's
-- number to the next texture it makes (Detailed Weather's grass.lua notes
-- this), and Detailed Weather frees a look's copies once the look moves on, so
-- a stale entry could name a ramp or a tree. For the same reason all that is
-- filed by texpos is forgotten when the look changes (dw_check_look, once a
-- frame). The edge pieces and ramp overlays drawn here (FLOOR EDGES, RAMP
-- OVERLAYS) are taken from its copies while a look shows, as DF draws them.
local dw_colour            -- its colour module; nil not looked up yet, false not running
local dw_look              -- the look key it showed when last checked
-- This look's answers: filed[copy texpos] = DF's own texpos, or false (not one
-- of its live copies); live[DF's own texpos] = what DF draws for it now.
local dw_memo = {filed = {}, live = {}}

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

-- DF's own texpos for a texpos that is Detailed Weather's live copy of it, or
-- nil (filed for the look).
local function dw_original(drawn)
    local f = dw_memo.filed[drawn]
    if f == nil then
        f = false
        local from = rawget(_G, 'detailed_weather_pointed_from')
        local original = from and from[drawn]
        local mod = original and dw_module()
        if mod then
            local ok, live = pcall(dw_live_copy, mod, original)
            if ok and live == drawn then f = original end
        end
        dw_memo.filed[drawn] = f
    end
    return f or nil
end

-- What DF draws for its own `original` now: Detailed Weather's live copy of it
-- while one of its looks shows, else the original itself (filed for the look).
local function dw_shown(original)
    local t = dw_memo.live[original]
    if t == nil then
        t = original
        local mod = rawget(_G, 'detailed_weather_pointed_from') and dw_module()
        if mod then
            local ok, live = pcall(dw_live_copy, mod, original)
            if ok and live then t = live end
        end
        dw_memo.live[original] = t
    end
    return t
end

-- Once a frame: when Detailed Weather's look has changed, everything filed by
-- texpos is forgotten, so freed numbers are filed afresh.
local function dw_check_look()
    local mod = dw_colour
    if mod == nil and dw_memo.active then mod = dw_module() end
    if not mod then return end   -- not looked up or not running: nothing filed
    local ok, key = pcall(dw_shown_key, mod)
    key = ok and key or false
    if key == dw_look then return end
    dw_look = key
    known_texpos = {}
    dw_memo = {filed = {}, live = {}, active = dw_memo.active}
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

-- SOIL ON A ROCK LAYER / ROCK ON A SOIL LAYER: at the soil-rock boundary, a
-- tile's geolayer_index can point at the neighbouring layer type. DF resolves
-- a soil tile on rock to the deepest SOIL_ANY layer above it, and a stone tile
-- on soil to the shallowest non-soil layer below it.
local function adjust_layer_mat(x, y, z, want_soil)
    local rx, ry = dfhack.maps.getTileBiomeRgn(x, y, z)
    if not ry then return nil end
    local region = dfhack.maps.getRegionBiome(rx, ry)
    local biome = region and df.world_geo_biome.find(region.geo_index)
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not biome or not block then return nil end
    local index = block.designation[x % 16][y % 16].geolayer_index
    if want_soil then
        for i = math.min(index, #biome.layers) - 1, 0, -1 do
            local inorganic = df.inorganic_raw.find(biome.layers[i].mat_index)
            if inorganic and inorganic.flags.SOIL_ANY then
                return dfhack.matinfo.decode(0, biome.layers[i].mat_index)
            end
        end
    else
        for i = math.max(0, index + 1), #biome.layers - 1 do
            local inorganic = df.inorganic_raw.find(biome.layers[i].mat_index)
            if inorganic and not inorganic.flags.SOIL_ANY then
                return dfhack.matinfo.decode(0, biome.layers[i].mat_index)
            end
        end
    end
    return nil
end

-- The colour code for a tile: its colour index + 1, or 0 for none.
local function colour_code(x, y, z)
    local ok, matinfo = pcall(tile_material.GetTileMat, x, y, z)
    if not ok or not matinfo then
        local ok2, fallback = pcall(tile_material.GetLayerMat, x, y, z)
        matinfo = ok2 and fallback or nil
    end
    local material
    pcall(function()
        material = matinfo.material
        local tt = dfhack.maps.getTileType(x, y, z)
        local tmat = tt and df.tiletype.attrs[tt].material
        if tmat == df.tiletype_material.SOIL
                and matinfo.inorganic and not matinfo.inorganic.flags.SOIL_ANY then
            local soil = adjust_layer_mat(x, y, z, true)
            if soil then material = soil.material end
        elseif tmat == df.tiletype_material.STONE
                and matinfo.inorganic and matinfo.inorganic.flags.SOIL_ANY then
            local rock = adjust_layer_mat(x, y, z, false)
            if rock then material = rock.material end
        end
    end)
    local ci = material and material_colour(material)
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
local FAST_CHECKS = 32
local FAST_CHECK_EVERY = 256

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

-- tiletype -> {material class, shape, special}, read off df.tiletype.attrs
-- once per tiletype. WHAT A TILE IS uses them too.
local tt_info = {}
local function tile_attrs(tt)
    local info = tt_info[tt]
    if not info then
        local attrs = df.tiletype.attrs[tt]
        info = {attrs.material, attrs.shape, attrs.special}
        tt_info[tt] = info
    end
    return info[1], info[2], info[3]
end

-- How the checks on the fast lookups stand, plus the per-frame block cache
-- and the geolayer sand cache.
-- (1.3.6) READ ON DEMAND: a block's tiletypes and designations are read
-- straight from the block as each tile is asked for, through a uint16 and a
-- uint32 view of its two 16x16 arrays (index x * 16 + y, the order DF keeps
-- them in, as the copies were made). In 1.3.5 every block touched was copied
-- whole, all 256 of each, value by value through DFHack into two new Lua
-- tables, and the copies were thrown away every frame: panning one column
-- touched about 8 blocks, some 4,000 reads and 24 new tables a frame for the
-- hundred-odd tiles asked about. A view reads the block as it is (a tile dug
-- shows at once); the views are still made afresh each frame (fast.frame), as
-- the copies were, so none is kept past the frame its block was found in.
local fast = {on=true, calls=0, checked=0, note=nil, full_n=0, full_s=0, kinds={},
              layer_sand={}, blocks={}, frame=0, blocks_frame=-1}

function fast.init_bits()
    fast.des_init = true
    local raw = df.new('uint32_t')
    local _, at = df.sizeof(raw)
    local d = df.reinterpret_cast(df.tile_designation, at)
    local function bool_mask(name, fallback)
        raw.value = 0
        local ok = pcall(function() d[name] = true end)
        return (ok and raw.value ~= 0) and raw.value or fallback
    end
    local function int_bits(name, fb_shift, fb_mask)
        raw.value = 0
        local ok = pcall(function() d[name] = 1 end)
        if not ok or raw.value == 0 then return fb_shift, fb_mask end
        local v, shift = raw.value, 0
        while (v & 1) == 0 do v = v >> 1 shift = shift + 1 end
        raw.value = 0
        pcall(function() d[name] = 15 end)
        local mask = raw.value >> shift
        return shift, (mask ~= 0) and mask or fb_mask
    end
    fast.m_hidden = bool_mask('hidden', 1 << 9)
    fast.m_sub = bool_mask('subterranean', 1 << 15)
    fast.s_geo, fast.m_geo = int_bits('geolayer_index', nil, nil)
    fast.s_bio, fast.m_bio = int_bits('biome', nil, nil)
    df.delete(raw)
end

function fast.block(x, y, z)
    if fast.blocks_frame ~= fast.frame then
        if next(fast.blocks) then fast.blocks = {} end
        fast.blocks_frame = fast.frame
    end
    local blocks = fast.blocks
    local bx, by = x >> 4, y >> 4
    local key = ((z * 4096) + bx) * 4096 + by
    local b = blocks[key]
    if b ~= nil then return b or nil end
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then blocks[key] = false return nil end
    if not fast.des_init then fast.init_bits() end
    -- READ ON DEMAND: b.tt[i] and b.des[i] read the block's own arrays.
    local _, tat = df.sizeof(block:_field('tiletype'))
    local _, dat = df.sizeof(block:_field('designation'))
    b = {tt = df.reinterpret_cast('uint16_t', tat), des = df.reinterpret_cast('uint32_t', dat),
         rgn = {}}
    blocks[key] = b
    return b
end

function fast.rgn(b, x, y, z, d)
    if fast.m_bio then
        local slot = (d >> fast.s_bio) & fast.m_bio
        local r = b.rgn[slot]
        if r ~= nil then
            if r then return r[1], r[2] end
            return nil
        end
        local rx, ry = dfhack.maps.getTileBiomeRgn(x, y, z)
        b.rgn[slot] = ry and {rx, ry} or false
        return rx, ry
    end
    return dfhack.maps.getTileBiomeRgn(x, y, z)
end

-- What has been worked out on this map: colour codes by layer and by
-- inorganic index, and each block's mineral events. Emptied on a map load.
local layer_codes, inorganic_codes, mineral_blocks = {}, {}, {}
local function reset_material_caches()
    layer_codes, inorganic_codes, mineral_blocks = {}, {}, {}
    fast.layer_sand, fast.blocks = {}, {}
end

-- A material's colour code, made as colour_code makes it.
local function material_code(matinfo)
    local ci = matinfo and matinfo.material and material_colour(matinfo.material)
    return ci and ci + 1 or 0
end

-- Stone and soil: the colour code of the tile's layer, or nil.
-- want: 0 = raw layer, 1 = soil (walk up off rock), 2 = stone (walk down off soil).
-- Also caches SOIL_SAND per geolayer in fast.layer_sand so is_sand() costs zero
-- tile-material calls per tile.
local function layer_code(x, y, z, want)
    local b = fast.block(x, y, z)
    if not b then return nil end
    local d = b.des[(x & 15) * 16 + (y & 15)]
    local rx, ry = fast.rgn(b, x, y, z, d)
    if not ry then return nil end
    local geo
    if fast.m_geo then
        geo = (d >> fast.s_geo) & fast.m_geo
    else
        local des = dfhack.maps.getTileFlags(x, y, z)
        if not des then return nil end
        geo = des.geolayer_index
    end
    -- Region coordinates offset, so a -1 at a world edge cannot share a key.
    local base_key = ((rx + 1024) * 4096 + ry + 1024) * 16 + geo
    local key = base_key * 3 + (want or 0)
    local code = layer_codes[key]
    if code == nil then
        local ok, matinfo = pcall(tile_material.GetLayerMat, x, y, z)
        matinfo = ok and matinfo or nil
        if want == 1 and matinfo and matinfo.inorganic and not matinfo.inorganic.flags.SOIL_ANY then
            local soil = adjust_layer_mat(x, y, z, true)
            if soil then matinfo = soil end
        elseif want == 2 and matinfo and matinfo.inorganic and matinfo.inorganic.flags.SOIL_ANY then
            local rock = adjust_layer_mat(x, y, z, false)
            if rock then matinfo = rock end
        end
        code = material_code(matinfo)
        layer_codes[key] = code
        if want == 1 then
            fast.layer_sand[base_key] = matinfo and matinfo.inorganic
                and matinfo.inorganic.flags.SOIL_SAND or false
        end
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
    if m == MAT_MINERAL then return vein_code(x, y, z) or layer_code(x, y, z, 0) end
    return layer_code(x, y, z, m == MAT_SOIL and 1 or m == df.tiletype_material.STONE and 2 or 0)
end

-- A tile's colour code: the fast lookup, checked against colour_code now and
-- then, or colour_code itself.
local function lookup_colour(x, y, z)
    local t0 = clock()
    local m
    local b = fast.block(x, y, z)
    local tt = b and b.tt[(x & 15) * 16 + (y & 15)]
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
-- stairs and ramps), so it keeps that look. Cached per geolayer so panning
-- across sand surfaces costs zero tile-material calls per tile.
local function is_sand(x, y, z)
    local b = fast.block(x, y, z)
    if b and fast.m_geo then
        local d = b.des[(x & 15) * 16 + (y & 15)]
        local rx, ry = fast.rgn(b, x, y, z, d)
        if ry then
            local base_key = ((rx + 1024) * 4096 + ry + 1024) * 16 + ((d >> fast.s_geo) & fast.m_geo)
            local cached = fast.layer_sand[base_key]
            if cached ~= nil then return cached end
            layer_code(x, y, z, 1)
            cached = fast.layer_sand[base_key]
            if cached ~= nil then return cached end
        end
    end
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
tinted_entries = function(pal, strength, list, idx, mean_list, mean_idx, mean_rgb)
    list = list or art.PIXELS
    local s = strength / 100.0
    local style = state.style
    local out = {}
    if style == 'keep' and (idx or mean_rgb) then
        local mr, mg, mb
        if mean_rgb then
            mr, mg, mb = mean_rgb[1], mean_rgb[2], mean_rgb[3]
        else
            local ml, mi = mean_list or list, mean_idx or idx
            local sr, sg, sb, n = 0, 0, 0, 0
            for i = 1, #mi do
                local e = ml[mi[i]]
                if e[4] > 0 then sr, sg, sb, n = sr + e[1], sg + e[2], sb + e[3], n + 1 end
            end
            if n == 0 then n = 1 end
            mr, mg, mb = sr / n, sg / n, sb / n
        end
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
-- Engraved floors are tinted as drawn too (ENGRAVED FLOORS BY THE MAP). A
-- picture that cannot be read (no surface, not 32x32) falls back to the stored
-- art for its art id.
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
local function surface_raw(texpos)
    local s = df.global.enabler.textures.raws[texpos]
    if not s then return nil end
    local ints = df.reinterpret_cast('int32_t', s)
    if ints:_displace(4)[0] ~= CELL_PX or ints:_displace(5)[0] ~= CELL_PX then return nil end
    local pitch_bytes = ints:_displace(6)[0]
    if pitch_bytes % 4 ~= 0 then return nil end
    local address = df.reinterpret_cast('uint64_t', s):_displace(4)[0]
    return df.reinterpret_cast('uint32_t', address), pitch_bytes // 4, address
end

local function surface(texpos)
    local ok, px, pitch, addr = pcall(surface_raw, texpos)
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
    local list, idx, seen, opaque = {{0, 0, 0, 0, 0}}, {}, {}, {}
    local hash, sr, sg, sb, cnt, on = 0, 0, 0, 0, 0, 0
    for n = 0, CELL_PX * CELL_PX - 1 do
        local packed = px[(n // CELL_PX) * pitch + n % CELL_PX]
        local i = 1
        if packed >> 24 > 0 then
            local r, g, b = packed & 0xFF, (packed >> 8) & 0xFF, (packed >> 16) & 0xFF
            sr, sg, sb, cnt = sr + r, sg + g, sb + b, cnt + 1
            i = seen[packed]
            if not i then
                list[#list + 1] = {r, g, b, packed >> 24, key_of(r, g, b)}
                i = #list
                seen[packed] = i
            end
            on = on + 2
            opaque[on - 1], opaque[on] = n + 1, i
            hash = (hash * 31 + packed + n) % 9007199254740881
        end
        idx[n + 1] = i
    end
    if cnt == 0 then cnt = 1 end
    return {list=list, idx=idx, hash=hash, mean={sr / cnt, sg / cnt, sb / cnt}, opaque=opaque}
end

-- PICTURES BY MEMCMP (1.3.7). DF puts some pictures together itself as it
-- draws, ramps among them, and gives the same picture a new number after
-- every zoom and on a level not seen before (Detailed Weather met it first:
-- its frost.lua's RAMPS BY PICTURE and colour.lua's PICTURES BY MEMCMP, seen
-- in play there as ramps and shores showing the game's colours on every zoom).
-- Here a new number was a whole read, 1024 pixels through Lua (0.35 to 0.40 ms
-- in play), at most READS_PER_FRAME a frame, and until its turn every tile
-- showing it kept DF's own picture. So after each step of a zoom the ramps
-- went untinted for some frames and came back, and a fast zoom, in or out,
-- made the tint flicker off and on (seen in play 2026-11-26; that day's
-- `stone-tint status` had 429 pictures read for 284 pictures, a third of the
-- reads the same picture again; and offline, DF's ramps given new numbers at
-- each zoom of a simulated view showed it frame by frame, ending with this).
-- Now each picture read keeps a copy of its pixels (4 KB), filed by
-- its signature, and a new number is known again by its 16 pixels and one
-- memcmp of the whole picture against each filed under them: a check's cost,
-- not a read's, and no read budget spent. Only a picture never seen is read.
-- A surface whose rows are padded (pitch not 32) is read as before.
local PICTURE_BYTES = CELL_PX * CELL_PX * 4
-- The source id of a picture filed with these pixels, or nil.
local function picture_known(sig, addr, pitch)
    local memcmp = dfhack.internal.memcmp
    if not memcmp or not addr or pitch ~= CELL_PX then return nil end
    local list = stone_tint_pictures[sig]
    if not list then return nil end
    for _, filed in ipairs(list) do
        if memcmp(filed.at, addr, PICTURE_BYTES) == 0 then return filed.id end
    end
    return nil
end
-- A picture just read, filed for picture_known under its signature.
local function picture_file(sig, addr, pitch, id)
    local memmove = dfhack.internal.memmove
    if not memmove or not dfhack.internal.memcmp or not addr or pitch ~= CELL_PX then return end
    local list = stone_tint_pictures[sig]
    if not list then list = {} stone_tint_pictures[sig] = list end
    local buf = df.new('uint32_t', CELL_PX * CELL_PX)
    local _, at = df.sizeof(buf)
    memmove(at, addr, PICTURE_BYTES)
    list[#list + 1] = {buf = buf, at = at, id = id}
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
    elseif not can_work() then
        -- (PICTURES BY MEMCMP) a new number is looked at first, within THE
        -- FRAME'S WORK CAP only: it is read only if it is a picture never seen
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
    -- The same 16 pixels is the same picture, even if DF has moved it.
    if s and s.id and s.sig == sig then
        this_frame.checks, this_frame.check_s = this_frame.checks + 1, this_frame.check_s + clock() - t0
        s.round, s.addr = source_round, addr
        return s.id
    end
    -- PICTURES BY MEMCMP: a picture seen before under another number (or this
    -- number now showing another picture seen before)
    local known = picture_known(sig, addr, pitch)
    this_frame.checks, this_frame.check_s = this_frame.checks + 1, this_frame.check_s + clock() - t0
    if known then
        srcs.by_texpos[texpos] = {id=known, addr=addr, sig=sig, round=source_round}
        stone_tint_stats.known_again = (stone_tint_stats.known_again or 0) + 1
        return known
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
    picture_file(sig, addr, pitch, id)   -- (PICTURES BY MEMCMP)
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
    return tinted_entries(pal, strength, data.list, data.idx, nil, nil, data.mean), data.idx
end

-- A source's pixel list and 1024 indices: a picture read off DF, or for a
-- negative id our stored art. nil if it has none. For pictures laid over
-- another (FLOOR EDGES, THE OVERLAY IN THE RAMP).
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

-- ENGRAVED FLOORS BY THE MAP. The engravings filed again when their number
-- has changed (once a frame).
function engravings.list() return df.global.world.event.engravings end
function engravings.refresh()
    local ok, list = pcall(engravings.list)
    if not ok or not list then return end
    local n = #list
    if n == engravings.count then return end
    local by_level = {}
    for i = 0, n - 1 do
        local e = list[i]
        if e and e.flags.floor then
            local p = e.pos
            local lz = by_level[p.z]
            if not lz then lz = {} by_level[p.z] = lz end
            local lx = lz[p.x]
            if not lx then lx = {} lz[p.x] = lx end
            lx[p.y] = true
        end
    end
    engravings.count, engravings.by_level = n, by_level
end
-- Whether the floor at x, y, z is engraved.
function engravings.at(x, y, z)
    local lz = engravings.by_level[z]
    local lx = lz and lz[x]
    return lx and lx[y] or false
end
-- Whether texpos shows vanilla's engraving: true, false, or nil while its
-- picture waits for a read. Its hash is read_source's, worked out once over
-- our stored copy's pixels.
function engravings.vanilla(texpos)
    local h = engravings.vanilla_hash
    if h == nil then
        h = false
        local idx = decode('engraved_floor')
        if idx then
            h = 0
            for n = 0, CELL_PX * CELL_PX - 1 do
                local e = art.PIXELS[idx[n + 1]]
                if e[4] > 0 then
                    h = (h * 31 + ((e[4] << 24) | (e[3] << 16) | (e[2] << 8) | e[1]) + n) % 9007199254740881
                end
            end
        end
        engravings.vanilla_hash = h
    end
    if not h then return false end
    local sid = source_for(texpos)
    if sid == nil then return nil end
    local data = sid and stone_tint_sources.data[sid] or nil
    return data ~= nil and data.hash == h
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
-- DF'S OWN PIECES AND OVERLAYS
-- ==========================================
-- DF draws two things from its tables of token textures rather than from a
-- picture layer, so they cannot be read off the screen:
--   * a floor's edge pieces, over the cell beside it (FLOOR EDGES). DF's
--     renderer (g_src renderer_2d.hpp, update_viewport_tile, read 2026-11-21)
--     draws edging 9 (EDGING_STONE) on a side from gps.stone_floor_texpos[0]
--     and edging 2 (EDGING_SOIL) from dirt_floor_texpos[0], at the side's
--     piece (S 2, W 6, E 4, N 8; the corners SE 1, SW 3, NE 7, NW 9): the
--     STONE_FLOOR_1 to 9 and DIRT_FLOOR_1 to 9 tokens, the same pieces
--     whichever floor drops them;
--   * a ramp's overlay (RAMP OVERLAYS).
-- Which pictures those tokens hold is read from the graphics raws, so no page
-- is named here and whichever graphics are installed are followed: every
-- graphics folder a tile page came from (tile_pagest.graphics_dir; its parent
-- when it holds no .txt file), in the order DF loaded them, every .txt file in
-- it, every [TILE_GRAPHICS:page:x:y:token] for those tokens, the page's texpos
-- at that cell (the page of that name from the same folder, else the last one
-- loaded). A token several graphics give takes the last one loaded, as DF
-- does, checked against DF's own tables: when that one's texture is in none of
-- them and an earlier one's is, the earlier one. Read when DF's textures move
-- (a map's load among them); each time the overlay widget updates, one token's
-- page cell is looked at again, and a change has them all read again.
local TEXTURE_TABLES = {}
for i = 1, 11 do TEXTURE_TABLES[i] = 'texture_indices' .. i end
local refresh_tokens
do
-- DF's walls byte for a ramp (screentexpos_ramp_flag bits 8 to 15) in its bit
-- order, the order a case is written in, and each diagonal's two sides.
local WALL_BITS = {'N', 'W', 'E', 'S', 'NW', 'NE', 'SW', 'SE'}
local CASE_ORDER = {'N', 'S', 'E', 'W', 'NW', 'NE', 'SW', 'SE'}
local SIDES_OF = {NW = {'N', 'W'}, NE = {'N', 'E'}, SW = {'S', 'W'}, SE = {'S', 'E'}}
-- A ramp's case from its walls, the rule build_stone_tint_art.py names a
-- ramp's cell by (read off vanilla's token names): the walls on its four
-- sides, and each diagonal wall whose two sides are both open; none is OTHER.
tokens.case_of_walls = {}
for walls = 0, 255 do
    local has, keep = {}, {}
    for i, name in ipairs(WALL_BITS) do
        if (walls >> (i - 1)) & 1 == 1 then has[name] = true end
    end
    for _, name in ipairs(CASE_ORDER) do
        local sides = SIDES_OF[name]
        if has[name] and not (sides and (has[sides[1]] or has[sides[2]])) then keep[#keep + 1] = name end
    end
    tokens.case_of_walls[walls] = #keep > 0 and table.concat(keep, ' ') or 'OTHER'
end
-- An overlay token's case (OVERLAY_RAMP_WITH_WALL_N_S_E_W: 'N S E W'), or nil.
local function overlay_case(token)
    if token == 'OVERLAY_RAMP_OTHER' then return 'OTHER' end
    local suffix = token:match('^OVERLAY_RAMP_WITH_WALL_(.+)$')
    if not suffix then return nil end
    local has, keep = {}, {}
    for part in suffix:gmatch('[^_]+') do has[part] = true end
    for _, name in ipairs(CASE_ORDER) do if has[name] then keep[#keep + 1] = name end end
    return #keep > 0 and table.concat(keep, ' ') or nil
end
-- The pieces' tokens: {'stone', n}, {'soil', n} and {'pebbles', n}.
local PIECE_TOKENS = {}
for n = 1, 9 do
    PIECE_TOKENS['STONE_FLOOR_' .. n] = {'stone', n}
    PIECE_TOKENS['DIRT_FLOOR_' .. n] = {'soil', n}
    PIECE_TOKENS['PEBBLES_FLOOR_' .. n] = {'pebbles', n}
end

-- A loaded page's texpos at cell x, y, or nil.
local function cell_texpos(page, x, y)
    if not page or not page.loaded or x >= page.page_dim_x or y >= page.page_dim_y then return nil end
    local i = y * page.page_dim_x + x
    if i >= #page.texpos then return nil end
    local t = page.texpos[i]
    return t > 0 and t or nil
end

-- Every definition of a wanted token in the graphics raws, in DF's load order:
-- defs[token] = {{t=texpos, page=, x=, y=}, ...}; and the folders and files read.
local function read_raws()
    local roots = {dfhack.filesystem.getBaseDir()}
    local ok_u, user = pcall(function() return dfhack.filesystem.getUserDir() end)
    if ok_u and type(user) == 'string' then roots[#roots + 1] = user end
    local appdata = os.getenv('APPDATA')
    if appdata then roots[#roots + 1] = appdata .. '/Bay 12 Games/Dwarf Fortress/' end
    roots[#roots + 1] = ''
    local function resolve_dir(p)
        for _, root in ipairs(roots) do
            local sep = (root == '' or root:match('[/\\]$')) and '' or '/'
            local cand = root .. sep .. p
            if dfhack.filesystem.isdir(cand) then return cand:gsub('\\', '/'):gsub('/+$', '') end
        end
    end
    local pages = df.global.texture.page
    local dirs, seen_dir, by_dir, by_name = {}, {}, {}, {}
    local function add_dir(d)
        if not d or d == '' then return end
        local key = d:gsub('\\', '/'):gsub('/+$', ''):lower()
        if not seen_dir[key] then seen_dir[key] = true dirs[#dirs + 1] = d end
    end
    -- Walk DF's actual object load order first (vanilla, then active mods in order).
    pcall(function()
        for _, p in ipairs(df.global.world.object_loader.object_load_order_src_dir) do
            if type(p) ~= 'string' then p = p.value end
            local base = resolve_dir(p)
            local g = base and (base .. '/graphics')
            if g and dfhack.filesystem.isdir(g) then add_dir(g) end
        end
    end)
    for pi = 0, #pages - 1 do
        local page = pages[pi]
        local ok, dir = pcall(function() return page.graphics_dir end)
        if ok and type(dir) == 'string' and dir ~= '' then
            local resolved = resolve_dir(dir) or dir
            if not by_dir[resolved] then by_dir[resolved] = {} end
            by_dir[resolved][page.token] = page
            add_dir(resolved)
        end
        by_name[page.token] = page
    end
    local defs, files = {}, 0
    for _, dir in ipairs(dirs) do
        local paths = {}
        for _, folder in ipairs({dir, dir .. '/..'}) do
            local ok, entries = pcall(dfhack.filesystem.listdir_recursive, folder, 4, false)
            for _, f in ipairs(ok and entries or {}) do
                if not f.isdir and f.path:lower():match('%.txt$') then
                    paths[#paths + 1] = folder .. '/' .. f.path:gsub('^[/\\]+', '')
                end
            end
            if #paths > 0 then break end
        end
        table.sort(paths)
        local dir_pages = by_dir[dir]
        for _, path in ipairs(paths) do
            local f = io.open(path, 'r')
            local text = ''
            if f then
                text = f:read('a') or ''
                f:close()
                files = files + 1
            end
            if text:find('_FLOOR_', 1, true) or text:find('OVERLAY_RAMP_', 1, true) then
                for pname, x, y, token in text:gmatch('%[TILE_GRAPHICS:([^:%]]+):(%d+):(%d+):([^:%]]+)') do
                    if PIECE_TOKENS[token] or overlay_case(token) then
                        x, y = tonumber(x), tonumber(y)
                        local t = cell_texpos((dir_pages and dir_pages[pname]) or by_name[pname], x, y)
                        if t then
                            local list = defs[token]
                            if not list then list = {} defs[token] = list end
                            list[#list + 1] = {t=t, page=pname, x=x, y=y}
                        end
                    end
                end
            end
        end
    end
    return defs, #dirs, files
end

-- Every value in DF's token tables: Detailed Weather's copies counted as their
-- originals too, and the entries stone-tint points elsewhere as the values it
-- keeps to put back.
local function table_values()
    local seen = {}
    local from = rawget(_G, 'detailed_weather_pointed_from')
    local gps = df.global.gps
    for _, name in ipairs(TEXTURE_TABLES) do
        local ok, arr = pcall(function() return gps[name] end)
        if ok and arr then
            for i = 0, #arr - 1 do
                local v = arr[i]
                seen[v] = true
                local o = from and from[v]
                if o then seen[o] = true end
            end
        end
    end
    for _, kept in ipairs({stone_tint_overlays, stone_tint_shades}) do
        for _, s in ipairs(kept and kept.slots or {}) do seen[s[3]] = true end
    end
    return seen
end

-- force: read them all again; otherwise only if the next token's page cell (one
-- a call, in turn) holds another texpos now. True when read.
local check_at = 0
refresh_tokens = function(force)
    if not force then
        local list = tokens.checks
        if #list == 0 then return false end
        check_at = check_at % #list + 1
        local c = list[check_at]
        if dfhack.screen.findGraphicsTile(c[1], c[2], c[3]) == c[4] then return false end
    end
    local ok, defs, dirs, files = pcall(read_raws)
    if not ok then defs, dirs, files = {}, 0, 0 end
    local values = next(defs) and table_values() or {}
    local stone, soil, pebbles, overlay, overlay_set, checks, found = {}, {}, {}, {}, {}, {}, 0
    for token, list in pairs(defs) do
        local pick = list[#list]
        if not values[pick.t] then
            for k = #list - 1, 1, -1 do
                if values[list[k].t] then pick = list[k] break end
            end
        end
        local piece = PIECE_TOKENS[token]
        if piece then
            (piece[1] == 'stone' and stone or piece[1] == 'soil' and soil or pebbles)[piece[2]] = pick.t
        else
            overlay[overlay_case(token)] = pick.t
            overlay_set[pick.t] = true
        end
        found = found + 1
        checks[#checks + 1] = {pick.page, pick.x, pick.y, dfhack.screen.findGraphicsTile(pick.page, pick.x, pick.y)}
    end
    tokens.stone, tokens.soil, tokens.pebbles, tokens.overlay, tokens.overlay_set =
        stone, soil, pebbles, overlay, overlay_set
    tokens.checks, tokens.dirs, tokens.files, tokens.found = checks, dirs, files, found
    -- the overlays hidden under the old textures are put back and hidden again under the
    -- new ones (update_ramp_overlays); the pieces and overlays drawn from the old go
    tokens.rehide = true
    edge.made, ramp.made = {}, {}
    -- (THE QUICK FRAMES) the pieces and overlays moved: a full frame follows
    tokens.gen = (tokens.gen or 0) + 1
    return true
end
end

-- ==========================================
-- RAMP OVERLAYS
-- ==========================================
-- DF draws a ramp overlay (its OVERLAY_RAMP_WITH_WALL_* and OVERLAY_RAMP_OTHER
-- tokens: vanilla's angled one, Dark Depths' dark one, Detailed Landscapes'
-- rounded one, whichever graphics fill them) over every ramp's picture, picked
-- by the same walls as the ramp. It is in no per-cell texpos layer, so it
-- cannot be changed cell by cell, and drawn over a tinted ramp in the graphics'
-- own colours it hid the tint: Detailed Landscapes' is fully opaque (measured
-- off ramps_overlay_lit_round.png 2026-11-13), and carries most of the rounded
-- hills' shape (ramps went square without it, seen in play 2026-11-15).
--
-- (v1.2) So stone-tint draws the overlay into each ramp's own picture, tinted
-- with the ramp (THE OVERLAY IN THE RAMP), and DF's is hidden: every token
-- table entry holding an overlay's texture, or Detailed Weather's copy of one,
-- points at one blank texture while ramps are tinted, and gets its old value
-- back otherwise. DF looks a token's texture up in those tables
-- (gps.texture_indices1 to 11) as it draws: Making Fuel's hide sprite writes
-- its ITEM_LIQUID entry there and globs follow it live. The overlays' textures
-- are DF's own, found by token (DF'S OWN PIECES AND OVERLAYS): until v1.1
-- vanilla's RAMP_OVERLAY and Dark Depths' DARK_RAMP_OVERLAY pages were hidden
-- by name, Detailed Landscapes' was left shown over the tint, and any other
-- graphics' left alone. Hiding is global, so every ramp stone-tint sees gets
-- its overlay drawn in: the ones it does not tint (grass, sand, constructed, a
-- switch off) as drawn, as DF would show them. "Ramp overlays" in the window:
-- Tinted (drawn in, the default), Hidden (drawn nowhere, as "Hide ramp
-- overlays" did) or As drawn (left to DF, over the tint). The shadows are
-- other tokens and are left alone.
--
-- The blank is a RESERVED texture: these entries hold raw texposes, not
-- handles, and the dynamic range gets wiped and renumbered. The entries and
-- their old values live in an environment global, so a console command
-- re-running this file cannot lose what is needed to put them back.
stone_tint_overlays = stone_tint_overlays or {hidden=false}

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

-- {table name, index, old value} for every token entry holding an overlay's
-- texture: DF's own (tokens.overlay_set), or Detailed Weather's copy of one
-- while one of its looks shows (detailed_weather_pointed_from, in both its
-- versions; only Detailed Weather writes its copies into these tables, so a
-- match is always one of its own). One pass over the tables, about 52,000
-- entries, so it runs only when the overlays are hidden, never per frame.
local function find_overlay_slots()
    local wanted = tokens.overlay_set
    local slots = {}
    if not next(wanted) then return slots end
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
    local want = art ~= nil and state.strength > 0 and state.ramps and state.overlays ~= 'shown'
    -- (DF'S OWN PIECES AND OVERLAYS read again: hidden again under the textures found now)
    if tokens.rehide then
        tokens.rehide = false
        if ov.hidden then show_ramp_overlays() end
    end
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
local function shaded_pixels(texpos, kind, flatten, flat_alpha)
    local px, pitch = surface(texpos)
    if not px then return nil end
    local out, sum, min_a, max_a = {}, 0, 255, 0
    for n = 0, CELL_PX * CELL_PX - 1 do
        local p = px[(n // CELL_PX) * pitch + n % CELL_PX]
        local a = p >> 24
        if a < min_a then min_a = a end
        if a > max_a then max_a = a end
        -- Black keeps the pixel's alpha: a << 24.
        if kind == 'fog' or (p & 0xFF) * 0.299 + ((p >> 8) & 0xFF) * 0.587
                + ((p >> 16) & 0xFF) * 0.114 < SHADE_MAX_LUMA then
            p = a << 24
        end
        out[n + 1] = p
        sum = sum + a
    end
    if kind == 'fog' and flatten and sum > 0 then
        -- Non-uniform ramp fog cells take the flat depth-1 fog's alpha instead of their
        -- own half-empty mean, so depth-1 ramps match the depth-1 floor beside them.
        local mean = (sum + 512) // 1024
        if min_a < max_a and flat_alpha and mean < flat_alpha then mean = flat_alpha end
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
    local flat_alpha = nil
    if rounded then
        local ok_f, t0 = pcall(function() return df.global.gps.texture_indices1[0] end)
        if ok_f and t0 and t0 > 0 then
            local px0, pitch0 = surface(t0)
            if px0 then
                local s0 = 0
                for n = 0, CELL_PX * CELL_PX - 1 do
                    s0 = s0 + (px0[(n // CELL_PX) * pitch0 + n % CELL_PX] >> 24)
                end
                local m0 = (s0 + 512) // 1024
                if m0 > 0 and m0 < 255 then flat_alpha = m0 end
            end
        end
    end
    local made, slots, probes, seen_tbl, black_set = {}, {}, {}, {}, {}
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
                        local px = shaded_pixels(v, kind, rounded, flat_alpha)
                        local t, handle
                        if px then t, handle = copy_texpos(px, true) end
                        if t then
                            copy = {texpos=t, handle=handle}
                            if kind == 'fog' then black_set[t] = true end
                        end
                        made[v] = copy
                    end
                    if copy then
                        arr[i] = copy.texpos
                        -- [5]: the texpos written here, to tell DF's own from ours
                        local slot = {name, i, v, copy, copy.texpos}
                        slots[#slots + 1] = slot
                        if not seen_tbl[name] then
                            seen_tbl[name] = true
                            probes[#probes + 1] = slot
                        end
                    end
                end
            end
        end
    end
    -- Marked applied even when nothing was found, so the tables are not
    -- searched again every frame; status reports the count. flat: whether
    -- ramp fog is filled flat, for the fog DF builds below (FOG BELOW).
    sh.slots, sh.probes, sh.applied, sh.flat, sh.flat_alpha, sh.black_set =
        slots, probes, true, rounded, flat_alpha, black_set
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
    sh.slots, sh.probes, sh.applied, sh.black_set = nil, nil, false, nil
end

-- Keep the shadows the way the settings ask, as update_ramp_overlays does the
-- overlays: one entry per touched table read each frame, and all pointed back
-- if DF rebuilt its tables or moved a copy.
local function refresh_shades()
    local gps = df.global.gps
    local black_set = {}
    for _, s in ipairs(stone_tint_shades.slots) do
        local copy = s[4]
        local t = dfhack.textures.getTexposByHandle(copy.handle)
        if t and t > 0 then copy.texpos = t end
        black_set[copy.texpos] = true
        pcall(function()
            local arr = gps[s[1]]
            local v = arr[s[2]]
            if v ~= s[5] then s[3] = v end   -- DF wrote its own again: the new one to put back
            arr[s[2]] = copy.texpos
            s[5] = copy.texpos
        end)
    end
    stone_tint_shades.black_set = black_set
    df.global.gps.force_full_display_count = 1
end
function update_shades()
    local sh = stone_tint_shades
    local want = state.black_shadows
    if sh.applied then
        if not want then
            remove_shades()
        elseif sh.probes and sh.probes[1] then
            local need_refresh = false
            for _, s in ipairs(sh.probes) do
                local ok, v = pcall(function() return df.global.gps[s[1]][s[2]] end)
                local t = dfhack.textures.getTexposByHandle(s[4].handle)
                if not ok then
                    sh.slots, sh.probes, sh.applied = nil, nil, false
                    need_refresh = false
                    break
                elseif v ~= s[5] or (t and t > 0 and t ~= s[5]) then
                    need_refresh = true
                    break
                end
            end
            if need_refresh then refresh_shades() end
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
-- (1.3.6) 4 again, from the 24 of 1.3.4. These reads are made in paint_fog,
-- before THE FRAME'S WORK CAP starts, so only this count bounds them: each new
-- texture in the fog layer is a 1024-pixel read and usually a texture made.
local FOG_READS_PER_FRAME = 4
local fog_copies = {}             -- texpos -> {copy=texpos or false, addr=, sig=, round=}
local fog_reads = 0

-- A fog texture's black copy, packed for createTile, or nil when it is not
-- fog (a visible pixel not vanilla's fog blue).
local function black_fog_pixels(px, pitch, flatten, flat_alpha)
    local out, sum, any, min_a, max_a = {}, 0, false, 255, 0
    for n = 0, CELL_PX * CELL_PX - 1 do
        local p = px[(n // CELL_PX) * pitch + n % CELL_PX]
        local a = p >> 24
        if a < min_a then min_a = a end
        if a > max_a then max_a = a end
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
        if min_a < max_a and flat_alpha and mean < flat_alpha then mean = flat_alpha end
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
    -- (THE FOG KEPT) a copy used unchecked this round is counted, so the
    -- layer is walked again next frame until the round is through.
    if fog_reads <= 0 then
        if c then rp.fog.skipped = rp.fog.skipped + 1 end
        return c and c.copy or nil
    end
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
    local black = black_fog_pixels(px, pitch, stone_tint_shades.flat, stone_tint_shades.flat_alpha)
    if black then
        copy = copy_texpos(black, false)
        if not copy then return nil end
        if stone_tint_shades.black_set then stone_tint_shades.black_set[copy] = true end
    end
    fog_copies[t] = {copy=copy, addr=addr, sig=sig, round=source_round}
    return copy
end

-- Reusable zero buffer + viewport pointer helper for C++ diffscan zero-skipping.
local scan = {buf = nil, size = 0}
function scan.zeros(n)
    if scan.size < n then
        if scan.buf then df.delete(scan.buf) end
        local buf = df.new('int32_t', n)
        for k = 0, n - 1 do buf[k] = 0 end
        scan.buf, scan.size = buf, n
    end
    return scan.buf
end
function scan.addr(vp, field)
    local _, at = df.sizeof(vp:_field(field))
    return at and df.reinterpret_cast('uint64_t', at).value or nil
end
function scan.base(vp, field)
    local ok, addr = pcall(scan.addr, vp, field)
    return (ok and addr and addr ~= 0) and addr or nil
end

-- Each frame: the fog layer of the levels below, made black.
--
-- THE FOG KEPT (1.3.6). This layer holds DF's own drawing of the levels'
-- haze, and nothing changes it between frames while the view stands still
-- (Detailed Weather draws its weather fog in the main view's layer, not this
-- one). So once a frame has given every cell its black copy, the layer as DF
-- drew it (raw) and as it was left (out) are kept, and the next frame
-- compares DF's new drawing with raw in C (diffscan), works out only the cells
-- that differ, and writes the whole layer back in one move (memmove). The
-- walk of every cell, 1.6 to 1.7 ms a frame on an 8,000-cell view in play
-- (`stone-tint status`, 2026-11-26), comes back only when something it rests
-- on moved: DF's textures (the sentinel), the black copies (black_set), the
-- copies kept (fog_copies), a round of checks (source_round), the view's size,
-- or more than FOG_DIFF_MOST cells differing at once. A cell whose copy waits
-- for a read is kept as -1 in raw, which DF never draws, so it differs next
-- frame and is tried again. Until 1.3.6 a frame whose copies had all come
-- after one that waited also made DF redraw the whole screen
-- (force_full_display_count); DF's own comparison of each cell already
-- redraws a cell whose value changed, so that is gone.
local FOG_DIFF_MOST = 256

local function paint_fog()
    local F = rp.fog
    if not state.black_shadows or not stone_tint_shades.applied then F.valid = false return end
    local lvp = df.global.gps.lower_viewport[0]
    if not lvp or not lvp.flag.active then F.valid = false return end
    local total = lvp.dim_x * lvp.dim_y
    if total <= 0 then F.valid = false return end
    fog_reads = FOG_READS_PER_FRAME
    local layer = lvp.screentexpos_interface
    local black_set = stone_tint_shades.black_set
    local fc, sr = fog_copies, source_round
    local diffscan, memmove = dfhack.internal.diffscan, dfhack.internal.memmove
    local base = diffscan and scan.base(lvp, 'screentexpos_interface') or nil
    -- What a cell showing DF's texture t is given (its black copy, or t itself:
    -- empty, already black, not fog, or no copy yet) and whether its copy
    -- waits for a read.
    local function give(t)
        if t == 0 or (black_set and black_set[t]) then return t, false end
        local c = fc[t]
        local copy
        if c and c.round == sr then copy = c.copy else copy = fog_copy(t) end
        if copy then return copy, false end
        return t, copy == nil
    end
    local keep = base ~= nil and memmove ~= nil and rp.on
    if keep and F.cap ~= total then
        if F.raw then df.delete(F.raw) df.delete(F.out) end
        F.raw, F.out = df.new('int32_t', total), df.new('int32_t', total)
        local _, ra = df.sizeof(F.raw)
        local _, oa = df.sizeof(F.out)
        F.raw_addr, F.out_addr, F.cap, F.valid = ra, oa, total, false
    end
    if keep and F.valid and F.sentinel == tint_sentinel and F.black == black_set
            and F.copies == fc and F.round == sr then
        local raw, out = F.raw, F.out
        local pos, n, skipped0 = 0, 0, F.skipped
        while pos < total do
            local hit = diffscan(raw, base, pos, total, 4)
            if not hit then break end
            n = n + 1
            if n > FOG_DIFF_MOST then break end
            local t = layer[hit]
            local o, waits = give(t)
            raw[hit] = waits and -1 or t
            out[hit] = o
            pos = hit + 1
        end
        if n <= FOG_DIFF_MOST then
            memmove(base, F.out_addr, total * 4)
            -- (a copy given unchecked this round: the next frame walks whole)
            if F.skipped ~= skipped0 then F.valid = false end
            F.kept = F.kept + 1
            return
        end
    end
    -- THE WHOLE WALK: DF's drawing kept first (raw), every cell given its copy,
    -- then the layer as left (out).
    F.skipped = 0
    if keep then memmove(F.raw_addr, base, total * 4) end
    local zeros = base and scan.zeros(total) or nil
    local i = 0
    while i < total do
        local t = layer[i]
        if t == 0 then
            if zeros then
                if i + 1 >= total then break end
                i = diffscan(zeros, base, i + 1, total, 4)
                if not i then break end
                t = layer[i]
            else
                t = nil
            end
        end
        if t then
            local o, waits = give(t)
            if o ~= t then layer[i] = o end
            if waits and keep then F.raw[i] = -1 end
        end
        i = i + 1
    end
    F.walked = F.walked + 1
    if keep then
        memmove(F.out_addr, base, total * 4)
        -- Kept for the next frames only once every copy on screen has been
        -- checked this round (F.skipped counts those used unchecked).
        F.valid = F.skipped == 0
        F.sentinel, F.black, F.copies, F.round = tint_sentinel, black_set, fc, sr
    end
end

-- ==========================================
-- WHAT A TILE IS
-- ==========================================
-- What a tile is to stone-tint, read off the map (TILES BY THE MAP): an art id
-- for a revealed natural floor (or a boulder's tile), stair or ramp of stone,
-- or of soil that is not sand; ENGRAVED for a natural stone floor with an
-- engraving on it; RAMP_OTHER for any other ramp (it gets its overlay: RAMP
-- OVERLAYS); false for anything else. The second value is true when no picture
-- DF draws on a tile like this one is ever ours: a wall, a fortification, open
-- space, a ramp's top, or grass (but for a grass ramp), which DF draws in
-- pictures of its own. A tile
-- under a shrub, a sapling or a construction is only false: the picture there
-- may be a floor's that is ours elsewhere. flag is the tile's
-- screentexpos_ramp_flag, which picks a ramp's cell. Map reads, so the render
-- loop calls it only for a tile whose picture changed, never per cell per
-- frame.
local tile_kind
do
local S = df.tiletype_shape
local FLOOR_LIKE = {[S.FLOOR] = true, [S.BOULDER] = true, [S.PEBBLES] = true}
local NEVER_SHAPES = {[S.WALL] = true, [S.FORTIFICATION] = true, [S.EMPTY] = true, [S.RAMP_TOP] = true}
local NEVER_MATERIALS = {}
for _, name in ipairs({'GRASS_LIGHT', 'GRASS_DARK', 'GRASS_DRY', 'GRASS_DEAD'}) do
    local m = df.tiletype_material[name]
    if m then NEVER_MATERIALS[m] = true end
end
local RAMP, SMOOTH, M_TREE = S.RAMP, df.tiletype_special.SMOOTH, df.tiletype_material.TREE
tile_kind = function(x, y, z, flag)
    local b = fast.block(x, y, z)
    if not b then return false, false end
    local idx = (x & 15) * 16 + (y & 15)
    local material, tshape, special = tile_attrs(b.tt[idx])
    -- (a grass ramp still gets its overlay: RAMP_OTHER, below)
    if NEVER_SHAPES[tshape] or (NEVER_MATERIALS[material] and tshape ~= RAMP) then
        return false, material ~= M_TREE and (tshape == S.WALL or NEVER_MATERIALS[material] ~= nil)
    end
    local stair = STAIR_SHAPES[tshape]
    if not (stair or tshape == RAMP or FLOOR_LIKE[tshape]) then return false, false end
    if (b.des[idx] & fast.m_hidden) ~= 0 then return false, false end
    local family = STONE_MATERIALS[material] and 'stone' or (material == MAT_SOIL and 'soil') or nil
    if family == 'soil' and is_sand(x, y, z) then family = nil end
    if not family then return tshape == RAMP and RAMP_OTHER or false, false end
    if stair then return STAIR_ART[family][stair], false end
    if tshape == RAMP then
        local bits = flag and math.tointeger(flag)
        local cell = bits and art and art.RAMP_CELL[(bits >> 8) & 0xFF]
        return (cell and RAMP_ART[family][cell]) or RAMP_OTHER, false
    end
    if family == 'stone' and special == SMOOTH then
        return engravings.at(x, y, z) and ENGRAVED or KIND_ART.smooth, false
    end
    return family == 'stone' and KIND_ART.rough_stone or KIND_ART.rough_soil, false
end
end

-- Whether a tile is subterranean (Detailed Weather's test for underground).
local function is_subterranean(x, y, z)
    local b = fast.block(x, y, z)
    if b then return (b.des[(x & 15) * 16 + (y & 15)] & fast.m_sub) ~= 0 end
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
    for _, k in ipairs({'rough', 'smooth', 'stairs', 'ramps', 'soil', 'black_shadows', 'engraved', 'faces'}) do
        if saved[k] ~= nil then state[k] = saved[k] end
    end
    -- (v1.2) "Ramp overlays", in place of "Hide ramp overlays": a save from before
    -- v1.2 has none, and takes the default (hidden).
    if OVERLAY_MODES[saved.overlays] then state.overlays = saved.overlays end
    if edge.modes[saved.edges] then state.edges = saved.edges end
end

local function save_state()
    if dfhack.isMapLoaded() then dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
end

-- Forget every texture filed (known_texpos), and Detailed Weather's answers.
local function reset_known()
    known_texpos = {}
    dw_memo = {filed = {}, live = {}, active = dw_memo.active}
end

local function reset_cache(z)
    cached_z = z
    color_cache = {}
    tile_checks = {}
    edge.sources = {}
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
    for lz in pairs(edge.sources) do
        if math.abs(lz - z) > KEEP_LEVELS then edge.sources[lz] = nil end
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
    refresh_map_bounds()
    reset_cache(nil)
end

-- Per-frame values paint_cell reads, set at the top of each frame.
-- frame_overlays: whether ramps get their overlays laid in this frame (THE
-- OVERLAY IN THE RAMP).
local frame_strength, frame_budget, frame_overlays = 0, 0, false

-- ==========================================
-- THE OVERLAY IN THE RAMP
-- ==========================================
-- While DF's overlays are hidden and "Ramp overlays" is Tinted, each ramp cell
-- gets one texture: its picture with the overlay DF would draw over it laid
-- in, the overlay of its walls' case (tokens.case_of_walls, from the tile's
-- screentexpos_ramp_flag; none where DF shows its down arrow instead,
-- VIEWPORT_RAMP_FLAG_SHOW_DOWN_ARROW). On a tinted ramp both are tinted with
-- the ramp's colour, the overlay moved by the ramp's own shift (keep), as a
-- floor's edge pieces are by their floor's, so the two match; any other
-- ramp's are laid together as drawn. The overlay goes over the picture by its
-- alpha. Kept by both pictures and the colour, made within the frame's
-- texture budget.
do
local SHOW_DOWN_ARROW = 1 << 25

-- A source's pixel entries packed for createTileset, as drawn.
local function drawn_entries(list)
    local out = {}
    for i, e in ipairs(list) do
        out[i] = e[4] == 0 and 0 or ((e[4] << 24) | (e[3] << 16) | (e[2] << 8) | e[1])
    end
    return out
end

-- Packed pixel `over` laid on `under` by its alpha (straight alpha, as DF's
-- surfaces hold it).
local function over_pixel(under, over)
    local oa = over >> 24
    if oa == 255 then return over end
    if oa == 0 then return under end
    local ua = under >> 24
    if ua == 0 then return over end
    local f = ua * (255 - oa) / 255          -- the share of the pixel under that shows
    local a = oa + f
    local function ch(s)
        return math.floor((((over >> s) & 0xFF) * oa + ((under >> s) & 0xFF) * f) / a + 0.5)
    end
    return (math.floor(a + 0.5) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0)
end
ramp.over_pixel = over_pixel

-- Ramp picture sid with overlay ov laid in: composited as drawn first, then
-- tinted as one picture so monochrome shadow/highlight overlays darken and
-- brighten naturally instead of shifting into a flat single colour.
local function laid_pixels(sid, ov, code, strength)
    local list, idx = source_data(sid)
    local olist, oidx = source_data(ov)
    if not list or not olist then return nil end
    local under, over = drawn_entries(list), drawn_entries(olist)
    local out = {}
    for j = 1, CELL_PX * CELL_PX do out[j] = over_pixel(under[idx[j]], over[oidx[j]]) end
    if not code then return out end
    local pal = palette_of(code - 1)
    if not pal then return nil end
    local clist, cidx, seen = {{0, 0, 0, 0, 0}}, {}, {}
    for j = 1, CELL_PX * CELL_PX do
        local packed = out[j]
        local i = 1
        if packed >> 24 > 0 then
            i = seen[packed]
            if not i then
                local r, g, b = packed & 0xFF, (packed >> 8) & 0xFF, (packed >> 16) & 0xFF
                clist[#clist + 1] = {r, g, b, packed >> 24, key_of(r, g, b)}
                i = #clist
                seen[packed] = i
            end
        end
        cidx[j] = i
    end
    local entries = tinted_entries(pal, strength, clist, cidx)
    for j = 1, CELL_PX * CELL_PX do out[j] = entries[cidx[j]] end
    return out
end

-- The overlay's source for a ramp cell's flag: an id, false (none: no case, no
-- token found, the down arrow, or a picture that cannot be read) or nil (not
-- read yet). Under a Detailed Weather look, its copy of the overlay: what DF
-- draws.
function ramp.overlay(flag)
    local bits = flag and math.tointeger(flag) or 0
    if bits & SHOW_DOWN_ARROW ~= 0 then return false end
    local t = tokens.overlay[tokens.case_of_walls[(bits >> 8) & 0xFF]]
    if not t then return false end
    return source_for(dw_shown(t))
end

-- The texpos of ramp picture sid with overlay ov laid in, tinted with `code` at
-- the frame's strength (code nil: as drawn). texpos, false (cannot be made) or
-- nil (not this frame).
function ramp.texpos(sid, ov, code)
    -- (looked up every frame for every ramp on screen: tables, no key made)
    local by_sid = ramp.made[sid]
    if not by_sid then by_sid = {} ramp.made[sid] = by_sid end
    local by_ov = by_sid[ov]
    if not by_ov then by_ov = {} by_sid[ov] = by_ov end
    local t = by_ov[code or 0]
    if t ~= nil then return t end
    -- The handles live with the floors' textures, one store per style and
    -- strength (one for ramps left as drawn), so a console re-run keeps them.
    local key = sid .. ':' .. ov .. ':' .. (code or 0)
    local stores = stone_tint_textures.ramps
    if not stores then stores = {} stone_tint_textures.ramps = stores end
    local skey = code and (state.style .. frame_strength) or 'drawn'
    local store = stores[skey]
    if not store then store = {} stores[skey] = store end
    local handle = store[key]
    if handle == nil then
        if frame_budget <= 0 or not can_work() then return nil end
        frame_budget = frame_budget - 1
        local t0 = clock()
        local px = laid_pixels(sid, ov, code, frame_strength)
        handle = false
        if px then
            local ok, handles = pcall(dfhack.textures.createTileset, px, CELL_PX, CELL_PX,
                CELL_PX, CELL_PX)
            handle = ok and handles and handles[1] or false
        end
        this_frame.made, this_frame.made_s = this_frame.made + 1, this_frame.made_s + clock() - t0
        store[key] = handle
        if handle then stone_tint_stats.textures = stone_tint_stats.textures + 1 end
    end
    if not handle then
        by_ov[code or 0] = false
        return false
    end
    t = dfhack.textures.getTexposByHandle(handle)
    -- 0 means DFHack is holding the texture until DF finishes loading.
    if t and t > 0 then
        by_ov[code or 0] = t
        return t
    end
    return nil
end

-- A ramp stone-tint does not tint, while it draws the overlays in: its picture
-- as drawn with its overlay laid in. Left as DF drew it (without its overlay)
-- while either picture waits for a read or cannot be read.
function ramp.plain(bg, flags, index, drawn)
    if not frame_overlays then return nil end
    -- (THE QUICK FRAMES: this_frame.pend wherever nil means "not yet")
    local ov = ramp.overlay(flags[index])
    if not ov then
        if ov == nil then this_frame.pend = true end
        return nil
    end
    local sid = source_for(drawn)
    if not sid then
        if sid == nil then this_frame.pend = true end
        return nil
    end
    local t = ramp.texpos(sid, ov, nil)
    if t then
        bg[index] = t
        ramp.laid = ramp.laid + 1
    elseif t == nil then
        this_frame.pend = true
    end
    return nil
end
end

-- One cell DF drew with a texture that may be ours (its known_texpos entry is
-- not false): works out what its tile is (WHAT A TILE IS) and writes the tinted
-- texture over DF's. bg and flags are the arrays of the viewport the cell is
-- in, z its level, colours and checks that level's caches. Returns the kind of
-- tile it tinted, for the counts, or nil. One function for the level you are
-- on and the levels below, so both tint the same way. Every map read and
-- material lookup in here waits for a later frame once this frame's work is
-- spent (THE FRAME'S WORK CAP), and the cell keeps DF's own picture until then.
local function paint_cell(bg, flags, index, drawn, wx, wy, z, colours, checks)
    -- What this tile is, read off the map once and kept against the picture DF
    -- drew there: under a Detailed Weather look, its copy's original, so the
    -- next look's copy of the same picture reads nothing again (every floor on
    -- screen did at each change of weather). A texture's first sight since the
    -- last reset also files it: never looked at again when no picture on a
    -- tile like this one is ours.
    local original
    if dw_memo.active then
        original = dw_memo.filed[drawn]
        if original == nil then original = dw_original(drawn) end
        if not original then original = nil end
    end
    local key = original or drawn
    local ccol = checks[wx]
    if not ccol then ccol = {} checks[wx] = ccol end
    local check = ccol[wy]
    if not check or check.texpos ~= key then
        if not can_work() then this_frame.waited = this_frame.waited + 1 this_frame.pend = true return nil end
        local t0 = clock()
        local id, never = tile_kind(wx, wy, z, flags[index])
        check = {texpos=key, id=id, never=never}
        ccol[wy] = check
        this_frame.maps, this_frame.map_s = this_frame.maps + 1, this_frame.map_s + clock() - t0
    end
    if known_texpos[drawn] == nil then known_texpos[drawn] = not check.never end
    local id = check.id
    if not id then return nil end
    if id == RAMP_OTHER then return ramp.plain(bg, flags, index, drawn) end
    -- An engraved floor counts and switches as one; its picture is picked below.
    local engraved = id == ENGRAVED
    if engraved then id = ENGRAVED_FACE end
    local kind = ART_KIND[id]
    if not group_enabled[ART_GROUP[id]] then
        if kind == K_RAMP then return ramp.plain(bg, flags, index, drawn) end
        return nil
    end
    local col = colours[wx]
    if not col then col = {} colours[wx] = col end
    local code = col[wy]
    if not code then
        if not can_work() then this_frame.waited = this_frame.waited + 1 this_frame.pend = true return nil end
        local t0 = clock()
        code = lookup_colour(wx, wy, z)
        col[wy] = code
        this_frame.colours, this_frame.colour_s = this_frame.colours + 1, this_frame.colour_s + clock() - t0
    end
    if code == 0 then
        if kind == K_RAMP then return ramp.plain(bg, flags, index, drawn) end
        return nil
    end
    -- Which picture to tint (THE ART AS DRAWN): the one DF drew; under one of
    -- Detailed Weather's copies on a subterranean tile, the copy's original
    -- (DETAILED WEATHER), read once per tile and kept with what the tile is.
    local src = drawn
    if original then
        if check.under == nil then
            if not can_work() then this_frame.waited = this_frame.waited + 1 this_frame.pend = true return nil end
            local t0 = clock()
            check.under = is_subterranean(wx, wy, z)
            this_frame.maps, this_frame.map_s = this_frame.maps + 1, this_frame.map_s + clock() - t0
        end
        if check.under then src = original end
    end
    local sid = source_for(src)
    if sid == nil then this_frame.pend = true return nil end   -- not read yet: DF's own picture this frame
    if engraved then
        -- Engraving faces off, and DF's picture vanilla's engraving: our copy
        -- without the face. Any other engraving as drawn.
        if not state.faces then
            local vanilla = engravings.vanilla(original or drawn)
            if vanilla == nil then this_frame.pend = true return nil end
            if vanilla then sid = -ENGRAVED_PLAIN end
        end
        if not sid then sid = state.faces and -ENGRAVED_FACE or -ENGRAVED_PLAIN end
    elseif not sid then
        sid = -id                          -- cannot be read: the stored art
    end
    local texpos
    if kind == K_RAMP and frame_overlays then
        -- THE OVERLAY IN THE RAMP: its overlay laid in and tinted with it. Until
        -- both are ready, the ramp alone, tinted.
        local ov = ramp.overlay(flags[index])
        if ov then
            texpos = ramp.texpos(sid, ov, code)
            if texpos then ramp.laid = ramp.laid + 1
            elseif texpos == nil then this_frame.pend = true end   -- (the laid copy waits)
        elseif ov == nil then
            this_frame.pend = true                                 -- (its overlay not read yet)
        end
    end
    if not texpos then
        local per = tint_cache[sid]
        if not per then per = {} tint_cache[sid] = per end
        texpos = per[code]
        if texpos == nil then
            texpos, frame_budget = tint_texpos(sid, code, frame_strength, frame_budget)
            -- nil: not this frame, so not cached; asked again next frame
            if texpos ~= nil then per[code] = texpos end
            -- FLOOR EDGES: a floor's tinted texture is filed with its colour and
            -- picture, which the pieces it drops take, as it is made.
            if texpos and (kind == K_FLOOR or kind == K_ENGRAVED) then
                edge.info[texpos] = {code=code, sid=sid, under=check.under or false}
            end
        end
    end
    if not texpos then
        if texpos == nil then this_frame.pend = true end   -- (nil: not this frame; false: nothing to draw)
        return nil
    end
    bg[index] = texpos
    return kind
end

-- ==========================================
-- FLOOR EDGES
-- ==========================================
-- A floor's art is a 3x3 set: the floor itself in the middle (piece 5, or 5B
-- to 5D) and eight small pieces round it that hang over its edges into the
-- next cells (STONE_FLOOR_1 to 9, DIRT_FLOOR_1 to 9 for soil). Where a floor
-- meets open ground (a channel, a ramp's top, a cliff) DF draws those pieces
-- on the open cell in the art's own colours, so every tinted floor kept a grey
-- lip round a channel (seen in play 2026-11-15).
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
-- So on every cell with edging, each side with stone or soil edging (9, 2)
-- whose floor stone-tint tinted this frame gets the piece DF draws there (DF'S
-- OWN PIECES AND OVERLAYS: since v1.2 by token, the same pieces whichever
-- graphics fill them; until v1.1 from the floor's own page, by name), tinted as
-- the floor is (keep moves it by the floor's own shift), and each corner
-- between two sides carrying the same stone or soil edging, one of them ours,
-- gets that corner's piece in the diagonal floor's tint (a side's, when the
-- diagonal is not one of ours). Edging of any other kind (grass, sand,
-- pebbles) is left as DF draws it. Corners
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
(function()
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

-- The pieces by edging ID: DF's own (DF'S OWN PIECES AND OVERLAYS), and the
-- art id of our stored copy of piece 1 (for a picture that cannot be read).
local EDGINGS = {[9] = {'stone', 1}, [8] = {'pebbles', 1}, [2] = {'soil', FIRST_SOIL_FLOOR}}

-- Per-frame resolved edge piece sources and canonical piece-5 floor shift
-- sources, so add_piece never calls dw_shown/source_for per cell and keeps one
-- canonical shift per edging family instead of multiplying by every floor/pebble variant.
local surf_sid = {[9] = {}, [8] = {}, [2] = {}}
local under_sid = {[9] = {}, [8] = {}, [2] = {}}
local surf_fsid, under_fsid = {}, {}
local resolved_frame = -1
local stored_mean, stored_opaque = {}, {}

local function resolve_edge_pieces()
    resolved_frame = frame_id
    local dw_on = dw_memo.active
    local pending = false
    for _, id in ipairs({9, 8, 2}) do
        local e = EDGINGS[id]
        local tk, base = tokens[e[1]], e[2]
        local ss, us = surf_sid[id], under_sid[id]
        for p = 1, 9 do
            local t = tk[p]
            if t then
                local sid = source_for(dw_on and dw_shown(t) or t)
                if sid == nil then pending = true end
                ss[p] = sid == nil and nil or (sid or -(base + p - 1))
                if dw_on then
                    local usid = source_for(t)
                    if usid == nil then pending = true end
                    us[p] = usid == nil and nil or (usid or -(base + p - 1))
                else
                    us[p] = ss[p]
                end
            else
                ss[p], us[p] = nil, nil
            end
        end
        -- (1.3.7) The floor piece's own picture shifts every piece of its set
        -- (keep's mean). While that picture waits for its read, its entry is nil
        -- and add_piece waits with it. Until 1.3.7 `tk[5] and ss[5] or ...`
        -- took the wait for "no picture" and gave the stored art's shift, and
        -- every stack made then kept it for the session (stack_texpos keys a
        -- stack by its pieces, not this shift): floor edges a shade off their
        -- floor whenever the edges were drawn before piece 5 was read (found
        -- offline 2026-11-26: a run with the reads unlimited and one without
        -- settled to different edge colours, frame after frame).
        if tk[5] then
            surf_fsid[id], under_fsid[id] = ss[5], us[5]
        else
            surf_fsid[id], under_fsid[id] = -(base + 4), -(base + 4)
        end
    end
    -- (THE QUICK FRAMES) a piece whose picture still waits for its read: the
    -- edges drawn this frame are not whole, so they are not kept (paint_edges)
    edge.pend_pieces = pending
end

local function source_mean(sid)
    if sid > 0 then
        local d = stone_tint_sources.data[sid]
        if not d then return nil end
        if not d.mean then
            local sr, sg, sb, n = 0, 0, 0, 0
            local list, idx = d.list, d.idx
            for i = 1, #idx do
                local e = list[idx[i]]
                if e[4] > 0 then sr, sg, sb, n = sr + e[1], sg + e[2], sb + e[3], n + 1 end
            end
            if n == 0 then n = 1 end
            d.mean = {sr / n, sg / n, sb / n}
        end
        return d.mean
    end
    local m = stored_mean[-sid]
    if m then return m end
    local list, idx = source_data(sid)
    if not list then return nil end
    local sr, sg, sb, n = 0, 0, 0, 0
    for i = 1, #idx do
        local e = list[idx[i]]
        if e[4] > 0 then sr, sg, sb, n = sr + e[1], sg + e[2], sb + e[3], n + 1 end
    end
    if n == 0 then n = 1 end
    m = {sr / n, sg / n, sb / n}
    stored_mean[-sid] = m
    return m
end

local function source_opaque(sid)
    if sid > 0 then
        local d = stone_tint_sources.data[sid]
        if not d then return nil end
        if not d.opaque then
            local op, on = {}, 0
            local list, idx = d.list, d.idx
            for j = 1, #idx do
                local i = idx[j]
                if list[i][4] > 0 then
                    on = on + 2
                    op[on - 1], op[on] = j, i
                end
            end
            d.opaque = op
        end
        return d.opaque
    end
    local op = stored_opaque[-sid]
    if op then return op end
    local list, idx = source_data(sid)
    if not list then return nil end
    op = {}
    local on = 0
    for j = 1, #idx do
        local i = idx[j]
        if list[i][4] > 0 then
            on = on + 2
            op[on - 1], op[on] = j, i
        end
    end
    stored_opaque[-sid] = op
    return op
end

local function floor_pixels(sid, code, strength)
    local by_sid = edge.floor_px[sid]
    if not by_sid then by_sid = {} edge.floor_px[sid] = by_sid end
    local px = by_sid[code]
    if px then return px end
    local list, idx = source_data(sid)
    local pal = palette_of(code - 1)
    if not list or not pal then return nil end
    local mrgb = state.style == 'keep' and source_mean(sid) or nil
    local entries = tinted_entries(pal, strength, list, idx, nil, nil, mrgb)
    px = {}
    for j = 1, CELL_PX * CELL_PX do px[j] = entries[idx[j]] end
    by_sid[code] = px
    return px
end

local function piece_pixels(sid, code, fsid, strength)
    local by_sid = edge.piece_px[sid]
    if not by_sid then by_sid = {} edge.piece_px[sid] = by_sid end
    local px = by_sid[code]
    if px then return px end
    local list, idx = source_data(sid)
    local pal = palette_of(code - 1)
    if not list or not pal then return nil end
    local mrgb = state.style == 'keep' and source_mean(fsid) or nil
    local entries = tinted_entries(pal, strength, list, idx, nil, nil, mrgb)
    local op = source_opaque(sid)
    if not op then return nil end
    px = {}
    local k = 0
    for m = 1, #op, 2 do
        k = k + 2
        px[k - 1] = op[m]
        px[k] = entries[op[m + 1]]
    end
    by_sid[code] = px
    return px
end

-- Puts piece `piece` of edging `id`'s set on top of the stack of n, tinted as
-- floor f using its edging family's canonical shift.
local function add_piece(n, f, id, piece)
    local sid = (f.under and under_sid or surf_sid)[id][piece]
    local fsid = (f.under and under_fsid or surf_fsid)[id]
    if not sid or not fsid then return nil end
    n = n + 1
    p_sid[n], p_code[n], p_fsid[n] = sid, f.code, fsid
    return n
end

-- The stack as one texture's pixels: copies pre-tinted floor pixels (if baked)
-- and stamps only the pre-tinted opaque pixels of each edge piece and spatter.
local function stack_texture(n, strength, floor_info, sp_sid)
    local out = {}
    local blend = ramp.over_pixel
    if floor_info then
        local fpx = floor_pixels(floor_info.sid, floor_info.code, strength)
        if not fpx then return false end
        for j = 1, CELL_PX * CELL_PX do out[j] = fpx[j] end
    else
        for j = 1, CELL_PX * CELL_PX do out[j] = 0 end
    end
    for i = 1, n do
        local ppx = piece_pixels(p_sid[i], p_code[i], p_fsid[i], strength)
        if not ppx then return false end
        for m = 1, #ppx, 2 do
            local j, v = ppx[m], ppx[m + 1]
            if (v >> 24) == 255 then out[j] = v else out[j] = blend(out[j], v) end
        end
    end
    if sp_sid then
        local slist = source_data(sp_sid)
        local sop = source_opaque(sp_sid)
        if not slist or not sop then return false end
        for m = 1, #sop, 2 do
            local j = sop[m]
            local e = slist[sop[m + 1]]
            out[j] = blend(out[j], (e[4] << 24) | (e[3] << 16) | (e[2] << 8) | e[1])
        end
    end
    local ok, handles = pcall(dfhack.textures.createTileset, out, CELL_PX, CELL_PX,
        CELL_PX, CELL_PX)
    if ok and handles and handles[1] then return handles[1] end
    return false
end

-- Zero-allocation trie lookup for the stack of n (with optional floor_info
-- underneath or sp_sid on top); only builds a string key on a cache miss.
local function stack_texpos(n, floor_info, sp_sid)
    local node = edge.made
    local fk = floor_info and (floor_info.sid * 65536 + floor_info.code) or 0
    local nxt = node[fk]
    if not nxt then nxt = {} node[fk] = nxt end
    node = nxt
    for i = 1, n do
        local pk = p_sid[i] * 65536 + p_code[i]
        nxt = node[pk]
        if not nxt then nxt = {} node[pk] = nxt end
        node = nxt
    end
    if sp_sid then
        local sp = node.sp
        if not sp then sp = {} node.sp = sp end
        nxt = sp[sp_sid]
        if not nxt then nxt = {} sp[sp_sid] = nxt end
        node = nxt
    end
    local texpos = node.t
    if texpos ~= nil then return texpos end
    for i = 1, n do
        parts[i] = p_sid[i] .. ':' .. p_code[i]
    end
    local key = table.concat(parts, ' ', 1, n)
    if floor_info then key = 'f' .. floor_info.sid .. ':' .. floor_info.code .. ' ' .. key end
    if sp_sid then key = key .. ' s' .. sp_sid end
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
        handle = stack_texture(n, frame_strength, floor_info, sp_sid)
        this_frame.made, this_frame.made_s = this_frame.made + 1, this_frame.made_s + clock() - t0
        store[key] = handle
        if handle then stone_tint_stats.textures = stone_tint_stats.textures + 1 end
    end
    if not handle then
        node.t = false
        return false
    end
    local t = dfhack.textures.getTexposByHandle(handle)
    if t and t > 0 then
        node.t = t
        if not floor_info then edge.ours[t] = true end
        return t
    end
    return nil
end

local S_FLOOR, S_BOULDER, S_PEBBLES = df.tiletype_shape.FLOOR, df.tiletype_shape.BOULDER,
    df.tiletype_shape.PEBBLES
local ROUGH_SPECIALS = {
    [df.tiletype_special.NORMAL] = true,
    [df.tiletype_special.WET] = true,
}

-- Map-level fallback for a rough floor at (wx, wy, z) when it isn't in
-- edge.info (1 tile off-screen or hidden under a shaft overhang).
-- Returns 9 (stone), 8 (pebbles), 2 (soil), or false.
local function edge_source(wx, wy, z)
    local b = fast.block(wx, wy, z)
    if not b then return false end
    local idx = (wx & 15) * 16 + (wy & 15)
    local material, tshape, special = tile_attrs(b.tt[idx])
    if (tshape ~= S_FLOOR and tshape ~= S_BOULDER and tshape ~= S_PEBBLES)
            or not ROUGH_SPECIALS[special] then
        return false
    end
    local id = STONE_MATERIALS[material] and (tshape == S_PEBBLES and 8 or 9)
        or (material == MAT_SOIL and 2) or false
    if not id then return false end
    if (b.des[idx] & fast.m_hidden) ~= 0 then return false end
    if id == 2 and is_sand(wx, wy, z) then return false end
    return id
end

local function map_floor_info(wx, wy, z, id, colours)
    if not group_enabled[(id == 9 or id == 8) and G_ROUGH or G_SOIL_FLOORS] then return false end
    if wx < 0 or wy < 0 or wx >= map_max_x or wy >= map_max_y then return false end
    local zsrc = edge.sources[z]
    if not zsrc then zsrc = {} edge.sources[z] = zsrc end
    local scol = zsrc[wx]
    if not scol then scol = {} zsrc[wx] = scol end
    local src_id = scol[wy]
    if src_id == nil then
        if not can_work() then this_frame.waited = this_frame.waited + 1 return false end
        local t0 = clock()
        src_id = edge_source(wx, wy, z)
        scol[wy] = src_id
        this_frame.maps, this_frame.map_s = this_frame.maps + 1, this_frame.map_s + clock() - t0
    end
    if src_id ~= id then return false end
    local col = colours[wx]
    if not col then col = {} colours[wx] = col end
    local code = col[wy]
    if not code then
        if not can_work() then this_frame.waited = this_frame.waited + 1 return false end
        local t0 = clock()
        code = lookup_colour(wx, wy, z)
        col[wy] = code
        this_frame.colours, this_frame.colour_s = this_frame.colours + 1, this_frame.colour_s + clock() - t0
    end
    if code == 0 then return false end
    local f = edge.fallback[code]
    if not f then f = {code=code, under=false} edge.fallback[code] = f end
    return f
end

local side_id = {}

-- Collects the tinted edge pieces for a cell's edging (flag). Checks the
-- visible viewport buffer first (zero map reads), falling back to the map when
-- the neighbor is off-screen or hidden under a shaft overhang.
local function cell_pieces(b0, b1, b2, b3, sx, sy, bg, dim_x, dim_y, info, win_x, win_y, z, colours)
    side_id[1], side_id[2], side_id[3], side_id[4] = b0, b1, b2, b3
    local any, clear = false, 0
    for s = 1, 4 do
        local id = side_id[s]
        local f = false
        if EDGINGS[id] then
            local side = SIDES[s]
            local nx, ny = sx + side.dx, sy + side.dy
            if nx >= 0 and nx < dim_x and ny >= 0 and ny < dim_y then
                f = info[bg[nx * dim_y + ny]] or false
            end
            if not f then
                f = map_floor_info(win_x + nx, win_y + ny, z, id, colours)
            end
            if f then
                any = true
                clear = clear | (0xFF << side.shift)
            end
        end
        taken[s] = f
    end
    if not any then return nil, 0 end
    -- Corners first, so the sides lie over them.
    local np = 0
    for c = 1, 4 do
        local corner = CORNERS[c]
        local a, b = corner.a, corner.b
        local id = side_id[a]
        if np and (taken[a] or taken[b]) and EDGINGS[id] and side_id[b] == id then
            local f
            local nx, ny = sx + corner.dx, sy + corner.dy
            if nx >= 0 and nx < dim_x and ny >= 0 and ny < dim_y then
                f = info[bg[nx * dim_y + ny]]
            end
            if not f then
                f = map_floor_info(win_x + nx, win_y + ny, z, id, colours) or nil
            end
            np = add_piece(np, f or taken[a] or taken[b], id, corner.piece)
        end
    end
    for s = 1, 4 do
        if np and taken[s] then
            np = add_piece(np, taken[s], side_id[s], SIDES[s].piece)
        end
    end
    if not np or np == 0 then return nil, 0 end
    return np, clear
end

-- One level's cells: each with edging gets its tinted pieces.
-- smart: bakes tinted edges into a tinted floor's bg when DF's own edges
-- (grass) or spatter (snow/mud/leaves) share the cell, and composites spatter
-- on top in bg2 for untinted cells, clearing our handled side bytes in
-- floor_flag so DF draws everything in its native order.
-- simple: writes tinted edges into bg2 over whatever DF draws.
-- off: leaves all floor edges to DF.
-- rec (1.3.6, THE QUICK FRAMES), when given: every cell given anything is
-- written down, so the quick frames can lay the same edges again without the
-- walk: what was written there (ff, bg2, bg; false where nothing was) and
-- what the result rests on (held: DF's background_two there; sp: DF's
-- spatter there; fi: the floor info of the picture under it, or false).
-- rec.ok is false when anything was left for a later frame (a tile's shape or
-- material by THE FRAME'S WORK CAP, a piece's or a spatter's picture not read
-- yet, a stack's texture not made yet), so the record isn't whole.
paint_edges = function(port, bg, dim_x, dim_y, win_x, win_y, z, colours, rec)
    if state.edges == 'off' then return end
    local ff, bg2 = port.screentexpos_floor_flag, port.screentexpos_background_two
    if not ff or not bg2 then return end
    local total = dim_x * dim_y
    if total <= 0 then return end
    local diffscan = dfhack.internal.diffscan
    local ff_base = diffscan and scan.base(port, 'screentexpos_floor_flag') or nil
    local zeros = ff_base and scan.zeros(total * 2) or nil
    local total2 = total * 2
    local spatter = port.screentexpos_spatter
    local smart = state.edges ~= 'simple'
    local info, ours = edge.info, edge.ours
    local flag_ok = edge.flag_ok
    if not flag_ok then flag_ok = {} edge.flag_ok = flag_ok end
    local rn, count0, waited0 = 0, edge.count, this_frame.waited
    local pend = 0   -- cells whose stack or spatter picture waits for a later frame
    local rc, rff, rb2, rbg, rheld, rsp, rfi
    if rec then
        rc, rff, rb2, rbg, rheld, rsp, rfi = rec.cell, rec.ff, rec.bg2, rec.bg, rec.held, rec.sp, rec.fi
    end
    local cell = 0
    while cell < total do
        local flag = ff[cell]
        if flag == 0 then
            if zeros then
                local start = (cell + 1) * 2
                if start >= total2 then break end
                local hit = diffscan(zeros, ff_base, start, total2, 4)
                if not hit then break end
                cell = hit >> 1
                flag = ff[cell]
            else
                flag = nil
            end
        end
        if flag and flag ~= 0 and flag >> 32 == 0 then
            local has = flag_ok[flag]
            if has == nil then
                has = (EDGINGS[flag & 0xFF] or EDGINGS[(flag >> 8) & 0xFF]
                    or EDGINGS[(flag >> 16) & 0xFF] or EDGINGS[(flag >> 24) & 0xFF]) ~= nil
                flag_ok[flag] = has
            end
            if has then
                if resolved_frame ~= frame_id then resolve_edge_pieces() end
                local b0 = flag & 0xFF
                local b1 = (flag >> 8) & 0xFF
                local b2 = (flag >> 16) & 0xFF
                local b3 = (flag >> 24) & 0xFF
                local held_in = bg2[cell]
                local held = held_in
                local stale = held ~= 0 and ours[held]
                if stale then
                    stone_tint_stats.edges_kept = (stone_tint_stats.edges_kept or 0) + 1
                    held = 0
                end
                local wrote_bg2 = false
                local ffw, bg2w, bgw = false, false, false
                local sx = cell // dim_y
                local np, clear = cell_pieces(b0, b1, b2, b3, sx, cell - sx * dim_y, bg,
                    dim_x, dim_y, info, win_x, win_y, z, colours)
                -- (read whenever a pieces stack came, or the cell is to be written down)
                local sp, floor_info = 0, nil
                if smart and (np or rec) then
                    sp = spatter and spatter[cell] or 0
                    floor_info = info[bg[cell]]
                end
                if np then
                    local rem_edges = ((flag & ~clear) & 0xFFFFFFFF) ~= 0
                    if floor_info and (rem_edges or sp ~= 0) then
                        local texpos = stack_texpos(np, floor_info, nil)
                        if texpos == nil then pend = pend + 1 end
                        if texpos then
                            ffw = flag & ~clear
                            ff[cell] = ffw
                            bg[cell] = texpos
                            bgw = texpos
                            info[texpos] = floor_info
                            edge.count = edge.count + 1
                        end
                    elseif held == 0 then
                        local sp_sid
                        if smart and sp ~= 0 then
                            sp_sid = source_for(sp)
                            if sp_sid == nil then pend = pend + 1 end
                            if not sp_sid then np = nil end
                        end
                        if np then
                            local texpos = stack_texpos(np, nil, sp_sid)
                            if texpos == nil then pend = pend + 1 end
                            if texpos then
                                if smart then
                                    ffw = flag & ~clear
                                    ff[cell] = ffw
                                end
                                bg2[cell] = texpos
                                bg2w = texpos
                                wrote_bg2 = true
                                edge.count = edge.count + 1
                            end
                        end
                    end
                end
                if stale and not wrote_bg2 then
                    bg2[cell] = 0
                    bg2w = 0
                end
                if rec and (ffw or bg2w or bgw) then
                    rn = rn + 1
                    rc[rn], rff[rn], rb2[rn], rbg[rn] = cell, ffw, bg2w, bgw
                    rheld[rn], rsp[rn], rfi[rn] = held_in, sp, floor_info or false
                end
            end
        end
        cell = cell + 1
    end
    if rec then
        for k = rn + 1, rec.n do
            rc[k], rff[k], rb2[k], rbg[k], rheld[k], rsp[k], rfi[k] = nil, nil, nil, nil, nil, nil, nil
        end
        rec.n, rec.count = rn, edge.count - count0
        -- (edge.pend_pieces speaks for this frame only when the pieces were
        -- resolved this frame: a level without edges never asks for them)
        rec.ok = this_frame.waited == waited0 and pend == 0
            and not (resolved_frame == frame_id and edge.pend_pieces)
    end
end
end)()

-- DF rebuilds screentexpos_background from scratch every rendered frame. This
-- was measured, not assumed: writing a sentinel into the buffer and reading it
-- back 1, 5 and 60 frames later found it gone every time (see probe.lua). Two
-- consequences shape this function:
--
--   * The scan cannot be skipped on quiet frames. There is no persistent state
--     to keep dirty -- skip a frame and DF's untinted floor is what shows.
--     (1.3.6) Every tile of ours is still written every frame, but a quick
--     frame writes them from a list instead of scanning (THE QUICK FRAMES).
--   * Nothing needs restoring. When the tint is switched off or a floor falls
--     out of scope we simply decline to write, and DF's own sprite stands.
--
-- So the work went into making each cell nearly free instead. Per cell in the
-- common case (a texture never ours) this is one array read and one hash
-- lookup, with no allocation and no C call; a cell whose texture may be ours
-- takes two lookups more (what its tile is, kept against the texture); an
-- empty cell is one read and a note for the level below. Map reads happen only
-- for a tile whose picture changed (WHAT A TILE IS); material lookups once per
-- tile per z-level, kept while the level is
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

-- ==========================================
-- THE QUICK FRAMES (1.3.6)
-- ==========================================
-- Every overlay draws on the game's own thread. DF's async_loop (g_src
-- enabler.cpp) is the simulation thread's loop: it runs render_things, where
-- DFHack draws the overlays, between the runs of mainloop, the game's tick,
-- while the main thread waits for it (do_frame: async_cmd::render, then
-- async_wait). So every millisecond spent here is a millisecond taken from
-- the game. Measured in play on 2026-11-26 (`stone-tint status`): 5.4 to 5.7
-- ms a frame on average on an 8,000-cell view, 1.6 to 1.7 of it the fog
-- below, the rest the scan of every cell and the floor edges' walk of every
-- flagged cell, every frame, whether anything had changed or not. With
-- Detailed Weather's own overlay and hook on the same thread, a busy moment in
-- the fort pushed the sum past a second and the game fell to 50 to 85 FPS for
-- seconds at a time; paused, the ticks cost nothing and it held 100.
--
-- DF still rebuilds the ground layer every frame (see the note below), so
-- every tile of ours has to be written every frame; but which tiles are ours,
-- and what each gets, only changes when something moves. So now:
--   * A FULL FRAME does what every frame did before (every cell scanned,
--     every flagged cell walked for its edges) and writes down, level by
--     level, each cell it gave something or left waiting: the cell, the
--     texture DF drew there (src), what it was given (out, or false while it
--     waits) and its kind (for the counts). The floor edges write down every
--     cell they gave anything (paint_edges' rec).
--   * A QUICK FRAME goes over those cells only. A cell still showing src gets
--     out back with one write; one showing something else, or still waiting,
--     goes through paint_cell as in a full frame, and its entry is brought up
--     to date or dropped (DF draws a texture never ours there now). The edges
--     are laid again from their record when nothing they rest on moved: no
--     cell of ours on that level changed, DF's floor flags are as they were
--     (diffscan) and each recorded cell holds what it held. Otherwise that
--     level's edges are walked whole and written down again.
--   * A full frame comes whenever anything that decides what a cell gets
--     moved (why_full): the view, the level, the view's size or the levels
--     below shown, a setting (strength, style, edges, ramp overlays, faces,
--     the switches), DF's textures (the sentinel), DF's own pieces read again
--     (tokens.gen), Detailed Weather's look, the engravings, and every
--     FULL_EVERY frames regardless.
--   * Not a new round of picture checks (THE ART AS DRAWN, every
--     SOURCE_CHECK_MS): the full frame every FULL_EVERY frames runs a
--     round's checks, as every full frame does (paint_cell asks source_for),
--     so a picture changed under the same number is seen within FULL_EVERY - 1
--     frames. Measured in play (2026-11-26): the rounds, until all their
--     checks were through, had called half of all full frames (220 of 430,
--     271 of 549), each about 5 ms against a quick frame's 0.3 to 0.4.
-- What a quick frame cannot see is a tile that was not ours becoming ours
-- while the view stands still (a wall dug out, a floor revealed): DF draws
-- it, and it waits for the next full frame, at most FULL_EVERY - 1 frames,
-- showing DF's own picture meanwhile, as a tile waiting for its texture always
-- has. Grass is never ours, so Detailed Weather's grass leaning in the wind
-- (new textures on every grass tile, as often as every frame) costs nothing
-- here. `stone-tint replay off` makes every frame a full frame again, for
-- comparing; `stone-tint status` gives both kinds' counts and times since the
-- last status, and what called the full frames.
local FULL_EVERY = 8
do
-- What was written down for level L (0 the level you are on, 1 to
-- LOWER_LEVELS the levels below): cell, src, out and kind side by side, n of
-- them; changed: whether a cell of ours on it changed this frame (the edges
-- then walk again); edges: paint_edges' record and DF's floor flags as kept.
local function level_of(L)
    local lv = rp.levels[L]
    if not lv then
        lv = {cell = {}, src = {}, out = {}, kind = {}, n = 0, changed = true,
              edges = {cell = {}, ff = {}, bg2 = {}, bg = {}, held = {}, sp = {}, fi = {},
                       n = 0, count = 0, ok = false, valid = false, raw = nil, raw_cap = 0}}
        rp.levels[L] = lv
    end
    return lv
end

-- A new map: every level's kept floor flags let go (df.new buffers, freed by
-- hand), nothing written down holds, and the next frame is a full frame.
function rp.forget()
    for _, lv in pairs(rp.levels) do
        local rec = lv.edges
        if rec.raw then df.delete(rec.raw) end
        rec.raw, rec.raw_cap = nil, 0
    end
    rp.levels, rp.key.valid, rp.fog.valid = {}, false, false
end

-- A full frame on one level: every cell DF drew there, as before 1.3.6 (the
-- levels below the same as the level you are on: THE LEVELS BELOW), each one
-- given something or left waiting written down.
function rp.full_level(L, port, pbg, pflags, lz, lcol, lchk, is_lower)
    local fx = rp.fx
    local total, dim_y, win_x, win_y = fx.total, fx.dim_y, fx.win_x, fx.win_y
    local max_x, max_y = fx.max_x, fx.max_y
    local known, counts = known_texpos, frame_counts
    local lv = level_of(L)
    local cells, srcs, outs, kinds = lv.cell, lv.src, lv.out, lv.kind
    local n = 0
    local diffscan = dfhack.internal.diffscan
    -- (asked for here, not held from elsewhere: THE ZEROS in onRenderFrame)
    local zeros = diffscan and scan.zeros(total) or nil
    local base = zeros and scan.base(port, 'screentexpos_background') or nil
    local scanned, below = 0, 0
    local cell = 0
    while cell < total do
        local drawn = pbg[cell]
        if drawn == 0 then
            if base then
                if cell + 1 >= total then break end
                cell = diffscan(zeros, base, cell + 1, total, 4)
                if not cell then break end
                drawn = pbg[cell]
            else
                drawn = nil
            end
        end
        if drawn then
            scanned = scanned + 1
            if known[drawn] ~= false then
                local sx = cell // dim_y
                local wx = win_x + sx
                local wy = win_y + cell - sx * dim_y
                if wx >= 0 and wx < max_x and wy >= 0 and wy < max_y then
                    this_frame.pend = false
                    local kind = paint_cell(pbg, pflags, cell, drawn, wx, wy, lz, lcol, lchk)
                    if kind then
                        counts[kind] = counts[kind] + 1
                        if is_lower then below = below + 1 end
                    end
                    local after = pbg[cell]
                    if after ~= drawn or this_frame.pend then
                        n = n + 1
                        cells[n], srcs[n] = cell, drawn
                        outs[n] = after ~= drawn and after or false
                        kinds[n] = kind or false
                    end
                end
            end
        end
        cell = cell + 1
    end
    for k = n + 1, lv.n do cells[k], srcs[k], outs[k], kinds[k] = nil, nil, nil, nil end
    lv.n, lv.changed = n, true
    fx.scanned, fx.below = fx.scanned + scanned, fx.below + below
end

-- A quick frame on one level: the cells written down only. One still showing
-- what it showed gets what it got, in one write; any other goes through
-- paint_cell as in a full frame.
function rp.quick_level(L, port, pbg, pflags, lz, lcol, lchk, is_lower)
    local fx = rp.fx
    local dim_y, win_x, win_y = fx.dim_y, fx.win_x, fx.win_y
    local known, counts = known_texpos, frame_counts
    local lv = level_of(L)
    local cells, srcs, outs, kinds = lv.cell, lv.src, lv.out, lv.kind
    local n, j, changed, below = lv.n, 0, false, 0
    for i = 1, n do
        local cell = cells[i]
        local v = pbg[cell]
        local src, out, kind = srcs[i], outs[i], kinds[i]
        local keep = true
        if v == src and out then
            pbg[cell] = out
        else
            -- Moved on, or still waiting: worked out as a full frame would.
            local new_out = false
            if v == 0 or known[v] == false then
                keep = false
            else
                local sx = cell // dim_y
                this_frame.pend = false
                kind = paint_cell(pbg, pflags, cell, v, win_x + sx, win_y + cell - sx * dim_y,
                    lz, lcol, lchk) or false
                local after = pbg[cell]
                if after ~= v then new_out = after end
                keep = new_out or this_frame.pend
            end
            if new_out ~= out then changed = true end
            src, out = v, new_out
        end
        if keep then
            j = j + 1
            cells[j], srcs[j], outs[j], kinds[j] = cell, src, out, kind
            if out and kind then
                counts[kind] = counts[kind] + 1
                if is_lower then below = below + 1 end
            end
        end
    end
    for k = j + 1, n do cells[k], srcs[k], outs[k], kinds[k] = nil, nil, nil, nil end
    lv.n, lv.changed = j, changed
    fx.scanned, fx.below = fx.scanned + n, fx.below + below
end

-- Whether a level's recorded edges still stand: DF's floor flags as kept, and
-- each recorded cell holding what it held (DF's background_two and spatter,
-- and the floor info of the picture now under it, which a grass tile's new
-- texture in the wind leaves as it was: none).
local function edges_hold(rec, port, pbg, total)
    local diffscan = dfhack.internal.diffscan
    local ff_base = diffscan and scan.base(port, 'screentexpos_floor_flag') or nil
    if not ff_base or not rec.raw or rec.raw_cap ~= total then return false end
    if diffscan(rec.raw, ff_base, 0, total * 2, 4) then return false end
    local bg2, spatter = port.screentexpos_background_two, port.screentexpos_spatter
    if not bg2 then return false end
    local smart = state.edges ~= 'simple'
    local info = edge.info
    local rc, rheld, rsp, rfi = rec.cell, rec.held, rec.sp, rec.fi
    for k = 1, rec.n do
        local cell = rc[k]
        if bg2[cell] ~= rheld[k] then return false end
        if smart then
            if spatter and spatter[cell] ~= rsp[k] then return false end
            if (info[pbg[cell]] or false) ~= rfi[k] then return false end
        end
    end
    return true
end

-- One level's floor edges: laid again from their record on a quick frame
-- when they still stand, otherwise walked whole (paint_edges) and written
-- down again, DF's floor flags kept first to tell the next frame whether they
-- moved.
function rp.edges_level(L, port, pbg, lz, lcol, full)
    local fx = rp.fx
    local total = fx.total
    local lv = level_of(L)
    local rec = lv.edges
    if not full and rec.valid and not lv.changed and edges_hold(rec, port, pbg, total) then
        local ff, bg2 = port.screentexpos_floor_flag, port.screentexpos_background_two
        local rc, rff, rb2, rbg = rec.cell, rec.ff, rec.bg2, rec.bg
        for k = 1, rec.n do
            local cell = rc[k]
            local w = rff[k]
            if w then ff[cell] = w end
            w = rb2[k]
            if w then bg2[cell] = w end
            w = rbg[k]
            if w then pbg[cell] = w end
        end
        edge.count = edge.count + rec.count
        rp.edges_kept = rp.edges_kept + 1
        return
    end
    local diffscan, memmove = dfhack.internal.diffscan, dfhack.internal.memmove
    local ff_base = diffscan and memmove and rp.on and scan.base(port, 'screentexpos_floor_flag') or nil
    if ff_base then
        if rec.raw_cap ~= total then
            if rec.raw then df.delete(rec.raw) end
            rec.raw = df.new('int32_t', total * 2)
            local _, a = df.sizeof(rec.raw)
            rec.raw_addr, rec.raw_cap = a, total
        end
        memmove(rec.raw_addr, ff_base, total * 8)
    end
    rec.ok = false
    paint_edges(port, pbg, fx.dim_x, fx.dim_y, fx.win_x, fx.win_y, lz, lcol, rec)
    rec.valid = ff_base ~= nil and rec.ok
    if not full then rp.edges_redone = rp.edges_redone + 1 end
end

-- Why this frame has to be a full one, or nil for a quick one. The reasons
-- are the keys of rp.why, for `stone-tint status`.
function rp.why_full(z, wx, wy, dx, dy, nl, strength, gmask)
    if not rp.on then return 'quick frames off' end
    local K = rp.key
    if not K.valid then return 'first frame' end
    if z ~= K.z then return 'level' end
    if wx ~= K.wx or wy ~= K.wy then return 'view moved' end
    if dx ~= K.dx or dy ~= K.dy or nl ~= K.nl then return 'view size or levels shown' end
    if strength ~= K.strength or state.style ~= K.style or state.edges ~= K.edges
            or frame_overlays ~= K.ov or state.faces ~= K.faces or gmask ~= K.gmask then
        return 'settings'
    end
    if tint_sentinel ~= K.sentinel or tokens.gen ~= K.tokens then return 'textures' end
    if dw_look ~= K.look then return 'weather look' end
    if engravings.count ~= K.eng then return 'engravings' end
    if frame_id - K.frame >= FULL_EVERY then return 'every 8 frames' end
    return nil
end

-- What a full frame rested on, for why_full.
function rp.keep_key(z, wx, wy, dx, dy, nl, strength, gmask)
    local K = rp.key
    K.valid, K.z, K.wx, K.wy, K.dx, K.dy, K.nl = true, z, wx, wy, dx, dy, nl
    K.strength, K.style, K.edges, K.ov, K.faces, K.gmask =
        strength, state.style, state.edges, frame_overlays, state.faces, gmask
    K.sentinel, K.tokens, K.look, K.eng = tint_sentinel, tokens.gen, dw_look, engravings.count
    K.frame = frame_id
end
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
    this_frame.pend = false

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
        reset_known()
        refresh_tokens(true)
        relearn = (clock() - t0) * 1000
    end
    -- THE ART AS DRAWN: this frame's reads, and a new round of checks now and then.
    frame_reads, frame_checks = READS_PER_FRAME, CHECKS_PER_FRAME
    frame_id = frame_id + 1
    fast.frame = frame_id
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
    dw_memo.active = rawget(_G, 'detailed_weather_pointed_from') ~= nil
    dw_check_look()
    -- ENGRAVED FLOORS BY THE MAP: filed again if their number changed.
    engravings.refresh()

    -- Taken after the z, sentinel and strength checks above, any of which can
    -- replace them.
    local bg = vp.screentexpos_background
    local ramp_flags = vp.screentexpos_ramp_flag
    local win_x, win_y = df.global.window_x, df.global.window_y
    local moved = last_win_x ~= nil and (win_x ~= last_win_x or win_y ~= last_win_y)
    last_win_x, last_win_y = win_x, win_y
    local counts = frame_counts
    counts[K_FLOOR], counts[K_STAIR], counts[K_RAMP], counts[K_ENGRAVED] = 0, 0, 0, 0
    edge.count = 0
    frame_strength, frame_budget = strength, NEW_TEXTURES_PER_FRAME
    -- THE OVERLAY IN THE RAMP: only while DF's overlays are hidden, any found
    local ov = stone_tint_overlays
    frame_overlays = state.overlays == 'tinted' and ov.hidden and ov.slots ~= nil and #ov.slots > 0
    ramp.laid = 0
    local total = dim_x * dim_y
    -- THE ZEROS, sized for the whole frame up front (the floor flags take two
    -- per cell), so nothing below makes the buffer again while another part of
    -- the frame still holds it. In 1.3.5 the frame held the buffer from
    -- scan.zeros(total) while paint_edges asked for scan.zeros(total * 2),
    -- which deleted it for a bigger one, and the levels below went on handing
    -- the deleted one to diffscan: on the first frame, and on every frame the
    -- view grew. The parts below each ask scan.zeros for it as they start.
    scan.zeros(total * 2)
    local edges_on = state.edges ~= 'off' and (group_enabled[G_ROUGH] or group_enabled[G_SOIL_FLOORS])

    -- THE LEVELS BELOW shown this frame: each in order, active and the main
    -- view's size, down to the map's floor.
    local lower = gps.lower_viewport
    local n_lower = 0
    for i = 0, LOWER_LEVELS - 1 do
        if z - i - 1 < 0 then break end
        local lvp = lower and lower[i]
        if not lvp or not lvp.flag.active or lvp.dim_x ~= dim_x or lvp.dim_y ~= dim_y then break end
        if not lvp.screentexpos_background or not lvp.screentexpos_ramp_flag then break end
        n_lower = i + 1
    end

    -- THE QUICK FRAMES: a full frame, or the cells written down at the last one.
    local gmask = 0
    for g = 1, G_ENGRAVED do
        if enabled[g] then gmask = gmask | (1 << g) end
    end
    local fx = rp.fx
    fx.total, fx.dim_x, fx.dim_y, fx.win_x, fx.win_y = total, dim_x, dim_y, win_x, win_y
    fx.max_x, fx.max_y, fx.scanned, fx.below = map_max_x, map_max_y, 0, 0
    local why = rp.why_full(z, win_x, win_y, dim_x, dim_y, n_lower, strength, gmask)
    local full = why ~= nil
    if full then rp.why[why] = (rp.why[why] or 0) + 1 end
    local run_level = full and rp.full_level or rp.quick_level

    local colours, checks = level_caches(z)
    run_level(0, vp, bg, ramp_flags, z, colours, checks, false)
    if edges_on then rp.edges_level(0, vp, bg, z, colours, full) end
    for i = 0, n_lower - 1 do
        local lz = z - i - 1
        local lvp = lower[i]
        local lbg = lvp.screentexpos_background
        colours, checks = level_caches(lz)
        run_level(i + 1, lvp, lbg, lvp.screentexpos_ramp_flag, lz, colours, checks, true)
        if edges_on then rp.edges_level(i + 1, lvp, lbg, lz, colours, full) end
    end
    if full then rp.keep_key(z, win_x, win_y, dim_x, dim_y, n_lower, strength, gmask) end

    stone_tint_stats.floors = counts[K_FLOOR]
    stone_tint_stats.engraved = counts[K_ENGRAVED]
    stone_tint_stats.stairs = counts[K_STAIR]
    stone_tint_stats.ramps = counts[K_RAMP]
    stone_tint_stats.below = fx.below
    stone_tint_stats.edges = edge.count
    -- (a quick frame lays the ramps' overlays from the list, without counting
    -- them: the last full frame's count stands)
    if full then stone_tint_stats.laid = ramp.laid end
    local took = (clock() - started) * 1000
    stone_tint_stats.frame_ms = timed_average(stone_tint_stats.frame_ms, took)
    stone_tint_stats.worst_ms = math.max(stone_tint_stats.worst_ms or 0, took)
    if full then
        rp.full_n, rp.full_ms = rp.full_n + 1, timed_average(rp.full_ms, took)
    else
        rp.quick_n, rp.quick_ms = rp.quick_n + 1, timed_average(rp.quick_ms, took)
    end
    add_cost('materials', this_frame.colours, this_frame.colour_s)
    add_cost('maps', this_frame.maps, this_frame.map_s)
    add_cost('looks', this_frame.checks, this_frame.check_s)
    add_cost('reads', this_frame.reads, this_frame.read_s)
    add_cost('made', this_frame.made, this_frame.made_s)
    if took >= SLOW_FRAME_MS then
        record_slow_frame(took, upkeep, relearn, level_from, z, moved, fx.scanned)
    end
end

function StoneTintOverlay:overlay_onupdate()
    -- Graphics can be reloaded without changing texture handles: one of DF's
    -- own pieces or overlays looked at again, all read again if it moved (DF'S
    -- OWN PIECES AND OVERLAYS).
    refresh_tokens(false)
end

-- Module state outlives a world: DFHack caches script environments, and the
-- overlay framework rebuilds widgets on SC_WORLD_LOADED without clearing
-- anything here. Without this, loading a second fort whose camera happens to
-- start on the same z-level as the last one leaves cached_z matching and paints
-- the previous fort's stone colours.
dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        -- Detailed Weather is looked up again for each map (DETAILED WEATHER).
        dw_colour, dw_look, dw_memo = nil, nil, {filed = {}, live = {}}
        -- (so the first frame drawn relearns, DF'S OWN PIECES AND OVERLAYS
        -- included, even should the textures come back at the same numbers)
        tint_sentinel = nil
        palettes = {}
        entry_cache = {}
        reset_tints(true)
        reset_material_caches()
        refresh_map_bounds()
        load_state()
        -- (DF'S OWN PIECES AND OVERLAYS are read in the first frame drawn: the
        -- map's load moves DF's textures, which reads them, THE OVERLAY)
        engravings.count, engravings.by_level = -1, {}
        reset_cache(nil)
        -- (THE QUICK FRAMES) nothing written down on another map holds here
        rp.forget()
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
        engravings.count, engravings.by_level = -1, {}
        rp.forget()
        if sc == SC_WORLD_UNLOADED then
            -- Colour indices belong to a world. The textures are not deleted
            -- (see make_texture); they are only forgotten.
            stone_tint_textures = {art_count=ART_COUNT, by_source=true}
            stone_tint_sources = {next_id=1, data={}, by_texpos={}, by_hash={}}
            -- (PICTURES BY MEMCMP) filed under the ids just started over: freed
            for _, list in pairs(stone_tint_pictures) do
                for _, filed in ipairs(list) do df.delete(filed.buf) end
            end
            stone_tint_pictures = {}
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
    -- runs to the Close line at row 30, so 31 rows.
    frame={w=44, h=35},
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
    local overlay_options = {}
    for i, m in ipairs(OVERLAY_MODES) do overlay_options[i] = {label=m[2], value=m[1]} end
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
        -- DF's ramp overlays (RAMP OVERLAYS): drawn into every ramp, tinted with
        -- the tinted ones; hidden everywhere; or left to DF, over the tint. Only
        -- while ramps are tinted.
        widgets.CycleHotkeyLabel{
            label='Ramp overlays:', key='CUSTOM_H', options=overlay_options,
            initial_option=state.overlays,
            on_change=function(value)
                state.overlays = value save_state() update_ramp_overlays() force_repaint()
            end,
        },
        -- Black shadows and depth fog, whatever graphics are loaded (SHADOWS
        -- AND FOG). Independent of the tint.
        toggle('Black shadows and fog:', 'CUSTOM_B', 'black_shadows'),
        widgets.CycleHotkeyLabel{
            label='Floor edges:', key='CUSTOM_D',
            options={{label='Smart', value='smart'}, {label='Simple', value='simple'},
                     {label='Off', value='off'}},
            initial_option=state.edges or 'smart',
            on_change=function(mode)
                state.edges = mode save_state() force_repaint()
            end,
        },
        widgets.Label{frame={t=30}, text={{key='LEAVESCREEN', text=': Close'}}},
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
    refresh_tokens(true)
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
-- keeps in stone_tint_stats, the ramp overlay entries hidden, DF's own pieces
-- and overlays found (tokens), and whether the art has the engraved cells (an
-- art-vanilla.lua older than this file does not, and then vanilla's engraving
-- is not known, nor drawn without its face).
function get_report()
    local ov = stone_tint_overlays
    local engraved_art = art ~= nil and art.CELLS.engraved_floor ~= nil
        and art.CELLS.engraved_floor_plain ~= nil
    local sh = stone_tint_shades
    return art ~= nil, stone_tint_stats, ov.hidden and #(ov.slots or {}) or nil,
        tokens, engraved_art, sh.applied and #(sh.slots or {}) or nil
end


-- Initialize module state independently of widget construction. DFHack can preserve
-- widget class objects across development rescans without calling init() again.
load_state()
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
        print(('stone-tint: strength is %d%%, tint style %s, %s edges'):format(get_state().strength,
            get_state().style, get_state().edges or 'smart'))
        local art_ok, stats, hidden, tk, engraved_art, shaded = get_report()
        if not art_ok then
            print('stone-tint: art data stone-tint/art-vanilla.lua did not load; nothing is tinted')
        end
        print(('stone-tint: tinted in the last drawn frame: %d floor, %d engraved, %d stair, %d ramp '
            .. 'tiles, %d of them on levels below; ramps given their overlay: %d'):format(stats.floors,
            stats.engraved or 0, stats.stairs, stats.ramps, stats.below or 0, stats.laid or 0))
        print(('stone-tint: floor edges over open ground tinted in the last drawn frame: %d cells; '
            .. 'found still in place from an earlier frame, so far: %d'):format(stats.edges or 0,
            stats.edges_kept or 0))
        -- DF'S OWN PIECES AND OVERLAYS: what was read, and what was found.
        local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
        print(('stone-tint: DF\'s own pieces and overlays, read from %d graphics folders (%d files): '
            .. 'stone floor pieces %d of 9, soil floor pieces %d of 9, pebbles pieces %d of 9, ramp overlays %d; engraved art %s')
            :format(tk.dirs, tk.files, count(tk.stone), count(tk.soil), count(tk.pebbles), count(tk.overlay),
            engraved_art and 'loaded' or 'missing from stone-tint/art-vanilla.lua'))
        print(('stone-tint: textures made this session: %d, from %d pictures read off DF'):format(
            stats.textures, stats.sources or 0))
        print(('stone-tint: frame %.2f ms recent average, worst %.2f ms since last status; '
            .. 'overlays, shadows and fog %.2f ms, worst %.2f ms'):format(stats.frame_ms or 0,
            stats.worst_ms or 0, stats.fog_ms or 0, stats.upkeep_worst_ms or 0))
        print(('stone-tint: so far: %d texture resets, %d pictures read, %d pictures checked, '
            .. '%d known again under a new number without a read (PICTURES BY MEMCMP)')
            :format(stats.resets or 0, stats.reads or 0, stats.checks or 0, stats.known_again or 0))
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
        -- THE QUICK FRAMES: both kinds' counts since the last status and their
        -- running average times, what called each full frame, the cells on the
        -- list as the last frame left it, and how often the edges and the fog
        -- below were laid again from their record. The counts then start over.
        local why = {}
        for k, v in pairs(rp.why) do why[#why + 1] = ('%s %d'):format(k, v) end
        table.sort(why)
        print(('stone-tint: since last status, quick frames %s: %d at %.2f ms on average; full '
            .. 'frames %d at %.2f ms; full frames called by: %s'):format(rp.on and 'on' or 'OFF', rp.quick_n, rp.quick_ms or 0,
            rp.full_n, rp.full_ms or 0, #why > 0 and table.concat(why, ', ') or 'nothing yet'))
        local listed = {}
        for L = 0, LOWER_LEVELS do
            local lv = rp.levels[L]
            if lv and lv.n > 0 then
                listed[#listed + 1] = (L == 0 and 'this level %d' or (L .. ' down %d')):format(lv.n)
            end
        end
        print(('stone-tint: cells on the quick frames\' list: %s; floor edges laid again from their '
            .. 'record %d times, walked again %d; the fog below kept %d frames, walked %d')
            :format(#listed > 0 and table.concat(listed, ', ') or 'none', rp.edges_kept,
            rp.edges_redone, rp.fog.kept, rp.fog.walked))
        rp.quick_n, rp.full_n, rp.why, rp.edges_kept, rp.edges_redone = 0, 0, {}, 0, 0
        rp.fog.kept, rp.fog.walked = 0, 0
        stats.worst_ms, stats.upkeep_worst_ms = 0, 0
        if hidden then
            print(('stone-tint: DF\'s ramp overlays hidden (%d DF table entries), %s'):format(hidden,
                get_state().overlays == 'tinted' and 'drawn into the ramps' or 'drawn nowhere'))
        else
            print('stone-tint: ramp overlays as the graphics draw them')
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
    elseif args[1] == 'edges' then
        if not edge.modes[args[2]] then qerror('edges must be one of: smart, simple, off') end
        state.edges = args[2]
        save_state()
        force_repaint()
    elseif args[1] == 'replay' then
        -- THE QUICK FRAMES on or off for this session (off: every frame a full
        -- frame, as before 1.3.6), for comparing.
        if args[2] == 'on' then rp.on = true
        elseif args[2] == 'off' then rp.on = false
        else qerror('replay must be on or off') end
        rp.key.valid, rp.fog.valid = false, false
        print(('stone-tint: quick frames %s'):format(rp.on and 'on' or 'off: every frame is a full frame'))
    else
        print('Use: stone-tint [gui]')
        print('     overlay enable stone-tint.map')
        print('     overlay disable stone-tint.map')
        print('     stone-tint clear-cache')
        print('     stone-tint status')
        print('     stone-tint set <' .. table.concat(STRENGTHS, '|') .. '>')
        print('     stone-tint style <keep|smooth|classic>')
        print('     stone-tint edges <smart|simple|off>')
        print('     stone-tint replay <on|off>')
    end
end

if dfhack_flags.module then return end

-- Only reached by a command run before the module ever loaded.
stone_tint_command(...)