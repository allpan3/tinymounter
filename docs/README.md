# tinymounter documentation

Start with [`AGENTS.md`](../AGENTS.md). It's the short version, and it links here for anything that
needs more than a line.

Each document has one job and one trigger: the change that obliges you to edit it. A document
that contradicts the code or the latest measurements is a defect, so fix it in the commit that made
it wrong.

| Document | Covers | Edit it when |
| --- | --- | --- |
| [architecture.md](architecture.md) | Product contract, decisions, components, phases and exit criteria, open decisions | the user makes a decision, or an owner, boundary or phase changes |
| [benchmark-plan.md](benchmark-plan.md) | What must be proven, cache states, acceptance targets, failure matrix | a method changes, or the user agrees to a target change |
| [prototype.md](prototype.md) | How to build, sign and run the current prototype, and its deliberate limits | a setup step, command or limitation changes |
| [research.md](research.md) | External findings, competitors and the source register | you start relying on a new external fact |
| [phase2-plan.md](phase2-plan.md) | Phase 2, the read-only vertical slice: decisions, data model, errors, UI scope and milestones | a phase 2 decision, milestone or design choice changes |
| [phase3-plan.md](phase3-plan.md) | Phase 3, offline and NAS changes you can trust: reconnection, restart after a crash, connecting in the app, verified offline status, folder keeps, live change discovery and disk-space protection and location lifecycle checks (M11 to M17 checked in the VM; limits in results) | a phase 3 decision, milestone or design choice changes |
| [phase4-plan.md](phase4-plan.md) | Accepted M18 creation, initial folder naming and Keep Both; M19's failed replacement gate and accepted Mac-only revision | write scope, permissions or recovery behavior changes |
| [synchronization.md](synchronization.md) | How File Provider locations stay consistent with server volumes and other writers (proposed) | the sync model, its guarantees or its tests change |
| [ui-design.md](ui-design.md) and [ui-mockup.html](ui-mockup.html) | App and Finder interface, accepted for prototyping: its terms, its ASD-STE100 text and an interactive mockup | the interface or its copy changes |
| [architecture-overview.html](architecture-overview.html) | The interactive data-path overview | the architecture changes visibly |
| [results/](results/) | One dated log per experiment or investigation | never rewritten. Add a new log instead |

## Results logs

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

Latest completed check: [2026-10-25 — file Keep Both](results/2026-10-25-keep-both.md). Earlier: [2026-10-22 — location changes and removal](results/2026-10-22-location-lifecycle.md), [disk-space protection](results/2026-10-21-disk-space-protection.md), [NAS change discovery](results/2026-10-19-nas-change-discovery.md), [Keep Downloaded status refresh](results/2026-10-19-keep-status-refresh.md), [Finder progress for Keep Downloaded](results/2026-10-19-keep-download-progress.md), [recursive folder keeps](results/2026-10-19-folder-keeps.md), [kept-file versions and guest SMB](results/2026-10-19-offline-versions.md), [guest SMB connections](results/2026-10-19-guest-connections.md), [kept-file local availability](results/2026-10-19-offline-status.md), [physical-Mac browsing and playback](results/2026-10-19-physical-mac-use.md), [first-folder delay investigation](results/2026-10-18-first-folder-delay.md), [File Provider approval](results/2026-10-18-file-provider-approval.md), [server removal and existing connections](results/2026-10-18-connection-management.md), [share picker delay on the physical Mac](results/2026-10-18-share-picker-delay.md), [connect in the app (M12)](results/2026-10-18-connect-in-app.md), [reconnection and restart after a crash (M11)](results/2026-10-18-reconnect-restart.md), [exit validation (M9)](results/2026-10-18-exit-validation.md), [Storage pane and folder completion (M8)](results/2026-10-18-storage-pane.md), [Settings window and menu bar (M7)](results/2026-10-16-settings-window.md), [Keep Downloaded and Pause (M6)](results/2026-10-16-keep-pause.md), [one-chunk read-ahead window](results/2026-10-15-read-ahead-window.md), [runtime race and recovery follow-up](results/2026-10-15-runtime-followup.md), [catalog browsing and reads by item](results/2026-10-14-catalog-browsing-reads.md), [share grant and Finder
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
