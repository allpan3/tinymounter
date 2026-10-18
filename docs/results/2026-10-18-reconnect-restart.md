# Reconnection and restart after a crash (M11) — 2026-10-18

## Outcome

In the signed app in the VM, the share comes back by itself when macOS drops it, and the app comes
back after a crash. An eject, Quit and Force Quit change nothing. All 7 checks of the
[phase 3 plan](../phase3-plan.md#3-checks-m11) passed. The run found and fixed two defects in the
restart after a crash.

| Question | Answer |
| --- | --- |
| Does the share come back after macOS drops it? | **Yes.** After a forced unmount, the app mounted the share in 1.26–1.5 s and a session started. After a 70 s outage, macOS unmounted the share 17 s after the NAS answered again, and the app mounted it 1.48 s later. |
| Does an eject stay? | **Yes.** After `diskutil unmount`, no share was mounted for over 4 min. A mount by someone else ended the hold, and a later forced unmount was followed by a mount again. |
| Does the app mount the share at launch? | **Yes**, in 3.5 s, after the share was ejected while the app was stopped. |
| Does the app come back after a crash? | **Yes.** After SIGSEGV, SIGTRAP, SIGILL and SIGABRT, the extension started the app again in 39–67 ms, and a new read matched the share. A second crash less than 60 s after a launch didn't restart it. |
| Do Quit and Force Quit leave the app stopped? | **Yes.** After a Quit and after `kill -9`, reads failed and nothing started the app, also when a new extension started. |
| Leaks | **None.** One share mount at the end. A crash during a transfer left at most 1 stage file, which the next launch removed. 0 of the 587 kept log lines held a share, host or account name. |

Two defects were found and fixed during the run:

1. **A Swift trap hung the app.** After `kill -TRAP`, the app didn't end, and one thread used 100%
   of a CPU. macOS ignores `SA_RESETHAND` for SIGILL and SIGTRAP ("silently ignored", sigaction(2)),
   so the handler raised the signal into itself again and again. A Swift trap, such as a failed
   force unwrap, arrives as SIGTRAP, so every such crash would have hung a thread instead. The
   handler now resets the signal to its default action itself.
2. **Launch Services refused some restarts.** After a SIGABRT, `openApplication` failed with
   NSCocoaErrorDomain 256 in 12.7 ms, the app stayed down, and Finder showed "The application
   “TinyMounterPrototype” is not open anymore." launchservicesd logged the old process's exit
   4 ms after the request. This happened in 2 of 9 restarts. A retry 1 s later worked, but the alert
   still showed, so the extension now waits until Launch Services no longer lists the crashed app,
   then opens it once. In the 4 crashes after this change, it waited 21–30 ms, and no alert showed.

Not established: sleep and wake, a network change, a Keychain without the password, a trap from
real code instead of `kill`, and the physical Mac.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434). Personal Team signed Release builds of
  the `reconnect-restart` branch; `codesign --verify --deep --strict` passed for each. The VM's
  `Tools/run-checks.sh` passed for each: 150 tests, 0 failures, and the required builds.
- One SMB share, connected in Finder with the saved grant. One location on a folder with 11
  entries, 5 of them files of 307–433 MB. Runs from 03:50 to 04:43 US/Pacific.
- Another agent session that shares the VM mounted the share from the saved login at 04:02,
  deleted only its own test folders and ejected the share at 04:04. The app's log shows that
  mount and eject as part of check 3.
- Forced unmounts used `umount -f`, as macOS's unmount does: only `didUnmount` is posted. Ejects
  used `diskutil unmount`. The outage was a pf anchor that dropped traffic to the NAS address
  only, as in M9, for 71 s; pf ended with only Apple's anchors. The Finder reconnect opened the
  saved `smb://` URL and clicked Connect in a dialog that the Keychain had filled in.
- Crashes: `pkill -<signal>` of the app 1 s into a full read of a file that wasn't downloaded,
  then a full read of the same file, by SHA-256 against the share. Crashes that had to restart
  were at least 63 s after the last launch. A restart time runs from the extension's loss of the
  reader to the end of `openApplication`. Quit used the quit Apple event (`osascript`), which
  runs the same `applicationWillTerminate` as the menu's Quit. Force Quit was `kill -9`.
- The App Group container is protected from the VM's tools, so the run state came from the log:
  `previous_run=` at each launch and `app_restart` in the extension. Stage files came from
  `staging_removed=` at launch and `temp_stage_files=` at each extension start.
- Builds, in order: the first M11 build (checks 1–4, Quit, `kill -9` and the first SIGSEGV and
  SIGTRAP), the handler fix, a retry of `openApplication` after 1 s, and the wait for Launch
  Services, which replaced the retry. The later changes touch only the restart after a crash.

## Data

### Reconnection

| Time | Event | Result |
| --- | --- | --- |
| 03:58:19 | `umount -f` | `remount_started` in the same millisecond as `didUnmount`; mounted in 1284 ms; session started. Before a fix in this run, the app waited for the 10 s poll. |
| 03:58:31 | `diskutil unmount` | `remount_held`. No smbfs mount until 04:02:49. |
| 04:02:49 | Mount by the other session | Session started. Its eject at 04:03:20: `remount_held` again. |
| 04:04:29 | Finder reconnect | Session started. |
| 04:04:41 | `umount -f` | Mounted in 1260 ms; session started. |
| 04:05:03–04:06:14 | NAS blocked for 71 s | No unmount during the block. macOS unmounted at 04:06:31; the app mounted the share in 1481 ms. |
| 04:11:00 | Launch, share not mounted | `previous_run=running` (after `kill -9`); mounted in 3515 ms. |

### Restart after a crash

| Time | Signal | Build | Result |
| --- | --- | --- | --- |
| 04:12:03 | SEGV | first | Restarted in 52 ms. The read during the crash failed after 1.4 s (errno 60); the new read matched. |
| 04:12:25 | TRAP | first | **The app didn't end**: one thread at 100% CPU. Defect 1. |
| 04:16:57 | TRAP | handler fix | Restarted in 39 ms. The read during the crash finished and matched. |
| 04:17:19 | ILL, 22 s after a launch | handler fix | `skipped=recent_launch`; the app stayed stopped. A read at 04:18:16 failed and restarted nothing. |
| 04:19:44 | ABRT | handler fix | **Not restarted**: code 256 and a Finder alert. Defect 2. A new extension started the app at 04:22:33 (`extension_start`). |
| 04:25:57–04:30:54 | ABRT, SEGV, ABRT, ABRT, ABRT | retry | 4 restarted at once in 41–44 ms. 1 failed with code 256 and worked at the second try, 1.1 s after the crash, with a Finder alert. |
| 04:38:51–04:42:06 | ABRT, ABRT, TRAP, SEGV | wait | All restarted in 58–67 ms, after a wait of 21–30 ms. No Finder alert. Every new read matched. |

After each crash, macOS showed its "quit unexpectedly" alert. Reopen brought the running app
forward with its Settings window; `pgrep` still found one instance.

### Quit and Force Quit

| Time | Event | Result |
| --- | --- | --- |
| 04:09:47 | Quit, then a read | The read failed in 0.5 s (errno 60). No app 16 s later. The next launch: `previous_run=stopped`. |
| 04:10:24 | `kill -9`, then a read | The read failed in 0.7 s. No app 16 s later. The next launch: `previous_run=running`. |
| 04:32:39 | Quit, `pkill` of the extension, then a read | A new extension started with 0 stage files, waited 5 s for the reader, and the read failed. No app 15 s later. The next launch: `previous_run=stopped`, `staging_removed=0`. |

## Correctness and limits

- Every full read after a crash matched the share by SHA-256 (9 reads).
- Of the 13 launches after a crash that the log kept, 7 removed 1 stage file left by the crashed
  transfer and 6 removed none. Idle launches removed none.
- The signals came from `kill`. A trap in code differs: when the handler returns, the trapping
  instruction runs again and gets the default action. That path is not tested.
- The wait for Launch Services ends after 5 s. If a crash report takes longer, the open can still
  be refused, with the alert.
- After a crash less than 60 s after a launch, reads fail until the user opens the app or a new
  extension process starts.
- Times are from one VM and one NAS. They are not performance measurements.

## Evidence

Private, gitignored, in the VM's `.local/phase2/`:

- `m11-checks.log` and `m11-signed-build.log`: the last checks and signed build. `m11-log.txt`:
  the log lines that the name check read. The crash reports are in the VM's
  `~/Library/Logs/DiagnosticReports`.
- Helpers: `m11-crash.py` (a signal during a read), `m11-read.py` (a read and its SHA-256 against
  the share), `m11-state.sh` (the app's pid), `spike-log.sh` (the app's log lines), `pf-block.sh`
  and `pf-unblock.sh`, `evict` and `m9-lognames.py`. `m11-native.txt`, `m11-cloud.txt` and
  `m11-files.txt` hold the location's paths and its test files.

## Next step

The user's run on the physical Mac (M10's second part) with this build. Then the rest of phase 3:
verified offline status for kept files, kept folders, NAS changes while the app runs, and cache
pressure.
