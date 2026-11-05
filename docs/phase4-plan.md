# Phase 4: write support

The [accepted SMB simplification](smb-simplification.md) replaces custom remote recovery and
content proofs. Implementation and signed VM checks are complete; read-performance targets
remain unmet. Earlier dated implementation notes describe their historical builds.

Date: 2026-10-23. Decision status: accepted. M18 starts phase 4 of
[architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria) with new files
and folders, then adds editing and conflict handling in later milestones. The remaining phase 3
checks are still open; starting this design does not mark them passed.

The [remaining roadmap](roadmap.md), accepted on 2026-10-29, sets the full sequence after M20
and its parallel workstreams. The accepted M18 to M20 contracts below still apply.
The user's [standing VM permission](roadmap.md#delivery-and-approval), granted on 2026-10-31,
supersedes the per-session VM approval limits recorded below; feature and safety gates still apply.

Native upload decision, 2026-10-23: the user accepted exclusive creation through native SMB.
Other devices can see a new file while it uploads, including a partial file after interruption.
Keep the complete local pending copy until remote completion is verified. Existing destinations
must remain untouched. The [API checks](results/2026-10-23-upload-publication.md) explain why
exclusive creation replaces the earlier temporary-sibling publication design.

## First milestone: create files and folders

M18 lets the user create a folder or copy a new file into a File Provider location in Finder.
Existing locations stay read-only. The user must explicitly enable changes for a location and
select its share again to grant write access. Passwords still belong to macOS and Keychain.
The first implementation and all destructive checks use disposable VM data, not the user's NAS.

Limit the first milestone to creating ordinary files and folders, including the initial naming
step after Finder creates an untitled folder. The user accepted that extension on 2026-10-23.
Replacing or editing existing files, general renaming, moving and deleting come later. A name
collision fails without changing the existing item. Do not make an editor's save look successful
when it requires an operation that this milestone does not support.

The visible behavior is:

- Finder can create a folder and copy a new file into the enabled location.
- A file is not reported as uploaded until the server has accepted the complete file.
- An interruption keeps the user's pending data locally. Reopening the app resumes or reports
  the unresolved operation without silently making another copy.
- A location with pending writes cannot be removed or have its source changed. Its data and
  configuration remain available until the writes finish or a later explicit recovery action
  resolves them.
- Read-only locations keep their present behavior, IDs, keep requests and downloads.

## Implementation boundaries

The main app continues to own SMB access and catalog writes. The extension requests mutations
through restricted IPC, and the app checks the location's write permission on every request.
Use Apple's user-selected read-write entitlement and a fresh scoped grant for the approved
location. Keep the sandbox enabled and the extension's permissions limited. A read-only grant
must never be silently upgraded.

New-item uploads keep complete local contents and the operation state needed for retry under
the supported File Provider URL-lifetime rules. Existing-file saves use the M19 callback below.
This prototype does not migrate older settings, catalogs or pending work. Finish or export that
work with its original build before Start Fresh. No new dependency is needed.

Create a new file's final name exclusively through SMB. Other devices may see incomplete contents
until upload completes. An interruption preserves the complete local pending copy. An acknowledged
partial upload restarts the complete write only after checking its recorded server identity.
An uncertain create retries exclusive creation; an existing name remains unresolved. Do not retry
under another name. Use exclusive folder creation and finish parent creation before its children.

A timeout can leave completion uncertain. Retain the pending copy and retry using recorded
identity evidence. Acknowledgment requires the expected identity, final size, flush and close;
there is no remote full-file readback. Never overwrite an unrelated destination on a create retry.

## Checks before claiming M18 works

Use a dedicated writable SMB fixture in macOS VM 1. Temporarily enable only that test share,
snapshot its settings, and restore them after removing all test data. The original NAS remains
read-only. Do not restart the VM, cut its network or stop shared system services.
The user separately approved one File Provider daemon restart for the stale-state diagnostic
on 2026-10-23. That restart is complete; it does not authorize other service restarts.

Verify a new file and folder in the signed sandboxed app, then compare the complete local and
remote file contents. Test same-name collisions, read-only locations and denied grants. Interrupt
the test app during staging, before publication and after remote commit but before acknowledgement.
The resumed operation must finish or remain clearly pending without losing the complete local
copy or overwriting an unrelated destination. Test removal/source-change refusal with pending
writes. Record matched before/after Finder actions.

Run Tools/run-checks.sh in the VM, update affected reference docs, and finish with a dated result
and README status. A physical-Mac install, publication and real-NAS write tests need separate
approval. This approval does not authorize them.

## Implementation status, 2026-10-23

Creation, explicit write grants, migrations and durable pending copies are implemented. All 208
VM tests and required checks passed. Signed extension callbacks through authenticated IPC passed
file/folder creation, and signed app stops checked recovery and pending-write lifecycle guards.
After the approved daemon restart, normal Finder file and nested-folder uploads passed with
matching hashes and native progress. Initial naming now passes the signed follow-up below;
file Keep Both now passes the signed follow-up at the end of this plan. See the
[results](results/2026-10-23-create-items.md).

Initial folder naming, decision status: accepted, 2026-10-23. The user approved handling the
initial name of a newly created folder. General renaming remains a later milestone. Native
exclusive folder rename failed, and a create/delete alternative deleted another client's
replacement folder in a controlled race. Neither route is suitable. An isolated direct SMB
client passed collision and competing-create checks. The authentication follow-up below resolved
the credential-probe defect. The initial naming callback, durable recovery state and signed
Finder checks pass. See the
[naming investigation](results/2026-10-23-initial-folder-naming.md).

Next step, decision status: accepted, 2026-10-23. After the dependency explanation, the user
asked to continue the fix. Prototype `libsmb2` for folder creation and initial naming, keeping native
reads and file uploads. The corrected credential probe and a signed sandboxed connection passed
without password acquisition. The [authentication follow-up](results/2026-10-23-folder-naming-authentication.md)
records the earlier probe defect and the LGPL-2.1-or-later obligations. Preserve the macOS-managed password contract.
Catalog version 4 separates the current lookup key from the immutable enumeration key, keeping
existing cursors and item IDs across naming. Migrations from versions 1, 2 and 3 preserve user
state. The final client passed read-only credential/identity checks on the NAS, signed fixture
creation/naming and interrupted recovery. All 230 tests and required checks passed with no Swift
warnings. File Keep Both now passes the follow-up below.

Folder-creation transport, decision status: accepted, 2026-10-23. Read-only NAS checks found
that native inodes are name hashes while direct SMB returns the server's object identifiers.
The earlier comparison therefore refused naming. Use direct SMB for exclusive folder creation
as well as initial naming, retaining the server identity from creation and keeping native catalog
identity separate. File uploads and reads remain native. The user approved this extension.
The client holds directory handles against replacement while recording the server identifier
and creation time, then binds native metadata to the receipt. Recovery checks that server
identity and creation time; a native name hash cannot prove ownership. Older folder receipts
without server proof remain readable but cannot authorize naming. Initial naming finishes before
TinyMounter creates children in that folder. A folder with child creation receipts cannot start
another naming operation, which would move those saved paths and become general renaming.
Signed verification passed on the disposable VM fixture; real-NAS writes remain unverified.
See the [identity findings](results/2026-10-23-folder-naming-fix.md#native-identifier-mismatch).

Keep Both follow-up, 2026-10-25: signed VM trials isolated Finder's need for rename capability
before it chooses the incoming copy's name. The implementation enables that capability in
locations with changes enabled. Finder also offers ordinary Rename, which the backend still
refuses. The accepted transport and create-only boundaries remain in force. Definite collisions
now include the existing catalog item in the error; uncertain uploads cannot change names.
All 232 VM tests and required checks passed. Final signed file Keep Both, repeated-collision,
byte-preservation, folder-copy and read-only Finder checks passed. The fixture is removed and
sharing is restored. The VM create checks are complete; physical-Mac writes remain unverified.
See the [results](results/2026-10-25-keep-both.md).

Physical-Mac installation, 2026-10-27: the user approved installing M18. The app and provider run
from Applications with the existing catalog ID and diagnostic counts retained. The location
remains read-only. Physical-Mac writes await the user's run; see the
[installation results](results/2026-10-25-keep-both.md#physical-mac-installation-2026-10-27).

## M19: online editing

Decision status: the ordinary SMB design was accepted on 2026-11-04. It replaces the earlier
remote recovery transactions. See [SMB simplification](smb-simplification.md) for the contract
and [VM results](results/2026-11-05-smb-simplification.md) for current evidence.

### Supported saves and boundaries

A writable location accepts whole-file content updates to ordinary existing files. The app
opens the current server file, writes the supplied contents, sets the length, flushes and closes
it before returning success. A competing edit may be overwritten. A failed or interrupted write
can leave partial remote contents, as an ordinary SMB write can. NAS snapshots and backups own
previous-version recovery. There is no remote backup, stage, recovery name or conflict copy.

The provider copies the callback contents once into the App Group for the app's access. That
copy is temporary; macOS owns the pending local item until the callback succeeds. Errors leave
it pending. Connection failures use the retryable server-unreachable error. Settings lists
system pending items and offers Retry Pending Changes. This does not promise retention of every
intermediate save or a previous remote version.

Ordinary saves accept stale base versions. Explicit fail-on-conflict requests are honored by a
metadata check, but the provider no longer advertises that optional capability. Missing targets
are not recreated by an edit. Packages, combined rename/content requests and unsupported document
metadata remain limited by the observed File Provider callbacks.

Scoped write access, account identity, ancestor containment, server permissions, cancellation,
complete-range reads and truthful completion remain required. Reads transfer each requested
range once with metadata checks; they do not establish an editing base or hash the remote file.

### Validation

The separate signed VM installation checks normal saves, competing edits, shorter and empty
contents, offline retry and a mid-write server interruption followed by app/provider restart.
The interrupted upload must retain complete local contents and retry to the exact server bytes.
Low-space admission keeps the 2 GiB reserve. Broader editor coverage, full OS restart, original-NAS
behavior and physical-Mac performance need their own evidence with this implementation.

### Revised Mac-only save proposal

The October 28 transaction and November 4 rechecks are historical designs, superseded above.
Their protocol and runtime evidence remains in [same-object saves](results/2026-10-28-same-object-save.md)
and [save rechecks](results/2026-11-04-save-recheck.md).

## M20: file renaming

Proposed 2026-10-28; accepted 2026-10-29, including the disposable VM fixture. The user also
approved replacing the separate creation and editing controls with one Read only toggle.
Implementation and signed VM verification are complete. The [results](results/2026-10-29-file-renaming.md)
record Finder behavior, recovery, preservation checks and remaining limits. The historical result describes that build; current validation is linked above.

### What the user gets

Rename an ordinary file in Finder, for example Notes.txt to Meeting notes.txt, in the same folder.
Keep its contents, permissions, attached data, item ID, downloads and Keep Downloaded request.
If another file already has the requested name, refuse the rename and leave both files alone.
This addresses the current Finder Rename action, which is advertised for Keep Both but fails
for existing files.

The initial milestone required a verified M19 revision. M21 now admits ordinary catalog files
with server identity and metadata checks, without downloading or hashing their contents.
Folder organization follows M22. Finder Replace and combined rename/content callbacks remain
outside the verified capability set. M18 initial folder naming continues unchanged.

Creation, editing and renaming use one write mode. A Read only toggle defaults off for new
locations. Adding a writable location obtains the macOS share grant. The 2026-11-04 UI decision
removes the SMB-only eligibility warning; ordinary overwrite races are accepted.
Existing read-only locations remain read-only. Already confirmed M19 write access also permits the supported M20 rename.
Legacy creation-only grants retain their existing access and pending work until the user
completes the one-time write confirmation; they do not silently acquire editing permission.
The UI reports that unfinished setup without separate controls for individual write features.
Read only blocks new remote changes and cannot be enabled while mutations are pending. Retain
the saved scoped grant and confirmation when toggling it, so permission is not requested again
for the same source. A different source needs new scoped access and confirmation.
The first milestone is online only. A pending rename is visible, prevents source/location removal
or permission revocation, and does not claim completion until verified. Existing pending content
edits or uploads must settle before the file can be renamed.

### Publication and recovery

Use the catalog's server identity and metadata to identify the selected original. Hold its ancestor
directories and a source handle that prevents competing main-content writes, deletion and
renaming. Check the source's server identity and metadata against the catalog revision. A
changed or replaced source stops the operation without mutating either pathname. Unsupported
identity or protection is a refusal, not permission for a weaker route.

Durably record the item, parent, exact old/new names and source evidence before sending one
handle-based SMB rename with replacement disabled. This changes the name of the original object;
it copies no payload and writes no file contents or access rules. A destination collision never
falls back to replacement or copy/delete. Case-only changes must work through the same protected
operation and exact-name verification, or fail clearly. No temporary-name sequence is proposed.

Verify the resulting object's identity and metadata before acknowledging completion.
Commit the new name under the original catalog ID, keep its enumeration key and keep requests,
and preserve content revisions when their bytes are unchanged. Refresh native metadata without
turning a name change into an unnecessary download. Reconciliation must defer during uncertainty
and apply the known rename to affected overlapping locations while preserving their own IDs.

After a lost reply or crash, inspect both names with fresh protected SMB evidence. Complete only
when the requested name holds the recorded object with matching metadata. Retry the old-to-new rename only
when the old name still proves the original and the exclusive destination is available. If the
source changed, disappeared or moved elsewhere, retain the operation and report the uncertainty.
Never rename a competing object back, infer success from a missing old name, or search the share
and guess. Local pending content from other operations remains untouched.

### Transport and verification gates

This expands the approved use of libsmb2 from initial naming and internal save transactions to
user-requested file rename. Reuse its existing protected opens, identity/readback queries and
no-replace rename. The adopted direct client also handles reads and uploads. macOS credentials,
encryption requirements, dynamic linkage and licence obligations stay the same.

The user approved a fresh disposable loopback-only Samba session in macOS VM 1,
with the same bounded synthetic files, temporary dependencies and private Keychain credential
used for M19. Do not create a macOS account, register a service or change Apple's sharing settings.
Snapshot the affected state, then remove the fixture, credential and temporary dependencies and
restore that state at the end. Stop only task-owned processes, close task-owned apps/windows and
remove obsolete test artifacts. Keep the original NAS read-only. No VM/shared-daemon restart,
network cut, physical-Mac installation or publication is included.

Before app integration, verify that the existing protocol preserves object identity, complete
contents, live permissions and attached data for a user-selected destination. Check competing
source changes and destination creates, existing open handles, case and Unicode collisions,
ancestor changes, and interruption before the request and after remote completion. Any failed
safety gate needs a design decision before proceeding.

Then test the signed Finder workflow, repeated renames, refusal of unverified files, read-only
and opt-in enforcement, interaction with pending saves, overlapping locations, restart recovery,
and preserved IDs, keeps, downloads and pagination. Use fresh state when persistent formats
change. Record matched before/after Finder actions, run Tools/run-checks.sh in the VM, and update
the affected docs, results log and README in the implementation commits.

## M21: organize ordinary files

Date: 2026-10-29. Decision status: accepted. The [remaining roadmap](roadmap.md) expands the
earlier verified-file move proposal to online rename and move for ordinary files, including
files never downloaded. The identity gate below is part of this milestone. The user approved
the scope and first disposable VM protocol session. Later signed organization results are linked
from the roadmap; the physical Mac retains the pre-simplification build.

### What the user gets

Rename an ordinary file or move it between existing folders in Finder, for example from Inbox
to Archive within the same location. Keep its contents, permissions, attached data, item ID
and downloaded copy. An explicit Keep Downloaded request follows the file. Retention inherited
from a folder follows the destination folder's setting; moving does not explicitly evict a
downloaded copy. Use the existing write mode, without another feature switch.

Admission uses server identity and metadata for both downloaded and never-downloaded files,
without silently hydrating or evicting those copies. The move may include a new filename, but
cannot include changed contents.
Refuse a destination collision without overwriting or automatically choosing another name.
Pending uploads, edits or renames involving either path must settle first. Read-only access
remains enforced. Folder moves belong to M22. Moves between locations or shares, deletion,
Replace, offline moves and combined move/content saves remain outside M21.

For overlapping locations, initially allow only moves whose old and new paths remain within
the same set of registered location roots. Every affected catalog must be available and able
to represent both parents. A move that crosses another location's boundary is refused before
remote mutation. This keeps each location's existing item ID and downloads intact; entering or
leaving an overlapping location needs a later identity and retention design.

### Publication and recovery

For a previously verified file, bind the selected item to its recorded server identity and
metadata. For an unverified file, the accepted admission rule below binds the operation
to the current object after known catalog details match. It does not establish historical
identity or compare a legacy downloaded copy. Preserve existing IDs, cached contents and their
evidence level through the transition.

Extend the protected rename transaction to include the source and destination parents. Resolve
both from catalog item IDs, validate them against fresh listings, and hold both ancestor chains
against deletion or replacement. Capture the server identities of the protected directories
at admission and retain them with the operation. Native pathname-derived inodes alone cannot
prove parent identity after interruption. If a selected parent cannot be bound to the protected
directory without guessing, refuse the move. This does not add general external-rename matching.

Check the original file's server identity and metadata against its catalog revision,
or record that evidence under protection at admission for an unverified file.
Durably record both paths, parent identities and all affected catalog views before one SMB
handle rename with replacement disabled. The server moves the original object; no payload
upload, copy/delete fallback or permission rewriting is allowed. Unsupported cross-filesystem
or server behavior must fail clearly.

Verify the destination's exact name, original file identity and metadata before
committing local success. Update parent, name and native lookup metadata under the original
item ID, preserve its content version and enumeration key, and recompute inherited retention.
Each catalog updates the move atomically. Deliver the move through the working set under the
original item ID, without deleting or recreating it: macOS ignores signals for other containers
from a replicated extension (`NSFileProviderManager.h`). If the system asks a folder enumerator
for changes, the old parent reports the departure and the new parent the arrival. A durable
receipt covers partial completion across catalogs and repeated provider callbacks.

After interruption, revalidate the recorded directories as well as both file paths. Complete
only when the destination proves the original object with matching metadata. Retry only when the original
still exists at the source and the recorded destination remains safe. A renamed or replaced
parent, changed source or ambiguous result retains the pending intent and reports the problem.
Never infer success just because the old path is absent, move another object's contents, or
undo a competing client's change. Pending work protects both paths and blocks source changes,
write-mode revocation and removal of every affected location.

If the persistent contract expands, change the format without a migration or downgrade guard:
until release, locations are added again after a format change.

### Transport and acceptance gates

The SMB rename wrapper accepts a destination path with replacement disabled. The provider,
durable intent and catalog now support parent changes. The installed File Provider SDK exposes
allowsReparenting for moving an item between folders. The integrated implementation passes
required VM checks; signed Finder checks remain. Cross-folder publication and recorded directory
recovery identities passed the isolated protocol checks below. Current organization uses server
identity and metadata, with no payload hashing. Folder moves still inspect descendant metadata;
no constant-time or large-tree performance claim is made.

The isolated Tools/check-file-organization.py probe passes all nine cases in the
[VM protocol run](results/2026-10-29-file-organization-protocol.md), including protected file/parent
identities, full bytes, permission and stream preservation, collisions, replacement races and
interrupted publication. A passing protocol run alone cannot prove the
historical identity of a legacy catalog row: those rows have no recorded server identity, and
native lookup IDs can be derived from names. A replacement with identical metadata can therefore
match an old row. On 2026-10-29 the user accepted binding unverified files and selected parents
to the current objects at admission, after matching known details. Record protected identity
and metadata evidence for the operation and retry; preserve the evidence level of local
copies. Observed files retain their identity and metadata checks. This boundary is
implemented; signed Finder verification remains.

This accepted scope expands libsmb2 use to user-requested cross-folder moves and the protected parent
identity queries needed for recovery. It adds no dependency or server component. The existing
client now handles remote reads and writes as well. macOS-managed credentials, encryption
and existing licence obligations remain; there is no SMB-only writer eligibility requirement.
First prove that cross-folder rename preserves original identity, complete contents, live
permissions and attached streams, including between folders with different permissions. Check
destination races, denied access, source changes, replacement of either parent and interruption
before and after server completion. A failed safety gate requires a decision before app integration.

Then verify normal signed Finder Rename, drag and Move Item Here for verified, legacy downloaded
and never-downloaded files. Cover repeated moves, collisions, read-only refusal, pending-save
exclusion, both explicit and inherited keeps, overlapping locations, pagination and interrupted
recovery. Include same-size/timestamp changes and identical-byte replacement. Compare item IDs,
local and remote identities and full downloaded bytes before and after, including an untouched
neighbor. Record matched M20/M21
workflows and run Tools/run-checks.sh in macOS VM 1.

The approved fixture is a new session of the disposable loopback-only Samba setup used for
M20, with synthetic files, temporary dependencies and a private disposable Keychain credential.
Do not create a macOS account, alter Apple's sharing settings, restart a shared daemon or VM,
or cut the network. Snapshot affected state, then remove task-owned server processes, mounts,
data, credentials, dependencies, apps/windows and obsolete builds; verify restoration and keep
useful evidence. The original NAS stays read-only. No physical-Mac installation, push,
publication or merge is included.
