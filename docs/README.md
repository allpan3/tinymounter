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
| [architecture.md](architecture.md) | Product contract, decisions, components and processes, sign-in and connection, catalog, enumeration, change watching and provider errors, write rules, phases and exit criteria, open decisions | the user makes a decision, or an owner, boundary, format, error rule or phase changes |
| [roadmap.md](roadmap.md) | Planned work that is not done yet, delivery rules, completion criteria and parallel worktree ownership | planned work is added, changed or finished, or the delivery or integration rules change |
| [release.md](release.md) | How to install and update the current release, its known limits, and its source and licences | a release ships, or an install step or known limit changes |
| [benchmark-plan.md](benchmark-plan.md) | What must be proven, cache states, acceptance targets, failure matrix | a method changes, or the user agrees to a target change |
| [prototype.md](prototype.md) | How to build, sign and run the current prototype, its deliberate limits, and the platform findings the design relies on | a setup step, command, limitation or finding changes |
| [research.md](research.md) | External findings, competitors and the source register | you start relying on a new external fact |
| [m24-integration-checklist.md](m24-integration-checklist.md) | Deletion implementation details and the Finder and recovery checks for ordinary deletion and Delete Permanently… | deletion behavior or its checks change |
| [pending-changes-plan.md](pending-changes-plan.md) | Pending changes: retry signal, failure reasons, the Settings list, stopping new items and location removal | pending-change recovery or its removal rule changes |
| [synchronization.md](synchronization.md) | How File Provider locations stay consistent with server volumes and other writers (proposed) | the sync model, its guarantees or its tests change |
| [ui-design.md](ui-design.md) and [ui-mockup.html](ui-mockup.html) | App and Finder interface, accepted for prototyping: its terms, its ASD-STE100 text and an interactive mockup | the interface or its copy changes |
| [architecture-overview.html](architecture-overview.html) | The interactive data-path overview | the architecture changes visibly |
