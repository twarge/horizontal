# MCP field findings 17: plane airwire ends, skipped loads, same-content staleness

Planning baseline: `f37ff76`. Written October 9, 2026. Items 55–59 came up
during round 16's live check on Billo on October 9. Round 16 passed; these
are what it showed could be better.

## Findings and changes

55. **"Not reached by the plane" didn't say which pads.**
    - **Before:** Billo's GND, P3.3V and P5V infos read "1 airwire on a net
      with a plane: the fill does not reach these pads, or the plane is not
      poured." Nothing in the reply named "these pads".
    - **Now:** the detail names each airwire's ends, up to three, e.g.
      "1 airwire on a net with a plane (R1.A to R2.A): …". An end is the
      pin whose pad sits at it (package pad positions, matched to the net's
      pins), or its position in mm when it is a via or junction. More than
      three end "; … N more". This replaces item 52's pin list on an
      unnamed plane net, since a plane net's pins are usually hundreds.

56. **Each dry run spent about a second loading.**
    - **Finding:** `load_ms` is the load of the *edited* project, not a
      reload of the open one. The dry run needs it to refuse an edit that
      introduces load diagnostics, and the commit installs it. A cached
      base would not have helped.
    - **Now:** the load is skipped where its answer is known. A batch whose
      files come out unchanged uses the open project (`timing.skipped_load`).
      On Billo the PA0 no-op dry run spent 957 ms here. A dry run whose files
      match a kept plan at the same revision reuses that plan's load and
      diagnostics (`timing.reused_load`), e.g. one op written by refdes then
      by uuid. A no-op commit no longer overwrites the cached diagnostics.
    - **Not done:** loading only what changed. The four different Billo dry
      runs would each still load (~1 s). That would need an incremental
      project load (re-parse the changed files, keep the board's parse when
      only the schematic moved), which is a larger change.

57. **A same-content plan was refused with no hint.**
    - **Before:** D2 was made at `…:0:b2f87e30…`. After a commit and an undo
      the document was at `…:2:b2f87e30…`, the same content, and the commit
      gave "Project changed since it was read." with `retryable: false`.
    - **Now:** still refused, since the revision contract stays strict. When
      the instance and snapshot match and only the generation moved, the
      message says the content is as it was (most likely an edit and its
      undo) and to send the request again at the actual revision, with a
      fresh dry run for a `plan_digest`. `details.snapshot_matches` is true.
    - **Not done:** accepting the plan. Its digest includes the revision, and
      the strictness is what lets a caller trust a commit was planned
      against what is open.

58. **The batch's own chosen pin was lost in the list.**
    - **Now:** when a batch sets `custom_only` and chooses alternates under
      it, the warning ends "…, including PA1, which this batch chose."

59. **`connection_status` listed each discovery path twice.**
    - **Before:** `find_live`, then `find_live_for` per project, which ran
      `find_live` again.
    - **Now:** `find_live_for(..., discovery=False)` reads only holder
      records, and each project is tried once.

## Tests

- **`testPlaneAirwireEndsSkippedLoadsSameSnapshotStalenessAndTheChosenPin`**
  covers:
  - an unpoured GND plane away from R1.A and R2.A, whose info names
    "R1.A to R2.A"
  - "including PA1, which this batch chose"
  - `skipped_load` and no `load_ms` on a no-op dry run
  - `reused_load` and no `load_ms` on `set_value` by uuid after the same op
    by refdes, then the commit reusing that dry run
  - a plan at content the project came back to (22k then 10k), refused with
    `snapshot_matches` and the actual revision in the message
- **`test_diagnostics_without_secret_values`** now checks that every
  discovery path appears once.
- Swift 862 tests (6 skipped), Python 66, all pass.
- Not covered by a unit test: the live path of 56 (a live no-op dry run).
  That's for the live check.
