# Connection layer for 0.2.0

Date: 2026-11-08. Implementation: steps 1–4 on `feat/smb-connection-layer`; Server Volume sign-in
(Decision 1) on `feat/server-volume-netfs-signin`
([results](results/2026-11-08-connection-layer.md)).
Decision status: accepted by the user on 2026-11-08, with the
[decisions](#decisions) below and the results of the
[password login](results/2026-11-08-password-login.md) and
[change notification](results/2026-11-08-smb-change-notify.md) spikes. UI copy is proposed for
[ui-design.md](ui-design.md) review. See the
[roadmap](roadmap.md#app-owned-smb-login-for-file-provider-locations-planned-for-020).

File Provider locations stop using the hidden macOS SMB mount. TinyMounter signs in with a
password that it keeps in its own Keychain item, opens its own SMB sessions for every operation,
and discovers NAS changes with SMB2 `CHANGE_NOTIFY`, one watch per discovery folder, plus the
existing periodic relisting. One
protocol-neutral layer, declared in
[`RemoteConnection.swift`](../Sources/TransferCore/RemoteConnection.swift), carries sign-in,
connection state, listing, reading, the existing write seams and change watching. SMB is its only
implementation. Server Volume mode keeps its mount.

The interface comes from what the app calls today, not from a general design: every method on
`RemoteSession` exists on `SMBEdit`, and all but `directoryIdentity` have callers outside it.
`directoryIdentity` replaces the mount-identity proofs. The interface names no SMB concept, so a
second protocol could implement it, but nothing here is built for that protocol.

## What the mount does now, and what replaces it

| The mount supplies | Today | In 0.2.0 |
| --- | --- | --- |
| Login | `SMBRename.c` reuses the mount's cached NTLM credential (`gss_iter_creds_f`); guest has a separate path | `RemoteClient.openSession(_:password:…)` with the password from `CredentialStore`; guest is removed |
| Proof that the share is present | `ShareSession` holds an `O_EVTONLY` root descriptor; `MountIdentity.requireMounted` checks it between steps | The SMB session itself. Proofs that need a stable location folder compare its `RemoteFileIdentity` (`directoryIdentity`) instead of a mount identity and inode |
| Share access grant | `NSOpenPanel` → `ServerGrant` bookmark, resolved per session; a second write bookmark per location | Nothing. Read only is a plain setting; the account's server permissions apply |
| Change discovery | Up to 64 kqueue vnode watches on mounted folders (`DirectoryWatch`) | Up to 64 `CHANGE_NOTIFY` watches per share, one per discovery folder, on a dedicated connection; `DirectoryRefresh` relists as now |
| Health and reconnect | Mount table polling, `willUnmount`/`didUnmount`, NetFS remount with backoff, `fstatat` probes | `ConnectionHealth` on the results of SMB calls; probes open a session; wake and network-path changes probe at once |
| Folder Select… | `NSOpenPanel` inside the mount | An in-app folder browser that lists folders over the connection (decision 3) |

## Interfaces

### Shared, in TransferCore

[`RemoteConnection.swift`](../Sources/TransferCore/RemoteConnection.swift) lands first and holds
only declarations:

- `RemoteProtocol` (`.smb`) and `ServerAccount` (protocol, host, account): the key of a saved
  password and of a server record.
- `CredentialStore`: `password(for:)`, `savePassword(_:for:)`, `deletePassword(for:)`.
- `ConnectionState`: `notConnected`, `connected`, `unresponsive`, `needsSignIn`. It replaces
  `ShareHealth.State`; `needsSignIn` replaces `needsGrant`.
- `RemoteClient`: `shareNames(on:password:)`, `openSession(_:password:folder:progress:)`,
  `openWatcher(_:password:notice:)`.
- `RemoteSession`: `UploadRemote & FileRenameRemote & FolderMoveRemote & DeletionRemote`, plus
  listing (`directoryIdentity`, `list`, `confirmMissing`), reading (`protectAncestors`,
  `readMetadata`, `transfer`) and the writes that are not seams yet (`overwrite`,
  `createFolder`, `nameFolder`, `renameSourceEntry`, `allowPublishedReads`,
  `captureFolderMoveProofs`, `releaseDeletionTraversal`).
- `ChangeNotice` (`changed(RelativePath)`, `lost(RelativePath)`, `ended(SourceFailure)`) and
  `RemoteWatcher` (`watch(_ folders:)`, `cancel()`). A watcher is one connection that holds one
  watch per folder in the set it was last given; paths start at the share root.

Errors stay `SourceFailure`. A refused account or password is `notAuthenticated`; an unknown
share is `missing`; a share the account may not open is `noPermission`. No new error type is
needed.

`captureDeletionTraversal(of:recursive:expecting:)` joins `RemoteSession` in step 3, when
`DeletionExpectation` moves from `SMBEdit.swift` to `RecursiveDeletion.swift`. The protocol has
no default arguments; callers pass `progressed: {}` where they relied on one.

### App types

```swift
/// Replaces ShareAccess and ShareSession. One per saved share.
final class ShareConnection: @unchecked Sendable {
    let shareID: UUID
    let editNamespace: EditNamespace
    init(share: ShareAddress, client: any RemoteClient, credentials: any CredentialStore,
         onRecovery: @escaping @Sendable ([SourceFailure]) -> Void)
    var state: ConnectionState { get }
    func onStateChange(_ handler: @escaping @Sendable (ConnectionState) -> Void)
    func refusal() -> SourceFailure?
    /// Opens a session, runs `body` on the caller's thread, records the result in the health.
    func withSession<T>(folder: RelativePath, progress: Progress,
                        _ body: (any RemoteSession, @escaping Progressed) throws -> T) throws -> T
    func enqueue(_ work: @escaping @Sendable () -> Void)
    func folderNames(in path: RelativePath) async throws -> [String]
    func connect()
    /// Sign In Again… saved a new password: needsSignIn ends and a session starts.
    func credentialsChanged()
    /// Replaces the watched set (at most 64 folders); one watcher connection per share.
    func watch(folders: Set<RelativePath>, notice: @escaping @Sendable (ChangeNotice) -> Void)
}

/// Generic-password items in the login (file-based) keychain; app-only, not synchronized.
struct KeychainCredentialStore: CredentialStore { … }

/// libsmb2 with a password. SMBEdit conforms to RemoteSession.
struct SMBClient: RemoteClient { … }

/// The mount table, NetFS mount, remount and eject handling, for Server Volume mode only.
final class ServerVolumeMount { … }
```

`ConnectionHealth` (TransferCore) is `ShareHealth` without mount events and without the
separate direct-call stall limit, because every call is now direct. Its probes back off from 5 s
to at most 60 s and restart at once on wake or a satisfied network path. `notAuthenticated`
enters `needsSignIn`, which refuses every request without I/O.

Rules the implementation must keep:

- **No repeated failed logins.** Each operation opens its own session, so a wrong password would
  otherwise fail once per request and can lock the NAS account. The first `notAuthenticated`
  stops all I/O for that server until a new password is saved.
- The password stays in memory only inside `ShareConnection`, read from the store at the first
  session and again after `credentialsChanged()`. It never reaches Settings.json, logs, process
  arguments, URLs or XPC. Logs name servers and shares by record ID only.
- The Keychain item: `kSecClassGenericPassword` in the login (file-based) keychain, service
  `dev.tinymounter.<protocol>`, account `<account>@<host>` with the host lowercased, not
  synchronizable, with no new entitlement. The data protection keychain needs a provisioning
  profile, which the Personal Team build lacks (decision 4). The extension never reads the item.
  A generic-password item can't match Finder's internet-password item for the same server, so a
  read never returns Finder's password and Forget never deletes it. A build signed by another
  certificate makes macOS ask once for the login keychain password.
- The password goes from the Keychain bytes straight to C, without a Swift `String`, and is read
  again for each connection. The vendored `smb2_clear_password()` zeroes libsmb2's copies right
  after connect.
- SMB 3 only, signing and encryption required, and no guest session: the vendored libsmb2 refuses
  a guest fallback and drops the `ntlm:<hex>` password form.
- Only `STATUS_LOGON_FAILURE`, `STATUS_PASSWORD_EXPIRED` and `STATUS_PASSWORD_MUST_CHANGE` enter
  `needsSignIn` (the user, 2026-11-08: a new password fixes these). libsmb2 reports a logon
  failure as `-ECONNREFUSED`, so classification reads `smb2_get_nterror()`. A locked or disabled account is `noPermission` and
  also stops retries until the user acts.
- When the network path is not satisfied, requests fail at once with `notConnected`.

## What current types become

| Current | 0.2.0 |
| --- | --- |
| `ShareAccess` (`ShareAccess.swift:142`) | `ShareConnection` for locations; mount code moves to `ServerVolumeMount` |
| `ShareSession` (`ShareAccess.swift:22`) | Deleted. `withSession` hands out a `RemoteSession` |
| `LocationSource` (`ShareAccess.swift:771`) | Moves unchanged to `LocationSource.swift`; holds a `ShareConnection` |
| `withWriteSession(_ bookmark:…)` (`LocationUploads.swift:180`) | `withSession` after a `writable` check |
| `LocationSource.writeBookmark` | `writable: Bool`; `configureWriteMode(_ writable: Bool)` |
| `ShareHealth`, `ShareHealth.State` | `ConnectionHealth`, `ConnectionState` |
| `RemountPolicy` | Server Volume only |
| `MountIdentity`, private `MountEntry` | Server Volume only, in `ServerVolumeMount.swift`; `guarding`, `requireSameMount` and the `ReadOnlyFile` extension are deleted |
| `DirectoryWatch` | Deleted; `RemoteWatch` from `SMBClient` |
| `ServerGrant`, `ShareGrantError` | `ShareRecord`; the error is deleted |
| `ServerRecord.address` URL | `ServerRecord.login: ServerAccount` |
| `SMBEdit.init(endpoint:folder:root:progress:)` | Created by `SMBClient.openSession`; no root descriptor |
| `tm_smb_create_folder`/`tm_smb_name_folder` calls in `LocationFolderNaming.swift` | `RemoteSession.createFolder`/`nameFolder` |
| `EditNamespace.shared(_ mountFrom:)` | `EditNamespace.shared(_ share: ShareAddress)` |
| `ShareAddress` | Gains `remoteProtocol`; the `f_mntfromname` parser stays for Server Volume |
| `Notifier.shareChanged(_ grant: ServerGrant, …)` | Takes `ShareRecord`; posts once on entering `needsSignIn` |
| `AppModel.shareStates`, `LocationState.needsGrant` | `ConnectionState`, `LocationState.needsSignIn` |

## Settings shape

A build with this shape rejects earlier `Settings.json` files, because required keys are missing,
and General offers Start Fresh. Nothing converts them.

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var servers: [ServerRecord]
    public var shares: [ShareRecord]
    public var locations: [LocationRecord]
    public var savedKeeps: [SavedKeepList]
    public var serverVolumes: [ServerVolumeRecord]
}

/// One sign-in. Two accounts on one host are two servers.
public struct ServerRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let login: ServerAccount
}

public struct ShareRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var serverID: UUID
    public let name: String
}

public struct LocationRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var shareID: UUID          // was grantID
    public var folder: String
    public var domainID: String
    public var retiredDomainID: String?
    public var removing = false
    public var pendingKeeps: [KeepPath] = []
    public var readOnly = true        // writeBookmark is removed
}

public struct ServerVolumeRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let shareID: UUID          // was grantID
}
```

`DeletionEndpoint` gains the protocol. Outbox and catalog formats otherwise stay. Before this build
goes on the physical Mac, pending changes must finish or be exported (AGENTS.md, "No migrations
before release").

## UI changes

Text is proposed for [ui-design.md](ui-design.md) review.

- **Add Server…** opens a sign-in sheet: Server (for example `smb://home-nas`), Name, Password,
  Cancel and Sign In. Sign In calls `shareNames`. A refusal shows "The server did not accept this
  name and password." in the sheet and saves nothing. Success saves the server record and the
  Keychain item. If the address names a share, the sheet selects it.
- **Add Share…** shows the share names from `shareNames` in a list. It mounts nothing and shows no
  panel.
- **Sign In Again…** replaces Select Again…. It shows in the location header when the state is
  `needsSignIn`, and on the server's row in Servers. It opens the sign-in sheet with Server and
  Name fixed. Saving calls `credentialsChanged()` on every share of that server.
- **Location header**: status "Sign in again." replaces "Select the share again."; Connect stays for
  `notConnected` and starts a connection attempt.
- **Servers pane**: each server shows `account@host`, its state and Sign In Again… when needed.
  Forget on a server deletes its Keychain item and its unused shares. Forget on a share ejects
  nothing for File Provider shares.
- **Read only** off asks for nothing; Confirm Write Access and its panel go away.
- **Folder Select…** opens an in-app folder browser for File Provider locations: a sheet that
  lists the share's folders through `ShareConnection.folderNames`, one level at a time, with
  Choose and Cancel. Folder completion stays.
- **Notification**: one per server on entering `needsSignIn`: "TinyMounter cannot sign in to
  <host>." / "Open TinyMounter Settings and click Sign In Again…."

## What is deleted

- `ShareSession`, File Provider use of `MountEntry`, bookmark resolution and refresh,
  `ShareAccess.makeGrant`, `connectedShares` for locations, the `willUnmount`/`didUnmount`
  handling for locations.
- `DirectoryWatch.swift`. The 64-watch limit per share stays, now for `CHANGE_NOTIFY` watches.
- `cached_principal`, `credential`, the guest branch and `-framework GSS` if nothing else uses it.
- `AppModel.writeGrant`, `selectShare`, `chooseConnectedShare`, `acquireShare`'s mount and the
  hidden-mount cleanup; `selectFolder` for File Provider drafts.
- `LocationController.saveGrant`, `saveWriteGrant`, `mountPath`, `shareMounted` for locations.
- `DirectoryListing.list(locationRoot:…)`, `confirmMissing(…locationRoot:…)` and
  `ReadOnlyFile(directoryFD:relativePath:expected:)`, which only tests call now, with their tests.
- The UI strings for grants, write grants, hidden mounts and other-account mounts.
- `com.apple.security.files.bookmarks.app-scope` if no bookmark remains. The export panel keeps
  `files.user-selected.read-write`.

## Implementation steps

Step 0 is this commit. Steps 1 and 2 run fully in parallel. Steps 3 and 4 start in parallel on
their new files and TransferCore parts, and finish after their dependencies merge. Each step is a
PR into one integration branch, merged in the order 2, 1, 3, 4; `main` gets the stack after step 4.
Every commit builds and passes `Tools/run-checks.sh`. This differs from the earlier
sequential plan (login, then notifications, then health) so that agents own separate files.

| Step | Owns | Depends on |
| --- | --- | --- |
| 1. Sign-in and credentials | New `Prototype/App/KeychainCredentials.swift`, `Prototype/App/SignInSheet.swift`, `Prototype/App/FolderBrowser.swift` (takes a `folderNames` closure; step 3 supplies the connection); `SettingsView.swift`; `UIText.swift`; the Servers section of `AppModel.swift`; `ServerRecord` in `LocationSettings.swift`; `SettingsTests.swift`; `ui-design.md` | 0; merges after 2 |
| 2. SMB client | `Prototype/SMB/SMBRename.c`, `SMBEdit.c`, both headers; `Prototype/App/SMBEdit.swift`; new `Prototype/App/SMBClient.swift`; a `Tools/` check against the built library | 0 |
| 3. Connection layer and mount removal | `ShareAccess.swift` split into `ShareConnection.swift`, `LocationSource.swift`, `ServerVolumeMount.swift`; `ShareHealth.swift` → `ConnectionHealth.swift`; `ShareMount.swift`; `DirectoryListing.swift`; the rest of `LocationSettings.swift`; every `Location*.swift`; `LocationController.swift` except discovery; `AppModel.swift` location actions; `Notifier.swift`; `App.entitlements`; their tests; `architecture.md`, `prototype.md` | 1, 2 |
| 4. Change watching | New `Prototype/SMB/SMBNotify.c` and header (one connection and thread per share, non-tree watches, filter `0xF5F`, 64 KiB buffer, request timeout cleared, re-arm in the completion, asynchronous echo every 60 s, handle close to stop), `Prototype/App/SMBWatch.swift`, `Prototype/App/LocationChangeWatch.swift`; `DirectoryWatch.swift` deletion; discovery in `LocationController.swift`; a path-to-folder lookup in `Catalog.swift`; `DirectoryRefresh.swift`; results log and README status | 0 for the C and watch code; 3 for wiring |

Each step that adds files runs `python3 Tools/generate-project.py` and commits the project with
them; the first step that uses `RemoteConnection.swift` adds it to `app_paths`. After step 3,
discovery is periodic relisting only, the accepted fallback, until step 4 merges.

### Step 1 checks

`swift test` covers the `ServerRecord` and `ServerAccount` coding and matching. In the signed VM
app, against the disposable fixture:

1. A wrong password shows the refusal, saves no record and no item, and the fixture's log shows
   one failed logon.
2. A correct password saves the server; Add Share… lists the fixture's shares without a mount
   (`mount | grep -c smbfs` is 0) and without a panel.
3. The password does not occur in `Settings.json`, the app's containers or
   `log show --predicate 'subsystem == "dev.tinymounter.prototype"'` for the run.
4. After relaunch, the app reads the item without a Keychain prompt. Finder's own item for the
   fixture is unchanged.
5. Sign In Again… replaces the item; Forget deletes it, and the next Add Server… asks again.

### Step 2 checks

`Tools/run-checks.sh`, plus a library check in the VM with the password from a VM-only file:

1. Sign-in succeeds; a wrong password returns `notAuthenticated` from one attempt; a missing
   share returns `missing`; a share the account can't open returns `noPermission`.
2. `shareNames` lists the fixture's disk shares and leaves out `IPC$` and other special shares.
3. The existing direct-SMB checks pass over password sessions: listing, a checksum read, upload,
   overwrite, rename, folder move and permanent deletion on the fixture.
4. Signing and encryption are negotiated as with the cached credential today.

### Step 3 checks

`Tools/run-checks.sh` and the signed VM app:

1. A 0.1.2 `Settings.json` is rejected and Start Fresh follows; no conversion runs.
2. Through add, browse, read, Keep Downloaded, upload, rename, move and Delete Permanently…,
   `mount` lists no SMB mount and no panel appears.
3. The M21–M26 signed Finder checks still pass on the fixture.
4. A changed fixture password moves every location of that server to Sign In Again… after the
   first refused request, with no further logon attempts. After Sign In Again…, pending uploads
   retry and Finder's errors clear.
5. With the fixture's SMB service stopped, the location becomes unresponsive; after a restart it
   recovers within one probe interval. Wake and a network-path change probe at once.
6. Server Volume checks pass: add, Show in Finder, intentional eject, reconnect after relaunch and
   busy-volume refusal.
7. Logs hold no host, account, share, path or password.

### Step 4 checks

In the signed VM app, with changes made on the fixture by another client:

1. A new, changed, renamed and deleted file in an open discovery folder, including one three
   folders below the location folder, appears in Finder within 3 s, against up to 60 s without
   notices. A content edit in a folder that is not watched is found by the 60 s relisting.
2. With `change notify = no` on the fixture, the 60 s relisting still finds each change.
3. After a fixture SMB restart, `ended` is followed by a new watch once the share reconnects.
4. Each share holds one watch connection and at most 64 watches (`lsof -i :445` in the VM).
   `STATUS_NOTIFY_ENUM_DIR` relists that folder; any other completion that the app did not cause
   reconnects with backoff and relists every watched folder.
5. The app's own uploads cause at most one listing per folder per 2 s (`DirectoryRefresh`).

### Step 4 wiring after step 3

`SMBNotify.c`, `SMBWatch` and `LocationChangeWatch` are built and checked against the fixture
([results](results/2026-11-08-change-watching.md)); nothing calls them yet. Wiring them:

1. `SMBClient.openWatcher` returns `SMBWatch(share:password:notice:)` with the Keychain bytes.
   `connect_share` in `SMBNotify.c` and `SMBWatch.connectFailure` switch to step 2's shared
   password connect (with `smb2_clear_password()`) and sign-in classification.
2. `ShareConnection` owns one `LocationChangeWatch(limit: SMBWatch.folderLimit, …)`. Its `open`
   throws `refusal()` without I/O when the state refuses requests, and otherwise reads the
   password and calls `client.openWatcher`. `excluded` is `editNamespace.isReserved`. `refresh`
   hops to the main actor and calls `discovery[domainID]?.changed(id)` for each ID, or
   `refreshAll` for nil, only while `canDiscover`. Several locations share one share, so this
   replaces the single-set `watch(folders:notice:)` above with `setFolders(_:domainID:root:)`
   and `removeLocation(_:)`.
3. `discoverChanges` passes each location's discovery folders as `WatchedFolder` (ID, parent
   ID, catalog path below the location folder) to `setFolders` instead of
   `setDiscoveryFolders`; a dropped, turned-off or removed location calls `removeLocation`.
   `Catalog.relativePath(of:)` and `item(id:)` give the path and parent, so no new catalog
   lookup is needed: notices name the watched path, which the plan maps back to its IDs.
   Watches then start with the membership, not after each listing.
4. Delete the watch code in `LocationSource.listSettledOnLane`, `onDirectoryChange` and its
   handler, `ShareSession`'s watch table, `keepWatches`, `drainWatches`, and
   `DirectoryWatch.swift` with its generator entry. `canDiscover` drops `hasSession`.
5. `LocationFolderMoves.drainFolderMove` and the deletion admission call
   `changeWatch.drain(below:)` after their reservation. It returns once the server closed the
   handles; on a 10 s timeout the watcher ends its connection instead, so it does not throw.
6. `reconnect()` follows a state change to `connected`, `credentialsChanged()` and wake.
   `ShareConnection` teardown calls `cancel()`.
7. Then run the step 4 checks above in the signed VM app.

## Spike answers

- **Login** ([results](results/2026-11-08-password-login.md)): libsmb2's own NTLMSSP signs in
  with the password and seals SMB 3.1.1 with no mount and no GSS cache, so `-framework GSS` can
  go. Wrong password: `STATUS_LOGON_FAILURE`; locked account: `STATUS_ACCOUNT_LOCKED_OUT`. Account
  forms and share enumeration (`IPC$` filtering) are step 2 checks.
- **Change notifications** ([results](results/2026-11-08-smb-change-notify.md)): a tree watch
  misses content writes below the watched folder, so step 4 uses one non-tree watch per discovery
  folder. A pending notify does not block other requests on its connection; 64 and 1,024 watches
  per connection worked, 4,000 exhausted the fixture's notify process. `STATUS_NOTIFY_ENUM_DIR`
  means "relist this folder". libsmb2's request timeout must be cleared on notify requests, and
  its synchronous `smb2_echo()` is broken. Name form in notices (NFC or NFD) is a step 4 check.

## Decisions

Accepted by the user on 2026-11-08:

1. **Server Volume sign-in.** NetFS gets the saved name and password, so one sign-in serves both
   modes. A separate small change after step 3. Implemented: the app signs in with its SMB
   client first, because smbfs reports a refused password as a missing share
   ([results](results/2026-11-08-connection-layer.md#server-volume-sign-in)).
2. **Server Volume status.** Without the grant, a server volume shows only mounted or not
   mounted, with no unresponsive state. Finder reports a stalled volume itself.
3. **Folder Select….** An in-app folder browser replaces the panel (step 1 builds it, step 3
   connects it).
4. **Keychain.** The login keychain until a paid membership provides a profile.
5. **Real NAS.** A read-only watch check on the user's NAS after 0.2.0 runs in the VM, with the
   user making the changes from another device. Not a prerequisite for the build.

## Appendix: current mount dependencies

Line numbers are from the base of this plan. "FP" marks code that File Provider locations use;
"SV" marks code that Server Volume mode keeps.

### Login

- `Prototype/SMB/SMBRename.c:3` GSS include; `:42–126` `release_lookup`, `credential`,
  `cached_principal` (`gss_iter_creds_f`); `:302–335` `connect_folder_share` uses the cached
  principal, or guest at `:318–322`; `:491–499` `tm_smb_begin_edit` refuses guest. FP.
- `Prototype/SMB/SMBEdit.c:35–43` `tm_edit_connect` takes no password. FP.
- `Prototype/SMB/SMBRename.h:26–35`, `SMBEdit.h:5` signatures without a password. FP.
- `Tools/generate-project.py:159` links `GSS`. FP.
- `Prototype/App/SMBEdit.swift:38–50` connects with the mount's account; `:18`, `:24`, `:815–838`
  keep the mount root and check `MountIdentity` for folder moves. FP.
- `Prototype/App/LocationFolderNaming.swift:83–98`, `:115–131` pin the mount root and call the C
  folder functions with the mount's account. FP.

### Share root, session and mount identity

- `Prototype/App/ShareAccess.swift:21–139` `ShareSession`: `O_EVTONLY` root, `openFolder`,
  `locationRoot`, watches; `:346–445` session start from the mount table and bookmark,
  `openRoot` with `fstatfs`; `:1189–1223` `MountEntry` (`getmntinfo_r_np`, `MNT_DONTBROWSE`). FP, SV.
- `Prototype/App/ShareAccess.swift:303–304`, `:1036–1052` read `session.identity.mountFrom` and
  `session.root` for listings and folder completion. FP.
- `Sources/TransferCore/ShareMount.swift:1–69` `MountIdentity`, `requireMounted`, `guarding`,
  `requireSameMount`, `ReadOnlyFile(directoryFD:…expected:)`. FP; identity also SV.
- `Sources/TransferCore/DirectoryListing.swift:136–180` native listing beneath a mount root; tests only.
- `Sources/TransferCore/ShareHealth.swift:6–8`, `:59–68` `needsGrant`, `mountAppeared`,
  `mountDisappeared`; `:16`, `:81–89` direct-call limit. FP, SV.
- `Prototype/App/LocationEdits.swift:33–36`, `:78–82` endpoint from `mountFrom`, `SMBEdit` with `session.root`. FP.
- `Prototype/App/LocationUploads.swift:155–160`, `:180–194` `withWriteSession` resolves the write
  bookmark, matches `connectedShares`, `guarding(root:)`. FP.
- `Prototype/App/LocationRenames.swift:75–77`, `:255–269`, `:285–288` sessions,
  `requireMounted(session.root)`. FP.
- `Prototype/App/LocationFolderMoves.swift:54`, `:86`, `:159–181`, `:211–226` sessions and
  `MountIdentity` in move admission. FP.
- `Prototype/App/LocationDeletions.swift:102–103`, `:161–163`, `:199`, `:213–262`, `:303–308`,
  `:345` admission root by `openFolder`, inode and `requireMounted`. FP.
- `Prototype/App/LocationDeletionSettlement.swift:10`, `:66–92`, `:155–183` settlement roots as
  `(MountIdentity, inode)`. FP.
- `Prototype/App/EditNamespace.swift:23–36` namespace key from `mountFrom`. FP.
- `Prototype/App/LocationController.swift:1199` deletion settlement matches `connection.mountFrom`. FP.

### Bookmarks and panels

- `Prototype/App/ShareAccess.swift:158`, `:216–232`, `:336–344`, `:387–409`, `:447–473`,
  `:739–762` grant creation, resolution (`.withoutMounting`), security scope and refresh. FP, SV.
- `Sources/TransferCore/LocationSettings.swift:11–126` `AppSettings` with `shares: [ServerGrant]`,
  `writeBookmark(for:)`; `:142–174` `ServerRecord` with optional account and `accepts(account:)`;
  `:176–210` `ServerGrant` (`bookmark`, `writeBookmark`, `mountFrom`); `:225–228`
  `LocationRecord.writeBookmark`; `:415–446` `ShareAddress` parses `f_mntfromname`. FP, SV.
- `Prototype/App/LocationUploads.swift:17–22`, `:142`; `LocationRenames.swift:56`, `:197–205`,
  `:285`; `LocationFolderMoves.swift:29`, `:41`, `:53`, `:84`, `:161`; `LocationDeletions.swift:21`,
  `:52`, `:161`, `:303–305`; `LocationFolderNaming.swift:61`, `:82`; `LocationEdits.swift:23`, `:31`
  write bookmark as the write permission. FP.
- `Prototype/App/AppModel.swift:430–440`, `:482–492`, `:578–613` write grant panel;
  `:1052–1088` `selectAgain`/`selectShare` panel and `makeGrant`; `:1188–1231` Folder Select…
  panel in the mount. FP.
- `Prototype/App/LocationController.swift:238–268` `saveGrant`, `saveWriteGrant`; `:348–356`,
  `:387–406`, `:547–568`, `:1165` write bookmarks on add, apply and write mode. FP.
- `Prototype/App/SettingsView.swift:193`, `:251–257`, `:538–540` Select Again…; `:292` Select…. FP, SV.
- `Prototype/App/UIText.swift:29`, `:36–37`, `:238`, `:289`, `:369–371`, `:382–388`, `:405–416`
  grant, write-grant and mount strings. FP.
- `Prototype/Config/App.entitlements:8` `files.bookmarks.app-scope`. FP, SV.

### Mounting, remounting and the mount table

- `Prototype/App/ShareAccess.swift:4`, `:150–214` NetFS import, poll and tick timers,
  `NSWorkspace` unmount and wake observers, `NWPathMonitor`; `:326–334` `setRemountWanted`;
  `:499–671` unmount handling, mount-table checks, `mountAgain`, `NetFSMountURLAsync` with
  `MNT_DONTBROWSE`, `mountPath(of:)`, `connectedShares`, `unmount`, `checkNow`, `unmountFailed`;
  `:674–699` `fstatat` probe on the root. FP, SV.
- `Sources/TransferCore/Remount.swift:1–76` `RemountPolicy`. SV after 0.2.0.
- `Prototype/App/LocationController.swift:86`, `:204–205`, `:221` remount wishes and launch
  connects; `:280–345` `removeServer`, `removeShare`, `disconnect` (unmount), `shareMounted`,
  `mountPath`, Server Volume add and remove; `:1035–1056` session diagnostics; `:1363–1398`
  `share(for:)`, `updateRemountWanted`. FP, SV.
- `Prototype/App/AppModel.swift:926–1050` `addServer`, `addShare`, `acquireShare` (NetFS mount,
  connected-share choice, hidden-mount cleanup), `connectShare`, `disconnect`; `:1154–1186`
  `chooseConnectedShare`; `:737–745` `showServerVolume`; `:1371`, `:1385` mount status messages. FP, SV.

### Change discovery

- `Prototype/App/DirectoryWatch.swift:1–30` `DispatchSource.makeFileSystemObjectSource`. FP.
- `Prototype/App/ShareAccess.swift:30–32`, `:77–134` watch table, 64-watch limit, drain;
  `:236–242` forwarding; `:872–875`, `:1078–1090` `LocationSource` starts watches after a listing. FP.
- `Prototype/App/LocationController.swift:1176–1180`, `:1293–1357` hints and discovery require
  `access.hasSession`. FP.
- `Prototype/App/LocationFolderMoves.swift:153` and `LocationDeletions.swift:152` drain watches below
  a folder before moving or deleting it. FP.

### State and notifications

- `Prototype/App/AppModel.swift:72–77`, `:208`, `:224`, `:234`, `:246–251`, `:1297–1298`
  `needsGrant` state and text. FP, SV.
- `Prototype/App/Notifier.swift:34–67` keyed by `ServerGrant`. FP, SV.

### Tests

- `Tests/TransferCoreTests/ShareMountTests.swift`, `ListingTests.swift:17`, `:159–167`,
  `:274–325`, `:386–397`, `PathTests.swift:108–138`, `SourceFailureTests.swift:83–84` mount
  identity and native listing. `ShareHealthTests.swift` `needsGrant` and mount events.
  `SettingsTests.swift:362` guest `mountFrom`. `RemountTests.swift` stays for Server Volume.

### Docs that change with step 3

- [architecture.md](architecture.md) §2 transport and credentials rows, §3 "macOS owns passwords
  and SMB mounts", §5 native mounts for grants, §7 M15 vnode watches.
- [prototype.md](prototype.md) "Servers and share grants" and "Deliberate limitations".
- [ui-design.md](ui-design.md) Share, Select Again… and write-grant text.
