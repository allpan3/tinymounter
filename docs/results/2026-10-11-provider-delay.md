# Range-read delay: database flush wait and fetch-size tradeoff

Date: 2026-10-11, US/Pacific.

## 1. Outcome

The recurring pause is now correlated with a specific macOS event: after the extension supplies content, `fileproviderd` logs **“Materialization or eviction waiting for flush.”** A database batch timer fires about 0.5–0.6 seconds later, and the blocked POSIX read returns approximately 2–4 ms after “Materialization or eviction completed and flushed.” This occurs with both a local source and the NAS source.

This locates most of the recurring delay **after our fetch callback**, in the system's materialization completion path on this VM. It does not establish that every macOS build behaves this way or that the delay cannot be hidden by better scheduling. No private database or system preference was changed.

Larger returned ranges improve ordinary sequential throughput, with a latency cost:

| Returned extent | Integrated median | Matched native median | Ratio of medians | Median first byte |
| --- | ---: | ---: | ---: | ---: |
| 64 MiB | 69.9 MB/s | 207.5 MB/s | 33.7% | 0.930 s |
| 256 MiB | 141.1 MB/s | 201.5 MB/s | 70.0% | 1.816 s |

Each row comprises five interleaved native/provider pairs reading **256 MiB**, using distinct previously unrequested provider extents. The 90% gate still fails. The earlier 23.1 MB/s result used 16 MiB extents and shorter 64 MiB samples; keep that method/date distinction when comparing results.

[Interactive comparison of throughput and first-byte delay](2026-10-11-range-tradeoff.html).

**The 64/256 MiB builds were diagnostic controls.** Source and signed runtime were restored to the prior 16 MiB preference afterward; this experiment does not ship a new default. A single small read should not silently acquire a 256 MiB download policy. The user's reported Driio rate of 80 MB/s remains an unreplicated comparison from their setup, not a matched competitor benchmark.

## 2. Setup and method

- Same VMPal `macOS VM 1`, macOS 27.0.1 (26A434), Xcode 27, arm64, existing UGREEN/Debian NAS fixture and native SMB mount. Recorded current hardware/OS and SMB settings. No mounts, network, NAS configuration or global daemons changed. The benchmark's managed-file access prompt for the new local test domain was accepted; no broader privacy access was granted.
- Main-app reader and extension remain sandboxed, with the existing restricted File Provider service. Source reads use 1 MiB POSIX buffers and `F_NOCACHE`. Only the provider's preferred extent changed between the 64 and 256 MiB Release builds. Both continue honoring minimum range, runtime alignment, version and EOF constraints.
- NAS fixture size remains 37,605,946,781 bytes. A separate **512 MiB local control** was copied read-only from its first 512 MiB, then selected through the app and exposed as another test domain. It uses the same app reader and staging handoff, with no network dependency during local trials.
- A one-off Python trace reader enables process-local hydration, applies `F_NOCACHE`, and records each 1 MiB `pread` start and duration. Concurrent `log stream --level debug` captures File Provider and prototype messages. Traces diagnose ordering, not clean throughput acceptance; logging and Python allocation can add overhead.
- The trace matches wall-clock log timestamps to each syscall interval. Millisecond log precision limits exact attribution. `read` duration itself uses a monotonic clock.
- Timed five-pair series use the existing Release `transfer-bench`, not the Python trace reader. Lightweight prototype logs, SMB session counters and all sample JSONL are captured. No build, checksum or unrelated test was deliberately run concurrently with either timed series.
- 64 MiB series: sample offsets start at 4 GiB, advancing 256 MiB. 256 MiB series: offsets start at 6 GiB with the same stride. Every provider sample is a miss. Alternating pair order reduces but does not remove cache-order bias. NAS cache remains unknown; native-first samples can warm server pages for the paired provider run.
- RX deltas were about 268.46 MB per 256 MiB sample for both paths, consistent with SMB ingress. These session counters can include unrelated traffic. They do not prove cold physical-disk reads.
- The larger 64/256 MiB sizes extend the initial 1–16 MiB tuning grid solely to measure the cost of amortizing the observed per-fetch wait. No product latency/throughput target was relaxed.

## 3. Data

### System trace

Four local misses, each returning 16 MiB, yielded:

| Read offset | Fetch callback | Logged flush wait | Callback to reader return | Flush-complete to reader return |
| --- | ---: | ---: | ---: | ---: |
| 64 MiB | 7.9 ms | 582 ms | 647 ms | 3.2 ms |
| 80 MiB | 5.8 ms | 598 ms | 648 ms | 3.2 ms |
| 96 MiB | 5.6 ms | 603 ms | 688 ms | 3.7 ms |
| 112 MiB | 6.4 ms | 636 ms | 693 ms | 1.8 ms |

The app's local transfer into staging took 2.8–3.1 ms. The local 64 MiB traced read took 2.76 seconds (24.3 MB/s), despite the fast source.

For four NAS misses starting at 12 GiB, logged flush waits were 622, 585, 512 and 512 ms. Reader returns followed flush completion by 2.0–2.2 ms. The **first** NAS transfer itself took 9.72 seconds; that separate startup/storage/network stall is retained in the evidence and its cause was not isolated. The next three NAS transfer times were 68.8, 70.0 and 71.6 ms. Do not attribute that first long transfer to the database timer.

### Overlapping-reader control

One 128 MiB trial using four concurrent readers of 16 MiB spans achieved **71.1 MB/s NAS-backed** and **112.4 MB/s local-backed**, versus about 24 MB/s for the traced local sequential control. Different access patterns, one trial each: these are directional scheduling controls, not medians or ordinary-player results. The NAS parallel range and local sequential range passed source-to-provider checksums.

### Sequential extent series

All rates are decimal MB/s, in sample order:

| Extent | Native samples | Integrated samples | Integrated first-byte seconds |
| --- | --- | --- | --- |
| 64 MiB | 198.5, 252.6, 207.5, 244.3, 198.3 | 70.73, 66.58, 72.87, 65.42, 69.87 | 0.930, 0.987, 0.826, 0.982, 0.928 |
| 256 MiB | 200.2, 254.6, 194.3, 247.5, 201.5 | 141.14, 127.87, 151.94, 127.35, 149.27 | 1.816, 2.016, 1.673, 2.018, 1.694 |

The 64 MiB series delivers four callbacks per sample; the 256 MiB series delivers one. The latter largely becomes a batch download before the first byte returns. Its 1.67–2.02 second first-byte range leaves little room for a player's decoding/startup work and is not evidence of passing the two-second first-frame target. It also does not satisfy the proposed one-second seek-resume target.

## 4. Correctness and limits

- Original-source SHA-256 matched for the 128 MiB parallel NAS range, the 64 MiB local trace range, and the complete first 256 MiB sample of each larger-extent series. Full digests are in `checksums.json`. Other performance samples are timing/counter checks, not separately hashed.
- Source files were opened read-only. Staging uses exclusive local creation and the existing ownership handoff. No remote mutations occurred.
- The original provider source was compared byte-for-byte against its saved pre-experiment copy after restoring 16 MiB. The signed app was rebuilt and a new local miss verified two 16 MiB callbacks. Existing cached extents were not used to claim restored performance.
- Nine unit tests, Release CLI checks, unsigned/signed Release builds and strict recursive signature verification passed. No Swift compiler warnings; only normal App Intents metadata and signed-extension stripping notices.
- Default sequential NAS performance remains the previously documented baseline until a new policy is implemented and verified. No adaptive prefetch implementation, real-player test, actual disconnection, reboot, physical-Mac benchmark or competitor installation is included here.
- The trace identifies the immediate wait in this workload. It does not show whether a different public download path, metadata model, macOS build, or scheduling policy removes it. No unsupported preference changes, internal database edits or fake materialization flags were used.

## 5. Evidence and reproduction

Private raw evidence: [`results/provider-delay-20261011/`](../../results/provider-delay-20261011/). It contains `trace-read.py`, `parallel-read.py`, `paired-series.py`, per-read timing, system logs, `trace-summary.json`, all paired samples/counters, `summary.json`, checksums, signed build logs/hashes and exact provider-source variants. `provider-before.swift` and `provider-16mib-binary` preserve the starting implementation. The local control and manifest are also there; treat source paths and raw system logs as private.

For tracing, use a fresh provider extent and compare syscall-return timestamps with the callback, flush-wait and flush-complete log events. For throughput, use the Release CLI and interleave native reads over the same source ranges. Rerunning these exact offsets without eviction/recreation measures cached content instead. The dedicated scripts use this VM's private fixture setup and remain ignored rather than becoming production tools.

Validation logs: `.build/delay-swift-test.log`, `.build/delay-release-cli.log`, `.build/delay-verify-benchmark.log`, `.build/delay-unsigned-build.log`; signed variant logs reside beside the evidence. Prior experiment: [app-owned NAS reader](2026-10-10-app-reader.md).

## 6. Next step

**Decision status: proposed experiment, not an implemented product policy.** Test adaptive, bounded read-ahead through the public `NSFileProviderManager.requestDownloadForItem` range API:

1. Keep initial/seek demand small, then recognize sequential *misses* before increasing the speculative window. Compare 64–256 MiB windows with the unchanged sequential reader.
2. Track requested speculative ranges separately, so their callbacks cannot recursively schedule an unbounded whole-file download. Keep transfer concurrency and total speculative bytes bounded; validate the same immutable version throughout.
3. Prioritize a new demand/seek over speculation, and measure both extra fetched bytes and reader latency. Completion of `requestDownload` acknowledges scheduling, not completed hydration.
4. File Provider does not report ordinary cache hits to this extension. Prove how the window advances from observable misses; do not assume we know the player's current position. If this limitation requires continuous whole-file background downloading, present that as a separate product-policy tradeoff.
5. Repeat the matched large sequential test and a real player's start/seek workload. Retain the 90% throughput and latency targets; do not count a warmed local read or cooperative multi-reader benchmark as a pass.

The existing SMB transport is sufficient for this next isolation step. A new SMB dependency would not directly address the observed wait after content handoff.
