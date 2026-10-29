# Same-object save protocol

Date: 2026-10-28. Decision status: the revised Mac-only M19 design and disposable VM fixture
are accepted. The CLI protocol gate passed; normal Save remains disabled pending app integration.

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
check; the signed app route remains unverified on this fixture.

Proceed to app integration. Signed TextEdit saves, conflict
and app-crash recovery, lifecycle preservation, matched recordings and final required checks
remain necessary under the [accepted design](../phase4-plan.md#revised-mac-only-save-proposal).
