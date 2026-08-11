# Hershey stroke font

`Sources/HorizontalNative/Views/HorizontalOutlineFont.swift` is generated from
here. It used to be transcribed from another project's copy of these tables; it
is now generated from OpenCV, which publishes them under the 3-clause BSD
license.

```bash
python3 Vendor/Hersheyish/generate_font.py          # regenerate
python3 Vendor/Hersheyish/generate_font.py --check   # CI: is it up to date?
```

## Why this resolves A4

Horizon's glyph table is not Horizon's work. Its `hershey_fonts.cpp` is a copy
of OpenCV's `g_HersheyGlyphs[]` and still carries OpenCV's BSD header, Intel and
Willow Garage copyright lines, and OpenCV's own `CvMat helper tables` comment.
Diffing the two shows Horizon's slots 0–3299 — all 1640 non-empty glyphs — are
byte-for-byte identical to OpenCV's.

The glyph-ID ordering tables are the same story. This project previously flagged
them as "the part that follows Horizon's arrangement", but they are OpenCV's
`HersheyPlain` and `HersheySimplex` from `modules/imgproc/src/drawing.cpp`, with
OpenCV's leading metadata word dropped. So the remediation plan's expectation —
find a public-domain Hershey distribution, then re-derive the character mapping
from the standard occidental ordering — turned out to be unnecessary on both
counts. Both halves come from one permissively licensed upstream.

What Horizon did author is 36 umlaut glyphs (Ä Ö Ü ä ö ü across six faces, added
in Horizon commit `969d8d57`) at table slots 3300–3355. This project never used
them: `HorizontalOutlineTextRenderer` maps no umlaut code point, so those slots
were never transcribed. Nothing here needs replacing.

Further upstream still, the outlines are the work of Dr. A. V. Hershey at the US
National Bureau of Standards. As a US government work they were never subject to
copyright, which gives the data two independent non-copyleft provenance chains.

## Inputs

Pinned by tag and verified by SHA-256 on every run; the generator refuses to
proceed on a mismatch.

| File | SHA-256 | License |
| --- | --- | --- |
| `opencv 4.4.0 modules/imgproc/src/hershey_fonts.cpp` | `5fa0d652…ab95432` | 3-clause BSD |
| `opencv 4.4.0 modules/imgproc/src/drawing.cpp` | `3f2f2711…c1e5ca8` | 3-clause BSD |

4.4.0 is deliberate: it is the last OpenCV release under the 3-clause BSD
license, since 4.5.0 relicensed to Apache-2.0. The glyph table is byte-identical
across both, so pinning the BSD release costs nothing. Copies live in
`upstream-cache/` so the build is reproducible offline, and OpenCV's license
travels with them in `LICENSE`.

The generator reads those files and nothing else. It does not read Horizon.

## Equivalence

Remediation here is only worth something if provenance changes and output does
not. `verify_equivalence.py` compares what the renderer consumes — both
glyph-ID tables, and the outline behind every code point it can be asked for, in
both font sizes — between the generated file and the one it replaced:

```bash
git show <pre-remediation-rev>:Sources/HorizontalNative/Views/HorizontalOutlineFont.swift > /tmp/old.swift
python3 Vendor/Hersheyish/verify_equivalence.py /tmp/old.swift
```

At the time of the switch this reported both tables identical, all 198 glyph IDs
present with byte-identical outlines, and all 212 code-point probes resolving to
the same outline. The pad-label golden tests, which measure real text through
`HorizontalOutlineTextRenderer`, pass unchanged.

## One deliberate departure from upstream

The simplex space advance is glyph 2198 (`"NV"`, 8 units) where OpenCV uses 2199
(`"JZ"`, 16 units). Text in board and schematic files is positioned against the
8-unit space, so the wider one would move every string containing a space. This
is an interoperability constant of the same kind as the other format facts
recorded here, and it is a single integer, not artwork. It lives in
`SPACE_GLYPH` in the generator.

## Scope

Only the two faces the renderer uses are emitted (`plainGlyphIDs`,
`simplexGlyphIDs`), and only the 198 glyph IDs those tables and the renderer's
non-ASCII map can actually reach. Adding a face is a one-line change to `FACES`.

Umlauts are not included, because adding them would change rendering rather than
preserve it — today an unmapped code point draws glyph 870. If they are wanted
later, they can be composed from the BSD base glyphs rather than taken from
Horizon; the sibling `hersheyish` project does exactly that, along with symbol
rescaling for the small faces.
