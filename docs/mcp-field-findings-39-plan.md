# MCP field findings 39: placing a part keeps the routed copper joined

Planning baseline: `7556819`. Written October 15, 2026. The item is the
user's, from placing parts on Billo's board in the app, and is numbered 125
for billo's `docs/horizontal-mcp-notes.md`.

## Findings and changes

125. **Placing a component showed every airwire, routed or not.**
     - **The report:** "When placing a component, all the connection lines
       suddenly appear even if they're connected. I think only the
       unconnected nets should show."
     - **Reproduced on Billo:** the board loads with 31 airwires.
       - `HorizontalBoard.placingPackage`, placing C129, made a draft with
         329.
       - `regenerateAirwires()` on the unchanged board alone gave 327: P5V
         went from 1 to 24 and P12V from 0 to 11.
     - **The cause:** Horizon writes no net on a board junction. Billo loads
       with 0 junction nets, and the editor's connectivity pass
       (`HorizontalBoardConnectivity.recompute`) gives 1,561.
       - **The loader** derives junction nets for its own airwire pass
         (`resolveBoardConnectivity`'s `airwireJunctionNetIDs`). It keeps
         them off the board, since a save writes the board's junction nets
         into the file.
       - **`regenerateAirwires()`** uses only the board's junction nets. On a
         board as loaded, a track ending at a bend joins nothing, so every
         routed connection that bends came back as an airwire.
       - **The commit** runs the connectivity pass first
         (`publishConnectivityResolvedEdit`), which is why the airwires went
         away again once the part was placed.
       - **The placement draft** regenerated without the pass.
       - **A move's live airwires** (`movingAirwires`) read the board's
         junction nets the same way. So moving a part straight after a load
         skipped the routed bends of its nets too.
     - **Tried first and dropped:** deriving the loader's junction nets inside
       `regenerateAirwires()`. It fixed the loaded board but disagreed with
       the editor's pass on a board that had been through it: 38 airwires
       instead of 31. The pass deliberately leaves some junctions without a
       net, such as copper joining two nets.
     - **Now:** both run the editor's connectivity pass first, as the commit
       does.
       - **`placingPackage`** takes its airwires from a resolved copy. The
         draft keeps its own nets until the commit.
       - **`startMovingAirwires`** resolves the board inside the background
         request, off the main thread.
     - **Costs:** placing C129 on Billo now takes 136 ms instead of 73 ms in a
       debug build, once per placement. A move pays nothing on the main
       thread.
     - **Result:** C129's placement draft has 33 airwires, the board's 31 and
       C129's own 2.
     - **Seen on the way:** the connectivity pass leaves 22 of Billo's tracks
       with no net (ADC1 IN± 7, SHIELD 6, GND, P3.3V, Signal 2− and 6
       unnamed). They touch no pad, and any edit's commit already strips them
       the same way.

## Tests

- **`HorizontalProjectEditorTests.testPlacingAPackageOnABoardAsLoadedKeepsItsRoutedCopperJoined`**
  (new).
  - **The board:** R1 and R2 are routed through a bend whose junction is
    written as Horizon writes it, and R3 is unplaced.
  - **Placement:** `placingPackage` places R3 with no airwires. Without the
    fix it has one, the bend.
  - **Moves:** the test also shows why the canvas resolves first. A move of
    R1 has one live airwire from the board as loaded, and none after the pass.
- **Results:**
  - **Swift:** 913 tests (6 skipped, 0 failures), the 912 from before plus the
    new one.
  - **App builds:** Xcode builds for macOS (`/tmp/r39-mac-dd`) and the iOS
    Simulator (`/tmp/r39-ios-dd`).
- **Left for the app:**
  - **Placement:** reopen Billo, so the board is as loaded, and place an
    unplaced part. Only the board's unrouted airwires and the new part's
    should show.
  - **Moves:** move a placed, routed part. Its live airwires should leave its
    routed connections alone.
