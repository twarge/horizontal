import asyncio
import json
import os
import tempfile
import unittest
import uuid
import time
from pathlib import Path
from unittest.mock import patch

from horizontal.client import Session
from horizontal import mcp_server as server

CLI = Path(__file__).resolve().parents[2] / ".build/debug/horizontal"


class MCPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"HORIZONTAL_CLI": str(CLI), "HORIZONTAL_ISOLATED": "1"})
        self.env.start()
        self.path = Path(self.temp.name) / "Test.horizontal"
        session = Session(isolated=True)
        session.new_project(self.path)
        session.close()
        self.opened = await self.call("open_project", path=str(self.path), source="disk")
        self.ref = self.opened["data"]["project_ref"]

    async def asyncTearDown(self):
        for project in list(server._projects.values()):
            project.session.close()
        server._projects.clear(); server._snapshots.clear()
        self.env.stop(); self.temp.cleanup()

    async def call(self, name, **args):
        result = await server.mcp.call_tool(name, args)
        self.assertFalse(result.is_error, result.structured_content or result.content)
        return result.structured_content

    async def test_advertised_contracts_are_typed_and_strict(self):
        tools = {t.name: t for t in await server.mcp.list_tools()}
        net = tools["get_net"]
        self.assertIn("id", net.input_schema["properties"])
        self.assertFalse(net.input_schema["additionalProperties"])
        ops = tools["apply_ops"].input_schema
        self.assertIn("expected_revision", ops["required"])
        self.assertIn("operation_id", ops["required"])
        self.assertIn("discriminator", ops["properties"]["ops"]["items"])
        self.assertIn("Component", tools["get_component"].output_schema["$defs"])

    async def test_errors_and_unnamed_lookup(self):
        for args in ({"sheet": 999}, {"sheet": True}, {"sheet": "1"}, {"shete": 1}):
            result = await server.mcp.call_tool("list_components", {"project_ref": self.ref, **args})
            self.assertTrue(result.is_error)
            self.assertIn(result.structured_content["error"]["code"], {"NOT_FOUND", "INVALID_ARGUMENT"})
        empty = await self.call("list_components", sheet=1, project_ref=self.ref)
        self.assertEqual(empty["data"], [])
        self.assertEqual(empty["meta"]["source"], "disk")
        net_id = "aaaaaaaa-0000-0000-0000-000000000001"
        edited = await self.call("apply_ops", project_ref=self.ref, expected_revision=self.opened["data"]["revision"], operation_id="make-net",
                                 ops=[{"op": "ensure_net", "id": net_id, "name": "temp"}, {"op": "rename_net", "net": net_id, "name": ""}])
        net = await self.call("get_net", project_ref=self.ref, id=net_id)
        self.assertEqual(net["data"]["name"], "")
        self.assertEqual(net["data"]["id"], net_id)
        bad = await server.mcp.call_tool("get_net", {"project_ref": self.ref, "id": net_id, "name": "also"})
        self.assertTrue(bad.is_error)
        conflict = await server.mcp.call_tool("apply_ops", {"project_ref": self.ref, "expected_revision": self.opened["data"]["revision"], "operation_id": "stale",
                                                           "ops": [{"op": "ensure_net", "name": "bad"}]})
        self.assertTrue(conflict.is_error)
        self.assertEqual(conflict.structured_content["error"]["code"], "STALE_REVISION")

    async def test_pinned_snapshot_and_render_metadata(self):
        pinned = await self.call("analysis_snapshot", project_ref=self.ref)
        frozen_ref = pinned["data"]["project_ref"]
        result = await server.mcp.call_tool("render_sheet", {"project_ref": frozen_ref, "sheet": 1})
        self.assertFalse(result.is_error, result.content)
        self.assertTrue(any(item.type == "image" for item in result.content))
        self.assertEqual(result.structured_content["meta"]["snapshot_id"], self.opened["data"]["snapshot_id"])
        await self.call("apply_ops", project_ref=self.ref, expected_revision=self.opened["data"]["revision"], operation_id="change",
                        ops=[{"op": "ensure_net", "name": "new"}])
        self.assertEqual((await self.call("list_nets", project_ref=frozen_ref))["data"], [])
        await self.call("release_analysis_snapshot", snapshot_ref=pinned["data"]["snapshot_ref"])

    async def test_diagnostics_without_secret_values(self):
        result = await self.call("connection_status")
        self.assertEqual(result["data"]["required_native_api"], 2)
        self.assertNotIn('"token"', json.dumps(result))
        self.assertEqual(result["data"]["contexts"][0]["project_ref"], self.ref)

    async def test_analysis_runs_from_native_schematic_evidence(self):
        unit, entity, gate, pin1, pin2 = [str(uuid.uuid4()) for _ in range(5)]
        items = [{"type": "unit", "uuid": unit, "name": "R", "pins": {pin1: {"primary_name": "1", "direction": "passive"}, pin2: {"primary_name": "2", "direction": "passive"}}},
                 {"type": "entity", "uuid": entity, "name": "Resistor", "prefix": "R", "gates": {gate: {"name": "Main", "unit": unit}}}]
        ops = [{"op": "ensure_component", "refdes": ref, "entity": entity, "value": "1k"} for ref in ["R1", "R2"]]
        ops += [{"op": "ensure_net", "name": name} for name in ["IN", "OUT", "GND"]]
        ops += [{"op": "connect", "component": ref, "pin": pin, "net": net} for ref, pin, net in [("R1", "1", "IN"), ("R1", "2", "OUT"), ("R2", "1", "OUT"), ("R2", "2", "GND")]]
        await self.call("apply_ops", project_ref=self.ref, expected_revision=self.opened["data"]["revision"], operation_id="divider", ops=ops, pool_items=items)
        pinned = (await self.call("analysis_snapshot", project_ref=self.ref))["data"]
        snapshot = pinned["snapshot"]
        nets = {net["name"]: net["id"] for net in snapshot["nets"]}
        scenario = {"reference_net": nets["GND"], "models": {component["id"]: {"kind": "resistor"} for component in snapshot["components"]},
                    "sources": [{"id": "input", "positive_net": nets["IN"], "negative_net": nets["GND"], "evidence": {"source": "user", "description": "Test source"}}]}
        setup = {"input_source": "input", "output_positive_net": nets["OUT"], "output_negative_net": nets["GND"], "sweep": {"start_hz": 1, "stop_hz": 1000, "points": 8}}
        self.assertTrue((await self.call("validate_analysis", snapshot_ref=pinned["snapshot_ref"], scenario=scenario, setup=setup))["data"]["ready"])
        job = (await self.call("analyze_transfer", snapshot_ref=pinned["snapshot_ref"], scenario=scenario, setup=setup))["data"]["job_id"]
        deadline = time.monotonic() + 10
        while True:
            status = (await self.call("analysis_result", job_id=job))["data"]
            if status["state"] not in {"running", "queued"}: break
            self.assertLess(time.monotonic(), deadline)
            await asyncio.sleep(.02)
        self.assertEqual(status["state"], "completed")
        self.assertAlmostEqual(status["result"]["data"]["magnitude"][0], .5)
        self.assertEqual(status["result"]["provenance"]["snapshot_id"], snapshot["meta"]["snapshot_id"])
        self.assertTrue(all(e["file"] == "top_block.json" for e in status["result"]["evidence"].values()))
        exported = (await self.call("export_analysis", job_id=job, target_directory=self.temp.name))["data"]
        self.assertTrue((Path(exported["directory"]) / "report.html").exists())
        await self.call("discard_analysis", job_id=job)

    async def test_pool_reach_and_the_state_of_the_live_channel(self):
        # An empty answer used to be indistinguishable from an app that is not
        # running; the status says which question was actually answered.
        state = (await self.call("live_state"))["data"]
        self.assertIn(state["status"], {"connected", "unavailable"})
        self.assertIsInstance(state["documents"], list)
        if state["status"] == "unavailable":
            self.assertIn("switched off", state["reason"])

        # A project the app is not holding is editable, and says so.
        self.assertEqual((await self.call("open_project", path=str(self.path), source="disk"))["data"]["editable"], True)

        # The project pool of a fresh project is empty, and the wider scopes
        # answer without an error even when no base pool is reachable.
        self.assertEqual((await self.call("list_parts", project_ref=self.ref))["data"], [])
        self.assertIsInstance((await self.call("list_parts", project_ref=self.ref, scope="all"))["data"], list)
        self.assertTrue((await server.mcp.call_tool("list_parts", {"project_ref": self.ref, "scope": "sideways"})).is_error)
        found = (await self.call("search_pool", project_ref=self.ref, query="nothing at all"))["data"]
        self.assertEqual(found["total"], 0)
        self.assertTrue(found["pools"][0]["is_project_pool"])

        # Bringing in a part is a mutation like any other: guarded, and named.
        tools = {t.name: t for t in await server.mcp.list_tools()}
        for name in ("import_pool_part", "pool_write"):
            self.assertIn("expected_revision", tools[name].input_schema["required"])
            self.assertIn("operation_id", tools[name].input_schema["required"])
        missing = await server.mcp.call_tool("import_pool_part", {
            "project_ref": self.ref, "part": "no-such-part",
            "expected_revision": (await self.call("project_files", project_ref=self.ref))["meta"]["revision"],
            "operation_id": str(uuid.uuid4())})
        self.assertTrue(missing.is_error)
        self.assertEqual(missing.structured_content["error"]["code"], "NOT_FOUND")

    async def test_schematic_ops_are_advertised_and_discriminated(self):
        ops = {t.name: t for t in await server.mcp.list_tools()}["apply_ops"].input_schema
        mapping = ops["properties"]["ops"]["items"]["discriminator"]["mapping"]
        for op in ("place_symbol", "remove_symbol", "draw_net_line"):
            self.assertIn(op, mapping)
        listed = {op["op"] for op in (await self.call("list_ops", project_ref=self.ref))["data"]}
        self.assertTrue({"place_symbol", "remove_symbol", "draw_net_line"} <= listed, listed)

    async def test_text_ops_are_advertised_and_round_trip(self):
        ops = {t.name: t for t in await server.mcp.list_tools()}["apply_ops"].input_schema
        mapping = ops["properties"]["ops"]["items"]["discriminator"]["mapping"]
        for op in ("place_text", "remove_text"):
            self.assertIn(op, mapping)
        self.assertEqual((await self.call("list_texts", project_ref=self.ref))["data"], [])

        await self.call("apply_ops", project_ref=self.ref, expected_revision=self.opened["data"]["revision"],
                        operation_id="note", ops=[{"op": "place_text", "text": "Rev B", "x_mm": 5, "y_mm": 6}])
        texts = (await self.call("list_texts", project_ref=self.ref))["data"]
        self.assertEqual([t["text"] for t in texts], ["Rev B"])
        self.assertEqual(texts[0]["x_mm"], 5)
        self.assertFalse(texts[0]["from_smash"])

        # A font the schema does not know never reaches the engine.
        rejected = await server.mcp.call_tool("apply_ops", {
            "project_ref": self.ref, "expected_revision": (await self.call("project_files", project_ref=self.ref))["meta"]["revision"],
            "operation_id": "bad-font", "ops": [{"op": "place_text", "text": "x", "x_mm": 1, "y_mm": 1, "font": "comic"}]})
        self.assertTrue(rejected.is_error)

    async def test_a_project_can_be_started_and_a_document_saved(self):
        created = Path(self.temp.name) / "Fresh.horizontal"
        created_result = await server.mcp.call_tool("new_project", {"path": str(created), "name": "Fresh"})
        self.assertFalse(created_result.is_error, created_result.structured_content)
        summary = created_result.structured_content["data"]
        self.assertTrue(created.exists())
        self.assertEqual(summary["source"], "disk")
        self.assertTrue(summary["editable"])
        # It opens as a context of its own, usable straight away.
        self.assertEqual((await self.call("list_nets", project_ref=summary["project_ref"]))["data"], [])
        self.assertEqual(len((await self.call("list_sheets", project_ref=summary["project_ref"]))["data"]), 1)

        # It will not write over something that is already there.
        again = await server.mcp.call_tool("new_project", {"path": str(created)})
        self.assertTrue(again.is_error)

        # A disk context has nothing held back, and says so rather than failing.
        saved = (await self.call("save", project_ref=self.ref))["data"]
        self.assertFalse(saved["saved"])
        # Named distinctly from the live answer: "nothing was saved here" must
        # never read as "the document was saved".
        self.assertEqual(saved["source"], "disk")
        self.assertIn("live", saved["note"])

        tools = {t.name: t for t in await server.mcp.list_tools()}
        self.assertFalse(tools["save"].annotations.read_only_hint)
        self.assertFalse(tools["new_project"].annotations.read_only_hint)
        # Neither is an edit of an existing design, so neither takes a revision.
        self.assertNotIn("expected_revision", tools["save"].input_schema.get("required", []))

    async def test_every_write_has_a_read_that_names_what_it_wrote(self):
        tools = {t.name: t for t in await server.mcp.list_tools()}
        for name in ("list_symbols", "list_net_lines", "list_tracks", "list_vias"):
            self.assertTrue(tools[name].annotations.read_only_hint, name)

        # An empty project answers with shapes, not errors.
        self.assertEqual((await self.call("list_symbols", project_ref=self.ref))["data"], [])
        self.assertEqual((await self.call("list_net_lines", project_ref=self.ref))["data"], [])
        tracks = (await self.call("list_tracks", project_ref=self.ref))["data"]
        self.assertEqual((tracks["total"], tracks["truncated"], tracks["tracks"]), (0, False, []))
        self.assertEqual((await self.call("list_vias", project_ref=self.ref))["data"]["total"], 0)

        # The bounds are enforced where the tool advertises them.
        for bad in ({"limit": 0}, {"limit": 10_000}, {"layer": "top"}, {"net": "no-such-net"}):
            result = await server.mcp.call_tool("list_tracks", {"project_ref": self.ref, **bad})
            self.assertTrue(result.is_error, bad)

    async def test_routing_ops_are_typed_before_they_reach_the_engine(self):
        ops = {t.name: t for t in await server.mcp.list_tools()}["apply_ops"].input_schema
        mapping = ops["properties"]["ops"]["items"]["discriminator"]["mapping"]
        for op in ("place_track", "remove_track", "set_track_width", "place_via", "remove_via"):
            self.assertIn(op, mapping)
        listed = {op["op"] for op in (await self.call("list_ops", project_ref=self.ref))["data"]}
        self.assertTrue({"place_track", "place_via", "set_track_width"} <= listed, listed)

        # A track end is a pad, a junction or a point — never a mixture, and
        # never half of one. The schema says so before the engine is asked.
        revision = (await self.call("project_files", project_ref=self.ref))["meta"]["revision"]
        for end in ({"component": "R1"}, {"junction": "j", "x_mm": 1, "y_mm": 1}, {"x_mm": 1}, {}):
            result = await server.mcp.call_tool("apply_ops", {
                "project_ref": self.ref, "expected_revision": revision, "operation_id": str(uuid.uuid4()),
                "ops": [{"op": "place_track", "from": end, "to": {"x_mm": 2, "y_mm": 2},
                         "layer": 0, "width_mm": 0.2}]})
            self.assertTrue(result.is_error, end)

    async def test_labels_and_sheets_round_trip_through_the_typed_surface(self):
        current = (await self.call("project_files", project_ref=self.ref))["meta"]["revision"]
        await self.call("apply_ops", project_ref=self.ref, expected_revision=current, operation_id="page",
                        ops=[{"op": "ensure_net", "name": "VBUS"},
                             {"op": "add_sheet", "name": "Power"},
                             {"op": "place_net_label", "net": "VBUS", "x_mm": 10, "y_mm": 10},
                             {"op": "place_power_symbol", "net": "VBUS", "sheet": 2, "x_mm": 20, "y_mm": 20,
                              "style": "dot", "orientation": "up"}])

        sheets = (await self.call("list_sheets", project_ref=self.ref))["data"]
        self.assertEqual([s["name"] for s in sheets][-1], "Power")
        labels = (await self.call("list_net_labels", project_ref=self.ref))["data"]
        self.assertEqual([l["net_name"] for l in labels], ["VBUS"])
        power = (await self.call("list_power_symbols", project_ref=self.ref))["data"]
        self.assertEqual(power[0]["style"], "dot")
        self.assertEqual(power[0]["sheet_index"], 2)
        # A power symbol means the net is a power net.
        found = await server.mcp.call_tool("get_net", {"project_ref": self.ref, "name": "VBUS"})
        self.assertFalse(found.is_error, found.structured_content)
        self.assertTrue(found.structured_content["data"]["is_power"])

        # The schema rejects a style or orientation the engine does not have.
        after = (await self.call("project_files", project_ref=self.ref))["meta"]["revision"]
        for op in ({"op": "place_power_symbol", "net": "VBUS", "x_mm": 1, "y_mm": 1, "style": "squiggle"},
                   {"op": "place_net_label", "net": "VBUS", "x_mm": 1, "y_mm": 1, "orientation": "sideways"},
                   {"op": "add_sheet"}):
            result = await server.mcp.call_tool("apply_ops", {
                "project_ref": self.ref, "expected_revision": after,
                "operation_id": str(uuid.uuid4()), "ops": [op]})
            self.assertTrue(result.is_error, op)

    async def test_board_shape_rules_and_pool_reads(self):
        tools = {t.name: t for t in await server.mcp.list_tools()}
        for name in ("list_planes", "list_polygons", "board_rules", "get_pool_item"):
            self.assertTrue(tools[name].annotations.read_only_hint, name)
        self.assertFalse(tools["pour_planes"].annotations.read_only_hint)
        self.assertIn("expected_revision", tools["pour_planes"].input_schema["required"])

        # A fresh board has no shape and no rules, and says so rather than
        # implying it is ready.
        rules = (await self.call("board_rules", project_ref=self.ref))["data"]
        self.assertEqual(rules["rules"], [])
        self.assertIn("no rules", rules["note"])
        self.assertEqual((await self.call("list_polygons", project_ref=self.ref))["data"], [])
        self.assertEqual((await self.call("list_planes", project_ref=self.ref))["data"], [])

        current = (await self.call("project_files", project_ref=self.ref))["meta"]["revision"]
        await self.call("apply_ops", project_ref=self.ref, expected_revision=current, operation_id="outline",
                        ops=[{"op": "place_polygon", "layer": 100,
                              "vertices": [{"x_mm": 0, "y_mm": 0}, {"x_mm": 30, "y_mm": 0},
                                           {"x_mm": 30, "y_mm": 20}, {"x_mm": 0, "y_mm": 20}]}])
        polygons = (await self.call("list_polygons", project_ref=self.ref))["data"]
        self.assertTrue(polygons[0]["is_board_outline"])
        self.assertEqual(len(polygons[0]["vertices"]), 4)

        # Fewer than three points is not a shape; the schema says so first.
        after = (await self.call("project_files", project_ref=self.ref))["meta"]["revision"]
        bad = await server.mcp.call_tool("apply_ops", {
            "project_ref": self.ref, "expected_revision": after, "operation_id": str(uuid.uuid4()),
            "ops": [{"op": "place_polygon", "layer": 100, "vertices": [{"x_mm": 0, "y_mm": 0}]}]})
        self.assertTrue(bad.is_error)

        # Pouring a board with no planes is not an error.
        poured = (await self.call("pour_planes", project_ref=self.ref, expected_revision=after,
                                  operation_id=str(uuid.uuid4())))["data"]
        self.assertEqual(poured["poured"], 0)

    async def test_hierarchy_stackup_and_autoroute_are_advertised(self):
        tools = {t.name: t for t in await server.mcp.list_tools()}
        self.assertTrue(tools["list_block_instances"].annotations.read_only_hint)
        self.assertFalse(tools["autoroute"].annotations.read_only_hint)
        self.assertIn("expected_revision", tools["autoroute"].input_schema["required"])
        mapping = tools["apply_ops"].input_schema["properties"]["ops"]["items"]["discriminator"]["mapping"]
        for op in ("add_block_instance", "connect_block_port", "place_block_symbol", "set_stackup"):
            self.assertIn(op, mapping)

        # A single-block project has nothing to compose, and says so.
        self.assertEqual((await self.call("list_block_instances", project_ref=self.ref))["data"], [])

        current = (await self.call("project_files", project_ref=self.ref))["meta"]["revision"]
        stacked = await self.call("apply_ops", project_ref=self.ref, expected_revision=current,
                                  operation_id="stack", ops=[{"op": "set_stackup", "inner_layers": 2}])
        self.assertEqual(stacked["data"]["changes"][0]["copper_layers"], 4)
        info = (await self.call("board_info", project_ref=self.ref))["data"]
        self.assertEqual(len(info["stackup"]), 4)

        # An inner-layer count the schema rejects never reaches the engine.
        after = (await self.call("project_files", project_ref=self.ref))["meta"]["revision"]
        bad = await server.mcp.call_tool("apply_ops", {
            "project_ref": self.ref, "expected_revision": after, "operation_id": str(uuid.uuid4()),
            "ops": [{"op": "set_stackup", "inner_layers": 99}]})
        self.assertTrue(bad.is_error)

        # Autorouting a net with no airwires is refused rather than reported as
        # a success that did nothing.
        nothing = await server.mcp.call_tool("autoroute", {
            "project_ref": self.ref, "net": "nope", "expected_revision": after,
            "operation_id": str(uuid.uuid4())})
        self.assertTrue(nothing.is_error)

    async def test_worker_restart_rebinds_a_disk_read(self):
        project = server._projects[self.ref]
        before = project.summary["instance_id"]
        project.session.transport._process.kill()
        project.session.transport._process.wait(timeout=2)
        result = await self.call("list_nets", project_ref=self.ref)
        self.assertEqual(result["data"], [])
        self.assertEqual(result["meta"]["source"], "disk")
        self.assertNotEqual(result["meta"]["instance_id"], before)


if __name__ == "__main__": unittest.main()
