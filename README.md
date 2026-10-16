# tinymounter

A macOS app that brings a network disk, such as a NAS, into Apple's file system: browse it from Finder or another file manager such as QSpace, download on demand, and keep selected files available offline. Finder is the first file manager and SMB the first protocol it will support. A later mode will mount server volumes, the ordinary macOS SMB mounts, automatically.

Status, 2026-10-11: verified NAS-cold full downloads reached **183.3 MB/s versus 192.7 MB/s native SMB (95.1%)**; with the file in NAS RAM, **229.0 versus 247.2 MB/s (92.6%)**. Each condition has five matched pairs, server cache/disk-read evidence, and representative complete-file checksum verification. Fully downloaded local reads also pass, though an unexplained speed gap to a local APFS control remains. See [verified cache results](docs/results/2026-10-11-cache-states.md), [full-download attribution](docs/results/2026-10-11-full-download.md), and [range-delay diagnosis](docs/results/2026-10-11-provider-delay.md).

Players and read-ahead, 2026-10-11: Finder double-click, Open With and Cmd-O always download an uncached video fully before the player starts, because Finder itself makes a coordinated whole-file read. VLC's and IINA's own File > Open stream; QuickTime Player always downloads the whole file. Bounded read-ahead now favours seeks, as the user asked: seeks during streaming took **0.23–0.27 s** in all 9 trials, and long sequential partial reads run at **77–93 MB/s (about 30–37% of native)**, fetching about 1.03× the bytes read. A throughput-first setting reached 148.8 versus 249.4 MB/s (59.7%) but let seeks wait up to 1.4 s. Without read-ahead it was 9.6%. See [player and read-ahead results](docs/results/2026-10-11-player-readahead.md). These are VM results: first-frame and seek-resume times and physical-Mac speed remain unverified.

Offline reading, 2026-10-11: a file kept downloaded stayed readable, with a matching checksum, while the NAS was unreachable, with the app quit or running. Files that weren't downloaded failed with a clear error rather than bad data, and reads recovered on their own when the NAS returned. See [offline results](docs/results/2026-10-11-offline-reading.md). It also survived restarting the app, the extension and macOS's File Provider daemon with the file cache flushed; a full restart hasn't been tested.

Interface, 2026-10-11: after three review rounds, the user accepted the [interface design](docs/ui-design.md) for prototyping and will evaluate it on the prototype. It is not built yet; see the [interactive mockup](docs/ui-mockup.html). It uses Apple's terms (File Provider, server volume), a Connection Mode setting, and Duplicate in the sidebar to add locations. Its text follows ASD-STE100. Proposal for review: [synchronization between File Provider locations and server volumes](docs/synchronization.md).

Phase 2, 2026-10-12: started, before phase 1's exit, on the current transport. The [phase 2 plan](docs/phase2-plan.md) records the user's decisions: a Finder connection for now, Keep Downloaded as requests, relisting at launch and reconnect, the interface scope, and the exit targets. Milestone M1's core library (catalog, folder listing, safe paths, per-item read-ahead registry, error classifier and share health) passes `swift test`, and on the NAS share it [matched native listings](docs/results/2026-10-12-nas-listing.md) field for field over 80 folders. M3's [saved share-root grant and Finder spikes](docs/results/2026-10-12-share-grant.md) are verified in the signed sandboxed app, including a depth-4 file open after relaunch. Its regression read through a fresh test location passed on 2026-10-13, so M3 is done. M4 (Finder browsing from a catalog per location) and M5 (reads by item, per-item read-ahead, staging cleanup) [passed their runtime checks](docs/results/2026-10-14-catalog-browsing-reads.md) in the signed app on 2026-10-14 and 2026-10-15: matching folder counts, checksummed partial and full reads, VLC and IINA streaming, clean restarts, crashes and a NAS outage. A follow-up the same day fixed IINA's full-download fallbacks (recent-file bookmarks, and a read racing a rewrite of delivered bytes) and a read-ahead stall, and Remove Location now deletes downloaded copies. A system race when a fast reader catches read-ahead can still cause a full download. Folder eviction, VLC's seeks and physical-Mac playback are unverified. A [remount test](docs/results/2026-10-12-remount-identity.md) showed that `st_dev` changes per mount while inode, size, mtime and ctime don't, so content versions leave out the device.

Competitor review, 2026-10-11: [PolyDrive](https://polydrive.net/) documents native SMB automounting, but excludes SMB from its File Provider path. Its cloud-drive offline features do not establish an offline SMB cache.

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

Initial target: macOS 27 and the user's UGREEN NAS running Debian, using SMB2/3. Offline reading comes first; offline editing and syncing changes back are a later phase. A wholly read-only first release is the proposed scope, rather than a requirement the user has imposed on all future versions.
