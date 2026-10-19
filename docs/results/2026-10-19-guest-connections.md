# Reusing a guest SMB connection, 2026-10-19

## Outcome

The signed VM app now offers an existing guest SMB connection, saves its read-only grant and reads
files that match the source. It removes macOS's empty password field from the mount identity;
nonempty passwords and typed password fields remain rejected. Existing grants keep their format.

## Setup and checks

This was part of the user-approved M13 fixture run in `macOS VM 1`, macOS 27.0.1, with Xcode 27.0.
Only a disposable local folder was shared, read-only to a guest connection. Existing shares were
disabled for the test. SMB guest access was enabled separately from guest login, which stayed off.

The previous build did not offer the guest connection because its kernel address had an empty
password field. After normalization, Add Share offered it. A manual SMB mount also supplies no
separate remount URL, so the app now takes its saved address directly from the verified SMB mount
identity, which is already used for reconnect. The root, SMB type, mount identity, bookmark and
read-only security scope checks remain.

The signed app saved the grant, added a location and read the fixture. A client write-open failed
with EROFS. All 157 tests and required checks passed on the isolated guest-fix commit in the VM,
including the normalization regression test, project generation, benchmark checks and required
builds. No Swift compiler warnings.

## Cleanup and limits

The test location, requests, downloads, server entry, mount, share and source folder were removed.
Existing share definitions were restored. SMB was left unloaded, SMB guest access off, and guest
login off. The original NAS connection stayed connected, and its files were never changed.
Cairndex and the physical-Mac app were untouched.

Local redacted recordings are `results/offline-status-20261019/guest-before.mp4` and
`guest-after.mp4`. VM evidence is in `.local/phase2/m13-guest-unit.log`, `m13-fresh-build.log` and
`m13-fixture-cleanup.json`. The isolated full-check log is `guest-isolated-checks.log`. This checks adopting an existing guest connection; NetFS mounting of
a loopback server was not a successful route in this setup. Physical-Mac guest access remains
unverified.
