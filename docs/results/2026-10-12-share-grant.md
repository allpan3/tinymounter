# Share grant and Finder spikes — 2026-10-12

## Outcome

M3's saved share-root grant works in the signed, sandboxed app: a depth-2 folder and three child
folders list correctly, and a regular file at depth 4 opens, including after app relaunch. No new
mount or privacy prompt was needed for those operations. Finder presents the two custom actions
according to the republished item's keep state. Materialized-set and idle progress reads work.

**M3 is complete.** Check 6, the regression read, passed on a second attempt on 2026-10-13: a 4
MiB partial read through a fresh fixture location matched the source's SHA-256. The first attempt,
on 2026-10-12, was blocked by a macOS prompt asking to let the test shell read files managed by
the new location; it was declined then. The user allowed that prompt for the second attempt's
location only. The six older fixture locations still fail reads with `versionNoLongerAvailable`,
because their stored versions include `st_dev` (see check 6).

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434), VMPal Tools 0.37. VM identity and
  administrator execution availability were checked; administrator execution was not needed.
- The existing Finder-mounted smbfs share remained connected and read-only. No server, mount,
  network or sandbox settings changed. No protected App Group container was inspected by shell.
- The Personal Team Release app ran from
  `.build/xcode-personal/Build/Products/Release/TinyMounterPrototype.app`.
  The prior agent verified `codesign --verify --deep --strict`. Entitlements included sandbox,
  application groups, app-scope and document-scope bookmarks, user-selected read-only access,
  network client and development `get-task-allow`. Signing identifiers remain private.
- The grant, relaunch and Finder spike checks ran at 09:13–09:21 on 2026-10-12, as recorded by the
  prior agent and the retained log. This follow-up inspected that evidence and attempted check 6
  at 19:11–19:13 on the same date (CLI timestamp: 19:13:00, UTC−07:00).
- Grant sequence: refuse a subfolder, select the share root, check a depth-2 folder, compare the
  four listing counts with native `ls -A | wc -l`, then quit, relaunch and repeat without a panel.
  The file-open check uses `fstat`, not a content read.
- Finder sequence: inspect the fixture context menu, toggle keep in the harness to republish
  `userInfo.keep`, inspect both labels, and invoke Allow Removal. Count Downloads reads the
  materialized set and `globalProgress(for: .downloading)`.
- Regression sequence: Choose Test File… browsed to a regular NAS file, approximately 2.55 GiB
  from Finder's size display, above 32 MiB and distinct from the excluded large fixture. Register
  a fresh location (suffix `5C36D2`), open it in Finder, and attempt a CLI read of 4 MiB at an 8 MiB
  offset with `--allow-hydration --cache-label "M3 regression"`. A bounded subsystem log
  stream ran throughout. Builds ran only after this attempt and cleanup.
- Cache state: the first listing is nominally cold relative to this harness session; NAS cache
  state was unknown. The post-relaunch listing followed the first listing and native counts.
  The new provider file had not been intentionally downloaded; Finder offered Download Now.
  Its allocated size could not be inspected because of privacy permission. No cache was flushed.

## Data

### Checks 1–5: grant, listing, relaunch and privacy

1. Selecting a subfolder was refused with "This folder is not a share. Select the share that you
   connected in Finder." The log recorded `grant_refused code=0`. Selecting the share root
   succeeded. No privacy prompt appeared for this app operation.
2. The first Check Location resolved once (`resolve_ms=1.3`, `stale=0`) and listed all four
   folders. Counts matched the native listings. The depth-4 file open took 4.5 ms and recorded
   `fingerprint_match=1`; total time was 4341.7 ms.
3. After quit and relaunch, the saved grant worked without a panel. One resolution took 3.8 ms,
   `stale=0`; the same counts and depth-4 open passed. Total time was 51.0 ms.
4. The prior agent recorded smbfs mount count 1 before and after, and one idle app directory
   descriptor on the share root (`O_EVTONLY` in the implementation). No mount operation was
   performed during this follow-up; its final mount-count check also returned 1.
5. The prior agent's private-name scan found zero occurrences of the share, host, account,
   folder names or `/Volumes` in the captured subsystem messages. The retained file also contains
   the later fixture errors and spike messages; it is not limited to the initial grant messages.

| Folder index | Entries (both runs and native) | First listing, ms | After relaunch, ms |
| --- | ---: | ---: | ---: |
| 0, depth 2 | 6 | 7.4 | 6.0 |
| 1, child | 24 | 171.7 | 10.0 |
| 2, child | 8 | 11.4 | 5.0 |
| 3, child | 23 | 4134.7 | 11.0 |

These are two different run conditions, each with one sample, not a repeated performance series.
A median across them would conceal the cache and relaunch difference. The 4.1 s first listing
is close to M4's 5 s first-listing wait and requires a timeout/recovery test; no default changed.

### Check 6: regression

**Second attempt, 2026-10-13 01:37, passed.** A new fixture location (suffix `961157`) was made
with Choose Test File… from the 32 MiB local fixture used on 2026-10-10. macOS asked whether "t3"
may access files managed by that location; the user allowed it for that location only. Then
`transfer-bench` read 4 MiB at offset 8 MiB with `--allow-hydration --stage-dir /tmp --verify`:

| Bytes | First read, s | Transfer, s | SHA-256 of the range |
| ---: | ---: | ---: | --- |
| 4194304 | 0.859 | 0.863 | matches the source range (`32f61c6d…`) |

The extension logged one partial demand fetch at offset 8388608 of 16777216 bytes (the 16 MiB
extent), and the app's reader logged the matching 16 MiB transfer. The file then held 16 MiB on
disk. Finder offers Download Now, not Remove Download, for a partly downloaded file, so the
location was removed with Remove Test Location; no folder for it remained in CloudStorage. One
sample, local source, page cache state unknown: this is a correctness check, not a speed number.

**First attempt, 2026-10-12 19:11, blocked.** The initial local-folder inspection prompted for
"t3" to access files managed by the new location. The VMPal command transport independently
prompted for "VMPal Tools". Both were declined. VMPal reported `PermissionError 1`; the CLI then
exited 1 with:

```text
transfer-bench: open source read-only: Operation not permitted
```

| Requested bytes | Offset | CLI bytes metric | transferSeconds | megabytesPerSecond | firstReadSeconds |
| ---: | ---: | --- | --- | --- | --- |
| 4194304 (4 MiB) | 8388608 (8 MiB) | not produced | not produced | not produced | not produced |

The CLI produced no JSON metrics because opening the source failed. The matching bounded log
stream contains only its predicate header: zero subsystem events, so no app-reader or provider
fetch can be correlated. This is an access-blocked check, not a measured zero-byte transfer.

The earlier old-fixture attempts did reach the app. Representative matching lines at 09:17:18:

```text
request=02D3D183-B195-45A9-BB0A-0CAA393437AC failed stage=transfer domain=NSFileProviderErrorDomain code=-2009
request=02D3D183-B195-45A9-BB0A-0CAA393437AC failed stage=app-reader kind=demand domain=NSFileProviderErrorDomain code=-2009
```

`SourceReaderHost` checks `source.snapshot == config.snapshot` at stage `transfer`.
`FileSnapshot` includes device, inode, size, mtime and ctime in equality and `versionData`.
M2 measured device changes across remount, so the old NAS fixture's snapshot rejection is
consistent with that known phase 1 limitation. The local fixture's post-restart mismatch is not
independently isolated. The denied fresh-fixture read cannot establish that device is the only
cause or rule out an M3 regression. No reader or version behavior was changed here. Phase 2's D1
fingerprint omits device and inode; D3 removes old fixture domains before M4.

### Check 7: Finder and materialized-set spikes

- Before an existing fixture was republished, its custom action was absent. After the harness
  toggled keep, Finder showed Allow Removal (`keep=1`) or Keep Downloaded (`keep=0`) as a separate
  item near the bottom of the context menu. The freshly registered follow-up fixture also showed
  Keep Downloaded, consistent with publishing `userInfo` at creation.
- Clicking Allow Removal reached the extension:
  `action=dev.tinymounter.action.allow-removal items=1` at 09:19:31.881. The spike only logs and
  completes; it does not change keep state.
- Finder's own Keep Downloaded was absent. Its standard Remove Download appeared for an existing
  downloaded fixture; Download Now appeared for the new undownloaded fixture.
- Count Downloads returned `materialized=3 folders=2 root=1 progress_total=1 progress_completed=1`
  at 09:19:04.965. The UI showed "Items on this Mac: 3 (2 folders). Download progress: 1 of 1."

### Required checks

On 2026-10-12 after the runtime attempt:

- `swift test`: 89 tests, 0 failures.
- `swift build -c release`: passed.
- `python3 Tools/verify-benchmark.py`: passed, local checks only.
- Unsigned Release `xcodebuild` with `.build/xcode` and `CODE_SIGNING_ALLOWED=NO`: passed, zero
  Swift compiler warnings. Only the two App Intents metadata-extraction notices remained.
- The prior signed build passed with those two notices and the already-signed binary stripping
  notice. It was not rebuilt or reinstalled during this follow-up.

## Correctness and limits

The sandboxed listing checks used a healthy share only. The depth-4 open verifies metadata, not
file contents. Neither the single slow listing nor the denied read supports a throughput claim;
there was no native transfer baseline and no new checksum measurement. VM observations do not
establish physical-Mac behavior. Active download progress, custom-action effects, decoration
behavior, other file managers, playback and offline/reconnect behavior were not tested here.

The new fixture was removed with the harness's Remove Test Location. Finder had no Remove Download
action for it, so that cleanup step was inapplicable. No fetch was logged and no download was
started. The harness reported preserved downloaded files, but a bounded immediate-child scan of
CloudStorage found no remaining path with this test ID. The six pre-existing locations remain.
The log stream was stopped. No NAS content was read by the regression attempt, changed or removed;
the excluded large fixture was never opened. No privacy permission was granted.

## Evidence

Local, gitignored evidence (private screenshots and build logs must be sanitized before sharing):

- [`log-stream.txt`](../../results/m3-20261012/log-stream.txt): grant, both listings, old-fixture
  errors, Count Downloads and the custom-action callback.
- [`signed-build.log`](../../results/m3-20261012/signed-build.log): prior signed Release build.
- [`finder-menu-keep1.png`](../../results/m3-20261012/finder-menu-keep1.png): prior private Finder
  context-menu capture.
- [`regression-attempt.json`](../../results/m3-20261012/regression-attempt.json): timestamp, exit
  code and CLI error, without the file path.
- [`regression-log-stream.txt`](../../results/m3-20261012/regression-log-stream.txt): bounded
  follow-up capture with zero subsystem events.
- [`regression-cleanup.json`](../../results/m3-20261012/regression-cleanup.json): no matching
  remaining CloudStorage entry after removal.
- [`checks-20261012.txt`](../../results/m3-20261012/checks-20261012.txt) and `check-0.log` through
  `check-3.log` in the same directory: commands, exit codes and build/test output.

To reproduce, use the signed harness sequence above on the already mounted share, then a new
fixture and the CLI arguments above. Capture `/usr/bin/log stream` for subsystem
`dev.tinymounter.prototype` with `--style compact --level debug`, with a time limit. Repeating the
CLI through these transports currently needs a managed-files permission decision; do not grant
it under the current instructions.

## Next step

M4, browsing on the catalog. Before it, the six phase 1 fixture locations are removed with
`.removeAll` (D3). M4 should test recovery when a first listing exceeds the 5 s wait. Each new
location raises the managed-files prompt for a test shell; the user decides each one. No gate,
timeout or source-reader behaviour was relaxed in this experiment.
