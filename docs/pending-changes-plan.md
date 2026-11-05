# Stuck pending changes

Date: 2026-11-05. Decision status: accepted. The [SMB simplification](smb-simplification.md)
replaces custom save recovery with ordinary writes and File Provider pending uploads. New-item,
rename and deletion records still distinguish unfinished operations from completed callbacks.

The user asked for simple, effective methods:

- Stop ordinary connection failures from becoming permanent.
- Record why each item waits.
- List each pending item in Settings.
- Let the user stop a new item when its state proves that nothing reached the server.

## Retry and status

File Provider owns an existing file's pending local contents until its upload callback succeeds.
The app returns success only after SMB write, size update, flush and close. A network failure
returns `serverUnreachable`; authentication and permission failures retain their distinct errors.
Other unresolved mutations can return `cannotSynchronize`, which macOS throttles until signalled.

**Retry Pending Changes** sends `signalErrorResolved(.cannotSynchronize)` and retries recorded
renames for affected locations. Share recovery also signals resolved connection errors and wakes
pending operations. Settings reads macOS's pending-item enumerator, including changes with no app
outbox record. It shows the item's path and failure, offers Show in Finder, and reports an
incomplete or unavailable pending list instead of treating it as empty.

A signed mid-write test exposed two problems: direct writes unnecessarily reopened the location
through the native mount, and the mutation error mapper turned connection failures into permanent
sync errors. Removing that redundant lookup and preserving retryable errors lets the complete
local edit upload automatically after app/provider restart. See the
[current results](results/2026-11-05-smb-simplification.md).

<a id="decisions"></a>

## New items

The local upload outbox retains a complete payload and the acknowledged server identity.
Exclusive creation prevents a retry from overwriting an unrelated destination. A new file or
folder at `attempting` without a server identity can try exclusive creation again; a name already
present keeps the outcome uncertain. An acknowledged partial file restarts its complete upload
only after checking the recorded identity. Local payload hashes protect this retained copy;
the remote file is not read back in full.

Stop Uploading is available only before remote mutation is possible. The next `createItem`
returns `excludedFromSync`, so macOS keeps the item locally and stops sending it. A later metadata
change can cause another create request. Stop Uploading does not apply to existing-file saves.

## Existing edits and organization

TinyMounter no longer keeps remote backups, conflict copies or a second durable edit outbox.
A competing change may be overwritten, and a failed write may leave partial server contents.
NAS snapshots/backups own previous-version recovery. Pending local contents must not be deleted
to hide an error or make space.

An edit whose remote target disappeared remains pending; it does not recreate the pathname.
Copy the local file outside the location before resolving such a failure. The old edit-specific
Export Local Copy and Stop Uploading controls have been removed with their transaction code.

Rename and deletion records preserve item identities and catalog settlement across crashes and
overlapping locations. Their pending state can block related operations. A refused system-only
rename/move shows its original path and instructions for restoring its name/parent in Finder.
It is not safe to report success merely because the old remote pathname is absent.

## Location removal

Every domain removal uses `.preserveDirtyUserData`. macOS keeps items that did not upload in a
folder that TinyMounter shows in Finder. Uncertain app-owned creates, renames and deletions still
block removal until settled. There is no force-discard action.

Before installing a format-incompatible prototype, finish or export older pending work using
its original build, then use Start Fresh. No migration of older recovery transactions is provided.

## Checks and unknowns

Signed VM checks cover ordinary and competing saves, shorter/empty writes, offline retention,
and automatic upload after a mid-write interruption and app/provider restart. Unit and protocol
checks cover error classification, exclusive creation and retained local payload integrity.
Full OS restart, pressure eviction and broader editors need new evidence for the simplified path.

Earlier behavior is recorded in [pending status](results/2026-11-02-pending-changes-list.md),
[new-item stopping](results/2026-11-02-stop-uploading.md) and
[pending rename recovery](results/2026-11-04-pending-rename-recovery.md).
