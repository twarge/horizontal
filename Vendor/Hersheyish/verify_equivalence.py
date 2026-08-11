#!/usr/bin/env python3
"""Prove the generated stroke font is data-identical to the file it replaced.

The A4 remediation is only worth anything if it changes provenance without
changing output. This parses two versions of HorizontalOutlineFont.swift and
compares what the renderer actually consumes: the two glyph-ID tables and the
outline string behind every reachable code point.

    python3 Vendor/Hersheyish/verify_equivalence.py <old-file> [<new-file>]

Exits non-zero on any difference. Run it against the pre-remediation file kept
in git history:

    git show <rev>:Sources/HorizontalNative/Views/HorizontalOutlineFont.swift > /tmp/old.swift
    python3 Vendor/Hersheyish/verify_equivalence.py /tmp/old.swift
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DEFAULT_NEW = os.path.join(ROOT, "Sources", "HorizontalNative", "Views",
                           "HorizontalOutlineFont.swift")

# Mirrors HorizontalOutlineTextRenderer.glyphID(for:font:).
EXTRA_CODEPOINTS = {
    0x03BC: 638, 0x00B5: 638, 0x00B7: 729, 0x2126: 550, 0x03A9: 550,
    0x03D1: 634, 0x00D7: 727, 0x00B0: 718, 0x00B1: 2233,
}
FALLBACK_ID = 870


def parse(path):
    src = open(path, encoding="utf-8").read()

    def ids(name):
        body = src.split("static let %s: [Int] = [" % name, 1)[1]
        return [int(t) for t in re.findall(r"\d+", body[:body.index("]")])]

    body = src.split("static let glyphs: [Int: String] = [", 1)[1]
    glyphs = {}
    for m in re.finditer(r'^\s*(\d+):\s*"((?:[^"\\]|\\.)*)",?\s*$', body, re.M):
        glyphs[int(m.group(1))] = m.group(2).replace('\\\\', '\\')
    return ids("plainGlyphIDs"), ids("simplexGlyphIDs"), glyphs


def outline(plain, simplex, glyphs, cp, small):
    """What the renderer would draw for cp, or None if it draws nothing."""
    table = plain if small else simplex
    if 32 <= cp < 127:
        gid = table[cp - 32]
    elif cp == 0x00A0:
        gid = table[0]
    else:
        gid = EXTRA_CODEPOINTS.get(cp, FALLBACK_ID)
    got = glyphs.get(gid)
    if got:
        return got
    # renderer's ASCII fallback path
    return glyphs.get(plain[cp - 32]) if 32 <= cp < 127 else None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    old_path = sys.argv[1]
    new_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_NEW

    old = parse(old_path)
    new = parse(new_path)
    failures = []

    def check(label, ok, detail=""):
        print("[%s] %s%s" % ("ok  " if ok else "FAIL", label,
                             ("  -- " + detail) if detail else ""))
        if not ok:
            failures.append(label)

    check("plainGlyphIDs identical", old[0] == new[0],
          "%d entries" % len(new[0]))
    check("simplexGlyphIDs identical", old[1] == new[1],
          "%d entries" % len(new[1]))
    check("same set of glyph IDs", set(old[2]) == set(new[2]),
          "%d ids" % len(new[2]))

    differing = sorted(k for k in set(old[2]) & set(new[2])
                       if old[2][k] != new[2][k])
    check("every shared outline byte-identical", not differing,
          "%d differ%s" % (len(differing),
                           ": " + str(differing[:6]) if differing else ""))

    # The behavioural check: every code point the renderer can be asked for,
    # in both font sizes, must resolve to the same outline.
    probes = list(range(32, 127)) + sorted(EXTRA_CODEPOINTS) + [0x00A0, 0x2603]
    mismatched = [(cp, small) for cp in probes for small in (False, True)
                  if outline(*old, cp=cp, small=small)
                  != outline(*new, cp=cp, small=small)]
    check("all %d code-point probes resolve identically" % (2 * len(probes)),
          not mismatched, "%d mismatched: %s" % (len(mismatched), mismatched[:6]))

    print()
    if failures:
        print("NOT EQUIVALENT: %s" % "; ".join(failures))
        return 1
    print("EQUIVALENT: the generated font renders identically to %s"
          % os.path.basename(old_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
