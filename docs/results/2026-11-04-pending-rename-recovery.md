# Pending rename recovery, 2026-11-04

Settings now lists changes that macOS holds without an app transaction. A refused stale-base
rename or move shows its reason, the last known server path and Show in Finder. Restoring that
name and parent in Finder clears the system entry. Retry retains the stale-base safety check.
Signed VM checks pass for folder renaming, moving, app restart and subsequent permanent deletion.
The user subsequently approved Mac installation; the dated README status records that outcome.

## Cause and change

The app can refuse organization before creating a rename intent. macOS then permanently
throttles the callback with `cannotSynchronize`. Settings previously listed only app records,
while the deletion preflight also checked the system pending set. The hidden item could
therefore block Delete Permanently… without a visible explanation.

Settings now enumerates that same public pending set independently of the existing transaction
list. It reports incomplete enumeration and lookup failures explicitly. The system list and
the app count overlap; they are not added together.

The system supplied the server name, not the pending local name, in the measured callbacks.
Comparing that name with the catalog cannot identify a refused rename. Instead, organization
callbacks attach a fixed, path-free reason to stale-base errors. The provider preserves this
recognized detail while continuing to strip arbitrary error information. macOS retains it in
the pending entry. Older generic errors get the reason on Retry. No app record format changes.

Settings derives the restore path from the live catalog. It withholds undo guidance for missing
or retired bindings and while the location has an unresolved rename transaction. Show in Finder
resolves the item through File Provider, so it selects the actual local name. Undo uses the
existing no-op callback when name and parent already equal the catalog. No server mutation,
forced discard, silent rebase or fabricated remote completion is added.

## Signed VM checks

Setup: macOS VM 1, macOS 27.0.1, signed `dev.tinymounter.offlinecheck`, and the agent-owned
Linux Samba fixture. The test used a new `RenameRecovery` subtree in the existing probe location.
Cache state was uncontrolled. These are correctness checks, not performance measurements.

To reproduce reliably, pause only this test identity's extension processes, rename or move the
local folder, add a child through the independent native SMB mount, wait for app reconciliation,
then resume those processes. The app rejects the callback with `versionChanged`. The server
keeps the original path, while macOS marks the local change permanently throttled. Two earlier
unpaused trials completed normally and are not refusal evidence.

| Check | Result |
| --- | --- |
| Baseline Settings | The old deletion notice appears; the refused rename does not |
| Candidate Settings | The pending row shows the refusal, last known server path and Finder recovery instructions |
| Retry | The stale request is refused again; all nine original server files retain their bytes and inodes |
| Show in Finder and rename undo | Finder selects the locally renamed folder; restoring its original name produces `rename_unchanged` and removes the system row |
| Move plus rename refusal | The server keeps the source folder; the local destination remains pending |
| Quit and relaunch | The specific error remains in macOS while the app is closed; Settings shows it after relaunch |
| Finder move undo | Move Here restores the parent, then restoring the name completes the no-op callback and clears the row |
| Independent backing audit | All nine original files retain their bytes and inodes; only the deliberately added fifth test child differs |
| Delete Permanently… after recovery | The task-created empty destination is deleted through the confirmed command; one node, two views, no unconfirmed result |

Five focused regressions cover file and folder restore paths, server metadata in the pending
set, missing/retired bindings, unresolved transactions, content-only errors and read-only catalog
projection. The final required `Tools/run-checks.sh` run after the error-detail repair and
diagnostic removal passed 663 tests with two optional skips, no failures and no Swift warnings.
The final signed build also launched and showed the recovered location without a system pending
rename or a status lookup warning. The earlier deletion notice remained visible. A final Linux
audit confirmed that all nine original files were unchanged and the test destination was absent.

Evidence is in `results/rename-recovery-20261104/` in the VM checkout and this worktree.
It includes before/after screenshots, build/check logs, refusal and undo logs, and private
File Provider dumps. Linux backing audits are retained under `/tmp/tinymounter-*-recovery-*.json`.
The later PR comparison records the same steps in each signed build: start at the selected
location, scroll to Access, select Retry Pending Changes and observe the result. These sampled
screen recordings are cropped to Settings and show only the disposable fixture:
[before](../media/pending-rename-recovery/before.gif) and
[after](../media/pending-rename-recovery/after.gif). The earlier still screenshots also show
Show in Finder and completed undo. The PR demo added one more disposable child to reproduce
the refusal; it did not change the nine original files.
Raw dumps are private and must be sanitized before sharing. Earlier fixture recovery records
remain intact. These VM checks changed no NAS settings or physical-Mac private data.

## Next save work

The existing TXT/RTF, PDF/PNG and source-file Save/Save As results still stand. No new editor
combination was observed in this task, so no save behavior was added.

- Observe a supported editor renaming a dirty document before implementing combined
  name/content callbacks. The current refusal remains.
- Establish an edit-base design for saves after plain POSIX reads. Those saves still preserve
  the original and publish a conflict copy.
- Specify incoming metadata synchronization from real callback evidence. Retained export
  metadata is not general remote metadata support.
- Finder Replace remains blocked on a supported intent/base binding. Ordinary Finder deletion
  stays refused. Physical-Mac daily-use acceptance and release preparation remain separate work.
