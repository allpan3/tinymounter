# Offline reading: pinned file without the NAS or the app

Date: 2026-10-11, US/Pacific. VMPal `macOS VM 1`, macOS 27.0.1 (26A434), signed prototype build with
seek-first read-ahead and range clipping at end of file. The user authorized cutting the VM off from
the NAS and restarting the VM for this test.

## 1. Outcome

**A file kept downloaded stayed fully readable with the NAS unreachable**, with the app quit and
with it running. Its SHA-256 matched the original each time. Keep Downloaded downloaded the whole
2.74 GB file in one full fetch, complete 13 s after the click.

**A file that wasn't downloaded failed with an error instead of returning bad data.**

- **App quit:** a read failed in 0.64 s with `Operation timed out`. The extension reported
  `serverUnreachable` at once.
- **App running, NAS unreachable:** the same failure took 30.7 s, because the app's own open of the
  NAS file blocked until the SMB client gave up.
- **Mislabelled error, now fixed:** that failure first reached the extension as a *permission*
  error (Cocoa 257). A stage-labelled rerun showed the app's bookmark resolution failing that way
  after about 30 s. The app now reports `serverUnreachable` for a bookmark failure at that point,
  and a third run confirmed it. The bookmark was validated when the location was set up. A
  bookmark that macOS reports as stale keeps its own error, so a moved or replaced source isn't
  misreported as an offline server.

**After the NAS came back, reads recovered on their own.** The first miss 0.6 s later still failed;
the next, 5 s later, succeeded in 0.8 s. No app restart, remount or domain reset was needed, and the
native SMB mount stayed connected (SMB 3.1.1).

**Persistence across process restarts and a flushed file cache:** passed. The test quit the app,
terminated the extension, restarted `fileproviderd` and flushed the unified buffer cache. The
pinned file then hashed correctly from disk. A full VM restart wasn't run: this agent's session
runs inside the VM, so it couldn't have checked or reported the result.

## 2. Setup and method

- Pinned file: the 2.74 GB MKV test location (`F7D8B0`). It started partially downloaded and was
  pinned with the app's Keep Downloaded. Completion was checked by allocated size, then by full
  SHA-256 against the original source's recorded hash.
- Hash reads ran from a shell whose inherited policy forbids downloading dataless files (policy 1).
  A hash can therefore only succeed from local content.
- Unpinned file: the 3.26 GB MP4 location (`CBD42C`), read at 1 MiB offsets that no earlier probe
  had downloaded. One attempt at a previously downloaded offset succeeded from cache. It's labelled
  as such and excluded.
- NAS cut: the VM's own session runs in this VM, so the whole network couldn't be turned off. A
  temporary `pf` anchor, `com.apple/900.tinymounter-offline-test`, blocked only the NAS address in
  both directions, for 88 s in total. Port 445 was confirmed unreachable during the block. Then the
  anchor was flushed and the `pf` reference released; `pf` was back to disabled.
- The test location stayed registered throughout. Nothing on the NAS was written.

## 3. Data

| Step | Condition | Result | Seconds |
| --- | --- | --- | ---: |
| Pinned hash, online | app running | match | 5.06 |
| A1 pinned hash | NAS blocked, app quit | match | 5.03 |
| A2 uncached 1 MiB read | NAS blocked, app quit | `Operation timed out`; extension `serverUnreachable` (-1004) | 0.64 |
| B1 pinned hash | NAS blocked, app running | match | 5.03 |
| B2 uncached 1 MiB read | NAS blocked, app running | `Operation timed out`; app reported Cocoa 257 (no permission) | 30.72 |
| C1 uncached read | NAS reachable again | `Operation timed out` (SMB still reconnecting) | 0.62 |
| C2 uncached read | 5 s later | success | 0.80 |
| D uncached read, stage logging | NAS blocked 40 s, app running | timed out; failed at bookmark resolution, Cocoa 257 | 30.82 |
| E uncached read, after the fix | NAS blocked 39 s, app running | timed out; extension `serverUnreachable` (-1004) | 30.77 |
| F uncached read | NAS reachable again | success on the first attempt | <1 |
| G pinned hash | app quit, extension and `fileproviderd` restarted, `purge` | match | 5.01 |

## 4. Correctness and limits

- This was a blocked server, not a cable pull or Wi-Fi loss. Interface changes, sleep and long
  outages remain untested.
- While unreachable, other programs using the native mount would also have stalled. The block was
  short and nothing visible failed, but other clients of this VM weren't checked.
- The 30-second wait comes from resolving the source bookmark on every miss, which blocks while the
  SMB server is unreachable; opening the file would block too. A shipping design needs a bounded,
  cancellable path and a reachability check before touching the mount.

## 5. Evidence

Private, in `results/offline-20261011/`: `attempt.py`, `attempts.jsonl` (every attempt),
`pinned-online-sha.txt`, the pin fetch log, and the extension and app logs for each blocked window
(`offline-window.log`, `stage-window.log`, `mapped-window.log`).

## 6. Next step

- **Full restart, still to do:** restart the VM or the physical Mac with the app not running, then
  hash or play the pinned file before launching the app. It's in the physical-Mac checklist.
- Bound the wait for an unreachable server instead of letting bookmark resolution block for about 30 s.
- The user's physical-Mac checklist (prototype guide, section 4) includes a real network
  disconnect and restart.
