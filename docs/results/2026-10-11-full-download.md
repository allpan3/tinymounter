# Full download versus repeated range fetching — 2026-10-11

## Outcome

The existing full-file path reached **232.3 MB/s median versus 254.5 MB/s native SMB (91.3%)** across five runs on a complete **2.55 GiB** NAS file. Native SMB into local staging reached **247.7 MB/s (97.3%)**. All samples, including the slower first provider transfer, are retained.

A separate **35.02 GiB** control measured **197.4 MB/s native**, **192.8 MB/s staging**, and **190.8 MB/s full download**. This is one run per path, not a repeated acceptance series.

This establishes that this prototype/VM can exceed 90% of native throughput for **complete materialization**. It does not pass the separate sequential range-read or video gates. No adaptive read-ahead, larger default extent, SMB tuning, or production transfer-code change was needed for this result.

The user's requested order is now explicit: attribute the 90% gap first, then investigate adaptive behavior. Opening content prioritizes needed ranges; Download / Keep Downloaded requests the complete file efficiently. The prototype already implements separate full and partial callbacks. File type alone is not a sufficient policy selector.

## Setup and method

- VMPal `macOS VM 1`, arm64, macOS 27.0.1 (26A434), Xcode 27.0. UGREEN NAS running Debian; the exact Samba version, physical hardware/storage configuration and server-cache state remain unknown.
- Existing user-mounted SMB3.1.1 share; negotiated signing algorithm AES-128-GMAC, encryption OFF. No mount, network, global SMB, server, sandbox or credential settings changed.
- Existing signed Release prototype with the approved app-owned source reader, two transfer workers and **16 MiB preferred partial extent**. Full fetch ignores that preference and transfers the complete source using a 1 MiB buffer into one staging file. Binary hashes and source metadata are in the private manifest.
- Small fixture: 2,742,783,442 bytes, an unchanged NAS MKV selected through the app into a dedicated new test domain. Provider allocation was zero and `SF_DATALESS` set before every timed provider sample; Finder's **Remove Download** evicted only this clean test copy between runs. The NAS source was never modified.
- Small run orders (N = native sink, S = staging, F = full provider): **F/N/S, N/S/F, F/S/N, S/N/F, F/N/S**. Source and app-reader descriptors use `F_NOCACHE`; no explicit staging `fsync`. This does not flush the NAS cache. A first-read/warm-cache effect is possible, not proven.
- Native and staging use the existing Release CLI, 1 MiB POSIX reads, complete files. Their rates divide logical bytes by `Transfer.run` time; source open is separately recorded. Full download uses a small optimized Swift `NSFileCoordinator` harness: time starts immediately before coordination and ends when its read accessor is entered. It enables hydration for that process only and restores the inherited policy. The accessor does not scan the local payload.
- Each full sample logs exactly one `mode=full` callback for the whole file, clears `SF_DATALESS`, and allocates the complete logical length (rounded to filesystem blocks). SMB RX increases by approximately the file length. This is actual materialization completion, **not** a download-request acknowledgement or cached-read speed.
- Lightweight prototype logs correlate app transfer, callback completion, and accessor entry. No builds, hashes or unrelated tests were deliberately run concurrently with timing. Aggregate SMB counters cannot exclude unrelated traffic; observed deltas were consistent with the requested payload.
- Large control: 37,605,946,781 bytes, existing movie, run N/S/F. The provider initially contained 4,051,697,664 allocated bytes from earlier range tests. Its full callback nevertheless fetched all 37,605,946,781 bytes again; ingress confirms a complete network transfer. Label this initially partial control separately from the five fully evicted runs.

## Data

Decimal MB/s; seconds for timing columns:

| Run | Native | Staging | Full provider | Full completion s | App transfer s | After callback s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 254.5 | 247.7 | 174.1 | 15.751 | 15.017 | 0.696 |
| 2 | 246.3 | 247.4 | 232.3 | 11.808 | 11.054 | 0.700 |
| 3 | 254.7 | 248.1 | 233.8 | 11.731 | 11.044 | 0.647 |
| 4 | 256.7 | 249.5 | 234.7 | 11.689 | 10.978 | 0.654 |
| 5 | 249.9 | 239.8 | 231.0 | 11.871 | 11.169 | 0.672 |
| Median | 254.5 | 247.7 | 232.3 | 11.808 | 11.054 | 0.672 |

Native range: **246.3–256.7 MB/s**. Staging range: **239.8–249.5 MB/s**. Full provider range: **174.1–234.7 MB/s**. Ratio of throughput medians: **91.3%**; median of paired ratios: **91.8%**. Four of five individual pairs exceed 90%; the first pair does not.

The first provider callback spends **15.017 s in source transfer/staging**, compared with **10.978–11.169 s** in subsequent callbacks. The extra first-run time is inside the app transfer, not an unusually long post-callback wait. These observations do not distinguish NAS caching, storage variability or other transfer-side effects.

Across all five runs:

- App transfer to provider callback completion adds **12–25 ms**.
- Coordination start to callback start adds approximately **12–42 ms**.
- Callback completion to accessor entry adds **647–700 ms**.
- SMB RX per full provider sample is **2,742,994,388–2,743,023,187 bytes**, versus 2,742,783,442 logical bytes.

The trace timestamps have millisecond precision and separate clocks; sub-millisecond conclusions are not supported. The recurring completion wait is consistent with the [earlier OS flush trace](2026-10-11-provider-delay.md); the timing series did not enable that heavy OS debug trace again.

### Large-file control

| Path | MB/s | Seconds |
| --- | ---: | ---: |
| Native SMB | 197.4 | 190.537 |
| SMB into staging | 192.8 | 195.077 |
| Full provider completion | 190.8 | 197.103 |

App transfer: **196.539 s**; provider callback: **196.684 s**; post-callback wait: approximately **0.350 s**. Full-provider/native ratio: **96.7%**. Provider SMB RX: **37,608,822,561 bytes**. Cache state remains unknown; this one ordered control is supporting evidence, not a physical-Mac claim or a five-run median.

### Why small fetches were slow

The native SMB and staging paths remain fast. The problematic sequential test repeatedly waits after small content handoffs. As an explanatory approximation, fetching 16 MiB at 250 MB/s takes **0.067 s**; adding a **0.67 s** handoff wait yields about **23 MB/s** if nothing overlaps. That matches the scale of the previous 16 MiB diagnostic. It is a serial-workload model, not a universal File Provider ceiling.

A full download amortizes that delay over the whole file. Making every open fetch gigabytes would increase startup and seek latency; it would not satisfy the user's two-workload requirement. The next range experiment should test whether supported scheduling can overlap a bounded window with the wait while preserving foreground seek priority.

## Correctness and limits

- Complete SHA-256 hashes of both NAS sources and their fully materialized provider copies match: 2,742,783,442 and 37,605,946,781 bytes. Provider verification ran with hydration disabled, so missing bytes could not be silently fetched. These are representative completed files, not per-run hashes of all five downloads.
- After the timed small-file checksum, a separate Keep Downloaded test evicted only the clean provider copy and clicked the existing app control. It triggered one full callback, received approximately 2.743 GB over SMB, and cleared `SF_DATALESS`. An APFS clone of that completed pinned content also matched the original source's full hash. No actual network disconnect or reboot was performed.
- Required checks passed: nine Swift unit tests, Release CLI checks, and the unsigned Release app build with no Swift warnings. Logs are `.build/full-{swift-test,swift-release,cli-check,unsigned-build}.log`. No production code was changed for this experiment.

- Full-download throughput measures time until local content is available, excluding a subsequent full scan by a consuming application. Earlier range-read figures include a POSIX consumer waiting for each missing extent. These are deliberately different workloads.
- The 300-second XPC reply timeout and completion-only progress remain prototype limitations. A successful large transfer does not establish cancellation, longer transfers or production lifecycle behavior.
- Physical-Mac measurements, real network disconnect/reboot retention, player first-frame/seek tests, concurrent edits, direct SMB and matched competitor tests remain unverified. The general sequential range-read 90% gate is unchanged.
- No conclusion about the internal cause of Mountain Duck's or Driio's reported rates follows from these measurements.

## Evidence and reproduction

Raw local evidence is ignored and contains private paths: `results/provider-full-20261011/`.

- `manifest.json`: fixtures, byte sizes, metadata, cache labels, binary hashes, run order and OS.
- `run.py`, `full-fetch.swift` and `full-fetch`: measurement runner and optimized coordinated-read harness. Compile with `swiftc -O full-fetch.swift -o full-fetch`.
- `round{1…5}-{source,staging,provider}.jsonl`, corresponding `*-record.json`, SMB before/after counters, and `round*-fetch.log`.
- `large1-*`: separate complete large-file control.
- `summarize.py`, `summary.json`: rates and timing decomposition.
- `verify.py`, `checksums.json`: complete original/provider hashes outside timing, hydration disabled.
- `pin-watch.py`, `pin-*`: separate Keep Downloaded behavior check; its monitor-start time includes the human/GUI delay and is not reported as a click-to-completion benchmark.
- [Interactive measurement view](2026-10-11-full-download.html).

To reproduce, select immutable fixtures in the signed app, keep its reader connected, complete managed-file permission prompts before timing, verify the dedicated small provider copy is evicted, and invoke `run.py` with the documented order. Evict only the clean test copy between provider repetitions. Run hashes and pin behavior checks after all timed runs. Do not replace fixtures or edit raw manifests without creating a new dated experiment.

## Next step

The existing SMB/staging/extension path can approach native speed under the cache conditions encountered, while serial range materialization repeatedly exposes the completion wait. The user subsequently confirmed 64 GB of NAS RAM and requires verified disk-backed and NAS-cached comparisons before adaptive work. Both fixtures fit in that RAM, so none of the figures here should be relabeled disk-cold. Read-only SSH telemetry and an approved eviction of only the small test file's page-cache entries will support the next experiment. After cache-controlled attribution, measure bounded read-ahead overlap, wasted bytes, cancellation and real-player startup/seek behavior. Keep explicit full download as a separate throughput path; users should not need to select adaptive modes manually.
