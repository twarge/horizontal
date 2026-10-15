# MCP field findings 40: Place and Replace, parametric search and a list's own keys in the Pools pane

Planning baseline: `bff9b76`. Written October 15, 2026. The three items are
the user's requests for the Pools pane, and are numbered 126 to 128 for
billo's `docs/horizontal-mcp-notes.md`.

## Findings and changes

126. **Rescan in the pool picker, a Place button, and Replace for selected
     components.**
     - **The request:** "Move 'Rescan the browsed pools' to the pool picker.
       Add a new Place button. If components are selected, change the view to
       show only parts that are compatible with the selected components and
       change the Place button to Replace."
     - **What there was:**
       - **Refresh** sat in the toolbar (`HorizontalPoolBrowserView.swift:504`
         at the baseline, help "Rescan the browsed pools").
       - **Place** showed only when the window passed `onPlacePart`, which
         `ProjectDocumentView` (`:1856`) and the iPad view did only while the
         project had a schematic. It looked like every other toolbar button.
       - **The workspace's selection** (`selectedComponentIDs`, kept by
         `selectComponents` for the schematic, the board and the 3D view)
         never reached the pane.
     - **Rescan:** it is now **Pools ▸ Rescan Pools**, beside Add Pool…, in
       the pool menu whose label is the pool in view. The toolbar button is
       gone from both the full and the compact row.
     - **Place:** a project window's pane always has it now, as the toolbar's
       last control, in the prominent style (`partButton`).
       - **When it can't act** it is disabled, and its help says why: no part
         selected, not a part, read-only operation, or a project with no
         schematic (`placeUnavailableReason`).
       - **Unchanged:** double-click and Return in the list, and the context
         menu's Place in Schematic.
       - **The standalone pool window** has no Place, as before.
       - **The window's side** is one value, `HorizontalPoolPartActions`:
         place, the reason it can't, the selection, and replace. It replaces
         `onPlacePart`.
     - **"Compatible" is Horizon's rule:** a part fits when it is for the
       entity the selected components share.
       - **Why the entity:** it gives a component its gates and pins, so
         keeping it keeps every connection.
       - **Horizon does the same:** Assign Part (`ToolAssignPart`) refuses a
         part for another entity ("wrong entity"). Its part browser shows only
         that entity's parts while assigning ("Only showing parts for Entity
         …", `PartBrowserWindow::set_entity`).
       - **Components on more than one entity** have no part in common
         (`ImpSchematic::entity_from_selection`). The pane then lists none and
         its banner says why.
       - **Base parts** are left out, as Horizon's part browser leaves them
         out.
       - **The model:** `HorizontalPartReplacement` (new, `Model/Pool`).
     - **Where the selection comes from:** the workspace reads it from the
       archive whenever the selection, the schematic or the panes change, but
       only while the Pools pane is open (`refreshLibraryPartReplacement`).
       - **What it reads:** each selected component's refdes, entity and
         part, from its block file.
       - **Which block:** the one the schematic shows when the selection is a
         sub-block's, else the top block.
     - **The view while components are selected:**
       - **The kind:** the pane switches to Parts.
       - **The list:** only the parts that fit. The search still narrows it,
         and so does Pools ▸ View (`HorizontalPoolBrowserView.listed`).
       - **The selection:** the components' own part is selected when they
         share one, as Horizon's part chooser opens on the component's part.
       - **The banner:** "Only showing parts for entity “Resistor”, to
         replace R12, R13." Its × goes back to every part and Place, as
         Horizon's info bar does, until the selection changes.
       - **The button** reads Replace. It is disabled, with the reason in its
         help, for a part that doesn't fit, a base part, or a part every
         target already has.
       - **Double-click and Return** replace too (Horizon's
         `handle_activate_part`). The context menu offers Replace R12, R13 as
         well as Place in Schematic.
     - **How Replace applies:** the same path as the canvas tools' block
       edits.
       - **Caching:** the part is cached into the project pool, as Place
         caches it (`cacheLibraryPart`, factored out of
         `placePartFromLibrary`).
       - **The edit:** `HorizontalCanvasProjectEdit` runs a `set_part` for
         every target not already on the part. It now takes the `block`
         `apply_ops` takes.
       - **One undo step:** `applyLiveArchive` installs the archive and
         registers Undo as "Replace Part" or "Replace Parts", on the iPad
         through `applyArchiveEdit`.
       - **Connections:** the entity stays, so `set_part` clears none.
     - **The board and the schematic** reload from the new archive, with the
       part's MPN, value and package.
     - **A package change follows `set_part`.** `set_part` leaves the board
       alone, and the board loader takes a component's package from its part,
       as Horizon does (`BoardPackage::update_package`). A placed component in
       another package shows the new footprint where it was.
     - **Refused with copper on its pads:** the new package's pads are other
       pads, and Horizon drops a track whose pad is gone when it loads the
       board (`Board::Board`). So a package change for a component with a
       track ending on one of its pads is refused before anything is written,
       with a message: "“RC0805-22K” comes in R0805, not R0603, and R12 has
       tracks on its pads, which the new footprint doesn't have. Nothing was
       changed: remove those tracks first, or choose a part in R0603."

127. **A parametric section behind a disclosure triangle.**
     - **The request:** "Add a parametric filter section that's hidden behind
       a disclosure triangle on the left. When resistor, capacitor or inductor
       are selected, grow the same parametric filtering as found in Horizon
       EDA."
     - **What Horizon does** (`pool_browser_parametric.cpp`,
       `pool_parametric.cpp`, `pool-update_parametric.cpp`):
       - **One search per table:** each table in the pools' `tables.json` has
         its own tab, listing the parts whose `parametric.table` names it.
       - **Leaving parts out:** the pool update skips a part whose quantity
         isn't wholly a number, or whose enum value the column doesn't list.
       - **Filter boxes:** a box for manufacturer, one for package, and one
         per column. Each lists the distinct values among the parts found,
         and shows only with more than one value.
         - **Order:** no value first, then quantities by number and text in
           natural order.
         - **Format:** `Column::format`, with "N/A" for no value.
         - **Choosing:** several values at once.
       - **Applying:** Search, or a double-click on a value, applies the
         chosen values. Each box's values replace that column's filter, and
         every box is cleared.
       - **Applied filters** show as "Value (2)" with the values in a tooltip
         and an × to take each off. Reset takes them all off.
       - **The result list:** MPN, Manufacturer and Package, then a column per
         value. A quantity shows its number in tabular digits, then its
         prefix and unit.
       - **Sorting** is the database's: a quantity column is a `DOUBLE`, so
         it sorts by number with a part without one after every number. Text
         sorts with natural collation.
     - **Now:** a section on the left of the parts list
       (`HorizontalPoolParametricFilterView`).
       - **The triangle:** collapsed by default, remembered across launches
         (`poolBrowser.showsParametricFilters`). It shows only for Parts.
       - **The table chooser** stands in for Horizon's tabs: All Parts, or one
         of the browsed pools' tables. The tables are read with the project
         pool's (or the pool's own) winning, as `PoolParametric` reads them.
       - **A chosen table** narrows the list to its parts. It grows Horizon's
         filter boxes, the applied-filter chips, Search and Reset, and gives
         the list its MPN, Manufacturer, Package, value and Pool columns,
         each sorting as Horizon's do.
       - **Collapsed with a table chosen,** the list keeps showing that table,
         and the strip shows a filter mark.
     - **Combining:** the table's parts are found among what the search,
       Pools ▸ View and 126's compatibility filter leave. Its filters narrow
       those, and the values left are taken from what is shown.
     - **The model:** `HorizontalPoolParametricSearch`,
       `HorizontalParametricFilters` and `HorizontalParametricRowComparator`
       (new, `Model/Pool`). They use round 32's `Column::format` port in
       `HorizontalPoolParametricTables.swift` and the parametric values the
       scan already keeps on each part (`HorizontalPoolLibraryItem.parametric`).
       Horizon's `parametric.db` isn't read: the rows are worked out from the
       same part files its pool update fills it from, by the same rules.
     - **In Replace:** with the section open, the pane picks the table the
       components' current part is in, when they share one.

128. **The parts list couldn't be walked with the arrow keys.**
     - **The request:** "The table in parts/pool view should be able to take
       focus and allow the user to arrow key up and down through the table of
       parts."
     - **The cause:** the canvas's window-wide key monitor
       (`TrackpadCanvasMonitor.MonitorView.handle`,
       `InteractiveCanvasView.swift:3575` at the baseline) sees every key in
       the window before the first responder does.
       - **When it takes them:** whenever its pane has the keyboard focus
         (`hasKeyboardFocus`, the workspace's `activeCanvasCommandPane`). A
         click on the Pools pane's table doesn't change that.
       - **What it let through:** only text input (`isTextInputActive`).
       - **What that did:** with the table focused, Down went to
         `handleKeyDown` and on to `onMoveSelectionByGrid` (`:3765`), which
         nudged the canvas's selection, and the table never saw the key.
         Letters ran canvas commands, so R rotated the canvas's selection and
         Delete deleted it. The same held for the navigator's outline.
       - **Checked:** SwiftUI's `Table` and `List` are an `NSTableView`
         (`SwiftUIOutlineTableView`), and a click on a row lands on the table,
         whose cells don't take the keyboard, `.textSelection` or not.
     - **Now:** a list with the keyboard takes its own keys, as a text field
       does. A list here is an `NSTableView` (outlines included), an
       `NSCollectionView` or an `NSBrowser` (`NSResponder.isKeyboardList`).
       - **The canvas's monitor** passes every key on while one is first
         responder. An interaction in progress still takes its own
         (`handlesInteractionKeys`).
       - **A click on the canvas** takes the keyboard back from a list, as it
         does from a field (`takeFocusFromOtherControl`).
       - **An interaction started from a list,** such as Place's double-click,
         takes the keyboard as one started from a field does.
       - **The workspace's monitor** reports a focused list as it reports a
         field. The canvas's keyboard-focus badge stands down
         (`isKeyboardInControl`, which was `isEditingText`), and L and Q leave
         the list its type-select.
       - **What changes elsewhere:** after a click on a sheet in the
         navigator, its outline has the keyboard, so R, M, the arrows and
         Delete wait for a click on the canvas. Before, they went to the
         canvas from the outline.
       - **In the pane:** both lists can take the focus (`@FocusState`), and
         Down in the search field moves into the list, selecting its first
         row when none is. The preview follows the list's selection, as it
         follows a click.
       - **Speed:** the rows the list starts from are now kept between scans
         (`visibleRows`) rather than worked out on every pass of the body, so
         each step of the arrows doesn't redo them.

## Tests

- **`HorizontalPoolPartReplacementTests`** (new, 126):
  - **The rule:** the parts of the shared entity fit, others and base parts
    don't, and the targets are in refdes order. Replace's operations skip a
    component already on the part. Mixed entities fit nothing and say why.
  - **The list:** only the parts that fit, still narrowed by the search;
    other kinds unchanged.
  - **The package rule:** a track on a pad blocks a package change; the same
    package, or no copper, doesn't.
  - **Replace through the editor,** on a project the dispatch session builds:
    - **The project:** two resistors on one entity, placed, connected and
      with a track on R1's pad; the parts in R0603 and R0805.
    - **Checked:** the selection read from the archive, the pane's list of
      the three parts, and the refusal of R0805 for routed R1.
    - **Then:** one edit gives both components the other R0603 part, keeping
      their entity and connections. The reloaded board shows the new MPN with
      R1's pads where they were.
    - **And:** unrouted R2 takes the R0805 part, and the board draws R2 with
      R0805's pads at its placement.
- **`HorizontalPoolParametricSearchTests`** (new, 127): a table's rows, with
  4.7e3 and 4700 one value, an unconvertible quantity or a value outside the
  enum leaving the part out, and "" for a missing value.
  - **The filter boxes:** columns in Horizon's order, values sorted and
    formatted ("4.70 kΩ", "N/A").
  - **Applying:** as Horizon's boxes do, with replace, remove and reset.
  - **Combining** with the search and Replace.
  - **Sorting:** by number with no value last, and in natural order.
  - **Stored quantities:** a stored quantity must be wholly a number.
- **`HorizontalPoolBrowserPaneTests`** (new, macOS, five tests): the pane
  mounted on a small pool beside a canvas monitor holding the keyboard focus.
  - **126:** with R1 selected the list has the three resistors, not the
    capacitor, and R1's part is selected. What Place and Replace say when
    they can't act.
  - **127:** opened, the section picks R1's table. The list's columns are
    MPN, Manufacturer, Package, Value and Pool, with one filter box (Value,
    three values).
  - **128:**
    - **The arrows:** they walk the list while the canvas holds the focus,
      the canvas's monitor passing them on.
    - **The search:** Down in it moves the keyboard into the list on its
      first row.
- **`HorizontalKeyboardFocusTests`** (128, three new and one extended):
  - **An `NSTableView` with the keyboard** takes Down, R and Delete from a
    focused canvas, while an interaction still takes Escape.
  - **A SwiftUI `Table`:** the same.
  - **Clicks:** one on the canvas takes the keyboard back from a list, and an
    interaction takes it.
  - **The workspace** reports a list's focus.
- **Without the fixes:**
  - **128:** with the list checks taken out of the canvas's and the
    workspace's monitors, all four keyboard tests fail. The canvas took Down,
    rotated on R, deleted on Delete, kept the keyboard on a click and an
    interaction, and the badge stayed on.
    - **The pane's arrow test** fails with only the canvas's check out.
    - **The search test** fails without the field's Down handler: the field
      editor keeps the keyboard.
  - **126:** with the compatibility filter taken out of `listed`, the list
    test and the pane's selection test fail (four rows, not three).
  - **127:** new behaviour throughout; there was nothing to take out.
- **Results:**
  - **Swift:** 932 tests (6 skipped, 0 failures), the 913 from before plus
    the 19 new ones. The first commit alone builds and passes its keyboard
    tests.
  - **App builds:** Xcode builds for macOS (`/tmp/r40-mac-dd`) and the iOS
    Simulator (`/tmp/r40-ios-dd`) succeed.
- **Left for the app:**
  - **126, the pool menu:** Pools ▸ Rescan Pools rescans, and the toolbar
    has no Refresh.
  - **126, Place:** Place sits at the end of the toolbar, prominent, in a
    project window. Its help says why when it's disabled.
  - **126, Replace:**
    - **Selecting:** select R12 and R13 on the board or the schematic. The
      pane switches to Parts and lists only resistors, R12's part selected,
      under the banner, and the button reads Replace.
    - **Replacing:** pick another part and Replace. Both take it, keep their
      nets, and the schematic, board and inspector show the new MPN and
      value. One Undo puts them back.
    - **Packages:** a part in another package for a routed resistor is
      refused with the message; an unrouted one shows the new footprint.
    - **Mixed:** a resistor with a capacitor shows the problem in the banner.
    - **The banner's ×** goes back to Place until the selection changes.
  - **127:** open the triangle and choose Resistors.
    - **The layout:** the section is 230 points wide; check that a narrow
      Pools pane still leaves the list room.
    - **The list** shows MPN, Manufacturer, Package, Value, Tolerance and
      Power rating, each sorting.
    - **The filter boxes:** choose values in several, then Search. The
      chips appear, the list narrows, the boxes narrow to what's left, a
      chip's × takes its filter off, and Reset takes them all off.
    - **Double-click** on a value applies it.
    - **Relaunch:** the triangle remembers its state.
  - **128:**
    - **The list:** click a row in the Pools pane's list and use Up and
      Down. The selection and the preview follow, and the canvas's
      keyboard-focus badge goes off.
    - **The canvas:** click it, and R, M and the arrows work there again.
    - **Elsewhere:** the same in the navigator's outline and the Parts pane.
    - **Tab** from the search into the list: unverified.
    - **Return with the Parts pane open too:** the Parts pane's Place has a
      window-wide Return shortcut (`HorizontalPartBrowserView.swift:192`),
      and a key equivalent is tried before the focused list's own Return. So
      Return in the Pools list may place the Parts pane's part instead. Before,
      the canvas's monitor took Return first. If it does, the Parts pane wants
      a `primaryAction` on its table rather than the shortcut.
    - **The navigator at launch:** if a window opens with the navigator
      holding the keyboard, the canvas's keys wait for a click on it. The
      badge shows which has them.
  - **iPad:**
    - **Place, Replace and the parametric section** are the same view, and
      Replace lands through the iPad's own undoable `applyArchiveEdit`.
    - **Arrow keys** with a hardware keyboard: not looked at. The iPad's
      canvas takes keys only as first responder.
