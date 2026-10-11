# First performance prototype

Status: 2026-10-10. This is an experiment for **one immutable file per domain**. It is not yet the general network-disk browser in the architecture plan.

## Implemented and checked

- A dependency-free Swift package with `transfer-bench` and a reusable transfer engine.
- Source files opened read-only, using bounded `pread` calls; optional local staging uses exclusive creation and `pwrite` at the source offsets.
- Full/range reads, runtime-aligned ranges, empty files, metadata fingerprint checks, progress/cancellation, and cleanup on handled failures.
- JSONL reporting of byte range, filesystem, open/transfer/first-read time, sustained rate after the first chunk, CPU, process-lifetime peak RSS, cache label, and optional post-timing SHA-256 verification.
- A SwiftUI app and replicated File Provider extension, sharing the same transfer engine. The app selects a single fixture, registers a domain, exposes pin controls, and removes domains while preserving downloaded user data. The extension implements full and partial fetching and rejects all remote mutations.
- Eight unit tests passed, covering alignment/overflow, exact content at nonzero offsets, EOF tails, empty files, cancellation before/during transfer, changed-source rejection, symlink/directory rejection, and a known SHA-256 vector.
- Release CLI build and local end-to-end checks passed. The unsigned Release app and extension build succeeded with Xcode 27. Only Xcode's informational App Intents extraction warnings remained; there are no Swift compiler warnings in that build.
- The Release app and extension also built successfully with Personal Team development signing and automatically generated Mac Team provisioning profiles. `codesign --verify --deep --strict` passed for the app including its embedded extension. Signed artifacts are in `.build/xcode-personal/Build/Products/Release/`; the build log is `.build/personal-signing-build.log`. The signed build additionally reports that it does not strip an already signed extension binary.

**NAS measurements are now available:** [first native SMB/staging results](results/2026-10-10-native-smb.md). Five paired 2 GiB runs and a separate range checksum completed successfully on the mounted share.

**Not yet tested:** domain registration/loading, shared bookmark access from the signed extension, actual Finder hydration/pinning, player behavior, or offline persistence. Xcode sign-in, Personal Team certificate creation, signed provisioning/build, and signature verification have succeeded. These checks do not establish sandbox/runtime correctness.

## 1. Native SMB benchmark — no signing needed

Connect the NAS in the VM's Finder with a read-only account where possible. Choose a representative large, unchanged file. These commands are examples; replace the quoted path with the actual file.

```sh
swift build -c release
.build/release/transfer-bench --help
mkdir -p results
smbutil statshares -a > results/native-smb-settings.txt
.build/release/transfer-bench '/Volumes/TEST_SHARE/large-video.mp4' --runs 5 --cache-label unknown > results/native-read.jsonl
mkdir -p .build/staging
.build/release/transfer-bench '/Volumes/TEST_SHARE/large-video.mp4' --stage-dir .build/staging --runs 5 --cache-label unknown > results/native-stage.jsonl
```

The staging directory must already exist and be local. Each successful run deletes its temporary file before reporting success. Handled errors clean up partial staging. A forced process kill or machine crash can leave an owned `tinymounter-<UUID>.stage` file; inspect the dedicated staging directory after such a test. A native SMB syscall can block during an outage, and cooperative cancellation cannot immediately interrupt that kernel call. Isolation and reliable timeout recovery remain future work.

Optional correctness check, outside the throughput series:

```sh
.build/release/transfer-bench '/Volumes/TEST_SHARE/large-video.mp4' --stage-dir .build/staging --offset 12345 --length 8388608 --verify
```

`--verify` hashes the source and staged **range** after timing; its digest is not a whole-file digest unless the range covers the whole file. Verification and repetitions warm caches. `--no-cache` requests `F_NOCACHE`; it neither flushes the NAS nor proves cold reads. `cacheStateVerified` remains false. The source path is included in JSONL, so review it before sharing logs.

`transferSeconds` includes staging allocation, reads/writes, final metadata check, and close; it excludes opening the source and post-timing checksums. `totalSeconds` includes the source open and range setup. `firstReadSeconds` measures time until the first `pread` returns, after the source open. `steadyStateMBps` excludes the first copied chunk and final metadata check/close. `--sync` adds and separately reports `fsync`; without it, staging bytes may still be in the OS's dirty page cache. Neither mode promises physical NAS-disk durability.

This initial harness does not collect wire-byte counters, negotiated security, SMB credits, provider callback traces, or reader-resume time into its JSON automatically. Capture SMB settings separately; extend instrumentation before final attribution. It uses one sequential POSIX stream, not a new SMB client. Existing native-client readahead still applies. The [benchmark plan](benchmark-plan.md) remains the full intended measurement program.

`Tools/run-native-series.py` now wraps this CLI to interleave five pairs of sink/staging runs, save SMB settings, and record before/after SMB session RX/TX counter deltas alongside each sample. Pass the selected file and a new local `--results-dir`; the default range is 2 GiB with `F_NOCACHE`. These are session counters, not a packet trace, and unrelated traffic on the same session can contribute. The script neither flushes the server cache nor proves it cold. It refuses to overwrite an existing results directory.

## 2. Build the Finder prototype

Open `TinyMounter.xcodeproj` in Xcode. Configure a development team and unique bundle/App Group identifiers valid for that team. Set the shared values in `Prototype/Config/Prototype.xcconfig`; ensure both targets have the same provisioned App Group and the extension bundle ID stays below the app's bundle ID. The checked-in identifiers are placeholders. Do not commit signing credentials or provisioning material.

**A paid membership is not the first step.** Sign in with a normal Apple Account under Xcode → Settings → Accounts. Apple offers a free **Personal Team** for development. Apple's current [macOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos) lists App Groups as supported for free Apple developer accounts. This is distinct from the special FileProvider Testing Mode entitlement, which this prototype does not request. The complete signed-extension setup still needs runtime validation with that Personal Team; free account capability support alone does not establish that this particular configuration loads correctly. See Apple's [developer account overview](https://developer.apple.com/help/account/basics/developer-account-overview).

Apple's paid Developer Program is [US$99 per membership year](https://developer.apple.com/programs/enroll/) (regional prices vary) and provides standard distribution/notarization resources. It is not needed for `transfer-bench`. Do not enroll just to run the current native SMB experiments.

**VM sign-in resolved:** Xcode now loads the Personal Team and has successfully created a development certificate. Earlier failures included DNS and AVP guest identity errors; see the [sign-in diagnostic notes](results/2026-10-10-xcode-signin.md). The exact cause of recovery is not isolated. Signed build/provisioning also succeeded; actual extension loading remains a separate check.

Build and run the `TinyMounterPrototype` scheme with normal development signing. The source file is granted read-only access using a security-scoped bookmark from `NSOpenPanel`. Sharing that permission with the signed extension is a **runtime feasibility gate**. If the extension cannot resolve/access the bookmark, record the actual sandbox error and determine a supported permission/helper design. Do not remove the sandbox or add broad exceptions to make the test appear successful.

Both targets include a local-network usage description and network-client entitlement. If macOS requests local-network access, handle it for the app and extension. Do not assume a permission granted to the app also establishes extension access.

The unsigned compile check, which does not install or run the extension, is:

```sh
xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounterPrototype -configuration Release -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

`Tools/generate-project.py` reproducibly creates the checked-in two-target project using only Python's standard library. If changing target/source structure, update the generator too; regenerating replaces manual project/scheme edits. Signing team and identifier settings can live in the shared xcconfig.

## 3. First runtime validation

1. Select a small local fixture first. Open the new test location in Finder, read it, verify bytes against the source, then exercise a nonzero-offset range. This checks extension loading and handoff without the NAS.
2. Create another test location from the mounted NAS's large immutable fixture. Compare the CLI read-to-sink, read-to-stage, and provider-path read with the same requested ranges/cache conditions. The app does not mount the NAS automatically.
3. Watch callback logs while opening/seeking a video. Each fetch logs an opaque request ID, full/partial mode, returned offset/bytes, queue time, callback time before handoff, and transfer time. Logs avoid source names/paths.

   ```sh
   log stream --level info --predicate 'subsystem == "dev.tinymounter.prototype"'
   ```

4. Choose **Keep Downloaded**, wait until Finder completes the whole download, then test disconnected reads and restart persistence. Setting the policy or receiving a successful signal is not proof that the download finished.
5. Choose **Allow Removal**, then Finder's **Remove Download** when resetting clean test content. Do not remove/re-add the domain as ordinary reconnect logic. Do not evict a file in use by a player during timed runs.
6. Use **Remove Test Location** to unregister it and preserve downloaded files. Inspect the preserved location reported by the app. The source file is never deleted.

## Deliberate limitations

- One selected file, stable opaque item ID, persisted configuration, and pin-only change generations. No directory tree, remote polling, database, credential storage, upload queue, or automount manager yet.
- Metadata fingerprints use device/inode/size/mtime/ctime. The fixture must stay immutable while the domain exists. Changes cause version failure rather than automatic updates. Fingerprints are not immutable server revisions and cannot detect every timestamp-preserving edit. Reconnect/remount may change identity evidence and require selecting a fresh fixture.
- Two concurrent extension fetches, 1 MiB POSIX buffers, and a preferred 4 MiB returned extent. OS minimum ranges may be larger. These are initial experiment values, not performance-tuned defaults.
- A staging URL is never changed after completion; macOS owns the handoff. Cleanup of files orphaned by a provider/system crash has not yet been implemented. Do not run crash/long-duration cache-budget tests as though this were release-ready.
- Per-request queue/transfer logs help distinguish full-file from partial behavior, but do not yet instrument actual player first frame or system reader resumption.
- Download retention is implemented through Apple's content policy. The interface intentionally says “requested,” not “offline-ready.” Runtime pinning and eviction behavior still need verification.
- Blocking I/O containment, scheduler fairness, persistent metadata, robust authentication/reconnect, and direct-SMB comparison remain later steps in the feasibility work.

The immediate prerequisites are a mounted test share/file for the CLI baseline and a usable signing team for the Finder experiment. VM results must be compared against the VM's native SMB baseline, then repeated on the physical Mac before judging the original 190/280 MB/s expectations.
