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
