"""Reproducible small-circuit analysis over a native immutable snapshot.

The bounded dense MNA solver deliberately accepts declared linear models only.
It never reads a project, resolves a label, or downloads a device model.
"""
from __future__ import annotations

import cmath
import hashlib
import json
import math
import platform
import importlib.metadata
from pathlib import Path
from typing import Annotated, Any, Literal

from pydantic import Field, model_validator

from .schemas import Input
from ._native import HorizontalError

ENGINE = "horizontal-linear-1"
K_B = 1.380649e-23


class Evidence(Input):
    source: Literal["user", "datasheet"]
    description: str = Field(min_length=1)
    document_sha256: str | None = None
    page: str | None = None

    @model_validator(mode="after")
    def datasheet_reference(self):
        if self.source == "datasheet" and (not self.document_sha256 or not self.page):
            raise ValueError("Datasheet evidence needs document_sha256 and page/table")
        return self


class Passive(Input):
    kind: Literal["resistor", "capacitor", "inductor"]
    pins: list[str] | None = Field(default=None, min_length=2, max_length=2)
    value_si: float | None = Field(default=None, ge=0)
    evidence: Evidence | None = None


class Amplifier(Input):
    kind: Literal["amplifier"]
    positive_pin: str
    negative_pin: str
    output_pin: str
    reference_pin: str | None = None
    gain: float = Field(gt=0, le=1e12)
    pole_hz: float | None = Field(default=None, gt=0)
    voltage_noise_v_rtHz: float | None = Field(default=None, ge=0)
    current_noise_a_rtHz: float | None = Field(default=None, ge=0)
    flicker_corner_hz: float = Field(default=0, ge=0)
    evidence: Evidence


class Contact(Input):
    pins: list[str] = Field(min_length=2, max_length=2)
    closed_states: list[str] = Field(min_length=1)
    on_resistance_ohm: float = Field(gt=0)
    off_resistance_ohm: float | None = Field(default=None, gt=0)


class Relay(Input):
    kind: Literal["relay"]
    states: list[str] = Field(min_length=2)
    latching: bool = False
    contacts: list[Contact] = Field(min_length=1, max_length=32)
    evidence: Evidence


class Boundary(Input):
    kind: Literal["boundary"]
    evidence: Evidence


DeviceModel = Annotated[Passive | Amplifier | Relay | Boundary, Field(discriminator="kind")]


class Source(Input):
    id: str = Field(min_length=1)
    positive_net: str
    negative_net: str
    dc_v: float = 0
    evidence: Evidence


class Load(Input):
    positive_net: str
    negative_net: str
    resistance_ohm: float = Field(gt=0)
    evidence: Evidence


class HeadroomLimit(Input):
    component_id: str
    positive_net: str
    negative_net: str
    minimum_v: float
    maximum_v: float
    kind: Literal["output", "common_mode", "adc_input"]
    rating: Literal["nominal", "typical", "guaranteed"]
    evidence: Evidence

    @model_validator(mode="after")
    def ordered(self):
        if self.minimum_v >= self.maximum_v: raise ValueError("Headroom limits are reversed")
        return self


class Scenario(Input):
    name: str = "default"
    reference_net: str
    component_ids: list[str] | None = None
    population: dict[str, bool] = Field(default_factory=dict)
    models: dict[str, DeviceModel] = Field(default_factory=dict)
    relay_states: dict[str, str] = Field(default_factory=dict)
    sources: list[Source] = Field(default_factory=list, max_length=16)
    loads: list[Load] = Field(default_factory=list, max_length=32)
    headroom_limits: list[HeadroomLimit] = Field(default_factory=list, max_length=32)
    temperature_k: float = Field(default=300, gt=0, le=2000)
    noise_correlation: Literal["uncorrelated"] = "uncorrelated"
    allow_partial_noise: bool = False


class Sweep(Input):
    start_hz: float = Field(default=1, gt=0)
    stop_hz: float = Field(default=100_000, gt=0)
    points: int = Field(default=128, ge=2, le=1024)
    spacing: Literal["log", "linear"] = "log"

    @model_validator(mode="after")
    def ordered(self):
        if self.start_hz >= self.stop_hz: raise ValueError("stop_hz must exceed start_hz")
        return self

    def frequencies(self) -> list[float]:
        if self.spacing == "linear": return [self.start_hz + (self.stop_hz - self.start_hz) * i / (self.points - 1) for i in range(self.points)]
        return [self.start_hz * (self.stop_hz / self.start_hz) ** (i / (self.points - 1)) for i in range(self.points)]


class FilterStage(Input):
    kind: Literal["coefficients", "sinc"]
    decimation: int = Field(default=1, ge=1, le=256)
    numerator: list[float] = Field(default_factory=lambda: [1.0], min_length=1, max_length=1024)
    denominator: list[float] = Field(default_factory=lambda: [1.0], min_length=1, max_length=64)
    sinc_order: int = Field(default=1, ge=1, le=5)

    @model_validator(mode="after")
    def valid_denominator(self):
        if not self.denominator[0]: raise ValueError("The first denominator coefficient cannot be zero")
        if self.kind == "sinc" and (self.numerator != [1.0] or self.denominator != [1.0]):
            raise ValueError("sinc stages do not accept coefficient overrides")
        # Schur reduction of the real denominator polynomial. A steady-state
        # frequency/noise response requires every pole strictly inside |z|=1.
        coefficients = list(self.denominator)
        while len(coefficients) > 1:
            reflection = coefficients[-1] / coefficients[0]
            if abs(reflection) >= 1 - 1e-12:
                raise ValueError("ADC IIR denominator is unstable or too close to the stability boundary")
            reduced = [coefficients[i] - reflection * coefficients[-1-i] for i in range(len(coefficients) - 1)]
            coefficients = [value / reduced[0] for value in reduced]
        return self


class ADCFilter(Input):
    component_id: str
    converter: str = Field(min_length=1)
    configuration: str = Field(min_length=1)
    input_rate_hz: float = Field(gt=0)
    stages: list[FilterStage] = Field(min_length=1, max_length=8)
    evidence: Evidence
    input_noise_psd_v2_hz: float | None = Field(default=None, ge=0)
    noise_band_limit_hz: float | None = Field(default=None, gt=0)
    sampling_model: Literal["ideal"] = "ideal"

    @model_validator(mode="after")
    def noise_band(self):
        if (self.input_noise_psd_v2_hz is None) != (self.noise_band_limit_hz is None):
            raise ValueError("Alias noise needs both PSD and its continuous-time bandwidth")
        return self


class Setup(Input):
    input_source: str
    output_positive_net: str
    output_negative_net: str
    sweep: Sweep = Field(default_factory=Sweep)
    signal_peak_v: float | None = Field(default=None, ge=0)
    signal_frequency_hz: float | None = Field(default=None, gt=0)
    adc: ADCFilter | None = None


def fail(message: str, **details: Any):
    raise HorizontalError(-32006, message, {"code": "UNSUPPORTED_MODEL", "details": details, "retryable": False, "outcome": "not_committed"})


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def solve(matrix: list[list[complex]], rhs: list[complex]) -> list[complex]:
    """Row-scaled Gaussian elimination with partial pivoting and explicit singular errors."""
    size = len(rhs)
    a = [list(row) + [rhs[i]] for i, row in enumerate(matrix)]
    for row in a:
        scale = max((abs(x) for x in row[:-1]), default=0)
        if not scale: fail("Circuit has a floating node or unconstrained source")
        for j in range(size + 1): row[j] /= scale
    for col in range(size):
        pivot = max(range(col, size), key=lambda row: abs(a[row][col]))
        if abs(a[pivot][col]) < 1e-14: fail("Circuit matrix is singular or ill-conditioned; check references, ideal sources, and floating nodes")
        a[col], a[pivot] = a[pivot], a[col]
        for row in range(col + 1, size):
            factor = a[row][col] / a[col][col]
            if factor:
                for j in range(col + 1, size + 1): a[row][j] -= factor * a[col][j]
                a[row][col] = 0j
    out = [0j] * size
    for row in reversed(range(size)):
        out[row] = (a[row][-1] - sum(a[row][j] * out[j] for j in range(row + 1, size))) / a[row][row]
        if not math.isfinite(abs(out[row])): fail("Circuit solve produced a non-finite result")
    return out


class Circuit:
    def __init__(self, snapshot: dict[str, Any], scenario: Scenario, setup: Setup):
        self.snapshot, self.scenario, self.setup = snapshot, scenario, setup
        self.components = {c["id"]: c for c in snapshot["components"]}
        self.nets = {n["id"] for n in snapshot["nets"]}
        self.missing: list[dict[str, Any]] = []
        self.warnings: list[str] = []
        self.devices: list[dict[str, Any]] = []
        self.excluded: list[str] = []
        self.noise_missing: list[str] = []
        if not snapshot.get("hierarchy_supported", False): fail("Hierarchical block instances are not yet supported by this analysis backend")
        if snapshot.get("symbolic_links", 0): fail("Analysis requires captured dependencies without symbolic links")
        for ref in [scenario.reference_net, setup.output_positive_net, setup.output_negative_net]: self.check_net(ref)
        ids = set(scenario.component_ids) if scenario.component_ids is not None else set(self.components)
        unknown = (ids | set(scenario.models) | set(scenario.population) | set(scenario.relay_states)) - self.components.keys()
        if unknown: fail("Scenario contains unknown component IDs", ids=sorted(unknown))
        if len(ids) > 128: fail("Select a subcircuit of at most 128 components")
        for id in sorted(ids):
            c = self.components[id]
            if not scenario.population.get(id, not c["no_populate"]):
                self.excluded.append(id)
                continue
            model = scenario.models.get(id)
            if model is None:
                self.missing.append({"component_id": id, "refdes": c["refdes"], "required": "explicit device model or boundary declaration"})
                continue
            if isinstance(model, Boundary):
                self.warnings.append(f"{c['refdes']} is an explicitly declared circuit boundary: {model.evidence.description}")
                continue
            if isinstance(model, Passive):
                connected = [p["gate_pin_path"] for p in c.get("pins", []) if p.get("net_id")]
                pins = model.pins if model.pins is not None else connected
                if len(pins) != 2: fail("Passive model needs exactly two logical gate/pin paths", component_id=id)
                value = model.value_si
                if value is None:
                    parsed = c.get("electrical_value", {})
                    unit = {"resistor": "ohm", "capacitor": "F", "inductor": "H"}[model.kind]
                    if parsed.get("status") != "parsed" or parsed.get("unit") != unit:
                        self.missing.append({"component_id": id, "required": f"unambiguous value in {unit}"})
                        continue
                    value = parsed["value_si"]
                elif model.evidence is None: fail("A value override needs evidence", component_id=id)
                self.devices.append({"kind": model.kind, "id": id, "a": self.pin(c, pins[0]), "b": self.pin(c, pins[1]), "value": value})
            elif isinstance(model, Amplifier):
                self.devices.append({"kind": "amplifier", "id": id, "a": self.pin(c, model.output_pin),
                                     "b": self.pin(c, model.reference_pin) if model.reference_pin else scenario.reference_net,
                                     "plus": self.pin(c, model.positive_pin), "minus": self.pin(c, model.negative_pin), "model": model})
                if model.voltage_noise_v_rtHz is None or model.current_noise_a_rtHz is None: self.noise_missing.append(id)
                self.warnings.append(f"{c['refdes']}: declared linear amplifier model; supply dependence, saturation and slew are not simulated")
            elif isinstance(model, Relay):
                state = scenario.relay_states.get(id)
                if state not in model.states:
                    self.missing.append({"component_id": id, "required": "explicit relay state", "allowed": model.states})
                    continue
                for i, contact in enumerate(model.contacts):
                    if not set(contact.closed_states) <= set(model.states): fail("Contact declares an unknown relay state", component_id=id)
                    resistance = contact.on_resistance_ohm if state in contact.closed_states else contact.off_resistance_ohm
                    a, b = self.pin(c, contact.pins[0]), self.pin(c, contact.pins[1])
                    if resistance is not None:
                        self.devices.append({"kind": "resistor", "id": f"{id}/contact/{i}", "a": a, "b": b, "value": resistance})
                    else: self.warnings.append(f"{c['refdes']} contact {i}: declared ideal open, without leakage or capacitance")
        if scenario.component_ids is not None:
            self.warnings.append("Selected subcircuit only; connections to omitted devices must be represented by declared sources and loads")
        for i, load in enumerate(scenario.loads):
            self.check_net(load.positive_net); self.check_net(load.negative_net)
            self.devices.append({"kind": "resistor", "id": f"load/{i}", "a": load.positive_net, "b": load.negative_net, "value": load.resistance_ohm})
        source_ids = [s.id for s in scenario.sources]
        if len(source_ids) != len(set(source_ids)): fail("Source IDs must be unique")
        if setup.input_source not in source_ids: fail("input_source must select a declared voltage source")
        for source in scenario.sources:
            self.check_net(source.positive_net); self.check_net(source.negative_net)
            self.devices.append({"kind": "source", "id": source.id, "a": source.positive_net, "b": source.negative_net, "dc": source.dc_v})
        device_ids = [device["id"] for device in self.devices]
        if len(device_ids) != len(set(device_ids)): fail("Source IDs collide with component or generated load/contact IDs")
        used = {setup.output_positive_net, setup.output_negative_net}
        for device in self.devices:
            used.update(device[key] for key in ("a", "b", "plus", "minus") if key in device)
        self.nodes = {id: i for i, id in enumerate(sorted(used - {scenario.reference_net}))}
        if len(self.nodes) > 48: fail("Select a subcircuit with at most 48 non-reference nodes")

    def check_net(self, id: str):
        if id not in self.nets: fail("Use a net UUID from the snapshot", net_id=id)

    def pin(self, component: dict[str, Any], path: str) -> str:
        matches = [p for p in component.get("pins", []) if p["gate_pin_path"] == path]
        if len(matches) != 1 or not matches[0].get("net_id"): fail("Model pin is unknown or unconnected", component_id=component["id"], gate_pin_path=path)
        self.check_net(matches[0]["net_id"])
        return matches[0]["net_id"]

    def require_device(self, id: str):
        if id not in self.components or id in self.excluded or (self.scenario.component_ids is not None and id not in self.scenario.component_ids):
            fail("Device must be populated and included in the selected circuit", component_id=id)

    def require_complete(self):
        if self.missing: fail("Circuit models or operating states are incomplete", missing=self.missing)

    def system(self, hz: float):
        branches = [d for d in self.devices if d["kind"] in {"source", "amplifier"} or (d["kind"] in {"resistor", "inductor"} and (not d["value"] or (d["kind"] == "inductor" and hz == 0)))]
        count = len(self.nodes) + len(branches)
        if count > 80: fail("Circuit exceeds 80 equations")
        matrix = [[0j] * count for _ in range(count)]
        branch_index = {d["id"]: len(self.nodes) + i for i, d in enumerate(branches)}
        def stamp(row, col, value):
            if row is not None and col is not None: matrix[row][col] += value
        for d in self.devices:
            a, b = self.nodes.get(d["a"]), self.nodes.get(d["b"])
            if d["id"] in branch_index:
                j = branch_index[d["id"]]
                stamp(a, j, 1); stamp(b, j, -1); stamp(j, a, 1); stamp(j, b, -1)
                if d["kind"] == "amplifier":
                    gain = self.amplifier_gain(d["model"], hz)
                    stamp(j, self.nodes.get(d["plus"]), -gain); stamp(j, self.nodes.get(d["minus"]), gain)
            else:
                if d["kind"] == "resistor": y = 1 / d["value"]
                elif d["kind"] == "capacitor": y = 2j * math.pi * hz * d["value"]
                else: y = 1 / (2j * math.pi * hz * d["value"])
                stamp(a, a, y); stamp(b, b, y); stamp(a, b, -y); stamp(b, a, -y)
        return matrix, branch_index

    @staticmethod
    def amplifier_gain(model: Amplifier, hz: float) -> complex:
        return model.gain / (1 + (1j * hz / model.pole_hz if model.pole_hz else 0))

    def solution(self, hz: float, dc=False) -> list[complex]:
        matrix, branches = self.system(hz)
        rhs = [0j] * len(matrix)
        for d in self.devices:
            if d["kind"] == "source": rhs[branches[d["id"]]] = d["dc"] if dc else int(d["id"] == self.setup.input_source)
        return solve(matrix, rhs)

    def voltage(self, solution: list[complex], positive=None, negative=None) -> complex:
        positive = self.setup.output_positive_net if positive is None else positive
        negative = self.setup.output_negative_net if negative is None else negative
        def node(id):
            if id == self.scenario.reference_net: return 0j
            if id not in self.nodes: fail("Requested node is outside the modeled circuit", net_id=id)
            return solution[self.nodes[id]]
        return node(positive) - node(negative)

    def gain(self, hz: float) -> complex:
        return self.voltage(self.solution(hz))

    def noise(self, hz: float) -> dict[str, float]:
        matrix, branches = self.system(hz)
        spectra = {}
        def contribution(id, psd, a=None, b=None, branch=None, scale=1):
            rhs = [0j] * len(matrix)
            if branch is not None: rhs[branch] = scale
            else:
                if a in self.nodes: rhs[self.nodes[a]] += 1
                if b in self.nodes: rhs[self.nodes[b]] -= 1
            spectra[id] = psd * abs(self.voltage(solve(matrix, rhs))) ** 2
        for d in self.devices:
            if d["kind"] == "resistor" and d["value"] > 0:
                contribution(d["id"], 4 * K_B * self.scenario.temperature_k / d["value"], d["a"], d["b"])
            elif d["kind"] == "amplifier":
                model = d["model"]
                if model.voltage_noise_v_rtHz is not None:
                    contribution(d["id"] + "/voltage", model.voltage_noise_v_rtHz ** 2 * (1 + model.flicker_corner_hz / hz), branch=branches[d["id"]], scale=self.amplifier_gain(model, hz))
                if model.current_noise_a_rtHz is not None:
                    for key in ("plus", "minus"):
                        contribution(d["id"] + "/current/" + key, model.current_noise_a_rtHz ** 2, d[key], self.scenario.reference_net)
        return spectra


def integrate(x: list[float], y: list[float]) -> float:
    return sum((x[i + 1] - x[i]) * (y[i + 1] + y[i]) / 2 for i in range(len(x) - 1))


def filter_gain(model: ADCFilter, hz: float) -> complex:
    rate = model.input_rate_hz
    gain = 1 + 0j
    for stage in model.stages:
        z = cmath.exp(-2j * math.pi * hz / rate)
        if stage.kind == "sinc":
            # The explicit finite sum is well behaved at DC and clock harmonics.
            response = sum(z ** n for n in range(stage.decimation)) / stage.decimation
            gain *= response ** stage.sinc_order
        else:
            denominator = sum(v * z ** i for i, v in enumerate(stage.denominator))
            if abs(denominator) < 1e-15: fail("ADC filter has a pole on the evaluated unit-circle frequency", frequency_hz=hz)
            gain *= sum(v * z ** i for i, v in enumerate(stage.numerator)) / denominator
        rate /= stage.decimation
    return gain


def validate(snapshot: dict[str, Any], scenario: Scenario, setup: Setup) -> dict[str, Any]:
    circuit = Circuit(snapshot, scenario, setup)
    return {"ready": not circuit.missing, "missing": circuit.missing,
            "missing_noise_models": circuit.noise_missing, "warnings": circuit.warnings,
            "excluded_components": circuit.excluded, "modeled_devices": [d["id"] for d in circuit.devices],
            "node_count": len(circuit.nodes), "snapshot_id": snapshot["meta"]["snapshot_id"]}


def analyze(kind: str, snapshot: dict[str, Any], scenario: Scenario, setup: Setup) -> dict[str, Any]:
    circuit = Circuit(snapshot, scenario, setup)
    circuit.require_complete()
    frequencies = setup.sweep.frequencies()
    data: dict[str, Any]
    if kind == "transfer":
        gains = [circuit.gain(f) for f in frequencies]
        phase, previous = [], None
        for gain in gains:
            angle = math.degrees(cmath.phase(gain))
            if previous is not None:
                while angle - previous > 180: angle -= 360
                while angle - previous < -180: angle += 360
            phase.append(angle if abs(gain) else None); previous = angle
        data = {"frequency_hz": frequencies, "gain_real": [g.real for g in gains], "gain_imag": [g.imag for g in gains],
                "magnitude": [abs(g) for g in gains], "magnitude_db": [20 * math.log10(abs(g)) if abs(g) else None for g in gains],
                "phase_deg": phase, "undefined_metrics": "Zero gain has no finite dB value or defined phase", "normalization": "V/V, selected input voltage source = 1 V"}
        crossings = []
        if abs(gains[0]):
            relative_db = [20 * math.log10(abs(g) / abs(gains[0])) if abs(g) else -math.inf for g in gains]
            for i in range(len(frequencies) - 1):
                a, b = relative_db[i], relative_db[i + 1]
                if math.isfinite(a) and math.isfinite(b) and a != b and (a > -3 >= b or a < -3 <= b):
                    fraction = (-3 - a) / (b - a)
                    crossings.append(math.exp(math.log(frequencies[i]) + fraction * math.log(frequencies[i+1] / frequencies[i])))
        data["minus_3db_crossings_hz"] = crossings
        data["bandwidth_definition"] = "Crossings relative to the first sweep sample, interpolated in dB/log-frequency; no extrapolation or assumed low-pass shape"
    elif kind == "noise":
        if circuit.noise_missing and not scenario.allow_partial_noise: fail("Noise models are incomplete", component_ids=circuit.noise_missing)
        per_frequency = [circuit.noise(f) for f in frequencies]
        contributions = {id: [row.get(id, 0) for row in per_frequency] for id in sorted({id for row in per_frequency for id in row})}
        total = [sum(row.values()) for row in per_frequency]
        gains = [abs(circuit.gain(f)) ** 2 for f in frequencies]
        referred = [psd / gain if gain > 1e-30 else None for psd, gain in zip(total, gains)]
        referred_sources = {id: [psd / gain if gain > 1e-30 else None for psd, gain in zip(values, gains)] for id, values in contributions.items()}
        data = {"frequency_hz": frequencies, "output_psd_v2_hz": total, "output_asd_v_rtHz": [math.sqrt(v) for v in total],
                "input_referred_psd_v2_hz": referred, "input_referred_unavailable": "Zero or negligible input-to-output gain" if None in referred else None,
                "output_rms_v": math.sqrt(integrate(frequencies, total)), "per_source_psd_v2_hz": contributions,
                "per_source_rms_v": {id: math.sqrt(integrate(frequencies, values)) for id, values in contributions.items()},
                "input_referred_rms_v": math.sqrt(integrate(frequencies, referred)) if None not in referred else None,
                "per_source_input_referred_psd_v2_hz": referred_sources,
                "completeness": "partial" if circuit.noise_missing else "complete_for_declared_models", "missing_models": circuit.noise_missing,
                "convention": "one-sided PSD, uncorrelated sources, trapezoidal integration over the stated frequency grid"}
    elif kind == "headroom":
        if setup.signal_peak_v is None or setup.signal_frequency_hz is None or not scenario.headroom_limits:
            fail("Headroom requires signal_peak_v, signal_frequency_hz, and evidenced device limits")
        dc, ac = circuit.solution(0, dc=True), circuit.solution(setup.signal_frequency_hz)
        limits = []
        for limit in scenario.headroom_limits:
            circuit.require_device(limit.component_id)
            pins = {p.get("net_id") for p in circuit.components[limit.component_id].get("pins", [])}
            if limit.positive_net not in pins: fail("Headroom limit must identify a net on the cited device", component_id=limit.component_id)
            center = circuit.voltage(dc, limit.positive_net, limit.negative_net).real
            gain = abs(circuit.voltage(ac, limit.positive_net, limit.negative_net))
            peak = setup.signal_peak_v * gain
            margin = min(center - peak - limit.minimum_v, limit.maximum_v - center - peak)
            limits.append({**limit.model_dump(), "dc_v": center, "signal_peak_v": peak, "margin_v": margin,
                           "maximum_input_peak_v": max(0, min(center - limit.minimum_v, limit.maximum_v - center)) / gain if gain else None,
                           "passed": margin >= 0})
        data = {"limits": limits, "limiting": min(limits, key=lambda x: x["margin_v"]),
                "scope": "Linear sinusoidal estimate against declared limits; saturation, slew and settling are not simulated"}
    elif kind == "adc_filter":
        model = setup.adc
        if model is None: fail("ADC analysis needs the exact converter configuration and filter model")
        circuit.require_device(model.component_id)
        part = circuit.components[model.component_id]
        input_nets = {p.get("net_id") for p in part.get("pins", [])}
        if setup.output_positive_net not in input_nets or (setup.output_negative_net != scenario.reference_net and setup.output_negative_net not in input_nets):
            fail("ADC input must be tied to the cited component's schematic pins")
        if part.get("mpn") and part["mpn"] != model.converter: fail("ADC converter does not match the schematic MPN", schematic_mpn=part["mpn"])
        output_rate = model.input_rate_hz / math.prod(stage.decimation for stage in model.stages)
        if setup.sweep.stop_hz > model.input_rate_hz / 2: fail("Filter sweep must not exceed input Nyquist frequency")
        digital = [filter_gain(model, f) for f in frequencies]
        analog = [circuit.gain(f) for f in frequencies]
        data = {"frequency_hz": frequencies, "digital_magnitude": [abs(g) for g in digital],
                "analog_magnitude": [abs(g) for g in analog], "combined_magnitude": [abs(a * d) for a, d in zip(analog, digital)],
                "input_rate_hz": model.input_rate_hz, "output_rate_hz": output_rate,
                "scope": "Declared digital filter and analog circuit; ideal sampler, no quantization, aperture, or intrinsic ADC noise"}
        delay = 0.0; rate = model.input_rate_hz; linear_phase = True; support = 0.0
        for stage in model.stages:
            length = stage.sinc_order * (stage.decimation - 1) + 1 if stage.kind == "sinc" else len(stage.numerator)
            if stage.kind == "coefficients" and (stage.denominator != [1.0] or stage.numerator != stage.numerator[::-1]): linear_phase = False
            support += (length - 1) / rate
            delay += (length - 1) / (2 * rate)
            rate /= stage.decimation
        data["group_delay_s"] = delay if linear_phase else None
        data["finite_impulse_support_s"] = support if all(s.kind == "sinc" or s.denominator == [1.0] for s in model.stages) else None
        data["timing_note"] = "Finite support excludes up to one output-sample alignment interval; non-linear-phase/IIR group delay is not reported"
        if model.input_noise_psd_v2_hz is not None:
            band = model.noise_band_limit_hz
            aliases = math.ceil(band / output_rate) + 1
            if aliases * setup.sweep.points > 32768: fail("Alias calculation exceeds its bounded workload; reduce bandwidth or grid size")
            baseband = [output_rate / 2 * (i + 0.5) / setup.sweep.points for i in range(setup.sweep.points)]
            densities = []
            for f in baseband:
                total = 0.0
                for k in range(-aliases, aliases + 1):
                    physical = abs(f + k * output_rate)
                    if physical <= band:
                        total += model.input_noise_psd_v2_hz * abs(circuit.gain(physical) * filter_gain(model, physical)) ** 2
                densities.append(total)
            data["alias_frequency_hz"] = baseband
            data["sampled_output_psd_v2_hz"] = densities
            data["sampled_output_rms_v"] = math.sqrt(sum(densities) * (output_rate / 2) / setup.sweep.points)
            data["alias_convention"] = "One-sided continuous input PSD summed over all aliases within the declared bandwidth; midpoint integration in output Nyquist band"
    else: raise ValueError("Unknown analysis kind")
    request = {"kind": kind, "snapshot": snapshot, "scenario": scenario.model_dump(mode="json"), "setup": setup.model_dump(mode="json")}
    algorithm = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    provenance = {"engine": ENGINE, "algorithm_sha256": algorithm, "python_version": platform.python_version(),
                  "schemas_sha256": hashlib.sha256(Path(__file__).with_name("schemas.py").read_bytes()).hexdigest(),
                  "dependencies": {"horizontal": importlib.metadata.version("horizontal"), "pydantic": importlib.metadata.version("pydantic")},
                  "platform": platform.machine(), "snapshot_id": snapshot["meta"]["snapshot_id"], "source": snapshot["meta"],
                  "request_sha256": digest(request), "temperature_k": scenario.temperature_k,
                  "numerics": "row-scaled complex Gaussian elimination, partial pivoting; no random sampling"}
    return {"kind": kind, "data": data, "provenance": provenance, "warnings": circuit.warnings,
            "evidence": {id: c.get("evidence", {}) for id, c in circuit.components.items() if scenario.component_ids is None or id in scenario.component_ids},
            "replay": request, "result_sha256": digest(data)}


def main():
    import sys
    try:
        request = json.load(sys.stdin)
        result = analyze(request["kind"], request["snapshot"], Scenario.model_validate(request["scenario"]), Setup.model_validate(request["setup"]))
        json.dump({"result": result}, sys.stdout, allow_nan=False)
    except (HorizontalError, ValueError) as error:
        json.dump({"error": error.structured() if isinstance(error, HorizontalError) else {"code": "INVALID_ARGUMENT", "message": str(error)}}, sys.stdout)


if __name__ == "__main__": main()
