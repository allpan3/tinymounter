# Recursive folder keeps, 2026-10-19

## Outcome

M14 passed its signed VM checks. Keep Downloaded on a folder downloaded an unopened tree,
including nested and empty folders. Its row changed from Requested to Available offline without
reopening Settings. All kept bytes matched the source with downloading forbidden after OS eject.
Newly listed files inherited retention, and saved folder and file requests restored correctly.
All 170 tests and required checks passed, with no Swift compiler warnings.

The signed Mac build was ready when the VM checks ended; the physical Mac still ran M13. Its
later approved installation is recorded below. Nothing was pushed or merged. Live NAS change
discovery and the user's macOS restart check remain open.

## Setup and method

- VMPal `macOS VM 1`, macOS 27.0.1, build 26A434; Xcode 27.0, build 27A266a.
- Personal Team signed app and extension, with their normal sandbox and read-only share grant.
- The user approved temporary VM File Sharing again. A disposable local folder was the only
  active SMB share, mounted read-only as a guest. Guest login stayed off. A client write-open
  failed with EROFS, errno 30. No NAS content was changed.
- The kept tree held a 64 KiB file, an 8 MiB file, an empty file and an empty nested folder.
  A later backend change added a 44 KiB file. A separate folder held a symbolic link to test
  unsupported contents. All source changes were confined to the disposable local backend.
- Provider, SMB and filesystem caches were reused. These were correctness checks, with no cold
  cache or performance claim. Full SHA-256 comparisons used a process policy that forbids hydration.
- Matched recordings select the same unopened folder and open its Finder shortcut menu. The old
  build has no folder Keep Downloaded action; the new build does. The clips exclude private UI.

## Decisions

The user asked to continue to the next milestone under the accepted recursive-folder design.
Keep Downloaded saves an explicit folder request. Its descendants inherit retention, including
newly listed items. Allow Removal cancels that request and preserves independent child requests;
there are no per-file exclusions. Settings lists explicit requests only.

The system enumerates kept folders through the public eager namespace policy. Existing content
policies download the files. Pause makes both policies lazy. Folder availability requires all
descendant folders to have complete listings with no skipped contents and to be materialized,
and all files to pass M13's version-aware local-copy check. Live source discovery remains later
work; the status covers the source versions observed by the app.

Catalog version 2 adds explicit-request and listing-completeness fields. Its transaction copies
existing file requests, preserves IDs and epochs, and gives live rows new metadata sequences to
republish the Finder actions. Earlier sync anchors remain valid. Settings version 3 records a
path and kind for saved requests. Versions 1 and 2 migrate existing strings to files, so a
replacement folder cannot accidentally inherit an old file request. Older builds reject the
new formats. The app and extension build number advances to distinguish the update.

## Checks

| Check | Observed result |
| --- | --- |
| Keep the unopened folder while paused | One folder request appeared as Requested |
| Resume, leave Settings open | macOS enumerated the tree and downloaded its files; the row changed to Available offline |
| Complete and empty files, hydration forbidden | All three SHA-256 comparisons matched; the empty nested folder was local |
| Disconnect through Servers | Normal OS unmount completed; the native mount was absent; all three hashes still matched and the folder stayed Available offline |
| Add a backend file while disconnected, then mount again | Reconnect listing discovered it and downloaded it without another keep request; all four hashes matched |
| Keep a child separately, keep its parent, then allow removal of the parent | Only the child request remained; the app reported one retained item and the file stayed Available offline |
| Keep the folder containing a symbolic link | Its row stayed Requested; the independent complete file stayed Available offline |
| Relaunch the signed app | Folder and independent file requests remained; both returned to Available offline and all four hashes matched |
| Remove with Save the Keep Downloaded list, then add the location again | Both typed requests returned; the tree downloaded automatically, without a second download prompt; all four hashes matched |
| Catalog migration unit check | File content versions, IDs and epoch stayed; old anchors returned the republished live rows |
| Settings migration unit checks | Version 1 and 2 locations, grants, domains and file requests were preserved; typed folder requests round-tripped |
| Full VM checks | 170 tests, zero failures; project generation, benchmark checks, release CLI and unsigned app builds passed; no Swift compiler warnings |
| Final retained subsystem-message audit | 186 messages, zero matches for the tested mounted-share values, signing team or path patterns |

Unit checks also cover nested and overlapping requests, newly listed descendants, pause state,
missing materialization, partial or updating files, unreadable listings, invalid names and name
collisions. The signed run covers folder behavior on this VM; it does not establish physical-Mac
performance or reboot persistence.

## Findings and limits

Final review found that a parent listing could report a changed child folder while leaving its
old listing marked complete. That listing is now invalidated. A fresh signed fixture run
downloaded the unopened tree, discovered an added file after relaunch, and matched all four files
after OS eject with hydration forbidden. A known folder serves cached pages while scheduling
the required listing in the background; unit checks cover this with the reader connected and
stopped. The final signed VM build was rebuilt and launched after that adjustment.

Several older test copies of the extension were still registered in the VM. macOS initially
launched a build that rejected catalog version 2. Two stale registrations were removed without
deleting their apps, the ready extension was registered, and its running path and build number
were checked before the folder tests. Migration also republishes the new action metadata even
when an item's retention did not change. This run is not a clean-machine update test.

A folder with skipped or unsupported entries stays Requested. There are no exclusions or
per-folder error explanations yet. A folder request includes files when the app discovers them;
it does not add continuous NAS change discovery. Available offline still describes the latest
source version observed by the app, with M13's location-wide synchronization wait.

The fixture used a manually mounted guest connection, as in M13. This does not establish NetFS
loopback reconnection. No VM restart or network cut was made. The physical-Mac offline and restart
checks remain the user's next checks after installation approval.

## Cleanup and evidence

The test location, keep requests, downloads, server entry, mount, SMB share and source folder were
removed. The saved list was consumed by restoration, and the final removal did not save it again.
Previous share definitions matched the snapshot exactly; SMB was unloaded, SMB guest access was
disabled and guest login stayed off. The original saved NAS grant and hidden connection remained.
Final app diagnostics reported zero catalogs, kept items and stage files, with one share/session.
Cairndex was untouched.

- VM `.local/phase2/m14-final-checks.log` and `m14-signed-build.log`.
- VM `m14-verify-{offline,added,relaunch,restored}.json`, `m14-runtime-messages.ndjson`,
  `m14-log-audit.json` and `m14-fixture-cleanup.json` in the same directory.
- Final rerun: `m14-verify-review-{initial,stopped,added,offline}.json` and
  `m14-final-cleanup.json` in the same VM directory.
- Matched local recordings: `results/folder-keeps-20261019/before.mp4` and `after.mp4`.
  Contact sheets were inspected; the clips show only the disposable fixture.
- Signed Mac build: `.build/xcode-personal/Build/Products/Release/TinyMounterPrototype.app`.
  Strict/deep signature verification passed for it and the signed VM app. The Mac build was not
  installed or opened during these VM checks. Its redacted build log is
  `results/folder-keeps-20261019/host-signed-build.log`.
  Xcode registered that copy during the build; its registration was removed afterward, leaving
  the installed M13 extension running from Applications. Local evidence is `host-ready-state.json`
  and `host-registration-cleanup.json` in the same results folder.

## Physical-Mac installation, 2026-10-19

The user approved installation with "do it". At 04:34 US/Pacific, the running M13 app quit
normally, its bundle was backed up, and the ready signed M14 build replaced it in Applications.
The signing team and bundle identifier matched before replacement. Strict/deep signature
verification passed, the installed executable matched the ready build, and one app process ran
from Applications. The running extension also came from Applications and matched the ready build.

Launch reconciliation retained one location, catalog and domain, with no unknown domains or
failed sequences. The existing keep request and connected share session remained. No catalog
was unavailable and no stage files remained. No user location or download was removed. Settings
and catalog migration therefore passed this launch check; no file content was read to verify
downloaded bytes on the physical Mac.

The Mac was locked. A broad accessibility scan repeatedly traversed its menu hierarchy and
caused extra app CPU load; the scan was stopped and the app returned to idle. The lock state
prevented a visible Settings-status check. Folder actions, offline reads and macOS restart on
the physical Mac remain unverified.

Local evidence is `results/folder-keeps-20261019/host-install.json`, which records the previous
app's backup path, plus `host-installed-provider.json` and `host-install-ui-status.json` in the
same folder. No source changed during installation, so the completed 170-test VM result still
applies. Nothing was pushed or merged.
