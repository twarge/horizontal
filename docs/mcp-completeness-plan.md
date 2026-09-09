# MCP completeness: survey and plan

Surveyed September 8, 2026, against the working tree that adds holder records,
pool search and import, schematic symbols, wires and text. The reliability and
analysis work is [its own plan](mcp-improvements-plan.md) and is not repeated
here; this asks a different question.

**The yardstick.** Can an agent take a design from where it is to where the
user wants it without the user touching the app? Every gap below is a place
where the answer is no, and the agent has to hand the work back.

**Where the surface stood.** 47 MCP tools over 38 native methods and 21 edit
operations. The block was well covered. The schematic was half covered. The
board was placement only. Nothing that was not the top block was reachable at
all. It now stands at 69 tools over 46 methods and 65 operations, and the
sections below say what closed each gap.

## Confirmed gaps

| Priority | Gap | Evidence | Consequence |
|---|---|---|---|
| **done** | ~~A live edit cannot be saved.~~ Fixed: `save` writes the open document through the document system, and `project_info` reports `unsaved_changes`. |  |  |
| **done** | ~~No track or via operation.~~ Fixed: `place_track`, `remove_track`, `set_track_width`, `place_via`, `remove_via` — manual routing, which refuses to short two nets. Autorouting remains a separate question. |  |  |
| **done** | ~~No power symbols or net labels.~~ Fixed: `place_power_symbol`, `place_net_label` and their removes, with `list_power_symbols` and `list_net_labels`. Buses and bus rippers remain. |  |  |
| **done** | ~~Reads do not cover what writes now touch.~~ Fixed: `list_symbols`, `list_net_lines`, `list_tracks` and `list_vias`, plus `package_instance` alongside `symbol_instance` so endpoint identities are nameable. |  |  |
| **done** | ~~No sheet management.~~ `add_sheet`, `rename_sheet`, `remove_sheet`, `set_sheet_index` — renumbering swaps, since two sheets cannot share a page number. |  |  |
| **done** | ~~`new_project` is native-only.~~ Fixed: it is an MCP tool, and refuses a path that already exists. |  |  |
| **done** | ~~No planes.~~ Fixed: `place_plane`, `remove_plane` and `pour_planes`, which runs the same pour engine the app does. |  |  |
| **done** | `place_polygon` (layer 100 is the outline), `set_stackup`, `place_hole`, `place_keepout`, `place_dimension` and `place_board_text` — a board is creatable from nothing. The app draws dimensions too: Design ▸ Draw Dimension. |  |  |
| **done** | ~~Rules and stackup are read-shallow and write-closed.~~ `board_rules` reads one entry per rule; `add_rule`, `set_rule` and `remove_rule` write, gated on the app's own rules validator; `set_stackup` sets the layers. |  |  |
| **done** | ~~Pool items are searchable and writable but not readable.~~ Fixed: `get_pool_item` reads through the project's own view of its pool. |  |  |
| **done** | ~~Only the top block is editable.~~ `apply` takes a `block`; `add_block_instance`, `connect_block_port` and `place_block_symbol` compose blocks; `list_block_instances` reads them. Writes are block-scoped, reads are project-wide — deliberate, and documented. |  |  |
| **done** | ~~No buses or net ties.~~ `add_bus`, `add_bus_member`, `place_bus_label`, `place_bus_ripper`, `add_net_tie`, `place_net_tie` and their removes and reads. The app draws them too: Design ▸ Place Bus Label, Place Bus Ripper, Tie Nets. |  |  |
| **done** | An automation edit is undoable in the app — it registers on the document's own undo manager, not a fallback the Undo command never reads — and through the MCP: `undo` drives that same stack, and refuses a disk context rather than pretending to have one. |  |  |

## What is already sound

Worth stating, so the plan does not churn it: source selection and revision
identity, guarded edits with receipts, recoverable transactions, the holder
records that make "who has this project open" answerable without the live
channel, structured errors, typed and discriminated schemas, and the analysis
tools over pinned snapshots. The block-level vocabulary — components, nets,
connections, groups and tags — is complete enough to describe a circuit.

## Delivery order

Each step is reviewable on its own and leaves the surface honest.

**1. Save, and `new_project`. — Done.** `HorizontalLiveDocument` carries
`save` and `isEdited`; the workspace view fills them in from
`HorizontalDocumentSaving`, which finds the document by URL through
`NSDocumentController` and writes it with `writeSafely`. `save` and
`new_project` are methods and tools. What remains unverified is only whether
SwiftUI's own `NSDocument` subclass behaves like the one the tests drive —
worth a manual check the first time it is used against a real document.

**2. Reads for everything already writable. — Done.** `list_symbols`,
`list_net_lines`, `list_tracks` and `list_vias`. Endpoints are reported the
way the file states them — a pin, a junction, a pad, a bus ripper, a port —
rather than as bare coordinates, which is what step 3 will need to write them.
Two identity names were wrong for new callers and are now spelled out:
`symbol_instance` and `package_instance` sit beside the older `symbol_id` and
`package_id`, which mean the pool item rather than the instance. The rule this
establishes: a write op ships with its read in the same change.

Still no standalone junction list. Junctions surface through the endpoints
that reference them, which is enough to find and remove a wire; placing one
outright belongs with the routing ops that need it.

**3. Manual routing. — Done.** `place_track`, `remove_track`,
`set_track_width`, `place_via`, `remove_via`. An endpoint is a pad
(`{component, pad}`), a junction, or a point that becomes one; a point where a
junction already sits joins that junction rather than stacking a second on top,
and a junction nothing holds any more goes with the copper that held it. The
net comes from the ends, and ends on different nets are refused rather than
shorted. Widths are explicit: the net class that would supply a default is not
readable until step 6.

Not covered: arcs (every track placed here is straight), and anything that
finds a path. Autorouting is still the open question below.

**4. Power symbols, net labels, and sheets. — Done.**
`place_power_symbol` marks its net as a power net, because that is what a
power symbol on a net means, and says so in the change. The symbol's shape is
a property of the net, not the symbol, so `style` sets it for every symbol on
that net — surprising until you know it, hence the note in the tool text.
`place_net_label` on two sheets is how one net spans pages. `add_sheet`,
`rename_sheet` and `remove_sheet`, where removing a sheet that still holds
work is refused rather than done quietly, and the last sheet stays.

Not covered: reordering pages, and buses, bus rippers and net ties.

**5. Planes and board outline. — Done.** `place_polygon` (layer 100 is the
outline), `place_plane`/`remove_plane`, and `pour_planes`, which runs the app's
own pour engine headlessly. Defining a plane and filling it stay separate acts,
and `list_planes` reports `poured` so the difference is visible. The recorded
gotcha holds: `pour_planes` pours from the board as committed, never from an
edit in flight. A pour drops fill that reaches nothing on its net, so a plane
over no copper of its own net yields nothing — which is correct, and worth
knowing before concluding the pour failed.

Keepouts, holes, dimensions and board text remain their own object kinds with
no ops.

**6. Rules, stackup and net classes. — Read done, write deliberately not.**
`board_rules` returns the rules as the file states them, the net classes they
select, and the stackup; `add_net_class` and `rename_net_class` create and name
classes. The follow-through: `place_track` now takes its width from a
`track_width` rule when one covers the net's class and layer, and still refuses
to invent one when none does.

Rule *writing* followed, once there was a way to make it safe: the app's own
`HorizontalBoardRulesValidator` gates every write, so nothing commits that the
rules editor would reject. `add_rule` uses the editor's own defaults for the
kind, and `set_rule` merges rather than replaces.

Doing it surfaced a bug in the read that shipped before it. Horizon keys rules
by kind, and the kinds that hold several key those by uuid underneath;
`board_rules` had treated each top-level entry as a single rule, so it reported
whole families as one. The synthetic fixture agreed with it, because both were
written from the same misunderstanding — the fix carries a test that reads a
board the app actually wrote.

**7. Pool item reads, then hierarchy. — Reads done, hierarchy half done.**
`get_pool_item` closes the pool loop: search, read, edit, write back.

Hierarchy turned out to split cleanly in two. Block *scoping* was contained —
`apply` takes a `block`, the editor loads that block's files, and a sub-block's
board operations are refused because its board file is not loaded at all. That
closes the "reads half-work while writes silently hit the top block" trap.

Block *composition* — `block_symbols` and `block_instances`, placing a
sub-block into a parent sheet — is not done, and is the part that genuinely
needs the decision below. It is also untested against a real multi-block
project: the test fixture has one block, so the scoping is proven by its
refusals and by naming the top block explicitly, not by editing a second one.

## The three decisions, now taken

**Autorouting — the correctness half is fixed; the completion half is not.**
The harness's own diagnosis was right: detour entry picked the ring corner
nearest the approach, and the elbow onto it cut through the hull the detour
existed to avoid. Tangent selection replaced it, and **violations went from
every completed route to none**, stable across samples. That made exposing the
router defensible, so `autoroute` exists: it writes only routes verified clear
and reports what it could not do.

What it still cannot do is route a dense board. Completion is a few percent,
because the finder walks around one obstacle at a time and gives up after
trying both ways past each. Getting past that means a real search — A\* over the
routing graph, or finishing the vendored PNS — and it is a different piece of
work from corner selection. The harness now asserts the violation invariant and
merely reports completion; the tool's own description says it is best effort.

**How far hierarchy goes — as far as composition, not as far as unified
scope.** The editor takes a `block` and loads that block's files; instances,
port connections and block symbols are ops. What was *not* done is making reads
block-scoped: `list_nets` and `list_components` still report the whole project.
That asymmetry is now deliberate and documented rather than accidental, because
a read that names no block sees an edit wherever it landed — which is usually
what a caller wants. Making reads scoped too would be the redesign; this was
not.

**Whether the board should be creatable from nothing — yes, and it is.**
`new_project` makes the project, `set_stackup` sets the layer count and
thicknesses, `place_polygon` on layer 100 gives it a shape, and the routing and
plane ops fill it. Rules stay unwritable, so a board built this way carries
Horizon's defaults rather than stated constraints — which `board_rules` says
outright rather than implying the board is fully specified.

This survey read the dispatch method table, the edit vocabulary, the schematic
and board object kinds in the file model, and the app's own command set. It
did not change behaviour.

## What is still missing, on both surfaces

Kept here rather than in a commit message, because it is the list to pick up
from next.

**In the MCP.** Nothing on the original list. Board dimensions and board text,
buses with their labels and rippers, net ties, arcs in polygons and tracks, and
`undo` are all ops or tools now, each with the read that names what it wrote.

**In the app.** Board holes and keepouts can be read, drawn, selected and
hidden, but not *created*: `placeHole` and `placeShape` are padstack-editor
tools that write into the padstack being edited, while a board hole is a
padstack reference plus a placement. A board-level tool needs a padstack
picker, a click-to-place interaction and an inspector — a real feature, not a
flag on the existing one. The same is true of keepouts, which have a
visibility toggle and no way to draw one.

The bus, ripper and net-tie tools took a different route than the rest of the
canvas, and the reason is worth keeping. Those objects live in the block as
much as on a sheet, and the sheet applier can update an entry but never create
one — it was never a writer of new objects. Rather than grow a second creator
that would have to agree with the first, the tools hand the automation
channel's own operations to `HorizontalCanvasProjectEdit`, and the document
adopts the archive that comes back exactly as it adopts one from the live
channel: reload, and one named step on the undo stack. What that buys is that
the file the tool writes is the file the MCP writes; what it costs is a whole
reload per placement, which is why it is not how the tools that only touch a
sheet work. Board holes and keepouts would fit the same shape.

**In the router.** Completion, at a few percent. The correctness invariant
holds and `autoroute` never writes a route it has not verified, but the finder
walks around one obstacle at a time and gives up after trying both ways past
each. Getting past that means a real search — A* over the routing graph, or
finishing the vendored PNS — not better corner selection.
