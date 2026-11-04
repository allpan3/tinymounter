# Single-client candidate validation, 2026-11-04

This report replaces the [earlier candidate record](2026-11-04-integrated-candidate.md) as the
summary of the `single-smb-client-prototype` branch. It covers the checks run after that record,
corrects two of its claims, and states the decision that remains.

## Outcome

The candidate passes the functional checks below, after three fixes found by those checks.
Measured read-only performance meets its targets in the VM; writable partial reads do not.

- **Functional checks pass.** Prefetch cleanup, automatic reconnection after a full VM restart,
  OS disk-pressure eviction, an interrupted upgrade and account-mismatch refusal were checked in
  macOS VM 1 against the Linux Samba fixture. The checks found and fixed three defects: a failed
  prefetch kept its space reservation and slot without scheduling expiry; an unanswered NetFS
  server-info request stopped automatic remounting; and one account's share could move to another
  account's server record. Successful concurrent use of two accounts was not established.
- **Read-only performance passes.** Partial reads reach a ratio of medians of 0.917 and a
  median paired ratio of 0.901 against native SMB. Seeks during streaming reach a p95 of
  0.737 s over 24 seeks, within the 1 s target.
- **Writable partial reads fail.** Five cold-cache rounds give a median paired ratio of 0.725
  (ratio of medians 0.759) against the 90% target. Writable seeks pass at a p95 of 0.824 s.
  The earlier 27 MB/s writable result did not reproduce, and no tested change to capabilities,
  POSIX flags or extent size improved the rate.

The decision that remains is the user's: whether to adopt this transport and install it on the
physical Mac with Start Fresh. Nothing in this report was installed on the physical Mac.

The candidate is commit `Refuse a share connected through another account`, built as signed VM
build 21. With this report on top, all 658 tests and the required VM checks pass, with two
optional skips and no Swift warnings. The normal-build gates for folder organization, deletion
and permanent deletion stay off.

## Corrections to the earlier record

- **0.917 is a ratio of medians.** The earlier record called 0.917 a "median ratio". It is the
  median provider rate, 154.77 MB/s, divided by the median native rate, 168.81 MB/s. The median
  of the five paired ratios is 0.901, and the lowest is 0.870. Both summary values pass the 90%
  target; two of five pairs are below it.
- **One SMB client does not make stale names or misdirected writes impossible.** The earlier
  record said no native-cache interaction can show them. This branch still mounts each share
  natively to obtain the user's grant and credentials, and other SMB clients, other Macs and
  programs on the server can still change the share. The single client removes the specific
  mixed-client cache interaction reproduced on November 3. It does not remove external writers,
  and the account-isolation defect below shows that the native mount still affects behavior.

## Functional checks

| Check | Result | Notes |
| --- | --- | --- |
| Prefetch claim, mismatch, seek cancellation, expiry, failure and close | Pass | Four permanent tests in `ReadPrefetchTests`; the failure test reproduced the defect before the fix |
| Prefetch cleanup in steady state | Pass | Five 512 MiB writable rounds: 159 completed and 1 stopped prefetches; 154 claimed, 6 discarded, all staging files removed |
| Prefetch cleanup at relaunch | Pass | Launch of build 21 logged `staging_removed=0` |
| Automatic reconnection after a full VM restart | Pass | Offline save and a new read recovered without user action |
| OS disk-pressure eviction | Pass | Kept and pending items stayed; ordinary downloads became dataless |
| Interrupted upgrade with unchanged format | Pass | A killed upload and an offline save published after the new build launched |
| Account-mismatch refusal | Pass after fix | The existing share and its locations stay under the first account; concurrent use of both accounts was not established |

### Prefetch

`ReadPrefetch` now owns the prefetch state machine in TransferCore. A failed or stopped prefetch
discards its candidate at once, which releases its space reservation and its slot. Before the
fix, the catch path returned before scheduling expiry, so a failed prefetch blocked the next one.
The seek series below also audited every prefetch: none was left without a claim or a discard.

### Reconnection after restart

The test credential was saved in the VM's login keychain as an internet password, without being
displayed. macOS asked twice whether NetAuthSysAgent may use it; the VM account's password was
entered through VMPal's password input, and Always Allow was chosen each time.

Sequence: download `pending.txt`; stop `smbd`; save new content offline; restart the VM. The VM
signed in automatically and the app reopened by window restoration. Remount attempts failed with
status 60 while the server was down. After `smbd` started, the remount succeeded within 15 s,
the pending save published without Retry, and a new 4 MiB read matched the server's hash. All six
locations were retained.

The first restart attempt found a defect: while the server VM was paused, NetFS reported status
-1 ("GetServerInfo failed"), and the remount policy treated it as final. Commit
`Keep retrying a remount when the server does not answer` retries it with the normal backoff.

The save landed as a conflict copy, with exact bytes, and the original stayed unchanged. The
cause is not the restart: an online control reproduced it. A POSIX read of the whole file runs as
a partial demand fetch, which does not establish an edit base. A later save then cannot prove it
replaces the version it read. Saves after Finder Download Now or a coordinated editor read, such
as TextEdit's, publish in place, as the next check shows.

### Disk-pressure eviction

The VM's APFS container reports about 926 GiB of host-backed capacity, so filling it was unsafe.
Additional APFS volumes created with `-reserve` lowered the container's free space without
writing data. Free space fell from 28 GiB to 6 GiB, which raised `VQ_LOWDISK`; a 5.8 GB filler
of written data then raised `VQ_VERYLOWDISK`. Both events made the deleted daemon request purges,
and `fileproviderd` made downloaded documents dataless across the TinyMounter domains.

| Item | State before | After both events |
| --- | --- | --- |
| `keep.bin`, Keep Downloaded | 64 MiB downloaded | 64 MiB downloaded |
| `pending.txt`, saved while the server was stopped | Pending | Pending, offline bytes intact |
| `plain.bin`, downloaded by Download Now | 64 MiB downloaded | Dataless |
| `later-read.bin`, downloaded earlier | 4 MiB downloaded | Dataless |

After the reserve volumes were deleted and `smbd` started, the pending save published in place
with the offline hash. An earlier pass without kept or pending items evicted 15 documents.

### Interrupted upgrade

An 805,306,368-byte new file was copied into the writable view. Eight seconds later, the app and
its extension were killed. The server then held 314,638,336 bytes under the final name; the
interface already states that other computers can see a new file before its upload finishes.
With the server stopped, an existing file was saved offline. The signed build 19 was then
installed over the killed diagnostic build 20, which shares its catalog format, and launched.

When the server returned, both changes published within 18 s without user action: the new file
with its full length and hash, and the offline save in place. All six locations, the Keep
Downloaded file and the evicted state of other files were retained. This is an update with an
unchanged format. Start Fresh is a different path, recorded in the
[Start Fresh installation](2026-11-02-start-fresh-install.md) results.

### Account isolation

A disposable Samba account `tmiso` with a private share was created; its password was generated
on the server and moved into the VM keychain without being displayed. The account, share,
keychain item and password files were removed afterwards.

The check found a defect. macOS reuses an existing mount of a share, whichever account asks
for it. Add Share under `tmiso@<host>` offered the share already mounted as `tmtest`, and
the app moved that share, with its locations, to the `tmiso` server record. The locations then
showed `tmiso` but used the `tmtest` connection. Commit `Refuse a share connected through another
account` refuses such a share with an explanation; build 21 shows it and keeps the share under
`tmtest`.

The private `tmiso` share could not be connected while `tmtest` was connected to the same host:
macOS reused the existing session, and the server refused it. No data crossed between the
accounts. The app's message for that case, "tinymounter cannot do this (status=2)", does not
explain the cause. Connecting both accounts through different host names was not tested.

## Performance

All performance numbers come from macOS VM 1 and the Linux Samba VM. They do not establish
physical-Mac throughput.

### Partial reads

Each round read 512 MiB of `partial.bin` with 1 MiB `F_NOCACHE` reads through ReadCheck, the
signed app that reads a file chosen in an Open panel. A native SMB read of the same range
followed or preceded it, in alternating order. Before every arm, `mincore` on the server
confirmed zero resident pages.

| View | Provider median MB/s | Native median MB/s | Ratio of medians | Median paired ratio | Lowest pair |
| --- | ---: | ---: | ---: | ---: | ---: |
| Read only, build 17 | 154.77 | 168.81 | 0.917 | 0.901 | 0.870 |
| Writable, build 20¹ | 133.96 | 176.54 | 0.759 | 0.725 | 0.636 |

¹ Build 20 is build 19 with the diagnostic patch below, which affects only the diagnostic
fixtures, not `partial.bin`.

All ten provider hashes match independent server reads. The writable pairs were 0.636, 0.859,
0.725, 0.728 and 0.640.

In the writable view, the app claims every prefetched extent in about 2 ms, and `fileproviderd`
dispatches speculative requests as it does in read-only views. Steady-state extents take about
117 ms per 16 MiB, against 82–94 ms in the read-only series. The extra time is in the system's
handling of each fault, not in the transfer.

### The earlier writable delay

The earlier record measured about 27 MB/s in a writable view, with 0.5 s between each
materialization and its completion and no speculative requests. That state did not reproduce:
a fresh file in the same view, with cold server cache, read at 121 MB/s, and switching the
view to Read only and back did not change it. The slow pilot ran before the VM restart, in a
`fileproviderd` process that had run many earlier tests. Its cause was not established.

A diagnostic build tested three changes on one file each, reading 256 MiB from offset 64 MiB:

| Variant | MB/s |
| --- | ---: |
| Unchanged writable item | 120.6 |
| Read-only POSIX flags (`userReadable` only) | 115.4 |
| Read-only view capabilities | 114.1 |
| 64 MiB demand extent | 87.7 |

None improved the rate; the larger extent was slower, because each fault waits for more data.
These reads used warm server cache and a command-line reader, so they compare variants, not
native throughput. No change was made to the product.

### Seeks during streaming

Each trial streamed 32 MiB, then read 1 MiB either just past the stream (an overlap seek, which
the prefetch may already hold) or 48–80 MiB away. Each series ran 24 trials, alternating kinds.

| Series | p95 | Median | Max | Overlap seeks | Away seeks |
| --- | ---: | ---: | ---: | ---: | ---: |
| Writable, build 18 | 0.824 s | 0.734 s | 0.848 s | 0.645–0.848 s | 0.693–0.824 s |
| Read only, build 19 | 0.737 s | 0.651 s | 0.771 s | 0.001 s | 0.651–0.771 s |
| Native SMB | 0.012 s | | 0.013 s | | |

All 48 range hashes in each provider series match the server. Both provider series pass the 1 s
target. They remain far slower than native, because each seek waits for a new 16 MiB extent and
the first fault in a region takes about 0.65 s, mostly outside the transfer. An earlier read-only series
in 64 MiB regions was discarded: read-ahead spilled across regions, and the server VM paused
when its host disk limit was reached.

## Supported workflows

The workflows in the earlier record still pass. Folder organization and custom permanent
deletion need the validation gates that normal builds keep off. Custom Delete Permanently… is
approved by the user. Ordinary Finder deletion and Finder Replace remain refused.

| Workflow | Status |
| --- | --- |
| Browse and open files | Pass; partial reads meet the target only in read-only views |
| Keep Downloaded | Pass, including folders and disk-pressure eviction |
| Create files and folders | Pass, including an upload killed mid-transfer |
| Save, repeated Save and Save As in TextEdit, Preview and Xcode | Pass |
| Saves after a POSIX whole-file read | Become conflict copies; the original is kept |
| Rename and move within a location | Pass, behind the folder gate |
| Delete Permanently… | Pass, behind the permanent-deletion gate |
| Offline saves through Quit, crash, restart and upgrade | Pass |
| Automatic reconnection after restart | Pass with a password saved in the keychain |
| Recovery Export, Retry and Stop Uploading | Pass |
| A second account on the same server | Refused while the first is connected |

## Transport adoption assessment

For the single-client transport:

- Full downloads, fully local reads, read-only partial reads and seeks meet their targets in the
  VM.
- One SMB client handles every read and write, which removes the mixed-client cache interaction
  reproduced on November 3.
- The functional checks above pass, including restart, eviction and upgrade.

Against it, or still to be decided:

- Writable partial reads reach about 0.73 of native.
- The app owns its SMB stack, including security fixes and server compatibility. Only Samba 4.19
  in a Linux VM has been tested.
- A process-wide lock serializes direct SMB connections, and each fetch opens a new encrypted
  connection.
- Credentials and grants still come from the native mount and NetFS, so restart and account
  behavior share their limits.
- The catalog uses different remote identities, so installation needs Start Fresh. Pending
  physical-Mac changes must be finished or exported first.

### libsmb2 licence obligations

libsmb2 6.3 is LGPL-2.1-or-later. The app builds it as a separate dynamic library in
`Contents/Frameworks` and bundles the licence and the vendor notice. The user accepted this
licence for main's protected operations, which already ship the library, so its obligations
already apply. Adopting this transport makes the library carry all reads and uploads. That adds
maintenance and security responsibility, not new licence obligations.

Distribution of either branch must meet these obligations, which are not yet fully met:

- **Change notices (§2(b)).** Each modified file must carry a prominent notice of the change and
  its date. The local changes are described in `Vendor/libsmb2/README.md`, but the modified files
  carry no such notices.
- **Source (§4).** The bundled library needs complete corresponding source, including local
  changes and build scripts. Supply it with the library or provide equivalent access from the
  same download location. Any written-offer route under §6(c) also needs the materials specified
  in §6(a) and an offer valid for at least three years.
- **Relinking (§6).** Users must be able to replace the library with a modified version. With
  hardened runtime and library validation, a re-signed library does not load unless the user
  re-signs the whole app or disables library validation; release packaging must document that.
- **Terms (§6).** Distribution terms must permit modification for the user's own use and reverse
  engineering for debugging those modifications.

## Remaining checks and decisions

| Item | Kind | What it needs |
| --- | --- | --- |
| Adopt the transport and install on the physical Mac with Start Fresh | User decision | The user's choice, including whether the folder and Delete Permanently… gates are on |
| Physical-Mac acceptance | Blocked by that decision | Installation, then the physical-Mac checks |
| Writable partial reads | Product limit | Accept about 0.73 of native, or a design change measured by the same method |
| Saves after a POSIX whole-file read | Product limit | Accept conflict copies, or a design that establishes an edit base for such reads |
| libsmb2 distribution obligations | Release gate | Change notices, source provision and relinking documentation |

## Evidence

Private evidence is in ignored `results/` directories in macOS VM 1:

- `results/perf-20261104/`: `seek-writable-18.json`, `seek-readonly-19.json`,
  `seek-native-19.json` and their runtime logs; `restart-19.log`; `pressure-19.log`,
  `pressure-2.json`, `pressure-2.log` and `pressure-2-show.log`; `diag-20.json`, `diag-t1.json`,
  `diag-t2.json`, `rc-t3.json` and their runtime logs; `w-provider-1.json` to `w-provider-5.json`,
  `w-native-1.json` to `w-native-5.json` and their runtime logs; `upgrade-upload2.log`;
  `relaunch-21.log`.
- `results/folder-single-20261103/`: the build logs, the diagnostic patch `diag-writable-20.patch`
  and `checks-candidate-21.log` with the required checks.
- Host `results/single-client-20261103/`: signed builds 18 to 21.

The Linux server's `mincore` checks ran before each partial-read arm; their output is in the
session transcript. The fixtures `bench-20261104/`, `restart-20261104/`, `pressure-20261104/`
and `diag-20261104/` remain on the Linux Samba share. The M22 Overlap view is writable, build 21
is installed in the VM, and the temporary reserve volumes, filler files and test account are
removed.

Host disk-use limits were raised during testing from 150 to 170 GB for macOS VM 1 and from
30 to 40 GB for TinyMounter Samba Test. After cleanup, macOS VM 1 uses about 127 GB and its
150 GB limit is restored. The Samba VM uses about 35 GB with the retained fixtures, so its
40 GB limit remains; restoring 30 GB would put it over the limit again.
