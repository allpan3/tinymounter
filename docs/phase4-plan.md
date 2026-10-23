# Phase 4: write support

Date: 2026-10-23. Decision status: proposed. M18 starts phase 4 of
[architecture §10](architecture.md#10-implementation-sequence-and-exit-criteria) with new files
and folders, then adds editing and conflict handling in later milestones. The remaining phase 3
checks are still open; starting this design does not mark them passed.

## First milestone: create files and folders

M18 lets the user create a folder or copy a new file into a File Provider location in Finder.
Existing locations stay read-only. The user must explicitly enable changes for a location and
select its share again to grant write access. Passwords still belong to macOS and Keychain.
The first implementation and all destructive checks use disposable VM data, not the user's NAS.

Limit the first milestone to creating ordinary files and folders. Replacing or editing existing
files, renaming, moving and deleting come later. A name collision fails without changing the
existing item. Do not make an editor's save look successful when it requires an operation that
this milestone does not support.

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

For a file, upload to a unique temporary sibling and publish the complete file with an operation
that atomically refuses an existing destination. First prove that the supported macOS SMB path
provides that behavior. A separate existence check followed by ordinary rename is insufficient.
If the server cannot provide it, fail safely; do not expose a partial file under its final name.
Use exclusive creation for folders and handle parent creation before dependent child operations.

A timeout after publication can leave the result uncertain. Reconcile using tested remote
identity evidence and complete content checks before marking the operation uploaded. If the
result cannot be proven, retain the pending copy and show the problem. Never guess success,
overwrite an unrelated file or retry under a new name without a user decision.

## Checks before claiming M18 works

Use a dedicated writable SMB fixture in macOS VM 1. Temporarily enable only that test share,
snapshot its settings, and restore them after removing all test data. The original NAS remains
read-only. Do not restart the VM, cut its network or stop shared system services.

Verify a new file and folder in the signed sandboxed app, then compare the complete local and
remote file contents. Test same-name collisions, read-only locations and denied grants. Interrupt
the test app during staging, before publication and after remote commit but before acknowledgement.
The resumed operation must finish once or remain clearly pending, with no data loss, partial
final file or overwrite. Test removal/source-change refusal with pending writes and migration
from the installed settings/catalog formats. Record matched before/after Finder actions.

Run Tools/run-checks.sh in the VM, update affected reference docs, and finish with a dated result
and README status. A physical-Mac install, publication and real-NAS write tests need separate
approval. This proposal does not authorize them.
