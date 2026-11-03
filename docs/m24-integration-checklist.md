# M24 integration checklist

The provider route and Settings recovery controls are implemented. Deletion remains disabled
in the normal build through `SourceReaderBridge.deletionEnabled = false`. The coordinator must
compile the app and complete the signed checks below in `macOS VM 1` before enabling it.
Host Swift package checks do not verify Finder, XPC, signing or controller lifecycle behavior.

This is a handoff procedure, not a results log. Use the disposable loopback Samba fixture.
Record runtime evidence in the existing [deletion results](results/2026-10-29-deletion-protocol.md)
and update the README after the run. Leave the original NAS and physical-Mac installation alone.

## Implementation details to review

- The provider advertises `allowsDeleting` only for supported writable items when the gate is
  enabled. It never advertises `allowsTrashing`. The callback forwards the exact base versions
  and recursive option through bounded JSON. A tombstone still requires durable app replay.
- Changed, replaced, moved, unsupported and refused selected items return `deletionRejected`.
  Remaining children return `directoryNotEmpty`. Unknown results return `cannotSynchronize`.
  Connection, authentication, cancellation and space errors retain their specific error codes.
- Retry uses the immutable admitted plan. Automatic launch/reconnect recovery only settles
  records whose remote work has ended. No retry adds a newly discovered child.
- Settings lists records in every admitted view, using paths relative to that location.
  Last-attempt reasons are in memory, as for PendingCreate. Node outcomes survive restart.
  Stop Deleting stays available while a Settings Retry runs.
- Dismiss hides only a completed notice. It retains the plan and every outcome, including
  uncertainty. Settled refusals and stopped requests also have dismissible notices. No new
  persisted fields, Settings/catalog formats or migrations were added.
- Settlement advances the surviving selected item's metadata version after a definite refusal
  or Stop. This lets a new Finder action use a new base while old callbacks replay the old
  outcome. Content versions, IDs and keeps do not change through that metadata refresh.
  An unconfirmed selected outcome does not get this refresh.
- The cancellation token and counted-Stop decisions now live in TransferCore. App KVO,
  progress cancellation, lane scheduling and Settings callbacks retain their existing roles.

## Prepare the VM candidate

1. Integrate the commits and run `Tools/run-checks.sh` in the VM. App-target changes have not
   been compiled on the host. No generator changes are needed because all production changes
   use files already included in both targets as appropriate.
2. Capture the baseline Finder/Settings recordings with deletion disabled. Confirm that direct
   filesystem deletion also fails and leaves the remote items intact.
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
3. Replay the original item and base versions. Expect the same terminal result with no new
   traversal or deletion. Repeat after process restart and after Dismiss Notice.
4. After admission releases its handles, open the target with an incompatible SMB handle and
   resume execution. Expect a definite refusal. Let settlement finish and verify that Finder
   reconstructs the selected live item with its updated metadata version. Close the competing handle and explicitly select Delete again. Expect a fresh admission and
   success. Replay the earlier base again and expect its original refusal. This checks that
   Finder distinguishes a new user action from an old callback.

## Lost reply, Retry and Dismiss

1. Inject a lost successful close reply before the `closeAcknowledged` checkpoint, using the
   existing signed deletion helper. Independently confirm that the object disappeared. Expect
   the record to remain unsettled, without a success claim based on the absent name.
2. Restart the app. Expect automatic recovery to leave that remote attempt unsettled. In
   Settings, click its Retry. Expect the recorded object to become unconfirmed when the fresh
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
