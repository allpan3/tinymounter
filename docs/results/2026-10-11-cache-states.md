# Verified NAS cache states — 2026-10-11

## Outcome

Complete downloads exceed 90% of matched native SMB in both verified NAS cache conditions on this VM:

| NAS state | Native SMB median | Full provider median | Provider/native |
| --- | ---: | ---: | ---: |
| Linux file cache empty; disk reads verified | 192.7 MB/s | 183.3 MB/s | 95.1% |
| File fully in NAS RAM; no disk reads | 247.2 MB/s | 229.0 MB/s | 92.6% |

Five native/provider pairs per condition, all retained. The same 2.55 GiB file and source reader are used throughout. No adaptive code or new transfer implementation was added.

The user correctly questioned rates above the disk's reported 200 MB/s. Here the higher SMB rates are directly associated with NAS RAM residency and zero physical disk reads. Earlier [full-download results](2026-10-11-full-download.md) remain labeled **NAS cache unknown**; observing residency later cannot retrospectively classify those runs.

A separate local-cache series reads fully downloaded provider content at **3166.2 MB/s median**, with hydration disabled. This is local storage/cache throughput, not an SMB result. Its equivalent local APFS clone reaches 6322.8 MB/s; that local-path gap remains unexplained and is not hidden by the network comparisons.

## Setup and method

- Same VMPal macOS 27.0.1 (26A434) VM, signed Release app/extension and 16 MiB partial preference as the full-download investigation. No production code changed. Native/staging permission design, 1 MiB transfer buffer and 300-second extension timeout are unchanged.
- The user reports **64 GB NAS RAM**; `/proc/meminfo` reports 65,613,488 KiB total. NAS kernel **6.18.15**, Samba **4.17.12-Debian**. The SMB share resolves to ext4 on LVM over a linear md device backed by two data disks (`sda`, `sdb`). SMB3.1.1, AES-128-GMAC signing algorithm, encryption OFF; no SMB/server/network/mount configuration changed.
- Fixture S is the unchanged **2,742,783,442-byte** NAS MKV from the earlier experiment. Its entire rounded page footprint is **2,742,784,000 bytes**. No source contents, names or permissions were modified; identity, size, mtime and ctime stayed unchanged. Ordinary read access may update atime.
- The user authenticated a temporary SSH connection directly in the VM. No password was exposed to the agent or placed in scripts. They explicitly approved evicting page-cache entries of **this file only** before cold samples. No global cache flush, service restart or unrelated-file eviction occurred.
- **Cold preparation:** open the approved NAS file read-only, use `POSIX_FADV_DONTNEED`, and require `fincore` to report **zero resident bytes**. The advice is not assumed to work: observed residency gates each run.
- **Hot preparation:** read that file locally on the NAS, then require **all pages resident**. This warm-up is outside transfer timing. Before/after `/proc/diskstats` snapshots verify actual physical-disk reads during each measured transfer. Count whole `sda`/`sdb` devices only; do not sum their partitions, md and LVM layers again.
- Both native and app-reader NAS descriptors request `F_NOCACHE` on macOS. SMB ingress is recorded in every case. Mac client policy alone does not prove any NAS cache state.
- Each provider test starts with the dedicated clean local copy evicted: zero allocated blocks and `SF_DATALESS` set. The existing pin was allowed to be removed, then Finder **Remove Download** reset only the test copy. Every run logs one full-file callback and clears `SF_DATALESS` before the coordinated accessor runs.
- Native rates use the existing CLI's `Transfer.run` time. Full-provider rates use coordination request to accessor entry, including materialization; subsequent reading of the local file is excluded. These are complete-download controls, not streaming or POSIX range-consumer rates.
- Trial order: **cold1 N/F; warm1 F/N; warm2 N/F; cold2 F/N; cold3 N/F; warm3 F/N; warm4 N/F; cold4 F/N; cold5 N/F; warm5 F/N**. State preparation occurs before every individual transfer, not only before each pair.
- Before the series, a separate native smoke probe measured 191.3 MB/s cold and 245.9 MB/s hot. It is retained separately and excluded from the predeclared five-pair medians.
- Lightweight logs and NAS/SMB counters ran during timing. Our builds, checksums and other tests did not overlap timed transfers. The VM was shared with another client's separate application work; aggregate counters can include unrelated traffic. Exact fixture residency and physical-disk deltas constrain the cache conclusion, but this is not an isolated physical-machine acceptance run.

## Data

Rates are decimal MB/s:

| Pair | Native cold | Provider cold | Native NAS-RAM | Provider NAS-RAM |
| --- | ---: | ---: | ---: | ---: |
| 1 | 192.3 | 180.3 | 248.2 | 229.7 |
| 2 | 193.4 | 183.2 | 247.2 | 223.5 |
| 3 | 192.7 | 183.3 | 246.5 | 229.0 |
| 4 | 192.9 | 183.6 | 245.8 | 224.7 |
| 5 | 192.4 | 185.1 | 251.7 | 231.9 |
| Median | 192.7 | 183.3 | 247.2 | 229.0 |

Cold native range: **192.3–193.4 MB/s**; cold provider: **180.3–185.1 MB/s**. NAS-RAM native range: **245.8–251.7 MB/s**; NAS-RAM provider: **223.5–231.9 MB/s**. Percentages are ratios of medians, not the best pair.

Cache evidence across every run:

- Cold starts: **0 resident bytes**. Physical disk reads: **2,742,784,000–2,742,788,096 bytes**, approximately the full file plus small metadata/other activity.
- Hot starts: **2,742,784,000 resident bytes**, the complete page-rounded file. Physical disk reads: **0 bytes in every run**.
- SMB RX: **2,742,993,964–2,743,727,790 bytes** per transfer; payload traversed the network in both states.
- Provider callback overhead beyond app transfer: **7.2–32.2 ms**. Time from callback completion to coordinated accessor: **620.6–933.1 ms**, median **687.5 ms**. Log timestamp resolution is one millisecond.

### Fully downloaded local content

Five alternating reads of the full provider file and an APFS clone on the same local volume. Both request `F_NOCACHE`; hydration is disabled. No provider fetch callback occurred. The local clone's full checksum matches the original NAS source. This does not flush the guest, host or physical SSD caches.

| Pair | Local APFS control | Fully downloaded provider |
| --- | ---: | ---: |
| 1 | 6687.2 | 3049.7 |
| 2 | 6526.2 | 3166.2 |
| 3 | 6322.8 | 3191.0 |
| 4 | 6183.3 | 3180.3 |
| 5 | 6061.4 | 3152.3 |
| Median | 6322.8 | 3166.2 |

SMB session RX changed by only 148–234,036 bytes per local run, rather than the 2.743 GB payload. These aggregate counters include metadata or other-client traffic, so do not describe them as literally zero network activity. With hydration disabled and no fetch callbacks, the complete reads did not download missing provider data. The approximately twofold local-control difference needs its own investigation before claiming provider cached reads match ordinary APFS speed.

## Correctness and limits

- Full original/provider SHA-256 checksums passed for both the 2.55 GiB and 35.02 GiB fixtures in the preceding experiment. A representative verified-cold download (cold3) and the final NAS-RAM download (warm5) also match Fixture S's original hash, with hydration disabled during verification. These are representative checks, not hashes after every timed sample.
- NAS identity, size, mtime and ctime are checked around each state-preparation/measurement sequence. The app independently checks its stored immutable-source fingerprint.
- Linux file-cache cold is not a claim that a drive's internal cache, controller cache or every metadata cache is empty. Disk counter evidence establishes that file reads reached the block devices. Naturally new files would also require residency verification; a new name alone is insufficient.
- No actual network outage or reboot was induced. Download completion and local readability are verified; disconnected retention/recovery remains a separate gate.
- This validates complete-file download throughput against matched native reads on this VM. It does **not** pass the sequential partial-read, real-player first-frame/seek, physical-Mac, longer-than-300-second transfer, cancellation or shipping lifecycle gates.
- The earlier 35 GiB control remains a single run with unknown NAS cache state. It is not relabeled cold merely because its rate resembled the disk rating.
- Required checks passed without production-code changes: nine Swift tests, Release CLI checks, unsigned Release app build with no Swift warnings (`.build/full-*.log`).

## Evidence and reproduction

Private raw data: `results/cache-state-20261011/` (ignored; includes NAS paths). Files:

- `manifest.json`, `nas-probe.json`, `samba-version.txt`, `initial-cache.json`: setup, memory, storage mapping, selected fixture and initial observed residency.
- `nas-state.py`: scoped NAS preparation/telemetry, executed over the temporary authenticated SSH channel. The path is fixed to the specifically approved fixture. `inspect` is read-only observation; `cold` requests per-file eviction; `warm` reads the file.
- `run-pair.py`, `cold{1…5}-*`, `warm{1…5}-*`: CLI/coordinator results, individual NAS and SMB before/after snapshots, parsed records and callback logs.
- `smoke-*`: preliminary native state-validation controls, separate from the series.
- `local-cache.py`, `local-samples.json`, `local-fetch.log`, `pin-and-local-checksum.json`: local-cache controls and hash evidence.
- `check-provider.py`, `cold3-checksum.json`, `warm5-checksum.json`: complete hashes after representative downloads.
- `summarize.py`, `summary.json`: sample statistics and timing decomposition.
- [Interactive cache-state comparison](2026-10-11-cache-states.html).
- The optimized coordinated-read harness and signed binary hashes are under `results/provider-full-20261011/`.

Repeat only against the approved immutable fixture, with explicit cache-state assertions before each run and a fully evicted clean provider copy. Keep the reader app connected, and run hashing/build checks outside timing windows. Review any failed state assertion instead of silently labeling that run cold or hot.

The temporary SSH control connection was closed after the series. The test provider file is fully downloaded and unpinned. NAS data and configuration were left unchanged.

## Next step and user-facing behavior

The cache-controlled full-download path now has evidence above 90% in both conditions. The remaining streaming issue is the recurring range handoff/materialization wait found in the [earlier trace](2026-10-11-provider-delay.md). SMB remains the transport in both native and integrated paths; the integrated path adds local staging and macOS's acceptance of each fetched extent before the application can read it.

There is no need for the user to choose between two adaptive modes. Ordinary opens and seeks should get needed bytes promptly through automatic range scheduling; an explicit Download / Keep Downloaded request asks for the complete file efficiently. The next proposed experiment is bounded read-ahead/overlap with measured startup, seeks and excess downloaded bytes. Do not simply make all opens fetch gigabytes. PDF and other formats follow actual viewer requests; partial format support does not guarantee a particular viewer streams through File Provider.
