"""
build_stone_tint_art.py

Writes stone-tint/art-vanilla.lua: vanilla's floor, engraved floor, stair and
ramp art as Lua data, for stone-tint to tint while the game runs. DF cannot hand
a PNG's pixels back to a script, so art that is to be tinted has to exist as
data.

Usage:
    python build_stone_tint_art.py <vanilla folder> <out file>

    vanilla folder  DF's data/vanilla (holds vanilla_environment and
                    vanilla_descriptors_graphics)
    out file        stone-tint/art-vanilla.lua beside stone-tint.lua

    engraved_floor_plain.png has to sit beside this script.

What goes in:
    floors          stone floor 1 to 9 (FLOORS 0:3 to 2:5), 5B to 5D
                    (ALT_FLOORS 7:4 to 7:6), smooth floor (FLOORS 6:3);
                    soil floor 1 to 9 (FLOORS 0:6 to 2:8), 5B to 5D
                    (ALT_FLOORS 7:7 to 7:9). ALT_FLOORS is floors.bmp.
    stairs          STAIRS rows 1 (stone) and 2 (dirt): up/down, up, down
    ramps           every cell of STONE_RAMPS and SOIL_RAMPS that a
                    *_RAMP_WITH_WALL_* or *_RAMP_OTHER token names (43 each)
    engraved        the engraved floor (FLOOR_STONE_ENGRAVED_NON_PALETTE, the
                    fixed art DF draws on a natural engraved floor), and the
                    same tile with the face carved out, read from
                    engraved_floor_plain.png. Both come last, so every earlier
                    cell and pixel entry keeps its place and the output only
                    grows.
    RAMP_CELL       which ramp cell DF draws for each of the 256 ways the 8
                    neighbours can be walls

Each pixel also carries its key column: the column of palettes.png row 0 (DF's
untinted reference ramp, 18 colours) nearest it in luminance, Rec.601 weights,
ties to the first. stone-tint blends a pixel toward the material's own palette
colour in that column:
    out = round(pixel + strength * (palette[key] - pixel)), halves to even
That is the maths the old PNG sheets were baked with, measured off them: run
over the 13 stone floor cells it reproduces every shipped stone-tint-<n>.png
pixel for pixel.

The ramp rule, from vanilla's token names: a ramp's cell is named by the
orthogonal neighbours that are walls, plus each diagonal wall whose two
orthogonal neighbours are both open; no walls at all is OTHER. Every one of the
256 combinations lands on exactly one of the 47 tokens.

The plain engraved floor. Vanilla's engraving was cut into vanilla's smooth
floor: outside its carving, every pixel of FLOOR_STONE_ENGRAVED_NON_PALETTE is
the smooth floor's own (FLOORS 6:3; 468 of the 1024 are equal, and every pixel
that differs belongs to the border squares, the frame lines or the face).
engraved_floor_plain.png puts the smooth floor back where the face was: the
panel inside the frame (rows 7 to 24, columns 7 to 24) is the smooth floor's
same 18 x 18, and the one frame pixel the beard crossed (row 25, column 14)
takes the frame line's colour. 205 pixels differ from vanilla's engraving, all
in rows 7 to 25, columns 9 to 23. It is a hardcopy as well as the source: edit
the PNG and run this again to change the plain tile.
"""
import os
import re
import sys

import numpy as np
from PIL import Image

TILE = 32
LUMA = np.array([0.299, 0.587, 0.114])
# Two characters per pixel, each one of these 64, name an entry of PIXELS.
ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

# DF's bit order for a ramp's walls (screentexpos_ramp_flag bits 8 to 15).
WALL_BITS = ['N', 'W', 'E', 'S', 'NW', 'NE', 'SW', 'SE']
ADJACENT = {'NW': ('N', 'W'), 'NE': ('N', 'E'), 'SW': ('S', 'W'), 'SE': ('S', 'E')}


def cell(img, x, y):
    return img[y * TILE:(y + 1) * TILE, x * TILE:(x + 1) * TILE]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    vanilla, out_path = sys.argv[1], sys.argv[2]
    env = os.path.join(vanilla, 'vanilla_environment', 'graphics')
    imgs = os.path.join(env, 'images')

    def load(name):
        return np.array(Image.open(os.path.join(imgs, name)).convert('RGBA')).astype(np.int64)

    floors, alt = load('floors.png'), load('floors.bmp')
    stairs = load('stairs.png')
    ramps = {'stone': load('ramps_stone.png'), 'soil': load('ramps_soil.png')}
    pal = np.array(Image.open(os.path.join(vanilla, 'vanilla_descriptors_graphics', 'graphics',
                                           'images', 'palettes.png')).convert('RGB')).astype(np.int64)
    key_luma = pal[0] @ LUMA

    # ---- the cells, named the way stone-tint.lua asks for them ----
    cells = []
    for kind, y0 in (('stone', 3), ('soil', 6)):
        n = 1
        for y in range(y0, y0 + 3):
            for x in range(3):
                cells.append(('%s_floor_%d' % (kind, n), cell(floors, x, y)))
                n += 1
        for i, suffix in enumerate(('5b', '5c', '5d')):
            cells.append(('%s_floor_%s' % (kind, suffix), cell(alt, 7, y0 + 1 + i)))
    cells.append(('smooth_floor', cell(floors, 6, 3)))
    for kind, y in (('stone', 1), ('soil', 2)):
        for x, shape in enumerate(('updown', 'up', 'down')):
            cells.append(('%s_stair_%s' % (kind, shape), cell(stairs, x, y)))

    tiles_txt = open(os.path.join(env, 'graphics_tiles.txt')).read()
    tokens = {}
    for x, y, suffix in re.findall(r'\[TILE_GRAPHICS:STONE_RAMPS:(\d+):(\d+):STONE_RAMP_'
                                   r'(?:WITH_WALL_)?([A-Z_]+)\]', tiles_txt):
        key = frozenset() if suffix == 'OTHER' else frozenset(suffix.split('_'))
        tokens[key] = '%s_%s' % (x, y)
    ramp_cells = sorted(set(tokens.values()), key=lambda s: tuple(map(int, s.split('_'))))
    for kind in ('stone', 'soil'):
        for c in ramp_cells:
            x, y = map(int, c.split('_'))
            cells.append(('%s_ramp_%s' % (kind, c), cell(ramps[kind], x, y)))

    # ---- engraved floors, last: every cell and pixel entry above keeps its
    # place, so the output only grows ----
    cells.append(('engraved_floor', cell(load('floor_stone_engraved_non_palette.png'), 0, 0)))
    plain_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'engraved_floor_plain.png')
    plain = np.array(Image.open(plain_path).convert('RGBA')).astype(np.int64)
    assert plain.shape == (TILE, TILE, 4), 'engraved_floor_plain.png must be one 32 x 32 cell'
    cells.append(('engraved_floor_plain', plain))

    ramp_by_walls = []
    for bits in range(256):
        walls = {WALL_BITS[i] for i in range(8) if bits >> i & 1}
        cardinal = walls & {'N', 'S', 'E', 'W'}
        diagonal = {d for d in walls - cardinal if not set(ADJACENT[d]) & cardinal}
        ramp_by_walls.append(tokens[frozenset(cardinal | diagonal)])

    # ---- pixels: one shared table of (r, g, b, a, key) ----
    entries, index = [(0, 0, 0, 0, 0)], {(0, 0, 0, 0, 0): 0}
    encoded = []
    for name, c in cells:
        px = c.reshape(-1, 4)
        keys = np.abs((px[:, :3] @ LUMA)[:, None] - key_luma[None, :]).argmin(axis=1)
        chars = []
        for (r, g, b, a), k in zip(px.tolist(), keys.tolist()):
            e = (0, 0, 0, 0, 0) if a == 0 else (r, g, b, a, k)
            if e not in index:
                index[e] = len(entries)
                entries.append(e)
            i = index[e]
            chars.append(ALPHABET[i // 64] + ALPHABET[i % 64])
        encoded.append((name, ''.join(chars)))
    assert len(entries) <= 64 * 64

    # ---- write the module ----
    out = []
    out.append('-- stone-tint/art-vanilla.lua')
    out.append('--@ module = true')
    out.append('-- Generated by build_stone_tint_art.py from DF\'s vanilla art. Do not edit by')
    out.append('-- hand: change the generator and run it again.')
    out.append('--')
    out.append('-- PIXELS lists every distinct pixel the art uses as {r, g, b, a, key}. key is')
    out.append('-- the palette column (0 to 17) the tint blends toward. Entry 1 is the')
    out.append('-- transparent pixel. CELLS holds each cell\'s 1024 pixels, row by row, two')
    out.append('-- characters per pixel: with p and q their 0-based places in ALPHABET, the')
    out.append('-- pixel is PIXELS[p * 64 + q + 1], so "AA" is the transparent entry 1.')
    out.append('-- RAMP_CELL[walls] names the ramp cell DF draws for a wall byte (bits N, W,')
    out.append('-- E, S, NW, NE, SW, SE, as in screentexpos_ramp_flag bits 8 to 15).')
    out.append('')
    out.append('CELL_PX = %d' % TILE)
    out.append("ALPHABET = '%s'" % ALPHABET)
    out.append('')
    out.append('PIXELS = {')
    for i in range(0, len(entries), 6):
        out.append('    ' + ' '.join('{%d,%d,%d,%d,%d},' % e for e in entries[i:i + 6]))
    out.append('}')
    out.append('')
    out.append('CELLS = {')
    for name, s in encoded:
        out.append("    %s = '%s'," % (name, s))
    out.append('}')
    out.append('')
    out.append('RAMP_CELL = {')
    for i in range(0, 256, 8):
        out.append('    ' + ' '.join("[%d]='%s'," % (b, ramp_by_walls[b]) for b in range(i, i + 8)))
    out.append('}')
    with open(out_path, 'w', newline='\n') as f:
        f.write('\n'.join(out) + '\n')
    print('wrote %s: %d cells, %d pixel entries, %d ramp cells' % (
        out_path, len(cells), len(entries), len(ramp_cells)))


if __name__ == '__main__':
    main()