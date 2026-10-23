# Phase 4: write support

Date: 2026-10-23. Decision status: accepted. M18 starts phase 4 of
[architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria) with new files
and folders, then adds editing and conflict handling in later milestones. The remaining phase 3
checks are still open; starting this design does not mark them passed.

Native upload decision, 2026-10-23: the user accepted exclusive creation through native SMB.
Other devices can see a new file while it uploads, including a partial file after interruption.
Keep the complete local pending copy until remote completion is verified. Existing destinations
must remain untouched. The [API checks](results/2026-10-23-upload-publication.md) explain why
exclusive creation replaces the earlier temporary-sibling publication design.

## First milestone: create files and folders

M18 lets the user create a folder or copy a new file into a File Provider location in Finder.
Existing locations stay read-only. The user must explicitly enable changes for a location and
select its share again to grant write access. Passwords still belong to macOS and Keychain.
The first implementation and all destructive checks use disposable VM data, not the user's NAS.

Limit the first milestone to creating ordinary files and folders, including the initial naming
step after Finder creates an untitled folder. The user accepted that extension on 2026-10-23.
Replacing or editing existing files, general renaming, moving and deleting come later. A name
collision fails without changing the existing item. Do not make an editor's save look successful
when it requires an operation that this milestone does not support.

The visible behavior is:

- Finder can create a folder and copy a new file into the enabled location.
- A file is not reported as uploaded until the server has accepted the complete file.
- An interruption keeps the user's pending data locally. Reopening the app resumes or reports
  the unresolved operation without silently making another copy.
- A location with pending writes cannot be removed or have its source changed. Its data and
  configuration remain available until the writes finish or a later explicit recovery action
  resolves them.
- Read-only locations keep their present behavior, IDs, keep requests and downloads.

## Implementation boundaries

The main app continues to own SMB access and catalog writes. The extension requests mutations
through restricted IPC, and the app checks the location's write permission on every request.
Use Apple's user-selected read-write entitlement and a fresh scoped grant for the approved
location. Keep the sandbox enabled and the extension's permissions limited. A read-only grant
must never be silently upgraded.

Save pending bytes and operation state durably before acknowledging a change that still needs
uploading. Keep an app-owned immutable copy under the supported File Provider URL-lifetime
rules. Persist only the operation state needed for restart and commit recovery. Any settings
or catalog change needs migration from the installed format and tests that preserve user state.
No new format version field or dependency is justified merely to track this work.

For a file, create its final name exclusively with `O_CREAT | O_EXCL`. Never open an existing
remote file for writing. Other devices may see incomplete new content until upload completes.
An interruption preserves the complete local pending copy. After an ambiguous attempt, prove
remote ownership and complete content before acknowledging success; otherwise retain the copy
and report the unresolved operation. Do not retry under another name. Use exclusive folder
creation and handle parent creation before dependent child operations.

A timeout after publication can leave the result uncertain. Reconcile using tested remote
identity evidence and complete content checks before marking the operation uploaded. If the
result cannot be proven, retain the pending copy and show the problem. Never guess success,
overwrite an unrelated file or retry under a new name without a user decision.

## Checks before claiming M18 works

Use a dedicated writable SMB fixture in macOS VM 1. Temporarily enable only that test share,
snapshot its settings, and restore them after removing all test data. The original NAS remains
read-only. Do not restart the VM, cut its network or stop shared system services.
The user separately approved one File Provider daemon restart for the stale-state diagnostic
on 2026-10-23. That restart is complete; it does not authorize other service restarts.

Verify a new file and folder in the signed sandboxed app, then compare the complete local and
remote file contents. Test same-name collisions, read-only locations and denied grants. Interrupt
the test app during staging, before publication and after remote commit but before acknowledgement.
The resumed operation must finish once or remain clearly pending, with no data loss, overwrite or loss of the complete local pending copy. Test removal/source-change refusal with pending writes and migration
from the installed settings/catalog formats. Record matched before/after Finder actions.

Run Tools/run-checks.sh in the VM, update affected reference docs, and finish with a dated result
and README status. A physical-Mac install, publication and real-NAS write tests need separate
approval. This approval does not authorize them.

## Implementation status, 2026-10-23

Creation, explicit write grants, migrations and durable pending copies are implemented. All 208
VM tests and required checks passed. Signed extension callbacks through authenticated IPC passed
file/folder creation, and signed app stops checked recovery and pending-write lifecycle guards.
After the approved daemon restart, normal Finder file and nested-folder uploads passed with
matching hashes and native progress. New Folder naming and Keep Both still fail, so M18 has not
met its exit checks. The physical-Mac app remains M16. See the
[results](results/2026-10-23-create-items.md).

Initial folder naming, decision status: accepted, 2026-10-23. The user approved handling the
initial name of a newly created folder. General renaming remains a later milestone. Native
exclusive folder rename failed, and a create/delete alternative deleted another client's
replacement folder in a controlled race. Neither route is suitable. An isolated direct SMB
client passed collision and competing-create checks. The authentication follow-up below resolved
the credential-probe defect. No production naming callback has been added. See the
[naming investigation](results/2026-10-23-initial-folder-naming.md).

Next step, decision status: accepted, 2026-10-23. After the dependency explanation, the user
asked to continue the fix. Prototype `libsmb2` for initial folder naming only, keeping native
reads and uploads. The corrected credential probe and a signed sandboxed connection passed
without password acquisition. The [authentication follow-up](results/2026-10-23-folder-naming-authentication.md)
records the earlier probe defect and the LGPL-2.1-or-later obligations. Preserve the macOS-managed password contract.
Repeat credential checks with the final client. Source identity checks, durable rename recovery
and signed Finder behavior must pass before installation. Keep Both's separate error remains unresolved.
