# MCP field findings 8: a text that follows its drag, a text move MCP shows

Planning baseline: `8bb215d`. Written October 4, 2026, from two notes taken
while putting "Amplifier" back on Billo after the live check of
[round seven](mcp-field-findings-7-plan.md).

## Findings and changes

27. **A sheet text didn't follow its drag in the app.**
    - **Before:** dragging a text on a sheet moved only its selection box.
      The text stayed where it was until the move committed, then jumped
      to the right place. The commit itself was right. This happened to
      every text Horizon wrote, since Horizon gives each one
      `"layer": 0`. The user found it while moving "Amplifier".
    - **Cause:** a text's ref didn't match between selection and drawing.
      - `HorizontalCanvasModeSupport.textSelectables` gives a text's ref
        the text's layer.
      - The schematic's Metal scene files the text's strokes under a ref
        with no layer.
      - `HorizontalSelectableRef` hashes `layer`, so the move patch's
        lookup of the selected ref in `lineSpansByRef` found nothing. The
        selection box comes from the selectables, under the same ref as
        the selection, so it moved.
      - `schematicMetalPatchOwnerRef` cuts a ref down to its id and type
        for wires and drawn lines and arcs, but not for texts. A text with
        no layer matched and moved: the five MCP placed on Billo (notes
        item 26) and any new text drawn in the app.
    - **Now:** a schematic text's selectable ref carries no layer
      (`SchematicCanvasView.textSelectables`). The selection, the Metal
      scene, its move patch and the editor's own selections all name a
      text by id alone. A sheet has no layers, and nothing in the
      schematic reads a text ref's layer.
      - **The board:** unchanged. It keeps the layer on both sides, so
        its refs already matched.
      - **Also:** editing an existing text selects it by a ref without a
        layer (`SchematicCanvasView.beginEditingExistingText`). For a text
        that stores a layer, that matched none of the selectables, and now
        it does. This wasn't tested on its own.
28. **Moving a text through MCP wasn't discoverable.**
    - **Before:** after round seven's live check, the agent said MCP had
      no op to move an existing text, and asked for one. `place_text`
      already did it. Given an existing text's `id` and a new `x_mm` and
      `y_mm`, it moved the text in place, keeping its uuid and every other
      field. But nothing an agent sees said so:
      - **`apply_ops`:** its description lists `place_text` and
        `place_board_text` under "an op that makes something".
      - **The schemas:** `PlaceText` and `PlaceBoardText` carry no
        description.
      - **`list_ops`:** the only place that said these ops edit, and an
        agent calls it separately.
      - **A trap:** for a text that was there, `x_mm` without `y_mm`, or
        the reverse, was dropped without an error.
    - **Now:**
      - **The descriptions:** `apply_ops` says `place_text` and
        `place_board_text` change a text that is there. The text is named
        by the id `list_texts` or `list_board_texts` gives, and only what
        is passed changes. `x_mm`, `y_mm` or both move it, and it keeps its
        uuid, layer and the rest.
        - **Schemas:** `PlaceText` and `PlaceBoardText` say the same.
        - **The list tools:** `list_texts` and `list_board_texts` say
          `place_text` and `place_board_text` take their ids to move or
          change a text.
        - **`list_ops`:** the Swift op summaries and the `x_mm`/`y_mm`
          parameter docs say it too.
      - **One coordinate:** for a text that is there, `x_mm` or `y_mm`
        alone moves it along that axis and keeps the other. A new text
        still needs both, with the same error as before.
      - **The reply:** both ops give `x_mm` and `y_mm`, where the text is
        after the op.
    - **The schema digest:** unchanged. It covers op and parameter names,
      and neither changed.
    - **Left as is:** `place_symbol`, `place_block_symbol` and
      `place_component` also drop a lone `x_mm` or `y_mm` for something
      already placed. They weren't part of this note.

## Verification

- **Swift:** 821 tests, 0 failures, 6 skipped. Three new tests, each
  failing against `8bb215d`'s sources:
  - **A text in the move preview (item 27):**
    `SchematicKeyboardMoveTests` puts two texts on a sheet, one stored
    with `layer: 0` and one with none. It selects all and presses the up
    arrow. In the Metal preview, before the commit, every stroke of both
    texts has moved 1.25 mm. Against `8bb215d` the preview never showed
    both moved.
  - **An existing text moves on either axis (item 28):**
    `HorizontalMCPFieldFindingsTests` moves a sheet text with `x_mm`
    alone. The stored text differs from before only in its shift. It
    keeps its uuid, text, size and `"layer": 0`. A board text moves with
    `y_mm` alone. Both replies give the new position, and a new text with
    one coordinate is refused.
  - **The op summaries (item 28):** `place_text` and `place_board_text`
    say that `x_mm`, `y_mm` or both move a text, and their `x_mm` doc says
    either alone does. With these two tests, `8bb215d`'s dispatch
    sources failed 8 assertions.
- **Python:** 65 tests, all passing, against this branch's debug CLI. The
  new test reads what an MCP client sees: `apply_ops`' description, the
  `PlaceText` and `PlaceBoardText` schema descriptions, and the two list
  tools' descriptions. It then moves a text with `x_mm` alone.
- **Live:** waits for a rebuilt app and a new session.

## Open

- **MCP's `place_text` omits `layer` on a sheet text** (notes item 26).
  Horizon writes `"layer": 0`, and five of Billo's notes lack it. Horizon
  reads a missing layer as 0, so nothing is lost, but its next save adds
  the key.
