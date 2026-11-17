# TinyMounter

A macOS app that brings a network disk, such as a NAS, into Apple's file system: browse it from Finder or another file manager such as QSpace, download on demand, and keep selected files available offline. Finder is the first file manager and SMB the first protocol it will support. Server Volume mode also mounts ordinary macOS SMB shares automatically, without an offline replica.

## Status

TinyMounter 0.4.0 is the current release, for personal use on Apple silicon with macOS 27. A File
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
The current source preserves uncertain local files for manual recovery after macOS loses its
synchronization state; that fix is not in 0.4.0. Physical-Mac acceptance checks remain open. Writable partial reads
stay at about 0.73 of native; 0.90 remains the improvement goal.

File Provider supports partial-file downloads. It is not a native SMB mount, and some applications still request whole files. Full downloads reach more than 90% of native SMB throughput in the VM. Sequential partial-read throughput is below target, and Finder-launched opens always download the whole file first.

- [Architecture and implementation phases](docs/architecture.md)
- [Prototype setup and current limitations](docs/prototype.md)
- [Performance and reliability validation plan](docs/benchmark-plan.md)
- [Research findings and primary sources](docs/research.md)
- [Interactive data-path overview](docs/architecture-overview.html)
- [Documentation index](docs/README.md)

Project rules for people and agents are in [AGENTS.md](AGENTS.md). Commits, PRs and the changelog are covered in [CONTRIBUTING.md](CONTRIBUTING.md).

Initial target: macOS 27 and the user's UGREEN NAS running Debian, using SMB2/3. The phases put what a daily user needs first: offline reading, then writes, then release hardening ([architecture §10](docs/architecture.md#10-implementation-sequence-and-exit-criteria)).
