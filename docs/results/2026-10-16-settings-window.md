# Settings window, menu bar and notifications (M7) — 2026-10-16

## Outcome

The phase 2 UI replaces the test window in the signed app in the VM. Locations are added, renamed,
changed, duplicated and removed from the Settings window. The menu bar item shows each location's
state and Pause Downloads. Notifications post once per outage. A saved Keep Downloaded list comes
back in a later location on the same share and downloads after the user accepts a prompt.

| Question | Answer |
| --- | --- |
| Does a `displayName` update rename the CloudStorage folder? | **Yes, at once.** The folder's ctime was the second of `location_renamed`. macOS drops spaces from the folder name. |
| Does a restored saved list download? | **Yes, after Download Now.** `requestDownloadForItem` on the folders above the kept file, root first, made the system fetch it 46.7 s and 51.0 s later, in two runs. |
| Does the menu bar item show download progress? | **As text only.** It shows "87% downloaded". A `ProgressView` in a menu-style `MenuBarExtra` doesn't render, so it was removed. |
| Does Quit warn during downloads? | **Yes, after a fix.** From the menu bar item the alert first opened behind Finder's windows. |
| One notification per share per outage? | **Yes, after a fix.** The first eject posted two. |
| Do notification permission and `SMAppService` work from the build folder? | **Yes.** The prompt gave `granted=true`; Open at login showed "Login Item Added". |

Five defects were found and fixed in the run (see [Defects fixed](#defects-fixed)), and a code
review found more ([Review fixes](#review-fixes)). Not established: the slow-unmount case after
the fix, an unresponsive share (it needs a network change), several shares, a full macOS restart
and the physical Mac.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1, Xcode 27.0. Personal Team signed Release builds
  of the M7 code, built again after each fix.
- One SMB share mounted by Finder, with the saved grant. Locations on a media folder of the share,
  on two of its subfolders and on the share root. Runs from 18:11 to 18:45 US/Pacific.
- Clicks and keys in the app, the menu bar item and Finder, with VMPal's input tools. Folder paths
  went into fields through the clipboard.
- Events come from `log show` of the app subsystem at info level, which logs only IDs and counts.
- Ejects used `diskutil unmount` of the share, not forced, as in M2. Reconnects used Finder's
  Connect to Server with its saved URL; the Keychain supplied the password, with no prompt.
- macOS asked for notification permission at the first Add; it was allowed.

## Data

### Locations and saved Keep Downloaded lists

| Time | Step | Result |
| --- | --- | --- |
| 18:11:41 | First launch, no locations: the window opened with a New Location draft. Add with Return. | `location_added pending_keeps=0`; the permission prompt followed, `granted=true` |
| 18:14:19 | Finder's Keep Downloaded on a 16,093,132-byte file | eager full fetch, `system=true`, 9.6 s transfer; the pane listed it as Requested |
| 18:14:53.693 | New Name, applied with Return | `location_renamed`; the window, the menu and the CloudStorage folder changed in the same second |
| 18:16:30, 18:16:44 | Pause Downloads, then Resume Downloads in the menu | `paused=true kept_changed=1`, then `paused=false kept_changed=1` |
| 18:18:16 | Remove Location… with "Save the Keep Downloaded list" on | `location_removed saved_keeps=1` |
| 18:18:46.875 | New Location on the same folder: the draft listed the saved path; Add | `pending_keeps=1`; 0.13 s later `restore_keeps kept=1 not_on_server=0` |
| 18:19:00.334 | "Download 1 kept file now?": Download Now | `request_folders requested=1 failed=0`; the system fetched the file at 18:19:47.040, `system=true` |
| 18:21:36 | Apply to a subfolder that holds the kept file, after the confirmation | `location_applied` with the kept path carried over; `restore_keeps kept=1`; the same prompt |
| 18:21:53 | Not Now | `restore_prompt download=false` |
| 18:24:34 | Relaunch | `launch_reconciliation records=2 catalogs=2 domains=2 unknown_domains=0`; the window stayed closed, as the menu bar item is shown |

Also checked, without log events: Revert discards a source edit; `−` removes a Keep Downloaded
request; Duplicate makes "<name> copy" below the original, and it stays there after Add (18:55,
after the last fix); a copy whose name is taken gets "<name> 2"; closing the window keeps the app
running, and a Dock click opens it again; General, Servers and About render; Open at login
registers and turns off again.

### Menu bar and Quit

| Time | Step | Result |
| --- | --- | --- |
| 18:28:51 | Finder's Download Now on a 2,742,783,442-byte MKV, then open the menu | "<name> · 87% downloaded"; no progress bar; the icon showed the download symbol. The fetch took 11.9 s (230 MB/s). |
| 18:29 | Quit tinymounter, after the download had ended | the app quit at once, as no download was in progress |
| 18:30–18:31 | The same at 33% | the warning opened behind Finder's windows; Cancel kept the app running |
| 18:33 | After the fix, at 24% | the warning opened in front, with Quit tinymounter as the default button; Cancel kept the app running |

### Notifications

| Time | Step | Result |
| --- | --- | --- |
| 18:34:53.453 | Eject | `state=notConnected`, `session_ended reason=will_unmount`, a notification at .465 |
| 18:34:56.175 | (no action) | `session_started`, `state=connected`: the volume was still in the mount table |
| 18:35:04.116 | (no action) | `session_ended reason=did_unmount`, a second notification |
| 18:41 | Reconnect, after the fix | all three locations Connected again |
| 18:42:08.139 | Eject | `state=notConnected` and one notification; no new session. This unmount ended at once. |
| 18:43:09 | Relaunch while not connected, then open a 5 KB file that isn't downloaded | two fetches failed; one notification, "A file cannot download" |

The banner reads "“<share>” is not connected" with "Connect to the share with Connect to Server
in Finder." Each share has one notification request ID, so a later notification replaces the
earlier one in Notification Center.

### Defects fixed

- **Two notifications for one eject.** `willUnmount` ended the session, but the volume stayed in
  the mount table until `didUnmount`, 10.7 s later. The 10 s mount-table poll started a new
  session in between. The app now starts no session on a mount from `willUnmount` until it leaves
  the mount table, or for at most 60 s.
- **The Quit warning opened behind other windows.** Quit from the menu bar item leaves the app
  inactive. The app now activates before the alert.
- **Earlier in the run:** the window's content overflowed because of `fixedSize` text; a Dock
  click didn't reopen a closed window; and Duplicate's name was replaced by the folder's name
  when the Name field took focus.

### Review fixes

A code review after the run found races and gaps that the run didn't reach. The fixes came before
the final checks:

- Add keeps the draft's ID and selection, takes a unique name again when it saves the record, and
  puts a copy below its original. Cancel and Revert are off while an Add or Apply runs.
- A saved list restores once per location, with no repeated paths, and stops if Apply replaced
  the domain. A folder counts as listed only after its listing succeeds.
- Share state changes are read on the main thread, so a late change can't replace a newer one.
- An Apply that fails after the record changed clears the edit. Remove keeps the location's
  drafts, and removing a share clears it from drafts.
- The window and the menu show a settings or domain problem. Notifications show while the app is
  active. Diagnostics run off the main thread.

A signed build with the fixes ran from 19:17 to 19:28. Add kept the selection, and a duplicate
stayed below its original after Add. Keep Downloaded on a 2,229,107-byte file, Remove with the list
saved, and a duplicate of the remaining location took the list back: one `restore_keeps kept=1`,
then the prompt. After Download Now, the system fetched the file 51.0 s after the folder request.
A later New Location draft showed no saved list. About showed the diagnostics. An eject while
tinymounter was the active app showed the banner and posted one notification.

### Text

The STE checker read 123 strings from `UIText.swift`, with placeholders filled in. It flagged 19.
Apple's and Finder's terms stay (Search, Revert, Download Now, Not Now, Allow, Resume Downloads,
right-click, notification, background, prototype), and so do the plan's terms (Requested, Keep
Downloaded list, saved) and the `home-nas` placeholder. One string changed: an unresponsive share
in Servers shows "Cannot connect", not "The server does not respond."

## Correctness and limits

- The notification fix was tested only with an unmount that ended at once. The slow case, which
  made the first eject post twice, was not reproduced.
- The 46.7 s and 51.0 s from the folder request to the fetch are two samples. Until it starts,
  the pane shows the file as Requested.
- The first launch of the build with the review fixes, with no locations, didn't open the window.
  Settings… in the menu bar item opened it, and three later launches opened it. The cause is not
  known.
- An unresponsive share was not tested; it needs the NAS to stop answering, and the VM's network
  stays unchanged. Its notification and the "Cannot connect" text are untested.
- One share, so a second grant in Servers and Apply to another share were not exercised.
- Nothing was written on the share.

Checks in the VM: `Tools/run-checks.sh` passed on the final commit: `swift test` ran 134 tests
with 0 failures, the release build and `verify-benchmark.py` passed, the project matched its
generator, and the app build had no Swift warnings. Each earlier commit of the branch also built
and passed its tests. A signed build before the review fixes loaded the settings of the earlier
run: 3 records, `unknown_domains=0`.

Cleanup at 18:57, and at 19:28 after the run with the review fixes: the test locations were
removed without saving their lists, and with them their downloaded copies. Diagnostics showed
`catalog_files=0 kept=0 stage_files=0`, and no CloudStorage folder is left. The app is running
with no locations, Open at login is off, one SMB mount remains as at the start, and the clipboard
that held folder paths was cleared.

## Evidence

Private, gitignored, in the VM's `.local/phase2/`:

- `m7-signed-build.log`: the last signed build. `m7-checks.log` and `split-<commit>.log`: the
  checks on each commit.
- Helpers: `m7-relaunch.sh` (fetch a commit, signed build, relaunch), `m7-log.sh` (compact
  `log show` of the app subsystem), `m7-windows.swift` (the app's windows), `split-check.sh`.
- The STE input is `results/ui-copy-20261011/m7-ste.txt`.

## Next step

M8: the Storage pane and folder completion. Test the slow unmount and an unresponsive share in M9.
