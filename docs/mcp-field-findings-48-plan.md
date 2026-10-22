# MCP field findings 48: reading a hierarchical design

Planning baseline: `320ca5e`. Written October 22, 2026, from the Calypso session that turned Calypso's ADC
converter and ADC driver into blocks used 4 and 8 times ("ADC Converter" on the ADC sheet, "Front-End Channel" on
the Front End sheet). The edits worked; reading the result back did not.

## Findings and changes

152. **`render_sheet` drew the wrong page once a design had instances.** It counted pages as every block's sheets
     end to end, but the schematic PDF prints each instance's sheets right after the sheet that uses it (Horizon's
     `walk_sheets`). Every sheet after the first one with instances came out as some other page:
     - **Wrong page:** "Front End A" drew page 5, an ADC Converter instance.
     - **Wrong block:** "ADC Converter" drew Coil Offset DACs.
     - **No page:** before the block had instances, the request failed with "The PDF has no page 14".
     - **Now:** the sheet asked for is drawn alone, as its PDF page, through
       `HorizontalExportBackend.exportSchematicPage`. That is the exporter's own drawing, framed and numbered as
       the PDF has it, so the page can't drift from the PDF.
       - **Which instance:** a sub-block's sheet is a page once per instance, and `instance` (a refdes path such
         as `ADC1`, or an instance uuid) picks which. The first is the default, and the reply's `page` and
         `instance` say which page was drawn.
       - **A block no instance uses** draws its sheet as the block holds it, with a `note` saying it is no page
         of the PDF.
       - **Shared code:** `schematicPages(of:)` is now what the exporter and the renderer both page through.
       - **Pages:** `HorizontalSchematicPage` carries its instances' refdes (`refdesPath`), as the PDF outline
         names them.
153. **A sheet index was ambiguous as soon as a sub-block existed.** Every block has a sheet 1, so `find_dangling`,
     `find_overlaps`, `list_*` and the other reads refused `sheet: 1` with "Sheet selector is ambiguous; use
     block_id and sheet_id".
     - **Now:** without `block_id`, an index or a name is the top block's sheet when the top block has one. A
       sub-block's sheet is reached by its block, its name or its id.
     - **Where:** `HorizontalDispatchValidation.sheet` and `renderSheet`.
154. **`check`, `get_net` and `netlist` read only the top block's own components.** A net that reached its pins
     through block ports looked empty:
     - **Single pin:** `ADC1_SDO0`, from U1.PC1 to instance ADC1's SDO0, came back as "Net has a single pin".
     - **No pins:** `AIN0+` … `AIN7-`, which join an ADC Converter port to a Front-End Channel port, came back as
       "Net has no pins".
     - **Count:** 36 single-pin and 16 no-pin findings, all false.
     - **Template pins:** the power nets listed the sub-blocks' own components (R50 on `VREF_ADC_5V`) once,
       under the block's refdes, rather than each instance's.
     - **Name clash:** a sub-block's port net called `AIN0+` or `VOCM`, beside the top net of that name, made
       `get_net` by name ambiguous.
     - **Now: pins.** In a design whose top block uses others (`flattenedBlock.isHierarchical`), a top block net's
       pins are the flattened design's:
       - its own components';
       - every instance component that reaches it through a port, or shares it as a power net, under the
         instance's refdes, with `instance_id` its flat uuid.
       A sub-block's own components leave the top block's nets: they are part of the design only through their
       instances. A sub-block's own nets keep that block's components, so editing and reading a block still agree.
     - **Now: block and ports.** Each net records its block (`block`, `block_id` in the reply, nil for the top
       block and the power nets every block shares). It also records the block instances whose ports are wired to
       it: `block_ports`, each with `instance`, `block`, `port` and `port_net_id`, plus `port_count`.
     - **Now: names.** One lookup, `HorizontalDesignIndex.nets(named:block:)`, chooses among nets of one name: the
       block a read is about, else the top block's. `get_net`, the net selector and the read filters
       (`list_net_labels` and the rest) all use it, so a name only both blocks use is no longer ambiguous.
     - **Now: `check`.** It counts what the flattened design puts on a top net, and on a sub-block's net its
       components plus the ports of the blocks it uses. Calypso's 52 findings are gone, and a real single-pin net
       in a sub-block says which block (" In block Channel.").
155. **An instance's refdes was no component.** After U21–U24 became instances ADC0–ADC3, `get_component U22`
     answered "No such component", though `place_component U22` placed it (the editor already resolved an instance
     through the flattened block).
     - **Now:** an instance's refdes, flat uuid or a prefix of it reads as the instance. The refdes, no-populate and
       board package are the instance's, and the pins sit on the flattened nets (an instance's own unnamed net reads
       as Horizon names it, `ADC1/C300, U21`). `instance` is the instance path and `instance_of` the block's own
       component.
     - **Who uses it:** `zoom_to`, `list_tracks`, `list_board_texts` and the rest that take a component resolve one
       the same way. `highlight` and `select` mark both the instance's package and the block's symbol.
     - **Lookup order:** the top block's component comes first, then the one instance with that refdes, then a
       sub-block's own component. A block whose components take the first instance's refdes, as Calypso's do,
       therefore reads as that instance.

## Not changed

- **The app quitting** during a live dry run on Weevling: that was a restart from Xcode, not a crash. The edit
  committed just before it had not autosaved, so it was lost.
- **`list_nets` still lists every block's nets.** That follows `testBlockScopingReachesTheSecondBlock`: reads aren't
  scoped, so an edit to a sub-block reads back. They now say which block they belong to.
- **An instance's own nets** (`ADC1/…`) are still the board's alone: named in replies, not listed as nets.

## Tests

- **Swift:** two in `HorizontalProjectEditorTests`, on a Channel block used twice (CHA, CHB, its R1 there as R11
  and R12):
  - `testAHierarchicalDesignReadsAsItsInstancesWireIt`:
    - `get_net IN` is the top net, with pins R11 and R12 and ports CHA and CHB.
    - The block's own IN lists under `block` Channel.
    - `get_component R12`, by refdes and by its flat uuid, is CHB's, pin 1 on IN.
    - `check` reports nothing about IN.
  - `testASubBlocksSheetRendersAsAnInstancesPage`:
    - The block's sheet, used nowhere, draws with a note.
    - `sheet: 1` is the top block's page 1.
    - CHB's page is 3; the default is CHA.
    - An unknown instance is refused, and `find_dangling sheet: 1` isn't ambiguous.
- **The whole suite:** 1,115 run, none fail, 6 skipped. `RouterRealBoardHarnessTests.testRoutingBetweenRealPads`
  went over its one-second budget once, at 1.32 s, and passed when rerun.
- **Python:** `make python-test`, 83 pass.
- **On Calypso (claude/h757):**
  - **`check`:** no connectivity findings, against 52 before.
  - **`get_net`:** `ADC1_SDO0` lists U1.PC1 and U22.SDO0 with port ADC1:SDO0; `AIN3+` lists C181, R94 and U22 with
    ports ADC1 and CH3.
  - **Renders:** ADC Converter as ADC2 is page 7, Front-End Channel as CH5 is page 15 (U37, R106–R113), Front End
    is page 9 and Power page 22, as in the PDF.

## Needs

- **An Xcode rebuild,** so the live app runs the new engine.
- **`make native`,** so the MCP server's release worker does.
- **A new session,** so the MCP server loads `render_sheet`'s `instance`.
