# Contributing

> Don't hurry. Make it work, make it well designed, and show the evidence.

[`AGENTS.md`](AGENTS.md) has the posture, the non-negotiables and the definition of done. They apply
to every contributor, human or agent. This file covers the workflow around them.

## Decide first

Agree on scope before writing code for anything non-trivial. Agreement can come from a discussion
thread, an explicit request, an issue, or an accepted decision in
[architecture.md](docs/architecture.md). A PR doesn't need an issue. A clean patch can still be
declined if the feature isn't worth its weight. Docs-only changes and obvious fixes skip this step.

## Branches

- `main` always builds and passes the checks in [`AGENTS.md`](AGENTS.md#before-you-finish).
- Do the work on a short-lived topic branch named for the change, such as `provider-range-reads`.
- Rebase onto `main` instead of merging it in. Merge a PR with Rebase and merge, not a squash, so
  its commits land on `main` as they are. Each of them must build and pass the checks.

## Commits

- **Subject: imperative, sentence case, no trailing period.** Aim for about 72 characters. Name the
  behaviour that changed, not the code you touched. Don't use Conventional Commit prefixes such as
  `feat:`.
  - `Reject a staged range when the source changes mid-transfer`
  - `Record SMB session counters around each benchmark run`
  - `Keep the provider's fetch queue from blocking on a dead mount`
- **Body: add one whenever the reason isn't obvious.** Describe what was observed, then why it
  happened, then what is different now. Include measured numbers with units. Wrap lines at 72
  characters. For example:

  ```text
  Report the first-read pause separately from sustained throughput

  A 256 MiB preflight waited 9.6 s for its first pread, so the run
  averaged 24.5 MB/s while later chunks averaged 194.7 MB/s. One
  average hid a startup problem inside a throughput number.

  firstReadSeconds is now reported next to steadyStateMBps, which
  excludes the first chunk.
  ```

- **No AI attribution.** Commits and PR descriptions never credit an AI tool, so no
  `Co-authored-by: Claude` trailer (or Codex, Copilot and so on) and no "Generated with" line.
  [`.claude/settings.json`](.claude/settings.json) turns off Claude Code's attribution. Other tools
  need the same setting.
- **One logical change per commit.** Put cleanup you noticed along the way in a separate commit.
- **Clean up a PR's commits before it merges.** Squash a commit that only fixes up an earlier commit
  in the PR into that commit, so `main` gets the finished change instead of the steps to it. Squash
  a very small fix, such as a typo fix, into the commit it belongs to as well. Keep it separate only
  if it isn't related to the rest of the PR.
- **Never commit** secrets, signing material, raw `results/`, or build output.

## Pull requests

- **The title is the changelog line.** Write it like a commit subject, so it reads well to a user.
- Put `Closes #N` in the description when there is an issue.
- Fill in every section of the [PR template](.github/PULL_REQUEST_TEMPLATE.md), or say why a section
  doesn't apply.
- **A change visible in a file manager or the app needs a before/after recording**, made with the
  same steps both times. An "after"-only clip doesn't count.
- **A performance claim links its results log.** Numbers in a PR need their setup and cache state.
- Point out anything surprising and any tradeoff you made on purpose. Also call out any behaviour
  change you didn't intend.
- **Read your own diff from top to bottom before you open the PR.** Most review comments are
  things a second pass would have caught.
- An automated or AI reviewer can help review a PR, but it doesn't gate it. The checks in
  `AGENTS.md` are still run locally.
- **CI runs `Tools/run-checks.sh` in the VM for each push to a PR.** The `Checks` workflow runs on
  `tinymounter-mac`, a self-hosted runner installed as a LaunchAgent on the Mac in
  `~/actions-runners/tinymounter`. It copies the PR's commit into `macOS VM 1` with `vmpal cp` and
  runs the checks in the VM's `~/ci/tinymounter` with `vmpal exec`. The job waits while the Mac is
  asleep or the runner is stopped, and fails when the VM isn't running. One check runs at a time,
  so a newer push cancels an older one; run it again from the PR.

## Changelog and releases

- **No hand-maintained `CHANGELOG.md`.** The changelog is the list of merged PR titles, so release
  notes can be generated from merged PRs, for example with GitHub's generated release notes. That
  only works if PR titles are written for users.
- Tag releases `vMAJOR.MINOR.PATCH`. A release should add no commits of its own, such as a version
  bump or generated notes.
- Until the first release, the project history is the dated status line in the README plus the logs
  in [`docs/results/`](docs/results/). A log records an experiment or investigation and what it
  found. A routine installation with no new finding updates only the README status line.

## Bugs

Include the macOS version, whether it happened on the VM or the physical Mac, the server and
protocol details (such as NAS model and SMB version), the steps, and expected versus actual
behaviour. Add the relevant `log stream --predicate 'subsystem == "dev.tinymounter.prototype"'`
output with paths removed.
