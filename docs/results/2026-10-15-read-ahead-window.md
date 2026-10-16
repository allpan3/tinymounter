# One-chunk read-ahead window — 2026-10-15

## Outcome

The read-ahead window is now **16 MiB**, one chunk, in source and in the signed app. The user
authorized choosing and keeping the setting from this comparison. The other settings are
unchanged: 16 MiB demand extent and chunk, one speculative fetch in flight, 30 ms chain gap.

| Measure, this VM | 128 MiB window | 16 MiB window |
| --- | --- | --- |
| Moving-boundary stress reader, fresh replicas | 5/5 failed with full downloads (earlier today) | **0/11** failed (5 earlier, 6 here) |
| IINA open, 60 s play and 5 seeks | 2/2 clean | 3/3 clean |
| Fetched bytes IINA never read | 287 MB (1 traced trial) | 85 MB (2 traced trials) |
| IINA reads that waited ≥ 0.5 s | 15 (1 traced trial) | 5, 5 |
| 512 MiB sequential read, 1 MiB `pread`s | 76.55, 76.83 MB/s | 105.50, 106.33 MB/s |

IINA played and resumed the same way with both windows. No IINA trial had a full download, a
`materializationFailed` event or a failed fetch, and every cached range matched native SMB.
The one-chunk window fetched less that IINA never read and was faster for a plain sequential
reader. It is the only setting tried that has passed the moving-boundary stress reader. This
supports the choice. It does not prove that the system race can't happen with one chunk.

Not established: picture, first frame and seek-resume time as a viewer sees them, other players,
several readers at a time, other files and NAS cache states, and the physical Mac.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434), Xcode 27. The 128 MiB arm used the
  Personal Team signed Release build left by the runtime follow-up; the 16 MiB arms were built the
  same way. The app was quit and the extension killed before each relaunch. The SMB share stayed mounted by Finder, with the saved grant. No network,
  mount, server or sandbox setting was changed. pf stayed disabled.
- Runs from 04:36 to 05:15 US/Pacific. The arms ran one after the other, not interleaved:
  128 MiB (the build at the start), then 16 MiB, then the final 16 MiB signed build.
- Cache: at 04:36, a native read of the whole 2.55 GiB MKV and the first 640 MiB of each of the
  three MP4s ran at 244.7–285.9 MB/s, so the NAS was probably warm for both arms. No cache was
  flushed. Each measured provider read started on a fresh replica (location removed and added)
  or on a file not yet read in it. Allocated bytes were 0 before every measured read.
- IINA 1.5.0 was driven over mpv's IPC socket, launched with `iina-cli`, `start=0` and no
  resume. Running it this way keeps file names out of the agent's transcript. `iina-cli`
  starts IINA as its child, so IINA inherits the shell's I/O policy, which has dataless
  materialization off; IINA then failed with "unrecognized file format" and no fetch.
  The driver turns materialization on before the launch, as an app from the Dock has it.
- IINA run: wait until the playback clock passes 0.5 s, play 60 s, then seek to 35%, 80%, 15%,
  60% and 5% of the 1:44:58 duration, with 20 s of play after each seek. Each second the driver
  read `time-pos` and `paused-for-cache`. "Clock + 1 s" is the time from the seek command until
  `time-pos` passes the target by 1 s, so it includes 1 s of playback.
- A private `fs_usage` trace of IINA recorded each read of the file and how long it waited.
  It ran for 128-2, 16-1 and 16-2. After each trial, the ranges handed to the system were read
  again through the location and natively, and compared by SHA-256. No fetch ran during that check.
- Sequential: `transfer-bench --length 536870912 --verify --allow-hydration` on two MP4s, then
  the same range natively with `--no-cache`. The seek probe streams a third MP4 with 1 MiB `pread`s
  and, from a second thread after 64 MiB, reads 1 MiB at 50%, 70%, 30% and 90% of the file, 1.5 s
  apart.
- Stress: `Tools/reproduce-read-race.py --length 1073741824 --io read --short-every 257`, as in
  the [runtime follow-up](2026-10-15-runtime-followup.md).
- Counts come from a bounded compact `log stream` of the app subsystem and `fileproviderd` at
  info level, which includes the error-level `materializationFailed` lines.
- Discarded: the first IINA run, whose output file name already existed, and one stress trial
  run on a replica that was not fresh. No privacy prompt appeared.

## Data

### IINA, 2.74 GB MKV

| Trial | Clock start, s | Clock + 1 s per seek, s | Cache pauses | Demand / sequential / speculative | Unique fetched |
| --- | ---: | --- | ---: | --- | ---: |
| 128-1, 04:44 | 1.54 | 1.84, 1.88, 1.13, 1.72, 1.12 | 0 | 7 / 21 / 92 | 1,994,231,250 |
| 128-2, 04:48 | 1.98 | 1.84, 1.82, 1.11, 1.82, 1.14 | 0 | 7 / 20 / 98 | 2,078,592,466 |
| 16-1, 04:55 | 1.88 | 1.88, 1.88, 1.09, 1.77, 1.10 | 0 | 7 / 53 / 53 | 1,876,479,442 |
| 16-2, 04:59 | 2.17 | 1.82, 1.91, 1.13, 1.80, 1.13 | 0 | 7 / 53 / 53 | 1,876,479,442 |
| 16-final, 05:10 | 1.85 | 1.84, 1.88, 1.11, 1.78, 1.09 | 0 | 7 / 53 / 53 | 1,876,479,442 |
| Median, 128 / 16 | 1.76 / 1.88 | equal within 0.1 s at each position | 0 / 0 | — | — |

After every seek the clock advanced 20.1 s in 20 s of play. Each seek's demand fetch took
0.092–0.106 s in the extension in both arms. The seek to 5% landed in cached data and fetched
nothing.

| Traced trial | Read by IINA, unique | Fetched, never read | Reads waiting ≥ 20 ms | Total wait, s | Waits ≥ 0.5 s | Longest, s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 128-2 | 1,791,244,500 | 287,347,966 | 60 | 18.74 | 15 | 0.836 |
| 16-1 | 1,791,244,500 | 85,234,942 | 60 | 16.29 | 5 | 0.803 |
| 16-2 | 1,791,244,500 | 85,234,942 | 60 | 16.66 | 5 | 0.783 |

IINA read the same 2,155,159,281 bytes in the same five regions in all three traced trials.
After each seek, it read 325–363 MB within about 10 s to fill its own cache, so it repeatedly
caught up with read-ahead. With 16 MiB, 54 of the 60 waits were 0.2–0.3 s, about one per reader
miss. With 128 MiB, 25 were about 0.1 s, but 15 were 0.5–0.8 s.

### Scripted reads

| Read | 128 MiB, MB/s (native) | 16 MiB, MB/s (native) |
| --- | --- | --- |
| 512 MiB sequential, MP4 A | 76.55 (231.24) | 105.50 (236.23) |
| 512 MiB sequential, MP4 B | 76.83 (236.08) | 106.33 (232.08) |
| Median | 76.69 (233.66), 32.8% | 105.92 (234.16), 45.2% |
| Seek probe: stream; seeks, s | 51.37; 0.384, 0.352, 0.253, 0.374 | 84.28; 0.228, 0.379 |

At 128 MiB, a 512 MiB read used 1 demand, 5 sequential and 27–29 speculative fetches; at 16 MiB,
1 demand, 16 sequential and 16 speculative. Speculation was requested one chunk at a time
after a 30 ms gap. The cause of the speed difference was not traced. The 16 MiB probe's stream
finished before its last two seeks. These are single samples per file, not a performance series.

| Stress trial, 16 MiB | Provider read, s | Provider MB/s | Native MB/s | Failed events / full fetches | 1 GiB hash |
| --- | ---: | ---: | ---: | --- | --- |
| 7, 05:05 | 11.014 | 97.49 | 275.24 | 0 / 0 | matched |
| 8, 05:05 | 10.979 | 97.80 | 275.73 | 0 / 0 | matched |
| 9, 05:06 | 11.246 | 95.47 | 274.63 | 0 / 0 | matched |
| 10, 05:07 | 11.029 | 97.36 | 274.25 | 0 / 0 | matched |
| 11, 05:08 | 10.984 | 97.76 | 277.59 | 0 / 0 | matched |
| 12, 05:14, final build | 11.309 | 94.95 | 274.37 | 0 / 0 | matched |
| Median | 11.022 | 97.43 | 274.94 | — | — |

Each trial had 65 partial fetches. With the earlier 0/5, the one-chunk window has 0/11 failures.
The 128 MiB baseline failed 5/5 and its confirmation 1/1, earlier the same day. The stress
helper's rate includes hashing and differs from `transfer-bench`.

## Correctness and limits

No mismatch: every IINA trial's cached ranges, all four sequential pairs, both probe streams and
all six stress reads matched native SHA-256. No full fetch, `materializationFailed` event,
failed fetch or unscheduled request appeared in any measured run. No hole was filled and nothing
was written on the share.

- Why one chunk avoids the race is not proven. The stress reader never caught a speculative
  chunk the system was still applying, but the race is a system behaviour, not ours.
- After a reader stops, up to 16 MiB can still download, instead of up to 128 MiB.
- IINA was launched by `iina-cli` with materialization turned on, not from the Dock or its own
  File > Open. The VM showed the playback clock only; picture and sound were not checked.
- One IINA file, one share and one reader at a time; two items' read-ahead sharing the domain's
  two fetch slots was not tested. Neither VLC nor QuickTime Player was rerun.
- Throughput may compare differently on the physical Mac or a slower NAS; repeat there.

Checks after the change: `swift test` ran 127 tests with 0 failures, including a new test that
a one-chunk window keeps one chunk ahead. `swift build -c release` and
`python3 Tools/verify-benchmark.py` passed. The unsigned Release `xcodebuild` passed with only
the two accepted App Intents notices. The final signed build passed `codesign --verify --deep
--strict`. No files or targets were added, so the project was not regenerated.

Cleanup at 05:15: the test location and its downloaded copies were removed, and its CloudStorage
folder is gone. The app is running with no locations, one SMB mount remains, pf is disabled,
and the log capture, IINA and helpers are stopped.

## Evidence

Private, gitignored, in `results/window-iina-20261015/`:

- `capture.txt` (mode 0600): the system and subsystem log. It holds private system metadata;
  never share it.
- `iina-*.json`, `.counts`, `.verify`, `.reads`: IPC samples, fetch counts, range checksums and
  IINA's read ranges and waits. The raw `fs_usage` traces held paths and were deleted after
  summarizing.
- `seq-*-provider.jsonl`, `seq-*-native.jsonl`, `probe-*.json`, `race16-*.json`: scripted runs.
- `swift-test.log`, `release-build.log`, `verify-benchmark.log`, `unsigned-build.log`,
  `signed-16.log`, `signed-final.log`; `before/`: copies of the changed files from the start.

The helpers are in the ignored `.local/phase2/`: `iina-run.py`, `iina-trial.sh`,
`window-count.py`, `verify-ranges.py`, `fsu-reads.py`, `reads-summary.py`, `seq-pair.sh`,
`seek-probe.py`, `race-trial.sh` and `alloc.py`. They print numbers only. Run `fs_usage -w -f
filesys IINA` as root into a 0600 file for the read trace.

## Next step

None for read-ahead before M6. Repeat the IINA run and the sequential pairs on the physical Mac
when it is available. Finder's retained folder error stays open, as in the runtime follow-up.
