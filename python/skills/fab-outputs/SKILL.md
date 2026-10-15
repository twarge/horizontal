---
name: fab-outputs
description: Generate and check fabrication and documentation outputs for a Horizon/Horizontal project — Gerbers, ODB++, drill files, BOM, pick-and-place, schematic PDF, STEP, board drawings. Use when asked to export, release or regenerate outputs, or when exported files are older than the design.
---

# Fabrication outputs

## 1. Gate on the design

1. Connect (the `connect` skill) and open the project live if the user has it open.
2. Run `check` with `full: true`. Do not export over errors or unrouted connections unless the user says to; list what `check` found. It has no geometric design rule check, so ask whether Horizon EDA's DRC has been run when clearances matter.
3. Call `save` and confirm `verified: true`, so the files hold the document and no autosave is pending. A live export that falls back to the server's worker needs exactly that, and is refused with `PERMISSION_DENIED` otherwise.

## 2. Decide names and places before writing

- `export_settings` shows the file names and folders Horizon EDA keeps in the project. Horizontal's `export` names its files after the project file and does not read those settings.
- Look at the existing output folders in the repository: the naming, the folder per kind, and which files are tracked in git. If `export` would write different names or places, say so and ask before replacing anything.
- The target must be outside the project package. Leaving `target_directory` out uses the export folder beside the project.

## 3. Export

Call `export` with the sections asked for: `schematic_pdf`, `bom`, `gerber`, `odb`, `pick_and_place`, `board_step`, `board_drawing`, `board_dxf`.

A live export writes as the sandboxed app, which can only write where it has access. When it cannot, and the project's files match the open document, the export runs in the server's worker instead and the reply says `via: "worker"`.

## 4. Check what was written

- List the files, and compare the copper layers with `board_info`'s stackup.
- Compare BOM lines and quantities with the `bom` tool. Check that do-not-populate parts are handled the way the assembler expects.
- Use `render_board` per layer, or with `mirrored` for the bottom, to eyeball the copper against the exported Gerbers.
- Commit outputs separately from design changes, with the source commit they were generated from in the message.
