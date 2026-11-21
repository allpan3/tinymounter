# Roadmap

This is the plan for work that is not done yet. [Architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria)
defines the phases. A roadmap entry is not a compatibility claim or an estimate of delivery time.
When an entry is finished, remove it and make sure the current documents state what it changed.

The goal is ordinary document work in Finder: create, open, save, organize and delete files,
then edit downloaded files while offline. TinyMounter remains a Mac app using an existing SMB
server. No server component is required. One Read only control governs all supported writes.

## Planned work

### Daily-use validation (M27)

Signed VM validation covers combined Finder create/save/rename/move/replace/delete workflows,
retained offline bytes through restart and disk pressure, eviction and re-download, saved keeps
after re-add, separate accounts, app-closed behavior and interrupted app replacement. Manual
recovery after system reimport preserves both copies. Kept files retain their bytes while paused
under disk pressure; new keeps wait for Resume, and explicit opens still download. The supported
VM checks are complete. Startup with accumulated old test domains can exhaust `fileproviderd`'s
file descriptors; restarting that daemon restored service. Actual sleep/wake remains unverified
because the VM refuses system sleep.

Phase 3 is not declared complete merely because its individual VM milestones passed.
Physical-Mac writes, download preservation and restart checks stay unverified until the user
performs them or authorizes a suitable disposable setup. Agent testing still leaves the
original NAS read-only.

Local SMB discovery is implemented and checked in the signed VM app. Physical-Mac acceptance
of discovery remains part of the user's later testing.

The accepted Pause behavior keeps file pins active while blocking background transfers.
Direct eviction requires Allow Removal first; macOS can still evict independently kept children
when an unkept parent is evicted. The accepted system-reimport
behavior preserves uncertain local files for manual resolution; neither copy wins automatically.

Include a read-only `CHANGE_NOTIFY` check on the user's NAS, with the user making the changes
from another device; change notification is verified only against Samba so far.

### Release readiness (M28)

M28 includes the unresolved [benchmark gates](benchmark-plan.md#6-proposed-acceptance-targets):
matched native/provider reads, streaming first frame and seeks, cached reads and resource use.
On the disposable Samba fixture, full downloads met the provider throughput target and cached
reads matched the local APFS control. Fresh sequential ranges in both read-only and writable
locations fell below the 0.90 target with verified cold and warm Samba file pages. The first read
waited for a macOS database flush. Later reads still stalled at 16 MiB boundaries. On a direct
open in IINA, the playback clock advanced before full materialization. macOS completed a
whole-file request during the run. First visible frame and end-to-end
resource use still need measurement. The SMB reader left no staging files after mid-transfer
cancellation or after the caller removed each completed download. The physical Mac needs its own matched runs.

The personal-use releases leave out public distribution, notarization, a dedicated uninstaller,
an accessibility audit, an automatic updater and broad OS/NAS compatibility. Before calling a
beta ready, choose distribution signing, complete the dependency licence review, verify a
separately signed rebuild at runtime and repeat the installation checks on the distribution
package. The personal 0.4.1 package opened with no locations in a fresh VM account. An update
from 0.4.0 kept a changed preference, and removing the app cleared the installed extension
registration.
The packaging tool now includes the matching source archive and licence notices in the DMG.
An unsigned VM rebuild linked a modified library. Broader OS/NAS compatibility needs its own
evidence. A ready package is not permission to install, notarize, publish or buy a developer
account.

### Not scheduled

- Changes made on the NAS by other devices in Recent Activity (frequent, and Finder already
  shows them).
- SMB session reuse to reduce logons (internal).
- The [Locations folder](ui-design.md#7-locations-folder-one-place-to-navigate) of aliases (not
  needed now).

## Delivery and approval

Implement the accepted scopes in dependency order without asking the user to select a new
feature after each milestone. Ordinary implementation choices belong to the agents. Record
significant choices and measured limits with the corresponding code and tests.

Review code and milestones periodically against everyday Finder use. Keep progress reports
about working user tasks, with internal test detail in the PR description. Check performance
during implementation, not only at M28: compare the current build with a reproducible earlier
build and a matched native baseline. Distinguish new regressions from targets that never passed,
and retain the original targets. Opus and Astra may both handle bounded implementation and
review tasks.

Return for a decision when evidence requires a smaller user-visible scope, a weaker safety
guarantee, different deletion or retention behavior, a new dependency, or transport behavior
outside the accepted plan. A failed safety gate does not authorize a fallback.

Test permissions remain separate from feature scope. All work inside the VM has standing
permission, including fixture sessions, mounts, service/settings changes, restarts, network
interruption and test installations. Do not request VM-operation approval again. Preserve
evidence and restore temporary test state. Keep the original NAS read-only. Physical-Mac
installation, publication, push and merge require separate approval.

## Common completion criteria

Every implementation milestone includes meaningful regression tests, signed
Finder workflows, collision/concurrent-change and interruption recovery checks, and matched
before/after recordings for visible behavior. Compare IDs, versions, keeps and downloaded bytes
with an untouched neighbor. Verify permissions and attached data where remote objects change.

Run Tools/run-checks.sh in macOS VM 1 on the integrated commit. Keep the docs with the change they
describe, and put the test evidence in the PR description. Preserve the distinction between a
build, a runtime result and a physical-Mac result. Existing benchmark targets and unresolved
phase exits remain in force; the roadmap does not silently relax them.

## Parallel work and integration

Use an isolated worktree per bounded implementation task. The coordinator assigns ownership
before work starts, supplies the accepted scope and baseline, and integrates reviewed commits.
Opus 5.5 is available for implementation. Do not let agents independently redesign the same
persisted records or shared interface.

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
