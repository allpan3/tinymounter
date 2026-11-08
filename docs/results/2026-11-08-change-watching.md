# Change watching for 0.2.0, 2026-11-08

## Outcome

Step 4 of the [connection-layer plan](../connection-layer-plan.md#implementation-steps) has its
self-contained part: `SMBNotify.c` (one CHANGE_NOTIFY connection and thread per share),
`SMBWatch` (the SMB `RemoteWatcher`) and `LocationChangeWatch` (the discovery folders of every
location on a share, reconnection and the listings each notice asks for). Nothing in the app
calls them yet; [wiring after step 3](../connection-layer-plan.md#step-4-wiring-after-step-3)
lists what must change.

Against the Samba fixture, driven through the built `libTinyMounterSMB`, every checked change in
a watched folder reached the owner in 1.2–2.4 ms, including a folder three levels below the
location folder. A content edit in an unwatched folder produced no notice. A queue overflow
became `lost`, a deleted watched folder became `lost` in 1 ms, an smbd restart became `ended`
and the watcher reopened and relisted 5.5 s later, and a server that stopped answering ended
the connection through the echo. An idle watcher survived 150 s with two echoes.

The Finder-level step 4 checks (changes visible in Finder within 3 s, `change notify = no`, the
app's own upload listings) need the wiring and remain open.

## Setup

- Client: VMPal `macOS VM 1`, macOS 27.0.1 (26A434), clone `~/Developer/tm-step4` at the
  commit that adds the watcher. `Tools/check-smb-watch.py` compiles the app's `SMBWatch.swift`,
  `LocationChangeWatch.swift` and TransferCore with `Tools/check-smb-watch.swift`, and links the
  `libTinyMounterSMB` that `Tools/run-checks.sh` built. A second libsmb2 connection
  (`Tools/check-smb-watch-actor.c`) makes the changes.
- Server: VMPal `TinyMounter Samba Test`, Samba 4.19.5-Ubuntu, global settings unchanged
  (`change notify` and `kernel change notify` on). A disposable account and share with a
  password generated on the server, moved as a file and never printed; both removed afterwards.
- Connection: SMB 3, signing and encryption required, NTLMSSP with the password. Watches have
  no `WATCH_TREE`, filter 0xF5F, 64 KiB output buffer, request timeout cleared.
- Latency runs from the start of the actor's operation to the `LocationChangeWatch` refresh
  callback, so it includes the operation (about 1 ms) but not `DirectoryRefresh`'s 500 ms hint
  delay or the listing.

## Data

`Tools/run-checks.sh` in the VM: passed. 534 tests, one optional skip, no failures; the app build
succeeded with no Swift warnings; SET_INFO 6, edit status 87, folder-create status 18 and CCM
7,205 cases passed.

Coverage through `LocationChangeWatch`, watched folders: the location folder `L`, `L/a` and
`L/a/b/c`. One trial each:

| Change by another client | In `L` | In `L/a/b/c` |
| --- | --- | --- |
| Create file | 1.4 ms | 1.3 ms |
| Write 4 KiB | 2.3 ms | 1.7 ms |
| Same-size write | 2.2 ms | 2.1 ms |
| Set attributes | 2.4 ms | 2.0 ms |
| Rename | 2.1 ms | 1.9 ms |
| Delete | 1.8 ms | 1.7 ms |
| Create and remove a folder | 1.2 ms, 1.2 ms | 1.6 ms, 1.7 ms |

A file create and an 8 KiB content write in the unwatched `L/a/b` produced no notice in 5 s,
also none from the watches on `L/a` and `L/a/b/c`. The 60 s relisting covers that folder.

Other cases:

| Case | Result |
| --- | --- |
| 1,100 creates (677 ms) while the notify thread was held, so no request was pending | one `lost` as soon as the watch re-armed, no other notice |
| Another client deletes a watched folder (raw: empty and previously non-empty) | `STATUS_DELETE_PENDING` in 1–2 ms; the parent's watch reports REMOVED |
| Same through `SMBWatch` | `lost` in 1 ms; the parent folder could be removed 2 ms after the deletion |
| Rename of the watched folder's grandparent while watched | allowed by Samba; the watch keeps reporting under its old path |
| `watch(_:)` removing a folder | returned after the server closed it, 0.5 ms |
| `systemctl restart smbd` (75 ms) | `ended`; reopened on the first retry; every folder relisted 5.5 s after `ended` (5 s backoff); the next create reported in 3.3 ms |
| The account's smbd stopped with SIGSTOP, echo every 5 s | `ended` with `STATUS_IO_TIMEOUT` (0xC00000B5), libsmb2's local reply timeout on the echo; 3 echoes before |
| Idle 150 s, echo every 60 s | 2 echoes answered, no notice during the idle period, next create 4 ms |
| 70 folders requested | 64 directories open on the server (`smbstatus -L`), one watcher process; 64 of 70 folders reported a create |

### Name form

Notice entries carry the server's stored spelling: a name created NFC (U+00E9) came back NFC,
a name created NFD (U+0301) came back NFD, the same as `smb2_readdir`. The watch path itself is
composed by `tm_smb_compose`, so an NFD spelling of an NFC folder opened it and reported its
changes. The catalog compares names in composed form (prototype.md, "Name spelling over SMB"),
and the watcher never uses entry names: a notice names only the watched folder by the path the
app gave it, and the listing decides what changed. NFC or NFD in a notice therefore changes
nothing.

## Decisions taken in the implementation

- **A deleted watched folder is `lost`, not `ended`.** The plan's rule ("any other completion →
  `ended`") would reconnect the whole share and relist up to 64 folders whenever someone deletes
  a folder on the NAS. `lost` lists the folder and its parent instead; the folder stays
  unwatched until the discovery set drops it.
- **Open failures don't end the watcher.** A missing folder is `lost`; any other refused open
  (for example access denied or a server out of watch resources) leaves that folder to the
  periodic listing.
- **Backoff 5, 10, 20, 40, 60 s**, reset only after a watcher stayed open 60 s, so a server
  that accepts the connection but rejects every watch doesn't reconnect every 5 s. A refused
  sign-in (`notAuthenticated`, `noPermission`) parks the watcher until `reconnect()`.
- **One watcher per share for all its locations.** `ChangeWatchPlan` unites their folders,
  keeps the shallowest 64, and routes a notice to every location that watches that path.
- **The vendored libsmb2 guards its global context list** with a mutex: the notify thread
  creates and destroys its context beside other threads. The synchronous `smb2_echo()` check is
  fixed. Both are listed in [Vendor/libsmb2/README.md](../../Vendor/libsmb2/README.md).
- The password connect is one function in `SMBNotify.c` (`connect_share`) and the sign-in
  classification one function in `SMBWatch`, both to be replaced by step 2's shared versions.

## Limits

- One Samba version on a VM network, one trial per change. NAS servers, Wi-Fi, NAT and sleep
  were not tested; the user's NAS check is decision 5 of the plan.
- The SIGSTOP case shows the echo path, not a network loss; its timing includes the manual stop.
- After the SIGSTOP case the stopped process held the scratch folder; it was removed on the
  server after the process was killed. `smbstatus -L` then showed one stale share-mode name for
  a reused inode.
- Finder behaviour and the plan's step 4 checks 1, 2 and 5 need the wiring.

## Evidence

JSON lines in the VM clone `~/Developer/tm-step4/results/watch-20261108/`: `coverage.jsonl`,
`batch1.jsonl` (overflow, names and a first `parents` run whose deletion case was invalid: the
folder was not empty), `delete.jsonl`, `parents.jsonl`, `restart.jsonl`, `idle.jsonl`,
`echo-timeout.jsonl` and `limit.jsonl`; the checks log is `results/run-checks-step4.log`. Build
products were removed after the run. To reproduce, with a disposable
account and share prepared as above:

```sh
python3 Tools/check-smb-watch.py --host-file <file> --password-file <file> --share <share> \
    --account <account> coverage , overflow , names , parents , delete , idle 150 , limit
```

`restart` and `echo-timeout` print `ready`, then wait for the smbd restart or the SIGSTOP on the
fixture.
