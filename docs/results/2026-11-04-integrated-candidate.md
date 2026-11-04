# Integrated single-client candidate, 2026-11-04

## Outcome

Read-only partial reads now pass the 90% target in macOS VM 1. Five fresh 512 MiB reads from
a 3 GiB file reach a median of 154.77 MB/s against 168.81 MB/s for matched native SMB reads, a
median ratio of 0.917. The earlier single-client build reached 0.492. The change prefetches the
next 16 MiB extent in the app's reader host while the File Provider callback returns the current
one. The extension's read-ahead policy is unchanged.

Three targets remain open:

- **Writable-location partial reads fail.** A writable view reads about 27 MB/s, because
  `fileproviderd` adds about 0.5 s after every coordinated materialization and never dispatches
  the extension's speculative requests there. The prefetch does not change this.
- **Automatic reconnection after a macOS restart is blocked.** It needs the test credential saved
  where NetFS can use it at login. The user must set this up; this task did not handle credentials.
- **OS disk-pressure eviction is blocked in this VM.** The VM disk reports 806 GiB free on host
  storage, so filling it is unsafe. It needs a small-disk VM or the physical Mac.

The candidate is commit `Prefetch the next extent for sequential direct reads` on the
`single-smb-client-prototype` branch, built as signed VM build 17. All 652 tests and the required
VM checks pass, with two optional skips and no Swift warnings. The normal-build gates for folder
organization, deletion and permanent deletion stay off. Production adoption of the single-client
transport and physical-Mac installation remain decisions for the user.

## Partial reads

### Method

The fixture is a new 3 GiB file, `bench-20261104/partial.bin`, on the Linux Samba share used by
the earlier [single-client series](2026-11-02-samba-names-and-uploads.md#read-measurements-2026-11-03).
The original NAS was not used. Build 17 ran with the M22 Overlap view set to Read only through
Settings. Each round read 512 MiB sequentially from a fresh offset with 1 MiB `F_NOCACHE` reads,
paired with a native SMB read of the same range. Before every arm, a `mincore` check on the Linux
server confirmed zero resident pages for the file. Rounds alternated order, starting with the
provider in round 1.

`fileproviderctl` has no eviction command, and Finder offers only Download Now for a partly
downloaded file. Each round therefore used a range that had never been read: offsets 64, 640,
1216, 1792 and 2368 MiB. Round 1 was the pilot and is included.

### Results

| Round | Offset MiB | Native MB/s | Provider MB/s | Ratio |
| --- | ---: | ---: | ---: | ---: |
| 1 | 640 | 172.44 | 152.84 | 0.886 |
| 2 | 1216 | 156.45 | 154.77 | 0.989 |
| 3 | 64 | 160.34 | 161.17 | 1.005 |
| 4 | 1792 | 168.81 | 152.14 | 0.901 |
| 5 | 2368 | 183.87 | 160.00 | 0.870 |
| Median | | 168.81 | 154.77 | 0.917 |

All five range hashes match independent Linux reads. Each provider sample allocated 528 MiB:
the 512 MiB read plus the one 16 MiB extent of read-ahead. The first read of each sample took
0.67–0.79 s.

Server traffic counters show about 1.0625 bytes fetched per byte read: 528 MiB of extents plus
one discarded 16 MiB prefetch per sample. The extension's read-ahead was therefore not duplicated
by the new prefetch.

### Mechanism

Before this change, each extent fetch opened a new encrypted SMB connection after the callback
arrived, and the next callback arrived only after macOS finished the previous materialization.
Connection and preparation cost about 35–50 ms per 16 MiB extent, on the critical path.

The reader host now records where each fetch ends. When the next fetch starts at that point, the
host fetches the following extent into its own staging file while the current one is returned.
A later request claims the prefetched data only on an exact match of item, content version and
range. Any other request, cancellation, or 2 s without a claim discards the data and releases its
space reservation. The `direct_read` log now separates connection, preparation and transfer time.

Logs for the five samples show 155 claimed prefetches, 10 extents fetched without prefetch (the
first two of each sample) and no stopped prefetches. Steady-state extents take about 82–94 ms per
16 MiB. The remaining gap to native comes mainly from the first two extents, where `fileproviderd`
adds about 0.6 s before steady state.

### Limits

- The seek-during-streaming latency and the 20-seek p95 gate were not measured for build 17. The
  prefetch adds at most one 16 MiB transfer ahead of a seek; this needs measurement, not inference.
- Leaked prefetch staging files were not checked. The `staging_removed=` count at the next app
  launch would show them.
- The VM's virtual NIC and storage do not establish physical-Mac throughput.

## Writable-location partial reads

A pilot in the writable M22 Overlap view read 512 MiB from offset 64 MiB in 19.645 s, about
27 MB/s. All 32 faults were coordinated reader faults. Each had a 500–530 ms gap between
`fileproviderd` logging "done executing materialize" and "finished providing". The extension
requested 31 sequential read-aheads, but `fileproviderd` dispatched none of them; only the 32
demand fetches ran. In the read-only view, 16 of 32 fetches in a comparable sample were
speculative.

The delay is not new. Build 08 writable 1 MiB seeks already took about 0.8 s, as recorded in the
[earlier results](2026-11-02-samba-names-and-uploads.md). The writable target therefore remains
unmet. A next experiment could test whether larger writable extents, or a different capability or
permission set on writable items, avoid the per-fault delay. This was not attempted here.

## Restart reconnection and storage pressure

The direct client authenticates with the cached GSS principal from the native mount. After a
macOS restart, reconnection therefore depends on NetFS finding a saved password. The earlier
trial in this VM ended with `EAUTH`, and the deletion checks also recorded that automatic
credential reconnection did not pass. Testing it requires the user to save the fixture credential,
for example with Finder Connect to Server and Remember this password. The existing evidence covers
a pending RTF that survives a VM restart and uploads after the test credentials are restored.

Actual disk-pressure eviction requires macOS to run low on space. This VM's APFS volume reports
806 GiB free on host storage, so filling it could affect the host. The existing evidence covers a
real disk-full condition on a disposable APFS image and signed low-space admission checks.

## Supported workflows in the candidate

These pass signed checks in macOS VM 1 with build 17 or the earlier builds on this branch. The
folder, deletion and permanent-deletion workflows need the validation gates that normal builds
keep off.

| Workflow | Status |
| --- | --- |
| Browse and open files | Full reads pass in read-only and writable views; partial reads pass in read-only views only |
| Keep Downloaded | Passes, including folders |
| Create files and folders | Passes |
| Save, repeated Save and Save As in TextEdit, Preview and Xcode | Passes |
| Rename and move files and folders within a location | Passes, behind the folder gate |
| Delete Permanently… for one file or folder | Passes, behind the permanent-deletion gate |
| Offline TextEdit saves through Quit, main-app crash and extension termination | Passes |
| Conflict preservation for competing server edits | Passes |
| Recovery Export, Retry and Stop Uploading | Passes |
| Low-space admission with retained earlier saves | Passes |

These remain refused by design: ordinary Finder deletion, Finder Replace, moves between locations,
and creating, renaming, moving or deleting items while offline.

## Remaining checks

| Check | Why it remains | What it needs |
| --- | --- | --- |
| Automatic reconnection after macOS restart | Needs a credential NetFS can use at login | User saves the fixture credential in the VM |
| OS disk-pressure eviction | Unsafe to fill this VM's host-backed disk | A small-disk VM or the physical Mac |
| Writable-location partial reads | Measured 27 MB/s against about 170 MB/s native | A design change, then the same five-round method |
| Seek latency and 20-seek p95 for build 17 | Not measured after the prefetch change | One signed seek series in the VM |
| Prefetch staging cleanup | Not checked | One app relaunch and its `staging_removed=` log line |
| Account isolation and interrupted upgrade | Not run on this branch | Signed VM checks |
| Physical-Mac acceptance | Not installed, by instruction | User approval to install with Start Fresh |

## Transport adoption assessment

For the single-client transport:

- VM full downloads, fully local reads and read-only partial reads meet their targets.
- One SMB client handles every read and write, so no native-cache interaction can show stale
  names or misdirected writes, as the November 3 probes did with mixed clients.

Against it, or still to be decided:

- libsmb2 is LGPL and needs a licence review before distribution.
- The app owns its SMB stack, including security fixes and server compatibility. Only Samba 4.19
  in a Linux VM has been tested.
- A process-wide lock serializes direct SMB connections, and each fetch opens a new encrypted
  connection. This bounds concurrent throughput.
- Credentials still come from the native mount and NetFS, so restart reconnection shares their
  limits.
- The catalog uses different remote identities, so installation needs Start Fresh. Pending
  physical-Mac changes must be finished or exported first.

The decision needed is whether to adopt this transport and install a build from this branch on the
physical Mac with Start Fresh, and if so whether the folder and Delete Permanently… gates are on.
The alternative is to keep the physical Mac on main.

## Evidence

Private evidence is in ignored `results/` directories:

- macOS VM 1, `results/perf-20261104/`: the native and provider partial-read JSON results,
  `partial-summary-17.json`, `runtime-17.log` with `prefetch` and `direct_read` lines, and the
  read-only and writable `fileproviderd` logs.
- macOS VM 1, `results/folder-single-20261103/checks-prefetch-17.log`: the required checks.
- Host, `results/single-client-20261103/signed-offlinecheck-17.tar`: the signed build 17.
- The Linux server's `mincore` and traffic-counter checks ran before and after each arm; their
  output is in the session transcript, not in these files.

The fixture file `bench-20261104/partial.bin` remains on the Linux Samba share for repeat runs.
The M22 Overlap view was returned to writable after the series.
