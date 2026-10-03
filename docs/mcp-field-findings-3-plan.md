# MCP field findings 3: staleness, debris and the cost of reading

Planning baseline: `2114efa`. Written October 3, 2026, from eleven notes
kept while finishing the Billo board's schematic through the MCP server after
[round two](mcp-field-findings-2-plan.md). This round covered:
- removing a sheet of leftover FPGA wiring;
- pruning stubs;
- tracking down GND and P12V symbols left on wires that went nowhere;
- checking an MCU's power pins.

## Findings and changes

1. **A rebuilt engine and a stale server disagreed silently.** The app
   listed new ops, while the server's schema rejected them.
   - The engine's `version` now reports `ops`, `ops_digest` (each op and its
     parameter names, digested) and its build time.
   - The Python schema computes the same digest. `connection_status`
     compares the live engine's `list_ops` with the schema op by op and
     parameter by parameter.
   - `open_project` returns `warnings` naming which side is older.
   - A test holds the schema and the engine in step.

2. **Dead contexts piled up**: twenty for one document, one per
   timeout-and-reopen. Opening a document that already has a context now
   returns that context and its `project_ref`. If the old context's
   connection was lost, it is re-attached to the new one. Contexts on a
   document since closed or reopened, and dead duplicates, are dropped.
   Reopening a disk context reloads it rather than starting another worker.

3. **The server could not tell it was out of date.** At startup it records its
   source files' modification time and its git commit. `connection_status`
   reports `stale` and the changed files when either moves. Its warnings say
   to restart the server, and that a reconnect may not.

4. **Reads were too large.**
   - `list_components` rows leave out package pads unless
     `include_terminals`. Those pads were most of the 60 KB for one sheet,
     because of the 240-ball MCU.
   - `get_component` on a part with more than 64 pins lists only its
     connected and no-connect pins, says how many it left out, and takes
     `all_pins`.

5. **A power-pin question took a full dump and jq.** `get_component` takes
   `pin_regex` and `group_pins`. The latter returns supply and ground pins
   by the net each is tied to, no-connects, unconnected pins, and a count of
   signal pins.

6. **"Reconnect" did not restart the server.** `connection_status` reports
   the server's PID, start time, package version and commit.

7. **`prune_sheet` kept debris that named a net.**
   - `unanchored` removes wiring islands that reach no pin, port or bus
     ripper, whatever net their labels or power symbols name. It reports
     where each was.
   - `stubs` trims dead-end wire runs back to where they branch.

8. **Whole-design reads did not fit.**
   - `list_net_lines` rows are compact by default: one-line ends such as
     `U8.PA13` or `junction:<id>`, and `[x, y]` points. The junction, label
     and power-symbol lists drop the repeated sheet and net uuids. `verbose`
     restores the full rows.
   - Two new reads answer the questions those dumps were for:
     - `find_dangling`: unanchored islands, stub ends, broken wires.
     - `find_overlaps`: a wire over a pin it does not end on, a junction on
       a pin with no wire, coincident junctions no wire joins, and a wire
       ending part way along another.

9. **A commit redid its dry run.** A dry run keeps what it staged and
   validated. A commit at the same revision, replaying the same request with
   its `plan_digest`, installs that instead of editing and loading again
   (`timing.reused_dry_run`). It accepts the request either as sent or with
   the normalized ops. On Billo the commit took 0.31 s against 4.4 s.

10. **Notes outlived their parts.** `list_texts` gives each free note its
    `near_symbol` and the distance to it, so a note far from everything
    stands out. `remove_component` and `remove_symbol` take
    `texts_within_mm`, removing the notes nearest to the removed symbols.

11. **The client showed a stale schema.** The `apply_ops` description ends
    with the schema digest and op count, so an agent can compare it with what
    `connection_status` and `version` report.

### Found on the way

Checking `find_overlaps` against Billo turned up 20 `wire_over_pin` hits on
mirrored vertical resistors. All were false. Schematic symbols turn the other
way when mirrored (`HorizontalPlacementTransform.schematicGeometry`), and the
new code had used the board transform. So did round two's `terminate_pin`, so
a stub off a mirrored and rotated symbol started from the wrong pin position.
All three now use the schematic transform. A test terminates a pin at four
angle and mirror combinations, checking the stub against the renderer's pin
position and checking that `find_overlaps` stays clean.

## Verification

- **Swift:** `HorizontalMCPFieldFindingsTests` now has 15 tests. The six
  new ones cover:
  - prune with `unanchored` and `stubs`;
  - overlaps;
  - note proximity and removal;
  - dry-run reuse and its refusal at a moved revision;
  - `version`'s vocabulary;
  - rotated and mirrored `terminate_pin`.
- **Python:** 58 tests. The new ones cover:
  - schema and engine parity, and the digest in the tool description;
  - server identity and stale warnings;
  - context reuse;
  - summary reads and pin groups;
  - `find_dangling` and prune through MCP.
- **The 56 MB Billo design, on a disk copy:**
  - `find_dangling` ran in 0.05 s and found 4 stub ends.
  - `find_overlaps` ran in 0.09 s and found nothing, after the transform fix.
  - A dry-run `prune_sheet` with `stubs` took 4.4 s; replaying it took 0.31 s.
  - Afterwards `find_dangling` was empty.
