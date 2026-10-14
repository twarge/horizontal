# MCP field findings 34: a right-click over the sidebar is the sidebar's

Planning baseline: `47693f3`. Written October 14, 2026. The item is the
user's, from trying to set a frame on Billo's MCU Power sheet with round
32's Frame menu, and is recorded in billo's `docs/horizontal-mcp-notes.md`.

## Findings and changes

120. **Right-clicking a sheet in the sidebar did nothing.**
     - **The symptom:** the row's context menu holds Rename… and round 32's
       Frame menu. It never opened, so neither could be reached from the
       sidebar.
     - **The cause:** the canvas takes its mouse events through a local
       event monitor, which sees every event in the window before the views
       do.
       - **What the monitor takes:** a right-click inside the canvas's
         bounds becomes the canvas's own context menu. The monitor then
         returns nil, so nothing else gets the click.
       - **Why that reached the sidebar:** the pane split ignores the
         leading safe area, so the leading pane's canvas runs under the
         sidebar. Its bounds cover the sidebar's rows.
       - **What was excluded:** `canvasMouseExclusionInsets` left alone only
         the strip under the toolbar, with a leading inset of 0. The fit
         already keeps the drawing out of the leading inset, like the top
         one.
       - **Why left clicks still worked:** a left click is passed on after
         the canvas looks at it.
       - **What else it cost:**
         - every click on the sidebar also gave the canvas the keyboard
           (`onRequestKeyboardFocus`);
         - a scroll over the sidebar panned the canvas instead.
     - **Now:** the exclusion takes the leading inset as well as the top
       one, the same two edges the fit keeps the drawing out of.
       - **Over the sidebar:** clicks, scrolls and the cursor go to the
         sidebar, whichever pane is leading.
       - **A canvas drag** that started on the canvas still runs on under
         the sidebar, since `isExcludedMouseLocation` excludes nothing while
         a primary drag is in progress.
       - **With the sidebar hidden** the inset is 0, so the whole canvas
         takes the mouse again.

## Tests

- **`CanvasSidebarMouseTests`** (new, macOS, Metal). It mounts a
  `BoardCanvasView` with a 200 pt leading safe-area inset and drives the
  canvas's own event monitor.
  - **Over the sidebar:**
    - a right-click is passed on rather than taken;
    - a left click is passed on too;
    - neither asks for the keyboard.
  - **Over the canvas:** a right-click is taken and asks for the keyboard.
  - **Without the fix:** the test fails, because the right-click over the
    sidebar is taken.
- **Results:**
  - **Swift:** 900 tests (6 skipped, 0 failures), the 899 from before plus
    the new one.
  - **App builds:** Xcode builds for macOS (`/tmp/r34-mac-dd`) and the iOS
    Simulator (`/tmp/r34-ios-dd`).
- **Left for the app:** right-click a sheet under **Blocks ▸ top_block** in
  the sidebar. The menu should open with Rename… and Frame. Also check that
  a trackpad scroll over the sidebar scrolls the list.
