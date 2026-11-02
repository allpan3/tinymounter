# Stuck pending changes

Date: 2026-11-02. Decision status: accepted on 2026-11-02 with the recommendations below.
The user asked for simple, effective methods. Parts 1–3 are implemented and pass a signed VM
check ([results](results/2026-11-02-pending-changes-list.md)). Parts 4–5 are implemented for new
items and pass a signed VM check ([results](results/2026-11-02-stop-uploading.md)); Stop
Uploading for edits of existing files is deferred.

On 2026-11-01 three pending records kept the physical Mac's location from being removed and
stopped NAS change discovery. Settings showed only "Pending changes: 3", and nothing the user
could do cleared them. The location was recovered with Start Fresh
([record](results/2026-11-02-start-fresh-install.md)).

This plan has four parts:

- Stop ordinary failures from becoming permanent.
- Record why each item waits.
- List each pending item in Settings.
- Let the user stop an item when its state proves that nothing reached the server.

Remove Location then works whenever no uncertain server work remains. The plan does not add a
force-discard action, which the [roadmap](roadmap.md) rules out.

## Causes

**macOS stopped retrying the folders.** The app reports every unexpected creation failure to
macOS as `NSFileProviderError.cannotSynchronize` (`SourceReaderHost.mutationError`). This includes
`UploadError.unresolved` and `UploadError.pendingWrites`, which `requireSettled` returns while
another change on the share is unfinished. Apple's `createItem` contract says that macOS then
"back[s] off until the next time it is signalled" with `signalErrorResolved`. The app never sent
that signal, and it runs a creation only inside `createItem`, so nothing retried the two folders.
Their six files waited behind them as `parentCreation` in macOS and have no app records.

**The edit could never finish.** Each retry of the edit failed its evidence check
(`UploadError.unresolved`, code 2). The NAS copy had changed after the local edit, which is
the likely reason. Export Local
Copy was available, but the record stayed pending after an export.

**Nothing showed why.** No upload, edit, rename or deletion record stores its last error or when
it was last tried. Info logs had rolled out by the time anyone looked, so it is still unknown why
the two folder creations failed.

**Pending changes block more than removal.** `pendingWrites` blocks these:

- Remove Location;
- source changes;
- turning Read only on;
- removing a domain at launch.

`EditNamespace.requireSettled` also stops discovery and new creations for the whole share. It
does this while any rename is pending, any deletion has not finished, or any edit is past
`prepared`.

## Proposal

### 1. Signal macOS to send failed items again

The error mapping stays. The app calls `signalErrorResolved(.cannotSynchronize)` for the
location's domain when the user clicks Retry Pending Changes, and for each affected domain
when its share recovers. Apple documents that this cancels throttling for every item throttled
with that error. macOS then calls `createItem` again, and the existing match by template resumes
the record. Retry also covers every location on the same share, because `requireSettled` is
share-wide.

### 2. Keep each new item's last failure

The app keeps the last failure of each new file or folder in memory, by its macOS template, with
its path, a short reason and the time. Success removes it, and Retry clears the list so that the
next attempts fill it again. Nothing is written to disk, and no record format changes. Edits and
renames already show their state, so they are not included.

### 3. List pending new items in Settings

Below the count, the location pane lists each new item that is not on the server yet: its
upload record, or a failure that came before a record existed. Each row shows "New folder:" or
"New file:" with the path, then "Waiting to upload" or "Did not upload: *reason* Last try:
*time*." Retry Pending Changes appears whenever anything is pending or listed. Items that macOS
holds behind a parent folder have no app record, so they are not listed.

### 4. Stop an item only with evidence

Stop Uploading appears only where the record's state proves that no server change is in
progress:

| Record | States | Stop Uploading |
|---|---|---|
| New folder or new file | `staging`, `prepared` (definite failure), `collision` | Marks the record `stopped` and discards its copy of the contents. macOS sends the item again and receives `excludedFromSync`, so the item stays on this Mac and is no longer pending. |
| New folder or new file | `attempting`, `created`, `verified` | Not offered. The server may have the item, so Retry checks it first. |
| Edit | `isLocalOnly`, or the conflict copy is published | Deferred. Remove Location keeps saves that never reached the server (part 5). |
| Edit | `mayHaveChangedOriginal` | Not offered. Recovery has to finish first (existing rule). |
| Rename | `refused` | Already final. The row offers Dismiss. |
| Rename or deletion, still pending | any | Retry only. |

### 5. Remove Location with stoppable items

Remove Location no longer refuses when every remaining record is stoppable. It does three
things:

1. It lists those items in the confirmation.
2. It stops them.
3. It removes the domain with `.preserveDirtyUserData`, like Start Fresh, and opens the kept
   folder in Finder.

Records in uncertain states still block removal, and the dialog names them.

## Decisions

1. **Removal rule.** Part 5 changes the accepted M18 rule that pending uploads prevent removal
   ([ui-design.md](ui-design.md#m18-creation-access-accepted-2026-10-23)), because the kept
   folder preserves the data. Part 5 changed the rule.
2. **Edits.** Stop Uploading for edits of existing files is deferred to a later change. It needs
   its own path through `modifyItem`. Remove Location already keeps saves that never reached
   the server, because macOS still holds them as not uploaded.
3. **Order.** Parts 1–3 come first, because they fix the stall and show the cause. Parts 4–5
   follow in a second PR.
4. **Exclusion.** Stop Uploading answers the item's next `createItem` with
   `NSFileProviderError.excludedFromSync`. macOS then keeps the item and its contents on this Mac
   and stops sending it. Apple documents that macOS calls `createItem` again whenever the item's
   metadata changes. The stopped record is gone by then, so the item uploads normally. A new item
   in a stopped folder changes the folder's metadata, so the dialog says this.
5. **Removal keeps local data.** Every domain removal uses `.preserveDirtyUserData`. macOS keeps
   items that did not upload, stopped items included, in a folder that tinymounter shows in
   Finder.
6. **Uncertain creates.** A new file or folder left at `attempting` without a server identity is
   tried again by creating it again. This succeeds only while the name is absent, so an item that
   the earlier attempt created is never created twice. A name that exists keeps the record
   uncertain. This replaces the check on Retry that part 4 planned.
7. **Refused saves.** When the server refuses the private stage file of a save, and a lookup on
   the same connection finds nothing at its name, the save returns to waiting. Before this, the
   save stayed uncertain, and `requireSettled` blocked new items on the whole share.

## Checks and unknowns

**VM checks.** Signed VM checks cover these cases:

- A folder created while the share is disconnected uploads after reconnect. Passed.
- A forced folder failure shows its reason in Settings and clears with Retry. Passed.
- Stop Uploading followed by Remove Location keeps the local files. See the
  [results](results/2026-11-02-stop-uploading.md).
- An edit whose NAS copy changed can be stopped, with its local copy saved. Deferred with
  Stop Uploading for edits.

**Answered by the check.** Items that macOS holds as `parentCreation` need no signal of their
own: macOS sends them as soon as the parent folder uploads.

**Fixed after the check.** On a share whose connections took longer than the 15 s health
limit, each create made the share look unresponsive, and the recovery that followed sent the
signal again, so a failing item was retried about every 21 s. tinymounter's own SMB calls now
have a 60 s limit while they run. The same follow-up keeps the Settings status updating while
a write waits for the server, and lets a file that the server refused upload again after
Retry. See the [follow-up check](results/2026-11-02-pending-changes-list.md#follow-up-check-of-the-limits).

**Fixed after the code review.** A folder that the server refused stayed uncertain forever. It
now returns to waiting when a lookup shows that nothing was created. Records that an older build
left uncertain do not change, so part 4's check on Retry must cover them. See the
[code review follow-up](results/2026-11-02-pending-changes-list.md#code-review-follow-up).
