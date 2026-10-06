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
import re
import subprocess
import threading
from contextvars import ContextVar
import os
from collections.abc import Callable
from pathlib import Path
from typing import Annotated, Any, Literal, get_type_hints

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError, UnexpectedToolError
from mcp.types import CallToolResult, TextContent, ImageContent, ToolAnnotations
from pydantic import BaseModel, Field, StrictInt, ValidationError

from ._native import (HorizontalError, find_live, find_live_for, find_cli, find_dylib, LiveTransport,
                      project_holders, transport_error)
from .client import Project, Session, open as open_any, _request_deadline, mutation_timeout
from .schemas import (Result, ProjectInfo, Component, ComponentFields, Net, Sheet, EditResult, Region, RenderedImage, EditOperation,
                      schema_vocabulary, vocabulary_digest, compare_vocabulary,
                      PinnedSnapshot, AnalysisValidation, AnalysisJob)
from .analysis import Scenario, Setup, validate as validate_circuit
from .analysis_jobs import AnalysisJobs

class TypedMCPServer(MCPServer):
    async def call_tool(self, name, arguments, context=None):
        # A mutation on a large live document can take longer than a read;
        # it gets the client's mutation budget plus time to look up its outcome.
        budget = 2 * mutation_timeout() + 10 if name in _mutations else 30
        deadline_token = _request_deadline.set(time.monotonic() + budget)
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
        "the BOM, run checks, export fabrication files, and render sheets or the board as images. "
        "Edits cover the block, schematic symbols, wires and text, board placement and manual track and via "
        "routing, and can pull parts in from the pools a project draws from. Nothing autoroutes. "
        "Edit replies are compact — ids and counts per op — unless verbose is passed. A mutation whose reply is "
        "lost is looked up by its operation_id before an error is returned, so a TIMEOUT means the outcome "
        "really is unknown; transaction_status answers it later."
    ),
)

_projects: dict[str, Project] = {}
_active_project: ContextVar[Project | None] = ContextVar("horizontal_project", default=None)
_edit_options: ContextVar[dict[str, Any]] = ContextVar("horizontal_edit", default={})
_mutations = {"apply_ops", "set_component_value", "rename_net", "connect_pin", "place_component", "copy_group_layout",
              "import_pool_part", "update_project_parts", "pool_write", "pour_planes", "autoroute"}
_snapshots: dict[str, dict[str, Any]] = {}
_jobs = AnalysisJobs()
_tool_lock = threading.RLock()


def _tool(fn: Callable[..., Any]) -> Callable[..., Any]:
    """Registers `fn` as a tool and turns engine errors into messages the client sees."""

    hints = get_type_hints(fn, include_extras=True)
    result_type = {"open_project": ProjectInfo, "new_project": ProjectInfo, "reload_project": ProjectInfo,
                   "analysis_snapshot": PinnedSnapshot, "validate_analysis": AnalysisValidation,
                   **{name: AnalysisJob for name in ("analyze_transfer", "analyze_noise", "analyze_headroom", "analyze_adc_filter", "analysis_result", "cancel_analysis")},
                   "list_components": list[Component | ComponentFields], "get_component": Component | ComponentFields,
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
                options = {key: value for key, value in options.items() if value is not None}
                verbose, file_text = kwargs.pop("verbose", False), kwargs.pop("file_text", False)
                if file_text: options["detail"] = "files"
                elif not verbose: options["detail"] = "compact"
                _edit_options.set(options)
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
    # live_state takes a project path to look beside, not an open context.
    if "path" in signature.parameters and fn.__name__ not in {"open_project", "live_state"}:
        parameters.append(inspect.Parameter("project_ref", inspect.Parameter.KEYWORD_ONLY, default=None, annotation=str | None))
    if fn.__name__ in _mutations:
        parameters += [inspect.Parameter("expected_revision", inspect.Parameter.KEYWORD_ONLY, annotation=str),
                       inspect.Parameter("operation_id", inspect.Parameter.KEYWORD_ONLY, annotation=str),
                       inspect.Parameter("plan_digest", inspect.Parameter.KEYWORD_ONLY, default=None, annotation=str | None),
                       inspect.Parameter("verbose", inspect.Parameter.KEYWORD_ONLY, default=False, annotation=Annotated[bool, Field(
                           description="Return the full reply: every change in full, the echoed ops, for a dry run what each "
                                       "file gains, loses and changes (as JSON paths), and the project summary. Off, the reply "
                                       "is ids and counts.")])]
        if "dry_run" in signature.parameters:
            parameters.append(inspect.Parameter("file_text", inspect.Parameter.KEYWORD_ONLY, default=False, annotation=Annotated[bool, Field(
                description="With dry_run, the verbose reply plus each changed file's whole text before and after. A "
                            "schematic on a large design is over a megabyte, so ask for this only when the paths are not enough.")]))
    wrapper.__signature__ = signature.replace(parameters=parameters, return_annotation=output)
    wrapper.__annotations__ = {p.name: p.annotation for p in parameters} | {"return": output}
    if fn.__name__ == "apply_ops":
        # A client may keep showing tool schemas from an earlier server; this
        # line is how an agent can tell which one it is looking at.
        wrapper.__doc__ = (fn.__doc__ or "") + (f"\n\n    Op schema {_SCHEMA_DIGEST}, {len(schema_vocabulary())} ops. connection_status "
                                                "and open_project compare it with the engine's and warn when they differ.")
    resource_writes = {"open_project", "new_project", "save", "undo", "reload_project", "analysis_snapshot", "release_analysis_snapshot", "analyze_transfer", "analyze_noise", "analyze_headroom", "analyze_adc_filter", "cancel_analysis", "discard_analysis"}
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


def _open_context_for(path: str, name: str | None) -> Project:
    """A brand-new project, opened as a context of its own."""
    if len(_projects) >= 64: raise ValueError("Close unused project contexts before opening another.")
    target = Path(path).expanduser()
    if target.exists(): raise ValueError(f"{target} already exists; new_project will not write over it.")
    session = Session(isolated=os.environ.get("HORIZONTAL_ISOLATED") != "0")
    try:
        project = session.new_project(target, name=name)
    except Exception:
        session.close()
        raise
    ref = str(uuid.uuid4())
    project.summary.update(project_ref=ref, requested_source="disk", transport=type(project.session.transport).__name__)
    _projects[ref] = project
    _active_project.set(project)
    return project


# What this server is, fixed when it started: a reconnect that leaves the
# process running keeps all of it, which is how a stale server shows itself.
_PACKAGE_DIR = Path(__file__).resolve().parent
_STARTED = time.time()


def _source_mtime() -> float:
    return max((p.stat().st_mtime for p in _PACKAGE_DIR.glob("*.py")), default=0)


def _git_commit() -> str | None:
    try:
        return subprocess.run(["git", "-C", str(_PACKAGE_DIR), "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, timeout=2).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


_SOURCE_MTIME = _source_mtime()
_COMMIT = _git_commit()
_SCHEMA_DIGEST = vocabulary_digest(schema_vocabulary())


def _server_identity() -> dict[str, Any]:
    changed = sorted(p.name for p in _PACKAGE_DIR.glob("*.py") if p.stat().st_mtime > _SOURCE_MTIME + 0.5)
    commit_now = _git_commit()
    identity = {"pid": os.getpid(), "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(_STARTED)),
                "package": importlib.metadata.version("horizontal"), "package_dir": str(_PACKAGE_DIR),
                "commit_at_start": _COMMIT, "commit_now": commit_now, "schema_digest": _SCHEMA_DIGEST,
                "ops": len(schema_vocabulary())}
    if changed or (commit_now and _COMMIT and commit_now != _COMMIT):
        identity["stale"] = True
        identity["changed_since_start"] = changed
    return identity


def _server_warnings(project: Project | None = None) -> list[str]:
    """What the agent should know before trusting this server's schema."""
    warnings = []
    identity = _server_identity()
    if identity.get("stale"):
        warnings.append("This MCP server's code changed after it started (" + (", ".join(identity["changed_since_start"]) or
                        f"commit {identity['commit_at_start']} -> {identity['commit_now']}") +
                        "); its tool schemas are the old ones. Ask the user to restart the server — a new session restarts it; "
                        "\"reconnect\" may not.")
    engine = project.session.engine if project else None
    if engine and engine.get("ops_digest") and engine["ops_digest"] != _SCHEMA_DIGEST:
        try:
            difference = compare_vocabulary(project.session.call("list_ops"))
        except HorizontalError:
            difference = {}
        newer = "the engine" if difference.get("engine_only_ops") or difference.get("engine_only_params") else "this server"
        warnings.append(f"The engine ({engine.get('host', 'worker')}) and this server's schema describe different ops; {newer} is newer. "
                        "Restart whichever is older (the app, or the MCP server). Differences: " + json.dumps(
                            {k: v for k, v in difference.items() if k not in {"match", "schema_digest", "engine_digest"}}))
    return warnings


def _drop_context(ref: str) -> None:
    project = _projects.pop(ref)
    _snapshots.pop(ref, None)
    if not any(p.session is project.session for p in _projects.values()):
        project.session.close()


def _open_context(path: str, source: str) -> Project:
    if source == "disk":
        # A disk context already open on this path is reloaded, not doubled.
        for other in _projects.values():
            if (not other.is_live and not other.summary.get("frozen") and not other.session.transport.closed
                    and Path(other.path).resolve() == Path(path).expanduser().resolve()):
                kept = {k: other.summary.get(k) for k in ("project_ref", "requested_source", "transport")}
                other.reload()
                other.summary.update(kept)
                _active_project.set(other)
                return other
    if len(_projects) >= 64: raise ValueError("Close unused project contexts before opening another.")
    project = open_any(path, source=source, isolated=os.environ.get("HORIZONTAL_ISOLATED") != "0")
    if project.is_live:
        # One context per open document. Reopening it returns the context the
        # agent already holds — re-attached if its connection was lost — and
        # contexts on a document since closed or reopened, or dead duplicates,
        # are dropped rather than left to pile up.
        same = [(ref, other) for ref, other in _projects.items()
                if other.is_live and not other.summary.get("frozen")
                and Path(other.path).resolve() == Path(project.path).resolve()]
        keep = next(((ref, o) for ref, o in same if o.summary.get("instance_id") == project.summary.get("instance_id")
                     and not o.session.transport.closed), None) or next(
            ((ref, o) for ref, o in same if o.summary.get("instance_id") == project.summary.get("instance_id")), None)
        for ref, other in same:
            if keep and ref == keep[0]:
                continue
            if other.summary.get("instance_id") != project.summary.get("instance_id") or other.session.transport.closed:
                _drop_context(ref)
        if keep:
            other = keep[1]
            fresh = {k: v for k, v in project.summary.items() if k not in {"project_ref", "requested_source", "transport"}}
            if other.session.transport.closed:
                other.session = project.session
                other._generation = project.session.generation
            else:
                project.session.close()
            other.handle = fresh.get("handle", other.handle)
            other.summary.update(fresh)
            other.last_metadata.update({k: fresh[k] for k in ("revision", "snapshot_id", "instance_id") if k in fresh})
            _active_project.set(other)
            return other
    ref = str(uuid.uuid4())
    project.summary.update(project_ref=ref, requested_source=source, transport=type(project.session.transport).__name__)
    _projects[ref] = project
    _active_project.set(project)
    return project


def _guard(project: Project) -> dict[str, Any]:
    """The preconditions every mutation shares."""
    if not project.is_live:
        # A disk edit under an open editor would be lost either way. The holder
        # records beside the project say who has it, whether or not the app's
        # live channel is reachable; the engine refuses on the same evidence.
        holders = project_holders(project.path)
        if holders:
            names = ", ".join(h.get("name") or "An editor" for h in holders)
            reachable = any(isinstance(h.get("endpoint"), dict) for h in holders)
            raise transport_error("DOCUMENT_OPEN", f"{names} has this project open, so its files cannot be edited on disk. " + (
                "Open it with source=\"live\" and the edit lands there as one undoable step."
                if reachable else
                "Turn on the live channel in its settings, then open the project with source=\"live\"; or close the document."))
    options = _edit_options.get()
    if not options.get("expected_revision") or not options.get("operation_id"):
        raise ValueError("expected_revision and operation_id are required for every edit.")
    return options


def _edit(project: Project, ops: list[dict[str, Any]], **kwargs: Any) -> dict[str, Any]:
    return project.apply(ops, **_guard(project), **{k: v for k, v in kwargs.items() if v is not None or k == "dry_run"})


def _edit_call(project: Project, method: str, **params: Any) -> dict[str, Any]:
    """A mutation that is not an ops batch; the same preconditions apply."""
    return project._call(method, **_guard(project), **params)


@_tool
def connection_status() -> dict[str, Any]:
    """Diagnose discovery, authentication, engine versions, binary selection and open contexts without opening a project. Tokens are never returned."""
    attempts: list[dict[str, Any]] = []
    info = find_live(attempts)
    # The app's own discovery file is in its sandbox container; the holder
    # records beside an open or configured project usually are not.
    for candidate in [os.environ.get("HORIZONTAL_PROJECT")] + [p.path for p in _projects.values()]:
        if info or not candidate:
            continue
        info = find_live_for(candidate, attempts)
    status: dict[str, Any] = {"mcp_version": importlib.metadata.version("mcp"), "required_native_api": 2,
                              "server": _server_identity(),
                              "discovery": attempts, "live": {"status": "unavailable", "reason": "No reachable live endpoint; app, automation, or document state is unknown"}}
    if info:
        transport = None
        started = time.monotonic()
        try:
            transport = LiveTransport(info, timeout=3)
            session = Session(transport=transport)
            version = session.version()
            status["live"] = {"status": "authenticated", "endpoint": transport.path, "discovery_path": info["path"], "engine": version,
                              "compatible": version.get("api") == 2, "latency_ms": round((time.monotonic() - started) * 1000, 1),
                              "schema": compare_vocabulary(session.call("list_ops"))}
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
                            "engine": p.session.engine,
                            "schema_matches": (p.session.engine or {}).get("ops_digest", _SCHEMA_DIGEST) == _SCHEMA_DIGEST}
                           for id, p in _projects.items()]
    warnings = _server_warnings()
    if status["live"].get("schema", {}).get("match") is False:
        warnings.append("The live app and this server's schema describe different ops: " + json.dumps(status["live"]["schema"]))
    if warnings:
        status["warnings"] = warnings
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
def transaction_status(operation_id: str, path: str | None = None, verbose: bool = False) -> dict[str, Any]:
    """Look up a mutation's outcome after a lost response: committed (with its receipt), not_committed (with the
    error — safe to resend), or unknown when the document never saw that id. The engine answers one request at a
    time, so this waits for a mutation still running. A lost connection is reopened first."""
    project = _resolve(path)
    return project._call("transaction_status", operation_id=operation_id, **({} if verbose else {"detail": "compact"}))


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
    """Open a Horizon project (.hprj file or .horizontal package) and return its summary: blocks, sheets, counts, diagnostics.
    Opening a document that already has a context returns that context, with the same project_ref. warnings says
    when this server or the engine is out of date."""
    project = _open_context(path, source)
    warnings = _server_warnings(project)
    return {**project.summary, **({"warnings": warnings} if warnings else {})}


@_tool
def new_project(path: str, name: str | None = None) -> dict[str, Any]:
    """Create a project from the new-document template as a .horizontal package and open it. path must not exist
    and must end in .horizontal. The project it makes has a pool, an empty top block, one schematic sheet and a
    board with no outline — give it one before expecting fabrication output to mean anything."""
    project = _open_context_for(path, name)
    return project.summary


@_tool
def save(path: str | None = None) -> dict[str, Any]:
    """Write a document open in Horizontal to its file, the way the Save command does. An edit through the live
    channel is one undoable step in the app and nothing more until this runs, so a task that edits a live document
    is not finished without it.

    Check source in the reply. "live" means a document was saved, and verified: the file is compared against the
    document afterwards rather than the document's own edited flag being trusted, so this can no longer claim
    success over a stale file. "disk" means the context you asked was a disk context, whose edits were already
    written when they committed — if your edit went to the app, that is the wrong context and you want
    open_project with source="live".

    A live save also gives leftovers: any temporary file a sandboxed safe save left beside the project file, with
    same_as_file. An empty list means the folder was looked at and held none."""
    return _resolve(path).save()


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


def _only(record: dict[str, Any], fields: list[str] | None) -> dict[str, Any]:
    """The fields asked for, and always what identifies the record."""
    if not fields: return record
    keep = set(fields) | {"id", "refdes"}
    return {key: value for key, value in record.items() if key in keep}


@_tool
def list_components(path: str | None = None, sheet: int | None = None, sheet_id: str | None = None, block_id: str | None = None, name: str | None = None,
                    fields: Annotated[list[str] | None, Field(description="Only these keys of each component (id and refdes always), e.g. [\"value\", \"mpn\"].")] = None,
                    refdes_prefix: Annotated[str | None, Field(description="Only components whose refdes starts with this, e.g. \"C\".")] = None,
                    include_terminals: Annotated[bool, Field(description="Include every package pad of every component (physical_terminals) — large for big packages; get_component reads one part's pins and pads.")] = False) -> list[dict[str, Any]]:
    """Every component with refdes, value, MPN, package, pin and connected-pin counts, and where it is placed.
    Optionally only those with a symbol on one sheet. Package pads are left out unless include_terminals."""
    components = _resolve(path).components(sheet=sheet, sheet_id=sheet_id, block_id=block_id, name=name)
    if refdes_prefix: components = [c for c in components if str(c.get("refdes", "")).upper().startswith(refdes_prefix.upper())]
    if not include_terminals:
        components = [{k: v for k, v in c.items() if k not in {"pins", "physical_terminals"}} for c in components]
    return [_only(c, fields) for c in components]


_SUPPLY_PIN = re.compile(r"^(V(DD|CC|BAT|CAP|IN|LDO|SMPS|REF\+|DDA|IO)|AVDD|DVDD|IOVDD|PVDD|VS\+|V\+|VREF$)", re.I)
_GROUND_PIN = re.compile(r"^(V(SS|EE|REF-)|(A|D|P|S)?GND|EP(AD)?$|PAD$|V-)", re.I)


def _pin_groups(pins: list[dict[str, Any]]) -> dict[str, Any]:
    """Pins by what they are for: supply and ground pins by the net each is tied to, no-connects, pins on no
    net, and a count of the signal pins."""
    groups: dict[str, Any] = {"supply": {}, "ground": {}, "no_connect": [], "unconnected": [], "signal": 0}
    for pin in pins:
        name, net = str(pin.get("pin", "")), pin.get("net")
        power = pin.get("direction") in {"power_input", "power_output"} or _SUPPLY_PIN.match(name) or _GROUND_PIN.match(name)
        if pin.get("connection_state") == "no_connect":
            groups["no_connect"].append(name)
        elif power:
            ground = _GROUND_PIN.match(name) or (net and _GROUND_PIN.match(str(net)))
            groups["ground" if ground else "supply"].setdefault(net or "(no net)", []).append(name)
        elif net is None:
            groups["unconnected"].append(name)
        else:
            groups["signal"] += 1
    return groups


@_tool
def get_component(refdes: str | None = None, path: str | None = None, id: str | None = None,
                  fields: Annotated[list[str] | None, Field(description="Only these top-level keys (id and refdes always), e.g. [\"pins\", \"symbols\"].")] = None,
                  pins: Annotated[str | None, Field(description="Only pins whose name contains this, case-insensitively, e.g. \"PA1\".")] = None,
                  pin_regex: Annotated[str | None, Field(description="Only pins whose name matches this regular expression, case-insensitively, e.g. \"^V(DD|SS)\".")] = None,
                  connected: Annotated[bool | None, Field(description="true: only pins on a net; false: only pins on none.")] = None,
                  group_pins: Annotated[bool, Field(description="Instead of the pin list, pin_groups: supply and ground pins by the net each is tied to, no-connects, pins on no net, and a count of signal pins — how a part's power is wired, at a glance.")] = False,
                  all_pins: Annotated[bool, Field(description="Every pin even on a large part; otherwise a part with more than 64 pins lists only the pins on a net or marked no-connect.")] = False) -> dict[str, Any]:
    """One component in full: pins with their nets, symbol placements, board placement, part details. A part with
    more than 64 pins lists only its connected and no-connect pins unless all_pins, and says how many it left out;
    pins, pin_regex and connected narrow the list, and group_pins summarises it."""
    component = _resolve(path).component(refdes=refdes, id=id)
    every = component.get("pins") or []
    if pin_regex is not None:
        try: pattern = re.compile(pin_regex, re.I)
        except re.error as error: raise ValueError(f"pin_regex is not a regular expression: {error}") from error
    if group_pins:
        component["pin_groups"] = _pin_groups(every)
        component["pins"] = []
        component["pins_omitted"] = len(every)
    elif pins is not None or pin_regex is not None or connected is not None:
        component["pins"] = [p for p in every
                             if (pins is None or pins.lower() in str(p.get("pin", "")).lower())
                             and (pin_regex is None or pattern.search(str(p.get("pin", ""))))
                             and (connected is None or (p.get("net") is not None) == connected)]
    elif len(every) > 64 and not all_pins:
        component["pins"] = [p for p in every if p.get("net") is not None or p.get("connection_state") == "no_connect"]
        component["pins_omitted"] = len(every) - len(component["pins"])
        component["note"] = (f"{component['pins_omitted']} pins on no net were left out; pass all_pins, connected=false, "
                             "or pins/pin_regex to see them.")
    return _only(component, fields)


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
def list_parts(path: str | None = None, scope: Literal["project", "pools", "all"] = "project") -> list[dict[str, Any]]:
    """Parts the project can use. "project" (the default) lists only the project pool — the self-contained cache beside
    the project, which is all a component can name today. "pools" lists the base pools it draws from, "all" lists both;
    a row with in_project_pool false needs import_pool_part before ensure_component can use it. Use search_pool to
    search by name, manufacturer or tag rather than reading a long list."""
    return _resolve(path).parts(scope=scope)


@_tool
def search_pool(path: str | None = None, query: str | None = None, kind: str | None = None,
                pool_path: str | None = None, limit: int = 50) -> dict[str, Any]:
    """Search every pool the project draws from — its own pool, the pools that pool includes, and the discovered base
    pools — for parts, entities, symbols, packages, padstacks, units, frames and decals. query is a case-insensitive
    substring of name, description, manufacturer, tags or uuid. Items with in_project_pool false live in a base pool
    and need import_pool_part first. The pools list says which pools were searched, and names any that could not be
    read rather than reporting them as empty."""
    params = {k: v for k, v in {"query": query, "kind": kind, "pool_path": pool_path}.items() if v is not None}
    return _resolve(path).search_pool(limit=limit, **params)


@_tool
def get_pool_item(uuid: str, path: str | None = None, kind: str | None = None, pool_path: str | None = None) -> dict[str, Any]:
    """One pool item's own JSON — the bytes pool_write takes back, so this is how an existing item is edited
    rather than replaced blind. A project-pool item is read through the project, so an unsaved change to it is
    what comes back; reading the file off disk would miss that, and is impossible anyway when the pool sits
    inside another app's sandbox container."""
    params = {k: v for k, v in {"kind": kind, "pool_path": pool_path}.items() if v is not None}
    return _resolve(path).pool_item(uuid, **params)


@_tool
def import_pool_part(part: str, path: str | None = None, dry_run: bool = False) -> dict[str, Any]:
    """Copy a part and everything it needs — entity, units, symbols, package, padstacks and 3D models — from a base
    pool into the project pool cache, exactly as placing it from the library does, so ensure_component can name it.
    part is a pool part uuid, or an MPN when it is unambiguous; find one with search_pool."""
    return _edit_call(_resolve(path), "import_pool_part", part=part, dry_run=dry_run)


@_tool
def list_part_updates(path: str | None = None, pool_path: str | None = None) -> dict[str, Any]:
    """Review project parts and their dependencies against source libraries. Returns changes, affected
    references, local-edit conflicts, unavailable sources, and review_digest. Does not change files."""
    return _resolve(path).part_updates(pool_path=pool_path)


@_tool
def update_project_parts(parts: list[str], path: str | None = None, dry_run: bool = False,
                         allow_project_changes: bool = False, review_digest: str | None = None,
                         pool_path: str | None = None) -> dict[str, Any]:
    """Explicitly update UUIDs from list_part_updates, including shared dependencies. Pass review_digest
    to reject changes since review. Local edits and unverified legacy copies require allow_project_changes;
    changes requiring pin/pad remapping are blocked. One transaction and one live undo step."""
    options = {k: v for k, v in {"review_digest": review_digest, "pool_path": pool_path}.items() if v is not None}
    return _edit_call(_resolve(path), "update_project_parts", parts=parts, dry_run=dry_run,
                      allow_project_changes=allow_project_changes, **options)


@_tool
def pool_write(items: list[dict[str, Any]], path: str | None = None, dry_run: bool = False) -> dict[str, Any]:
    """Write pool items — unit, entity, symbol, part, package, padstack — into the project pool cache and reload.
    Each item is the pool item's own JSON, with its "type" and "uuid". Use this to author a part the pools do not
    have; import_pool_part is the way to bring in one they do."""
    return _edit_call(_resolve(path), "pool_write", items=items, dry_run=dry_run)


@_tool
def list_symbols(path: str | None = None, sheet: int | None = None, sheet_id: str | None = None,
                 name: str | None = None, block_id: str | None = None) -> list[dict[str, Any]]:
    """Symbol instances on the schematic sheets: which component and gate each draws, where it sits, and the
    instance id that place_symbol moves and draw_net_line refers to. get_component answers the same question for
    one component; this answers it for a sheet."""
    return _resolve(path).symbols(sheet=sheet, sheet_id=sheet_id, name=name, block_id=block_id)


def _endpoint(end: dict[str, Any]) -> str:
    kind = end.get("kind")
    if kind == "pin":
        return f"{end.get('refdes') or end.get('component') or end.get('symbol')}.{end.get('pin_name') or end.get('pin')}"
    if kind == "junction":
        return "junction:" + str(end.get("junction"))
    return f"{kind}:{end.get(kind, '')}"


@_tool
def list_net_lines(path: str | None = None, net: str | None = None, sheet: int | None = None,
                   sheet_id: str | None = None, name: str | None = None, block_id: str | None = None,
                   verbose: Annotated[bool, Field(description="Full rows: each end's kind, ids, component and gate, and the sheet and net uuids.")] = False) -> list[dict[str, Any]]:
    """The wires drawn on the schematic sheets, with their ids, nets and what each end connects to. An endpoint
    reads "U8.PA13" for a pin (refdes and pin name), "junction:<id>" for a junction, or the bus ripper or block
    port it lands on; from_mm and to_mm are [x, y]. verbose gives the full rows. Horizon derives connectivity
    from the block, not from these — they are what draw_net_line records. find_dangling and find_overlaps answer
    the usual questions about them without reading every wire."""
    rows = _resolve(path).net_lines(net=net, sheet=sheet, sheet_id=sheet_id, name=name, block_id=block_id)
    if verbose:
        return rows
    def xy(point: dict[str, Any] | None) -> list[float] | None:
        return [point["x_mm"], point["y_mm"]] if point else None
    return [{"id": r["id"], "sheet_index": r.get("sheet_index"), "net_name": r.get("net_name"),
             "from": _endpoint(r.get("from") or {}), "to": _endpoint(r.get("to") or {}),
             "from_mm": xy(r.get("from_mm")), "to_mm": xy(r.get("to_mm"))} for r in rows]



@_tool
def find_dangling(path: str | None = None, sheet: int | None = None, sheet_id: str | None = None,
                  name: str | None = None, block_id: str | None = None) -> dict[str, Any]:
    """Drawing that connects nothing, sheet by sheet: wiring islands that reach no pin, port or bus ripper — even
    when a label or power symbol gives them a net — dead-end runs of wire, and wires whose ends name nothing. Each
    comes with ids and a position. A stub is the whole run back to where it branches: every wire and junction that
    prune_sheet with stubs: true would remove, the bare ends it stops at, and branches_from, the junction or pin
    ("U8.PA13") it hangs from. totals.stub_net_lines and stub_junctions are what such a prune removes, to check a
    dry run against. prune_sheet with unanchored: true and stubs: true removes it all."""
    params = {k: v for k, v in {"sheet": sheet, "sheet_id": sheet_id, "name": name, "block_id": block_id}.items() if v is not None}
    found = _resolve(path)._call("find_dangling", **params)
    for sheet_row in found.get("sheets", []):
        for stub in sheet_row.get("stubs", []):
            if isinstance(stub.get("branches_from"), dict): stub["branches_from"] = _endpoint(stub["branches_from"])
    return found


@_tool
def find_overlaps(path: str | None = None, sheet: int | None = None, sheet_id: str | None = None,
                  name: str | None = None, block_id: str | None = None) -> dict[str, Any]:
    """Places a sheet looks connected and is not: a wire over a pin it does not end on, a junction on a pin with no
    wire to it, junctions sharing a spot that no wire joins, and a wire ending part way along another with no
    junction there. Each finding names the pin or wires and where it is."""
    params = {k: v for k, v in {"sheet": sheet, "sheet_id": sheet_id, "name": name, "block_id": block_id}.items() if v is not None}
    return _resolve(path)._call("find_overlaps", **params)


def _compact_marks(rows: list[dict[str, Any]], verbose: bool) -> list[dict[str, Any]]:
    """Rows without the uuids a page full of them repeats: the sheet's (sheet_index says it) and the net's
    (net_name says it, unless the net is unnamed)."""
    if verbose:
        return rows
    return [{k: v for k, v in r.items() if k != "sheet" and not (k == "net" and r.get("net_name"))} for r in rows]


@_tool
def list_block_instances(path: str | None = None) -> list[dict[str, Any]]:
    """The blocks this block uses: each instance, the block it stands for, its reference designator, which of its
    ports are wired to which net here, and where its symbol is drawn. This is how a hierarchical design is read."""
    return _resolve(path).block_instances()


@_tool
def autoroute(net: str, path: str | None = None, layer: int = 0, width_mm: float | None = None,
              max_routes: int = 20, dry_run: bool = False) -> dict[str, Any]:
    """Try to route a net's airwires automatically on one layer. Best effort, and usually not enough: it walks
    around one obstacle at a time rather than searching, so on a dense board it completes a small minority and
    reports the rest. Everything it does write has been checked clear of the board's clearances; what it cannot
    route stays an airwire, is listed in unrouted with what blocked it, and place_track draws those by hand."""
    return _edit_call(_resolve(path), "autoroute", net=net, layer=layer, max_routes=max_routes, dry_run=dry_run,
                      **({"width_mm": width_mm} if width_mm is not None else {}))


@_tool
def list_junctions(path: str | None = None, net: str | None = None, sheet: int | None = None,
                   sheet_id: str | None = None, name: str | None = None, block_id: str | None = None,
        verbose: Annotated[bool, Field(description="Include the sheet and net uuids.")] = False) -> list[dict[str, Any]]:
    """Schematic junction IDs, positions, and nets. Use these IDs in typed wire endpoints. The sheet and net
    uuids are left out unless verbose."""
    return _compact_marks(_resolve(path).junctions(net=net, sheet=sheet, sheet_id=sheet_id, name=name, block_id=block_id), verbose)


@_tool
def list_net_labels(path: str | None = None, net: str | None = None, sheet: int | None = None,
                    sheet_id: str | None = None, name: str | None = None, block_id: str | None = None,
        verbose: Annotated[bool, Field(description="Include the sheet and net uuids.")] = False) -> list[dict[str, Any]]:
    """Net labels on the schematic sheets: which net each names, where it sits, and the id remove_net_label takes.
    A label is how a net is named on the page, and how one net spans several sheets. The sheet and net uuids are
    left out unless verbose."""
    return _compact_marks(_resolve(path).net_labels(net=net, sheet=sheet, sheet_id=sheet_id, name=name, block_id=block_id), verbose)


@_tool
def list_power_symbols(path: str | None = None, net: str | None = None, sheet: int | None = None,
                       sheet_id: str | None = None, name: str | None = None, block_id: str | None = None,
        verbose: Annotated[bool, Field(description="Include the sheet and net uuids.")] = False) -> list[dict[str, Any]]:
    """Power symbols on the schematic sheets, with the net each marks and the id remove_power_symbol takes. The
    shape a symbol draws with — gnd, dot, antenna or earth — belongs to the net, not the symbol, so every symbol
    on one net looks the same. The sheet and net uuids are left out unless verbose."""
    return _compact_marks(_resolve(path).power_symbols(net=net, sheet=sheet, sheet_id=sheet_id, name=name, block_id=block_id), verbose)


@_tool
def undo(path: str | None = None, redo: bool = False) -> dict[str, Any]:
    """Take back the last step on an open document's undo stack — the same stack the app's Edit menu drives, so an
    edit made here and one made by hand undo alike, newest first. Pass redo to put one back. can_undo and can_redo
    in open_project name what is on top, so you can tell whether your own edit is still there before reaching for
    this. Live documents only: a disk edit committed as a transaction, and taking that back means applying the
    inverse rather than popping a stack that does not exist."""
    return _resolve(path).undo(redo=redo)


@_tool
def list_board_texts(path: str | None = None, layer: int | None = None,
                     smashed: Annotated[bool | None, Field(description="Also list the reference designators Horizon smashed out of packages — on a populated board, most of its texts. A text or component search looks through them unless this is false.")] = None,
                     text: Annotated[str | None, Field(description="Only texts containing this, as stored or as drawn, ignoring case, e.g. \"$project\" or \"U1\"; smashed texts included unless smashed is false.")] = None,
                     component: Annotated[str | None, Field(description="Only the texts smashed out of this part's package, by refdes or id; implies smashed.")] = None) -> list[dict[str, Any]]:
    """Free text on the board layers, with the ids remove_board_text takes and place_board_text takes to move or
    change one. Texts smashed out of packages are left out unless smashed, or a text or component search, asks for them: each is marked from_smash and belongs to the package named in its package field, so it moves
    and dies with the component rather than being edited on its own; refdes names that part. A text that draws
    something other than what it stores ("$RD", "$project_title") says what in drawn."""
    return _resolve(path).board_texts(layer=layer, smashed=smashed, text=text, component=component)


@_tool
def export_settings(path: str | None = None,
                    kind: Annotated[Literal["gerber", "odb", "pick_and_place", "board_step", "board_pdf", "bom", "schematic_pdf"] | None,
                                    Field(description="Only this kind.")] = None) -> dict[str, Any]:
    """The export settings Horizon EDA keeps in the project — file names, directories, options — by kind, as the
    files store them, or null where a project has none. set_export_settings changes them. Horizontal's own export
    names its files after the project file and does not read these."""
    return _resolve(path).export_settings(kind=kind)


@_tool
def list_dimensions(path: str | None = None) -> list[dict[str, Any]]:
    """Dimensions on the board: the two points each measures between, its mode, and measures_mm — what it actually
    reads, worked out for the mode, so you do not have to know which axis a horizontal dimension uses."""
    return _resolve(path).dimensions()


@_tool
def list_buses(path: str | None = None) -> list[dict[str, Any]]:
    """Buses in this block, the nets their members carry, and where each bus is labelled or ripped on the sheets.
    A bus is a drawing convenience — the nets in it stay separate nets; ripping a member off is what lets one be
    wired on its own."""
    return _resolve(path).buses()


@_tool
def list_net_ties(path: str | None = None) -> list[dict[str, Any]]:
    """Net ties in this block: which two nets each joins on the board while keeping them apart in the schematic,
    and where each is drawn. That separation is the whole point of a tie — a single-point ground join, say."""
    return _resolve(path).net_ties()


@_tool
def list_holes(path: str | None = None) -> list[dict[str, Any]]:
    """Holes through the board: where each is, how big, and whether it is plated. Horizon plates a hole by giving
    it a net — one without is a mounting hole. A hole's size comes from the padstack it references, so place_hole
    takes a padstack rather than a diameter."""
    return _resolve(path).holes()


@_tool
def list_keepouts(path: str | None = None) -> list[dict[str, Any]]:
    """Areas copper may not enter, with the polygon bounding each. A keepout with all_copper_layers applies to
    every copper layer; otherwise it applies to the layer its polygon is on."""
    return _resolve(path).keepouts()


@_tool
def list_planes(path: str | None = None, net: str | None = None) -> list[dict[str, Any]]:
    """Copper pours on the board: the net each carries, its layer and priority, and whether it has been filled.
    poured false means the plane is defined and empty — place_plane defines, pour_planes fills. net_missing
    marks a plane on a net the block doesn't have: Horizon leaves it out when it opens the board, so does the
    loader, and remove_plane takes it out of the file."""
    return _resolve(path).planes(net=net)


@_tool
def list_polygons(path: str | None = None, layer: int | None = None) -> list[dict[str, Any]]:
    """Board polygons with their vertices and the layer each is on. is_board_outline marks layer 100, the shape
    the board is cut to — a board without one has no shape, however complete the rest of it looks. A polygon a
    plane pours into names that plane."""
    return _resolve(path).polygons(layer=layer)


@_tool
def pour_planes(path: str | None = None, dry_run: bool = False) -> dict[str, Any]:
    """Fill every plane on the board, as Update All Planes does in the app. Planes stay empty from the moment
    place_plane defines one until this runs, and it recomputes them all from the board as it now stands — so run
    it after the copper and placement are settled, not before."""
    return _edit_call(_resolve(path), "pour_planes", dry_run=dry_run)


@_tool
def list_tracks(path: str | None = None, net: str | None = None, layer: int | None = None, limit: int = 200) -> dict[str, Any]:
    """Copper tracks on the board: net, layer, width, and what each end lands on — a pad (naming the component)
    or a junction. Boards carry thousands, so filter by net or layer; truncated says whether the limit cut the
    answer short, and total says how many matched."""
    params = {k: v for k, v in {"net": net, "layer": layer}.items() if v is not None}
    return _resolve(path).tracks(limit=limit, **params)


@_tool
def list_vias(path: str | None = None, net: str | None = None, limit: int = 200) -> dict[str, Any]:
    """Vias on the board: net, position, the layers each spans, and whether its shape comes from a padstack, a
    board via definition or the via rules. net_pinned marks a via whose net was set outright rather than
    inherited through the copper that reaches it."""
    params = {k: v for k, v in {"net": net}.items() if v is not None}
    return _resolve(path).vias(limit=limit, **params)


@_tool
def list_texts(path: str | None = None, sheet: int | None = None, sheet_id: str | None = None,
               name: str | None = None, block_id: str | None = None,
               smashed: Annotated[bool | None, Field(description="Also list the texts Horizon smashed out of symbols. A text or component search looks through them unless this is false.")] = None,
               text: Annotated[str | None, Field(description="Only texts containing this, as stored or as drawn, ignoring case; smashed texts included unless smashed is false.")] = None,
               component: Annotated[str | None, Field(description="Only the texts smashed out of this part's symbols, by refdes or id; implies smashed.")] = None) -> list[dict[str, Any]]:
    """Free text on the schematic sheets, and where each sits, with the ids remove_text takes and place_text takes to
    move or change one.
    Texts smashed out of symbols are left out unless smashed, or a text or component search, asks for them: each is marked from_smash and belongs to the symbol
    named in its symbol field, so it moves and dies with the component rather than being edited on its own; refdes
    names that part. A text that draws something other than what it stores says what in drawn."""
    return _resolve(path).texts(sheet=sheet, sheet_id=sheet_id, name=name, block_id=block_id, smashed=smashed, text=text,
                                component=component)


@_tool
def board_rules(path: str | None = None, kind: str | None = None) -> dict[str, Any]:
    """The board's design rules as data, with the net classes they select and the stackup they apply to — what a
    route has to respect and what check validates. Rules are given as the file states them, because twenty rule
    kinds have twenty shapes and a normalized form would lose the detail that matters. A board that declares no
    rules says so: nothing then constrains a route, and place_track will insist on an explicit width.

    Horizon keys rules by kind; a kind listed in multi_kinds holds several, each with its own id, and the rest
    hold one. add_rule, set_rule and remove_rule take the same kind and id, and every write is checked by the
    app's own rules validator before it commits — a change that would leave the rules invalid is refused with
    what was wrong, because a clearance rule written wrong is worse than no rule at all."""
    return _resolve(path).board_rules(kind=kind)


@_tool
def board_info(path: str | None = None) -> dict[str, Any]:
    """Board size, stackup, drawing layers, and object counts. airwires says where counts.airwires comes from — the
    editor's connectivity pass, the set check reports — and, for a project open in Horizontal, what the board
    canvas draws beside it (canvas, null when the board pane is not up)."""
    return _resolve(path).board_info()


@_tool
def check(path: str | None = None) -> dict[str, Any]:
    """Run the checks Horizontal has: load diagnostics, rules validation, annotation, single-pin nets, components with
    no symbol on any sheet, unplaced packages, unrouted connections."""
    return _resolve(path).check()


@_tool
def export(sections: list[str], path: str | None = None, target_directory: str | None = None) -> dict[str, Any]:
    """Run the app's exporters. Sections: schematic_pdf, bom, gerber, odb, pick_and_place, board_step, board_drawing, board_dxf. Writes files; the target must be outside the project package."""
    return _resolve(path).export(sections, target_directory=target_directory)


@_tool
def live_state(path: str | None = None) -> dict[str, Any]:
    """Documents open in Horizontal right now, with their selection and highlight.

    status is "connected" only when the app answers. Pass a project path when you have one: the app's own
    discovery file lives in its sandbox container, which macOS refuses to other processes, so a project's
    own holder records are often the only way to reach the channel. "unavailable" without a path does not
    mean no document is open — the channel is also off until the user turns it on, and stops when the last
    document closes. held_by in open_project answers whether a project is open regardless of any of this.
    """
    attempts: list[dict[str, Any]] = []
    info = find_live_for(path, attempts) if path else find_live(attempts)
    holders = project_holders(path) if path else []
    if info is None:
        blocked = any("not permitted" in str(attempt.get("reason", "")).lower() for attempt in attempts)
        reason = ("No reachable live endpoint. Horizontal may not be running, may have no document open, "
                  "or may have its live channel switched off in its settings.")
        if blocked and not path:
            reason += (" Its discovery file was found but could not be read — it is inside the app's sandbox "
                       "container. Pass a project path to look beside the project instead.")
        if holders:
            reason = (f"{', '.join(h.get('name') or 'An editor' for h in holders)} has this project open but is "
                      "serving no reachable live channel. Turn it on in the app's settings; it starts at once.")
        return {"status": "unavailable", "documents": [], "discovery": attempts,
                "held_by": [{k: v for k, v in h.items() if k != "endpoint"} for h in holders], "reason": reason}
    live = Session(transport=LiveTransport(info))
    try:
        return {"status": "connected", "endpoint": live.transport.path, "documents": live.live_state(),
                "discovery": attempts, "held_by": [{k: v for k, v in h.items() if k != "endpoint"} for h in holders]}
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
def show_panes(panes: list[str], path: str | None = None) -> dict[str, Any]:
    """Show these panes in the app's window and hide the rest: schematic, board, threeD, parts, library.
    Replaces what is showing rather than adding to it. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there are no panes to show.")
    return project.show_panes(panes)


@_tool
def show_sheet(path: str | None = None, sheet: int | None = None, name: str | None = None, sheet_id: str | None = None, block_id: str | None = None) -> dict[str, Any]:
    """Show a schematic sheet in the app's schematic pane, by index, name or id. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is no sheet to show.")
    return project.show_sheet(sheet=sheet, name=name, sheet_id=sheet_id, block_id=block_id)


@_tool
def show_layers(preset: str, path: str | None = None) -> dict[str, Any]:
    """Show a board layer view in the app: top_placement, top_silkscreen, top_routing, bottom_placement,
    bottom_silkscreen, bottom_routing, top_view, bottom_view (mirrored), flip_view, placement, silkscreen, routing
    (the side that is up), all, copper_only or clean. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there are no layers to show.")
    return project.show_layers(preset)


@_tool
def zoom(path: str | None = None, factor: float = 2, pane: str | None = None) -> dict[str, Any]:
    """Zoom a pane's view in the app about its centre: 2 is twice as close, 0.5 twice as far, 0 fits everything; pane
    board, schematic or threeD, else the one the user is working in. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is no view to zoom.")
    return project.zoom(factor=factor, pane=pane)


@_tool
def list_ops(path: str | None = None) -> list[dict[str, Any]]:
    """The edit operations apply_ops accepts, with their parameters. They cover the block, the schematic, board
    placement and manual copper routing; nothing here autoroutes."""
    return _resolve(path).list_ops()


@_tool
def apply_ops(ops: list[EditOperation], path: str | None = None, dry_run: bool = False,
              pool_items: list[dict[str, Any]] | None = None, block: str | None = None) -> dict[str, Any]:
    """Apply edit operations. Each op is {"op": name, ...params}; see list_ops. Components and nets may be named by
    refdes or net name. When the project is open in Horizontal the edit lands there as one undoable step; a project
    open in an editor cannot be edited on disk at all, and the attempt fails with DOCUMENT_OPEN naming the holder.
    dry_run validates without changing anything and reports any holder in blocked_by.

    What these ops cover: the block (components, nets, connections), schematic symbols, the wires between their
    pins, free text on the sheets, board package placement, and copper — tracks and vias. Routing here is manual:
    place_track draws the segment it is told to draw and does not find a path, and nothing autoroutes. check
    reports what is still unrouted.

    block selects which block to edit; without it, the top one. A sub-block's components are instantiated
    wherever that block is used, so it has no board of its own and board operations on one are refused.

    Pins are named by name or uuid, whole names first, so PA13(JTMS/SWDIO) works; a wire end can name a
    component and pin instead of a symbol instance. Cleanup: remove_net_line, remove_junction, prune_sheet,
    remove_sheet with force, and retire_net, which takes the net's labels, wires, junctions and planes with it. Drawing:
    terminate_pin runs a stub from a pin to a label or power symbol. set_no_connect marks unused pins;
    remap_part matches pins by name when pin_map is left out. Refer to sheets by name or uuid in a batch that
    adds or reorders sheets — page numbers move.

    An op that makes something — place_junction, place_symbol, draw_net_line, place_text, place_board_text,
    ensure_component, ensure_net and the add_ ops — may give a short name as its id instead of a UUID
    ("id": "j1"), and later ops in the batch use that name where they refer to that kind of thing
    ({"kind": "junction", "junction": "j1"}; remove_text's id). The reply's handles maps each name to the UUID it
    became. A failing op is named in the error: "ops[3] place_junction: …", and so is a name it involved, with
    the earlier op that removed the thing if one did — removing a wire takes the junctions it leaves bare.

    Texts: place_text and place_board_text also change a text that is already there. Name it by the id list_texts
    or list_board_texts gives, and pass only what changes: x_mm, y_mm or both move it, and it keeps its uuid, its
    layer and everything else. A text smashed out of a symbol or package moves with its part instead.

    Project: set_project_meta sets the title-block values — project_title, rev and the rest, what $project_title
    stands for on the sheets and the board. set_export_settings changes the export settings Horizon EDA keeps
    in the project; export_settings shows them.

    The reply is compact unless verbose: per op, its ids, scalars and counts, plus timing. A slow live commit
    is waited for (HORIZONTAL_MUTATION_TIMEOUT seconds, 180 by default), and a lost reply is resolved through
    transaction_status before this returns."""
    # by_alias: a track end is spelled "from", which is a Swift and Python keyword.
    encoded = [op.model_dump(exclude_unset=True, by_alias=True) if isinstance(op, BaseModel) else op for op in ops]
    return _edit(_resolve(path), encoded, dry_run=dry_run, pool_items=pool_items, block=block)


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
    """Place a component's package on the board, or move or rotate it if it is already placed. Its connections stay
    airwires until something routes them: place_track and place_via draw copper one segment at a time, and
    copy_group_layout clones the routing an already-laid-out group has."""
    fields = {k: v for k, v in {"x_mm": x_mm, "y_mm": y_mm, "angle_deg": angle_deg, "bottom": bottom}.items() if v is not None}
    return _edit(_resolve(path), [{"op": "place_component", "component": refdes, **fields}])


@_tool
def render_sheet(path: str | None = None, sheet: int | None = None, name: str | None = None, region: Region | None = None, dpi: float = 110, sheet_id: str | None = None, block_id: str | None = None) -> dict[str, Any]:
    """Render one schematic sheet as a PNG image (by index or name; default the first sheet). region {min_x_mm, min_y_mm, max_x_mm, max_y_mm} renders only that part, at higher effective detail."""
    params = {k: v for k, v in {"sheet": sheet, "name": name, "region": region.model_dump() if region else None, "sheet_id": sheet_id, "block_id": block_id}.items() if v is not None}
    return _resolve(path)._call("render_sheet", dpi=dpi, max_pixels=2400, **params)


@_tool
def render_board(path: str | None = None,
                 layers: Annotated[list[str] | None, Field(description="Names from board_info.drawing_layers; use layers or layer_ids. Empty uses defaults.")] = None,
                 mirrored: bool = False, region: Region | None = None, dpi: float = 110,
                 layer_ids: Annotated[list[StrictInt] | None, Field(description="Integer IDs from board_info.drawing_layers, e.g. [0, -100]. Empty uses defaults.")] = None) -> dict[str, Any]:
    """Render the board drawing as a PNG image. Pass layer names from board_info to choose layers; mirrored views it from the bottom; region {min_x_mm, min_y_mm, max_x_mm, max_y_mm} renders only that part."""
    params = {k: v for k, v in {"layers": layers, "region": region.model_dump() if region else None}.items() if v is not None}
    if layers is not None and layer_ids is not None:
        raise ValueError("Use layers or layer_ids, not both.")
    if layer_ids is not None:
        params["layer_ids"] = layer_ids
    return _resolve(path)._call("render_board", mirrored=mirrored, dpi=dpi, max_pixels=2400, **params)


@_tool
def zoom_to(path: str | None = None, refdes: str | None = None, net: str | None = None, pane: str | None = None, margin_mm: float = 3,
            components: list[str] | None = None, nets: list[str] | None = None) -> dict[str, Any]:
    """Frame a component (refdes) or a net in the app's board or schematic pane; pane "all" frames it in every pane
    that is showing and can show it, the 3D view included. Needs the project open in Horizontal."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is no pane to zoom.")
    return project.zoom_to(refdes=refdes, net=net, pane=pane, margin_mm=margin_mm, components=components, nets=nets)


@_tool
def render_viewport(path: str | None = None, pane: str = "board", dpi: float = 110, airwires: bool | None = None,
                    region: Region | None = None) -> dict[str, Any]:
    """Render what the app's board or schematic pane currently shows, as a PNG in the exporter's drawing style. Needs the project open in Horizontal.

    On the board the airwires are drawn over it, dashed in blue, when the pane's Connections switch shows them:
    the ones the board canvas draws, which the exporter does not. airwires=true draws them with the switch off,
    false leaves them off. airwires in the reply says whose they are (source "canvas", or "connectivity" when the
    canvas gave none), how many are in view, whether the switch shows them (shown), whether this picture has
    them (drawn), and matches_check: whether they are the ones check reports, with the nets that differ.

    A fitted pane spends much of the picture on margins and notes; region {min_x_mm, min_y_mm, max_x_mm,
    max_y_mm} renders only that part of what it shows, as large as the whole view would be, so in more detail. The reply
    gives view (what the pane shows), region (what was drawn) and px_per_mm."""
    project = _resolve(path)
    if not project.is_live:
        raise ValueError("The project is not open in Horizontal, so there is no viewport to render.")
    params: dict[str, Any] = {}
    if airwires is not None:
        params["airwires"] = airwires
    if region is not None:
        params["region"] = region.model_dump()
    return project._call("render_viewport", pane=pane, dpi=dpi, max_pixels=2400, **params)


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
