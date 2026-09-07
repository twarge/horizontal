"""An MCP server over the Python bindings, for Claude Code and other clients.

Run it with `horizontal-mcp` (stdio). Every tool takes the project path; set
HORIZONTAL_PROJECT to make it optional. Projects stay open between calls.
"""

from __future__ import annotations

import functools
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import Image, MCPServer
from mcp.server.mcpserver.exceptions import ToolError

from ._native import HorizontalError
from .client import Project, Session, open as open_any

mcp = MCPServer(
    name="horizontal",
    instructions=(
        "Reads Horizon EDA projects (.hprj, .horizontal) through Horizontal's own model. "
        "Call open_project first, or set HORIZONTAL_PROJECT; then query components, nets, the netlist, "
        "the BOM, run checks, export fabrication files, and render sheets or the board as images."
    ),
)

_session: Session | None = None
_projects: dict[str, Project] = {}


def _get_session() -> Session:
    global _session
    if _session is None:
        _session = Session(isolated=os.environ.get("HORIZONTAL_ISOLATED") == "1")
    return _session


def _tool(fn: Callable[..., Any]) -> Callable[..., Any]:
    """Registers `fn` as a tool and turns engine errors into messages the client sees."""

    @functools.wraps(fn)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        try:
            return fn(*args, **kwargs)
        except (HorizontalError, ValueError, OSError) as error:
            raise ToolError(str(error)) from error

    return mcp.tool()(wrapper)


def _resolve(path: str | None) -> Project:
    if not path:
        path = os.environ.get("HORIZONTAL_PROJECT")
    if not path:
        if len(_projects) == 1:
            return next(iter(_projects.values()))
        raise ValueError("Pass a project path, or set HORIZONTAL_PROJECT.")
    key = str(Path(path).expanduser().resolve())
    project = _projects.get(key)
    if project is None or (not project.is_live and _live_has(key)):
        # Prefer the app's open document when it has this project, so reads
        # see unsaved edits and writes are undoable there.
        project = open_any(key, isolated=os.environ.get("HORIZONTAL_ISOLATED") == "1")
        _projects[key] = project
    return project


def _live_has(key: str) -> bool:
    live = Session.live()
    if live is None:
        return False
    try:
        return any(s.get("live") and Path(s["path"]).resolve() == Path(key) for s in live.call("list_projects"))
    except Exception:
        return False
    finally:
        live.close()


@_tool
def open_project(path: str) -> dict[str, Any]:
    """Open a Horizon project (.hprj file or .horizontal package) and return its summary: blocks, sheets, counts, diagnostics."""
    return _resolve(path).info()


@_tool
def reload_project(path: str | None = None) -> dict[str, Any]:
    """Re-read the project from disk after it changed."""
    return _resolve(path).reload()


@_tool
def project_files(path: str | None = None) -> dict[str, Any]:
    """The files that make up the project on disk."""
    return _resolve(path).files()


@_tool
def list_sheets(path: str | None = None) -> list[dict[str, Any]]:
    """Schematic sheets in page order."""
    return _resolve(path).sheets()


@_tool
def list_components(path: str | None = None, sheet: int | None = None) -> list[dict[str, Any]]:
    """Every component with refdes, value, MPN, package, and where it is placed. Optionally only those with a symbol on one sheet."""
    return _resolve(path).components(sheet=sheet)


@_tool
def get_component(refdes: str, path: str | None = None) -> dict[str, Any]:
    """One component in full: every pin with its net, symbol placements, board placement, part details."""
    return _resolve(path).component(refdes=refdes)


@_tool
def list_nets(path: str | None = None) -> list[dict[str, Any]]:
    """Every net with its class, power/port flags, pin count, and routing counts."""
    return _resolve(path).nets()


@_tool
def get_net(name: str, path: str | None = None) -> dict[str, Any]:
    """One net in full: the pins on it and how much of it is routed."""
    return _resolve(path).net(name=name)


@_tool
def netlist(path: str | None = None, include_unconnected: bool = False) -> dict[str, Any]:
    """The whole netlist: every net with its pins. Large; prefer get_net for one net."""
    return _resolve(path).netlist(include_unconnected=include_unconnected)


@_tool
def bom(path: str | None = None, include_no_populate: bool = True) -> dict[str, Any]:
    """Bill of materials grouped by part, as the BOM exporter groups it."""
    return _resolve(path).bom(include_no_populate=include_no_populate)


@_tool
def list_parts(path: str | None = None) -> list[dict[str, Any]]:
    """Parts available in the project pool."""
    return _resolve(path).parts()


@_tool
def board_info(path: str | None = None) -> dict[str, Any]:
    """Board size, stackup, drawing layers, and object counts."""
    return _resolve(path).board_info()


@_tool
def check(path: str | None = None) -> dict[str, Any]:
    """Run the checks Horizontal has: load diagnostics, rules validation, annotation, single-pin nets, unplaced parts, unrouted connections."""
    return _resolve(path).check()


@_tool
def export(sections: list[str], path: str | None = None, target_directory: str | None = None) -> dict[str, Any]:
    """Run the app's exporters. Sections: schematic_pdf, bom, gerber, odb, pick_and_place, board_step, board_drawing, board_dxf. Writes files; the target must be outside the project package."""
    return _resolve(path).export(sections, target_directory=target_directory)


@_tool
def live_state() -> list[dict[str, Any]]:
    """Documents open in Horizontal right now, with their selection and highlight. Empty when the app is not running."""
    live = Session.live()
    if live is None:
        return []
    try:
        return live.live_state()
    finally:
        live.close()


@_tool
def highlight(path: str | None = None, components: list[str] | None = None, nets: list[str] | None = None) -> dict[str, Any]:
    """Highlight components (refdes) and nets (names) in the app's canvases; empty lists clear. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is nothing to highlight.")
    return project.highlight(components=components, nets=nets)


@_tool
def select(path: str | None = None, components: list[str] | None = None, nets: list[str] | None = None) -> dict[str, Any]:
    """Select components (refdes) and nets (names) in the app. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is nothing to select.")
    return project.select(components=components, nets=nets)


@_tool
def list_ops(path: str | None = None) -> list[dict[str, Any]]:
    """The edit operations apply_ops accepts, with their parameters."""
    return _resolve(path).list_ops()


@_tool
def apply_ops(ops: list[dict[str, Any]], path: str | None = None, dry_run: bool = False) -> dict[str, Any]:
    """Apply edit operations. Each op is {"op": name, ...params}; see list_ops. Components and nets may be named by refdes or net name. When the project is open in Horizontal the edit lands there as one undoable step; otherwise the files are written and reloaded. dry_run validates without changing anything."""
    return _resolve(path).apply(ops, dry_run=dry_run)


@_tool
def set_component_value(refdes: str, value: str, path: str | None = None) -> dict[str, Any]:
    """Set a component's value and write the project."""
    return _resolve(path).set_value(refdes, value)


@_tool
def rename_net(net: str, name: str, path: str | None = None) -> dict[str, Any]:
    """Rename a net and write the project."""
    return _resolve(path).rename_net(net, name)


@_tool
def connect_pin(refdes: str, pin: str, net: str, path: str | None = None, create_net: bool = False) -> dict[str, Any]:
    """Connect a component pin (pin name, or gate/pin) to a net and write the project."""
    return _resolve(path).connect(refdes, pin, net, create_net=create_net)


@_tool
def place_component(refdes: str, path: str | None = None, x_mm: float | None = None, y_mm: float | None = None, angle_deg: float | None = None, bottom: bool | None = None) -> dict[str, Any]:
    """Place a component's package on the board, or move or rotate it if it is already placed."""
    return _resolve(path).place(refdes, x_mm=x_mm, y_mm=y_mm, angle_deg=angle_deg, bottom=bottom)


@_tool
def render_sheet(path: str | None = None, sheet: int | None = None, name: str | None = None, region: dict[str, float] | None = None, dpi: float = 110) -> Image:
    """Render one schematic sheet as a PNG image (by index or name; default the first sheet). region {min_x_mm, min_y_mm, max_x_mm, max_y_mm} renders only that part, at higher effective detail."""
    png = _resolve(path).render_sheet(sheet=sheet, name=name, region=region, dpi=dpi, max_pixels=2400)
    assert isinstance(png, bytes)
    return Image(data=png, format="png")


@_tool
def render_board(path: str | None = None, layers: list[str] | None = None, mirrored: bool = False, region: dict[str, float] | None = None, dpi: float = 110) -> Image:
    """Render the board drawing as a PNG image. Pass layer names from board_info to choose layers; mirrored views it from the bottom; region {min_x_mm, min_y_mm, max_x_mm, max_y_mm} renders only that part."""
    png = _resolve(path).render_board(layers=layers, mirrored=mirrored, region=region, dpi=dpi, max_pixels=2400)
    assert isinstance(png, bytes)
    return Image(data=png, format="png")


@_tool
def zoom_to(path: str | None = None, refdes: str | None = None, net: str | None = None, pane: str | None = None, margin_mm: float = 3) -> dict[str, Any]:
    """Frame a component (refdes) or a net in the app's board or schematic pane. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is no pane to zoom.")
    return project.zoom_to(refdes=refdes, net=net, pane=pane, margin_mm=margin_mm)


@_tool
def render_viewport(path: str | None = None, pane: str = "board", dpi: float = 110) -> Image:
    """Render what the app's board or schematic pane currently shows, as a PNG in the exporter's drawing style. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is no viewport to render.")
    png = project.render_viewport(pane=pane, dpi=dpi, max_pixels=2400)
    assert isinstance(png, bytes)
    return Image(data=png, format="png")


@_tool
def list_groups(path: str | None = None) -> list[dict[str, Any]]:
    """Horizon groups (instances of a sub-circuit, e.g. an atopile module) with their members by tag and whether each is placed."""
    return _resolve(path).groups()


@_tool
def copy_group_layout(source: str, target: str, path: str | None = None, x_mm: float | None = None, y_mm: float | None = None, angle_deg: float | None = None, include_routing: bool = True) -> dict[str, Any]:
    """Lay out the target group like the source group: every member with a matching tag is placed at the same relative position and rotation, and by default the tracks and vias between the source's members are copied too. The target's anchor stays where it already is unless x_mm and y_mm are given."""
    return _resolve(path).copy_group_layout(source, target, x_mm=x_mm, y_mm=y_mm, angle_deg=angle_deg, include_routing=include_routing)


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
