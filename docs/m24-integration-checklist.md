# M24 integration checklist

The provider route and Settings recovery controls are implemented. Ordinary deletion stays
disabled because Finder Replace can delete its destination before saving the new file. The
approved **Delete Permanently…** command uses a separate route and confirmation. Both gates
remain false in normal builds. Complete the signed checks below in `macOS VM 1` before
enabling the custom command.
Host Swift package checks do not verify Finder, XPC, signing or controller lifecycle behavior.

This is a handoff procedure, not a results log. Use the approved disposable Samba fixture;
the current single-client candidate uses the Linux VM fixture from the November 3 checks.
Record runtime evidence in the [deletion results](results/2026-10-29-deletion-protocol.md) or
[confirmed-command results](results/2026-11-03-permanent-command.md)
and update the README after the run. Leave the original NAS and physical-Mac installation alone.

## Implementation details to review

- The provider advertises `allowsDeleting` only for supported writable items when the gate is
  enabled. It never advertises `allowsTrashing`. The callback forwards the event domain version,
  exact item base versions and recursive option through bounded JSON. A tombstone still requires
  durable app replay.
- Changed, replaced, moved, unsupported and refused selected items return `deletionRejected`.
  The extension constructs that error with `fileProviderErrorForRejectedDeletion(of:)` and
  the surviving catalog item; a bare error code makes macOS retry without restoring the item.
  Remaining children return `directoryNotEmpty`. Unknown results return `cannotSynchronize`,
  except a fully settled unconfirmed deletion with a live selected row. That row is restored
  through `deletionRejected` while its durable outcome remains unconfirmed.
  A recorded request must finish every view's settlement before returning a terminal refusal.
  Until then, failures such as a changed location root or lost write permission return
  `cannotSynchronize`; Settings and logs retain the original failure.
  Connection, authentication, active cancellation and space errors retain their specific error
  codes. A completed stopped request replays `deletionRejected`, never `userCancelled`.
- Admission blocked only by another deletion, or by the reader's full job queue, returns
  `CocoaError.xpcConnectionReplyInvalid` for automatic retry. Other pending-write refusals still
  return `cannotSynchronize`. This avoids depending on a completion signal in every overlapping
  domain, including when a read or upload holds the last job slot.
- Retry uses the immutable admitted plan. Automatic launch/reconnect recovery only settles
  records whose remote work has ended. No retry adds a newly discovered child.
- Completed settlement signals the owner's stopped File Provider requests so Finder can replay
  a refusal and restore survivors. Launch/reconnect also signals already-complete records;
  completed-request replay itself sends no new signal.
- Settings lists records in every admitted view, using paths relative to that location.
  Last-attempt reasons are in memory, as for PendingCreate. Node outcomes survive restart.
  Stop Deleting stays available while a Settings Retry runs.
- Dismiss hides only a completed notice. It retains the plan and every outcome, including
  uncertainty. Settled refusals and stopped requests also have dismissible notices.
- A confirmed child deletion checkpoints parent identities through their still-protected
  handles in `DeletionProgress.parentUpdates`. This accounts for synthetic directory creation
  times changing after child removal. The admitted plan stays immutable; new handles must match
  the checkpoint exactly. Missing checkpoints retain the earlier evidence and can leave work
  unconfirmed. No Settings/catalog format or migration is added.
- Replay matches the owner, item and original event domain version, even when Finder changes
  the callback's item base versions. The app compares decoded Apple versions semantically.
  It advances the persisted domain version before terminal settlement and republishes completed
  recovery after launch. A fresh action on the restored item then carries a newer event version.
  Settlement no longer increments item metadata solely to distinguish requests. Fresh listings
  still update real metadata; unchanged content, IDs and keeps survive.
- The cancellation token and counted-Stop decisions now live in TransferCore. App KVO,
  progress cancellation, lane scheduling and Settings callbacks retain their existing roles.
- Only `cancelDeletion` from a cancelled provider Progress, or Settings Stop Deleting, requests
  durable Stop. Releasing a deletion job after completion or timeout, or invalidating its XPC
  connection, detaches the waiter without cancelling the transaction. Other reader jobs retain
  their release behavior. The existing plan can finish without its original waiter or remain
  recoverable after a remote error.

## Prepare the VM candidate

`Tools/prepare-folder-candidate.py --enable --overlap-checks --deletion-checks OUTPUT`
reuses the existing signed folder fixture and exports deletion callbacks and both views'
durable deletion records. Add `--enable-permanent-deletion` for the approved command. The separate
`--enable-deletion` option reproduces the earlier ordinary-deletion protocol checks; never use
both. These options leave normal-build gates unchanged; use unique `check-` snapshot labels and
the existing local evidence picker. The current candidate is still a VM-only transport experiment.
Adding `--crash-checks` enables `deletion-fault.json`, bound to the fixture run, selected item,
`Deletion/` path, node index and checkpoint. It exports the durable plan/progress and stops
the app before or after an attempting, close-acknowledged or deleted checkpoint. Each control
fires once. Kill only the recorded test process, preserve the hit and resume the fixture app.
The `admitted` stage stops after traversal handles are released. `action: "fail"` throws a
synthetic error instead of stopping, so the real callback can fail while retaining pending work.
`action: "fail-repeated"` keeps that error active across automatic retries until Stop settles
the record or the control is removed. A `deletion-fault-CHECKPOINT.json` control takes precedence
at its named checkpoint, allowing admission failure and a separate Settings hold in one trial.
The `settings` stage requires `action: "hold"` and suspends only the asynchronous Settings
callback. Create `deletion-release-CONTROL_UUID` in the evidence directory to release it;
after 180 seconds it fails without settling. This leaves the main actor and request lanes free.
The `settled` checkpoint stops after durable completion, before signaling File Provider retry.
Snapshot labels starting `check-stopped-replay-` also exercise the production app replay route
for a completed stopped item with refreshed catalog bases and an equivalent XML event archive.
The helper requires the original stopped outcome and unchanged durable records. This supplements
real Finder callbacks; it does not claim that Finder sent the constructed request.
`check-unconfirmed-replay-` applies the same check to completed unconfirmed selected items,
requiring the original unconfirmed result, current item bases and unchanged durable records.
The `check-reader-jobs-hold` request suspends the idle reader queue and submits four
constructed reads through the selected domain's connected reader session. Delete another
fixture file in Finder while those jobs occupy the session. `check-reader-jobs-release-one`
releases one slot without running the queued reads; Finder must retry the deletion itself.
`check-reader-jobs-drain` releases the rest and resumes the queue. After the operations drain,
`check-reader-jobs-verify` requires four single cancellation replies and no remaining jobs.
A trial suffix may follow each phase, such as `check-reader-jobs-hold-second`. Wait for a successful
deletion callback with the other three reads still held before draining them.
A 180-second safety timeout drains the queue and makes verification fail. Each request exports
a `-jobs.json` report. The deletion uses Finder/XPC; the occupied reads use constructed requests.
For lifecycle trials, synchronous checkpoints also accept `action: "hold"`; only the transaction's
worker waits for its release file. `attempting-after` holds immediately before marking the protected
object; `marked` holds after the mark succeeds and before close. The app and extension remain live.
`check-deletion-session-state-TRIAL` exports the connected session's jobs, active/cancelled
transaction progress and queued Stops. `check-deletion-session-invalidate-TRIAL` exports the
same observations and invalidates that actual connection. Inspect again after reconnection.
`check-provider-cancel-TRIAL` sends a fixture/item/event-bound command to cancel the Progress
returned by the active real provider callback. Its timer consumes the command once and emits
`delete-progress-cancel`. This tests the production cancellation path with a constructed trigger;
it does not establish the behavior of Finder's cancellation UI.
With one real Finder deletion awaiting Settings, `check-joined-jobs-hold` joins three constructed
requests to that event in the actual reader session and requires a fifth request to be busy.
Use `check-joined-jobs-release` to detach one waiter without Stop, then `check-joined-jobs-cancel`
to queue Stop from a different waiter while a short lane barrier makes that ordering observable.
After releasing Settings, `check-joined-jobs-verify` requires three single replies, correct receipts,
no jobs and unchanged confirmed outcomes. The remote deletion has already finished in this trial.
With `Deletion/SourceClose.txt` awaiting the real Settings callback, `check-source-close` closes
the controller's existing source directly and requires its recovery waiters to drain without Stop.
After releasing Settings, `check-source-closed-state` requires the same durable record and no new
Stop. These commands omit catalog snapshots because that catalog is intentionally closed. Restart
the app normally to exercise launch reopening and settlement. This is a source API probe, not a
user-facing Remove Location action, which pending deletion correctly blocks.
`catalog-second` injects a failure before the second catalog's settlement. The repeated actions
`fail-version`, `fail-readonly` and `fail-invalid` exercise the production completion-error mapping.
`check-incomplete-deletion-TRIAL` replays that settled but incomplete `Deletion/CatalogDelay`
record through the connected reader session and requires `cannotSynchronize` with unchanged records.
`check-keep-restore-start` seeds pending keeps only for the two fixture locations: the files in
`Deletion/Restore/` and the untouched neighbor. A run-bound `keep-restore.json` control holds the
actual older restore after it enters the controller's restoring set. Its release file is
`keep-restore-release-CONTROL_UUID`; the hold times out after 180 seconds. The candidate also
records actual `controller-recovered` callbacks so reconnect evidence need not infer their use.
`check-removal-state-TRIAL` exports the two fixture domains' Settings, registration, catalog
presence and owner records even after removal. It verifies that unrelated Settings stay intact.

1. Integrate the commits and run `Tools/run-checks.sh` in the VM. App-target changes have not
   been compiled on the host. The generator includes the shared domain-version archive helper
   in both targets. Use fresh catalogs and deletion records for the required event field.
2. Capture the baseline Finder/Settings recordings with deletion disabled. Direct filesystem
   deletion may succeed locally before its callback. Confirm rejection restores the local item,
   stops callback retries and leaves the remote item intact.
3. Enable only `SourceReaderBridge.deletionEnabled` in the disposable candidate. Build and sign
   it using the existing VM procedure. Do not change the normal-build gate in the integration
   branch until all acceptance checks pass.
4. Add two writable locations that overlap on the fixture. Put the selected test subtree below
   both roots, with neither configured root inside it. Retain an untouched neighboring file.
   Create a regular file, an empty folder, and a nested folder with multiple regular files.
   Leave one nested branch unlisted in the second location. Keep some selected files downloaded.
5. Record the selected and neighboring objects' server identities, contents, attached data,
   permissions, catalog IDs, content/metadata versions and keep requests. Record the date,
   OS/build, fixture setup and cache state. Audit backing storage independently of Finder.

## Finder deletion and warning

The numbered checks below record the ordinary-deletion protocol investigation. They do not
authorize enabling ordinary deletion. For the accepted workflow, use Finder's
**Delete Permanently…** custom action with the ordinary callback gate off. Verify Return and
Escape cancel on the first press, including after closing Settings with a text field active.
Verify one click confirms, cancellation remains responsive, and connection loss before
confirmation admits no record. Verify a pending save blocks the action and a save racing after
admission remains exportable. After Stop Uploading exports that save, confirm system pending
state clears without restoring a server file. Check both overlapping views and refused Replace.

1. Select the regular file and invoke Finder's deletion command. The warning must say that the
   item will be deleted immediately or permanently, and that the action cannot be undone.
   It must offer Cancel and a destructive deletion action, with no promise of Trash retention
   or Put Back. Record Finder's actual wording and command name. If its UI implies recoverable
   Trash semantics, stop at the UI gate rather than enabling deletion.
2. Cancel the warning. Expect no deletion request or remote change. Repeat and confirm. Expect
   the admitted file to disappear from backing storage, both catalogs and both location views.
   Confirmed-node keep requests must clear. The untouched neighbor must retain its contents,
   metadata, identity and downloaded bytes. Repeat for a never-downloaded file and a file with
   a verified editing base.
3. Delete the empty folder. Expect one confirmed node, removal from both views, and no change
   to its neighboring objects. There must be no hidden retention copy.
4. Delete the populated folder. Record whether Finder sends `.recursive` or individual child
   callbacks. For a recursive callback, expect child-before-parent outcomes for the complete
   admitted traversal, including children the second catalog never listed. Confirm every
   removed object in backing storage and every affected view. A nonrecursive callback on a
   populated folder must return `directoryNotEmpty` and remove nothing through that callback.
5. Use a signed callback probe for a configured root, an ancestor containing a configured root,
   a read-only location, and an unsupported item. Expect rejection and no remote mutation.

## Concurrent deletions and job capacity

1. Select three independent files in Finder and delete them together. Suspend the first record's
   `commitDeletionSettings` callback so later callbacks run before `finishDeletionSettings`.
   Expect each blocked callback to return `NSCocoaErrorDomain/NSXPCConnectionReplyInvalid`,
   without admitting another record. Release Settings completion. Without Retry, a new user
   action or `signalErrorResolved`, all three requests must be resent as needed, admitted and
   completed. Audit backing storage, both catalogs and the durable records.
2. Repeat with requests originating in both overlapping domains, including a selected item
   visible in only one view. Delay completion of the second catalog too. Every busy request
   must resume after the blocking record completes, with one record per item/event version.
3. In a signed callback probe, occupy all four reader job slots with held reads or uploads,
   then request deletion. Expect the same transient error and no deletion record. Release a
   slot and verify automatic retry completes. Repeat with deletion jobs holding the slots.
4. Separately block admission with a pending edit or rename. Expect `cannotSynchronize`, as
   before. Verify read-only and stale-base refusals still return `deletionRejected`, and a
   lost reader returns `serverUnreachable`. Record retry timing and callback counts.

The macOS 27.2 SDK's `NSFileProviderReplicatedExtension.h`, documentation for
`deleteItemWithIdentifier:baseVersion:options:request:completionHandler:`, says errors other
than its listed terminal/domain errors "will be considered to be transient and will cause the
deletion to be retried." It specifies `NSCocoaErrorDomain/NSXPCConnectionReplyInvalid` for errors
without a suitable existing code. This is the contract used for busy admission; actual Finder
retry timing remains a VM check.

The same header says `deletionRejected` causes the system to "re-create the deleted item on
disk based on the latest metadata available from the extension." It reserves `NSUserCancelledError`
for completing the active cancelled Progress. Thus a durable stopped replay is a refusal, while
the original cancelled provider call still completes with `userCancelled`. The header also says
macOS can cancel Progress when a call takes too long. The API does not identify whether that
explicit cancellation came from the user or the system.

The header is under `System/Library/Frameworks/FileProvider.framework/Headers` in that SDK;
the deletion error and cancellation contract is at lines 805–846.

## Changed items, arriving children and a new user request

1. In the signed test helper, suspend execution after admission releases its traversal handles
   and before `resumeDeletionOnLane` runs. Through another SMB client, change one admitted file
   while preserving its length and modification time. Resume. Expect a changed outcome and
   preserved bytes. Repeat with a same-name replacement and expect the replacement to survive.
   For a previously verified file, also change or replace it before admission and expect refusal.
2. Admit a populated folder, then add a child before execution. Change or replace a different
   admitted child. Resume. Expect unaffected admitted children to delete, new/changed objects
   to survive, and their nonempty parents to remain. Finder must get `directoryNotEmpty`.
   Settings must name every admitted item with its actual outcome and an accurate confirmed
   deletion count. A new child must not appear as an attempted node of the old record.
3. Replay the original item/event version, including refreshed item base versions. Expect the
   same terminal result with no new traversal or deletion. Repeat after restart and Dismiss Notice.
4. After admission releases its handles, open the target with an incompatible SMB handle and
   resume execution. Expect a definite refusal. Let settlement finish and verify that Finder
   reconstructs the selected live item. Close the competing handle and explicitly select Delete again. Expect a newer event version, fresh admission and
   success. Replay the earlier event again and expect its original refusal. This checks that
   Finder distinguishes a new user action from an old callback.
5. Inject a transport failure at the selected item's mark after the attempting checkpoint while
   leaving that object present, then Stop and settle. Suspend the fresh listing first. Its
   outcome must not be treated as confirmed. Let reconciliation finish and verify the surviving
   selected row returns through File Provider's rejected-deletion response. Its ID, content
   version and keeps must survive. Replay the original event before and after restart and expect
   `deletionRejected` only after every view settles and a live selected row is available, with the
   same unconfirmed record, including when item base versions changed. An absent selected row
   or incomplete settlement must retain `cannotSynchronize`. No replay may admit
   another operation. A new Finder action after restoration must carry a newer event version.

   The November 3 signed probe showed that working-set updates alone do not restore this item
   while the callback returns `cannotSynchronize`. The response above rejects further execution
   of that completed request and restores the observed survivor; it does not confirm deletion.
   Settings must retain the uncertainty and the original replay record through dismissal.
6. Interrupt recursive deletion after a confirmed child, then change the location-root inode
   before Retry so `withDeletionAdmissionRoot` fails with `versionChanged`. Expect
   `cannotSynchronize`, an incomplete record and accurate partial outcomes, never an early
   `deletionRejected`. Restore the original root and finish recovery. Repeat with lost write
   access and an injected `invalidRequest` while a record exists, including a record whose
   remote work ended but catalog/Settings settlement is pending. Terminal refusal is allowed
   only after all views finish. Without an admitted record, those refusals keep their existing
   `deletionRejected` mapping.

## Lost reply, Retry and Dismiss

1. Inject a lost successful close reply before the `closeAcknowledged` checkpoint, using the
   existing signed deletion helper. Independently confirm that the object disappeared. Expect
   the record to remain unsettled, without a success claim based on the absent name.
2. Restart the app. Automatic settlement alone must leave that remote attempt unsettled;
   Finder may independently replay its callback and resume the original request. If it remains
   unsettled, click its Settings Retry. Expect the recorded object to become unconfirmed when the fresh
   evidence cannot prove deletion. Reconciliation may remove a now-absent catalog entry, but
   the notice must still say that deletion is unconfirmed.
3. Repeat with a replacement created at the path before Retry. Expect the replacement to
   survive unchanged and remain readable. Neither Retry nor replay may mark it for deletion.
4. Separately interrupt a request before any mark with a recoverable connection failure. Restore
   the connection and use the row's Retry. Expect work to continue against the original plan,
   followed by catalog and Settings completion. Observe the actual controller persistence
   callback, not only a helper's private Settings callback.
5. While any remote node or catalog/Settings obligation remains unfinished, expect no Dismiss
   action, and verify that a direct Dismiss API call also refuses. Once complete, dismiss an
   unconfirmed notice and a definite partial-failure notice. The confirmation must explain that
   dismissal cannot restore data or confirm uncertainty. Expect the rows to hide in both views
   while their on-disk replay records and outcomes remain unchanged except for `dismissed`.
6. Restart and replay both dismissed records. Expect no new mutation and no conversion of an
   unconfirmed outcome into success. A stopped completed record must likewise remain stopped.

## Cancellation and controller lifecycle

1. Cancel Finder progress immediately after admission. Expect one provider completion with
   `userCancelled`, durable Stop, no later node attempts, and settlement of the stopped record.
2. Cancel inside an active protected node, first before marking and then after marking but
   before the close reply/checkpoint. Expect remote protection to end before durable Stop.
   The latter case may delete its active object, but must preserve an unconfirmed outcome and
   leave every later node untouched. Repeat using Settings Stop Deleting during an active Retry.
3. Force the ordering where `Progress.isCancelled` is true but the joined request's KVO callback
   has not acquired the recovery lock. Let completion run. Expect cancellation to queue Stop
   before app recovery replies are released. Provider cancellation completion can arrive first.
   Run two explicit Stops and check that both checkpoints drain before app recovery completion.
   Count each provider/app reply exactly once after an observation window.
4. Suspend the real `commitDeletionSettings` callback. Close the source while it waits, then
   release the callback. Expect no success through the closed source, no discarded record,
   and no new token-driven Stop merely because the source closed. Already queued Stops must
   still persist. Reopen the location and expect automatic settlement to finish without another
   remote deletion. Confirm only proved-deleted typed keep paths were removed.
5. Repeat recovery through controller launch, share reconnect, and completion of older Keep
   Downloaded restoration. Expect settled records to resume reconciliation, unsettled records
   to require explicit Retry, and both location views to receive parent/working-set updates.
   Check these callbacks against the real persisted Settings and foreign records.
6. Hold a recursive deletion before a node mark, then after a mark but before close acknowledgement.
   At each point separately let the provider's 60-second response deadline expire, invalidate the
   reader connection, and restart the extension. Do not cancel provider Progress. Resume the held
   node and inspect the actual outbox. None of these paths may set `progress.stopped`, create a
   `.stopped` node, or queue a counted Stop. An app-side transaction with a live source may finish;
   an interrupted transaction must retain its original plan and uncertain in-flight evidence.
   Reconnect and replay, or use Settings Retry after a remote failure, and audit every node.
7. Repeat with an explicit provider Progress cancellation and with Settings Stop Deleting.
   Expect durable Stop only in these runs, after active protection ends. The original provider
   cancellation must complete once with `userCancelled`. Once settlement completes, replay the
   same base before and after process restart and Dismiss Notice. Expect `deletionRejected`,
   no new remote attempts, and Finder restoration of surviving items. Observe that callbacks
   cease instead of looping on `userCancelled`.
8. Release an already completed deletion job and repeat the XPC lifecycle checks with joined
   waiters. Releasing one waiter must not stop the shared transaction; explicit cancellation by
   a joined waiter must still request Stop. Verify ordinary read/upload release still cancels
   its job and removes owned staging files.

## Remove Location and finish

1. Leave a deletion unsettled and choose Remove Location in each overlapping view. Expect the
   blocking dialog to name the selected path relative to that view. The domain, catalogs and
   deletion record must remain. Repeat with an unconfirmed completed record before dismissal.
2. Stop an untouched request and let all settlement finish. Expect removal to be allowed because
   no unfinished deletion remains. For an unconfirmed completed request, removal
   becomes available only after explicit dismissal. Removing a secondary view must retain the
   owner's replay record. Removing the owner may remove its settled record only after domain
   removal succeeds.
3. Capture the matching after recordings. Run `Tools/run-checks.sh` on the integrated candidate,
   preserve private evidence and restore temporary fixture/service state. Record all failures
   and unavailable cases. Normal-build enablement still requires the signed warning, callback,
   recovery and lifecycle gates above to pass.
