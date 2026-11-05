# Write confirmation and save races, 2026-11-04

The write-access picker now asks only for access to the selected share. The user rejected an
SMB-only eligibility warning, including a shortened version with optional details: it asks
users to reason about an internal concurrency constraint and does not help them grant access.
No write authorization, transaction or storage behavior changed. The merged UI update is installed
on the physical Mac; the README records its installation checks.

## Focused investigation

`EditTransaction.publish` checks the base, verifies a backup, moves the original to its work
name, copies the staged contents into that object and verifies the result. `SMBEdit.update`
uses the protected handles but has no conditional content update against a direct NAS writer.

Two temporary package-level probes injected another version into the existing fake remote:

- Immediately before the copy: publication completed, and the intervening version was absent
  from the final file, stage and backup. Final verification cannot detect bytes already overwritten.
- Immediately after the copy: verification refused completion, retained the competing work
  version and local save, and Retry did not repeat the overwrite.

Both probes passed their expected-outcome assertions. They characterize a gap, not a fix.
They ran on the Mac without building an app or accessing a NAS. The earlier protocol probe
already established that direct backing-filesystem writes can bypass SMB protection; this
model experiment does not add a new real-server compatibility claim. Probe source and output
are retained locally in `results/write-confirmation-20261104/direct-writer-probe.*`.

## Disposable-server follow-up

The real transaction loses competing contents written before or during its copy. Refusing
completion afterward does not recover those bytes. A fresh check before mutation caught the
pre-copy change, but it did not resolve the pending save or protect the subsequent copy.

On 2026-11-04, an unsigned CLI in macOS VM 1 used the merged `EditTransaction`, `EditOutbox`
and `SMBEdit` with the production SMB library. Only the test copy of `SMBEdit` gained a pause
after its first 1 MiB copy chunk. A wrapper paused after backup verification or after copying.
Its ShareAccess shim runs the call directly, matching the production path without an active
health-monitor activity. No app or production source changed.

The server was the existing disposable Linux VM, Samba 4.19.5, on its `tinymounter-single`
share. A new task-owned directory held 2 MiB ordinary files. The original, local edit and
competing version used distinct repeated bytes. A process running as the fixture account held
an original file descriptor from before the SMB transaction, wrote the complete competing
version through it and called fsync. Caches were uncontrolled; this was not a performance test.
The original NAS was not accessed.

| Write point | Surviving contents | Transaction and Retry |
| --- | --- | --- |
| No competing writer | Original contains the edit; backup contains the base | Published; Retry adds no write |
| After verified backup, before mutation | Work contains the edit; competing version is absent | Pending in copying; Retry adds no write |
| After the first copy chunk | Work contains 1 MiB of the competing version and 1 MiB of the edit | Pending in copying; Retry adds no write |
| After the complete copy | Work contains the complete competing version | Pending in copying; Retry adds no write |
| Before mutation, with an experimental fresh check | Original contains the complete competing version; no work file | Refused before rename or copy; Retry stays pending |

Every case retained the complete local edit, remote stage and original-content backup.
Fresh SMB sessions and independent backing-filesystem reads agreed on the surviving bytes.
The direct writer's inode matched the work object's SMB file ID across rename. In the
pre-copy case, Samba also changed the reported creation timestamp, so the full identity no
longer matched and publication refused. Unlike the earlier model probe, this run did not
acknowledge success. The competing bytes were still lost. The no-writer control published
successfully with the same file creation method.

The experimental check compares fresh contents with the backup before the first rename.
It changes only the probe wrapper and deliberately does not supply product recovery. These
are transaction/transport observations, not signed editor or File Provider acceptance.

## Follow-up implementation

The user approved the [fresh check and conflict recovery](2026-11-04-save-recheck.md) on
2026-11-04. It rechecks after staging and after backup verification, with failOnConflict and Retry
coverage. Signed VM verification passes. This narrows the race; it cannot exclude a direct write
that starts after the check or preserve every version written during copying.

Closing that remaining window needs an update that excludes the competing write or preserves
the object it writes. Any alternative must retain the original's permissions and unrelated
streams; the rejected replacement route cannot simply be restored. No new retention policy,
server component or save architecture is approved by the warning removal.

Raw probe sources, state records, logs and archived synthetic contents are retained in
`results/direct-writer-20261104/`. The writer exited, and the task-owned live fixture was removed
after archive and byte verification. Existing VM locations and fixtures were preserved.

## UI verification

The final signed VM build shows the share selector and confirmation controls with no warning
or details accessory. Cancel closed the picker without granting access; the temporary duplicate
draft was then cancelled. No location was added or fixture content changed.
`Tools/run-checks.sh` passed: 663 tests, two optional skips, no failures or Swift warnings.
The [before](../media/write-confirmation/before.gif) and
[after](../media/write-confirmation/after.gif) recordings use the same steps: duplicate the
disposable Writable location, click Add, then cancel the picker and draft. They sample real
frames at their capture times. Raw screenshots and logs are in
`results/write-confirmation-20261104/`.
