# Claude Code

The `horizontal` plugin gives Claude Code Horizontal's MCP server and a set of
skills for working on Horizon EDA projects. With it, Claude can:

- read the documents you have open,
- review designs,
- make edits that land as undoable steps,
- export fabrication files.

## Install

Install [uv](https://docs.astral.sh/uv/) (`brew install uv`), then in a
terminal (without uv the server runs on any Python 3.11 or later it finds,
such as `brew install python@3.13`; macOS's own `/usr/bin/python3` is 3.9):

    claude plugin marketplace add twarge/horizontal
    claude plugin install horizontal@twarge

Or, in a Claude Code session:

    /plugin install horizontal --marketplace twarge/horizontal

Start a new session afterwards; MCP servers load when a session starts.
Settings > AI Agent Access in Horizontal shows the same commands with a Copy button;
choose Claude Code in the client picker. Codex uses the same server and skills
with its own plugin packaging; see [codex.md](codex.md).

In Horizontal:

1. Turn on **Settings > AI Agent Access > Enable MCP Server**. Without it, Claude
   can read and write project files on disk, but cannot see or change what is
   open in the app.
2. Open your project, as a `.horizontal` package or from its `.hprj`. The app
   publishes its endpoint in its per-user cache folder, and that is how the
   server finds it; connecting needs no access to the project's folder.

If you registered the server by hand before (`claude mcp add … horizontal`),
remove that entry. A user- or project-scope server with the same name takes
precedence over the plugin's:

    claude mcp remove horizontal -s user

## What it adds

**The `horizontal` MCP server.** About 80 tools over Horizontal's own model:

- projects, components, nets, the netlist and the BOM;
- checks;
- rendering sheets and the board to images;
- the edit vocabulary (`apply_ops`, `remap_part`, pool imports, placement,
  manual routing);
- exports and analyses.

[automation.md](automation.md) describes the methods and the live channel.

**Skills.** Claude loads each one when a task calls for it. You can also run
them directly:

| Skill | For |
|---|---|
| `/horizontal:connect` | Getting connected, and reading connection errors |
| `/horizontal:review` | Design reviews that trace intent, check datasheets and put numbers on findings |
| `/horizontal:edit` | The edit protocol: dry runs, part swaps, schematic wiring, copper on changed pads, verifying, saving |
| `/horizontal:fab-outputs` | Exporting and checking Gerbers, ODB++, BOM, pick-and-place, PDFs and STEP |

## Live and disk

When Horizontal has the project open, the server works on that document.

- Reads see unsaved edits.
- Each edit is one step on the app's undo stack.
- The document autosaves those edits in place, as it does yours. Claude calls
  `save` before committing or exporting, so the files are complete and
  verified at that moment.
- The open document doesn't notice its files changing on disk. Close the
  project before a git `checkout`, `pull`, `stash` or `reset` that touches it,
  or its next autosave writes the old copy back.

With the project closed, the server works on the files directly. That needs
the native engine (`libHorizontalPy.dylib` or the `horizontal` command line
tool), which the App Store app does not provide. Build it from a source
checkout with `make native`, or set `HORIZONTAL_DYLIB` / `HORIZONTAL_CLI`.

## Updating

    claude plugin marketplace update twarge

The plugin's `version` pins installs until it changes. It follows the Python
package's version, so a release bumps `version` in `python/pyproject.toml`,
`python/plugin.json`, `python/.claude-plugin/plugin.json` and the root package
entry in `python/uv.lock` together. A test enforces that.

## Developing the plugin

- **Layout.**
  - The marketplace is `.claude-plugin/marketplace.json` at the repository
    root.
  - The plugin is rooted at `python/`. An installed copy carries the server's
    source and `uv.lock`, so the server and the skills always come from the
    same commit.
  - The manifest's server entry runs the launcher, `bin/horizontal-mcp`,
    which both clients share. With uv it runs `uv run --python 3.13 --frozen
    --project <plugin root> horizontal-mcp`: uv downloads Python 3.13 if
    necessary, avoiding dependency builds against the newest installed
    Python. Its virtual environment lives in `${CLAUDE_PLUGIN_DATA}`, which
    survives updates.
  - Without uv the launcher uses the first Python 3.11 or later it finds,
    makes a virtual environment beside uv's (`venv-pip`) and installs with
    pip, from `pyproject.toml`'s ranges, not `uv.lock`. It looks for uv and
    Python in Homebrew's and `~/.local/bin` as well as `PATH`, which a client
    started from the Dock doesn't have.
- **Trying changes.** Use `claude --plugin-dir ./python`, or add the checkout
  as a local marketplace (`claude plugin marketplace add ./`). A local
  marketplace reads the plugin in place.
- **Validating.** Run `claude plugin validate ./python` and
  `claude plugin validate .`.
- **Tests.** `make python-test` includes `tests/test_plugin.py`. It checks:
  - the manifests;
  - the version;
  - that every tool, op and field a skill names exists in the server.
- **The development server.** Inside this repository, the root `.mcp.json`
  runs the checkout's server against the checkout's `.build/`. As a project
  server it takes precedence over the plugin's.

[mcp-app-store-study.md](mcp-app-store-study.md) covers how the server could
ship inside the sandboxed app instead (`Horizontal --mcp`), and why that comes
later.
