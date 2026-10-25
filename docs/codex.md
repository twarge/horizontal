# Codex

The Horizontal plugin gives Codex the local MCP server and skills for connecting,
reviewing designs, making undoable edits, and exporting fabrication files.
Install it once; Codex can then select the appropriate skill for a request such
as “Review my board in Horizontal”. It runs on the Mac with Horizontal, not in a
cloud-only session.

## Install

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) and the
[Codex command-line tool](https://developers.openai.com/codex/cli/), then run:

```sh
codex plugin marketplace add twarge/horizontal
codex plugin add horizontal@twarge
```

In Horizontal:

1. Turn on **Settings > MCP Server > Enable MCP Server**.
2. Open your project and grant Horizontal access to its containing folder when
   asked. Open a Horizon project from its `.hprj`; the app's Grant Access action
   grants folder access for a `.horizontal` package too.
3. Start a new Codex chat and ask it to connect to your project in Horizontal.
   Include the project location if it cannot find the document by name.

Settings has these same installation commands with a Copy button. If your Codex
version offers installation in the Plugins directory, choose the **Horizontal**
marketplace and install **Horizontal** there. The plugin's setup action runs the
included connection skill; it checks the connection without editing the board.

The launcher uses Python 3.13, which uv downloads if needed, and installs locked
dependencies into the plugin's data directory. This first start needs network
access and can take longer than later connections. If it times out, run the
plugin's setup skill to finish installation, then restart the connection.
The app must be running with the project
open for live mode. Installing the plugin does not turn on the app's MCP switch
or grant it access to project folders.

If a manually configured `horizontal` server points to an old checkout, inspect
it with `codex mcp list`. To replace that entry with the plugin, remove it with
`codex mcp remove horizontal`, then start a new chat. Do not register both copies.

## What Codex learns

The plugin bundles the server and four shared skills:

| Skill | Use |
|---|---|
| `connect` | Onboarding, project discovery and connection troubleshooting |
| `review` | Circuit and board reviews backed by model data and datasheets |
| `edit` | Dry runs, revision checks, undoable edits and verification |
| `fab-outputs` | Fabrication and documentation exports |

The MCP server also sends essential live-connection and edit instructions during
initialization. The skills and server ship together; the plugin needs no personal
checkout paths or separately installed skills.

Live reads include unsaved work. Live edits are undoable and autosaved. Disk mode
for closed projects additionally needs the native CLI or library, built from
source with `make native` or selected through `HORIZONTAL_CLI` / `HORIZONTAL_DYLIB`.
The App Store app alone supports live mode. See [automation.md](automation.md).

## Connection troubleshooting

Run the plugin's connection skill. It checks `connection_status`, then
`live_state` with the project path, and opens the document with `source: "live"`.
An unreadable discovery file inside the app's private container is expected;
the holder record beside the project is another discovery route. Check the MCP
switch and project-folder access before changing macOS privacy settings.

If `uv` or `codex` is not found, install the missing command-line tool. Restart
the desktop client after installing tools so it sees the updated environment.

## Updating and developing

```sh
codex plugin marketplace upgrade twarge
codex plugin add horizontal@twarge
```

Start a new chat after an update. For changes not yet pushed, use the local
checkout as the marketplace:

```sh
codex plugin marketplace add /absolute/path/to/horizontal
codex plugin add horizontal@twarge
```

Use `codex plugin marketplace list` to check which source named `twarge` is
registered; local and remote examples are alternatives. Tests can set
`CODEX_HOME` to a temporary directory to avoid changing a user's installation.

The repo catalog is `.agents/plugins/marketplace.json`; its `./python` path is
relative to the repository root. `python/plugin.json` is the portable manifest,
`python/mcp.json` launches the server using `${PLUGIN_ROOT}`, and
`${PLUGIN_DATA}/venv` keeps its environment outside the installed source.
Both client manifests request the same Python version to avoid compiling
dependencies against a newly released interpreter during connection startup.
Claude Code retains its own compatibility manifest and marketplace, sharing the
same server and skills. Bump both manifests, `pyproject.toml` and the root package
entry in `uv.lock` together for a release. `tests/test_plugin.py` checks the
packaging and the tools named by the skills.

This repository marketplace is independent of the public OpenAI Plugin Directory.
Public submission of a local MCP plugin currently requires approved-partner
access; see the [desktop-only submission guide](https://developers.openai.com/plugins/deploy/desktop-only).
