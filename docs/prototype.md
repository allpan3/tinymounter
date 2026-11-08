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

## Initial implementation and checks

- A dependency-free Swift package with `transfer-bench` and a reusable transfer engine.
- Source files opened read-only, using bounded `pread` calls; optional local staging uses exclusive creation and `pwrite` at the source offsets.
- Full/range reads, runtime-aligned ranges, empty files, metadata fingerprint checks, progress/cancellation, and cleanup on handled failures.
- JSONL reporting of byte range, filesystem, open/transfer/first-read time, sustained rate after the first chunk, CPU, process-lifetime peak RSS, cache label, and optional post-timing SHA-256 verification.
- A SwiftUI app with a Settings window and a menu bar item, and a replicated File Provider extension (section 2). The app signs in to the server with its saved password, adds and removes locations, and owns all share I/O and every catalog write: it lists folders into each location's SQLite catalog and stages file bytes with the transfer engine. The extension reads the catalog read-only to page folders, fetches full and partial ranges by item ID from the app through a restricted File Provider service, runs read-ahead per item, and supports new ordinary files/folders only in explicitly enabled locations. Initial folder naming is implemented through an app-owned SMB client; general modify/delete remain denied. Signed Finder checks pass, including file Keep Both.
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

Build and run the `TinyMounter` scheme with normal development signing. The app has the
phase 2 interface of [ui-design.md](ui-design.md): a Settings window (⌘,) with the locations in
its sidebar, and a menu bar item with Pause Downloads. With no locations, or with the menu bar
item hidden, the window opens at launch. Closing it keeps the app running; the Dock icon or the
menu bar item opens it again. Nothing migrates from phase 1: remove
the fixture domains with the phase 1 build before the first run (D3). A domain without a catalog
fails every request with `serverUnreachable` and never reports an item as deleted.

**Servers, sign-in and shares.** Shares are added only through a location. Add Server… in the
location's Server menu opens a sign-in sheet for the address, account and password. The app
signs in with NTLMSSP over SMB 3, with signing and encryption required; there is no guest login
and no macOS dialog. A refused password shows the refusal and saves nothing. An accepted one
saves the server in `Application Support/tinymounter/Settings.json` in the app container, mode
0600, and the password in a generic-password item in the login keychain: service
`dev.tinymounter.smb`, account `name@host`. Add Share… lists the server's disk shares over that
sign-in. Folder Select… opens a folder browser in the app that lists folders over the connection.
No mount and no panel are used.

Read only is a plain setting per location; the account's permissions on the server apply. A
share stays saved after its last location is removed. Servers lists the saved shares by server,
with their connection state and the locations that use each one. Forget deletes an unused share;
Forget on the password row deletes the server, its shares and its Keychain item. When the server
refuses the saved password, every location of that server shows "Sign in again." and Sign In
Again…, and the app makes no further logon attempt until the user enters a new password.

Server Volume is a separate whole-share location mode. It asks macOS to mount the share visibly
and opens it in Finder, with no File Provider catalog, download cache or Read only control. The
app signs in with the server's saved name and password, then passes them to NetFS; macOS shows no
dialog. One sign-in serves the server's File Provider locations and volumes, so a refused password
shows Sign In Again… on both. The status is mounted or not mounted. Native volumes reconnect at
launch, wake and network changes, and respect an intentional eject for the current app session.
Remove disconnects before forgetting the volume and retains the entry if the volume is busy. A
share cannot have both modes, even through different saved accounts; remove its existing locations
before switching. Server aliases are not resolved to detect that two differently named servers
might be the same machine. Show in Finder opens the share's `smb://` address, which Finder
resolves to the mounted volume
([results](results/2026-11-08-connection-layer.md#server-volume-sign-in)).

Up to 0.1.2, shares were mounted by macOS and granted through `NSOpenPanel`. That flow was
verified in [M3](results/2026-10-12-share-grant.md) and
[M12](results/2026-10-18-connect-in-app.md). The
[connection-management follow-up](results/2026-10-18-connection-management.md) passed signed VM
checks, including migration of an existing location, busy ejects, removal and re-add, and
reuse of a visible Finder mount. The 0.2.0 connection layer is verified in the
[connection-layer results](results/2026-11-08-connection-layer.md).

**File Provider approval.** If macOS disables the File Provider, the location shows
"File Provider is off." and Open System Settings…. In Extensions, open TinyMounter
and turn on File Provider. The location's status updates when the system reports the change;
the user does not need to remove the location or restart the app. The
[approval checks](results/2026-10-18-file-provider-approval.md) verified recovery on the physical
Mac and the new action in the signed VM build. The UI update is now installed on the physical
Mac. After the requested reset, the user resumed Finder browsing.

Each operation opens its own SMB session with the saved password: each listing, transfer and
change. `ConnectionHealth` tracks each share from the results of those calls. A refused password
enters Sign in again. A failed connection, a request that times out after 10 s, or a call with no
progress for 60 s makes the share unresponsive; requests then fail at once, and a probe opens a
session after 5 s, backing off to 60 s. Wake and a returning network path probe at once.
**Folder** is relative to the share; empty means the full share.

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

Guest SMB connections were accepted from 2026-10-19
([results](results/2026-10-19-guest-connections.md)) and are removed in 0.2.0: every server needs
an account and a password.

Each new location makes macOS ask whether a test shell may access files it manages; allow it only
for that location.

Only the main app connects to the share; the extension reads the catalog and staged files. Both components retain the sandbox; no Full Disk Access, TCC reset, or sandbox exception is needed for this tested route.

The extension publishes a restricted File Provider service. The app connects via the domain manager and exports a per-domain reader on the resulting XPC connection, only for domains whose catalog it opened. Messages are JSON of at most 8192 bytes, including deletion event archives of at most 4096 bytes. Reads carry IDs, versions and counts. A create request also carries a validated leaf name, kind and opaque local inbox ID; source values are never logged. A list request carries a request ID and a folder's item ID; its reply, sent after the commit, carries the folder's listing generation and its entry, change and skip counts. A fetch carries a request ID, an item ID, the content version and a byte range; its receipt carries a staging leaf name and metrics. A keep request carries a request ID, at most 100 file IDs and the requested value; its reply, sent after the commit, carries the number of rows that changed. When a worker starts a fetch's transfer, the app sends a started message with the request ID; then it sends the bytes done at most every 0.5 s. Both sides check peer signing identity. At most two app transfers run concurrently for all domains, with at most four outstanding fetches per domain connection. A location queues at most 16 folders for listing, and a request for a folder that is already queued joins it. The app's own listings for Add Location and relisting run one at a time and are never refused. The app writes an exclusive staging file in the shared App Group, and the extension moves it into the provider's temporary directory before handing it to macOS. The move must remain on the same volume. No bulk bytes pass over XPC.

The app retries lost connections with bounded backoff. A new per-domain extension reader service gives fetches up to 5 s from its creation for the first connection, checking cancellation every 100 ms. After attachment, losing the reader still fails at once. The deadline is shared, so subsequent requests cannot restart the wait. Never-listed folder enumeration retains its existing connection requirement. The 60 s transfer stall deadline still starts at the app’s `started` message. Closing the window is different from quitting the process; the prototype must remain running to supply missing content and to list folders that were never listed.

Both targets include local-network and Network Volumes usage descriptions and the network-client entitlement. macOS asks once per app signature for Local Network access, and until the user allows it, a connect fails with `EHOSTUNREACH`. The app then waits up to 30 s while Network framework reports `localNetworkDenied`, and connects again as soon as access is allowed, so no relaunch is needed. If access stays off, the app says that it cannot reach the local network and how to turn access on; probes recover the share once the user does.

The unsigned compile check, which does not install or run the extension, is:

```sh
xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounter -configuration Release -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

`Tools/generate-project.py` reproducibly creates the checked-in two-target project using only Python's standard library. If changing target/source structure, update the generator too; regenerating replaces manual project/scheme edits. Signing team and identifier settings can live in the shared xcconfig.

## 3. First runtime validation

1. Remove the phase 1 fixture domains first (D3). Then build, sign and launch the app. Click
   **Add Server…** in the Server menu and type the address. Select an existing connection or
   connect another share, then click Open in the panel.
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

Version 0.1.0 builds as `TinyMounter.app`; the target and scheme are `TinyMounter`.
The rename keeps the bundle identifiers, App Group and sandbox entitlements. When replacing an
earlier installation, unregister and remove `TinyMounterPrototype.app` after verifying the new app.

On the physical Mac, keep only `/Applications/TinyMounter.app` outside active signing
or installation work. Unregister and remove temporary signing/transfer bundles after packaging
or transfer, and remove the temporary rollback copy after verifying an installation. Do not
retain app backups. Keep test logs and other evidence. Unregistering a loose `.app` bundle alone
does not prevent macOS from discovering it again in Spotlight.

**Update.** Quit TinyMounter, build the new version, and open it. After Quit, the app stays
stopped: only a crash makes the extension start it again. Keep the same team and bundle
identifier, because the settings and catalogs are in containers named after them. While the
formats stay the same, the locations, their downloads and their Keep Downloaded requests stay.
Until release, no build migrates settings, catalogs or pending changes from an earlier build.
After a format change, finish or export pending changes with the old build, remove the
locations, and add them again with the new build. If that isn't possible, the new build shows
Start Fresh… in General when it can't read the settings. It removes every location with
macOS's option to keep changes that did not upload, opens that folder in Finder, and moves the
earlier settings, outboxes and catalogs aside in the containers. It also deletes every saved
server password: the generic-password items of the `dev.tinymounter.<protocol>` services. A
0.1.2 `Settings.json` is refused this way.

Saves use ordinary SMB writes in the [simplification branch](smb-simplification.md).
File Provider owns pending local contents until the upload callback succeeds. TinyMounter
sets the final size, flushes and closes the remote file before completing the callback; errors
remain pending in macOS. Competing edits can be overwritten and failed writes can leave partial
remote contents. There are no custom remote backups, recovery names or conflict copies.
Signed VM saves, competing-write overwrite, shorter/empty writes and interrupted-upload retry
across app/provider restart pass; see the [results](results/2026-11-05-smb-simplification.md). Finish or export older pending changes with the
older build before using Start Fresh; this branch does not migrate old recovery transactions.

The catalog records departures from former parents for known moves and preserves content
versions when metadata indicates unchanged data. Reads check file metadata and transfer each
requested range once. They do not establish edit receipts or retain content-hash proofs.
The immutable enumeration key keeps folder-page cursors valid when names change. Catalogs
carry no schema version; incompatible prototype state requires Start Fresh.

**Remove.** In this order:

1. In Settings, click **Remove Location…** for each location. This removes it from Finder with its
   downloaded copies. The files on the share don't change.
2. In Servers, click **Forget** next to each server's password. This deletes the server, its
   shares and its Keychain item.
3. In General, turn off **Open at login**.
4. Click **Quit TinyMounter** in the menu bar item.
5. Delete `TinyMounter.app`.
6. Optionally, delete its data: `~/Library/Containers/<bundle ID>` and
   `~/Library/Containers/<bundle ID>.provider`, and
   `~/Library/Group Containers/<team>.<bundle ID>`. They hold the settings and the
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

- One saved password per server, and locations that are folders on its shares. File Provider locations use no mount, so other apps and file managers don't see the share. File Provider locations have no Disconnect. New locations default to writable setup with a safety confirmation. Existing read-only locations stay read-only. Supported writes are new files/folders, ordinary content saves, file/folder rename and move, permanent deletion and Finder file Replace.
- Keep Downloaded is a request for a file or folder, not proof of a download (phase 2 decision 3). M14 adds recursive folder requests, verified in the signed VM app ([results](results/2026-10-19-folder-keeps.md)). The system eagerly enumerates kept folders, and newly listed descendants inherit retention. Allow Removal cancels a request while preserving independent child requests. A folder is Available offline only if every descendant folder has an unskipped complete listing and is materialized, and every file passes the local-copy check. The system downloads an independently kept file only when its parent folder is materialized: a kept file in a folder that the system never enumerated waits until the folder is enumerated. Evicting a kept file fails; evicting its folder evicts it, and the system downloads it again at once. The location pane shows Requested, Update in progress or Available offline. It signals the working set and waits for macOS to apply provider changes, then reads fresh local metadata and rechecks catalog versions. Available offline requires current content with matching catalog size and modification date; this covers the source version last observed by the app, not live NAS freshness. The wait covers the location. Before waiting, the app rechecks previously synchronized content versions against fresh local metadata and materialization, so unrelated downloads do not reset their status. New or changed versions still need the wait; folder status uses current membership and listing completeness. Provider disablement or replacement clears remembered verification ([status-refresh results](results/2026-10-19-keep-status-refresh.md)). Signed VM checks passed, including source edits that preserved size/date ([results](results/2026-10-19-offline-versions.md)). Remove Location can save them, and a later location on the same share takes the ones inside its folder; for independently kept files outside a folder request, the app asks whether to download them now if their parent folders are not materialized (M7).
- Pause Downloads sets `paused` in every catalog. Kept files then report `.downloadLazily`, kept folders use lazy namespace policy, and read-ahead stops. The extension cancels its running system and speculative fetches and refuses those that start while paused. A background fetch that is still waiting for the first reader connection is cancelled when the reader connects. Files that apps open, and Finder's Download Now, still download. Resume and each app launch clear Pause. Changes run one at a time, in order. A failed change shows a message, and while a catalog may still be paused, the menu bar item offers Resume Downloads. While paused, the user can also remove a kept file's download; Resume downloads it again. Whether kept files stay on disk while paused when the system needs the space is untested.
- NAS changes in listed materialized and kept folders are discovered while the app runs. Since 0.2.0, each share has one `CHANGE_NOTIFY` connection with at most 64 non-tree watches, one per discovery folder, plus periodic reconciliation, due 60 s after a successful listing. In the VM, a change three folders deep reached the catalog 1.1–1.5 s after another client made it; a missing name still waits for the 15 s confirmation below. One automatic listing runs at a time, with a one-second gap and failure backoff, so this is not a fixed latency guarantee. Unvisited unkept trees are not scanned. Launch, wake, recovery and access checks also refresh listings. A downloaded copy can stay stale between refreshes. A NAS rename is a delete plus a create, and its keep request does not follow. Signed isolated VM checks passed. The signed M15 update is installed and running on the physical Mac with the existing location retained; the user confirmed live changes work there ([results](results/2026-10-19-nas-change-discovery.md)).
- Keep Downloaded transfers publish progress for Finder's native circle. File progress reports transferred bytes; kept ancestor folders show indeterminate progress while descendant transfers run. The circle starts with the transfer, not during earlier enumeration, and clears when it ends or fails. It is a read-only indicator; Pause Downloads remains the control for background transfers. Settings remains the check for Available offline. The signed VM comparison passed; the signed update is installed on the physical Mac ([results](results/2026-10-19-keep-status-refresh.md)).
- Only a complete listing changes the catalog, after the server confirmed that each missing name is gone. A listing that would remove every child of a folder, remove a kept file, or change a kind is held; a listing that starts at least 15 s later applies what it finds (D5). Symlinks, special files, invalid names and name-key collisions are not shown; the listing log counts them as skipped.
- Content versions are `f1:<size>:<mtime_ns>:<ctime_ns>` (D1), so a remount does not download copies again. Each transfer still checks the full snapshot, device and inode included, on its open descriptor. A change that keeps size and timestamps can't be detected.
- Two concurrent extension fetches per domain, two app transfers for all domains, 1 MiB POSIX buffers, and a preferred 16 MiB returned extent for demand misses. OS minimum ranges may be larger. A small seek can download up to 16 MiB.
- Read-ahead is per item: up to 8 planners, by item and content version, and the least recently used goes. It starts only when a miss continues the previous miss of the same item. It keeps one 16 MiB speculative fetch in flight, at most one chunk past the latest sequential miss, and pauses 30 ms before each chained request. Without that pause, `fileproviderd` held a waiting seek until speculation stopped. A seek cancels only its own item's speculation. A successful full handoff retires that item/version's pending speculation and cancels its running speculation; future misses after eviction can start a new run. After a reader stops, up to 16 MiB can still download. A fetch counts as speculative only if it covers the planned offset and length. A returned range never extends into bytes already delivered, and speculation skips them: rewriting them raced IINA's reads and made `fileproviderd` download the whole file. A miss in delivered bytes when no new bytes came for 10 s means macOS evicted them, so the planner starts again; before this, a file read again after Remove Downloads got 1 MiB fetches and no read-ahead (M8). A demand that overtakes a request the system hasn't delivered retires it. A 128 MiB window let a moving-boundary stress reader trigger a system materialization race and a full download in 5/5 trials; the one-chunk window avoided it in 11, which doesn't prove it gone. Items share the domain's pipeline depth of 2, so one file's read-ahead can delay another file's read. The sequential partial-read gate still fails.
- Each SMB request times out after 10 s. After a connection fails, a request times out, or a call makes no progress for 60 s, the share is unresponsive: requests fail at once with `serverUnreachable`, and probes open a session after 5 s, backing off to 60 s, until the server answers. With the fixture's SMB service stopped, the share was unresponsive after 6 s, and it was connected 5 s after the restart, at the first probe; the pending upload then finished ([results](results/2026-11-08-connection-layer.md)). Downloaded files keep working; see the [offline results](results/2026-10-11-offline-reading.md), measured with the fixture build.
- The main app must stay running for misses and for folders never listed. When a worker starts a fetch, the app says so and then reports progress at most every 0.5 s. From that start, the extension ends its wait after 60 s with neither progress nor a reply (D2). Before it, a fetch that waits for one of the two workers that all locations share has no deadline: only the reply, a lost connection or cancellation ends it. With the app stopped by `SIGSTOP`, a fetch failed 60.0 s after its last progress (M6). After a crash, the extension starts the app again within about 70 ms, unless the app crashed less than 60 s after its launch. A read that runs during the crash fails, or finishes if the system tries again. After Quit or Force Quit, misses fail at once until the user opens the app (M11). Not verified at runtime: whether the system cancels a waiting fetch, as it can cancel one that stops making progress ([phase 2 §9](phase2-plan.md#9-milestones)).
- A staging URL is never changed after completion; macOS owns the handoff. App staging leases are released on completion, cancellation or connection invalidation. At launch, before any reader connects, the app deletes leftover stage files in `ReaderStaging`. Each extension process deletes the stage files in its temporary directory that were created before it started, and logs `temp_removed` and the stage files left. Runtime cancellation races, adversarial IPC requests and long-duration staging growth remain unverified.
- Ordinary Finder deletion and file Replace are enabled after the November 6 signed VM checks.
  Finder warns that deletion is immediate and cannot be undone. Replace may delete the old file
  before the new upload finishes. The separate confirmed **Delete Permanently…** command remains
  available. Settings lists durable deletion requests with per-item outcomes,
  Retry, Stop Deleting and safe Dismiss Notice actions. Signed VM checks pass for refusal
  restoration, the permanent warning, Cancel, regular files and nested folders. Parent identity
  checkpoints survive restart; lost checkpoints retain uncertainty and replacements survive
  replay. Stop Deleting exposed an unsafe replay after Finder refreshed item metadata.
  The repair binds replay to Apple's event domain version and requires fresh catalogs and
  deletion records. Signed Stop restoration, interruption before notification and replay after
  dismissal/restart now pass. Retry continues an interrupted request admitted by the command.
  See the [command results](results/2026-11-03-permanent-command.md) and
  [adoption record](results/2026-11-04-adoption.md).
- Unsupported metadata-only modifications remain local. A completed new folder can receive its initial name once; the app checks its receipt and remote identity. Create and initial naming require a location with Read only turned off. Existing locations stay read-only. A reimport `createItem` (`.mayAlreadyExist`) completes with the live row of the same name and kind, and with `nil` only for a file without contents that no row matches; anything else keeps the error. A matched file with contents is downloaded again from the NAS unless its size equals the row's and its modification date is less than 1 µs from the row's, as measured between `Date`s. A NAS change that keeps the size and mtime and changes only the ctime is not found on reimport, so the old disk copy stays as the current version. Not verified at runtime: it needs a system reimport.
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
the original's mode. Writable setup reuses the share's retained permission. Earlier settings without
that permission ask once for the share root and retain it for subsequent locations. Ordinary file/folder organization and the confirmed
Delete Permanently… command are enabled, along with ordinary Finder deletion and file Replace.
Ordinary folder Replace passes the [November 6 checks](results/2026-11-06-folder-replace.md),
including automatic retry after a directory-watcher timeout. Packages, Finder Merge and symbolic
links remain outside the verified capability set.

Finder's New Folder creates an untitled folder on the server, then sends a separate rename when
the user types a name. The app's restricted SMB client now creates and names that folder using
its retained server identity and creation time. A folder's initial name must precede child
creation; child requests first finish any already pending parent naming. Copying a folder that
already has its final name works, including its children. New-file uploads and reads use the direct SMB client.
Finder's Keep Both needs rename capability to select an alternative name before creation.
Enabled locations advertise it. The later organization milestones handle ordinary file and folder rename/move with metadata-based admission. Definite server
collisions return the existing item through Apple's collision-error factory. All 232 tests and
required checks passed, and the final signed VM app passed repeated file collisions with matching
bytes. Finder offered no Keep Both action for the tested folder collision. The fixture is
removed and sharing is restored. See the [results](results/2026-10-25-keep-both.md).

New-file creation records the request before local staging and retains a complete local payload.
Other clients may see partial new contents during upload. Acknowledgment requires the expected
identity, final size, flush and close. An unacknowledged create retries only with exclusive
creation; an existing name keeps the outcome unresolved. An acknowledged partial file restarts
its complete upload after checking the recorded identity. Local payload integrity checks remain;
there is no remote full-file readback. Settings lists pending new items and offers Stop Uploading
only when nothing reached the server. macOS keeps those local items on removal. See the
[pending-change plan](pending-changes-plan.md).

Settings also lists changes held by macOS, including refused renames with no app transaction.
Show in Finder selects the local item. A stale-base refusal shows the last known server path;
restore that name and folder in Finder to undo it, then make a fresh request if needed.
Retry never overrides the stale base. An older generic error receives the specific reason on
Retry. The system list overlaps the app's transaction count and can be incomplete; Settings
reports that limit. See [pending-change recovery](pending-changes-plan.md#retry-and-status).

Existing-file saves use the ordinary overwrite path described in section 5. The signed VM
checks cover repeated saves, competing server edits, shorter/empty files, offline retention and
automatic retry after a mid-write interruption and app/provider restart. Combined filename/parent and content callbacks stage the input, rename or move the same item,
then overwrite it; a failed callback retains pending local contents. No custom recovery
copies or edit bases remain. Reads and writes use at most 1 MiB per request, capped by server
limits and available credits; short replies advance only by the confirmed byte count.

Rename intents retain affected catalog IDs and settle each view after the server operation.
Directory enumeration verifies stored spelling, including case-only changes. Metadata indicates
whether contents changed; it is not a full-content proof. TextEdit's encoding attribute, last-used
date and explicit modification date are not uploaded. Metadata-only retries return unsupported
fields through File Provider's documented contract without claiming remote synchronization.

## Name spelling over SMB

The tested macOS mount and the catalog show accented names decomposed (NFD), while the native
client sends them composed (NFC). The app's SMB client does the same: one C function
composes every path before libsmb2 sends it. Like the macOS client, it leaves U+2000–2FFF,
U+F900–FAFF and U+2F800–2FAFF unchanged, because NFC would turn characters such as U+2126 OHM
SIGN and the CJK compatibility ideographs into other characters. The app compares server names
with catalog names in composed form, so saves, renames, moves and deletions find accented items
on servers that compare names byte for byte. A rename or move that changes only the
normalization sends no request. On the tested byte-exact Samba share, a name stored as NFD
cannot be opened through the macOS mount or this adapter. An independent libsmb2 client can
rename an NFC name to NFD without normalization, as the November 3 folder-recovery probe verifies.
Its downloads fail as a missing file. Its saves stay unresolved without a conflict
copy, and its renames, moves and deletions refuse. If the catalog doesn't list such a name, a
new file or folder can still be created next to it, as through Finder's own mount. Unit tests
cover these comparisons. Folder moves compare literal server names with the composed path
the client sends. A complete protected listing can therefore retire a binding whose server
spelling changed to NFD, while still accepting NFD catalog names for NFC server names.
The earlier Unicode and file-ID-reuse probes led to the adopted direct SMB transport. Their
historical save/recovery behavior is recorded in the
[transport investigation](results/2026-11-02-samba-names-and-uploads.md). Current save semantics,
validation and read-performance limits are in the
[simplification results](results/2026-11-05-smb-simplification.md). The physical Mac still has the
pre-simplification build; this branch has only been installed in the VM.

Read-only regular files advertise the File Provider write capability but retain read-only
POSIX permissions, read-only parent folders and both provider/app mutation guards. On the
tested macOS build, omitting that capability makes exported copies immutable and breaks
Finder Keep Both. The signed final build copies and completes Keep Both successfully. The
capability trial refused a TextEdit save back to the read-only location. Rename capability remains absent.
