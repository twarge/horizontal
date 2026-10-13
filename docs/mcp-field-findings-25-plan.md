# MCP field findings 25: part_value, and pool item windows that wouldn't move

Planning baseline: `f30ddc1`. Written October 12, 2026. Both came from the
user during round 24 and are recorded in billo's `docs/horizontal-mcp-notes.md`
as items 86 and 87.

## Findings and changes

86. **`get_component`'s `part_value` gave the part's MPN when it stored no
    value.**
    - **Before:** `HorizontalDispatchPoolIndex.partValue` returned the part's
      `displayValue`, Horizon's `Part::get_value`, so U8 on Billo read
      `part_value` "STM32H757AII6" as well as `value` and `effective_value`.
      A round 20 test (item 67) pinned it there.
    - **The user:** "Not sure why part_value would give "STM32H757AII6".
      effective_value can indeed give that."
    - **Now:**
      - `partValue` is what the part stores, through its base, and the new
        `partDisplayValue` is `Part::get_value`.
      - `HorizontalDesignComponent` carries both. `get_component` gives the
        stored one as `part_value`.
      - `effective_value` and `value_source` come from the shown one, as
        before: what `Component::get_value` shows when there is a part, the
        component's own value otherwise.
    - **On Billo, expected:** U8 reads `part_value` "", `effective_value` and
      `value` "STM32H757AII6", `value_source` "part".

87. **Pool item editor windows could be resized but not moved.**
    - **The user:** a part opened from the Pools pane gave a window that
      "can't be moved(!) but can be resized". Dragging its title bar does
      nothing. Every pool item editor does it, canvas ones too, while
      project windows move.
    - **Before:**
      - `WindowChromeConfigurator` gave pool item windows a "standard title
        bar" by removing `.fullSizeContentView` from the window SwiftUI had
        laid out for it.
      - It did so again on every SwiftUI update of `ProjectDocumentView`,
        writing the style mask, title visibility and background colour each
        time.
      - Project windows keep `.fullSizeContentView`, and the configurator's
        own comment already said it "stays on either way", because dropping
        it rearranged the toolbar.
    - **Not confirmed:** that removing it is what stops the drag. It is the
      one thing pool item windows do that project windows don't. A test
      can't drag a window, so the user's look is the check.
    - **Now:**
      - Every document window keeps `.fullSizeContentView`.
      - A pool item window's title bar is opaque: never transparent,
        whatever the Transparent Toolbar preference says. The toolbar
        background was already visible (`ProjectDocumentView.body`), and
        nothing in the editors ignores the safe area, so their content stays
        below the title bar.
      - The configurator writes a property only when its value differs, so a
        SwiftUI update no longer makes AppKit rebuild the title bar.

## Tests

- **`HorizontalMCPFieldFindingsTests`** (86): the round 20 assertion is now
  `effective_value` "C1005" (Horizon shows the MPN of a part with no value)
  and `part_value` "" (what the part stores), with `value_source` "part".
- **`HorizontalWindowChromeTests`** (87):
  - `testAPoolItemWindowKeepsFullSizeContentWithAnOpaqueTitleBar` fails on
    the old code;
  - `testACanvasWindowFollowsTheTransparentToolbarPreference`.
- **Moving the window** needs the user to try it in the app.
- **Results:** Swift 875 tests (6 skipped, 0 failures), Python 74 OK. The
  release products were rebuilt, and the app builds in Xcode (Debug, with
  its own DerivedData under `/tmp`).
- **On a copy of Billo,** through the release worker: U8 reads `part_value`
  "", `effective_value` and `value` "STM32H757AII6", `value_source` "part".
  J2 reads the same pattern with 27FLZ-SM2-TB, and C24 `part_value` "4.7 µF".
