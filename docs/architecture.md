# Architecture proposal

Date: 2026-10-19. Decision status: production architecture proposed; the user set the phase order on 2026-10-18; the app-owned reader experiment and the bounded read-ahead experiment are approved and implemented. Phase 2's M4 and M5 build moves them from one file to catalog-backed folders, read by item; signed VM browsing and reads are verified, with the remaining recovery and materialization limits recorded in the [runtime follow-up](results/2026-10-15-runtime-followup.md). Full downloads exceed 90% of native speed in verified NAS-cold and NAS-cached states; sequential partial reads don't yet. The shipping transport remains gated by experiments. Source references resolve in [research.md](research.md).

## 1. Product contract

The first useful milestone is a file-system location backed by the user's SMB share, tested first in Finder. Users can browse, open, stream supported media, download files, and select **Keep Downloaded** for reliable offline reading. The NAS remains the source of truth. No NAS agent, cloud relay, tinymounter account, kernel extension, or FUSE installation is required.

The user selected offline reading first. This plan recommends making the initial provider entirely read-only, including while online, to validate the central performance proposition before implementing uploads. Users can copy a file out to edit locally. On 2026-10-18 the user moved writes ahead of release hardening (§10). Online editing is not a trivial intermediate step: a local save can race with loss of connectivity, so it also needs durable pending-write handling.

Initial validation targets macOS 27 and the user's UGREEN hardware running Debian with 64 GB RAM. The [cache-controlled experiment](results/2026-10-11-cache-states.md) verified Samba 4.17.12-Debian, ext4 on LVM over linear md storage, and SMB3.1.1 with AES-128-GMAC signing and encryption off. Broader OS support and other NAS implementations come after feasibility. The core range API exists from macOS 12.3 and content policies from macOS 13; recursive namespace pinning has a macOS 27 API [A1–A4].

Two explicit modes will eventually share the same connection setup:

| Mode | User-visible storage | Offline behavior | Delivery |
| --- | --- | --- | --- |
| File Provider location | OS-managed location, normally under `~/Library/CloudStorage` | Materialized local files; selected files/folders pinned | First |
| Server volume | Normal macOS SMB volume | Requires server connectivity; kernel caching is not a durable offline replica | Later |

The modes have different paths and semantics. Do not silently change a File Provider location into a server volume when the network changes. Do not offer simultaneous writable views as the default.

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

**TinyMounter.app** owns connection setup through macOS's login dialog, domain registration, pin controls, connection status, diagnostics, and later the native-mount policy UI. One File Provider domain represents a particular share/subfolder and authenticated account. Domain identity is stable across app restarts and reconnections.

**Saved connections, accepted and implemented on 2026-10-18.** Server addresses and share grants
are separate records. The app owns read-only grants; macOS owns passwords and SMB mounts. An
existing connection can be associated with a saved server by explicit selection, with confirmation
for another address. Disconnect ejects that OS volume. Remove ejects all associated connections
before deleting the server; failure retains the records. Keep Downloaded lists hold typed file
and folder requests ([M14 results](results/2026-10-19-folder-keeps.md)). The
[connection-management results](results/2026-10-18-connection-management.md) record VM checks and
physical-Mac limits.

**TinyMounterFileProvider.appex** owns the File Provider callbacks: item lookup, paginated enumeration, working-set changes, full and partial fetches, cancellation, progress, and error translation. It must work when the settings window is closed. Cached reads must not depend on the app being alive. Do not remove/re-add domains to implement reconnect.

**Current approved experiment:** the main app owns source reads, because direct extension access to the existing NAS mount was denied by Network Volumes privacy. The extension vends a restricted `NSFileProviderServiceSource`; the app connects through its domain manager and exports a reader over duplex XPC. Both peers require the same signing team and the exact counterpart bundle ID. Read requests contain an item ID, a content version and a range, never a pathname. In the phase 2 build (M4 and M5), the app resolves a saved share-root grant once per mount session and owns all share I/O and every catalog write. It lists folders into one SQLite catalog per domain, builds each file's path from that catalog beneath the location root, compares the file's fingerprint with the catalog row, and stages read-only POSIX reads in the shared App Group. The extension reads the catalog read-only and never touches the share. The extension moves the completed file into its File Provider temporary directory using an exclusive same-volume rename, then hands it to macOS. Payload bytes are never serialized across XPC [A9]. No separate helper or daemon was added. The [phase 2 plan](phase2-plan.md#3-architecture) gives the processes and flows.

The app must remain running for cache misses and for folders that were never listed; cached reads and listed folders work after it quits. Full app-independent fetching, crash recovery and shipping lifecycle are still gates. The [reader experiment](results/2026-10-10-app-reader.md) verifies NAS access and checksums but records a large throughput gap. This does not select the production transport.

For the read-only milestone, advertise only applicable read/enumeration capabilities and reject remote create/modify/delete/rename callbacks with the appropriate permission error. Enforce this through provider behavior and a read-only NAS account/internal mount, not only by hiding UI controls. Check enforcement using POSIX operations as well as Finder. The phase 2 build returns `fileWriteNoPermission` and counts these calls in its log; only a reimport `createItem`, which is identity matching, completes with the existing item.

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
4. Pipeline bounded SMB reads into a regular, potentially sparse staging file on the same volume as the user-visible file. The current app-owned reader first writes in the shared App Group, then the extension moves that file into `NSFileProviderManager.temporaryDirectoryURL()` before completion. Cross-volume moves fail; there is no copying fallback. Bytes go at their original offsets; the file must reach at least the returned extent's end [A2]. Stage files that a crash leaves are deleted at app launch, before any reader connects, and by each extension process for files created before it started.
5. Complete with the item/version, staging URL, exact fetched range, and appropriate flags. Never mark holes as downloaded zeros. Once handed off, do not mutate the file: macOS clones and unlinks it [A2]. While the app reads, it reports the bytes done at most every 0.5 s, and the extension updates the fetch's progress. Once the app starts the transfer, the extension ends its wait after 60 s with neither progress nor a reply (phase 2, D2), not after an absolute 300 s, so long healthy downloads go on and time queued for an app worker is not a stall.
6. macOS resumes the application's read. Later reads of materialized content use local storage without going through SMB or the extension [A3].

Do not wait for an entire video to download before completing a small requested range. Conversely, do not return before the promised extent is present. Use larger extents for sustained sequential access and small prioritized extents after a seek. Coalesce duplicate in-flight requests for the same version/range; each completion needs correct staging-file ownership, not a shared URL that the OS may unlink.

Initial experiment grid: 256 KiB, 1 MiB, and 4 MiB SMB requests, subject to negotiated limits; 1/4/8/16 in-flight requests; provider extents from 1–16 MiB, always respecting the requested minimum/alignment. These are tuning candidates, not constants to hard-code. Account for SMB credits and bytes in flight. A synchronous read loop with small chunks can waste most of the network's capacity.

The [October 11 diagnostic](results/2026-10-11-provider-delay.md) extended returned extents to 64/256 MiB after locating a recurring database-flush wait after handoff. Throughput rose, but first-byte delay and overfetch grew; the prototype default remains 16 MiB. The [full-download attribution](results/2026-10-11-full-download.md) separated source transfer, callback time and macOS materialization. The subsequent [verified cache comparison](results/2026-10-11-cache-states.md) reached 95.1% of native with NAS disk reads and 92.6% with NAS RAM, across five pairs per state. This answers the full-download throughput question on the VM. The [player and read-ahead experiment](results/2026-10-11-player-readahead.md) then raised sequential partial reads from 23.4 to 148.8 MB/s (59.7% of native over 2 GiB). Seek-first settings, which the user asked for, run at 77–93 MB/s. The range-read gate still fails.

The user distinguishes two workloads. **Open** should prioritize the ranges an application needs to begin displaying content or resume a seek; these need not be at the beginning of the file. **Download / Keep Downloaded** should fetch the entire file efficiently, with completion and retention tracked separately. The current full callback already streams the whole source into staging in one request, using bounded memory. Honor the actual full-versus-partial request rather than assigning behavior solely from a filename extension. Some applications require full materialization even when the format permits partial access [A1].

**Bounded read-ahead, implemented experiment.** Cache hits produce no callbacks, so the extension sees only misses. A miss that continues the previous miss of the same item schedules speculative ranges for that item through public range-download requests [A10]. Read-ahead state is per item: up to 8 planners, by item and content version. Speculative completions never extend the window, and a seek makes only its own item's earlier requests stale. The first miss and any seek fetch only the 16 MiB demand extent.

The user prioritized seeks during streaming. `fileproviderd` held a waiting seek for as long as speculative requests kept arriving back to back, up to about 2.7 s. With one 16 MiB chunk at a time, a window up to 128 MiB and a 30 ms pause before each chained request, seeks during streaming took 0.23–0.27 s, with about 1.03× bytes fetched per byte read, but long sequential reads fell to about 30–37% of native. The [October 15 comparison](results/2026-10-15-read-ahead-window.md) then cut the window to one chunk: speculation stays 16 MiB past the latest sequential miss. A moving-boundary stress reader no longer triggered the system materialization race (0/11, against 5/5 at 128 MiB), IINA played and seeked the same, and 512 MiB sequential reads rose from 32.8% to 45.2% of native in the VM. Throughput-first settings (64 MiB chunks, a 1 GiB window) reached 59.7% with 1.49× and seeks of 0.72–1.37 s. Continuous whole-file downloading remains a separate policy choice.

Prioritize foreground reads and seeks over background pinning and metadata crawling. Bound aggregate buffers per domain and globally; target no more than 256 MiB of transfer buffers for the initial one-stream experiment. Avoid full-file memory buffers, per-chunk database commits, and an `fsync` after every network read. Preserve the handoff and future write durability contracts.

**Application limitation:** Apple states that partial downloads require suitable POSIX reads. Whole-file clones or reads using file coordination request the entire file [A1]. Implement full fetch as well. Supporting the range protocol does not guarantee streaming in every app, and a custom player is outside this product's scope. Measured on macOS 27 ([player results](results/2026-10-11-player-readahead.md)):

- **Finder:** in the measured VM configurations, double-click, Open With and Cmd-O made a coordinated whole-file read before handing the file to an app. Content downloaded fully before playback started. The [physical-Mac run](results/2026-10-19-physical-mac-use.md) includes partial playback reads, but its exact opening routes were not recorded.
- **Opt-out:** Apple's `NSFileProviderExtensionNonMaterializingProcessNames` [A2] stops the download, but Finder then silently refuses to open the file, so Finder isn't listed. Only `ScopedBookmarkAgent` is: resolving an app's recent-file bookmarks otherwise downloads each whole file ([M5 follow-up](results/2026-10-14-catalog-browsing-reads.md#follow-up-2026-10-15)).
- **VLC:** streams with partial reads when opened from its own File > Open or from `open -a`.
- **QuickTime Player:** always downloads the whole file.
- **IINA:** streams with partial reads from its own Open, after the extension began clipping IINA's end-of-file reads that run past EOF.
- **Quick Look:** shows only a generic icon for a file that isn't downloaded, and fetches nothing.
- **TextEdit:** normal saves pass in the signed M19 VM build under its explicit editing opt-in
  ([results](results/2026-10-28-same-object-save.md)). Other editing applications remain unverified.

## 5. Native SMB versus direct SMB

### Native bridge

Create an app-owned read-only mount with public NetFS APIs; `MNT_DONTBROWSE` can hide it from ordinary browsing but is not a security boundary. Reuse Apple's SMB client, negotiated security, and supported multichannel behavior. Read via `pread`/equivalent into APFS staging. A bare SMB path or symlink cannot substitute for materializing a File Provider file.

The first diagnostic can use a user-mounted share with deliberately granted access. A shipping implementation must additionally prove automated mount ownership, extension sandbox access, credential isolation, logout/reboot behavior, and disconnected-I/O containment. Test a signed installation on a clean user account. Do not assume the extension can access arbitrary mounts, or that an embedded XPC service automatically escapes its sandbox.

If a separate per-user helper is required, establish supported sandbox-to-helper access and authenticate the IPC peer. No private SMB APIs or broad sandbox bypass is part of the design. A helper timeout does not magically cancel a blocked kernel read; measure real recovery. Do not force-unmount a share used by another application, and never reuse/unmount an unrelated user mount merely because its pathname matches.

### Direct asynchronous SMB

`libsmb2` is a plausible candidate: it exposes asynchronous high-level and raw APIs, SMB2/3 signing/encryption, and pipelining opportunities [L1]. Build the measured version from pinned source and use a thin Swift adapter. AMSMB2 is a useful reference, but a convenient Swift async API alone does not prove deep per-file pipelining. Audit scheduling, copying, cancellation, and credential/session reuse.

Separate latency-sensitive metadata from bulk reads; pool authenticated sessions only when measured beneficial. Scope a pool by server, share, account, and security policy. Multiple connections/files are not the same as pipelined reads of one large file, nor are they automatically SMB Multichannel. Verify leases, reconnect behavior, authentication, negotiated read size/credits, and server compatibility rather than assuming parity with Apple's client.

`libsmb2` is LGPL-2.1-or-later. Dependency selection must include notices/source obligations, linkage and user-relinking requirements, and signing/distribution compatibility. The wrapper's MIT license does not erase its bundled library's obligations [L1–L2]. Complete that review before committing to a distribution build.

A limited `libsmb2-6.3` prototype is accepted for M18 exclusive folder creation and initial naming
on 2026-10-23. Native reads and new-file uploads remain selected. The app embeds a separate dynamic
library and uses public GSS APIs for macOS-cached NTLM credentials. Authenticated mutations require SMB encryption.
Its source, local changes and licence are in Vendor/libsmb2. This does not select a replacement
read transport or a distribution package. See the [authentication checks](results/2026-10-23-folder-naming-authentication.md).

On 2026-11-02 the user approved uploading private save-stage contents through the existing
protected SMB handle. Native stage opens failed after the Linux fixture reused deleted file IDs;
the direct-handle probe passed 20 repeated 2 MiB uploads. The implementation uses bounded writes,
retains exclusive sharing protection, and verifies the flushed and reopened stage before publication.
Signed VM checks pass for repeated stages, Unicode saves, sharing protection and interrupted uploads.
November 3 probes reproduce stale native names after direct rename and a native metadata write
recreating a deleted stage after file-ID reuse. No fix is verified; the Mac update is withheld.
See the [staging results](results/2026-11-02-samba-names-and-uploads.md).

The separate `single-smb-client-prototype` branch, authorized on 2026-11-03, uses that client for
remote listing, metadata, payload reads and new uploads as well. It retains native mount grants,
credentials, lifecycle and change hints. Protected full reads stage once through the same
deny-write/delete handle, verify all staged bytes locally, then recheck server metadata and
security before accepting the version. Protected partial reads still verify and stage serially.
Its catalog uses server IDs directly and therefore requires fresh test state. A separate signed
VM bundle passes repeated saves, conflict preservation, interrupted-save recovery and fresh
read-only downloads. Five coordinated read-only full downloads exceed the native staging median
with verified empty Linux file cache. Partial reads reach about 49% of native, below the 90%
target. Read-only copy and Keep Both pass; recovery export refuses network destinations.
Arbitrary external native-mount writes remain outside that evidence. The physical Mac retains
the earlier transport; production adoption remains undecided. See the
[experiment record](results/2026-11-02-samba-names-and-uploads.md#single-client-transport-experiment).

The November 3 continuation adds recovery of acknowledged partial new uploads. It reopens the
recorded file with exclusive SMB sharing, proves the exact identity and every existing byte
against the retained complete payload, and appends only missing bytes. Changed identities,
changed prefixes, oversized files and uncertain create replies remain unresolved. Full flush,
close and reopen verification still precedes acknowledgment. Signed VM checks pass for resumed
uploads and refusal of changed prefixes or replacement identities.

### Selection rule

Keep the native bridge if it meets the throughput gate and works cleanly under the shipping permissions/lifecycle model. Prefer direct SMB if it is comparably fast and materially simpler to deploy/recover. If direct SMB is slow while native-backed File Provider is fast, optimize or replace the SMB transport. If both provider paths are slow but their staging controls are fast, investigate provider scheduling and materialization. Do not switch frameworks solely because one first implementation is slow.

## 6. Offline retention and pinning

Distinguish these states in product language:

- **Online only:** metadata exists; content needs the server.
- **Partially downloaded:** some ranges are local; arbitrary offline reads cannot be promised.
- **Downloaded:** complete local copy, available offline while retained; the OS may evict it under pressure.
- **Keep Downloaded:** fully materialize and apply the keep-downloaded policy. Claim offline readiness only after completion.
- **Downloading / unavailable / permission needed:** explicit progress or actionable error, not a permanently spinning mount.

VM test, 2026-10-11: a kept-downloaded file stayed readable with a matching hash while the NAS was unreachable, with the app quit and running ([offline results](results/2026-10-11-offline-reading.md)).

Use `NSFileProviderContentPolicy.downloadEagerlyAndKeepDownloaded` for pins. On macOS 27, combine it with `NSFileProviderNamespacePolicy.materializeEagerly` for pinned folders so unvisited subfolders also enumerate. Track pin intent separately from observed hydration status. Earlier-OS support, if later added, needs a deliberate bounded recursive enumeration strategy [A4].

Folder pinning has a byte/item budget, free-space reserve, progress, and cancellation. M16 implements a shared 2 GiB local reserve with conservative staging/handoff reservations and retry after space returns. The reserve is an admission policy; other processes can still consume local space. Configurable folder budgets remain planned. Never label a budget-limited or failed tree fully available offline. Retain complete already-downloaded files during a network outage. A sparse file's apparent logical size does not prove offline availability. Remote changes and partial materialization need version-aware invalidation, not unconditional removal of every local copy on reconnect.

The OS owns the main content cache. Tinymounter owns temporary transfer files and their crash cleanup, metadata, and pin policy. Cache limits are best-effort controls over evictable content, not a promise of an exact private cache size. Never edit the OS's internal File Provider database or cache directories directly.

Disconnecting, disabling refresh, removing a connection, and deleting remote files are different operations. Domain removal must preserve downloaded files or pending data according to the documented removal mode and the user's explicit intent; it must not be used as routine repair [A5]. The read-only release exposes no remote deletion operation.

## 7. Identity, versions, and change discovery

Use a persistent opaque UUID as `NSFileProviderItemIdentifier`. Paths change on rename and should not be primary IDs. Map it to domain/account, parent ID, remote name/path, supported remote identity evidence, and metadata. Do not mistake an open SMB handle's FileId for a universally persistent cross-reconnect object ID. Test server-provided identity stability across rename, replacement, reboot, and reconnect. Measured on 2026-10-12 in the VM: after an eject and reconnect of the Finder mount, inode, size, mtime and ctime stayed the same for 268 of 268 entries, while `st_dev` and `f_fsid` changed ([remount results](results/2026-10-12-remount-identity.md)). So content versions leave out the device. Rename, replacement and server reboot are not tested. The phase 2 build keeps one SQLite catalog per domain in the App Group: UUID item IDs kept by parent, name key and kind; content versions `f1:<size>:<mtime_ns>:<ctime_ns>`; sync anchors over a durable change sequence; keyset page tokens; and tombstones written only by a complete listing ([phase 2 §4 and §5](phase2-plan.md#4-data-model)).

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

Watch active/materialized directories with SMB `CHANGE_NOTIFY` where supported; reconcile on wake/reconnect, on access when stale, and periodically with backoff. Notifications are invalidation hints, not a durable history of everything that happened offline. Fall back if a server accepts watches but never delivers them. Do not recursively poll millions of files at a fixed short interval or rely on local FSEvents to discover every remote SMB change. Pinned trees get bounded scheduled scans. M15 uses public Dispatch vnode sources on the native SMB mount [C1, C2], with at most 64 watches per session. It monitors listed materialized and kept folders, and parents of kept files. Periodic reconciliation covers missed events. A successful listing is due again after 60 s; one automatic listing runs at a time with a one-second gap, so larger sets take longer. Failures back off to at most 240 s. Wake requests refresh, and launch/recovery reconciliation and per-fetch fingerprint checks remain. It never walks unvisited unkept trees. See the [phase 3 plan](phase3-plan.md#m15-discover-nas-changes-while-the-app-runs) and [signed VM results](results/2026-10-19-nas-change-discovery.md).

**Version coherence is a separate feasibility gate.** Plain SMB usually exposes mutable files, not retrievable immutable revisions. Size/mtime/change-time fingerprints are useful change evidence, not cryptographic version IDs. They may miss timestamp-preserving modifications. Never combine ranges after detecting a version change; use Apple's strict-version failure (`versionNoLongerAvailable`) and let the system refetch/retry.

For ordinary files, validate identity/version at open and after fetching, and keep a stable handle while reading. Validate behavior when other SMB clients write or replace the file. Reliable immutable snapshots, or a tested server-enforced exclusion strategy, provide stronger guarantees. Holding a deny-write/delete handle for an entire partially cached session can interfere with other users and does not survive every restart. If a server cannot uphold the supported consistency contract, disable partial fetch for that case and use a full fetch under a tested stable-read mechanism; if even that cannot obtain consistent content, fail/retry rather than publish known mixed content. Do not claim perfect snapshot semantics for arbitrary external modifications without server support.

### Edited-file read verification

Decision status: implementation authorized by the 2026-11-02 read-performance task;
performance and app integration await coordinator-run VM checks.

An edit receipt binds server identity to a complete SHA-256 digest. Metadata alone cannot
prove that mutable SMB content still matches it. The original read path therefore digested
the entire protected server file before each native transfer, including tiny ranges. The
November 1 implementation reuses bounded block digests, but loses them on restart/remount
and serializes complete verification before every full transfer.

Keep the independent server checks and native payload transport. Persist one bounded block
proof per location in a disposable local cache, bound to the exact receipt and relative path.
Load it only for that receipt, and validate fresh protected server identity, size, times,
attributes, security and requested block contents on every use. Never trust the cache as
evidence of the server's current state. Missing, malformed, mismatched or oversized evidence
takes the existing complete-verification path. The cache contains at most 2 MiB of digests,
with 1 MiB blocks and a 64 GiB indexing limit. It changes no catalog or receipt format and
requires no Start Fresh. A new installation or a different cached item can still incur one
whole-file verification before the first small read.

Capture the table during the existing complete server verification after a save or upload,
and after a verified full handoff. This adds block hashing, but no server payload read, to
publication. Store only after the receipt is committed or the staged read has passed its
checksum. Cache-write failure leaves the operation valid and the next read uses the slow
path. Location close and location removal remove its cache; normal process exit does not. The
cache lives under the app's Caches directory and may be purged without losing a receipt or
pending save.

For full downloads, run protected whole-file verification alongside native staging. Both
must succeed, and the local staged checksum must equal the independently obtained server
digest before handoff. This overlaps the repeated verification cost; it does not eliminate
the server read or assert a speedup before measurement. Reuse an existing block table instead
of hashing every block again during full verification when its receipt still matches.
Mutations retain their complete checks. Persistent metadata-only digest reuse is unsafe;
keeping deny-write/delete handles between requests would interfere with other clients.

The handle and lock rules are:

- The existing recursive share namespace lock encloses each protected request. Inside it,
  take the location upload lock. Catalog access takes the catalog lock; session acquisition
  takes the share start lock and then the share state lock. Location-root lookup briefly
  takes the session's lock. None of these inner locks spans the transfer or worker join.
  The namespace lock also serializes proof-cache access, with no separate cache lock.
  Catalog and share state locks never call back into the namespace while held.
- Each request owns a fresh protected SMB connection, ancestor handles denying delete,
  a regular-file handle denying write/delete, and one native read-only descriptor. The
  same protected handle supplies metadata and all server digest reads. The same native
  descriptor supplies the entire staged range. No handle is cached or reused by another
  request; the persisted proof contains only immutable data.
- For a full transfer, only the native worker performs payload I/O on the native descriptor.
  It acquires no namespace, upload, catalog, share start or session-root lock. Space checks
  take the download-budget lock; progress notification takes the share health/state lock.
  The owner holds neither while joining, and their callbacks do not acquire the namespace.
  The owning thread performs protected SMB
  work, joins the worker on success, failure or cancellation, then checks staging. Both
  handles stay alive through the join and final checksum. Worker failure cancels verification;
  verification failure cancels the worker. Cancellation cannot close a descriptor beneath
  a blocked read. A kernel read must return before its descriptor and protections close.
- The worker's result/progress lock never encloses I/O, progress/cancellation callbacks or a wait.
  The owner waits without that lock. The native worker therefore cannot wait for any lock
  held by its joining owner. Concurrent protected requests serialize under the existing
  namespace lock; listings can still delay reads. No lock scope is narrowed in this change.

Server protection excludes an SMB replacement or writer between verification and staging.
Metadata/block mismatch follows full verification and the existing version-change path;
stale native data fails the independent staged checksum. A failed or cancelled transfer
removes staging; only verified evidence enters the cache. A remount can reuse only content
evidence, after fresh server protection and identity/block checks. Metadata-preserving changes outside a
requested block remain detectable on later access or full verification, as in the existing
range-read contract. Direct backing-store writes that bypass SMB protection remain outside
that contract. The VM checks are specified in the benchmark plan.

## 8. Writes and offline editing, later

Offline editing means saving to the downloaded local copy and uploading when the server returns. Preserve both copies when the server copy also changed. Even online writes require the same foundation to survive an unexpected disconnect.

Add a durable upload outbox with item/base-version, immutable staged content, requested metadata operation, idempotency identity, and explicit states. Respect Apple's ownership/lifetime rules for callback URLs; keep an authorized clone before acknowledging work that will continue later. Mark content uploaded only after a verified remote commit, or follow Apple's deferred-upload contract with `isUploaded = false` so dirty content cannot be evicted [A2–A3].

Upload to a uniquely named temporary sibling; close/flush as required, validate the base, and atomically publish where the server supports it. A `stat` followed by `rename` is **not** compare-and-swap: another client can write between them. SMB sharing modes/locks and target replacement semantics require server-specific testing. When conditional replacement cannot be made safe, preserve a separate conflict file rather than silently replace the NAS version.

Crashes after remote commit but before local acknowledgement must be recoverable without duplicate writes or deletions. Renames, safe saves, moves across folders, packages, case-only renames, and remote deletes during local edits are first-class tests. Never silently discard an outbox during domain removal, reset, upgrade, or uninstall. Do not promise arbitrary live SQLite databases, VM disk images, or remote POSIX lock semantics on a synchronized local replica.

## 9. Future server volume mode

Use public `NetFSMountURLAsync`/cancellation and mount inspection. Run at **user login and wake** through a registered per-user component; pre-login boot mounting is separate future scope. Store no plaintext credentials in shell commands or launch configuration.

Maintain a per-share state machine: `disabled → waitingForPolicy → probing → mounting → mounted → recovering/backoff`, with distinct authentication-required and permission-required states. Network callbacks trigger debounced reevaluation, followed by DNS resolution and an actual SMB connection probe. `NWPathMonitor` reporting a usable path is not proof that a NAS is reachable [N1–N3].

Rules can later include trusted network, VPN reachability, wired preference, and manual override. Preserve a user's intentional eject instead of immediately remounting. Avoid duplicate mount attempts, back off with jitter, and recover after sleep, login, DNS/address changes, and server reboot.

An Ethernet/Wi-Fi change is not a reason to forcibly unmount every open file. Apple's SMB Multichannel can supply redundancy and choose interfaces when supported [N2]. Let healthy native sessions recover; remount when needed and safe. Tinymounter cannot promise seamless migration of every existing file descriptor across every path change. Do not globally rewrite `nsmb.conf` to implement a per-connection preference.

## 10. Implementation sequence and exit criteria

The user set the order of phases 3 to 7 on 2026-10-18: what a daily user needs comes first, and
refinement comes after. Writes now come before release hardening. After M9, the user agreed to
move phase 5 earlier. Its reconnection part now starts phase 3; the rest stays in phase 5, because
it waits for the transport decision.

The [remaining roadmap](roadmap.md), accepted on 2026-10-29, sets user-facing milestones,
dependencies and completion criteria within these phases. It also assigns parallel worktree
ownership. The user approved its scopes, permanent-deletion policy, parallel agents/worktrees
and first disposable VM test session. Each implementation still has to pass its safety gates.

1. **Feasibility harness.** Signed File Provider with a small local fixture; full/range fetching; cancellation; local-network permissions tested for both app and extension; native SMB baseline; native-backed provider; async SMB comparator. Exit: attribution of throughput overhead, player matrix, and transport/permissions decision. Follow [benchmark-plan.md](benchmark-plan.md). Do this before the full UI.
2. **Read-only vertical slice.** One SMB share, persistent IDs/database, lazy directory enumeration, range/full reads, Keychain, meaningful offline/auth errors, safe restart. Exit: real Finder browsing and media reading without memory growth or leaked mounts/staging files. Started 2026-10-12 before phase 1's exit, on the current transport, with the user's Finder connection standing in for Keychain until the transport decision; see the [phase 2 plan](phase2-plan.md). It ends with M9, exit validation in the VM, and M10, daily use on the physical Mac: updates keep locations, removal steps, and a signature that lasts.
3. **Offline and NAS changes you can trust.** It starts with reconnection, because in M9 macOS dropped the Finder connection after a 70 s outage and the user had to connect again. After an outage, sleep or a network change, the app asks macOS to mount the share again with the password that the user saved in the Keychain, and it leaves an intentional eject alone. A VM spike showed that the sandboxed app can mount. After a crash, the extension starts the app again, but not after the user quits it ([phase 3 plan](phase3-plan.md)). The user then connects in the app, with macOS's own login dialog, and Finder shows only the locations (M12). M13 verifies kept-file offline status after a public File Provider stabilization barrier, against the catalog version observed by the app ([results](results/2026-10-19-offline-versions.md)). M14 adds recursive folder requests, inherited retention and aggregate offline status ([results](results/2026-10-19-folder-keeps.md)). M15 adds bounded directory watches and periodic discovery in materialized and kept folders while the app runs ([results](results/2026-10-19-nas-change-discovery.md)). M16 adds a shared local-space budget with a 2 GiB reserve, disk-full status and persisted retry that respects Pause ([results](results/2026-10-21-disk-space-protection.md)). M17 verifies location-change ordering, interrupted Apply/Remove and provider disablement with two locations ([results](results/2026-10-22-location-lifecycle.md)). Full restart and OS eviction under pressure remain unverified. Exit: the share comes back by itself after an outage, and an eject stays; the app comes back after a crash, and a Quit stays; pinned files survive disconnect/reboot and hashes match; incomplete files are never represented as available offline; a NAS change in a listed folder shows without a relaunch. Testing NAS changes needs an isolated writable share.
4. **Writable synchronization.** Durable outbox, conflict preservation, remote commit/recovery semantics, then offline editing. This is a separate data-integrity project, not a checkbox added to the downloader. It needs change discovery from phase 3, and an isolated writable share for its tests. The [phase 4 plan](phase4-plan.md) sets new files and folders as M18; the user approved its scope and disposable writable VM fixture on 2026-10-23. The [native publication check](results/2026-10-23-upload-publication.md) found that exclusive creation works, but exposes a new file remotely during upload. The user accepted that visibility tradeoff on 2026-10-23; M18 creation and recovery are implemented. After an approved VM daemon restart, normal Finder file and nested-folder uploads passed with matching hashes and native progress. Initial naming and file Keep Both pass the signed follow-ups. See the [M18 results](results/2026-10-23-create-items.md).
5. **Own connection.** Credentials that the app keeps in the Keychain, and an SMB connection of its own instead of the macOS mount, if phase 1's transport decision chooses one.
6. **Release hardening.** Multiple shares/accounts, several locations on one folder, load and failure testing, app-closed behavior, signing/notarization, clean install/update/uninstall, accessibility and diagnostics. Performance gates must pass on the physical Mac/NAS pair. Add broader NAS coverage before broad compatibility claims.
7. **Server volume mode.** Mount server volumes automatically. Reuse connections, Keychain, reachability, and any proven native mount component. Add the policy state machine and safe user controls. It can be prioritized independently after File Provider locations are proven.

## 11. Open decisions for the first experiment

- **Single-client transport experiment, accepted 2026-11-03.** Evaluate the existing SMB client
  for remote listing, metadata, reads and writes in a separate VM-only prototype. Controlled
  probes reproduce both remaining symptoms when direct mutations leave stale native caches.
  Keep verification, recovery, sandbox and scoped access; use fresh test state. First prove
  correctness, then compare against the VM's native throughput baseline before selecting a
  production transport. No additional dependency or licence change is proposed. This exceeds
  the private-stage exception. The user authorized all needed VM work, including this
  experiment; production adoption and physical-Mac installation remain separate. See the
  [scope and evidence](results/2026-11-02-samba-names-and-uploads.md#single-client-transport-experiment).
- **Protected save-stage uploads, accepted 2026-11-02.** Upload private save-stage contents through
  the existing protected SMB handle. Repeated native opens failed after the Linux fixture reused
  a deleted file ID; a direct-handle probe passed 20 repeated 2 MiB writes with full readback and
  close-metadata verification. This changes the native-upload choice only for private save stages.
  Native reads and new-file uploads remain selected. No dependency or licence changes are needed;
  distribution review remains open. Required VM checks and signed repeated-stage, sharing and
  interruption checks pass. Native final-confirmation failures and a recreated file at an old
  stage name block the Mac update. Further transport changes remain undecided. See the
  [evidence and next steps](results/2026-11-02-samba-names-and-uploads.md#signed-app-verification-2026-11-02).
- **M23 interrupted uploads, accepted 2026-10-29.** The [ordering core](results/2026-10-29-pending-save-order.md)
  and retirement change pass the required VM checks. The user permits a newer save after durably
  preventing an older save from publishing, provided it has not started changing the original.
  Retain its uncertain artifacts and local copy, visible and exportable. Signed update recovery
  published the latest save and preserved the older export. Recovery cleanup and status reporting
  pass required VM checks. Broader signed workflows and storage admission checks remain.
- **M24 attached data during deletion, accepted 2026-10-29.** The [VM probe](results/2026-10-29-deletion-protocol.md)
  completed file/folder deletion and eleven crash scenarios. SMB permits adding streams under
  a deny-all main-file handle. Deleting all attached data present at removal, including such
  concurrent additions, is accepted. Lost-reply absence remains unconfirmed as already
  required. No app deletion capability is enabled.

- **M21 admission for ordinary catalog rows, accepted 2026-10-29.** Source review found that legacy
  downloaded and never-downloaded rows lack historical server identity. Name-derived native IDs
  and matching timestamps cannot distinguish an earlier replacement. The organization probe
  tests protected operations and recovery, but cannot supply that missing history. Binding a
  move to the object currently at the path, after matching known details and establishing
  protected identity/content evidence, is implemented but awaits signed verification. An indistinguishable
  prior replacement may therefore be moved. The [protocol results and accepted boundary](results/2026-10-29-file-organization-protocol.md#admission-decision)
  retain full-content recovery and existing verified-file admission. All nine isolated protocol
  cases pass, but cannot establish the missing history.

- **Remaining milestones, accepted 2026-10-29.** The user requested one forward plan and
  approved parallel agents/worktrees. The [roadmap](roadmap.md) defines M21 to M28, completion
  criteria and shared integration ownership. Accepted scopes include explicit permanent deletion
  and bounded offline editing. The first disposable VM test session is approved. Weaker recovery
  evidence, subsequent fixture sessions, installation and publication need separate decisions.
  Existing benchmark and phase exit gates remain.
- **M21 file organization, accepted 2026-10-29.** Rename and move ordinary files within one
  location, including files never downloaded, with an identity gate before mutation. Preserve
  original objects, IDs, downloads and keeps; prove departures as well as arrivals in enumeration.
  Reuse protected no-replace rename with durable evidence for both parents. Initially refuse
  crossing an overlapping location's boundary and moves between locations; folder operations
  follow in M22. The [transaction plan](phase4-plan.md#m21-organize-ordinary-files) keeps the
  content-preservation checks. Its first disposable VM protocol session is approved.
- **M20 file renaming, accepted 2026-10-29.** After M19 installation, the next feature
  is renaming an ordinary file within its folder, using an existing M19 verified revision.
  Preserve the original object and item ID; refuse collisions, changed sources and uncertain
  identity. Folder renaming, moves and unverified files remain outside the first scope. The
  [design](phase4-plan.md#m20-file-renaming) covers protected no-replace rename, recovery and a
  fresh disposable VM fixture. The user approved one write mode for all supported mutations,
  with a Read only toggle that defaults off for new locations. Existing read-only locations
  remain read-only. Signed VM Finder, conflict, interruption and preservation checks pass;
  see the [results](results/2026-10-29-file-renaming.md). Physical-Mac M20 behavior is unverified.
- **M19 online editing, accepted 2026-10-27.** The [safety design](phase4-plan.md#m19-online-editing)
  uses protected, no-replace renames through a recovery name, complete local pending copies,
  proven base revisions and conflict copies. The user accepted the temporary absence of
  the original pathname, internal file rename/cleanup and the limited libsmb2 expansion.
  The approved VM probe passed mixed native/direct staging and competing SMB access checks,
  but server-local access bypassed protection. The user accepted an SMB-only writer boundary:
  editing requires explicit confirmation that every writer accesses the folder through SMB.
  A different client transport does
  not fix server-local exclusion. Editor callbacks, metadata
  preservation and interrupted recovery were the next gates. The authenticated Apple SMB fixture
  does not expose security descriptors, and native SMB also misses an explicit backing ACL.
  The user approved a standalone Samba fixture and its test dependencies in VM 1.
  It exposes security descriptors, but competing SMB permission and named-stream changes
  bypass the proposed guard. The accepted SMB-only boundary does not cover this gap.
  Denying all sharing also permits those changes. That replacement route is rejected.
  The revised design below preserves the original object instead. The earlier temporary
  server, installation and test data were removed, with Apple's sharing settings unchanged.
  The revised M19 transaction and provider integration pass signed VM save and retention checks.
  The user reaffirmed Mac-only operation through the server's existing SMB service. The
  [revised design](phase4-plan.md#revised-mac-only-save-proposal), approved on 2026-10-28,
  keeps the original object, backs up its contents and updates it while temporarily renamed.
  Approval covers hidden content writes, longer unavailability, disposable transaction files,
  additional SMB operations and a fresh disposable VM fixture session. The
  [CLI protocol gate](results/2026-10-28-same-object-save.md) passed on the disposable Samba
  fixture, including private copies, ancestor protection, crashes and actual space exhaustion.
  Signed TextEdit saves, conflicts, interruption retention, local export and item/keep preservation
  pass. Partial work stays unresolved; fixture connection delays can defer retries. The disposable
  fixture and dependencies are removed, and original settings are verified. No server component
  or Save Edited Copy workflow is approved. See the [earlier gate](results/2026-10-27-edit-publication.md) for the
  rejected replacement sequence.
- **Safe upload publication, accepted for M18.** Use native exclusive creation, preserve complete local pending copies, and verify before acknowledging upload. Other devices can see partial new content. Never open an existing remote destination for writing. An uncertain interrupted attempt remains pending unless remote identity and complete contents prove success. See the [API results](results/2026-10-23-upload-publication.md).
- **Initial folder naming, accepted for M18 on 2026-10-23.** Finder creates an untitled folder, then sends a rename for the typed name. The callback and signed Finder checks pass. Native exclusive folder rename failed, and create/delete is unsafe under replacement races. An isolated direct SMB client passed no-overwrite rename checks. A limited `libsmb2` prototype is accepted for exclusive folder creation and initial naming, retaining server identity separately from native inodes. Corrected credential checks connected without a password, and signed naming and interrupted recovery passed on the disposable VM fixture. Folder renaming beyond initial naming stays deferred. See the [naming investigation](results/2026-10-23-initial-folder-naming.md). File Keep Both now passes the [signed follow-up](results/2026-10-25-keep-both.md). Enabled locations advertise rename capability so Finder can choose a new copy name. M20 also supports same-folder renames of verified ordinary files through its protected transaction.

- Physical Mac hardware, exact NAS/disk models, NIC/link topology, and physical-Mac SMB settings. VM/NAS telemetry now establishes 64 GB RAM, Samba 4.17.12-Debian, ext4/LVM/linear md storage and the negotiated VM SMB settings; see the cache report.
- Current competitor app versions and exact scripts/files used for the reported rates.
- Whether native bridge permissions/lifecycle are acceptable and whether direct SMB matches its speed. The approved app-owned reader resolves the immediate NAS access gate. Full downloads now exceed 90% in both verified NAS cache conditions. [Tracing](results/2026-10-11-provider-delay.md) places most recurring range-read delay after callback completion, waiting for a macOS database batch flush. Bounded read-ahead is now implemented and reaches 59.7% of native for long sequential reads; neither shipping readiness nor an unavoidable OS ceiling is established. The local cached-read gap to ordinary APFS also needs investigation.
- Which further players and opening routes use partial reads on macOS 27, and what coherence guarantee the server can support. The measured VM Finder launch routes downloaded the whole file first; the physical-Mac routes remain unrecorded.
- **Instant playback from Finder.** The user proposes keeping folders used mainly for playback on server volumes, with Finder aliases bringing File Provider locations and server volumes together for navigation; the [interface](ui-design.md), accepted for prototyping, keeps them in a Locations folder. A Finder alias test passed for both kinds of target. Server volume mode stays a later phase, by the user's decision. A server volume covers a whole share, so a server-volume "folder" means a mounted share plus an alias into it.
- **Synchronization between views.** Proposed in [synchronization.md](synchronization.md). The user wants this model settled before any overlap guard. It covers changes made through a server volume or another device while a File Provider location holds metadata or downloaded copies, and later two-sided writes.
- **Read-ahead tuning.** Seeks come first, as the user asked. On October 15, under the user's authorization, the window became one 16 MiB chunk after the [comparison](results/2026-10-15-read-ahead-window.md): 0/11 stress failures against 5/5 at 128 MiB, the same IINA playback and seeks, and 45.2% of native for sequential partial reads. Throughput-first settings reached 59.7% on October 11 but let seeks wait. Repeat on the physical Mac; the system race is avoided in these trials, not proven gone.
- **Failed-folder recovery.** Supported directory materialization restored children but left Finder’s error banner. No complete automatic recovery is verified. A notification explaining Try Again is proposed only; adding it or submitting an Apple Feedback report requires the user’s approval.
- Product deployment floor and distribution signing. The current macOS 27 experiment now runs with the configured Personal Team and a team-prefixed macOS App Group; production signing/lifecycle remains undecided.

No NAS credentials are needed to review this plan. For the experiment, a read-only test account/share and a representative large video/file are enough; the user can connect it in the VM or enter credentials into the app instead of placing secrets in chat. Writes and deliberate server disruption will need a dedicated scratch area and explicit test scope. The VM is appropriate for correctness work; its virtual NIC/storage cannot establish the physical Mac's absolute speed.
