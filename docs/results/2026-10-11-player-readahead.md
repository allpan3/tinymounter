# Player launch paths and bounded read-ahead

Date: 2026-10-11, US/Pacific. Same VMPal `macOS VM 1`, macOS 27.0.1 (26A434), Xcode 27, arm64,
native SMB share and app-owned reader as the [cache-state results](2026-10-11-cache-states.md).

## 1. Outcome

**Finder forces a whole-file download before any player gets the file.** Double-click, Open With
and Cmd-O in Finder each produced exactly one full fetch of an uncached 2.74 GB MKV. The extension
log marks it `isFileViewerRequest = true`, and `fileproviderd` names the requester:
`coordination(… by: name=Finder … isPOSIX=0)`. Finder makes a coordinated read itself, before
LaunchServices hands the file to VLC. Apple documents that coordinated reads request the entire
file. The same VLC streams with partial fetches when Finder isn't involved (`open -a VLC` or VLC's
own File > Open). Read-ahead can't change this, because the full request comes before the player.

**The one documented opt-out doesn't help.** With `NSFileProviderExtensionNonMaterializingProcessNames
= ["Finder"]`, Finder's coordinated read failed at once with `EPERM`, nothing was fetched, and
Finder silently didn't open the file. No alert appeared. The setting was rejected and removed.

**QuickTime Player always materializes the whole file.** `open -a` and its own File > Open each
produced one full fetch of a 3.26 GB MP4 before the document appeared.

**Bounded read-ahead raises sequential partial reads from 23.4 to 148.8 MB/s, but the 90% gate
still fails.** With 64 MiB chunks and a window of up to 1 GiB, five 2 GiB pairs measured 148.8 MB/s
against 249.4 MB/s native SMB (59.7%), with 1.49× bytes fetched per byte read. Five 512 MiB pairs
measured 101.2 MB/s against 224.4 MB/s (45.1%). The unchanged 16 MiB baseline measured 23.4 MB/s
against 245.3 MB/s (9.6%). Full downloads are unaffected.

**The user then asked for seeks to take priority; the prototype now uses seek-first settings.**
See the seek follow-up in section 3. Seeks during a sequential stream took 0.23–0.27 s in all 9 trials, against
0.72–1.37 s with the settings above. Long sequential partial reads fell to 77.1 and 93.2 MB/s
(about 30–37% of native), with only 1.02–1.04× bytes fetched per byte read.

**Finder aliases are a free way to combine locations.** An alias to a native SMB folder and an
alias to the File Provider location both open in place in Finder. A video opened through the native
alias was reported playing by VLC about 0.4 s after the click, with VLC already running.

Not established: first-frame time, seek-resume time and playback smoothness. This VM has no audio
output device, and VLC creates no video output here, on native SMB too. Scripted VLC seeks froze
its playback clock on native SMB as well. Player flags below show when the player reported it was
playing, not when a frame appeared. Physical-Mac playback remains unverified.

## 2. Setup and method

- Fixtures, read-only: an uncached 2.74 GB HEVC/E-AC-3 MKV (test domain `F7D8B0`), a 3.26 GB
  H.264/AAC MP4 with its `moov` box at the start (new domain `CBD42C`), and the existing 35.02 GiB
  MKV (`596FF0`) for sequential series. Each provider copy was evicted with Finder's Remove Download
  before use; a partially downloaded copy first needs Download Now. NAS cache state is unknown for
  every sample here. No NAS, mount or network settings were changed.
- Players: QuickTime Player (built in) and VLC 3.0.24 arm64, downloaded from videolan.org. Its
  SHA-256 matched the published value and Gatekeeper accepted it as notarized Developer ID VideoLAN
  (75GAHG3SZQ). VLC was refused local-network access and metadata retrieval. It was granted access to
  the test domain's managed files when macOS asked; the first run includes that prompt.
- A timeline script polled each player's AppleScript `playing`/`current time` every 0.1 s.
  It also polled the provider file's allocated blocks and captured prototype and `fileproviderd`
  logs. Its polling launched VLC before most runs, so those times exclude a cold VLC launch.
  Click times are a marker written just before the GUI action, accurate to a few hundred
  milliseconds; run 12's marker was invalid.
- Read-ahead (`ReadAheadPlanner`, unit-tested): the first miss and any seek fetch only the 16 MiB
  demand extent. A miss that continues the previous one schedules speculative chunks through
  `NSFileProviderManager.requestDownloadForItem(withIdentifier:requestedRange:)`, one 64 MiB chunk in
  flight at a time. Speculation stops at a limit set by that demand miss: the window equals the bytes
  read so far in the run, at least one chunk and at most 1 GiB. Speculative completions never move
  the limit, so they can't schedule themselves indefinitely. A seek makes earlier requests stale and
  cancels any speculative fetch the extension is running.
- Sequential series: the Release `transfer-bench`, 1 MiB `pread`s with `F_NOCACHE`, alternating
  native/provider order, fresh provider extents, SMB session counters, and fetch logs. Bytes fetched
  per sample come from the extension's own callback log.

## 3. Data

### Launch paths

Times are seconds after the click marker, or after the fetch request for runs without one.

| Run | Opened with | Fetch | Callback | Player has file |
| --- | --- | --- | ---: | --- |
| 01 | Finder double-click → VLC | full 2,742,783,442 B | 11.97 s | 12.5 s after request; then the access prompt |
| 03 | Finder Open With → VLC | full | 11.41 s | playing 11.6 s after request |
| 04 | Finder Cmd-O → VLC | full | 21.28 s | playing 21.7 s after request |
| 08 | Finder double-click → VLC, current build | full, `viewer=true` | 11.77 s | playing 14.0 s after click |
| 02 | `open -a VLC` | 16 MiB @ 0 + 118,226 B tail | 0.11 / 0.01 s | playing 2.4 s after `open` |
| 05 | VLC File > Open | 16 MiB @ 0 + same tail | 0.12 / 0.01 s | playing 1.7 s after click |
| 06 | `open -a "QuickTime Player"` | full 3,263,640,367 B | 18.76 s | document 19.5 s after `open` |
| 07 | QuickTime File > Open | full | 13.67 s | document 15.1 s after click |
| 09 | Finder double-click, Finder non-materializing | none; `EPERM` | — | never opened, no alert |
| 11 | Finder alias → native SMB folder → double-click | native SMB | — | playing ~0.4 s after click |
| 12 | Finder alias → File Provider location → double-click | full, `viewer=true` | 11.81 s | waited for the full download |

During run 05, a scripted VLC seek to about 30 minutes fetched one 16 MiB extent in 0.09 s, and the
system finished materializing it about 0.2 s after the seek. VLC's clock then stopped advancing, as
it also did on native SMB, so seek resumption couldn't be measured. After 40 s of `open -a` playback,
only about 16.9 MB had materialized.

### Sequential reads

All rates are decimal MB/s, in sample order.

| Series | Native samples | Provider samples | Native / provider median | Ratio |
| --- | --- | --- | --- | ---: |
| 16 MiB baseline, 5 × 512 MiB | 245.33, 248.75, 245.49, 244.40, 239.48 | 23.14, 23.54, 23.43, 23.71, 23.27 | 245.33 / 23.43 | 9.6% |
| Read-ahead, 5 × 512 MiB | 249.73, 242.88, 206.69, 224.39, 196.27 | 103.44, 101.24, 100.18, 88.89, 105.85 | 224.39 / 101.24 | 45.1% |
| Read-ahead, 5 × 2 GiB | 249.40, 250.62, 248.55, 254.94, 248.79 | 149.55, 147.00, 147.28, 148.80, 149.69 | 249.40 / 148.80 | 59.7% |

Provider first-byte times: baseline 0.635–0.757 s, read-ahead 0.675–1.235 s. Bytes fetched per
byte read: 1.492 for every 2 GiB sample; 1.72–2.06 for the 512 MiB samples. In the 512 MiB series,
a 2-second pause let speculative tails overlap the next sample. Native samples 2 and 4 show
31.5 MB and 69.2 MB of extra SMB ingress, so that series' native median is pulled down. The 2 GiB
series waited 8 s between samples.

Single diagnostic trials, not series: 32 MiB chunks with a fixed 256 MiB window reached 115.4 MB/s
over 512 MiB; 64 MiB chunks with a fixed 1 GiB window reached 165.0 MB/s over 2 GiB. A third
diagnostic overlapped extents that an earlier series had already downloaded and was discarded.

Per-chunk logs explain the ceiling. A 64 MiB speculative transfer took about 0.27 s (~248 MB/s),
and the next system callback began about 50 ms after completion. The chain therefore runs at about
203 MB/s. Each time the reader reaches the window's end, a demand miss adds the ~0.7–0.8 s
materialization flush wait. Each 2 GiB read had seven demand misses; the six after the first add
about 4 s in total. Reaching 90% would need
both more parallel speculation and windows above 1 GiB, which means more bytes downloaded that a
stopped reader never uses.

### Seeks while read-ahead runs

Scripted 1 MiB `pread`s at fresh offsets of the provider files, not player seeks:

| Case | Samples, seconds |
| --- | --- |
| Seek with nothing in flight | 0.811, 0.743, 0.703, 0.707, 0.728 |
| Seek right after a sequential miss | 0.655, 0.664, 0.695, 0.675, 0.753 |
| Seek from a second thread during a 256 MiB sequential stream | 0.787, 0.718, 0.755, 1.371 |

The extension's cancellation never fired. `fileproviderd` didn't deliver the seek's fetch until
the speculative fetch already running for that file finished. It also ran a speculative chunk the
extension requested after the seek was issued, before delivering the seek. A seek can therefore
wait for one or two speculative chunks, about 0.25–0.45 s each at 64 MiB. Smaller chunks would
shorten that wait and lower sequential throughput.

### Follow-up the same day: seeks first

The user asked that seeks take priority when a player streams an integrated file. Method: three or
two 512 MiB native/provider pairs on the uncached 3.26 GB MP4, and the second-thread seek probe on
the uncached 2.74 GB MKV, five more trials on the MP4 where noted. Each arm started from copies
whose allocated size was verified as 0 bytes. The `dataless` flag stays set on partially downloaded
copies, so it can't prove eviction; a first attempt that relied on it was discarded.

| Read-ahead settings | Provider MB/s, 512 MiB (native) | Fetched per byte read | Seeks during stream, s |
| --- | --- | ---: | --- |
| 64 MiB chunks, ≤ 1 GiB window | 101.40, 100.92, 102.31 (246.27, 252.17, 249.22) | 1.94 | 0.784, 0.811, 0.767, 0.751; earlier 0.787, 0.718, 0.755, 1.371 |
| 16 MiB, ≤ 1 GiB, fixed classification | 119.00 (253.20); later samples overlapped | 2.00 | 0.238, 0.227, 2.579, 0.236; 2.670, 0.259, 0.257, 0.265 |
| 16 MiB, ≤ 128 MiB | 120.22, 120.59 (256.01, 246.14) | 1.25 | 0.240, 0.235, 0.243, 0.246; MP4 0.259, 0.218, 2.671, 2.525, 2.652 |
| **16 MiB, ≤ 128 MiB, 30 ms gap (current)** | 108.15, 72.72 (250.98, 249.29) | 1.09 | 0.259, 0.267, 0.244, 0.251; MP4 0.253, 0.253, 0.226, 0.255, 0.262 |

With the current settings, single 2 GiB reads measured 77.13 MB/s against 255.48 native (MP4) and
93.19 against 251.53 (MKV), fetching 1.016× and 1.039× the bytes read.

**Why seeks waited.** In every slow trial, the seek was never delivered to the extension as its own
fetch while speculative requests kept arriving back to back. `fileproviderd` answered it only after
the chain passed the seek offset, or about 0.1 s after the chain stopped requesting. Smaller
windows don't help, because sequential misses keep extending the chain. A 30 ms pause before each
chained request (demand-triggered requests stay immediate) let every waiting seek through in these
trials. It costs sequential throughput.

**A bug and a system failure, both seen with 16 MiB chunks.** When a reader reached a planned chunk
first, `fileproviderd` delivered the reader's 1 MiB miss at that offset before our request. The
extension matched by offset only, treated it as speculative, returned 1 MiB, and then took the next
miss for a seek. In that run, a reader fault arrived while the previous speculative chunk was still
materializing. `fileproviderd` logged `materializationFailed`, failed the reader's `pread` with
`ETIMEDOUT`, and fell back to a full download of the whole file. Classification now requires the
planned offset and length; a request already covered by a demand is dismissed when it arrives. The
failure didn't recur in the 35 later trials and samples. Whether a correct reader can still trigger
that system race is unknown.

**Trade-off.** The current settings favour seeks and minimal extra download over throughput. They
move the sequential partial-read gate further from 90%: about 30–37% of native, against 59.7% with
the throughput settings. Video playback at typical bitrates needs far less than 77 MB/s, but this
is a scripted reader, not a player. Full downloads and Finder opens are unaffected.

### Follow-up: IINA, Quick Look, and two fixes

IINA 1.5.0 arm64 came from its GitHub release; the SHA-256 matched the published digest and it is
notarized as Developer ID Hechen Li (67CQ77V27R). Quick Look and IINA were then tested on the
evicted 2.74 GB MKV.

- **Quick Look** (Space in Finder) on the uncached video fetched nothing. It showed a generic icon
  and "Zero KB" instead of a preview.
- **IINA's own Open initially fell back to a full download.** IINA reads the last 128 KiB of the
  file. That read started 101,897 bytes before end of file, and macOS passed the range through
  unclipped, past EOF. The extension rejected it as an invalid range three times. `fileproviderd`
  logged `materializationFailed`, and a coordinated full read then downloaded the whole file (11.2 s).
  VLC's tail read had stayed inside the file. Fix: the extension now clips requested ranges at EOF.
- **IINA's sequential reads overlap the previous range by 64 KiB.** The planner treated each such
  miss as a seek, so read-ahead never started. Fix: a miss up to one chunk before the previous end
  counts as sequential.
- After both fixes, IINA streamed with partial reads only: the tail read was served, and read-ahead
  filled about 130 MB/s ahead of the reader. IINA's own buffer read about 486 MB in the first 30 s.
  There were no failures or full-download fallbacks. Four seek probes afterwards took
  0.247–0.266 s, matching the seek-first results above.

The `materializationFailed` seen during the 16 MiB arm above showed no extension error. That one
remains a system-side failure of unknown cause.

## 4. Correctness and limits

- No content was written to the NAS. Every provider fetch validated the immutable source fingerprint.
  Range checksums weren't recomputed in this experiment; the earlier reports verified the same
  staging path.
- Speculative bytes become ordinary evictable File Provider content. After a reader stops, up to one
  window may still download.
- The Finder setting was cleared through the extension, because the shell can't access the
  extension's sandboxed preferences. A one-time build deleted the key at launch; the final build
  doesn't contain that line. Run 12 confirmed Finder's normal full fetch afterwards.
- `requestDownloadForItem`'s completion only acknowledges scheduling. Speculative chunks were
  identified by their offsets in the extension, and `isSystemRequest` was true for each.
- The planner tracks one sequential run per extension instance. That matches the one-file fixture.
  Several files, or several readers of one file, need state per item and reader patterns that
  weren't tested.
- VM limits: no audio device, and no VLC video output. Player times are scripting flags, not frames.
  Physical-Mac playback and network disconnection weren't tested.

## 5. Evidence and reproduction

Private raw evidence, not for sharing:

- `results/player-20261011/`: `observe.py`, `summarize.py`, `seek.py`, and `runs/01–17` with
  timelines and system logs. Runs 13–17 are the Quick Look and IINA follow-up;
  `results/readahead-20261011/overlap-seek*` is the seek check after the fixes.
- `results/readahead-20261011/`: `series.py`, `overfetch.py`, `seek-probe.py`, `seek-probe2.py`,
  the build helper, samples, fetch logs, overfetch summaries, each variant's provider source and
  binary hash, and `provider-before.swift`.
- `results/readahead-20261011/chunk-compare.sh` and the `c64`, `c16`, `c16c`, `c16w128` and
  `c16gap` samples, seek results and fetch logs for the seek follow-up. Discarded runs are in
  `invalid/`: an overlap of already downloaded extents, and a 16 MiB arm started on a copy that
  was only partly evicted.
- `results/alias-20261011/make-alias.swift`, which writes Finder alias files with
  `URL.writeBookmarkData`.

The scratch alias folder is `~/tinymounter-alias-test`. Downloaded VLC installer images and the
local MP4 remuxes were deleted after use.

Checks after the final code: `swift test` (14 tests), Release CLI build and
`Tools/verify-benchmark.py`, and the unsigned Release Xcode build with no Swift warnings. Logs:
`.build/player-*.log`. The signed runtime passed `codesign --verify --deep --strict`.

## 6. Next step

Decision status: proposed.

- Finder double-click on content that isn't downloaded will wait for a full download. That's about
  95% of native speed for a full file, but minutes for very large files. The prototype's 300-second
  reply wait can fail for very large files.
- For media that must start instantly from Finder, use native SMB, as the user suggested, with
  Finder aliases for navigation. The native mode itself stays a later phase, by the user's decision.
  The user wants the synchronization model between native and integrated views designed before
  any overlap guard.
- Read-ahead stays, with the seek-first settings from section 3 that the user asked for. Its
  costs are lower sequential throughput and a small chance of the system materialization race.
  The 30 ms gap is empirical and needs confirming on the physical Mac.
