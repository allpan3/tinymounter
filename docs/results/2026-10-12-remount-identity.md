# 2026-10-12 — Remount identity on the NAS share (phase 2, M2)

## Outcome

After an eject and a reconnect of the Finder SMB mount, every entry kept its inode, size, mtime
and ctime. Every entry's `st_dev`, and the share's `f_fsid`, changed. This supports decision D1 of
the [phase 2 plan](../phase2-plan.md): a content version built from size, mtime and ctime survives a
remount, and one that includes the device would make every downloaded copy download again.

It does not show that inodes survive a server restart, a rename, a replacement, or a reconnect by
another address or account. Only one eject and reconnect was run. The plan's second round, 10
minutes later, was not run: reconnecting needs the user to type the NAS password in Finder's
dialog, because the saved Keychain entry is not used.

## Setup and method

- VM: macOS 27.0.1 (26A434), the "macOS VM 1" guest. NAS: the UGREEN NAS running Samba 4.17.12
  (see architecture.md §11), one share mounted by Finder at `/Volumes/<share>`.
- Tool: a Swift program built with `swiftc` from the M1 `TransferCore` sources and a scratch
  `main.swift`. It only lists and stats: `readdir` and `fstatat(AT_SYMLINK_NOFOLLOW)` for every
  entry, plus `fstatfs` of the share root. It writes a private JSON (mode 0600) and prints counts
  only.
- Folders: the three largest folders with at most 500 entries, from a breadth-first walk of 80
  folders, 268 entries in all. The second snapshot read the folder list from the first.
- Run order on 2026-10-12: snapshot A at 04:49; `diskutil unmount` of the share, not forced, in
  place of Finder's Eject; reconnect through Finder's Connect dialog, with the user typing
  the password; snapshot B at 06:50. The share was disconnected for most of that time while the
  dialog waited for the user.
- Unchanged on purpose: server settings, `nsmb.conf`, the mount options Finder chose, and the NAS.
  Nothing was written to the share.

## Data

| Field | Entries compared | Changed after remount |
| --- | --- | --- |
| `st_dev` | 268 | 268 |
| inode (`st_ino`) | 268 | 0 |
| size | 268 | 0 |
| mtime (ns) | 268 | 0 |
| ctime (ns) | 268 | 0 |
| kind | 268 | 0 |

| Mount property | Changed |
| --- | --- |
| share root `st_dev` | yes |
| `f_fsid` | yes |
| `f_mntfromname` (compared as a SHA-256 hash) | no |
| mount path | no |
| smbfs mounts before and after | 1 and 1 |

No entry was missing or new after the reconnect.

## Correctness and limits

- One round only, about two hours apart. The second round of the plan is still to run.
- A remount on the same address and account. Inode stability across a Samba restart, a NAS
  reboot, a rename or a replacement is not tested. The catalog stores the file ID only as evidence
  and never uses it as a key, so this result does not change identity rules.
- `f_fsid` changes per mount, so a share session must read the mount identity again after every
  remount. The plan's `ShareAccess` already does this once per mount session.
- The tool found no symlinks or special files in these folders.

## Evidence

Private, under the ignored `results/remount-20261012/`: `a-before.json`, `b-after1.json`,
`compare-1.txt`, and `tool/main.swift`. The JSON files hold share-relative paths, so sanitize
them before sharing. To reproduce: build `tool/main.swift` with the `Sources/TransferCore/*.swift`
files (`swiftc -O`), run `snapshot <share root> a.json`, eject and reconnect, run
`snapshot <share root> b.json a.json`, then `compare a.json b.json`.

## Next step

D1 is decided: content versions use size, mtime and ctime only. The second remount round runs
when the user can type the password. M3, the share grant gate in the sandboxed app, needs no user
input.
