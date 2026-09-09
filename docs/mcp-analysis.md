# MCP API 2: sources, edits and reproducible analysis

The Python package is version 0.2. Native API 2 is required by both Python and
MCP. Build `horizontal` and `HorizontalPy`, rebuild the Xcode app for live
operation, install the locked Python dependencies, and restart the MCP
connection. An already running app retains its previous native API until it
is relaunched. `connection_status` identifies the engine actually in use.

## Select and retain a source

`open_project(path, source="auto" | "live" | "disk")` returns a summary in
`data`, including `project_ref`, `requested_source`, resolved `source`,
transport, native instance identity, `revision`, and `snapshot_id`.

`live` requires a matching open document and sees its unsaved archive. `disk`
captures saved files. `auto` resolves once; a closed live document or failed
connection does not turn that context into a disk context. Live and disk
contexts for the same path may coexist. Pass `project_ref` to distinguish
them. Path shorthand is supported only when it identifies one context.
`close_project` releases the MCP context without closing the app's document.

Every project result is `{data, meta}`. `meta` identifies the source, instance,
revision, content snapshot and API version. Image tools return PNG content
alongside structured image, sheet, region and snapshot metadata. Python
methods continue returning ordinary dictionaries/lists/PNG bytes, with
metadata on `project.last_metadata`.

`revision` is an opaque edit precondition scoped to an open context or live
document instance. `snapshot_id` is SHA-256 over ordered file identities and
contents. Reopening a disk context changes its revision even if bytes are
unchanged. Disk reads stay on their captured state until `reload_project`;
live reads capture the current archive. Indexing, pool resolution, rendering
and export consume the captured archive. External dependencies and symbolic
links are rejected where they cannot be captured reproducibly.

`connection_status` is usable before opening a project. It reports discovery
paths/failures, authenticated live version and compatibility, endpoint
latency, selected worker/dylib paths and content hashes, and open contexts.
An unavailable endpoint does not establish whether the app is stopped,
automation is disabled, or no document is open. Tokens are omitted.

## Identity and errors

`get_net(name=None, id=None)` and `get_component(refdes=None, id=None)` require
exactly one nonempty selector. Use the UUID for an unnamed net. Selection,
highlighting and zoom accept UUIDs as well as uniquely resolved labels.

Sheet selection accepts a sheet UUID, index or name, optionally qualified
by `block_id`. Missing sheets return `NOT_FOUND`, ambiguous sheets return
`AMBIGUOUS_SELECTOR`, and valid empty sheets return an empty list. Unknown
render layers, extra fields, malformed operations, wrong scalar types and
non-finite numbers are rejected. Edit operations have a discriminated `op`
schema; advertised input/output schemas are tested through the MCP SDK.

Tool failures set MCP `isError` and retain a structured `error` containing
`code`, `message`, `details`, `retryable`, and `outcome`. Relevant codes include
`INVALID_ARGUMENT`, `NOT_FOUND`, `AMBIGUOUS_SELECTOR`, `INCOMPATIBLE_ENGINE`,
`LIVE_UNAVAILABLE`, `LIVE_DOCUMENT_CHANGED`, `DOCUMENT_OPEN`, `AUTH_FAILED`,
`CONNECTION_LOST`, `TIMEOUT`, `STALE_REVISION`, `READ_ONLY`, `SNAPSHOT_EXPIRED`,
`UNSUPPORTED_MODEL`, and `RECOVERY_REQUIRED`.

`DOCUMENT_OPEN` is the one that cannot be worked around by retrying: an editor
has the project open, so its files are not the editor's state and writing them
would lose an edit either way. `details.holders` names who, `project_info`
reports the same as `held_by`, and a `dry_run` plans anyway and reports them in
`blocked_by`. Editing through the live channel, or closing the document, is
what clears it — see [the automation guide](automation.md).

## Review and commit an edit

1. Read through the intended `project_ref`; keep the returned revision.
2. Call `apply_ops` with `expected_revision`, a unique `operation_id`, the
   operations, and `dry_run=true`. The result includes normalized operations,
   changed-file previews, before/after snapshot IDs and `plan_digest`.
3. Commit the returned `normalized_ops` with the same `expected_revision`
   and `plan_digest`, `dry_run=false`, and a commit operation ID. Include the
   same pool items if the plan creates or changes pool data.
4. Retain the receipt. After a lost response, call `transaction_status` with
   that operation ID. `unknown` does not establish that an edit was absent.

Convenience MCP edit tools require the same revision and operation ID.
Direct native `apply` and `pool_write` enforce revision checks too. Python
convenience methods default to the last observed revision, and generate an
operation ID when one is omitted. For an explicit Python review/commit:

```python
revision = project.info()["revision"]
preview = project.apply(ops, dry_run=True, expected_revision=revision)
receipt = project.apply(
    preview["normalized_ops"], expected_revision=revision,
    plan_digest=preview["plan_digest"], operation_id="unique-commit-id",
)
```

Live edits install one archive as one undo step and report
`durability="unsaved_document"`. Disk edits stage and load the complete
candidate before replacing any files, then report `durability="disk"`.
Pool items and dependent design operations share one batch, including in
the atopile bridge. A repeated operation ID returns its saved receipt only
when its request digest matches; using it for different inputs is an error.

Disk writers use a bounded advisory lock and an fsynced journal beside the
project in `.horizontal-transactions`. Readers join existing locks without
creating directories just to inspect a project. On interruption, a prepared
journal rolls back and a committed journal finishes installing its receipt.
If any target matches neither its old nor new bytes, recovery retains the
journal and returns `RECOVERY_REQUIRED`. Preserve that directory and resolve
the conflicting file against the recorded originals before retrying recovery.

The guarantee is recoverable multi-file consistency for participating
Horizontal readers/writers. Arbitrary external editors/readers do not honor
the lock. The app's `.hprj` sibling writes participate, but SwiftUI's final
project-file write and whole-package replacement are separate document-save
operations. The MCP server rejects disk edits when it positively finds the
same project open live. Endpoint unavailability cannot prove no editor holds
it. Live receipts remain valid only while that document instance survives.

MCP native requests use a 30-second deadline covering server queue/lock and
transport waits, with bounds on message sizes, connections and operation
counts. Reads may reconnect once within that deadline; edits never replay
automatically. Worker timeouts terminate the worker. Live requests check
expiration before execution and commit; they cannot interrupt an ongoing
commit. Model-only live queries execute off the main actor over captured
state. Native rendering/export and document edits retain the app thread.
In-process ctypes execution has cooperative checks, not hard cancellation.

## Electrical evidence and scenarios

Components return `raw_value`, inherited `part_value`, `effective_value`,
`value_source`, and an `electrical_value` with parse status, SI value/unit and
explicit tolerance where supported. Engineering notation includes `4k7`,
`100nF`, `2.2µF`, `0R`, scientific notation and percent tolerances. Ambiguous
text and part numbers stay unparsed. A part value can mask a component edit.

Each logical pin retains gate/pin UUIDs, connection state and a list of
physical pad UUIDs/names. Inherited part mappings support multiple pads per
pin, alphanumeric terminals and components without a board placement.
`physical_terminals` also lists unmapped and explicitly mechanical pads.

`analysis_snapshot` pins the current archive and returns `snapshot_ref`, a
read-only `project_ref`, file hashes, components/nets and source evidence.
It expires after 30 minutes; at most 16 analysis snapshots are retained.
Release it with `release_analysis_snapshot`. The frozen project can be used
with ordinary query/render tools, but cannot be edited or reloaded.

Build a typed `Scenario` and `Setup` from its stable IDs. Scenarios specify
selected components, population overrides, explicit device models, relay
states, ideal voltage sources/supplies, loads, temperature and device limits.
Native DNP flags are the population baseline. A model replacement or value
override is a scenario substitution and does not alter the design.

Every populated selected component needs a supported model or an evidenced
boundary declaration. Passive models can use an unambiguous schematic SI
value; other values require evidence. Relay models declare contact pin pairs,
closed states and resistance. Even a latching relay needs an explicit state;
coil voltage does not select one automatically. Open contacts without leakage
are labeled ideal. Datasheet evidence includes a document hash and page/table;
user inputs are explicitly labeled. The server does not retrieve or verify
datasheets on the user's behalf.

For an existing two-component RC circuit, the Python numerical interface is:

```python
from horizontal.analysis import Scenario, Setup, analyze, validate

pinned = project.freeze()
snapshot = pinned.analysis_snapshot()
r = pinned.component("R1")["id"]
c = pinned.component("C1")["id"]
gnd = pinned.net("GND")["id"]
source = pinned.net("IN")["id"]
output = pinned.net("OUT")["id"]
scenario = Scenario.model_validate({
    "name": "RC nominal", "reference_net": gnd, "component_ids": [r, c],
    "models": {r: {"kind": "resistor"}, c: {"kind": "capacitor"}},
    "sources": [{"id": "input", "positive_net": source, "negative_net": gnd,
                 "evidence": {"source": "user", "description": "Ideal test source"}}],
})
setup = Setup(input_source="input", output_positive_net=output, output_negative_net=gnd)
requirements = validate(snapshot, scenario, setup)
result = analyze("transfer", snapshot, scenario, setup)
pinned.close()
```

The default sweep is 1 Hz–100 kHz, 128 logarithmic points. Select sufficient
frequency resolution and explicit boundary loading for the circuit under
study. Omitting devices does not automatically reproduce their loading.

## Analysis jobs and limits

Use `validate_analysis` before `analyze_transfer`, `analyze_noise`,
`analyze_headroom`, or `analyze_adc_filter`. The validation tool reports
missing circuit models/states; each calculation additionally checks its
analysis-specific inputs and numerical solvability.

| Tool | Result and scope |
|---|---|
| `analyze_transfer` | Complex V/V gain, magnitude/dB, unwrapped phase, and sampled −3 dB crossings relative to the first frequency point. |
| `analyze_noise` | One-sided PSD and amplitude density, output/input-referred spectra, per-source contributions and trapezoid-integrated RMS. Missing amplifier noise blocks a total calculation unless partial analysis is explicitly requested. |
| `analyze_headroom` | DC bias plus peak sinusoidal excursion, compared with evidenced output, input or ADC limits. Limits retain nominal/typical/guaranteed ratings. This does not simulate clipping, slew or dynamic settling. |
| `analyze_adc_filter` | Analog response plus explicit FIR/IIR or sinc decimation stages, output rate, supported timing and bounded alias-noise integration. The converter/configuration must be evidenced and bound to the measured schematic pins. |

The solver supports R/C/L, zero-ohm links, ideal voltage sources, linear
amplifiers with optional dominant pole and noise, and resistive relay contacts.
It is bounded to 128 selected components, 48 non-reference nodes, 80
equations, and 1,024 frequency samples. It rejects unsupported hierarchy,
unconnected model pins, singular circuits and unstable IIR filters. It does
not include arbitrary SPICE models, nonlinear transients, correlated noise,
sampled tolerances/Monte Carlo, aperture behavior, quantization or intrinsic
ADC noise. A declared linear amplifier model is not a supply-dependent device
simulation. Headroom measures declared node pairs; model both input-pin
limits when common-mode constraints require them.

ADC coefficients operate at each stage's input rate. Sinc stages are explicit
normalized moving-average cascades, never inferred from an ADC name. Group
delay is reported for symmetric FIR/sinc chains; finite impulse support is
reported only for FIR/sinc chains and excludes sample-alignment latency.
Alias noise requires an explicit continuous input PSD and bandwidth and is
limited to the stated ideal-sampling model.

Jobs run in isolated subprocesses: two workers, at most four queued/running
jobs, maximum 60 seconds including queue time. `analysis_result` returns status
and completed results; `cancel_analysis` stops work, and `discard_analysis`
releases retained results. Up to 32 jobs remain for 30 minutes. Completed
jobs retain their original inputs; they are never relabeled as a newer
schematic. There is no cross-job numerical result cache.

`export_analysis` writes a new directory outside the project containing
`report.html`, SVG/PNG plots, numerical CSV, `result.json`, `evidence.json`,
`scenario.json`, and `replay.json`. Schematic crops use the original pinned
snapshot (up to eight sheets). Keep that snapshot until export or explicitly
set `include_schematic_images=false` after releasing it. Unplaced components
retain file/JSON evidence without invented schematic images.

Replay with `python -m horizontal.analysis < replay.json`. The recorded
request, schematic file hashes, algorithm/schema hashes, dependency versions,
model evidence, temperature and numerical conventions make changes auditable.
The exported scenario is a versioned sidecar keyed by stable IDs. The backend
uses deterministic spectra, so no random seed applies. Cross-platform
floating-point equality should be compared with a tolerance; identical bytes
across architectures are not promised.
