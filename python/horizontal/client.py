"""A thin Pythonic layer over the dispatch methods."""

from __future__ import annotations

import base64
import itertools
from pathlib import Path
from typing import Any

from ._native import HorizontalError, LiveTransport, Transport, default_transport, find_live


class Session:
    """One connection to the engine; holds the open projects."""

    def __init__(self, transport: Transport | None = None, isolated: bool = False):
        self.transport = transport or default_transport(isolated=isolated)
        self._ids = itertools.count(1)

    @classmethod
    def live(cls) -> "Session | None":
        """A session on the running app's live channel, or None when the app is not up."""
        info = find_live()
        return cls(transport=LiveTransport(info)) if info else None

    @property
    def is_live(self) -> bool:
        return isinstance(self.transport, LiveTransport)

    def call(self, method: str, **params: Any) -> Any:
        request = {"jsonrpc": "2.0", "id": next(self._ids), "method": method, "params": params}
        response = self.transport.call(request)
        if "error" in response:
            error = response["error"]
            raise HorizontalError(error.get("code", -32603), error.get("message", "Unknown error"), error.get("data"))
        return response.get("result")

    def version(self) -> dict[str, Any]:
        return self.call("version")

    def methods(self) -> list[dict[str, Any]]:
        return self.call("methods")

    def open(self, path: str | Path) -> "Project":
        summary = self.call("open_project", path=str(Path(path).expanduser()))
        return Project(self, summary)

    def new_project(self, path: str | Path, name: str | None = None) -> "Project":
        """Create a project from the template as a .horizontal package and open it."""
        params: dict[str, Any] = {"path": str(Path(path).expanduser())}
        if name:
            params["name"] = name
        return Project(self, self.call("new_project", **params))

    def projects(self) -> list["Project"]:
        return [Project(self, summary) for summary in self.call("list_projects")]

    def live_state(self) -> list[dict[str, Any]]:
        """The documents open in the app with their selection; live sessions only."""
        return self.call("live_state")

    def close(self) -> None:
        self.transport.close()


class Project:
    """An open project. Every method returns plain dicts and lists."""

    def __init__(self, session: Session, summary: dict[str, Any]):
        self.session = session
        self.summary = summary
        self.handle: int = summary["handle"]

    def __repr__(self) -> str:
        return f"Project({self.summary.get('title')!r}, handle={self.handle})"

    def __enter__(self) -> "Project":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def _call(self, method: str, **params: Any) -> Any:
        return self.session.call(method, handle=self.handle, **params)

    @property
    def path(self) -> str:
        return self.summary["path"]

    @property
    def is_live(self) -> bool:
        """True when this handle is a document open in the app."""
        return bool(self.summary.get("live"))

    def select(self, components: list[str] | None = None, nets: list[str] | None = None) -> dict[str, Any]:
        """Select components (by refdes) and nets (by name) in the app; live documents only."""
        return self._call("select", components=list(components or []), nets=list(nets or []))

    def highlight(self, components: list[str] | None = None, nets: list[str] | None = None) -> dict[str, Any]:
        """Highlight components and nets in the app's canvases; empty clears. Live documents only."""
        return self._call("highlight", components=list(components or []), nets=list(nets or []))

    @property
    def title(self) -> str:
        return self.summary["title"]

    def info(self) -> dict[str, Any]:
        self.summary = self._call("project_info")
        return self.summary

    def files(self) -> dict[str, Any]:
        return self._call("project_files")

    def reload(self) -> dict[str, Any]:
        self.summary = self._call("reload_project")
        return self.summary

    def close(self) -> None:
        self._call("close_project")

    def sheets(self) -> list[dict[str, Any]]:
        return self._call("list_sheets")

    def components(self, sheet: int | None = None) -> list[dict[str, Any]]:
        params = {"sheet": sheet} if sheet is not None else {}
        return self._call("list_components", **params)

    def component(self, refdes: str | None = None, id: str | None = None) -> dict[str, Any]:
        params = {"refdes": refdes} if refdes else {"id": id}
        return self._call("get_component", **params)

    def nets(self) -> list[dict[str, Any]]:
        return self._call("list_nets")

    def net(self, name: str | None = None, id: str | None = None) -> dict[str, Any]:
        params = {"name": name} if name else {"id": id}
        return self._call("get_net", **params)

    def netlist(self, include_unconnected: bool = False) -> dict[str, Any]:
        return self._call("netlist", include_unconnected=include_unconnected)

    def bom(self, include_no_populate: bool = True) -> dict[str, Any]:
        return self._call("bom", include_no_populate=include_no_populate)

    def parts(self) -> list[dict[str, Any]]:
        return self._call("list_parts")

    def board_info(self) -> dict[str, Any]:
        return self._call("board_info")

    def check(self) -> dict[str, Any]:
        return self._call("check")

    # Edits: operations as data, applied to the project files and reloaded.

    def list_ops(self) -> list[dict[str, Any]]:
        """The edit vocabulary `apply` accepts."""
        return self.session.call("list_ops")

    def apply(self, ops: list[dict[str, Any]], dry_run: bool = False) -> dict[str, Any]:
        """Apply edit operations; each is {"op": name, ...params}. Writes only changed files."""
        result = self._call("apply", ops=list(ops), dry_run=dry_run)
        if not dry_run and "project" in result:
            self.summary = result["project"]
        return result

    def ensure_component(self, refdes: str | None = None, part: str | None = None, entity: str | None = None, **fields: Any) -> str:
        op: dict[str, Any] = {"op": "ensure_component", **fields}
        if refdes is not None:
            op["refdes"] = refdes
        if part is not None:
            op["part"] = part
        if entity is not None:
            op["entity"] = entity
        return self.apply([op])["changes"][0]["component"]

    def ensure_net(self, name: str, **fields: Any) -> str:
        return self.apply([{"op": "ensure_net", "name": name, **fields}])["changes"][0]["net"]

    def set_value(self, component: str, value: str) -> dict[str, Any]:
        return self.apply([{"op": "set_value", "component": component, "value": value}])

    def rename_net(self, net: str, name: str) -> dict[str, Any]:
        return self.apply([{"op": "rename_net", "net": net, "name": name}])

    def connect(self, component: str, pin: str, net: str, create_net: bool = False) -> dict[str, Any]:
        return self.apply([{"op": "connect", "component": component, "pin": pin, "net": net, "create_net": create_net}])

    def place(self, component: str, x_mm: float | None = None, y_mm: float | None = None, angle_deg: float | None = None, bottom: bool | None = None) -> dict[str, Any]:
        op: dict[str, Any] = {"op": "place_component", "component": component}
        for key, value in (("x_mm", x_mm), ("y_mm", y_mm), ("angle_deg", angle_deg), ("bottom", bottom)):
            if value is not None:
                op[key] = value
        return self.apply([op])

    def remove_component(self, component: str) -> dict[str, Any]:
        return self.apply([{"op": "remove_component", "component": component}])

    def pool_write(self, items: list[dict[str, Any]]) -> dict[str, Any]:
        """Write pool items (unit, entity, symbol, part, package, padstack) into the project pool."""
        return self._call("pool_write", items=list(items))

    def recompute_connectivity(self) -> dict[str, Any]:
        """The editor's post-edit connectivity pass; `open` already ran it once."""
        return self._call("recompute_connectivity")

    def export(self, sections: list[str], target_directory: str | Path | None = None, **options: Any) -> dict[str, Any]:
        params: dict[str, Any] = {"sections": list(sections)}
        if target_directory is not None:
            params["target_directory"] = str(target_directory)
        if options:
            params["options"] = options
        return self._call("export", **params)

    def render_sheet(
        self,
        sheet: int | None = None,
        name: str | None = None,
        sheet_id: str | None = None,
        region: dict[str, float] | None = None,
        dpi: float = 150,
        max_pixels: int = 4096,
        output_path: str | Path | None = None,
    ) -> bytes | Path:
        """A sheet as PNG bytes, or the path written. `region` is
        {"min_x_mm", "min_y_mm", "max_x_mm", "max_y_mm"} to render part of it."""
        params: dict[str, Any] = {"dpi": dpi, "max_pixels": max_pixels}
        if sheet is not None:
            params["sheet"] = sheet
        if name is not None:
            params["name"] = name
        if sheet_id is not None:
            params["sheet_id"] = sheet_id
        if region is not None:
            params["region"] = region
        if output_path is not None:
            params["output_path"] = str(output_path)
        result = self._call("render_sheet", **params)
        return _image_result(result)

    def render_board(
        self,
        layers: list[str] | None = None,
        mirrored: bool = False,
        region: dict[str, float] | None = None,
        dpi: float = 150,
        max_pixels: int = 4096,
        output_path: str | Path | None = None,
    ) -> bytes | Path:
        """The board drawing as PNG bytes, or the path written; `region` as for render_sheet."""
        params: dict[str, Any] = {"dpi": dpi, "max_pixels": max_pixels, "mirrored": mirrored}
        if layers:
            params["layers"] = list(layers)
        if region is not None:
            params["region"] = region
        if output_path is not None:
            params["output_path"] = str(output_path)
        result = self._call("render_board", **params)
        return _image_result(result)

    # Live documents only: the app's canvases.

    def zoom_to(self, refdes: str | None = None, net: str | None = None, pane: str | None = None, margin_mm: float = 3) -> dict[str, Any]:
        """Frame a component or net in the app's board or schematic pane."""
        params: dict[str, Any] = {"margin_mm": margin_mm}
        if refdes is not None:
            params["refdes"] = refdes
        if net is not None:
            params["net"] = net
        if pane is not None:
            params["pane"] = pane
        return self._call("zoom_to", **params)

    def render_viewport(self, pane: str = "board", dpi: float = 150, max_pixels: int = 4096, output_path: str | Path | None = None) -> bytes | Path:
        """What the app's pane shows right now, rendered in the exporter's style."""
        params: dict[str, Any] = {"pane": pane, "dpi": dpi, "max_pixels": max_pixels}
        if output_path is not None:
            params["output_path"] = str(output_path)
        return _image_result(self._call("render_viewport", **params))

    # Groups: Horizon's instances of a sub-circuit.

    def groups(self) -> list[dict[str, Any]]:
        """Groups with their members by tag and whether each is placed."""
        return self._call("list_groups")

    def copy_group_layout(self, source: str, target: str, x_mm: float | None = None, y_mm: float | None = None, angle_deg: float | None = None, include_routing: bool = True) -> dict[str, Any]:
        """Lay the target group out like the source group: placement of every member with a matching tag, and by default the routing between them."""
        op: dict[str, Any] = {"op": "copy_group_layout", "source": source, "target": target, "include_routing": include_routing}
        for key, value in (("x_mm", x_mm), ("y_mm", y_mm), ("angle_deg", angle_deg)):
            if value is not None:
                op[key] = value
        return self.apply([op])


def _image_result(result: dict[str, Any]) -> bytes | Path:
    if "error" in result:
        raise HorizontalError(-32000, result["error"])
    if "path" in result:
        return Path(result["path"])
    return base64.b64decode(result["png_base64"])


_default_session: Session | None = None
_live_session: Session | None = None


def new_project(path: str | Path, name: str | None = None, isolated: bool = False) -> Project:
    """Create a project from the template (a .horizontal package) and open it in this process."""
    global _default_session
    if _default_session is None:
        _default_session = Session(isolated=isolated)
    return _default_session.new_project(path, name=name)


def open(path: str | Path, isolated: bool = False, prefer_live: bool = True) -> Project:
    """Open a project. When Horizontal has it open, the app's live document is used
    (reads see unsaved edits; writes land on its undo stack); otherwise the engine
    in this process opens the files."""
    global _default_session, _live_session
    resolved = str(Path(path).expanduser().resolve())
    if prefer_live:
        if _live_session is None:
            _live_session = Session.live()
        if _live_session is not None:
            try:
                for summary in _live_session.call("list_projects"):
                    if summary.get("live") and Path(summary["path"]).resolve() == Path(resolved):
                        return Project(_live_session, summary)
            except HorizontalError:
                _live_session = None
    if _default_session is None:
        _default_session = Session(isolated=isolated)
    return _default_session.open(resolved)
