# Kept-file versions and guest SMB, 2026-10-19

## Outcome

M13's applied-version check passed in the signed VM app. Available offline now requires macOS to
apply the provider's known changes before the app reads fresh local metadata. Controlled changes
that preserved size and modification time were handled correctly. The final three kept files,
including an empty file, matched the source with hydration forbidden, also after OS eject.
All 161 tests and required checks passed. The physical-Mac app is unchanged.

This verifies the version last observed by the app. It does not add continuous NAS change
discovery or promise that an unobserved source change is already present locally.

## Setup and method

- Same VM, macOS and Xcode as the [initial local-copy check](2026-10-19-offline-status.md).
- The user approved temporary VM File Sharing. Only a disposable local folder was exposed, with
  a read-only guest SMB mount. The existing share was disabled during the test. SMB guest access
  was enabled separately from guest login, which remained disabled throughout.
- The fixture held an empty file, a 1 MiB file and a 64 MiB file. One change added 4 KiB to the
  small file. Other changes replaced bytes while retaining its size and exact backend mtime.
  Backend ctime changed, and reconnect listing recorded a changed catalog row.
- A writer made 83 in-place changes to the larger fixture while kept downloads resumed. It
  changed only the disposable local source. No NAS file was written, renamed or deleted.
- Provider and SMB caches were reused during the sequence; reconnects made new mount sessions.
  These were correctness checks, not performance measurements.

The app signals the working set, waits for `waitForStabilization`, then enumerates materialized
items. That public API waits for filesystem and provider changes up to the call to be applied.
The app clears cached URL resource values and checks current/not downloading, size and mtime.
It rereads catalog versions afterward and discards a result whose version or location changed.
No content is opened by the status check, and no settings/catalog format changed.

## Checks

| Check | Observed result |
| --- | --- |
| Guest connection before the fix | Absent from usable connected shares; Add Share could not adopt it |
| Guest connection after the fix | Offered by Add Share, selected in the open panel, saved and read in the signed app |
| Client write-open on the fixture | Failed with EROFS, errno 30 |
| Kept zero-byte file | Available offline; full local read matched the source |
| Change bytes while preserving size and backend mtime | Reconnect listing detected the new fingerprint; older content was not confirmed as available after synchronization |
| Change size and mtime while downloads paused | Labels stayed Requested while the new version was pending |
| Resume while the larger source changed repeatedly | Fingerprint checks returned versionChanged; macOS retried full fetches; the observed labels stayed Requested during the unsettled work |
| Final reconnect after the writer stopped | All three labels became Available offline; full SHA-256 checks matched the final source with hydration forbidden |
| Repeat same-size/date change on the final source | New copy reached Available offline and matched the source; other kept files also returned to Available offline |
| OS eject of the fixture, final code | Native mount absent; all three labels stayed Available offline and all hashes still matched with hydration forbidden |
| Final checks | 161 tests, zero failures; generation, benchmark checks, release CLI and unsigned app builds passed; zero Swift compiler warnings |
| Final retained-log audit | 195 app/extension messages; zero tested private-name or path-pattern matches |

The guest check exposed two connection assumptions. macOS includes an empty password field in a
guest mount address. The app now removes that empty field from the mount identity; typed password
fields and nonempty passwords remain rejected. The manual guest mount in this fixture also
omitted the separate remount URL. The app uses the address from its verified SMB mount, which is already the address
used for reconnect. Existing saved grants keep their format and values.

## Correctness and limits

On the tested macOS build, the materialized-set projection does not expose the applied opaque
content version. The supported stabilization barrier replaces the proposed direct comparison. The catalog must remain unchanged
across the observation before the app can confirm the synchronized local copy.

A barrier covers the whole location. While an update is paused or being retried, other complete
kept files can also show Requested. This conservative delay prevents an old observation from
remaining a positive result. It does not remove those files.

An earlier empty-file label remained Update in progress although a later independent metadata
query was current; relaunch cleared it. The final code explicitly clears URL resource caches on
each observation. The repeated source-change check then returned all three labels to Available
offline. The stale fields from the earlier observation were not captured, so their exact cause
was not established.

Some reads made while Requested still returned older complete content. After the source refreshed
and the labels became Available offline, the full hashes matched. M13 does not make every open
atomic with a concurrent source edit. Live source discovery and stronger concurrent-edit semantics
remain separate work. No system restart, network cut or physical-Mac speed claim was made.

## Cleanup and evidence

The test location, keep requests, downloads, server entry, mount, share and source folder were
removed. The existing share definitions matched the saved configuration exactly. SMB was left
unloaded and SMB guest access disabled; guest login stayed disabled. The original saved NAS grant
and connected hidden mount were retained. Catalog and stage-file counts were zero. Cairndex was
untouched. The signed VM app remains running; no host app was installed or opened.

- VM `.local/phase2/m13-complete-checks.log`, `m13-fresh-build.log`,
  `m13-versions-check-summary.json`, `m13-versions-runtime-log.ndjson` and
  `m13-fixture-cleanup.json`.
- Local status recordings from the first check: `results/offline-status-20261019/{before,after}.mp4`.
  Guest connection recordings use `guest-before.mp4` and `guest-after.mp4` in that directory.
- A signed Mac build is ready at `.build/xcode-personal/Build/Products/Release/TinyMounterPrototype.app`.
  Strict/deep signature verification passed. It was not installed or opened; all tests ran in the
  VM. Its redacted build log is `results/offline-status-20261019/host-signed-build.log`.
- Public API contracts: [research A12](../research.md#apple-file-provider).

The next user check is offline use of the new build on the physical Mac. Kept folders and
continuous source-change discovery remain later phase 3 work. The earlier physical-Mac restart
check is also still open.

## Physical-Mac installation

The user approved installation on 2026-10-19. At 02:25 US/Pacific, the running app quit normally,
its bundle was backed up, and the signed build replaced it in Applications. The team and bundle
identifier matched before replacement. Strict/deep signature verification passed, the installed
executable matched the ready build, and one app process ran from Applications.

Launch reconciliation retained one location, catalog and domain, with no unknown domains or
failed sequences. The existing keep request remained, the share session was connected, and no
stage files remained. Settings showed Connected. The kept row first showed Requested and then
Available offline after macOS settled. This installation check did not read file content or test
offline availability on the physical Mac. No user location or download was removed.

Local evidence is `results/offline-status-20261019/host-install.json` and
`host-install-ui-status.json` in the same folder. The installation record's backup path points
to the previous app. No source changed during installation, so the completed 161-test VM result
still applies. Nothing was pushed or merged.
