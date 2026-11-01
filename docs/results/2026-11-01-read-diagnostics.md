# Protected-read diagnostics

Date: 2026-11-01. The signed VM check confirms that read diagnostics distinguish full
verification, cached block verification and waiting for the share's namespace lock.
Cancellation during the local staging checksum returns cancelled and removes the staged file.
All required VM checks pass. This change adds observations only; it does not improve speed
or explain the slow outlier in the [earlier range-read series](2026-11-01-verified-range-reads.md).
The physical Mac keeps its previously installed build.

## Setup and method

Work started on a fresh topic branch from the merged `main`. No persistent format, migration,
transport, lock scope or verification rule changed. One request-correlated log event records
verification mode, protected payload bytes, namespace wait and phase durations. Logs contain
opaque request IDs, without source names or paths. The performance runner retains these events
with provider callbacks and also captures listings.

The signed Release helper ran in macOS VM 1, macOS 27.0.1 build 26A434, against the existing
loopback Samba 4.25.1 fixture. It used an isolated app identity with the production sandbox,
a picker-authorized share, fresh private Settings and catalog, and no File Provider domain.
Only the helper's entry point replaced app code in an isolated source archive. Its calls use
the production `LocationSource.transfer` implementation. The fixture's existing immutable
2 GiB payload was read only. No existing Settings or catalogs were migrated.

One process ran the cases below in order. Each range was 16 MiB at offset 64 MiB. Server,
native SMB and local filesystem cache states were uncontrolled. The helper forced the stated
in-memory proof state. These are diagnostic observations, without a matched native baseline
or repeated samples, so they establish neither throughput nor a latency regression.

## Observations

Durations below are milliseconds. Protected bytes count payload read by the verification
connection, excluding wire overhead and the separate native payload transfer.

| Case | Verification | Protected bytes | Namespace wait | Verification time | Total time |
| --- | --- | ---: | ---: | ---: | ---: |
| Full read establishing an edit base | Full | 2048 MiB | 0.003 | 4910.165 | 7584.452 |
| Range with retained proof | Blocks, cache hit | 16 MiB | 0.005 | 37.598 | 140.615 |
| Same range after a forced 400 ms lock hold | Blocks, cache hit | 16 MiB | 417.865 | 36.553 | 516.274 |
| Cancel during the staging checksum | Blocks, cache hit | 16 MiB | 0.003 | 35.617 | 81.360 |
| Range after clearing proof and its session reference | Full fallback | 2064 MiB | 0.001 | 5977.334 | 6034.859 |

The forced hold occurred before the first catalog lookup. Its recorded wait confirms that
instrumentation includes this initial lock acquisition, not only the later protected-transfer
lock. Clearing both proof and session reference produced `cache=session`; fallback read the
whole file and then the requested range. That case did not perform an actual remount.

All four successful transfers matched independent native-source SHA-256 checks. The cancellation
case reached `phase=checksum`, returned cancelled, and left staging empty. The helper also
required an empty staging directory after the final case. An audit matched each request ID to
exactly one diagnostic and checked its mode, byte count, phase and forced-wait observation.

## Verification and limits

`Tools/run-checks.sh` passed in the VM: 540 Swift tests, one optional skip, no failures,
four performance-log parser tests, Release CLI checks, a warning-free unsigned app build,
six SET_INFO encoding cases, 57 edit-status cases, 15 folder-create status cases and 7,205
encryption cases. Parser tests cover request and app isolation, older builds without diagnostics,
failed attempts, malformed input and sample boundaries.

The first helper build needed call-site corrections. Two signed attempts then exited after
listing without a report and are excluded. Running the picker-based helper through a normal
AppKit application loop resolved that early exit; the final run returned a successful report
and passed the separate log audit. Product code needed no runtime repair.

This check does not exercise Finder, provider callbacks, an actual slow listing, concurrent
mutations or a remount. Callback correlation is checked by the parser tests, not by this signed
helper. The previous performance targets, full-download cost and remaining mutation cases stay
open. New diagnostics have not yet been used in a repeated performance comparison.

## Evidence and next step

Private VM evidence is in `.local/phase4/read-diagnostics-20261101/`: `checks.log`,
`probe-build*.log`, `runtime*.jsonl`, `runtime*-log.ndjson`, `diagnostic-audit.json`,
the isolated helper source and signed archives, and `restoration.json`. Retain the unsuccessful
attempts with the final run. The audit pins the production commit and records exact request IDs.

The helper exited, the fixture was unmounted, and its temporary Samba process stopped.
Hostname contents, Apple SMB loading and service overrides match their saved state. The
original Samba configuration and backing-root identity are unchanged. Private helper state
and evidence remain; no provider domains were registered.

Next, reuse the existing provider performance runner to reproduce slow cached reads with these
diagnostics, including reads during listings. Use that attribution before changing locks or
verification, and retain the existing performance targets and integration gates.
