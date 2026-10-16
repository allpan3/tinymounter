# Catalog browsing and reads by item — 2026-10-14 (phase 2, M4 and M5)

## Outcome

M4 and M5 work in the signed, sandboxed app on the real NAS share. Finder browsed a location four
folder levels deep from the catalog, and every checked folder's child count matched the share. Quitting
the app, restarting the extension and `fileproviderd`, purging the file cache, write attempts and
crashes during downloads caused no tombstones, no leftover staging files and no wrong data. Three
partial reads and three full downloads matched the share's SHA-256. VLC and IINA played from their
own File > Open with partial reads.

Each check that ran passed. Not covered: evicting a listed folder (Finder offered no way), two of
IINA's five seeks, the seek-cancel check (no speculative read was in flight at a seek), VLC's
seeks (VLC freezes after a seek in this VM, also on native SMB) and two outage cases that macOS
cut short by unmounting the share. One defect was found and fixed: the launch relist also tried
the system's Trash folder and counted it as a failure. Five findings came out of the runs. The
[follow-up](#follow-up-2026-10-15) resolved the first three:

1. **IINA can fall back to a full download.** Two causes, both fixed or reduced. Resolving IINA's
   recent-file bookmarks at launch downloaded each whole file. And a system race, in which a read
   meets a range being rewritten, made `fileproviderd` log `materializationFailed` and download the
   whole MKV (12.4 s and 14.9 s). The race can still happen when a fast reader catches read-ahead.
2. **IINA's reads often never start read-ahead.** A planner bug, now fixed: a request the system
   never delivered blocked all later read-ahead for the file.
3. **Remove Location keeps downloaded copies.** `.preserveDownloadedUserData` (D3) moved the five
   fully downloaded files, 4.9 GiB, into a dated, read-only folder in CloudStorage. It now uses
   `.removeAll`.
4. **Finder keeps a failed folder's error.** After the app came back, Finder did not list a folder
   that had failed while the app was quit, until the user clicked Try Again. Open.
5. **A crashed extension's first retry fails.** macOS retried a download 2 ms after the new
   extension started, before the app had reconnected. The retry failed with -1004 and Finder
   showed an alert. Open.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434), VMPal Tools 0.39. The UGREEN NAS runs
  Samba 4.17.12; its one share was mounted by Finder (smbfs) with the password from the Keychain.
- The Personal Team Release build, started at 05:00 on 2026-10-14, from
  `.build/xcode-personal/Build/Products/Release/TinyMounterPrototype.app`. The Trash fix was built
  and signed at 00:40 on 2026-10-15 and checked once (`codesign --verify --deep --strict` passed).
- One location on a top-level folder of the share: 3 entries at its root, folders to depth 4 and
  10,613 files at depth 5. The harness's saved share-root grant from M3 was reused.
- Runs: 2026-10-14 22:33 to 2026-10-15 00:41. A bounded `log stream` of subsystem
  `dev.tinymounter.prototype` ran throughout (`--style compact --level debug`). `kill -USR1`
  wrote the app's diagnostics.
- Counts through the location came from a stdlib Python helper that turns on dataless
  materialization (`setiopolicy_np`) and prints counts only. Reads used `transfer-bench` with
  `--allow-hydration --stage-dir .build/staging --verify`; the native read of each range came
  after the provider read, so it ran warm. Downloads used Finder's Download Now.
- Cache state: the NAS was warm for most folders, because a native walk had read them minutes
  before. No NAS cache was flushed. Times are single samples, not a performance series.
- Privacy prompts allowed, inside the VM, under the user's rules: "t3", then VLC and IINA "want to
  access files managed by TinyMounterPrototype". The prompt names the provider, not the location.
- VLC 3.0.24 got `--codec=avcodec,none --avcodec-hw=none` at launch for software decoding, without
  a saved preference. IINA 1.5.0 had its update check declined.
- Outage (D8): a temporary pf anchor dropped traffic to and from the NAS address only, with the
  enable token released afterwards; pf ended disabled, as before.

## Data

### M4: browsing on the catalog

| Check | Result |
| --- | --- |
| M4-1 launch | `launch_reconciliation records=0 catalogs=0 domains=0`, 0 staging files (2026-10-14 05:00) |
| M4-2 add and browse | Location listed in 13 ms. Finder browsed root, depth 1 and depth 2. Nine folders (depth 0–3, 3–60 entries) matched the share exactly; the root has one extra `.Trash`, which the system creates. 0 skipped entries |
| M4-3 timing | 24 first listings, all `outcome=listed`, longest wait 259.5 ms. See the table below |
| M4-4 app quit | A never-listed folder failed with `first_page action=fail reader=0` and code -1004, 3 attempts in 60 ms. Finder showed "Your device couldn't connect to the server. There may be a problem with the server or network." with Try Again. After relaunch: recovery, then a relist of 15 folders with `changed=0`. Finder did not list the folder for 2 minutes; Try Again listed it in 45 ms. Tombstones stayed 0 |
| M4-5 restarts | `pkill` of the extension, `killall fileproviderd`, `purge`: 4,270 items and 0 tombstones before and after, the same counts in all nine folders, and relist `changed=0` after relaunch |
| M4-6 writes | `touch`, `mkdir`, `mv` and `rm` in the location failed with EPERM. No mutation call reached the extension. The share's folder kept its entry count and mtime |
| M4-7 WAL | A 613-entry listing committed while a new 814-entry folder was paged: no `catalog_unavailable`, no `list_unseen=1`. After a clean quit and an extension kill, the new extension browsed listed folders and answered `fail reader=0` for a never-listed one |
| M4-8 logs | 922 lines checked against 10,638 names from the share and against the host, address, share, account and paths: 0 hits. No `code=-1005`, no `stalled=1`. smbfs mounts 1 throughout, apart from the outage |

| Folder | Entries | Listing, ms | Total, ms | Condition |
| ---: | ---: | ---: | ---: | --- |
| A | 2,001 | 9.9 | 22.0 | first listing, a native walk had read it 1 minute before |
| B | 1,171 | 7.5 | 13.3 | first listing, opened from Finder, native walk 1 minute before |
| C | 881 | 217.0 | 227.6 | first listing, native walk about 4 minutes before |
| A | 2,001 | 361.9 | 379.7 | launch relist |

Reopening folder A in Finder 148 s after its listing made no call to the extension: the system
does not enumerate a materialized folder again, as the plan assumed.

App diagnostics worked from inside the sandbox: `rss_bytes` 35.0 MB (just after `purge`) to
120.6 MB, and `descriptors` 6–9, never 0 or -1.

### M5: reads by item

| Read | Bytes | Result | Times |
| --- | ---: | --- | --- |
| Partial, offset 16 MiB | 16,777,216 | SHA-256 equal | CLI first read 0.884 s; extension transfer 0.135 s |
| Partial, offset 64 MiB | 16,777,216 | SHA-256 equal | 0.837 s; 0.151 s |
| Partial, offset 112 MiB | 16,777,216 | SHA-256 equal | 0.788 s; 0.120 s |
| Finder Download Now | 36,579,203 | SHA-256 equal, `mode=full kind=full` | transfer 0.223 s |
| Finder Download Now (M5-4) | 268,058,156 | complete | transfer 1.400 s |
| Finder Download Now | 1,933,497,667 | complete | transfer 8.722 s |

About 0.7 s of each partial read's time passed outside the extension, which is consistent with
the phase 1 `fileproviderd` flush wait.

- **M5-3 VLC:** each open fetched one 16 MiB demand at offset 0 and one read of the file's tail.
  The first seek fetched one demand range at the new position. With hardware decoding, the
  VM's video decoder failed every 6 s ("ParavirtualizedVideoDecoder … failed"). With software
  decoding, VLC played until the first seek, then its clock froze and later seeks read nothing.
  Another file, opened on the native SMB path with the same flags, froze the same way after two
  seeks, so this is VLC in this VM, as phase 1 found. No VLC thread was waiting on a read.
- **M5-3 IINA:** a 158 MB MP4 streamed with one demand, then sequential misses that each started a
  speculative chain to the end of the file. A 1.68 GB MP4 played in real time with demand reads
  only, two positions interleaved; IINA's own buffer pulled 1.14 GB in about 1.5 minutes. Three
  of the five planned seeks ran, with Jump To (40:00, 1:10:00, 20:00); IINA's on-screen controls
  don't draw in this VM. The 1:10:00 jump passed the end, and IINA moved to the next file in the
  folder, which then streamed with demand reads at its new positions. No speculative read failed, so the seek-cancel check (code 3072 only for the item
  that seeked) has no evidence.
- **M5-3 IINA, 2.74 GB MKV:** see finding 1. The second run, after eviction, streamed correctly
  for 4 s, a demand at IINA's resume point, then sequential misses and speculative chains, until
  `materialize(…) error: materializationFailed` at 00:20:58.654. The kernel request just before
  it asked for a range that two speculative extents, finished 167 ms and 41 ms before, already
  covered. A background
  `fetchContents` of all 2,742,783,442 bytes followed (`system=true`).
- **M5-4 progress:** Finder drew its progress bar and stop button on the file icon, then a
  thumbnail. The download took 1.43 s, too short to see the bar advance. No `stalled=1`.
- **M5-5 app crash:** `kill -9` of the app 3 s into a 2.03 GB download. The extension failed the
  fetch with -1004, Finder showed the server alert, and the file stayed dataless. The relaunch
  logged `staging_removed=1`, then `stage_files=0`.
- **M5-5 extension crash:** `kill -9` of the extension 4 s into a 5.68 GB download. The app
  cancelled its transfer (reply 3072). The new extension logged `temp_removed=0
  temp_stage_files=0` and no sweep failure. The system's retry, 2 ms later, failed with -1004
  (finding 5).
- **M5-6 app quit:** an uncached 4 MiB read failed after 1.58 s with `pread: Operation timed out`
  and returned no bytes. The extension logged `failed stage=app-reader … code=-1004`.
- **M5-7 memory:** two batches of 20 partial reads of 4 MiB, at 40 offsets of the 5.68 GB file, all
  passed.

| RSS | Before | After 20 reads | After 40 reads |
| --- | ---: | ---: | ---: |
| App | 108.3 MiB | 115.0 MiB | 115.0 MiB |
| Extension | 22.9 MiB | 24.2 MiB | 24.2 MiB |

### Outage (D8)

| Time | Event |
| --- | --- |
| 00:34:04 | NAS address blocked; ping to it fails |
| 00:35:16 | An uncached read starts |
| 00:35:27.8 | `state=unresponsive`; the read fails with ETIMEDOUT after 12.1 s, no data |
| 00:35:33.5 onwards | `probe ok=0` every 6.0 s |
| 00:36:05 | A new uncached read is refused in 0.63 s with -1004 |
| 00:36:16 | macOS unmounts the share: `state=notConnected`, `session_ended reason=did_unmount` |
| 00:36:29 | App relaunched during the outage: launch reconciliation, then no session, because there is no mount |
| 00:37:19 | Block removed |
| 00:38:29 | Share reconnected from Finder; macOS showed its dialog with the Keychain password filled in. `session_started` without Select Share (10.9 ms), `recovery`, then relist of 25 folders with `changed=0` in 1.2 s |

The unmount 2 minutes into the block cut two planned cases short: `probe ok=1` while the share is
still mounted, and starting a session while the share is mounted but unreachable.

### Defect fixed

The materialized set includes the system's Trash folder (`NSFileProviderTrashContainerItemIdentifier`),
which is not in the catalog. Every relist tried it and counted a failure (`failed=1`, code 256).
`MaterializedFolders` now skips it. After the fix, a relaunch relisted 25 of 25 folders with
`failed=0`. The extension still answers the system's `item(for:)` on that identifier with
`fileReadUnknown` (logged as `item=other … code=256`); the effect of that is not known.

### Required checks

On 2026-10-15 after the fix: `swift test` ran 121 tests with 0 failures. `swift build -c release`
and `python3 Tools/verify-benchmark.py` passed (local checks only). The unsigned Release
`xcodebuild` and the signed build passed with zero Swift warnings; only the App Intents metadata
notice remained.

## Follow-up, 2026-10-15

The user chose to remove downloaded copies on Remove Location, to find the IINA fallback before M6,
and to change read-ahead. Runs from 01:03 to 01:36 used a bounded capture of the subsystem,
`fileproviderd`, `filecoordinationd` and APFS kernel messages at debug level.

**Remove Location.** It now removes the domain with `.removeAll`, also when launch reconciliation
finishes an interrupted removal. Removing the location with 3 downloaded files (3.9 GiB) left
nothing in CloudStorage, and free space came back.

**Recent-file bookmarks.** When IINA launched, `ScopedBookmarkAgent` made a coordinated read of
the two MP4 files in IINA's recent list. Both started downloading in full about 1 s after launch,
before any file was opened: 1.68 GB and 1.93 GB. With `ScopedBookmarkAgent` in
`NSFileProviderExtensionNonMaterializingProcessNames`, the agent's two reads failed with EPERM and
nothing downloaded. IINA still listed both recent items, and Resume streamed the MKV with partial
reads. Other apps' uses of the agent are untested.

**The race.** Both MKV fallbacks began with a reader fault on a range that `fileproviderd` was
still applying from a just-returned fetch:

- Run 1: IINA read from two positions about 5–10 MB apart. Every miss looked like a seek, so each
  returned 16 MiB and overwrote up to 16 MiB that the other position had already received. A read
  inside such an overwrite, 31 ms after it was returned, failed 30 ms later.
- Run 2: one reader caught up with read-ahead. Its fault straddled the boundary of a chunk returned
  15 ms before; the system had not finished applying it.

Phase 1 saw run 2's case once, in a run that also had a classification bug, and left open whether
a correct reader could trigger it. Run 2 shows it can.

**Read-ahead changes.** The settings are unchanged (16 MiB demand extent and chunk, 128 MiB window,
one speculative fetch, 30 ms gap). Two rules are new:

- A returned range never extends into bytes already delivered, and speculation skips them. A unit
  test replays run 1's 20 offsets: before the change, the second position's returns each rewrote
  up to 16 MiB of delivered data; after it, only bytes the reader asked for again.
- A demand that starts inside a request the system hasn't delivered retires it. In one run the
  system silently dropped a read-ahead request; the reader then overtook it by 16 KiB, and the
  old planner waited for it forever, so the rest of the file had no read-ahead.

The two-position rule proposed earlier was not built. The logs show it would not help: in run 1
one position kept jumping ahead of all delivered data, and the 1.68 GB MP4 was a single reader
that skips 2–17 MB at a time.

| Run, 2026-10-15 | Build | Start | Fetches | Fallback |
| --- | --- | --- | --- | --- |
| 3, 01:04 | `.removeAll` only | resume at 223 MB | 2 full (recent files), 30 partial with read-ahead | 2 recent files downloaded |
| 4, 01:15 | + bookmark opt-out | Resume from the recent list | 30 partial with read-ahead | none |
| 5, 01:26 | + no-rewrite rule | beginning | 25 partial; read-ahead stopped after one dropped request | none |
| 6, 01:31 | + overtake rule | beginning, then 5 jumps | 7 demand or sequential, 23 speculative in the first 75 s; seeks below | none |

In run 6, after the first 75 s, the returned ranges overlapped by at most 64 KiB. Jump To 40:00,
1:05:00, 20:00 and 55:00 each fetched one demand range, in 0.085–0.097 s, and the clock moved on
after each. Over the seeks there were 14 sequential and 74 speculative fetches; 05:00 needed no
fetch. No speculative fetch was in flight at a seek, so none was cancelled. IINA showed video in
run 4; its on-screen controls still don't draw in this VM.

**One position, unchanged path.** A 512 MiB sequential `transfer-bench` read of an uncached MP4
took 9.22 s (58.2 MB/s, one sample, NAS cache unknown). Read-ahead grew with the run, from 2 to
at least 5 chunks ahead, as before: 1 demand, 5 sequential, 31 speculative fetches. For a reader that never goes back, the
new rules never apply, so this is the old code path; phase 1's 77–93 MB/s used a different file and
cache state.

**Checks:** `swift test` ran 124 tests with 0 failures. The release build, `verify-benchmark.py`,
the unsigned Release build (only the two App Intents notices) and the signed build passed.

## Correctness and limits

- One share, one location, healthy NAS apart from the outage. Two locations, nested locations and
  the two-location queue check are M9's.
- Evicting a listed folder could not run. Finder offers Remove Download only when everything below
  is downloaded, and this macOS has no `fileproviderctl evict`. M8's Remove Downloads covers it.
- No first listing came near the 5 s deadline, so the deadline path and `late_listed` are still
  untested on the NAS. The `started` rule (D2) was not tested by a SIGSTOP stall.
- Players: VLC's seeks and both players' picture are unverifiable in this VM (no video output).
  Physical-Mac playback is unverified.
- The VM numbers are relative and single samples; none is a speed claim.

Cleanup: the location was removed. Its 4.9 GiB of preserved copies were deleted, after clearing
their `uchg` flag. The share stayed mounted, the old fixture locations are gone, and pf is
disabled.

## Evidence

Local, gitignored, in `results/m4m5-20261014/`:

- `log-stream.txt`, `log-stream-2.txt`, `log-stream-3.txt`: the subsystem log of all runs.
- `m4-2-counts.txt`, `m4-6-result.txt`, `m5-1-result.txt`: count and checksum results, without
  names.
- `swift-test.log`, `m4m5-checks.txt`, `unsigned-build.log`, `signed-build.log` to
  `signed-build-6.log`: build and test output; the build logs hold local paths.
- `fpd-debug-1.txt` (48 MB, mode 0600): the follow-up's debug capture, including `fileproviderd`
  and `filecoordinationd`. It holds abbreviated file names and process names; never share it.

The helpers are in the ignored `.local/phase2/` (`count.py`, `timed-list.py`, `mutate.sh`,
`m5-reads.py`, `pf-block.sh`, `pf-unblock.sh`). The `fs_usage` trace of the second MKV run, 937 MB with
paths, was summarized by process and then deleted.

## Next step

M6, Keep Downloaded and Pause. The remaining race (a fast reader that catches read-ahead) and
findings 4 and 5 stay open; none blocks M6.
