# Working on tinymounter

These rules apply to humans and agents alike. The [README](README.md) describes the project and its
current status.

## Posture: evidence before claims

- **A number is a measurement only with its date, setup, cache state and evidence.** Otherwise it
  is a target or an estimate, so call it that. Report rates in decimal MB/s and sizes in MiB/GiB.
- **Say exactly how far something got:** compiles, runs, or verified at runtime. A clean build
  says nothing about sandbox, file-manager or signing behaviour.
- **VM numbers are relative.** Compare a VM result only with the VM's own native SMB baseline.
  Claims about the physical Mac need a run on the physical Mac.
- **Prefer the simplest correct solution.** Add an abstraction only when it removes more
  complexity than it adds. Prefer modern Apple APIs. A deprecated API is a defect. Don't add
  compatibility layers or speculative fallbacks.
- **Dependencies need a decision.** The user accepted a limited `libsmb2` prototype for M18
  exclusive folder creation and initial naming after the safety checks and licence review.
  Reads and file uploads stay native. Further dependencies or transport changes need a user
  decision after measurement and a licence review ([architecture.md §5](docs/architecture.md#5-native-smb-versus-direct-smb)).
  M19's accepted design adds protected regular-file staging, verification and transactional
  rename/cleanup, gated by the [protocol checks](docs/phase4-plan.md#m19-online-editing).

## Where things are

| Path                     | Holds                                                                   |
| ------------------------ | ----------------------------------------------------------------------- |
| `Sources/TransferCore/`  | transfer engine, catalog, folder listing, safe paths, error classifier  |
| `Sources/TransferBench/` | the `transfer-bench` CLI                                                |
| `Tests/`                 | unit tests for `TransferCore` (`swift test`)                            |
| `Prototype/`             | SwiftUI app, File Provider extension, shared XPC protocol, xcconfig     |
| `Tools/`                 | stdlib-only Python: project generator, CLI checks, SMB series runner    |
| `docs/`                  | plans, research and dated results; [index](docs/README.md)              |
| `results/`               | raw local evidence. It is gitignored and may hold private paths         |

| Read it before you                              | Doc                                         |
| ----------------------------------------------- | ------------------------------------------- |
| change a component, owner, phase or decision    | [architecture.md](docs/architecture.md)     |
| measure anything or claim performance           | [benchmark-plan.md](docs/benchmark-plan.md) |
| build, sign or run the prototype                | [prototype.md](docs/prototype.md)           |
| rely on an external fact or competitor claim    | [research.md](docs/research.md)             |
| commit, open a PR or cut a release              | [CONTRIBUTING.md](CONTRIBUTING.md)          |

## Where to test

Develop on the Mac, but run every test and check in the VMPal VM `macOS VM 1`. The Mac has only
the Command Line Tools: `swift build` works there, but `swift test` and `xcodebuild` don't, and
runtime checks need the signed app in the VM. The VM's clone in `~/Developer/tinymounter` fetches
from the read-only shared folder `tinymounter-host`, its remote `host`, so commit before you
test; uncommitted edits don't reach the VM. The VM's view of the shared folder's refs can stay
stale, so `git fetch host` can miss new commits or fail with "not our ref", but new objects show:
fetch the commit itself with `git -c uploadpack.allowAnySHA1InWant=true fetch host <commit>`. If
that fails too, send a `git bundle` of the new commits with VMPal's file transfer and fetch from
it. Raw `results/` and the `.local/` helpers stay in the VM. CI has its own clone in
`~/ci/tinymounter`; don't work in it.

## Non-negotiables

Never break these without an explicit task to do so.

- **The network disk is the source of truth and is read-only.** No code path writes, renames or
  deletes remote content by default. M18 explicitly permits creating new files/folders only after
  per-location write opt-in, with no overwrite. Runtime writes in development use only the approved
  disposable VM fixture; the original NAS stays read-only. Run disruptive tests only within an
  agreed isolated scope.
  M19 permits existing-file content updates only through its accepted recovery transaction;
  it does not authorize overwrites at the ordinary pathname or general rename, move or delete.
  M20's accepted scope adds protected no-replace renaming of verified ordinary files within
  their folder. Its single write mode defaults on for new locations after scoped access and
  safety confirmation; existing read-only locations remain read-only. Agent tests still use
  only the approved disposable VM fixture. Moves, general deletion and replacement stay denied.
  The user accepted the [remaining roadmap](docs/roadmap.md) on 2026-10-29, authorizing M21
  through M28 in dependency order after their protocol gates. This includes ordinary-file and
  folder organization, pending-save recovery, permanent deletion without a custom Trash,
  safe replacement and bounded offline editing. These remain denied in the current build until
  implemented and verified. On 2026-10-31 the user granted standing permission for all work inside
  the VM, including new fixture sessions, mounts, service/settings changes, restarts, network
  interruption and test installations. Do not ask again for VM-operation approval. Preserve
  evidence and restore temporary test state. Physical-Mac installation and publication remain
  separate decisions; the original NAS stays read-only.
- **Never present incomplete data as complete.** An uncached range fails clearly and is never filled
  with zeroes. A requested pin is not "available offline" until the download is verified.
- **No secrets in the repo, logs or chat.** Credentials go through Keychain or the user's own Finder
  connection. Signing material is never committed. Logs never include source names or paths.
  Sanitize `results/` before sharing it.
- **Never weaken the sandbox to make a test pass.** Record the actual error, then design a supported
  route.
- **No migrations before release.** This is a prototype. Design every format and setup flow for a
  new installation of the release version. Don't write migrations, legacy states or downgrade
  guards for earlier builds' `Settings.json` or catalogs; existing ones are to be removed. A build
  may reject earlier data; the user then clicks Start Fresh and adds the locations again. Before
  such a build goes on the physical Mac, say so, and make sure pending changes are finished or
  exported first.
- **Leave system state alone outside the VM.** Don't change server settings, mounts, network
  settings or global `nsmb.conf` outside the VM without asking. VM work has the standing
  permission above.
- **Generated files are never hand-edited.** `TinyMounter.xcodeproj` comes from `python3
  Tools/generate-project.py`. To add files or targets, change the generator, regenerate, and commit
  both.

## Working as an agent

The user owns the product. The agent researches, proposes, builds and measures.

- **Decide before you build.** The user decides scope, user-visible behaviour, acceptance targets,
  dependencies, paid accounts and anything outward-facing. Bring a recommendation with its
  tradeoffs. Mark a plan `Decision status: proposed` until the user accepts it. Add unknowns to
  [Open decisions](docs/architecture.md#11-open-decisions-for-the-first-experiment) instead of
  guessing.
- **Suggest freely, build only what's approved.** In discussion, bring up features, risks and gaps
  the user hasn't mentioned or may have missed. Write no code for them until the user agrees.
- **Take the smallest step that answers the next question.** Follow the phase order and exit
  criteria in [architecture.md
  §10](docs/architecture.md#10-implementation-sequence-and-exit-criteria). Don't build UI or
  features before the gate that justifies them.
- **Never relax a gate silently.** If a target fails, report the measured gap and propose a change.
  Never quietly change the denominator.
- **In code, do what was asked and only that.** Keep existing behaviour unless the task is to change
  it. If it changed anyway, say so.
- **Look before you "fix" something that looks wrong.** Many limits are deliberate (see
  [prototype.md](docs/prototype.md#deliberate-limitations)).
- **Name what you couldn't verify.** Hydration in Finder and other file managers, playback, Apple
  sign-in and physical-Mac speed need the user or real hardware. List them as unverified rather than
  inferring.
- **Close the loop in writing.** Every experiment ends with a results log (see
  [docs/README.md](docs/README.md#results-logs)) and an updated dated status line in the README.

## Conventions

- **Comments are rare, one line, and explain the _why_:** a gotcha or an invariant, never the
  _what_. Keep them under 100 characters, and never comment on a change you just made. If one line
  can't carry the reason, use a named function, constant or type.
- **A doc that contradicts the code is a defect.** Fix it in the commit that made it wrong. Docs
  state current truth; history lives in git and in results logs.
- **Log under the `dev.tinymounter.prototype` subsystem**, using opaque request IDs rather than
  paths.

## Before you finish

Run `Tools/run-checks.sh` in the VM. It stops at the first failure, and CI runs it for each pull
request ([CONTRIBUTING.md](CONTRIBUTING.md#pull-requests)). It checks that:

- The checked-in project matches `Tools/generate-project.py`.
- `swift test` passes.
- `swift build -c release && python3 Tools/verify-benchmark.py` passes.
- The unsigned app build succeeds with no Swift warnings:
  `xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounterPrototype -configuration Release -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build`
- The SMB SET_INFO encoder preserves file handles and encodes rename destinations correctly,
  checked against the built library without a network connection.

Then check by hand that:

- If files or targets changed, `Tools/generate-project.py` includes them.
- Every doc your change made wrong is fixed, and status claims say what was not verified.
- You read your own diff from top to bottom.
