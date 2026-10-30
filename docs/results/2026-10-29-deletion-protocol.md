# Permanent-deletion protocol checks

Date: 2026-10-29. Within the approved M21–M26 disposable VM session.

The isolated deletion probe completed successfully, including eleven process-interruption
scenarios and guarded cleanup. It also confirmed a safety limitation: another SMB client can
add attached data while the main file is protected. The user accepted deletion of the whole
object, including data added during the operation, on 2026-10-29. M24 is not enabled.

After a lost reply, absence cannot distinguish deletion from a move elsewhere. The probe
reports that state as absent, unconfirmed. This matches the roadmap's existing requirement
to preserve uncertainty; it is not evidence that the object was deleted.

## Setup

macOS VM 1 ran macOS 27.0.1 and the approved loopback-only Samba fixture. The C helper includes
the existing publication probe and adds complete paginated listing and exact-status capture.
The Python runner accepts only the fixed disposable endpoint and backing/mount paths. All
objects are synthetic, within one random subtree, and file payloads are 65,792 bytes. Cache
states were uncontrolled; no performance is claimed. The original NAS remained read-only.

The helper compiled and the Python syntax check passed in the VM. Runtime evidence is in
.local/phase4/m21-20261029/deletion-01, including result.json, the object ledger, neighbor
snapshots and per-interruption receipts. Compilation and execution logs are beside it.

## Observations

| Operation | Result |
| --- | --- |
| File and empty-folder deletion | Protected identity/content checks passed. The name and recorded identity disappeared only after completion. File streams disappeared too; recreating the name did not inherit them. |
| Competing access | SMB read/write/delete opens returned sharing_violation. Native unlink, rename and rmdir returned EBUSY after the object was proved visible. |
| Existing handles | Each incompatible reader, writer and deleter blocked protected deletion. With a deliberately shared reader, the name remained delete_pending after the deleting handle closed, until the last reader closed. |
| Changed/replaced file | Changed complete contents and an identical-byte replacement were refused; both retained objects remained provable. |
| Read-only file | The attribute was set successfully. Delete returned cannot_delete and preserved the file. |
| Arriving child | SMB child creation succeeded both before the delete mark and after it. The mark or close returned directory_not_empty; folder and arriving child survived. |
| Populated folder | The server refused with directory_not_empty and preserved the complete tree. This is not recursive-deletion evidence. |
| Parent replacement | The held parent blocked rename. A later replacement was detected without deleting its occupant. |
| Untouched neighbors | Complete bytes, attached stream, permissions, owner, mode and identity matched the baseline. Complete folder listings matched the ledger. |

The eleven interruption cases killed only probe processes. File/folder crashes before the
delete request allowed a freshly proved retry. Crashes after marking or closing returned
absent, unconfirmed. Competitor rename within the parent, rename elsewhere, replacement,
changed bytes and changed streams produced the expected distinct recovery outcomes. No retry
deleted a replacement or changed object.

DELETE_PENDING mapped to ENOENT in the errno adapter. Production deletion recovery must retain
the exact SMB status, because treating that error as an absent object would be wrong.

## Attached-data decision

The competing client successfully added a named stream while the deny-all main-file handle
was held. The guard observed the stream and the probe preserved it. A further stream change
after a final check would still be possible, so another read cannot close this race.

Decision status: accepted on 2026-10-29. Permanent Delete removes the selected object and all its attached
data at deletion time, including attached data added during the operation. The main contents
still require protected complete-content verification, and in-use files still refuse deletion.
App deletion is not implemented. Without that boundary, the current transport cannot prove the full
concurrent-attached-data guarantee.

## Cleanup and remaining work

The probe removed 51 proved synthetic objects and found four interruption targets already
absent. Cleanup completed with no retained objects from this run. This does not mean the
whole fixture session is closed: its server, credential and dependencies remain for the
approved work, and final restoration is still owed. No Apple sharing/account settings, shared
daemons, VM power state or network settings changed.

The integrated source's required checks already pass with 332 tests, one optional skip and
no Swift warnings. These two probe files add no production capability and need no project
generation. Signed Finder deletion, warning/callback semantics, recursive deletion, runtime
identity admission and exact-status production wiring remain unverified. No installation,
publication or original-NAS write occurred.

## Transaction core, 2026-10-30

A one-object deletion core now models the protected request and its recovery checkpoints.
It reloads durable state on every call and requires identity, complete main-file contents,
the exact name and a complete parent listing before marking deletion. Empty directories also
require a complete empty listing. Changed attached data follows the accepted whole-object policy.

A successful close reply must be durably recorded before later absence can confirm deletion.
Without that acknowledgement, absence remains unconfirmed. Once close is acknowledged, retries
only verify the outcome; they never issue another deletion. A replacement, changed contents,
changed parents or movement to another name prevents automatic retry. Every persistence failure
stops the current call, including failures after the durable write may have succeeded.

The core accepts caller-supplied evidence, a remote interface and atomic persistence callbacks.
It adds no disk format, adapter, catalog mutation or File Provider capability. Endpoint binding,
root and pending-write exclusions, older-reader refusal, recursive progress and UI remain
integration work. On 2026-10-30 the user extended current-name selection to unverified-file
deletion: known details must match, and the admitted object must be protected and verified.
Previously verified files retain historical checks. Recovery never targets a later replacement.

Twenty-seven simulated-remote tests cover request/close/checkpoint interruption, stale callers,
changed or replaced objects, incomplete listings, exact absence classification and arriving
children. Source review found no blocking defect. Tools/run-checks.sh passes on the integrated
source in macOS VM 1: 441 tests, one optional skip, no failures or Swift warnings, project
generation, release CLI validation, unsigned app build and six encoder cases. Evidence:
.local/phase4/m21-20261029/m24-core-checks.log. These are simulated-remote tests, not signed
deletion or SMB adapter evidence; M24 remains incomplete.

## Exact server errors, 2026-10-30

The production SMB client now exposes the exact status from its last failed server reply.
Every operation clears the previous status, including local validation failures and successful
cleanup closes. Transport failures and synthetic timeout/shutdown callbacks provide no server
evidence. Swift copies the status into the error before cleanup; existing filesystem error
codes and collision handling stay unchanged. Failed information queries also stop interpreting
the server's error payload as a successful data reply.

A standalone regression uses the real request encoders and deterministic callbacks without
opening a connection. It covers distinct absence and pending-delete replies, cleanup, local
errors, malformed successful replies and teardown callbacks. All 57 cases pass in VM 1.
The required checks also pass: 441 tests, one optional skip, no failures or Swift warnings,
project generation, release CLI validation, unsigned app build and six encoder cases.
Evidence: .local/phase4/m21-20261029/m24-status-checks.log. The callback tests establish error
classification in the adapter; they do not establish live deletion behavior. This adds no
deletion capability.

## Production adapter preparation

The Swift adapter now implements the one-object deletion contract without exposing a File
Provider capability. A fresh session protects the parent chain and holds the selected file
or empty directory with deny-all sharing. File evidence uses a complete digest and requires
one link. Listings continue through every page. Only an exact name-not-found reply supplies
name absence; delete-pending, path-not-found and transport errors remain distinct.

Deletion and close use the same target handle. Confirmation opens the name afresh after the
acknowledged close. The session retains no stream or native handles on the target. Review found
no unsafe-deletion defect under the fresh-session contract. It also found character-based path
splitting in the shared parent helpers; these now use the existing byte-safe path components,
so a leading combining mark cannot hide a parent separator. Required VM checks pass: 472 tests,
one optional skip, no failures or Swift warnings, project generation, release CLI validation,
unsigned app build, six encoder cases and 57 status cases. Evidence:
.local/phase4/m21-20261029/m24-adapter-checks.log. Initial live adapter results follow below. Durable
operation storage, catalog mutation and the user-facing deletion flow remain unimplemented.

## Signed adapter attempt, 2026-10-30

Two regular-file deletions passed in the signed, sandboxed app in macOS VM 1. Both recorded
an acknowledged close, then confirmed name and identity absence with fresh protected checks.
The run stopped during connection setup for the next case. Empty-folder deletion, paginated
confirmation, changed/replaced-file refusal and interruption recovery remain unverified through
this production adapter. No File Provider deletion capability is enabled.

Setup admitted nine targets in a new synthetic subtree. The large directory's complete listing
contained 513 entries with at least 127,086 encoded bytes, exceeding one SMB listing buffer.
Before the run, a controlled in-place write retained one file's identity, and an identical-byte
replacement received a different identity. Its original was retained separately. Cache state
was uncontrolled; this is a correctness check, with no performance claim.

The first setup failed after one admission. A fresh setup passed after its reports were retained
and all 522 fixture files were checked unchanged. The deletion run then completed its first two
cases before another failure. In both failures, logs show a cached credential followed by
`smb_connect result=-1`, surfaced as `NSPOSIXErrorDomain:1`. This locates the failure in connection
setup; it does not establish the underlying cause. The seven remaining intents stayed prepared.

An isolated continuation helper compiles without Swift diagnostics and passes strict signature
verification in the VM with the same sandbox entitlements. It requires the two successful case
reports and the other seven original intents before continuing. It allows at most three
connection attempts, records failures and never retries the deletion body in that loop.
Automatic approval review blocked replacing and registering the VM test app, treating it as
an installation change outside the fixture-session approval. The verified continuation is
staged but has not run. Production transport and deletion code are unchanged.

Private evidence in `.local/phase4/m21-20261029` includes `m24-adapter-setup.jsonl`,
`m24-adapter-setup2.jsonl`, `m24-adapter-run.jsonl`, the Finder-copied `m24-adapter-*-inspection`
directories, `m24-adapter-between.json`, `m24-continuation-build.log` and
`m24-continuation-verification.json`. The failed reports and original test app remain intact.
The fixture session remains open; final removal and restoration are still owed.
