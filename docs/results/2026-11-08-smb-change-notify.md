# SMB2 CHANGE_NOTIFY through libsmb2, 2026-11-08

## Outcome

TinyMounter 0.2.0 can discover NAS changes with SMB2 `CHANGE_NOTIFY` sent by the vendored
libsmb2, without the hidden macOS mount. On the Samba 4.19 fixture, replies arrived 1–5 ms
after a change, libsmb2 delivered the reply buffer intact, and the probe's parser decoded every
entry. A watch can share a connection with listings and reads.

`SMB2_WATCH_TREE` is not enough on its own. A tree watch reported creates, deletes, renames,
attribute and timestamp changes made over SMB anywhere below the watched folder. It missed
content writes in subfolders, and it missed every change made directly on the server below the
first level. A watch without `WATCH_TREE` on each folder caught content writes in that folder.
The recommended design therefore keeps the M15 folder set and cap, with one non-tree watch per
folder on a dedicated connection, and keeps periodic listing as the fallback.

The probe found three hazards that the implementation must handle:

- libsmb2's per-request timeout expires a pending notify locally. The server's later reply then
  destroys the connection. The notify request must have its timeout cleared.
- libsmb2 has no client `SMB2 CANCEL`, and its synchronous `smb2_echo()` always fails on a live
  connection. The asynchronous echo works.
- 4,000 watches on one folder made Samba's `smbd-notifyd` grow to 2.7 GB when one change
  arrived. The kernel OOM killer stopped it, and `smbd.service` failed. 1,024 watches worked.

This is one Samba version on a VM network. Synology DSM, other NAS servers, Wi-Fi, NAT, Mac
sleep and long idle periods beyond 20 minutes remain unverified.

## Setup and method

- Client: VMPal `macOS VM 1`, macOS 27.0.1 (26A434), in its own clone `~/Developer/tm-notify-spike`.
  The probe `Tools/check-smb-notify.c` is compiled with the vendored libsmb2 sources by
  `Tools/check-smb-notify.py`, which also reads the credential from the VM Keychain and passes it
  on stdin.
- Server: VMPal `TinyMounter Samba Test`, Ubuntu 24.04.5, Samba 4.19.5-Ubuntu, defaults for
  `change notify` and `kernel change notify` (both on, so smbd also uses Linux inotify),
  `smb2 max trans` 8 MiB, `smb2 max credits` 8192, `deadtime` 10080 min.
- Connection: SMB 3.1.1, AES-128-CCM encryption (required by the share), AES-128-CMAC signing,
  NTLM. VM-to-VM network, no NAT.
- A disposable share and account were used only for this check. The existing `tmtest`
  Keychain item now asks for interactive approval, which another agent's spike was using, so
  the probe used a new account `tmnotify` whose Keychain item trusts `/usr/bin/security`.
  The password was generated on the server and moved as a file; it was never printed.
- Each scenario creates its own scratch folder, makes changes from a second libsmb2 connection
  (the "actor") and records each notify completion with a monotonic timestamp. The watching
  connection runs its own thread with a `poll()`/`smb2_service()` loop, as a TinyMounter
  watcher would. Server-local changes come from a shell script run as the share owner on the
  server. Their latency uses a clock offset estimated from the server mtime of files created over
  SMB (best round trip 0.2–0.3 ms).
- Default completion filter 0xF5F: file and folder names, attributes, size, last write, creation,
  security and the three stream flags. Last access is excluded. Output buffer 64 KiB unless
  stated.
- Latency is measured from the start of the actor's operation to the notify callback, so it
  includes the operation itself (1–4 ms).

## Data

### Coverage of one tree watch on the location folder

Changes made over SMB by the second connection (`coverage`, `content`, `latency`):

| Change | Depth 0 (watched folder) | Depth 1–3 |
| --- | --- | --- |
| Create file or folder | ADDED, plus MODIFIED | ADDED |
| Delete file or folder | REMOVED | REMOVED |
| Rename in place | RENAMED_OLD_NAME + RENAMED_NEW_NAME in one reply | same |
| Move to another folder | REMOVED, then ADDED + MODIFIED | same |
| Set attributes, set mtime, truncate (SET_INFO) | MODIFIED | MODIFIED |
| Write data, same size or extended | MODIFIED, 1–2 replies | **nothing** (0 of 30 at depth 3) |
| Write a named stream | not tested | ADDED with the base file's name (depth 2, one trial) |

Changes made on the server itself (`listen` plus a server script, 2026-11-08):

| Change | Depth 0 | Depth 1–2 |
| --- | --- | --- |
| Create, rename, delete, chmod, touch, same-size write | reported, 0–5 ms | **nothing** |
| Append to a file | not reported in 1 of 1 trial | nothing |
| Create a subfolder | ADDED for the subfolder | nothing for its contents |

Watches without `WATCH_TREE` (`flat`), three on one connection for the root, `sub` and
`sub/deep`: a write to a file in each folder produced two MODIFIED replies on that folder's
watch, 2–5 ms after the write started. A create in `sub/deep` produced ADDED and MODIFIED on
the `sub/deep` watch only. No watch reported changes in a deeper folder.

The pattern matches Samba's design: smbd reports changes that pass through its own SMB code
for the whole tree, and adds inotify events, which Linux delivers only for the watched folder's
direct children. Content writes over SMB reach a watch only through inotify. This is an
interpretation; the probe did not turn off `kernel change notify`, which is a global setting
shared with another agent's tests.

Reply contents: each reply is a FILE_NOTIFY_INFORMATION list with the action and a path relative
to the watched folder, using `\` as the separator. All replies parsed without errors. A single
create usually produces two replies (ADDED, then MODIFIED); a reader that re-arms after each
reply receives both.

### Latency

Changes from the second SMB connection, 30 samples each, tree watch:

| Change | Depth | Median | p90 | Max |
| --- | --- | --- | --- | --- |
| Create | 0 | 1.6 ms | 2.5 ms | 2.7 ms |
| Write 512 bytes | 0 | 2.0 ms | 2.9 ms | 3.2 ms |
| Delete | 0 | 1.7 ms | 2.2 ms | 2.6 ms |
| Create | 3 | 1.9 ms | 2.8 ms | 5.5 ms |
| Delete | 3 | 2.1 ms | 3.5 ms | 5.6 ms |
| Write 512 bytes | 3 | missed 30 of 30 | | |

Server-local creates at depth 0: 20 of 20 reported, median 0.05 ms after the server's
timestamp, range −0.4 to 2.6 ms. The clock offset error is a few tenths of a millisecond, so
these values mean "within about 3 ms", not sub-millisecond precision.

### Many changes and buffer size

| Case | Result |
| --- | --- |
| 2,000 SMB creates in a subfolder, watch re-armed after each reply, 64 KiB or 4 KiB buffer | 2,000 replies, one entry each, all names seen, no overflow; last reply with the last create (1.3–1.5 s) |
| 2,000 server-local creates at depth 0 in 40 ms | 79 replies, up to 124 entries each, all 2,000 names, no overflow |
| Changes made while no request was pending, then re-arm | delivered at once in the next reply (2 files, 5 entries) |
| 1,000 creates while not pending, 64 KiB buffer | one reply with 1,001 entries, 28,028 bytes |
| 1,001 creates while not pending, 64 KiB buffer | `STATUS_NOTIFY_ENUM_DIR` (0x0000010C), no entries |
| 100 creates while not pending, 4 KiB buffer | one reply, 101 entries, 2,828 bytes |
| 200 creates while not pending, 4 KiB buffer | `STATUS_NOTIFY_ENUM_DIR` |

Samba keeps up to 1,000 changes for an open handle with no pending request and also returns
`STATUS_NOTIFY_ENUM_DIR` when the changes do not fit the buffer. The client must treat that
status as "relist this folder".

Buffer sizes: 0 bytes always returns `STATUS_NOTIFY_ENUM_DIR`. 4 KiB and 64 KiB work.
Above 64 KiB, Samba rejects the request with `STATUS_INVALID_PARAMETER` because libsmb2 sends
a notify with a credit charge of 1. With the credit charge set to the buffer size in 64 KiB
units, 1 MiB and 8 MiB work, and 8 MiB + 1 is rejected (the negotiated maximum transaction
size is 8 MiB).

### Connection model

- With a notify pending on a connection, synchronous libsmb2 calls on the same connection
  (`smb2_opendir`/`smb2_readdir`, `smb2_open`/`smb2_pread`) took 1–3 ms, the same as without
  one. A change made during the listing was delivered by the notify callback inside the next
  synchronous call. libsmb2 dispatches every reply that arrives while any call services the
  socket, so the callback runs on whichever thread is in libsmb2 at the time.
- 64 and 1,024 watches on one connection: all were accepted with no early completions; one
  change completed all of them (last reply after 5 ms and 1.55 s), and all re-armed. libsmb2's
  credit count stayed at 1,023 because Samba grants credits in the interim responses.
- 4,000 watches on one connection: one change produced only 2 replies in 20 s, then the next
  connection failed. `smbd-notifyd` had reached 2.7 GB resident memory and was killed by the
  kernel OOM killer; `smbd.service` failed. smbd was restarted at once; the outage was about
  one minute.

### Cancellation, lifetime and timeouts

| Case | What the client observed |
| --- | --- |
| `SMB2 CANCEL` with the notify's MessageId (sent by the probe through libsmb2 internals) | completion with `STATUS_CANCELLED` (0xC0000120) in 0.7–0.8 ms; connection stays usable; re-arm works |
| Close the watched directory handle | completion with `STATUS_NOTIFY_CLEANUP` (0x0000010B) within 1 ms; close succeeds |
| Another client renames the watched folder | no completion; the watch keeps working under the new name |
| Another client deletes the watched folder | completion with `STATUS_DELETE_PENDING` (0xC0000056) |
| Server process for the connection killed | `smb2_service()` fails with POLLHUP at once; the pending callback receives a shutdown status when the context is destroyed |
| Server tree disconnect (`smbcontrol close-share`) | completion with `STATUS_NOTIFY_CLEANUP`, the same status as our own close |
| Reconnect, reopen and re-arm after either | 27–38 ms |
| 15 s with a notify pending, its request timeout cleared, connection timeout 10 s | no completion, no error |
| Same with libsmb2's request timeout left on | local `STATUS_IO_TIMEOUT` (0xC00000B5) after 10.8 s; the server's later reply made `smb2_service()` fail ("Failed to decrypyt pdu") and the connection was unusable |
| Synchronous `smb2_echo()` | always −ENOMEM, "Not Connected to Server": its socket check is inverted |
| Asynchronous echo with a notify pending | succeeds |
| 20 min idle with one pending notify, no echo | connection alive, no spurious completion; the next change arrived 1.6 ms later |

## Recommended design

- **Connection and thread.** Give each share one dedicated notify connection with its own
  `smb2_context` and thread. The thread runs the `poll()`/`smb2_service()` loop, arms, re-arms
  and closes watches, and sends echoes; nothing else uses that context, because libsmb2 is not
  thread-safe and callbacks run inside whatever call services the socket. Listings and reads
  stay on the existing short-lived connections. Sharing the connection works, but it would tie
  notification delivery to other work and expose watches to that work's error handling, which
  destroys the context on a 12 s timeout.
- **Watches.** One watch without `WATCH_TREE` per folder in the existing M15 set: listed
  materialized and kept folders and parents of kept files, at most 64 per share. A tree watch
  would miss content edits in subfolders on Samba, and per-folder watches also catch changes
  made on the server. Do not raise the cap toward the thousands; 4,000 watches crashed the
  fixture's notify daemon.
- **Requests.** Completion filter 0xF5F without last access. Output buffer 64 KiB: the largest
  size that works with libsmb2's fixed credit charge of 1, and above Samba's 1,000-entry queue
  for short names. Clear `pdu->timeout` on every notify request (TinyMounter's SMB code already
  includes `libsmb2-private.h`); keep normal timeouts on other requests.
- **Events.** Treat entries as invalidation hints, as M15 does: schedule a listing of the
  watched folder and let the existing listing and confirmation rules change the catalog. Re-arm
  in the completion callback. Samba queues changes made between replies, so re-arming promptly
  loses nothing while the handle stays open.
- **Relist triggers.** `STATUS_NOTIFY_ENUM_DIR`: relist that folder and re-arm. Any other error
  completion that the client did not cause, including `STATUS_NOTIFY_CLEANUP` without a local
  close, `STATUS_DELETE_PENDING`, or a socket failure: drop the watch, reconnect with backoff,
  reopen the watches and relist every watched folder, because changes during the gap are lost.
- **Stopping a watch.** Close the directory handle and treat the `STATUS_NOTIFY_CLEANUP`
  completion as the end. This avoids adding an `SMB2 CANCEL` command to libsmb2.
- **Keepalive.** Send an asynchronous echo every 60 s with a 10 s reply limit, and reconnect on
  failure. With a quiet folder, TCP sends nothing, so a vanished server or a network change
  after sleep stays unnoticed until the next real request. The 60 s value is a proposal. Samba
  kept a quiet connection open for 20 minutes; network and sleep failures were not measured.
- **Fallback.** Keep the M15 schedule: each watched folder relisted 60 s after a successful
  listing, one automatic listing at a time, failure backoff to 240 s, refresh on wake. Some
  servers accept watches and never complete them, and Samba itself misses some changes.

## Correctness and limits

- One Samba version with inotify on ext4. Synology DSM (also Samba-based, with its own changes),
  macOS, Windows and other NAS servers may differ in coverage, queue limits and memory use.
- The 4,000-watch crash shows the fixture's behaviour, not a safe limit. The safe ceiling lies
  somewhere at or above 1,024 on this 4 GB server; 64 per share leaves a wide margin.
- One append on the server at depth 0 produced no reply, while a same-size write did. The probe
  did not repeat it.
- Named streams were tested once, at depth 2.
- Only filter 0xF5F was tested. Which flag produced each event class was not isolated, so the
  recommendation keeps all of them rather than a minimal set.
- `SMB2 CANCEL` was sent by changing libsmb2's next MessageId around `smb2_queue_pdu()`. It
  shows server behaviour; it is not a design for production use.
- The idle test covered 20 minutes on a VM network. NAT timeouts, Wi-Fi changes and Mac sleep
  were not tested.
- The probe removed its scratch folder after each run except the interrupted 4,000-watch run;
  that folder went with the disposable share.

## Evidence

Raw JSON lines are in the VM clone `~/Developer/tm-notify-spike/results/notify-20261108/`
and copied to the ignored `results/notify-20261108/` on the host, which alone holds the
server script's timestamps:
`coverage.jsonl`, `batch1.jsonl` (content, buffers, first shared run), `batch2.jsonl`
(shared, latency, bursts, many), `batch3.jsonl` (first cancellation run and burst thresholds),
`cancel.jsonl`, `flat.jsonl`, `listen-local.jsonl` with `server-local-changes.jsonl`,
`listen-disconnect.jsonl` and `idle.jsonl`. The first shared run in `batch1.jsonl` and the
close-handle case in `batch3.jsonl` are superseded: a queued second reply completed the next
request early. The idle "completion" in `batch1.jsonl` has the same cause.

To reproduce in the VM, with a share and account prepared as above:

```sh
python3 Tools/check-smb-notify.py --share <share> --account <account> \
    --log <file> coverage , content , flat , latency 30 3 , burst 1001 65536 late , cancel
```

`listen <folder> <seconds>` prints events as they arrive and reconnects after a drop; run a
server-side change script or disconnect while it runs. Avoid `many` with more than about
1,000 watches on a shared fixture.

Cleanup: the fixture's `smb.conf` matches its original SHA-256 again after a targeted removal
of the test share section and a config reload. The share folder, the `tmnotify` Samba and Unix
accounts, its VM Keychain item, the server's temporary script and log, and the VM clone's build
products are removed. smbd is active. The fixture was not restarted except for the one smbd
service start after the OOM failure. The VM clone and its logs remain.

## Next step

Design the notify connection in the 0.2.0 protocol-neutral structure and add a small libsmb2
helper for the notify request with its timeout cleared and its credit charge set. The open
question is coverage on the user's NAS. The probe writes, so it must not run there. A
watch-only check, with the user making changes from another device, needs the user's decision.
