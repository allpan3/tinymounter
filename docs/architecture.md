# Architecture proposal

Date: 2026-10-10. Decision status: proposed; the transport choice is gated by experiments. Source references resolve in [research.md](research.md).

## 1. Product contract

The first useful milestone is a file-system location backed by the user's SMB share, tested first in Finder. Users can browse, open, stream supported media, download files, and select **Keep Downloaded** for reliable offline reading. The NAS remains the source of truth. No NAS agent, cloud relay, tinymounter account, kernel extension, or FUSE installation is required.

The user selected offline reading first. This plan recommends making the initial provider entirely read-only, including while online, to validate the central performance proposition before implementing uploads. Users can copy a file out to edit locally. Online editing is not a trivial intermediate step: a local save can race with loss of connectivity, so it also needs durable pending-write handling.

Initial validation targets macOS 27 and the user's UGREEN hardware running Debian. Confirm the Samba version and configuration during testing; Debian alone does not establish those details. Broader OS support and other NAS implementations come after feasibility. The core range API exists from macOS 12.3 and content policies from macOS 13; recursive namespace pinning has a macOS 27 API [A1–A4].

Two explicit modes will eventually share the same connection setup:

| Mode | User-visible storage | Offline behavior | Delivery |
| --- | --- | --- | --- |
| Integrated drive | OS-managed File Provider location, normally under `~/Library/CloudStorage` | Materialized local files; selected files/folders pinned | First |
| Native network drive | Normal macOS SMB volume | Requires server connectivity; kernel caching is not a durable offline replica | Later |

The modes have different paths and semantics. Do not silently change a File Provider location into a native mount when the network changes. Do not offer simultaneous writable views as the default.

## 2. Architecture decisions

| Area | Proposed decision | Reason / gate |
| --- | --- | --- |
| macOS integration | `NSFileProviderReplicatedExtension` plus `NSFileProviderPartialContentFetching` | Native integration with Finder and other file managers, local APFS materialization, offline reads, range requests |
| Implementation | Swift app and core libraries; SwiftUI/AppKit where appropriate; C interop for a direct SMB library | Small native macOS application; no UI runtime in the byte path |
| First transport prototype | Native SMB mount, read using POSIX APIs | Holds the SMB implementation constant against Finder to isolate integration cost |
| Shipping SMB transport | Decide between native bridge and async `libsmb2` after the spike | Native performance must be balanced against permissions, hangs, helper lifecycle, and deployment |
| Metadata | Per-domain SQLite database in an App Group, WAL, short transactions | Stable identities, directory snapshots, ordered changes, pins, restart recovery |
| Downloaded content | OS-managed materialized files; short-lived staging in the provider's temporary directory | Avoid an unnecessary second permanent content cache |
| Credentials | Keychain with a deliberate shared access group | Separate connection records by account; never put passwords in URLs or process arguments |
| Distribution | Signed development builds first; Developer ID/notarized beta proposed | Prove real extension behavior and entitlements early; App Store remains a separate packaging gate |
| Future mount management | NetFS APIs, per-user login component, `NWPathMonitor` plus actual SMB reachability | Native mounts and reconnection without inventing a filesystem |

File Provider, cache ownership, and metadata architecture are selected. The shipping transport is deliberately **not** selected from documentation alone.

## 3. Components and ownership

**TinyMounter.app** owns connection setup, credentials entry, domain registration, pin controls, connection status, diagnostics, and later the native-mount policy UI. One File Provider domain represents a particular share/subfolder and authenticated account. Domain identity is stable across app restarts and reconnections.

**TinyMounterFileProvider.appex** owns the File Provider callbacks: item lookup, paginated enumeration, working-set changes, full and partial fetches, cancellation, progress, and error translation. It must work when the settings window is closed. Cached reads must not depend on the app being alive. Do not remove/re-add domains to implement reconnect.

For the read-only milestone, advertise only applicable read/enumeration capabilities and reject remote create/modify/delete/rename callbacks with the appropriate permission error. Enforce this through provider behavior and a read-only NAS account/internal mount, not only by hiding UI controls. Check enforcement using POSIX operations as well as Finder.

**TinyMounterCore** contains domain records, metadata reconciliation, version mapping, scheduler, pins, and transport-neutral contracts. Begin with an internal interface specific to SMB's needs; do not build an elaborate universal protocol framework before a second protocol exists.

**SMB transport** implements `connect`, `list`, `stat`, `openRead`, `readRange`, `close`, and capability discovery. Optional change watches complement reconciliation. Calls carry cancellation, priorities, version context, and byte-progress reporting. Keep the data path off the main actor and separate from serialized metadata writes.

**Per-user background component**, if needed, owns long-lived change watches and later automount. Registration and actual lifecycle must be tested. The File Provider process can be suspended or restarted, so perpetual sockets in the extension are not a sufficient background-refresh strategy. Driio's release notes report this exact lifecycle issue [D2]. A background watcher is an optimization: on-demand fetch and reconnect reconciliation must work without it.

**Native bridge worker**, only if that transport ships, owns tinymounter's internal SMB mounts and potentially blocking POSIX I/O. It hands over file descriptors or writes into an authorized staging file rather than serializing large `Data` objects across XPC. Each share gets bounded isolation so an unreachable mount cannot starve all domains.

Proposed source layout once implementation begins:

```text
Apps/TinyMounter/                 setup, menu bar, domain management
Extensions/TinyMounterProvider/   OS callbacks and item adapters
Packages/TinyMounterCore/         metadata, scheduler, reconciliation
Packages/SMBTransport/            transport contract and selected backend
Helpers/NativeSMBWorker/          only if justified by the transport gate
Tools/TransferBench/              native, direct-SMB, and provider measurements
Tests/Integration/               signed-extension and failure-recovery tests
```

## 4. First-read and streaming path

1. Finder or an application accesses a placeholder. macOS invokes the provider for the requested content.
2. Resolve the stable item ID and requested content version. Connect or reuse an authenticated SMB session/handle.
3. For a range request, honor the OS's **runtime alignment**, minimum range, requested version, and strict-version flag. Fetch an aligned extent covering the request. Handle empty files, end-of-file ranges, overflow, and cancellation explicitly.
4. Pipeline bounded SMB reads into a regular, potentially sparse staging file from `NSFileProviderManager.temporaryDirectoryURL()`, on the same volume as the user-visible file. Bytes go at their original offsets; the file must reach at least the returned extent's end [A2].
5. Complete with the item/version, staging URL, exact fetched range, and appropriate flags. Never mark holes as downloaded zeros. Once handed off, do not mutate the file: macOS clones and unlinks it [A2].
6. macOS resumes the application's read. Later reads of materialized content use local storage without going through SMB or the extension [A3].

Do not wait for an entire video to download before completing a small requested range. Conversely, do not return before the promised extent is present. Use larger extents for sustained sequential access and small prioritized extents after a seek. Coalesce duplicate in-flight requests for the same version/range; each completion needs correct staging-file ownership, not a shared URL that the OS may unlink.

Initial experiment grid: 256 KiB, 1 MiB, and 4 MiB SMB requests, subject to negotiated limits; 1/4/8/16 in-flight requests; provider extents from 1–16 MiB, always respecting the requested minimum/alignment. These are tuning candidates, not constants to hard-code. Account for SMB credits and bytes in flight. A synchronous read loop with small chunks can waste most of the network's capacity.

Prioritize foreground reads and seeks over background pinning and metadata crawling. Bound aggregate buffers per domain and globally; target no more than 256 MiB of transfer buffers for the initial one-stream experiment. Avoid full-file memory buffers, per-chunk database commits, and an `fsync` after every network read. Preserve the handoff and future write durability contracts.

**Application limitation:** Apple states that partial downloads require suitable POSIX reads. Whole-file clones or reads using file coordination request the entire file [A1]. Implement full fetch as well. QuickTime, VLC, IINA, Quick Look, and editing applications must be tested individually. Supporting the range protocol does not guarantee streaming in every app, and a custom player is outside this product's scope.

## 5. Native SMB versus direct SMB

### Native bridge

Create an app-owned read-only mount with public NetFS APIs; `MNT_DONTBROWSE` can hide it from ordinary browsing but is not a security boundary. Reuse Apple's SMB client, negotiated security, and supported multichannel behavior. Read via `pread`/equivalent into APFS staging. A bare SMB path or symlink cannot substitute for materializing a File Provider file.

The first diagnostic can use a user-mounted share with deliberately granted access. A shipping implementation must additionally prove automated mount ownership, extension sandbox access, credential isolation, logout/reboot behavior, and disconnected-I/O containment. Test a signed installation on a clean user account. Do not assume the extension can access arbitrary mounts, or that an embedded XPC service automatically escapes its sandbox.

If a separate per-user helper is required, establish supported sandbox-to-helper access and authenticate the IPC peer. No private SMB APIs or broad sandbox bypass is part of the design. A helper timeout does not magically cancel a blocked kernel read; measure real recovery. Do not force-unmount a share used by another application, and never reuse/unmount an unrelated user mount merely because its pathname matches.

### Direct asynchronous SMB

`libsmb2` is a plausible candidate: it exposes asynchronous high-level and raw APIs, SMB2/3 signing/encryption, and pipelining opportunities [L1]. Build the measured version from pinned source and use a thin Swift adapter. AMSMB2 is a useful reference, but a convenient Swift async API alone does not prove deep per-file pipelining. Audit scheduling, copying, cancellation, and credential/session reuse.

Separate latency-sensitive metadata from bulk reads; pool authenticated sessions only when measured beneficial. Scope a pool by server, share, account, and security policy. Multiple connections/files are not the same as pipelined reads of one large file, nor are they automatically SMB Multichannel. Verify leases, reconnect behavior, authentication, negotiated read size/credits, and server compatibility rather than assuming parity with Apple's client.

`libsmb2` is LGPL-2.1. Dependency selection must include notices/source obligations, linkage and user-relinking requirements, and signing/distribution compatibility. The wrapper's MIT license does not erase its bundled library's obligations [L1–L2]. Complete that review before committing to a distribution build.

### Selection rule

Keep the native bridge if it meets the throughput gate and works cleanly under the shipping permissions/lifecycle model. Prefer direct SMB if it is comparably fast and materially simpler to deploy/recover. If direct SMB is slow while native-backed File Provider is fast, optimize or replace the SMB transport. If both provider paths are slow but their staging controls are fast, investigate provider scheduling and materialization. Do not switch frameworks solely because one first implementation is slow.

## 6. Offline retention and pinning

Distinguish these states in product language:

- **Online only:** metadata exists; content needs the server.
- **Partially downloaded:** some ranges are local; arbitrary offline reads cannot be promised.
- **Downloaded:** complete local copy, available offline while retained; the OS may evict it under pressure.
- **Keep Downloaded:** fully materialize and apply the keep-downloaded policy. Claim offline readiness only after completion.
- **Downloading / unavailable / permission needed:** explicit progress or actionable error, not a permanently spinning mount.

Use `NSFileProviderContentPolicy.downloadEagerlyAndKeepDownloaded` for pins. On macOS 27, combine it with `NSFileProviderNamespacePolicy.materializeEagerly` for pinned folders so unvisited subfolders also enumerate. Track pin intent separately from observed hydration status. Earlier-OS support, if later added, needs a deliberate bounded recursive enumeration strategy [A4].

Folder pinning has a byte/item budget, free-space reserve, progress, and cancellation. Never label a budget-limited or failed tree fully available offline. Retain complete already-downloaded files during a network outage. A sparse file's apparent logical size does not prove offline availability. Remote changes and partial materialization need version-aware invalidation, not unconditional removal of every local copy on reconnect.

The OS owns the main content cache. Tinymounter owns temporary transfer files and their crash cleanup, metadata, and pin policy. Cache limits are best-effort controls over evictable content, not a promise of an exact private cache size. Never edit the OS's internal File Provider database or cache directories directly.

Disconnecting, disabling refresh, removing a connection, and deleting remote files are different operations. Domain removal must preserve downloaded files or pending data according to the documented removal mode and the user's explicit intent; it must not be used as routine repair [A5]. The read-only release exposes no remote deletion operation.

## 7. Identity, versions, and change discovery

Use a persistent opaque UUID as `NSFileProviderItemIdentifier`. Paths change on rename and should not be primary IDs. Map it to domain/account, parent ID, remote name/path, supported remote identity evidence, and metadata. Do not mistake an open SMB handle's FileId for a universally persistent cross-reconnect object ID. Test server-provided identity stability across rename, replacement, reboot, and reconnect.

Minimum database records:

| Record | Important fields |
| --- | --- |
| Domain | UUID, server/share/subfolder, account reference, security policy, schema generation |
| Item | UUID, parent UUID, name/type, remote identity evidence, size, modification/change times, local metadata/content generations |
| Directory snapshot | Item UUID, ordered enumeration generation, pagination state, last successful complete reconciliation |
| Change log | Monotonic sequence, item UUID, update/deletion record, transaction generation |
| Pin | Item UUID, inherited/explicit intent, budget, enumeration/download progress |
| Transfer | Request ID, item/version, range, staging ownership, cancellation and cleanup state |

Use directory listing metadata to avoid a separate `stat` for every child where possible. Persist complete listing generations; a failed or partial listing must **never** be interpreted as deletion of missing children. Permission denied and server unreachable are not `noSuchItem`—that error can cause local removal [A2].

File Provider sync anchors are ordered cursors over tinymounter's durable change log, not wall-clock timestamps or SMB notification sequence numbers. Commit item changes and log entries atomically. Advance an anchor only through changes actually delivered, including tombstones. Expired anchors trigger a supported full resynchronization. Test pagination with interleaved additions, renames, and large deletion batches.

Watch active/materialized directories with SMB `CHANGE_NOTIFY` where supported; reconcile on wake/reconnect, on access when stale, and periodically with backoff. Notifications are invalidation hints, not a durable history of everything that happened offline. Fall back if a server accepts watches but never delivers them. Do not recursively poll millions of files at a fixed short interval or rely on local FSEvents to discover every remote SMB change. Pinned trees get bounded scheduled scans.

**Version coherence is a separate feasibility gate.** Plain SMB usually exposes mutable files, not retrievable immutable revisions. Size/mtime/change-time fingerprints are useful change evidence, not cryptographic version IDs. They may miss timestamp-preserving modifications. Never combine ranges after detecting a version change; use Apple's strict-version failure (`versionNoLongerAvailable`) and let the system refetch/retry.

For ordinary files, validate identity/version at open and after fetching, and keep a stable handle while reading. Validate behavior when other SMB clients write or replace the file. Reliable immutable snapshots, or a tested server-enforced exclusion strategy, provide stronger guarantees. Holding a deny-write/delete handle for an entire partially cached session can interfere with other users and does not survive every restart. If a server cannot uphold the supported consistency contract, disable partial fetch for that case and use a full fetch under a tested stable-read mechanism; if even that cannot obtain consistent content, fail/retry rather than publish known mixed content. Do not claim perfect snapshot semantics for arbitrary external modifications without server support.

## 8. Writes and offline editing, later

Offline editing means saving to the downloaded local copy and uploading when the server returns. Preserve both copies when the server copy also changed. Even online writes require the same foundation to survive an unexpected disconnect.

Add a durable upload outbox with item/base-version, immutable staged content, requested metadata operation, idempotency identity, and explicit states. Respect Apple's ownership/lifetime rules for callback URLs; keep an authorized clone before acknowledging work that will continue later. Mark content uploaded only after a verified remote commit, or follow Apple's deferred-upload contract with `isUploaded = false` so dirty content cannot be evicted [A2–A3].

Upload to a uniquely named temporary sibling; close/flush as required, validate the base, and atomically publish where the server supports it. A `stat` followed by `rename` is **not** compare-and-swap: another client can write between them. SMB sharing modes/locks and target replacement semantics require server-specific testing. When conditional replacement cannot be made safe, preserve a separate conflict file rather than silently replace the NAS version.

Crashes after remote commit but before local acknowledgement must be recoverable without duplicate writes or deletions. Renames, safe saves, moves across folders, packages, case-only renames, and remote deletes during local edits are first-class tests. Never silently discard an outbox during domain removal, reset, upgrade, or uninstall. Do not promise arbitrary live SQLite databases, VM disk images, or remote POSIX lock semantics on a synchronized local replica.

## 9. Future native automount mode

Use public `NetFSMountURLAsync`/cancellation and mount inspection. Run at **user login and wake** through a registered per-user component; pre-login boot mounting is separate future scope. Store no plaintext credentials in shell commands or launch configuration.

Maintain a per-share state machine: `disabled → waitingForPolicy → probing → mounting → mounted → recovering/backoff`, with distinct authentication-required and permission-required states. Network callbacks trigger debounced reevaluation, followed by DNS resolution and an actual SMB connection probe. `NWPathMonitor` reporting a usable path is not proof that a NAS is reachable [N1–N3].

Rules can later include trusted network, VPN reachability, wired preference, and manual override. Preserve a user's intentional eject instead of immediately remounting. Avoid duplicate mount attempts, back off with jitter, and recover after sleep, login, DNS/address changes, and server reboot.

An Ethernet/Wi-Fi change is not a reason to forcibly unmount every open file. Apple's SMB Multichannel can supply redundancy and choose interfaces when supported [N2]. Let healthy native sessions recover; remount when needed and safe. Tinymounter cannot promise seamless migration of every existing file descriptor across every path change. Do not globally rewrite `nsmb.conf` to implement a per-connection preference.

## 10. Implementation sequence and exit criteria

1. **Feasibility harness.** Signed File Provider with a small local fixture; full/range fetching; cancellation; local-network permissions tested for both app and extension; native SMB baseline; native-backed provider; async SMB comparator. Exit: attribution of throughput overhead, player matrix, and transport/permissions decision. Follow [benchmark-plan.md](benchmark-plan.md). Do this before the full UI.
2. **Read-only vertical slice.** One SMB share, persistent IDs/database, lazy directory enumeration, range/full reads, Keychain, meaningful offline/auth errors, safe restart. Exit: real Finder browsing and media reading without memory growth or leaked mounts/staging files.
3. **Offline-read alpha.** Complete-file and recursive folder pins, offline readiness, change discovery, reconnect reconciliation, cache pressure handling, domain lifecycle. Exit: pinned files survive disconnect/reboot and hashes match; incomplete files are never represented as fully offline-ready.
4. **Read-only release hardening.** Multiple shares/accounts, load and failure testing, app-closed behavior, signing/notarization, clean install/update/uninstall, accessibility and diagnostics. Performance gates must pass on the physical Mac/NAS pair. Add broader NAS coverage before broad compatibility claims.
5. **Writable synchronization.** Durable outbox, conflict preservation, remote commit/recovery semantics, then offline editing. This is a separate data-integrity project, not a checkbox added to the downloader.
6. **Native automount mode.** Reuse connections, Keychain, reachability, and any proven native mount component. Add the policy state machine and safe user controls. It can be prioritized independently after the integrated mode is proven.

## 11. Open decisions for the first experiment

- Actual Mac hardware, NAS disk/RAID/filesystem, RAM, NIC/link topology, Samba version, and SMB signing/encryption/multichannel state.
- Current competitor app versions and exact scripts/files used for the reported rates.
- Whether native bridge permissions/lifecycle are acceptable and whether direct SMB matches its speed.
- Which players use partial reads on macOS 27, and what coherence guarantee the server can support.
- Developer signing team/App Group identifiers and product deployment floor when creating the extension.

No NAS credentials are needed to review this plan. For the experiment, a read-only test account/share and a representative large video/file are enough; the user can connect it in the VM or enter credentials into the app instead of placing secrets in chat. Writes and deliberate server disruption will need a dedicated scratch area and explicit test scope. The VM is appropriate for correctness work; its virtual NIC/storage cannot establish the physical Mac's absolute speed.
