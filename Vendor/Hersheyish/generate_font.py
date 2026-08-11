#!/usr/bin/env python3
"""Generate Sources/HorizontalNative/Views/HorizontalOutlineFont.swift.

The stroke-font tables come from OpenCV, which publishes them under the
3-clause BSD license. This script downloads two files from a pinned OpenCV tag,
verifies them by SHA-256, and emits the Swift tables from those. It reads
nothing else -- in particular it does not read Horizon EDA.

    python3 Vendor/Hersheyish/generate_font.py            # fetch (cached), emit
    python3 Vendor/Hersheyish/generate_font.py --offline   # cache only
    python3 Vendor/Hersheyish/generate_font.py --check     # verify, do not write

See README.md in this directory for the provenance argument.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CACHE = os.path.join(HERE, "upstream-cache")
OUTPUT = os.path.join(ROOT, "Sources", "HorizontalNative", "Views",
                      "HorizontalOutlineFont.swift")

# OpenCV 4.4.0 is the last release under the 3-clause BSD license; 4.5.0 and
# later are Apache-2.0. The glyph table is byte-identical across both, so
# pinning the BSD release keeps the licence question as simple as possible.
OPENCV_TAG = "4.4.0"
UPSTREAM = {
    "hershey_fonts.cpp": (
        "modules/imgproc/src/hershey_fonts.cpp",
        "5fa0d65264f72e5b166d07973aabd49f27cc54d0074062a8efc312bf9ab95432",
    ),
    "drawing.cpp": (
        "modules/imgproc/src/drawing.cpp",
        "3f2f2711deeacaa1f50e5d9f06fce89f33aed1821a98030a8b9bccd49c1e5ca8",
    ),
    "LICENSE": (
        "LICENSE",
        "a5a7cf90fe5ac9763baad852cf69cf9d9b89bff934a679fdc5c8fcecaeba9a25",
    ),
}
RAW = "https://raw.githubusercontent.com/opencv/opencv/{tag}/{path}"

# The two faces HorizontalOutlineTextRenderer uses, and the OpenCV table each
# is taken from.
FACES = [("plainGlyphIDs", "HersheyPlain"), ("simplexGlyphIDs", "HersheySimplex")]

# Code points HorizontalOutlineTextRenderer maps outside ASCII, plus the
# not-a-glyph fallback. Listed here so their artwork is emitted too.
EXTRA_IDS = [
    550,   # U+03A9 / U+2126 omega, ohm
    634,   # U+03D1 theta symbol
    638,   # U+00B5 / U+03BC micro, mu
    718,   # U+00B0 degree
    727,   # U+00D7 multiplication
    729,   # U+00B7 middle dot
    2233,  # U+00B1 plus-minus
    870,   # fallback drawn for unmapped code points
]

# Only ASCII 0x20..0x7E is addressed by code point. OpenCV's `HersheyComplex`
# table runs on past 95 entries into a legacy 8-bit Greek/Cyrillic block, which
# must never be reached that way; neither face here has one, but the span is
# pinned explicitly so that stays true if a face is added.
ASCII_SPAN = 95

# Space advance. OpenCV's simplex table uses glyph 2199 ("JZ", 16 units wide);
# board and schematic files authored against the 8-unit space ("NV", glyph
# 2198) lay out differently, and text has to land where the file says it does.
# This is an interoperability constant, in the same category as the other
# format facts recorded in DERIVED.md -- not artwork.
SPACE_GLYPH = {"simplexGlyphIDs": 2198}


def download(url):
    """Fetch a URL, falling back to curl where urllib has no CA bundle."""
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read()
    except Exception as exc:                 # noqa: BLE001 -- any transport issue
        print("  urllib failed (%s); trying curl" % exc)
        try:
            return subprocess.run(["curl", "-fsSL", "--max-time", "60", url],
                                  check=True, stdout=subprocess.PIPE).stdout
        except (OSError, subprocess.CalledProcessError) as exc2:
            sys.exit("could not download %s: %s" % (url, exc2))


def fetch(offline=False):
    """Return the pinned upstream sources, verifying every digest."""
    os.makedirs(CACHE, exist_ok=True)
    out = {}
    for name, (path, want) in UPSTREAM.items():
        dest = os.path.join(CACHE, name)
        if not os.path.exists(dest):
            if offline:
                sys.exit("missing cached upstream %s and --offline was given" % name)
            url = RAW.format(tag=OPENCV_TAG, path=path)
            print("fetching %s" % url)
            with open(dest, "wb") as f:
                f.write(download(url))
        blob = open(dest, "rb").read()
        got = hashlib.sha256(blob).hexdigest()
        if got != want:
            sys.exit("SHA-256 mismatch for %s\n  expected %s\n  got      %s"
                     % (name, want, got))
        print("verified %-20s %s..." % (name, got[:16]))
        out[name] = blob.decode("utf-8")
    return out


def glyph_table(src):
    """Parse OpenCV's g_HersheyGlyphs[] into a list of strings.

    Handles adjacent-literal concatenation (two literals with no comma between
    them form one array element) and decodes backslash escapes.
    """
    body = src.split("const char* g_HersheyGlyphs[] =", 1)[1]
    i = body.index("{") + 1
    elems, cur, n = [], [], len(body)
    while i < n:
        c = body[i]
        if c == '"':
            i += 1
            while body[i] != '"':
                if body[i] == "\\":
                    cur.append(body[i + 1])  # only \\ and \" occur in this data
                    i += 2
                else:
                    cur.append(body[i])
                    i += 1
            i += 1
        elif c == "/" and body[i + 1] == "/":
            i = body.index("\n", i)
        elif c == ",":
            elems.append("".join(cur))
            cur = []
            i += 1
        elif c == "0" and not cur and body[i + 1:i + 2] in ("}", "\n", " "):
            break
        else:
            i += 1
    return elems


def face_table(src, name):
    """Parse `static const int <name>[] = {...}`, dropping the metadata word."""
    body = src.split("static const int %s[] =" % name, 1)[1]
    body = body[body.index("{") + 1:body.index("}")]
    rest = body.split(",", 1)[1]
    return [int(t) for t in rest.replace("\n", " ").split(",") if t.strip()]


HEADER = '''\
// Hershey stroke-font tables.
//
// Generated by Vendor/Hersheyish/generate_font.py -- do not edit by hand.
//
// The glyph outlines and the per-face glyph-ID tables are verbatim data from
// OpenCV {tag}, which publishes them under the 3-clause BSD license:
//
//     modules/imgproc/src/hershey_fonts.cpp   (g_HersheyGlyphs)
//     modules/imgproc/src/drawing.cpp         ({tables})
//
// See Vendor/Hersheyish/LICENSE for that license and Vendor/Hersheyish/README.md
// for the provenance argument. The outlines themselves originate with
// Dr. A. V. Hershey at the US National Bureau of Standards and were never
// subject to copyright.
//
// One value departs from upstream: the simplex space advance is glyph 2198
// ("NV", 8 units) rather than OpenCV's 2199 ("JZ", 16 units), because text in
// board and schematic files is positioned against the 8-unit space. See
// SPACE_GLYPH in the generator.
'''


def emit_swift(glyphs, faces):
    """Render the Swift source. Only glyph IDs actually reachable are emitted."""
    tables = ", ".join(sym for _, sym in FACES)
    out = [HEADER.format(tag=OPENCV_TAG, tables=tables),
           "enum HorizontalOutlineFont {"]

    for swift_name, _ in FACES:
        ids = faces[swift_name]
        out.append("    static let %s: [Int] = [" % swift_name)
        for i in range(0, len(ids), 16):
            out.append("        " + ", ".join(str(v) for v in ids[i:i + 16])
                       + ("," if i + 16 < len(ids) else ""))
        out.append("    ]")
        out.append("")

    reachable = sorted({i for ids in faces.values() for i in ids} | set(EXTRA_IDS))
    out.append("    static let glyphs: [Int: String] = [")
    for gid in reachable:
        literal = glyphs[gid].replace("\\", "\\\\").replace('"', '\\"')
        out.append('        %d: "%s",' % (gid, literal))
    out.append("    ]")
    out.append("}")
    return "\n".join(out) + "\n", reachable


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true",
                    help="use the cached upstream files, do not download")
    ap.add_argument("--check", action="store_true",
                    help="verify the checked-in file matches, write nothing")
    args = ap.parse_args()

    src = fetch(args.offline)
    glyphs = glyph_table(src["hershey_fonts.cpp"])
    print("upstream glyph table: %d slots, %d non-empty"
          % (len(glyphs), sum(1 for g in glyphs if g)))

    faces = {}
    for swift_name, sym in FACES:
        ids = face_table(src["drawing.cpp"], sym)[:ASCII_SPAN]
        if swift_name in SPACE_GLYPH:
            ids[0] = SPACE_GLYPH[swift_name]
        faces[swift_name] = ids

    text, reachable = emit_swift(glyphs, faces)
    print("emitting %d faces and %d reachable glyphs"
          % (len(faces), len(reachable)))

    if args.check:
        have = open(OUTPUT, encoding="utf-8").read() if os.path.exists(OUTPUT) else ""
        if have == text:
            print("OK: %s is up to date" % os.path.relpath(OUTPUT, ROOT))
            return 0
        print("STALE: %s differs from generator output"
              % os.path.relpath(OUTPUT, ROOT))
        return 1

    with open(OUTPUT, "w") as f:
        f.write(text)
    print("wrote %s" % os.path.relpath(OUTPUT, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
