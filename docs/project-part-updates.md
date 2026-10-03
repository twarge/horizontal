# Project Part Updates

Parts remain project-local snapshots. Importing or placing an already cached
part never refreshes it implicitly. Parts > Updates compares the open document
with its source libraries; Refresh checks again without changing the project.

## Review

The Parts table shows Current, Update available, Modified in project,
Source unavailable, or Project-only. Changes are aggregated across base parts,
entities, units, symbols, packages, global and package-local padstacks, and
binary 3D models. JSON formatting and the editor-owned `_imp` field are ignored.
Package model paths are normalized to Horizon's project-cache layout.

The review lists affected component references, changed fields, project/library
previews, and an optional JSON comparison. Selecting a shared dependency lists
all affected parts, including parts that were not checked. Used parts with
verified, nonconflicting updates are checked initially. Updates require explicit
confirmation to replace local edits or legacy copies without an import baseline.

Changing part identity, inheritance, entity/package assignments, pad mapping,
gate/unit assignments, or removing existing pins or pads requires remapping and
cannot be forced by the confirmation checkbox. This first implementation is
deliberately conservative: cached symbols no longer supplied by the source also
require review/remapping. Cosmetic entity gate changes do not trigger this block.
Unused cached files are retained; cleanup is not part of an update.

## Provenance And Application

`<project pool>/.horizontal/pool-cache.json` records source pool UUIDs,
pool-relative source paths, and canonical imported-content hashes. Horizon's
item JSON remains compatible. Recorded source identity wins over browsing
order. Legacy items need an unambiguous source; Choose Source Library can
explicitly select a pool when several contain the same UUID.

Planning reads the current archive, not the last-saved project. Source content
and the project library are checked again before applying. The complete staged
project must load without introducing new diagnostics. The app installs the
archive as one undoable edit, retaining private model files so unsaved 3D model
updates and undo display the appropriate bytes. Copper geometry changes mark
plane fills stale. No source-library files are edited.

## Automation

`list_part_updates` returns statuses, changes, affected references, and a
`review_digest`. `pool_path` can name an otherwise undiscovered source and
explicitly resolve legacy-source ambiguity.

`update_project_parts` takes `parts` (project part UUIDs), `expected_revision`,
`operation_id`, optional `review_digest`, optional `pool_path`, and
`allow_project_changes` (default false). `dry_run` returns the transaction
preview and `plan_digest`; supply that digest when applying the reviewed plan.
Breaking mapping changes are refused even with `allow_project_changes: true`.
Live mutations are one undo step; disk mutations use the existing transactional
writer. The UI and automation use the same comparison and update planner.
