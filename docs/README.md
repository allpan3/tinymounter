# TinyMounter documentation

Start with [`AGENTS.md`](../AGENTS.md). It's the short version, and it links here for anything that
needs more than a line.

Each document has one job and one trigger: the change that obliges you to edit it. A document
that contradicts the code or the latest measurements is a defect, so fix it in the commit that made
it wrong.

| Document | Covers | Edit it when |
| --- | --- | --- |
| [smb-simplification.md](smb-simplification.md) | Accepted ordinary SMB semantics, simplification scope and validation | this implementation or its evidence changes |
| [architecture.md](architecture.md) | Product contract, decisions, components, phases and exit criteria, open decisions | the user makes a decision, or an owner, boundary or phase changes |
| [roadmap.md](roadmap.md) | Accepted remaining milestones, completion criteria, dependencies and parallel worktree ownership | the forward scope, order or integration plan changes |
| [benchmark-plan.md](benchmark-plan.md) | What must be proven, cache states, acceptance targets, failure matrix | a method changes, or the user agrees to a target change |
| [prototype.md](prototype.md) | How to build, sign and run the current prototype, and its deliberate limits | a setup step, command or limitation changes |
| [research.md](research.md) | External findings, competitors and the source register | you start relying on a new external fact |
| [phase2-plan.md](phase2-plan.md) | Phase 2, the read-only vertical slice: decisions, data model, errors, UI scope and milestones | a phase 2 decision, milestone or design choice changes |
| [phase3-plan.md](phase3-plan.md) | Phase 3, offline and NAS changes you can trust: reconnection, restart after a crash, connecting in the app, verified offline status, folder keeps, live change discovery and disk-space protection and location lifecycle checks (M11 to M17 checked in the VM; limits in results) | a phase 3 decision, milestone or design choice changes |
| [phase4-plan.md](phase4-plan.md) | Accepted M18 creation, M19 Mac-only editing, M20 file renaming with one write mode, and M21 file organization | write scope, permissions or recovery behavior changes |
| [m24-integration-checklist.md](m24-integration-checklist.md) | Deletion gates and the signed Finder/recovery checks behind Delete Permanently… | deletion integration or its remaining checks change |
| [pending-changes-plan.md](pending-changes-plan.md) | Accepted fix for stuck pending changes: retry signal, failure reasons and the Settings list, then evidence-based stopping and removal | pending-change recovery or its removal rule changes |
| [connection-layer-plan.md](connection-layer-plan.md) | Proposed 0.2.0 connection layer without the macOS mount: interfaces, settings, UI, parallel steps, spike questions and the mount-dependency map | the 0.2.0 interface, step split or a spike result changes |
| [synchronization.md](synchronization.md) | How File Provider locations stay consistent with server volumes and other writers (proposed) | the sync model, its guarantees or its tests change |
| [ui-design.md](ui-design.md) and [ui-mockup.html](ui-mockup.html) | App and Finder interface, accepted for prototyping: its terms, its ASD-STE100 text and an interactive mockup | the interface or its copy changes |
| [architecture-overview.html](architecture-overview.html) | The interactive data-path overview | the architecture changes visibly |
| [results/](results/) | One dated log per experiment or investigation | never rewritten. Add a new log instead |

## Results logs

- [App-owned SMB password login](results/2026-11-08-password-login.md). 0.2.0 spike: libsmb2 password login without a mount, Keychain item and entitlement limits, error mapping and memory hygiene. Proposed.

- [One add flow and a simpler Servers pane](results/2026-11-07-servers-redesign.md). Shares added only in locations, retained access, Forget and the first-time flow.

- [Native SMB server volumes](results/2026-11-07-native-server-volumes.md). One mode per share, native Finder operations, safe removal and reconnect.

- [Finder folder Replace](results/2026-11-06-folder-replace.md). Native SMB comparison, pending-upload retention and automatic retry after a watcher timeout.

- [Share access and automatic connection](results/2026-11-06-share-access.md). Retained permission, existing settings, Add reconnect, read-only checks and Finder visibility limits.

- [0.1.0 release verification](results/2026-11-06-release.md). Signed packaging, quarantine approval, Finder installation and before/after recordings.

- [Selected app and menu icons](results/2026-11-06-icons.md). Required checks and signed VM icon inspection pass; physical-Mac installation remains.
- [Personal-use 0.1.0 acceptance](results/2026-11-06-personal-use-acceptance.md). App naming, restart retention, editor saves, low-space refusal, Finder deletion/Replace and combined saves; native reconnection and pressure-test limits.

- [SMB simplification](results/2026-11-05-smb-simplification.md). Ordinary saves replace remote recovery and content proofs. Interrupted uploads retry automatically; matched VM save/read measurements record the remaining read-performance gap.

- [Spotlight cleanup](results/2026-11-05-spotlight-cleanup.md). Removed leftover app bundles and stale registrations on the physical Mac; signing and installation cleanup now prevents retained runnable copies.

- [Save recheck](results/2026-11-04-save-recheck.md). Fresh original-content checks route detected changes through conflict-copy recovery; the later copy window remains unresolved.

- [Write confirmation and save races](results/2026-11-04-write-confirmation.md). The access picker drops its technical warning. Direct-writer VM probes reproduce lost or mixed contents during a save; a pre-mutation check catches earlier changes but leaves the copy window open.
- [Pending rename recovery](results/2026-11-04-pending-rename-recovery.md). Settings lists system-only pending changes, preserves stale-base refusal reasons and guides Finder undo. Signed VM rename/move recovery, app restart and subsequent permanent deletion pass.

- [Single-client adoption](results/2026-11-04-adoption.md). The user adopted the transport and accepted writable partial reads; normal builds enable folder organization and Delete Permanently…. Retry continues an interrupted permanent deletion; restoring the original name clears a refused rename. Same-steps VM recording and installation preflight.
- [Single-client candidate validation](results/2026-11-04-candidate-validation.md). Prefetch cleanup, restart reconnection, disk-pressure eviction, interrupted upgrade and account-mismatch refusal pass after three fixes. Concurrent use of two accounts is unverified. Read-only partial reads and seeks meet their VM targets; writable partial reads fail at a median paired ratio of 0.725. Corrects the earlier record and states the adoption decision.
- [Integrated single-client candidate](results/2026-11-04-integrated-candidate.md). Read-only partial reads reach a ratio of medians of 0.917 with next-extent prefetch. Superseded by the validation above.
- [Confirmed permanent deletion](results/2026-11-03-permanent-command.md). Signed Finder command, Cancel, pending-save refusal and permission-loss recovery pass. Concurrent-save recovery retains and exports local bytes; Stop Uploading clears pending state without recreating the server file. The normal command gate stays off.
- [Samba filenames, uploads and saves](results/2026-11-02-samba-names-and-uploads.md). Direct save-stage uploads pass required VM checks and signed save/recovery cases. November 3 probes reproduce stale native names and wrong-path quarantine writes after direct mutations. A single-client VM experiment is authorized; the Mac update remains withheld.
- [Stuck pending changes, parts 4–5](results/2026-11-02-stop-uploading.md). Signed VM check: Stop Uploading keeps a refused new item on this Mac, and Remove Location keeps items that never reached the server in a folder shown in Finder. A refused save no longer blocks the share. Stop Uploading for edits is deferred.
- [Stuck pending changes, parts 1–3](results/2026-11-02-pending-changes-list.md). Signed VM check: Retry and share recovery resume new items that macOS throttled, and Settings lists failures with reasons. Follow-up fixes remove a retry loop on slow connections, keep the status updating during outages and let refused files and folders upload again.
- [Start Fresh installation](results/2026-11-02-start-fresh-install.md). The physical Mac's earlier location was removed and added again, and files that never uploaded were restored to the NAS.
- [Protected-read diagnostics](results/2026-11-01-read-diagnostics.md). Signed VM checks distinguish verification from namespace waits and verify checksum-cancellation cleanup; no new speed claim.
- [Verified range reads](results/2026-11-01-verified-range-reads.md). Signed VM small-read improvement, full-download cost, restart/remount checks and remaining mutation coverage; physical Mac keeps the earlier build.
- [Physical-Mac update](results/2026-11-01-local-update.md). Latest normal build installed with unchanged sandbox and identity; startup retains the existing location. Physical-Mac performance and writes remain unmeasured.
- [Everyday-use and performance review](results/2026-10-31-everyday-use-review.md). Encryption acceleration cuts the measured writable-open delay; edited-file cache misses and throughput targets remain unresolved. Fixture corrections restore Finder folder creation and remove the connection delay. Temporary VM state is restored.
- [VM graphics interruption during save checks](results/2026-10-30-vm-graphics-interruption.md) — the frozen attempt reached no save checkpoint; the approved restart and fixture recovery restored testing.
- [Folder-move preparation and adapter checks](results/2026-10-30-folder-move-catalog.md) — selected signed move and recovery checks pass; ambiguous-name fixtures and Finder integration remain unverified.
- [Permanent-deletion protocol checks](results/2026-10-29-deletion-protocol.md) — protocol, core and signed adapter checks pass for files, empty folders and recovery; lost replies remain unconfirmed. App deletion is unavailable.
- [Pending-save ordering](results/2026-10-29-pending-save-order.md) — ordering, retained recovery and cleanup checks pass; a signed callback interruption reaches the final save. M23 remains incomplete.
- [SMB file organization checks](results/2026-10-29-file-organization-protocol.md) — protocol, signed Finder moves, overlapping-view recovery and five app-API boundary cases pass; remaining M21 checks are open.
- [SMB rename request encoding](results/2026-10-29-smb-rename-encoding.md) — handle corruption reproduced and fixed; six packet checks and required VM checks pass.
- [Catalog preparation for file moves](results/2026-10-29-move-catalog.md) — migration and core checks pass; app integration and signed Finder moves remain unverified.
- [File renaming and one write mode](results/2026-10-29-file-renaming.md) — M20 signed Finder renames, recovery and preservation checks pass; one Read only toggle.

Name each log `results/YYYY-MM-DD-topic.md`. Write it when the experiment ends, then link it from
the README status line. Keep this order:

1. **Outcome.** What the result supports, and what it explicitly doesn't.
2. **Setup and method.** Hardware, OS build, server and protocol state, binary, run order, cache
   state, and anything left unchanged on purpose.
3. **Data.** Samples with medians, not only the best run.
4. **Correctness and limits.** Checksums, cleanup, and what the measurement can't distinguish.
5. **Evidence.** Links to raw files under the ignored `results/`, plus how to reproduce them.
6. **Next step.** The next question, and what blocks it.

A past log is a record. Correct it with a new log or a dated note, not by rewriting it.

Latest completed check: [2026-10-29 — file renaming and one write mode](results/2026-10-29-file-renaming.md). Earlier: [2026-10-28 — same-object save and recovery](results/2026-10-28-same-object-save.md), [2026-10-25 — file Keep Both](results/2026-10-25-keep-both.md), [2026-10-22 — location changes and removal](results/2026-10-22-location-lifecycle.md), [disk-space protection](results/2026-10-21-disk-space-protection.md), [NAS change discovery](results/2026-10-19-nas-change-discovery.md), [Keep Downloaded status refresh](results/2026-10-19-keep-status-refresh.md), [Finder progress for Keep Downloaded](results/2026-10-19-keep-download-progress.md), [recursive folder keeps](results/2026-10-19-folder-keeps.md), [kept-file versions and guest SMB](results/2026-10-19-offline-versions.md), [guest SMB connections](results/2026-10-19-guest-connections.md), [kept-file local availability](results/2026-10-19-offline-status.md), [physical-Mac browsing and playback](results/2026-10-19-physical-mac-use.md), [first-folder delay investigation](results/2026-10-18-first-folder-delay.md), [File Provider approval](results/2026-10-18-file-provider-approval.md), [server removal and existing connections](results/2026-10-18-connection-management.md), [share picker delay on the physical Mac](results/2026-10-18-share-picker-delay.md), [connect in the app (M12)](results/2026-10-18-connect-in-app.md), [reconnection and restart after a crash (M11)](results/2026-10-18-reconnect-restart.md), [exit validation (M9)](results/2026-10-18-exit-validation.md), [Storage pane and folder completion (M8)](results/2026-10-18-storage-pane.md), [Settings window and menu bar (M7)](results/2026-10-16-settings-window.md), [Keep Downloaded and Pause (M6)](results/2026-10-16-keep-pause.md), [one-chunk read-ahead window](results/2026-10-15-read-ahead-window.md), [runtime race and recovery follow-up](results/2026-10-15-runtime-followup.md), [catalog browsing and reads by item](results/2026-10-14-catalog-browsing-reads.md), [share grant and Finder
spikes](results/2026-10-12-share-grant.md), [core library listing on the NAS share](results/2026-10-12-nas-listing.md),
[remount identity](results/2026-10-12-remount-identity.md), [offline reading with the NAS
unreachable](results/2026-10-11-offline-reading.md), [player launch paths and bounded
read-ahead](results/2026-10-11-player-readahead.md), [verified NAS-cold, NAS-RAM and local-cache
results](results/2026-10-11-cache-states.md) with an [interactive
comparison](results/2026-10-11-cache-states.html), [full-download
attribution](results/2026-10-11-full-download.md), [materialization flush wait and fetch-size
tradeoff](results/2026-10-11-provider-delay.md), [app-owned NAS reader
works](results/2026-10-10-app-reader.md), and [local provider checks and direct extension NAS
denial](results/2026-10-10-provider-runtime.md).

Latest competitor review: [2026-10-11 — PolyDrive research](research.md#polydrive--reviewed-2026-10-11). Documentation review only; no PolyDrive runtime or speed measurements.

Write-support gate: [2026-10-23 native SMB publication check](results/2026-10-23-upload-publication.md).
Native exclusive creation is accepted and implemented. Signed upload/recovery checks and all 208
tests passed. Normal Finder uploads pass after a VM daemon restart; the follow-up below fixes
initial naming. Keep Both still fails. See the
[M18 results](results/2026-10-23-create-items.md).
The user accepted initial folder naming. Its [safety investigation](results/2026-10-23-initial-folder-naming.md)
found a direct SMB route. The [authentication follow-up](results/2026-10-23-folder-naming-authentication.md)
corrected the credential probe and passed a signed sandboxed connection. The accepted client
now handles exclusive folder creation and initial naming.
The [naming implementation checks](results/2026-10-23-folder-naming-fix.md) passed signed Finder,
collision and interrupted recovery checks, with all 230 tests and required VM checks passing.
The fixture is removed and sharing is restored. The physical-Mac app remains M16.

M19's [publication gate](results/2026-10-27-edit-publication.md) passed competing SMB checks
but found that server-local access bypasses protection. The user accepted an explicit SMB-only
writer requirement for editing. Later competing SMB metadata changes defeated the replacement
design. The [Mac-only revision](phase4-plan.md#revised-mac-only-save-proposal) and a new disposable
VM test session were approved on 2026-10-28. Its CLI protocol gate passed on the disposable
Samba fixture. Signed TextEdit saves, conflict preservation, interruption retention and local
export pass. IDs, keep requests and an independent download survive. The fixture, temporary
dependencies and task windows are cleaned up, with original settings verified.
The [October 28 protocol results](results/2026-10-28-same-object-save.md) record the current
same-object save and recovery checks, including unresolved partial work and fixture connection
delays. The verified M19 build is installed on the physical Mac, with retained location/catalog
counts in background launch checks. Physical-Mac writes remain unverified.
