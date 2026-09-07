"""The atopile bridge against a tiny hand-written board file: parse, pool
items, a fresh project, sync, re-sync, and a rename matched by pads."""

import os
import tempfile
import unittest
from pathlib import Path

import horizontal
from horizontal import ato

BOARD = '''(kicad_pcb (version 20240108) (generator "atopile")
  (net 0 "")
  (net 1 "GND")
  (net 2 "VCC")
  (net 3 "SIG")
  (footprint "ACME_R0402:R0402" (layer "F.Cu") (uuid "aaaaaaaa-0000-0000-0000-000000000001")
    (at 10 20 90)
    (property "Reference" "R1" (at 0 0 0) (layer "F.SilkS"))
    (property "Value" "1kΩ" (at 0 0 0) (layer "F.Fab"))
    (property "atopile_address" "app.divider.r_top" (at 0 0 0) (layer "User.9"))
    (property "LCSC" "C11702" (at 0 0 0) (layer "User.9"))
    (property "Manufacturer" "ACME" (at 0 0 0) (layer "User.9"))
    (property "Partnumber" "0402WGF1001TCE" (at 0 0 0) (layer "User.9"))
    (fp_line (start -0.9 -0.5) (end 0.9 -0.5) (stroke (width 0.12)) (layer "F.SilkS"))
    (fp_rect (start -1 -0.6) (end 1 0.6) (stroke (width 0.05)) (layer "F.CrtYd"))
    (pad "1" smd rect (at -0.5 0 90) (size 0.6 0.5) (layers "F.Cu" "F.Paste" "F.Mask") (net 2 "VCC"))
    (pad "2" smd rect (at 0.5 0 90) (size 0.6 0.5) (layers "F.Cu" "F.Paste" "F.Mask") (net 3 "SIG"))
  )
  (footprint "ACME_R0402:R0402" (layer "F.Cu") (uuid "aaaaaaaa-0000-0000-0000-000000000002")
    (at 10 25 0)
    (property "Reference" "R2" (at 0 0 0) (layer "F.SilkS"))
    (property "Value" "1kΩ" (at 0 0 0) (layer "F.Fab"))
    (property "atopile_address" "app.divider.r_bottom" (at 0 0 0) (layer "User.9"))
    (property "LCSC" "C11702" (at 0 0 0) (layer "User.9"))
    (property "Manufacturer" "ACME" (at 0 0 0) (layer "User.9"))
    (property "Partnumber" "0402WGF1001TCE" (at 0 0 0) (layer "User.9"))
    (pad "1" smd rect (at -0.5 0 0) (size 0.6 0.5) (layers "F.Cu" "F.Paste" "F.Mask") (net 3 "SIG"))
    (pad "2" smd rect (at 0.5 0 0) (size 0.6 0.5) (layers "F.Cu" "F.Paste" "F.Mask") (net 1 "GND"))
  )
  (footprint "ACME_R0402:R0402" (layer "F.Cu") (uuid "aaaaaaaa-0000-0000-0000-000000000004")
    (at 40 20 0)
    (property "Reference" "R5" (at 0 0 0) (layer "F.SilkS"))
    (property "Value" "1kΩ" (at 0 0 0) (layer "F.Fab"))
    (property "atopile_address" "app.divider2.r_top" (at 0 0 0) (layer "User.9"))
    (property "LCSC" "C11702" (at 0 0 0) (layer "User.9"))
    (property "Manufacturer" "ACME" (at 0 0 0) (layer "User.9"))
    (property "Partnumber" "0402WGF1001TCE" (at 0 0 0) (layer "User.9"))
    (pad "1" smd rect (at -0.5 0 0) (size 0.6 0.5) (layers "F.Cu" "F.Paste" "F.Mask") (net 2 "VCC"))
    (pad "2" smd rect (at 0.5 0 0) (size 0.6 0.5) (layers "F.Cu" "F.Paste" "F.Mask") (net 1 "GND"))
  )
  (footprint "ACME_R0402:R0402" (layer "F.Cu") (uuid "aaaaaaaa-0000-0000-0000-000000000005")
    (at 40 25 0)
    (property "Reference" "R6" (at 0 0 0) (layer "F.SilkS"))
    (property "Value" "1kΩ" (at 0 0 0) (layer "F.Fab"))
    (property "atopile_address" "app.divider2.r_bottom" (at 0 0 0) (layer "User.9"))
    (property "LCSC" "C11702" (at 0 0 0) (layer "User.9"))
    (property "Manufacturer" "ACME" (at 0 0 0) (layer "User.9"))
    (property "Partnumber" "0402WGF1001TCE" (at 0 0 0) (layer "User.9"))
    (pad "1" smd rect (at -0.5 0 0) (size 0.6 0.5) (layers "F.Cu" "F.Paste" "F.Mask") (net 1 "GND"))
    (pad "2" smd rect (at 0.5 0 0) (size 0.6 0.5) (layers "F.Cu" "F.Paste" "F.Mask") (net 2 "VCC"))
  )
  (footprint "ACME_TH:HOLE" (layer "F.Cu") (uuid "aaaaaaaa-0000-0000-0000-000000000003")
    (at 30 30 0)
    (property "Reference" "J1" (at 0 0 0) (layer "F.SilkS"))
    (property "Value" "pin" (at 0 0 0) (layer "F.Fab"))
    (property "atopile_address" "app.j1" (at 0 0 0) (layer "User.9"))
    (pad "1" thru_hole circle (at 0 0) (size 1.6 1.6) (drill 0.8) (layers "*.Cu" "*.Mask") (net 1 "GND"))
    (pad "" np_thru_hole circle (at 3 0) (size 2 2) (drill 2) (layers "*.Cu" "*.Mask"))
  )
)
'''


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.board = Path(self.tmp.name) / "design.kicad_pcb"
        self.board.write_text(BOARD, encoding="utf-8")
        self.project_path = Path(self.tmp.name) / "design.horizontal"

    def tearDown(self):
        self.tmp.cleanup()

    def test_parse(self):
        footprints, nets = ato.read_kicad_pcb(self.board)
        self.assertEqual([fp.refdes for fp in footprints], ["R1", "R2", "R5", "R6", "J1"])
        self.assertEqual(nets[1], "GND")
        r1 = footprints[0]
        self.assertEqual(r1.address, "app.divider.r_top")
        self.assertEqual(r1.rot, 90)
        self.assertEqual([(p.name, p.net, p.rot) for p in r1.pads], [("1", "VCC", 0), ("2", "SIG", 0)])
        self.assertEqual(r1.courtyard, (-1, -0.6, 1, 0.6))
        self.assertEqual(len(r1.silk_lines), 1)
        j1 = footprints[4]
        self.assertEqual(j1.pads[0].drill, (0.8, 0.8))
        self.assertEqual(j1.pads[1].kind, "np_thru_hole")

    def test_pool_items_are_deterministic_and_shared(self):
        footprints, _ = ato.read_kicad_pcb(self.board)
        padstacks = {}
        first = ato.package_for(footprints[0], padstacks)
        second = ato.package_for(footprints[1], padstacks)
        self.assertEqual(first[0], second[0], "the same footprint yields one package")
        self.assertEqual(len(padstacks), 1, "equal pads share one padstack")
        unit, entity, symbol, pins, gate = ato.unit_entity_symbol_for(footprints[0])
        self.assertEqual(sorted(p["primary_name"] for p in unit["pins"].values()), ["1", "2"])
        self.assertEqual(entity["prefix"], "R")
        self.assertEqual(set(symbol["pins"]), set(pins.values()))
        again = ato.unit_entity_symbol_for(footprints[0])
        self.assertEqual(again[0]["uuid"], unit["uuid"])

    def test_sync_creates_and_is_idempotent_and_matches_renames(self):
        report = ato.sync(self.board, self.project_path, create=True, prefer_live=False)
        self.assertEqual(report["footprints"], 5)
        self.assertEqual(report["mismatches"], [])
        self.assertEqual(report["diagnostics"], [])
        self.assertEqual(report["op_summary"]["ensure_component"], 5)
        self.assertEqual(report["op_summary"]["ensure_net"], 3)

        project = horizontal.open(self.project_path, prefer_live=False)
        r1 = project.component("R1")
        self.assertEqual(r1["mpn"], "0402WGF1001TCE")
        self.assertEqual({p["pin"]: p["net"] for p in r1["pins"]}, {"1": "VCC", "2": "SIG"})
        self.assertEqual(r1["board"]["x_mm"], 10)
        self.assertEqual(r1["board"]["y_mm"], -20)
        self.assertEqual(r1["board"]["angle_deg"], 90)
        self.assertNotEqual(r1["group"], ato.NULL_UUID)
        self.assertEqual(len(project.parts()), 2)

        again = ato.sync(self.board, self.project_path, prefer_live=False)
        self.assertEqual(again["ops"], 0)
        self.assertEqual(again["pool_written"], 0)

        # Module layouts transfer through groups: divider2 laid out like divider.
        groups = {g["name"]: g for g in project.groups()}
        self.assertEqual(sorted(groups), ["app", "app.divider", "app.divider2"])
        self.assertEqual({m["tag"] for m in groups["app.divider"]["members"]}, {"r_top", "r_bottom"})
        moved = project.copy_group_layout("app.divider", "app.divider2", x_mm=60, y_mm=-40, angle_deg=0)
        change = moved["changes"][0]
        self.assertEqual(change["placed"], 2)
        r6 = project.component("R6")["board"]
        r5 = project.component("R5")["board"]
        self.assertEqual((r6["x_mm"], r6["y_mm"]), (60, -40), "the anchor (r_bottom, first tag alphabetically) goes to the given point")
        self.assertEqual((r5["x_mm"], r5["y_mm"]), (60, -35), "r_top keeps its 5 mm offset above r_bottom")
        self.assertEqual(r5["angle_deg"], 90, "r_top keeps its own rotation")

        renamed = Path(self.tmp.name) / "renamed.kicad_pcb"
        renamed.write_text(BOARD.replace('"SIG"', '"MID"'), encoding="utf-8")
        report = ato.sync(renamed, self.project_path, prefer_live=False)
        self.assertEqual(report["op_summary"], {"rename_net": 1})
        self.assertEqual(report["mismatches"], [])

        removed = Path(self.tmp.name) / "removed.kicad_pcb"
        text = BOARD.replace('"SIG"', '"MID"')
        start = text.index('(footprint "ACME_TH:HOLE"')
        end = text.index("\n  )\n", start) + len("\n  )\n")
        removed.write_text(text[:start] + text[end:], encoding="utf-8")
        report = ato.sync(removed, self.project_path, prefer_live=False)
        self.assertEqual(report["op_summary"].get("remove_component"), 1)
        self.assertEqual(report["mismatches"], [])
        self.assertEqual([c["refdes"] for c in project.components()], ["R1", "R2", "R5", "R6"])


if __name__ == "__main__":
    unittest.main()
