"""Versioned public schemas. UUIDs are identities; labels are presentation."""
from __future__ import annotations

from typing import Annotated, Any, Generic, Literal, TypeVar
from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictStr, model_validator


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, strict=True)


class Record(BaseModel):
    # Additive native fields survive the adapter; known fields remain validated.
    model_config = ConfigDict(extra="allow", allow_inf_nan=False)


class Metadata(Record):
    source: Literal["live", "disk"]
    revision: str
    snapshot_id: str
    instance_id: str
    api_version: int = 2
    frozen: bool = False
    project_ref: str | None = None
    origin: dict[str, Any] | None = None


T = TypeVar("T")
class Result(BaseModel, Generic[T]):
    data: T
    meta: Metadata | None = None


class Sheet(Record):
    id: str
    index: int
    name: str
    block_id: str | None = None
    symbol_count: int


class Pad(Record):
    id: str
    name: str


class PhysicalTerminal(Pad):
    role: Literal["electrical", "mechanical", "unmapped"]
    gate_id: str | None = None
    pin_id: str | None = None
    gate_pin_path: str | None = None


class Pin(Record):
    pin: str
    gate_id: str
    pin_id: str
    gate_pin_path: str
    physical_pads: list[Pad]
    direction: str
    net_id: str | None = None
    net: str | None = None
    connection_state: Literal["connected", "unconnected", "no_connect"] | None = None


class ElectricalValue(Record):
    raw: str
    status: Literal["parsed", "unsupported", "ambiguous"]
    value_si: float | None = None
    unit: Literal["ohm", "F", "H"] | None = None
    tolerance_fraction: float | None = None


class Component(Record):
    id: str
    refdes: str
    value: str
    raw_value: str
    part_value: str
    effective_value: str
    value_source: Literal["component", "part"]
    electrical_value: ElectricalValue
    no_populate: bool
    part_id: str | None = None
    block_id: str | None = None
    pins: list[Pin] | None = None
    physical_terminals: list[PhysicalTerminal] = Field(default_factory=list)
    symbols: list[dict[str, Any]] | None = None


class NetPin(Record):
    component_id: str
    refdes: str
    gate_id: str
    pin_id: str
    gate_pin_path: str
    pin: str
    physical_pads: list[Pad]


class Net(Record):
    id: str
    name: str
    pin_count: int
    is_power: bool
    is_port: bool
    pins: list[NetPin] | None = None


class ProjectInfo(Record):
    handle: int
    path: str
    title: str
    revision: str
    snapshot_id: str
    source: Literal["live", "disk"]
    instance_id: str
    sheets: list[Sheet]
    component_count: int
    net_count: int
    live: bool
    project_ref: str | None = None


class EditResult(Record):
    applied: int
    before_revision: str
    after_snapshot_id: str
    plan_digest: str
    normalized_ops: list[dict[str, Any]] = Field(default_factory=list)
    changes: list[dict[str, Any]] = Field(default_factory=list)
    dry_run: bool = False
    after_revision: str | None = None
    operation_id: str | None = None
    durability: Literal["disk", "unsaved_document"] | None = None
    written: list[str] = Field(default_factory=list)


class Region(Input):
    min_x_mm: float
    min_y_mm: float
    max_x_mm: float
    max_y_mm: float

    @model_validator(mode="after")
    def positive_area(self):
        if self.max_x_mm <= self.min_x_mm or self.max_y_mm <= self.min_y_mm:
            raise ValueError("region must have positive width and height")
        return self


class RenderedImage(Record):
    format: Literal["png"]
    width: int
    height: int


class AnalysisSnapshot(Record):
    schema_version: Literal[1]
    meta: Metadata
    project: ProjectInfo
    components: list[Component]
    nets: list[Net]
    file_hashes: dict[str, str]
    hierarchy_supported: bool
    symbolic_links: int


class PinnedSnapshot(Record):
    snapshot_ref: str
    project_ref: str
    snapshot: AnalysisSnapshot
    expires_in_s: int


class AnalysisValidation(Record):
    ready: bool
    missing: list[dict[str, Any]]
    missing_noise_models: list[str]
    warnings: list[str]
    excluded_components: list[str]
    modeled_devices: list[str]
    node_count: int
    snapshot_id: str


class TransferData(Record):
    frequency_hz: list[float]
    gain_real: list[float]
    gain_imag: list[float]
    magnitude: list[float]
    magnitude_db: list[float | None]
    phase_deg: list[float | None]


class NoiseData(Record):
    frequency_hz: list[float]
    output_psd_v2_hz: list[float]
    output_asd_v_rtHz: list[float]
    output_rms_v: float
    input_referred_psd_v2_hz: list[float | None]
    per_source_psd_v2_hz: dict[str, list[float]]
    per_source_rms_v: dict[str, float]
    completeness: Literal["partial", "complete_for_declared_models"]


class HeadroomData(Record):
    limits: list[dict[str, Any]]
    limiting: dict[str, Any]
    scope: str


class ADCData(Record):
    frequency_hz: list[float]
    digital_magnitude: list[float]
    analog_magnitude: list[float]
    combined_magnitude: list[float]
    input_rate_hz: float
    output_rate_hz: float
    group_delay_s: float | None
    finite_impulse_support_s: float | None


class AnalysisReport(Record):
    kind: Literal["transfer", "noise", "headroom", "adc_filter"]
    data: TransferData | NoiseData | HeadroomData | ADCData
    provenance: dict[str, Any]
    warnings: list[str]
    evidence: dict[str, dict[str, Any]]
    result_sha256: str


class AnalysisJob(Record):
    job_id: str
    state: Literal["queued", "running", "completed", "failed", "cancelled"]
    kind: Literal["transfer", "noise", "headroom", "adc_filter"]
    snapshot_id: str
    result: AnalysisReport | None = None


class EnsureComponent(Input):
    op: Literal["ensure_component"]
    id: str | None = None
    refdes: str | None = None
    part: str | None = None
    entity: str | None = None
    value: str | None = None
    group: str | None = None
    tag: str | None = None


class ComponentOp(Input):
    component: StrictStr


class RemoveComponent(ComponentOp):
    op: Literal["remove_component", "remove_placement"]


class SetValue(ComponentOp):
    op: Literal["set_value"]
    value: StrictStr


class SetRefdes(ComponentOp):
    op: Literal["set_refdes"]
    refdes: StrictStr


class SetPart(ComponentOp):
    op: Literal["set_part"]
    part: StrictStr | None


class SetPopulation(ComponentOp):
    op: Literal["set_no_populate"]
    no_populate: StrictBool


class SetGroup(ComponentOp):
    op: Literal["set_group_tag"]
    group: str | None = None
    tag: str | None = None


class EnsureNet(Input):
    op: Literal["ensure_net"]
    name: StrictStr
    id: str | None = None
    net_class: str | None = None
    is_power: bool = False


class NetOp(Input):
    net: StrictStr


class RenameNet(NetOp):
    op: Literal["rename_net"]
    name: StrictStr


class SetNetClass(NetOp):
    op: Literal["set_net_class"]
    net_class: StrictStr


class RetireNet(NetOp):
    op: Literal["retire_net"]


class Connect(ComponentOp):
    op: Literal["connect"]
    pin: StrictStr
    net: StrictStr
    create_net: bool = False


class Disconnect(ComponentOp):
    op: Literal["disconnect"]
    pin: StrictStr


class Place(ComponentOp):
    op: Literal["place_component"]
    x_mm: float | None = None
    y_mm: float | None = None
    angle_deg: float | None = None
    bottom: bool | None = None


class CopyLayout(Input):
    op: Literal["copy_group_layout"]
    source: StrictStr
    target: StrictStr
    x_mm: float | None = None
    y_mm: float | None = None
    angle_deg: float | None = None
    include_routing: bool = True


EditOperation = Annotated[EnsureComponent | RemoveComponent | SetValue | SetRefdes | SetPart | SetPopulation |
                          SetGroup | EnsureNet | RenameNet | SetNetClass | RetireNet | Connect | Disconnect |
                          Place | CopyLayout, Field(discriminator="op")]
