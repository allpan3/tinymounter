# Exit validation (M9) and daily use in the VM (M10) — 2026-10-18

## Outcome

Phase 2's exit criteria 1 to 6 hold in the signed app in the VM, also after crashes and with a
share that stops responding. An update keeps every location, and a crash during Remove Location is
finished at the next launch. The run found no tinymounter defect.

| Criterion or question | Answer |
| --- | --- |
| 1. Finder browsing 3 levels deep, child counts | **Yes.** 15 folders at depths 0–3 had the same names as the share; the location root has one extra `.Trash`, which the system creates. 0 skipped entries. |
| 2. Media reading and checksums | **Yes.** IINA and VLC played from `open -a` with partial fetches only. 40 full reads and 40 range reads of 16 MiB matched the share by SHA-256, and so did a 2.74 GB read across an extension kill. |
| 3. No memory growth | **Yes.** After 20 identical cycles, app RSS was 0.5% above cycle 1 and extension RSS 0.8% below it. The limit is 10% at cycle 3. |
| 4. No leaked mounts | **Yes.** tinymounter never mounted or unmounted. The one change: macOS itself unmounted the share after a 70 s outage (see below). |
| 5. No leaked staging | **Yes.** 0 stage files at every idle check. An app killed during a transfer left 1, which the next launch removed. |
| 6. No tombstones from failures, no names in logs | **Yes.** 0 tombstones, no `noSuchItem`, and no name, host, address or account in the log lines that remained. |
| Does a share that stops responding recover? | **Yes, if macOS keeps the mount.** After a 30 s block, a probe succeeded 11 s after it ended, and the app recovered. After a 70 s block, macOS unmounted the share 18 s after the block ended. |
| Does a slow unmount post one notification and start no session? | **Yes.** The unmount took 11 s; the app ended its session at `willUnmount` and started none. |
| M10: does an update keep the locations? | **Yes.** A new build over the running one kept the location, its 3,722 items, the kept file and every download. |
| M10: what does deleting the app leave? | **Everything.** The domain, Finder's sidebar entry, the CloudStorage folder with 1.1 GB of downloads, and a running extension stayed. Building the app again brought the location back. |
| M10: how long does the signature last? | **One year, by the certificate.** The build has no provisioning profile, so the 7-day limit on free profiles doesn't apply. The VM's development certificate is valid to 2027-10-11. |

Three results matter for daily use. A network outage of 70 s made macOS drop the Finder
connection, and the user must connect again in Finder; phase 3 now starts with
reconnection by the app. If the app crashes, files that aren't downloaded fail at once until the user opens the app
again; nothing restarts it. And a user who deletes the app without removing its locations keeps
them in Finder.

Exit criteria 7 and 8 moved to phases 6 and 3 on 2026-10-18 and were not tested. Not established:
the physical Mac (M10's second part), disk pressure, several locations, a full macOS restart.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434), VMPal Tools 0.40. Personal Team
  signed Release builds. Until 02:52 the build of the merged M8 code ran; at 02:52 and 02:55 the
  branch's commit was built and signed again. The two have the same source tree;
  `codesign --verify --deep --strict` passed.
- One SMB share mounted by Finder, with the saved grant. One location on the top-level folder of
  the share that M4 used: 3 entries at its root, folders to depth 4 and over 10,000 files at
  depth 5.
- Runs from 02:05 to 02:57 US/Pacific. Another session ran a test suite in the VM from about
  02:29 to 02:41, which doesn't use the NAS. Times and rates here are not performance
  measurements.
- Helpers in Python and Swift, in the VM's private `.local/phase2/`, printed only indexes,
  counts, times and checksum results. Reads turn on the I/O policy that lets a process download
  dataless files (`setiopolicy_np`). Evictions used `FileManager.evictUbiquitousItem(at:)`.
- Diagnostics come from `kill -USR1` of the app and `ps` RSS of the app and extension. Events
  come from `log show` of the app subsystem at info level. Lines older than about 35 minutes
  rolled out before the name check, so it read the 271 lines from 02:26:40 on.
- Players: IINA 1.5.0 and VLC 3.0.24, each opened with `open -a <player> <path>`, which doesn't
  go through Finder.
- Outages (D8): a temporary pf anchor dropped traffic to and from the NAS address only; the
  enable token was released afterwards, and pf ended disabled. Ejects used `diskutil unmount`,
  not forced. Reconnects opened the share's saved `smb://` URL, and Finder's dialog filled in the
  password from the Keychain.
- macOS asked whether VMPal Tools, IINA and VLC may access files that TinyMounterPrototype
  manages, and whether VMPal Tools may access Documents. Each was allowed. The first VLC prompt
  got Don't Allow by a mis-aimed click; `tccutil reset FileProviderDomain` for VLC asked again,
  and that prompt was allowed.

## Data

### Browsing (criterion 1)

A breadth-first walk listed the root, then at most 3 subfolders of each folder, to depth 3.

| Depth | Folders | Entries per folder | Names only on one side |
| --- | --- | --- | --- |
| 0 | 1 | 3 | `.Trash` in the location |
| 1 | 2 | 6, 60 | 0 |
| 2 | 3 | 8–25 | 0 |
| 3 | 9 | 2–25 | 0 |

The walk waited 2 min 25 s on a privacy prompt. Each first listing took 80–90 ms after it.

### Soak (criterion 3)

Each cycle repeated the walk, read a 268 MB and a 227 MB file in full, read 16 MiB at offset 0
of a 1.68 GB file and at 1 GiB of a 2.74 GB file, checked each against the share, evicted the
four files, and waited 15 s. 20 cycles ran from 02:10 to 02:23, about 10.5 GB through the
location.

| After cycle | App RSS | Extension RSS | Items | Stage files |
| --- | --- | --- | --- | --- |
| 1 | 107,664 KiB | 26,576 KiB | 1,688 | 0 |
| 3 | 107,696 KiB (+0.03%) | 26,608 KiB (+0.1%) | 1,688 | 0 |
| 10 | 107,840 KiB | 26,352 KiB | 1,688 | 0 |
| 20 | 108,240 KiB (+0.5%) | 26,368 KiB (−0.8%) | 1,688 | 0 |

The app rose by about 30 KiB a cycle. 20 cycles can't tell a leak of this size from allocator
growth. The extension process stayed the same, and descriptors stayed at 10. Cycle 1's full reads
took 15.6 and 7.0 s; later cycles took 3.3–3.6 s, probably with the files in the NAS's cache.

### Players (criterion 2)

| Player | File | Fetches | Downloaded |
| --- | --- | --- | --- |
| IINA, about 90 s of playback | 1.93 GB MP4 | 81 partial demand fetches, mostly 16 MiB | 1.28 GB |
| VLC, about 50 s of playback | 2.74 GB MKV | 16 MiB fetches as it played | 33.7 MB |

Neither player caused a full download. IINA's misses alternated between two regions 10–25 MiB
apart, so no miss continued the one before it, and tinymounter's read-ahead never started.

### Crashes (criterion 5)

| Time | Action | Result |
| --- | --- | --- |
| 02:43:56 | `kill -9` of the extension 4 s into a 2.74 GB read | The app logged `failure=cancelled`; a new extension started 51 ms later and logged `temp_removed=0 temp_stage_files=0`. The read finished in 26.4 s and matched the share. |
| 02:45:11 | `kill -9` of the app 3 s into a 2.03 GB read | The read failed at once with ETIMEDOUT (errno 60); the extension logged code -1004. Relaunched by hand at 02:45:12: `staging_removed=1`, a relist of 19 folders with `changed=0`, then 0 stage files. |
| 02:56:59 | `kill -9` of the app during Remove Location, with `fileproviderd` stopped by `SIGSTOP` so that the removal waited; then `SIGCONT` | The pane showed "The removal is not complete." The domain and its 1.2 GB folder stayed. At the next launch: `remove_domain`, `delete_catalog` and `delete_record`, each `ok=1`; then no domain, no folder and no catalog. |

### Unresponsive share and eject

| Time | Event | Result |
| --- | --- | --- |
| 02:45:55 | pf block, 70 s, during a 2.74 GB read | `state=unresponsive` at 02:46:10 and one notification. A downloaded file read in 0.0 s; a dataless one failed at once with ETIMEDOUT. The running read failed 40.7 s after the block. |
| 02:47:06 | Block released | Probes every 5 s still failed. At 02:47:24 macOS unmounted the share (`did_unmount`), and the state became not connected. |
| 02:48:13 | Share connected again from Finder | `session_started` with the saved grant, recovery, a relist of 20 folders with `changed=0` in 519 ms |
| 02:48:39 | pf block, 30 s | `state=unresponsive` 16.9 s later and one notification. The running read failed with ETIMEDOUT 30.6 s after the block. |
| 02:49:10 | Block released | `probe ok=1` at 02:49:21, recovery, a relist of 20 folders with `changed=0`. A dataless 63.7 MB file then read in 4.2 s. |
| 02:49:56 | `diskutil unmount` 3 s into a 2.03 GB read | `willUnmount` at .383: session ended, one notification, and both running fetches failed with `notConnected`. The unmount ended at 02:50:07, after 11 s. No session started in between, and 0 stage files stayed. |
| 02:50:52 | Share connected again | `session_started`, a relist of 22 folders with `changed=0` |

Over the second remount, 1,301 entries to depth 3 kept their inode, size, mtime and ctime, and
`st_dev` changed for all of them, as in M2.

### Logs (criterion 6)

Of the 271 remaining lines, 0 held one of the 1,115 names in the location to depth 3. Checked
against the names of the whole share to depth 3, plus the host, address, share and account,
61 lines matched two common words: "source", from the log category `source-reader`, and "cache",
a folder name. No other name matched. No line had `code=-1005`, `stalled=1` or `mutation=`.
Tombstones stayed 0 in every diagnostics line.

### Daily use in the VM (M10)

| Time | Step | Result |
| --- | --- | --- |
| 02:51:53 | Keep Downloaded in Finder on a downloaded 36.6 MB file | `changed=1`, `kept=1` |
| 02:52:38 | The new build replaced the running app, then launched | `launch_step step=add_domain ok=1`, the saved grant started a session, relist `changed=0`. Items 3,722, kept 1 and 22 listed folders, as before; the 4 downloaded or partly downloaded files kept every allocated byte. |
| 02:53:07 | App quit and its bundle deleted | After 60 s: the domain still registered, the CloudStorage folder with 1,146,464 KiB, the location in Finder's sidebar, and the extension process still running. A downloaded file read; a dataless one failed with ETIMEDOUT. |
| 02:55:52 | App built again and launched | The same counts as before the deletion, and a dataless 65.8 MB file downloaded in 1.9 s |

The development certificate in the build's signature is valid from 2026-10-11 to 2027-10-11. The
bundle has no `embedded.provisionprofile`: its entitlements (sandbox, a team-prefixed App Group,
app-scoped bookmarks, user-selected read-only files and network client) need none on macOS.
Whether the app still launches after the certificate expires was not tested.

## Correctness and limits

- One location on one share. Two locations on one folder, and nested locations, moved to phase 6.
- No NAS change was made, so criterion 8 (phase 3) was not tested. Every relist found
  `changed=0`.
- The probe recovery was seen only after a 30 s outage. After 70 s, and after 2 minutes in M4,
  macOS unmounted the share before any probe succeeded.
- A read that is running when the share stops responding fails after 30–41 s and doesn't resume:
  a player must open the file again. This is the soft mount's timeout.
- After an app crash, nothing starts the app again, so files that aren't downloaded fail until
  the user opens it. Open at login doesn't restart a crashed app.
- `fstatat`'s `st_ino` against the listing's file ID was not checked again; M1's sweep found
  them equal. Held `O_EVTONLY` descriptors after an eject were not tested: the app closes them at
  `willUnmount`.
- The players were opened with `open -a`, not from their File > Open. In the 2026-10-11 player
  tests, VLC streamed the same both ways, because neither goes through Finder.
- 20 soak cycles in 13 minutes are not a day of use.
- Nothing was written on the share.

Checks: the M9 commits change only documentation. The app's source is the same as `main`'s,
whose `Tools/run-checks.sh` passed in CI on the M8 pull request.

Cleanup: the location was removed without saving its list (the crash test above). The app runs
with no locations, Open at login is off, IINA and VLC are closed, pf is disabled with no anchor
rules, and the share is mounted once, as at the start.

## Evidence

Private, gitignored, in the VM's `.local/phase2/`:

- `m9-signed-build.log`: the last signed build. `m9-log.txt`: the log lines that the name check
  read. `m9-ident-before.json`: the identity snapshot, by hashed path.
- Helpers: `m9-walk.py` (child counts), `m9-soak.sh` (the cycles), `m9-read.py` (a read and its
  SHA-256 against the share), `m9-evict.swift`, `m9-diag.sh` (diagnostics, RSS and mounts),
  `m9-crash.py`, `m9-remove-crash.sh`, `m9-outage.sh` with `pf-block.sh` and `pf-unblock.sh`,
  `m9-eject.sh`, `m9-ident.py`, `m9-lognames.py`, `m9-domains.sh` and `m9-state.py`.
  `m9-native.txt` and `m9-cloud.txt` hold the location's paths.

## Next step

M10's second part: the user installs the app on the physical Mac and uses it read-only, following
[prototype.md §5](../prototype.md#5-install-update-and-remove). Then phase 3, which now starts with
reconnection: after the outage result, the user agreed to move it earlier.
