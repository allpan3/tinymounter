# Same-object save protocol

Date: 2026-10-28. Decision status: the revised Mac-only M19 design and disposable VM fixture
are accepted. The CLI protocol gate, normal signed TextEdit saves, conflicts and recovery
retention checks pass. Partial work remains unresolved, with complete versions retained and
the local edit exportable. All 264 tests and required VM checks pass, with one optional fixture
skip. The disposable fixture is removed, original settings are verified and task windows are
closed. The verified M19 build is now installed on the physical Mac; installation checks are
recorded below. Physical-Mac writes remain unverified.

Basic saves preserve the original remote object, its live permissions and attached stream on
the disposable Samba fixture. Empty, growing and shrinking files, a competing destination and
connection loss pass. All six process-crash boundaries and ancestor protection pass.
Low-space recovery retains the complete versions after an uncertain copy, and protected cleanup
preserves a changed artifact. These are CLI protocol
results, not signed app or TextEdit verification.

## Setup and method

Tests run only in macOS VM 1, macOS 27.0.1, with standalone Samba 4.25.1 on loopback. The server
uses its private account database, acl_xattr and streams_xattr. Two test identities map to
existing local accounts; no macOS account is created. Native SMB uploads the payload, and the
vendored libsmb2 supplies protected handles, queries, COPYCHUNK, flush and exclusive rename.
Direct connections request signing and encryption. Caches are uncontrolled; no performance
claim is made. The original NAS remains read-only.

The first test created a private stage, uploaded and verified the complete edit, then held the
original against competing main-content access. It copied and verified the old contents into a
private backup before renaming the original. A second SMB client changed its permissions and
wrote a 27-byte named stream. COPYCHUNK updated the original's main contents; exact-length,
flush and whole-file checks preceded its exclusive rename back. Reconnection checks compared
the complete old/new bytes, original identity, live permissions and attached stream.

The independent account can read the public original but cannot read the private copies.
The follow-up also starts with an original owned by that account. Each stage is created empty
with a verified empty DACL. Its server-assigned owner supplies the private access rule before
any payload upload. That owner differs from the original's owner. This avoids granting private
staging access based on the owner of an unrelated existing file.

## Observations

| Check | Result |
| --- | --- |
| Shrink 8 KiB to 4 KiB | Original identity, concurrent permissions and stream survive; both copies match after reconnect |
| Different original owner | Native upload and same-object save pass; the other account cannot read stage or backup |
| Empty original to 4 KiB | Pass |
| 8 KiB original to empty edit | Pass |
| 1 MiB original to 16 MiB edit | Pass |
| Competing create at the original name | Exclusive publication refuses; competing bytes and both versions survive |
| Disconnect after the first 1 MiB of an 8 MiB edit | Partial work file, complete 4 MiB backup and complete 8 MiB stage survive reconnect |
| SIGKILL after staging | Original unchanged; complete local and remote edit retained |
| SIGKILL after backup | Original unchanged; complete old/new remote copies and local edit retained |
| SIGKILL after first rename | Fresh identity and complete-content evidence permit exclusive restoration of the old original |
| SIGKILL after partial copy | Partial work stays untouched; complete backup, stage and local edit survive |
| SIGKILL after complete copy | Exclusive restoration of the complete new original succeeds |
| SIGKILL after publication | Fresh identity/content evidence permits acknowledgement without another write |
| Protected parent directories | Existing delete access blocks the guard; competing direct and native renames fail |
| Actual remote-volume exhaustion | An uncertain copy leaves partial work; fresh SMB reads verify both complete copies and local input |
| Cleanup after verified publication | Protected deletion removes the proved stage; a backup with newly attached data is retained |

Existing main-content readers and writers prevent acquisition of the original-file guard.
New competing SMB writes fail while it is held. Native macOS reads return EAGAIN. The first
matrix attempt incorrectly rejected that refusal because it expected a different sharing error;
a focused repeat confirmed EAGAIN for empty and nonempty files. The corrected check records
the error and still requires denial of access.

The first ancestor test failed during setup: this Samba package created a directory with
backing mode 000 despite a stored Everyone access rule, preventing creation of its child.
A repeat uses pre-existing synthetic directories prepared locally, which matches M19's
existing-file scope. It then found that a metadata-only directory open does not exclude an
already-open delete handle. Adding directory-list access makes the guard effective: incompatible
existing access blocks it, new delete opens fail, and native ancestor rename returns EBUSY.
Both ancestor identities and the original file's path and contents remain unchanged. The raw
folder-creation setup failure remains separate from this passing existing-directory check.

## Recovery and limits

Process-crash checks write and sync the complete pending input outside the remote fixture,
stop the test client at a named boundary and send SIGKILL only to that child. Fresh SMB
connections inspect recorded identities and complete contents. They restore only complete
old or new original objects with an exclusive destination. Partial contents stay retained.
These checks do not implement application recovery or simulate server power loss.

The work file remains the user's original object and is never a cleanup candidate. Stage and
backup are new transaction files covered by the accepted requirement that other programs leave
them alone. The tests do not establish application-exclusive ownership for a shared SMB account.

The temporary fixture, Homebrew/Samba installation, isolated server state, disposable Keychain
and synthetic files are removed. Cleanup verification is recorded below. No shared daemon, VM
or network restart, physical-Mac installation or publication was performed.

## Evidence and next step

Sources are Tools/check-edit-in-place.py, Tools/check-edit-recovery.py and the fixture-only
Tools/check-edit-publication.c library. Tools/check-edit-space.py checks actual ENOSPC only
when a separate bounded disposable volume is mounted under the fixture. Its 128 MiB APFS
volume reached ENOSPC on native close, after ENXIO on a buffered write. The first runner stopped
before copying because it did not retain both errors. A separate copy attempt ended with an
uncertain transport result. Fresh SMB connections verify the recorded backup, stage and original
identities. Both complete versions and the local input survive, while the changed 4 MiB work
file remains unresolved and untouched. Backing-volume reads independently agree. This establishes
retention after actual space exhaustion, not reliable ENOSPC delivery from COPYCHUNK. All synthetic
content files are limited to 16 MiB; the VM's ordinary storage remains available.

Private evidence is in VM .local/phase2/m19-same-object-20261028: first.json,
foreign-owner.json, empty-base-v2.json, empty-edit-v2.json, large-grow-v2.json,
collision-v2.json, interrupted-v2.json, native-read-detail.json and the crash case directories.
The current C probe compiles without diagnostics; its Python sources pass syntax compilation.
Earlier 244-test required checks cover the unchanged app foundations, not this new protocol.

The existing production credential code also connected to the fixture using macOS-cached GSS
credentials, with no password acquisition or mutation. Its callback returned the expected
existing-directory identity. Evidence: cached-auth.json. This is an unsigned CLI authentication
check; signed app authentication is established by the saves below.

The CLI gate allowed app integration. Signed checks below cover the subsequent implementation
under the [accepted design](../phase4-plan.md#revised-mac-only-save-proposal).

## Signed app integration

The normal signed app completes a first recovered save, a fresh repeated TextEdit save and a
concurrent-edit conflict. Exact remote contents match. The repeated save updates the original
without a conflict or leftover stage/backup. For the conflict, a native SMB client changes the
original after the editor receives its base. The app preserves those competing bytes and
publishes exactly one new copy containing the local edit, then acknowledges completion.
Three earlier diagnostic conflict copies are separate from that test.

`fileproviderctl evaluate` reports uploaded after the recovered save. The local text-encoding
and last-used attributes remain present. TextEdit sends contents with date and extended-attribute
fields. Metadata-only retries return those fields as unsupported using the SDK's documented
contract. No remote date or attached-data synchronization is claimed.

The integrated transaction retains immutable generations, strong base receipts and original
catalog IDs. A changed strong receipt invalidates a fetch even when native size and times match.
Uncertain namespace changes defer overlapping-location reconciliation. Complete old or new
originals can recover through an exclusive rename; partial work stays retained. Cleanup never
removes the original work object. Pending edits block disabling writes/editing and changing or
removing the location, and can be exported locally.

Signed checks exposed three integration problems that are now corrected:

- macOS changes security attributes when it copies callback input. A durable sidecar retains
  the exact original metadata; generation matching excludes per-copy access, quarantine and
  provenance attributes. Existing snapshots remain authoritative. A crash before the snapshot
  exists can replay matching document contents with the new callback's security attributes.
- The exclusive publication handle blocks native final inspection. After durable publication,
  the adapter reacquires read-compatible protection and rechecks identity, complete contents
  and modification time. A change in that gap retains the transaction. Native directory
  enumeration refreshes name caches without reconciling transaction artifacts.
- Native staging adds quarantine. Verification records its complete bounded stream and cleanup
  compares it. Unknown or changed attached data retains the artifact; original-file streams
  remain untouched. An old test stage without this evidence required verified fixture
  maintenance. That removal is not counted as automatic cleanup; the fresh save cleans itself.

All 26 focused outbox/transaction tests pass, and the personalized app builds without Swift
warnings. These include replay after interruption before the metadata snapshot. Final
Tools/run-checks.sh passes: 264 tests, one optional fixture skip and no failures. Project
generation, release CLI/benchmark validation and the unsigned app build also pass, without
Swift warnings.

### Signed interruption checks

A separate source archive adds fixture-only stop points; production sources contain none.
The helper is restricted to the disposable domain and synthetic test names. It uses the app's
real outbox, protected transport and recovery paths. Each check stops and kills only that app,
then launches the normal signed candidate. Matching-input replay checks use the same source
method in the signed fixture helper, with stop points disabled.

| Stop point | Recovery result |
| --- | --- |
| Before the local metadata snapshot | Intent survives; matching input completes the same generation |
| Complete local preparation | Completes; local export matches and all three source lifecycle guards refuse changes |
| After 1 MiB of a 4 MiB native stage upload | Original remains unchanged; incomplete stage and complete local edit stay pending |
| Complete remote stage | Completes with no retained artifact |
| Verified old-content backup | Completes with no retained artifact |
| Original renamed, contents still old | First launch restores the old original and retains the edit; a second launch completes |
| After the first 1 MiB copied into the hidden original | Signed replay refuses partial work; full old backup, full stage and complete local edit survive |
| Complete new contents before publication | Completes with no retained artifact |
| Verified publication before acknowledgement | Fresh normal launch acknowledges and cleans up without another content write |

The partial-copy case leaves the original name absent. Its 2 MiB work file contains 1 MiB of
edited bytes and 1 MiB of old bytes. Repeated readback confirms that recovery leaves it untouched.
Normal launch and Retry Pending Saves sometimes defer before inspection because of the fixture
connection delay described below. A targeted signed replay reaches recovery and returns
unresolved. The normal app's Export Local Copy save panel exports the complete 4 MiB edit,
with an exact byte match. Automatic repair of partial work is not claimed.

The final audit confirms valid complete content and matching exports for all three retained
generations, and refusal by all three source lifecycle guards. Nine completed test generations
retain their original catalog IDs and Keep Downloaded requests, including the tombstone for a
deleted original. An independent downloaded file retains its inode, size and digest with
hydration forbidden before and after the tests.

The VM became suspended during the checks and was resumed with the user's approval, preserving
its session. The after-publication case initially retained its artifacts after EPERM; a fresh
normal launch completed it. No VM or shared daemon was restarted.

The three old diagnostic `.preparing` records predate the metadata fixes. A signed fixture helper
verified each synthetic payload against complete remote conflict copies, exported the payloads,
and removed only those three test records. This is test-state cleanup, not product recovery.

### Additional conflict checks

Signed probes of the source's edit method also pass these cases:

- A competing SMB edit changes the bytes while preserving size and modification time. The
  competing original survives, and exactly one conflict copy contains the local edit.
- A deleted original stays absent, and exactly one conflict copy contains the edit.
- With failOnConflict, the competing original survives, no conflict copy appears, and the
  complete local edit stays pending and exportable.
- Disabling editing rejects an edit request and leaves the original unchanged.

These use the real signed source/edit path. The specific File Provider deletionConflicted
callback was not separately invoked. Broader editor compatibility and physical-Mac writes
remain unverified.

### Recordings and fixture limitations

The baseline shows M18 TextEdit reporting the file as locked. The candidate uses the same
initial synthetic contents and select-all, type `Edited test document.`, Save sequence. Its
remote bytes match after completion. Caches are uncontrolled and these clips make no timing
claim. Both clips are encoded with current AVFoundation APIs, and their first and last frames
were inspected. The before clip uses note.txt and the after clip uses recording.txt with the
same starting contents. VMPal's capture scale changed, so the framing differs. These are matched
workflow recordings, not a timing comparison.

Cached-credential connections take about 20 seconds on this fixture, also in the earlier unsigned
CLI control. This exceeds the existing 15-second share-health stall threshold and can transiently
mark the test share unresponsive. Authentication succeeds; the cause is not established. The
stall threshold is unchanged, and no physical-Mac latency claim follows from this fixture.

### Cleanup and evidence

After the retention checks, a fixture-only helper verified and exported all three remaining
synthetic generations before removing their test records. The normal app removed the test
location with Save the Keep Downloaded list off, then removed its server and ejected its SMB
connection. Final diagnostics show no locations, catalogs, keeps or staging files, and retain
the original share and session. This maintenance does not provide a product discard action.

Only the task-owned Samba processes were stopped. The disposable credential, private server
state, socket, 128 MiB disk image, synthetic files and all 20 temporary Homebrew formulas were
removed. The Homebrew prefix did not exist before the fixture and is gone again. Apple's
sharing records, SMB launch override, guest settings and Keychain search/default settings match
their original snapshots. Apple SMB remains unloaded. The original NAS stays read-only.

TextEdit and tinymounter are closed, Finder has no windows, and the user's Terminal process is
retained. The current verified app and useful evidence remain. On this VM, October 28 `du`
inventories account for about 1.8 GiB of removed test data and build output; they do not measure
host disk-image compaction or physical space reclaimed. The remaining repository build output
is about 12 MiB. Obsolete host signing copies and temporary recording/build files are also
removed.

Selected local evidence is in results/m19-same-object-20261028 and the VM evidence directory
above. It includes signed stop/recovery receipts, signed-final-audit.json,
signed-partial-retention.json, signed-ui-export.json, retained-download-after.json,
final-checks.json, final-cleanup.json, runtime-hooks.diff and both editor recordings. Private
settings snapshots remain only in the VM and are excluded from copied evidence.

## Physical-Mac installation, 2026-10-28

The user approved installation. The retained normal signed M19 candidate replaced M18 in
Applications after a normal quit and bundle backup. Strict/deep signature verification passed.
The app and provider retain their bundle identifiers, App Group and exact entitlements, including
the sandbox. Their installed executables and the SMB library match the verified candidate.
Both processes run from Applications.

The old app was first reopened in the background to collect fresh startup diagnostics, because
macOS denied direct access to its private settings and catalog. Before and after the update,
launch reconciliation reports one location, catalog and domain, with no unknown domains or
failed sequences. Diagnostics retain 12,920 live items, two tombstones, 3,393 listed folders,
one share/session, zero keep requests and zero staging files. The open catalog ID also matches
the prior M18 installation evidence. These checks establish retained registration and matching
counts, not an independent comparison of every item ID or downloaded byte.

The installer changed no locations, write permissions, grants, mounts or caches. M19 still
requires its separate editing opt-in. Settings migration and preservation of individual IDs,
keeps and downloaded bytes were checked in the VM; private container access and downloaded-byte
comparison were unavailable in this physical-Mac installation check. No Settings window was
opened, no app was activated and the pointer was not moved. No NAS write was performed.

Only the tinymounter app and its own provider were stopped. No shared daemon, VM or network
restart occurred. The production code is unchanged from the completed 264-test VM run, so the
required checks were not repeated for this installation and documentation update. Evidence is
in results/m19-install-20261028. No push, publication or merge occurred.
