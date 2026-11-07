# Finder folder Replace

Date: 2026-11-06. The user selected Folder Replace as the next feature. Signed VM checks
passed for ordinary folders, including automatic retry after a stalled SMB directory watcher.
This change is not installed on the physical Mac or included in the published 0.1.1 DMG.

## Behavior and fix

Finder Replace removes the destination folder and uploads the incoming tree. Files present
only in the old folder disappear, as in the native SMB control. This is not atomic: an
interrupted replacement can leave a partial remote tree. Pending local uploads remain available
for retry. NAS backups own previous versions. Merge is a separate action and was not tested.

The existing delete/create callbacks already handled normal replacement. Testing a downloaded
folder after an outage exposed a ten-second refusal before deletion began. Pausing only the
fixture server's native SMB session reproduced it while direct SMB requests still worked.
A process sample showed `ShareSession.drainWatches` waiting for a watcher to close.
The old code reported this as pending local writes, leaving Finder at "cannot synchronize"
after the connection resumed. Manual Retry completed the same operation.

Handle-drain timeouts now have their own error. Deletion and folder-move callbacks map it to
the existing retryable busy response. They still wait for the handles to close before changing
the server. Actual pending-upload guards and their errors are unchanged. No new recovery store,
content verification pass, dependency or format change was added.

## Validation

Setup: macOS VM 1, macOS 27.0.1, isolated signed app and writable Samba fixture. Native SMB
and File Provider used separate folders with the same initial contents. The physical NAS was
not modified. Cache states below describe provider downloads; server caches were not controlled.
These are correctness checks, not performance measurements.

| Case | Result |
| --- | --- |
| Native SMB populated-folder Replace | Old-only file and nested folder removed; incoming tree matched |
| Provider destination not downloaded | Same final tree as native SMB |
| Downloaded destination, including nested contents | Clean repeats passed; outage-related timeout reproduced and fixed |
| Stop at Finder's conflict prompt | Original folder unchanged |
| Empty incoming folder | Destination remained a folder with no children |
| Read-only location | Finder paste unavailable; remote original unchanged |
| Interrupted 64 MiB upload and app/provider restart | Local bytes survived; automatic retry produced the expected remote hash |
| Native SMB session paused for 30 seconds | Baseline required manual Retry; candidate retried automatically with exact incoming contents |
| Folder rename under the same session pause | Candidate retried after two drain timeouts and completed without manual Retry |

The candidate's replacement log records the drain timeout, later deletion admission and
successful uploads. Independent server reads confirm the final paths and contents; Settings
shows no remaining pending change. A POSIX read-only probe returned errno 11 and does not
establish a permission-error contract. Finder Merge, packages, links, concurrent remote writers,
overlapping locations and physical-Mac workflows are outside this check.

`Tools/run-checks.sh` passed in the VM: 520 package tests, one optional skip, release CLI and
benchmark verification, generated-project consistency, warning-free unsigned app build and
all C protocol checks. The signed candidate passed strict/deep signature verification.

Raw evidence is in `results/folder-replace-20261106/` on the host and VM. It includes process
samples, callback logs, local/server inventories, checks and matched before/after frame
recordings with timestamps. The reproduction pauses only the native client's Samba worker,
chooses Finder Replace, then resumes that worker after 30 seconds. The candidate must finish
without clicking Retry, and the server tree must contain exactly the incoming files.

The test location had no pending changes before removal. Cleanup removed its downloaded copies,
isolated app, generated app builds, transfer archives and server fixture. Finder has zero open
windows. VM free space increased from 813.88 GiB to 814.53 GiB. Logs and recordings remain;
older unrelated fixtures were preserved. Temporary host signing bundles were removed after transfer.
