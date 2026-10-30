# Permanent-deletion protocol checks

Date: 2026-10-29. Within the approved M21–M26 disposable VM session.

The isolated deletion probe completed successfully, including eleven process-interruption
scenarios and guarded cleanup. It also confirmed a safety limitation: another SMB client can
add attached data while the main file is protected. M24 is not enabled. Accepting deletion of
the whole object, including data added during the operation, still needs a decision.

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

Decision status: proposed. Permanent Delete removes the selected object and all its attached
data at deletion time, including attached data added during the operation. The main contents
still require protected complete-content verification, and in-use files still refuse deletion.
This is not implemented. Without that boundary, the current transport cannot prove the full
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
