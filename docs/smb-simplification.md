# Simpler SMB operations

Date: 2026-11-04. Decision status: accepted. Implementation and VM validation are in progress.

TinyMounter follows ordinary SMB file-operation semantics. The user explicitly replaced the
earlier custom recovery requirement and delegated implementation of this audit. NAS snapshots
and backups own previous-version recovery. This decision supersedes the stronger save,
conflict-preservation and replacement guarantees in the earlier milestone plans.

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
- Keep scoped access, path containment, account separation, server permissions, accurate errors,
  cancellation and complete-range checks. These remain correctness requirements.

File Provider is a local synchronization interface. It cannot reproduce a live SMB descriptor's
locking semantics, and queued offline saves have no exact native-mount equivalent. Do not claim
equivalence beyond the ordinary operations tested. Optional fail-on-conflict requests must be
honored if received; stop advertising that optional feature for the last-writer-wins design.

## Implementation order and evidence

1. Remove custom save transactions, edit receipts, read proofs and their recovery interface.
2. Remove content hashing from organization/deletion and narrow coordination around transfers.
3. Measure the remaining transport costs; change request sizing or connection handling only
   where the implementation and measurements justify it.
4. Run required VM checks and signed workflows, then compare saves and reads with the VM's
   native SMB control. Record setup, cache state, samples and unverified cases in a results log.

The earlier 64 MiB save experiment measured 6.357 s for the rechecked transaction and 0.347 s
for native overwrite plus fsync (medians, five alternating pairs, warmed unverified caches,
2026-11-04). The transaction timing excluded connection and local preparation and omitted the
app's final readback. It is evidence of redundant work, not an editor-latency measurement.
See [save recheck](results/2026-11-04-save-recheck.md).

Use fresh test state. Preserve the older VM application's pending fixtures. This task does not
authorize publication or installation of the new architecture on the physical Mac.
