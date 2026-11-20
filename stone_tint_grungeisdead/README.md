# Stone Tint

Natural stone and soil floors, engraved floors, stairs and ramps display subtle colors based on
their actual material. Bauxite is vermilion, limonite is saffron, cassiterite is gray, microcline
is aqua, and so on.

## Requirement

DFHack 53.15-r3 or a compatible release is required.

## Use

In the DFHack console:

```text
overlay enable stone-tint.map
stone-tint
```

The GUI offers Off, 10%, 15%, 20%, 25%, 30%, 40%, and 50% strengths, and switches for rough,
smooth and engraved floors, stairs, ramps, soil, engraving faces and ramp overlays. Settings
persist with each fortress. The default is 50%.

`stone-tint status` reports what was tinted in the last drawn frame, `stone-tint set <strength>`
sets the strength, and `stone-tint clear-cache` rereads the materials.

Stone Tint changes rendering only. It does not modify saves or map tiles.

## Engraved floors

Dwarf Fortress draws natural engraved floors with a fixed blue-gray picture that ignores the
stone. Stone Tint draws engraved floors in their stone's color at the same strength as the floor
around them. With "Engraving faces" switched off, an engraved floor keeps its carved border and
the dwarf face is left out.

## Ramp overlays

"Hide ramp overlays" removes the overlay Dwarf Fortress draws over every ramp, which would
otherwise cover the tinted ramp. It affects every ramp, tinted or not, and only while ramps are
tinted. Ramp shadows are kept.

## Performance

Dwarf Fortress rebuilds its map background texture buffer every rendered frame, so the visible
viewport must be scanned every frame. On an 86-by-45 viewport at a 100 FPS cap, the optimized
renderer measured 3.45 to 3.81% of wall time. This is about five times faster than the initial
version, but it is still a measurable always-on cost.

If changed geology ever displays a stale color, run `stone-tint clear-cache`.