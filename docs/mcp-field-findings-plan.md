# MCP field findings: visible updates and reliable edit contracts

Planning baseline: `47f2c6a`. Implemented September 30, 2026. This work addresses
findings 3–8 and the report that the board only showed the changes after closing
and reopening it. The reported import, 171-operation edit, and verified save
had already succeeded; no repair of that completed design was attempted.

## Delivered changes and verification

- **Live display:** propagate external schematic revisions, clear all affected
  sheet caches and stale drawing drafts, submit changed Metal scenes even when
  the window is inactive, and discard superseded asynchronous scene builds.
  Canonical document URLs keep the same workspace and undo/live closures when
  AppKit changes `/tmp` to `/private/tmp` during save. Snapshot pool enumeration
  also handles those aliases for imports that have not yet reached disk.
- **Finding 3:** `render_board.layer_ids`, project-specific layer discovery,
  custom layer names, and structured valid choices in errors; legacy names
  remain supported.
- **Finding 4:** preserve JSON boolean and integer identity at the native
  serialization boundary. Validate normalized operations with the strict input
  schema while preserving their exact replay payload and plan digest.
- **Finding 5:** track and via results and net filters use resolved connectivity.
- **Finding 6:** dry-run responses say `status: "preview"`, put prospective paths
  in `would_write`, and return empty `written` without a durability claim.
- **Finding 7:** add junction discovery/creation, typed pin/junction wire
  endpoints, endpoint retargeting, and atomic `remap_part` with explicit pin and
  optional pad maps. Preserve existing instance IDs, wires, copper, and library
  items; incomplete or conflicting mappings reject the transaction.
- **Finding 8:** retain the existing commit/save guarantees and exercise them
  together with the new edit capabilities.

Initial validation: the native Swift test target executed 713 tests, with zero failures and six existing
skips (an optional 3D render fixture, opted-out speech integration, and four
plane golden tests whose source board no longer matches their recorded data).
The Python/MCP suite passed all 46 tests. `make build` and `make native`
succeeded. The 19 MCP tests also passed against the rebuilt release CLI, and
the default release dylib preserved a boolean preview through commit.

Mounted real board/schematic canvases submit changed frames for same-count
edits, undo, redo, and edits while the window is hidden. A disposable project in
the sandboxed app exercised a five-to-six-pin remap with different library gate
and pin identities, preserved five original wires, and added the sixth wire
and track. The existing window visibly showed all six pins and tracks, changed
labels, a moved footprint, and a thicker track without reopening. Undo/redo
preserved the expected netlist. A live save returned `saved: true` and
`verified: true`; an independent disk context matched the pin/pad netlist and
all six tracks, with zero airwires. A later check after autosave returned
`saved: false`, `had_unsaved_changes: false`, `verified: true`, with the same
live document identity and matching disk data.

The exact reported 171-operation payload was not supplied, so this was a
representative regression, not a replay of that batch. The mounted test records
frame submission, not GPU readback; the separate app observation establishes
visible output for the tested fixture.

Pre-commit review found that native Horizon wires and junctions can omit cached
net fields. Wire editing and schematic queries now resolve connectivity from
endpoint identities and current block connections, including edits earlier in
the same batch. A regression uses native-style files to verify derived net
queries, duplicate-wire and junction reuse, endpoint retargeting, rejection of
self-loops and conflicting nets, and unchanged files after reads or refused
edits. Separate junctions at the same coordinates remain electrically separate.
After review, the full Swift suite executed 787 tests across three targets,
with zero failures and the same six skips. All 46 Python/MCP tests passed
against the rebuilt debug native tools, and `make build` succeeded.

**Setup limitation found during verification:** a sandboxed app granted access
only to a `.horizontal` package may be unable to publish the holder record in
the containing folder. Grant access to the project folder and use
`source="live"` when edits must reach an open window. `source="auto"` may fall
back to disk if discovery cannot find the document; disk success cannot promise
an update to an already open canvas. The verified live fixture used a `.hprj`
in an explicitly accessible disposable folder. This change does not redesign
holder discovery or macOS permissions.

The original implementation plan follows for acceptance criteria and rationale.

## 1. Make committed live edits visible — P1, first priority

**Evidence.** `ProjectDocumentView.installLiveSnapshot` replaces the archive
and project and increments board edit, board sync, and schematic edit revisions.
The board canvas already receives `boardSyncRevision`; its
`adoptExternallyUpdatedBoard` drops its local draft and invalidates drawing and
selection caches. This means the board symptom needs reproduction before
choosing a fix. Separately, the project view does **not** pass a `syncRevision`
to `SchematicCanvasView`, although that canvas already provides an external
replacement handler. That is a confirmed refresh gap, but does not by itself
explain the board symptom.

**Work.**

- Reproduce on a disposable project through an explicitly live MCP context.
  Record the running app/native build, project identity, and returned revision
  so the reproduction is tied to the code under test.
- Follow one edit from `applyArchive` through snapshot installation, the canvas
  revision callback, model adoption, drawing-cache invalidation, and presentation
  of the next frame. Check edits after prior mouse-driven canvas edits, when a
  local draft/cache already exists, as well as a freshly opened board.
- Fix the failing transition in place. Preserve viewport, visible layers,
  surviving selections, and document undo history. Ensure an older asynchronous
  scene build or schematic-to-board sync cannot overwrite a newer result.
- Pass an external schematic replacement revision from the project view to the
  schematic canvas. Invalidate cached pages affected by a replacement, including
  pages that are not currently visible. Choose revision increments so normal
  canvas edit callbacks do not reset their own ongoing interactions.
- Exercise the same replacement path for live pool changes, apply, undo, and
  redo; check the 3D view as well.

**Acceptance.** Move a footprint without changing object counts, change a track
width, and replace a five-pin symbol/footprint with a six-pin version. Each
change must appear in the existing window after the next completed render,
without reopening, saving, zooming, or changing panes. Repeat with the app in
the background and return to it, and with a hidden pane later revealed. Verify
undo/redo and a subsequent manual edit do not restore stale geometry.

An exported `render_board` image is insufficient evidence: it uses the export
renderer, not the on-screen canvas. Add a mounted-view/render integration test
and perform a visible app check. Existing live-server tests use a document
stand-in and do not establish this behavior.

## 2. Preserve boolean types through dry-run/commit — P1, finding 4

**Confirmed cause.** `HorizontalDispatchJSON.sanitized` attempts a `Double`
cast before preserving booleans. Foundation bridges JSON booleans through
`NSNumber`; a small reproduction of this branch order emitted `false` as `0`
and `true` as `1`. `normalized_ops` copies the input correctly before response
serialization. The strict Python input schema then correctly rejects the
numeric value on replay.

**Work.** Preserve JSON boolean identity before numeric conversion, using a
type distinction that does not also convert numeric 0/1 to booleans. Retain
integer precision and existing handling of non-finite numbers. Apply this at
the shared native response boundary, covering nested operations and pool JSON.
Validate normalized operations against the same discriminated operation
schema used for inputs, so an invalid preview cannot be advertised as replayable.

**Acceptance.** Through native JSON serialization and an actual MCP client,
dry-run operations containing both boolean values, feed `normalized_ops` back
unchanged with the returned base revision and plan digest, and commit. Include
nested arrays/pool fields and numeric 0/1 controls. Confirm boolean identity,
integer precision, and digest agreement. Keep strict input validation.

## 3. Return resolved track connectivity — P1, finding 5

**Confirmed cause.** `listTracks` builds a lookup of parsed tracks but uses it
only for coordinates. Net values and net filtering read raw `item["net"]`.
Original Horizon routing can omit that field; the dispatch session already
recomputes connectivity for its model. `listVias` already consults the model
when its stored net is absent.

**Work.** Use the shared resolved connectivity model for the returned track net,
name, and net filter. Preserve endpoint identities from file data. Expose the
stored net separately only if it helps explain a difference; do not write
derived values back to the project as part of a query. Audit the parallel via
query for consistent behavior. Leave genuinely unresolved or conflicting
connectivity explicit rather than guessing a net.

**Acceptance.** Use a fixture with native-style tracks lacking stored net fields:
pad-to-junction chains, branches, and paths through vias. `list_tracks(net=...)`
must include the resolved tracks and agree with the connectivity model and
pad netlist. Include a floating segment and a conflicting-net case to prevent
false assignments. Verify reads leave the archive unchanged.

## 4. Make import previews unambiguous — P2, finding 6

**Confirmed cause.** `HorizontalDispatchPool.importPart` returns a `written`
list while building a staged archive. `HorizontalDispatchMutation.execute`
adds `would_write`, but returns the builder's `written` unchanged on a dry run.
The original project is not committed by this path.

**Work.** Make the mutation coordinator own persistence-related response fields
for every mutation, including `pool_write`. Dry runs return `dry_run: true`,
`status: "preview"`, `would_write`, and `written: []`, with no committed
revision or durability claim. Commits retain `status: "committed"`, changed
paths, and the existing `durability` distinction between `unsaved_document`
and `disk`. Add `would_write` and status to the typed result contract. Keep the
existing `applied` count for compatibility and document that, in a dry run,
it counts staged changes and is not evidence of persistence.

**Acceptance.** Import previews leave disk bytes, the live archive, revision,
dirty state, and undo history unchanged. A live commit changes the document
and reports `unsaved_document`; save then verifies disk state. A disk commit
reports disk durability. Repeated imports remain idempotent. Assert these
semantics through the MCP response schema as well as native tests.

## 5. Make render layer selection discoverable — P2, finding 3

**Evidence.** `render_board` accepts layer names and numeric IDs encoded as
strings, using the exporter's layer list. The docstring already points to
`board_info`, but the advertised field is simply `list[str]` and errors do not
include valid choices. This is a discovery problem; rejecting unknown layers
is appropriate.

**Work.** Keep existing names compatible and add an explicit `layer_ids:
list[int]` selector, mutually exclusive with `layers`, across native dispatch,
Python, and MCP. Define `board_info.drawing_layers` as the authoritative list
of renderable IDs and display names. Give the input schema field descriptions
and examples; return structured valid choices for invalid layer requests.
Resolve names and IDs through one shared resolver. Define omitted/empty
selectors consistently with existing default-render behavior.

A fixed global enum cannot describe project-specific user layers and stackups;
discovery must remain project-specific.

**Acceptance.** Every advertised drawing layer can be passed back to rendering
by name or ID, including inner and user layers. Unknown selections fail with
valid alternatives. Existing name-based requests continue to work, and mixed
selectors fail before rendering.

## 6. Support explicit schematic wire and gate changes — P2, finding 7

**Evidence.** `drawNetLine` accepts two component-pin endpoints only. There is
no operation to retarget an existing line endpoint. `setPart` also clears
connections when the entity changes. The reported project-local gate/pad-map
workaround preserves the established connectivity; it does not require an
automatic migration of the user's completed design.

**Work, in two reviewable increments.**

1. Generalize `draw_net_line` with typed `from`/`to` endpoints for a symbol pin
   or sheet junction, retaining the legacy pin-to-pin parameters as a mutually
   exclusive form. Add junction discovery/creation and an operation to retarget
   an existing net-line endpoint by line ID. Expose created identities in dry-run
   normalization so the proposal can be committed unchanged. Keep block-level
   `connect` explicit: drawing a wire must validate the logical net rather than
   silently changing it. Reject cross-sheet endpoints, missing pins, ambiguous
   gates, and different-net junctions. Reuse junctions only when compatible;
   coincident coordinates alone are not sufficient.
2. Add an atomic part/gate/pin remap operation with an explicit old-to-new
   identity map. Capture the old connectivity before the existing `set_part`
   clearing behavior can discard it. Update component connections, symbol gate
   and pin references, and wire endpoints together; validate against the target
   part's pad map. Report unmapped connected pins and reject incomplete mappings
   rather than inferring identity from names or pin numbers. Use imported target
   library identities without modifying the source library. Keep unrelated
   instances that share pool items unchanged.

**Acceptance.** Reproduce the five-to-six-pin substitution with different gate
UUIDs. Preserve the five old wire IDs and their nets, connect/draw the sixth pin
to a junction, and verify symbol endpoints, logical pins, physical pads, copper,
and airwires. Preview and commit must agree; invalid mappings must leave no
partial changes; a live commit must undo/redo as one step.

## Delivery and final regression — finding 8

Implement the visible-refresh work first, followed by boolean preservation,
track connectivity, preview semantics, layer discovery, and the two schematic
increments. Each change carries focused native tests and MCP tests where its
contract crosses that boundary. Document the new contracts in the existing
automation/Python documentation and update the completeness plan's claims.

Use the successful import → edit → live save flow as a regression baseline.
On a disposable representative project, compare the validated preview with the
committed pin/pad netlist, copper, and airwires; verify the existing window;
then save and independently reopen the saved copy. Replay the original
171-operation batch if its recording is available. The supplied findings do
not contain that payload; the delivered regression uses a representative fixture.

Keep the three checks distinct: the transaction committed, the file matches
the live snapshot, and the current canvas shows that snapshot. The current
save implementation verifies archive hashes; it does not verify presentation.
Completion requires all three, with no new schema, transaction, permission,
connection, or save regressions.
