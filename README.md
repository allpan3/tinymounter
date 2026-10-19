# tinymounter

A macOS app that brings a network disk, such as a NAS, into Apple's file system: browse it from Finder or another file manager such as QSpace, download on demand, and keep selected files available offline. Finder is the first file manager and SMB the first protocol it will support. A later mode will mount server volumes, the ordinary macOS SMB mounts, automatically.

Status, 2026-10-11: verified NAS-cold full downloads reached **183.3 MB/s versus 192.7 MB/s native SMB (95.1%)**; with the file in NAS RAM, **229.0 versus 247.2 MB/s (92.6%)**. Each condition has five matched pairs, server cache/disk-read evidence, and representative complete-file checksum verification. Fully downloaded local reads also pass, though an unexplained speed gap to a local APFS control remains. See [verified cache results](docs/results/2026-10-11-cache-states.md), [full-download attribution](docs/results/2026-10-11-full-download.md), and [range-delay diagnosis](docs/results/2026-10-11-provider-delay.md).

Players and read-ahead, 2026-10-11: in the measured VM configurations, Finder double-click, Open With and Cmd-O downloaded an uncached video fully before the player started, because Finder made a coordinated whole-file read. VLC's and IINA's own File > Open stream; QuickTime Player always downloads the whole file. Bounded read-ahead now favours seeks, as the user asked: seeks during streaming took **0.23–0.27 s** in all 9 trials, and long sequential partial reads run at **77–93 MB/s (about 30–37% of native)**, fetching about 1.03× the bytes read. A throughput-first setting reached 148.8 versus 249.4 MB/s (59.7%) but let seeks wait up to 1.4 s. Without read-ahead it was 9.6%. See [player and read-ahead results](docs/results/2026-10-11-player-readahead.md). These are VM results: first-frame and seek-resume times and physical-Mac speed remain unverified.

Offline reading, 2026-10-11: a file kept downloaded stayed readable, with a matching checksum, while the NAS was unreachable, with the app quit or running. Files that weren't downloaded failed with a clear error rather than bad data, and reads recovered on their own when the NAS returned. See [offline results](docs/results/2026-10-11-offline-reading.md). It also survived restarting the app, the extension and macOS's File Provider daemon with the file cache flushed; a full restart hasn't been tested.

Interface, 2026-10-11: after three review rounds, the user accepted the [interface design](docs/ui-design.md) for prototyping and will evaluate it on the prototype. M7 builds it; see the [interactive mockup](docs/ui-mockup.html). It uses Apple's terms (File Provider, server volume), a Connection Mode setting, and Duplicate in the sidebar to add locations. Its text follows ASD-STE100. Proposal for review: [synchronization between File Provider locations and server volumes](docs/synchronization.md).

Phase 2, 2026-10-15: M1–M3 are complete, and the signed M4/M5 app has [runtime evidence](docs/results/2026-10-14-catalog-browsing-reads.md) for catalog browsing, checksummed reads, playback, restarts and outages. The [runtime follow-up](docs/results/2026-10-15-runtime-followup.md) fixes the first-fetch connection race after an extension crash (3/3 complete reads matched native hashes) and stops obsolete read-ahead after a full handoff. The [read-ahead window comparison](docs/results/2026-10-15-read-ahead-window.md) adopted a one-chunk (16 MiB) window: a moving-boundary stress reader that failed with full downloads in 5/5 trials at 128 MiB passed 0/11 at 16 MiB, IINA played and seeked the same in 3/3 trials with less fetched data it never read (85 versus 287 MB), and 512 MiB sequential reads rose from 76.7 to 105.9 MB/s (45.2% of native). These are VM trials with fresh replicas and a probably warm NAS; they don't prove the system race is gone. Finder still retains a failed folder’s error. All 127 unit tests and required builds/checks pass. Folder eviction, VLC seeks and physical-Mac playback remain unverified. See the [phase 2 plan](docs/phase2-plan.md) for scope and open decisions.

Keep Downloaded and Pause (M6), 2026-10-16: Finder's Keep Downloaded and Allow Removal now record a request through the app, and a temporary Pause Downloads button stops Keep Downloaded downloads and read-ahead, while files that the user opens and Finder's Download Now still download. In the signed VM app, all 6 completed eager downloads of kept files were system requests, Pause cancelled a running 2.74 GB download at once, kept files stayed on disk while paused, and Resume and a relaunch downloaded the files kept while paused. Every downloaded file matched native SMB by SHA-256. A kept file in a folder that the system never enumerated doesn't download until the folder is listed, which affects M7's saved keep lists. The D2 deadline is now verified: with the app stopped, a fetch failed 60.0 s after its last progress. All 129 unit tests and the required builds and checks pass. Disk pressure while paused, several locations and the physical Mac remain unverified. See the [M6 results](docs/results/2026-10-16-keep-pause.md).

Settings window and menu bar (M7), 2026-10-16: the phase 2 interface replaces the test window. Locations are added, duplicated, renamed, changed with Apply and removed from a Settings window; a menu bar item shows each location's state and download percentage, with Pause Downloads and a Quit warning; and a notification posts once per share per outage. Remove Location can save the Keep Downloaded list, and a later location on the same share takes it back; for kept files in folders that the system never listed, the app asks whether to download them now, and Download Now made the system fetch the file 47 to 51 s later. A rename renamed the CloudStorage folder at once. Two defects found in the VM run are fixed: an eject posted two notifications, and the Quit warning opened behind other windows. All 134 unit tests and the required builds and checks pass. An unresponsive share and the slow-unmount case remain untested. See the [M7 results](docs/results/2026-10-16-settings-window.md).

Storage pane and folder completion (M8), 2026-10-18: the Storage pane shows each location's downloaded space and the total, and Remove Downloads evicts the downloaded files that the user doesn't keep. In the signed VM app, the pane's totals matched the sizes of the downloaded files on disk, a kept file stayed downloaded in three runs, and a file held open stayed, with an alert. A partly downloaded file isn't in the materialized set, so the pane leaves it out and Remove Downloads leaves it on disk. The Folder field suggests subfolders from one listing of the typed folder, in about 9 ms. The run found and fixed a read-ahead defect: a file read again after an eviction downloaded at about 1.6 MB/s instead of in 3 s. All 140 unit tests and the required builds and checks pass. Eviction under disk pressure and several locations remain untested. See the [M8 results](docs/results/2026-10-18-storage-pane.md).

Exit validation (M9), 2026-10-18: phase 2's exit criteria 1 to 6 hold in the signed VM app. Finder browsing matched the share 3 levels deep, every read in 20 soak cycles matched the share by SHA-256, app memory grew 0.5%, IINA and VLC played with partial downloads, and no mount, stage file or tombstone leaked, also after the app and the extension were killed. A share that stopped answering for 30 s recovered by itself; after 70 s, macOS unmounted it, and the user had to connect again in Finder. After an app crash, files that aren't downloaded fail until the user opens the app again. In M10's VM part, an update kept the locations and their downloads, and the next launch finished a Remove Location that a crash interrupted. Deleting the app without removing its locations leaves them in Finder. M10's run on the physical Mac remains. See the [M9 results](docs/results/2026-10-18-exit-validation.md) and how to [install, update and remove](docs/prototype.md#5-install-update-and-remove) the app.

Reconnection and restart after a crash (M11), 2026-10-18: phase 3 starts with an app that comes back by itself. When macOS drops the share, the app asks macOS to mount it again with the password saved in the Keychain, but not after an eject; after a crash, the extension starts the app again, but not after Quit or Force Quit. In the signed VM app, the share came back 1.3–1.5 s after a forced unmount and after macOS's unmount at the end of a 70 s outage, and an eject stayed for over 4 min. After SIGSEGV, SIGTRAP, SIGILL and SIGABRT, the app ran again within 67 ms and new reads matched the share; a second crash within 60 s of a launch didn't restart it. The run found and fixed two defects: a Swift trap hung a thread instead of ending the app, and Launch Services refused 2 of 9 restarts with a Finder alert. All 150 unit tests and the required builds and checks pass. Sleep and wake, a network change and the physical Mac remain untested. See the [M11 results](docs/results/2026-10-18-reconnect-restart.md) and the [phase 3 plan](docs/phase3-plan.md).

Connect in the app (M12), 2026-10-18: the user now types the share's address in tinymounter instead of connecting in Finder. macOS shows its own login dialog and share list, so tinymounter never sees the password, and the app mounts the share hidden, so Finder's sidebar shows only the tinymounter location. In the signed VM app, the share mounted in 1.26 s with the Keychain password, a read through the location matched the share, and a mount again after a forced unmount stayed hidden. Servers has new Connect and Disconnect buttons, and removing a server unmounts its hidden share. All 152 unit tests and the required builds and checks pass. Typing a password in macOS's dialog remains untested. See the [M12 results](docs/results/2026-10-18-connect-in-app.md).

Physical Mac connection check, 2026-10-18: the signed M12 build is installed and connects a share. The reported first-use picker wait of about 10 s remains unexplained. The picker appeared in 1.33 s on a repeat and 1.97 s after the test share was unmounted and the app and picker process restarted. Cache states beyond that reset are unknown. Daily file use, sleep and wake, a network change and a macOS restart remain unverified. See the [picker investigation](docs/results/2026-10-18-share-picker-delay.md).

Connection management follow-up, 2026-10-18: servers and share grants are saved separately. Disconnect ejects the OS volume, and Remove ejects associated shares before forgetting the server; a failed eject keeps the entry. In the signed VM app, an existing location survived migration, existing Finder and hidden connections could be reused, and removal/re-add and a partial two-share removal failure passed. All 156 tests and required checks passed. The signed Mac build is installed and launches with no settings error; physical-Mac connection checks remain. See the [connection-management results](docs/results/2026-10-18-connection-management.md).

File Provider approval, 2026-10-18: macOS had disabled the File Provider on the physical Mac. Enabling its switch restored Connected without restarting the app. The UI now gives enable instructions and an Open System Settings button. In the signed VM app, the button opened Login Items, the location recovered on the same domain, and a read matched the source. All 156 tests and required checks passed. The new UI is installed on the physical Mac; after the requested reset, the user resumed Finder browsing. See the [File Provider approval results](docs/results/2026-10-18-file-provider-approval.md).

First folder delay, 2026-10-18: the user's Finder run on the physical Mac hit the 5 s folder deadline. Its share-listing stage took 9.47 s for 5 entries, while the next three new folders completed in 41–127 ms. The installed diagnostic build separates the operations. The pause did not recur after app and mount resets, but the original location's automatic refresh warms the share, so fully cold access remains unverified. All 156 tests and required VM checks passed. The cause remains unresolved. See the [investigation](docs/results/2026-10-18-first-folder-delay.md).

Physical-Mac daily use, 2026-10-19: the user reports fast Finder browsing, video startup and seeking, and that the supplied checks passed except macOS restart. Logs confirm partial-file reads and read-ahead, with one earlier item also receiving a later full download. A download button can remain while only part of a file is cached. No playback or browsing performance code changed in the diagnostic update; cache states were uncontrolled. The user will continue observing. See the [physical-Mac results](docs/results/2026-10-19-physical-mac-use.md).

Guest SMB connections, 2026-10-19: the signed VM app can reuse and save a guest mount after removing macOS's empty password field from its address. Passwords remain rejected, and existing grants keep their format. See the [guest-connection results](docs/results/2026-10-19-guest-connections.md).

Offline status (M13), 2026-10-19: the signed VM app shows Requested, Update in progress or Available offline after macOS applies the app's known changes. Controlled source edits, including edits that preserved size and modification time, passed. All three final kept files matched the source with downloading forbidden after an OS eject. Guest connections are also accepted without saving empty password fields. All 161 tests and required checks passed. The signed build is also installed on the physical Mac; launch retained the existing location and keep request. Its offline check and macOS restart remain open. M15 below adds live NAS change discovery. See the [version and offline-status results](docs/results/2026-10-19-offline-versions.md).

Competitor review, 2026-10-11: [PolyDrive](https://polydrive.net/) documents native SMB automounting, but excludes SMB from its File Provider path. Its cloud-drive offline features do not establish an offline SMB cache.

Folder keeps (M14), 2026-10-19: the signed VM app keeps folders recursively, including newly listed
files. Pause/resume, independent child requests, incomplete-folder status, relaunch and saved-list
restoration passed. Kept bytes matched the source with downloading forbidden after OS eject.
All 170 tests and required checks passed. The signed build is installed on the physical Mac;
launch retained the existing location and keep request. The user reports that folder keeping works;
physical-Mac offline and restart checks remain open. See the [folder-keep results](docs/results/2026-10-19-folder-keeps.md).

Finder download feedback, 2026-10-19: kept full-file transfers now publish progress for Finder's
native circle, including indeterminate progress on kept ancestor folders. The signed VM comparison
and checksums passed, as did all 170 tests and required checks. The fixture was removed and sharing
settings restored. The signed update is installed on the physical Mac. See the
[progress results](docs/results/2026-10-19-keep-download-progress.md).

Keep Downloaded status refresh, 2026-10-19: an existing verified item now stays Available offline
while a second request downloads. New or changed versions still require synchronization. The
signed before/after VM comparison and four local hashes passed, along with all 175 tests and
required checks. The signed update, including Finder's progress circle, is installed on the
physical Mac with the existing location and three keep requests retained. The user confirmed
that the status fix works; physical-Mac offline hashes and a restart remain open. See the [results](docs/results/2026-10-19-keep-status-refresh.md).

NAS change discovery (M15), 2026-10-19: the signed isolated VM app discovered external additions,
content edits, renames and deletions without relaunch. New kept descendants downloaded, local
hashes matched with hydration forbidden, and failed listings preserved known children. All 182
tests and required checks passed. Directory watches and periodic listings cover materialized
and kept folders. The signed update is installed and running on the physical Mac; its existing
location was retained. The user confirmed live changes work on this Mac. Offline hashes and
macOS restart remain open.
See the [results](docs/results/2026-10-19-nas-change-discovery.md).

## Run the prototype

See [prototype setup and validation](docs/prototype.md). Build the benchmark with `swift build -c release`; run `.build/release/transfer-bench --help`. Open `TinyMounter.xcodeproj` to configure signing for the Finder prototype.

## Recommendation

Use Apple's replicated File Provider extension for File Provider locations. Start with a read-only performance prototype backed by native macOS SMB, then compare a direct asynchronous SMB client. Select the shipping transport using measured throughput, video behavior, sandbox feasibility, and reconnect reliability.

File Provider supports partial-file downloads. It is not a native SMB mount, and some applications still request whole files. Near-native full-download throughput is verified under the VM conditions above. Sequential partial-read throughput is below target, and Finder-launched opens always download the whole file first.

- [Architecture and implementation phases](docs/architecture.md)
- [Prototype setup and current limitations](docs/prototype.md)
- [First NAS benchmark results](docs/results/2026-10-10-native-smb.md)
- [Performance and reliability validation plan](docs/benchmark-plan.md)
- [Research findings and primary sources](docs/research.md)
- [Interactive data-path overview](docs/architecture-overview.html)
- [Documentation index](docs/README.md)

Project rules for people and agents are in [AGENTS.md](AGENTS.md). Commits, PRs and the changelog are covered in [CONTRIBUTING.md](CONTRIBUTING.md).

Initial target: macOS 27 and the user's UGREEN NAS running Debian, using SMB2/3. Offline reading comes first. Writes come next, before release hardening: on 2026-10-18 the user ordered the phases so that what a daily user needs comes first ([architecture §10](docs/architecture.md#10-implementation-sequence-and-exit-criteria)).
