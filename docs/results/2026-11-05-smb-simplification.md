# SMB simplification, 2026-11-05

Ordinary SMB writes now replace remote save transactions, conflict copies and content proofs.
The final VM save series has similar cost to native overwrite plus fsync when connection setup
is included. Signed interruption testing verifies complete local retention and automatic retry
after app/provider restart. Full and partial reads still miss the 90% native-throughput target.
This branch has not been published or installed on the physical Mac.

A competing edit can be overwritten, and an interrupted write can leave partial remote data.
NAS snapshots/backups own previous-version recovery. File Provider retains pending local edits;
TinyMounter reports success only after the server accepts write, length, flush and close.
The [audit decisions](../smb-simplification.md#audit-decisions) explain what was removed and why
identity, containment, local upload integrity and catalog settlement remain.

## Setup and method

Tests ran on November 5 in macOS VM 1, macOS 27.0.1, nine virtual CPUs and 8 GiB RAM. The
server was the disposable Samba 4.19.5 Ubuntu VM, kernel 7.0.0-31, two virtual CPUs, about 4 GB
RAM and ext4 storage. Both used the same host's virtual network. The final signed Release app
used separate SimplifyCheck identity and fresh location state. Older pending fixtures remained
intact. No original-NAS writes or physical-Mac app builds were performed.

Both clients required encryption. The native mount reported SMB 3.1.1, AES-128-GCM encryption
and AES-128-GMAC signing, with compression counters at zero. The direct client requires signing
and encryption, but its negotiated cipher was not captured. Cipher parity and physical-network
performance are therefore unverified. Requests are limited to 1 MiB, server limits and available
credits, with one request outstanding per connection.

Five alternating native/direct pairs per size measured the production Swift overwrite path.
Native timing includes open, write, truncate, fsync and close. Direct operation timing includes
ancestor handling, file open, write, size, flush, close and returned metadata; connection setup
is reported separately. Input generation and independent hash verification are outside timing.
Files were read before each save, warming caches without measuring residency. There were no
builds during timing. These are transport measurements, not editor Save latency: provider
dispatch, the local callback copy and catalog updates are excluded.

## Save measurements

Final candidate, seconds; medians with ranges for five samples:

| Size | Direct operation | Direct including connection | Native |
| --- | ---: | ---: | ---: |
| 1 MiB | 0.0246, 0.0170–0.0271 | 0.0537, 0.0437–0.1023 | 0.0535, 0.0466–0.0953 |
| 64 MiB | 0.2536, 0.2457–0.2799 | 0.2680, 0.2610–0.2954 | 0.2840, 0.2757–0.3021 |

Operation samples in round order, seconds:

| Size | Direct | Native |
| --- | --- | --- |
| 1 MiB | 0.021346, 0.027109, 0.026046, 0.024560, 0.017019 | 0.053484, 0.048204, 0.087127, 0.046587, 0.095347 |
| 64 MiB | 0.251085, 0.253646, 0.245670, 0.263062, 0.279863 | 0.278903, 0.284885, 0.302136, 0.275661, 0.284033 |

All 20 final server files matched the input digests in independent Linux reads. Earlier same-day
five-pair series compared the former 64 KiB limit with 1 MiB requests. The 64 MiB operation median
was 0.489 s at 64 KiB and 0.240 s at 1 MiB, against contemporaneous native medians of 0.286 s and
0.283 s. All 40 files from those series also matched. The final series above includes removal
of a redundant pre-write metadata query and is the result for the completed code.

The [November 4 transaction](2026-11-04-save-recheck.md#save-timing) measured 6.357 s for 64 MiB
against 0.347 s native. Its method and build differ, so these results do not establish an exact
speedup factor. They show that the new implementation avoids the previous multi-pass save cost.

## Read measurements

The existing release benchmark and provider helper ran five alternating pairs for each workload.
Full reads used fresh 2 GiB files with zero provider allocation before each sample. Native reads
staged to APFS with `F_NOCACHE`; provider reads used coordinated whole-file download. Partial
reads used fresh 512 MiB ranges in a 3 GiB file, 1 MiB POSIX reads and `F_NOCACHE`. Hash checks
ran outside timing, with provider hydration disabled, and every measured range/file matched.

Initial fixtures were copied on the server before testing. Server, native-client and local cache
residency were unverified. A separate partial series flushed and evicted only its fixture's Linux
file pages before each arm, then verified zero resident pages with `mincore`. The host virtual-disk
cache and native-client cache remained unverified; this is not a fully cold-storage comparison.

| Workload and server cache state | Native median, MB/s | Provider median, MB/s | Median paired provider/native ratio |
| --- | ---: | ---: | ---: |
| Full 2 GiB, residency unverified | 199.09 | 169.63 | 0.854 |
| Partial 512 MiB, residency unverified | 371.53 | 151.27 | 0.416 |
| Partial 512 MiB, zero resident Linux file pages | 320.42 | 155.99 | 0.442 |

Individual wall times in round order, seconds:

| Workload | Native | Provider |
| --- | --- | --- |
| Full | 10.7864, 11.8790, 11.7676, 7.2770, 7.9981 | 14.9422, 12.6596, 13.6967, 12.5031, 9.3692 |
| Partial, unverified | 2.0245, 1.3370, 1.7409, 1.3879, 1.4450 | 3.5491, 4.0064, 3.5489, 3.3326, 3.8255 |
| Partial, Linux pages evicted | 1.4277, 2.0465, 1.7217, 1.6755, 1.5032 | 3.4417, 3.3301, 3.2514, 3.7869, 3.5872 |

Each full download used one 2 GiB callback and exactly 2 GiB of direct payload. Most full-download
time was inside the app transfer, 9.09–14.74 s; callback time beyond that transfer was only
0.031–0.037 s. The full-read gap cannot be attributed entirely to File Provider. Each initial
partial sample used 33 callbacks of 16 MiB, or 528 MiB returned for 512 MiB requested. Partial
callback and prefetch intervals overlap; summing them does not isolate elapsed overhead.

These results leave the 90% target unchanged and unmet. The November 4 accepted writable-partial
series used a different helper/setup and native baseline. It cannot establish improvement or
regression against this run. Fully local APFS parity, seek latency, read-only versus writable
comparisons and physical-Mac speed were not remeasured here.

## Runtime correctness and retry repair

Signed VM checks covered ordinary/repeated saves, competing server edits, shorter/empty files
and offline retention. A first mid-write interruption retained the complete 64 MiB local edit
but failed automatic retry after restart. Native location-folder lookup returned missing, then
the mutation error mapper converted connection failures into a permanently throttled sync error.
The existing Retry Pending Changes action uploaded the retained bytes without a reset or discard.

Direct mutations now validate the scoped grant and mount without reopening the location through
native SMB. Transport resets return connection errors, and the provider preserves retryable
connection, authentication and permission errors. In the repeat test, the server stopped after
2,084,864 bytes of a 64 MiB file changed. The remote file was partial and the local file complete.
After terminating the test app/provider and restarting the server and app, automatic retry
uploaded the exact 64 MiB contents. No manual Retry was needed; independent local/server hashes
matched, and the pending entry cleared.

The final signed app created a folder and file, moved/renamed the file into a child folder, then
renamed that populated folder. Independent server checks confirmed the new paths, absence of the
old paths, unchanged file/folder inodes and exact contents. Local inodes also survived both moves.
This was a POSIX-through-provider smoke check, not a fresh Finder GUI, keep-selection or
overlapping-location recovery matrix. A final all-domain diagnostic dump timed out; it is not
evidence that every older test domain has no pending changes.

Four simultaneous SMB clients completed 40 reads, and 10 wrong-account attempts were refused.
This checks connection separation; it does not establish concurrent operation of two valid
accounts. Ordinary Finder deletion, Replace and combined rename/content callbacks remain disabled
or unsupported. The confirmed deletion command was not rerun through the GUI in this pass.
Full OS restart, pressure eviction and broader editor coverage still need evidence for this path.

## Required checks and cleanup

`Tools/run-checks.sh` passes in the VM: 518 package tests with one optional fixture skip, release
benchmark and log-parser checks, project generation, deletion-event checks, unsigned app build
without Swift warnings, six SET_INFO cases, 87 edit-status cases, 18 folder-create cases and
7,205 CCM cases. The final documentation commit is also included in the required check pass.
The manual deletion helper typechecks, and a generated candidate with folder, overlap, deletion,
editor and save-space hooks builds. Its save-space hook now checks app staging and new items;
this does not revalidate the removed edit-outbox recovery matrix.

The temporary 16 GiB read fixture was removed after measurements. Guest trimming reduced the
server VM's allocated disk to about 37.5 GB; its temporary 60 GB limit was restored to 40 GB and
the server restarted. Older fixtures and pending local data were preserved. Host signing removed
its loose app bundle after packaging, preserving the separate Spotlight cleanup. The physical
Mac's installed app was not replaced.

## Evidence and next step

Raw evidence stays private in the macOS VM under `results/smb-simplification-20261105/`:

- `saves-final/samples.json` and `summary.json`, plus the earlier `saves-64k/` and `saves-1m/`.
- `reads/setup.json`, `native-security.txt`, `samples.json`, `summary.json`, `cold-samples.json`,
  `cold-summary.json` and `fetch-log.ndjson`; `read-series.py` and `cold-cache.py` retain the driver.
- `midwrite-retry.log`, `midwrite-retry-pending.txt`, `midwrite-retry-complete.txt`, earlier
  interruption logs and `concurrency.json`.
- `checks-audit.log`, `checks-final.log`, signed build logs and `helper-build-final.log`.

The Samba VM retains `~/smb-simplification-final-verification.json` with all 20 final save hashes
and the organization checks. `Tools/check-smb-saves.py` documents the save-series invocation;
compile its Swift helper against the production adapter and run only in the disposable fixture.
The read driver uses the existing benchmark and provider helper, with new disposable files.

The next performance investigation should isolate direct SMB transfer from local staging under
matched cache/security settings, then measure partial-read dispatch and materialization. Further
read-ahead or transport changes need that attribution. Publishing or installing this branch on
the physical Mac remains a separate decision.
