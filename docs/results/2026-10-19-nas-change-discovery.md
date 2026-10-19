# NAS change discovery, 2026-10-19

## Outcome

M15 discovered external additions, same-size/mtime content edits, renames and deletions without
relaunch in the signed VM app. New descendants of a kept folder downloaded automatically, and
all kept files matched the disposable source with hydration forbidden. Failed listings preserved
known children. Normal eject stayed ejected, and discovery resumed on manual reconnect.
All 182 tests and required checks passed, with no Swift compiler warnings.

The signed physical-Mac build was ready when the VM checks ended; its later approved
installation and successful user-run live-change check are recorded below. QSpace behavior,
broader NAS notification coverage, physical-Mac offline hashes and restart persistence remain
unverified.
Nothing was pushed or merged for M15.

## Setup and method

- VMPal `macOS VM 1`, macOS 27.0.1, build 26A434; Xcode 27.0, build 27A266a.
- The user approved temporary isolated VM File Sharing. Only a disposable local folder was
  shared over guest SMB; the client mount was read-only. A client write-open failed with EROFS,
  errno 30. Backend mutations used the disposable local path. NAS content was unchanged.
- The original tree contained a small file, a 65536-byte file, an empty file and an empty nested
  folder. Later additions held 1920, 9216 and 7680 bytes. A separate folder with an unsupported symlink
  was outside the kept tree.
- App and extension used the normal sandbox and existing host development identity. The old VM
  certificate failed strict verification with `CSSMERR_TP_CERT_REVOKED`, despite appearing in
  `security find-identity`. Both comparison apps were signed with the existing valid host
  identity and passed strict/deep verification in the VM. No trust or entitlement changes were
  made. Registration was repaired before launching each selected app.
- Provider, SMB and filesystem caches were reused and uncontrolled. These were correctness
  checks, with no cold-cache or performance claim. Hash comparisons forbade hydration through
  the process-local filesystem policy.
- Matched Finder recordings open the same folder and add the same disposable backend file.
  The old build's open window did not show it during the 16 s recording; M15 showed it without
  relaunch or navigation. These clips establish behavior in this setup, not a latency guarantee.

## Decisions

Public Dispatch vnode sources watch native SMB directories with notification-only descriptors.
There are at most 64 watches per mount session. Session and location removal release watches;
directory removal or revocation retires a watch. Events are invalidation hints. Only the existing
complete listing, per-name absence check and delayed confirmation can delete catalog entries.

The scheduler covers listed materialized and kept folders and parents of kept files. It never
walks unvisited unkept trees. A folder becomes due 60 s after success; one automatic listing runs
at a time with a one-second gap. Domains rotate, with oldest-due folders first. Events coalesce,
and failed listings back off. Wake requests refresh. The [plan](../phase3-plan.md#m15-discover-nas-changes-while-the-app-runs)
records the exact policy. No format, UI, dependency, NAS-write or sandbox change was needed.

## Checks

| Check | Observed result |
| --- | --- |
| Standalone native watch on read-only loopback SMB | Two directory events during an orchestrated add/edit/delete sequence; the earlier attempt ended before its writer ran and is excluded |
| External addition in open Finder folder | Appeared automatically with M15; matched old-build recording stayed unchanged |
| Keep the tree | Four initial files matched SHA-256 with hydration forbidden; the folder later showed Available offline |
| Edit while preserving file size and mtime, then add a nested folder | Changed content and the new descendant downloaded automatically; all five hashes matched and all descendant folders were local |
| Separate content-only edit, with size and mtime preserved | Initially the old local hash differed; the new version downloaded and matched without relaunch; a directory hint was also delivered |
| Rename a kept descendant | Existing confirmation held the deletion first, then published delete plus create; old name disappeared and all five current hashes matched |
| Delete the renamed descendant | Confirmation held, then removed it; both old names were absent and four remaining hashes matched |
| Deny access to one backend folder | Automatic listing failures were logged, including a retry; known local children remained. Original permissions were restored |
| Normal OS eject | Completed without force; after a 12 s observation the fixture stayed unmounted with zero app descriptors on it; all four kept hashes still matched |
| Manually remount read-only | Recovery listed all five known folders with zero failures; another addition downloaded automatically and all five hashes matched; folder showed Available offline |
| Remove the test location | Cloud location disappeared; zero descendant directory descriptors remained. Two session-root descriptors remained until server removal |
| Required VM checks | 182 tests, zero failures; generated project, release CLI, benchmark verification and unsigned app build passed; zero Swift warnings |

The seven new scheduling tests cover silent-folder fallback, event bursts, hints during listing,
fairness, membership removal, failure backoff and wake. Periodic listings also ran in the signed
app, but the content-only trial delivered a hint; it does not isolate silent-server fallback at
runtime. The kept folder showed Requested while completeness and provider synchronization were
pending, then returned to Available offline. No offline gate was relaxed.

## Correctness and limits

A fingerprint uses size, mtime and ctime; it cannot detect an edit that preserves all three.
Rename remains delete plus create, so an explicit keep request does not follow a rename.
Discovery is eventual, and larger folder sets or failures extend the refresh cycle. Native SMB
notifications are server-dependent. This loopback fixture does not establish notification
coverage on the user's NAS or NetFS guest-loopback reconnection.

The initial provider-launch failure came from the revoked VM signer and stale registration,
not a source listing result. The valid app was registered before launch and the running app's
executable was verified. The comparison reused the same domain and fixtures afterward.

## Cleanup and evidence

The test location, keep request, downloads, saved server, native mount, SMB share and source
folder were removed. The Keep Downloaded list was not saved. All fixture app descriptors were
gone after server removal. Previous share definitions matched the snapshot exactly; SMB was
unloaded, SMB guest access was off and guest login stayed off. The original NAS connection and
Cairndex were preserved. Final diagnostics reported zero catalogs, kept items and stage files,
with one original share/session. The final audit found zero private-pattern matches in 184
retained subsystem messages. No VM restart or network cut was made.

- VM `.local/phase2/m15-checks.log` records all required checks. The source did not change after
  this run; later edits completed documentation and results.
- VM `m15-verify-{initial,edit-add,content-pending,content-final,rename-final,recovered,ejected,reconnect}.json`
  records hashes with hydration forbidden. `m15-dirs-rename-final.json`, `m15-denied-check.json`,
  `m15-eject-check.json`, `m15-reconnect-diagnostics.json`, `m15-location-removal-check.json`,
  `m15-server-removal-check.json` and `m15-cleanup.json` record state checks in the same directory.
- VM `m15-runtime-messages.ndjson` contains message-only evidence. The audit checks mounted-share
  values, signing-team values, addresses and path patterns; its summary is `m15-log-audit.json`.
- Matched local recordings: `results/nas-change-discovery-20261019/{before,after}.mp4` and
  `comparison.png`. Cropped frames were inspected and show only disposable fixture contents.
- Ready Mac app: `.build/m15-host/Build/Products/Release/TinyMounterPrototype.app`.
  Its strict/deep signature passed with the installed app's bundle ID and unchanged entitlements.
  `results/nas-change-discovery-20261019/host-signed-build.log` is redacted; `host-ready-state.json`
  records verification and removal of build-created registration. The installed app was untouched.

Next, check live changes during physical-Mac use after the installation recorded below.
Broader NAS coverage and the existing physical-Mac offline-hash and restart checks remain open.

## Physical-Mac installation, 2026-10-19

The user approved installation with "yes". At 16:15 US/Pacific, the running app quit normally,
the previous bundle was backed up, and the signed M15 build replaced it in Applications and
opened. Signing team, bundle ID and entitlements matched before replacement. Strict/deep
signature verification passed, both installed binaries matched the ready build, and one app
and one provider process ran from Applications.

Launch retained one location, catalog and domain, with no unknown domains or failed sequences.
Before and after diagnostics showed 540 items, 14 listed folders, one connected share/session,
zero keep requests and zero stage files. No user setting, download or mount was reset.
The new app's directory monitoring opened additional notification-only descriptors as expected.

The existing 182-test VM result still applies because installation changed no source. Local
installation evidence is `results/nas-change-discovery-20261019/host-install.json`, including the
backup path, and `host-installed-provider.json`. Live NAS changes, offline hashes and macOS
restart on the physical Mac remain unverified. Nothing was pushed or merged for M15.

## Physical-Mac user check, 2026-10-19

After receiving the Finder live-change test sequence, the user confirmed that it worked and
reported updates within three seconds. This is a user-reported observation on the installed
M15 build and their existing NAS connection. Cache state and operation-by-operation timestamps
were not recorded, so it is not a controlled latency measurement or guarantee.

The live-change check is confirmed by the user. Physical-Mac offline hashes and macOS restart,
QSpace and broader NAS coverage remain open. No source, installed app or user state changed in
response to this report.
