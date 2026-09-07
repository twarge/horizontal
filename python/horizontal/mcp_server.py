"""An MCP server over the Python bindings, for Claude Code and other clients.

Run it with `horizontal-mcp` (stdio). Every tool takes the project path; set
HORIZONTAL_PROJECT to make it optional. Projects stay open between calls.
"""

from __future__ import annotations

import functools
import inspect
import json
import time
import uuid
import atexit
import importlib.metadata
import logging
import hashlib
import threading
from contextvars import ContextVar
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any, Literal, get_type_hints

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError, UnexpectedToolError
from mcp.types import CallToolResult, TextContent, ImageContent, ToolAnnotations
from pydantic import BaseModel, ValidationError

from ._native import HorizontalError, find_live, find_cli, find_dylib, LiveTransport, transport_error
from .client import Project, Session, open as open_any, _request_deadline
from .schemas import (Result, ProjectInfo, Component, Net, Sheet, EditResult, Region, RenderedImage, EditOperation,
                      PinnedSnapshot, AnalysisValidation, AnalysisJob)
from .analysis import Scenario, Setup, validate as validate_circuit
from .analysis_jobs import AnalysisJobs

class TypedMCPServer(MCPServer):
    async def call_tool(self, name, arguments, context=None):
        deadline_token = _request_deadline.set(time.monotonic() + 30)
        try:
            return await super().call_tool(name, arguments, context)
        except ToolError as error:
            if isinstance(error, UnexpectedToolError): logging.getLogger(__name__).exception("Unexpected tool failure: %s", name)
            failure = {"code": "ENGINE_ERROR" if isinstance(error, UnexpectedToolError) else "INVALID_ARGUMENT",
                       "message": str(error), "retryable": False, "outcome": "unknown" if isinstance(error, UnexpectedToolError) else "not_committed", "details": {}}
            return CallToolResult(content=[TextContent(type="text", text=json.dumps({"error": failure}))], structured_content={"error": failure}, is_error=True)
        finally:
            _request_deadline.reset(deadline_token)


mcp = TypedMCPServer(
    name="horizontal",
    instructions=(
        "Reads Horizon EDA projects (.hprj, .horizontal) through Horizontal's own model. "
        "Call open_project first, or set HORIZONTAL_PROJECT; then query components, nets, the netlist, "
        "the BOM, run checks, export fabrication files, and render sheets or the board as images."
    ),
)

_projects: dict[str, Project] = {}
_active_project: ContextVar[Project | None] = ContextVar("horizontal_project", default=None)
_edit_options: ContextVar[dict[str, Any]] = ContextVar("horizontal_edit", default={})
_mutations = {"apply_ops", "set_component_value", "rename_net", "connect_pin", "place_component", "copy_group_layout"}
_snapshots: dict[str, dict[str, Any]] = {}
_jobs = AnalysisJobs()
_tool_lock = threading.RLock()


def _tool(fn: Callable[..., Any]) -> Callable[..., Any]:
    """Registers `fn` as a tool and turns engine errors into messages the client sees."""

    hints = get_type_hints(fn, include_extras=True)
    result_type = {"open_project": ProjectInfo, "reload_project": ProjectInfo,
                   "analysis_snapshot": PinnedSnapshot, "validate_analysis": AnalysisValidation,
                   **{name: AnalysisJob for name in ("analyze_transfer", "analyze_noise", "analyze_headroom", "analyze_adc_filter", "analysis_result", "cancel_analysis")},
                   "list_components": list[Component], "get_component": Component,
                   "list_nets": list[Net], "get_net": Net, "list_sheets": list[Sheet],
                   **{name: EditResult for name in _mutations},
                   **{name: RenderedImage for name in ("render_sheet", "render_board", "render_viewport")}}.get(fn.__name__, hints.get("return", Any))
    output = Result[result_type]
    @functools.wraps(fn)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        token = _active_project.set(None)
        edit_token = _edit_options.set({})
        locked = False
        try:
            deadline = _request_deadline.get() or (time.monotonic() + 30)
            locked = _tool_lock.acquire(timeout=max(0, deadline - time.monotonic()))
            if not locked or time.monotonic() >= deadline:
                raise transport_error("TIMEOUT", "Request expired waiting for the MCP context lock")
            ref = kwargs.pop("project_ref", None)
            if ref is not None:
                if ref not in _projects: raise ValueError("Unknown project_ref; open the project first.")
                _active_project.set(_projects[ref])
            if fn.__name__ in _mutations:
                options = {key: kwargs.pop(key, None) for key in ("expected_revision", "operation_id", "plan_digest")}
                _edit_options.set({key: value for key, value in options.items() if value is not None})
            value = fn(*args, **kwargs)
            project = _active_project.get()
            meta = dict(project.last_metadata) if project else None
            if project and meta is not None:
                meta["project_ref"] = next((key for key, p in _projects.items() if p is project), None)
            if isinstance(value, dict) and "png_base64" in value:
                data = {key: v for key, v in value.items() if key != "png_base64"}
                structured = output(data=data, meta=meta).model_dump(mode="json", exclude_none=True)
                return CallToolResult(content=[ImageContent(type="image", data=value["png_base64"], mime_type="image/png"),
                                                TextContent(type="text", text=json.dumps(structured))], structured_content=structured)
            return output(data=value, meta=meta)
        except (HorizontalError, ValueError, OSError) as error:
            failure = error.structured() if isinstance(error, HorizontalError) else {
                "code": "ENGINE_ERROR" if isinstance(error, ValidationError) else "INVALID_ARGUMENT" if isinstance(error, ValueError) else "IO_ERROR",
                "message": str(error), "retryable": False, "outcome": "not_committed", "details": {}}
            return CallToolResult(content=[TextContent(type="text", text=json.dumps({"error": failure}))],
                                  structured_content={"error": failure}, is_error=True)
        finally:
            if locked: _tool_lock.release()
            _active_project.reset(token)
            _edit_options.reset(edit_token)

    signature = inspect.signature(fn)
    parameters = [p.replace(annotation=hints.get(p.name, p.annotation)) for p in signature.parameters.values()]
    if "path" in signature.parameters and fn.__name__ != "open_project":
        parameters.append(inspect.Parameter("project_ref", inspect.Parameter.KEYWORD_ONLY, default=None, annotation=str | None))
    if fn.__name__ in _mutations:
        parameters += [inspect.Parameter("expected_revision", inspect.Parameter.KEYWORD_ONLY, annotation=str),
                       inspect.Parameter("operation_id", inspect.Parameter.KEYWORD_ONLY, annotation=str),
                       inspect.Parameter("plan_digest", inspect.Parameter.KEYWORD_ONLY, default=None, annotation=str | None)]
    wrapper.__signature__ = signature.replace(parameters=parameters, return_annotation=output)
    wrapper.__annotations__ = {p.name: p.annotation for p in parameters} | {"return": output}
    resource_writes = {"open_project", "reload_project", "analysis_snapshot", "release_analysis_snapshot", "analyze_transfer", "analyze_noise", "analyze_headroom", "analyze_adc_filter", "cancel_analysis", "discard_analysis"}
    registered = mcp.tool(annotations=ToolAnnotations(read_only_hint=fn.__name__ not in _mutations | resource_writes | {"export", "highlight", "select", "zoom_to", "close_project", "export_analysis"},
                                               destructive_hint=fn.__name__ in _mutations,
                                               idempotent_hint=fn.__name__ not in _mutations | resource_writes | {"export_analysis"},
                                               open_world_hint=False))(wrapper)
    # SDK 2.1 generates an argument model. Make its outer object as strict as our
    # nested Input models; contract tests cover this narrow SDK integration seam.
    tool = mcp._tool_manager.get_tool(fn.__name__)
    tool.fn_metadata.arg_model.model_config.update(extra="forbid", strict=True)
    tool.fn_metadata.arg_model.model_rebuild(force=True)
    tool.parameters = tool.fn_metadata.arg_model.model_json_schema()
    return registered


def _resolve(path: str | None) -> Project:
    selected = _active_project.get()
    if selected is not None:
        if path and Path(path).expanduser().resolve() != Path(selected.path).resolve():
            raise ValueError("path and project_ref refer to different projects.")
        return selected
    if not path:
        path = os.environ.get("HORIZONTAL_PROJECT")
    if not path:
        if len(_projects) == 1:
            project = next(iter(_projects.values()))
            _active_project.set(project)
            return project
        raise ValueError("Pass a project path, or set HORIZONTAL_PROJECT.")
    key = str(Path(path).expanduser().resolve())
    candidates = [p for p in _projects.values() if Path(p.path).resolve() == Path(key) and not p.summary.get("frozen")]
    if len(candidates) > 1: raise ValueError("Both live and disk contexts are open; pass project_ref.")
    project = candidates[0] if candidates else _open_context(key, "auto")
    _active_project.set(project)
    return project


def _open_context(path: str, source: str) -> Project:
    if len(_projects) >= 64: raise ValueError("Close unused project contexts before opening another.")
    project = open_any(path, source=source, isolated=os.environ.get("HORIZONTAL_ISOLATED") != "0")
    ref = str(uuid.uuid4())
    project.summary.update(project_ref=ref, requested_source=source, transport=type(project.session.transport).__name__)
    _projects[ref] = project
    _active_project.set(project)
    return project


def _edit(project: Project, ops: list[dict[str, Any]], **kwargs: Any) -> dict[str, Any]:
    if not project.is_live:
        # A positive live match means a disk edit would race an open document.
        if _live_has(str(Path(project.path).resolve())):
            raise transport_error("LIVE_DOCUMENT_OPEN", "Use the live context for edits while Horizontal holds this project.")
    options = _edit_options.get()
    if not options.get("expected_revision") or not options.get("operation_id"):
        raise ValueError("expected_revision and operation_id are required for every edit.")
    return project.apply(ops, **options, **kwargs)


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
def connection_status() -> dict[str, Any]:
    """Diagnose discovery, authentication, engine versions, binary selection and open contexts without opening a project. Tokens are never returned."""
    attempts: list[dict[str, Any]] = []
    info = find_live(attempts)
    status: dict[str, Any] = {"mcp_version": importlib.metadata.version("mcp"), "required_native_api": 2,
                              "discovery": attempts, "live": {"status": "unavailable", "reason": "No reachable live endpoint; app, automation, or document state is unknown"}}
    if info:
        transport = None
        started = time.monotonic()
        try:
            transport = LiveTransport(info, timeout=3)
            session = Session(transport=transport)
            version = session.version()
            status["live"] = {"status": "authenticated", "endpoint": transport.path, "discovery_path": info["path"], "engine": version,
                              "compatible": version.get("api") == 2, "latency_ms": round((time.monotonic() - started) * 1000, 1)}
        except (HorizontalError, OSError) as error:
            status["live"] = {"status": "failed", "reason": str(error)}
        finally:
            if transport: transport.close()
    binaries = []
    for kind, path in (("worker", find_cli()), ("in_process", find_dylib())):
        if path:
            stat = path.stat()
            with path.open("rb") as file:
                binary_hash = hashlib.file_digest(file, "sha256").hexdigest()
            binaries.append({"kind": kind, "path": str(path.resolve()), "size": stat.st_size, "modified_ns": stat.st_mtime_ns, "sha256": binary_hash})
    status["binaries"] = binaries
    status["hard_deadlines"] = os.environ.get("HORIZONTAL_ISOLATED") != "0"
    status["contexts"] = [{"project_ref": id, "path": p.path, **p.last_metadata,
                            "transport": type(p.session.transport).__name__, "connected": not p.session.transport.closed,
                            "engine": p.session.engine} for id, p in _projects.items()]
    return status


@_tool
def close_project(path: str | None = None) -> dict[str, Any]:
    """Release an MCP context; a user's live document remains open."""
    project = _resolve(path)
    ref = next(id for id, candidate in _projects.items() if candidate is project)
    _snapshots.pop(ref, None)
    project.close()
    del _projects[ref]
    if not any(p.session is project.session for p in _projects.values()): project.session.close()
    return {"closed": ref}


@_tool
def transaction_status(operation_id: str, path: str | None = None) -> dict[str, Any]:
    """Look up a mutation outcome after a lost response. Unknown does not authorize replay."""
    return _resolve(path).transaction_status(operation_id)


@_tool
def analysis_snapshot(path: str | None = None) -> dict[str, Any]:
    """Pin immutable schematic evidence for analysis and rendering. Returns snapshot_ref and a read-only project_ref. Expires after 30 minutes."""
    for ref, item in list(_snapshots.items()):
        if time.monotonic() - item["created"] > 1800:
            _release_snapshot(ref)
    if len(_snapshots) >= 16: raise ValueError("Release unused analysis snapshots before creating another")
    project = _resolve(path).freeze()
    snapshot = project.analysis_snapshot()
    _active_project.set(project)
    ref = str(uuid.uuid4())
    _projects[ref] = project
    _snapshots[ref] = {"project": project, "snapshot": snapshot, "created": time.monotonic()}
    return {"snapshot_ref": ref, "project_ref": ref, "snapshot": snapshot, "expires_in_s": 1800}


def _snapshot(ref: str) -> dict[str, Any]:
    item = _snapshots.get(ref)
    if item is None or time.monotonic() - item["created"] > 1800:
        raise transport_error("SNAPSHOT_EXPIRED", "Snapshot expired; capture a new snapshot explicitly")
    _active_project.set(item["project"])
    return item["snapshot"]


def _release_snapshot(ref: str):
    item = _snapshots.pop(ref)
    _projects.pop(ref, None)
    try: item["project"].close()
    finally:
        if not any(p.session is item["project"].session for p in _projects.values()): item["project"].session.close()


@_tool
def release_analysis_snapshot(snapshot_ref: str) -> dict[str, Any]:
    """Release pinned native files after analysis. Completed jobs retain their immutable numerical input."""
    if snapshot_ref not in _snapshots: raise ValueError("Unknown analysis snapshot")
    _release_snapshot(snapshot_ref)
    return {"released": snapshot_ref}


@_tool
def validate_analysis(snapshot_ref: str, scenario: Scenario, setup: Setup) -> dict[str, Any]:
    """Resolve explicit models, population and relay states against schematic IDs; list missing inputs before calculation."""
    return validate_circuit(_snapshot(snapshot_ref), scenario, setup)


@_tool
def analyze_transfer(snapshot_ref: str, scenario: Scenario, setup: Setup, timeout_s: float = 30) -> dict[str, Any]:
    """Start bounded complex transfer-function analysis. Use analysis_result with the returned job_id."""
    return _jobs.submit("transfer", _snapshot(snapshot_ref), scenario, setup, timeout_s)


@_tool
def analyze_noise(snapshot_ref: str, scenario: Scenario, setup: Setup, timeout_s: float = 30) -> dict[str, Any]:
    """Start one-sided noise PSD and RMS analysis with per-source contributions; incomplete noise models require an explicit partial-analysis choice."""
    return _jobs.submit("noise", _snapshot(snapshot_ref), scenario, setup, timeout_s)


@_tool
def analyze_headroom(snapshot_ref: str, scenario: Scenario, setup: Setup, timeout_s: float = 30) -> dict[str, Any]:
    """Start DC and sinusoidal margin analysis against explicitly evidenced device limits."""
    return _jobs.submit("headroom", _snapshot(snapshot_ref), scenario, setup, timeout_s)


@_tool
def analyze_adc_filter(snapshot_ref: str, scenario: Scenario, setup: Setup, timeout_s: float = 30) -> dict[str, Any]:
    """Start analog/filter response, supported timing and bounded alias-noise analysis for an explicit converter configuration."""
    return _jobs.submit("adc_filter", _snapshot(snapshot_ref), scenario, setup, timeout_s)


@_tool
def analysis_result(job_id: str, include_replay: bool = False) -> dict[str, Any]:
    """Read an analysis job's status and, when completed, its data and schematic evidence."""
    result = _jobs.status(job_id, include_result=True, include_replay=include_replay)
    if result["state"] == "failed":
        error = result["error"]
        raise HorizontalError(-32006, error["message"], error)
    return result


@_tool
def cancel_analysis(job_id: str) -> dict[str, Any]:
    """Cancel queued/running numerical work without changing the schematic."""
    return _jobs.cancel(job_id)


@_tool
def discard_analysis(job_id: str) -> dict[str, Any]:
    """Release a completed or stopped analysis job."""
    _jobs.discard(job_id)
    return {"discarded": job_id}


@_tool
def export_analysis(job_id: str, target_directory: str, include_schematic_images: bool = True) -> dict[str, Any]:
    """Export plots, CSV, model assumptions, replay input and matching schematic crops. Image export requires the original pinned snapshot to remain available."""
    images = []
    if include_schematic_images:
        status = _jobs.status(job_id, include_result=True)
        if status["state"] != "completed": raise ValueError("Only completed analyses can be exported")
        evidence = status["result"]["evidence"]
        sheets: dict[tuple, list[dict[str, Any]]] = {}
        for component in evidence.values():
            for symbol in component.get("symbols", []):
                sheets.setdefault((symbol["sheet_id"], symbol.get("block_id")), []).append(symbol)
        if len(sheets) > 8: raise ValueError("Image export is limited to eight sheets; select a smaller subcircuit or omit images")
        if sheets:
            candidate = next((item for item in _snapshots.values() if item["snapshot"]["meta"]["snapshot_id"] == status["snapshot_id"] and time.monotonic() - item["created"] <= 1800), None)
            if candidate is None: raise transport_error("SNAPSHOT_EXPIRED", "The original schematic snapshot is unavailable. Export with include_schematic_images=false to retain numerical results and file evidence.")
            project = candidate["project"]
            for (sheet_id, block_id), symbols in sorted(sheets.items(), key=lambda item: str(item[0])):
                region = {"min_x_mm": min(s["x_mm"] for s in symbols) - 15, "max_x_mm": max(s["x_mm"] for s in symbols) + 15,
                          "min_y_mm": min(s["y_mm"] for s in symbols) - 15, "max_y_mm": max(s["y_mm"] for s in symbols) + 15}
                params = {"sheet_id": sheet_id, "region": region, "dpi": 110, "max_pixels": 2048}
                if block_id: params["block_id"] = block_id
                image = project._call("render_sheet", **params)
                images.append({**image, "snapshot_id": status["snapshot_id"], "block_id": block_id, "symbol_ids": [s["symbol_id"] for s in symbols]})
    return _jobs.export(job_id, target_directory, images=images)


@_tool
def open_project(path: str, source: Literal["auto", "live", "disk"] = "auto") -> dict[str, Any]:
    """Open a Horizon project (.hprj file or .horizontal package) and return its summary: blocks, sheets, counts, diagnostics."""
    project = _open_context(path, source)
    return project.summary


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
def list_components(path: str | None = None, sheet: int | None = None, sheet_id: str | None = None, block_id: str | None = None, name: str | None = None) -> list[dict[str, Any]]:
    """Every component with refdes, value, MPN, package, and where it is placed. Optionally only those with a symbol on one sheet."""
    return _resolve(path).components(sheet=sheet, sheet_id=sheet_id, block_id=block_id, name=name)


@_tool
def get_component(refdes: str | None = None, path: str | None = None, id: str | None = None) -> dict[str, Any]:
    """One component in full: every pin with its net, symbol placements, board placement, part details."""
    return _resolve(path).component(refdes=refdes, id=id)


@_tool
def list_nets(path: str | None = None) -> list[dict[str, Any]]:
    """Every net with its class, power/port flags, pin count, and routing counts."""
    return _resolve(path).nets()


@_tool
def get_net(name: str | None = None, path: str | None = None, id: str | None = None) -> dict[str, Any]:
    """One net in full: the pins on it and how much of it is routed."""
    return _resolve(path).net(name=name, id=id)


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
def apply_ops(ops: list[EditOperation], path: str | None = None, dry_run: bool = False, pool_items: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """Apply edit operations. Each op is {"op": name, ...params}; see list_ops. Components and nets may be named by refdes or net name. When the project is open in Horizontal the edit lands there as one undoable step; otherwise the files are written and reloaded. dry_run validates without changing anything."""
    encoded = [op.model_dump(exclude_unset=True) if isinstance(op, BaseModel) else op for op in ops]
    return _edit(_resolve(path), encoded, dry_run=dry_run, pool_items=pool_items)


@_tool
def set_component_value(refdes: str, value: str, path: str | None = None) -> dict[str, Any]:
    """Set a component's value and write the project."""
    return _edit(_resolve(path), [{"op": "set_value", "component": refdes, "value": value}])


@_tool
def rename_net(net: str, name: str, path: str | None = None) -> dict[str, Any]:
    """Rename a net and write the project."""
    return _edit(_resolve(path), [{"op": "rename_net", "net": net, "name": name}])


@_tool
def connect_pin(refdes: str, pin: str, net: str, path: str | None = None, create_net: bool = False) -> dict[str, Any]:
    """Connect a component pin (pin name, or gate/pin) to a net and write the project."""
    return _edit(_resolve(path), [{"op": "connect", "component": refdes, "pin": pin, "net": net, "create_net": create_net}])


@_tool
def place_component(refdes: str, path: str | None = None, x_mm: float | None = None, y_mm: float | None = None, angle_deg: float | None = None, bottom: bool | None = None) -> dict[str, Any]:
    """Place a component's package on the board, or move or rotate it if it is already placed."""
    fields = {k: v for k, v in {"x_mm": x_mm, "y_mm": y_mm, "angle_deg": angle_deg, "bottom": bottom}.items() if v is not None}
    return _edit(_resolve(path), [{"op": "place_component", "component": refdes, **fields}])


@_tool
def render_sheet(path: str | None = None, sheet: int | None = None, name: str | None = None, region: Region | None = None, dpi: float = 110, sheet_id: str | None = None, block_id: str | None = None) -> dict[str, Any]:
    """Render one schematic sheet as a PNG image (by index or name; default the first sheet). region {min_x_mm, min_y_mm, max_x_mm, max_y_mm} renders only that part, at higher effective detail."""
    params = {k: v for k, v in {"sheet": sheet, "name": name, "region": region.model_dump() if region else None, "sheet_id": sheet_id, "block_id": block_id}.items() if v is not None}
    return _resolve(path)._call("render_sheet", dpi=dpi, max_pixels=2400, **params)


@_tool
def render_board(path: str | None = None, layers: list[str] | None = None, mirrored: bool = False, region: Region | None = None, dpi: float = 110) -> dict[str, Any]:
    """Render the board drawing as a PNG image. Pass layer names from board_info to choose layers; mirrored views it from the bottom; region {min_x_mm, min_y_mm, max_x_mm, max_y_mm} renders only that part."""
    params = {k: v for k, v in {"layers": layers, "region": region.model_dump() if region else None}.items() if v is not None}
    return _resolve(path)._call("render_board", mirrored=mirrored, dpi=dpi, max_pixels=2400, **params)


@_tool
def zoom_to(path: str | None = None, refdes: str | None = None, net: str | None = None, pane: str | None = None, margin_mm: float = 3) -> dict[str, Any]:
    """Frame a component (refdes) or a net in the app's board or schematic pane. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is no pane to zoom.")
    return project.zoom_to(refdes=refdes, net=net, pane=pane, margin_mm=margin_mm)


@_tool
def render_viewport(path: str | None = None, pane: str = "board", dpi: float = 110) -> dict[str, Any]:
    """Render what the app's board or schematic pane currently shows, as a PNG in the exporter's drawing style. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is no viewport to render.")
    return project._call("render_viewport", pane=pane, dpi=dpi, max_pixels=2400)


@_tool
def list_groups(path: str | None = None) -> list[dict[str, Any]]:
    """Horizon groups (instances of a sub-circuit, e.g. an atopile module) with their members by tag and whether each is placed."""
    return _resolve(path).groups()


@_tool
def copy_group_layout(source: str, target: str, path: str | None = None, x_mm: float | None = None, y_mm: float | None = None, angle_deg: float | None = None, include_routing: bool = True) -> dict[str, Any]:
    """Lay out the target group like the source group: every member with a matching tag is placed at the same relative position and rotation, and by default the tracks and vias between the source's members are copied too. The target's anchor stays where it already is unless x_mm and y_mm are given."""
    fields = {k: v for k, v in {"x_mm": x_mm, "y_mm": y_mm, "angle_deg": angle_deg}.items() if v is not None}
    return _edit(_resolve(path), [{"op": "copy_group_layout", "source": source, "target": target, "include_routing": include_routing, **fields}])


def main() -> None:
    mcp.run(transport="stdio")


def _shutdown():
    _jobs.close()
    for session in {p.session for p in _projects.values()}:
        session.close()


atexit.register(_shutdown)


if __name__ == "__main__":
    main()
