# Write confirmation and save races, 2026-11-04

The write-access picker now asks only for access to the selected share. The user rejected an
SMB-only eligibility warning, including a shortened version with optional details: it asks
users to reason about an internal concurrency constraint and does not help them grant access.
No write authorization, transaction or storage behavior changed. The UI change is not installed
on the physical Mac.

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

## Next bounded step

Use a disposable VM file and a direct writer with an already-open handle. Inject writes after
backup verification, during the copy and after the copy. Compare every surviving version and
recovery state. Test a fresh base check immediately before mutation as a way to catch changes
since backup; it narrows the window but cannot protect the subsequent copy by itself.

Closing the remaining window needs evidence for an update that either excludes the competing
write or preserves the object it writes. Any alternative must retain the original's permissions
and unrelated streams; the rejected replacement route cannot simply be restored. No new
retention policy, server component or save architecture is implemented by this UI change.

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
