# Architecture proposal

The [accepted SMB simplification](smb-simplification.md) replaces custom remote recovery and
content proofs. Read-performance targets remain unmet.

Decision status: production architecture proposed; File Provider, cache ownership, the metadata architecture and the direct SMB transport are selected (§2), and the user set the phase order (§10). Full downloads exceed 90% of native speed in verified NAS-cold and NAS-cached states; sequential partial reads don't yet. Source references resolve in [research.md](research.md).

## 1. Product contract

The first useful milestone is a file-system location backed by the user's SMB share, tested first in Finder. Users can browse, open, stream supported media, download files, and select **Keep Downloaded** for reliable offline reading. The NAS remains the source of truth. No NAS agent, cloud relay, TinyMounter account, kernel extension, or FUSE installation is required.

The user selected offline reading first. This plan recommends making the initial provider entirely read-only, including while online, to validate the central performance proposition before implementing uploads. Users can copy a file out to edit locally. The user later moved writes ahead of release hardening (§10). Online editing is not a trivial intermediate step: a local save can race with loss of connectivity, so it also needs durable pending-write handling.

Initial validation targets macOS 27 and the user's UGREEN hardware running Debian with 64 GB RAM. The cache-controlled experiment ran against Samba 4.17.12-Debian, ext4 on LVM over linear md storage, and SMB3.1.1 with AES-128-GMAC signing and encryption off. Broader OS support and other NAS implementations come after feasibility. The core range API exists from macOS 12.3 and content policies from macOS 13; recursive namespace pinning has a macOS 27 API [A1–A4].

Two explicit modes share the same connection setup:

| Mode | User-visible storage | Offline behavior | Delivery |
| --- | --- | --- | --- |
| File Provider location | OS-managed location, normally under `~/Library/CloudStorage` | Materialized local files; selected files/folders pinned | First |
| Server volume | Normal macOS SMB volume | Requires server connectivity; kernel caching is not a durable offline replica | Since 0.1.2 |

The modes have different paths and semantics. Do not silently change a File Provider location into a server volume when the network changes. Use one mode per server/share across saved accounts. Remove existing locations before switching modes. Native volumes have no File Provider domain or catalog; server permissions govern writes.

## 2. Architecture decisions

| Area | Proposed decision | Reason / gate |
| --- | --- | --- |
| macOS integration | `NSFileProviderReplicatedExtension` plus `NSFileProviderPartialContentFetching` | Native integration with Finder and other file managers, local APFS materialization, offline reads, range requests |
| Implementation | Swift app and core libraries; SwiftUI/AppKit where appropriate; C interop for a direct SMB library | Small native macOS application; no UI runtime in the byte path |
| First transport prototype | Native SMB mount, read using POSIX APIs | Held the SMB implementation constant against Finder to isolate integration cost; replaced by the direct transport |
| Selected SMB transport | Direct `libsmb2` for sign-in, remote I/O and change notification; NetFS mounts only for Server Volume | Adopted after the single-client experiments; the File Provider mount was removed in 0.2.0; distribution and performance gates remain |
| Metadata | Per-domain SQLite database in an App Group, WAL, short transactions | Stable identities, directory snapshots, ordered changes, pins, restart recovery |
| Downloaded content | OS-managed materialized files; short-lived staging in the provider's temporary directory | Avoid an unnecessary second permanent content cache |
| Credentials | One generic-password item per server in the login keychain, service `dev.tinymounter.smb` | Separate connection records by account; never put passwords in URLs, settings, logs or process arguments |
| Distribution | Signed development builds first; Developer ID/notarized beta proposed | Prove real extension behavior and entitlements early; App Store remains a separate packaging gate |
| Server Volume mounts | NetFS with the saved password; `NWPathMonitor` plus actual mount results (§9) | Native mounts and reconnection without inventing a filesystem |

File Provider, cache ownership, metadata architecture and the direct SMB transport are selected.
Parts of §4 and §5 describe the earlier native-transport design and its measurements.

## 3. Components and ownership

**TinyMounter.app** owns sign-in with its own sheet and Keychain item, domain registration, pin controls, connection status, diagnostics, and native-volume connection controls. One File Provider domain represents a particular share/subfolder and authenticated account. Domain identity is stable across app restarts and reconnections.

**Saved connections.** Servers and
shares are separate records. `Settings.json` holds a server's protocol, host and account and a
share's name; it holds no password and no bookmark. The app keeps each server's password in its
own Keychain item and signs in with NTLMSSP; there is no guest login. Shares are added only
through a location and stay saved after their last location is removed. Servers lists them;
Forget deletes an unused share, or a server with its shares and its password. Earlier settings
are refused, and Start Fresh replaces them ([§5](#sign-in-and-connection)).
Keep Downloaded lists hold typed file and folder requests.

**TinyMounterFileProvider.appex** owns the File Provider callbacks: item lookup, paginated enumeration, working-set changes, full and partial fetches, cancellation, progress, and error translation. It must work when the settings window is closed. Cached reads must not depend on the app being alive. Do not remove/re-add domains to implement reconnect.

**Processes.** The main app owns every connection to the share. This started because Network
Volumes privacy denied the extension access to the NAS mount; the app now also holds the password
and runs the only SMB client.

| Process | Owns | Never |
| --- | --- | --- |
| `TinyMounter.app`, a sandboxed app with a Dock icon and a menu bar item | settings, sign-in and saved passwords, SMB sessions and change watches, all share I/O, every catalog write, domain add and remove, staging files, relisting, notifications, UI | logs names or paths |
| `TinyMounterFileProvider.appex`, one process per domain | File Provider callbacks, catalog reads, staging handoff, per-item read-ahead, Finder actions | connects to the share, creates or writes a catalog |
| `fileproviderd` | the replica, materialization, Finder integration | — |

The extension vends a restricted `NSFileProviderServiceSource`; the app connects through its
domain manager and exports a reader over duplex XPC, only for domains whose catalog it opened.
Both peers require the same signing team and the exact counterpart bundle ID. Requests carry item
IDs, content versions and ranges, never a pathname. Payload bytes are never serialized across XPC
[A9]. Both ends ship in one bundle and domain IDs are never reused, so the XPC protocol has no
version handshake. No separate helper or daemon exists.

The main flows:

1. **Browse.** `enumerateItems(folder)` → XPC `list(folder)` → the app lists the folder over SMB →
   `Catalog.reconcile` in one transaction → a reply with counts → the extension pages from the
   catalog. If rows changed, the app signals `.workingSet`, debounced by 200 ms.
2. **Read.** `fetchPartialContents` or `fetchContents` → catalog row and strict version check →
   XPC `fetch(item, version, range)` → the app builds the path from its catalog, compares the
   server file's fingerprint with the row and stages the bytes in the App Group → the extension
   renames the staged file into `temporaryDirectoryURL()` and completes.
3. **Keep.** Finder action → `performAction` → XPC `keep(ids, value)` → the app sets the explicit
   request and inherited retention, with new metadata sequences, and signals `.workingSet`. Kept
   folders report eager namespace policy and kept files `.downloadEagerlyAndKeepDownloaded`, so
   the system's full fetch takes flow 2.
4. **Recovery.** When a share becomes healthy again, the app calls `signalErrorResolved` for each
   error that its requests returned, retries pending creates, renames and deletions, signals
   `.workingSet` for each domain on that share and starts flow 5. When a reader session connects,
   the app does the same for that domain with `.serverUnreachable` only, and does not start flow 5.
5. **Relist.** At launch and after each recovery, the app reads each domain's materialized set
   with `enumeratorForMaterializedItems` and lists each materialized folder again, one at a time,
   except the system's own Trash folder. The system never enumerates a materialized folder again
   by itself, so relisting only those folders keeps the NAS load in proportion to what is on this
   Mac.

The app signals only `.workingSet`: replicated domains ignore other containers
(`NSFileProviderManager.h`).

**Restart after a crash.** The extension starts the app again after a crash, and only then. The
app keeps its run state (`running`, `stopped` or `crashed`) and its launch time in `RunState` in
the App Group. `applicationWillTerminate`, which runs for Quit, logout and shutdown, writes
`stopped`. A handler for SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT and SIGFPE writes `crashed`
with `pwrite` to a descriptor opened at launch, resets the signal to its default action itself and
raises it again, so the crash report stays the same; macOS ignores `SA_RESETHAND` for SIGILL and
SIGTRAP. Force Quit and a kill for memory leave `running`, so nothing restarts the app. When an
extension starts or loses the app's reader and reads `crashed`, it waits until Launch Services no
longer lists the crashed app, up to 5 s, then opens the app without activating it. If the app
crashed less than 60 s after its launch, the extension does not restart it, so a crash at launch
cannot loop.

The app must remain running for cache misses and for folders that were never listed; cached reads and listed folders work after it quits. Full app-independent fetching and shipping lifecycle are still gates. The first reader experiment verified NAS access and checksums but had a large throughput gap; it did not select the production transport.

A location with Read only on advertises no create, rename, move or delete capability and read-only POSIX permissions, and the extension and the app both refuse its create, modify, delete and rename callbacks with `fileWriteNoPermission`. Enforcement does not depend on hiding UI controls, and the account's permissions on the server still apply. Files keep the File Provider write capability so that copies made from them are not immutable. Only a reimport `createItem`, which is identity matching, completes with the existing item.

**TransferCore** contains domain records, metadata reconciliation, version mapping, scheduling, pins, and the transport-neutral contracts. Its interface is specific to SMB's needs; there is no universal protocol framework before a second protocol exists.

**SMB transport** implements the `RemoteSession` and `RemoteWatcher` interfaces (§5): sign-in, listing, metadata, ranged reads, writes and change watches. Change watches complement reconciliation. Calls carry cancellation, priorities, version context, and byte-progress reporting. Keep the data path off the main actor and separate from serialized metadata writes.

**Per-user background component**, if needed, owns long-lived change watches and later automount. Registration and actual lifecycle must be tested. The File Provider process can be suspended or restarted, so perpetual sockets in the extension are not a sufficient background-refresh strategy. Driio's release notes report this exact lifecycle issue [D2]. A background watcher is an optimization: on-demand fetch and reconnect reconciliation must work without it.

**Code layout.** [AGENTS.md](../AGENTS.md#where-things-are) lists the folders. Shared code goes into the `TransferCore` package target: Xcode compiles sources directly into each app target, so a second module would add entries without isolation. The package deploys on macOS 27, like every Xcode target, because `O_NOFOLLOW_ANY` and `O_RESOLVE_BENEATH` have no availability annotations. The C adapter over libsmb2 is in `Prototype/SMB`, and libsmb2 itself in `Vendor/libsmb2`.

## 4. First-read and streaming path

1. Finder or an application accesses a placeholder. macOS invokes the provider for the requested content.
2. Resolve the stable item ID and requested content version. Connect or reuse an authenticated SMB session/handle.
3. For a range request, honor the OS's **runtime alignment**, minimum range, requested version, and strict-version flag. Fetch an aligned extent covering the request. Handle empty files, end-of-file ranges, overflow, and cancellation explicitly.
4. Pipeline bounded SMB reads into a regular, potentially sparse staging file on the same volume as the user-visible file. The current app-owned reader first writes in the shared App Group, then the extension moves that file into `NSFileProviderManager.temporaryDirectoryURL()` before completion. Cross-volume moves fail; there is no copying fallback. Bytes go at their original offsets; the file must reach at least the returned extent's end [A2]. Stage files that a crash leaves are deleted at app launch, before any reader connects, and by each extension process for files created before it started.
5. Complete with the item/version, staging URL, exact fetched range, and appropriate flags. Never mark holes as downloaded zeros. Once handed off, do not mutate the file: macOS clones and unlinks it [A2]. While the app reads, it reports the bytes done at most every 0.5 s, and the extension updates the fetch's progress. Once the app starts the transfer, the extension ends its wait after 60 s with neither progress nor a reply, not after an absolute 300 s, so long healthy downloads go on and time queued for an app worker is not a stall.
6. macOS resumes the application's read. Later reads of materialized content use local storage without going through SMB or the extension [A3].

Do not wait for an entire video to download before completing a small requested range. Conversely, do not return before the promised extent is present. Use larger extents for sustained sequential access and small prioritized extents after a seek. Coalesce duplicate in-flight requests for the same version/range; each completion needs correct staging-file ownership, not a shared URL that the OS may unlink.

Initial experiment grid: 256 KiB, 1 MiB, and 4 MiB SMB requests, subject to negotiated limits; 1/4/8/16 in-flight requests; provider extents from 1–16 MiB, always respecting the requested minimum/alignment. These are tuning candidates, not constants to hard-code. Account for SMB credits and bytes in flight. A synchronous read loop with small chunks can waste most of the network's capacity.

Tracing found a recurring database-flush wait after handoff. Returned extents of 64/256 MiB raised throughput, but first-byte delay and overfetch grew, so the prototype default remains 16 MiB. A full-download attribution separated source transfer, callback time and macOS materialization. Full downloads exceed 90% of native in the VM, with the NAS file on disk and in NAS RAM; this answers the full-download throughput question on the VM. Bounded read-ahead raises sequential partial reads, but seek-first settings, which the user asked for, keep them far below native. The range-read gate still fails.

The user distinguishes two workloads. **Open** should prioritize the ranges an application needs to begin displaying content or resume a seek; these need not be at the beginning of the file. **Download / Keep Downloaded** should fetch the entire file efficiently, with completion and retention tracked separately. The current full callback already streams the whole source into staging in one request, using bounded memory. Honor the actual full-versus-partial request rather than assigning behavior solely from a filename extension. Some applications require full materialization even when the format permits partial access [A1].

**Bounded read-ahead, implemented experiment.** Cache hits produce no callbacks, so the extension sees only misses. A miss that continues the previous miss of the same item schedules speculative ranges for that item through public range-download requests [A10]. Read-ahead state is per item: up to 8 planners, by item and content version. Speculative completions never extend the window, and a seek makes only its own item's earlier requests stale. The first miss and any seek fetch only the 16 MiB demand extent.

The user prioritized seeks during streaming. `fileproviderd` holds a waiting seek for as long as speculative requests keep arriving back to back. One 16 MiB chunk is in flight at a time, with a 30 ms pause before each chained request, and the window is one chunk: speculation stays 16 MiB past the latest sequential miss. A 128 MiB window let a moving-boundary stress reader trigger the system materialization race; the one-chunk window avoided it, with the same IINA playback and seeks. Throughput-first settings (64 MiB chunks, a 1 GiB window) read faster but fetch more and let seeks wait over a second. Continuous whole-file downloading remains a separate policy choice. The app's reader host also fetches the next extent while the current one materializes, keeping the extension policy unchanged. Read-only views then meet the partial-read and seek targets. Writable views reach about 0.73 of native, because `fileproviderd` takes longer per 16 MiB fault there; capability, POSIX-flag and extent-size changes did not help.

Prioritize foreground reads and seeks over background pinning and metadata crawling. Bound aggregate buffers per domain and globally; target no more than 256 MiB of transfer buffers for the initial one-stream experiment. Avoid full-file memory buffers, per-chunk database commits, and an `fsync` after every network read. Preserve the handoff and future write durability contracts.

**Application limitation:** Apple states that partial downloads require suitable POSIX reads. Whole-file clones or reads using file coordination request the entire file [A1]. Implement full fetch as well. Supporting the range protocol does not guarantee streaming in every app, and a custom player is outside this product's scope. Measured on macOS 27 in the VM:

- **Finder:** in the measured VM configurations, double-click, Open With and Cmd-O made a coordinated whole-file read before handing the file to an app. Content downloaded fully before playback started. On the physical Mac, playback used partial reads, but the opening routes were not recorded.
- **Opt-out:** Apple's `NSFileProviderExtensionNonMaterializingProcessNames` [A2] stops the download, but Finder then silently refuses to open the file, so Finder isn't listed. Only `ScopedBookmarkAgent` is: resolving an app's recent-file bookmarks otherwise downloads each whole file.
- **VLC:** streams with partial reads when opened from its own File > Open or from `open -a`.
- **QuickTime Player:** always downloads the whole file.
- **IINA:** streams with partial reads from its own Open, after the extension began clipping IINA's end-of-file reads that run past EOF.
- **Quick Look:** shows only a generic icon for a file that isn't downloaded, and fetches nothing.
- **TextEdit, Preview and Xcode:** ordinary saves work in writable locations. Other editing
  applications are unverified.

## 5. Native SMB versus direct SMB

### Native bridge

Create an app-owned read-only mount with public NetFS APIs; `MNT_DONTBROWSE` can hide it from ordinary browsing but is not a security boundary. Reuse Apple's SMB client, negotiated security, and supported multichannel behavior. Read via `pread`/equivalent into APFS staging. A bare SMB path or symlink cannot substitute for materializing a File Provider file.

The first diagnostic can use a user-mounted share with deliberately granted access. A shipping implementation must additionally prove automated mount ownership, extension sandbox access, credential isolation, logout/reboot behavior, and disconnected-I/O containment. Test a signed installation on a clean user account. Do not assume the extension can access arbitrary mounts, or that an embedded XPC service automatically escapes its sandbox.

If a separate per-user helper is required, establish supported sandbox-to-helper access and authenticate the IPC peer. No private SMB APIs or broad sandbox bypass is part of the design. A helper timeout does not magically cancel a blocked kernel read; measure real recovery. Do not force-unmount a share used by another application, and never reuse/unmount an unrelated user mount merely because its pathname matches.

### Direct asynchronous SMB

`libsmb2` is a plausible candidate: it exposes asynchronous high-level and raw APIs, SMB2/3 signing/encryption, and pipelining opportunities [L1]. Build the measured version from pinned source and use a thin Swift adapter. AMSMB2 is a useful reference, but a convenient Swift async API alone does not prove deep per-file pipelining. Audit scheduling, copying, cancellation, and credential/session reuse.

Separate latency-sensitive metadata from bulk reads; pool authenticated sessions only when measured beneficial. Scope a pool by server, share, account, and security policy. Multiple connections/files are not the same as pipelined reads of one large file, nor are they automatically SMB Multichannel. Verify leases, reconnect behavior, authentication, negotiated read size/credits, and server compatibility rather than assuming parity with Apple's client.

`libsmb2` is LGPL-2.1-or-later. Dependency selection must include notices/source obligations, linkage and user-relinking requirements, and signing/distribution compatibility. The wrapper's MIT license does not erase its bundled library's obligations [L1–L2]. Complete that review before committing to a distribution build.

`libsmb2-6.3` is the adopted client for remote listing, metadata, reads and writes. The app
embeds it as a separate dynamic library. Since 0.2.0, File Provider locations use no mount,
because third-party file managers listed the hidden one. The app signs
in with the server's Keychain password, opens an SMB session for each operation, keeps one
`CHANGE_NOTIFY` connection per share with at most 64 watches, and judges each share's health from
the results of its calls. Authenticated
mutations require encryption. The library source and licence are in `Vendor/libsmb2`; the
personal-use release includes the complete source, notices and [rebuilding instructions](release.md#rebuild-and-replace-the-library).

The [simplification audit](smb-simplification.md) removes full-content proofs and remote save
transactions. Each operation owns its connection and credentials. A small lock protects only
library context creation/destruction; independent connections can transfer concurrently. Read
and write requests are capped at 1 MiB, negotiated server limits and available credits. One
request is outstanding per connection; pipelining and session pooling are not implemented.

New uploads use exclusive creation. An acknowledged partial upload restarts the complete write
only after matching the recorded server identity; an uncertain create never overwrites an
unrelated destination. macOS sends a new item again when its contents change before the upload
finishes, for example when it took a file that an app was still writing. The new contents then
replace the retained copy, and an acknowledged partial file is written again with them. Listings
leave out a file that a pending upload is still writing, so it never appears beside the local
item. Stop Uploading deletes such a file after matching its recorded identity, so that an upload
that macOS no longer sends can be settled. Local retained contents have integrity checks, but the remote upload is
not read back in full. Existing-file saves use ordinary overwrite semantics. Creates and saves run
one at a time on the share's lane, and the share's namespace lock covers their checks, the server
create, a save's catalog update and the final listing; the contents are written outside the lock,
so reads and listings in the share don't wait for the transfer. Listings run beside the lane under
the namespace lock. A listing keeps the row of a file that an upload or save is writing as it is,
and lists the folder again when the write ends. While a rename, move or deletion is unsettled, or
a folder move holds the folder, the listing waits on the lane instead. macOS itself shows new
server items only after the domain's running upload of a new item ends: fileproviderd holds the
fetch of an unknown item until the create job finishes. Edits and deletions of known items show at
once, as do new items while a save of an existing file runs.

### Sign-in and connection

One protocol-neutral layer, declared in
[`RemoteConnection.swift`](../Sources/TransferCore/RemoteConnection.swift), carries sign-in,
connection state, listing, reading, writing and change watching. SMB is its only implementation,
and nothing in it is built for a second protocol. `RemoteClient` lists a server's share names,
opens a `RemoteSession` for one operation and opens a `RemoteWatcher` for change notices.
`CredentialStore` saves and reads passwords. Errors stay `SourceFailure`: a refused account or
password is `notAuthenticated`, an unknown share `missing`, and a share that the account may not
open `noPermission`.

The app keeps one `ShareConnection` per saved share. It opens a session for each operation and
records each result in `ConnectionHealth`, whose states are not connected, connected,
unresponsive and needs sign-in. Probes back off from 5 s to at most 60 s and start at once on wake
or when the network path returns. Without a network path, requests fail at once with
`notConnected`. Proofs that need a stable location folder compare its server identity
(`directoryIdentity`); there is no mount identity.

Rules that the connection keeps:

- **No repeated failed logins.** Each operation opens its own session, so a wrong password would
  otherwise fail once per request and could lock the NAS account. The first `notAuthenticated`
  enters needs sign-in, which refuses every request for that server without I/O until a new
  password is saved. Only `STATUS_LOGON_FAILURE`, `STATUS_PASSWORD_EXPIRED` and
  `STATUS_PASSWORD_MUST_CHANGE` do this, because a new password fixes them. libsmb2 reports a
  logon failure as `-ECONNREFUSED`, so classification reads `smb2_get_nterror()`. A locked or
  disabled account is `noPermission` and also stops retries until the user acts.
- **The password stays out of everything else.** It never reaches `Settings.json`, logs, process
  arguments, URLs or XPC, and the extension never reads it. It goes from the Keychain bytes to C
  without a Swift `String` and is read again for each connection; the vendored
  `smb2_clear_password()` zeroes libsmb2's copies right after connect. Logs name servers and
  shares by record ID only.
- **The Keychain item** is a `kSecClassGenericPassword` item in the login (file-based) keychain:
  service `dev.tinymounter.<protocol>`, account `<account>@<host>` with the host in lowercase,
  not synchronizable, with no new entitlement. The data protection keychain needs a provisioning
  profile, which the Personal Team build lacks, so the login keychain stays until a paid
  membership provides one. A generic-password item never matches Finder's internet-password item
  for the same server, so a read never returns Finder's password and Forget never deletes it.
- **SMB 3 only**, with signing and encryption required and no guest session: the vendored libsmb2
  refuses every guest session and treats an `ntlm:<hex>` password as an ordinary password
  ([Vendor/libsmb2](../Vendor/libsmb2/README.md)).
- **A dropped session is ended by the next one.** When a request fails with the connection (reset,
  timeout), the session closes for good and the share remembers its ID. The share's next
  session sends one such ID as SESSION_SETUP's PreviousSessionId, oldest first, so the server ends
  that session and closes its open files at once instead of when it notices the lost connection.
  Only sessions that TinyMounter opened and never uses again are named; Samba honours it for the
  same user only. The IDs stay in `Application Support/tinymounter/PreviousSessions.json` in the
  app's container, so the next run names them too. When the app quits, including at logout,
  restart and shutdown, its open sessions are added, because a network loss at that moment leaves
  them on the server. A Force Quit or crash adds none. Removing a share removes its IDs, and an
  unreadable file is logged and ignored.
- **Transient upload failures retry by themselves.** A create or save that fails with the
  connection, a timeout or a sharing violation (`ETXTBSY`) is retried through the location's Retry
  Pending Changes: at once when the share's recovery runs, otherwise after 2 s, doubling to at most
  5 minutes while such failures recur, and no longer once none is left. Other failures, such as
  Read only, a name collision, a refused permission, a full disk or an edit conflict, still wait
  for the user.

### Selection rule

Keep the native bridge if it meets the throughput gate and works cleanly under the shipping permissions/lifecycle model. Prefer direct SMB if it is comparably fast and materially simpler to deploy/recover. If direct SMB is slow while native-backed File Provider is fast, optimize or replace the SMB transport. If both provider paths are slow but their staging controls are fast, investigate provider scheduling and materialization. Do not switch frameworks solely because one first implementation is slow.

## 6. Offline retention and pinning

Distinguish these states in product language:

- **Online only:** metadata exists; content needs the server.
- **Partially downloaded:** some ranges are local; arbitrary offline reads cannot be promised.
- **Downloaded:** complete local copy, available offline while retained; the OS may evict it under pressure.
- **Keep Downloaded:** fully materialize and apply the keep-downloaded policy. Claim offline readiness only after completion.
- **Downloading / unavailable / permission needed:** explicit progress or actionable error, not a permanently spinning mount.

A kept-downloaded file stays readable while the NAS is unreachable, with the app quit or running.

Use `NSFileProviderContentPolicy.downloadEagerlyAndKeepDownloaded` for pins. On macOS 27, combine it with `NSFileProviderNamespacePolicy.materializeEagerly` for pinned folders so unvisited subfolders also enumerate. Track pin intent separately from observed hydration status. Earlier-OS support, if later added, needs a deliberate bounded recursive enumeration strategy [A4].

Folder pinning has a byte/item budget, free-space reserve, progress, and cancellation. M16 implements a shared 2 GiB local reserve with conservative staging/handoff reservations and retry after space returns. The reserve is an admission policy; other processes can still consume local space.

**Download space.** One app-owned budget covers concurrent requests across locations. Admission needs room for twice the requested payload plus 64 KiB of metadata, for staging and the provider handoff, counting range payload bytes rather than a sparse file's logical end. Reservations last until release, and written staging bytes reduce them. The app checks capacity again every 16 MiB, reading fresh available capacity without assuming that macOS will purge other data. Missing capacity fails the download, and a disk-full error crosses XPC as Cocoa's `fileWriteOutOfSpace`, never as a remote or connection failure. While the app runs, it checks blocked kept files every 30 s and requests their download through File Provider's public API once their payload fits with another 64 MiB of headroom; `signalErrorResolved` does not cover local disk-full errors. A paused, disconnected, disabled or removing location is not retried. Blocked requests are saved in `BlockedDownloads.json` in the App Group, with opaque IDs, versions and ranges only, and each retry checks the current keep intent and source version.

**Folder keeps.** The catalog stores each explicit request separately from effective retention. A parent listing that reports a changed child folder makes that child's earlier complete listing incomplete; its next connected enumeration serves cached pages and lists it in the background. Folder status stays unconfirmed until a complete listing is observed. Configurable folder budgets remain planned. Never label a budget-limited or failed tree fully available offline. Retain complete already-downloaded files during a network outage. A sparse file's apparent logical size does not prove offline availability. Remote changes and partial materialization need version-aware invalidation, not unconditional removal of every local copy on reconnect.

The OS owns the main content cache. TinyMounter owns temporary transfer files and their crash cleanup, metadata, and pin policy. Cache limits are best-effort controls over evictable content, not a promise of an exact private cache size. Never edit the OS's internal File Provider database or cache directories directly.

Disconnecting, disabling refresh, removing a connection, and deleting remote files are different operations. Domain removal must preserve downloaded files or pending data according to the documented removal mode and the user's explicit intent; it must not be used as routine repair [A5]. Deleting remote files is a separate, explicit user action (§8).

## 7. Identity, versions, and change discovery

Use a persistent opaque UUID as `NSFileProviderItemIdentifier`. Paths change on rename and should not be primary IDs. Map it to domain/account, parent ID, remote name/path, supported remote identity evidence, and metadata. Do not mistake an open SMB handle's FileId for a universally persistent cross-reconnect object ID. Test server-provided identity stability across rename, replacement, reboot, and reconnect. After an eject and reconnect of the Finder mount, inode, size, mtime and ctime stay the same, while `st_dev` and `f_fsid` change. So content versions leave out the device. Rename, replacement and server reboot are not tested. The app keeps one SQLite catalog per domain in the App Group: UUID item IDs kept by parent, name key and kind; content versions `f1:<size>:<mtime_ns>:<ctime_ns>`; sync anchors over a durable change sequence; keyset page tokens; and tombstones written only by a complete listing ([Catalog](#catalog), [Enumeration](#enumeration)).

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

File Provider sync anchors are ordered cursors over TinyMounter's durable change log, not wall-clock timestamps or SMB notification sequence numbers. Commit item changes and log entries atomically. Advance an anchor only through changes actually delivered, including tombstones. Expired anchors trigger a supported full resynchronization. Test pagination with interleaved additions, renames, and large deletion batches.

Watch active/materialized directories with SMB `CHANGE_NOTIFY` where supported; reconcile on wake/reconnect, on access when stale, and periodically with backoff. Notifications are invalidation hints, not a durable history of everything that happened offline. Fall back if a server accepts watches but never delivers them. Do not recursively poll millions of files at a fixed short interval or rely on local FSEvents to discover every remote SMB change. Pinned trees get bounded scheduled scans. Up to 0.1.2, M15 used public Dispatch vnode sources on the native SMB mount [C1, C2]. Since 0.2.0, each share has one `CHANGE_NOTIFY` connection with at most 64 non-tree watches, one per folder. It monitors listed materialized and kept folders, and parents of kept files. Periodic reconciliation covers missed events. A successful listing is due again after 60 s; one automatic listing runs at a time with a one-second gap, so larger sets take longer. Failures back off to at most 240 s. Wake requests refresh, and launch/recovery reconciliation and per-fetch fingerprint checks remain. It never walks unvisited unkept trees. See [Change watching](#change-watching).

**Version coherence is a separate feasibility gate.** Plain SMB usually exposes mutable files, not retrievable immutable revisions. Size/mtime/change-time fingerprints are useful change evidence, not cryptographic version IDs. They may miss timestamp-preserving modifications. Never combine ranges after detecting a version change; use Apple's strict-version failure (`versionNoLongerAvailable`) and let the system refetch/retry.

For ordinary files, validate identity/version at open and after fetching, and keep a stable handle while reading. Validate behavior when other SMB clients write or replace the file. Reliable immutable snapshots, or a tested server-enforced exclusion strategy, provide stronger guarantees. Holding a deny-write/delete handle for an entire partially cached session can interfere with other users and does not survive every restart. If a server cannot uphold the supported consistency contract, disable partial fetch for that case and use a full fetch under a tested stable-read mechanism; if even that cannot obtain consistent content, fail/retry rather than publish known mixed content. Do not claim perfect snapshot semantics for arbitrary external modifications without server support.

### Read and save verification

The [accepted simplification](smb-simplification.md) removes full-content verification from
reads and saves. A read checks the catalog fingerprint against the opened server file, transfers
the requested bytes and checks metadata again before handing them to File Provider. Incomplete
ranges fail. Writable and read-only locations use the same read path.

A save writes directly through an SMB handle, sets the final length, flushes and closes it.
The File Provider callback completes only after that succeeds; macOS retains failed uploads.
Previous-version recovery belongs to NAS snapshots/backups. There is no remote
stage/backup/work transaction, persistent edit base or read proof.

### Catalog

Each File Provider domain has one SQLite catalog, `Catalogs/<domain ID>.sqlite` in the App
Group. The app creates it before `NSFileProviderManager.add`, and creation fails if the file
exists; the app deletes it after the domain is removed. The app is the only writer, keep requests
included, so no process waits for another's write lock. The extension opens the catalog with
`SQLITE_OPEN_READONLY`, and neither open ever creates one. Both opens check the `meta` row, the
epoch, the domain, the counters and a live root folder with no parent. Any failure is "catalog
unavailable", so damage never crashes the writer or expires every anchor. The catalog uses WAL;
the writer adds `synchronous=FULL` and `fullfsync=ON`, because delivered anchors must survive
power loss and a plain `fsync` does not flush the drive's cache. Writes use `BEGIN IMMEDIATE` and
never hold share I/O inside. The schema is in [`Catalog.swift`](../Sources/TransferCore/Catalog.swift).
It has no schema version and no migration: a catalog with an earlier schema fails to open.

**Item IDs.** A `UUID().uuidString` is assigned the first time a complete listing shows a live
`(parent_id, name_key)` that has no row. IDs hold no names, because they can appear in system
logs. The same parent, name key and kind keep the ID across relistings, restarts and
reconnects. A case-only rename keeps the ID and stores the new exact name. A kind change
tombstones the old row and inserts a new ID, because File Provider does not support type
changes. Any other external change, including a NAS rename or move, is delete plus create; the
SMB file ID is stored only as evidence. TinyMounter's own renames and moves keep the ID (§8).
Two locations on the same folder have separate catalogs and separate IDs.

**Name collisions.** A case-sensitive NAS can hold names with the same name key. The existing
name wins: a live row pairs with the listed name whose exact bytes equal its stored name. Only if
no listed name has those bytes is it a case-only or normalization-only rename, and the first name
in byte order wins once the stored name is confirmed absent. A key with no live row takes the
first name in byte order. The other names are skipped and counted, and a row is never tombstoned
as missing while any name with its key is listed.

**Versions and cursors.** A file's `contentVersion` is `f1:<size>:<mtime_ns>:<ctime_ns>`; folders
use `d1`. The device and inode stay out, because they change with each connection and every copy
would download again. `metadataVersion` is the row's `change_seq`. No cursor holds a name:

| Cursor | Bytes | Content |
| --- | --- | --- |
| Sync anchor | 25 | `0x01`, epoch (16), `change_seq` (Int64, big-endian) |
| Folder page | 9 | `0x02`, last row (Int64); the next page reads that row's immutable `enumeration_key` |
| Working-set page | 9 | `0x03`, last row (Int64) |

Folder pages use keyset paging in name order. The immutable enumeration key keeps a cursor valid
across reconciles and renames. `OFFSET` paging with `pageExpired` was rejected: that error makes
the system synchronize again from scratch.

**Writers.** Rows are never removed: a tombstone sets `deleted`, from a complete listing or a
settled TinyMounter operation. Every visible change takes
`last_seq + 1`, so a change batch can never end inside a group of equal sequences. Tombstones stay
for the catalog's life, which is the domain's life.

### Enumeration

`enumerator(for:)` does one primary-key lookup and no share I/O:

| Identifier | Result |
| --- | --- |
| `.workingSet` | working-set enumerator |
| `.trashContainer` | an empty enumerator |
| root, or a live folder | folder enumerator |
| a live file | item enumerator: that one item, because the system enumerates single documents |
| a tombstone | throws `noSuchItem` |
| an unknown ID | an enumerator whose calls fail with `CocoaError(.fileReadUnknown)` (transient) |
| catalog unavailable | throws `serverUnreachable` |

**First page of a folder.** A folder listed before comes from the catalog at once; if its listing
is older than 60 s, the extension also asks the app to list it, and differences arrive through the
working set. For a folder never listed, the extension asks the app to list it and waits at most
5 s; listings do not queue behind a transfer on the share's lane. At the deadline it finishes with `serverUnreachable`; the app finishes the listing, and the
extension calls `signalErrorResolved` when the late reply succeeds. A reply carries the folder's
listing generation, and the extension serves the page only if its own connection sees at least
that value. With no reader, a never-listed folder fails with `serverUnreachable` at once.

**Pages and changes.** Pages hold `suggestedPageSize` rows, or 200, at most 1,000; later pages
never call the app. A malformed token, or one whose row is not a child of the folder, gives
`pageExpired`. `enumerateChanges(from:)` reads rows with `change_seq` above the anchor in one read
transaction: live rows go to `didUpdate`, tombstones to `didDeleteItems`, and each tombstoned
descendant has its own row. A full batch finishes at its last sequence with `moreComing`;
otherwise the batch finishes at `last_seq`, so an up-to-date client gets its own anchor back. An
anchor expires only if it is malformed, has another epoch or is above `last_seq`.

### Listing and reconciliation

A listing reads a folder over SMB and commits whole, in one transaction after it completes;
streamed batches would let the system see children of a folder whose listing is not complete.

1. The app lists every entry of the folder. If the folder's identity or times change during the
   listing, it starts again, at most three times; then the listing is incomplete. More than
   100,000 entries fail the listing. Nothing is written for a failed listing.
2. Entries that are not regular files or folders (reparse points, such as symbolic links, and
   devices), invalid names and name-key collisions are skipped and counted. An entry whose
   attributes can't be read leaves its row as it was: its name proves that it exists, so it does
   not fail the listing.
3. For each live child that the listing lacks, the app lists the folder again. Only a second
   listing without it confirms the absence; a name that is still there gives `listingIncomplete`,
   and the folder is listed again later.
4. `Catalog.reconcile` inserts new entries, updates changed ones with a new sequence, and
   tombstones each confirmed-missing child with its live descendants.
5. Before the commit, the app refuses a plan that removes every child of a folder that had
   children, or removes a kept file (a kind change and a kept file below a removed folder count
   too). A listing that starts at least 15 s later applies what it finds. There is no holding
   area: that listing deletes a kept file's local copy.

**Doubt never deletes.** Tombstones come only from a complete listing in which the server
confirmed each missing name gone. Timeouts, permission errors, a lost connection, a stopped app,
a rejected path, a name that is still there and per-entry errors all end before `reconcile`, or
leave rows as they were. Only a tombstone gives `noSuchItem`, because that error makes the system
delete local copies.

### Change watching

`SMBWatch` keeps one `CHANGE_NOTIFY` connection and thread per share, signed in as every session
is. It holds one watch without `WATCH_TREE` per folder, because a tree watch misses content writes
below the watched folder. The filter is `0xF5F` and the buffer 64 KiB. libsmb2's request timeout
is cleared on notify requests, which stay pending until a change, and each completion re-arms its
watch. An asynchronous echo every 60 s keeps the connection checked; libsmb2's synchronous
`smb2_echo()` is broken. Closing a handle stops its watch.

`STATUS_NOTIFY_ENUM_DIR` relists that folder. `STATUS_NOT_IMPLEMENTED` or `STATUS_NOT_SUPPORTED`,
as from Samba with `change notify = no`, ends the watcher without a retry; the periodic listings
cover the folders, and a recovered connection, wake or new password tries once more. Any other
completion that the app did not cause reconnects with backoff from 5 s to 60 s and relists every
watched folder. Notices name the
watched path, which the app maps back to catalog IDs, and the changed entries. A notice whose
entries are all files that this Mac is uploading or saving lists nothing; each of those writes
lists the notice's folders once when it ends. Before a folder move or deletion, the app
reserves the paths and closes every watch at or below them; the watcher waits up to 10 s for the
server to close those handles, and otherwise ends its connection. Notices and the app's own
changes coalesce, with at least 2 s between listings of one folder.

### Provider errors

`SourceFailure` classifies share I/O failures, and only domain and code cross XPC. The extension
maps catalog and SQLite errors itself, into `NSCocoaErrorDomain` or `NSFileProviderErrorDomain`
only.

| Condition | Extension returns | Location status |
| --- | --- | --- |
| Reader not connected (app quit or starting) | listed folders from the catalog; fetches wait only within the first 5 s of the reader service, then `serverUnreachable` | — |
| No network path, a stalled or timed-out request, or an unresponsive share | `serverUnreachable`, at once while unresponsive | "TinyMounter cannot connect to <host>. Make sure that <host> is on. Make sure that this Mac is on the same network." |
| The server refuses the saved password | `notAuthenticated`, with no I/O until a new password | "Sign in again." |
| No permission on an item, or a path rejected by containment | `fileReadNoPermission` | — |
| A missing item, or one that is no longer a regular file | `fileReadNoSuchFile` (transient), and a relist of the parent | — |
| Location folder not on the share | `fileReadNoSuchFile`; the root is never tombstoned | "This folder is not on the share." |
| Version changed | `versionNoLongerAvailable` | — |
| Tombstone | `noSuchItem`, the only case | — |
| Unknown ID, a folder over 100,000 entries, an incomplete listing | `CocoaError(.fileReadUnknown)` (transient); nothing written | — |
| Catalog missing, unreadable, damaged, or of another schema or domain | `serverUnreachable`; never created again | "TinyMounter cannot read the data for this location. Remove the location. Then add it again." |
| Malformed page token or anchor | `pageExpired` or `syncAnchorExpired` | — |
| Local disk full | `fileWriteOutOfSpace` | "Not sufficient space" for an affected keep request |
| Domain turned off by the user | the system returns `domainDisabled` | "File Provider is off." |

## 8. Writes and offline editing

The [ordinary SMB contract](smb-simplification.md) governs existing-file saves. File Provider owns
pending local contents and retries; the app never acknowledges an unfinished remote write.
Competing edits may be overwritten, and interrupted writes may leave partial remote data.
Previous-version recovery belongs to the NAS. The separate local upload outbox remains for new
items, where exclusive creation and retry identity prevent accidental replacement.

Do not discard pending local data during domain removal, reset, upgrade or uninstall. Removal
uses macOS's preserve-dirty-user-data option. Older save transactions must finish or be exported
with their original build before Start Fresh. A synchronized local replica does not promise
remote POSIX locking for databases or VM disk images.

Deletion replay binds the owner domain, item ID and `NSFileProviderRequest.domainVersion`.
Finder can refresh a retry's item base versions, so those versions only validate new admission.
The app securely archives Apple's event version and compares decoded versions semantically.
Each catalog persists the current domain version before registration and advances it before
terminal deletion settlement. Launch recovery advances and republishes completed settlement
before waking stopped requests. A delayed event for another item may still be a first request.
Missing, malformed or future events fail without mutation. This format requires fresh catalogs
and deletion records; no migration is provided.
Finder's Replace sends an indistinguishable delete followed by a separate create. Under the
ordinary SMB contract that is accepted: ordinary Finder deletion and Replace are enabled, and
Replace can delete the old destination before the new upload finishes. A separate
**Delete Permanently…** command with confirmation uses its own XPC entry point.
The command accepts one ordinary file or folder at a time, with recursive folder deletion.
Cancel is the default, the selected version is rechecked after confirmation, and pending system
synchronization in either overlapping view blocks admission. This conservative check can also
block deletion while an unrelated item in that view is syncing. Retry may continue an
interrupted recorded request.
A save arriving after deletion fails and remains pending in File Provider. The removed custom
edit outbox no longer provides Export Local Copy or Stop Uploading for edits. Copy the pending
local file outside the location before resolving a missing-target error.

### Organization, deletion and offline rules

**Rename and move.** Organization uses server identity and metadata; it never downloads file
contents only to rename or move them. Folder moves inspect descendant metadata, so their cost
grows with the cataloged subtree. Descendant IDs, downloads and keeps survive a move. The old
parent's departure and the new parent's arrival reach File Provider through enumeration, without
deleting and recreating the moved item. An uncertain operation or a pending save in the affected
subtree blocks the move. TinyMounter refuses to move a folder into its descendant, to move a
configured location root, or to move a subtree that contains another location root. A move stays
within the same set of overlapping registered roots, and every affected catalog must be
available. Cross-filesystem errors and incompatible open handles fail clearly. There is no
copy/delete fallback, permission rewrite or automatic movement of configured roots.

A rename or move holds the ancestor folders of both paths and a source handle that prevents
competing writes, deletion and renaming. It durably records the item, both parents, the exact
names and the server identities before one handle-based SMB rename with replacement disabled. A
destination collision is refused, never replaced or renamed automatically. Success needs the
destination's exact name, the original identity and matching metadata; the catalog then keeps the
item ID, enumeration key and content version. An explicit Keep Downloaded request follows the
item; inherited retention follows the destination folder. After a lost reply or a crash, the app
checks both paths again: it completes only when the destination holds the recorded object, and
retries only when the source still holds it and the destination is free. It never renames a
competing object back, infers success from a missing old name or searches the share. Otherwise
the operation stays pending and visible in Settings.

**Deletion.** Deletion is permanent: there is no TinyMounter Trash and no hidden retention copy,
and the app does not advertise Move to Trash or Put Back. Deleting a file removes its contents
and attached data, including attached data that another device adds while the deletion runs;
SMB cannot exclude that race. A server's own backups or recycle bin are outside TinyMounter's
guarantee. Delete may act on the server object currently at the selected name when its known
details still match, so an earlier replacement with indistinguishable details may be deleted.
Recovery stays bound to the admitted identity and never deletes a later replacement. A recursive
deletion records per-item progress, refuses protected roots and reports a partial result
accurately; it is not atomic. After a lost reply, an absent pathname does not prove deletion, and
Retry never acts on a replacement at that path. Uncertain cases stay visible in Settings.

**Replace and metadata.** New-file creation stays exclusive, including reimports and retries, so
an unrelated create cannot overwrite another file. Content-only saves keep the destination's
access permissions and concurrent metadata; Finder's delete/create Replace creates a new server
object. Unsupported tags or streams stay local. Syncing standalone Finder tags and locks needs a
later merge policy.

**Offline edits.** The latest pending save of a file with complete local contents uploads when
the server returns. Ordinary overwrite semantics apply if the server changed it, and a missing
remote target stays an error. A local editor's Save does not mean that the server received the
change. Offline creation, rename, move and deletion are outside the verified scope.

**Scope.** The daily-use target is ordinary files and folders within one location. Moves between
locations or shares, packages, live databases, VM images, symbolic and hard links and general
POSIX semantics need separate compatibility work. Copying a file to another location is not a
transactional move. External renames are not inferred from native pathname-derived IDs.

## 9. Server volume mode

The implemented mode uses public `NetFSMountURLSync` and the existing remount policy. Before each
mount, the app signs in with its SMB client and the saved password through the server's
`ServerSignIn`, then passes the name and password to NetFS with no UI. The client sign-in is
needed because smbfs reports a refused password as `ENOENT`, the same as a missing share. It
mounts visibly during Add and reconnects on app launch, wake and network return. Open at Login
uses the existing app setting; pre-login mounting is future scope. Native volumes have separate
saved records and create no provider domains or catalogs.

Remount attempts back off after network failures, from 10 s, doubling, to at most 5 min, one
attempt at a time. Authentication failures stop until the user
types a new password; other failures stop until conditions change or the user connects again. An
intentional eject holds reconnect during the current app session. A safe unmount must succeed
before removal forgets the record; no force option is used. Credentials are the app's own Keychain
item, shared with File Provider locations. `NWPathMonitor` reporting a usable path does not prove
that the server is reachable [N1–N3]; mount results determine success. Trusted-network, VPN and
wired preference policies remain future work.

An Ethernet/Wi-Fi change is not a reason to forcibly unmount every open file. Apple's SMB Multichannel can supply redundancy and choose interfaces when supported [N2]. Let healthy native sessions recover; remount when needed and safe. TinyMounter cannot promise seamless migration of every existing file descriptor across every path change. Do not globally rewrite `nsmb.conf` to implement a per-connection preference.

## 10. Implementation sequence and exit criteria

The user set the order of phases 3 to 7: what a daily user needs comes first, and refinement
comes after. Writes come before release hardening. Phase 5's reconnection part starts phase 3;
the rest stays in phase 5, because it waits for the transport decision.

The [roadmap](roadmap.md) lists the planned work within these phases, with its completion
criteria and parallel worktree ownership. Each implementation still has to pass its safety gates.

1. **Feasibility harness.** Signed File Provider with a small local fixture; full/range fetching; cancellation; local-network permissions tested for both app and extension; native SMB baseline; native-backed provider; async SMB comparator. Exit: attribution of throughput overhead, player matrix, and transport/permissions decision. Follow [benchmark-plan.md](benchmark-plan.md). Do this before the full UI.
2. **Read-only vertical slice.** One SMB share, persistent IDs/database, lazy directory enumeration, range/full reads, Keychain, meaningful offline/auth errors, safe restart. Exit: real Finder browsing and media reading without memory growth or leaked mounts/staging files. It started before phase 1's exit, on the native transport, with the user's Finder connection standing in for Keychain until the transport decision. It ends with M9, exit validation in the VM, and M10, daily use on the physical Mac: updates keep locations, removal steps, and a signature that lasts.
3. **Offline and NAS changes you can trust.** It starts with reconnection, because in M9 macOS dropped the Finder connection after a 70 s outage and the user had to connect again. After an outage, sleep or a network change, the app asks macOS to mount the share again with the password that the user saved in the Keychain, and it leaves an intentional eject alone; since 0.2.0, only Server Volume mode mounts (phase 5). A VM spike showed that the sandboxed app can mount. After a crash, the extension starts the app again, but not after the user quits it ([§3](#3-components-and-ownership)). The user then connects in the app, with macOS's own login dialog, and Finder shows only the locations (M12). M13 verifies kept-file offline status after a public File Provider stabilization barrier, against the catalog version observed by the app. M14 adds recursive folder requests, inherited retention and aggregate offline status. M15 adds bounded directory watches and periodic discovery in materialized and kept folders while the app runs. M16 adds a shared local-space budget with a 2 GiB reserve, disk-full status and persisted retry that respects Pause. M17 verifies location-change ordering, interrupted Apply/Remove and provider disablement with two locations. Full restart and OS eviction under pressure remain unverified. Exit: the share comes back by itself after an outage, and an eject stays; the app comes back after a crash, and a Quit stays; pinned files survive disconnect/reboot and hashes match; incomplete files are never represented as available offline; a NAS change in a listed folder shows without a relaunch. Testing NAS changes needs an isolated writable share.
4. **Writable synchronization.** Ordinary SMB operations, durable pending local uploads, correct catalog settlement and verified offline retry. NAS snapshots/backups own previous-version recovery. It needs change discovery from phase 3, and an isolated writable share for its tests. M18 to M21 add new files and folders, editing, renaming and file organization (§8). Exclusive creation exposes a new file remotely during upload; that visibility tradeoff is accepted.
5. **Own connection.** Credentials that the app keeps in the Keychain, and an SMB connection of its own instead of the macOS mount, if phase 1's transport decision chooses one. Done in 0.2.0 ([§5](#sign-in-and-connection)).
6. **Release hardening.** Multiple shares/accounts, several locations on one folder, load and failure testing, app-closed behavior, signing/notarization, clean install/update/uninstall, accessibility and diagnostics. Performance gates must pass on the physical Mac/NAS pair. Add broader NAS coverage before broad compatibility claims.
7. **Server volume mode.** Mount server volumes automatically. Reuse connections, Keychain, reachability, and any proven native mount component. Add the policy state machine and safe user controls. It can be prioritized independently after File Provider locations are proven.

## 11. Open decisions for the first experiment

- **Ordinary SMB semantics, accepted.** Ordinary writes replace custom recovery and conflict
  preservation. Competing edits may be overwritten; failed writes may leave partial remote
  contents. The [audit](smb-simplification.md) removes redundant payload verification while
  preserving pending local uploads, containment and accurate completion.
- **Single-client transport, adopted.** The app's own SMB client handles remote listing,
  metadata, reads and writes. Writable partial reads reach about 0.73 of native; 0.90 stays the
  improvement goal. Normal builds enable folder organization and Delete Permanently….
- **Earlier save transactions, superseded.** Protected stages, remote backups, complete-content
  rechecks and the M23 edit outbox were removed by the ordinary SMB decision.
- **M24 attached data during deletion, accepted.** SMB permits adding streams under a deny-all
  main-file handle. Deleting all attached data present at removal, including such concurrent
  additions, is accepted. A lost reply leaves the deletion visibly unconfirmed.

- **M21 admission for ordinary catalog rows, accepted.** Source review found that legacy
  downloaded and never-downloaded rows lack historical server identity. Name-derived native IDs
  and matching timestamps cannot distinguish an earlier replacement. Binding a move to the
  object currently at the path, after matching known details and establishing protected
  identity/metadata evidence, is implemented. An indistinguishable prior replacement may
  therefore be moved. Organization uses metadata, not the earlier full-content contract;
  protocol checks cannot establish the missing history.

- **Planned work.** The [roadmap](roadmap.md) holds the work that is not done yet, its
  completion criteria and shared integration ownership. Physical-Mac installation and
  publication remain separate decisions. Existing benchmark and phase exit gates remain.
- **M21 file organization, accepted.** Rename and move ordinary files within one location,
  including files never downloaded, with an identity gate before mutation. Preserve original
  objects, IDs, downloads and keeps; prove departures as well as arrivals in enumeration. Reuse
  protected no-replace rename with durable evidence for both parents. Initially refuse crossing
  an overlapping location's boundary and moves between locations; folder operations follow in
  M22. [§8](#organization-deletion-and-offline-rules) states the stable-identity and metadata
  checks.
- **M19/M20 historical gates.** Git history keeps the earlier protected save and verified-file
  rename designs. Ordinary saves now overwrite directly, and file
  organization uses metadata without complete-content proofs. Broader editor combinations need
  signed callback checks before enablement.
- **Initial folder naming, accepted for M18.** Finder creates an untitled folder, then sends a rename for the typed name. Native exclusive folder rename failed, and create/delete is unsafe under replacement races. `libsmb2` creates folders exclusively and gives them their initial name, retaining server identity separately from native inodes. Enabled locations advertise rename capability so Finder can choose a new copy name for Keep Both. M20 and later milestones support renaming ordinary files and folders.

- Physical Mac hardware, exact NAS/disk models, NIC/link topology, and physical-Mac SMB settings. VM/NAS telemetry establishes 64 GB RAM, Samba 4.17.12-Debian, ext4/LVM/linear md storage and the negotiated VM SMB settings.
- Current competitor app versions and exact scripts/files used for the reported rates.
- Whether native bridge permissions/lifecycle are acceptable and whether direct SMB matches its speed. The approved app-owned reader resolves the immediate NAS access gate. Full downloads now exceed 90% in both verified NAS cache conditions. Tracing places most recurring range-read delay after callback completion, waiting for a macOS database batch flush. Bounded read-ahead is now implemented and reaches 59.7% of native for long sequential reads; neither shipping readiness nor an unavoidable OS ceiling is established. The local cached-read gap to ordinary APFS also needs investigation.
- Which further players and opening routes use partial reads on macOS 27, and what coherence guarantee the server can support. The measured VM Finder launch routes downloaded the whole file first; the physical-Mac routes remain unrecorded.
- **Instant playback from Finder.** The user proposes keeping folders used mainly for playback on server volumes, with Finder aliases bringing File Provider locations and server volumes together for navigation; the [interface](ui-design.md), accepted for prototyping, keeps them in a Locations folder. A Finder alias works for both kinds of target. Native server volumes use one mode per share. A server volume covers a whole share, so a server-volume "folder" means a mounted share plus an alias into it.
- **Synchronization between views.** Proposed in [synchronization.md](synchronization.md). One mode per share excludes mixed TinyMounter modes on one share; external writers still require change discovery. It covers changes made through a server volume or another device while a File Provider location holds metadata or downloaded copies, and later two-sided writes.
- **Read-ahead tuning.** Seeks come first, as the user asked. The window is one 16 MiB chunk, which avoided the system materialization race in stress trials without proving it gone; throughput-first settings read faster but let seeks wait. Repeat on the physical Mac. With the single-client prefetch, read-only partial reads and seeks in both views meet their targets, but writable partial reads stay at about 0.73 of native.
- **Failed-folder recovery.** Supported directory materialization restored children but left Finder’s error banner. No complete automatic recovery is verified. A notification explaining Try Again is proposed only; adding it or submitting an Apple Feedback report requires the user’s approval.
- Product deployment floor and distribution signing. The current macOS 27 experiment now runs with the configured Personal Team and a team-prefixed macOS App Group; production signing/lifecycle remains undecided.

No NAS credentials are needed to review this plan. For the experiment, a read-only test account/share and a representative large video/file are enough; the user can connect it in the VM or enter credentials into the app instead of placing secrets in chat. Writes and deliberate server disruption will need a dedicated scratch area and explicit test scope. The VM is appropriate for correctness work; its virtual NIC/storage cannot establish the physical Mac's absolute speed.
