# tinymounter

A macOS app that brings a network disk, such as a NAS, into Apple's file system: browse it from Finder or another file manager such as QSpace, download on demand, and keep selected files available offline. Finder is the first file manager and SMB the first protocol it will support. A later mode will manage ordinary native SMB mounts automatically.

Status, 2026-10-10: the read-only benchmark has now run against the NAS. Five paired 2 GiB runs measured 247.2 MB/s native reads and 243.6 MB/s with local staging; a separate range checksum passed. The one-file File Provider app and extension now build with Personal Team development signing and pass strict signature verification. Finder integration has not yet been tested.

## Run the prototype

See [prototype setup and validation](docs/prototype.md). Build the benchmark with `swift build -c release`; run `.build/release/transfer-bench --help`. Open `TinyMounter.xcodeproj` to configure signing for the Finder prototype.

## Recommendation

Use Apple's replicated File Provider extension for the integrated drive. Start with a read-only performance prototype backed by native macOS SMB, then compare a direct asynchronous SMB client. Select the shipping transport using measured throughput, video behavior, sandbox feasibility, and reconnect reliability.

File Provider supports partial-file downloads. It is not a native SMB mount, and some applications still request whole files. Near-native network throughput is a feasibility target, not an established result.

- [Architecture and implementation phases](docs/architecture.md)
- [Prototype setup and current limitations](docs/prototype.md)
- [First NAS benchmark results](docs/results/2026-10-10-native-smb.md)
- [Performance and reliability validation plan](docs/benchmark-plan.md)
- [Research findings and primary sources](docs/research.md)
- [Interactive data-path overview](docs/architecture-overview.html)
- [Documentation index](docs/README.md)

Project rules for people and agents are in [AGENTS.md](AGENTS.md). Commits, PRs and the changelog are covered in [CONTRIBUTING.md](CONTRIBUTING.md).

Initial target: macOS 27 and the user's UGREEN NAS running Debian, using SMB2/3. Offline reading comes first; offline editing and syncing changes back are a later phase. A wholly read-only first release is the proposed scope, rather than a requirement the user has imposed on all future versions.
