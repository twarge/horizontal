"""The Claude Code plugin and marketplace that ship this package, and the skills in it."""

import json
import re
import tomllib
import unittest
from pathlib import Path

from horizontal import mcp_server as server

PACKAGE = Path(__file__).resolve().parents[1]
REPOSITORY = PACKAGE.parent
IDENTIFIER = re.compile(r"`([a-z][a-z0-9]*(?:_[a-z0-9]+)+)`")


def frontmatter(text: str) -> dict[str, str]:
    match = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not match:
        return {}
    return dict(line.split(": ", 1) for line in match.group(1).splitlines() if ": " in line)


class PluginTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.marketplace = json.loads((REPOSITORY / ".claude-plugin" / "marketplace.json").read_text())
        self.manifest = json.loads((PACKAGE / ".claude-plugin" / "plugin.json").read_text())
        self.pyproject = tomllib.loads((PACKAGE / "pyproject.toml").read_text())

    def test_marketplace_lists_this_package_as_the_plugin(self):
        entry = next(p for p in self.marketplace["plugins"] if p["name"] == self.manifest["name"])
        self.assertEqual((REPOSITORY / entry["source"]).resolve(), PACKAGE)

    def test_plugin_version_follows_the_package(self):
        # Setting version pins users to it, so it moves with the package it runs.
        self.assertEqual(self.manifest["version"], self.pyproject["project"]["version"])

    def test_server_runs_the_package_script_from_the_installed_plugin(self):
        server_config = self.manifest["mcpServers"]["horizontal"]
        self.assertIn("horizontal-mcp", server_config["args"])
        self.assertIn("horizontal-mcp", self.pyproject["project"]["scripts"])
        root = server_config["args"][server_config["args"].index("--project") + 1]
        self.assertEqual(root, "${CLAUDE_PLUGIN_ROOT}")
        self.assertTrue(server_config["env"]["UV_PROJECT_ENVIRONMENT"].startswith("${CLAUDE_PLUGIN_DATA}"))

    def test_skills_have_names_and_descriptions(self):
        skills = sorted((PACKAGE / "skills").glob("*/SKILL.md"))
        self.assertTrue(skills)
        for skill in skills:
            meta = frontmatter(skill.read_text())
            self.assertEqual(meta.get("name"), skill.parent.name, skill)
            self.assertTrue(20 < len(meta.get("description", "")) <= 1024, skill)

    async def test_skills_name_only_tools_ops_and_fields_that_exist(self):
        tools = await server.mcp.list_tools()
        known = {tool.name for tool in tools}
        apply_ops = next(tool for tool in tools if tool.name == "apply_ops").input_schema
        known |= set(apply_ops["properties"]["ops"]["items"]["discriminator"]["mapping"])

        def properties(schema):
            if isinstance(schema, dict):
                for key, value in schema.items():
                    if key == "properties" and isinstance(value, dict):
                        known.update(value)
                    properties(value)
            elif isinstance(schema, list):
                for value in schema:
                    properties(value)

        for tool in tools:
            properties(tool.input_schema)
            known |= set(re.findall(r"[a-z][a-z0-9_]+", tool.description or ""))
        # Reply fields the skills tell Claude to read are fields of the result models,
        # or of the engine's own project summary, which the Python side passes through.
        known |= set(re.findall(r"[a-z][a-z0-9_]+", (PACKAGE / "horizontal" / "schemas.py").read_text()))
        known |= {"unsaved_changes"}

        for skill in sorted((PACKAGE / "skills").glob("*/SKILL.md")):
            unknown = set(IDENTIFIER.findall(skill.read_text())) - known
            self.assertFalse(unknown, f"{skill.parent.name} names {sorted(unknown)}, which the server does not have")


if __name__ == "__main__":
    unittest.main()
