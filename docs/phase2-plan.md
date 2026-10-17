# Phase 2: read-only vertical slice

Date: 2026-10-12. Decision status: accepted. The user started phase 2 on 2026-10-11 and made the
decisions in section 1 on 2026-10-12. Done: M1, the core library, with its read-only [NAS
listing](results/2026-10-12-nas-listing.md); M2's first remount round, which [decided
D1](results/2026-10-12-remount-identity.md). M3's [share grant and Finder
spikes](results/2026-10-12-share-grant.md), verified in the signed app, with its regression read
passing on 2026-10-13. M4 and M5 [passed their runtime checks](results/2026-10-14-catalog-browsing-reads.md)
on 2026-10-14 and 2026-10-15. The follow-up on 2026-10-15 fixed IINA's full-download fallbacks
and read-ahead stalls, and Remove Location now deletes downloaded copies. A system race that caused
fallbacks was avoided in 11 stress trials after the window became one chunk
([comparison](results/2026-10-15-read-ahead-window.md)). M6 [passed its runtime
checks](results/2026-10-16-keep-pause.md) on 2026-10-16, which also verified the D2 deadline.
Nothing after M6 is built.

This is phase 2 of [architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria).
It starts before phase 1's exit and keeps the current transport. The phase 1 sequential
partial-read gate still fails. This phase doesn't change that; of the seek-first read-ahead
settings it changes only the window. Evidence tags: **[V]** verified in this VM, **[H]** stated
in the macOS 27.0 SDK headers, **[D]** documented by Apple online only, **[I]** inferred,
**[A, Mx]** an assumption that milestone Mx checks.

## 1. Decisions

The user's decisions:

1. **Transport unchanged.** The main app reads the NAS through the user's existing macOS SMB
   mount, through the app-owned reader and the restricted File Provider service. The extension
   can't read network volumes itself: Network Volumes privacy denies it [V].
2. **Connection, for phase 2 only.** The user connects the share in Finder. Then the user selects
   the mounted share root once in tinymounter's Servers pane (`NSOpenPanel`). A location is a
   saved server grant, a share and a folder path in it. tinymounter stores no passwords; macOS
   keeps them. This stands in for "Keychain" in the phase 2 definition. After the transport
   decision, tinymounter's own Keychain-based connection replaces it.
3. **Keep Downloaded is a request.** Finder gets Keep Downloaded and Allow Removal. The location
   pane lists the requests as "Requested". A verified "Available offline" and keeping whole
   folders are phase 3.
4. **UI.** Build the accepted [ui-design.md](ui-design.md) and [mockup](ui-mockup.html), with the
   phase 2 scope in decision 5: a Settings window with a sidebar (Locations; then General,
   Storage, Servers, About), one pane per location, adding by Duplicate into a "Not added" draft,
   `+` New Location, Revert and Apply for source changes (Apply replaces the domain), Name applied
   at once, Connection Mode with Server volume "Not available in this version", and a menu bar
   item. Text follows ASD-STE100 and reuses the mockup's checked strings.
5. **Phase 2 UI scope.**
   - Built: a Dock icon (a regular app, not menu-bar-only); download progress in the menu bar
     item, a transfer symbol and Pause Downloads; the Storage pane, with disk space used per
     location and Remove Downloads; notifications; folder-path completion, built last.
   - Changed from the design: Add Share… instead of Add Server… (decision 2). Duplicate does not
     copy Keep Downloaded requests: it is only a starting point for a new location. The same
     folder, and nested folders, can be locations more than once, and M9 tests that this works.
   - Remove Location asks whether to save the Keep Downloaded list. A saved list comes back when
     a later location on the same share contains those files.
   - Pause Downloads stops background downloads only: Keep Downloaded downloads and read-ahead. A
     file that the user opens still downloads.
   - Not in phase 2: the Locations folder and Open Locations Folder (Finder's sidebar already shows
     each location), Export Diagnostics (About copies diagnostic counts), and the "Keep this much
     disk space free" setting.
6. **Folders already listed are listed again** at app launch and when a share reconnects (D6).
7. **Exit thresholds (D7).** App and extension memory after the third identical soak cycle within
   10% of after the first; 0 staging files at idle; smbfs mount count unchanged; 0 tombstones
   caused by failures.
8. **Tests the main agent may run (D8):** eject and reconnect the VM's SMB mount, and leave it
   connected afterwards; block only the NAS address with a temporary pf anchor; Finder full
   downloads of files over 256 MiB; VLC and IINA playback. Nothing on the NAS changes.

The agent's decisions, which the user can change:

- **D1.** Content versions use size, mtime and ctime only. After an eject and reconnect, `st_dev`
  changed for all 268 entries measured, and size, mtime, ctime and inode for none (M2). The full
  snapshot check during each transfer stays, device and inode included.
- **D2.** Progress messages and a 60 s no-progress deadline replace the absolute 300 s reply
  wait. Otherwise a Keep Downloaded download that takes over 300 s fails and starts again.
- **D3.** The six fixture domains (about 2.9 GiB downloaded) are removed with `.removeAll`: they
  hold only test copies of NAS files. Remove Location also uses `.removeAll` (user, 2026-10-15):
  `.preserveDownloadedUserData` left 4.9 GiB of read-only copies in CloudStorage in M4.
- **D5.** A mass-deletion guard (section 5, reconcile step 4). Without a holding area, a kept file's
  local copy is deleted once a second complete listing confirms that the NAS removed it.
- **D9.** The defaults in section 10.

Choices this plan makes where the reviewed designs disagreed, one reason each:

- **The app is the only catalog writer**, keep requests included; the extension opens the catalog
  read-only. One writer avoids cross-process write locks, and a keep needs the app to download.
- **A listing commits whole**, in one transaction after it completes. Streamed batches would let
  the system see children of a folder whose listing is not complete.
- **Error rules from the failure-first design.** Only a tombstone that a complete listing wrote
  gives `noSuchItem`. Every other doubt is a transient or connection error.
- **Keyset paging in name order.** The page token is a row number, and the query reads that row's
  name key. It is stable across reconciles and holds no names. `OFFSET` paging with
  `pageExpired` was rejected: that code (-1002) makes the system re-sync from scratch [H].
- **A per-entry error does not fail a listing.** The entry's name proves that it exists, so its
  row stays as it was. Failing the folder would block it indefinitely.
- **No new SwiftPM target.** New shared code goes into `TransferCore`. Xcode compiles sources
  directly into each target, so a second module adds entries without isolation [V].
- **Package platform raised to macOS 27.** `O_NOFOLLOW_ANY` and `O_RESOLVE_BENEATH` have no
  availability annotations, and every Xcode target already deploys on 27.0.
- **No XPC version handshake.** Both ends ship in one bundle and domain IDs are never reused, so
  the existing `connect(domainID)` binding is enough.
- **Mutation error codes unchanged until measured.** `fileWriteNoPermission` stays, with a counter
  in M4. Only reimport `createItem` calls change, because they are identity matching, not writes.
- **Relisting reads the materialized set.** The system never enumerates a materialized folder
  again, and the header asks the provider to track those folders [H]. Relisting only them keeps
  the NAS load in proportion to what is on this Mac.

## 2. Scope and exit criteria

| Phase 2 definition | Form in this plan |
| --- | --- |
| One SMB share | One granted share root, tested with several locations (folders) on it |
| Persistent IDs and database | One SQLite catalog per File Provider domain; opaque UUID item IDs |
| Lazy directory enumeration | The app lists a folder when the system first enumerates it |
| Range and full reads | The existing fetch paths, addressed by item ID, with per-item read-ahead |
| Credentials | Decision 2: the user's Finder connection plus a saved share-root grant |
| Meaningful offline and authentication errors | Section 7; never `noSuchItem` for doubt |
| Safe restart | Durable catalog and anchors, staging sweeps, domain steps that resume |

Decisions 3 to 6 add Keep Downloaded requests, the UI and relisting.

**Exit criteria.** M9 shows each one with dated evidence in a results log:

1. Real Finder browsing at least 3 folder levels deep. Child counts equal a native listing minus
   the entries that the log reports as skipped.
2. Media reading: VLC and IINA stream with partial reads from their own File > Open. Range reads
   and full downloads match native checksums.
3. No memory growth: app and extension RSS after the third identical soak cycle stay within 10% of
   after the first (decision 7).
4. No leaked mounts: the smbfs mount count does not change, and tinymounter never mounts.
5. No leaked staging: 0 stage files in `ReaderStaging` and in the extension's temporary
   directory at idle, also after the crash tests.
6. No tombstones caused by failures. No names, paths, hosts or accounts in logs.
7. Two locations on the same folder, and two nested locations, browse and read independently.
   Removing one changes nothing in the other.
8. A NAS change in a folder that Finder already listed shows after an app relaunch and after a
   reconnect.

**Phase 2 does not:**

- write, rename or delete anything on the NAS;
- keep folders, show "Available offline" or "Update in progress", or add Finder decorations;
- find NAS changes between relistings: no `CHANGE_NOTIFY` and no polling;
- store passwords, open its own SMB connection, mount, or offer server volumes or the Locations
  folder;
- track renames (a NAS rename is delete plus create), or show symlinks and special files;
- fix the phase 1 range-read gate or change the seek-first read-ahead settings;
- migrate the six one-file fixture domains: the current build removes them first (D3).

## 3. Architecture

| Process | Owns | Never |
| --- | --- | --- |
| `TinyMounterPrototype.app`, sandboxed app with a Dock icon and a menu bar item | settings, share grants, mount sessions, all share I/O (list, stat, read), every catalog write, domain add and remove, staging files, relisting, notifications, UI | writes to the share, mounts, logs names |
| `TinyMounterProvider.appex`, one process per domain | File Provider callbacks, catalog reads, staging handoff, per-item read-ahead, Finder actions | opens the share, writes or creates a catalog |
| `fileproviderd` | replica, materialization, Finder integration | — |

**App** (`Prototype/App/`):

- `SettingsStore`: `Settings.json` in the app container, written atomically with mode 0600. A
  file that can't be read stops launch reconciliation and shows a problem. It is never read as
  "no locations".
- `ShareAccess`, one per server grant:
  - checks the mount with `getmntinfo(MNT_NOWAIT)`, which does no I/O (0.018 ms [V]), against the
    grant's `f_mntfromname`;
  - only then resolves the bookmark with `[.withSecurityScope, .withoutUI, .withoutMounting]`,
    once per mount session, and calls `startAccessingSecurityScopedResource` once;
  - opens the share root `O_EVTONLY|O_DIRECTORY`, which does not block eject [V]. `fstatfs` must
    show smbfs, the matched mount's `f_fsid` and `f_mntfromname`, and `f_mntonname` equal to the
    opened path;
  - runs one serial metadata lane, the `ShareHealth` state and one probe while unhealthy;
  - closes its descriptors and stops access on `NSWorkspace` will-unmount and did-unmount, and
    polls the mount table every 10 s as a backstop and to start a session when the share is
    mounted. A mount from will-unmount gets no new session until it leaves the mount table, or
    for at most 60 s (M7).
- `LocationSource`, one per added location: the writer catalog, a location-root descriptor opened
  beneath the share root once per mount session, coalesced listings, `transfer(request)` for
  reads, and `keep(ids, value)` (M6).
- `SourceReaderHost` and `SourceReaderSession` (existing): one duplex XPC session per domain, only
  for domains whose catalog the app opened. They add `list`, `started`, `progress` and, in M6,
  `keep`, and fetches go through `LocationSource`.
- `LocationController`: domain add, rename, apply and remove, saved keep lists, relisting, and
  launch reconciliation. M7's `AppModel` drives it.

**Extension** (`Prototype/Provider/`): `FileProviderExtension` (callbacks, read-ahead registry,
temporary-directory sweep, `NSFileProviderCustomAction`); `CatalogItem` (the
`NSFileProviderItem` for a `CatalogRow`) and `Enumerators` (folder, item, working set, empty
trash); `SourceReaderService` (existing listener, plus `list` and `keep` calls with deadlines).

**Core** (`Sources/TransferCore/`, tested with `swift test`): `Catalog` and its `CatalogRow`
(schema, reconcile, queries, cursors), `DirectoryListing` (`getattrlistbulk`), `RelativePath` and
name keys, `ContentFingerprint`, `ShareMount` (`MountIdentity` and its checks, and
`ReadOnlyFile(directoryFD:relativePath:expected:noCache:)`), `ReadAheadRegistry`, `SourceFailure`
(share I/O error classifier), `ShareHealth` (state machine), the staging sweep and the settings
types. Xcode compiles `DirectoryListing`, `ShareMount`, `ShareHealth`, the settings types and the
catalog's creation and writes (`CatalogReconcile.swift`: `create`, `openWriter`, `reconcile`,
`missingChildren` and the setters) into the app only. The extension's only open, `Catalog.open`,
is `SQLITE_OPEN_READONLY`.

**Flows:**

1. **Browse.** `enumerateItems(folder)` → XPC `list(folder)` → the app's lane lists the folder →
   `Catalog.reconcile` in one transaction → a reply with counts → the extension pages from the
   catalog. If rows changed, the app signals `.workingSet`, debounced by 200 ms.
2. **Read.** `fetchPartialContents` or `fetchContents` → catalog row and strict version check →
   XPC `fetch(item, version, range)` → the app opens the catalog path beneath the share root,
   compares the fingerprint and stages the bytes → the extension renames the staged file into
   `temporaryDirectoryURL()` and completes.
3. **Keep.** Finder action → `performAction` → XPC `keep(ids, value)` → the app sets `keep` with a
   new change sequence and signals `.workingSet` → the item reports
   `.downloadEagerlyAndKeepDownloaded` → the system's full fetch takes flow 2.
4. **Recovery.** When a share becomes healthy again (a session starts, the first in each app
   process included, or a probe succeeds), the app calls `signalErrorResolved` for
   `.serverUnreachable`, and for `.notAuthenticated` if it was used since the last recovery. Then
   it signals `.workingSet` for each domain on that grant, and starts flow 5. When a reader
   session connects, the app does the same for that domain with `.serverUnreachable` only, and
   does not start flow 5.
5. **Relist (D6).** At app launch, once the share is healthy, and after each recovery, the app
   reads each domain's materialized set with `enumeratorForMaterializedItems` [V, M3]. It lists
   each materialized folder again, one at a time on the metadata lane, except the system's own
   Trash folder, which is in that set but not in the catalog [V, M4]. Changes reach the system
   through the working set, as in flow 1.

Only `.workingSet` is signalled: replicated domains ignore other containers [H].

**Transport boundary.** Only `ShareAccess`, `DirectoryListing` and `ShareMount` (with
`ReadOnlyFile(directoryFD:…)`) know about the mount. The transport decision replaces those three,
not the catalog, the XPC contract or the UI.

**Kept as is:** full and partial fetch with the EOF clamp and alignment; the seek-first read-ahead
settings (16 MiB demand extent and chunk, one speculative fetch in flight, 30 ms chain gap);
`versionNoLongerAvailable` on any version change; `O_EXCL` staging and the
same-volume `RENAME_EXCL` handoff with no copy fallback; both peer code-signing requirements and
the euid check; no payload bytes over XPC; the 4096-byte message bound; two app transfer workers
and four jobs per session; pipeline depth 2; `invalidate()` never cancels queued operations; the
empty trash enumerator; logs only under `dev.tinymounter.prototype`.

**Changed, with reasons:**

| Change | Reason |
| --- | --- |
| `enumerator(for:)` serves file identifiers | The system enumerates single documents; today's `noSuchItem` there would delete the file [H] |
| `noSuchItem` only for tombstones | It makes the system delete local copies [H] |
| Bookmark resolved once per mount session, with `.withoutMounting` | Resolution per request blocked about 30 s per miss offline [V], and could remount after an eject |
| App-scoped share-root bookmark | A document-scoped bookmark can't point to a folder [V] |
| ENOENT at fetch: transient error plus a relist of the parent | Deletion comes only through a complete listing |
| Content version without device and inode (D1) | `st_dev` changes per mount [V, M2]; every copy would download again |
| Fetch progress, 60 s stall deadline instead of 300 s (D2) | Long healthy downloads fail at 300 s; the system stops fetches that show no progress [H] |
| Reimport `createItem` matched to existing items | A rejection is retried, and `nil` would delete the disk copy [H] |
| Read-ahead state per item | The planner tracked one file per domain |
| Read-ahead window 16 MiB, not 128 MiB | A fast reader caught deeper read-ahead and the system downloaded the whole file [V, M5] |
| A Dock icon instead of the harness window | Decision 5 |

## 4. Data model

**Settings** (`Application Support/tinymounter/Settings.json` in the app container; app only):

```swift
struct AppSettings: Codable {
  var version = 1; var servers: [ServerGrant]; var locations: [LocationRecord]
  var savedKeeps: [SavedKeepList]
}
struct ServerGrant: Codable {
  let id: UUID
  var bookmark: Data    // app-scoped, .withSecurityScope + .securityScopeAllowOnlyReadAccess
  let mountFrom: String // f_mntfromname, "//account@host/share"
  let host: String, account: String, share: String  // from NSURLVolumeURLForRemountingKey
}
struct LocationRecord: Codable {
  let id: UUID; var name: String; var serverID: UUID
  var folder: String            // a RelativePath; "" is the full share
  var domainID: String          // NSFileProviderDomainIdentifier, a UUID
  var retiredDomainID: String?  // Apply in progress: the old domain still to remove
  var removing = false
  var pendingKeeps: [String] = []  // saved paths, from the share root, not found yet (M7)
}
struct SavedKeepList: Codable {
  let host: String, share: String  // not the grant ID, so a new grant for the share matches
  var paths: [String]              // RelativePaths from the share root
}
```

The bookmark, `mountFrom`, host, account and saved paths are private. They are never logged and
never in the App Group: the bookmark holds the SMB account and the server address [V]. Drafts
("Not added") live in memory only. Show in menu bar and Notifications are not in this file: they
are `UserDefaults` preferences, which SwiftUI's `@AppStorage` reads at launch (M7).

**Saved keep lists.** When the user removes a location with "Save the Keep Downloaded list"
selected, the app adds the location's kept paths, from the share root, to the list for the grant's
host and share. When the user adds a location, it takes every saved path inside its folder out of
the list. After the root listing, the app lists the parent folders of each taken path, as flow 1
does, and sets `keep` on the rows it finds. A path that a complete listing of its parent lacks
shows "Not on the server", and `−` discards it. A path that can't be checked yet waits for the next
recovery.

A kept file whose folders the system hasn't materialized doesn't download (M6). So when a location
finds such files, the app asks "Download N kept files now?". Download Now calls
`requestDownloadForItem(withIdentifier:)` on each folder above them, root first; Not Now leaves
them to download when the user opens the folders (M7).

Apply keeps the location's Keep Downloaded requests where it can. On the same share, the kept and
pending paths inside the new folder become pending paths of the new domain. The others go to the
old share's saved list without a question, so a later location can take them.

**Catalog**, `<AppGroup>/Catalogs/<domainID>.sqlite` with `-wal` and `-shm`. The app creates it
before `NSFileProviderManager.add`, and creation fails if the file exists. The app deletes it
after the domain is removed. The app reopens its writer with `openWriter`; the extension opens it
with `SQLITE_OPEN_READONLY`; neither open ever creates one. Both opens check `user_version`, the
`meta` row, the epoch's length, the domain, the counters (`0 ≤ listing_gen`, `0 ≤ last_seq < 2^62`,
`max(change_seq) ≤ last_seq`) and a live root folder with no parent. Any failure is
"catalog unavailable" (section 7), so damage never crashes the writer or expires every anchor.
Pragmas: `journal_mode=WAL` and `busy_timeout=2000`; the writer adds `synchronous=FULL` and
`fullfsync=ON`, because delivered anchors must survive power loss [H]. A plain `fsync` doesn't ask
the drive to flush its cache; `F_FULLFSYNC` does [H]. The system SQLite leaves `fullfsync` off by
default [V]. Writes use `BEGIN IMMEDIATE` and never hold share I/O inside.
`import SQLite3` autolinks the system library in SwiftPM and in both Xcode targets [V].

```sql
PRAGMA user_version = 1;               -- any other value: catalog unavailable; no migrations
CREATE TABLE meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  domain_id TEXT NOT NULL,             -- must equal the domain that opens it
  epoch BLOB NOT NULL,                 -- 16 random bytes, fixed for the catalog's life
  last_seq INTEGER NOT NULL,           -- highest change_seq handed out
  listing_gen INTEGER NOT NULL,        -- number of complete listings applied
  paused INTEGER NOT NULL DEFAULT 0);  -- Pause Downloads; the app clears it at launch
CREATE TABLE items (
  row INTEGER PRIMARY KEY,             -- never reused, because rows are never deleted
  id TEXT NOT NULL UNIQUE,             -- UUID; the root row holds the root container constant
  parent_id TEXT REFERENCES items(id), -- NULL only for the root
  name TEXT NOT NULL,                  -- exact remote component; root: location name
  name_key TEXT NOT NULL,              -- NFD, case fold, NFC; fixed for the row's life
  kind INTEGER NOT NULL,               -- 1 folder, 2 file
  size INTEGER NOT NULL DEFAULT 0,
  mtime_ns INTEGER NOT NULL DEFAULT 0,
  ctime_ns INTEGER NOT NULL DEFAULT 0,
  file_id INTEGER,                     -- ATTR_CMN_FILEID: evidence only, never a key
  keep INTEGER NOT NULL DEFAULT 0,     -- Keep Downloaded requested (files only)
  list_gen INTEGER,                    -- folders: last complete listing; NULL = never listed
  listed_at REAL,
  deleted INTEGER NOT NULL DEFAULT 0,  -- tombstone; only reconcile sets it
  change_seq INTEGER NOT NULL UNIQUE); -- last visible change
CREATE UNIQUE INDEX items_live_name ON items(parent_id, name_key) WHERE deleted = 0;
CREATE INDEX items_kept ON items(row) WHERE keep = 1 AND deleted = 0;
```

At creation, `meta` holds the domain ID, a random epoch, `last_seq = 0`, `listing_gen = 0` and
`paused = 0`. The root row has `change_seq = 0`.

**Item IDs and identity:**

- A `UUID().uuidString` is assigned the first time a complete listing shows a live
  `(parent_id, name_key)` that has no row. IDs hold no names, because they can appear in system
  logs [H].
- The same parent, name key and kind keep the ID across relistings, restarts and remounts. A
  case-only rename keeps the ID and stores the new exact name.
- A kind change (file to folder, or back) tombstones the old row and inserts a new ID: File
  Provider does not support type changes [H].
- Any other change, including a NAS rename or move, is delete plus create, which
  synchronization.md §5 allows. `file_id` is stored only as evidence: smbfs promises no persistent
  IDs [V].
- When names in one listing have the same key (a case-sensitive NAS can hold them), the existing
  name wins. A live row pairs with the listed name whose exact bytes equal its stored name, and
  that name decides an update, a kind change, or, if it is unreadable, no change. Only if no
  listed name has the stored bytes is it a case-only or normalization-only rename, and the first
  name in byte order wins, once listing step 6 has confirmed the stored name (section 5). A key
  with no live row takes the first name in byte order. The other names are skipped and counted,
  and a row is never tombstoned as missing while any name with its key is listed.
- A path is the location folder plus the names along the parent chain (a recursive CTE, depth at
  most 256). Each component is validated again before `openat`.
- Two locations on the same folder have separate catalogs and separate IDs. Nothing joins them.

**Versions.** A file's `contentVersion` is the UTF-8 string `f1:<size>:<mtime_ns>:<ctime_ns>`
(D1). Folders use `d1`. Both are at most 128 bytes [H]. `metadataVersion` is `change_seq` in
decimal. Each transfer still checks the full `FileSnapshot`, device and inode included, on its
open descriptor. `FileSnapshot.versionData` stays as it is for `transfer-bench`.

**Cursors.** No cursor holds a name, and all are far below the 500-byte limit [H].

| Cursor | Bytes | Content |
| --- | --- | --- |
| Sync anchor | 25 | `0x01`, epoch (16), `change_seq` (Int64, big-endian) |
| Folder page | 9 | `0x02`, last row (Int64); the next page reads that row's `name_key` |
| Working-set page | 9 | `0x03`, last row (Int64) |

**Writers.** Only the app writes. Only `reconcile` sets `deleted`. `updateFingerprint`, `setKeep`,
`setPaused` and `setRootName` give each row they change a new `change_seq` and never delete;
`setPaused` changes every kept row. Every visible change takes `last_seq + 1`, so a change batch
can never end inside a group of equal sequences. Tombstones stay for the catalog's life, which is
the domain's life.

## 5. Enumeration and changes

**Dispatch.** `enumerator(for:)` does one primary-key lookup and no share I/O:

| Identifier | Result |
| --- | --- |
| `.workingSet` | working-set enumerator |
| `.trashContainer` | the existing empty enumerator |
| root, or a live folder | folder enumerator |
| a live file | item enumerator: that one item |
| a tombstone | throws `noSuchItem` |
| an unknown ID | an enumerator whose calls fail with `CocoaError(.fileReadUnknown)` (transient) |
| catalog unavailable | throws `serverUnreachable` |

**First page of a folder.** Both initial-page constants get name order.

- Listed before (`list_gen` set): serve the catalog at once. If `listed_at` is older than 60 s,
  also send `list` without waiting. Differences then arrive through the working set.
- Never listed, reader connected: send `list` and wait at most 5 s, then serve the catalog. On an
  error, finish with the mapped error (section 7). At the deadline, finish with
  `serverUnreachable`. The app completes the listing and signals the working set if rows
  changed. The extension, which knows that its deadline fired, calls `signalErrorResolved` when
  the late reply succeeds. A reply carries the folder's `list_gen`; the extension serves the page
  only if its own connection sees at least that value, and otherwise finishes with
  `serverUnreachable`.
- Never listed, no reader: `serverUnreachable` at once.

**Pages.** `WHERE parent_id = ? AND deleted = 0 AND name_key > (SELECT name_key FROM items WHERE
row = ?) ORDER BY name_key LIMIT n`, with `n = suggestedPageSize ?? 200`, at most 1,000. Fewer
than `n` rows ends the enumeration. Later pages never call the app. A malformed token, or one
whose row is not a child of the folder, gives `pageExpired`. The working set pages all live rows
except the root by `row`, and never starts a listing.

**Changes.** `enumerateChanges(from:)` reads, in one read transaction, `WHERE change_seq > ? ORDER
BY change_seq LIMIT suggestedBatchSize ?? 200`. Live rows go to `didUpdate`, tombstones to
`didDeleteItems`. Each tombstoned descendant has its own row, so every deletion is reported. A
full batch finishes at its last sequence with `moreComing = true`. Otherwise it finishes at
`last_seq` with `moreComing = false`, so an up-to-date client gets its own anchor back [H]. An
anchor expires (`syncAnchorExpired`) only if it is malformed, has another epoch, or is above
`last_seq`. A Name change reports the root as updated [A, M7]. Folder and item enumerators answer
`enumerateChanges` with the same query, filtered by `parent_id` or `id`.

**Listing** (app, `DirectoryListing`):

1. Open the folder with `openat(locationRoot, path or ".", O_RDONLY|O_DIRECTORY|O_CLOEXEC|`
   `O_NOFOLLOW_ANY|O_RESOLVE_BENEATH)`. The descriptor lives only for the listing, so it never
   blocks an eject.
2. `fstatfs` must match the session: smbfs, `f_fsid` and `f_mntfromname`. `O_RESOLVE_BENEATH`
   crosses mount points [V], so a folder on another file system below a location root that still
   matches gives `pathRejected`. If the location root fails `fstatfs` or no longer matches, this
   or any other failure of the listing gives `notConnected` (`MountIdentity.guarding`). After an
   unmount, held `O_EVTONLY` descriptors are dead and fail with ENOTDIR, EIO or EBADF [I].
3. `getattrlistbulk` with `FSOPT_PACK_INVAL_ATTRS` and a 256 KiB buffer, asking for
   `RETURNED_ATTRS`, `NAME`, `ERROR`, `OBJTYPE`, `FILEID`, `MODTIME`, `CHGTIME` and
   `FILE_DATALENGTH`. One pass gives every field (169 entries: 39.6 ms cold, 0.9 ms warm [V]).
4. The listing is complete only if the loop ended with 0, every entry has a name, there are at
   most 100,000 entries of any kind, and `fstatfs` still matches. Otherwise it throws and writes
   nothing.
5. Skipped and counted: entries that are not regular files or folders; invalid names (empty, `.`,
   `..`, containing `/` or NUL, over 255 bytes); name-key collisions, which the listing still keeps
   for `reconcile` (section 4); new entries with `ATTR_CMN_ERROR`. An entry whose type, times, file
   ID or (files only) size comes back invalid counts as one with `ATTR_CMN_ERROR`.
6. A pass can end with 0 and still lack an entry: the smbfs `readdirattr` fallback can skip an
   entry whose lookup fails [I]. `Catalog.missingChildren(of:listing:)` gives the exact stored
   names of the live children that the listing lacks and that `reconcile` would change: those
   whose key the listing lacks, and those that would go to a readable twin because no listed name
   has their stored bytes, each with that twin's file ID. `DirectoryListing.confirmMissing` then
   runs `fstatat(folder, name, AT_SYMLINK_NOFOLLOW)` for each, with the checks of steps 1 and 2.
   Only ENOENT confirms an absence, or, for a row with a twin, a result whose `st_ino` is the
   twin's file ID: a case-insensitive server finds a case-only rename's new name by the old one
   [I]. A name that now holds a symlink or another kind that is never shown also confirms it. A
   name that still holds another file or folder throws `listingIncomplete`: nothing is written,
   and the folder is listed again later. Then `reconcile` runs, which does no share I/O.

**Reconcile** (`Catalog.reconcile(folder:listing:accept:)`, app only, one `BEGIN IMMEDIATE`):

1. The folder row must be live and a folder. Otherwise throw and write nothing.
2. Insert new entries. Update changed ones (name, size, mtime, ctime, file ID), each with a new
   sequence, and keep `keep`. An existing entry with `ATTR_CMN_ERROR` stays as it was. Rows pair
   with names by the collision rule in section 4.
3. Tombstone each live child whose key the listing lacks, once listing step 6 has confirmed its
   absence, and each live descendant of it, each with a new sequence. A kind change tombstones the
   old row and inserts a new one.
4. `accept` sees the planned changes inside the transaction; `false` writes nothing. The app
   refuses a plan that removes every child of a folder that had children, or removes a kept file,
   and relists 15 s later (D5). It applies that second complete listing. A kind change counts as a
   removal, and a kept file below a removed folder counts too (`Catalog.needsConfirmation`).
5. Set `list_gen = ++listing_gen` and `listed_at`, commit, and return the counts.

**Why doubt never deletes.** Tombstones have one writer, and it runs only on a complete listing from
a verified mount, after `fstatat` showed each missing name gone (ENOENT) or renamed to its twin.
Timeouts, permission errors, a missing mount, a stopped app, a rejected path, a name that is still
there and per-entry errors all end before `reconcile`, or leave rows as they were. This is
synchronization.md rule 3.

**Change discovery in phase 2.** The system does not enumerate a materialized folder again and has
no other invalidation [H]. So the app finds NAS changes in three ways: a never-listed or evicted
folder is listed when the system enumerates it; materialized folders are listed again at launch and
after a reconnect (flow 5); and each fetch compares the fingerprint (section 6). A change made
between these events does not show until the next one. Downloaded copies stay stale until then,
which falls short of synchronization.md rule 2.

## 6. Reads

1. **Lookup** in the extension's read-only catalog: a tombstone gives `noSuchItem`; an unknown ID
   or a folder gives `CocoaError(.fileReadUnknown)`; an unavailable catalog gives
   `serverUnreachable`. A requested `contentVersion` other than the row's gives
   `versionNoLongerAvailable`.
2. **Classify and range.** `ReadAheadRegistry.classify(item, version, fileSize, offset, length)`.
   A stale speculative request completes with `userCancelled`. A seek cancels only that item's
   speculative fetches. The range is `clampedToEOF`, then `aligned` with `fileSize` from the row,
   preferring the 16 MiB demand extent or the planned speculative length. A full fetch is
   `[0, size)`.
3. **Request.** XPC `fetch {id, item, version, range}` on the existing two-worker queue.
   Before the first reader connection, fetches share a deadline 5 s after the extension's
   per-domain reader service starts. Attachment wakes them; cancellation is checked at most
   100 ms apart. Expiry gives `serverUnreachable`. Losing an established connection still fails
   at once. This startup wait is separate from the transfer stall deadline below.
4. **App.** Check the version against the row, then the share state: not connected or
   unresponsive gives `serverUnreachable` with no I/O. Build the path from the catalog and open
   `ReadOnlyFile(directoryFD: locationRoot, relativePath:, expected:, noCache: true)`. It uses
   `openat(…, O_RDONLY|O_CLOEXEC|O_NONBLOCK|O_NOFOLLOW_ANY|O_RESOLVE_BENEATH)` and requires a
   regular file. A symlink anywhere in the path gives ELOOP, an escape ENOTCAPABLE [V]. The mount
   checks are those of listing step 2: a file on another file system gives `pathRejected`, and a
   failure while the location root is off the mount gives `notConnected`. The transfer runs inside
   `MountIdentity.guarding(root: locationRoot)` for the same reason.
   - Fingerprint differs from the row: `updateFingerprint`, signal `.workingSet`, and reply
     `versionNoLongerAvailable`. The system asks again for the new version.
   - ENOENT, ENOTDIR or not a regular file: queue a relist of the parent and reply
     `fileReadNoSuchFile` (transient).
   - Other errors: mapped through `SourceFailure` (section 7).
   - Then `Transfer.run` into `ReaderStaging`, as today. A change during the transfer
     (`sourceChanged`) updates the row from the held descriptor and replies
     `versionNoLongerAvailable`. Ranges from two versions are never combined.
5. **Progress (D2).** When a worker begins the transfer, the app sends `started {id}`. Then it
   sends `progress(requestID, completedBytes)` at most every 0.5 s, and the extension sets
   `Progress.completedUnitCount`. From `started`, the wait ends with `serverUnreachable` after
   60 s with neither progress nor a reply [V, M6]. This replaces the absolute 300 s deadline.
   Before `started`, only the reply, a lost XPC connection or cancellation ends the wait, so time
   queued for the two workers that all locations share is not a stall. The app bounds that time: each
   running transfer progresses, fails with the mount's own timeout, or is refused at once while
   the share is unresponsive. The system cancels a fetch that stops making progress, after a time
   that it doesn't state [H], so it may still cancel a queued fetch [A, M5] (section 9).
6. **Handoff**, unchanged: check the receipt and the staged file, `renamex_np(RENAME_EXCL)` it
   into `temporaryDirectoryURL()`, complete with the row's item and the exact range, never touch
   the file again, then call `release(id)`.
7. **Read-ahead follow-up.** `demandCompleted` and `speculativeFinished` per item lead to
   `requestDownloadForItem(withIdentifier: item, requestedRange:)`, with the 30 ms chain gap.
   The range returned for a demand stops at the first byte already delivered (`ReadAheadRegistry.extent`).
   A successful full handoff retires that item/version's pending speculation and cancels its
   running speculation. Late completions cannot extend that chain. A later demand after eviction
   can start a fresh run; the planner does not remember the whole file as permanently delivered.

**Per-item read-ahead.** `ReadAheadRegistry` holds up to 8 `ReadAheadPlanner`s, keyed by item ID
and content version, and drops the least recently used. A version change starts a new planner.
The speculative map is keyed by request ID and records the item and version. Items still share the domain's
pipeline depth of 2, so one file's read-ahead can delay another file's foreground read [I].
The settings are phase 1's, except the window: one 16 MiB chunk past the latest sequential miss
(above). Two planner rules are new [V, M5]:

- Each planner remembers the ranges it handed to the system (up to 64 merged ranges). A returned
  range never extends into them, and read-ahead skips them. In M5, IINA's second read position
  rewrote bytes the first had just read; `fileproviderd` failed a read of them
  (`materializationFailed`) and downloaded the whole file.
- A demand that starts inside a request still waiting for the system retires that request and
  plans again from the demand's end. The system sometimes never delivers a request, which stopped
  read-ahead for the rest of the file.

**Bookmark resolution.** The extension lists `ScopedBookmarkAgent` in
`NSFileProviderExtensionNonMaterializingProcessNames`. When an app such as IINA starts, the agent
resolves its recent-file bookmarks with a coordinated read, which downloaded each whole file. With
the key set, the agent's read fails with EPERM, the recent items still show, and opening one
streams [V, M5]. Other uses of the agent are untested.

**Keep Downloaded downloads** are ordinary full fetches after the item reports
`.downloadEagerlyAndKeepDownloaded`. A request is not proof of a download (decision 3). The
system downloads a kept file only when its parent folder is materialized: a kept file in a folder
that the system never enumerated waits until the folder is enumerated [V, M6]. Evicting a kept
file fails; evicting its folder evicts it, and the system downloads it again at once [V, M6].

**Pause Downloads** (decision 5). The app sets `paused` in each catalog and signals `.workingSet`.
While it is set, kept items report `.downloadLazily`, so the system starts no eager downloads, and
the extension requests no read-ahead. After the commits, the app tells each connected extension,
which cancels its running fetches that are system requests or speculative; such a fetch that
starts later fails at once. A fetch that checked `paused` before the commit and still waits for
the first reader connection (up to 5 s) can't get that cancel, so when the reader connects, the
extension checks `paused` again and cancels it [I, not reproduced]. A reader that waits on
a cancelled speculative range gets it from its own fetch about 0.7 s later [V, M6]. Eager
Keep Downloaded fetches are system requests (`request.isSystemRequest`) [V, M6], so they
complete with `userCancelled`. A file that the user
opens downloads as usual, and so does Finder's Download Now, which is not a system request
[V, M6]. Resume and app launch clear `paused`. Pause and Resume changes run one at a time, in
order. A failed change shows a message, and while a catalog may still be paused, the app offers
Resume. Kept files already on disk stay while paused [V, M6, without disk pressure], unless the
system needs the space [A]. While paused, the user can also remove their downloads, and Resume
downloads them again [V, M6].

## 7. Errors, offline and restart

`SourceFailure` in core classifies share I/O failures; any other error keeps its own domain and
code (`unknown`). The extension maps catalog and SQLite errors itself, and maps every error into
`NSCocoaErrorDomain` or `NSFileProviderErrorDomain` only [H]. Errors cross XPC as domain and code
only, as today.

| Condition | Extension returns | Location status |
| --- | --- | --- |
| Reader not connected (app quit or starting) | listed folders from the catalog; fetches wait only within the initial 5 s connection window, otherwise `serverUnreachable` | — |
| No matching mount in the mount table | `serverUnreachable` at once, with no I/O | "Connect to the share with Connect to Server in Finder." (new) |
| ENOENT or ENOTDIR at the share root; a share or location root whose `fstatfs` fails or no longer matches (`notConnected`) | `serverUnreachable`; the share stays not connected until a new mount, and no probe runs | as the row above |
| ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ECONNRESET, ENXIO, ESTALE; an operation with no progress for 15 s; bookmark resolution fails while the mount is present (offline in phase 1: Cocoa 257 after about 30 s [V]) | `serverUnreachable`; the share becomes unresponsive | "tinymounter cannot connect to <host>. Make sure that <host> is on. Make sure that this Mac is on the same network." (approved) |
| First listing still running at 5 s | `serverUnreachable`; the app signals when it finishes | — |
| No grant; `startAccessing` false; EPERM at the share or location root; EAUTH or ENEEDAUTH | `notAuthenticated`; the session ends, and until the grant's mounts change or the share is selected again, requests fail at once and no probe runs | "Select the share again in Servers." (new) |
| EACCES or EPERM on an item | `fileReadNoPermission`; a listed folder uses the catalog | — |
| ELOOP or ENOTCAPABLE; a folder or file on another file system below a matching location root | `fileReadNoPermission`, logged as `path_rejected=1` | — |
| ENOENT or ENOTDIR on an item; a file that is no longer a regular file | `fileReadNoSuchFile` (transient) and a relist of the parent | — |
| Location folder not on the share | `fileReadNoSuchFile`; the root is never tombstoned | "This folder is not on the share." (new) |
| Version changed | `versionNoLongerAvailable` | — |
| Tombstone | `noSuchItem`, the only case | — |
| Unknown ID | `CocoaError(.fileReadUnknown)` (transient) | — |
| Catalog missing, unreadable, damaged (counters or root row), or of another schema or domain | `serverUnreachable`; never re-created | "tinymounter cannot read the data for this location. Remove the location. Then add it again." (new) |
| Folder with over 100,000 entries | `CocoaError(.fileReadUnknown)`; nothing written | — |
| A name that the listing lacked still exists (`listingIncomplete`) | listed folders from the catalog; otherwise `CocoaError(.fileReadUnknown)` (transient); nothing written | — |
| Malformed page token or anchor | `pageExpired` or `syncAnchorExpired` | — |
| Cancelled | `userCancelled` (existing) | — |
| Domain turned off by the user | the system returns `domainDisabled` | "This location is turned off in System Settings." (new) |

**Unresponsive share.** A blocked kernel SMB call can't be cancelled [V]. `ShareHealth` marks the
share unresponsive when a lane operation or a transfer makes no progress for 15 s, or a call fails
with a timeout-class errno. A listing makes progress with each `getattrlistbulk` batch, and a
confirmation (listing step 6) with each `fstatat`. Otherwise a large folder or a large removal would
count as one long call: at the measured cold rate (169 entries in 39.6 ms), 100,000 entries take
about 23 s, an estimate [I]. A lane operation of one call, such as one `fstatat`, makes no progress
until it returns. While it is unresponsive, requests fail at once. One probe, `fstatat(shareRoot,
".")`, runs every 5 s, never two at a time. It tests the server, so a location folder removed on
the NAS can't keep a share unresponsive. When a session start times out, or its bookmark
resolution fails, there is no session, so the probe starts one instead. Success recovers as in
flow 4 of section 3. A share whose mount went away (`notConnected`) is never unresponsive: no
probe runs, and only a new mount brings it back. The first request in an outage still waits for
the mount's own timeout: about 30 s measured [V], up to 600 s if the mount is hard [I].

**Offline.** Downloaded files and materialized folders work from the replica without the
extension [H]. Evicted folders with a complete listing come from the catalog. Never-listed folders
fail with `serverUnreachable`. Nothing is invented: rows come only from complete listings and
`fstat` results.

**Failed folder recovery.** `signalErrorResolved` lifts error throttling; it does not promise
that Finder retries an enumeration. Replicated extensions signal `.workingSet`; the SDK says
individual folder signals are ignored. In the [October 15 follow-up](results/2026-10-15-runtime-followup.md),
a diagnostic one-level directory download request repopulated all children, but Finder retained
the error banner even after another resolution signal and a folder metadata update. The pending
set did not expose the failed folder. No automatic recovery workaround or notification is installed.

**Notifications** (decision 5), when General › Notifications is on. One per share per outage,
never at launch and never with a file name:

- a share that has locations goes from connected to not connected or unresponsive;
- a download that the user started fails because the share is not connected or does not respond.

The app asks for permission when the first location is added. The text is checked in M7.

**Mutations.** `createItem`, `modifyItem` and `deleteItem` keep `fileWriteNoPermission`, which
the system retries [H]. M4 counts them in the log (`mutation=create|modify|delete`, no names). A
`createItem` with `.mayAlreadyExist` (a reimport) returns the live row with the same
`(parent, name_key)` and kind (`Catalog.reimportDecision`), if the parent is a listed live
folder. For a file with contents, it also sets `shouldFetchContent`, which the system asks for
when the disk content doesn't match the item [H], unless the template's `documentSize` equals the
row's size and its `contentModificationDate` is less than 1 µs from the row's mtime, as measured
between the two `Date`s (a `Date` can't hold every nanosecond). A date cut to whole microseconds
can measure 1 µs or more from the row's; that file is fetched again. The NAS is the source of
truth: a disk file with another size or mtime, such as an older version or another file saved
under that name, is replaced by the NAS file. The template has no ctime, so a NAS change that
keeps the size and mtime (such as an edit followed by `touch -r`) is not found, and the old disk
copy is kept as the current version. It returns `nil`, which deletes the disk copy [H], only when
the template is a file with `nil` contents and nothing matches: that copy holds no data. A
folder, a file with contents, a template of another kind than the match, or one that is neither a
file nor a folder keeps the existing error, even under a tombstoned name. Folders and files with
contents can hold the user's only copy, such as a new file saved under the name of a file that
the NAS removed, and `nil` deletes a folder's children too [H]. The NAS is never written. If M4
shows retry storms, propose `deletionRejected` and `cannotSynchronize` to the user.

**Restart:**

- **App launch:** delete `tinymounter-<UUID>.stage` regular files in `ReaderStaging` before any
  reader session connects, when no fetch can be in flight. Load the settings, finish `removing`
  records and `retiredDomainID` removals, clear `paused` (M6), and call
  `NSFileProviderManager.add` for every record, which is idempotent [H]. Start a share session
  when its mount appears, then signal and relist (flow 5). Unknown domains are logged and never
  removed.
- **Extension start:** delete `tinymounter-<UUID>.stage` regular files in its temporary directory
  that were created before this process started and are not active; log `temp_removed=N` and
  the stage files left. The header requires this cleanup [H]. Planners start empty. The first
  fetches can wait for the reader connection within the shared 5 s startup window described in §6.
- **`fileproviderd` restart:** anchors and tombstones are durable, so the system resumes.
- **macOS restart:** the share stays unmounted until the user connects it in Finder, and sessions
  never mount it. That kept files stay readable across a full restart is not tested.
- **Crash in a catalog write:** the transaction rolls back (WAL, `synchronous=FULL`).

**Domain steps survive a crash.** Add: create the catalog, list the location root into it, save
the record, `add`. Remove: save the kept paths if the user asked, save `removing = true`, `remove`
in the D3 mode, delete the catalog, delete the record. Apply: create the new catalog and list its
root, save the record with the new `domainID` and `retiredDomainID`, `remove` the old domain with
`.removeAll`, delete its catalog, clear `retiredDomainID`, then `add` the new domain. Launch
reconciliation finishes any step that a crash interrupted. A catalog without a record is deleted
at launch.

**Old fixture domains.** No migration code. Before the M4 build is installed, the main agent
removes the six fixture domains with `.removeAll` (D3). If one is missed, its extension finds no
catalog and returns `serverUnreachable`, never `noSuchItem`.

**Leaks and diagnostics.** The app never mounts. Outside a listing or a transfer it holds only
`O_EVTONLY` descriptors on the share. The shell can't read the App Group [V], so the app logs
counts at launch and on `SIGUSR1`: catalogs, items, tombstones, listed folders, stage files,
descriptors and RSS. The extension logs its temporary stage-file count after its sweep, and its
planner count with each fetch.

**Logs.** Subsystem `dev.tinymounter.prototype`; categories `fetch`, `source-reader`, `listing`,
`share`, `catalog` and `actions`. Request IDs, item UUIDs, counts, sizes, times and error codes
only.

## 8. UI

**Scenes.** A regular app with a Dock icon, a `MenuBarExtra` in `.menu` style and the Settings
window, at least 780 × 540 and resizable. The window opens at launch when there are no locations,
and when the user clicks the Dock icon. Closing it keeps the app running, because the reader must
stay up. Quit warns during downloads with the approved text.

**Sidebar.** A `List(selection:)`: Locations (records and drafts in order, each with a status
symbol plus a VoiceOver label, or "Not added"), then General, Storage, Servers and About.
`.searchable` filters locations by name. At the bottom: `+` (New Location, ⌘N) and `−` (Remove
Location…, or Cancel for a draft). The shortcut menu has Show in Finder, Duplicate (⌘D) and Remove
Location…; the first two are disabled for drafts.

**Location pane** (`Form`, `.grouped`):

1. Header: name, server › share › folder, status line, Show in Finder.
2. Source: Server, Share, Folder (placeholder "Full share", with completion and Select…), Name.
3. Connection Mode: File Provider, selected; Server volume disabled, with its mockup description.
4. Keep Downloaded: each request as a path in the location, with "Requested" or "Not on the
   server", and `−`.
5. Remove Location….
6. Bottom bar. For a draft: "Finder does not show this location until you click Add.", with Cancel
   and Add (also Return). For a changed source: the mockup's Apply text, with Revert and Apply.

| Action | Settings | File Provider | Catalog |
| --- | --- | --- | --- |
| Add Share… (Servers `+`, Server picker) | `NSOpenPanel` at `/Volumes`, folders only; must be an smbfs volume root with `MNT_LOCAL` clear; save the grant | — | — |
| New Location (`+`, ⌘N) | draft with the first grant and an empty folder; the name follows the share | — | — |
| Duplicate (menu, ⌘D) | draft below the original with the same grant and folder and no Keep Downloaded requests, "<name> copy" made unique, Folder focused with its text selected | — | — |
| Add | the folder must list completely beneath the share root within 10 s; save the record; take the saved keep paths inside the folder | `add(domain(UUID, name))` | created and root listed first; saved paths resolved |
| Cancel | drop the draft; select the original | — | — |
| Name (Return or focus loss) | unique name saved | `add` again with the same ID and the new `displayName` [H] | `setRootName` |
| Revert | drop the edit | — | — |
| Apply (server, share or folder changed) | confirmation; record updated in steps (section 7) | `remove(old, .removeAll)`, then `add(new UUID)` | new catalog; old one deleted |
| Remove Location… | confirmation with "Save the Keep Downloaded list" (selected); `removing`, then deleted | `remove(domain, .removeAll)` | kept paths saved if selected; deleted |
| Show in Finder | — | `getUserVisibleURL(for: .rootContainer)` | — |
| `−` on a request | — | signal `.workingSet` | `setKeep(false)`, or the saved path discarded |
| Finder Keep Downloaded, Allow Removal | — | `performAction`, XPC `keep`, signal | `setKeep(true or false)` |
| Open at login | `SMAppService.mainApp` register or unregister | — | — |

The name follows the last folder component until the user types one. Drafts never touch File
Provider. Connection Mode can't change in phase 2, so Apply follows only a source change. Apply
removes before it adds, so two domains never share a display name or a disk location [H].

**Folder completion**, built last (M8). While the user types in Folder, the app lists the typed
parent folder on the metadata lane, 150 ms after the last keystroke, and suggests at most 50
subfolders whose names start with the typed text. It never lists more than one folder at a time.
Select… stays.

**Other panes.**

- **Servers:** one row per grant with host, "account · share", Connected or not connected, Select
  Again…, `+`, and `−` (disabled while a location uses the grant).
- **General:** Open at login, Show in menu bar and Notifications.
- **Storage:** for each location, the disk space that its downloaded files use, and Remove
  Downloads, which evicts the downloaded files that are not kept, after a confirmation that the
  files on the server do not change. Then the total. The space is the sum of the catalog sizes of
  the files in the materialized set [A, M8]; files that are open stay (EBUSY) and are counted.
- **About:** "Version 0.1 (prototype)" and diagnostic counts with Copy.

**Menu bar.** A drive symbol, `arrow.down.circle` during downloads (SF Symbols has no drive with a
transfer badge) and a warning badge on a problem. One line per location with its state, or "42%
downloaded" while it downloads, from `globalProgress(for: .downloading)` on the domain's manager
[V, M7]. A menu-style `MenuBarExtra` shows only menu items, so there is no progress bar; one would
need an `NSStatusItem` with a custom item view. Then Pause Downloads or Resume Downloads,
Settings… and Quit tinymounter.

**Finder actions**, in `Provider-Info.plist` under `NSExtension` ›
`NSExtensionFileProviderActions` (key names [D]):

| Identifier | Name | Activation rule |
| --- | --- | --- |
| `dev.tinymounter.action.keep-downloaded` | Keep Downloaded | `SUBQUERY(fileproviderItems, $i, $i.userInfo.keep == 0).@count > 0 AND SUBQUERY(fileproviderItems, $i, $i.userInfo.keep == nil).@count == 0` |
| `dev.tinymounter.action.allow-removal` | Allow Removal | the same, with `keep == 1` |

Only files publish `userInfo["keep"]`, so a selection with a folder matches neither rule. Kept
files report `.downloadEagerlyAndKeepDownloaded`, except while paused; other items keep
`.downloadLazily`, as today. `performAction` sends at most 100 IDs per message, to stay within
4096 bytes, and accepts at most 1,000 IDs per action. With the app quit, or with no reply in
10 s, it fails with `serverUnreachable`. Finder's own Download Now and Remove Download stay.

**Strings.** All UI text lives in `Prototype/App/UIText.swift`, so the STE checker reads one file.
Reused from the mockup: the sidebar and pane labels, "Not added", "Connected", "Full share",
"Select…", "Not on the server", the File Provider and Server volume descriptions, the Add-bar and
Apply texts, "Remove this location from this Mac. The files on the server do not change.", "Not
available in this version.", "Quit tinymounter" with its warning, and "Version 0.1 (prototype)".
New strings, to check with the STE checker and by hand: "Add Share…", "Select Again…", "Select
the share that you connected in Finder.", the new status texts in section 7, "Requested", "To
keep a file downloaded, right-click it in Finder. Then click Keep Downloaded.", "Save the Keep
Downloaded list", "Pause Downloads", "Resume Downloads", the Storage and notification texts, and
the reworded usage descriptions. Status text names the grant's host, never a fixed name.

## 9. Milestones

| # | Milestone | Question it answers | Needs |
| --- | --- | --- | --- |
| M1 | Core library | Do the catalog, listing, safe paths, registry and error classifier pass unit tests and a read-only NAS listing? | — |
| M2 | Remount identity (main agent) | Do `st_dev`, file IDs, mtime and ctime survive an eject and reconnect? | — |
| M3 | Share grant gate and spikes | Does a saved share-root grant reach depth 2 in the sandboxed app? How does Finder show custom actions? Can the app read a domain's materialized set and its download progress? | M1 |
| M4 | Browsing on the catalog | Does Finder browse lazily from persistent IDs, with no deletion from failures, and does relisting find NAS changes? | M2, M3 |
| M5 | Reads by item | Do range and full reads, per-item read-ahead and staging cleanup work? | M4 |
| M6 | Keep Downloaded and Pause | Do Finder actions record durable requests, and does Pause stop only background downloads? | M5 |
| M7 | Settings window, menu bar and notifications | Does the phase 2 UI replace the harness, with saved keep lists, progress and notifications? | M6 |
| M8 | Storage pane and folder completion | Are the space totals right, and does Remove Downloads keep kept files? | M7 |
| M9 | Exit validation | Do the exit criteria hold, with evidence? | M8 |

Reads are unavailable between M4 and M5, so M4 and M5 land together. Every milestone ends with
the AGENTS.md checks, the docs it made wrong fixed, and its results in writing.

M5's runtime check also covers the D2 deadline (section 6, step 5), which no unit test reaches
from end to end:

- Two locations: location A runs two Download Now fetches that keep both app workers busy, then a
  file in location B is opened. Record any `userCancelled` or `stalled=1` line for B. If the
  system cancels B, propose to the user a demand-read priority or a worker kept for each location.
- A transfer that stops after `started` logs `stalled=1` about 60 s after its last progress. A
  share outage doesn't show this, because the mount's own timeout (about 30 s) makes the app reply
  first, so stop the app's process with `SIGSTOP` during a transfer, then continue it. M6 ran
  this check on 2026-10-16: `stalled=1` came 60.0 s after the stop
  ([results](results/2026-10-16-keep-pause.md)).

M1 also built `setKeep`, `setPaused`, `keptItems` and `ShareHealth`, which belong to M6 and M4.
They stay in M1: D5's kept-file rule needs `keep` in its tests. M4 extends `ShareHealth` with the
needs-grant state (`notAuthenticated`) and with the errors that each recovery resolves (flow 4).

## 10. Unverified assumptions and open questions

### Verified in M3

On 2026-10-12 in the signed, sandboxed app on macOS 27.0.1 in the VM:

- The saved app-scoped share-root grant listed a depth-2 folder and three child folders, and
  opened a file at depth 4. It worked after relaunch, with one resolution per session, no new
  privacy prompt and no new mount. Only a healthy share was tested.
- Finder showed Keep Downloaded or Allow Removal as a separate context-menu item after the
  fixture item was republished with `userInfo.keep`. The rule switched with the harness's keep
  state. Finder's own Keep Downloaded was absent; its Download Now and Remove Download remain.
  An Allow Removal click reached the extension. The spike logs only; M6 implements the action.
- Count Downloads read the materialized set (3 items, including 2 folders) and download progress
  (1 of 1). Active progress updates and disk-space accounting remain unverified.

See the [M3 results](results/2026-10-12-share-grant.md).

### Verified in M4 and M5

On 2026-10-14 and 2026-10-15 in the signed app in the VM ([M4 and M5
results](results/2026-10-14-catalog-browsing-reads.md)):

- The read-only WAL connection in the extension saw the app's commits while Finder paged another
  folder, and opened the catalog after a clean app quit and an extension kill.
- Read-only `fileSystemFlags` on folders did not disturb materialization. Terminal writes in the
  location failed with EPERM before any mutation call reached the extension.
- First listings stayed far below the 5 s wait. All 24 finished in time; the longest wait was
  259.5 ms (613 entries, queued behind another listing). The slowest listing was a launch relist
  of 2,001 entries: 379.7 ms.
- Finder does **not** retry a failed folder after the app relaunches and signals
  `serverUnreachable` resolved. It shows "Your device couldn't connect to the server" with Try
  Again until the user clicks it.
- Remove Location with `.preserveDownloadedUserData` moved the 5 fully downloaded files, not the
  partly downloaded ones, into a dated, read-only (`uchg`) folder next to the location in
  CloudStorage. Remove Location now uses `.removeAll` (D3).
- A one-chunk (16 MiB) read-ahead window avoided the system materialization race in 0/11
  moving-boundary stress trials, against 5/5 failures at 128 MiB. IINA's playback and seeks were
  unchanged, and it fetched less data that IINA never read
  ([comparison](results/2026-10-15-read-ahead-window.md)).

### Verified in M6

On 2026-10-16 in the signed app in the VM ([M6 results](results/2026-10-16-keep-pause.md)):

- Keep Downloaded and Allow Removal changed one row each and switched the Finder action. All 6
  completed eager downloads of kept files were system requests. With the app quit, the action
  failed with `serverUnreachable`.
- Pause cancelled a running 2.74 GB eager download in the same millisecond as its commit, and the
  system's retry failed at once. A user read and Finder's Download Now still downloaded, and
  read-ahead stopped and started again with Resume. Resume and a relaunch downloaded the files
  kept while paused. Cancelling a running speculative fetch didn't fail the read that waited on it
  (3 of 3), and a kept file's download could be removed while paused.
- A kept file in a folder that the system never enumerated didn't download in 74 s. It downloaded
  0.14 s after the folder was listed.
- D2: a fetch failed 60.0 s after `SIGSTOP` of the app, and after `SIGCONT` the app released the
  job and left no stage file.

### Unverified assumptions

| Assumption | Checked in |
| --- | --- |
| File IDs, mtime and ctime after a second remount, a server restart, a rename or a replacement (one remount measured: unchanged) | M2, M9 |
| Kept files stay on disk while paused when the system needs the space (2.5 min without disk pressure measured) | not tested: it needs a full disk |
| The system applies a root update from the working set, and a `displayName` update renames the CloudStorage folder | M7 |
| Notification permission and `SMAppService` work from the build folder | M7 |
| Materialized-set sizes give the disk space used; partly downloaded files make it an estimate | M8 |
| Two domains on the same folder, or on nested folders, don't affect each other | M9 |
| NSWorkspace mount notifications reach the sandboxed app on eject | M9 |
| The Finder mount is soft (about 30 s timeout), not hard (up to 600 s) | M9 |
| After an eject, held `O_EVTONLY` smbfs descriptors fail `fstatfs`, and other calls give ENOTDIR, EIO or EBADF (modelled only with revoke(2) on a pty) | M9 |
| A volume mounted inside the share gives `pathRejected` (modelled only with `/` and the data volume) | not tested: it needs a mount inside the share |
| On smbfs, `fstatat`'s `st_ino` equals the listing's `ATTR_CMN_FILEID` (true in M1's sweep; not rechecked in the app) | M9 |
| After a case-only rename on the NAS, `fstatat` of the old name finds the renamed item (modelled only on case-insensitive APFS) | not tested: it needs a change on the NAS |
| smbfs errno values for authentication failures | not testable without a server change |
| Kept files stay readable across a full macOS restart; physical-Mac behaviour | needs the user or real hardware |

### Defaults (D9)

M3's slowest first listing, 4134.7 ms for 23 entries with the NAS cache state unknown, was close
to the 5 s first-listing wait. M4's 24 first listings waited at most 259.5 ms. The deadline path
itself was not reached; the default is unchanged.

| Default | Value |
| --- | --- |
| Symlinks, special files, invalid names, key collisions | not shown; counted in logs |
| First-listing wait in the extension | 5 s |
| Background relist when a listed folder is enumerated again | listing older than 60 s |
| Relisting at launch and reconnect | materialized folders only, one at a time |
| Operation or transfer stall that marks a share unresponsive | 15 s |
| Probe interval while unresponsive; mount-table poll | 5 s; 10 s |
| Entries per folder | at most 100,000 |
| Pending listings per session | 16 |
| Read-ahead planners kept | 8 items |
| Initial reader connection deadline; cancellation polling | 5 s from service creation; 100 ms |
| Keep IDs per message; per action | 100; 1,000 |
| Keep reply wait in the extension | 10 s |
| Progress message interval; fetch stall deadline from `started` (D2) | 0.5 s; 60 s |
| Working-set signal debounce; D5 confirmation listing | 200 ms; 15 s |
| Folder completion | 150 ms after typing; 50 suggestions |
| Notifications | one per share per outage |

### Open questions

- Does the system call `enumerateChanges` on folder or item enumerators in a replicated domain?
  Both implement it, so either case works.
- Finder keeps a failed folder's error until Try Again (M4). Individual folder signals are
  ignored for replicated providers, and requesting a directory enumeration restored children
  without clearing the banner in the October 15 follow-up. Should a notification ask the user
  to click Try Again? User approval is required before adding this UI; it is not in M7, by the
  user's decision.
- A mount reached by another address or account doesn't match the grant and shows as not
  connected. Is matching on host and share instead worth its risk in phase 3?
- Can the extension start the app when it needs the reader? No API is known; the plan relies on
  Open at login.
- M4 counted no mutation calls: Terminal's touch, mkdir, rm and mv failed with EPERM before the
  extension saw them. Change `deleteItem` to `deletionRejected` and `createItem` and `modifyItem`
  to `cannotSynchronize` only if another app reaches them.
