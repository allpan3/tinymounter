# Phase 3: offline and NAS changes you can trust

Status: complete. M11 to M17 are implemented and checked in the VM. Since 0.2.0, the app's own
SMB connection replaces the macOS mount that §1, §4 and M15 use
([connection-layer plan](connection-layer-plan.md)). Decision status: accepted. The app connects
the share again by itself, it starts again after a crash but not after the user quits it, and the
user connects in the app, with only the locations in Finder. The design below is the agent's.
M13 to M15 add verified offline status, folder keeps and live change discovery below. M16 adds
local disk-space protection. M17 checks the existing location lifecycle below.

This is phase 3 of [architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria).
It starts with M11, because in M9 macOS dropped the Finder connection after a 70 s outage, and an
app crash stopped every location until the user opened the app again. Evidence tags are those of the
[phase 2 plan](phase2-plan.md).

## 1. Reconnection

When a share that has locations is not mounted, the app asks macOS to mount it with
`NetFSMountURLAsync`, at the grant's address, with no UI. macOS uses the password that the user
saved in the Keychain; the app never reads, asks for or stores it. The mount is the same as
Finder's, so the saved grant matches it and a session starts [V: spike].

- **When.** At launch, at once when macOS unmounts the share (`didUnmount`), and at each
  mount-table poll (10 s) while the share is not mounted. Wake and a network change make the next
  try immediate.
- **Not after an eject.** An eject, from Finder or `diskutil unmount`, posts `willUnmount` first.
  macOS's own unmount after an outage posted only `didUnmount` [V: M9, M11]. After
  `willUnmount`, the app doesn't mount the share until someone mounts it again or the app
  launches again.
- **Retries.** A network failure (such as ETIMEDOUT or EHOSTUNREACH) waits 10 s, then twice as
  long each time, up to 5 min. Any other failure, such as a missing Keychain password, stops the
  tries until the share is mounted again, the Mac wakes or the network changes, so that a wrong
  password is not sent again and again. One try runs at a time.
- **Shares without locations** are not mounted.

The user can still connect in Finder at any time; the app's messages say so already.

## 2. Restart after a crash

The extension starts the app again after a crash, and only then. Quit and Force Quit leave the app
stopped.

- **Run state.** The app keeps an 8-byte state in `RunState` in the App Group, and its launch
  time on the next line. At launch it writes `running`. `applicationWillTerminate`, which runs for
  Quit, logout and shutdown, writes `stopped`. A handler for SIGSEGV, SIGBUS, SIGILL, SIGTRAP,
  SIGABRT and SIGFPE writes `crashed` with `pwrite` to a descriptor opened at launch, resets the
  signal to its default action and raises it again, so the crash report stays the same. It resets
  the action itself, because macOS ignores `SA_RESETHAND` for SIGILL and SIGTRAP: the handler then
  ran again and again, and a Swift trap hung a thread instead of ending the app [V: M11].
- **Force Quit** ends the app with a signal that it can't handle, so the state stays `running`
  and nothing restarts it. A kill by the system for memory is the same.
- **Who restarts it.** When an extension loses the app's reader, and when an extension starts, it
  reads the state. If it is `crashed`, it waits until Launch Services no longer lists the crashed
  app, up to 5 s, then opens the containing app without activating it. Asked sooner, Launch
  Services didn't start the app and showed "The application is not open anymore" in 2 of 9
  restarts [V: M11]. With the wait, the app ran again 58–67 ms after the crash. A new extension
  waits up to 5 s for the reader, so the request that started it can still succeed.
- **No loop.** If the app crashed less than 60 s after its launch, the extension doesn't restart
  it, and reads fail until the user opens it. Only a new extension process restarts it then, once
  60 s have passed since that launch [V: M11].
- **The crash alert.** macOS still shows "quit unexpectedly". Its Reopen button brings the
  restarted app forward with its Settings window, and starts no second instance [V: M11].
- At launch the app logs the previous state, such as `previous_run=crashed`.

## 3. Checks (M11)

In the signed app in the VM:

1. Remove the share with a forced unmount, as macOS does after an outage: a session starts
   again without the user. Measure the time.
2. A 70 s outage: after macOS unmounts the share, the app mounts it when the NAS answers again.
3. Eject with `diskutil unmount`: the share stays unmounted for 2 min. Mount it in Finder: the
   session starts, and a later forced unmount is followed by a mount.
4. Launch with the share not mounted: the app mounts it.
5. `kill -SEGV`, `kill -TRAP` and `kill -ABRT` of the app during a read: the app runs again within
   seconds, and a new read matches the share. Twice within 60 s: the second crash doesn't restart
   it.
6. `kill -9` (as Force Quit does) and Quit: the app stays stopped, also when Finder opens a file
   in a location.
7. No mount and no stage file leaks.

Not testable in the VM: sleep and wake, a network change, and a Keychain without the password.

## 4. Connect in the app (M12)

The user asked to connect in TinyMounter instead of Finder, and to see only the locations in
Finder. M12 keeps the macOS mount; phase 5's own connection would remove it.

- **Add Server…** saves an SMB address independently of its share grants. A server-only address
  requires no mount. Add Share… offers existing connections first, including Finder and hidden
  mounts. Connect Another Share… asks macOS to mount the server URL with `NetFSMountURLAsync`,
  showing its own login dialog and share list. The app never sees the password. A full share URL
  remains accepted in Add Server… and starts share selection after saving the server.
- **The open panel stays.** The sandboxed app can't read a mount that it made (EPERM) until the
  user selects it [V: M12]. So the panel opens on the new mount, and the user clicks Open. If the
  user cancels it, the app unmounts the share that it mounted.
- **Hidden from Finder.** The app mounts with `MNT_DONTBROWSE` (`nobrowse`), also when it mounts a
  share again (§1). Finder's sidebar then shows only the locations, and the mount stays in
  `/Volumes` [V: M12]. A share that the user connects in Finder stays visible, and the app uses it.
- **Connect.** Servers shows Connect for a share that isn't connected, such as after an eject or
  when the Keychain has no password. It mounts the saved address, with macOS's dialog if
  necessary. The messages that said to use Connect to Server in Finder now say to click Connect.
- **Disconnect.** The user can't eject a hidden share in Finder, so Servers shows Disconnect for a
  connected share. The app unmounts it with `FileManager.unmountVolume`, which posts `willUnmount`,
  so the share stays unmounted until Connect, as after an eject, and no notification shows. macOS
  posts `willUnmount` before the unmount can fail: when a file is open on the share, the app shows
  a message and starts its session again [V: M12].
- **Removing a server** ejects its associated connections before deleting its record, including
  connections adopted from Finder. A failure keeps the entry. Other Connected Shares exposes
  mounts without saved grants and offers Use Share or Disconnect.

If several shares are selected in macOS's list, the panel opens on the first. Newly mounted
shares that are not selected in the panel are unmounted; an unsuccessful cleanup remains visible
under Other Connected Shares.

M12 checks, before the connection-management follow-up:

1. Add Share… with `smb://server/share` and the password in the Keychain: no dialog, the panel
   opens on the share, and a location on it reads a file that matches the share. Finder's sidebar
   doesn't show the share.
2. An account that the Keychain doesn't have: macOS's login dialog shows. Cancel shows no message
   and leaves no mount and no server.
3. Only the server: macOS's share list shows. Cancel in the panel then unmounts the share.
4. A share that is already mounted: the panel opens on it, and the server keeps its row.
5. A forced unmount: the app mounts the share again, hidden.
6. An eject, then Connect: the share is mounted, and a session starts.
7. Disconnect: the share stays unmounted, with no notification, until Connect. With a file open on
   the share, a message shows, and the share stays connected.
8. Removing the server unmounts its hidden mount. A wrong address shows a message.
9. No mount and no stage file leaks, and no names in the log.

Not testable in the VM: typing a password in macOS's dialog, which only the user does.

### Connection management follow-up

Decision status: accepted and implemented. A share left connected through Finder under a
different address made the native share selector an unusable route back to that share once the
app's entry was removed.

- Save a server address independently of its share grants. Add Server needs no mount; choose a
  share when setting up a location. The app still never asks for or stores a password.
- Offer connected SMB shares in the app, including hidden mounts and mounts made outside the app.
  Explicit selection associates a connection with a saved server. Do not merge addresses by DNS
  or assume that matching share names identify the same NAS or account.
- Disconnect is a normal OS unmount. Remove ejects every share associated with the saved server
  before deleting its record. A failed eject keeps the record and its controls, with an error.
  Never force an eject. A server used by a location cannot be removed.
- Show mounted shares without a saved grant, so a cancelled setup or an earlier build cannot
  leave a hidden mount without controls. Re-adding can select that connection directly.
- Settings version 2 separates server addresses from share grants. Migrate version 1 atomically,
  preserving grants, location IDs, domain IDs, bookmarks and saved Keep Downloaded lists. The
  existing version field makes an older build refuse a format it cannot preserve.

The original cancellation checks change deliberately: cancelling share selection keeps the
saved server, while leaving no new grant.

## 5. Milestones

| # | Milestone | Question it answers | Needs |
| --- | --- | --- | --- |
| M11 | The app comes back by itself | Does the share come back after macOS drops it, and the app after a crash, with no change after an eject or a Quit? | M9 |
| M12 | Connect in the app | Can the user connect in TinyMounter, with macOS's own dialogs, and see only the locations in Finder? | M11 |
| M13 | Verified offline status for kept files | Can the app distinguish a keep request from a complete, current local copy? | M12 |
| M14 | Keep folders downloaded | Can the user keep a folder and its subfolders without opening each one? | M13 |

UI refinement stays deferred; the physical-Mac restart check remains open. M15 to M17 cover NAS
change discovery while the app runs, local disk space and the location lifecycle.

### M13: verified offline status for kept files

Decision status: implemented. Its physical-Mac offline check and macOS restart remain open.

The Keep Downloaded list distinguishes Requested, Update in progress and Available offline.
The app signals the working set and waits for `waitForStabilization` to apply provider changes.
It then queries only materialized kept files through security-scoped URLs, clears cached resource
values and requires current, not downloading, and matching catalog size and modification date.
It rechecks catalog versions after observation. Missing metadata, failed waits, a changed version
or a replaced location cannot retain an earlier positive result.

Materialized-set and pending-set changes, domain download start/finish and catalog changes reload
the list. No polling, content reads, source scan or persistent format change was added. A wait
covers the whole location. Before that wait, the app rechecks local metadata and materialization
for previously verified content versions, so unrelated downloads do not reset those rows. New or
changed versions still require synchronization. Folder status uses current membership and listing
completeness. Provider disablement or replacement clears the remembered verification. Available offline refers to the latest source
version the app has observed; M15 below adds live discovery with bounded refresh intervals.

The tested materialized-item projection returned unusable download flags and omitted its opaque
content version and userInfo. The public stabilization barrier supplies the consistency check
instead.

### M14: keep folders downloaded

Decision status: implemented, with the accepted recursive-folder design. Finder's native progress
circle shows during kept transfers. Other UI refinement remains separate work.

Keep Downloaded in Finder accepts files and folders. A folder request includes its descendants,
including items found by later listings. The app lists requests in Settings, rather than adding
a row for every inherited file. Allow Removal cancels a request; independently kept descendants
remain kept. An inherited item has no separate Allow Removal action until its enclosing request
is removed. No per-file exclusions are added.

The catalog separates each explicit request from effective retention. File Provider's public
namespace policy asks macOS to enumerate kept folders eagerly, and its content policy retains
their files. Pause Downloads makes both policies lazy. No separate recursive downloader is added.
A folder is Available offline only when every descendant folder has an unskipped complete listing
and is materialized, and every descendant file passes M13's local-copy check. Unvisited, unreadable
or unsupported contents cannot produce a positive folder status. This describes observed source
versions, not continuous source freshness.

A parent listing that reports a changed child folder invalidates that child's previous complete
listing. Its next connected enumeration schedules a background listing while serving cached
pages. Cached browsing remains available with the reader stopped; folder status stays unconfirmed
until a complete listing is observed.

Catalog migration preserves existing IDs, change anchors, files and file requests while adding
explicit-request and listing-completeness fields. Live items get new metadata sequences so
Finder receives the new actions; existing anchors remain valid. The app and extension build
number advances so macOS can distinguish the new extension. Saved requests record their path and kind;
existing strings migrate to file requests. The settings version changes so an older build cannot
rewrite folder requests as files. Location IDs, domains, bookmarks and downloads stay intact.

Checks must cover both migrations, nested and overlapping requests, newly listed descendants,
pause/resume, unkeep, incomplete listings and empty folders. The signed VM run must download a
previously unopened tree, update the open Settings pane, survive relaunch and OS eject, and read
all kept bytes with hydration forbidden. Use a small isolated fixture and remove it afterward;
never request an uncontrolled NAS tree. Record matched before/after actions and run all checks
in the VM before offering a signed physical-Mac build.

### M15: discover NAS changes while the app runs

Decision status: implemented. Implementation choices below are the agent's. Since 0.2.0,
SMB2 `CHANGE_NOTIFY` watches on the app's own connection replace the Dispatch sources below
([architecture §7](architecture.md#7-identity-versions-and-change-discovery)).

Monitor directory vnodes through public Dispatch sources on the native SMB mount. Apple's SMB
client connects directory monitoring to CHANGE_NOTIFY. These are hints, not deletion evidence;
the existing complete-listing, absence checks and delayed confirmation remain unchanged. There
are at most 64 watches per mount session. They use O_EVTONLY descriptors and end with their
session or when their location/folder is removed from monitoring.

Monitor the root, materialized folders and already listed folders in kept trees. Never walk an
unvisited unkept tree. Periodic listings cover missed or unsupported notifications, including file
content edits. A successful listing is due again after 60 seconds. One automatic listing runs
at a time, with a one-second gap between completions; due folders rotate fairly across domains.
Large sets therefore take longer than one interval. Events coalesce and have a two-second minimum
per-folder interval. Failed folders back off through 30, 60, 120 and 240 seconds. Disconnected,
unresponsive, disabled and removing locations do no scheduled source I/O. Launch/recovery keep
the existing reconciliation; wake also requests a refresh.

Changes use the catalog's current identity rules. Rename is still delete plus create; a keep
request does not follow a rename. No format, remote write, new dependency or UI change is added.
Available offline remains a check of the source version last observed, rather than a guarantee
that the NAS cannot change between refreshes.

Physical-Mac offline hashes and restart, QSpace and broader NAS notification coverage remain
unverified.


### M16: protect local disk space during downloads

Decision status: accepted and implemented.

The prototype leaves a fixed 2 GiB reserve on the local staging volume. This is an implementation
policy, not a measured macOS requirement. One app-owned budget covers concurrent requests across
locations. Admission requires room for twice the requested payload plus 64 KiB of metadata,
allowing for staging and provider handoff. It counts range payload bytes, not the sparse file's
logical end offset. Reservations remain until release; written staging bytes reduce outstanding
reservations. Capacity is checked again every 16 MiB during transfer. Unexpected ENOSPC or EDQUOT
still fails safely and removes the unfinished stage file. Other processes can consume space
between checks, so the reserve is not an OS-enforced quota.

Read fresh ordinary volume available capacity, without assuming macOS will purge other data.
No kept copy is evicted to make room. The native provider retention and manual Pause policies
remain unchanged. Missing local capacity fails the download rather than granting speculative
space. Disk-full failures cross XPC as Cocoa's local fileWriteOutOfSpace error, never a remote
quota or connection failure.

Settings shows Not sufficient space for an affected keep request or kept ancestor folder, with
instructions to free local space. Verified independent copies keep Available offline. All
completeness, version and materialization checks remain necessary for a positive offline state.

While the app runs, check blocked kept files every 30 seconds. Once their complete payload fits
with another 64 MiB of recovery headroom, request their download through File Provider's public
API. This avoids misusing signalErrorResolved, whose documented supported errors do not include
local disk-full errors. A manually paused, disconnected, disabled or removing location is not
retried. Unkept on-demand reads fail clearly and remain under the requesting app/system's control.
Save blocked reader requests atomically in the App Group as `BlockedDownloads.json`. It contains
only opaque IDs, versions and byte ranges; settings and catalogs remain unchanged. The queue
survives relaunch, then each retry checks current keep intent and source version. Public pending
item and URL error projections did not expose the failed request in the VM. If saving fails,
in-memory recovery remains active for that process; a relaunch cannot recover an unsaved request.
No settings/catalog migration or new dependency is needed.

Verification must cover shared reservations, external capacity loss, partial-stage cleanup,
large sparse offsets, overflow-safe accounting, local error mapping, folder aggregation,
independent offline status and recovery without overriding Pause. Use a small disposable volume
for a real ENOSPC path and signed app checks for admission, Finder/app status and retry. Record
matched before/after actions, restore sharing and remove all test downloads afterward.

Physical-Mac low-space checks remain open.


### M17: verify location changes and removal

Decision status: verification of accepted behavior. The Add, Name, Apply and Remove contract is
already accepted in phase 2 sections 7 and 8. This step adds no new feature or interface.

Check that one location can change its name or source, or be removed, without changing another
location's identity, kept requests or downloaded copies. A rejected Apply must leave the old
location usable. A crash after saving an Apply or Remove must finish in order at the next app
launch. Removed and retired domains must leave no catalog, watcher, reader reservation or retry
record in use. A user-disabled location must keep its saved configuration and recover when the
provider is enabled again.

Use two temporary VM locations on the existing read-only grant, bounded small file reads and
opaque evidence. Do not change the NAS, sharing, native mounts or network. Inject interruptions
only into the test app or a separate test build. Never stop shared system services. Keep Cairndex
and the original connection intact, then remove every temporary location and download. Broader
multi-location load and performance checks remain in phase 6. A full macOS restart remains the
user's separate check; the VM is not restarted.

Put the signed results in the PR and run Tools/run-checks.sh before closing this step. If a check finds
a defect in the accepted behavior, fix the cause, add a useful regression check and update the
affected docs in the same commit. New recovery actions or destructive behavior need a separate
user decision.

A saved request returns on re-add; its automatic download completion remains unverified.
