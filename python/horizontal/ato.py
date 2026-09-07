"""horizontal-ato: bring an atopile build into a Horizontal project.

atopile writes its design to a KiCad board file: every footprint carries an
`atopile_address` property, its part (LCSC, manufacturer, part number,
value, datasheet), and pads with their nets. That file is the seam. This
tool reads it, turns each distinct footprint into Horizon pool items (unit,
entity, symbol, part, package, padstacks) with ids derived from the design so
the same input always yields the same ids, and turns the component list and
netlist into edit operations for the dispatcher. Nets are matched to the
project's existing nets by the pads on them, so a renamed net keeps its
tracks; atopile's module path becomes Horizon's group and tag, the fields
Horizon uses to copy placement between identical sub-circuits.

    horizontal-ato sync build/default/design.kicad_pcb project.horizontal --create

Works headless or against the document open in Horizontal (the edit then
lands on its undo stack).
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import uuid as uuidlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import client as horizontal_client
from ._native import HorizontalError

NAMESPACE = uuidlib.UUID("2d7f1c46-6f8b-4f7c-9a0d-31d4e9c5a7b1")
NULL_UUID = "00000000-0000-0000-0000-000000000000"
NM = 1_000_000
ANGLE_UNITS = 65_536

# Horizon layer numbers.
TOP_COPPER = 0
BOTTOM_COPPER = -100
INNER = [-1, -2]
TOP_MASK, BOTTOM_MASK = 10, -110
TOP_SILK = 20
TOP_PASTE = 30
TOP_ASSEMBLY = 40
TOP_PACKAGE = 50
TOP_COURTYARD = 60


def uuid5(kind: str, key: str) -> str:
    return str(uuidlib.uuid5(NAMESPACE, f"{kind}:{key}"))


def nm(mm: float) -> int:
    return int(round(mm * NM))


def angle_units(degrees: float) -> int:
    return int(round(degrees / 360 * ANGLE_UNITS)) % ANGLE_UNITS


# --- S-expressions -----------------------------------------------------------

_TOKEN = re.compile(r'\s*(?:(\()|(\))|"((?:[^"\\]|\\.)*)"|([^\s()"]+))', re.S)


def parse_sexpr(text: str) -> Any:
    """KiCad's s-expression file as nested lists; atoms are str, int, or float."""
    stack: list[list[Any]] = [[]]
    pos = 0
    length = len(text)
    while pos < length:
        match = _TOKEN.match(text, pos)
        if not match or match.end() == pos:
            if text[pos:].strip() == "":
                break
            raise ValueError(f"Unparseable s-expression near offset {pos}: {text[pos:pos+40]!r}")
        pos = match.end()
        opener, closer, quoted, atom = match.groups()
        if opener:
            stack.append([])
        elif closer:
            node = stack.pop()
            stack[-1].append(node)
        elif quoted is not None:
            stack[-1].append(quoted.replace('\\"', '"').replace("\\\\", "\\"))
        else:
            value: Any = atom
            try:
                value = int(atom)
            except ValueError:
                try:
                    value = float(atom)
                except ValueError:
                    pass
            stack[-1].append(value)
    if len(stack) != 1:
        raise ValueError("Unbalanced parentheses in s-expression.")
    return stack[0]


def children(node: list[Any], name: str) -> list[list[Any]]:
    return [child for child in node[1:] if isinstance(child, list) and child and child[0] == name]


def child(node: list[Any], name: str) -> list[Any] | None:
    found = children(node, name)
    return found[0] if found else None


# --- KiCad board model ---------------------------------------------------------

@dataclass
class Pad:
    name: str
    kind: str          # smd, thru_hole, np_thru_hole
    shape: str         # rect, roundrect, oval, circle, custom
    x: float           # footprint-local mm, KiCad axes
    y: float
    rot: float         # degrees, footprint-local
    w: float
    h: float
    drill: tuple[float, float] | None
    layers: list[str]
    net: str | None
    rratio: float = 0.25


@dataclass
class Footprint:
    lib_id: str
    uuid: str
    layer: str
    x: float
    y: float
    rot: float
    props: dict[str, str]
    pads: list[Pad] = field(default_factory=list)
    silk_lines: list[tuple[tuple[float, float], tuple[float, float], float]] = field(default_factory=list)
    courtyard: tuple[float, float, float, float] | None = None

    @property
    def address(self) -> str:
        return self.props.get("atopile_address") or self.props.get("Reference") or self.uuid

    @property
    def refdes(self) -> str:
        return self.props.get("Reference", "")

    @property
    def bottom(self) -> bool:
        return self.layer.startswith("B.")

    @property
    def footprint_name(self) -> str:
        return self.lib_id.split(":", 1)[1] if ":" in self.lib_id else self.lib_id

    @property
    def library(self) -> str:
        return self.lib_id.split(":", 1)[0] if ":" in self.lib_id else ""


def _at(node: list[Any]) -> tuple[float, float, float]:
    at = child(node, "at")
    if not at:
        return (0.0, 0.0, 0.0)
    values = [float(v) for v in at[1:] if isinstance(v, (int, float))]
    while len(values) < 3:
        values.append(0.0)
    return (values[0], values[1], values[2])


def _xy(node: list[Any] | None) -> tuple[float, float]:
    if not node:
        return (0.0, 0.0)
    return (float(node[1]), float(node[2]))


def read_kicad_pcb(path: Path) -> tuple[list[Footprint], dict[int, str]]:
    root = parse_sexpr(path.read_text(encoding="utf-8"))
    board = next(node for node in root if isinstance(node, list) and node and node[0] == "kicad_pcb")
    nets = {int(n[1]): str(n[2]) for n in children(board, "net") if len(n) >= 3}
    footprints: list[Footprint] = []
    for node in children(board, "footprint"):
        lib_id = str(node[1]) if len(node) > 1 and isinstance(node[1], str) else ""
        layer_node = child(node, "layer")
        layer = str(layer_node[1]) if layer_node else "F.Cu"
        fp_uuid_node = child(node, "uuid") or child(node, "tstamp")
        fp_uuid = str(fp_uuid_node[1]) if fp_uuid_node else uuid5("footprint", lib_id + str(len(footprints)))
        x, y, rot = _at(node)
        props: dict[str, str] = {}
        for prop in children(node, "property"):
            if len(prop) >= 3 and isinstance(prop[1], str):
                props[prop[1]] = str(prop[2]) if not isinstance(prop[2], list) else ""
        footprint = Footprint(lib_id=lib_id, uuid=fp_uuid, layer=layer, x=x, y=y, rot=rot, props=props)
        for pad_node in children(node, "pad"):
            name = str(pad_node[1])
            kind = str(pad_node[2])
            shape = str(pad_node[3])
            px, py, prot = _at(pad_node)
            size = child(pad_node, "size")
            w, h = (float(size[1]), float(size[2])) if size else (0.0, 0.0)
            drill_node = child(pad_node, "drill")
            drill: tuple[float, float] | None = None
            if drill_node:
                numbers = [float(v) for v in drill_node[1:] if isinstance(v, (int, float))]
                if numbers:
                    drill = (numbers[0], numbers[1] if len(numbers) > 1 else numbers[0])
            layers_node = child(pad_node, "layers")
            layers = [str(v) for v in layers_node[1:]] if layers_node else []
            net_node = child(pad_node, "net")
            net = str(net_node[2]) if net_node and len(net_node) >= 3 else None
            ratio_node = child(pad_node, "roundrect_rratio")
            ratio = float(ratio_node[1]) if ratio_node else 0.25
            local_rot = (prot - rot) % 360
            footprint.pads.append(Pad(name, kind, shape, px, py, local_rot, w, h, drill, layers, net or None, ratio))
        crt: list[tuple[float, float]] = []
        for line in children(node, "fp_line"):
            layer_of = child(line, "layer")
            stroke = child(line, "stroke")
            width = float(child(stroke, "width")[1]) if stroke and child(stroke, "width") else 0.12
            start, end = _xy(child(line, "start")), _xy(child(line, "end"))
            if layer_of and layer_of[1] == "F.SilkS":
                footprint.silk_lines.append((start, end, width))
            elif layer_of and layer_of[1] == "F.CrtYd":
                crt.extend([start, end])
        for rect in children(node, "fp_rect"):
            layer_of = child(rect, "layer")
            stroke = child(rect, "stroke")
            width = float(child(stroke, "width")[1]) if stroke and child(stroke, "width") else 0.12
            (x1, y1), (x2, y2) = _xy(child(rect, "start")), _xy(child(rect, "end"))
            corners = [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]
            if layer_of and layer_of[1] == "F.SilkS":
                for i in range(4):
                    footprint.silk_lines.append((corners[i], corners[(i + 1) % 4], width))
            elif layer_of and layer_of[1] == "F.CrtYd":
                crt.extend(corners)
        if crt:
            xs = [p[0] for p in crt]
            ys = [p[1] for p in crt]
            footprint.courtyard = (min(xs), min(ys), max(xs), max(ys))
        footprints.append(footprint)
    return footprints, nets


# --- Horizon pool items --------------------------------------------------------

def _placement(x_nm: int = 0, y_nm: int = 0, angle: int = 0) -> dict[str, Any]:
    return {"angle": angle, "mirror": False, "shift": [x_nm, y_nm]}


def _shape(form: str, params: list[int], layer: int, parameter_class: str) -> dict[str, Any]:
    return {"form": form, "layer": layer, "parameter_class": parameter_class, "params": params, "placement": _placement()}


def padstack_for(pad: Pad) -> tuple[str, dict[str, Any]]:
    """A padstack with explicit shapes for this pad's geometry. Keyed by the
    geometry, so equal pads across footprints share one padstack."""
    mask_expansion = nm(0.1)
    w, h = nm(pad.w), nm(pad.h)
    shapes: dict[str, dict[str, Any]] = {}
    holes: dict[str, dict[str, Any]] = {}
    if pad.kind == "np_thru_hole":
        kind = "mechanical"
        diameter = nm(pad.drill[0]) if pad.drill else w
        key = f"mech:{diameter}"
        holes[uuid5("hole", key)] = {"diameter": diameter, "length": diameter, "parameter_class": "hole", "placement": _placement(), "plated": False, "shape": "round"}
        for layer in (TOP_MASK, BOTTOM_MASK):
            shapes[uuid5("shape", f"{key}:mask:{layer}")] = _shape("circle", [diameter + 2 * mask_expansion], layer, "mask")
        name = f"Mechanical hole {pad.drill[0] if pad.drill else pad.w:g} mm"
    elif pad.kind == "thru_hole":
        kind = "through"
        drill_w, drill_h = pad.drill or (min(pad.w, pad.h) / 2, min(pad.w, pad.h) / 2)
        slot = abs(drill_w - drill_h) > 1e-6
        key = f"th:{pad.shape}:{w}:{h}:{nm(drill_w)}:{nm(drill_h)}"
        holes[uuid5("hole", key)] = {
            "diameter": nm(min(drill_w, drill_h)), "length": nm(max(drill_w, drill_h)),
            "parameter_class": "hole", "placement": _placement(), "plated": True,
            "shape": "slot" if slot else "round",
        }
        form = "circle" if pad.shape == "circle" else ("obround" if pad.shape == "oval" else "rectangle")
        params = [max(w, h)] if form == "circle" else [w, h]
        for layer in [TOP_COPPER, BOTTOM_COPPER, *INNER]:
            shapes[uuid5("shape", f"{key}:copper:{layer}")] = _shape(form, params, layer, "copper")
        mask_params = [params[0] + 2 * mask_expansion] if form == "circle" else [w + 2 * mask_expansion, h + 2 * mask_expansion]
        for layer in (TOP_MASK, BOTTOM_MASK):
            shapes[uuid5("shape", f"{key}:mask:{layer}")] = _shape(form, mask_params, layer, "mask")
        name = f"TH {pad.shape} {pad.w:g}x{pad.h:g} drill {drill_w:g}" + (f"x{drill_h:g}" if slot else "")
    else:
        kind = "bottom" if pad.layers and pad.layers[0].startswith("B.") else "top"
        key = f"smd:{pad.shape}:{w}:{h}:{kind}"
        form = "circle" if pad.shape == "circle" else ("obround" if pad.shape == "oval" else "rectangle")
        params = [max(w, h)] if form == "circle" else [w, h]
        copper, mask, paste = (TOP_COPPER, TOP_MASK, TOP_PASTE) if kind == "top" else (BOTTOM_COPPER, BOTTOM_MASK, -130)
        shapes[uuid5("shape", f"{key}:pad")] = _shape(form, params, copper, "pad")
        mask_params = [params[0] + 2 * mask_expansion] if form == "circle" else [w + 2 * mask_expansion, h + 2 * mask_expansion]
        shapes[uuid5("shape", f"{key}:mask")] = _shape(form, mask_params, mask, "mask")
        if any(layer.endswith("Paste") for layer in pad.layers) or not pad.layers:
            shapes[uuid5("shape", f"{key}:paste")] = _shape(form, params, paste, "paste")
        name = f"SMD {pad.shape} {pad.w:g}x{pad.h:g}"
    padstack_uuid = uuid5("padstack", key)
    return padstack_uuid, {
        "holes": holes,
        "name": name,
        "padstack_type": kind,
        "parameter_program": "",
        "parameter_set": {},
        "parameters_required": [],
        "polygons": {},
        "shapes": shapes,
        "type": "padstack",
        "uuid": padstack_uuid,
        "well_known_name": "",
    }


def _footprint_key(fp: Footprint) -> str:
    pads = sorted((p.name, p.kind, p.shape, round(p.x, 4), round(p.y, 4), round(p.rot, 2), round(p.w, 4), round(p.h, 4), p.drill) for p in fp.pads)
    return fp.lib_id + "|" + json.dumps(pads, sort_keys=True)


def package_for(fp: Footprint, padstacks: dict[str, dict[str, Any]]) -> tuple[str, dict[str, Any], dict[str, str]]:
    """The Horizon package for a footprint: pads referencing padstacks, the
    silkscreen, a courtyard, and the refdes texts. Returns the package,
    plus pad name to pad uuid."""
    key = _footprint_key(fp)
    package_uuid = uuid5("package", key)
    pads: dict[str, dict[str, Any]] = {}
    pad_uuids: dict[str, str] = {}
    for pad in fp.pads:
        padstack_uuid, padstack = padstack_for(pad)
        padstacks[padstack_uuid] = padstack
        pad_uuid = uuid5("pad", f"{key}|{pad.name}|{pad.x}|{pad.y}")
        pads[pad_uuid] = {
            "name": pad.name,
            "padstack": padstack_uuid,
            "parameter_set": {},
            "placement": _placement(nm(pad.x), -nm(pad.y), angle_units(pad.rot)),
        }
        pad_uuids.setdefault(pad.name, pad_uuid)
    junctions: dict[str, dict[str, Any]] = {}
    lines: dict[str, dict[str, Any]] = {}

    def junction(point: tuple[float, float]) -> str:
        jid = uuid5("junction", f"{key}|{point[0]:.4f}|{point[1]:.4f}")
        junctions[jid] = {"position": [nm(point[0]), -nm(point[1])]}
        return jid

    for index, (start, end, width) in enumerate(fp.silk_lines):
        lines[uuid5("line", f"{key}|silk|{index}")] = {"from": junction(start), "to": junction(end), "layer": TOP_SILK, "width": nm(width)}
    if fp.courtyard:
        x1, y1, x2, y2 = fp.courtyard
    else:
        xs = [p.x + p.w / 2 for p in fp.pads] + [p.x - p.w / 2 for p in fp.pads] or [0.0]
        ys = [p.y + p.h / 2 for p in fp.pads] + [p.y - p.h / 2 for p in fp.pads] or [0.0]
        x1, y1, x2, y2 = min(xs) - 0.25, min(ys) - 0.25, max(xs) + 0.25, max(ys) + 0.25
    courtyard = {
        "layer": TOP_COURTYARD,
        "parameter_class": "courtyard",
        "vertices": [
            {"arc_center": [0, 0], "arc_reverse": False, "position": [nm(x), -nm(y)], "type": "line"}
            for x, y in ((x1, y1), (x2, y1), (x2, y2), (x1, y2))
        ],
    }
    refdes_y = -nm(y1) + nm(1.0)
    package = {
        "arcs": {},
        "default_model": NULL_UUID,
        "dimensions": {},
        "junctions": junctions,
        "keepouts": {},
        "lines": lines,
        "manufacturer": fp.props.get("Manufacturer", ""),
        "models": {},
        "name": f"{fp.footprint_name} ({fp.library})" if fp.library else fp.footprint_name,
        "pads": pads,
        "parameter_program": "",
        "parameter_set": {},
        "polygons": {uuid5("polygon", f"{key}|courtyard"): courtyard},
        "rules": {},
        "tags": ["atopile", fp.library] if fp.library else ["atopile"],
        "texts": {
            uuid5("text", f"{key}|rd-silk"): {"font": "simplex", "from_smash": False, "layer": TOP_SILK, "origin": "center", "placement": _placement(0, refdes_y), "size": nm(1.0), "text": "$RD", "width": nm(0.15)},
            uuid5("text", f"{key}|rd-package"): {"font": "simplex", "from_smash": False, "layer": TOP_PACKAGE, "origin": "center", "placement": _placement(), "size": nm(0.3), "text": "$RD", "width": 0},
        },
        "type": "package",
        "uuid": package_uuid,
    }
    return package_uuid, package, pad_uuids


def _pin_direction(name: str) -> str:
    upper = name.upper()
    if upper in {"GND", "VSS", "VEE", "AGND", "DGND", "PGND"}:
        return "power_input"
    if upper.startswith(("VCC", "VDD", "VBAT", "VIN", "V+")):
        return "power_input"
    return "passive"


def unit_entity_symbol_for(fp: Footprint) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, str], str]:
    """One unit (a pin per distinct pad name), an entity with a Main gate,
    and a box symbol with the pins down its two sides."""
    key = fp.lib_id + "|" + "|".join(sorted({p.name for p in fp.pads}))
    unit_uuid = uuid5("unit", key)
    entity_uuid = uuid5("entity", key)
    symbol_uuid = uuid5("symbol", key)
    gate_uuid = uuid5("gate", key)
    names = sorted({p.name for p in fp.pads}, key=lambda n: (len(n), n))
    pin_uuids = {name: uuid5("pin", f"{key}|{name}") for name in names}
    unit = {
        "manufacturer": fp.props.get("Manufacturer", ""),
        "name": fp.library or fp.footprint_name,
        "pins": {pin_uuids[name]: {"direction": _pin_direction(name), "names": [], "primary_name": name, "swap_group": 0} for name in names},
        "type": "unit",
        "uuid": unit_uuid,
    }
    prefix = re.sub(r"[0-9?]+$", "", fp.refdes) or "U"
    entity = {
        "gates": {gate_uuid: {"name": "Main", "suffix": "", "swap_group": 0, "unit": unit_uuid}},
        "manufacturer": fp.props.get("Manufacturer", ""),
        "name": fp.library or fp.footprint_name,
        "prefix": prefix,
        "tags": ["atopile"],
        "type": "entity",
        "uuid": entity_uuid,
    }
    # Box symbol: pins alternate left and right, 2.5 mm apart, on a body
    # 10 mm wide; pin positions are the connection ends, 2.5 mm out.
    left = names[0::2]
    right = names[1::2]
    rows = max(len(left), len(right), 1)
    height = nm(2.5) * (rows + 1)
    body_half_w = nm(5.0)
    pins: dict[str, dict[str, Any]] = {}
    for column, orientation, sign in ((left, "left", -1), (right, "right", 1)):
        for index, name in enumerate(column):
            y = height // 2 - nm(2.5) * (index + 1)
            pins[pin_uuids[name]] = {
                "decoration": {"clock": False, "dot": False, "driver": "default", "schmitt": False},
                "length": nm(2.5),
                "name_orientation": "in_line",
                "name_visible": True,
                "orientation": orientation,
                "pad_visible": True,
                "position": [sign * (body_half_w + nm(2.5)), y],
            }
    corners = [(-body_half_w, height // 2), (body_half_w, height // 2), (body_half_w, -height // 2), (-body_half_w, -height // 2)]
    junctions = {uuid5("sjunction", f"{key}|{i}"): {"position": [x, y]} for i, (x, y) in enumerate(corners)}
    junction_ids = list(junctions.keys())
    lines = {
        uuid5("sline", f"{key}|{i}"): {"from": junction_ids[i], "layer": 0, "to": junction_ids[(i + 1) % 4], "width": 0}
        for i in range(4)
    }
    texts = {
        uuid5("stext", f"{key}|refdes"): {"font": "simplex", "from_smash": False, "layer": 0, "origin": "center", "placement": _placement(0, height // 2 + nm(1.25)), "size": nm(1.5), "text": "$REFDES", "width": 0},
        uuid5("stext", f"{key}|value"): {"font": "simplex", "from_smash": False, "layer": 0, "origin": "center", "placement": _placement(0, -height // 2 - nm(1.25)), "size": nm(1.5), "text": "$VALUE", "width": 0},
    }
    symbol = {
        "arcs": {},
        "can_expand": False,
        "junctions": junctions,
        "lines": lines,
        "name": unit["name"],
        "pins": pins,
        "polygons": {},
        "text_placements": {},
        "texts": texts,
        "type": "symbol",
        "unit": unit_uuid,
        "uuid": symbol_uuid,
    }
    return unit, entity, symbol, pin_uuids, gate_uuid


def part_for(fp: Footprint, entity_uuid: str, package_uuid: str, gate_uuid: str, pin_uuids: dict[str, str], pad_uuids: dict[str, str], all_pad_uuids: list[tuple[str, str]]) -> tuple[str, dict[str, Any]]:
    lcsc = fp.props.get("LCSC") or fp.props.get("lcsc_id") or ""
    mpn = fp.props.get("Partnumber") or fp.props.get("MPN") or fp.library or fp.footprint_name
    key = lcsc or f"{fp.props.get('Manufacturer', '')}|{mpn}|{fp.lib_id}"
    part_uuid = uuid5("part", key)
    pad_map = {pad_uuid: {"gate": gate_uuid, "pin": pin_uuids[name]} for name, pad_uuid in all_pad_uuids if name in pin_uuids}
    tags = ["atopile"] + ([f"lcsc:{lcsc}"] if lcsc else [])
    part = {
        "MPN": [False, mpn],
        "datasheet": [False, fp.props.get("Datasheet", "")],
        "description": [False, fp.props.get("Description", "")],
        "entity": entity_uuid,
        "inherit_model": False,
        "inherit_tags": False,
        "manufacturer": [False, fp.props.get("Manufacturer", "")],
        "model": NULL_UUID,
        "orderable_MPNs": {},
        "package": package_uuid,
        "pad_map": pad_map,
        "parametric": {},
        "tags": tags,
        "type": "part",
        "uuid": part_uuid,
        "value": [False, fp.props.get("Value", "")],
    }
    return part_uuid, part


# --- Sync ----------------------------------------------------------------------

@dataclass
class Plan:
    pool_items: list[dict[str, Any]] = field(default_factory=list)
    ops: list[dict[str, Any]] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    components: dict[str, dict[str, Any]] = field(default_factory=dict)   # id -> {refdes, part, pins: {pad: net name}}
    net_ids: dict[str, str] = field(default_factory=dict)                  # net name -> id


def plan_sync(project: horizontal_client.Project, footprints: list[Footprint], sync_positions: bool = False) -> Plan:
    plan = Plan()
    existing_components = {c["id"].lower(): c for c in project.components()}
    existing_parts = {p["id"].lower(): p for p in project.parts()}
    netlist = project.netlist(include_unconnected=True)
    existing_nets = {n["id"].lower(): n for n in netlist["nets"]}
    refdes_to_id = {c["refdes"]: cid for cid, c in existing_components.items() if c["refdes"]}
    existing_pins: dict[tuple[str, str], str] = {}     # (component id, pin) -> net id
    existing_pad_sets: dict[str, set[tuple[str, str]]] = {}
    for net in netlist["nets"]:
        pairs = {(refdes_to_id.get(p["refdes"], p["refdes"]), p["pin"]) for p in net["pins"]}
        existing_pad_sets[net["id"].lower()] = pairs
        for pair in pairs:
            existing_pins[pair] = net["id"].lower()

    # Pool items, once per distinct footprint and part.
    padstacks: dict[str, dict[str, Any]] = {}
    packages: dict[str, dict[str, Any]] = {}
    units: dict[str, dict[str, Any]] = {}
    entities: dict[str, dict[str, Any]] = {}
    symbols: dict[str, dict[str, Any]] = {}
    parts: dict[str, dict[str, Any]] = {}
    component_parts: dict[str, str] = {}
    for fp in footprints:
        package_uuid, package, pad_uuids = package_for(fp, padstacks)
        packages[package_uuid] = package
        unit, entity, symbol, pin_uuids, gate_uuid = unit_entity_symbol_for(fp)
        units[unit["uuid"]] = unit
        entities[entity["uuid"]] = entity
        symbols[symbol["uuid"]] = symbol
        all_pads = [(pad["name"], pad_uuid) for pad_uuid, pad in package["pads"].items()]
        part_uuid, part = part_for(fp, entity["uuid"], package_uuid, gate_uuid, pin_uuids, pad_uuids, all_pads)
        parts[part_uuid] = part
        component_parts[uuid5("component", fp.address)] = part_uuid
    for group in (padstacks, units, entities, symbols, packages, parts):
        plan.pool_items.extend(group.values())

    # Nets from the pads, matched to existing nets by the pads on them.
    new_pad_sets: dict[str, set[tuple[str, str]]] = {}
    for fp in footprints:
        cid = uuid5("component", fp.address)
        for pad in fp.pads:
            if pad.net and pad.kind != "np_thru_hole":
                new_pad_sets.setdefault(pad.net, set()).add((cid, pad.name))
    taken: set[str] = set()
    matched_ids: dict[str, str] = {}
    for name, pairs in sorted(new_pad_sets.items(), key=lambda kv: -len(kv[1])):
        best_id, best_score = None, 0.0
        for net_id, existing_pairs in existing_pad_sets.items():
            if net_id in taken or not existing_pairs:
                continue
            score = len(pairs & existing_pairs) / len(pairs | existing_pairs)
            if score > best_score:
                best_id, best_score = net_id, score
        if best_id and best_score >= 0.5:
            matched_ids[name] = best_id
            taken.add(best_id)
            if existing_nets[best_id]["name"] != name:
                plan.ops.append({"op": "rename_net", "net": best_id, "name": name})
                plan.notes.append(f"net {existing_nets[best_id]['name']!r} renamed to {name!r} (matched by its pads)")
        else:
            by_name = next((nid for nid, n in existing_nets.items() if n["name"] == name and nid not in taken), None)
            net_id = by_name or uuid5("net", name)
            matched_ids[name] = net_id
            taken.add(net_id)
            if net_id not in existing_nets:
                plan.ops.append({"op": "ensure_net", "id": net_id, "name": name})
    plan.net_ids = matched_ids

    # Components: create, rename, connect, place.
    managed_part_ids = {pid for pid, p in existing_parts.items() if "atopile" in (p.get("tags") or [])}
    seen: set[str] = set()
    for fp in footprints:
        cid = uuid5("component", fp.address)
        seen.add(cid)
        part_uuid = component_parts[cid]
        pins = {pad.name: pad.net for pad in fp.pads if pad.net and pad.kind != "np_thru_hole"}
        plan.components[cid] = {"refdes": fp.refdes, "part": part_uuid, "pins": pins, "address": fp.address}
        existing = existing_components.get(cid)
        pieces = fp.address.split(".")
        group = ".".join(pieces[:-1]) if len(pieces) > 1 else None
        tag = pieces[-1]
        if existing is None:
            plan.ops.append({"op": "ensure_component", "id": cid, "refdes": fp.refdes, "part": part_uuid, "group": group, "tag": tag, "value": fp.props.get("Value", "")})
        else:
            if existing.get("refdes") != fp.refdes and fp.refdes:
                plan.ops.append({"op": "set_refdes", "component": cid, "refdes": fp.refdes})
            if (existing.get("part_id") or "").lower() != part_uuid:
                plan.ops.append({"op": "set_part", "component": cid, "part": part_uuid})
        for pad_name, net_name in pins.items():
            net_id = matched_ids[net_name]
            if existing_pins.get((cid, pad_name)) != net_id:
                plan.ops.append({"op": "connect", "component": cid, "pin": f"Main/{pad_name}", "net": net_id})
        if existing is not None:
            for (ecid, pin), _ in existing_pins.items():
                if ecid == cid and pin not in pins:
                    plan.ops.append({"op": "disconnect", "component": cid, "pin": f"Main/{pin}"})
        if existing is None or sync_positions:
            plan.ops.append({"op": "place_component", "component": cid, "x_mm": fp.x, "y_mm": -fp.y, "angle_deg": fp.rot, "bottom": fp.bottom})

    # Components this tool made earlier that the design no longer has.
    for cid, comp in existing_components.items():
        if cid in seen:
            continue
        if (comp.get("part_id") or "").lower() in managed_part_ids:
            plan.ops.append({"op": "remove_component", "component": cid})
            plan.notes.append(f"{comp['refdes']} is gone from the design and is removed")
    # Nets that only those components used are retired.
    removed = {op["component"] for op in plan.ops if op["op"] == "remove_component"}
    for net_id, pairs in existing_pad_sets.items():
        if net_id in taken or not pairs:
            continue
        if all(cid in removed for cid, _ in pairs):
            plan.ops.append({"op": "retire_net", "net": net_id})
    return plan


def validate(project: horizontal_client.Project, plan: Plan) -> list[str]:
    """Pad-to-net equality between the design and the project after sync."""
    netlist = project.netlist(include_unconnected=True)
    actual: dict[tuple[str, str], str] = {}
    for net in netlist["nets"]:
        for pin in net["pins"]:
            actual[(pin["refdes"], pin["pin"])] = net["name"]
    problems: list[str] = []
    for comp in plan.components.values():
        for pad, net_name in comp["pins"].items():
            got = actual.get((comp["refdes"], pad))
            if got != net_name:
                problems.append(f"{comp['refdes']}.{pad}: design says {net_name!r}, project says {got!r}")
    return problems


def sync(board: Path, project_path: Path, create: bool = False, dry_run: bool = False, sync_positions: bool = False, prefer_live: bool = True) -> dict[str, Any]:
    footprints, _ = read_kicad_pcb(board)
    if create and not project_path.exists():
        project = horizontal_client.new_project(project_path, name=project_path.stem)
    else:
        project = horizontal_client.open(project_path, prefer_live=prefer_live)
    plan = plan_sync(project, footprints, sync_positions=sync_positions)
    report: dict[str, Any] = {
        "board": str(board),
        "project": project.path,
        "live": project.is_live,
        "footprints": len(footprints),
        "pool_items": len(plan.pool_items),
        "ops": len(plan.ops),
        "notes": plan.notes,
    }
    if dry_run:
        report["dry_run"] = True
        report["op_summary"] = _summarize(plan.ops)
        return report
    written = project.pool_write(plan.pool_items) if plan.pool_items else {"written": [], "skipped": 0}
    report["pool_written"] = len(written.get("written", []))
    if plan.ops:
        result = project.apply(plan.ops)
        report["applied"] = result["applied"]
        report["diagnostics"] = result.get("project", {}).get("diagnostics", [])
    else:
        report["applied"] = 0
    report["op_summary"] = _summarize(plan.ops)
    report["mismatches"] = validate(project, plan)
    report["check"] = project.check()["counts"]
    return report


def _summarize(ops: list[dict[str, Any]]) -> dict[str, int]:
    summary: dict[str, int] = {}
    for op in ops:
        summary[op["op"]] = summary.get(op["op"], 0) + 1
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="horizontal-ato", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("sync", help="Sync an atopile board file into a Horizontal project.")
    s.add_argument("board", type=Path, help="The .kicad_pcb atopile wrote.")
    s.add_argument("project", type=Path, help="The .hprj or .horizontal project.")
    s.add_argument("--create", action="store_true", help="Create the project (as a .horizontal package) if it does not exist.")
    s.add_argument("--dry-run", action="store_true", help="Plan only; change nothing.")
    s.add_argument("--sync-positions", action="store_true", help="Move existing packages to the board file's positions too.")
    s.add_argument("--no-live", action="store_true", help="Edit the files even if the project is open in Horizontal.")
    s.add_argument("--json", action="store_true", help="Print the report as JSON.")
    p = sub.add_parser("inspect", help="Summarize an atopile board file.")
    p.add_argument("board", type=Path)
    g = sub.add_parser("groups", help="List the project's groups (atopile module instances) and what is placed.")
    g.add_argument("project", type=Path)
    c = sub.add_parser("copy-layout", help="Lay one module instance out like another: placement and routing by tag.")
    c.add_argument("project", type=Path)
    c.add_argument("--from", dest="source", required=True, help="Group (module instance) to copy from.")
    c.add_argument("--to", dest="target", required=True, help="Group to lay out.")
    c.add_argument("--x", type=float, default=None, help="Anchor X in mm (default: where the target's anchor already is).")
    c.add_argument("--y", type=float, default=None)
    c.add_argument("--angle", type=float, default=None, help="Rotation of the copy in degrees.")
    c.add_argument("--no-routing", action="store_true", help="Placement only.")
    args = parser.parse_args(argv)

    if args.command == "groups":
        project = horizontal_client.open(args.project)
        for group in project.groups():
            print(f"{group['name']}  ({group['placed_count']}/{len(group['members'])} placed)")
            for member in group["members"]:
                print(f"    {member['tag']:24} {member['refdes']:8} {'placed' if member['placed'] else 'unplaced'}")
        return 0
    if args.command == "copy-layout":
        project = horizontal_client.open(args.project)
        result = project.copy_group_layout(args.source, args.target, x_mm=args.x, y_mm=args.y, angle_deg=args.angle, include_routing=not args.no_routing)
        change = result["changes"][0]
        print(f"placed {change['placed']} packages, copied {change['tracks']} tracks, {change['vias']} vias (anchor tag {change['anchor_tag']})")
        return 0

    if args.command == "inspect":
        footprints, nets = read_kicad_pcb(args.board)
        print(f"{len(footprints)} footprints, {len(nets) - (1 if 0 in nets else 0)} nets")
        for fp in footprints:
            connected = sum(1 for pad in fp.pads if pad.net)
            print(f"  {fp.refdes:6} {fp.address:40} {fp.lib_id:50} {len(fp.pads)} pads ({connected} connected) at {fp.x:g},{fp.y:g} rot {fp.rot:g} {'bottom' if fp.bottom else 'top'}")
        return 0

    try:
        report = sync(args.board, args.project, create=args.create, dry_run=args.dry_run, sync_positions=args.sync_positions, prefer_live=not args.no_live)
    except HorizontalError as error:
        print(f"horizontal-ato: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for key, value in report.items():
            if key in ("notes", "mismatches"):
                for line in value:
                    print(f"  {key[:-1]}: {line}")
            else:
                print(f"{key}: {value}")
    return 1 if report.get("mismatches") else 0


if __name__ == "__main__":
    sys.exit(main())
