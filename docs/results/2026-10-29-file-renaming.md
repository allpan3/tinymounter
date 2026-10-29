# File renaming and one write mode

Date: 2026-10-29. Decision status: accepted; implementation and VM checks in progress.

M20 permits same-folder renaming of ordinary files with an existing M19 verified revision.
The protocol gate must pass before app integration. No rename runtime result is claimed yet.
The original NAS remains read-only during agent testing. The installed M19 build is unchanged.

## Write controls

The development UI uses one Read only toggle. New locations default to writable setup;
duplicates inherit their original mode. Writable setup obtains the scoped grant and confirms
the SMB-only writer and temporary-save-file requirements. Existing read-only locations stay
read-only. Legacy creation-only locations keep their access and pending data while offering
Complete Write Setup. Confirmed grants are retained when Read only is selected, and source
changes require fresh authorization. Pending writes block enabling Read only.

Settings version 6 preserves identities, keep lists and grants while adding the mode. Older
builds must refuse this format: they would treat a retained inactive write grant as active.
Catalog creation/editing flags change together so Finder sees one permission change.

## Evidence pending

Migration and catalog regression coverage is added. Focused checks, Tools/run-checks.sh,
signed UI and Finder checks, matched recordings and fixture cleanup are still pending.
