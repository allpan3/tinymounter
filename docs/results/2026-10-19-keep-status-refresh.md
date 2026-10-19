# Keep Downloaded status refresh

Date: 2026-10-19. Decision status: implemented, verified in the signed VM app and installed on
the physical Mac with the user's approval.

An existing verified item now stays Available offline while a second request downloads. The
signed before/after comparison reproduced the original reset and passed with the fix. All four
fixture files matched their source hashes with further downloading forbidden. All 175 tests and
required checks passed, with no Swift warnings. Physical-Mac feedback on this fix and Finder's
progress circle remains open.

## Setup and method

The development Mac and macOS VM 1 both ran macOS 27.0.1, build 26A434. The fixture used a
temporary, read-only guest SMB share inside the VM, within the approved M14 test scope. It held
an independent 16 MiB file and a tree with 64 MiB, 0.0625 MiB and empty files plus an empty folder.
The NAS remained read-only and was not used for these downloads.

Both signed builds used the same app path, domain and fixture. First keep the independent file
and wait for Available offline. Pause Downloads, keep the tree, return to Settings and resume.
Record only the Keep Downloaded rows. Before the fixed run, Allow Removal on the tree and
Finder's Remove Download evicted its files; the independent copy stayed local. Verify the same
initial statuses before repeating the sequence. Filesystem, SMB and provider caches were reused
and uncontrolled; this comparison makes no performance claim.

## Change and checks

Refreshing one request previously reset every Settings row to Requested until macOS finished
its location-wide synchronization check. That reset did not remove or redownload existing copies.

The controller now remembers content versions that passed synchronization and the local-copy
check during this app session. Each refresh first checks fresh local metadata and materialized
items against those versions. Unchanged verified files can remain Available offline while the
location synchronizes a new request. A changed version, missing or updating local copy loses its
verification. Folder status still requires current complete listings, materialized folders and
verified files throughout the tree. Disabling or replacing the provider clears remembered versions.
A failed or inconsistent observation cannot produce a positive result.

| Check | Result |
| --- | --- |
| Original signed build, resume the second request | Both rows became Requested, then Available offline |
| Fixed signed build, same steps | Independent file stayed Available offline; only the new tree remained Requested until completion |
| Full local reads with hydration forbidden | All four SHA-256 comparisons matched the fixture |
| Regression tests | Independent requests, same-size/date version changes, missing or updating copies, removed requests, a new verifier and folder membership/listing/materialization changes passed |
| Required VM checks | 175 tests, zero failures; project generation, release CLI, benchmark checks and unsigned app build passed; no Swift warnings |
| Retained log audit | 72 message-only entries, zero matches for tested private mount/team/path patterns |

No saved format, download policy, sandbox entitlement or NAS write behavior changed. The new
content-version checks have unit coverage; source mutation and provider disablement were not
repeated in this signed comparison. Available offline still refers to the latest source version
observed by the app. Finder's Remove Download remains a native command; Allow Removal first ends
a Keep Downloaded request.

## Cleanup and installation

The test location, downloads, requests, server, mount, share and local source were removed without
saving the keep list. Original share definitions matched their snapshot after restoration; SMB
was unloaded, SMB guest access was off and guest login stayed off. Final diagnostics reported zero
catalogs, kept items and stage files, with the original one share/session. Cairndex was untouched;
no VM restart or network change was made.

At 06:18 US/Pacific, the physical-Mac app quit normally and the signed update was installed and
opened from Applications. Same team and bundle ID, strict/deep signature verification and app/
extension binary comparisons passed. One app and one extension run from Applications. Launch
retained one location/domain/catalog and all three keep requests, with no failed reconciliation
steps or stage files. The previous app is in the local app-backups folder. No cache reset or mount
change was made on the physical Mac. Nothing was pushed or merged.

## Evidence and next check

- VM `.local/phase2/m14-status-checks.log`, `m14-status-compile.log`, `m14-status-verified.json`,
  `m14-status-cleanup.json`, `m14-status-runtime-messages.ndjson` and `m14-status-log-audit.json`.
- Local `results/keep-status-refresh-20261019/{before,after}.mp4`, `comparison.png` and
  `{before,after}-statuses.json`. The inspected crops show only disposable fixture rows.
- Local `host-signed-build.log`, `host-install.json` and `host-installed-provider.json` in that
  results folder. The backup path is recorded in the installation evidence.

Next is the user's evaluation on the physical Mac. Its offline hashes and macOS restart check
remain open. The Finder progress circle has the limits recorded in its separate results log.

## Physical-Mac feedback

The user confirmed on 2026-10-19 that the installed fix works. This verifies the reported
Settings behavior in their use; a controlled offline hash run and macOS restart remain open.
