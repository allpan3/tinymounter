# Performance and reliability validation plan

This is a proposed experiment, not benchmark results. Research completed 2026-10-10; no transfers were measured. See [architecture.md](architecture.md) for the implementation design and [research.md](research.md) for sources.

## 1. What we need to prove

Determine separately whether throughput is limited by the server/network, the selected SMB transport, local staging, File Provider dispatch/materialization, or the reading application. Throughput and responsiveness are separate criteria: a fast whole-file download can still make a video wait minutes before playing.

User observations, not independently reproduced:

| Scenario | Reported rate |
| --- | ---: |
| Native SMB, cold NAS cache / disk limited | About 190 MB/s |
| Native SMB, hot NAS cache / network limited | About 280 MB/s |
| Mountain Duck integrated mode | About 10–20 MB/s; video freezes until downloaded |
| Driio | About 80 MB/s |

These figures do not establish an Apple API ceiling or identify a competitor's bottleneck. Keep decimal MB/s distinct from MiB/s; 280 MB/s is approximately 267 MiB/s.

## 2. Define every cache state

Record server page cache, Mac SMB/client cache, provider materialization, and local filesystem cache separately. A second read of the integrated path can become a local SSD benchmark; it no longer measures SMB.

- **Remote cold, provider cold:** storage read from NAS, no local provider content. The 190 MB/s observation appears to describe this, but confirm the original test.
- **Remote hot, provider cold:** NAS serves from RAM, but bytes still cross the network and hydrate the provider. This is the important comparison to 280 MB/s.
- **Provider fully materialized:** bytes are local. Compare with equivalent local APFS reads, not network speed.
- **Provider partially materialized:** record exact requested/downloaded extents and test both hits and misses.
- **Offline pinned:** network unavailable, fully downloaded pinned content survives restart.

Use a sufficiently large or rotating dataset, or controlled eviction/recreation of test provider items, to obtain the intended state. Evict only the dedicated clean test files. `F_NOCACHE` can help characterize client caching but does not flush the NAS or prove all caches cold. Record cache state as unknown if it cannot be established; do not label it cold on faith. Server cache dropping/reboots are not part of the default test because they affect unrelated workloads.

## 3. Collect a reproducible baseline

Record hardware/OS builds, app/library commits, compiler configuration, server model/CPU/RAM/storage/filesystem, Samba version, share settings, cable/NIC/switch/link speed, RTT, MTU, and local available disk space. Use the physical Mac for final rate claims; record VM results separately with a native baseline inside the same VM.

Inspect the actual negotiated SMB dialect, signing, encryption, read limits, and multichannel behavior. Use `smbutil statshares -a` and relevant `smbutil multichannel` output for native mounts, along with direct-client instrumentation and NAS counters where available. Mountain Duck documents signing/encryption enabled when supported [M2]. Match security settings between comparisons; do not silently disable protection to reach a number. Keep optional isolated experiments labeled separately.

Use release builds with lightweight signposts. Prepare a large immutable, non-sparse, nontrivially-compressible fixture (e.g. 16–32 GiB, adjusted to RAM/storage), smaller mixed files, a directory with 10,000 entries, and representative videos. Include MP4s with metadata near the beginning and end. Hash fixtures outside timed throughput windows. Use a manifest identifying byte counts and test data; avoid zero-filled files, server-side copy, and APFS cloning being mistaken for a network transfer.

Interleave configurations to reduce thermal/cache-order bias. Run at least five valid repetitions per configuration/cache state and report median, range, and individual samples. Measure steady-state throughput after startup separately from total wall time and time to first byte. Browser/Finder copies and generic disk speed apps are supplemental workloads, not the only baseline.

## 4. Factor the data path

Use the same bytes, read pattern, environment, and cache state for each row where applicable:

| ID | Path | What it isolates |
| --- | --- | --- |
| A | Native mounted SMB → POSIX sequential/range reads → sink | Native network/client baseline |
| B | Native mounted SMB → same-volume APFS staging file | Cost of creating local downloaded content |
| C1 | Local pre-existing fixture → minimal File Provider with clone handoff → reader | Lower bound on provider dispatch/handoff; not a network simulation |
| C2 | Local fixture → matching range writes/staging → File Provider → reader | Provider scheduling plus real staging; local disk contention must be recorded |
| D | Native SMB → staging → File Provider → reader | Integrated path while keeping Apple's SMB client |
| E | Async direct SMB → sink | Direct transport versus A |
| F | Async direct SMB → APFS staging | Direct transport plus local writes versus B |
| G | Async direct SMB → staging → File Provider → reader | Complete alternative implementation versus D |
| H | Fully materialized provider file → reader | Local cached/offline performance |
| I | Mountain Duck integrated / Driio → same readers | Reproduce user experience with exact versions/settings |

For read-to-sink tests, account for client page cache explicitly. A file that fits in Mac memory can otherwise make native SMB appear faster than the network. For provider tests, verify byte ingress and materialization; a cached response invalidates the remote-read comparison. Test POSIX `read`/`pread`, actual Finder copy, and `NSFileCoordinator` access separately. Never compare a coordinated whole-file fetch against a native tiny-range read without labeling the semantic difference.

The harness should output one JSONL record per run: configuration, dataset hash, requested cache state and verification, logical bytes, wire bytes where observable, first-byte latency, total duration, sustained MB/s, CPU, peak RSS, local bytes written, range/request counts, negotiated security, cancellation outcome, and success/hash verification. Later scripts summarize these records; raw runs remain reviewable.

## 5. Instrument the bottlenecks

Correlate monotonic timestamps/request IDs across: reader start, provider callback, metadata lookup, queue wait, connection setup, first SMB byte, last SMB byte, staging completion, callback completion, and reader resumption. Record full-versus-partial callback type, requested/returned extent, concurrency, SMB credits where exposed, retransmits, CPU by process, disk I/O, and temp-file cleanup.

Benchmark signatures and next action:

- **A fast, E slow:** direct transport/auth/security/pipelining issue; File Provider is not involved yet.
- **A/E fast, B/F slow:** local storage/copying/staging bottleneck.
- **B fast, D slow:** investigate provider queueing, extent sizing, file handoff, version lookups, or reading-app semantics. This implicates the integrated path, not automatically an unavoidable OS ceiling.
- **D fast, G slow:** investigate the direct adapter/scheduler or interaction with the provider.
- **D/G fast bulk rate, slow video start:** inspect whole-file fetches, codec access patterns, range alignment and prefetch, and seek priorities.
- **H slow or contacts the server for ordinary cached reads:** investigate local disk/content eviction or unnecessary provider work.
- **Only competitors slow:** still do not infer their internals from one number; compare security and access behavior and report the measured conditions.

A single 64 KiB request waiting 3 ms before the next has a rough request-window ceiling of 22 MB/s. This illustrates how software can leave bandwidth unused; it is not a diagnosis of Mountain Duck. At 280 MB/s, a 1 ms RTT needs roughly 280 kB in flight just to cover propagation, plus pipeline depth to cover processing. Measure actual latencies and negotiated constraints.

## 6. Proposed acceptance targets

These are product gates to validate, not promised measured speeds. Agree on any relaxation explicitly after seeing results.

- Direct transport, if selected: median sustained single-file throughput at least **95% of native SMB** under matched settings/cache state.
- Provider path: target **90% of matched native SMB** for large sequential cold-provider reads, with total hydration time reported alongside sustained rate. At the user's current reference rates, that is about **171 MB/s cold NAS / 252 MB/s hot NAS**. If native rate changes in the actual test, use the contemporaneous ratio.
- If local APFS staging is independently below the target, document that physical bound and stop treating the native-to-sink target as presently achievable on that hardware. Do not hide the gap by silently changing the denominator.
- Media: on the wired reference network, first frame within **2 seconds** and random seek resume within **1 second at p95** over at least 20 seek operations, for each supported tested player/format. No stalls caused by downloading the entire file; log bytes fetched before first frame. A player that forces full materialization is an explicit compatibility limitation, not a passed streaming test.
- Offline: **zero data/hash mismatches** after pinning, disconnect, process restart, and reboot. Uncached ranges fail clearly; they must never be supplied as zeroes. Cached reads should behave like equivalent local APFS reads.
- Resource use: bounded memory independent of total file size, initial transfer-buffer budget ≤256 MiB for one active stream; no staging growth across repeated completed/cancelled runs. Separate RSS for app, extension, helper, and system services.
- Reconnect: repeated ordinary outages recover without deleting/re-adding the domain, duplicate mounts, or stale-success states. Report time from verified server reachability to successful new read.

If the 90% goal fails, inspect the factored controls before building the rest of the product. If the OS integration demonstrably prevents the desired workload after tuning, present the measured tradeoff and retain native automount as an independent mode; do not claim it supplies offline caching.

## 7. Failure and compatibility matrix

Perform disruptive cases only against an isolated fixture/share and within an agreed test scope. Initial work against a real server is read-only.

| Case | Required outcome |
| --- | --- |
| Wi-Fi loss / cable removal mid-range | Completed content remains valid; no sparse holes reported as data; bounded recovery |
| Change route, wake, or reconnect | Stable domain identity; resume/retry against validated version |
| App quit / extension termination / reboot | Pinned files remain accessible; metadata recovers; orphan staging cleaned |
| Disk full while downloading/pinning | Clear error, accurate offline status, no eviction of pinned content to pretend success |
| Server modifies/truncates/replaces file between ranges | Detect supported version changes; fail/refetch rather than knowingly mix versions |
| Server reboot / changed address | Revalidate identity and credentials; no stale-handle reuse |
| Wrong password / revoked read permission | Correct item/domain error; no destructive interpretation as deletion |
| Partial listing / timeout / interrupted pagination | No mass deletions; anchors do not skip changes |
| Rename, case-only rename, Unicode collision | Stable supported identity; explicit collision behavior |
| Symlink, package, xattrs, sparse or very large file | Document supported semantics; no traversal outside configured root |
| Two accounts on one server | Separate credentials and permissions, including pooled sessions |
| Fresh install on macOS 27 | App and extension each get usable local-network access; no reliance on an old permission cache |
| Finder, QSpace, Quick Look, QuickTime, VLC/IINA, POSIX, coordinated read | Distinct callback and playback behavior recorded |

For a read-only first release, remote writes/renames in these tests are made by a separate controlled test actor, not by tinymounter. Future write-mode tests add crash-after-commit, duplicate callback, concurrent external writes, conflict retention, offline safe-save, quota, rename/delete races, and outbox preservation.

## 8. What to build first

Deliver a signed minimal provider and a small `TransferBench` executable capable of A–D plus H. Use an already-connected test share initially, then prove automatic native mount access under the final sandbox/helper arrangement. Add E–G to evaluate the direct SMB candidate. This sequence answers the user's central question early without implementing the full app.

Only then reproduce competitor runs. Documentation research did not require installing an app or accessing NAS credentials. Actual comparison requires a test share/file and installed app versions; Driio's App Store install may require the user's Apple account interaction. Do not treat VM-relative numbers as the final physical-machine result.
