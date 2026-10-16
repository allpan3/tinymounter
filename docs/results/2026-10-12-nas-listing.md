# 2026-10-12 — Core library listing on the NAS share (phase 2, M1)

## Outcome

The phase 2 core library lists the real SMB share correctly. Over 80 folders, the
`getattrlistbulk` listing matched `readdir` name for name and `fstatat` field for field: kind, size,
mtime, ctime and file ID. A second listing changed nothing in the catalog. On smbfs, the absence
check that guards every deletion confirmed made-up names with ENOENT and held back a reconcile when
a real name was missing from the listing.

This shows correct listings on a healthy share. It doesn't show what happens when a lookup fails
during a listing, which is the case the absence check exists for. Nothing in the prototype calls
this code yet: the File Provider extension still serves the phase 1 fixture.

## Setup and method

- VM: macOS 27.0.1 (26A434), "macOS VM 1". NAS: the UGREEN NAS running Samba 4.17.12, one share
  mounted by Finder (smbfs). Swift 6.4, `swiftc -O`.
- Code: the M1 `Sources/TransferCore` files as fixed after review, built with a scratch
  `main.swift` into a command-line program. The program is not sandboxed, unlike the app that
  will use this code (M3 tests that).
- Sweep: breadth-first from the share root, up to 80 folders and 5 levels deep. For each folder:
  list it; compare with `readdir` and `fstatat(AT_SYMLINK_NOFOLLOW)`; reconcile into a new catalog
  under `/tmp`; list again and compute the missing children; run the absence check on one made-up
  name and one real name; reconcile the second listing. For 40 names whose uppercase form differs,
  `fstatat` on the uppercase form. Output is counts only; catalogs were deleted after each folder.
- Depth check: the share root and, at each depth, the first folder in byte order with 2 to 500
  entries, down to depth 4.
- Read only: nothing was written to the share. The share was mounted throughout.

## Data

Sweep at about 08:10, on the fixed code:

| Measure | Result |
| --- | --- |
| Folders, entries (files) | 80, 653 (426) |
| Largest folder, median folder | 169, 5 entries |
| Unreadable, other kinds, invalid names, key collisions | 0, 0, 0, 0 |
| Names in `readdir` but not the listing, or the reverse | 0, 0 |
| Folders whose counts differ from `readdir` | 0 |
| `fstatat` mismatches: kind, size, mtime, ctime, file ID | 0, 0, 0, 0, 0 |
| Names with non-ASCII bytes; of those, not in NFC | 23; 0 |
| Missing children after an identical second listing | 0 |
| Made-up names confirmed absent (ENOENT) | 80 of 80 |
| Real names held back as `listingIncomplete` | 80 of 80 |
| Catalog rows changed by the second reconcile | 0 |
| Uppercase lookups that found the same file | 23 of 40 |

An earlier sweep at about 04:55, on the code before the review fixes, gave the same zero
mismatches over 80 folders and 775 entries (578 files). The two sweeps visited different folders,
because the walk follows the server's listing order. Its first listings took 7.5 ms median, 13.7
ms at p90 and 45.5 ms at most per folder. Those are first listings in that process with the macOS
and NAS caches in an unknown state, so they are not cold-cache numbers. The later sweep's times
are warm and are not reported.

The depth check (5 folders, depth 0 to 4, at most 37 entries) also gave 0 mismatches and 0
changes on the second reconcile.

## Correctness and limits

- The share is healthy, so a lookup that fails during a listing was never triggered. The absence
  check is tested against that case only with local folders (unit tests).
- Uppercase lookups found the same file for 23 of 40 names and nothing for 17. The NAS is
  neither fully case-insensitive nor fully case-sensitive for lookups, and this test doesn't show
  why. The absence check accepts both answers for a case-only rename, so it doesn't depend on
  this.
- The smbfs file ID from the listing equalled `st_ino` for every entry.
- No folder held a symlink, a special file, an invalid name or a key collision, so those paths
  were not exercised on smbfs.
- An eject during a listing, and a volume mounted inside the share, are only modelled in unit
  tests.

## Evidence

Private, under the ignored `results/nas-listing-20261012/`: `sweep.swift` and `depth-check.swift`,
the scratch `main.swift` files. The checks printed counts only and kept no output files beyond
this log. To reproduce: build either file with `Sources/TransferCore/*.swift` using `swiftc -O`,
and pass the share root as the only argument. Unit tests: `swift test`, 83 tests, all passing on
2026-10-12.

## Next step

M3: show that the sandboxed app reaches two folder levels below one saved grant of the share
root, and record how Finder shows the custom Keep Downloaded action.
