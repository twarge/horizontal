# MCP field findings 47: where pool_write puts a new part

Planning baseline: `cefff8a`. Written October 21, 2026. This is item 151 in
`horizontal-mcp-notes.md`, from the Jude session on October 21 that drew the
Rotating Field sheet: a DAC80504 (U34), three coil drivers and J6.

## Findings and changes

151. **A part made through the MCP went into the project pool's cache.**
     The session wrote the DAC80504's unit, entity, symbol, package and
     part, and ten passives, with `pool_write`. Every file went to
     `<kind>/cache/<uuid>.json` (a package to
     `packages/cache/<uuid>/package.json`). The cache is where Horizon keeps
     copies of a base pool's items, and nothing recorded a pool these came
     from, so all eleven parts read as cached copies whose source was
     missing:
     - `list_part_updates` gave `sourceUnavailable`, "No browsed pool holds
       this part. Choose its source library to continue."
     - The Parts pane said "Not in an attached pool".

     A part no pool has belongs to the project, the way a part made in the
     app's project pool does.
     - **Now:** `pool_write`, and `apply`'s `pool_items` with it, decides
       where each item goes from the project pool as the transaction holds
       it:
       - **One the project pool has,** cached or its own, is written over
         where it is. A uuid in both places is the cache's, as the part
         loaders read the cache first.
       - **A copy of an attached pool's item,** one that pool holds under
         that uuid, goes in the cache, where `import_pool_part` would put it.
       - **One no pool has is the project's own.** It goes where the app
         saves a new item (`HorizontalPoolItemFactory.suggestedURL`):
         `parts/<mpn>.json`, `units/<name>.json`,
         `packages/<name>/package.json` and so on, each name slugged. A
         symbol goes beside its unit, so `units/<dir>/<name>.json` draws as
         `symbols/<dir>/<name>.json`, as the app's New Symbol suggests.
     - **Names that collide:** a new item keeps clear of every file in the
       project pool and of the rest of its batch, adding `-2`, `-3`, … as
       `availableURL` does. The comparison ignores case, since a Mac disk
       takes `parts/DAC.json` and `parts/dac.json` for one file. A package
       keeps clear of any directory of that name.
     - **Results:** `list_part_updates` gives such a part `projectOnly`
       with `in_attached_pool` false. The Parts pane still offers Copy to
       Pool, and Clean Up Project Pool leaves it alone, as it leaves every
       project-local item.
     - **Where it looks:** the project pool's items come from the
       transaction's archive, so a live document's unsaved items count. The
       attached pools are read through the library scan, and only when an
       item is new to the project.
     - **Frames:** `add_sheet` and `set_sheet_frame` found a frame at its
       cache path, or through the project pool index, which reads the disk.
       A frame of the project's own, written in the same batch or into a live
       document since its last save, wasn't on disk yet, so the editor now
       also looks for it in the transaction's snapshot. Parts, packages and
       the rest were already found there, through `HorizontalDispatchPoolIndex`
       and the project the transaction writes out.
     - **Descriptions:** the dispatcher's and the MCP tool's say where items
       go, and that `written` gives the paths.

## Not changed

- **The Pools pane didn't show the DAC80504** until Pools > Rescan Pools.
  The pane keeps its own scan and rescans only on that command, a saved item
  or a change to the registered pools. `pool_write` clears the library's
  scan cache, but a live edit reaches disk at the next autosave, so a scan
  in between can cache the pool without the new item. That is a separate
  fix in the Pools pane: rescan when the MCP writes pool items.
- **Parts already in Jude's cache** stay there. Nothing here moves a file.
  Moving the eleven to the project's own folders, and leaving no copy in the
  cache, makes them `projectOnly`.
- **A same-uuid edit of an attached pool's item** that the project hasn't
  imported still goes in the cache with no provenance record, as before, so
  `list_part_updates` sees an unverified copy.

## Tests

- **Swift:** five in `HorizontalMCPFieldFindings47Tests`:
  - A new part's six items go where the app saves new ones. The part is
    `projectOnly`, places with its package, and is skipped when sent again.
  - `apply`'s `pool_items` lands the same way.
  - An imported part's edit stays in the cache, and a project unit keeps
    its file when renamed.
  - An edit of Stock's unit goes in the cache, and a part derived from
    Stock's under a new uuid is the project's.
  - Names that collide, in other case and within a batch, take `-2` and
    `-3`, and each symbol stays beside its unit.
- **Changed test:**
  `HorizontalDispatchTests.testNewProjectWritesATemplatePackageAndPoolWriteAddsItems`
  expected a new unit at `pool/units/cache/<uuid>.json`. It now expects
  `pool/units/thing.json`.
- **Caught by the suite:** `HorizontalSheetEditingTests` passes a frame as
  `pool_items` and names it in `add_sheet` in the same batch. With the frame
  at `frames/<name>.json` the editor couldn't find it, which is the frame
  change above.
- **The whole suite:** 1,087 run, none fail, 6 skipped.
- **Python:** `test_mcp`, 45 pass, against the worktree's debug build.
- **Op digest:** `41850defba0fb21a`, unchanged.

## Needs

- **An Xcode rebuild**, so the live app runs the new engine.
- **A new session**, so the MCP server loads the new `pool_write`
  description.

## To check on Jude

- A dry run of `pool_write` with a new unit: `written` should name
  `pool/units/<name>.json`.
