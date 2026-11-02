# tinymounter

A macOS app that brings a network disk, such as a NAS, into Apple's file system: browse it from Finder or another file manager such as QSpace, download on demand, and keep selected files available offline. Finder is the first file manager and SMB the first protocol it will support. A later mode will mount server volumes, the ordinary macOS SMB mounts, automatically.

Pending changes, 2026-11-02: Settings lists each new item that did not upload, with the reason
and the time of the last try. Retry Pending Changes, and share recovery, make macOS send items
it had stopped retrying. A signed VM check passes; the build is not installed on the physical
Mac. Follow-up fixes stop a retry loop on slow-connecting shares, keep the status updating while
a write waits for the server, and let a refused file upload after Retry. See the
[VM results](docs/results/2026-11-02-pending-changes-list.md).

Migration removal, 2026-11-01: builds no longer migrate or guard settings, catalogs and pending
changes from earlier builds. One write permission replaces the old creation-only state, so the
Complete Write Setup step is gone, and the folder picker now explains the write conditions. All
540 VM tests (one skipped) and the required checks pass. Settings from an earlier build are
rejected; Start Fresh in General removes the earlier locations so they can be added again.

Physical-Mac update, 2026-11-02: the build with Start Fresh is installed. Start Fresh removed the
earlier location, which stuck pending changes kept the earlier build from removing. The location
was added again with write access, and the files that never uploaded were restored to the NAS
with checksum verification. Stuck pending changes still block removal. See the
[installation record](docs/results/2026-11-02-start-fresh-install.md).

Read diagnostics, 2026-11-01: required VM checks and five signed app checks pass. Logs distinguish
full verification, cached block verification and share-lock waits; cancellation during the local
checksum removes staging. No read behavior or performance target changed, and no speed improvement
is claimed. See the [diagnostic results and limits](docs/results/2026-11-01-read-diagnostics.md).

Read-performance development, 2026-11-01: the signed VM candidate reduces repeated small-read
latency from 4.127 s to 0.721 s median, with matching checksums. Full downloads are about 8%
slower in this comparison; first reads after restart/remount and one slow outlier remain.
The candidate passed required checks. This change is not installed on the physical Mac. See the
[measurements and remaining checks](docs/results/2026-11-01-verified-range-reads.md).

Everyday-use review, 2026-10-31: accelerated encryption gives a 7.19 s median for five 2 GiB
writable downloads in the VM; the earlier profiled sample took 77.10 s. All required checks
and 7,205 encryption cases pass. Edited-file cache misses still wait 4–5 s, and throughput
remains below target. Repeated read-only comparisons show no demonstrated regression against M17.
A supported Samba setting fixes folder creation, including signed Finder creation and initial
naming. Correcting VM hostname resolution removes the fixture's 20-second connection delay.
Repeated content verification, integrated Finder workflows and recovery controls remain open;
M22/M24 stay disabled in the normal build. Temporary VM service and hostname changes are restored. See the
[review and measurement limits](docs/results/2026-10-31-everyday-use-review.md).

Save recovery, 2026-10-30: signed TextEdit checks recovered from stops before publication and before its reply. A simulated mid-copy space failure preserved the earlier exportable save; the complete newer save uploaded after retry. Item IDs, server identities and keep flags survived, with no final pending copies or false conflicts. [The observed callbacks and limits are recorded](docs/results/2026-10-29-pending-save-order.md#signed-callback-observation-2026-10-30). Bounded reserve, partial-stage continuation and lost-cleanup-reply checks also pass. A fresh signed probe verifies full replacement-artifact preservation through cleanup. Actual disk exhaustion and broader editor workflows remain unverified; M23 is incomplete.

Folder moves, 2026-10-31: signed adapter checks pass for populated and case-only moves,
destination collisions, lost-reply recovery and partial-catalog recovery. Signed app checks also
pass for read/watch draining, pending-write exclusions, overlapping views, keeps and recovery
after settings persistence. Two ambiguous-name cases could not run on the fixture.
The repaired lock scopes also pass signed Settings-callback and fresh-process recovery checks.
Signed Settings-gap checks cover case-only descendant retirement, source-only ancestor changes
and retry after restoring a changed root or destination ancestor. The Unicode-spelling case is
unavailable because the native listing rewrites its initial name. Signed root-retirement checks
now pass after partial catalog completion: old subtree IDs and keeps retire, the share unblocks,
and completed replay returns a changed-version error. Restoring the folder produces new IDs.
The run found and fixed a surviving-root handle conflict; all required VM checks pass.
Root removal/replacement and downloaded-copy invalidation still need signed verification.
[Signed Finder rename, move and case-only checks preserve the downloaded copies](docs/results/2026-10-30-folder-move-catalog.md#signed-finder-checks-2026-10-30).
New-folder creation now passes with the repaired fixture; parent-scoped enumeration and interruption checks
remain open. Folder organization stays disabled in the normal build.
The integrated candidate passes all required VM checks with 569 tests, one optional skip and no
failures or Swift warnings, including save recovery, recursive deletion, catalog settlement,
keep-path cleanup and the gated app caller.

Deletion adapter, 2026-10-30: signed file and empty-folder deletion, paginated confirmation,
changed/replaced-file refusal and recovery checks pass. Lost close replies remain unconfirmed.
[The results and simulated-interruption limits are recorded](docs/results/2026-10-29-deletion-protocol.md#signed-adapter-continuation-2026-10-30).
The durable recursive-deletion core also passes 28 simulated-server and storage tests in VM 1.
Protected traversal admission passes required VM checks and bounded signed recursive checks.
Deletion inventory, catalog settlement and gated app admission pass
required VM checks. The fresh-listing settlement bridge also passes source review and VM checks;
the connected recovery scheduler and cancellation repair also pass the required VM checks.
Follow-up recovery fixes also pass checks. Signed recursive refusals, two-view deletion, lost-reply
restart recovery, competing changes and replacement preservation pass with independent backing
audits. Native replacement reads can need a second open to observe the settled catalog identity.
Signed admission and joined cancellation, close, counted Stop and automatic-settlement checks
also pass. Recovery controls and provider integration remain pending; Finder deletion is unavailable.
The fixture is unmounted, its server is stopped and Apple SMB is restored. Uncertain records,
fixtures and private evidence remain for investigation; see the
[final validation and restoration record](docs/results/2026-10-29-deletion-protocol.md#final-validation-and-service-restoration-2026-10-30).

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

Disk-space protection (M16), 2026-10-22: the signed VM checks passed blocking, clear Finder
errors, recovery after relaunch, manual Pause and preservation of completed copies. A disposable
volume also passed real disk-full cleanup and recovery. All 192 tests and required checks passed.
The app reserves 2 GiB and shows Not sufficient space for blocked keeps. VM fixtures are removed
and sharing is restored. The signed update is installed on the physical Mac with its existing
location retained. Physical-Mac low-space checks remain. See the [results](docs/results/2026-10-21-disk-space-protection.md).

Location changes and removal (M17), 2026-10-22: signed VM checks passed rename, rejected source
changes, interrupted Apply/Remove and provider off/on without changing the other location's kept
copy. Re-adding restored a saved request; automatic download completion remains unverified.
No production code changed. Test locations and downloads are removed. All 192 tests and
required checks passed. See the [results](docs/results/2026-10-22-location-lifecycle.md).

Write support (M18), 2026-10-23: new file/folder creation, explicit per-location write grants,
pending copies and recovery are implemented. All 208 VM tests and required checks passed.
Signed extension callbacks through authenticated IPC created files and folders with matching
remote hashes; interruption and lifecycle guards passed. After an approved VM File Provider daemon
restart, normal Finder file and nested-folder uploads passed, with matching hashes and native
progress. Initial naming and file Keep Both now pass the follow-up checks below. Existing
locations stay read-only. The physical-Mac installation is recorded below. See the
[results](docs/results/2026-10-23-create-items.md) and
[accepted plan](docs/phase4-plan.md).

Initial folder naming investigation, 2026-10-23: the user approved this part of New Folder.
Native exclusive rename is unavailable on the tested SMB mount, and create/delete failed a
replacement race. An isolated direct SMB client preserved existing destinations in collision
and competing-create checks. The follow-ups below resolve dependency adoption, macOS credential
reuse and initial naming. The fixture is removed and sharing is restored. See the
[investigation](docs/results/2026-10-23-initial-folder-naming.md).

Folder naming authentication follow-up, 2026-10-23: the earlier zero-match credential result
came from a parser defect. The corrected probe acquired the account/server-bound credential
and connected in a signed sandboxed app without a password. A limited `libsmb2` naming
prototype is accepted; initial naming now passes the implementation checks below. Native reads
and file uploads remain unchanged. See the [follow-up](docs/results/2026-10-23-folder-naming-authentication.md).

Initial folder naming implementation, 2026-10-23: Finder's initial folder-name callback, durable
intent and catalog updates are implemented. General renaming remains denied. Catalog version 4
preserves listing cursors with an immutable enumeration key and migrates earlier formats.
The read-only NAS check found native name-based identifiers that cannot prove rename ownership.
The accepted direct SMB client now creates and initially names folders with retained server
identity, separate from native catalog identity. Signed Finder, collision, read-only and recovery
checks passed, and all 230 tests and required VM checks passed without skips or Swift warnings.
The fixture is removed and sharing is restored. Keep Both failed in this run; the follow-up
below resolves file collisions. See the
[checks](docs/results/2026-10-23-folder-naming-fix.md).

Keep Both follow-up, 2026-10-25: signed VM isolation trials found that Finder needs rename
capability to select an alternative name before creation. Enabled locations advertise it.
General remote renaming remained unavailable in M18. Its final signed app passed repeated file
collisions, original-byte preservation, folder copying and read-only Finder paste. All 232 VM
tests and required checks passed. The fixture is removed and sharing is restored. See the [results](docs/results/2026-10-25-keep-both.md).

Physical-Mac M18 installation, 2026-10-27: the signed app and provider run from Applications.
The existing catalog ID and diagnostic counts are retained; the location stays read-only.
Downloaded bytes were not independently checked. Creation and Keep Both await the user's run.
See the [installation results](docs/results/2026-10-25-keep-both.md#physical-mac-installation-2026-10-27).

Online editing (M19), 2026-10-28: normal and repeated TextEdit saves pass in the signed VM app.
A concurrent SMB edit preserves the other client's file and saves the local edit as a separate
conflict copy, including when size and modification time are unchanged. Successful saves retain
the original file object and clean up their verified temporary copies. The product runs on the
Mac and uses the server's existing SMB service.

In M19, editing requires a separate opt-in for folders whose writers all use SMB. Programs must leave
tinymounter's temporary save files alone. A save keeps complete local content and a verified
remote backup, then changes the original while it is temporarily away from its normal name.
Other readers must close it first; an interrupted save can prolong its unavailability.
Uncertain recovery retains the complete versions. General rename, move, deletion, Finder Replace,
packages, databases and VM images remain unsupported. TextEdit's local metadata is preserved,
but explicit dates and attached data are not synchronized to the server.

Required VM checks pass: 264 tests, one optional fixture skip, no failures or Swift warnings.
Signed recovery checks cover preparation through publication. Partial uploads and content copies
retain the complete versions; partial work remains unresolved and the normal Export Local Copy
action works. Item IDs, keep requests and an independent download are preserved. Fixture
connection delays can defer retries. The temporary server, dependencies, files and task windows
are cleaned up, with original settings verified. The verified M19 build is installed on the
physical Mac. Background launch checks retain one location and matching catalog counts, with
no failed migration; downloaded bytes were not independently checked there. Editing still
requires its separate opt-in, and physical-Mac writes are the user's checks. See the
[October 28 results](docs/results/2026-10-28-same-object-save.md) and the
[accepted design](docs/phase4-plan.md#revised-mac-only-save-proposal).

File renaming and one write mode (M20), 2026-10-29: signed VM Finder checks pass same-folder
renaming of verified ordinary files, including repeated and case-only changes. Contents, IDs,
downloads and Keep Downloaded requests survive. Conflicts refuse replacement, and interrupted
renames recover from evidence. Uncertain operations remain pending and protect every affected
location. Unverified files, folder renaming, moves, deletion and Replace remain unsupported.

One Read only toggle now controls supported writes. It defaults off for new locations, with
scoped access and safety confirmation during setup. Existing read-only locations stay read-only.
Required VM checks pass: 281 tests, one optional fixture skip and no Swift warnings.
The fixture and obsolete VM builds are removed. Slow fixture authentication can still show a
temporary Unresponsive status. The installed M19 build is unchanged; physical-Mac M20 behavior
is unverified. See the
[results and matched recordings](docs/results/2026-10-29-file-renaming.md) and the
[accepted scope](docs/phase4-plan.md#m20-file-renaming).

Roadmap accepted, 2026-10-29: the [remaining roadmap](docs/roadmap.md) defines the accepted
work toward ordinary file/folder operations, complete online saves and offline editing, followed
by daily-use and release validation. The user approved permanent deletion, parallel agents and
worktrees, and the first disposable VM test session. Implementation is starting with M21 and
M23; their safety gates and runtime checks are not yet passed. Installation is deferred.

File-move catalog preparation, 2026-10-29: the catalog preserves item identity, versions and keeps
across a proven move, and records departures for the old folder. Migration and core checks pass
in VM 1: 294 tests, one optional skip, no failures or Swift warnings, and all required builds.
This core-only result precedes the protocol and signed integration checks below. See the
[catalog results](docs/results/2026-10-29-move-catalog.md).

SMB rename encoding, 2026-10-29: a VM packet regression reproduced a vendor bug that could
change the file handle in a rename request. The fix passes six encoding cases and all required
checks, including 294 tests with one optional skip and no Swift warnings. It enables no new
write operation; signed SMB runtime checks and installation remain pending. See the
[encoding results](docs/results/2026-10-29-smb-rename-encoding.md).

File organization protocol, 2026-10-29: all nine disposable VM cases pass, including protected
moves, collisions, permission/stream preservation and crash recovery. File-organization
integration uses the accepted current-object admission rule for unverified rows and passes all
required VM checks: 356 tests, one optional skip and no Swift warnings. Signed Finder moves
preserve unverified, legacy downloaded and verified files, their versions and downloaded copies.
Overlapping-view and before/after-move interruption checks also preserve those copies. On
2026-10-30, five signed app-API boundary cases passed, including refusal of pending uploads
before SMB admission; their temporary locations were removed. Finder drag, pending-edit and
remaining callback checks and matched recordings are open. The fixture session has ended. See the
[protocol results](docs/results/2026-10-29-file-organization-protocol.md).

Pending saves (M23), 2026-10-29: a focused VM regression reproduces an older save publishing
while a newer complete copy waits. The core fix and retirement pass required checks. A signed
app update recovered an interrupted upload, published the latest TextEdit save and kept the
older copy exportable. Recovery cleanup and clearer status reporting pass all required VM
checks, including 373 tests with one optional skip and no failures or Swift warnings. Signed
retained-save cleanup and export now pass; storage admission checks remain. See the
[ordering results](docs/results/2026-10-29-pending-save-order.md).
The 2026-10-30 follow-up extends uncertain-removal retention to already published saves and
corrects cleanup handle lifetime. All required VM checks pass, including 404 tests with one
optional skip and no failures or Swift warnings. Signed cleanup, a subsequent TextEdit save
and app restart pass with unchanged item identity and keeps; M23 remains incomplete.

Deletion protocol (M24), 2026-10-29: the disposable VM probe completed deletion, competing-access
and eleven crash scenarios, then cleaned up its test subtree. The user accepted deleting the
whole selected file, including concurrent attached data; lost replies remain visibly unconfirmed.
The initial transaction core passed required VM checks on 2026-10-30: 441 tests, one optional
skip and no failures or Swift warnings. Exact SMB error capture also passes 57 simulated
callback cases and required VM checks; no app deletion capability is enabled. See the
[deletion results](docs/results/2026-10-29-deletion-protocol.md).

Folder catalog preparation (M22), 2026-10-30: subtree commits preserve item identity and file
versions and require fresh directory listings before reporting offline availability. Atomic
settlement also handles proved changed or missing descendants. Required VM checks pass with
414 tests, one optional skip and no failures or Swift warnings. The folder transaction core
then passed required checks with 472 tests and one optional skip. Recovery after partial catalog
completion, the SMB adapter and saved keep-path rewriting now pass required checks with 490
tests and one optional skip. Runtime integration and signed checks remain; app folder rename
and move are unavailable. See the
[catalog preparation](docs/results/2026-10-30-folder-move-catalog.md).

## Run the prototype

See [prototype setup and validation](docs/prototype.md). Build the benchmark with `swift build -c release`; run `.build/release/transfer-bench --help`. Open `TinyMounter.xcodeproj` to configure signing for the Finder prototype.

## Recommendation

Continue with Apple's replicated File Provider extension and native macOS SMB reads/uploads.
The accepted direct-SMB adapter handles protected write operations and their verification.
Complete the integrated Finder workflows and matched performance checks before expanding the
normal build's capabilities. Any transport change still needs measurement and a separate decision.

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
