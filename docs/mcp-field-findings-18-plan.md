# MCP field findings 18: what to retry, and values a part hides

Planning baseline: `17d189d`. Written October 9, 2026. Items 60–61 came up
during round 17's live check on Billo on October 9. Round 17 passed; these
are what it showed could be better.

## Findings and changes

60. **A same-content `STALE_REVISION` said `retryable: false` but told the
    caller to send it again.**
    - **Before:** after a commit and an undo, Billo's D1 (a `plan_digest`
      commit at `…:0:b2f87e30…`) was refused with "Send it again with
      expected_revision …:2:b2f87e30…; a commit with plan_digest needs a
      fresh dry run at that revision." and `retryable: false`. A client
      that goes by `retryable` would give up on what the message calls
      safe to redo.
    - **Now:** `retryable` keeps its meaning, which is that the request as
      sent may be sent again (a `TIMEOUT`, a lost connection). The request
      as sent would be refused again, so it stays false. `details.retry`
      says what to send instead:
      - `"dry_run_at_actual"` when the request carried a `plan_digest`. The
        message reads "Dry-run it again with expected_revision …, then
        commit with the plan_digest that gives."
      - `"resend_at_actual"` otherwise. The message reads "Send it again
        with expected_revision …."
      A stale revision whose content differs gets no `retry`, since the
      caller has to read again.
    - **Not done:** accepting a plan whose snapshot matches. The reasons in
      item 57 still hold.

61. **A value hidden by the part's own was only a `note`.**
    - **Before:** `set_value` C24 → "10 µF" gave `changes[0].note` "The part
      C1005X5R1A475K050BC defines the value 4.7 µF, which Horizontal shows
      instead." with `warnings` empty, and the dry run would write
      `top_block.json` and add an undo step all the same.
    - **Now:** it is a warning, e.g. "C24 is part C1005X5R1A475K050BC, whose
      own value 4.7 µF is the one shown, so the 10 µF set_value wrote does
      not show. set_part to a part with the value 10 µF (search_pool finds
      one) changes what is shown." The warning is worked out once the
      batch has run, so several things count:
      - the last value a batch sets on a component, one warning per
        component, sorted by refdes
      - the part the component ends the batch with (a later `set_part` to
        a part without a value hides nothing)
      - a value equal to the part's, which hides nothing
      The `note` is gone from the change. The op's description, the
      `apply_ops` and `set_component_value` docstrings, and the automation
      guide say so.
    - **Not suggested:** `set_part` with `part: null`. It keeps the value
      but drops the part, and the component's board package with it.

## Tests

- **`testSameContentStalenessSaysWhatToRetryAndAHiddenValueWarns`**
  covers:
  - a hidden value's warning, with no `note`
  - one warning per component, with the last value named and sorted by
    refdes
  - no warning for the part's own value, or after a later `set_part` to a
    part without one
  - `retry` `dry_run_at_actual` and `resend_at_actual` with their
    messages, with `retryable` false
  - no `retry` on a different snapshot, and a resend at the actual
    revision that commits
- **`testRenameRetireGroupTagAndRemove`** now checks R1's warning
  ("whose own value RC0603FR-0710KL is the one shown") in place of the note,
  and that R2, with no part, has none.
- Swift 863 tests (6 skipped), Python 66, all pass.
