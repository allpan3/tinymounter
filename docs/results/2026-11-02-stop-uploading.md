# Stuck pending changes: VM check of parts 4–5

Date: 2026-11-02. A signed VM build of parts 4–5 of the
[pending-changes plan](../pending-changes-plan.md) works for new files and folders. Stop
Uploading keeps a refused item on this Mac and removes it from the pending list. Remove Location
now works when the only pending items never reached the server: macOS keeps them in a folder,
and the app shows that folder in Finder. The check found two defects, both fixed: a save that the
server refused blocked every new upload on the share, and a removal that kept nothing still
tried to show a folder. Stop Uploading for edits of existing files is deferred; Remove Location
keeps such saves on this Mac.

## Setup

The app ran in macOS VM 1 under a separate test identity (`dev.tinymounter.stopcheck`), signed
with the installed app's Apple Development certificate. A new location used the loopback Samba
fixture share `tinymounter-m19-edit-test`, folder `probe-stop-20261102`, with write access. The
first runs used the `pendingcheck` identity; its location kept a record from build 01 that no
later build can clear (see [Limits](#limits)), so later runs used the new identity.

Write access on the server was removed by adding `read only = yes` to the share with a
configuration reload, and ending the kernel mount's smbd process so that the next connection
read the new setting. Removing the line and ending the process again restored write access.

Four builds of the `stop-uploading` branch ran. Builds 02–04 added the fixes below. The final
code differs from build 04 only in two comments. `Tools/run-checks.sh` passed in VM 1 on the
final commit: 549 tests, one skipped, no failures or Swift warnings.

## Results

| Check | Result |
|---|---|
| Stop Uploading, refused folder and refused file | The rows left Settings. Each item's next create got `excludedFromSync` (-2010); nothing was deleted on this Mac or the server. The record's copy of the contents was freed. Both items showed `isExcludedFromSync=1`. |
| Stopped file, unchanged, after write access returned | Not uploaded, also after Retry Pending Changes. |
| Stopped file, edited later | Uploaded. The server copy's SHA-256 matched the local file. |
| New child in a stopped folder | macOS sent the folder again, as Apple documents for a metadata change. With write access, the folder and its child uploaded. The dialog text now says this. |
| Uncertain creates left by older builds | `vetoed-file-05.txt` and `denied-folder-07`, stuck at `attempting`, resolved at the next launch with the exclusive create and uploaded; SHA-256 matched. |
| Remove Location with a blocking change | The dialog named the change and pointed to Retry Pending Changes. |
| Remove Location with stoppable items | The confirmation listed the edited file, the new file and the new folder. After the removal, the kept folder held the local edit, the new file, and the new folder with its child. The server did not change. Finder opened with the folder selected. |
| Stop Uploading, then Remove Location | The stopped file and the stopped folder with its child were in the kept folder. |
| Remove Location with nothing pending | macOS returned a location but created no folder. The app logs `preserved=0` and does not open Finder (build 04). |
| Refused save, then new items | The save went back to "Waiting to upload", and a new folder got the server's own refusal, not "Other changes on this share must finish first" (builds 02–04). |

## Defects found and fixed

**A refused save blocked the share.** With write access removed, a save's private stage create
was refused, and the save stayed at `creatingStage`. Recovery treats that state as an uncertain
write, so the save never published. `requireSettled` also blocks every new item on the share
while such a record exists, and it did so even after write access returned. A later save of the
same file published, but the stuck record stayed. Now, when the server answers the stage create
with an error and a lookup on the same connection finds nothing at the stage name, the save
returns to `prepared`. Samba can refuse a create and still leave the file, so the refusal alone
is not enough.

**A clean removal looked for a kept folder.** `NSFileProviderManager.remove(_:mode:)` with
`.preserveDirtyUserData` returns a location even when it kept nothing, and then creates no
folder there. The app now opens Finder only when the folder exists.

## Limits

- **Short windows on this fixture.** Folder creates return Cocoa error 513, which macOS retries
  by itself with backoff (0, 5, 11, 20 s and longer). Each SMB connection on this fixture takes
  about 20 s, because the VM cannot resolve its own host name. A refused folder is therefore
  `attempting` most of the time, and Stop Uploading and Remove Location are offered only between
  attempts. A real NAS should give short attempts and long gaps; this was not measured.
- **Edits.** Stop Uploading for edits of existing files is deferred
  ([plan, decision 2](../pending-changes-plan.md#decisions)).
- **Unanswered stage creates.** A save whose stage create timed out, or whose app crashed
  without an answer, stays uncertain under the M19 rule and blocks new items on the share. The
  same exclusive-create check could resolve it; that is a possible follow-up.
- **Records from older builds.** A save that build 01 left at `creatingStage` stays stuck, because
  builds do not migrate pending changes before release. The `pendingcheck` location in VM 1 keeps
  it as evidence.

## Cleanup and evidence

Build logs, check logs, the app log and the kept folders' SHA-256 lists are in VM 1 under
`.local/phase4/stop-uploading-20261102`. The `stopcheck` app was quit and removed, the kept
folders were deleted after their lists were saved, and the fixture's Samba server, mount and
Apple smbd state were restored. The `pendingcheck` app and location stay in VM 1 with the stuck
record.
