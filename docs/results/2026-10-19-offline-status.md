# Kept-file local availability, 2026-10-19

## Outcome

The signed sandboxed VM app distinguishes a Keep Downloaded request from a complete local copy.
Partial content stays Requested; complete content shows Available offline. Completion updates the
open pane, and full files remain readable after an OS eject. All 160 tests and required checks
pass. M13 remains in progress because strict source-version verification is still open.

Available offline means macOS reports its known version as current, with the catalog's size and
modification date. This is not a live NAS check. The system's materialized enumerator omits the
opaque provider content version, so a catalog change that preserves size and modification date
cannot yet be compared directly with the applied copy. This gate has not been relaxed.

## Setup and method

- VMPal `macOS VM 1`, macOS 27.0.1, build 26A434; Xcode 27.0, build 27A266a.
- Personal Team signed app and extension, with their normal sandbox and existing saved SMB grant.
- One temporary location on the read-only NAS. A 73-byte file was read in full; a 139.46 MiB file
  was first read for 1 MiB, leaving 16 MiB allocated and the dataless flag set. No large fixture.
- Source and kernel caches were uncontrolled. This is a correctness check, not a speed comparison.
- Matched recordings select Storage, select the location, then scroll to Keep Downloaded. Both
  start with the same complete small file kept. Private text is masked in the recordings.

The app first enumerates materialized IDs, then queries security-scoped URLs only for kept files
in that set. It reads Foundation's downloading status, downloading flag, file size and modification
date without opening content. Failed or missing metadata clears an earlier positive state.
Materialized-set and pending-set notifications, domain download start/finish and catalog changes
reload the list. A generation and the current location key reject old asynchronous replies.
Settings and catalog formats are unchanged.

## Checks

| Check | Observed result |
| --- | --- |
| Complete small file kept, previous build | Requested |
| Same file, new signed app | Available offline |
| Partial large file kept while downloads paused | Requested; 16 MiB remained allocated |
| Read partial file with hydration forbidden | Failed with errno 11; no zero-filled success |
| Resume Downloads, stay in the location pane | Changed to Available offline after completion |
| Full read of both completed files, hydration forbidden | SHA-256 matched the native source |
| Disconnect through Servers, wait for normal OS unmount | Native mount absent; both files still matched SHA-256 with hydration forbidden |
| Relaunch app | Both kept files returned to Available offline |
| Turn off File Provider in System Settings | Both labels changed to Requested |
| Turn it on again, same location | Both labels returned to Available offline |
| Remove a keep request | Its row disappeared without deleting the downloaded copy |
| Remove temporary location without saving its keep list | Location and downloads removed; no catalog or stage files remained |
| Full VM checks | 160 tests, zero failures; project generation, benchmark checks, release CLI and unsigned app builds passed; no Swift compiler warnings |
| Log audit | 122 app/extension messages; zero matches for tested private names or path patterns |

The first completion attempt stayed at Update in progress until the pane reopened. Its
materialized-set event arrived before the final metadata. Adding pending-set and domain
start/finish observations fixed the repeated check. No polling was added.

## Correctness and limits

The materialized-item probe reported false downloaded/current flags and an empty content version
for the complete small file. Provider-defined userInfo was also absent from the system projection.
The final implementation uses the public URL metadata instead; those temporary probes are removed.

Unit tests cover partial logical size, missing metadata, a stale status, mismatched size/date,
downloading and empty files. Runtime checks cover normal completion, offline reads, relaunch,
unkeep and disabled-provider invalidation. Source changes during an observation and changes that
preserve size/date remain untested. The size/date check is not a substitute for the opaque version.

No NAS file was changed. The temporary location and downloads were removed, File Provider was
left enabled, and the original saved server and hidden mount were left connected. Cairndex was
untouched. No physical-Mac app was installed or opened, and no VM restart or network cut was made.
The user's physical-Mac restart check remains open.

## Evidence

- Local redacted recordings: `results/offline-status-20261019/before.mp4` and `after.mp4`.
- VM `.local/phase2/m13-final-checks.log`, `m13-final-source-build.log`, `m13-unit.log`,
  `m13-check-summary.json` and `m13-runtime-log.ndjson`.
- Public API contracts: [research A12](../research.md#apple-file-provider).

To repeat, keep a completely downloaded file, then keep a partial file while downloads are paused.
Resume without leaving the pane, verify both checksums with hydration forbidden, eject through
Servers, confirm the native mount is absent, and verify again. Toggle File Provider off and on,
then remove the test requests and location.

## Next step

Use an isolated writable fixture to test file changes without touching NAS content. A temporary
SMB share backed by a disposable VM folder is proposed in the [M13 plan](../phase3-plan.md#m13-verified-offline-status-for-kept-files).
Enabling VM File Sharing needs approval before that test can run.

## Follow-up, 2026-10-19

The user approved the isolated VM fixture. The applied-version gate now uses the public
stabilization barrier and fresh URL metadata, with successful source-change and offline checks.
All 161 tests and required checks passed. See the [version-check results](2026-10-19-offline-versions.md)
for the evidence, conservative waiting behavior and remaining limits.
