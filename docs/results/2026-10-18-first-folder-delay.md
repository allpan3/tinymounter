# First-folder delay on the physical Mac — 2026-10-18

## Outcome

The user's first slow Finder folder hit the app's five-second first-page deadline. The app
spent 9,468.3 ms in its share-listing stage for five entries, then 3.8 ms on the remaining
checks and catalog work. A retry joined the same listing and received the completed result.
The next three newly listed folders completed in 40.8–127.4 ms.

This identifies the slow stage, not the blocked system call. There was no matched native-SMB
first-access control, and cache states were not controlled. It does not establish whether the
pause came from opening the folder, a metadata read, or another part of source access. The
thread sample started after the pause and did not capture a listing operation.

The diagnostic change separates source lookup, session and location-root access, directory
open time and bulk metadata-read time. Listing behavior, safety checks, pagination and the
five-second deadline are unchanged. The signed VM app records the new fields, and all 156 tests
and required checks passed. The user approved installing the signed diagnostic build on the Mac.
The pause did not recur after app and mount resets, with the cache limits below. Its cause
remains unresolved.

## Setup and method

- Physical Mac, macOS 27.0.1 (26A434), installed signed File Provider approval build, 2026-10-18,
  23:10–23:14 US/Pacific. The user browsed in Finder and confirmed that mainly the first folder
  was slow. The location had just been added; each measured folder's first page requested a
  listing rather than serving its catalog.
- Read the app and extension's existing unified logs. A 20-second `sample` of the running app,
  taken after the reported pause, found no listing or directory-read stack. The app, connection,
  mounts and caches were left in place. No NAS content was changed or downloaded by the probe.
- SMB/client and NAS cache states are unknown. Later folders differ from the stalled folder;
  these samples are observations of the user's run, not a controlled cache comparison.

## Data

| Time, US/Pacific | Entries | Share-listing stage, ms | App total, ms | Extension first-page wait, ms |
| --- | ---: | ---: | ---: | ---: |
| 23:10:46, location root | 5 | 8.5 | 11.1 | Already in catalog before Finder opened it |
| 23:11:35, first child | 5 | 9,468.3 | 9,472.1 | Deadline at 5,333.5; late completion at 9,473.0 |
| 23:13:20, another folder | 18 | 54.5 | 60.8 | 61.2 |
| 23:13:27, another folder | 6 | 32.8 | 40.4 | 40.8 |
| 23:13:31, another folder | 136 | 124.8 | 126.9 | 127.4 |

At the deadline, the extension returned `NSFileProviderError.serverUnreachable` (-1004).
A second request joined the app's in-flight listing and waited 4,136.8 ms. Once the first
request completed, that retry received five rows; the next enumeration served the catalog.
The combined `list_ms` timer includes catalog lookup, acquiring a share session and location
root, directory open, metadata reads, parsing and mount verification. It excludes the later
catalog reconcile and is not a measurement of the SMB server alone.

## Correctness and limits

- Five entries were committed after the slow listing, with no skipped entry, held plan or
  tombstone. The subsequent folders likewise logged no skips or tombstones.
- A successful late listing resolves the temporary error, but Finder can retain a folder error
  until Try Again. This existing limitation makes a slow first listing more disruptive than a
  simple loading wait.
- The diagnostic fields contain durations, counts and existing opaque request IDs. No names or
  paths are added to logs. The captured errno is preserved before reading the timing clock.
- A controlled reproduction and native first-access baseline remain necessary. Increasing the
  timeout would not explain or remove the 9.47-second operation.

## Evidence

Local evidence under `results/folder-navigation-20261018/`: `host-app-log.json`,
`host-recent-listing-log.json` and `host-app-sample.txt`. The log records use opaque item and
request IDs; the result above does not include source names.

## Diagnostic verification

On 2026-10-18, 23:20 to 23:24 US/Pacific, the signed Release diagnostic build ran in
`macOS VM 1`, macOS 27.0.1. A temporary location listed the connected share's root and one child
in Finder. Both log lines included lookup, session, root, open and bulk-read times. The child
returned 16 entries with `open_ms=6.0`, `bulk_ms=7.9` and `bulk_calls=2`. These are instrumentation
checks with unknown SMB and NAS cache states, without a native control. The VM did not reproduce
the physical Mac's pause.

An initial attempt used a stale test-folder path that was not on the selected share. It failed
as missing before adding a location. The successful test used the share root. The temporary
location was removed afterwards, with no requested file download or NAS mutation. The existing
server and mount stayed in place.

`Tools/run-checks.sh` passed in the VM with 156 tests, zero failures, the generated-project check,
Release CLI and benchmark checks, and the unsigned Release app build. No Swift compiler warning
was reported. Deep, strict signature verification passed for the signed VM app and the ready
Mac build. The captured app messages passed the configured private-value check.

Additional local evidence is `results/folder-navigation-20261018/vm-runtime-log.json` and
`host-signed-build.log`. The VM check and signed-build logs are
`.local/phase2/listing-timing-checks.log` and `listing-timing-signed.log`.

## Physical-Mac diagnostic run

The diagnostic build was installed and opened after approval on 2026-10-18, about 23:35 to
23:49 US/Pacific, on the same physical Mac and macOS build as the original observation. Its
team and bundle identifier matched the installed app, its executable matched the ready build,
and deep, strict signature verification passed. The previous app was backed up locally.

The original location and downloaded files were preserved. A temporary duplicate used a new
catalog without Keep Downloaded requests. For the native control, the app quit normally and
the test share was normally unmounted, then mounted hidden through NetFS using its saved URL
and macOS credentials. The provider arm repeated the app and mount reset. No NAS content or
global cache setting changed.

| Time, US/Pacific | Operation | Entries | Open, ms | Bulk reads, ms | App/core total, ms | Extension wait, ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 23:39:12 | Native control, first child listing after remount | 6 | 2.7 | 7.3 | 11.0 | Not applicable |
| 23:39:12 | Native immediate repeat | 6 | 0.0 | 0.0 | 0.1 | Not applicable |
| 23:44:07 | Original stalled folder, launch refresh after another remount | 5 | 2.9 | 6.4 | 13.1 | Background refresh |
| 23:45:09 | Temporary location, first child page in Finder | 6 | 2.1 | 5.7 | 12.5 | 13.2 |

Every row used two bulk-read calls. The native control ran the same `DirectoryListing` code
outside the app sandbox. The native and temporary-location samples used the same six-entry
folder. The five-entry folder from the original stall was observed separately during launch
refresh, identified by its unchanged opaque item ID.

These are not matched cold-access samples. The original location automatically refreshes its
materialized folders at launch and warms the share before the temporary location opens in
Finder. NAS, kernel and persistent cache states remain uncontrolled. The table diagnoses the
attempts; it does not establish a performance ratio or explain the original pause. Some setup
probes waited on macOS file-access prompts. Allow was clicked, and those waits are excluded.

After the run, Storage reported the same downloaded total for the original location and zero
downloaded bytes for the temporary one. The temporary domain was removed. A new, unadded
"Listing test" draft with the same source was left selected for the user. It has no catalog
or downloaded files. Final diagnostics showed one catalog, no staging files and no kept files;
the original domain remained. The saved share stayed connected and hidden, and File Provider
stayed enabled. Live app messages passed the private-value token check.

Additional local evidence under `results/folder-navigation-20261018/` includes
`host-diagnostic-install.json`, `host-native-listing.json`, `host-reset-native.json`,
`host-reset-provider.json`, `host-diagnostic-live-log.ndjson` and `host-replay-ready.json`.

## Next step

In the selected "Listing test" draft, click Add, then Show in Finder and open a folder. Capture
another pause with the operation timings. This resets the location's listing history while
preserving the original downloads; it does not reset all SMB or NAS caches. A fully controlled
first-access reproduction remains open.
