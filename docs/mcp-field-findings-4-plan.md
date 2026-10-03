# MCP field findings 4: stubs that add up, previews that fit

Planning baseline: `f25c1ad`. Written October 3, 2026, from two notes taken
while pruning the last dead-end wires from Billo live, the first edit after
[round three](mcp-field-findings-3-plan.md) was merged.

## Findings and changes

12. **find_dangling and prune_sheet disagreed on what a stub is.**
    - **Before:** `find_dangling` listed 2 stubs on Billo's Digital sheet,
      one wire and one junction each. The `stubs: true` dry run removed 4
      wires and 4 junctions there. Each stub was a two-wire branch (rail,
      corner, dead end), and prune peeled it back a wire per pass. The
      removal was right, but the compact reply gave only counts. It looked
      as if prune would take wiring nobody had reported, and clearing that
      took a wire listing and a render.
    - **Now:** `HorizontalSchematicDebris` traces each dead end in one pass,
      back to where it branches, and groups the result into runs. A run is
      one stub however many wires or bare ends it has; a Y of two dead arms
      is one. Each stub lists every wire and junction it takes, its bare
      ends, and `branches_from`, the junction or pin it hangs from. The MCP
      server spells that end as `U8.PA13` or `junction:<id>`.
    - **Totals:** `find_dangling` adds `stub_net_lines` and `stub_junctions`.
    - **Prune:** `prune_sheet` with `stubs` removes those same runs in one
      pass instead of recomputing the sheet per layer. Its `removed` counts
      now include `stubs` and `unanchored_islands`, which a compact reply
      keeps, so a dry run can be checked against `find_dangling` directly.
13. **A verbose dry run of one prune was 2.2 MB.**
    - **Before:** `preview` carried every changed file's whole text before
      and after, about 1.1 MB each for Billo's schematic. The useful part,
      `changes`, was 738 bytes.
    - **Now:** a dry run's preview, at detail `full` (the default, MCP
      `verbose`), gives each file's sizes and the JSON paths it adds,
      removes and changes, at most 100 of each with the full count beside.
      For example: `sheets/<id>/net_lines/<id>` removed.
    - **Whole text:** only at the new detail `files`, the MCP `file_text`
      flag. Only tools that have a dry run take it.

## Verification

- **Swift:** 805 tests, 0 failures. `HorizontalMCPFieldFindingsTests` has 17,
  including two new ones:
  - A rail with two dead runs off one junction, one of them a Y, gives 2
    stubs of 5 wires and 5 junctions. Both hang from the rail junction, and
    the dry run removes exactly that.
  - A verbose dry run previews paths and no text; `files` adds the text;
    an unknown detail is refused.
- **Python:** 60 tests, all passing. New ones cover:
  - `branches_from` spelled as one string;
  - `file_text` advertised only on tools with a dry run;
  - a verbose dry run with paths but no text, and `file_text` adding it.
- **Billo, on a disk copy (debug build):** recreated the Digital sheet's
  rail–corner–dead-end branch off the P3.3V rail junction.
  - `find_dangling` (0.16 s): 1 stub, 2 wires, 2 junctions, branching from
    `7eb0b0b0…`.
  - The compact dry run removed 2 wires, 2 junctions, 1 stub.
  - The verbose dry run reply was 1,806 bytes, against 2.2 MB before. Its
    preview names the 4 removed paths.
  - `detail: "files"` still returns the 2.2 MB of text when asked.
