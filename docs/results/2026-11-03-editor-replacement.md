# Finder replacement and document saves

Date: 2026-11-03. M25 protocol observation and signed editor checks on the VM-only
single-client branch. M25 is incomplete. Normal deletion and Finder Replace remain gated.

Finder Replace sent an ordinary deletion followed by a separate creation for both an unopened
file and a verified downloaded file. Neither callback bound the incoming contents to the old
destination. Enabling deletion would therefore allow the old contents to disappear before the
incoming file was durable or verified. This fails the accepted replacement gate and also blocks
normal deletion enablement. A timing heuristic cannot distinguish this from independent actions.

Ordinary Save and Save As passed for the tested TextEdit, Preview and Xcode documents. Repeated
disconnected TextEdit saves survived intentional Quit/relaunch, main-app crash and extension
termination. A competing server edit preserved both versions. A moved-original trial instead
published an unwanted conflict copy. Build 18 retains and exports the edit, but returning the
original exposed a catalog-binding retry defect. Its guard passes the fresh signed checks below.
An app-absent save survives refused eviction and uploads after relaunch; an RTF save survives an
app crash and a competing edit. Metadata export exposed omitted callback attributes. The repair
awaits signed verification. These checks do not complete the storage or offline-editing matrix.

## Setup and evidence

- macOS VM 1, macOS 27.0.1, Xcode 27; Linux Samba 4.19.5 on ext4. The original NAS was untouched.
- Signed EventCheck build 16, generated with folder organization and callback tracing enabled,
  deletion disabled and no failure hooks. The installed app is in the VM only.
- Build 17 adds `--editor-checks` snapshots through the existing evidence-folder grant. It
  exports complete local hashes with materialization disabled, validated durable pending saves,
  and the system's pending-upload status, including while disconnected.
- A new disposable fixture contains TXT, RTF, PDF, PNG and Swift source files, all below 64 KiB,
  plus replacement sources with different contents and untouched neighbors.
- The macOS evidence directory is `results/replace-20261103/` followed by the run UUID in
  `config.json`. It holds callback events, catalog/local snapshots, `online-report.json` and
  `pdf-report.json`. The Linux evidence directory is `/tmp/tinymounter-replace-` followed by
  the same UUID. `seed.json` and the `*-audit.json` files independently record server inodes,
  ownership, modes, modification times, hashes and xattrs.
- Required checks immediately before this candidate passed with 644 tests, two optional skips
  and no Swift warnings, in `results/folder-single-20261103/checks-deletion-final.log`.
  `build-eventcheck-16.log` also has no Swift warnings. Vendor C conversion warnings and Xcode's
  informational App Intents warnings remain.
- Build 17 and `results/replace-20261103/checks-editor-state.log` passed the same required checks
  with 644 tests, two optional skips and no Swift warnings.

## Finder gestures

| Gesture | Observed callbacks and result |
| --- | --- |
| Cancel, labelled Stop by Finder | No content mutation; the selected original remained unchanged. |
| Keep Both | Created the incoming file under a numbered name; original bytes and identity remained. |
| Replace an unopened destination | Recursive delete with its existing ID and `f1` base; then create with a new temporary ID and options zero. |
| Replace a verified downloaded destination | The same delete/create sequence, with the destination's `e1` base on the delete only. |

The disabled deletion handler returned `deletionRejected` with the surviving item. The following
create failed with `filenameCollision`. Finder then renamed the original to a numbered name and
retried the create at the requested name. Both complete files survived. The originals retained
their server inodes, bytes, ownership, modes and modification times. Samba added its archive
attribute after the rename, so xattrs were not byte-identical. This is observed fallback behavior,
not implemented transactional Replace or evidence that enabling deletion would be safe.

`check-replace-baseline`, `check-replace-cancel`, `check-replace-keep-both`,
`check-replace-cold`, `check-replace-verified-downloaded` and `check-replace-verified` capture the
states. The unopened destination had no fetch or edit base. TextEdit opened the second destination
before its trial; its full fetch, edit-base receipt and materialization-disabled hash were verified.

The reviewed Xcode 27 SDK exposes only `recursive` in `NSFileProviderDeleteItemOptions`.
`NSFileProviderRequest.isSystemRequest` and `isFileViewerRequest` are explicitly invalid for
create/modify/delete callbacks. `domainVersion` describes when an event was observed; it does
not express replacement intent. `mayAlreadyExist` concerns reimport and merging, not permission
to overwrite. See `NSFileProviderReplicatedExtension.h` and `NSFileProviderRequest.h`, read on
2026-11-03. No supported binding was found in these APIs or in the observed callbacks.

## Ordinary editor workflows

| App and format | Actions verified | Server result |
| --- | --- | --- |
| TextEdit TXT | Two explicit saves, then Save As | Latest text and a separate complete copy |
| TextEdit RTF | Bold text, two saves, then Save As | Latest text and RTF formatting in both files |
| Preview PDF | Rotate, Save, rotate again, Save, then Save As | Original and copy decode to the same text, one page, 300 by 240 points, rotation 180 degrees |
| Preview PNG | Rotate and Save twice, then Save As | Complete saved image and byte-identical copy |
| Xcode Swift file | Two saves, then Save As | Latest source text and a separate complete copy |

Each Save used `modifyItem` for the existing ID with contents and a base version. Save As used
`createItem` for the separate name. No delete callback occurred during these editor operations.
Final hashes of all ten local editor files, read with materialization disabled, matched independent
server hashes. The original files retained their server inodes, ownership and modes. No edit
remained pending and no server stage, backup or work file remained in the final inventory.
The untouched neighbor, marker, Cancel destination and Keep Both original remained unchanged.

PDF Save As re-encoded the document, so its hash differs from the original. PDFKit verified the
decoded text, page count, media box and rotation. This does not establish arbitrary PDF annotations,
forms, signatures or large-document compatibility. The PNG is a small solid-color synthetic image.

Content callbacks returned unsupported metadata fields pending. The first TXT save included
extended attributes; later saves included content modification dates. The content path preserves
the destination's access metadata and existing attached data. Incoming xattrs are retained with
pending local data for export, not generally synchronized. Resource forks prevent remote
publication. Combined rename/content changes remain refused. The observed documents do not
prove arbitrary incoming metadata compatibility or standalone tag/lock synchronization.

## First disconnected conflict

With TextEdit holding the verified TXT file, the test forcibly unmounted only the disposable
share. Two explicit local saves succeeded. A direct local read returned the complete second
revision while the share remained unmounted. The server file then received a competing in-place
edit, retaining its inode. Finder supplied the SMB reconnection; automatic remount was not tested.

After reconnect, the server retained its competing edit and a separate conflict file contained
the complete second local revision. `check-offline-text-reconnected` and Linux
`offline-conflict-audit.json` record the result. This is one app-running trial. It does not prove
app-closed ownership, restart persistence, eviction prevention or exact upload counts.

The old snapshot helper could not inspect the disconnected state because it resolves a live
share bookmark. A direct CLI read of the app's private outbox was denied by macOS. No sandbox
permission changed. Build 17's scoped snapshots resolved that evidence gap.

## Offline save ownership

These build 17 trials used the downloaded `TextCopy.txt` created by TextEdit's earlier Save As.
Each trial forcibly unmounted only the disposable share. Server audits independently verified
the final contents after reconnection.

| Trial | Observed result | Evidence |
| --- | --- | --- |
| Repeated Save | Sequence 13 was durable, then consolidated into sequence 14. Complete local bytes matched validated pending bytes; macOS reported not uploaded. Reconnect published sequence 14 and cleared pending state. | `check-editor-state-offline-{one,two}`, `check-editor-state-online-after-two`, Linux `offline-two-audit.json` |
| Intentional Quit | The app was absent during two local saves. Relaunch automatically remounted the share and published the latest text before evidence-picker acceptance. | `quit-local-save.json`, `check-editor-state-after-quit` |
| Main-app crash | SIGKILL and relaunch while Samba was stopped preserved the same prepared sequence 16 and complete local contents. Restoring Samba and reconnecting published it and cleared pending state. | `app-crash-control.json`, `check-editor-state-{before,after}-app-crash`, `check-editor-state-crash-reconnected`, Linux `app-crash-{offline,reconnected}-audit.json` |
| Extension termination | Killing the provider PID identified by this fixture's event retained sequence 17. Another Save durably replaced it with sequence 18; reconnect published that revision. | `extension-kill-control.json`, `check-editor-state-extension-{terminated,new-save,reconnected}`, Linux `extension-reconnected-audit.json` |

The Quit trial's `quit-before-reconnect-audit.json` was actually captured after relaunch had
already reconnected and uploaded. It is not pre-reconnect evidence. An initial extension-kill
attempt found two processes and refused to kill either; `check-editor-state-after-extension-kill`
belongs to that failed setup. The later `extension-terminated` snapshot follows the actual kill.
These trials establish the tested small TXT lifecycle, not OS restart or eviction safety.

## Missing original

Build 17 durably retained sequence 19 while disconnected. Linux then renamed `TextCopy.txt`
to `TextCopyMoved.txt`, preserving its inode and contents. After reconnect the app published
the local revision as `TextCopy (conflict ...).txt` and completed the pending record. The moved
original survived unchanged, but automatic conflict publication violates M26's accepted policy.
Evidence is `check-editor-state-before-original-move`,
`check-editor-state-original-move-reconnected`, Linux `original-move-control.json`,
`original-move-reconnected-audit.json` and `original-move-report.json`.

The transaction now requires the original to exist before private staging. An absent original
retains a prepared local save for recovery/export and sends no mutation. A missing original
after an earlier staging attempt retains that stage and the local save. Already-started
transactions still recover their own moved object from recorded evidence. Existing-file
content conflicts retain their separate-copy behavior. This policy also applies to connected
saves with missing originals; no offline schema flag is needed. Focused regression tests cover
absence across reopening/retry, export, moved-original preservation and return, and an existing
private stage. Required VM checks pass with 647 tests, two optional skips and no Swift warnings
in `results/replace-20261103/checks-missing-original.log`; build 18 also has no Swift warnings.

Build 18 retained sequence 20 after Linux moved the original again. Reconnect and the normal
Retry Pending Changes action created no stage or conflict copy and left the moved file unchanged.
Export Local Copy produced all 47 expected bytes. The `check-editor-state-fixed-move-*`
snapshots, `fixed-move-export-report.json` and Linux `fixed-move-{control,report}.json` record this.

Returning the original then exposed a second defect. Reconciliation had tombstoned the old
catalog item and assigned a new ID when its name returned. Retry published the save remotely,
but catalog completion refused that new occupant. The record remained published with recovery
artifacts. Evidence is the Linux `fixed-move-returned-audit.json` and app logs; no completion is
claimed. Full snapshots waited in user-visible URL resolution, so queue-only snapshots omit
that step explicitly. The app now validates the original catalog binding before beginning any
pending publication, including Retry. A deleted binding stays local even if its pathname returns.
Already-started recovery still uses its recorded evidence. A catalog regression test covers the
read-only, deleted and returned-name cases. Fresh signed verification is recorded below.
The fixture's `check-editor-end-trace` action archives only its own tracing pointer after checking
the run identity. It permits a fresh fixture while preserving the failed location and recovery
records for investigation. It is absent from ordinary builds.

## Fresh recovery checks

The separate signed OfflineCheck-1 installation uses the same code as EventCheck build 20,
with its own bundle ID, App Group, settings and fresh fixture. The failed EventCheck transaction
remains preserved. Only the fresh test domain was enabled in System Settings. Its initial
`check-editor-state-baseline` preceded enablement and is not hydration evidence.
`check-editor-state-hydrated` verifies the downloaded TXT bases before disconnection.
Evidence uses the setup paths above with the fresh run in its own `config.json`.

Stopping the disposable Linux Samba service disconnected these trials. The snapshot's
`connected` field reports whether a mount path exists, not live server reachability. It can
remain true during the outage. Cache state was uncontrolled; these are correctness checks.

| Trial | Verified result | Evidence |
| --- | --- | --- |
| Moved original | Reconnect retains the prepared save with no server stage or conflict copy. Reconciliation retires the original catalog binding. | `check-editor-state-move-{offline,reconnected}`, Linux `move-reconnected-audit.json` |
| Returned original | Returning the same server inode and choosing Retry preserves its original bytes. The old local save remains prepared across relaunch and exports completely. | `check-editor-state-queue-return-retry`, `returned-original-export-report.json`, Linux `return-retry-audit.json` |
| Deleted original | After archiving and unlinking only the disposable original, reconnect and Retry retain the local save. Export reproduces its complete bytes without recreating the server pathname. | `check-editor-state-queue-delete-{offline,reconnected}`, `deleted-original-export-report.json` |
| Unrelated ordinary save | Another file publishes normally, preserves its inode, and leaves both recovery records intact. | `check-editor-state-queue-normal-save`, Linux `missing-original-report.json` |
| App absent and eviction | With the app intentionally quit and Samba stopped, TextEdit saves and closes a downloaded file. Finder's Remove Download reports that it cannot be evicted. Complete local bytes remain with materialization disabled. Relaunch publishes the same revision and clears that file's system pending entry. | `app-absent-*.json`, `app-absent-eviction.log`, `check-editor-state-queue-app-absent-relaunch`, Linux `app-absent-{before-relaunch,relaunch}-audit.json` |
| RTF interruption and conflict | A bold TextEdit save is durably prepared offline. After SIGKILL, a competing server edit and relaunch, the original keeps that edit and inode; one conflict copy matches the entire pending RTF. | `check-editor-state-queue-rich-{offline,reconnected}`, `rich-app-crash-control.json`, Linux `rich-conflict-report.json` |

The returned-name full snapshot also waited in macOS URL resolution. Its request is preserved
in `blocked-url-requests`; queue-only capture completed after resuming the diagnostic session.
The first resume attempt used `setup` and was correctly refused as an existing tracing session.
No domain or pending save was removed to recover diagnostics.

Required VM checks for the binding guard and diagnostic change pass with 648 tests, two optional
skips and no Swift warnings in `checks-edit-binding.log` and `checks-editor-trace.log` under
`results/replace-20261103`. These checks do not cover OS restart or real disk-pressure eviction.

## Incoming metadata and recovery export

The fresh fixture also tests a resource fork, Finder tags and a custom attribute. TextEdit
preserved the tags and custom attribute on TXT but removed its resource fork before delivery.
A separate in-place POSIX fixture write retained the fork, then triggered a content callback.
That save remained prepared across app termination and reconnect; the server document stayed
unchanged. Export Local Copy reproduced the entire content, resource fork and tag data.
`metadata-input-attributes.json`, `metadata-after-textedit.json`, `metadata-posix-save.json`,
`metadata-export-report.json` and Linux `metadata-remote-report.json` record the distinction.

The unmarked custom attribute was absent from export. Apple's Xcode 27 SDK documents that
File Provider filters nonsyncable attributes and caps syncable attributes at about 32 KiB.
No arbitrary-xattr preservation claim follows. The resource fork travels as contents; tags
have their own item property. These tests do not enable remote tag or resource-fork syncing.

The earlier TXT recovery exports also omitted `com.apple.TextEncoding`, although the provider
logged that macOS supplied it in `item.extendedAttributes`. The provider copied only the content
snapshot and ignored that separate dictionary. It now adds those delivered attributes to its
private local stage before durable preparation. Pending export can then retain them without
changing the server metadata policy. Regressions cover export after reopening and refusal of
symlinks, hard links and invalid attribute names. Signed verification remains pending.

## Remaining work and decision

Verify the callback-attribute repair in the signed candidate, then continue signed low-space
admission, interruption coverage for other document formats and broader eviction checks.
Do not infer completion from the successful small-document checks.

Normal Finder deletion cannot be enabled under the current replacement guarantee using the
observed callbacks. A possible alternative is an explicit provider action for permanent deletion,
with ordinary delete callbacks refused; that changes the user workflow and needs a decision.
Safe replacement needs an explicit transaction entry point or a supported OS binding. Neither
alternative is implemented here, and neither changes the accepted safety guarantee.

Failed setup attempts remain in the evidence. The UI tool rejected Unicode typing before either
initial text-save attempt, so those two snapshots are not save trials. A plain `shasum` returned
an empty digest without materializing the verified-destination placeholder; it was not accepted
as verification. The later TextEdit fetch and complete local hash established the base. Early
server comparison scripts incorrectly required identical Samba xattrs and byte-identical PDF
encodings; the final reports state the narrower verified properties above.
