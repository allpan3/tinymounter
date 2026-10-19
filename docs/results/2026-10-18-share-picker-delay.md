# Share picker delay on the physical Mac

## Outcome

The user's reported first-use wait of about 10 s remains unexplained. The picker appeared in
1.33 s with the share already mounted, and in 1.97 s after quitting the app, unmounting the test
share and letting the picker process exit. Neither attempt reproduced the reported wait.

The signed M12 app installed and connected a share on the physical Mac. This checks installation
and Add Share, not daily use or the rest of M10.

## Setup and method

- 2026-10-18, 19:02 to 19:39 US/Pacific. Physical Mac, Apple M5 Max, Mac17,14, macOS 27.0.1
  build 26A434. The existing Personal Team signed M12 Release build ran from `/Applications`.
  Its signature passed verification, its team and bundle identifier matched the installed M11
  app, and the installed executable matched the ready build. There were no locations to migrate.
- One user-approved SMB share, with macOS's saved credentials. The agent entered no password.
  The NAS, SMB metadata and kernel cache states were unknown. No global cache was cleared.
- Timed from the accessibility click on Connect in Add Share until the Open button appeared in
  the picker. Polling and process sampling add overhead; this does not measure the first visible
  pixel. Each valid condition has one sample, so there is no measured latency distribution.
- For the fresh attempt, the app quit normally and its picker helper exited. The test share was
  unmounted without force, and the same app relaunched. A pre-existing SMB mount stayed connected.
  App settings and persistent picker state stayed, so this is not a fully cold-cache run.

## Data

| Time | Condition | Mount callback | Connect to picker Open button |
| --- | --- | --- | --- |
| 19:28 | First agent attempt, picker process already used | 53.8 ms | Invalid probe; no timing |
| 19:31 | Share mounted and granted, picker process already used | Not retained | 1.330 s |
| 19:38 | Test share unmounted, app and picker process restarted | 48.7 ms | 1.966 s |

The first probe looked for Open directly under the sheet. The button is inside its split group,
so that probe missed it. Its 20 s polling limit is not a picker delay and is excluded.

During reset, `diskutil unmount` did not finish within 20 s. A later normal POSIX unmount completed
in 57 ms. No force was used. The cause of the `diskutil` wait is unknown.

## Correctness and limits

The picker opened on the share, Open created a grant, and a session started. After the final
Open, bookmark resolution took 1.1 ms and opening the share root took 0.1 ms. The app remains
running with the test server connected. No location was added and no NAS file was downloaded.

The picker process samples show AppKit, FinderKit, bookmark and metadata work during the fast
attempts. They do not explain the user's slow attempt. The mount callback's short duration also
does not measure the whole connection flow, including presentation of the picker.

Password entry and the Keychain checkbox, daily file use, sleep and wake, a network change and a
macOS restart remain unverified on the physical Mac.

## Evidence

Local, gitignored, under `results/m10-physical-mac-20261018/`:

- `installation-190308.json` and `setup.json`: installation checks and hardware/OS setup.
- `add-share-attempt-1.json`, `add-share-attempt-2.json` and `add-share-attempt-fresh.json`:
  conditions and timings, including the invalid first probe.
- `add-share-app-stack-1.txt`, `add-share-panel-stack-2.txt` and
  `add-share-panel-stack-fresh.txt`: call graphs without process headers or binary paths.
- `add-share-events.json` and `reset-attempt.json`: sanitized app events and reset results.

The local helper `/tmp/tinymounter-picker-timing.py` polls the picker and samples its process.
Run it with a user-approved SMB URL after selecting Servers. The fresh condition also requires
quitting the app, unmounting that test share and confirming that the old picker process exited.

`Tools/run-checks.sh` passed in the VM with 152 tests, 0 failures and the required builds. Its log
is in the VM at `.local/phase2/m12-physical-docs-checks.log`. No application code changed.

## Next step

Capture a slow attempt before changing the connection flow. Separate timing of mounting from
picker construction, setting its directory and displaying the sheet. The current evidence does
not justify calling a 10 s wait normal or assigning it to SMB resolution.
