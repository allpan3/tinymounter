# Connection layer for 0.2.0, 2026-11-08

## Outcome

Steps 3 and 4 of the [connection-layer plan](../connection-layer-plan.md#implementation-steps)
are implemented on `feat/smb-connection-layer`. File Provider locations use no mount: the app
signs in with the password from its Keychain item, opens an SMB session for each operation,
watches discovery folders with `CHANGE_NOTIFY`, and judges each share's health from its calls.

In the signed sandboxed VM app, against a disposable fixture account and share, add, browse,
read, Keep Downloaded, upload, rename, move and Delete Permanently… all worked with no SMB mount
(`mount | grep -c smbfs` was 0 throughout). A changed password stopped all logons after one
refusal, a stopped SMB service recovered at the first probe after the restart, and logs held no
source names.

Two problems remain:

- **Server Volume can't mount a new share** (check 6 fails). The app's NetFS mount carries no
  password, and macOS had no session or Keychain item for the new share, so the mount failed with
  status 2. In 0.1.2 the hidden File Provider mount supplied that session. Plan Decision 1
  (NetFS gets the saved name and password) is now required before release, not optional.
- **Notice-driven rename and delete miss the 3 s target.** Notices reach the catalog in about
  1.5 s, but a missing name still waits for the 15 s confirmation (D5), so a delete appeared
  about 11 s later and a rename's new name was not shown during the check.

## Setup

- Client: VMPal `macOS VM 1`, macOS 27.0.1 (26A434), clone `~/Developer/tm-step3`. Unsigned
  build with bundle `dev.tinymounter.releasecheck`, signed on the host, installed as
  `~/Applications/TinyMounter-Step3.app`. A second bundle, `dev.tinymounter.lancheck`, checked
  Local Network first use with a signature macOS had not seen.
- Server: VMPal `TinyMounter Samba Test`, Samba 4.19.5-Ubuntu. A disposable account and two
  shares with a password generated inside the VMs, entered through the sign-in sheet and never
  printed. Global settings unchanged; all removed afterwards and `smb.conf` restored
  byte-for-byte.
- Logon counts come from the fixture's capture, counted by session setup result.

## Data

### Build and tests

`Tools/run-checks.sh` in the VM at the last code commit: passed. 517 tests, one optional skip, no
failures; the app build had no Swift warnings; SET_INFO 6, edit status 87, folder-create status
and CCM 7,205 cases passed. Host `swift test`: 517 tests, one skip. The count fell from 539
because the mount, grant and bookmark tests were removed with `ShareHealth`, `ShareMount` and
the grant code.

### Step 3 checks

| Check | Result |
| --- | --- |
| 1. 0.1.2 `Settings.json` refused, Start Fresh | Not run in the app (see below); unit tests pass |
| 2. No mount and no panel | Pass. Mount count 0 through every operation |
| 3. M21–M26 Finder checks | Partial pass (see below) |
| 4. Changed password | Pass. 1 logon attempt, 1 failure in about 100 s |
| 5. SMB service stopped | Pass. Unresponsive after 6 s; connected 5 s after restart |
| 6. Server Volume | Fail. Add can't mount a new share |
| 7. Logs | Pass. No source names in 474 lines |

**Check 1.** macOS container protection refused writing an earlier `Settings.json` into the test
app's container from the VM's shell, also as root and from Terminal, so the in-app Start Fresh
was not run. `testEarlierSettingsAreRejectedNotConverted` and
`testServerRecordRejectsTheEarlierAddressAndAnEmptySignIn` decode 0.1.2 shapes and fail as
required. Start Fresh's deletion of saved passwords has no runtime check.

**Check 2.** In the in-app browser, the share list and folders appeared without a panel.
Checksums of read files matched the server. Upload, rename, folder create, file move, folder move
and deletion of a file and a folder tree reached the server; the upload's checksum matched.

**Check 3.** Covered through Finder and the shell: rename, move, Delete Permanently… with its
confirmation, Keep Downloaded (the menu then offered Allow Removal) and upload retry after a
refusal and after an outage. Not run: M23 competing edits, M25 editor saves and M26 offline.

**Check 4.** After the fixture password changed, the next request was refused and the share
entered Sign in again at once. Later `fileproviderd` retries failed with no I/O, the watcher
closed its 8 watches, and one notification was posted. Sign In Again… with the new password
connected; the pending upload finished 0.4 s later with a matching checksum, and 8 watches
reopened. The next 15 s had 21 accepted logons, one per operation.

**Check 5.** With smbd stopped, the watch ended at once and backed off; the share was unresponsive
6 s later, with a notification. After the restart, the first probe connected 5.4 s later, the
pending upload finished and the watches reopened. Wake and a network-path change were not
tested: they need the VM to sleep or lose its network, which the test rules forbid.

**Check 6.** The location form shows mounted or not mounted, as planned. Add failed with "The
share does not exist" from macOS and then "TinyMounter cannot do this (status=2)". A Finder
mount with a typed and remembered password worked once through the fixture's Bonjour name, after
which both the app and Finder failed again. Show in Finder, eject, reconnect and busy refusal were
not reached.

**Check 7.** `log show` for the subsystem over the run: 474 lines, no host, account, share,
folder or file names, no `smb://` and neither password.

### Step 4 checks

| Check | Result |
| --- | --- |
| 1. Changes in Finder within 3 s | Create and change pass; rename and delete fail (D5) |
| 2. `change notify = no` | Not run: needs a global fixture setting |
| 3. Watch after SMB restart | Pass |
| 4. One connection, at most 64 watches | Pass. 1 connection, 8 watches |
| 5. Own uploads | Pass. 2 notice listings for 6 uploads |

**Check 1.** Changes by another client, three folders below the location folder: a create reached
the provider in 1.1 s and a change in 1.5 s; a file in a second folder in 1.4 s. A rename and a
delete were listed within 1.5 s, but the catalog held the missing names for the 15 s
confirmation; the delete settled about 11 s later. The 60 s relisting of an unwatched folder was
not measured here; the [watcher results](2026-11-08-change-watching.md) cover it.

**Check 4.** `lsof -i :445` showed one TCP connection from the app between operations, the
watcher. Up to 8 folders were watched.

**Check 5.** During 6 uploads to one folder, it had 8 listings: 6 were the uploads' own
listings, and 2 came from notices, 2.1 s apart.

### Local Network access

- **First use:** with the new `lancheck` signature, sign-in raised macOS's Local Network prompt
  while the sheet waited. After Allow, clicked 5 s later, sign-in finished and the share list
  appeared with no relaunch.
- **Denied:** with access turned off, Add Share… showed "TinyMounter cannot reach the local
  network. In System Settings › Privacy & Security › Local Network, turn on TinyMounter. Then try
  again." after the 30 s wait.

## Decisions to review

- `ServerSignIn`, one per server, runs sign-ins one at a time so that a wrong password reaches the
  server once; a refusal reaches the server's other shares within the 1 s health tick. The plan
  gave `ShareConnection` only a credential store.
- The password stays in memory from the first sign-in until a refusal or a new password. The plan
  said both "read again for each connection" and "read at the first session".
- A Keychain read error is treated as Sign in again.
- Every operation opens its own session, as the plan says. After a reconnect this is a burst of
  logons (21 in 15 s in check 4). A session pool would reduce it; not built.
- Notifications: connected to not connected is no longer notified, because reconnection is
  automatic. Unresponsive stays, and Sign in again notifies once per server.
- Diagnostics reports `connected` shares instead of mount `sessions`.
- The hidden-mount cleanup from earlier builds is dropped; Start Fresh covers earlier installs.
- Deletion admission and settlement compare the location folder's `directoryIdentity` instead of
  a mount identity and inode.
- `DirectoryWatch.swift` went in the first commit, with its only user, not with step 4.
- Commits group the plan's parts as: connection layer and mount removal; GSS and guest removal;
  the bookmark entitlement; step 4 wiring; Start Fresh password deletion; Local Network; docs.
- Local Network: after a connect fails as unreachable, the app waits up to 30 s only while Network
  framework reports `localNetworkDenied`, then connects once more. A new `localNetworkDenied`
  failure is handled like `serverUnreachable` by health and Finder. The vendored connect now
  returns its errno instead of `EIO`.
- The D5 confirmation delay applies to notice-driven renames and deletes; not changed here.
- Test builds with different bundle IDs share one Keychain item for the same server, because the
  service name holds no bundle ID; the second build asked for the login keychain password.

## Remaining

- Server Volume sign-in (plan Decision 1): pass the saved name and password to NetFS, then rerun
  check 6. Improve the "status=2" message.
- Decide whether notice-driven deletes and renames may skip the 15 s confirmation.
- Before release: Start Fresh on a real 0.1.2 install, M23/M25/M26, wake and network-path probes,
  `change notify = no`, and physical-Mac acceptance.
