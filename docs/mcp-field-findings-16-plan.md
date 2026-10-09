# MCP field findings 16: no-op durability, kept plans, unrouted wording

Planning baseline: `2bc665a`. Written October 9, 2026. Items 50–54 came up
during round 15's live check on Billo on October 8. Round 15 passed; these
are what it showed could be better.

## Findings and changes

50. **A committed no-op said `durability: "unsaved_document"`.**
    - **Before:** the PA0 → `TIM2_CH1` commit gave `unchanged: true`,
      `written: []` and the revision it started from, yet told the caller
      the document had unsaved changes. `open_project` said it had none.
    - **Now:** a commit whose batch leaves every file as it was gives
      `durability: "unchanged"`, live or on disk. The Python `EditResult`
      accepts it, and `python/README.md` and `docs/automation.md` say so.

51. **"1 airwire remain."**
    - **Now:** "1 airwire remains.", "3 airwires remain."

52. **An unnamed unrouted net was only its uuid.**
    - **Before:** two of Billo's 19 unrouted nets read
      `69926eed-…` and `babd2a5a-…`. Finding them took a `get_net` each.
    - **Now:** for a net with no name, the detail lists its pins in natural
      order, up to six, e.g. "3 airwires remain (C39.P, R25.B, U12.VIN,
      U9.Out)." More than six end "… N pins". The same goes for "Not
      reached by the plane". The `net` key stays the uuid, which `get_net`
      takes.

53. **Only the latest dry run could be replayed.**
    - **Before:** the entry kept one staged plan. A commit with the digest
      of an earlier dry run redid the edit (about 1 s on Billo, no
      `reused_dry_run`). A committed no-op also cleared it.
    - **Now:** `stagedPlans` keeps the latest four at the current revision,
      newest last. A commit replays the newest that matches its revision,
      request and `plan_digest`. A dry run of the same request replaces its
      older plan. A commit that changes something clears them all, and one
      that changes nothing keeps them, since the revision hasn't moved.

54. **The warning said "still" when the batch had just set custom_only.**
    - **Now:** it says "now draws the primary names" for a symbol the batch
      set to `custom_only`, and "still draws" for one that already was.

## Tests

- **`testNoOpDurabilityKeptPlansAndUnroutedNetsByPin`** covers:
  - "now draws" from a lone `custom_only`, and "still draws" from choosing
    an alternate under it
  - `durability: "unchanged"` on a no-op commit, and "disk" on a real one
  - the first of two dry runs, with a no-op commit in between, reused
    (`reused_dry_run`, no `load_ms`)
  - "1 airwire remains." on a named net, and "1 airwire remains (R1.B,
    R2.B)." on one whose name was blanked
- **`testABatchNamesWhatItMakesAndUsesTheNames`** now runs four dry runs in
  between, so its commit still redoes the plan, which also covers eviction.
- Swift 861 tests (6 skipped), Python 66, all pass.
- Not covered by a unit test: the live path of 50 and 53. That's for the
  live check.
