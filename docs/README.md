# TinyMounter documentation

Start with [`AGENTS.md`](../AGENTS.md). It's the short version, and it links here for anything that
needs more than a line.

Each document has one job and one trigger: the change that obliges you to edit it. A document
that contradicts the code is a defect, so fix it in the commit that made it wrong. Documents state
the current truth: test evidence goes in the PR description, raw evidence stays in the local
`results/`, and history lives in Git.

| Document | Covers | Edit it when |
| --- | --- | --- |
| [smb-simplification.md](smb-simplification.md) | Accepted ordinary SMB semantics and the simplification audit | ordinary SMB save, conflict or replacement behavior changes |
| [architecture.md](architecture.md) | Product contract, decisions, components, phases and exit criteria, open decisions | the user makes a decision, or an owner, boundary or phase changes |
| [roadmap.md](roadmap.md) | Accepted remaining milestones, completion criteria, dependencies and parallel worktree ownership | the forward scope, order or integration plan changes |
| [benchmark-plan.md](benchmark-plan.md) | What must be proven, cache states, acceptance targets, failure matrix | a method changes, or the user agrees to a target change |
| [prototype.md](prototype.md) | How to build, sign and run the current prototype, and its deliberate limits | a setup step, command or limitation changes |
| [research.md](research.md) | External findings, competitors and the source register | you start relying on a new external fact |
| [phase2-plan.md](phase2-plan.md) | Phase 2, the read-only vertical slice: decisions, data model, errors, UI scope and milestones | a phase 2 decision, milestone or design choice changes |
| [phase3-plan.md](phase3-plan.md) | Phase 3, offline and NAS changes you can trust: reconnection, restart after a crash, connecting in the app, verified offline status, folder keeps, live change discovery and disk-space protection and location lifecycle checks (M11 to M17 checked in the VM; limits in results) | a phase 3 decision, milestone or design choice changes |
| [phase4-plan.md](phase4-plan.md) | Accepted M18 creation, M19 Mac-only editing, M20 file renaming with one write mode, and M21 file organization | write scope, permissions or recovery behavior changes |
| [m24-integration-checklist.md](m24-integration-checklist.md) | Deletion gates and the signed Finder/recovery checks behind Delete Permanently… | deletion integration or its remaining checks change |
| [pending-changes-plan.md](pending-changes-plan.md) | Pending changes: retry signal, failure reasons, the Settings list, stopping new items and location removal | pending-change recovery or its removal rule changes |
| [connection-layer-plan.md](connection-layer-plan.md) | Proposed 0.2.0 connection layer without the macOS mount: interfaces, settings, UI, parallel steps, spike questions and the mount-dependency map | the 0.2.0 interface, step split or a spike result changes |
| [synchronization.md](synchronization.md) | How File Provider locations stay consistent with server volumes and other writers (proposed) | the sync model, its guarantees or its tests change |
| [ui-design.md](ui-design.md) and [ui-mockup.html](ui-mockup.html) | App and Finder interface, accepted for prototyping: its terms, its ASD-STE100 text and an interactive mockup | the interface or its copy changes |
| [architecture-overview.html](architecture-overview.html) | The interactive data-path overview | the architecture changes visibly |
