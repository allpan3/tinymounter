# First performance prototype

Status: 2026-10-16. The signed [phase 2](phase2-plan.md) M4/M5 build browses granted SMB
folders from one catalog per location and reads files by item ID. VM browsing, checksummed reads,
restarts and outage checks are recorded in the [M4/M5 results](results/2026-10-14-catalog-browsing-reads.md).
The [runtime follow-up](results/2026-10-15-runtime-followup.md) verifies the initial reader
connection wait. The [window comparison](results/2026-10-15-read-ahead-window.md) adopted a
16 MiB read-ahead window, which avoided the system materialization race in 11 stress trials.
Finder's retained folder error remains open.
M6 adds Keep Downloaded, Allow Removal and a temporary Pause Downloads button, verified in the
[M6 results](results/2026-10-16-keep-pause.md).
The phase 1 one-file fixture build is gone (D3).

## Implemented and checked

- A dependency-free Swift package with `transfer-bench` and a reusable transfer engine.
- Source files opened read-only, using bounded `pread` calls; optional local staging uses exclusive creation and `pwrite` at the source offsets.
- Full/range reads, runtime-aligned ranges, empty files, metadata fingerprint checks, progress/cancellation, and cleanup on handled failures.
- JSONL reporting of byte range, filesystem, open/transfer/first-read time, sustained rate after the first chunk, CPU, process-lifetime peak RSS, cache label, and optional post-timing SHA-256 verification.
- A SwiftUI test harness and a replicated File Provider extension (section 2). The app saves a share-root grant, adds and removes locations, and owns all share I/O and every catalog write: it lists folders into each location's SQLite catalog and stages file bytes with the transfer engine. The extension reads the catalog read-only to page folders, fetches full and partial ranges by item ID from the app through a restricted File Provider service, runs read-ahead per item, and rejects all remote mutations.
- 129 unit tests passed on 2026-10-16. They cover transfer correctness and cancellation,
  read-ahead bounds and stale requests, full-handoff cleanup, catalog and listing consistency,
  safe paths, mount identity, share health, error classification, staging, settings, XPC messages,
  deadlines and launch reconciliation. Fixtures are local; unit tests do not read the NAS.
- Release CLI build and local end-to-end checks passed on 2026-10-16. The unsigned Release app and extension build succeeded with Xcode 27. Only Xcode's informational App Intents extraction warnings remained; there are no Swift compiler warnings in that build.
- The M3 build also built with Personal Team development signing and automatically generated Mac
  Team provisioning profiles. `codesign --verify --deep --strict` passed for the app including its
  embedded extension. Its signed artifacts were in `.build/xcode-personal/Build/Products/Release/`
  and its build log is `results/m3-20261012/signed-build.log`. The signed build additionally
  reports that it does not strip an already signed extension binary. The current M4/M5 build also passed development signing; see the October 15 runtime follow-up.

The results below were measured with the phase 1 fixture build. M4 and M5 keep its transfer
engine, staging handoff and approved read-ahead settings. Current-build checks are in the M4/M5 results and runtime follow-up linked above.

**NAS measurements are now available:** [first native SMB/staging results](results/2026-10-10-native-smb.md). Five paired 2 GiB runs and a separate range checksum completed successfully on the mounted share.

**Runtime verified:** domain registration, extension loading, shared document-scoped access to a local fixture, Finder reveal, partial reads with original-source checksums, and a full local download after a pin update. The complete file remained readable with automatic hydration disabled after app quit/relaunch. See [runtime results](results/2026-10-10-provider-runtime.md).

**App-owned NAS reader now verified:** direct extension reads still encounter the documented Network Volumes denial, so the approved experiment moves source reads into the already-authorized main app. NAS range checksums, a new local partial/full download, cached reads after app quit, and missing-range recovery after reconnect pass. Keep the app running for downloads. See [reader results](results/2026-10-10-app-reader.md).

**Sequential partial-read performance gate fails:** five paired 64 MiB diagnostic reads with 16 MiB extents measured 23.1 MB/s through File Provider versus 239.5 MB/s native SMB, a 9.6% ratio. Earlier 4 MiB fetches measured 6.3 MB/s. These are VM diagnostics, not the full acceptance series. Full reboot persistence and disk-pressure eviction remain unverified; later playback and outage checks are linked above.

**Delay diagnosis, October 11:** local and NAS traces correlate the recurring pause with `fileproviderd` waiting for its database batch flush before resuming a read. Temporary 64/256 MiB builds reached 69.9/141.1 MB/s over five paired 256 MiB samples, with 0.93/1.82-second median first-byte delays. These settings were not adopted; source and signed runtime were restored to 16 MiB. The [delay report](results/2026-10-11-provider-delay.md) proposed bounded read-ahead; it's now implemented (see below). The requested full-download attribution and verified NAS cache comparisons are now complete; they do not resolve the partial-read gate. The latest restored signed build log is `results/provider-delay-20261011/restored16-build.log`.

**Full-download control, October 11:** the unchanged full callback achieved a five-run median of 232.3 MB/s versus 254.5 MB/s native, with complete original/provider hashes matching. A separate 35 GiB single control reached 190.8 versus 197.4 MB/s. These used unknown NAS cache states; they are not disk-cold claims. See [full-download results](results/2026-10-11-full-download.md). The preferred partial extent remains 16 MiB.

**Players and read-ahead, October 11:** Finder double-click, Open With and Cmd-O make a coordinated whole-file read, so an uncached video always downloads fully before the player starts. VLC and IINA opened from their own File > Open stream with partial reads; QuickTime Player always downloads the whole file. Listing Finder in `NSFileProviderExtensionNonMaterializingProcessNames` made double-click do nothing, so Finder isn't listed; `ScopedBookmarkAgent` is (M5 follow-up). The extension now runs bounded sequential read-ahead, tuned for seeks at the user's request: seeks during streaming took 0.23–0.27 s, and long sequential partial reads measured 77–93 MB/s against about 253 MB/s native, fetching about 1.03× the bytes read. A throughput-first setting reached 59.7% of native; without read-ahead it was 9.6%. The partial-read gate still fails. See the [player and read-ahead results](results/2026-10-11-player-readahead.md). First-frame and seek-resume times couldn't be measured in this VM.

**Verified cache states, October 11:** five native/provider pairs per state measured full-download medians of **183.3 versus 192.7 MB/s (95.1%)** with NAS disk reads and **229.0 versus 247.2 MB/s (92.6%)** with the file fully in NAS RAM. Per-file residency and physical-disk counters verify every sample; representative full hashes match. Fully materialized reads with hydration disabled reached 3166.2 MB/s versus a 6322.8 MB/s local APFS control; that local gap remains unexplained. See [cache-state results](results/2026-10-11-cache-states.md).

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

For provider-path POSIX tests, add `--allow-hydration`. Some command runners inherit a policy that forbids downloading dataless files and otherwise fail with `EDEADLK`. This option changes only the benchmark process's I/O policy and restores it after each run; inherited/effective values are included in JSON. It also permits ctime changes only when the opened source is initially local and marked `SF_DATALESS`, because hydration changes that metadata. Device/inode, size and mtime checks remain; ordinary local files and NAS sources retain ctime checks. The JSON `ignoresMaterializationChangeTime` field records whether this exception applied. This is a fixture benchmark, not a general concurrent-edit validator.

`transferSeconds` includes staging allocation, reads/writes, final metadata check, and close; it excludes opening the source and post-timing checksums. `totalSeconds` includes the source open and range setup. `firstReadSeconds` measures time until the first `pread` returns, after the source open. `steadyStateMBps` excludes the first copied chunk and final metadata check/close. `--sync` adds and separately reports `fsync`; without it, staging bytes may still be in the OS's dirty page cache. Neither mode promises physical NAS-disk durability.

This initial harness does not collect wire-byte counters, negotiated security, SMB credits, provider callback traces, or reader-resume time into its JSON automatically. Capture SMB settings separately; extend instrumentation before final attribution. It uses one sequential POSIX stream, not a new SMB client. Existing native-client readahead still applies. The [benchmark plan](benchmark-plan.md) remains the full intended measurement program.

`Tools/run-native-series.py` now wraps this CLI to interleave five pairs of sink/staging runs, save SMB settings, and record before/after SMB session RX/TX counter deltas alongside each sample. Pass the selected file and a new local `--results-dir`; the default range is 2 GiB with `F_NOCACHE`. These are session counters, not a packet trace, and unrelated traffic on the same session can contribute. The script neither flushes the server cache nor proves it cold. It refuses to overwrite an existing results directory.

## 2. Build the Finder prototype

Open `TinyMounter.xcodeproj` in Xcode. Configure a development team and unique bundle identifier. Set the shared values in `Prototype/Config/Prototype.xcconfig`; both targets use `$(DEVELOPMENT_TEAM).$(TINYMOUNTER_BUNDLE_ID)` as their macOS App Group, and the extension bundle ID stays below the app's bundle ID. This team-prefixed macOS group form does not require Developer portal registration. The previously tested `group.…` override signed but failed runtime container access with these profiles. The checked-in identifiers are placeholders. Do not commit signing credentials or provisioning material.

**A paid membership is not the first step.** Sign in with a normal Apple Account under Xcode → Settings → Accounts. Apple offers a free **Personal Team** for development. Apple's current [macOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos) lists App Groups as supported for free Apple developer accounts. This is distinct from the special FileProvider Testing Mode entitlement, which this prototype does not request. The phase 1 build fetched both local and NAS content with Personal Team signing through the app-owned reader. See Apple's [developer account overview](https://developer.apple.com/help/account/basics/developer-account-overview).

Apple's paid Developer Program is [US$99 per membership year](https://developer.apple.com/programs/enroll/) (regional prices vary) and provides standard distribution/notarization resources. It is not needed for `transfer-bench`. Do not enroll just to run the current native SMB experiments.

**VM sign-in resolved:** Xcode now loads the Personal Team and has successfully created a development certificate. Earlier failures included DNS and AVP guest identity errors; see the [sign-in diagnostic notes](results/2026-10-10-xcode-signin.md). The exact cause of recovery is not isolated. Signed build/provisioning and local extension loading have now succeeded; see the separate runtime report.

Build and run the `TinyMounterPrototype` scheme with normal development signing. Its window is a
test harness for M4–M6, not the phase 2 interface (M7). Its Pause Downloads button stands in for
the menu bar item until M7. Nothing migrates from phase 1: remove
the fixture domains with the phase 1 build before the first run (D3). A domain without a catalog
fails every request with `serverUnreachable` and never reports an item as deleted.

**Share grant (M3).** Verified in the signed sandboxed app on 2026-10-12; see the
[M3 results](results/2026-10-12-share-grant.md). **Select Share…** opens `NSOpenPanel` at
`/Volumes`. The app accepts only a mounted smbfs volume root with `MNT_LOCAL` clear whose address
has an account and no password. It saves a read-only, security-scoped **app-scoped** bookmark and
the mount's `f_mntfromname` in `Application Support/tinymounter/Settings.json` in the app container
(mode 0600, never in the App Group: the bookmark holds the account and server address). Selecting
the same share again replaces the bookmark and keeps the grant, so its locations stay. Only the
app has `com.apple.security.files.bookmarks.app-scope` and `files.user-selected.read-only`; neither
target has document-scope. Whether app-scope is necessary in addition to user-selected access was
not isolated by the M3 test.

The app resolves the bookmark only while the mount table lists the share, once per mount session,
with `.withoutMounting`. Per session it holds one `O_EVTONLY` share-root descriptor and one per
location root, and it ends the session on unmount. It polls the mount table every 10 s and starts
a session by itself when the share is mounted. **Folder** is relative to the share; empty means
the full share. **Check Location** lists it and up to 3 child folders, then opens one file at
depth 2 or more with `fstat` only. It logs counts and times, never names. In M3, the depth-2
listing and depth-4 file open passed before and after relaunch, without another panel, privacy
prompt or mount. Only a healthy share was tested.

M4 and M5 passed their runtime checks in the signed app on 2026-10-14 and 2026-10-15; see the
[M4 and M5 results](results/2026-10-14-catalog-browsing-reads.md) for what is still unverified.

**Locations (M4).** Type a folder and a name, then click **Add Location**. The app creates the
location's catalog, `Catalogs/<domain ID>.sqlite` in the App Group, lists the folder into it,
saves the record in `Settings.json`, then adds the File Provider domain. Each location has **Show
in Finder** and **Remove Location**. Remove marks the record, removes the domain with
`.removeAll`, which deletes its downloaded copies, then deletes the catalog and the record. At launch, the app finishes any step that a crash interrupted, adds every
domain again, deletes catalogs that have no record, and leaves unknown domains alone. The same
folder can be two locations, each with its own domain and catalog.

**Browsing (M4).** The extension opens the catalog read-only and never creates one. For a folder
that was never listed, it asks the app to list it and waits at most 5 s; after that, Finder gets
`serverUnreachable`, and the app still finishes the listing. A listed folder comes from the
catalog at once, and is listed again in the background if its listing is over 60 s old. With the
app quit, listed folders still browse and never-listed ones fail with `serverUnreachable`. At
launch and whenever the share recovers, the app lists each materialized folder again, one at a
time (D6), except the system's own Trash folder. Only a complete listing writes the catalog, and only a tombstone that one wrote gives
`noSuchItem` ([phase 2 §5 and §7](phase2-plan.md#5-enumeration-and-changes)). Finder can retain a failed folder’s error after recovery until Try Again is clicked; no complete automatic workaround is installed.

**Reads (M5).** A fetch starts from the item's catalog row with a strict version check. The app
checks the version and the share state again, builds the path from its catalog, opens the file
beneath the location root, and compares its size, mtime and ctime with the row before it stages
any bytes. A changed file updates the row and fails with `versionNoLongerAvailable`, so the system
asks for the new version. A missing file fails with the transient `fileReadNoSuchFile`, and the
app lists its parent again.

**Finder actions (M3, M6).** The extension declares Keep Downloaded and Allow Removal under
`NSExtension` › `NSExtensionFileProviderActions`, with the identifiers and rules of
[phase 2 §8](phase2-plan.md#8-ui). Each file publishes `userInfo["keep"]` from its catalog row.
With the fixture build on macOS 27.0.1, Finder showed the matching custom action near the bottom
of its context menu after the item was republished. Finder's own Keep Downloaded was absent;
Download Now and Remove Download remain. `performAction` sends the file IDs to the app, at most
100 in each message and 1,000 in each action. The app records the request in the catalog and
signals the working set, and a kept file then reports `.downloadEagerlyAndKeepDownloaded`. With
the app quit, or with no reply in 10 s, the action fails with `serverUnreachable`.

Each new location makes macOS ask whether a test shell may access files it manages; allow it only
for that location.

This bookmark does not grant the extension Network Volumes privacy access on the tested macOS build. The main app resolves it for source reads. Both components retain the sandbox; no Full Disk Access, TCC reset, or sandbox exception is needed for this tested route.

The extension publishes a restricted File Provider service. The app connects via the domain manager and exports a per-domain reader on the resulting XPC connection, only for domains whose catalog it opened. Messages are JSON of at most 4096 bytes and hold IDs, versions and counts, never names. A list request carries a request ID and a folder's item ID; its reply, sent after the commit, carries the folder's listing generation and its entry, change and skip counts. A fetch carries a request ID, an item ID, the content version and a byte range; its receipt carries a staging leaf name and metrics. A keep request carries a request ID, at most 100 file IDs and the requested value; its reply, sent after the commit, carries the number of rows that changed. When a worker starts a fetch's transfer, the app sends a started message with the request ID; then it sends the bytes done at most every 0.5 s. Both sides check peer signing identity. At most two app transfers run concurrently for all domains, with at most four outstanding fetches per domain connection. A location queues at most 16 folders for listing, and a request for a folder that is already queued joins it. The app's own listings for Add Location and relisting run one at a time and are never refused. The app writes an exclusive staging file in the shared App Group, and the extension moves it into the provider's temporary directory before handing it to macOS. The move must remain on the same volume. No bulk bytes pass over XPC.

The app retries lost connections with bounded backoff. A new per-domain extension reader service gives fetches up to 5 s from its creation for the first connection, checking cancellation every 100 ms. After attachment, losing the reader still fails at once. The deadline is shared, so subsequent requests cannot restart the wait. Never-listed folder enumeration retains its existing connection requirement. The 60 s transfer stall deadline still starts at the app’s `started` message. Closing the window is different from quitting the process; the prototype must remain running to supply missing content and to list folders that were never listed.

Both targets include local-network and Network Volumes usage descriptions and the network-client entitlement. Network Volumes privacy for an existing SMB mount is distinct from Local Network permission for sockets. If macOS requests local-network access, handle it for the app and extension. Do not assume a permission granted to the app also establishes extension access.

The unsigned compile check, which does not install or run the extension, is:

```sh
xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounterPrototype -configuration Release -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

`Tools/generate-project.py` reproducibly creates the checked-in two-target project using only Python's standard library. If changing target/source structure, update the generator too; regenerating replaces manual project/scheme edits. Signing team and identifier settings can live in the shared xcconfig.

## 3. First runtime validation

1. Remove the phase 1 fixture domains first (D3). Then build, sign and launch the app. With the
   share connected in Finder, click **Select Share…** and select the share root.
2. Type a folder and a name, click **Add Location**, then **Show in Finder**. Browse the root and
   two levels down. The listing log gives each folder's entry count, skipped names and times.
3. Read a range of a file at least two levels deep through its CloudStorage path, then the same
   range natively, and compare the two `sha256` values. The JSONL holds the source path, so
   compare it with a script that prints only whether they are equal.

   ```sh
   mkdir -p .build/staging
   .build/release/transfer-bench '<CloudStorage path>' --allow-hydration --stage-dir .build/staging --verify --offset N --length 16777216
   ```

4. Watch the logs while you browse, read, or seek in a video. Lines hold request, item and domain
   UUIDs, counts, sizes, times and error codes, never names or paths. `kill -USR1 <app pid>` logs
   the app's diagnostic counts: catalogs, items, tombstones, listed folders, stage files,
   descriptors, RSS, kept files and paused catalogs.

   ```sh
   log stream --level info --predicate 'subsystem == "dev.tinymounter.prototype"'
   ```

5. Use Finder's **Remove Download** when resetting clean test content. A partially downloaded copy offers only **Download Now**: download it fully, then remove it. Check eviction by allocated size (`du`), not the `dataless` flag, which stays set on partial copies. Right after a download, Remove Download can briefly report “Resource busy”; retry after a few seconds. Do not remove/re-add the domain as ordinary reconnect logic. Do not evict a file in use by a player during timed runs.
6. Use **Remove Location** to remove the domain. It also deletes the location's downloaded copies and its CloudStorage folder (D3). The files on the share never change.

## 4. Physical-Mac check

The VM numbers are relative to the VM's own native SMB. On the physical Mac, run the same comparisons
once, wired, with nothing else heavy running. About 30 minutes:

1. **Build and sign** in Xcode with the Personal Team, as in section 2. Launch the app and wait for
   "Source reader connected".
2. **Native baseline.** Pick one large video on the mounted share, 5 GB or more. Then run
   `.build/release/transfer-bench '<file on /Volumes/…>' --offset 0 --length 2147483648 --runs 3 --no-cache`.
3. **File Provider sequential reads.** Add a location whose folder holds the same file. Run the
   same command against the CloudStorage path with `--allow-hydration`, at offsets 0, 3 GiB and
   6 GiB. Every sample needs a fresh range, so don't repeat offsets.
4. **Full download.** Evict the copy with Finder's Remove Download (a partly downloaded copy needs
   Download Now first). Then time Finder's Download Now until the cloud badge disappears.
5. **Players.** Evict again. Open the file from VLC's or IINA's own File > Open, and note the time to
   the first picture. Do 20 seeks to unplayed parts and note any wait over 1 second. Then try a
   Finder double-click to see the full-download wait.
6. **Offline.** Right-click the file, click Keep Downloaded, and wait until the cloud badge
   disappears. Disconnect the Mac from the network, play the file and seek in it, then connect again.
7. **Logs.** Keep `log stream --level info --predicate 'subsystem == "dev.tinymounter.prototype"'`
   running during steps 3–5 and save its output. It contains no file names or paths.

Record the Mac model, macOS build, link speed and NAS cache state where known. Share the numbers,
not the raw `results/` folder, which can hold private paths.

## Deliberate limitations

- Read-only, on the user's own Finder connection: one grant per share, and locations that are folders on it. The app never mounts, writes, renames or deletes on the share. The Settings window, the menu bar, notifications and the Storage pane are not built (M7–M8).
- Keep Downloaded is a request for each file, not proof of a download (phase 2 decision 3). The system downloads a kept file only when its parent folder is materialized: a kept file in a folder that the system never enumerated waits until the folder is enumerated. Evicting a kept file fails; evicting its folder evicts it, and the system downloads it again at once. The app doesn't list the requests or show download state yet (M7), and Remove Location deletes them with the catalog.
- Pause Downloads sets `paused` in every catalog. Kept files then report `.downloadLazily` and read-ahead stops. The extension cancels its running system and speculative fetches and refuses those that start while paused. A background fetch that is still waiting for the first reader connection is cancelled when the reader connects. Files that apps open, and Finder's Download Now, still download. Resume and each app launch clear Pause. Changes run one at a time, in order. A failed change shows a message, and while a catalog may still be paused, the window offers Resume Downloads. While paused, the user can also remove a kept file's download; Resume downloads it again. Whether kept files stay on disk while paused when the system needs the space is untested.
- NAS changes show only after a listing: when the system enumerates a never-listed or evicted folder; in the background when it enumerates a folder listed over 60 s ago; for each materialized folder at app launch and after the share recovers; and as a fingerprint check at each fetch. There is no `CHANGE_NOTIFY` and no polling, so a change between these events doesn't show, and a downloaded copy stays stale until then. A NAS rename is a delete plus a create.
- Only a complete listing changes the catalog, after `fstatat` confirmed that each missing name is gone. A listing that would remove every child of a folder, remove a kept file, or change a kind is held; a listing that starts at least 15 s later applies what it finds (D5). Symlinks, special files, invalid names and name-key collisions are not shown; the listing log counts them as skipped.
- Content versions are `f1:<size>:<mtime_ns>:<ctime_ns>` (D1), so a remount does not download copies again. Each transfer still checks the full snapshot, device and inode included, on its open descriptor. A change that keeps size and timestamps can't be detected.
- Two concurrent extension fetches per domain, two app transfers for all domains, 1 MiB POSIX buffers, and a preferred 16 MiB returned extent for demand misses. OS minimum ranges may be larger. A small seek can download up to 16 MiB.
- Read-ahead is per item: up to 8 planners, by item and content version, and the least recently used goes. It starts only when a miss continues the previous miss of the same item. It keeps one 16 MiB speculative fetch in flight, at most one chunk past the latest sequential miss, and pauses 30 ms before each chained request. Without that pause, `fileproviderd` held a waiting seek until speculation stopped. A seek cancels only its own item's speculation. A successful full handoff retires that item/version's pending speculation and cancels its running speculation; future misses after eviction can start a new run. After a reader stops, up to 16 MiB can still download. A fetch counts as speculative only if it covers the planned offset and length. A returned range never extends into bytes already delivered, and speculation skips them: rewriting them raced IINA's reads and made `fileproviderd` download the whole file. A demand that overtakes a request the system hasn't delivered retires it. A 128 MiB window let a moving-boundary stress reader trigger a system materialization race and a full download in 5/5 trials; the one-chunk window avoided it in 11, which doesn't prove it gone. Items share the domain's pipeline depth of 2, so one file's read-ahead can delay another file's read. The sequential partial-read gate still fails.
- The first request in an outage waits for the mount's own timeout, about 30 s measured. After a call fails with a timeout-class errno, or a listing or transfer makes no progress for 15 s, the share is unresponsive: requests fail at once with `serverUnreachable`, and one probe runs every 5 s until the server answers. A session start whose bookmark resolution fails while the share is mounted is handled the same way, and the probe then starts the session. A blocked SMB kernel call can't be interrupted. Downloaded files keep working; see the [offline results](results/2026-10-11-offline-reading.md), measured with the fixture build.
- The main app must stay running for misses and for folders never listed. When a worker starts a fetch, the app says so and then reports progress at most every 0.5 s. From that start, the extension ends its wait after 60 s with neither progress nor a reply (D2). Before it, a fetch that waits for one of the two workers that all locations share has no deadline: only the reply, a lost connection or cancellation ends it. With the app stopped by `SIGSTOP`, a fetch failed 60.0 s after its last progress (M6). Not verified at runtime: whether the system cancels a waiting fetch, as it can cancel one that stops making progress ([phase 2 §9](phase2-plan.md#9-milestones)).
- A staging URL is never changed after completion; macOS owns the handoff. App staging leases are released on completion, cancellation or connection invalidation. At launch, before any reader connects, the app deletes leftover stage files in `ReaderStaging`. Each extension process deletes the stage files in its temporary directory that were created before it started, and logs `temp_removed` and the stage files left. Runtime cancellation races, adversarial IPC requests and long-duration staging growth remain unverified.
- Create, modify and delete return `fileWriteNoPermission` and are counted in the log (`mutation=`). A reimport `createItem` (`.mayAlreadyExist`) completes with the live row of the same name and kind, and with `nil` only for a file without contents that no row matches; anything else keeps the error. A matched file with contents is downloaded again from the NAS unless its size equals the row's and its modification date is less than 1 µs from the row's, as measured between `Date`s. A NAS change that keeps the size and mtime and changes only the ctime is not found on reimport, so the old disk copy stays as the current version. Not verified at runtime: it needs a system reimport.
- Per-request logs record full or partial mode, demand, sequential or speculative kind, Finder (`viewer`) and system flags, queue and transfer times. They don't instrument actual player first frame or system reader resumption.
- Finder-launched opens of content that isn't downloaded wait for a full download.
- Blocking I/O containment, scheduler fairness, robust authentication/reconnect, and direct-SMB comparison remain later steps in the feasibility work.

The mounted share, Personal Team signing and app-owned NAS access prerequisites are met in this VM. Full-download throughput exceeds 90% in both verified NAS cache states. Seek-first read-ahead keeps scripted seeks at 0.23–0.38 s but reaches only about 45% of native for 512 MiB sequential partial reads with the one-chunk window, below the 90% target. Finder always downloads uncached files fully before an app opens them. Local cached-read parity, disconnected retention and shipping lifecycle also remain open. VM results must be compared against the VM's native SMB baseline, then repeated on the physical Mac before judging the original 190/280 MB/s expectations.
