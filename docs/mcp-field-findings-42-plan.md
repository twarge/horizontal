# MCP field findings 42: the parametric filters in a bar under the toolbar

Planning baseline: `0682c7f`. Written October 15, 2026. The item is the
user's, from the Pools pane after round 40, and is numbered 130 for billo's
`docs/horizontal-mcp-notes.md`.

## Findings and changes

130. **The parametric section moves under the toolbar.**
     - **The request:** "Place the parametric part section in a horizontal bar
       below the existing parts toolbar. Place the disclosure triangle to the
       left of the existing parts toolbar."
     - **The user's second thought:** they also asked for the selections to
       apply at once without the Search button, then took it back: "Keep the
       search button!" Horizon's two steps stay as round 40 made them: values
       chosen in the boxes wait until Search, or a double-click, applies them.
     - **Now:**
       - **The triangle:** `parametricDisclosure` is the first control of the
         toolbar row while parts are listed. Closed, it shows a filter mark
         when a table still narrows the list, as the collapsed column did.
       - **The bar:** `HorizontalPoolParametricFilterView` is a bar under the
         toolbar, above the replacement banner and the list.
         - **On its left:** the table picker, Search and Reset, and the applied
           filters' chips.
         - **To their right:** the filter boxes side by side, 150 pt wide, a
           list 112 pt high each. They scroll sideways when the pane is
           narrower than they are.
       - **The list** takes the pane's full width again.
       - **Unchanged:** the filters' model (`HorizontalParametricFilters`),
         the table's columns, Replace's auto-picked table, and the AppStorage
         key.

## Tests

- **`HorizontalPoolBrowserPaneTests.testTheParametricSectionGrowsTheTablesFiltersAndColumns`**
  also checks that the Value box sits above the list in the window. With the
  old side column it fails: the box was at x = 210 beside a list starting at
  x = 431.
- **Snapshot:** a throwaway snapshot of the mounted pane showed the triangle
  before the kind picker, and the bar with Resistors, Search, Reset and the
  Value box above the banner and list.
- **Results:**
  - **Swift:** 934 tests (6 skipped, 0 failures).
  - **App builds:** Xcode builds for macOS (`/tmp/r42-mac-dd`) and the iOS
    Simulator (`/tmp/r42-ios-dd`).
- **Left for the app:** the bar's look at real widths, and with a table that
  has many columns (capacitors), where the boxes scroll sideways.
