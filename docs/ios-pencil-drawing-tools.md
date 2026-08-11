# Drawing tools on iOS with Apple Pencil

Reference plan. **Partly implemented** — status is marked per item. The goal is
that every canvas drawing tool is usable on iPad with an Apple Pencil and no
hardware keyboard.

## Context

What already worked before this plan: the rail tool buttons dispatch every tool;
Pencil **hover** drives the live preview (`UIHoverGestureRecognizer` → `onHover`
→ `onCursorWorldPointChange`), Pencil **tap** places a vertex (`onPrimaryClick`),
and **double-tap** commits graphics. Board draw tools were largely functional
because `HorizontalIPadProjectView.boardRouteControlBar` provides
Finish/Cancel/Back/Via/Flip during a board interaction.

Three gaps blocked "all tools with Pencil", plus two found later.

---

## 1. Shared on-canvas tool control bar — ✅ DONE

The keystone gap: the schematic had no on-canvas commit/cancel. `DrawNetLine`,
schematic `DrawGraphics` and `PlacePart` placed vertices but could only be
committed (Return) or cancelled (Esc) from a hardware keyboard.

`boardRouteControlBar` was extracted to a shared `toolControlBar(for:)` driven by
`HorizontalCanvasCommandActions` (`canCancelInteraction` / `canCommitInteraction`
/ `canToggleVia` / `canFlipTrackPosture` / `dispatch(...)`), and overlaid on the
schematic as well.

File: `Sources/HorizontalNative/Views/HorizontalIPadProjectView.swift`.

## 2. Cross-platform prompt sheets — ✅ DONE

The three prompts in `Sources/HorizontalNative/Utilities/` (`…TextPrompt`,
`…TrackWidthPrompt`, `…PlaneNetPrompt`) were macOS-only **synchronous**
`NSAlert`s called inline. SwiftUI has no synchronous modal, so iOS needed an
async, state-driven sheet.

One shared foundation now serves text / number / option-picker, reusing
`HorizontalSelectionPropertyOption`. The sync→async seam at each call site is
`continueWith(_:)`: macOS keeps `NSAlert.run()` → `continueWith(v)`; iOS presents
the sheet and calls `continueWith` from its completion. macOS behaviour is
unchanged.

## 3. AddText un-gated on both canvases — ✅ DONE

`addText()` was `#if os(macOS)` on **both** board and schematic, so the iPad rail
button no-opped. The macOS body was extracted to `placeText(_:)` (build text →
`registerUndoSnapshot` → set sheet → `onSheetChange` → `beginMove(tracksCursor:)`)
and is now called from the macOS alert and the iOS sheet alike.

## 4. Track width and plane net on iOS — ✅ DONE

`enterTrackWidth()` uses the `.number` prompt, with a **Width** button on the
track control bar gated on `canEnterTrackWidth`. `commitDrawPlane()` /
`definePlaneForSelection` present the `.optionPicker` seeded from
`sortedPlaneNetOptions()`, defaulting to the highlighted/first net so Cancel
still yields a valid plane.

## 5. Pencil behaves as the cursor — ✅ DONE

Found later, and the reason drawing still felt wrong on device:

- **A Pencil drag panned the board.** The pan recognizer took one touch and
  accepted Pencil touches. It is now restricted to non-Pencil touch types, so
  finger/trackpad pan while the Pencil points.
- **Nothing tracked the tip while down.** UIKit *ends* hover the instant the tip
  contacts the glass, and hardware without Pencil hover never reports it at all.
  The view now reads Pencil touches directly and feeds the same cursor.

Handled as raw touches on the view rather than a gesture recognizer, deliberately:
a recognizer joins the failure graph and can starve the tap that commits or the
long-press context menu. Also fixed an ordering bug where hover-ended fired at
the moment of a tap and dropped the preview (`isPencilDown` suppresses it).

The same commit fixed the **pinch re-grab jump** (ported from DeXeF): a second
finger silently re-bases the pan recognizer's translation onto the two-finger
centroid, and `handlePan` applied that leap as a delta. The flag is set in
`touchesBegan` — before any recognizer callback — and outlives the second finger,
because dropping back to one finger re-bases the translation again.

---

## Remaining

### Device testing — NOT DONE
Everything above is **build-verified only**. On iPad + Pencil, confirm:
- DrawNetLine → Finish/Cancel via the schematic bar
- Add Text on board and schematic
- DrawTrack → set Width; DrawPlane → pick a net
- Routing: hover shows the preview, tap places, double-tap finishes
- Pencil drag no longer pans (finger still does) — the one change to existing habits
- Long-press context menu still opens with the Pencil (disabled during routing by design)
- Pinch, lift one finger, replace it — the board should not jump

### iOS text-placement popover — NOT DONE
macOS has the inline popover editor (hover placeholder → click → popover anchored
at the text, live update). iOS still uses the prompt sheet. Porting the popover
would need the anchor maths against `canvasDisplayTransform`, which on iOS is not
maintained during live pan/zoom.

### Autorouter on iOS — BLOCKED, and now moot
Previously "feasible and small": the `canImport` gate was false only because
`Package.swift` omitted `.iOS`. **The vendored KiCad PNS router has since been
removed** (GPLv3, incompatible with App Store distribution).
The inert `#if canImport(HorizontalPushShoveRouter)` seams remain, and
`HorizontalRouterWorld` (our own clearance-matrix extractor) is still the seam a
future router would use.

---

## Out of scope (recorded so the analysis isn't redone)

- **Rules component/part/keepout pickers.**
- **Stubbed transforms** — Scale, Align/Distribute, Lock, Measure, Disconnect,
  decal rotate/mirror. Caveats found:
  - **Lock** is feasible; the `locked` field already serializes (hardcoded
    `false`), and `fixed`-package is the template.
  - **Disconnect** is *not* a stored-net-null: net is derived by
    `HorizontalBoardConnectivity.recompute` and would be overwritten. It needs a
    geometry detach or a new field — and adding a field is forbidden by the
    standing rule that the on-disk format never changes relative to Horizon EDA.
    Needs a product decision.
  - **Decal rotate/mirror** needs an applicator round-trip check for orientation.

## On-disk format

No format change anywhere in this plan. AddText, track and plane all persist
through `HorizontalProjectJSONApplicator`, identically to the macOS tools — only
the input and presentation are new.

## Verification

`make build` (macOS), `make ios`, `make test`. Runtime/device testing is the
user's, and is the outstanding item above.
