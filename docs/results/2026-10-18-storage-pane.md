# Storage pane and folder completion (M8) — 2026-10-18

## Outcome

The Storage pane's totals match the downloaded files on disk, and Remove Downloads keeps kept
files. The Folder field suggests subfolders from a listing of the share.

| Question | Answer |
| --- | --- |
| Are the space totals right? | **Yes, for complete downloads.** The pane showed 617.5 MB and 982.3 MB; the sizes of the files that were not dataless added up to 617,530,693 and 982,301,975 bytes. A partly downloaded file isn't in the materialized set, so its 16 MiB didn't count. |
| Does Remove Downloads keep kept files? | **Yes.** A kept 310,464,214-byte file stayed downloaded in three runs, and the other downloaded files became dataless. After Allow Removal, a later run removed it. |
| Does a file that an app has open stay? | **Yes.** Its eviction failed with EBUSY, and the app said "tinymounter cannot remove 1 downloaded file." |
| Does completion list the share? | **Yes.** One typed letter listed the share root's 8 folders in 8.6 ms, and a typed folder with "/" listed its 2 subfolders in 9.2 ms. More typing in the same folder didn't list it again. |

The run found three defects, which are fixed (see [Defects fixed](#defects-fixed)). The worst:
a file that was read again after Remove Downloads downloaded at about 1.6 MB/s instead of in 3 s,
because read-ahead still counted its bytes as delivered. Not established: eviction under disk
pressure, several locations, and the physical Mac.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1, Xcode 27.0. Personal Team signed Release builds
  of the M8 code, built again after each fix.
- One SMB share mounted by Finder, with the saved grant. One location on a media folder of the
  share with 11 files: 6 of 2–3 KB and 5 of 307–433 MB. Here they are f0 to f10, in size order.
  Runs from 00:04 to 00:37 US/Pacific.
- A helper read a file in full or its first 16 MiB. It turns on the I/O policy that lets a process
  download dataless files (`setiopolicy_np`); without it, reads in the VM's exec sessions failed
  with EDEADLK.
- Disk use came from `lstat` of each file: its size, its allocated blocks and `SF_DATALESS`. The
  helpers printed only the index, never a name.
- Keep Downloaded and Allow Removal were clicked in Finder's context menu, and Remove Downloads in
  the pane, with VMPal's input tools. A helper process held a file open. Evictions from outside
  the app used `FileManager.evictUbiquitousItem(at:)`, as in M6.
- Events come from `log show` of the app subsystem at info level, which logs only IDs and counts.
- macOS asked whether VMPal Tools may access files that TinyMounterPrototype manages; it was
  allowed.
- After the location was added, Finder's sidebar didn't show it, and its context menu had no
  Download Now, Remove Download or Keep Downloaded, although `fileproviderctl evaluate` offered
  Keep Downloaded. A relaunch of Finder (`killall Finder`) showed all of them. The cause is not
  known; it didn't happen again in the run.

## Data

### Storage totals

| Time | Files on disk | Pane | Measured |
| --- | --- | --- | --- |
| 00:08:45 | f0, f1, f6 and f7 downloaded; the first 16 MiB of f8 | "617.5 MB downloaded · 919.5 GB available" | 617,530,693 bytes in the 4 complete files; f8 had 16,777,216 bytes allocated and stayed dataless |
| 00:25:30 | f0, f1, f6, f7 and f9; f7 kept | "982.3 MB downloaded" | 982,301,975 bytes |
| 00:34 | f6 only, after an outside eviction of f7 | "307.1 MB downloaded", with no action in the app | 307,062,035 bytes |
| 00:35:03 | none, after the last run | "0 bytes downloaded" | 0 bytes allocated, after an outside eviction of f8 |

The pane shows logical sizes. Allocated blocks are larger: 634,314,752 bytes at 00:08:45,
because each file rounds up to 4 KiB and f8's 16 MiB counts.

### Remove Downloads

| Time | Before | Confirmation | Result |
| --- | --- | --- | --- |
| 00:15:37 | f7 kept; f0, f1 and f6 downloaded | "3 files (307.1 MB)" | `files=4 removed=3 stayed=0`, 1.75 s. f7 stayed; f8's 16 MiB stayed. |
| 00:26:28 | f6 held open; f0, f1 and f9 downloaded; f7 kept | "4 files (671.8 MB)" | `files=5 removed=3 stayed=1`, error code 16 (EBUSY); "tinymounter cannot remove 1 downloaded file." f7 stayed. |
| 00:30:28 | the same, with the text fixes; f0 and f1 dataless | "2 files (671.8 MB)" | `files=3 removed=1 stayed=1`; f6 and f7 stayed |
| 00:31 | Allow Removal on f7 at 00:30:58 | "1 file (307.1 MB)": stale, it left out f7 | cancelled; fixed, see below |
| 00:35:03 | after the fix: f6 kept at 00:34:29, then allowed at 00:34:47 | "1 file (307.1 MB)" | `files=1 removed=1 stayed=0` |

Keeping f6 at 00:34:29 turned Remove Downloads… off at once, as nothing else was downloaded.

### Read-ahead after an eviction

| Read | Fetches | Time |
| --- | --- | --- |
| f6, 00:08:42, before any eviction | a 16 MiB demand fetch, then sequential fetches and 9 speculative 16 MiB fetches | 3.3 s |
| f6 again, 00:16:03, after Remove Downloads | 1 MiB demand and sequential fetches, 0.65 s apart, with no read-ahead; each transfer took 6 ms | stopped by the 3 min limit at 292.6 of 307.1 MB |
| f9 again, 00:26:58, after Remove Downloads, with the fix | a 16 MiB demand fetch, 11 sequential and 10 speculative fetches | 3.9 s |

Both f9 reads ran in the same extension process. The first, before its eviction, took 4.9 s.

### Folder completion

- 00:04:22: one letter typed in a new draft's Folder field. The app listed the share root, 8
  folders in 8.6 ms, and suggested 1.
- 00:04:32: that folder and "/" typed. The listing found 2 subfolders in 9.2 ms. More letters
  filtered the same list.
- Clicking a suggestion filled the field, and the draft's Name followed.
- 00:04:43: Down, Down and Return chose a suggestion and added the location (`location_added`).
  Finder's Go to Folder does the same: Return goes to the highlighted path. See
  [Decisions](#decisions).
- When the window opened with a location selected, the Folder field took focus, and the app
  listed the folder's parent once (10.3–23.4 ms). No suggestions showed.

### Text

The STE checker read the 13 new strings, with placeholders filled in, and flagged one word: "now"
in the Storage pane's footer, which became "immediately". On the screen, two more changed: the
EBUSY alert said "If an app uses them" for one file, which is now "it", and the size in the
confirmation broke between "307.1" and "MB", so sizes use a no-break space.

## Defects fixed

- **Slow reads after an eviction.** The read-ahead planner keeps the ranges that it delivered for
  as long as the extension runs. After an eviction of a file that had downloaded through partial
  fetches, every byte still looked delivered: each fetch got the minimum 1 MiB and no read-ahead.
  The system faults only on bytes that it lacks, and its race with a handoff lasted tens of
  milliseconds in M5. So a miss in delivered bytes when no new bytes came for 10 s now starts the
  planner again. This covers Remove Downloads, Finder's Remove Download and the system's own
  evictions. A unit test checks both sides of the 10 s.
- **A stale count in the confirmation.** The pane read the space again only when a location
  changed or a download started or ended, so a keep change after the last read didn't show. Remove
  Downloads… now reads the files again before the confirmation. The pane also reads again when
  the kept files change and when the system posts `NSFileProviderMaterializedSetDidChange`, which
  replaced the download trigger. The notice came for an outside eviction (00:34 above).
- **Text**, as above.

## Decisions

- **Return on a suggestion submits.** For a draft, that is Add. This is the platform's behaviour,
  and Finder's Go to Folder works the same way. The risk: a user who wanted a deeper folder adds
  its parent and must Apply or remove it. A click on a suggestion fills the field without Add.
  Stopping the submit needs a way to tell a chosen suggestion from a typed path; SwiftUI gives
  none.
- **Partly downloaded files are left alone.** They aren't in the materialized set, so the pane
  doesn't count them and Remove Downloads doesn't remove them. `evictUbiquitousItem` removed f8's
  16 MiB. Finding them would mean checking every file of the location.
- **10 s before read-ahead forgets delivered bytes.** A file read again less than 10 s after its
  eviction gets 1 MiB fetches until 10 s pass with no new bytes. That case was not tested.

## Correctness and limits

- Eviction under disk pressure was not tested. Whether macOS then also removes partly downloaded
  files is not known.
- One location, so the total over several locations was not checked.
- The available space changed from 919.5 GB to 964.27 GB between runs, with no action of ours.
- The Finder problem above was seen once; the app does nothing about it.
- Nothing was written on the share.

Checks in the VM: `Tools/run-checks.sh` passed on the final commit: `swift test` ran 140 tests
with 0 failures, the release build and `verify-benchmark.py` passed, the project matched its
generator, and the app build had no Swift warnings. Each earlier commit of the branch also built
and passed its tests.

Cleanup: at 00:35 every download of the location was removed, f8's 16 MiB included, and the holder
process had ended. At 00:37 the location was removed without saving its list
(`location_removed saved_keeps=0`). The app is running with no locations, Open at login is off,
and one SMB mount remains, as at the start.

## Evidence

Private, gitignored, in the VM's `.local/phase2/`:

- `m8-signed-build.log`: the last signed build. `split-<commit>.log`: the checks on each commit.
- Helpers: `m8-relaunch.sh` (fetch a bundle, signed build, relaunch), `m8-measure.py` (each file's
  size, allocated bytes and dataless flag, by index), `m8-read.py`, `m8-hold.py`,
  `m8-evict.swift`, and M7's `m7-log.sh` and `m7-windows.swift`. `m8-folder.txt` and
  `m8-cloud.txt` hold the test folder's paths.
- The STE input is `results/ui-copy-20261011/m8-ste.txt`.

## Next step

M9: exit validation. Test the slow unmount and an unresponsive share there.
