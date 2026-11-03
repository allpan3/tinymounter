# First performance prototype

Status: 2026-10-19. The signed [phase 2](phase2-plan.md) M4/M5 build browses granted SMB
folders from one catalog per location and reads files by item ID. VM browsing, checksummed reads,
restarts and outage checks are recorded in the [M4/M5 results](results/2026-10-14-catalog-browsing-reads.md).
The [runtime follow-up](results/2026-10-15-runtime-followup.md) verifies the initial reader
connection wait. The [window comparison](results/2026-10-15-read-ahead-window.md) adopted a
16 MiB read-ahead window, which avoided the system materialization race in 11 stress trials.
Finder's retained folder error remains open.
M6 adds Keep Downloaded, Allow Removal and Pause Downloads, verified in the
[M6 results](results/2026-10-16-keep-pause.md). M7 replaces the test window with the Settings
window, the menu bar item and notifications, verified in the
[M7 results](results/2026-10-16-settings-window.md). M8 adds the Storage pane, Remove Downloads
and folder completion, verified in the [M8 results](results/2026-10-18-storage-pane.md).
M9 showed phase 2's exit criteria 1 to 6 in the VM, also after crashes and outages, and M10's VM
part checked an update, a deleted app and a crash during Remove Location; see the
[M9 results](results/2026-10-18-exit-validation.md) and [section 5](#5-install-update-and-remove).
The phase 1 one-file fixture build is gone (D3).

M16 disk-space protection passed the signed isolated VM checks on 2026-10-22, including retry
after relaunch and manual Pause. All 192 tests and required checks passed. The signed update is
installed on the physical Mac with its existing location retained. Physical-Mac low-space checks
remain.
See the [disk-space results](results/2026-10-21-disk-space-protection.md).

M17 checked location changes and removal in the signed VM on 2026-10-22. Interrupted Apply
and Remove recovered without affecting a second location's kept copy. Provider off/on preserved
both configurations, including across relaunch. No production code changed. See the
[location lifecycle results](results/2026-10-22-location-lifecycle.md) for limits.

## Implemented and checked

- A dependency-free Swift package with `transfer-bench` and a reusable transfer engine.
- Source files opened read-only, using bounded `pread` calls; optional local staging uses exclusive creation and `pwrite` at the source offsets.
- Full/range reads, runtime-aligned ranges, empty files, metadata fingerprint checks, progress/cancellation, and cleanup on handled failures.
- JSONL reporting of byte range, filesystem, open/transfer/first-read time, sustained rate after the first chunk, CPU, process-lifetime peak RSS, cache label, and optional post-timing SHA-256 verification.
- A SwiftUI app with a Settings window and a menu bar item, and a replicated File Provider extension (section 2). The app saves a share-root grant, adds and removes locations, and owns all share I/O and every catalog write: it lists folders into each location's SQLite catalog and stages file bytes with the transfer engine. The extension reads the catalog read-only to page folders, fetches full and partial ranges by item ID from the app through a restricted File Provider service, runs read-ahead per item, and supports new ordinary files/folders only in explicitly enabled locations. Initial folder naming is implemented through an app-owned SMB client; general modify/delete remain denied. Signed Finder checks pass, including file Keep Both.
- 140 unit tests passed on 2026-10-18. They cover transfer correctness and cancellation,
  read-ahead bounds, stale requests and evictions, full-handoff cleanup, catalog and listing
  consistency, storage sums, folder completion, safe paths, mount identity, share health, error
  classification, staging, settings, XPC messages, deadlines and launch reconciliation. Fixtures
  are local; unit tests do not read the NAS.
- Release CLI build and local end-to-end checks passed on 2026-10-18. The unsigned Release app and extension build succeeded with Xcode 27. Only Xcode's informational App Intents extraction warnings remained; there are no Swift compiler warnings in that build.
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

**Players and read-ahead, October 11:** in the measured VM configurations, Finder double-click, Open With and Cmd-O made a coordinated whole-file read, so an uncached video downloaded fully before the player started. VLC and IINA opened from their own File > Open stream with partial reads; QuickTime Player always downloads the whole file. Listing Finder in `NSFileProviderExtensionNonMaterializingProcessNames` made double-click do nothing, so Finder isn't listed; `ScopedBookmarkAgent` is (M5 follow-up). The extension now runs bounded sequential read-ahead, tuned for seeks at the user's request: seeks during streaming took 0.23–0.27 s, and long sequential partial reads measured 77–93 MB/s against about 253 MB/s native, fetching about 1.03× the bytes read. A throughput-first setting reached 59.7% of native; without read-ahead it was 9.6%. The partial-read gate still fails. See the [player and read-ahead results](results/2026-10-11-player-readahead.md). First-frame and seek-resume times couldn't be measured in this VM.

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

Build and run the `TinyMounterPrototype` scheme with normal development signing. The app has the
phase 2 interface of [ui-design.md](ui-design.md): a Settings window (⌘,) with the locations in
its sidebar, and a menu bar item with Pause Downloads. With no locations, or with the menu bar
item hidden, the window opens at launch. Closing it keeps the app running; the Dock icon or the
menu bar item opens it again. Nothing migrates from phase 1: remove
the fixture domains with the phase 1 build before the first run (D3). A domain without a catalog
fails every request with `serverUnreachable` and never reports an item as deleted.

**Servers and share grants.** Add Server… saves an SMB server address without mounting a share.
Choose Add Share… in the location's Share menu or beside the saved server. The app offers SMB
shares already connected on this Mac, including hidden shares. Selecting a connection at another
address asks for confirmation before associating it with this server. Connect Another Share…
uses macOS's login dialog and share selector. The app never sees the password.

Then `NSOpenPanel` opens on the selected share, and the user clicks Open. The app accepts only a
mounted smbfs volume root with `MNT_LOCAL` clear whose address has an account and no password.
It saves a read-only, security-scoped app-scoped bookmark and the mount's `f_mntfromname` in
`Application Support/tinymounter/Settings.json` in the app container, mode 0600. It never saves
these in the App Group. Only the app has `com.apple.security.files.bookmarks.app-scope` and
`files.user-selected.read-write`; ordinary share bookmarks remain deliberately read-only. Select Again… replaces the bookmark and keeps the grant ID.

Connect mounts a share's saved address. Disconnect ejects that connection, including one selected
from Finder. Remove ejects the server's associated connections before deleting its entry. A busy
share keeps its entry and shows an error; no eject is forced. Other Connected Shares shows mounts
without a saved grant, with Use Share and Disconnect, so a hidden mount remains manageable.

The original grant and connection flow was verified in [M3](results/2026-10-12-share-grant.md) and
[M12](results/2026-10-18-connect-in-app.md). The
[connection-management follow-up](results/2026-10-18-connection-management.md) passed signed VM
checks, including migration of an existing location, busy ejects, removal and re-add, and
reuse of a visible Finder mount. The update is installed and launches on the physical Mac;
connection checks there remain.

**File Provider approval.** If macOS disables the File Provider, the location shows
"File Provider is off." and Open System Settings…. In Extensions, open TinyMounterPrototype
and turn on File Provider. The location's status updates when the system reports the change;
the user does not need to remove the location or restart the app. The
[approval checks](results/2026-10-18-file-provider-approval.md) verified recovery on the physical
Mac and the new action in the signed VM build. The UI update is now installed on the physical
Mac. After the requested reset, the user resumed Finder browsing.

The app resolves the bookmark only while the mount table lists the share, once per mount session,
with `.withoutMounting`. Per session it holds one `O_EVTONLY` share-root descriptor and one per
location root, and it ends the session on unmount. It polls the mount table every 10 s and starts
a session by itself when the share is mounted. **Folder** is relative to the share; empty means
the full share. In M3, a test button listed a depth-2 folder and opened a depth-4 file before and
after relaunch, without another panel, privacy prompt or mount. Only a healthy share was tested.

M4 and M5 passed their runtime checks in the signed app on 2026-10-14 and 2026-10-15; see the
[M4 and M5 results](results/2026-10-14-catalog-browsing-reads.md) for what is still unverified.

**Locations (M4, M7).** Click `+` or **New Location** (⌘N), or **Duplicate** a location, which
makes a "Not added" draft. Choose the Server, type or select the Folder, then click **Add**. The
app creates the location's catalog, `Catalogs/<domain ID>.sqlite` in the App Group, lists the
folder into it, saves the record in `Settings.json`, then adds the File Provider domain. A Name
change applies at once. A Server or Folder change needs **Apply**, which replaces the domain and
its downloaded copies. Each location has **Show in Finder** and **Remove Location…**, which asks
whether to save the Keep Downloaded list. Remove marks the record, removes the domain with
`.removeAll`, which deletes its downloaded copies, then deletes the catalog and the record. At launch, the app finishes any step that a crash interrupted, adds every
domain again, deletes catalogs that have no record, and leaves unknown domains alone. The same
folder can be two locations, each with its own domain and catalog.

**Menu bar and notifications (M7).** The menu bar item shows each location's state, or "42%
downloaded" while it downloads. Quit warns while downloads are in progress. A notification posts
once per share per outage: when a share that has locations disconnects or stops responding, or
when a download that the user started fails for that reason. None posts at launch, and none
holds a file name. General turns notifications and the menu bar item off.

**Storage and folder completion (M8).** Storage shows each location's downloaded space, the sum
of the catalog sizes of the files in its materialized set, then the total and the space left. A
partly downloaded file isn't in that set, so it doesn't count. **Remove Downloads…** evicts the
downloaded files that are not kept, after a confirmation; a file that an app has open stays, and
the app says how many stayed. While the user types in Folder, the app lists the typed parent
folder and suggests its subfolders. Return on a suggestion also submits it, so a draft is added.

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

Guest SMB connections are accepted after removing macOS's empty password field from the mounted
address. The verified SMB mount identity supplies the saved address; a separate remount URL is
not required, because manual guest mounts do not supply one. Addresses containing a password
remain rejected. Existing grants and the saved format do not change. The signed VM app saved a
guest grant and read files that matched the source
([results](results/2026-10-19-guest-connections.md)).

Each new location makes macOS ask whether a test shell may access files it manages; allow it only
for that location.

This bookmark does not grant the extension Network Volumes privacy access on the tested macOS build. The main app resolves it for source reads. Both components retain the sandbox; no Full Disk Access, TCC reset, or sandbox exception is needed for this tested route.

The extension publishes a restricted File Provider service. The app connects via the domain manager and exports a per-domain reader on the resulting XPC connection, only for domains whose catalog it opened. Messages are JSON of at most 4096 bytes. Reads carry IDs, versions and counts. A create request also carries a validated leaf name, kind and opaque local inbox ID; source values are never logged. A list request carries a request ID and a folder's item ID; its reply, sent after the commit, carries the folder's listing generation and its entry, change and skip counts. A fetch carries a request ID, an item ID, the content version and a byte range; its receipt carries a staging leaf name and metrics. A keep request carries a request ID, at most 100 file IDs and the requested value; its reply, sent after the commit, carries the number of rows that changed. When a worker starts a fetch's transfer, the app sends a started message with the request ID; then it sends the bytes done at most every 0.5 s. Both sides check peer signing identity. At most two app transfers run concurrently for all domains, with at most four outstanding fetches per domain connection. A location queues at most 16 folders for listing, and a request for a folder that is already queued joins it. The app's own listings for Add Location and relisting run one at a time and are never refused. The app writes an exclusive staging file in the shared App Group, and the extension moves it into the provider's temporary directory before handing it to macOS. The move must remain on the same volume. No bulk bytes pass over XPC.

The app retries lost connections with bounded backoff. A new per-domain extension reader service gives fetches up to 5 s from its creation for the first connection, checking cancellation every 100 ms. After attachment, losing the reader still fails at once. The deadline is shared, so subsequent requests cannot restart the wait. Never-listed folder enumeration retains its existing connection requirement. The 60 s transfer stall deadline still starts at the app’s `started` message. Closing the window is different from quitting the process; the prototype must remain running to supply missing content and to list folders that were never listed.

Both targets include local-network and Network Volumes usage descriptions and the network-client entitlement. Network Volumes privacy for an existing SMB mount is distinct from Local Network permission for sockets. If macOS requests local-network access, handle it for the app and extension. Do not assume a permission granted to the app also establishes extension access.

The unsigned compile check, which does not install or run the extension, is:

```sh
xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounterPrototype -configuration Release -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

`Tools/generate-project.py` reproducibly creates the checked-in two-target project using only Python's standard library. If changing target/source structure, update the generator too; regenerating replaces manual project/scheme edits. Signing team and identifier settings can live in the shared xcconfig.

## 3. First runtime validation

1. Remove the phase 1 fixture domains first (D3). Then build, sign and launch the app. Click
   **Add Server…** in the Server menu and save the address. In Share, click **Add Share…**,
   select an existing connection or connect another share, then click Open in the panel.
2. Type a folder and a name, click **Add**, then **Show in Finder**. Browse the root and
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
6. Use **Remove Location…** to remove the domain. It also deletes the location's downloaded copies and its CloudStorage folder (D3). The files on the share never change.

Folder-listing log lines separate catalog lookup, session acquisition, the location root,
`openat`, and time in `getattrlistbulk`, with a bulk-call count. `list_ms` still covers the whole
listing stage. These fields diagnose the physical Mac's
[first-folder delay](results/2026-10-18-first-folder-delay.md); they do not change the first-page
deadline or listing behavior. The diagnostic build is installed on the physical Mac. App and
mount resets did not reproduce the pause, but existing locations refresh and warm the share
before a new location is browsed. A new catalog alone does not establish cold SMB access.

## 4. Physical-Mac check

The [physical-Mac follow-up](results/2026-10-19-physical-mac-use.md) records the user's fast
browsing and playback, partial reads and reported sleep/wake and network checks. macOS restart
and the full performance series below remain unverified.

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
   Finder double-click and record whether it requests partial reads or waits for a full download.
6. **Offline.** Right-click the file, click Keep Downloaded, and wait until the cloud badge
   disappears. Disconnect the Mac from the network, play the file and seek in it, then connect again.
7. **Logs.** Keep `log stream --level info --predicate 'subsystem == "dev.tinymounter.prototype"'`
   running during steps 3–5 and save its output. It contains no file names or paths.

Record the Mac model, macOS build, link speed and NAS cache state where known. Share the numbers,
not the raw `results/` folder, which can hold private paths.

## 5. Install, update and remove

These steps keep the prototype for daily use. The VM checked them on 2026-10-18
([M9 results](results/2026-10-18-exit-validation.md#daily-use-in-the-vm-m10)). Installation and
Add Share also passed on the physical Mac on 2026-10-18
([picker investigation](results/2026-10-18-share-picker-delay.md)). The user reports successful
daily-use checks except macOS restart on 2026-10-19; see the
[physical-Mac results](results/2026-10-19-physical-mac-use.md) for the evidence and limits.

The user approved installing the M14 folder-keep build on 2026-10-19. Its signature and running
app and extension were verified in Applications, and launch retained the existing location and
keep request. The user then confirmed that folder keeping works. Physical-Mac offline checks
remain open
([installation results](results/2026-10-19-folder-keeps.md#physical-mac-installation-2026-10-19)).

**Install.** Build and sign with the Personal Team, as in section 2, and keep one copy of the app.
The build embeds no provisioning profile, because its entitlements need none on macOS, so the
7-day limit of free provisioning profiles doesn't apply. Its signature uses Xcode's Apple
Development certificate, which is valid for one year (in the VM, from 2026-10-11 to 2027-10-11).
Build again with a new certificate before it expires: what an expired one does is untested.

**Update.** Quit tinymounter, build the new version, and open it. After Quit, the app stays
stopped: only a crash makes the extension start it again. Keep the same team and bundle
identifier, because the settings and catalogs are in containers named after them. While the
formats stay the same, the locations, their downloads and their Keep Downloaded requests stay.
Until release, no build migrates settings, catalogs or pending changes from an earlier build.
After a format change, finish or export pending changes with the old build, remove the
locations, and add them again with the new build. If that isn't possible, the new build shows
Start Fresh… in General when it can't read the settings. It removes every location with
macOS's option to keep changes that did not upload, opens that folder in Finder, and moves the
earlier settings, outboxes and catalogs aside in the containers. A location's write grant
implies the SMB-only write confirmation, and an inactive grant is retained when Read only is
enabled.

Pending saves of a file keep their arrival order, and only the newest complete save publishes.
The [ordering implementation](results/2026-10-29-pending-save-order.md) passes core checks and a
signed interrupted-save update check. Retired-save cleanup and status reporting pass required
VM checks; their signed checks remain. Retry Pending Changes attempts cleanup only with complete artifact evidence;
uncertain data stays retained. A private stage or backup create that got no answer is sent
again. It is exclusive, so it succeeds only while the name is free. An older save settles such
a create with an exclusive create that the server deletes on close. When the name is taken, the
app opens the occupant on the same connection with delete access and no sharing. It deletes the
occupant only if it is a regular file of 0 bytes with one link, no named streams and the empty
DACL that the private create sets, and then sends the create once more. Anything else keeps the
save uncertain. A lost create that the server carries out after the save settled can still leave
an empty private file. Stop Uploading for a save that never reached the server, or whose
conflict copy is published, first writes a copy through a save panel. The app checks the copy
against the save before it ends the save. macOS's next send of those contents gets the server's
version, which replaces the local file. This is not verified in the VM yet. The pane reports
local saved-copy bytes under the existing
2 GiB free-space reserve and can dismiss resolved conflict notices without removing receipts.
The 2026-10-30 completed-cleanup follow-up passes required VM checks; signed checks remain.
Its cleaningUp state retains uncertain removals and keeps publication receipts.

The catalog records departures from former parents for known file moves. The catalog API is
preparation for M21; the provider does not yet admit cross-folder moves. A row keeps its f1
version until a verified full handoff establishes an immutable receipt. The immutable enumeration
key keeps folder-page cursors valid when initial naming changes the lookup key. Catalogs carry no
schema version and no build migrates them: a catalog from a build with a different schema fails
to open, and the location must be added again.

**Remove.** In this order:

1. In Settings, click **Remove Location…** for each location. This removes it from Finder with its
   downloaded copies. The files on the share don't change.
2. In Servers, select each server and click `−`. Remove ejects its associated shares before
   forgetting the server. If an eject fails, close open files and try again. Disconnect any
   remaining test mounts in Other Connected Shares.
3. In General, turn off **Open at login**.
4. Click **Quit tinymounter** in the menu bar item.
5. Delete `TinyMounterPrototype.app`.
6. Optionally, delete its data: `~/Library/Containers/<bundle ID>` and
   `~/Library/Containers/<bundle ID>.provider`, and
   `~/Library/Group Containers/<team>.<bundle ID>`. They hold the share grant, the settings and the
   catalogs, which hold the names of the files on the share.

If you delete the app first, its locations stay: Finder's sidebar keeps them, macOS keeps their
domains and downloaded copies, and the old extension keeps running. Downloaded files still open;
the others fail. To clean up, build and open the app again, then remove the locations. If the app
stops during Remove Location, it says "The removal is not complete", and its next launch finishes
the removal.

## Deliberate limitations

- The reader reserves 2 GiB on its staging volume, plus temporary space for concurrent downloads.
  A blocked keep shows Not sufficient space. Blocked kept files retry every 30 s when space
  returns, including after relaunch; manual Pause, disconnected and disabled locations stop
  retries. Ordinary on-demand reads fail clearly. No kept copy is evicted to make room. This
  cannot prevent other processes from filling the disk, and OS eviction under pressure remains
  unverified. If the retry file cannot be saved, an unsaved request is lost on app relaunch.

- One macOS mount grant per share, and locations that are folders on it. The app asks macOS to mount the address that the user types, with macOS's own dialogs, and hides the mount from Finder's sidebar, so that Finder shows only the locations (M12). When macOS drops a share that has locations, the app asks macOS to mount it again with the password that the user saved in the Keychain; after an eject, it waits until the share is mounted again, or until the user clicks Connect in Servers (M11, M12). The user can't eject a hidden share in Finder, so Servers has Disconnect. New locations default to writable setup with a scoped grant and safety confirmation. Existing read-only locations stay read-only. Supported writes are new files/folders, protected content saves and same-folder renames of verified ordinary files. Moves, deletion and Finder Replace remain unavailable.
- Keep Downloaded is a request for a file or folder, not proof of a download (phase 2 decision 3). M14 adds recursive folder requests, verified in the signed VM app ([results](results/2026-10-19-folder-keeps.md)). The system eagerly enumerates kept folders, and newly listed descendants inherit retention. Allow Removal cancels a request while preserving independent child requests. A folder is Available offline only if every descendant folder has an unskipped complete listing and is materialized, and every file passes the local-copy check. The system downloads an independently kept file only when its parent folder is materialized: a kept file in a folder that the system never enumerated waits until the folder is enumerated. Evicting a kept file fails; evicting its folder evicts it, and the system downloads it again at once. The location pane shows Requested, Update in progress or Available offline. It signals the working set and waits for macOS to apply provider changes, then reads fresh local metadata and rechecks catalog versions. Available offline requires current content with matching catalog size and modification date; this covers the source version last observed by the app, not live NAS freshness. The wait covers the location. Before waiting, the app rechecks previously synchronized content versions against fresh local metadata and materialization, so unrelated downloads do not reset their status. New or changed versions still need the wait; folder status uses current membership and listing completeness. Provider disablement or replacement clears remembered verification ([status-refresh results](results/2026-10-19-keep-status-refresh.md)). Signed VM checks passed, including source edits that preserved size/date ([results](results/2026-10-19-offline-versions.md)). Remove Location can save them, and a later location on the same share takes the ones inside its folder; for independently kept files outside a folder request, the app asks whether to download them now if their parent folders are not materialized (M7).
- Pause Downloads sets `paused` in every catalog. Kept files then report `.downloadLazily`, kept folders use lazy namespace policy, and read-ahead stops. The extension cancels its running system and speculative fetches and refuses those that start while paused. A background fetch that is still waiting for the first reader connection is cancelled when the reader connects. Files that apps open, and Finder's Download Now, still download. Resume and each app launch clear Pause. Changes run one at a time, in order. A failed change shows a message, and while a catalog may still be paused, the menu bar item offers Resume Downloads. While paused, the user can also remove a kept file's download; Resume downloads it again. Whether kept files stay on disk while paused when the system needs the space is untested.
- NAS changes in listed materialized and kept folders are discovered while the app runs. M15 uses at most 64 native SMB directory watches per mount session plus periodic reconciliation, due 60 s after a successful listing. One automatic listing runs at a time, with a one-second gap and failure backoff, so this is not a fixed latency guarantee. Unvisited unkept trees are not scanned. Launch, wake, recovery and access checks also refresh listings. A downloaded copy can stay stale between refreshes. A NAS rename is a delete plus a create, and its keep request does not follow. Signed isolated VM checks passed. The signed M15 update is installed and running on the physical Mac with the existing location retained; the user confirmed live changes work there ([results](results/2026-10-19-nas-change-discovery.md)).
- Keep Downloaded transfers publish progress for Finder's native circle. File progress reports transferred bytes; kept ancestor folders show indeterminate progress while descendant transfers run. The circle starts with the transfer, not during earlier enumeration, and clears when it ends or fails. It is a read-only indicator; Pause Downloads remains the control for background transfers. Settings remains the check for Available offline. The signed VM comparison passed; the signed update is installed on the physical Mac ([results](results/2026-10-19-keep-status-refresh.md)).
- Only a complete listing changes the catalog, after `fstatat` confirmed that each missing name is gone. A listing that would remove every child of a folder, remove a kept file, or change a kind is held; a listing that starts at least 15 s later applies what it finds (D5). Symlinks, special files, invalid names and name-key collisions are not shown; the listing log counts them as skipped.
- Content versions are `f1:<size>:<mtime_ns>:<ctime_ns>` (D1), so a remount does not download copies again. Each transfer still checks the full snapshot, device and inode included, on its open descriptor. A change that keeps size and timestamps can't be detected.
- Two concurrent extension fetches per domain, two app transfers for all domains, 1 MiB POSIX buffers, and a preferred 16 MiB returned extent for demand misses. OS minimum ranges may be larger. A small seek can download up to 16 MiB.
- Read-ahead is per item: up to 8 planners, by item and content version, and the least recently used goes. It starts only when a miss continues the previous miss of the same item. It keeps one 16 MiB speculative fetch in flight, at most one chunk past the latest sequential miss, and pauses 30 ms before each chained request. Without that pause, `fileproviderd` held a waiting seek until speculation stopped. A seek cancels only its own item's speculation. A successful full handoff retires that item/version's pending speculation and cancels its running speculation; future misses after eviction can start a new run. After a reader stops, up to 16 MiB can still download. A fetch counts as speculative only if it covers the planned offset and length. A returned range never extends into bytes already delivered, and speculation skips them: rewriting them raced IINA's reads and made `fileproviderd` download the whole file. A miss in delivered bytes when no new bytes came for 10 s means macOS evicted them, so the planner starts again; before this, a file read again after Remove Downloads got 1 MiB fetches and no read-ahead (M8). A demand that overtakes a request the system hasn't delivered retires it. A 128 MiB window let a moving-boundary stress reader trigger a system materialization race and a full download in 5/5 trials; the one-chunk window avoided it in 11, which doesn't prove it gone. Items share the domain's pipeline depth of 2, so one file's read-ahead can delay another file's read. The sequential partial-read gate still fails.
- The first request in an outage waits for the mount's own timeout, about 30 s measured. After a call fails with a timeout-class errno, or a listing or transfer makes no progress for 15 s, the share is unresponsive: requests fail at once with `serverUnreachable`, and one probe runs every 5 s until the server answers. A session start whose bookmark resolution fails while the share is mounted is handled the same way, and the probe then starts the session. A blocked SMB kernel call can't be interrupted, and a read that runs when the share stops answering fails after 30–41 s and doesn't resume. After a 70 s outage, macOS unmounted the share 17 s after the NAS answered again, and the app mounted it again in 1.5 s (M11). After a 30 s outage, the app recovered by itself 11 s after it ended (M9). Downloaded files keep working; see the [offline results](results/2026-10-11-offline-reading.md), measured with the fixture build.
- The main app must stay running for misses and for folders never listed. When a worker starts a fetch, the app says so and then reports progress at most every 0.5 s. From that start, the extension ends its wait after 60 s with neither progress nor a reply (D2). Before it, a fetch that waits for one of the two workers that all locations share has no deadline: only the reply, a lost connection or cancellation ends it. With the app stopped by `SIGSTOP`, a fetch failed 60.0 s after its last progress (M6). After a crash, the extension starts the app again within about 70 ms, unless the app crashed less than 60 s after its launch. A read that runs during the crash fails, or finishes if the system tries again. After Quit or Force Quit, misses fail at once until the user opens the app (M11). Not verified at runtime: whether the system cancels a waiting fetch, as it can cancel one that stops making progress ([phase 2 §9](phase2-plan.md#9-milestones)).
- A staging URL is never changed after completion; macOS owns the handoff. App staging leases are released on completion, cancellation or connection invalidation. At launch, before any reader connects, the app deletes leftover stage files in `ReaderStaging`. Each extension process deletes the stage files in its temporary directory that were created before it started, and logs `temp_removed` and the stage files left. Runtime cancellation races, adversarial IPC requests and long-duration staging growth remain unverified.
- The M24 candidate routes permanent deletion behind `SourceReaderBridge.deletionEnabled`, which
  is false in the normal build. Settings lists its durable requests with per-item outcomes,
  Retry, Stop Deleting and safe Dismiss Notice actions. The candidate still needs app compilation
  and signed Finder/recovery checks in the VM. See the [integration checklist](m24-integration-checklist.md).
- General modify and delete remain denied. A completed new folder can receive its initial name once; the app checks its receipt and remote identity. Create and initial naming require an explicitly enabled location and a fresh scoped write grant. Existing locations stay read-only. A reimport `createItem` (`.mayAlreadyExist`) completes with the live row of the same name and kind, and with `nil` only for a file without contents that no row matches; anything else keeps the error. A matched file with contents is downloaded again from the NAS unless its size equals the row's and its modification date is less than 1 µs from the row's, as measured between `Date`s. A NAS change that keeps the size and mtime and changes only the ctime is not found on reimport, so the old disk copy stays as the current version. Not verified at runtime: it needs a system reimport.
- Per-request logs record full or partial mode, demand, sequential or speculative kind, Finder (`viewer`) and system flags, queue and transfer times. They don't instrument actual player first frame or system reader resumption.
- The measured VM Finder-launched opens waited for a full download. The physical-Mac run includes
  partial playback reads, but its exact opening routes were not recorded.
- Blocking I/O containment, scheduler fairness, robust authentication/reconnect, and direct-SMB comparison remain later steps in the feasibility work.

The mounted share, Personal Team signing and app-owned NAS access prerequisites are met in this VM. Full-download throughput exceeds 90% in both verified NAS cache states. Seek-first read-ahead keeps scripted seeks at 0.23–0.38 s but reaches only about 45% of native for 512 MiB sequential partial reads with the one-chunk window, below the 90% target. The measured VM Finder launch routes downloaded uncached files fully before an app opened them. Local cached-read parity, disconnected retention and shipping lifecycle also remain open. VM results must be compared against the VM's native SMB baseline, then repeated on the physical Mac before judging the original 190/280 MB/s expectations.


## New files and folders, M18

Creation, recovery and migration checks passed in the VM, including signed extension callbacks
through authenticated IPC. After an approved VM File Provider daemon restart, normal Finder file
and nested-folder uploads passed with matching hashes and native progress. Initial naming now
passes the [signed follow-up](results/2026-10-23-folder-naming-fix.md). File Keep Both also passes
the [signed follow-up](results/2026-10-25-keep-both.md). M18's VM create checks are complete;
physical-Mac writes and other file managers remain unverified.

The user approved installing M18 on 2026-10-27. The app and provider run from Applications with
the existing catalog ID and diagnostic counts retained; the location remains read-only. See the
[installation results](results/2026-10-25-keep-both.md#physical-mac-installation-2026-10-27).
See the [results](results/2026-10-23-create-items.md). In the development UI, a location's Access
section has one Read only toggle. It defaults off for a new location; a duplicate inherits
the original's mode. Writable setup selects the same share root and confirms the SMB-only
write requirements. The grant belongs to this location. Replacement, move, delete, packages and symbolic links remain unsupported. Editing and file renaming use the
protected transactions described below.

Finder's New Folder creates an untitled folder on the server, then sends a separate rename when
the user types a name. The app's restricted SMB client now creates and names that folder using
its retained server identity and creation time. A folder's initial name must precede child
creation; child requests first finish any already pending parent naming. Copying a folder that
already has its final name works, including its children. New-file uploads and reads stay native.
Finder's Keep Both needs rename capability to select an alternative name before creation.
Enabled locations advertise it. M20 also handles Rename for verified ordinary files in the
same folder; unverified files and existing folders still refuse it. Definite server
collisions return the existing item through Apple's collision-error factory. All 232 tests and
required checks passed, and the final signed VM app passed repeated file collisions with matching
bytes. Finder offered no Keep Both action for the tested folder collision. The fixture is
removed and sharing is restored. See the [results](results/2026-10-25-keep-both.md).

The app records the request before local staging, then saves immutable pending bytes before
exclusive remote creation. A replay can restage matching system input after a staging interruption.
The system admits one content upload and one metadata upload per domain at a time. Other devices can
see the new file during upload. It is not acknowledged until its remote identity and complete
content are verified. The verified editing base records metadata from the protected open file;
the mount's cached directory timestamps can still predate the completed upload. An interrupted
upload with an unacknowledged create is tried again only with another exclusive create;
an item at the name keeps it pending. In the single-client prototype, an acknowledged partial
file can resume after exact identity and complete prefix verification under exclusive SMB
sharing. Only missing bytes are appended; existing bytes are never overwritten. The
source cannot change while a write is pending. The location can be removed when its only pending
items never reached the server; macOS keeps them on this Mac. Settings lists each new item that
is not on the server yet, with the reason for its last failure since the app started, and offers
Stop Uploading when nothing reached the server. A failed creation reports `cannotSynchronize`,
so macOS stops sending it until Retry Pending Changes or a share recovery signals it again
([plan](pending-changes-plan.md)). Completed receipts deduplicate system replay and are removed with a
finished location. Pending records and content stay in private app storage; the extension sends authenticated create and initial-name requests.
See the accepted [phase 4 plan](phase4-plan.md).

Normal and repeated TextEdit Save pass in the signed VM app, including a concurrent-edit
conflict. The installed M19 build has a separate editing opt-in; M20 combines creation, editing
and supported renaming under the confirmed write mode. Filename-only renaming uses the
app-owned protected transaction. Rename intents retain every affected catalog ID and block lifecycle
changes and reconciliation until publication is resolved. Directory enumeration verifies the
actual stored spelling, including case-only changes.
Interrupted local staging remains visible. New uploads establish a verified editing base, and
changed strong revisions advance even when native timestamps are unchanged.
Stage, backup and published-file verification uses the server's close-response timestamps,
then reopens and checks identity, content and metadata before accepting that version. A missing
close response or a mismatch retains recovery data. This handles servers that finalize write
timestamps on close without accepting unexplained timestamp changes during cleanup.
Private save stages upload through their existing SMB handle with exclusive sharing protection.
Writes use at most 64 KiB per request; short acknowledgements advance only by the confirmed count.
A lost reply leaves the save pending. This avoids native pathname opens after server file-ID reuse.
Signed VM checks pass for repeated stage uploads, sharing exclusion and interruption. Native
confirmation after publication can still fail until Retry; the Mac update remains withheld.
Pending edits retain bounded original attributes separately, because macOS can change metadata
when a sandboxed app copies the file. Export restores user attributes while macOS controls the
new local file's access and quarantine attributes.
TextEdit's encoding attribute, last-used date and explicit modification date are not uploaded.
Metadata-only retries return those fields as unsupported through File Provider's documented
contract, preserving their local values without claiming remote synchronization.
The verified M19 build is installed on the physical Mac. Background launch checks retain the
location and catalog counts; physical-Mac saves and downloaded-byte comparisons remain unverified.
See the [installation results](results/2026-10-28-same-object-save.md#physical-mac-installation-2026-10-28).
M19's replacement design failed its
concurrent metadata-preservation gate. The user reaffirmed Mac-only operation; a
[revised save design](phase4-plan.md#revised-mac-only-save-proposal) was approved on 2026-10-28
and passed its [CLI protocol gate](results/2026-10-28-same-object-save.md) on the disposable
Samba fixture. Signed interruption checks retain complete versions, and the normal export panel
recovers pending content. Item IDs, keep requests and an independent download survive. Partial
work stays unresolved, and fixture connection delays can defer retries. The fixture, temporary
dependencies and task windows are cleaned up. See the same results log for the exact coverage
and limits. No server component is required.

## Name spelling over SMB

The tested macOS mount and the catalog show accented names decomposed (NFD), while the native
client sends them composed (NFC). The app's SMB client does the same: one C function
composes every path before libsmb2 sends it. Like the macOS client, it leaves U+2000–2FFF,
U+F900–FAFF and U+2F800–2FAFF unchanged, because NFC would turn characters such as U+2126 OHM
SIGN and the CJK compatibility ideographs into other characters. The app compares server names
with catalog names in composed form, so saves, renames, moves and deletions find accented items
on servers that compare names byte for byte. A rename or move that changes only the
normalization sends no request. On the tested byte-exact Samba share, a name stored as NFD
cannot be opened through the macOS mount or this adapter. Other SMB clients were not tested.
Its downloads fail as a missing file. Its saves stay unresolved without a conflict
copy, and its renames, moves and deletions refuse. If the catalog doesn't list such a name, a
new file or folder can still be created next to it, as through Finder's own mount. Unit tests
cover these comparisons. Signed Samba/ext4 checks verify selected accented uploads and saves,
and 20 repeated saves with stage file-ID reuse. November 3 probes reproduce stale native names
after direct rename and quarantine writes recreating a deleted stage after file-ID reuse.
The separate single-client branch now uses direct SMB for remote listings, metadata, reads and
uploads, with fresh catalog state. Required VM checks, 20 signed saves, Unicode content, upload
acknowledgment and a fresh read-only 2 GiB download pass. Conflict and interrupted-save recovery
preserve complete contents. Retired saves no longer block unrelated listings and mutations.
Interrupted new uploads retain a complete local copy beside the partial server item. Automatic
continuation of a proven partial upload is implemented; signed VM validation is pending.
Preliminary full-read callback rates are comparable with native staging in the
VM, with cache residency unverified. End-to-end handoff, writable and partial-read benchmarks,
Finder's read-only copy warning and native-mount export interactions remain open. The physical
Mac still runs the earlier transport. See the
[runtime results and accepted staging change](results/2026-11-02-samba-names-and-uploads.md).
