# Disk-space protection, 2026-10-21

Decision status: accepted behavior; implementation and VM checks completed on 2026-10-22.

M16 passed the signed isolated VM checks and all 192 tests and required builds, with no Swift
warnings. Blocked keeps recover after app relaunch and space recovery, without overriding manual
Pause. Completed copies remain intact. All fixtures are removed and sharing is restored.
The signed build is ready. Physical-Mac installation and low-space checks remain; the installed
M15 app is unchanged. Publication is not approved.

## Setup and policy

Checks ran on October 21 and 22 in macOS VM 1, on macOS 27, using a disposable read-only guest
SMB share and local APFS staging. The source fixtures were 0 B to 8 MiB. No NAS data changed.
Cache state was uncontrolled; this is a correctness check with no speed claim. Hash checks
for completed copies prohibited hydration, so a missing copy could not silently download.

The shipping reserve is 2 GiB, an implementation policy rather than a measured macOS requirement.
One budget covers reader sessions across locations. Each request reserves twice its payload plus
64 KiB for staging and handoff; written bytes reduce outstanding reservations. Range accounting
uses payload size, not a sparse file's logical end offset. Capacity is checked every 16 MiB.
Recovery requires another 64 MiB of headroom. Other processes can consume space between checks;
this does not impose an OS quota or evict existing kept files.

Signed pressure checks used a separate source archive with only the budget constructor changed.
The before/after UI run compared M15 with an M16 build whose reserve left 8 MiB at launch. For
repeatable final recovery checks, the test constructor capped reported capacity at 8 MiB for
90 s after launch, then 128 MiB, while also honoring actual ordinary available capacity. The
system disk was never filled. The final signed build restored the shipping constructor.
A separate 256 MiB disposable APFS image exercised actual ENOSPC without that test cap.

## Results

| Check | Result |
| --- | --- |
| Same Finder Keep Downloaded action before/after | M15 completed the 8 MiB file; M16 rejected it and showed Not sufficient space and a free-space instruction. |
| Independent kept copy | Remained Available offline and matched its source hash during the blocked request. |
| Native Finder error | Reported that the file could not be saved because there was not enough space. The provider returned Cocoa 640; a POSIX full read surfaced errno 60, so ENOSPC propagation to every caller is not claimed. |
| Retry after relaunch | Relaunch preserved the blocked state. The recovery loop later logged a successful public download request and the file matched its source hash without hydration. |
| Manual Pause | The 8 MiB file stayed unmaterialized after capacity returned while paused. Resume allowed the recovery loop to retry; both kept copies then matched. |
| Real disk-full volume | Admission rejected before staging. An unguarded transfer hit actual ENOSPC and removed its partial output. Freeing space allowed recovery and a matching hash. External pressure during a transfer removed its partial stage and preserved a completed copy. |
| Shipping signed build | A freshly evicted 8 MiB file completed Keep Downloaded and matched with hydration forbidden. A fresh 4 KiB demand read also matched. |
| Required checks | Tools/run-checks.sh passed 192 tests, release CLI verification, project generation and the unsigned app build. No Swift warnings. |

Public pending-item and URL error projections did not expose the failed request after relaunch.
The app therefore saves only opaque retry records in BlockedDownloads.json, atomically in the
App Group. Settings and catalog formats do not change. Every retry checks current keep intent,
version and location state. If saving fails, in-memory recovery remains active, but relaunch
cannot restore an unsaved request. Unit tests cover round-trip, missing state, clearing,
invalid IDs, mismatched records, negative/overflowing ranges and preservation on rejected writes.

An initial raised-reserve experiment did not observe capacity recovery after a system-volume
filler was deleted. The signed app's statfs value stayed unchanged while the CLI value changed;
the cause was not established. The final code reads uncached ordinary Foundation volume capacity.
The real-volume check passed capacity rejection and recovery with that implementation. The
final signed retry check used the explicit test cap above to avoid unrelated VM disk activity.

## Evidence and cleanup

Local recordings are results/disk-space-protection-20261021/before.mp4 and after.mp4, with a
comparison image. They show the same keep action; scroll positions differ slightly. They remain
local and are not published. The VM holds m16-final-checks.log, m16-volume-check.json,
m16-verify-paused-after-relaunch.json, m16-verify-resumed.json and m16-verify-default-after.json
under .local/phase2. These records use fixture IDs and counters.

Removed the test location without saving its keep list, its downloads, saved test server, SMB
mount/share/backend, filler and disposable volume/image. Original share definitions match their
snapshot; smbd is unloaded, SMB guest access is off and the guest account remains off. Final app
diagnostics show zero catalogs, kept requests and stage files, with the original one share and
session retained. No test fixture descriptor remains. Cairndex was untouched. No VM restart or
network cut was used. A final message-only audit found zero private-pattern matches in 167
messages. The host app and provider still run from Applications; the prepared build has the
same bundle and unchanged sandbox entitlements, and passes strict/deep signature verification.

Physical-Mac low-space behavior, QSpace, OS eviction of unkept copies under pressure, multiple
signed locations competing for space and a macOS restart remain unverified. Shared reservation
accounting is unit-tested. No dependency or sandbox change was made.
