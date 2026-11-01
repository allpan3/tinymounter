# Verified range reads

Date: 2026-11-01. A bounded in-memory digest table reduces repeated small reads of an
edit-base revision from a median of 4.127 s to 0.721 s in VM 1. All measured bytes match.
One read still took 4.254 s. Full downloads increased from 7.192 s to 7.780 s, about 8%.
The throughput target remains unmet. This candidate is installed only in the VM;
the [physical-Mac update](2026-11-01-local-update.md) uses the earlier verified build.

## Implementation and setup

Each location retains at most 2 MiB of SHA-256 digests, in 1 MiB blocks, from one complete
protected verification. The proof belongs to an immutable receipt, path and live mount
session. Each request opens fresh protected handles, verifies the requested blocks, transfers
payload through native SMB and checks the staged bytes before handoff. Full downloads and
mutations still verify the whole object. Source close and remount discard reusable evidence.
The final local checksum now observes cancellation and reports progress.

A metadata-preserving change outside the requested blocks can remain undetected until those
blocks are requested or a full verification runs. Returned bytes must still match the requested
immutable revision. Files larger than 64 GiB use full verification. No persistent format or
transport changed in this patch.

The signed Release candidate ran in macOS VM 1, macOS 27.0.1, with 9 CPUs and 8 GiB RAM,
against the existing loopback Samba 4.25.1 fixture. Security settings and the 16 MiB returned
extent stayed unchanged. Temporary hostname resolution and the documented Samba mkdir setting
matched the [earlier measurement](2026-10-31-everyday-use-review.md).

Both builds read the same immutable, non-sparse 2 GiB file in the writable location.
Each series interleaves five native/provider pairs, alternating their order. Full downloads
start after Finder eviction, verified by allocation and the dataless flag. Small reads request
1 MiB at offsets 256 MiB apart; each must allocate fresh provider bytes. Native reads use
`F_NOCACHE`. Server and native cache states are unknown. The builds ran in separate sessions,
so this comparison cannot remove drift between sessions. No build ran during timing.

## Measurements

All values below are seconds, in run order. Range times are the reader's first-byte latency,
including provider scheduling. Full times run from coordinated-read request to accessor entry.

| Case | Five samples | Median |
| --- | --- | --- |
| Earlier small reads | 4.321, 4.097, 4.127, 4.912, 4.004 | 4.127 |
| Reusable proof after a full download | 0.674, 0.721, 0.725, 4.254, 0.645 | 0.721 |
| After app restart | 5.961, 0.766, 0.711, 0.849, 0.755 | 0.766 |
| After unmount and remount | 5.274, 0.728, 0.667, 0.710, 0.713 | 0.713 |
| Earlier full download | 7.192, 7.383, 6.791, 6.783, 10.065 | 7.192 |
| Current full download | 8.087, 8.335, 7.780, 7.653, 7.423 | 7.780 |

The four fast calls in the first proof series spent 0.103–0.128 s in the provider callback.
The slow call spent 3.626 s there; its fetch-only log cannot separate verification from
waiting for the share lock. A later competing-change read overlapped a 3.793 s listing of
another location on the same share, showing why listing contention remains worth measuring.
That later observation does not establish the cause of the earlier outlier.

Current full downloads reached a median 276.0 MB/s against 3342.9 MB/s native, or 8.3% of
native; the earlier ratio was 8.7%. The accepted target remains 90%. Additional block hashing
adds work to full verification, but this measurement does not isolate its entire cost.
The first read after restart or remount still verifies the whole file. These results do not
establish sequential throughput, media latency or physical-Mac performance.

## Correctness and remaining checks

`Tools/run-checks.sh` passed for the measured implementation: 579 tests, one optional skip,
no failures, a warning-free Release app build, encoder/status checks and 7,205 encryption
cases. Ten new tests cover range boundaries, short reads, changed blocks, bounded storage,
error propagation and checksum cancellation. Independent source review found no remaining blocker.

All 15 provider range samples and five full downloads passed checksums and ingress checks.
The remount log records session end and a new session in the same app process. An initial
remount attempt lacked its mount directory; its failed samples remain in the evidence and
are excluded from the completed series.

Two extra signed provider reads returned current bytes after an in-place byte change and
an identical-byte replacement of a separate 64 MiB fixture. These checks do not prove that
the requests used cached `e1` evidence or forced stale native bytes through the rejection
path. Treat those as integration limits. Forced competing opens during a cached read,
cancellation during a signed staging checksum, proof-budget eviction across files and
metadata-only fallback at runtime also remain unverified.

## Evidence and next step

Private VM evidence is in `.local/phase4/verified-read-20261101/`: `checks.log`, `build.log`,
`installed.json`, `summary.json`, the four completed series directories, `remount-log.ndjson`,
the mutation reports and `restoration.json`. `run-series.py` reuses the existing performance
runner's measurements, checksums and callback parser. Its manifest pins the tested commit;
later concurrent changes in the shared checkout are outside these results.

The synthetic mutation file was removed after checking its identity and hash. Its previous
copy remains privately with the evidence. The measurement files are unchanged. The candidate
app, its providers and the temporary Samba service are stopped, the fixture is unmounted, hostname
contents and Apple SMB service state are restored, and the original server configuration and
backing-root identity match their prior values.

Next, attribute the remaining first-read and listing waits and close the forced cached-read
mutation checks before another physical-Mac performance update. Continue the integrated Finder
and recovery work against the existing milestone gates; this result relaxes none of them.
