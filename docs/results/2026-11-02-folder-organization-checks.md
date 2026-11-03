# Folder organization: first signed VM checks

Date: 2026-11-02. A signed VM build with folder organization enabled delivers folder renames
and moves through the working set, as the [M21 plan](../phase4-plan.md) now requires. The check
of accented names found a wider problem than folder moves. The app reads names through the
kernel SMB mount, which shows them decomposed (NFD). Macs store them precomposed (NFC) on the
server. The app's own SMB client sends the NFD spelling back to the server. On a server that
compares names byte for byte, as a typical NAS filesystem does, this would break protected
reads and writes of items with accented names. The fixture finds both spellings, so it cannot
show this. Folder organization stays disabled.

## Setup

The app ran in macOS VM 1 under a separate test identity (`dev.tinymounter.orgcheck`), signed
with the installed app's Apple Development certificate. It was built from `everyday-batch-1`
at the commit that adds the working-set check, with `folderOrganizationEnabled` set to true in
a copy of the source. One writable location used the loopback Samba fixture share
`tinymounter-m19-edit-test`, folder `probe-org-20261102`. Its backing store is APFS, which
finds a name in either spelling.

Finder operations used Finder scripting (`set name`, `move`), except the move back to `Inbox`,
which used Copy and Move Item Here (⌥⌘V). Every SMB connection on this fixture takes about
20 s, because the VM cannot resolve its own host name. Each callback below includes one or two
such connections.

## Results

| Check | Result |
| --- | --- |
| Rename `Tree`, move it to `Archive`, move it back, case-only rename | Each action produced one `folder_move ok=true` and one working-set batch that covered the folder and its 6 known descendants, with `deleted=0`. No create or delete callbacks. All 21 replica item IDs, inodes and SHA-256 digests stayed the same, and the never-downloaded file stayed dataless. The server renamed in place (same inodes). Finder relaunch and `ls` agreed. |
| Rename `Résumé.txt` stored NFC and NFD; rename an ASCII file inside each `Café` folder | All succeeded on the fixture, only because the server finds the NFD spelling. |
| Move the NFC-stored `Café` folder | Refused with `versionChanged`: the root name check compares bytes (`LocationFolderMoves.swift`, `SMBEdit.captureFolderMoveProofs`). The server did not change. |
| Rename the NFD-stored `Café` to `Café renamed` | Succeeded. The server stores the new name in NFD. |
| The refused folder in Finder | Finder kept it displaced in `Archive` with `isUploading=1` and error -2005. The system made no retry in 21 minutes. Moving it back in Finder succeeded at once and cleared the error. |
| Rename a never-downloaded 1 GiB file | 36 s: one connection (20 s) and one full read of the file for its digest (15 s). Reads of other files in the share waited 37 s. |
| Move a folder holding 2 × 1 GiB | 56 s: two connections and about 16 s of other work. Reads of other files waited about 54 s. |

`netstat -I lo0` counted almost none of the SMB traffic, so the byte counts were not usable.
The 4 GiB cases were not run, to keep the VM disk below its 150 GB limit.

## Accented names

The macOS SMB client converts names to NFC on the wire when it creates them. A file created
through the kernel mount with an NFD name was stored as NFC. The client shows every name as
NFD. The catalog therefore holds NFD names, and the app's own SMB client (libsmb2) sends those
bytes unchanged.

On a server that compares names byte for byte, code reading shows these results for an item
whose name, or an ancestor's name, is stored as NFC:

- **Downloads on a writable location fail.** A download that establishes an edit base opens
  each ancestor and the file through libsmb2 (`protectedTransfer`, `SMBEdit.protectAncestors`).
  The server answers that the name is not found, and Finder reports a missing file.
- **Saves of a file with an accented name make a conflict copy.** The save cannot find the
  original, treats it as gone, and publishes the contents as a new file next to it. That copy has
  an NFD name. The original is not changed.
- **Uploads into an accented folder** reach the right folder through the kernel mount. The
  edit base that follows cannot open the file, so the record stays pending and blocks Remove
  Location.
- **Folder moves, file moves into accented folders, new folders and deletions refuse** before
  any server change.

No path was found that changes the wrong object. These results come from code reading and from
the observed client behavior. They have not been observed on a byte-exact server: macOS file
systems (APFS and exFAT were tried) find both spellings, so a byte-exact fixture needs a
non-macOS server, such as Samba on ext4.

The installed app on the physical Mac logged no download failures in the 5 days before this
check.

## Not run

Stale saves after a move, real crashes at each recovery step, Keep and Settings restoration, and
outside changes after the server rename need a build with crash and stop points. They were not
run, because a fix for accented names would change the code those checks cover.

## Evidence

In VM 1 under `.local/phase4/org-checks-20261102`: replica and backing audits `replica-NN.json`
and `backing-NN.json` with the helpers `audit.py`, `compare.py` and `step.sh`, and the cost probe
output `cost-*.txt`. The app log stream is on the host in
`results/org-checks-20261102/app-log-02.txt`.
