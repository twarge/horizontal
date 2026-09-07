"""Exercise the MCP wire protocol, including structured error and image results."""
import os
import tempfile
import unittest
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from horizontal.client import Session
from horizontal._native import SubprocessTransport


class StdioTests(unittest.IsolatedAsyncioTestCase):
    async def test_stdio_contract(self):
        import sys
        cli = Path(__file__).resolve().parents[2] / ".build/debug/horizontal"
        with tempfile.TemporaryDirectory() as directory:
            project_path = Path(directory) / "Test.horizontal"
            native = Session(transport=SubprocessTransport(cli))
            try: native.new_project(project_path)
            finally: native.close()
            params = StdioServerParameters(command=sys.executable, args=["-m", "horizontal.mcp_server"], env={**os.environ, "HORIZONTAL_CLI": str(cli)})
            async with stdio_client(params) as (reader, writer):
                async with ClientSession(reader, writer) as client:
                    await client.initialize()
                    listed = await client.list_tools()
                    self.assertIn("analyze_adc_filter", {tool.name for tool in listed.tools})
                    opened = await client.call_tool("open_project", {"path": str(project_path), "source": "disk"})
                    self.assertFalse(opened.is_error, opened.content)
                    ref = opened.structured_content["data"]["project_ref"]
                    missing = await client.call_tool("list_components", {"project_ref": ref, "sheet": 999})
                    self.assertTrue(missing.is_error)
                    self.assertEqual(missing.structured_content["error"]["code"], "NOT_FOUND")
                    rendered = await client.call_tool("render_sheet", {"project_ref": ref, "sheet": 1})
                    self.assertFalse(rendered.is_error)
                    self.assertTrue(any(item.type == "image" for item in rendered.content))
                    self.assertEqual(rendered.structured_content["meta"]["snapshot_id"], opened.structured_content["meta"]["snapshot_id"])
