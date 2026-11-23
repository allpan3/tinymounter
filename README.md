# TinyMounter

A macOS app that brings a network disk, such as a NAS, into Apple's file system: browse it from Finder or another file manager such as QSpace, download on demand, and keep selected files available offline. Finder is the first file manager and SMB the first protocol it will support. Server Volume mode also mounts ordinary macOS SMB shares automatically, without an offline replica.

## Status

TinyMounter 0.4.2 is the current release, for personal use on Apple silicon with macOS 27. A File
Provider location shows a share or a folder on it in Finder, downloads files on demand and keeps
selected files and folders downloaded for offline use. With Read only off, it also supports new
files and folders, ordinary saves, offline edits, rename and move, Finder Replace and permanent
deletion. The app signs in with its own SMB client and the password in its own Keychain item, so
File Provider locations use no macOS mount; it watches listed and kept folders with `CHANGE_NOTIFY`. Server
Volume mode mounts a whole share as a normal Finder volume with the same saved password. See the
[install notes and known limits](docs/release.md) and the [planned work](docs/roadmap.md).

## Run the prototype

See [prototype setup and validation](docs/prototype.md). Build the benchmark with `swift build -c release`; run `.build/release/transfer-bench --help`. Open `TinyMounter.xcodeproj` to configure signing for the Finder prototype.

## Recommendation

Continue with Apple's replicated File Provider extension. The adopted single-client transport
uses the app's own SMB connection for sign-in, listings, metadata, reads, writes and change
notification. The menu bar panel shows transfers and recent activity, with configurable
notifications and upload recovery. [Daily-use validation](docs/roadmap.md#daily-use-validation-m27) is in progress.
Version 0.4.1 adds local SMB server discovery and a configurable minimum free disk space of
20 GB by default. It preserves uncertain local files for manual recovery after macOS loses its
synchronization state and retains kept downloads during Pause. Both fixes passed signed VM checks. Physical-Mac acceptance checks remain open.

Version 0.4.2 pipelines SMB reads and writes and avoids a second checksum on fresh APFS uploads.
File Provider supports partial-file downloads. In VM tests of the signed candidate, full downloads and
writable sequential reads met the 90% native SMB throughput target. Read-only sequential
reads reached 94% with cold Samba file pages and 84% with warm pages. IINA streamed video
through its own File > Open. QuickTime and the tested Finder launches requested the whole
file. [Benchmark conditions](docs/benchmark-plan.md#fixed-regression-set-during-implementation)

- [Architecture and implementation phases](docs/architecture.md)
- [Prototype setup and current limitations](docs/prototype.md)
- [Performance and reliability validation plan](docs/benchmark-plan.md)
- [Research findings and primary sources](docs/research.md)
- [Interactive data-path overview](docs/architecture-overview.html)
- [Documentation index](docs/README.md)

Project rules for people and agents are in [AGENTS.md](AGENTS.md). Commits, PRs and the changelog are covered in [CONTRIBUTING.md](CONTRIBUTING.md).

Initial target: macOS 27 and the user's UGREEN NAS running Debian, using SMB2/3. The phases put what a daily user needs first: offline reading, then writes, then release hardening ([architecture §10](docs/architecture.md#10-implementation-sequence-and-exit-criteria)).
