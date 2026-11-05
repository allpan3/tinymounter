# Stuck pending changes

The [accepted SMB simplification](smb-simplification.md) supersedes this document's custom
remote recovery and conflict-preservation requirements from 2026-11-04. Implementation and VM
validation are in progress; earlier completed milestones remain historical evidence.

Date: 2026-11-02. Decision status: accepted on 2026-11-02 with the recommendations below.
The user asked for simple, effective methods. Parts 1–3 are implemented and pass a signed VM
check ([results](results/2026-11-02-pending-changes-list.md)). Parts 4–5 are implemented for new
items and pass a signed VM check ([results](results/2026-11-02-stop-uploading.md)). Stop
Uploading for edits of existing files passes the signed
[concurrent-save recovery check](results/2026-11-03-permanent-command.md).

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
renames with transaction records already show their state. Part 6 covers changes held only by macOS.

### 3. List pending new items in Settings

Below the count, the location pane lists each new item that is not on the server yet: its
upload record, or a failure that came before a record existed. Each row shows "New folder:" or
"New file:" with the path, then "Waiting to upload" or "Did not upload: *reason* Last try:
*time*." Retry Pending Changes appears whenever anything is pending or listed. Items that macOS
holds behind a parent folder have no app record; part 6 lists them when macOS supplies them.

### 4. Stop an item only with evidence

Stop Uploading appears only where the record's state proves that no server change is in
progress:

| Record | States | Stop Uploading |
|---|---|---|
| New folder or new file | `staging`, `prepared` (definite failure), `collision` | Marks the record `stopped` and discards its copy of the contents. macOS sends the item again and receives `excludedFromSync`, so the item stays on this Mac and is no longer pending. |
| New folder or new file | `attempting`, `created`, `verified` | Not offered. The server may have the item, so Retry checks it first. |
| Edit | `prepared`, or the conflict copy is published, and no other save of the file needs work | Opens a save panel. After the app writes the copy and checks it against the save, it marks the record `stopped` and discards its copy of the contents. macOS sends the file again and receives the server's version, which replaces the local file. Cancel changes nothing. |
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

### 6. Show changes held only by macOS

Accepted follow-up, 2026-11-04: Settings also reads File Provider's pending set. This includes
renames and moves refused before an app transaction exists. Each system row shows its supplied
name, failure and Show in Finder. The system can supply the server name even when Finder shows
a pending local name. The list is separate from the app's transaction count; these sets overlap.
A capped or unavailable system list is reported explicitly.

A stale-base organization refusal keeps `cannotSynchronize`, with a fixed reason that contains
no path. The provider preserves only this recognized error detail. Settings uses the catalog
to show the last known server path and tells the user to restore that name and folder in
Finder. It withholds that guidance for retired bindings or unresolved rename transactions.
Retry keeps the existing admission checks. It does not rebase the request onto a newer item.
An older generic error gets its specific reason when Retry sends the request again.

macOS owns the pending entry and its error; no new app storage or data migration is added.
Undo uses the existing callback that completes only when the requested name and parent already
match the catalog. No server rename, content discard or forced completion is added.

## Decisions

1. **Removal rule.** Part 5 changes the accepted M18 rule that pending uploads prevent removal
   ([ui-design.md](ui-design.md#m18-creation-access-accepted-2026-10-23)), because the kept
   folder preserves the data. Part 5 changed the rule.
2. **Edits.** The route for new items does not carry over to edits of existing files: Apple's
   `NSFileProviderError.h` says that after `excludedFromSync`, macOS downloads the item and then
   calls `deleteItem` for it. For an existing file, that call asks the provider to delete the
   file on the server. Stop Uploading for an edit therefore first writes the save to a file that
   the user selects, named like `Report (not uploaded 2026-11-02).txt`. Only after the app
   checks that file against the save does it mark the record `stopped` and discard the save.
   The app then signals macOS, which sends the file again. The app answers with no published
   version, so `modifyItem` sets `shouldFetchContent`, and macOS fetches the server's version
   and replaces the local file. This is the documented conflict route in
   `NSFileProviderReplicatedExtension.h`. Any send for the file removes its `stopped` record,
   so a later save uploads normally. If the answer does not reach macOS, macOS sends the file
   again, and the save uploads. Other saves of the file must finish first, because a
   retired save needs a newer one before its cleanup. The user approved this on 2026-11-02.
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
8. **Leftover creates.** A stage or backup create that got no answer can still reach the server
   later. It then leaves an empty file at a name that only that save uses. When a retry, or the
   check of an older save, finds the name taken, the app opens the occupant on the same
   connection with delete access and no sharing. This open fails while another client has the
   file open. The app deletes the occupant only if it is a regular file of 0 bytes, with one
   link, no named streams and the empty DACL that the private create sets. The app replaces that
   DACL only after it records the identity, so a file that still has it never received
   contents. The save then sends its create again. Anything else stays at the name, and the
   save stays uncertain. The user approved this on 2026-11-02.

## Checks and unknowns

**VM checks.** Signed VM checks cover these cases:

- A folder created while the share is disconnected uploads after reconnect. Passed.
- A forced folder failure shows its reason in Settings and clears with Retry. Passed.
- Stop Uploading followed by Remove Location keeps the local files. See the
  [results](results/2026-11-02-stop-uploading.md).
- A save that did not upload can be stopped. The selected file holds the save, and Finder and
  TextEdit then show the server's version. Not run yet.
- The next attempt removes the empty file of a stage or backup create without an answer
  (fixture case c05). Not run yet. It also shows whether the server lets the owner open a file
  with an empty DACL for delete. If it does not, such a save stays uncertain.

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
