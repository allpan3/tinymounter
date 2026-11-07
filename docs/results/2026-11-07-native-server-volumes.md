# Native SMB server volumes

Date: 2026-11-07. Decision status: accepted and implemented. Signed VM validation passed.
The installed physical-Mac app and published DMG remain on 0.1.1.

## Behavior

Add offers File Provider or Server volume (SMB). Native mode mounts the whole share visibly
in Finder and uses the server's permissions. It creates no File Provider domain or catalog,
and offers no download cache, Keep Downloaded or TinyMounter Read only control.

One mode is allowed per server/share, including saved accounts with different credentials.
Remove existing locations before switching. Additional File Provider locations on the same
share remain supported. Matching is case-insensitive; different DNS names or IP aliases for
the same server are not resolved into one identity.

The existing NetFS connection and remount policy handles both modes. Native Add connects
when needed and safely replaces an existing hidden mount with a browsable one. Remove must
successfully unmount before forgetting the entry. Busy volumes remain saved and show an
instruction to close their open files. Intentional eject holds reconnect for the app session;
launching the app again reconnects saved volumes.

## Verification

Setup: macOS VM 1, macOS 27.0.1, signed sandboxed app with an isolated identity, and the
existing disposable Samba VM. All writes used a new task-owned subtree. No performance
measurement was made; native move identity was checked independently on the server.

- Add from a disconnected saved share connected automatically. Mount inspection showed no
  `nobrowse` flag. Show in Finder opened the native volume. The provider dump and app launch
  reconciliation showed zero domains and catalogs for the isolated app.
- Finder renamed and moved a file into a sibling folder. Its server inode and contents stayed
  unchanged. A file created through the native mount had the expected contents on the server.
- An open writable file made Remove fail with Cocoa error 769. The mount and saved entry
  remained. The final signed build displayed the clear busy-volume message. Removal succeeded
  after the file was closed.
- Finder eject stayed disconnected for more than three mount-poll intervals. Relaunch mounted
  the saved native volume again, visibly. Stopping Samba and dropping the mount without an
  intentional-eject notification produced timed-out mount attempts and backoff; restoring
  Samba led to an automatic visible remount.
- Native mode rejected File Provider Add on the same share. After native removal, provider
  Add succeeded with a hidden support mount. TextEdit opened and saved the fixture file;
  independent server inspection confirmed the edit. While that provider location existed,
  native Add was rejected. After provider removal, native Add converted the remaining hidden
  mount to a visible one. Removing either kind left server contents intact.
- Settings tests cover same-share conflicts across accounts and case changes, removing
  provider records, multiple provider locations, invalid native records, persistence and
  removal before switching.
- `Tools/run-checks.sh` passed: 522 tests, one optional fixture skip, zero failures, no Swift
  warnings, benchmark verification, generated project, Release app and SMB encoding/status
  checks. The final signed candidate also built and passed strict/deep signature verification.

This run does not establish physical-Mac behavior, another NAS implementation, a full OS
restart or sleep/wake behavior for native mode. Existing reconnect policy tests cover wake
signals; the runtime checks here exercised app launch and server return. File Provider's
support mount still cannot hide the NAS under Network or change a pre-existing visible mount.

## Evidence and cleanup

Local evidence: `results/native-server-volumes-20261107/`, including `vm/checks.log`,
`vm/runtime.log`, provider dumps, independent server checks and `vm/cleanup.json`.
Matched recordings start in Settings, inspect Servers and return to the Add form; the 0.1.1
baseline has no native choice, and the candidate continues through native Add and Show in
Finder. Recordings are `before-frames.gif` and `after-native-frames.gif`. Raw desktop frames
remain local because they include unrelated retained test files.

The test locations, app, task fixture, build products and duplicate transfer archives were
removed. TextEdit closed after its save reached the server; Finder has zero open windows.
Samba is active, and the fixture share is unmounted. Free space was about 815 GiB before the
run and 814.10 GiB after cleanup. Logs, recordings and unrelated retained data remain.
