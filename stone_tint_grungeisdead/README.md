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

The GUI offers Off, 10%, 15%, 20%, 25%, 30%, 40%, 50%, 60%, 75% and 100% strengths, a choice of
tint style, switches for rough, smooth and engraved floors, stairs, ramps, soil, engraving faces
and black shadows and fog, and a choice for ramp overlays. Settings persist with each fortress.
The default is 50%, Keep texture.

`stone-tint status` reports what was tinted in the last drawn frame and where each frame's time
went, `stone-tint set <strength>` sets the strength, and `stone-tint clear-cache` rereads the
materials and the graphics.

Stone Tint changes rendering only. It does not modify saves or map tiles.

## Tint styles

Keep texture (the default) moves each picture's average colour toward its material's colour and
every pixel with it by the same amount, so the texture stays as drawn at any strength; at 100% the
average is the material's colour. Smooth moves each pixel toward the material's colour at its own
brightness. Classic is the original maths, pixel by pixel; on art not drawn in vanilla's key
colours it can scramble the pattern, so the higher strengths are best with Keep texture.

## Black shadows and fog

Wall and ramp shadows and the depth fog over lower levels are redrawn black with their own
transparency, as Dark Depths draws them, from whatever graphics are loaded. Lighter pixels in a
shadow (Detailed Landscapes' rim along its rounded slopes) are kept. Switch it off to keep the
graphics' own shadows and fog.

## Any graphics

Stone Tint finds the tiles it tints on the map, not by their pictures: every revealed natural
floor, stair and ramp of stone or soil (sand excepted) is tinted, whatever graphics drew it. It
tints the picture Dwarf Fortress drew there, so vanilla's art, Detailed Landscapes', Detailed
Weather's weather colors and any other graphics' floors, ramps and engravings keep their look
under the tint. The edge pieces floors drop over open ground and the overlays drawn over ramps are
found by Dwarf Fortress's own graphics tokens in the installed graphics, so they follow whatever
graphics fill them too.

## Engraved floors

Dwarf Fortress draws natural engraved floors with a picture of its own that ignores the stone
(vanilla's is a fixed blue-gray). Stone Tint tints it like the floor around it. With "Engraving
faces" switched off, vanilla's engraving keeps its carved border and the dwarf face is left out;
any other graphics' engraving is tinted as drawn.

## Ramp overlays

Dwarf Fortress draws an overlay over every ramp, which would cover the tinted ramp. "Ramp
overlays" picks what happens to it while ramps are tinted: Tinted (the default) draws it into
each ramp, tinted with the ramp, so the ramp keeps its shape (Detailed Landscapes' rounded hills
among them); Hidden removes it from every ramp; As drawn leaves it to Dwarf Fortress, over the
tint. Ramps Stone Tint does not tint (grass, sand, constructed) keep their overlay as drawn. Ramp
shadows are kept.

## Performance

Dwarf Fortress rebuilds its map background texture buffer every rendered frame, so the visible
viewport must be scanned every frame. On an 86-by-45 viewport at a 100 FPS cap, the optimized
renderer measured 3.45 to 3.81% of wall time. This is about five times faster than the initial
version, but it is still a measurable always-on cost.

If changed geology ever displays a stale color, run `stone-tint clear-cache`.