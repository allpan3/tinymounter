# Start Fresh installation on the physical Mac

Date: 2026-11-01 to 2026-11-02. The build from main (Start Fresh, PR #22) is installed in
Applications. Start Fresh removed the earlier location, the user's location was added again
with write access, and the changes that never uploaded are now on the NAS. One edited file was
not restored because the NAS copy was newer.

## Why Start Fresh was needed

The new build reads no earlier settings (no migrations before release). The earlier build could
not remove its location first, because it refuses removal while changes are pending, and three
pending records never finished:

- Two folders created in Finder failed on the server and were throttled permanently by macOS.
  Their six files (17.4 GB) waited behind them and never uploaded.
- One edit of a small JSON file failed with an unresolved upload error on every retry.

Pending changes also blocked NAS change discovery. Settings showed only a count, so the user
could not tell what was pending. Two `.DS_Store` deletions, one folder deletion and one file
moved to the Trash also never reached the NAS.

## What ran

1. The six files and the edited JSON file were copied from the location to a local folder and
   checked byte for byte.
2. The signed Release build was installed with a backup of the earlier app. Startup reported
   the earlier settings as unreadable, as designed, and General offered Start Fresh.
3. Start Fresh removed the domain. macOS kept the seven files that had not uploaded in a dated
   folder in `~/Library/CloudStorage`; paths and sizes matched the local copy.
4. The location was added again: the server address with the share, Use Share for the connected
   share, its root in the open panel, Add, then Confirm Write Access. Read only is off. The
   first listing of the root took a little over two minutes; later listings returned at once.
   The root shows the same three items as the share.
5. The six files were copied to their original paths through SMB. Each SHA-256 matched before
   the copy got its final name, and all six show in the location with the same sizes.
6. The JSON file was not restored: the NAS copy changed about 27 hours after the local edit.
7. With the user's approval, the local copies were deleted.

## Problems found

- **Settings opens out of sight.** Settings… in the menu bar item opened the window on the
  desktop where it was first shown, not the current one, so it seemed not to open. This PR sets
  the window's collection behavior to `moveToActiveSpace`. The change is not yet checked at
  runtime with more than one desktop.
- **Stuck pending changes block removal.** A failed folder creation that macOS throttles
  permanently holds its children and blocks location removal and change discovery, and the
  user cannot see which items are pending. This is not fixed.
- **The earlier build did not quit through an Apple event.** It logged "Failed responder chain
  validation for terminate: action. Canceling termination." and was stopped with SIGTERM. The
  installed build was not checked for this.
- **Unlabeled buttons.** Accessibility reports no names for the location's Add and Cancel
  buttons; only their positions identify them.
- **Python's `shutil.copy2` fails on the SMB share.** The share rejects macOS file flags
  (`chflags`, errno 22); copying the data and setting the times works.

Private evidence is in `results/start-fresh-install-20261101/` on the Mac.
