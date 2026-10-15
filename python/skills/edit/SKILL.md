---
name: edit
description: Change a Horizon/Horizontal design safely through the horizontal MCP tools — swap a part, add or remove components, rewire nets, redraw schematic wiring, move packages, or clear copper. Use for any apply_ops, remap_part, import_pool_part or place_component work, and before saving or committing design changes.
---

# Edit a design safely

Every edit is planned, dry-run, committed in a small batch, and verified. The app autosaves it. Horizontal has no geometric design rule check, so you are the one who keeps copper consistent with the netlist.

## 1. Open the right context

Open with `source: "live"` when the user has the project open (see the `connect` skill). Confirm `data.source` is `"live"`, and keep the `revision` from the reply.

A live edit is one undo step in the app, and the document autosaves it in place like any Mac document, so the files follow within seconds. Undo in the app, or the `undo` tool, takes an edit back and autosaves that too. Git is the record across sessions. A disk edit is refused with `DOCUMENT_OPEN` while the app holds the project.

While the app has the project open, don't run git commands that rewrite its files (`checkout` of another branch, `stash`, `pull`, `reset`, `rebase`). The open document does not reload them, and its next autosave writes its own copy back. Ask the user to close the project first, and reopen it afterwards. Creating a branch, `add` and `commit` touch nothing in the project and are fine.

## 2. Gather what the ops will name

- `list_ops` lists every edit op and its parameters. Components and nets may be named by refdes, net name or UUID. Unnamed nets need their UUID.
- `get_component` gives gate and pin ids, symbol positions, angle and mirror, and board placement.
- `list_net_lines` gives the wires on a sheet and what each end lands on; `list_power_symbols` and `list_net_labels` give the rest of the drawing.
- `list_tracks` (filtered by net) gives copper and the pads each track lands on.
- Take a baseline with `find_dangling` and `check`, so you can tell your own leftovers from what was already there.

## 3. Dry run, then commit

Send each batch to `apply_ops` with `dry_run: true`, an `expected_revision` and a fresh `operation_id`. Read the reply: `status`, `applied`, `would_write`, and any error naming `ops[N]`. Then commit the same ops with the dry run's `plan_digest`, the same `expected_revision` and a new `operation_id`.

- Ops that create things take a short `id` ("j1", "u24"), which later ops in the batch use. The reply's `handles` maps each to its UUID.
- Keep a batch to one logical change. Each becomes one undo step the user can read ("Remove Track, Remove Symbol… (31 edits)").
- If a commit's reply is lost, call `transaction_status` with the `operation_id` before retrying.

## 4. Part swaps

1. Find the part with `search_pool`. A row with `in_project_pool: false` needs `import_pool_part` first, which is a mutation in its own right.
2. Read the new part's datasheet pinout. Extra pins — shutdown, reference, null — need a decision. Mark the unused ones with `set_no_connect` only when floating is the datasheet's "on" state.
3. `remap_part` keeps connections, symbols and wires.
   - When gate names differ (a dual's `A`/`B` against a single's `Main`), pass `pin_map` with old `gateUUID/pinUUID` → new `gateUUID/pinUUID`.
   - Before the remap, take a gate that goes away off the sheet (`remove_symbol`) and `disconnect` its pins.
   - A pad that still has copper blocks the remap ("needs an unambiguous pad_map"). Remove that copper first (step 6), or pass `pad_map`.
4. New symbols can put pins at different offsets. After a remap, `place_symbol` the gate so its pins land on the existing wires, then render to check.

## 5. Schematic wiring

- `draw_net_line` joins pins and junctions with one straight segment. Make orthogonal routes from `place_junction` corners, and keep to the sheet's grid (usually 1.25 or 2.5 mm).
- `terminate_pin` runs a short stub to a power symbol or label. Copy the sheet's existing layout (shared rails, power-symbol style and orientation) where there is one.
- `remove_symbol` removes the wires that end on the symbol, but leaves junction-to-junction pieces behind. Clean them up with `remove_net_line` by id, or `prune_sheet` with `stubs` and `unanchored` once your baseline showed nothing dangling.
- A named net drawn without a label is flagged "Label missing". Leave internal nodes unnamed, as most sheets do, or label them where the label fits.

## 6. Copper

Changing a pad's net leaves its tracks on the old net. That is a silent short, because nothing checks clearance or connectivity against copper.

- Before you reconnect pins or swap footprints, use `list_tracks` on every affected net and `remove_track` each track that lands on a pad whose net changes.
- On long trunks, remove only the stubs at the changed pads.
- Look for vias left under a footprint that lost its exposed pad.
- Don't guess positions in a dense layout. Leave new packages unplaced (`check` lists them) and say what needs placing and routing.

## 7. Verify

- `render_sheet` with `region` crops over every area you touched.
- `find_dangling` across all sheets should match the baseline.
- `check` with `full: true`: new findings should be only the expected ones (unplaced packages, unrouted connections).
- Use `get_net` or `netlist` on each changed net, and compare with the intended connections pin by pin.

## 8. Save and record

1. Before committing, call `save` and confirm `verified: true`. It writes any autosave still pending, so git doesn't take the files halfway through one. `saved: false` with `had_unsaved_changes: false` only means autosave had already written everything.
2. In git, commit on a branch rather than the default one. The message should say what changed, why, and what is left: routing, unplaced parts, follow-ups.
3. Leave stale exports (PDFs, Gerbers, BOMs) alone until routing is done, then regenerate them with the `fab-outputs` skill.
