# MCP field findings 41: the Metal patch indicator is gone

Planning baseline: `bff9b76`. Written October 15, 2026. The item is the
user's and is numbered 129 for billo's `docs/horizontal-mcp-notes.md`.

## Findings and changes

129. **The schematic showed a "Metal patch" capsule during patched moves.**
     - **The request:** "you can remove/hide the Metal Patch indicator now."
     - **What it was:** a debug badge in the schematic canvas's top-left corner
       (`schematicMetalPatchIndicator`). It showed while a move was being
       patched in Metal (`canPatchSchematicMoveInMetal` with buffer patches),
       to show that the patch path was in use.
     - **Now:** the badge and its overlay are removed. The board never had
       one.
     - **Kept:** `schematicMovePatchDiagnostic`, which still feeds the
       move-start diagnostics log.

## Tests

- No behaviour depends on the badge, and no test referred to it.
- **Swift:** 913 tests (6 skipped, 0 failures).
- **App builds:** Xcode builds for macOS (`/tmp/r41-mac-dd`) and the iOS
  Simulator (`/tmp/r41-ios-dd`).
- **Left for the app:** move a symbol on the schematic; no badge should show.
