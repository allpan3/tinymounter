# App-owned NAS reader: permission gate cleared, throughput gate fails

Date: 2026-10-10, US/Pacific (raw timestamps extend into October 11 UTC).

## 1. Outcome

The approved one-file experiment now reads the NAS through the enabled File Provider extension. The main app performs source reads using its existing selected-file permission and passes staging ownership through a restricted File Provider service. Both processes remain sandboxed. No broader privacy grant, administrator operation, separate helper or third-party SMB client was required.

NAS checksums, local full/partial downloads, cached reads with the app quit, and reconnection after relaunch passed. **Near-native performance did not pass.** Five paired 64 MiB diagnostic reads produced these medians:

| Preferred returned extent | Native SMB | Integrated reader | Ratio of medians |
| --- | ---: | ---: | ---: |
| 4 MiB | 250.9 MB/s | 6.3 MB/s | 2.5% |
| 16 MiB, confirmation series | 239.5 MB/s | 23.1 MB/s | 9.6% |

The proposed 90% target is unchanged. These short diagnostics locate overhead; they do not substitute for the large-file acceptance series or prove a fixed File Provider ceiling. Earlier 247.2/243.6 MB/s native/staging results excluded File Provider.

## 2. Setup and method

- VMPal `macOS VM 1`, macOS 27.0.1 (26A434), Xcode 27.0, arm64; UGREEN/Debian NAS, existing native SMB 3.1.1 mount. SMB settings were captured again, not changed.
- Same unchanged 37,605,946,781-byte NAS fixture as the earlier experiment. Source descriptors are read-only. No server, mount or network configuration changes.
- Personal Team signed Release app and extension, with team-prefixed shared App Group. The exact current binary hashes and uncommitted source snapshot are in the ignored evidence folder. The initial 4 MiB binary was superseded; its source difference is the returned extent preference. Initial Swift capture warnings were subsequently fixed without changing reader behavior.
- App → shared local staging → exclusive same-volume rename into provider temporary storage → macOS materialization → POSIX reader. No whole-payload XPC serialization and no `fsync` per fetch.
- Each series has five alternating native/provider pairs, each reading 64 MiB in 1 MiB POSIX calls. Every provider sample uses a previously unrequested extent. The 4 MiB series starts at 256 MiB, advancing 128 MiB per pair; the 16 MiB confirmation starts at 320 MiB with the same stride. Extents do not overlap.
- `F_NOCACHE` on the native benchmark, integrated reader and app NAS descriptor. The benchmark enables process-local hydration. This does not flush the NAS or prove a cold server cache. The first 2 GiB had been read in earlier work; server cache remains unknown. Repeated source reads and checksum checks can warm it.
- SMB session RX deltas accompany every paired sample. They were about 67.12–67.14 MB per 64 MiB read, consistent with network ingress rather than a fully cached provider hit. Counters include unrelated session traffic and are not a packet trace.
- An exploratory 16 MiB series at offsets starting at 2 GiB had highly variable native rates and overlapped the short unit-test/build invocation at its start. Its results are retained below. The confirmation series had no concurrent builds, but native variability remained; no samples were discarded from either series.

## 3. Data

All rates are decimal MB/s, in run order.

| Series | Native samples | Integrated samples |
| --- | --- | --- |
| 4 MiB | 248.9, 245.4, 257.4, 250.9, 255.0 | 6.44, 6.33, 6.26, 6.34, 6.32 |
| 16 MiB exploratory | 6.8, 233.3, 184.9, 237.7, 179.6 | 23.69, 22.14, 24.01, 22.76, 23.83 |
| 16 MiB confirmation | 239.5, 245.4, 257.4, 114.8, 116.0 | 23.32, 23.48, 23.07, 22.58, 20.46 |

Exploratory medians: 184.9 MB/s native and 23.7 MB/s integrated. The reason for the slow native outlier and later variability was not isolated. Do not interpret a ratio as a physical-machine guarantee.

The trace records 80 callbacks for the five 4 MiB samples and 20 for each 16 MiB series. Median times:

| Series | App transfer into staging | Extension callback before handoff | Residual interval between consecutive completions |
| --- | ---: | ---: | ---: |
| 4 MiB | 19.7 ms | 31.1 ms | 637.8 ms |
| 16 MiB confirmation | 75.0 ms | 88.0 ms | 649.0 ms |

The residual is completion-to-completion wall time minus the later callback duration. It includes reader work, OS materialization/dispatch and any inter-sample gap; it is **not** a direct measurement of one OS subsystem. Most successive completions are within a sample. The observed pattern supports investigating that interval, while larger extents amortize it. It does not show that XPC, SMB transport, or the API alone imposes the limit.

A separate two-read control with 16 MiB extents measured 20.0 MB/s with reader `F_NOCACHE` and 20.6 MB/s without it. The app's NAS descriptor retained `F_NOCACHE` in both. This small control did not remove the gap; it is not a full cache-policy benchmark.

## 4. Correctness and limits

- First NAS smoke: 8 MiB at offset 64 MiB, SHA-256 matched the original source (`f84118cb…629724b`). It used two 4 MiB fetches. Initial setup/connection latency made it slower than the repeated series; it is not included in those medians.
- New 32 MiB local fixture: a nonzero-offset partial read matched, then **Keep Downloaded** triggered a full callback. Whole-file SHA-256: `8ec91eab833c876b4af6586e04e67710631a5a8a38d6c69f5a9df0bb1dddc08c`.
- With the app process quit, that full local file and the already-fetched NAS smoke range still matched, without enabling automatic hydration.
- An uncached NAS read at offset 8 GiB failed promptly with `pread: Operation timed out` while the app was closed; no successful zero-filled result was reported. A read immediately after launch also failed before the reader connected. After connection, the same range succeeded and its 1 MiB checksum matched the source. The domain was not removed/recreated.
- The app now uses a preferred 16 MiB extent. Small seeks may download more than requested. Full fetches exist, but a whole 37.6 GB NAS download and actual player playback were not tested.
- Cached reads with the app closed are not an actual network-disconnect, eviction-pressure or reboot test. Those remain open. NAS source-version validation remains strict; this is an immutable-fixture experiment, not remote change tracking.
- Requests and receipts are bounded and validated; peers are restricted by File Provider service access, same user, signing team and counterpart bundle ID. Expected signed-peer connection was tested. Malicious peers, malformed requests, cancellation races and crash-orphan cleanup were not exercised. Ordinary lease cleanup is implemented; long-duration staging growth is unverified.
- App transfer progress reaches the extension only on completion. The extension's 300-second wait is a prototype timeout and cannot cancel a blocked kernel SMB read. App-independent downloads and production lifecycle remain unresolved.
- Nine unit tests, Release CLI checks, unsigned and signed Release builds passed. No new Swift warnings remain; only App Intents metadata notices and the signed embedded-binary strip notice appear. `codesign --verify --deep --strict` passed.

## 5. Evidence and reproduction

Private raw evidence: [`results/provider-reader-20261010/`](../../results/provider-reader-20261010/). It includes `manifest.json`, all series JSONL and SMB counters, fetch logs, `summary.json`, lifecycle/checksum records, binary hashes, source snapshots, and the local `run-series.py`. Paths/server details are private; sanitize before sharing. Build/check logs are `.build/reader-*.log`.

To reproduce, keep the signed app open, wait for its reader connection, and use `transfer-bench --allow-hydration --no-cache --offset … --length 67108864` against a **fresh uncached extent** of the selected provider fixture. Interleave native reads of that exact source range, capture SMB counters and provider logs, and alternate order. Reusing these already downloaded offsets measures a different cache state. To reproduce 4 MiB, change only the provider's preferred extent and rebuild; the current source uses 16 MiB. The one-off runner contains this VM's private paths and is intentionally not a general shipped tool.

## 6. Next step

Keep File Provider and the proven app-owned read route for attribution. Instrument reader resumption and system dispatch around the callback boundary, compare sequential/full-fetch behavior and further extent/prefetch policies against seek responsiveness, and test a real player. The byte-transfer layer is fast over these short ranges, but total integrated reads are not. Do not build directory browsing, uploads or automount on the assumption that the throughput gate has passed. A direct SMB dependency and a separate background helper remain separate decisions.
