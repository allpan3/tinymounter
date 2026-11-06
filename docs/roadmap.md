# Roadmap to everyday use

The [accepted SMB simplification](smb-simplification.md) replaces custom remote recovery and
content proofs. Implementation and signed VM checks are complete; read-performance targets
remain unmet. Earlier dated milestones remain historical evidence.

Date: 2026-10-29. Decision status: accepted. The user approved this roadmap, including permanent
deletion without a tinymounter Trash, parallel agents/worktrees and the first disposable VM test
session. Implementation follows the safety gates and dependencies below. Each physical-Mac
installation needs the user's separate approval.

The goal is ordinary document work in Finder: create, open, save, organize and delete files,
then edit downloaded files while offline. Tinymounter remains a Mac app using an existing SMB
server. No server component is required. One Read only control governs all supported writes.

This is the forward plan. [Architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria)
defines the phases, [phase 4](phase4-plan.md) holds transaction designs, and dated results record
what actually passed. A completed milestone needs its own evidence; a roadmap entry is not a
compatibility claim or an estimate of delivery time.

## Milestones and dependencies

### Personal-use 0.1.0 scope, accepted 2026-11-06

Complete the integrated VM checks for ordinary Finder operations, Preview/Xcode saves,
offline edits across a full OS restart, low-space refusal and OS cache eviction. Address defects
found in those workflows. The user will provide physical-Mac daily-use feedback; agent-run
physical-Mac workflow acceptance is not a prerequisite for this personal-use version.

Prepare version 0.1.0 with the visible app name TinyMounter, removing Prototype. Present simple
logo drafts after functional work; the user chooses the logo before it is adopted. An automatic
updater is optional and deferred. Public distribution, notarization, a dedicated uninstaller,
an accessibility audit and broad OS/NAS compatibility are outside this personal-use milestone.
Keep dependency notices and obligations intact; licensing our own code does not relicense
dependencies. Publication remains a separate action. Existing performance gaps remain recorded.

Current checklist, 2026-11-05 (the dated results supersede older status notes below):

| Scope | Implemented and signed-VM verified | Remaining |
| --- | --- | --- |
| M21/M22 organization | Ordinary files and folders; preserved IDs, downloads and keeps; interruption recovery; visible recovery for refused renames/moves | Broader NAS and physical-Mac acceptance |
| M23 saves/retry | Ordinary overwrite, competing edits, shorter/empty saves, system pending items and automatic interrupted-upload retry | Broader compatibility and physical-Mac acceptance; old export/conflict recovery is removed |
| M24 deletion | Confirmed Delete Permanently… and interrupted-operation Retry | Ordinary Finder deletion stays refused because its callbacks cannot distinguish Replace |
| M25 editor saves | Earlier transaction builds covered TextEdit, Preview and Xcode; the simplified path covers TextEdit and ordinary file writes | Repeat broader editor coverage; Finder Replace and combined rename/content callbacks remain disabled |
| M26 offline saves | Signed VM offline retention and automatic retry across app/provider restart | Broader formats, OS restart and pressure checks with the simplified implementation |
| M27/M28 acceptance and release | Integrated VM candidate; merged build installed and launched on the physical Mac | Physical-Mac daily workflows, broader NAS compatibility and release packaging/licensing remain unverified |

Evidence: [editor saves](results/2026-11-03-editor-replacement.md),
[candidate validation](results/2026-11-04-candidate-validation.md),
[adoption](results/2026-11-04-adoption.md) and
[pending rename recovery](results/2026-11-04-pending-rename-recovery.md).
Physical-Mac installation is not workflow acceptance.

Numbers identify outcomes; independent work may run in parallel. M21 and M23 can start together
after agreement on their shared interfaces. M21 includes the identity work
needed for ordinary existing files. The earlier proposal limited to verified-file moves is
expanded here, before implementation, so downloading a file is not a permanent prerequisite
for organizing it.

| Milestone | What the user gets | Complete when | Depends on |
| --- | --- | --- | --- |
| M21: organize files | Rename and move ordinary files within one location, including files never downloaded | Finder handles verified, legacy downloaded and never-downloaded files; collisions fail; unchanged contents, IDs and downloaded copies survive | M20 and the identity gate below |
| M22: organize folders | Rename and move folders with their contents | Descendant IDs, downloads and keeps survive the move and the next listing; old/new folders enumerate correctly | M21 |
| M23: finish pending saves | Repeated saves stay in order, retry after reconnect, and have a clear recovery action when stuck | The final accepted local save reaches the intended file; pending local contents survive failure; low space refuses new staging | M19/M20; shared admission contract with M21 |
| M24: delete items | Delete files and folders from writable locations, with explicit permanent-deletion behavior | Changed/replaced items survive, recursive failures are accurate, retries never delete a new occupant, and every affected view updates | M21, M22 and M23 |
| M25: everyday saves and Replace | Use the tested ordinary-document editor workflows and Finder's file Replace | Callback sequences have been observed; replacement follows ordinary SMB semantics with accurate failure reporting; supported metadata behavior is explicit | M21, M23 and M24 |
| M26: edit offline | Save downloaded ordinary files repeatedly while disconnected; upload on reconnect | The latest durable save uploads once, competing changes may be overwritten, and app/extension interruption loses no accepted save | M23 and M25, integrated with M21/M22 |
| M27: daily-use validation | A combined build with a precise supported-workflow list | Integrated VM checks and the separately authorized physical-Mac acceptance checks pass; earlier unresolved correctness gates are accounted for | M21 to M26 |
| M28: release readiness | A package ready for a separately approved beta | Signing, licensing, clean lifecycle, diagnostics, accessibility, compatibility and performance gates have evidence | M27; research and measurement design can start earlier |

### M21 and M22: identity and organization

M21's [transaction plan](phase4-plan.md#m21-organize-ordinary-files) protects the original file
and both parent directories, publishes with one no-replace rename, and recovers from recorded
evidence. Bind the selected catalog item and parents to actual server objects before mutation.
Fresh observation must not assign an old downloaded copy to an unproven object at the same name.
The accepted simplification removes full-content hashes from organization, including retries.
Use server identity and metadata; do not hydrate file contents merely to rename or move them.
Folder moves still inspect descendant metadata, so they are not constant-time operations.
The accepted SMB expansion is limited to protected ordinary-file admission, parent/directory
identity queries, no-replace file/folder moves and verified user-requested deletion. Prove each
operation on the disposable fixture before integration. There is no new dependency, general
replacement-by-path API in this plan. The separately adopted direct transport handles bulk I/O.

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

### M23: save ordering and retry

File Provider owns pending local saves. A callback succeeds only after the complete SMB write,
size update, flush and close. Failed writes remain pending; connection failures must permit
retry. The latest callback contents may overwrite competing server changes. Earlier remote
versions belong to NAS snapshots/backups, with no TinyMounter conflict copies or remote recovery.

Settings lists system pending items and offers Retry Pending Changes. The 2 GiB staging reserve
remains. Do not discard a pending local edit to make room or clear an error. Missing remote
targets remain pending instead of recreating the old path. Copy local contents outside the
location before resolving such failures.

The signed VM interruption test verifies complete local retention across app/provider restart
and automatic upload after reconnection. Multiple editors, full OS restart and physical-Mac
acceptance still need evidence with this implementation.

### M24: deletion policy

Accepted policy: explicit permanent deletion, with no custom Trash or hidden retention copies.
Deleting removes the selected file's contents and attached data from the server and its location
views. A server's own backups or recycle bin are outside tinymounter's guarantee. The UI must
make that permanent effect clear; Finder's actual warning and callback behavior is a protocol/UI
gate. Do not advertise Move to Trash or Put Back without implementing their different semantics.
The user accepted this product choice with the roadmap on 2026-10-29. The user also accepted
that Delete removes attached data added by another device while deletion is underway. SMB
cannot exclude that race. Main-content protection and visibly unconfirmed lost replies remain.

On 2026-10-30 the user also approved current-name admission for unverified files: Delete may
act on the server object currently at the selected name when its known details still match.
An earlier replacement with indistinguishable details may therefore be deleted. Protect and
verify that object before deletion; previously observed files keep identity/metadata
checks. Recovery stays bound to the admitted identity and must never delete a later replacement.

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

Replacement follows ordinary SMB overwrite behavior; previous-version preservation belongs to NAS snapshots.
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

Scope: edit ordinary files with complete local contents, then upload the latest pending save
when the server returns. Ordinary overwrite semantics apply if the server changed. A missing
remote target remains an error. No full-content editing base is required.

The signed VM checks cover offline save and mid-write interruption across app/provider restart.
They do not establish retention of every intermediate generation or full OS-restart behavior.
Offline creation, rename, move and deletion remain outside this milestone's verified scope.
A local editor's Save is not a claim that the server received the change. Test supported editors,
low-space admission and OS restart before broad offline guarantees.

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

## Starting point before the simplification

The [2026-10-31 everyday-use review](results/2026-10-31-everyday-use-review.md) sets the next
integration priorities within the accepted milestones:

1. Signed Finder folder creation and initial naming now pass with the repaired disposable fixture.
   The supported Samba setting also fixes adapter/native creation. Correcting VM hostname
   resolution removes its connection delay. Neither change requires a user's server to change.
2. Repeated full/partial reads and the writable-open profile are complete for the disposable VM
   fixture. Encryption acceleration gives a 7.19 s median for five 2 GiB writable downloads,
   but edited-file cache misses still take 4–5 s. Address repeated content verification while
   preserving native payload reads/uploads and integrity checks. Continue the
   [fixed regression set](benchmark-plan.md#fixed-regression-set-during-implementation);
   the original throughput, APFS and media gates remain open.
3. Finish integrated M22 parent enumeration and recovery, M23 recovery controls, and M24 Finder
   deletion after its protocol/UI gate. Measure completion in Finder and verify preserved or
   deliberately removed local data before enabling the normal-build capabilities.

On 2026-11-02 the user asked for parallel agents on the work that can proceed now. Four
worktrees run at once: M23 remaining code, including an unanswered stage create that blocks the
share and Stop Uploading for edits (Opus 5.5); M24 Finder routing and recovery controls, gated
off (Astra); the edited-file cache-miss verification cost above (Astra); and the M21/M22 gaps
sorted into code and evidence gaps, with the code gaps closed (Opus 5.5). The coordinator
integrates each branch and runs every VM and signed check.

Use further isolated probes to answer a concrete blocker in those workflows. More standalone
edge cases do not substitute for completing the accepted user tasks. M25/M26 follow their
existing dependencies; M27/M28 and the physical-Mac acceptance gates remain open.

Current protocol evidence: [file organization](results/2026-10-29-file-organization-protocol.md)
and [permanent deletion](results/2026-10-29-deletion-protocol.md). Their operation checks pass,
with current-object admission and whole-file deletion boundaries accepted on 2026-10-29. These probes
enable no Finder capability. The [M23 ordering core](results/2026-10-29-pending-save-order.md)
and retirement change pass required VM checks. Recovery cleanup and status reporting also pass
those checks. Signed retained-save cleanup, export, a subsequent TextEdit save and app restart
also pass. Bounded reserve, partial-stage continuation, lost-cleanup-reply and fresh
replacement-artifact preservation probes pass; broader callbacks remain.
The November 3 [Finder Replace observation](results/2026-11-03-editor-replacement.md) sends
unbound delete/create requests for unopened and verified destinations. This blocks both Replace
and normal deletion enablement under the accepted guarantee. The user approved a separate
**Delete Permanently…** command with confirmation on 2026-11-03. Its gated implementation
reuses protected deletion and recovery, while refusing ordinary delete callbacks. Signed
[command checks](results/2026-11-03-permanent-command.md) pass for Cancel, one-click file/folder
deletion, stale-file and pending-save refusal, connection loss before confirmation, and
permission-loss recovery. A concurrent-save repair passes signed retention, export and
Stop Uploading checks without recreating the server file. Ordinary document Save and Save As
pass for the tested TextEdit, Preview and Xcode files. Signed TextEdit checks also pass for repeated
offline saves, intentional Quit/relaunch, main-app crash and extension termination. A moved-original
trial exposed unwanted conflict publication; the signed repair retains and exports local contents.
A returned-original retry exposed a retired catalog binding; its additional guard passes signed
moved, returned and deleted-original checks. An app-absent TXT save survives Finder's refused
eviction and uploads after relaunch. An offline RTF save survives an app crash and a competing
edit. Recovery export preserves the tested tags and resource fork; the signed retention repair also
preserves text encoding and syncable callback attributes. The remaining offline checks continue.
The November 3 APFS image check now covers real local outbox exhaustion: the older save and
metadata remain exportable, reopening selects it, and retry preserves both complete generations.
Signed low-space admission also preserves the earlier save through both provider and app
refusals. Export succeeds while blocked; restoring capacity and selecting Retry publishes the
latest local revision and clears its system pending entry. A pending RTF survives a full VM
restart and publishes after restoring the test credentials, without Retry. Unattended restart
reconnection and actual disk-pressure eviction remain unverified.

M18 creation, M19 same-object editing and M20 verified-file renaming have signed VM evidence.
Since 2026-11-02 the physical Mac runs main with the [pending-changes fixes](pending-changes-plan.md)
and M21 file organization. Existing read-only locations stay
read-only. Folder organization, deletion, Finder Replace and deliberate offline editing remain
unavailable. M21 now handles ordinary files in signed VM checks, including unverified files,
preserved downloads, overlapping views and interrupted moves. Its remaining acceptance checks
are recorded in the organization results; this does not complete the milestone.
M22's [earlier adapter and app checks](results/2026-10-30-folder-move-catalog.md) cover draining,
pending-write exclusion, overlapping views, collisions and Settings recovery. The November 3
[Linux Samba checks](results/2026-11-03-folder-organization.md) add signed Finder rename, move,
case-only naming, working-set delivery and new-folder creation. Downloaded copies, IDs and keeps
survive unchanged contents. All seven instrumented crash checkpoints recover; checks also pass
between catalog updates and after one view finishes. Same-identity changes and a real stale
TextEdit save preserve server contents and publish a separate conflict copy. An independent SMB
move or replacement after a crash retires both views' old IDs and keeps; new discovery never
inherits their downloaded bytes. Controller Settings cleanup and changed-version replay pass.
Parent creation-time changes are checkpointed while protected, after a directory read. Losing
protection before that checkpoint can still leave an intent unresolved. Destination-ancestor
changes remain pending until the expected identity returns. Signed Unicode-respelling recovery
retires only the affected child in both views. Case-colliding and Unicode-equivalent names
block recovery without mutation; removing the test collisions permits preserved-ID completion.
The required VM checks pass with 628 tests. Its
[candidate validation](results/2026-11-04-candidate-validation.md) passes the functional checks
and read-only performance targets; writable partial reads stay below target. On 2026-11-04 the
user adopted the transport and normal builds enabled folder organization
([adoption](results/2026-11-04-adoption.md)). Physical-Mac acceptance follows Start Fresh.

M24's signed production-adapter checks pass for ordinary files, empty directories, paginated
confirmation, changed/replaced-file refusal and recovery after injected interruptions. Lost
close replies stay unconfirmed. Durable operation storage and the recursive transaction pass
28 simulated-server and storage tests in VM 1. Protected traversal admission compiles and passes
required VM checks and bounded signed recursive checks. The app inventory and namespace blocking
pass required VM checks. Catalog settlement with immutable admission evidence
and fresh-listing obligations, and gated app admission and execution, also pass required VM checks.
The owner-lane scheduler now connects settlement, Settings cleanup and lifecycle retry; that
wiring and its cancellation repair pass required VM checks. Signed recursive checks cover refusals,
two-view deletion, lost-reply restart recovery, competing changes and replacement preservation,
with independent backing audits. Native replacement reads can need a second open to match the
settled catalog identity. Automatic recovery only settles records whose remote work has ended.
Signed admission and joined cancellation, close, counted Stop and automatic settlement also pass.
Gated Finder routing and Settings recovery controls are implemented as of 2026-11-02. Settings
names deletion records, reports per-item outcomes, and offers Retry, Stop Deleting and safe
Dismiss Notice actions. November 3 VM checks pass for the app build, refusal restoration,
Finder's permanent warning and Cancel, verified and unopened files, and nested folders.
Protected-parent checkpoints account for Samba's synthetic creation-time changes and pass signed
restart, lost-checkpoint and replacement-refusal checks. Required VM checks pass with 635 tests.
Delayed Settings completion and explicit Retry pass. Stop Deleting exposed unsafe rebasing of
the callback's item metadata. The domain-version repair now passes signed Stop restoration,
interruption before notification, a later deliberate Delete and refreshed replay after dismissal
and restart. The restored item's ID, keep and downloaded copy survive. Required VM checks pass
with 644 tests. Normal builds enable the confirmed Delete Permanently… command from 2026-11-04;
ordinary Finder deletion stays refused under the Replace design. See the
[integration checklist](m24-integration-checklist.md).

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

On 2026-10-31 the user reaffirmed autonomous implementation and requested periodic code and
milestone reviews against everyday Finder use. Keep progress reports about working user tasks,
with internal test detail in the results logs. Check performance during implementation, not only
at M28: compare the current build with a reproducible earlier build and a matched native baseline.
Distinguish new regressions from targets that never passed, and retain the original targets.
Opus and Astra may both handle bounded implementation and review tasks.

Return for a decision when evidence requires a smaller user-visible scope, a weaker safety
guarantee, different deletion or retention behavior, a new dependency, or transport behavior
outside the accepted plan. A failed safety gate does not authorize a fallback. The single-client
transport and ordinary overwrite semantics have separate explicit approval.

Test permissions remain separate from feature scope. On 2026-10-31 the user granted standing
permission for all work inside the VM, including fixture sessions, mounts, service/settings
changes, restarts, network interruption and test installations. Do not request VM-operation
approval again. Preserve evidence and restore temporary test state. Keep the original NAS
read-only. Physical-Mac installation, publication, push and merge require separate approval.

The first test session, approved on 2026-10-29, uses the same disposable loopback-only Samba setup as M20,
with bounded synthetic files, temporary dependencies and a private Keychain credential. It
covers file/parent identity, file and directory rename, delete-on-close and Finder/editor
callbacks. Recovery checks may stop only task-owned test processes, including that disposable
server. Restore the saved state and remove the fixture at the end. That initial approval covered
one session; the later standing VM permission now governs subsequent sessions.

The active session ended on 2026-10-30: its mount and task server are stopped, and Apple SMB is
restored. Uncertain records, backing fixtures and private artifacts remain for investigation;
[final validation and restoration](results/2026-10-29-deletion-protocol.md#final-validation-and-service-restoration-2026-10-30)
records the remaining cleanup. The root-retirement checks reopened and closed on 2026-10-31 under
the standing VM permission above. The fixture is again unmounted, its server is stopped and Apple
SMB is restored; original Settings bytes are unchanged. Both runs' evidence and recovery artifacts
remain; see the [runtime follow-up](results/2026-10-30-folder-move-catalog.md#runtime-follow-up-2026-10-31).

The later October 31 everyday-use review reopened and then unmounted the disposable fixture.
Its temporary Samba process is stopped, the original hostname file is restored, and Apple SMB
is again loaded and inactive with its original override. Evidence, isolated test builds and
recovery records remain. The physical Mac was not updated.

## Common completion criteria

Every implementation milestone includes meaningful regression tests, signed
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
| Saves and retry | Ordinary writes, File Provider pending contents and M26 lifecycle verification | LocationEdits and provider callbacks; coordinate admission with organization |
| Protocol and compatibility | Probe identity, delete behavior and actual editor/Replace callbacks; prepare M24/M25 work | Isolated probe sources and fixtures; coordinator runs them in VM 1; production enablement follows results |

The coordinator owns shared provider/IPC wiring and integrates one accepted contract at a time.
M24 deletion follows the identity and recovery contracts; M25 follows proven deletion/editor
callbacks. Their isolated core work can overlap once those contracts are fixed. Do not assign
all milestones to independent agents against incompatible snapshots. Planning speed from three
agents is not a measured implementation speedup.

For the first implementation batch, catalog work accepts only a caller-proven file move and
owns departure/arrival history and keep recomputation. It does not establish server identity or
enable a provider capability. Save work owns LocationEdits and the provider content callback, with File Provider retaining
pending contents. Shared controller/IPC wiring stays with the integration owner. Protocol work owns an isolated organization probe and proposes any required
SMB adapter change before another branch uses it. Only the coordinator changes shared settings
compatibility, project generation and production capability admission after those gates pass.

Catalog/settings formats, shared IPC, provider callback routing, the project generator and
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
does not provide offline copies. File Provider's adopted direct SMB transport does not replace
native mounts in that future mode.
