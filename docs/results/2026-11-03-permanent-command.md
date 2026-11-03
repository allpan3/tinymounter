# Confirmed permanent deletion

Date: 2026-11-03. Status: signed VM command checks pass for ordinary deletion, Cancel,
changed-file refusal and incomplete-deletion recovery. A concurrent-save check exposed a gap:
macOS retained the local revision, but the app refused to retain it for export after its catalog
item was deleted. The repair passes focused unit tests; signed recovery validation is pending.
Normal build gates remain off. Ordinary Finder deletion stays refused because Replace can issue
the same deletion callback before it saves the incoming file.

## Setup and workflow

Tests use macOS VM 1, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), and the separate signed
OfflineCheck app. The disposable server is TinyMounter Samba Test, Linux 7.0.0-31-generic,
Samba 4.19.5-Ubuntu. Two writable locations show the same fresh fixture. No physical-Mac app
installation or original-NAS write is part of these checks. Cache state is mixed; these are
correctness tests, with no performance claim.

The user approved **Delete Permanently…** with confirmation. It accepts one eligible file or
folder, warns that server deletion affects everyone and cannot be undone, and defaults to
Cancel. A separate XPC route keeps ordinary delete callbacks disabled. Both before and after
confirmation, the app checks the selected version and pending system synchronization in every
overlapping view. An unrelated syncing item can therefore also block the command.

The first standalone alert blocked main-actor work. A nonmodal window fixed responsiveness but
had unreliable focus and first-click handling. Build 10 uses AppKit's asynchronous alert sheet.
Return cancels; a single click on Delete Permanently completes the selected file's deletion.

## Signed results

| Check | Observation |
| --- | --- |
| Finder menu and Cancel | Command appears on eligible writable files/folders. Cancel leaves all 15 initial entries unchanged, without an extra Finder error. |
| Connection loss before confirmation | Invalidating the actual XPC connection cancels the prompt. No deletion record is admitted and server contents stay unchanged. |
| Responsiveness | A fixture snapshot completes while confirmation waits. |
| File and populated folder | Confirmed deletion removes one selected file, then a four-node nested tree. Both catalogs complete. |
| Changed file during confirmation | Changing the server contents before confirmation refuses admission; the changed file and neighbors survive exactly. |
| Pending save | A TextEdit save during a Samba outage remains locally complete and in the durable save queue. The command refuses deletion. After credential-assisted remount, the save completes with matching server bytes. Automatic credential reconnection did not pass. |
| Read-only location | The command disappears from the read-only peer's Finder menu. Its original write setting is restored. A snapshot during the transition failed and is not backend enforcement evidence. |
| Finder Replace | Ordinary deletion returns `deletionRejected`. Finder preserves the original under `Replace 2.txt`, with its original identity and bytes, and creates the incoming `Replace.txt`. This observed fallback is not transactional Replace. |
| Refusal wording | Build 9 displays “Deletion could not finish” with guidance to inspect pending changes, instead of an opaque File Provider error code. |
| Keyboard and first click | Build 10 Return cancels. One destructive-button click deletes only the selected file; the other entries remain unchanged except its parent's timestamp. |

## Interrupted deletion and permission loss

A scoped failure stops a three-node folder request after one confirmed child deletion and an
attempting checkpoint for the second. Actual Settings **Stop Deleting** records that child as
unconfirmed and stops the parent. A second fault holds catalog settlement.

Removing traversal permission from the disposable fixture root, then releasing the controls and
clicking Retry, produces `EACCES` (13). The record remains pending with its original outcomes.
Restoring mode 0755 and retrying completes both catalogs. The immutable plan stays unchanged;
the uncertain child is still uncertain. An independent Linux audit finds all 14 surviving entries
unchanged, including identities, bytes, ownership, modes, times and xattrs. Dismissing the notice
does not claim another deletion.

Earlier build 8 attempts refused before admission; their cause was not established. The same
selection admits after the build 9 restart. Those attempts are not permission-loss evidence.
One snapshot during restored settlement reports failure; the subsequent stable snapshot and
independent backing audit establish the final state. All scoped fault controls are archived and
the fixture's permissions are restored.

## Save arriving after admission

With a verified file open in TextEdit, a test hold pauses after durable deletion admission.
TextEdit saves a new 67-byte revision; a separate read verifies it before the hold is released.
Deletion completes, and macOS retains the new revision as not uploaded. The app repeatedly
refuses the save because its catalog item is now a tombstone, so no app recovery record exists.

The repair separates local retention from permission to publish. Matching writable file bindings
can supply their former path for local staging even when the file or its parents were deleted.
Publication still rejects deleted bindings, including when another object appears at that path.
The existing export workflow can recover those bytes without recreating the deleted server file.
Three focused package tests pass, covering retention, export, replacement protection and binding
checks. Signed validation of this repair is pending.

## Evidence and remaining checks

Raw VM evidence is in `results/permanent-20261103/` under run
`820D3EFE-EF14-4333-898D-8EA94C00B55C`. Linux audits are in the matching
`/tmp/tinymounter-permanent-` run directory. Relevant labels include `check-command-*`,
`check-editor-state-queue-*`, `check-permission-{interrupted,stopped,denied,restored}9`,
`check-command-permission-final9`, and `check-editor-state-race-*10`.
The failed build 9 keyboard check is retained as `check-command-return-cancel9`; that snapshot
only records state and does not itself prove cancellation.

`Tools/run-checks.sh` passes for build 10: 650 tests, two optional skips, no failures or Swift
warnings, Release CLI verification, unsigned app build and protocol encoder checks. The earlier
command and nonmodal-window implementations also passed their required checks. Logs are in
`results/folder-single-20261103/`, including `checks-permanent-sheet.log`. Final checks after
the save-retention repair remain. Wider editor/lifecycle compatibility and physical-Mac behavior
are unverified. This work does not complete the full deletion or beta acceptance gates.
