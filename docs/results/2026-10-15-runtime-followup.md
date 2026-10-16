# Runtime race and recovery follow-up — 2026-10-15

## Outcome

The initial fetch after an extension crash now survives the reader connection window. Three
crash-during-download trials completed and matched the native whole-file SHA-256. The extension
waits only until a shared deadline 5 s after its per-domain reader service starts, with cancellation
checks every 100 ms. An absent app still gives `serverUnreachable`; no missing bytes are invented.

The materialization race is reproducible. A contiguous reader with moving 64 KiB boundaries
failed and triggered a full download in **5/5 trials with the approved 128 MiB window**.
A temporary 16 MiB window had **0/5 failures and 0/5 full downloads**, with all five 1 GiB hashes
matching native SMB. A 64 KiB alignment experiment failed in its first trial and was removed.
The approved 128 MiB window is restored in source and the signed app. A confirmation trial failed
again. This is a stress workload's observed rate, not a real-player failure rate.

A smaller mitigation is installed: after a full handoff, retire pending speculation for that
item/version and cancel its running speculation. The confirmation trial had no further speculative
chain, but still had one system partial fetch after the full fetch, versus nine extra partial
fetches in one baseline trial. This reduces redundant work; it does not prevent the full fallback
or the reader's error. The fallback is still served normally.

Finder's failed-folder error remains unresolved. A supported one-level directory download request
restored all 24 children automatically, but Finder retained its error banner and Try Again.
Further error-resolution signals and a folder metadata update did not clear it. Diagnostic code
was removed; no notification or other recovery UI was added.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434), Xcode 27, signed sandboxed Release
  app and extension. The Finder-mounted SMB share and saved grant were reused. No network,
  mount, server or sandbox settings were changed; no outage was introduced.
- Runs on October 15, approximately 01:46–02:37 US/Pacific. The 2,742,783,442-byte fixture is
  2.55 GiB. The larger fixture was not read. The test location was removed and re-added before
  each race and crash trial. Race samples recorded zero allocated replica bytes before reading.
- NAS cache state is **unknown**; repeated reads were likely warm. Neither server nor client
  cache was flushed. Native checksum reads followed provider reads. These VM diagnostics do not
  establish cold-cache performance, physical-Mac speed or an acceptance-gate result.
- `Tools/reproduce-read-race.py` enables process-local dataless materialization, reads from byte
  24,048 with 65,536-byte calls, and uses 40,000 bytes every 257th call. Reads remain contiguous;
  shorter calls shift subsequent boundaries. Each measured trial requests 1 GiB without delay.
  Successful full ranges or returned prefixes are hashed against the native source.
- Counts come from bounded compact debug captures of the app subsystem and `fileproviderd`.
  Each failed fault produced two `materializationFailed` lines, only one at error severity.
  Tables count error events. `mode=full` counts successful full handoffs, not scheduling requests.
  A 20 s settling interval captures the fallback after read failure. The earliest baseline helper
  lacked settling/counting/prefix verification; its event and full fetch were counted from the
  continuing capture through 02:07:55.
- Run order: fixed-step controls; moving-boundary baseline; 64 KiB alignment; temporary one-chunk
  window; restore 128 MiB and add full-handoff cleanup; crash, timeout and cancellation checks;
  restored-window confirmation. The startup wait was present in the setting comparisons but was
  not exercised: the app was connected before reads. Full-handoff cleanup was absent from those
  comparisons. No compilation ran concurrently with measured reads.
- Temporary comparison changed only the window. Demand extent and speculative chunk stayed
  16 MiB, one speculative fetch remained in flight, and the chain gap stayed 30 ms. The user
  authorized reversible diagnostic comparisons; keeping different settings requires a decision.
- No new macOS privacy prompt appeared during this follow-up.

## Data

### Materialization race

Fixed 64 KiB `pread` controls missed the bug: 0/5 failures and 0/5 full fallbacks, all hashes
matched. Four read 1 GiB and one read 2 GiB; delays were 0, 0, 0.2, 0.5 and 0.35 ms. These are
controls with different workloads, not additional moving-boundary successes.

| Moving-boundary baseline | Returned bytes before errno 60 | Failed events | Full fetches | Prefix hash |
| --- | ---: | ---: | ---: | --- |
| 6, 02:07 | 419,014,144 | 1 | 1 | not retained by initial helper |
| 7, 02:09 | 184,228,480 | 1 | 1 | matched |
| 8, 02:11 | 435,700,288 | 1 | 1 | matched |
| 9, 02:13 | 200,914,624 | 1 | 1 | matched |
| 10, 02:14 | 536,472,512 | 1 | 1 | matched |

Each fault was 65,536 bytes and straddled the start of a just-returned chunk. Faults arrived
26, 31, 30, 25 and 28 ms after the respective returns. The original IINA fault at 00:20:58.628
arrived 15 ms after return, corroborating the same trigger. System logs attribute the resulting
full fetch to `materialization|itemChangedRemotely|backgroundWork`; the extension logs
`system=true viewer=false`.

The 64 KiB-alignment trial returned 50,215,040 bytes before errno 60, then one failed event and
one full fallback; its prefix hash matched. Alignment is not retained.

| Temporary 16 MiB window | Provider read, s | Provider MB/s | Native MB/s | Failed events / full fetches | 1 GiB hash |
| --- | ---: | ---: | ---: | --- | --- |
| 1, 02:26 | 11.579 | 92.73 | 274.41 | 0 / 0 | matched |
| 2, 02:27 | 11.610 | 92.48 | 274.85 | 0 / 0 | matched |
| 3, 02:27 | 10.984 | 97.75 | 270.98 | 0 / 0 | matched |
| 4, 02:28 | 11.052 | 97.15 | 274.29 | 0 / 0 | matched |
| 5, 02:29 | 11.263 | 95.33 | 270.92 | 0 / 0 | matched |
| Median | 11.263 | 95.33 | 274.29 | — | — |

These rates include the helper's read/hash loop and differ from `transfer-bench` methodology.
They compare only this VM with its own native SMB path. The failing baseline cannot supply a
completed-range throughput comparison, so no speed improvement or penalty is established.
Five successes are insufficient to establish that a one-chunk window eliminates the race.

At 02:36 with 128 MiB restored and full-handoff cleanup active, the reader failed after
251,235,200 bytes; the prefix hash matched. There was one failed event and one full handoff
(13.123 s callback, 2.55 GiB). During the 9.2 s observed after that handoff, one extra 16 MiB
system partial fetch was returned as demand; no speculative chain followed. Baseline run 6 had
nine extra partial fetches after its full handoff. This is one cleanup confirmation, not a
statistical estimate of bytes saved.

### Extension startup

The baseline coordinated whole-file read failed with -1004 after `kill -9` during the download.
The new extension started at 01:54:09.601 and failed its retry at .603, before the reader attached.

| Fixed trial | Initial connection wait, ms | Whole coordinated operation, s | Result |
| --- | ---: | ---: | --- |
| 1, 02:31 | 1,027.5 | 18.313 | 2.55 GiB, native hash matched |
| 2, 02:32 | 1,016.8 | 18.318 | 2.55 GiB, native hash matched |
| 3, 02:33 | 1,033.3 | 18.086 | 2.55 GiB, native hash matched |
| Median | 1,027.5 | 18.313 | — |

Each trial killed the extension 3 s after starting the read. Operation time includes the abandoned
transfer, restart, new transfer and checksum. The native whole-file hash was checked separately
at 02:34. These are correctness trials, not download-throughput measurements.

With the app quit at 02:34, a fresh undownloaded file stayed at zero allocated bytes:

- Losing the already-established reader failed with -1004; the coordinated caller took 0.408 s.
- After killing the extension, the new service waited 5,002.2 ms and failed with -1004; total
  caller time was 5.641 s. The accessor never ran.
- A second request after that deadline failed without a new startup wait (0.494 s total).
- At 02:36, cancelling the coordinator after 0.5 s returned Cocoa 3072 in 0.539 s. The new
  service logged a 515.2 ms wait and cancellation, with no staged-content handoff.

### Failed-folder recovery

At 01:56, opening a never-listed folder with the app quit produced three enumeration failures
with `reader=0`, code -1004. Finder showed its connection error and Try Again.

| Supported mechanism tested | Observation |
| --- | --- |
| Existing recovery signal and working-set signal | Finder did not retry the failed enumeration |
| Enumerate pending items, filter folders with download errors | zero matching folders; enumeration was not capped |
| Diagnostic known folder ID, `requestDownloadForItem` with `{NSNotFound, 0}` | scheduled at 01:59:40.075; listing completed at .147 with 24 children; Finder displayed them but retained the error banner |
| Another recovery signal after directory materialization | banner persisted |
| Relist plus folder metadata version update and working-set signal | banner still present at 02:05 |

The installed manager header explicitly ignores individual folder signals for replicated providers;
it requires working-set signaling. `signalErrorResolved` removes throttling, without promising
Finder UI retry. Directory materialization enumerates one level and leaves children dataless.
Reimport can widen to a larger subtree and restart the extension; it is not a targeted banner
reset and was not used. The diagnostic used a known opaque ID because the pending set did not
identify the failure. No persistent failed-folder tracking was added.

## Correctness and limits

No returned data mismatch was found. One early baseline prefix was not checksummed, as recorded
above. Full fallbacks are still verified and handed off under the existing staging contract;
no error was invented to suppress them, no uncached holes were zero-filled, and remote content
remained read-only. Full-handoff cleanup forgets delivered ranges so a later eviction can restart
normal read-ahead. Two unit tests cover pending/running cleanup, late completion, future demand,
and isolation by item/version.

Checks: **126 unit tests passed**, Release CLI build and `verify-benchmark.py` passed, and the
unsigned Release app/extension build passed with only the two accepted App Intents notices and
no Swift compiler warnings. Signed builds passed with the usual signed-binary stripping notice.
No Swift source files or targets were added, so project regeneration was unnecessary.

Unverified: real-player frequency and one-chunk IINA/seek behavior, physical-Mac playback and
speed, recovery under app reconnection delays beyond 5 s, multiple concurrent startup fetches,
and complete automatic clearing of Finder's error banner. Later eviction after full handoff is
unit-tested, not runtime-tested. A full macOS restart and disk-pressure eviction were not run.

Cleanup at 02:41–02:42: the final signed app was relaunched, the test location and its downloaded
copies were removed, and its CloudStorage path no longer existed. App diagnostics reported zero
catalogs, items and staging files. The app remains running with no locations, one SMB mount
remains, pf is disabled, and the diagnostic log capture was stopped. Resume notes were appended
to the shared agent file.

## Evidence

Private, gitignored evidence is in `results/m4m5-followup-20261015/`. Debug captures contain
private system metadata and must never be shared. Build logs redact signing team identifiers.

- `baseline-debug.txt`, `comparison-debug.txt`, `original-race.txt`: timestamped system and
  subsystem evidence; original race corroboration.
- `baseline-1.json` through `baseline-10.json`, `align64-1.json`, `window16-1.json` through
  `window16-5.json`, `restored128-1.json`: numeric run settings, call timings, checksums and counts.
- `crash-baseline-1.txt`, `crash-fixed-1.json` through `crash-fixed-3.json`, `native-full-hash.txt`,
  `startup-negative.json`, `startup-cancel.json`: restart and failure-path evidence.
- `folder-spike/`: removed diagnostic source; `before/`: task-start source snapshots preserving
  pre-existing work. No commits or repository reset operations were performed.
- `swift-test.log`, `release-build.log`, `verify-benchmark.log`, `unsigned-build.log`,
  `signed-final-reviewed.log`: final validation.

Reproduce with a fresh test replica and an already-connected app. Supply the fixture's relative
path in a private local text file. Run `Tools/reproduce-read-race.py` with `--length 1073741824
--io read --short-every 257`, the provider/native roots, `--relative-path-file`, a new `--output`,
`--run`, and a bounded compact `--log` capture containing the subsystem and `fileproviderd`.
Bound the command with `perl -e 'alarm 180; exec @ARGV'`. Remove/re-add the location between
trials and wait for the helper's settling interval before doing so. The helper emits no names or
paths; raw system captures remain private. Local crash/cancellation helpers are in `.local/phase2/`.

## Next step

**Decision status: proposed.** The 16 MiB window is the best candidate found: recommend validating
it with IINA playback/seeks before adopting it. It limits speculative depth and could reduce
sequential speed on other workloads; the approved 128 MiB setting remains in place. Rejecting
the system's full fallback remains risky because the fetch API retries other errors.

No complete supported Finder recovery mechanism was verified. A notification explaining Try
Again is a possible fallback, pending user approval. An Apple Feedback report could document
both system behaviors; none was submitted. Keep the initial connection wait and the bounded
full-handoff cleanup, whose narrower effects were verified here.
