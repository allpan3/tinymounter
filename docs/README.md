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
