# Stuck pending changes: VM check of parts 1–3

Date: 2026-11-02. A signed VM build of parts 1–3 of the
[pending-changes plan](../pending-changes-plan.md) works. New items that macOS throttled with
`cannotSynchronize` upload again after Retry Pending Changes or after share recovery. Settings
lists each failed new item with a reason and the time of the last try. Files held behind a
failed folder upload as soon as the folder does. The check found two defects, both now fixed:
Retry blocked the main thread while an upload was running, and system errors showed as raw
codes. One limit remains. On this fixture, an item that keeps failing is retried about every
21 s, and each retry posts the share notification again.

**Note, later on 2026-11-02.** Both limits below are fixed, and the follow-up check found and
fixed one more defect: a file that the server refused could never upload. See the
[follow-up check](#follow-up-check-of-the-limits).

## Setup

The app ran in macOS VM 1 under a separate test identity (`dev.tinymounter.pendingcheck`),
signed with the installed app's Apple Development certificate. A new location used the
loopback Samba fixture share `tinymounter-m19-edit-test`, folder `probe-pending-20261102`, with
write access. The build was the `pending-changes-list` branch; the final run used the build
with both fixes. `Tools/run-checks.sh` passed in VM 1 on that build: 540 tests, one skipped,
no failures or Swift warnings.

Failures were forced in three ways:

- **Server stopped.** smbd was terminated and later started again.
- **Server refuses names.** Samba's `veto files = /vetoed-*/` was added and removed with a
  configuration reload, without dropping connections. A refused folder returns
  `0xc0000034` (errno 2), which the app reports to macOS as `cannotSynchronize`.
- **No recovery.** smbd was paused with SIGSTOP right after a `cannotSynchronize` failure, so
  the share could not recover and only Retry could release the item.

Evidence came from the app log and from fileproviderd's throttle log, which records each
`signalErrorResolved` call, the throttles it clears and the items macOS sends again.

## Results

| Check | Result |
|---|---|
| Folder and child file created while the server was stopped | Both uploaded after smbd restarted. One queued create returned `cannotSynchronize` at reconnect. Share recovery sent the signal, and macOS sent the create again 60 ms later. |
| Folder refused by the server | Settings showed "New folder: vetoed-folder" and "Did not upload: The server refused the change: No such file or directory. Last try: Nov 2, 2026 at 2:02 AM." The held child file was not listed, as planned. |
| Recovery after a refusal | fileproviderd logged "resolved error cannotSynchronize … clearing this error's throttles" and "2 throttles expired", then `throttleExpired` for the create and for a throttled rename. macOS sent both again within 20 ms. After the veto was removed, the folder uploaded. |
| Child file held behind the folder | macOS sent it right after the folder upload succeeded. It needed no signal of its own. |
| Retry with no recovery | With smbd paused, both items stayed throttled for 98 s and nothing retried them. One Retry click cleared both throttles, and macOS sent the create and the rename again 21 ms later. |
| Item blocked by a pending rename | Settings showed "Did not upload: Other changes on this share must finish first." |
| Finish | After the veto was removed and smbd resumed, the rename and the file completed, and Settings no longer showed pending changes. |
| Write-access panel | The panel fits the 1,280 × 973 VM screen. Hide Options, Cancel and Confirm Write Access are visible and work. |

## Defects found and fixed

**Retry blocked the main thread.** Retry clears the failure list on the main actor. The list
used the upload lock, and the share's lane holds that lock for a whole create, including
network calls. Retry therefore waited until the running create finished, which has no limit
on a dead mount. The list now has its own lock. In the next run, fileproviderd recorded
Retry's signal immediately, while a create was in progress.

**System errors showed as codes.** A file refused through the mount showed "Error
NSPOSIXErrorDomain 2." These errors now read "The upload failed: *description*." This text was
not seen at runtime after the fix, because the next failures had other causes.

## Limits

**Retry loop on slow connections.** Each create opens its own SMB connection. On this fixture
a connection takes about 20 s because the VM cannot resolve its own hostname, a known fixture
defect ([2026-10-31 review](2026-10-31-everyday-use-review.md)). That trips the 15 s share
health limit, so the share changes to unresponsive and back. Each return to connected runs
recovery, which now also sends the `cannotSynchronize` signal. While a failure persists, the
item is therefore retried about every 21 s, and each cycle posts the "cannot connect"
notification again. A share with fast connections should run recovery only after real
outages. That expectation was not tested. The underlying cause is the health limit counting
connection setup as a stall, which needs a separate change.

**Status stops while the server is unreachable.** With smbd stopped, a create waits in
`fstatfs` on the dead kernel mount while it holds the upload lock. The pending count and the
new list wait for that lock, so Settings stops updating until the server returns. This existed
before this change. Retry no longer waits for it.

## Cleanup and evidence

The location was removed, and the test app, its provider registration and its CloudStorage
folder are gone. The fixture share was unmounted, Samba stopped, the test folder deleted, and
Apple's smbd bootstrapped again. Its state matches the state recorded before the test.
Logs and screenshots are kept in `.local/phase4/pending-changes-20261102/` in VM 1 and in
`results/pending-changes-20261102/` on the Mac.

## Follow-up check of the limits

Date: 2026-11-02, the same evening. The user asked for the limits to be fixed and checked
before the PR. Four changes followed, each built, signed and installed the same way as above:

1. **Direct SMB calls get a 60 s stall limit.** Folder creation, folder naming and the
   connection for a protected save use tinymounter's own SMB client, which times out each
   request itself after 10 s. While such a call runs, the share health check allows 60 s
   without progress instead of 15 s. Other share I/O keeps the 15 s limit.
2. **Status reads stop waiting for long locks.** The pending count and lists wait at most
   0.5 s for the upload or namespace lock, then read the records without it. The records are
   saved atomically.
3. **The write bookmark resolves inside the share session.** With the server paused, a create
   blocked in bookmark resolution, before the session began, so no stall limit covered it.
4. **A refused file can upload again.** When the server refused a file's create, the record
   stayed in the attempting state with no server identity. Each later attempt failed as
   "tinymounter cannot confirm the result on the server", even after the cause was gone. A
   refusal now returns the record to prepared. After a timeout or a lost connection, the
   outcome is unknown, so the record stays unresolved as before.

| Check | Result |
|---|---|
| Refusal on the slow fixture | One create. Its connection took 20 s, and the server refused the folder with `cannotSynchronize`. In the next 2 min 20 s there was no other attempt, no share state change and no notification. Before the fix, the folder was retried about every 21 s with a notification each time. |
| Retry while the refusal continues | Retry sent one signal, which cleared one throttle. macOS sent the create once, the server refused it, and nothing retried it in the next 70 s. |
| Status while a create is blocked | smbd was paused with SIGSTOP, and a new file blocked in bookmark resolution while it held both locks. 8 s later Settings showed "Pending changes: 2" and "New file: held-04.txt, Waiting to upload". |
| Outage detection after change 3 | With smbd paused again, the blocked create waited in `fstatfs` inside the session. The share became unresponsive 15 s later, one notification was posted, and Settings showed "tinymounter cannot connect to 127.0.0.1". When smbd resumed, the probe reconnected the share. Recovery then signaled `serverUnreachable` and `cannotSynchronize`, macOS sent both throttled creates again, and the queued file uploaded. |
| System error text | A file created in a folder that had been deleted on the server showed "Did not upload: The upload failed: No such file or directory." |
| Refused file, then allowed | A vetoed file failed with "The server does not give write access." After the veto was removed, one Retry uploaded it with the correct contents. |

In these runs the share changed state only during real outages: the paused smbd, and a
server connection that the check ended on purpose. Each outage posted one notification.

**Fixture notes.** Samba applies `veto files` when a client connects, so a reload does not
change the macOS mount's existing connection. The check ended that server process to make the
mount reconnect. Through the mount, a vetoed file name returned `EACCES` in this run, not
`ENOENT` as earlier.

**Remaining limits.**

- A create that is blocked when the server stops can't be cancelled. It holds the share's
  queue until the server answers again, as before. Items queued behind it have no record yet,
  so Settings lists them only when their turn comes.
- A direct SMB call that hangs is detected after 60 s instead of 15 s.
- `vetoed-file-05.txt` failed under the build before change 4 and stays unresolved. That
  record blocks Remove Location, so the test location remains in VM 1 as a test case for part
  4 (Stop Uploading). Remove the location after part 4 is in.

**Checks.** `Tools/run-checks.sh` passed in VM 1 on the final build: 542 tests, one skipped, no
failures or Swift warnings.

**Cleanup.** The fixture share was unmounted, Samba stopped, and Apple's smbd bootstrapped
again; its state matches the state recorded before the follow-up. The test app is quit. The app,
its location and the folder `probe-pending-20261102` on the fixture share stay for part 4.

**Evidence.** `runtime-followup.log`, `sample-hold-04.txt` and `sample-hold-05.txt` (app
stacks during the blocked creates) and `checks-06.log` are in both folders; `build-04.log` to
`build-06.log` are in the VM folder. Screenshots `settings-vetoed-04.jpg`,
`settings-held-during-pause-04.jpg`, `settings-unresponsive-05.jpg`,
`settings-posix-text-05.jpg` and `settings-refused-file-06.jpg` are in the Mac folder.
