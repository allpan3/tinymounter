# SMB file organization checks

Date: 2026-10-29. Within the approved M21–M26 disposable VM session.

All nine organization protocol cases pass on the disposable Samba server. Protected moves
preserve the original object, complete contents, permissions and attached streams. This does
not complete M21. Older catalog rows have no historical server identity, so admitting them
still needs a decision. No new Finder operation is enabled.

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
Signed Finder moves, departure notifications, preserved downloads, name-derived native IDs,
cross-filesystem refusal and large-file cost still need verification.

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
implemented. Compilation and signed Finder checks remain; this protocol run predates that code.

Source review found a stale-callback defect: a filename-only callback could carry an old parent
and accidentally move a file back after another view moved it. The provider now carries the
changed fields to app admission, which refuses mismatches in fields the user did not change.
Matching durable intents still replay before new admission. Core regressions cover both a stale
parent on rename and a stale name on move; signed overlapping-view checks remain.
