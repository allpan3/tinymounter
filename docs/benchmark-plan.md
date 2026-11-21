# Performance and reliability validation plan

This document defines the proposed validation program. Full-download medians exceed 90% of native in both verified NAS cache states; the complete sequential range-read, latency and reliability gates have not passed. See [architecture.md](architecture.md) for the implementation design and [research.md](research.md) for sources.

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

Record server page cache, Mac SMB/client cache, provider materialization, and local filesystem cache separately. A second read of the File Provider path can become a local SSD benchmark; it no longer measures SMB.

- **Remote cold, provider cold:** storage read from NAS, no local provider content. The 190 MB/s observation appears to describe this, but confirm the original test.
- **Remote hot, provider cold:** NAS serves from RAM, but bytes still cross the network and hydrate the provider. This is the important comparison to 280 MB/s.
- **Provider fully materialized:** bytes are local. Compare with equivalent local APFS reads, not network speed.
- **Provider partially materialized:** record exact requested/downloaded extents and test both hits and misses.
- **Offline pinned:** network unavailable, fully downloaded pinned content survives restart.

The user requires separate NAS-cold and NAS-cached measurements before adaptive work. Their NAS has 64 GB RAM, enough to hold both current fixtures. Use server-side residency and physical-disk counters to verify those states; rates alone cannot distinguish them. For the explicitly approved 2.55 GiB fixture only, `POSIX_FADV_DONTNEED` through a read-only NAS descriptor can request page-cache eviction; require `fincore` to report zero resident pages before a cold sample. Warm that file with a local NAS read and require every page resident before a hot sample. Capture physical `sda`/`sdb` read counters before and after, avoiding double-counting md/LVM devices. Confirm cold reads reach the disks and hot runs have negligible physical data reads; retain measured deltas and unrelated-activity limitations. This controls Linux page cache, not a disk drive's internal cache. Do not use global `drop_caches` or extend eviction to other files. For naturally uncached alternatives, verify residency first; using a different movie alone does not prove a cold cache.

Use a sufficiently large or rotating dataset, or controlled eviction/recreation of test provider items, to obtain the intended state. Evict only the dedicated clean test files. `F_NOCACHE` can help characterize client caching but does not flush the NAS or prove all caches cold. Record cache state as unknown if it cannot be established; do not label it cold on faith. Server cache dropping/reboots are not part of the default test because they affect unrelated workloads.

## 3. Collect a reproducible baseline

Record hardware/OS builds, app/library commits, compiler configuration, server model/CPU/RAM/storage/filesystem, Samba version, share settings, cable/NIC/switch/link speed, RTT, MTU, and local available disk space. Use the physical Mac for final rate claims; record VM results separately with a native baseline inside the same VM.

Inspect the actual negotiated SMB dialect, signing, encryption, read limits, and multichannel behavior. Use `smbutil statshares -a` and relevant `smbutil multichannel` output for native mounts, along with direct-client instrumentation and NAS counters where available. Mountain Duck documents signing/encryption enabled when supported [M2]. Match security settings between comparisons; do not silently disable protection to reach a number. Keep optional isolated experiments labeled separately.

Use release builds with lightweight signposts. Prepare a large immutable, non-sparse, nontrivially-compressible fixture (e.g. 16–32 GiB, adjusted to RAM/storage), smaller mixed files, a directory with 10,000 entries, and representative videos. Include MP4s with metadata near the beginning and end. Hash fixtures outside timed throughput windows. Use a manifest identifying byte counts and test data; avoid zero-filled files, server-side copy, and APFS cloning being mistaken for a network transfer.

Interleave configurations to reduce thermal/cache-order bias. Run at least five valid repetitions per configuration/cache state and report median, range, and individual samples. Measure steady-state throughput after startup separately from total wall time and time to first byte. Browser/Finder copies and generic disk speed apps are supplemental workloads, not the only baseline.

### Fixed regression set during implementation

Use this set at integration checkpoints. Compare a reproducible earlier
signed Release build, the current read-only location and the current writable location in the
same VM, with separate state and matched native controls. Reuse `transfer-bench`,
`Tools/run-native-series.py` for native sink/staging pairs, and the existing provider measurement
runner. Extend those tools only for missing observations; do not build another benchmark system.

| Case | Fixed comparison and observations |
| --- | --- |
| Full download | Same 2 GiB non-sparse random file; coordinated whole-file read after verified provider eviction; native sink and APFS staging controls; five interleaved rounds; complete hashes outside timing; SMB ingress, callback and native-transfer time |
| Partial read and seek | Same 3 GiB file; 512 MiB sequential POSIX reads from fresh extents, plus seeks that overlap observed read-ahead; matched native ranges; five throughput rounds; first-byte latency, fetched/requested bytes, returned extents and full-download fallback |
| Fully local read | Same completely downloaded 2 GiB file and local APFS clone; hydration disabled, hashes verified, `F_NOCACHE`, no cache flush; five alternating-order rounds; fetch callbacks and SMB counters |
| Finder organization | Create and initially name a folder, rename/move an ordinary file and populated folder, then relist both parents; record callback-to-visible completion, collisions, IDs, downloaded bytes, keeps and an untouched neighbor |
| Saves and retry | Repeated TextEdit saves, reconnect retry and one interrupted write; verify the final server hash, retained pending local contents, IDs, keeps and accurate status |

Run workflow cases only through supported or explicitly gated candidate capabilities on the
disposable fixture. Record unavailable actions instead of counting adapter checks as Finder
success. Add permanent deletion to the organization case once its provider/UI gate passes.
These workflow checks complement throughput samples; they are not statistical latency claims.

Writable and read-only locations share the same metadata-checked read path. Record network
bytes and provider materialization separately; a local cache hit is not an SMB throughput sample.

The direct SMB client emits `direct_read` with request ID, payload bytes, completion phase and
total time. Native SMB session counters do not count those reads, so they alone cannot judge this
transport. The runner follows completed direct reads, including claimed prefetches, back to
the selected provider’s callbacks. Use server traffic counters as an independent check.
On the encrypted Samba VM fixture, writable full downloads met the provider target. A fully
downloaded copy read at a rate comparable to its local APFS clone, with hydration disabled
and hashes verified. With overlapping SMB reads, the signed writable candidate exceeded 90%
of native for fresh 512 MiB reads with both cold and warm Samba file pages. On November 21,
2026, the read-only location reached 212 versus 226 MB/s cold (94%) and 201 versus 240 MB/s
warm (84%). Each rate is the median of five reads against the normal encrypted native mount.
The median wait for the first 1 MiB was 0.63 seconds cold and 0.66 seconds warm.
After that read, the read-only medians were 282 MB/s cold and 270 MB/s warm. All ten
provider ranges matched their server hashes. The physical Mac needs its own comparison.

For a partial-read comparison, verify server residency before each reader runs, including
the bytes it can prefetch beyond the timed range. Report the native and provider rates
alongside their ratio. Measure the first read separately and correlate subsequent stalls at
extent boundaries with the extension handoff and the application's return from `pread`.
To isolate SMB session setup, read the same extents into APFS staging with one login per extent
and again with one login for the file. Reopen and validate the handles in both cases. To isolate
overlapping SMB requests, hold the session policy and staging write size fixed. Record the
negotiated cipher for each native mount and retain the normal native mount as the release control.

Keep setup, security settings, run order and all four cache states with the samples. A single
pilot can identify a delay to investigate, but cannot establish a regression. Separate changes
against the earlier build from unresolved original targets, including sequential throughput,
local APFS parity and media latency. This set does not replace the larger acceptance fixtures,
20-seek p95 requirement or physical-Mac validation below, and it changes no target or denominator.

### Ordinary SMB follow-up

Use the existing release benchmark and provider helper in the VM. Compare full downloads,
512 MiB fresh partial ranges and fully local reads against the same VM's native controls.
Use five alternating-order pairs; verify hashes outside timing and record provider allocation,
returned extents, callback time and `direct_read` bytes. The save comparison uses
`Tools/check-smb-saves.py` and the production Swift overwrite path at 1 and 64 MiB. Connection
setup is reported separately from write/size/flush/close; neither is editor Save latency.

Writable and read-only locations now use the same metadata-checked read path. No edit-base,
block-proof or whole-file-verification warmup is needed. After a save, evict only clean test
contents before measuring network reads. Native session counters exclude the direct SMB client;
use request diagnostics or independent server counters for its traffic.

Correctness cases include ordinary competing writes, shorter/empty saves, offline retention,
mid-write disconnection, app/provider restart and automatic retry. Verify complete local bytes
before retry and exact remote bytes afterwards. Partial remote contents are an accepted failed-write
outcome. Do not count a queued callback or local Save as successful server completion.

The earlier proof-cache experiments are not requirements for the simplified implementation. All cache-state and physical-Mac qualifications above still
apply; this change does not relax throughput targets.

## 4. Factor the data path

Use the same bytes, read pattern, environment, and cache state for each row where applicable:

| ID | Path | What it isolates |
| --- | --- | --- |
| A | Native mounted SMB → POSIX sequential/range reads → sink | Native network/client baseline |
| B | Native mounted SMB → same-volume APFS staging file | Cost of creating local downloaded content |
| C1 | Local pre-existing fixture → minimal File Provider with clone handoff → reader | Lower bound on provider dispatch/handoff; not a network simulation |
| C2 | Local fixture → matching range writes/staging → File Provider → reader | Provider scheduling plus real staging; local disk contention must be recorded |
| D | Native SMB → staging → File Provider → reader | File Provider path while keeping Apple's SMB client |
| E | Async direct SMB → sink | Direct transport versus A |
| F | Async direct SMB → APFS staging | Direct transport plus local writes versus B |
| G | Async direct SMB → staging → File Provider → reader | Complete alternative implementation versus D |
| H | Fully materialized provider file → reader | Local cached/offline performance |
| I | Mountain Duck integrated / Driio → same readers | Reproduce user experience with exact versions/settings |

For read-to-sink tests, account for client page cache explicitly. A file that fits in Mac memory can otherwise make native SMB appear faster than the network. For provider tests, verify byte ingress and materialization; a cached response invalidates the remote-read comparison. Test POSIX `read`/`pread`, actual Finder copy, and `NSFileCoordinator` access separately. Never compare a coordinated whole-file fetch against a native tiny-range read without labeling the semantic difference.

The current CLI's `--allow-hydration` explicitly enables process-local dataless-file downloads and records inherited/effective policy. For an initially local dataless source, the benchmark allows materialization-induced ctime changes while checking identity, size and mtime; the actual NAS source remains strictly validated by the app-owned reader. See [prototype setup](prototype.md). A managed-file privacy prompt must be completed before timed repetitions. Record callback and reader time separately: the first local experiment observed a 7.028 ms callback but a 604.518 ms reader transfer for one 256 KiB miss; this single probe is not a throughput result.

The app-reader diagnostic uses five interleaved native/provider pairs of **64 MiB**, each on a fresh provider extent, with 1 MiB POSIX reads and SMB session RX deltas. It compares 4 MiB and 16 MiB returned extents; the app's NAS descriptor uses `F_NOCACHE`. This deliberately short diagnostic locates the large per-fetch delay; it does not replace the large-file acceptance series or relax the 90% gate. Report all samples, including variable native rates and the exploratory series, and keep server cache state unknown. No concurrent development builds should run during timed series.

The October 11 follow-up separates heavy system tracing from throughput trials. The trace records each `pread` interval and correlates it with fetch completion and macOS's flush events, using a local source as a network-independent control. Temporary 64/256 MiB returned extents use five paired **256 MiB** samples with first-byte latency and ingress counters. These larger diagnostic sizes extend the initial tuning grid without changing the default or acceptance gates. Four-reader trials are labeled cooperative-reader controls, not ordinary sequential/player performance. For read-ahead work, measure downloaded/requested byte amplification and avoid speculative callbacks scheduling further unbounded downloads.

Player launch paths are tested separately from throughput. Evict the provider copy, then open it from Finder (double-click, Open With, Cmd-O), from the player's own File > Open, and with `open -a`. For each, record the fetch mode and bytes, the Finder flag on the request, and when the player reports the file playing. Interleave native-SMB controls. Wait several seconds between read-ahead samples so speculative tails don't overlap the next sample's counters, and report fetched bytes per byte read from the extension's callback log. A seek probe must actually collide with an in-flight speculative fetch, confirmed in the log, before it can claim anything about seek priority. Verify eviction by allocated size before each arm; the `dataless` flag stays set on partially downloaded copies. Space samples so one sample's speculation can't reach the next sample's start, or the planner treats them as one run.

For the user's requested **full-download attribution before adaptive read-ahead**, use the following method. Use a complete immutable NAS file, an evicted clean provider item, and a coordinated read to request full materialization. Time from the coordination request to accessor entry, verify `mode=full` in the extension log, compare app transfer and callback duration, and confirm complete materialization with hydration disabled. The scheduling acknowledgement of a range/download request is not a completion measurement. Interleave five native-to-sink, native-to-staging, and provider full-download runs; retain the first sample even if server-cache warming appears likely. Record an additional large-file control separately from the repeated smaller fixture. Verify original-source and provider hashes outside all timing windows. A pin-triggered full download is an additional behavior check: downloaded and retained are distinct states. These controls explain the cost of full download; they do not substitute for the existing large sequential range-read and media gates.

The harness should output one JSONL record per run: configuration, dataset hash, requested cache state and verification, logical bytes, wire bytes where observable, first-byte latency, total duration, sustained MB/s, CPU, peak RSS, local bytes written, range/request counts, negotiated security, cancellation outcome, and success/hash verification. Later scripts summarize these records; raw runs remain reviewable.

## 5. Instrument the bottlenecks

Correlate monotonic timestamps/request IDs across: reader start, provider callback, metadata lookup, queue wait, connection setup, first SMB byte, last SMB byte, staging completion, callback completion, and reader resumption. Record full-versus-partial callback type, requested/returned extent, concurrency, SMB credits where exposed, retransmits, CPU by process, disk I/O, and temp-file cleanup.

Benchmark signatures and next action:

- **A fast, E slow:** direct transport/auth/security/pipelining issue; File Provider is not involved yet.
- **A/E fast, B/F slow:** local storage/copying/staging bottleneck.
- **B fast, D slow:** investigate provider queueing, extent sizing, file handoff, version lookups, or reading-app semantics. This implicates the File Provider path, not automatically an unavoidable OS ceiling.
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

Use a separate controlled actor for competing remote changes. The accepted write milestones add
crash-after-commit, duplicate callback, concurrent overwrites, offline
retention/retry, quota, rename/delete races and pending local content preservation. Run these only on the disposable
fixture and through capabilities whose safety gates have passed.

## 8. What to build first

Deliver a signed minimal provider and a small `TransferBench` executable capable of A–D plus H. Use an already-connected test share initially, then prove automatic native mount access under the final sandbox/helper arrangement. Add E–G to evaluate the direct SMB candidate. This sequence answers the user's central question early without implementing the full app.

Only then reproduce competitor runs. Documentation research did not require installing an app or accessing NAS credentials. Actual comparison requires a test share/file and installed app versions; Driio's App Store install may require the user's Apple account interaction. Do not treat VM-relative numbers as the final physical-machine result.
