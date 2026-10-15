# MCP field findings 35: R turns a moving part without rebuilding the scene

Planning baseline: `6d468d8`. Written October 14, 2026. The item is the
user's, from moving parts on Billo's board in the app, and is numbered 122
for billo's `docs/horizontal-mcp-notes.md`.

## Findings and changes

122. **R while moving a part on the board felt like a reload.**
     - **The symptom:** "Move is really smooth, but rotation feels like it is
       reloading or rebuilding metal or something." The same went for T, and
       for R while placing a package from the unplaced list.
     - **How a move is drawn:** the scene is built once for the board from
       before the move. Each step then sends translation patches: the
       renderer shifts the resident primitives of what moves, in place, by
       what changed since the patch it last applied (`applyBufferPatches`).
       Nothing is built or uploaded whole.
     - **The cause:** 105's move branch in `transformSelection`
       (`BoardCanvasView.swift:5903` at the baseline) turned a copy of the
       board, made it the move's `originalBoard` and called
       `invalidateSelectableCache()`.
       - **What that cost:** the call bumps `metalSceneRevision`, which is in
         the element-bucket key (`:8396`). So the next body pass built the
         whole board's scene again (`buildBoardMetalElementBuckets`),
         concatenated it, and the renderer uploaded every layer group.
       - **And more:** the hit-testing selectables were rebuilt too, and so
         were the resident move plan and the live airwires. The airwires are
         a background request, so until it landed the board's own showed,
         from before the move.
       - **Placing a package:** `transformPlacingPackage` (`:3702`) did the
         same on purpose ("one rebuild per key press").
     - **Now, the patches carry a turn:** translation patches have an
       `angle`.
       - **What it means:** the run is turned about the world origin, then
         shifted by `delta`, as `HorizontalPlacementTransform` places a point.
       - **How the renderer applies it:** it keeps, per run, the placement it
         last applied, and applies only the difference
         (`HorizontalMetalPlacementStep`). Quarter turns are exact, and with
         no turn the arithmetic is the old shift's.
     - **The move keeps its scene:** a quarter turn of a move patched in Metal
       goes into `MoveState.turn` (`BoardMoveTurn`).
       - **What it holds:** the turned model board, made as 105 made it; the
         placement from `originalBoard`'s copy of what moves to that board;
         and how many turns there have been, for the caches keyed on the
         move's points.
       - **What stays:** `originalBoard`, and with it the resident scene, the
         selectables, the resident move plan and the airwire request.
       - **What every move patch now uses:** `MoveState.livePlacement`, the
         turns so far and then the shift since the last. That covers span
         translations, track ends that follow a pad, regenerated arcs, the
         selection overlay, and the live airwires
         (`MovingAirwires.airwires(placement:)`).
       - **The pivot** is 105's: the cursor, or without one the selection's
         centre where it is now.
     - **Texts are drawn again:** turning a text's strokes with the part is
       not always what a rebuilt scene draws.
       - **Why:** the outline renderer draws a text between a quarter and
         three-quarter turn the other way round, so it stays readable. A
         part's name at 0° turned clockwise lands at 270° and is drawn
         reading up, where its turned strokes read down. Pad labels settle
         on their own readable angle too, a square pad's on the shallowest.
       - **What the scene build records:** each text's strokes
         (`BoardMetalTextRun`), which the concat step turns into spans per
         owner (`BoardMetalSceneMetadata.textSpansByRef`).
       - **What a turn redraws:** the texts of what moves, from the turned
         model. That is package texts, a selected board text, pad labels
         (`packagePadLabelTextsByLayer` over the moving packages' pads), via
         labels, and the name of a package with no geometry.
       - **How:** as `lineRedrawPatches`, which the renderer writes after
         every translation. They are made once per turn and scene, then
         shifted with the move.
     - **The commit** carries on from the turn's board, so the geometry it
       lands and its one undo step back to the board from before the move are
       105's.
       - **It rebuilds the scene,** as every package move's commit already
         did: a preserved scene keeps a moved package where it was.
       - **For other selections** a turned commit rebuilds too, since the
         preserved scene is the one from before the turn.
     - **Esc** drops the turn with the move.
     - **Placing a package:** R turns it in place the same way.
     - **Still rebuilt, by 105's path:**
       - **E (mirror):** it takes a package to the other side, onto other
         layers, so its primitives belong to other composite groups and
         colours.
       - **A turn that isn't a quarter turn:** Rotate Arbitrary.
       - **Move Exactly** during a move.
       - **A move that can't be patched in Metal.**
       - **Some selections:** tracks, net ties, junctions, polygons,
         keepouts, planes, dimensions, decals or connection lines. The model
         turns a track's connections its own way, and the rest don't turn at
         all.
       - **More than 20,000 text strokes to redraw**
         (`maximumTurnedTextStrokes`), as when a whole board is turned. The
         redraws are written on every step after the turn, so past that the
         one rebuild costs less. No test covers the limit itself.
     - **Turned whole, not redrawn:**
       - **Clipped silkscreen:** with clip-silkscreen-to-mask on, a clipped
         text is drawn as fragments, not strokes.
       - **Track labels** on a track that turns whole with a part. A track
         that ends on a pad has no label, so this is rare.
     - **The iPad** shares all of it: `BoardCanvasView`, its command handlers
       and the renderer are the same on both.

## Tests

- **`BoardMoveRotateTests`** (macOS, Metal):
  - **The new test** mounts a package with a silkscreen outline and its name
    above it. It finds the board scene's renderer, and moves the part up, R,
    up, Enter with the canvas's own key monitor.
  - **What it checks:**
    - the resident outline turns upright and moves on;
    - the renderer's new `residentSceneUploads` count doesn't change from
      before R until the commit;
    - the preview draws the name as the committed board has it, at 270°;
    - the scene the commit rebuilds draws what the preview drew.
  - **Without the change:**
    - with the in-place turn disabled, the upload count goes from 3 to 4 at
      R;
    - without the text redraws, the name and the rebuilt scene don't match
      the preview.
  - **105's three tests** pass as they were.
- **`HorizontalMetalMovePatchTests`:**
  - **Turned patches:** a run is placed by quarter turns and shifts in turn,
    and is back on the base once the patches end. This caught the
    difference of two angles going unwrapped, which turned by trigonometry
    and left the run a fraction off.
  - **Redraws:** they land over a translation of the same run on every pass.
- **`HorizontalMovingAirwiresTests`:** a package turned and shifted keeps
  the rats' nest a regeneration of the turned board gives, and each pad's
  airwire leaves from where the turn put it.
- **Results:**
  - **Swift:** 904 tests (6 skipped, 0 failures), the 900 from before plus
    the four new.
  - **App builds:** Xcode builds for macOS (`/tmp/r35-mac-dd`) and the iOS
    Simulator (`/tmp/r35-ios-dd`).
  - **Not felt:** the tests show that R uploads nothing and that the preview
    is what the commit draws; whether the turn now feels like a move step is
    for the app to say.
- **Left for the app:**
  - **On Billo's board,** drag a part and press R a few times, then T. The
    part, its name and its pad labels should turn with no pause, the
    selection box and the airwires with them, and the tracks on its pads
    should follow. Release: the commit rebuilds the scene, as a plain move's
    does, and nothing should jump, the names reading as they did in the
    preview.
  - **The same with the arrow keys,** and while placing a package from the
    unplaced list.
  - **E** still pauses as before: it takes the part to the other side.
  - **One undo** puts the part back where it was before the move, and Esc
    mid-move leaves it untouched.
  - **On iPad,** the same with a hardware keyboard.
