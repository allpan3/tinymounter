# Keep Downloaded and Pause (M6) — 2026-10-16

## Outcome

M6 works in the signed app in the VM. Finder's Keep Downloaded and Allow Removal record a request
in the catalog through the app, and the test window's Pause Downloads stops Keep Downloaded
downloads and read-ahead while files that the user opens still download. Every downloaded file
matched native SMB by SHA-256.

| Question | Answer |
| --- | --- |
| Does `isSystemRequest` mark eager Keep Downloaded fetches? | **Yes**, 6 of 6 completed eager fetches logged `system=true`. Finder's Download Now logged `system=false`, so Pause doesn't stop it. |
| Do kept files stay on disk while paused? | **Yes, without disk pressure.** A 147 MB kept file stayed allocated for 2.5 min while paused. Disk pressure was not tested. |
| Does a kept file download when its parent folder isn't materialized? | **No.** `fileproviderd` held it for `parentCreation` and fetched nothing in 74 s. Listing the folder started the download 0.14 s later. |
| D2: does a stopped app's fetch fail about 60 s after its last progress? | **Yes.** `stalled=1` came 60.0 s after `SIGSTOP`. After `SIGCONT` the app released the job and left 0 stage files. |

The third answer matters for M7. A restored saved Keep Downloaded list holds kept files whose
folders the system hasn't materialized, so they won't download until the user opens each folder.

Not established: disk pressure while paused, actions on more than one file (batches over 100 IDs
have unit tests only), several locations, a full macOS restart, and the physical Mac.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a). Personal Team
  signed Release build of the M6 code, built at 03:51 and again at 04:12 from the same source,
  after the Q3 diagnostic build. `codesign --verify --deep --strict` passed.
- One location on a media folder of the share, on a fresh replica, added at 03:53 and again at
  04:23 for the last check. The SMB share stayed mounted by Finder, with the saved grant. No
  network, mount, server or sandbox setting was changed.
- Runs from 03:53 to 04:25 US/Pacific. Actions were clicked in Finder's context menu, and Pause and
  Resume in the test window, with VMPal's input tools.
- Downloads were checked by allocated size, and by SHA-256 against the same file read natively
  from the SMB mount, with a script that prints only whether they are equal.
- Counts come from a compact `log stream` of the app subsystem and `fileproviderd` at info level.
- Q3 used a temporary diagnostic build that was never committed. On `SIGUSR2`, the app listed one
  root folder that the system had never enumerated, then kept the first file of 1–512 MiB in it,
  and logged only IDs. The committed code replaced it afterwards.
- D2 used a coordinated whole-file read (`NSFileCoordinator`) of a 1.93 GB MP4 that wasn't
  downloaded, with `kill -STOP` of the app 3.1 s after the fetch began and `kill -CONT` 78 s later.
- Evictions used `FileManager.evictUbiquitousItem(at:)`. Finder offers no Remove Download for a
  partly downloaded folder.
- macOS asked whether VMPal Tools and the read helper may access files that TinyMounterPrototype
  manages, and VMPal Tools for iCloud Drive. Each prompt was allowed.
- Discarded: the first D2 attempt at 04:12:40. Its 1.93 GB fetch finished in 9.9 s (195.1 MB/s)
  before the stop, and the read helper then waited for a privacy prompt; `spindump` showed it in
  `open()`, waiting for sandbox approval.

## Data

### Keep Downloaded and Allow Removal

| Time | Action | Result |
| --- | --- | --- |
| 03:55:00 | Keep Downloaded, 147,165,726-byte file | `changed=1`; eager full fetch done at 03:55:01.3, `system=true` |
| 03:58:08 | Keep Downloaded, 2,742,783,442-byte MKV | `changed=1`; the system queued a background fetch 0.27 s later |
| 03:59:46 | Keep Downloaded while paused, 36,579,203-byte file | `changed=1`; no fetch until Resume |
| 04:02:12 | Allow Removal on one kept file | `changed=1`; the file stayed downloaded, and Finder showed Keep Downloaded for it again |
| 04:02:55 | Keep Downloaded while paused, 63,652,420-byte file | `changed=1`; no fetch, 0 bytes allocated |
| 04:04:50 | Keep Downloaded with the app quit, 65,764,584-byte file | failed with −1004 (`serverUnreachable`), `changed=0`; Finder showed "Your device couldn't connect to the server" |

Finder shows both actions with a plain checkbox-like icon; the extension sets no icon.

### Pause and Resume

| Time | Event | Result |
| --- | --- | --- |
| 03:58:13.273 | Pause, MKV download running | `kept_changed=2` and `cancelled=1` in the same millisecond. The fetch ended at 03:58:13.368, and the system got `NSUserCancelledError` (3072). Its retry at 03:58:13.417 failed at once (`stage=paused`). At 03:58:13.490, `fileproviderd` unscheduled the background download for "content policy". |
| 03:58:13–04:00:43 | Paused | the 147 MB kept file stayed allocated; the MKV stayed at 0 bytes |
| 03:59:05–03:59:17 | 256 MiB read of an MP4 | 21.68 MB/s, native 220.37 MB/s (`--no-cache`); 15 read-ahead plans skipped, none requested |
| 04:00:43.889 | Resume | `kept_changed=3`; eager fetches of the 36.6 MB file and the MKV done at 04:00:44.4 and 04:00:58.8, both `system=true` |
| 04:02:47 | Pause, then quit the app | `kept_changed=2` |
| 04:05:21.244 | Launch the app | `paused=false kept_changed=3`; diagnostics `kept=3 catalogs_paused=0`; the 63.7 MB file kept while paused downloaded at 04:05:22.0, `system=true` |
| 04:19:20.678 | Pause during a 2.03 GB read | `cancelled=0`: no speculative fetch was in flight. 45 read-ahead plans skipped. Sequential misses came about 0.75 s apart (about 22 MB/s); before, two chunks came every 0.27 s (about 125 MB/s). |
| 04:19:54.313 | Resume during the read | read-ahead started again with 12 speculative fetches; the read ended at 04:20:05, 53.0 s in all |
| 04:23:33 | Pause, then Finder's Download Now on a 65.8 MB file | full fetch done at 04:23:48.2, `system=false viewer=true` |

The 2.03 GB read's rates come from fetch log times and are single samples.

### Eviction and parent folders (Q3)

| Time | Step | Result |
| --- | --- | --- |
| 04:07:45 | Evict the kept 63.7 MB file's parent folder | succeeded. The folder stayed materialized: no new listing, dataless flag clear. The kept file was evicted and fetched again at 04:07:46.8 (`system=true`, 0.29 s transfer, `why:materialization\|itemChangedRemotely\|backgroundWork`). |
| 04:08:30 | Evict the kept file itself | refused with `NSCocoaErrorDomain` 512; the file stayed allocated |
| 04:10:41.966 | Diagnostic build: keep an 8,280,656-byte file in a root folder that the system never enumerated (1 of 3 root folders was dataless; the app listed its 60 entries first) | `changed=1`. `fileproviderd` added the item at 04:10:42.204 and held it for `parentCreation`. |
| 04:10:42–04:11:56 | Wait | no fetch in 74 s; the folder stayed dataless |
| 04:11:56 | List the folder, as an app does | the folder materialized; the system scheduled the fetch at 04:11:56.417, and it finished at 04:11:56.553 (`system=true`) |

### D2 stall deadline

| Time | Event |
| --- | --- |
| 04:16:42.975 | The coordinated read's full fetch began |
| 04:16:46.063 | `kill -STOP` of the app |
| 04:17:46.072 | `stalled=1 completed_bytes=666894336`: the fetch failed with `serverUnreachable` (−1004), 60.0 s after the stop |
| 04:17:46.113 | The system retried. The retry waited without a deadline, because the stopped app never sent `started` (plan §6, step 5). |
| 04:18:04 | `kill -CONT`. The app marked the share unresponsive at 04:18:04.685, probably because its 15 s transfer stall check counted the stopped time. The retry and one more failed at once with `serverUnreachable`, and the first job was released with `failure=cancelled`. The coordinated read returned −1004. |
| 04:18:09.808 | The probe succeeded, the share was connected again, and the app relisted 9 folders in 513 ms |
| 04:18:12.792 | Diagnostics: `stage_files=0`, `sessions=1`. The file stayed at 0 bytes allocated. |

## Correctness and limits

Every downloaded file matched native SHA-256: the 147 MB, 36.6 MB, 63.7 MB and 65.8 MB files, the
2.74 GB MKV, the 256 MiB paused read and the 2.03 GB read. Q3's 8.3 MB file and the 63.7 MB file
downloaded again after the folder eviction were not hashed. Nothing was written on the share.

- Pause cancelled a running eager download. The cancellation of a running speculative fetch uses
  the same path, but no trial had one in flight at the moment of Pause.
- Kept files stayed on disk for 2.5 min while paused, with plenty of free space. Whether the
  system evicts them under disk pressure is untested.
- Each action had one file. Splitting an action into messages of 100 IDs, and refusing more than
  1,000, have unit tests only.
- While paused, the extension also refuses a system full download that follows a
  `materializationFailed` range fault. Read-ahead is off while paused, so the race that causes it
  shouldn't happen, but a fault at the moment of Pause could fail that read. Not tested.
- Q3's consequence for M7: the SDK header says that `requestDownloadForItemWithIdentifier:` on a
  dataless folder materializes it one level down. Whether that is enough for a restored list is
  untested.
- One location; a full macOS restart, the physical Mac and Finder's display of request state
  (M7) remain unverified.

Checks on the final commit, in the VM: `swift test` ran 129 tests with 0 failures, including two
new tests for keep messages. `swift build -c release` and `python3 Tools/verify-benchmark.py`
passed. The unsigned Release `xcodebuild` passed with only the accepted App Intents notices, for
the final commit and for the Keep Downloaded commit before Pause. No files or targets were added,
so the project was not regenerated.

Cleanup at 04:25: the test location and its downloaded copies were removed, and its CloudStorage
folder is gone. Diagnostics showed `catalog_files=0 kept=0 stage_files=0`. The app is running with
no locations, one SMB mount remains, the log capture and helpers are stopped, and the clipboard
that held the folder path was cleared.

## Evidence

Private, gitignored, in the VM's `results/m6-20261016/`:

- `capture.txt` (mode 0600): the system and subsystem log. It holds private system metadata;
  never share it.
- `paused-read-provider.jsonl`, `paused-read-native.jsonl`: the paused 256 MiB read.
- `d2-read.txt`, `pause-during-read.txt`: the read helpers' results.
- `signed-build.log`, `q3-signed-build.log`, `signed-build-2.log`: the builds that ran.
- `final-swift-test.log`, `final-release-build.log`, `final-verify-benchmark.log`,
  `final-unsigned-build.log`, `keep-only-unsigned-build.log`: the checks on the final commits.
  The files without `final-` are the same checks on an earlier commit with the same code.

The helpers are in the VM's ignored `.local/phase2/`: `m6-file.py` (state, reveal, compare, read,
eviction and folder checks; it prints numbers only), `evict.swift`, `full-read.swift` and
`build-signed.py`. The Q3 diagnostic patch was not kept; Setup describes it.

## Next step

M7, the Settings window, menu bar and notifications. Before it builds saved Keep Downloaded
lists, decide how a restored list gets its downloads (Q3). Test Pause under disk pressure when a
full disk is available, and run the physical-Mac offline step.
