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

Latest completed experiment: [2026-10-15 — one-chunk read-ahead window](results/2026-10-15-read-ahead-window.md). Earlier: [runtime race and recovery follow-up](results/2026-10-15-runtime-followup.md), [catalog browsing and reads by item](results/2026-10-14-catalog-browsing-reads.md), [share grant and Finder
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
