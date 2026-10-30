# Roadmap to everyday use

Date: 2026-10-29. Decision status: accepted. The user approved this roadmap, including permanent
deletion without a tinymounter Trash, parallel agents/worktrees and the first disposable VM test
session. Implementation follows the safety gates and dependencies below. Installation is deferred.

The goal is ordinary document work in Finder: create, open, save, organize and delete files,
then edit downloaded files while offline. Tinymounter remains a Mac app using an existing SMB
server. No server component is required. One Read only control governs all supported writes.

This is the forward plan. [Architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria)
defines the phases, [phase 4](phase4-plan.md) holds transaction designs, and dated results record
what actually passed. A completed milestone needs its own evidence; a roadmap entry is not a
compatibility claim or an estimate of delivery time.

## Milestones and dependencies

Numbers identify outcomes; independent work may run in parallel. M21 and M23 can start together
after agreement on their shared interfaces. M21 includes the identity work
needed for ordinary existing files. The earlier proposal limited to verified-file moves is
expanded here, before implementation, so downloading a file is not a permanent prerequisite
for organizing it.

| Milestone | What the user gets | Complete when | Depends on |
| --- | --- | --- | --- |
| M21: organize files | Rename and move ordinary files within one location, including files never downloaded | Finder handles verified, legacy downloaded and never-downloaded files; collisions fail; unchanged contents, IDs and downloaded copies survive | M20 and the identity gate below |
| M22: organize folders | Rename and move folders with their contents | Descendant IDs, downloads and keeps survive the move and the next listing; old/new folders enumerate correctly | M21 |
| M23: finish pending saves | Repeated saves stay in order, retry after reconnect, and have a clear recovery action when stuck | The final accepted local save reaches the intended file; uncertain older work remains protected; low space cannot destroy a saved version | M19/M20; shared admission contract with M21 |
| M24: delete items | Delete files and folders from writable locations, with explicit permanent-deletion behavior | Changed/replaced items survive, recursive failures are accurate, retries never delete a new occupant, and every affected view updates | M21, M22 and M23 |
| M25: everyday saves and Replace | Use the tested ordinary-document editor workflows and Finder's file Replace | Callback sequences have been observed; interrupted replacement retains complete old/new versions; supported metadata behavior is explicit | M21, M23 and M24 |
| M26: edit offline | Save downloaded ordinary files repeatedly while disconnected; upload on reconnect | The latest durable save uploads once, conflicts preserve both versions, and app/extension interruption loses no accepted save | M23 and M25, integrated with M21/M22 |
| M27: daily-use validation | A combined build with a precise supported-workflow list | Integrated VM checks and the separately authorized physical-Mac acceptance checks pass; earlier unresolved correctness gates are accounted for | M21 to M26 |
| M28: release readiness | A package ready for a separately approved beta | Signing, licensing, clean lifecycle, diagnostics, accessibility, compatibility and performance gates have evidence | M27; research and measurement design can start earlier |

### M21 and M22: identity and organization

M21's [transaction plan](phase4-plan.md#m21-organize-ordinary-files) protects the original file
and both parent directories, publishes with one no-replace rename, and recovers from recorded
evidence. Bind the selected catalog item and parents to actual server objects before mutation.
Fresh observation must not assign an old downloaded copy to an unproven object at the same name.
Keep full-content checks where the existing contract needs them. Removing those checks, including
during recovery after protection was lost, is not approved by this roadmap. Measure the cost;
do not claim constant-time moves or require silent local hydration to establish evidence.
The accepted SMB expansion is limited to protected ordinary-file admission, parent/directory
identity queries, no-replace file/folder moves and verified user-requested deletion. Prove each
operation on the disposable fixture before integration. There is no new dependency, general
replacement-by-path API or replacement for native bulk reads/uploads in this plan.

M22 extends the same operation to the original directory object. Handle concurrent child changes
without pretending every descendant stayed unchanged. Preserve proven unchanged descendants'
content versions when native pathname-derived IDs change. Do not globally ignore identity
changes in reconciliation. Resolve old-parent departure and new-parent arrival through supported
File Provider enumeration, without globally deleting and recreating the moved item.

Include inherited keeps, saved keep paths, replay receipts, watches and native metadata refresh.
An uncertain operation or pending save in the affected subtree blocks the move. Refuse moving
a folder into its descendant, moving a configured location root, or moving a subtree that
contains another location root.
Moves must stay within the same set of overlapping registered roots; all affected catalogs must
be available. Cross-filesystem errors and incompatible open handles fail clearly. No copy/delete
fallback, permission rewrite or automatic movement of configured roots is included.

### M23: save ordering and recovery

First reproduce the repeated-save ordering issue below. Add a durable per-file order and retain
the latest fully staged generation. Earlier local-only generations can be consolidated after
the newer copy is durable; this is not a history-of-every-save feature. Resolve any publication
that may have changed the original before publishing a successor. Accepted on 2026-10-29:
an older save proved not to have started changing the original may be durably prevented from
publishing, allowing a newer save to continue. Keep its uncertain temporary files and local
copy visible and exportable; retirement does not authorize their deletion. A conflict must contain the
latest accepted local contents, without treating the app's own earlier save as another device's
edit. Retry on reconnect needs explicit evidence rather than reliance on untested system replay.

Show waiting, conflict and recovery-required states separately. Give retained data a bounded
space policy that refuses new work before deleting saved content. Keep Export Local Copy and
add evidence-based restoration/cleanup where it is safe. A partial original cannot simply be
renamed back over the public file. Do not add a force-discard action that hides unresolved remote
work. Dismiss a completed notice only when no pending data or artifact ownership is lost.

Done includes multiple saves, duplicate callbacks, concurrent external edits, low space, crashes
between generations, and recovery with unchanged IDs/keeps. A newer failed save must leave the
previous complete save available. This milestone also protects online saves racing a disconnect.

### M24: deletion policy

Accepted policy: explicit permanent deletion, with no custom Trash or hidden retention copies.
Deleting removes the selected file's contents and attached data from the server and its location
views. A server's own backups or recycle bin are outside tinymounter's guarantee. The UI must
make that permanent effect clear; Finder's actual warning and callback behavior is a protocol/UI
gate. Do not advertise Move to Trash or Put Back without implementing their different semantics.
The user accepted this product choice with the roadmap on 2026-10-29. The user also accepted
that Delete removes attached data added by another device while deletion is underway. SMB
cannot exclude that race. Main-content protection and visibly unconfirmed lost replies remain.

Start implementation with ordinary files and empty directories; the milestone also includes
populated-folder deletion so users can finish normal cleanup. Resolve selected-object identity
and pending writes first. A fresh complete traversal must not delete newly arrived or changed
children under an old request. Record per-item progress, refuse protected roots, and report a
partly completed recursive deletion accurately. It is not an atomic whole-tree operation.
After a lost reply, do not use an absent pathname alone to claim the recorded object was deleted,
and never retry against a replacement at that path. Uncertain cases remain visible and recoverable
as operations, without promising restoration of content already permanently deleted.

### M25: editors and replacement

Observe callback sequences before enabling new combinations. Cover TextEdit, Preview's ordinary
document files and an available code editor; additional app installation needs its own approval.
Include repeated Save, Save As, temporary/lock-file cleanup, rename plus content changes and
Finder's file Replace. Installed app/format coverage belongs in the results, not a claim that
all editors work. Packages and folder Replace remain outside this milestone.

Replacement must preserve complete incoming and previous contents until publication is verified.
An unrelated same-name create, a reimport, or a delete followed by a create is not proof of an
authorized replacement transaction. If File Provider does not provide a supported way to bind
that intent and base, stop at that gate and present the limitation. Do not use M18's partial
visibility of new uploads to justify destroying an existing destination first.

Preserve destination access permissions and concurrent metadata. Define which incoming document
attributes each supported save can synchronize; unsupported tags, streams or combined operations
must remain explicit. M19's existing preservation checks are not evidence that arbitrary incoming
metadata can safely replace current server metadata. Broader standalone Finder tag/lock syncing
needs a later merge policy and is not included here.

### M26: offline editing

Scope: edit ordinary files whose complete current local copy and editing base were verified
before disconnection. Repeated saves keep the latest durable contents. On reconnect, an unchanged
base receives those contents; a competing edit preserves both versions. For a deleted or moved
remote original, retain the local edit for recovery/export rather than guess where it belongs or
silently recreate the old pathname. This accepted offline policy differs from the older general
delete-versus-edit proposal in synchronization.md.

Offline creation, renaming, moving and deletion are deferred. Test the app-running, intentional
Quit, app-crash and extension-termination cases separately. If the app is unavailable, prove
macOS retains and replays dirty contents without eviction, or present the required ownership
change for approval. A local editor's Save is not a claim that the server has received it.
Done requires automatic reconnect upload, correct conflict contents, durable pending status,
bounded storage, and no loss across interrupted staging or upload. Full OS restart remains a
separately authorized acceptance check.

### M27 and M28: evidence for use and distribution

M27 combines the features on one candidate and closes earlier correctness gaps. Include retained
offline bytes after restart, eviction/low-space behavior, saved keeps after re-add, multi-location
and account isolation, app-closed behavior and recovery after interrupted upgrades. Phase 3 is
not declared complete merely because its individual VM milestones passed. Physical-Mac writes,
download preservation and restart checks remain unverified until the user performs them or
authorizes a suitable disposable setup. Agent testing still leaves the original NAS read-only.

M28 includes the unresolved [benchmark gates](benchmark-plan.md#6-proposed-acceptance-targets):
matched native/provider reads, streaming first frame and seeks, cached reads and resource use.
Existing VM partial-read results do not meet the sequential target; no physical-Mac speed claim
follows. No target is relaxed by this schedule. Choose distribution signing, satisfy dependency
licensing/relinking obligations and verify clean install/update/uninstall before calling a beta
ready. Broader OS/NAS compatibility needs its own evidence. A ready package is not permission to
install, notarize, publish or buy a developer account.

## Starting point

Current protocol evidence: [file organization](results/2026-10-29-file-organization-protocol.md)
and [permanent deletion](results/2026-10-29-deletion-protocol.md). Their operation checks pass,
with current-object admission and whole-file deletion boundaries accepted on 2026-10-29. These probes
enable no Finder capability. The [M23 ordering core](results/2026-10-29-pending-save-order.md)
and retirement change pass required VM checks; signed workflows and recovery cleanup remain.

M18 creation, M19 same-object editing and M20 verified-file renaming have signed VM evidence.
M20 is the development baseline; the physical Mac runs M19. Existing read-only locations stay
read-only. Folder organization, deletion, Finder Replace and deliberate offline editing are
not implemented. The M20 rename restriction to previously verified files is a remaining product
gap, not the intended final behavior.

The supported write boundary remains folders whose writers use SMB and leave tinymounter's
transaction files alone. All milestones preserve complete pending content, refuse silent
replacement of another device's changes, retain uncertainty, and preserve existing locations,
IDs, keep requests and downloads except when the user explicitly requests their removal.

## Dependencies found in the review

File and folder operations need identities that remain meaningful after a pathname changes.
M20 has historical evidence for fully verified files. For ordinary catalog rows and selected
parents, the user accepted binding to the objects currently at the selected paths on 2026-10-29.
Known details must match; protected identity and complete-content evidence govern the operation
and recovery. An earlier replacement with indistinguishable details may be moved. Preserve
the evidence level of local copies; verified files retain their stricter historical checks.

Queued saves need their own ordering rule. A [VM regression](results/2026-10-29-pending-save-order.md)
reproduced the baseline publishing an older save while a newer complete local copy waited.
The integrated M23 core adds durable arrival order and explicit edit retry on share recovery.
Required core checks pass. Bounded storage, the recovery interface and signed workflows remain.
This is core regression evidence, not a signed Finder or offline-editing result.

Do not solve ordering by discarding uncertain transactions. A missing remote identity does not
prove no remote request was sent. Consolidation is safe only when a complete newer local copy
is durable and the older operation is proven never to have started a remote mutation. An older
save that touched only its temporary files can instead be durably retired with those files and
its local copy retained. Operations that may have changed the original must resolve first.
A failed new save must leave the last
durable save available, including its document metadata.

These dependencies justify two implementation tracks: identity and organization, and pending
saves and recovery. They share mutation admission and provider callbacks, so their interfaces
and integration order must be agreed before agents edit those shared parts.

## Delivery and approval

Implement the accepted scopes in dependency order without asking the user
to select a new feature after each milestone. Ordinary implementation choices belong to the
agents. Record significant choices and measured limits with the corresponding code and tests.

Return for a decision when evidence requires a smaller user-visible scope, a weaker safety
guarantee, different deletion or retention behavior, a new dependency, or transport behavior
outside the accepted plan. A failed safety gate does not authorize a fallback. Keep the current
native read/upload transport unless its replacement is separately approved.

Test permissions remain separate from feature scope. Each new writable fixture session needs
fresh approval. Request the complete bounded session together, including any task-owned server
interruption needed for recovery tests. No VM or shared-daemon restart, network cut, Apple sharing
change or account change is included. Keep the original NAS read-only. Installation, publication,
push and merge require their own approval; none is included here.

The first test session, approved on 2026-10-29, uses the same disposable loopback-only Samba setup as M20,
with bounded synthetic files, temporary dependencies and a private Keychain credential. It
covers file/parent identity, file and directory rename, delete-on-close and Finder/editor
callbacks. Recovery checks may stop only task-owned test processes, including that disposable
server. Restore the saved state and remove the fixture at the end. This approval covers one
session, not standing permission to reopen it later.

## Common completion criteria

Every implementation milestone includes meaningful regression tests, required migrations, signed
Finder workflows, collision/concurrent-change and interruption recovery checks, and matched
before/after recordings for visible behavior. Compare IDs, versions, keeps and downloaded bytes
with an untouched neighbor. Verify permissions and attached data where remote objects change.

Run Tools/run-checks.sh in macOS VM 1 on the integrated commit. Keep docs, README status and the
results log with the change they describe. Preserve the distinction between a build, a runtime
result and a physical-Mac result. Existing benchmark targets and unresolved phase exits remain
in force; the roadmap does not silently relax them.

## Parallel work and integration

Use an isolated worktree per bounded implementation task. The coordinator assigns ownership
before work starts, supplies the accepted scope and baseline, and integrates reviewed commits.
Opus 5.5 is available for implementation. Do not let agents independently redesign the same
persisted records or shared interface.

| Workstream | First assignment | Ownership and integration dependency |
| --- | --- | --- |
| Organization | M21 identity, move intent and catalog changes; then M22 | Catalog identity/change records, FileRename and the SMB organization adapter; integrate after protocol gates |
| Saves and recovery | M23 ordering, durable consolidation and recovery; then M26 local queue behavior | EditOutbox/EditTransaction and recovery UI; coordinate admission with organization and integrate offline behavior after M25 |
| Protocol and compatibility | Probe identity, delete behavior and actual editor/Replace callbacks; prepare M24/M25 work | Isolated probe sources and fixtures; coordinator runs them in VM 1; production enablement follows results |

The coordinator owns shared provider/IPC wiring and integrates one accepted contract at a time.
M24 deletion follows the identity and recovery contracts; M25 follows proven deletion/editor
callbacks. Their isolated core work can overlap once those contracts are fixed. Do not assign
all milestones to independent agents against incompatible snapshots. Planning speed from three
agents is not a measured implementation speedup.

For the first implementation batch, catalog work accepts only a caller-proven file move and
owns departure/arrival history and keep recomputation. It does not establish server identity or
enable a provider capability. Save-queue work owns EditOutbox, EditTransaction and LocationEdits;
it preserves the existing EditBaseReceipt contract and leaves shared controller/IPC wiring to
the coordinator. Protocol work owns an isolated organization probe and proposes any required
SMB adapter change before another branch uses it. Only the coordinator changes shared settings
compatibility, project generation and production capability admission after those gates pass.

Catalog/settings migrations, shared IPC, provider callback routing, the project generator and
namespace locking have one integration owner. Agree on the small shared contract first; then
independent implementations can proceed against it. Feature branches must not advertise a
capability before the relevant safety gate and signed integration check pass.

Only the coordinator operates VM 1. Run one test job and one fixture session at a time, including
CI. A candidate must be committed before transfer to the VM. Keep evidence tied to that candidate;
do not mix outboxes, credentials or synthetic locations from different branch states. A combined
candidate still needs checks after integration even if its branches passed independently.

Inventory storage before testing. Remove task-owned fixtures, credentials, temporary dependencies,
obsolete builds and opened apps/windows at the end; verify restored settings. Keep the current
verified candidate and useful evidence, and preserve user-owned or unidentified windows. Agents
must not accumulate extra builds or start servers in their worktrees.

## Deliberate limits

The initial daily-use target is ordinary files and folders within one location. Moving between
locations or shares, packages, live databases, VM images, symbolic/hard links and general POSIX
filesystem semantics need separate compatibility work. Copying supported files to another
location is distinct from a transactional move. External rename matching is not inferred from
native pathname-derived IDs.

Native server-volume automount remains an independent later mode under architecture §9. It
does not provide offline copies. An app-owned replacement for native SMB remains conditional
on the transport decision; it is not an automatic milestone or a prerequisite added by this plan.
