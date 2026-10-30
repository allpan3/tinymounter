# SMB file organization checks

Date: 2026-10-29. Within the approved M21–M26 disposable VM session.

All nine organization protocol cases pass on the disposable Samba server. Signed Finder moves
also preserve item IDs, content versions and downloaded copies, including across overlapping
locations and app interruption. The user accepted current-object admission for unverified files.
M21 remains incomplete: the remaining signed refusal cases, matched recordings and limits below
still need evidence.

## Setup and evidence

macOS VM 1 ran macOS 27.0.1, the production SMB library with the rename encoder fix, and
Tools/check-file-organization.py. The second client used the existing isolated publication
helper and its private Keychain credential. Files contained 65,792 synthetic bytes. Cache
states were uncontrolled; this is correctness evidence, not a performance measurement.
The original NAS stayed read-only. No Apple sharing/account settings, shared daemons or
network settings changed.

Evidence remains in VM .local/phase4/m21-20261029/organization-04/result.json and its log.
Earlier failed runs remain alongside it. The fixture is still open for the approved remaining
checks; cleanup and exact state restoration are still owed. Installation remains deferred.

## Results

| Case | Observed result |
| --- | --- |
| File move | Same server identity, exact destination name and complete bytes; source name absent. Live permission changes, attached stream, existing reader and neighbor preserved. |
| Collisions | Ordinary, case-only, Unicode, canonically equivalent Unicode and competing-create collisions returned EEXIST and preserved both files. |
| Access denied | Denied source/destination permissions refused the rename with EACCES; source intact, destination absent. |
| Changed or replaced file | Full digest detected an in-place rewrite with unchanged size/mtime. Identical-byte replacement had a different server identity; original remained elsewhere. |
| Replaced parents | Fresh direct-SMB evidence detected both replacement parents, including a case alias, and the replacement file. |
| Folder move | Directory and child identities and child bytes survived. A reader below the directory blocked the move with EACCES; closing it allowed the move. |
| Crash before request | Fresh protection proved the old name and contents. A competing destination made retry refuse without changing either file. |
| Crash after request | Fresh protection proved the destination and contents. Recreating the source produced a different object and left the moved original intact. |
| Reconnect | A new production connection proved the moved file and both parents again. |

SMB write/delete opens against the guarded file and delete opens against each protected parent
returned ETXTBSY. Native file/parent renames returned EBUSY, including the separately held
directory case. The probe now requires EBUSY for these native guard checks; an absent stale
pathname cannot count as protection. Saved observations from this run satisfy that stricter
requirement.

The moved file's change time changed, but modification time did not. A folder move changed the
folder's change time; its child's recorded times were unchanged. Native IDs equaled the server
IDs in this fixture and survived the moves. This does not reproduce pathname-derived native
IDs observed on the original NAS. Native metadata could also lag direct SMB: one initial file
fingerprint differed, and cached lookups after parent replacement still described old objects.
Admission cannot rely on a native stat as fresh identity evidence.

The timestamp-restoration requests succeeded, but change time still differed afterward. This
run therefore did not reproduce an indistinguishable metadata replacement. The missing-history
problem follows from the catalog's stored information, not from claiming this experiment forged
all timestamps successfully.

## Test setup corrections

The first two runs failed some setup steps because new backing directories were absent from
the native client's cached listing. Creating those directories through the raw SMB probe also
failed with EACCES in the third run. The final runner precreates its fixed synthetic directories
before the native client first observes their parent. No server setting changed to achieve this.
Native Unicode observations now use the spelling returned by directory enumeration, and native
timestamps come from an integer stat helper. Missing observations remain missing, not changes.

The production library is the source already covered by 294 VM tests, the required builds and
six packet-encoding cases. Only probe setup and evidence collection changed for this run.
The signed integration checks below followed this protocol run. Pathname-derived native IDs,
cross-filesystem refusal and large-file cost still need runtime verification.

## Admission decision

Decision status: accepted on 2026-10-29. For a never-verified file and its selected parents, bind the request
to the objects currently at those paths when protected admission begins. Require the known
catalog metadata to match, exact directory entries and fresh server identities. Read and record
the file's complete contents under protection, then retain that evidence through publication
and recovery. A prior replacement that matches all known metadata may therefore be moved as
the current file. Existing verified revisions still require their recorded identity and bytes.

Keep legacy downloaded copies and their evidence level unchanged. A move must not upgrade one
to a verified editing base or claim that an old copy was compared when it was not. Subsequent
editing still requires a verified full download. This decision changes initial selection
semantics only; it does not permit metadata-only recovery, overwrites or copy/delete fallback.
Production admission, durable parent evidence, file moves and saved keep-path updates are
implemented. The integrated candidate passes all required VM checks: 346 tests, one optional
skip, no failures or Swift warnings, and six encoder cases. Evidence is in the session's
m21-final-checks-01.log. Signed Finder checks remain; this protocol run predates that code.

Source review found a stale-callback defect: a filename-only callback could carry an old parent
and accidentally move a file back after another view moved it. The provider now carries the
changed fields to app admission, which refuses mismatches in fields the user did not change.
Matching durable intents still replay before new admission. Core regressions cover both a stale
parent on rename and a stale name on move; signed overlapping-view checks remain.

The first signed Finder rename of a never-downloaded file initially returned serverUnreachable,
then recovered automatically and renamed the server object. Admission opened a protected SMB
connection, persisted its evidence, then released that connection before opening another for
publication. The fixture's roughly 20 s authentication exceeded the unchanged 15 s health
threshold, so the second session admission failed. Initial publication now keeps the admission
connection and guards. Recovery still opens a fresh connection and revalidates recorded evidence.
Required checks and the signed repeated rename and cross-folder Move Item Here pass after this
correction. The moved file retains its server identity and complete contents; the neighbor is
unchanged. The next case-only rename exposed a second delete-capable handle against the same
object and returned ETXTBSY before mutation. Case-only admission now releases that file handle
before the transaction reopens and fully revalidates it; parent guards and the connection stay
held. Required VM checks and the signed case-only rename now pass. Evidence is in
m21-case-checks.log and m21-case-guard-before.json / m21-case-guard-after.json.

An isolated app-owned audit confirmed that the never-downloaded file retained its item ID and
f1 content version through the rename and move, and still had a dataless local placeholder.
The audit forbids hydration on its thread. After their moves into a kept folder, the legacy
downloaded and verified kept files retain their item IDs, f1/e1 content versions, local inodes
and full local digests. The legacy file inherits the destination's keep without gaining an
explicit request; the verified file keeps its explicit request. Local verification succeeds
with hydration forbidden.
Evidence is in m21-downloaded-moves-comparison.json and its before/after app-owned audits.
Overlapping-view and interruption checks are recorded below.

Moving two files together then exposed a stale health state: the first move completed, but the
second callback arrived before the periodic probe cleared Unresponsive and was refused. A
successful operation on the current mount session now resolves that timeout before returning.
The 15 s stall threshold stays unchanged. Success cannot restore a missing mount or denied
grant, and an old session cannot restore a replacement session. Required checks pass with
349 tests, one optional skip and no Swift warnings in m21-health-checks.log. The previously
refused move completed after the update. A fresh two-file Move Item Here back to Inbox completed
both callbacks successfully without the stale-timeout refusal. Evidence:
m21-paired-move-health-after.json. This is functional evidence, not a move-speed claim.
After moving out of the kept folder, the legacy file loses inherited retention and the verified
file retains its explicit keep. Both still have their original f1/e1 versions.

## Overlapping views and interrupted moves

Two writable locations exposed the same synthetic folder. Moving the verified file through
Finder in one location removed it from the other location's already-open Inbox. Both catalogs
recorded Archive as its parent. Each view preserved its own item ID, e1 version, explicit keep,
local inode and complete local digest. The app-owned audit forbade hydration. Evidence:
m21-overlap-before.json, m21-overlap-after.json and m21-overlap-comparison.json.

The isolated signed test build then stopped before sending a move and, in a separate case,
immediately after the server completed it. Killing that stopped app and restarting recovered
both operations. Before publication, every server file was unchanged. After publication, the
selected file had its original server inode and full digest at the destination, and the old
name was absent. Neighbors were unchanged. Both views retained their item IDs, versions, keeps,
local inodes and complete local digests after recovery; all move intents reached completed.
Evidence: m21-interrupt-before-* and m21-interrupt-after-* in the same VM session. Stop and audit
hooks remain confined to the test archive.

Recovery also exposed redundant verification: queued retries and replayed callbacks reopened
the same verified intent while its settings update and completion were pending. Each fixture
authentication took roughly 20 s, so these repeated connections delayed completion and produced
temporary Unresponsive notifications. Completion now keeps one set of waiting callbacks per
intent on the share's serial queue. Recovery skips that intent while settings finish, and
replayed callbacks wait for the same result. Failure releases the waiters for a later retry;
restart still requires normal durable recovery. Required VM checks pass: 356 tests, one optional
skip, no failures or Swift warnings, and six encoder cases in m21-completion-checks.log. A signed
repeat of the post-move interruption used one recovery connection and completed the replayed
callback. Both views retained their IDs, versions, keeps, local inodes and full digests, and the
intent completed. Evidence: m21-completion-recovery-log.json, m21-completion-connection-count.json
and m21-completion-comparison.json. Neither interruption lost data. These are correctness
observations with uncontrolled cache state, not performance results.
