# Stuck pending changes

Decision status: accepted and implemented. The [SMB simplification](smb-simplification.md)
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

Creation and modification dates changed without file contents stay local through File Provider's
unsupported-field contract. They do not produce a permission failure that Retry cannot resolve.

A create or save blocked by other changes keeps that specific reason in Settings, without an
activity event. Namespace settlement signals a retry. A separate wakeup repeats from 2 seconds
up to 5 minutes until macOS resends the item; sending a signal alone does not clear it. Resending,
Stop Uploading or closing the location ends that wakeup. Reconnection preserves it until resend.

Writes go only through the app's SMB sessions, and the mutation error mapper keeps connection
failures retryable, so a complete local edit uploads again after an app or
provider restart while macOS retains its synchronization state.

<a id="decisions"></a>

## New items

The local upload outbox retains a complete payload and the acknowledged server identity.
Exclusive creation prevents a retry from overwriting an unrelated destination. A new file or
folder at `attempting` without a server identity can try exclusive creation again; a name already
present keeps the outcome uncertain. An acknowledged partial file restarts its complete upload
only after checking the recorded identity. Local payload hashes protect this retained copy;
the remote file is not read back in full.

A late cancellation can hide a completed upload from macOS. A resend with newer contents
retains the same server identity and catalog item, and writes that server file again. A replaced
or missing server file is refused, with the new local contents retained for recovery.

Stop Uploading is available for a new item before remote mutation is possible. It is also
available for a new file whose upload left a partial server file or lost its create reply, while
no upload of it runs, so that an item that macOS no longer sends can be settled. For a partial
file it first deletes the server file, only if its file ID and creation time still match the
recorded identity; another item at that name stays. After a lost create reply it stops only while
no item has the name. A file that is complete on the server and a folder that reached the server
cannot be stopped. The next `createItem` returns `excludedFromSync`, so macOS keeps the item
locally and stops sending it. A later metadata change can cause another create request. Stop
Uploading does not apply to existing-file saves.

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

Recovery requires stable server identities for the parent folders, including their creation
times. A server that changes a parent's reported creation time can leave recovery pending even
when its file ID is unchanged. Retry does not bypass this replacement check.

## System reimport

If macOS loses its synchronization database, it asks the extension to reimport local items.
A file whose size or modification date differs from the catalog might contain an unsent edit,
or it might be an old download. TinyMounter preserves it with a recovery error. It neither
fetches over the local contents nor uploads them over the server copy. Files with no catalog
match but with local contents, and unmatched folders, are also retained. Settings shows a local
recovery notice with the original path and a button to open the location. macOS may rename the
local item during recovery, so check the location for that copy. The app saves only the notice
and item identity, not another copy of the contents. That identity also blocks a later ordinary
create retry. Retry does not authorize either copy to replace the other; notices remain until
the location is removed.

Copy the retained item outside the location and verify that the copy opens. Finder preview and
copy can remain blocked while reimport is unresolved. If copying is blocked, cancel the copy,
settle app-owned pending operations, and remove the location. macOS preserves unsent files in a
recovery folder that opens in Finder. Verify those files, compare them with the server copy,
and add the location again. Copy the chosen contents into the new location only when you intend
an ordinary upload; keep the recovery copy until that upload completes.

## Location removal

Every domain removal uses `.preserveDirtyUserData`. macOS keeps items that did not upload in a
folder that TinyMounter shows in Finder. Uncertain app-owned creates, renames and deletions still
block removal until settled; Stop Uploading settles a new file that stopped partway. There is no
force-discard action.

Before installing a format-incompatible prototype, finish or export older pending work using
its original build, then use Start Fresh. No migration of older recovery transactions is provided.

## Checks and unknowns

Unit and protocol tests cover error classification, exclusive creation and retained local
payload integrity. Pressure eviction and broader editors are unverified for the simplified path.
