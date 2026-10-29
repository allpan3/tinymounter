# Same-object save protocol

Date: 2026-10-28. Decision status: the revised Mac-only M19 design and disposable VM fixture
are accepted. The CLI protocol gate and normal signed TextEdit saves pass, including a
concurrent-edit conflict. VM 1 became suspended during the final recovery check. Its remaining
checks and fixture cleanup await permission to resume; the agent did not suspend the VM.

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

The fixture remains active. Its temporary Homebrew/Samba installation, isolated server state,
disposable Keychain and synthetic files must be removed, and saved system state verified,
before handoff. No shared daemon, VM or network restart, physical-Mac installation or publication
is part of this experiment.

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
then launches the normal signed candidate.

| Stop point | Normal signed recovery |
| --- | --- |
| Complete local preparation | Completes; local export matches and all three source lifecycle guards refuse changes |
| Complete remote stage | Completes with no retained artifact |
| Verified old-content backup | Completes with no retained artifact |
| Original renamed, contents still old | First launch restores the old original and retains the edit; a second launch completes |
| Complete new contents before publication | Completes with no retained artifact |
| Verified publication before acknowledgement | Stop is verified; recovery result was not collected before VM suspension |

Each stopped generation retained valid complete local content. The helper seeded Keep Downloaded
requests for identity checks. A separate downloaded file was hashed with hydration forbidden;
its after comparison and final ID/keep audit remain. Partial upload/copy and further conflict
variants remain unverified in the signed app, although the CLI and unit checks above cover
partial-copy retention. No VM or shared daemon was restarted.

The three old diagnostic `.preparing` records predate the metadata fixes. A signed fixture helper
verified each synthetic payload against complete remote conflict copies, exported the payloads,
and removed only those three test records. This is test-state cleanup, not product recovery.

### Recordings and remaining checks

The baseline shows M18 TextEdit reporting the file as locked. The candidate uses the same
initial synthetic contents and select-all, type `Edited test document.`, Save sequence. Its
remote bytes match after completion. Caches are uncontrolled and these clips make no timing
claim. Both clips are encoded with current AVFoundation APIs. The capture scale changed between
runs, so framing review remains. Interruption/conflict variants, lifecycle preservation and
complete fixture cleanup await VM resumption.

Cached-credential connections take about 20 seconds on this fixture, also in the earlier unsigned
CLI control. This exceeds the existing 15-second share-health stall threshold and can transiently
mark the test share unresponsive. Authentication succeeds; the cause is not established. The
stall threshold is unchanged, and no physical-Mac latency claim follows from this fixture.


Before handoff, 11 obsolete host signing copies were removed. The normal verified candidate,
current fixture-test build and recording baseline remain. Guest storage and window cleanup
cannot proceed while the VM is suspended; the temporary fixture and dependencies still exist.
