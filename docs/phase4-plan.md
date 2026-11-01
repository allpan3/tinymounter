# Phase 4: write support

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

Save pending bytes and operation state durably before acknowledging a change that still needs
uploading. Keep an app-owned immutable copy under the supported File Provider URL-lifetime
rules. Persist only the operation state needed for restart and commit recovery. Any settings
or catalog change needs migration from the installed format and tests that preserve user state.
No new format version field or dependency is justified merely to track this work.

For a file, create its final name exclusively with `O_CREAT | O_EXCL`. Never open an existing
remote file for writing. Other devices may see incomplete new content until upload completes.
An interruption preserves the complete local pending copy. After an ambiguous attempt, prove
remote ownership and complete content before acknowledging success; otherwise retain the copy
and report the unresolved operation. Do not retry under another name. Use exclusive folder
creation and handle parent creation before dependent child operations.

A timeout after publication can leave the result uncertain. Reconcile using tested remote
identity evidence and complete content checks before marking the operation uploaded. If the
result cannot be proven, retain the pending copy and show the problem. Never guess success,
overwrite an unrelated file or retry under a new name without a user decision.

## Checks before claiming M18 works

Use a dedicated writable SMB fixture in macOS VM 1. Temporarily enable only that test share,
snapshot its settings, and restore them after removing all test data. The original NAS remains
read-only. Do not restart the VM, cut its network or stop shared system services.
The user separately approved one File Provider daemon restart for the stale-state diagnostic
on 2026-10-23. That restart is complete; it does not authorize other service restarts.

Verify a new file and folder in the signed sandboxed app, then compare the complete local and
remote file contents. Test same-name collisions, read-only locations and denied grants. Interrupt
the test app during staging, before publication and after remote commit but before acknowledgement.
The resumed operation must finish once or remain clearly pending, with no data loss, overwrite or loss of the complete local pending copy. Test removal/source-change refusal with pending writes and migration
from the installed settings/catalog formats. Record matched before/after Finder actions.

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

Date: 2026-10-27. Decision status: accepted. The user approved this scope after reviewing the
normal save, conflict, recovery and temporary missing-file behavior. Ordinary implementation
decisions are delegated. The user subsequently accepted restricting editing to folders whose
writers all use SMB. Programs accessing the server filesystem directly, including other
protocols, are outside this safety boundary. Enabling editing must explicitly confirm this
requirement; existing write-enabled locations do not acquire editing permission automatically.
The protocol gate and signed checks of TextEdit, conflicts, retention after interruption,
export and lifecycle guards pass. Partial work remains unresolved. The fixture is removed and
original settings are verified; the results log records compatibility limits and connection delays.
The user approved physical-Mac installation on 2026-10-28. The verified build is installed,
with matching background startup counts. Physical-Mac saves remain the user's checks; see the
[installation results](results/2026-10-28-same-object-save.md#physical-mac-installation-2026-10-28).

The replacement sequence below failed its metadata-preservation gate. The user reaffirmed
Mac-only operation: use the server's existing SMB service, with no tinymounter server component.
The user approved the [revised design](#revised-mac-only-save-proposal) on 2026-10-28;
its protocol gate passed before app integration. The replacement sequence below is superseded
by that same-object transaction.

Implement whole-file content updates to ordinary existing files in explicitly write-enabled
locations. Preserve the old remote file under a recovery name, then publish the complete edit
with a second exclusive rename. Both operations must use checked SMB handles and prohibit
replacement. This is a recoverable transaction, not an atomic replacement: other clients can
observe the original name missing between the two renames, and an interruption can prolong
that gap. The user accepted this availability tradeoff. Uninterrupted access at the original
name is not promised.

### Why this publication route

The reviewed SMB2 rename request has a source handle, destination name and ReplaceIfExists
flag, but no expected destination version or identity. Replacement therefore does not supply
compare-and-swap. An open that denies write and delete sharing protects the old file from
other SMB opens, but the standard replacement algorithm can reject an open target. Closing
that protection before replacing the target restores the race. Compound requests, byte locks
and oplocks are not a documented transaction across validation and replacement.

The existing native results also rule out assuming that Foundation supplies a safe exclusive
rename. Apple's published smbfs implementation removes an existing target before renaming the
source. These are API/source findings, not new runtime results or a claim about all servers.
See [research W6–W9](research.md#upload-publication).

Two no-replace renames avoid deleting an unchecked destination. Move the old file through
the same handle used to validate it; if another client creates the original name before
publication, leave that client's file untouched. The old file remains at its recovery name
and the local edit remains in the outbox.

### Supported saves and boundaries

The initial user workflow is opening an existing plain-text file in TextEdit, editing, saving
repeatedly and reopening it. Include direct content writes and the temporary-file replacement
used by document editors in signed VM checks. Apple's NSDocument documentation describes
temporary-directory and old-revision rename save routes. File Provider reports logical changes
through modifyItem with baseVersion; it can combine content, date, name and parent changes.
Documentation does not establish which callback sequence TextEdit produces in this build.

Accept content updates and the associated supported date fields for the same item, parent and
name. A local editor's temporary-file save is supported only if File Provider presents it as
that logical content update. Do not infer permission to replace from a same-name create, use
mayAlreadyExist as replacement authorization, or implement remote rename/delete merely because
an editor requests them. Reject a combined unsupported name/parent change before mutating the
server; Apple's contract requires name and content changes to stay together. Honour
failOnConflict and preserve bytes when the system requests conflict handling itself.

General rename, moves, Finder Replace, deletion, directory/package editing, symbolic links,
hard-linked files, live databases and VM images remain outside M19. Detect extra streams,
resource forks and metadata that cannot be preserved; refuse publication rather than silently
drop them. Preserve and verify destination access permissions on the staged replacement before
moving the old file. Broader editor and metadata compatibility requires another decision.

This is online-first support. A save can race with disconnection, so pending data must survive
even though deliberate offline editing is not an M19 acceptance claim. An editor's successful
local Save is distinct from verified upload. Pending, conflict and unresolved outcomes need
visible status and a way to export retained content through an ordinary save panel.

### Base evidence and durable local content

Before any remote mutation, copy the callback's complete contents into immutable app-owned
storage, verify the copy and durably record its operation, item, base revision and digest.
Apple unlinks the callback URL after completion. Cancellation must not race that ownership
transfer or discard an already durable pending copy. Local space admission uses the existing
reserve; failure leaves the remote file unchanged and does not report upload success.

The current f1 size/time version cannot authorize replacement. Bind a trustworthy base receipt
to the exact content revision supplied to File Provider, with complete-content digest and
server identity evidence. A metadata fingerprint alone must not identify this receipt, nor
may a later read overwrite the evidence for an earlier revision. Establish receipts on verified
full handoffs and successful uploads. Partial downloads or legacy materializations without
such evidence take the conflict-copy path. Do not force eviction or redownload of existing
copies to seed receipts. The implementation must distinguish legacy revisions from new proven
revisions without changing the meaning of a version already handed to the system.

For partial reads of an `e1` revision, a bounded in-memory block-digest table may reuse the
evidence from a complete protected verification. Each fetched block must match that revision,
and the native staged range must match the protected range digest before handoff. A new request
still opens fresh protected ancestor/file handles and validates identity and metadata; no
handle or connection stays open between requests. A missing proof, remount, metadata difference
or block mismatch takes the full-verification path. Full downloads and mutations retain their
whole-file checks. No receipt or catalog format changes.

This preserves the bytes of the requested immutable version, not immediate detection of every
out-of-range change. A metadata-preserving edit outside the requested blocks is discovered when
those bytes are read, or during full-download/save verification. Unchanged requested bytes can
still satisfy the prior revision. The implementation keeps one table per location, with 1 MiB
blocks and at most 2 MiB of digests (64 GiB indexed); larger files use full verification.
These November 1 implementation choices follow the user's standing autonomous-development
instruction. [Signed VM checks](results/2026-11-01-verified-range-reads.md) measure the small-read
improvement, full-download cost and restart/remount fallback. Forced cached-read mutation races
and physical-Mac performance remain unverified.

Before moving the old file, compare its identity, complete digest and relevant metadata with
the base receipt while server-enforced protection is held. A native inode can be a name hash,
as M18 established; it is not server ownership proof. An SMB open FileId is also not sufficient
cross-session evidence by itself. Identity continuity and reconnect evidence are VM gates.
If protection cannot be acquired, defer; never close it to force publication through.

Repeated callbacks with the same base and contents reuse a durable receipt. A new local save
gets its own immutable generation. Serialize commits for an item and retain unresolved earlier
generations; a changed payload must not overwrite an uncertain pending operation.

### Remote transaction

1. Persist unique staging and recovery names and the transaction intent locally. Exclusively
   create the remote staging file through direct SMB and retain a handle that prevents its
   deletion or replacement. Stream the edit into that owned file through native SMB. This is
   permission to write the transaction's new staging file, never the existing user file.
2. Close the native writer, obtain write exclusion without losing the staging identity guard,
   flush and verify the complete staged content through direct SMB. Prepare and verify the
   supported metadata. Hold the stage and relevant ancestor identities through publication.
   Native/direct handle compatibility and cache coherence must pass before adopting this route.
3. Open the existing destination with the access needed for handle-based rename and readback,
   denying other write/delete opens. Validate the base under that protection. Persist intent
   before renaming this exact file to its unused recovery name, with replacement disabled.
4. Rename the verified stage to the original name, again with replacement disabled. A competing
   create wins its name and is never overwritten. Do not use ordinary native rename as fallback.
5. Verify the published identity and full content, then durably record the outcome and update
   the catalog under the original item ID. Retain its keep requests. Only verified completion
   permits upload success and disposal of the local pending copy.

Recovery files and stages are transaction artifacts, not completed user uploads. Suppress only
artifacts proved by receipts, never every file matching a name prefix. While a transaction is
active or uncertain, reconciliation must not turn its temporary absence into a tombstone or
let stale native listings undo the committed catalog state. Account for overlapping locations
in the same app. Other clients can still observe the stated namespace gap.

Internal cleanup is part of the accepted permission expansion. Before verified completion,
never delete the old recovery file or the complete local pending copy. Afterwards, remove only
the exact checked transaction artifacts through protected handles. A changed or unprovable
recovery file is retained and reported, never removed by pathname alone. This does not enable
the provider's general delete callback. It does not promise historical version retention after
a successful save, or survival of a server that violates acknowledged durability guarantees.

### Conflicts and interrupted recovery

A changed, deleted, replaced or unprovable base preserves the remote state and publishes the
local edit under an exclusive conflict name, such as `Report (conflict 2026-10-27 1430).txt`.
Persist the chosen name before publication. A definite collision can choose another name;
an uncertain result must first be reconciled. The original remote item keeps its ID and keep
requests; the conflict copy gets a new ID. Report that the edit was saved separately. Never
tell File Provider to replace its dirty local contents with the remote version until the
conflict copy is verified and durably represented in the catalog. Respect failOnConflict by
returning the conflict and retaining data instead of claiming automatic resolution succeeded.

If another client occupies the original name after the old file moved, preserve that file,
the old recovery file and the pending edit. Report the conflict. If the parent disappeared or
ownership evidence is missing, keep the edit locally and offer export; do not recreate a tree
or guess a destination. Handle deletionConflicted callbacks without discarding their contents.

Record each intent before sending its mutation. After an interruption, inspect the original,
staging and recovery names using fresh direct-SMB evidence. Resume or restore only when
identity, complete contents and the recorded state prove the action safe. Restoration is also
exclusive; it must never displace a competing file. A matching name, size or timestamp, an
absent temporary file, or a lost reply cannot prove success. If the new file matches the
recorded staged identity and bytes, finish the receipt without repeating publication. If it
changed again, or any evidence is ambiguous, retain pending data and report the uncertainty.
Do not reapply an old edit over a later remote edit.

Keep the existing guards against disabling writes, removing a location or changing its source
while pending or unresolved data exists. Upgrades retain settings, domains, catalog/item IDs,
anchors, keep requests, downloads and M18 receipts. Any required catalog migration must test
that preservation. No location reset is part of implementation or recovery.

### Transport approval and exit gates

Accepted libsmb2 expansion: exclusive regular staging-file creation, protected file/ancestor
opens, server identity and metadata queries, full readback verification, flush, no-replace file
renames, and handle-based deletion of proved completed transaction artifacts. Native SMB remains
the normal download and payload-upload path. If this mixed path cannot safely retain ownership
and exclusion, stop and request a transport decision; do not switch payload uploads silently.
Retain the existing macOS-managed credentials, encryption requirement, sandbox and dynamic
linkage. The vendored LGPL-2.1-or-later licence still requires source, notices and relinking
support before distribution; this is not release approval.

After design approval, obtain fresh permission to configure a disposable writable SMB fixture
in macOS VM 1. Snapshot and restore its sharing state. Keep the original NAS read-only. Never
restart the VM or shared daemons, or interrupt its network. Use only the test app/client's own
process or socket for interruption checks. The first implementation gate tests the proposed
regular-file protocol and native/direct interoperability before exposing editing in the app.

Required checks include concurrent SMB write/rename/delete opens, existing writer handles,
same-size timestamp-preserving edits, replacement at the same name, competing creates during
publication, missing parents, ambiguous replies, and changed recovery artifacts. Include
backing-filesystem interference to identify limits of SMB share-mode enforcement; do not claim
those modes lock server-local or other-protocol writers. A server/path without the required
exclusion must refuse same-name publication. Verify bytes as well as identities at every stop.

Interrupt during local staging, remote upload, before and after each rename, and after remote
verification but before local acknowledgement. Verify replay, subsequent saves, conflict-copy
collisions, lifecycle guards, read-only enforcement, migrations and stable item/keep identity.
Exercise the normal signed TextEdit workflow and local safe saves, not just direct callback
probes. Record matched before/after steps. Run Tools/run-checks.sh in the VM and record the
results and limits in the affected docs and README with the implementation commits.

Physical-Mac writes remain the user's checks. No new physical-Mac install, push, publication
or merge is authorized. The protocol route, actual editor callbacks, metadata coverage,
reconnect proof and performance cost remain unverified until these gates pass.

The fixture-only Tools/check-edit-publication.c and .py probe the first protocol gate without
changing the app. The C helper connects only to the named M19 loopback fixture; the
Python runner also verifies that exact native mount. The separately approved disposable
account can be selected with --authenticated-test-account; its password is read privately
from Keychain, never supplied on the command line. Compile the helper against the existing
libTinyMounterSMB.dylib in the VM, then pass its path with --library and the approved mount
with --fixture-root. The probe leaves its uniquely named synthetic files for inspection and
fixture cleanup. Use --check-metadata-exclusion to test competing SMB permission, timestamp
and named-stream changes while the original-file guard is held. Add --deny-all-sharing to
check the strongest share mode. The competing client writes only a fixed synthetic stream
payload; the app's payload transport is unchanged. Its JSON reports observations,
not a claim that M19 is implemented.
The [gate status](results/2026-10-27-edit-publication.md) records the approved writable VM probe.
Native/direct interoperability and publication passed against competing SMB clients. Direct
backing-filesystem writes, renames and deletion bypassed protection. The user accepted an SMB-only writer boundary after this result. Same-name editing requires
that explicit location opt-in; the client cannot establish server-wide access policy itself.
Use --check-backing-access to reproduce this limit on the disposable fixture. Transport errors
terminate the probe process with status 70 so queued callbacks cannot outlive their storage.
The authenticated follow-up also fails the permission-preservation gate: direct security
queries return STATUS_NOT_SUPPORTED and native SMB misses an explicit backing ACL. Do not
treat that as an empty ACL or publish a replacement. The user approved the standalone Samba
fixture in VM 1 and its test dependencies. Samba exposes the access rules, but competing SMB
permission, timestamp and nonempty named-stream changes bypass the original-file guard, even
with all sharing denied. This blocks implementation of the accepted save route; reading metadata
again cannot remove a race after that read. The fixture and temporary installation are removed.
No new boundary is accepted. Do not substitute static permissions, a ban on other clients'
metadata changes, or separate-copy saves without a new decision. A different payload transport
alone would not make the tested server serialize those operations.

### Revised Mac-only save proposal

Proposed 2026-10-27; accepted 2026-10-28, including the disposable VM fixture and its temporary
installation. The [CLI protocol gate](results/2026-10-28-same-object-save.md) passed on the
disposable Samba fixture. Signed TextEdit saves, conflict preservation, recovery retention and
local export pass, with item IDs, keep requests and an independent download retained. The
fixture and temporary dependencies are removed. Keep normal Save as the goal. Save Edited
Copy was not accepted and is not a substitute for this milestone.

Keep the original remote file object, including its permissions and unrelated streams, and
change only its main contents while it is away from its normal name. First preserve the old
contents in a separate remote recovery copy. This avoids copying stale access rules onto a
replacement and later deleting the original object with another client's attached data.
The protocol sources support investigating this route; they do not prove it safe at runtime.

**Accepted changes:** the original object is modified under a temporary name;
the old contents survive in a separate file rather than in the untouched original object.
Other readers must close the file before the update can start. It stays unavailable during
backup, copying and verification, potentially much longer than the previous two-rename gap.
New staging and backup files are disposable transaction storage: other programs, including
programs using the same SMB account, must not change, rename or delete them. SMB cannot enforce
ownership by one application. This additional boundary does not prohibit permission or stream changes to
the user's original file, even while that file has its temporary name.

The approved experiment uses this sequence:

1. Retain the complete immutable edit locally. Create a separate remote stage with private
   access rules, verified before putting content in it, and upload through native SMB.
   Flush and verify the whole stage under retained identity and write protection.
2. Open the original with read, write and rename access, denying other main-stream reads,
   writes and deletion. Hold the relevant ancestor identities. An existing incompatible open
   defers saving. Compare the original's identity, complete contents and base evidence;
   a mismatch follows the accepted conflict path without modifying it.
3. Exclusively create a private recovery file and copy the complete old main contents into it
   with SMB server-side copy. Flush and verify the whole backup before changing the original.
   Keep both backup and stage protected. No original permissions or streams are copied back.
4. Record intent, then rename the original to a unique work name without replacement, through
   the protected handle. Copy the stage into this same object, set its exact final length,
   flush and verify all edited bytes. Never perform this write at the ordinary pathname.
5. Restore that object's original name using another no-replace rename. A competing create
   is preserved; retain the work file, backup and pending edit and report the conflict.
   Verify identity and content again, record completion durably, and retain the catalog item
   ID and keep requests. Only then acknowledge upload and clean up proved disposable copies.

The work file is the user's original object, **never a disposable artifact**. Cleanup may
remove only new stage/backup objects with recorded ownership and complete-content evidence.
Known changes or uncertain ownership retain an artifact for recovery. Metadata races on these
new disposable copies are outside the proposed boundary; checking their metadata does not
make that boundary enforceable. Suppress only names proved by transaction receipts, not every
name with a prefix. Preserve unrelated files and all unresolved copies.

After a crash, first acquire fresh protection and inspect each recorded object. A complete old
or new original can be restored or acknowledged only with matching identity/content evidence
and an exclusive destination. An incomplete or changed original is not blindly overwritten:
retain it, the full remote backup and the local edit, report the uncertainty, and offer recovery
of the complete versions. The normal name can remain absent until recovery. A failed or
unsupported operation before step 4 leaves the original contents intact. Remote space failure
during step 4 must retain the already verified backup and local edit.

Local callbacks remain limited to same-item content updates. Preserve remote permissions and
unrelated attached data without rewriting them. Use the server's normal write timestamps;
do not restore a stale pre-save timestamp. Explicit date or attached-data changes requested by
an editor need a supported contract or must be refused. The TextEdit callback gate remains;
no general rename, move, delete, Finder Replace, package, database or VM-image support follows
from this proposal. Existing locations, IDs, keep requests and downloads remain unchanged.

**Transport expansion:** use the existing libsmb2 raw API for resume keys and
FSCTL_SRV_COPYCHUNK, exact-length updates on the hidden original, and private permissions on
new transaction files. Server-side copy is an ordinary SMB request, not installed server code,
and is not atomic. Native SMB retains downloads and stage payload uploads. There is no silent
fallback to direct payload uploads. A server that cannot demonstrate private staging, protected
copy, flush and recovery must refuse editing. No new app dependency is proposed; the existing
LGPL distribution requirements still apply.

The first gate is a CLI experiment in macOS VM 1, with fresh fixture approval on 2026-10-28. Recreate the
previous standalone, loopback-only Samba fixture and its temporary dependencies, private
account database and Keychain credential. Do not create a macOS account, register a service
or change Apple's sharing settings. Use only synthetic files, bounded to 16 MiB each. Check
private temporary-file access, existing readers/writers, permissions and nonempty stream changes
through a second SMB client, empty/growing/shrinking files, complete old/new bytes, name
collisions, low-space errors and interruption of the test client's own process or connection.
Confirm that changing main contents leaves the original identity, current access rules and
unrelated streams intact, including after reconnect. Retain ambiguous states instead of
repairing them by assumption.

Only a passing protocol gate permits app integration under an approved revision. Then complete
the previously required signed TextEdit, conflict, interruption, lifecycle and matched-recording
checks, plus Tools/run-checks.sh. Keep the original NAS read-only. Remove the fixture,
credential and newly installed dependencies; close task-owned apps/windows and remove obsolete
test artifacts before handoff. No VM/shared-daemon restart, network cut, physical-Mac install
or publication is part of this proposal. Source findings and rejected leads are in
[research W11–W13](research.md#m19-mac-only-revision-review-2026-10-27).

The October 28 CLI gate passed private staging, different original ownership, size changes,
competing SMB access and names, six process-crash boundaries, ancestor protection and protected
cleanup. Directory guards need directory-list access; metadata-only opens do not enforce the
required exclusion. Actual remote space exhaustion produced an uncertain copy result; fresh
SMB reads verified the complete backup, stage and local input while retaining partial work.
The existing cached-credential client also connected without acquiring a password. These CLI
checks permitted app integration. The subsequent signed checks establish TextEdit saves, conflict
preservation and retained recovery data; the results log records their exact coverage and limits.

## M20: file renaming

Proposed 2026-10-28; accepted 2026-10-29, including the disposable VM fixture. The user also
approved replacing the separate creation and editing controls with one Read only toggle.
Implementation and signed VM verification are complete. The [results](results/2026-10-29-file-renaming.md)
record Finder behavior, recovery, preservation checks and remaining limits. The physical Mac
still runs M19.

### What the user gets

Rename an ordinary file in Finder, for example Notes.txt to Meeting notes.txt, in the same folder.
Keep its contents, permissions, attached data, item ID, downloads and Keep Downloaded request.
If another file already has the requested name, refuse the rename and leave both files alone.
This addresses the current Finder Rename action, which is advertised for Keep Both but fails
for existing files.

Start with files whose current revision M19 has already verified through a complete download
or upload. A downloaded legacy copy alone is insufficient. Refuse an unproven revision without
evicting it, silently downloading it again, or assigning its identity from a pathname. This is
a deliberate first-step limit; folder renaming and renaming never-verified files need later
identity work. General moves, deletion, Finder Replace and combined rename/content saves remain
outside this scope. Existing M18 initial folder naming continues unchanged.

Creation, editing and renaming use one write mode. A Read only toggle defaults off for new
locations. Adding a writable location obtains the macOS share grant and confirms the existing
SMB-only writer and transaction-file requirements during setup. Existing read-only locations
remain read-only. Already confirmed M19 write access also permits the supported M20 rename.
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

Use the existing M19 verified revision to identify the selected original. Hold its ancestor
directories and a source handle that prevents competing main-content writes, deletion and
renaming. Check the source's server identity and complete contents against that revision. A
changed or replaced source stops the operation without mutating either pathname. Unsupported
identity or protection is a refusal, not permission for a weaker route.

Durably record the item, parent, exact old/new names and source evidence before sending one
handle-based SMB rename with replacement disabled. This changes the name of the original object;
it copies no payload and writes no file contents or access rules. A destination collision never
falls back to replacement or copy/delete. Case-only changes must work through the same protected
operation and exact-name verification, or fail clearly. No temporary-name sequence is proposed.

Verify the resulting object's identity and complete contents before acknowledging completion.
Commit the new name under the original catalog ID, keep its enumeration key and keep requests,
and preserve content revisions when their bytes are unchanged. Refresh native metadata without
turning a name change into an unnecessary download. Reconciliation must defer during uncertainty
and apply the known rename to affected overlapping locations while preserving their own IDs.

After a lost reply or crash, inspect both names with fresh protected SMB evidence. Complete only
when the requested name holds the recorded object and contents. Retry the old-to-new rename only
when the old name still proves the original and the exclusive destination is available. If the
source changed, disappeared or moved elsewhere, retain the operation and report the uncertainty.
Never rename a competing object back, infer success from a missing old name, or search the share
and guess. Local pending content from other operations remains untouched.

### Transport and verification gates

This expands the approved use of libsmb2 from initial naming and internal save transactions to
user-requested file rename. Reuse its existing protected opens, identity/readback queries and
no-replace rename. Native downloads/uploads, macOS credentials, encryption requirements, dynamic
linkage and licence obligations stay the same. No new dependency or server component is proposed.

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
and preserved IDs, keeps, downloads and pagination. Include migrations if persistent formats
change. Record matched before/after Finder actions, run Tools/run-checks.sh in the VM, and update
the affected docs, results log and README in the implementation commits.

## M21: organize ordinary files

Date: 2026-10-29. Decision status: accepted. The [remaining roadmap](roadmap.md) expands the
earlier verified-file move proposal to online rename and move for ordinary files, including
files never downloaded. The identity gate below is part of this milestone. The user approved
the scope and first disposable VM protocol session. M20 remains the verified development build;
the physical Mac still runs M19. Installation is deferred.

### What the user gets

Rename an ordinary file or move it between existing folders in Finder, for example from Inbox
to Archive within the same location. Keep its contents, permissions, attached data, item ID
and downloaded copy. An explicit Keep Downloaded request follows the file. Retention inherited
from a folder follows the destination folder's setting; moving does not explicitly evict a
downloaded copy. Use the existing write mode, without another feature switch.

Existing M19 verified revisions provide the first implementation path. Completion also needs
safe admission of never-downloaded files and legacy downloaded copies, without silently hydrating
or evicting those copies. The move may include a new filename, but cannot include changed contents.
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
complete contents. For an unverified file, the accepted admission rule below binds the operation
to the current object after known catalog details match. It does not establish historical
identity or compare a legacy downloaded copy. Preserve existing IDs, cached contents and their
evidence level through the transition.

Extend the protected rename transaction to include the source and destination parents. Resolve
both from catalog item IDs, validate them against fresh listings, and hold both ancestor chains
against deletion or replacement. Capture the server identities of the protected directories
at admission and retain them with the operation. Native pathname-derived inodes alone cannot
prove parent identity after interruption. If a selected parent cannot be bound to the protected
directory without guessing, refuse the move. This does not add general external-rename matching.

Check the original file's server identity and complete contents against its verified revision,
or record that evidence under protection at admission for an unverified file.
Durably record both paths, parent identities and all affected catalog views before one SMB
handle rename with replacement disabled. The server moves the original object; no payload
upload, copy/delete fallback or permission rewriting is allowed. Unsupported cross-filesystem
or server behavior must fail clearly.

Verify the destination's exact name, original file identity and complete contents before
committing local success. Update parent, name and native lookup metadata under the original
item ID, preserve its content version and enumeration key, and recompute inherited retention.
Each catalog updates the move atomically. Deliver departure to the old parent's enumerator and
arrival to the new one, then signal the working set without deleting/recreating the global item.
The current change query filters on the row's current parent, so signaling both folders alone
is insufficient. A durable receipt covers partial completion across catalogs and repeated
provider callbacks.

After interruption, revalidate the recorded directories as well as both file paths. Complete
only when the destination proves the original object and contents. Retry only when the original
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
recovery identities pass the isolated protocol checks below. The current rename
path hashes complete contents repeatedly; no
large-file move performance result is claimed. Metadata-only recovery after losing protection
is not an approved substitute. Any reduction of the content-verification guarantee needs its
own evidence and decision.

The isolated Tools/check-file-organization.py probe passes all nine cases in the
[VM protocol run](results/2026-10-29-file-organization-protocol.md), including protected file/parent
identities, full bytes, permission and stream preservation, collisions, replacement races and
interrupted publication. A passing protocol run alone cannot prove the
historical identity of a legacy catalog row: those rows have no recorded server identity, and
native lookup IDs can be derived from names. A replacement with identical metadata can therefore
match an old row. On 2026-10-29 the user accepted binding unverified files and selected parents
to the current objects at admission, after matching known details. Record protected identity
and full-content evidence for the operation and recovery; preserve the evidence level of local
copies. Verified files retain their historical identity/content checks. This boundary is
implemented; signed Finder verification remains.

This accepted scope expands libsmb2 use to user-requested cross-folder moves and the protected parent
identity queries needed for recovery. It adds no dependency or server component. The existing
requirement that files change only through SMB still applies. Native reads and file uploads,
macOS-managed credentials, encryption and existing licence obligations remain.
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
