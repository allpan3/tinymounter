# Save recheck, 2026-11-04

The user approved the fresh check with existing conflict-copy recovery. The transaction now
rechecks the original after uploading the local save and after verifying the backup, before
renaming or copying into the original. Detected changes preserve the original and publish the
local save as a conflict copy. A caller that sets failOnConflict receives the existing conflict
error and retains its local save instead.

A recorded conflict decision survives Retry, even if the original returns to its earlier bytes.
Retry can also verify a complete backup after a lost response and finish the conflict copy.
Cleanup removes only the verified private backup; it never removes the competing original.
Persistent formats, write grants and the conflict-copy naming policy are unchanged.

## Verification

Focused transaction regressions cover changes during staging and after backup, failed fresh
reads, lost backup and conflict replies, persisted conflict decisions, failOnConflict, missing
originals, changed or partial backups, and metadata-only changes. All 81 focused transaction
tests pass. The required VM checks pass with 674 tests, two optional skips, no failures and no
Swift warnings. Physical-Mac installation status is tracked in the [README](../../README.md).

Signed TextEdit checks ran on 2026-11-04 in macOS VM 1, macOS 27.0.1, against the existing
disposable Samba 4.19.5 VM. The fixture used small plain-text files with distinct original,
local-save and competing contents. Caches were uncontrolled; these were correctness checks.
Test-only copies paused the app after persisting the staged or backed-up state. A direct
server writer changed the original in place and called fsync before the app continued.

- After staging and after verified backup, the candidate preserved the complete competing
  original with its inode unchanged and published one complete local-save conflict copy.
- Killing the app after backup, changing the original and relaunching also published one
  conflict copy. Subsequent app restarts and Retry did not duplicate these copies.
- The final signed build without pause hooks completed ordinary and repeated TextEdit saves
  to a published conflict file. Independent server reads matched both saved revisions.

The first baseline attempt exceeded the existing request timeout while paused. It stopped
before mutation and remains pending with the competing original, stage and backup retained.
It is excluded from the comparison. The matching recordings below use a separate transaction
CLI fixture; they do not show a signed editor session. The disposable fixture and its recovery
data remain for inspection. The VM now runs the final build without test hooks; existing
locations and unrelated pending changes were preserved.

## Before/after demonstration

[Before recording](../media/save-recheck/before.gif) ·
[After recording](../media/save-recheck/after.gif)

Both recordings show native Finder viewing the disposable server folder. The CLI uses the
production transaction and SMB adapter, with a test pause after copying the backup. The only
production-source difference between the two programs is this transaction change. Each run
starts with the same original contents, stages the same local edit, pauses, receives the same
direct server write with fsync, continues, reopens the transaction and retries. The recordings
retain capture timing and crop out unrelated windows; pauses are test controls, not save latency.

Before the fix, the transaction overwrote the competing bytes, left the original under its work
name and remained pending in copying. Retry did not recover the competing version. After the
fix, the original retained the competing contents and its inode, one conflict copy held the local
edit, and verified private artifacts were removed. Retry created no duplicate. Independent Linux
reads checked every surviving file's contents. Signed editor acceptance is recorded separately above.

## Save timing

On 2026-11-04, five alternating-order before/after pairs at each size measured normal save
publication, completion and cleanup through the production transaction and SMB adapter. Optimized
Swift CLI builds differed only in the transaction source. Connection setup, base establishment
and local staging preparation preceded timing; File Provider and editor dispatch were excluded.
Each pair was followed by native SMB overwrite plus fsync as a local control. That control has
no backup or conflict recovery and is not an equivalent save implementation.

The client was macOS VM 1, macOS 27.0.1 (26A434), nine virtual CPUs and 8 GiB RAM. The server
was the disposable Samba 4.19.5 Ubuntu VM, kernel 7.0.0-31, two virtual CPUs, about 4 GB RAM and
ext4 storage. Traffic used the same host's virtual network. Both TinyMounter programs required
signing and encryption. The native mount negotiated SMB 3.1.1 with AES-128-GCM encryption and
AES-128-GMAC signing; its compression counters stayed zero. The direct client's negotiated
cipher was not captured, so native/direct cipher parity is unverified.

Setup fully read each original and prepared local input before timing, warming server and local
caches. Cache residency was not measured or flushed. There was no provider materialization and
no build during the series. All 30 final files passed independent server-side digest verification;
completed saves left no private artifacts.

| File size | Before median (range), s | After median (range), s | Added median time | Native control median (range), s |
| --- | ---: | ---: | ---: | ---: |
| 1 MiB | 0.274 (0.268–0.322) | 0.289 (0.211–0.329) | 0.014 s | 0.095 (0.092–0.101) |
| 64 MiB | 5.397 (5.252–5.500) | 6.357 (4.755–6.946) | 0.961 s, 17.8% | 0.347 (0.336–0.352) |

The small-file difference falls within the observed variation. The 64 MiB median increased by
about a second, with a wide after range. These are VM transaction measurements with warmed,
unverified caches, not physical-NAS performance or editor Save latency.

Individual samples in round order, seconds:

| File size | Before | After | Native control |
| --- | --- | --- | --- |
| 1 MiB | 0.267534, 0.273573, 0.280885, 0.321703, 0.274215 | 0.210756, 0.257734, 0.299390, 0.328974, 0.288671 | 0.092355, 0.101384, 0.095473, 0.096926, 0.093536 |
| 64 MiB | 5.440499, 5.396533, 5.499607, 5.277434, 5.252125 | 5.680985, 6.357094, 6.945814, 6.851796, 4.755049 | 0.335564, 0.350577, 0.351873, 0.339195, 0.346737 |

Raw build logs, runtime traces and synthetic fixture evidence are in the VM's
`results/save-recheck-20261104/`. Resumed host-side artifacts are in
`results/save-recheck-resume-20261104/`. Timing sources, build logs and samples are in the VM's
`results/save-timing-20261104/`; demo sources and transaction records are in
`results/save-demo-cli-20261104/`. Host recordings and timing summaries are in
`results/save-recheck-review-20261104/`. The server audits are
`/tmp/save-timing-audit-20261104.json` and `/tmp/save-demo-audit-20261104.json` in the Samba VM.

## Limits

The extra checks read the full original twice more during a normal save; their measured cost is
above. A direct writer can still change the file after the final check or during the copy;
this narrows the known race without resolving it. Missing originals and incomplete or changed
backup artifacts keep their existing pending recovery behavior.
