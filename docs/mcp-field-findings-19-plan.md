# MCP field findings 19: airwire order, previews everywhere, and a part's package

Planning baseline: `ef1ec0e`. Written October 9, 2026. Items 62–64 came up
during round 18's live check on Billo on October 9. Round 18 passed; these
are what it showed could be better.

## Findings and changes

62. **"Not reached by the plane" named an airwire's ends in no set order.**
    - **Before:** the same airwire on the same snapshot (`b2f87e30…`) read
      "(C37.B to U10.GAIN)" under the app built at 09:05 and "(U10.GAIN to
      C37.B)" under the one built at 09:29, and likewise U18.EN/U18.IN.
      `airwireEnds` printed each airwire `from` then `to` as the rats' nest
      made it, and took `prefix(3)` of the airwires in the rats' nest's own
      order. Both change from one run of the app to the next, so with more
      than three airwires even *which* three were named could change. Every
      other list in `check` is in natural order (item 52).
    - **Now:** each airwire's two names are put in natural order, then the
      airwires by that pair, before three are taken. Five pads in a row read
      "(R8.A to R9.A; R9.A to R10.A; R10.A to R11.A; … 1 more)", R9 before
      R10. On Billo the three infos will read (C37.B to U10.GAIN),
      (U10.~RESET to U10.VLOGIC) and (U18.EN to U18.IN).

63. **Five edit tools took a `plan_digest` but had no `dry_run`.**
    - **Before:** the `_tool` decorator gives every mutation
      `expected_revision`, `operation_id` and `plan_digest`, but only tools
      that declared `dry_run` got it. `set_component_value`, `rename_net`,
      `connect_pin`, `place_component` and `copy_group_layout` could only
      commit. On Billo, a `set_component_value` call meant as a preview was
      refused by the client's permission check because it would have
      written, and the preview had to be rebuilt as `apply_ops`. Item 61's
      warning reached a `set_component_value` caller only after the write.
    - **Now:** all five take `dry_run` (and so `file_text`), passed through
      to the same `apply` the rest use, and each description says a dry run
      gives the `plan_digest` its commit takes. A test asserts that every
      tool in `_mutations` advertises `plan_digest`, `dry_run` and
      `file_text`, so a new wrapper can't miss it again.

64. **The set_value hint sent the caller to parts in any package.**
    - **Before:** item 61's warning said "set_part to a part with the value
      10 µF (search_pool finds one)". It did find 11 on Billo, but no
      `search_pool` row names a package, and none of the 11 is a C0402 like
      C24. Finding the package of the one in the project pool took three
      `get_pool_item` calls: the part (no `package`, only `base`), its base
      (`package` uuid), and the package (name "C0603").
    - **Now:**
      - The pool scan keeps a part's `package` and `base`.
        `HorizontalDispatchPool.packages` follows a derived part's base
        chain to the part that names a package, through whichever pool holds
        it, and finds its name.
      - `search_pool` part rows carry `package` and `package_id`, and so do
        `list_parts` rows from the base pools.
      - `search_pool` takes `package`, a name in any case or a uuid, which
        keeps only parts in that package. It narrows the search to parts,
        and refuses a `kind` that isn't one.
      - The warning names the component's package and the search that keeps
        it: "C24 is part C1005X5R1A475K050BC, whose own value 4.7 µF is the
        one shown, so the 10 µF set_value wrote does not show. set_part to a
        part with the value 10 µF changes what is shown; search_pool with
        query "10 µF" and package "C0402" lists those in C24's package, and
        a part in another one changes C24's footprint too." A package with
        no name is given by its uuid, which `package` also takes.
        `HorizontalPoolPart` gains `packageID` and `searchPackage` for this.
    - **Not done:** saying in the warning whether any pool has such a part.
      That would scan every pool from inside a dry run, about 4,500 items on
      Billo, to word a hint, when the search it names is one call.
    - **Not done:** a derived part's manufacturer, description and datasheet
      are still read from its own file, where they are inherited and empty.
      Billo's project-pool C1608X5R1C106M080AB row reads manufacturer "",
      while its base C1608 says TDK. A "TDK" search of the project pool
      finds 16 parts, the base among them, but not that one. That's a
      separate finding (Billo's notes item 65).

## Tests

- **`testPlaneAirwireEndsReadInOrderAndAPartsPackageIsFoundThroughItsBase`**
  covers:
  - five pads in a row named in natural order, with the same three airwires
    (it fails on the old `airwireEnds`, reading "R9.A to R8.A")
  - a derived part's `package` and `package_id` taken from its base, and a
    part in another package next to it
  - `package` by name in another case and by uuid, and refused with
    `kind: symbol`
  - the warning's exact text for a component whose part is derived, and the
    uuid for a package with no name
- **`testPlaneAirwireEndsSkippedLoadsSameSnapshotStalenessAndTheChosenPin`**
  now expects "(R1.A to R2.A)" rather than either direction.
- **`test_every_edit_tool_can_preview_what_it_commits`** (Python): every
  mutation tool advertises `plan_digest`, `dry_run` and `file_text`;
  `search_pool` advertises `package`; and `rename_net` dry-runs, leaves the
  net as it was, then commits that `plan_digest` with `reused_dry_run`.
- **`test_a_verbose_dry_run_previews_paths_and_file_text_only_on_request`**
  checked that `rename_net` had no `file_text`, as a tool without a dry
  run. Every edit tool has one now, so it checks `get_net` instead.
- Swift 864 tests (6 skipped), Python 67, all pass.
