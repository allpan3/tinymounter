# Everyday-use and performance review

Date: 2026-10-31. Accelerated SMB encryption reduces the measured writable-open delay: five
2 GiB downloads have a 7.19 s median, compared with an earlier 77.10 s profiled sample after
the fixture connection fix. This is not a repeated before/after speedup measurement. Small
reads of files prepared for editing still wait 4–5 s for whole-file verification. Performance
targets and integrated Finder organization, deletion and recovery workflows remain open.
These are VM results, not physical-Mac acceptance.

The new-folder failure reproduces through both the production SMB adapter and native `mkdir`.
A supported Samba setting fixes both on the disposable fixture. Signed Finder creation and
initial naming also complete. M22 and M24 remain disabled in the normal build.

## Setup and method

All runs used macOS VM 1 on 2026-10-31, macOS 27.0.1, 9 virtual CPUs and 8 GiB RAM, with
loopback Samba 4.25.1. Isolated signed Release builds used separate identities and state:
M17 baseline `c2f52a0` and current `7406009`. The sandbox stayed intact. No physical-Mac app
was updated, and the original NAS remained read-only.

The full-download pilot used one sample per path of the same 2 GiB random, non-sparse file.
Each provider copy began dataless with zero allocated blocks. Complete hashes matched outside
the timing windows, and native SMB RX increased by at least 2 GiB per remote arm. Server cache
was uncontrolled. This is a diagnostic pilot, not a repeated regression or acceptance series.

Five cached-read rounds alternated local APFS, baseline, current read-only and current writable
order with its reverse. Complete local hashes were verified, hydration was disabled and the
reader requested `F_NOCACHE`; no cache flush ran. There were no fetch callbacks. SMB RX changed
by only 148 to 556 bytes per sample, consistent with metadata traffic. Local page-cache state
remains uncontrolled, so these results do not measure uncached SSD throughput.

## Measurements

Full-download pilot, one sample per path. Rates use decimal MB/s.

| Path | Total seconds | MB/s |
| --- | ---: | ---: |
| Native SMB to sink | 0.746210 | 2877.856 |
| Native SMB to APFS staging | 1.197229 | 1793.712 |
| M17 full download | 3.044812 | 705.293 |
| Current read-only full download | 3.322138 | 646.416 |
| Current writable full download | 95.476436 | 22.492 |

The writable callback took 94.875978 s. Native transfer accounted for 2.143914 s and connection
setup for 20.190 s. The later profile below attributes most verification CPU samples to
software AES. The pilot alone could not establish that cause or a read-only regression.

Cached-read results, five samples per path:

| Path | Median MB/s | Range MB/s |
| --- | ---: | ---: |
| Local APFS clone | 16927.247 | 11263.45 to 17628.14 |
| M17 provider | 2684.528 | 1925.13 to 2866.01 |
| Current read-only provider | 2542.507 | 2137.35 to 2746.02 |
| Current writable provider | 3080.262 | 2378.71 to 3306.25 |

The provider ranges overlap; this series does not demonstrate a current cached-read regression.
The gap to the local APFS control remains unexplained. It does not establish cached-read parity.
The earlier sequential-read, media and physical-Mac targets remain unchanged.

### Repeated read-only comparison

Five rounds per build then used the corrected fixture, including hostname resolution, with
the same native controls and reader. Full downloads used the 2 GiB file; each partial sample
read 512 MiB from a fresh slot in a 3 GiB file. Each full copy was evicted through Finder before
timing. Builds ran sequentially, with native/provider order alternating within each run.
Server cache remained unknown. All samples passed hashes, ingress and callback checks.

| Workload | M17 median MB/s, range | Current median MB/s, range |
| --- | ---: | ---: |
| Full download | 838.4, 757.2 to 993.2 | 860.1, 694.0 to 917.5 |
| Fully local provider read | 2876.1, 2608.3 to 3178.2 | 2700.0, 2557.7 to 3070.3 |
| Sequential partial read | 206.6, 193.1 to 215.0 | 194.2, 179.2 to 210.7 |

The full-download median is similar. Current partial and cached medians are about 6% lower;
both their raw and native-normalized ranges overlap, so five samples do not establish a
regression or exclude a smaller one. Partial first-read medians were 0.672 s and 0.682 s.
The local-clone control in these runs was much slower than in the earlier cached pilot.
The comparison cannot explain that cache/storage difference or establish general local parity.

Full-download rates were 24.8% and 25.2% of matched native; partial rates were 6.4% and 5.9%.
Both builds miss the 90% target on this very fast loopback fixture. The earlier NAS full-read
passes used a different server and network and do not transfer to this setup. These results
do not support enabling more features on performance grounds.

The first baseline attempt completed its timed rounds but failed during final reporting:
its APFS clone inherited the provider's immutable flag, so cleanup could not unlink it.
The runner now retains that control and saves hashes incrementally. The table uses the
complete rerun, not the attempt whose final verification report was lost.

A separate listing check returned the same 1,000 names through native SMB and both providers.
First observed provider enumeration took 0.381 s for M17 and 0.458 s for current, one sample
each after native enumeration had warmed the shared path. Five subsequent warm enumerations
had medians of 0.482 ms and 0.494 ms, with overlapping ranges. These warm directory reads are
local-cache observations, not repeated remote-listing measurements. The command initially
failed because its inherited process policy prohibited dataless materialization; rerunning
with that process-only policy enabled reached the provider normally.

### Writable-open profile

After fixing hostname resolution, a profiled 2 GiB writable full download still took 77.096 s.
Its callback took 76.885 s, including 2.293 s of native transfer. Complete hashes and the
single full callback matched. This one CPU-profiled sample is diagnostic, not a latency median.
In an eight-second sample at 10 ms intervals, 646 of 676 samples in the version-reading call
were in SMB AES-CCM decryption; nine were in SHA-256. The bundled software AES implementation
is the measured hotspot. Accelerating that calculation must preserve the cipher, tag checks,
independent protected digest, native payload transfer and lock order.

Five subsequent native sink/staging pairs retained the same bytes and `F_NOCACHE` policy.
Sink median was 4411.5 MB/s, range 3906.6 to 4714.8; APFS staging median was 1717.1 MB/s,
range 1366.5 to 1944.0. Every arm received at least 2 GiB through SMB. This later control
shows that staging itself costs time, but it was not interleaved with the provider series
and does not replace their matched native denominators.

### Accelerated encryption and remaining read cost

The candidate now uses public CommonCrypto CBC and CTR operations for AES-128-CCM. The cipher,
authentication tag, protected content digest, native payload transfer and lock order remain
unchanged. Local encryption failures reject requests before queuing and restore unsent message
IDs; authentication failures clear plaintext. No connection timeout or security setting changed.

The final candidate passed `Tools/run-checks.sh` in VM 1: 569 tests with one optional skip,
Release CLI verification, project consistency, the unsigned app build with no Swift warnings,
and the existing SMB status/encoding checks. All 7,205 encryption cases passed, including an
RFC vector, portable equivalence, altered packets, injected API failures and rejected queues.
The final queue test initially failed because its compiler flags omitted the library's
conditional credential field, shifting its view of the queue. Matching the library's build
configuration fixed that test; the complete check set then passed.

A separately signed Release candidate passed strict signature verification and ran in the
existing isolated current-app identity. Five alternating-order rounds used the same native
controls, fixtures and cache rules as above. The 2 GiB full fixture already had an edit base
and was evicted before every round. The 3 GiB partial fixture had never established an edit
base; each round read a fresh 512 MiB slot. All 30 samples passed hashes, ingress and callback
checks. No builds or profiling ran during timing.

| Workload | Provider median MB/s, range | Matched control median MB/s | Ratio of medians |
| --- | ---: | ---: | ---: |
| Writable full download | 298.6, 213.4 to 316.6 | 3424.0 native SMB | 8.7% |
| Fully local read | 2998.0, 2828.7 to 3032.4 | 2932.4 local APFS clone | 102.2% |
| Partial read without an edit base | 180.1, 164.4 to 195.0 | 3158.6 native SMB | 5.7% |

Full-download times were 7.192, 7.383, 6.791, 6.783 and 10.065 s. Median callback time beyond
native transfer fell from the earlier profiled sample's 74.592 s to 4.698 s. The slowest final
round spent 5.528 s in native transfer; its remaining callback time was 4.371 s. Cached reads
made no fetch callbacks. The local-control rates differ from the earlier pilot, so this series
does not resolve the historical APFS gap or prove general local parity.

Five further nonsequential 1 MiB reads used fresh offsets 256 MiB apart in the evicted 2 GiB
file with an edit base. First-read latency was 4.321, 4.097, 4.127, 4.912 and 4.004 s
(median 4.127 s); matched native reads ranged from less than 1 ms to 41 ms. All hashes matched.
These reads still require a protected whole-file digest before the requested native range.
Native SMB counters do not include that separate verification connection. This is a bounded
read-cost check, not the 20-seek player acceptance test.

Encryption acceleration removes the dominant measured CPU cost, but does not meet the 90%
throughput target or make edited-file cache misses responsive. The next performance design
must address repeated whole-file verification without weakening version or identity checks.
It also needs a complete handle-lifetime and lock-order design; narrowing one lock alone is
unsafe. The native payload transport remains unchanged.

## Folder creation and correctness

The production C adapter had an independent error-handling defect. It treated an SMB error
payload as a successful query response and could free invalid memory. The repair checks status
before interpreting the payload. Stage tracing and a bounded reproduction now distinguish
connection, create and observation failures.

Both the production adapter and native `mkdir` returned `EACCES` and left a mode-000 directory
with the original fixture configuration and with two ACL variants. Disabling Samba's temporary
mkdir path with `vfs mkdir use tmp name = no` in a temporary fixture configuration made both
routes succeed while retaining the original ACL and stream settings. The backing directory
had mode 0777, uid 501, gid 0 and a DOS attribute; the native mount reported mode 0700.
An existing-name attempt returned `EEXIST` / `0xc0000035` with `create_sent=0`. Same-identity
replay succeeded with `create_sent=0`.

Finder creation and initial naming then completed in the signed current app. Its provider
reported create received at 19:22:19.396, upload success at 19:22:39.573, initial naming at
19:22:39.585 and name success at 19:22:59.658. The backing audit found the named directory,
mode 0777, uid 501, gid 0 and `user.DOSATTRIB`. The name typed by automation lost its first
character; Finder, the provider and the backing store agreed on the resulting name.

The reviewed Samba source explains a plausible failure path: its temporary no-replace rename
falls back after Darwin returns `EINVAL`, creates a mode-000 destination, then attempts an
ordinary rename. Published XNU source checks destination permissions before replacement.
The configuration comparison supports this diagnosis, but there is no server log proving
that exact fallback occurred. The reviewed XNU release is for macOS 26, not the running 27.
See the [source review](../research.md#samba-folder-creation-review-2026-10-31).

The supported setting permits a brief visibility window before final directory metadata is
applied. It is acceptable for this disposable fixture; it is not a product requirement or
permission to reconfigure a user's server.

The connection delay is a separate fixture defect. A headers-only packet capture during
Finder creation showed two server-response gaps of 10.01 to 10.04 s per connection. Resolving
the VM's own hostname took 5.03 s and failed. A temporary `/etc/hosts` entry for both IPv4 and
IPv6 reduced repeated lookups to 0.0003 to 0.0028 s. Adding IPv4 alone still took five seconds.
With both entries, fresh adapter create, collision and replay operations took 0.157, 0.029 and
0.032 s, respectively, with the same expected identities and outcomes. No timeout, encryption
or product safety setting changed. These are diagnostic observations, not latency medians.
Signed Finder creation then took 0.160 s from provider receipt to upload success; initial
naming took 0.069 s from its callback to success. The backing audit confirmed the named,
empty directory and expected metadata. These are callback timings from one run, excluding
the pause while automation typed the name.

`Tools/run-checks.sh` passed in VM 1 on `ee98c63`: 569 tests, one optional skip, no failures
or Swift warnings. Project generation, Release CLI validation, the unsigned app build, six
SET_INFO cases, 57 edit-status cases and 15 folder-create cases passed. These checks do not
establish signed Finder behavior. The final encryption candidate's complete checks and signed
read measurements are recorded above.

## Evidence and next work

Private evidence is retained in VM 1 under `.local/phase4/milestone-review-20261031/`:
`pilot/`, `cached/`, `checks-01.log`, `benchmark-helper-build.log`,
`benchmark-runner-check.json`, `fixture.json`, `partial-fixture.json` and the opaque-ID
`*-create.json` / `*-observe-after.json` records. These contain local fixture details and are
not published. Reuse the existing measurement runner, `transfer-bench` and
`Tools/run-native-series.py` with the cache and counter checks above; retain individual samples.

The acceleration evidence is in `checks-ccm-validated.log`, `accelerated-final-build.*`,
`accelerated-install.json`, `accelerated-writable/` and `accelerated-edit-base-seeks/` in that
same private directory. Earlier failed checks and diagnostic samples remain alongside it.

`final-restoration.json` verifies that the fixture is unmounted, its temporary Samba process
is stopped, the original hostname file is restored byte for byte, and Apple SMB is loaded and
inactive with its prior service override. The original Samba configuration and backing-root
identity are unchanged. Both isolated performance apps are stopped; their builds, data,
fixtures and earlier recovery evidence remain. Updating the candidate retained the existing
test locations. A byte comparison of its Settings file was unavailable because macOS refused
container access; the installer did not modify Settings.

Next, address repeated verification on edited-file cache misses and finish the integrated
M22/M24 Finder workflows and recovery controls after their gates. Add a bounded diagnostic only
when a specific failure blocks one of those workflows. The physical Mac remains unchanged.
