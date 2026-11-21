# Simpler SMB operations

Decision status: accepted and implemented. Read-performance targets remain unmet.

TinyMounter follows ordinary SMB file-operation semantics. This replaces the earlier custom
recovery requirement. NAS snapshots and backups own previous-version recovery. This decision supersedes the stronger save,
conflict-preservation and replacement guarantees of the earlier designs, which Git history keeps.

## Contract

- Saving writes the current contents to the remote file, sets its length, flushes and closes it.
  A competing edit can be overwritten. An interrupted write can leave partial remote contents.
  TinyMounter does not make remote backups, recovery names or conflict copies.
- File Provider owns pending local contents until an upload completes. Return success only
  after the server accepts the operation. Return failures to macOS for pending status and retry.
  Prove offline, interruption and restart behavior in a separate signed VM test installation.
- Reads transfer the requested bytes once. Metadata checks detect observed version changes;
  TinyMounter does not hash whole files or retain block proofs to defend against other writers.
- Rename, move and deletion use server operations and metadata. Preserve stable File Provider
  identities and correct directory reconciliation without reading file contents.
- Keep the Read only setting, path containment, account separation, server permissions, accurate errors,
  cancellation and complete-range checks. These remain correctness requirements.

File Provider is a local synchronization interface. It cannot reproduce a live SMB descriptor's
locking semantics, and queued offline saves have no exact native-mount equivalent. Do not claim
equivalence beyond the ordinary operations tested. Optional fail-on-conflict requests must be
honored if received; stop advertising that optional feature for the last-writer-wins design.

The client serializes only libsmb2 context creation/destruction, whose context list is global.
Each connection owns its requests and credentials; unrelated payload I/O can run concurrently.
Each wire read or write is capped at 1 MiB and the server maximum. A download can have four
reads outstanding on its connection, subject to the total available SMB credits.

No operation looks up the location folder through a native path: there is no mount. Transport resets
are classified as connection failures and returned as retryable provider errors.

## Audit decisions

| Area | Change or retained requirement |
| --- | --- |
| Existing-file saves | Removed remote stage/backup/work files, original rechecks, conflict copies, edit outbox and recovery UI. One ordinary overwrite completes after size, flush and close. |
| Reads | Removed whole-file and block proofs. Requested bytes are transferred once; metadata, exact range and cancellation checks remain. |
| Transport | Removed the connection-lifetime global mutex and unused recovery APIs. Context-list mutations alone are serialized. Requests use up to 1 MiB within server/credit limits. |
| Error/retry | Broken transport returns a retryable connection error. Removed redundant native location-folder opens from direct mutations. |
| New uploads | Removed one redundant local hash pass and the duplicate pre-write metadata query. Retained exclusive creation, identity records and local payload integrity so an ambiguous retry cannot replace an unrelated file. |
| File organization | Removed payload hashing. Retained short operation records and multi-catalog settlement to preserve item IDs, keeps and callback replay. |
| Folder organization | Still inspects descendant metadata and can scale with the cataloged subtree. A root-only rename with lazy reconciliation would need a different identity/overlapping-view settlement design; deleting these checks alone would make cached identities unreliable. No constant-time claim. |
| Permanent deletion | Retained bounded traversal, admitted identities, cancellation and per-item settlement. Partial tree deletion is reported accurately. No custom Trash or retained remote payload. |
| Scheduling | Independent SMB connections can run concurrently. The per-share mutation lane still orders saves/creates with namespace and lifecycle changes; removing it needs operation-specific admission/drain work. No blind switch to unbounded concurrent writers. |
| Local storage/lifecycle | File Provider retains failed edits. New-item outbox bytes and the staging reserve remain; removal preserves dirty user data. No migration of older prototype save transactions. |

Ordinary Finder deletion, file and folder Replace and combined rename/content saves are
enabled. Broader document metadata remains unsupported.
This audit changes save semantics;
it does not claim native descriptor locking or complete native-SMB feature parity.

