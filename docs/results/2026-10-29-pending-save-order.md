# Pending-save ordering

Date: 2026-10-29. M23 implementation in progress; not a completed milestone.

The baseline VM regression reproduced an older save publishing while a newer complete local
save was waiting. The ordering fix passes the required VM checks, including the same regression.
The signed update-recovery and retained-save cleanup checks below also pass. Recovery cleanup and
clearer status reporting pass the required VM checks. Storage admission and the remaining
interruption cases still need runtime evidence.

## Reproduction

The focused EditTransactionTests regression stages two different saves against one base and
asks the older generation to publish. The baseline wrongly performs two renames and one
content update. Five assertions fail: refusal, unchanged remote state, no moves, no update and
retained prepared state. This uses an in-memory remote with real durable local payloads;
it is not a signed Finder or SMB runtime reproduction.

Setup: macOS VM 1, synthetic local data, uncontrolled cache state. The test compiled and ran.
Evidence: VM .local/phase4/m21-20261029/save-order-before.log. There is no performance claim.

## Implementation and compatibility

New saves record durable arrival order. Only the latest complete generation can begin
publication. Earlier local-only generations retire after the newer payload is verified;
work that may have changed the original must resolve first. A failed newer staging operation
preserves the earlier complete copy. The app's own proved earlier publication can explain a
changed base, while an unrelated change still takes the conflict route.

Review rejected identity-only removal of partial or changed remote artifacts. Cleanup of
superseded copies requires the recorded complete versions. Under the subsequently
accepted policy, a superseded save whose publication has not started can enter a durable retired
state if cleanup fails. Its uncertain artifacts and complete local copy remain untouched and
exportable. It no longer blocks the newest complete save. Retired records cannot publish or
return to an active state, including through a stale callback. M23 remains incomplete.

An empty Ordering.edit file makes M19/M20 refuse an outbox containing unfinished ordered saves.
It is removed only when ordered work is complete and no retired recovery remains. A new retired
state also makes older ordering-aware builds fail closed, rather than ignore a new flag and
publish the old save. Old-format saves remain readable; differing
contents with no known order remain blocked and exportable. Missing ordering evidence fails
closed. This guard is required because older writers would otherwise ignore arrival order.
It adds no Settings or catalog format change and preserves locations, IDs and keeps.

The app retains a new generation before resolving earlier publications of the same item.
Pending renames and foreign publications remain excluded. Share recovery now schedules edit
retry explicitly. The provider's existing upload pipeline depth of one remains; signed checks
must establish that replayed callbacks carry current contents.

A replay after private staging has started now prepares a fresh generation from the callback's
complete contents. The previous attempt is cleaned up with full evidence or retained as retired.
This avoids retrying the same incomplete stage indefinitely. A publication that may already
have changed the original still follows recovery before any successor can publish.

## Signed interrupted-save recovery

A signed baseline app stopped after recording ownership of a private stage, before writing its
bytes. The original server file stayed unchanged. After restarting the app, another TextEdit
save did not advance past that empty stage. Export Local Copy returned the complete first save.

Installing the corrected signed candidate over this pending state let the later TextEdit save
reach the original server file. The old stage remained empty and untouched. The app showed
"Older save kept for recovery. It will not upload. Newer saves can continue." Export Local Copy
still returned the first save byte for byte. After an app restart, an app-owned audit found one
retired first save and one completed latest save. The server bytes matched the latest save.

Setup: macOS VM 1, disposable loopback Samba fixture, one synthetic text document, TextEdit,
uncontrolled cache state. The stop and audit hooks exist only in isolated test archives.
Evidence is in .local/phase4/m21-20261029: m23-before-current.json, m23-update-recovery.json,
m23-after-audit.json and the before/after exported copies. This is update-recovery evidence,
not a matched before/after recording or a disconnected editing check. It does not establish
callback currency for every retry or editor. Slow fixture authentication and temporary
Unresponsive status remain observed limitations.

The stage's initial access permissions also prevented the fixture cleanup helper from reopening
it. After both exports and the final server contents were saved as evidence, fixture cleanup
removed that known empty stage through the backing directory. This does not add a production
cleanup route or authorize deleting uncertain user artifacts.

## Interrupted local preparation

Retry now examines saves left in preparing before it chooses the next publication. A missing or
short local payload can be removed only when its durable records show that staging never reached
the server. Complete bytes are verified and flushed, then recovered to prepared with their saved
metadata. A complete copy with inconsistent metadata, an orphan payload, or evidence of a later
state remains pending. UploadOutbox owns removal and syncs payload deletion before removing its
receipt, so interrupted cleanup can resume without losing the evidence for a surviving payload.

Matching callbacks reuse an already complete staged copy. This also protects ordinary uploads
from replacing their complete copy after a lost state update. Focused regressions cover low
space, a lost state update, interrupted cleanup, earlier complete copies, metadata uncertainty
and release of the older-build guard. Required VM checks pass on the integrated source:
356 tests, one optional skip, no failures or Swift warnings, and six encoder cases. Evidence is
in m23-preparing-checks.log. Recovery runs on retry or ordering evaluation; it does not claim
that every failed Save was accepted.

## Retained recovery cleanup and status

Retry Pending Changes now attempts retired-save cleanup after pending publications. Automatic
reconnect retry leaves retained recovery data alone. Cleanup requires a proved successor and
checks every remaining temporary file before removing any. Each file must match its recorded
identity and complete expected contents. Partial, changed, unowned or absent artifacts remain
unresolved with the local copy retained. Ordinary supersession also refuses missing artifacts.

Cleanup persists complete evidence before deletion, then records each acknowledged removal.
A retry never revisits an acknowledged removed name, even if another file now occupies it.
A lost removal reply remains unconfirmed. A final durable checkpoint allows interrupted local
payload removal to resume. Legacy retired saves need an active ordered successor because a
completed receipt alone cannot establish their relative order.

The location pane separates waiting, conflict and recovery states and reports local payload
bytes, including orphan payloads. The existing free-space policy remains: reserve 2 GiB and
the space needed to stage new work, then refuse new saves before deleting retained contents.
No separate quota or automatic pruning is added. Dismiss Notice hides only completed conflict
notices with no retained recovery; the publication receipt remains available for replay.

These changes pass Tools/run-checks.sh in macOS VM 1: 373 tests, one optional skip, no failures
or Swift warnings, project generation, release CLI checks, unsigned app build and six encoder
cases. Evidence is m23-cleanup-checks.log in the same session. Signed cleanup and recovery status
are checked below; storage admission remains.

## Completed-publication cleanup follow-up

Implemented on 2026-10-30; required VM checks pass. Completed publications now retain cleanup
progress separately from their save receipt. Missing or changed artifacts and lost removal
replies keep the local recovery copy. A durable acknowledgement prevents retry from deleting
a new occupant at a previously cleaned name. Once all removals are acknowledged, a local
checkpoint permits payload removal to resume without contacting the server.

The new cleaningUp state makes earlier builds, including the earlier M23 implementation,
refuse these records. Ordering.edit alone is insufficient because earlier M23 builds already
skip that guard. Completion returns to the readable completed state; old completed records
without retained recovery stay unchanged. No Settings or catalog format changes are needed.
Callbacks and successor saves treat cleaningUp as a proved publication, while Settings says
that the file is saved on the server and recovery files still need attention.

The SMB adapter also closes its upload verifier and reacquires exclusive artifact protection
before cleanup, then checks the recorded complete version again. Otherwise its own remaining
reader could defer removal beyond the delete handle's close reply. An absent artifact now
fails cleanup. Tools/run-checks.sh passes in macOS VM 1: 404 tests, one optional skip, no failures
or Swift warnings, project generation, release CLI validation, unsigned app build and six
encoder cases. Evidence is m23-completed-cleanup-checks.log. The signed ordinary-save check below
exercises this handle behavior on the fixture; lost cleanup replies remain unit-test evidence.

## Signed cleanup comparison, 2026-10-30

On the same retained-save state, the older signed build exported the first save but left its
temporary file and recovery notice after Retry. The new signed build exported identical bytes,
then Retry removed the verified temporary file and recovery entry. The latest server document's
complete bytes and identity stayed unchanged. An app restart preserved its item ID, content
version and explicit keep, with zero pending saves.

The setup first interrupted an upload after creating its private stage, before writing bytes.
A newer TextEdit save reached the original while the older local copy and empty stage remained.
The experiment then filled that same stage with the exact first-save bytes after checking its
identity. This simulates late stage completion; it is not evidence that a disconnected SMB
upload completed. Both builds used this completed stage for the matched Export/Retry workflow.

A further ordinary TextEdit save through the new build reached the same server object and
finished with no stage or backup left. Its receipt was completed without retained recovery.
After restart, the item ID and explicit keep survived, the content version changed, and pending
saves remained zero. This exercises cleanup in the upload session, including closing the
upload verifier before reacquiring exclusive artifact protection.

Setup: macOS VM 1, macOS 27.0.1, disposable loopback Samba fixture, one synthetic text document,
uncontrolled cache state. Production source passed the 404-test check above; signed test archives
add only isolated stop and audit hooks, with unchanged entitlements. No performance claim.
Evidence in .local/phase4/m21-20261029: m23-cleanup-before-result.json,
m23-cleanup-after-result.json, m23-cleanup-stage-completed.json,
m23-cleanup-after-audit-log.jsonl, m23-cleanup-ordinary-save-result.json and
m23-cleanup-ordinary-save-log.jsonl. Both exported copies are retained there. Matched 90-second
screen sequences, 82 frames each, are in host results/m23-cleanup-20261030/{before,after}-frames.
This does not establish low-space admission, stale callback delivery, lost cleanup replies,
or offline editing, and does not complete M23.

## Verification and remaining work

Tools/run-checks.sh passes on the integrated source including retirement: 336 tests, one optional native-fixture skip,
zero failures, project generation, release CLI validation, unsigned app build and six rename
encoding cases. There are no Swift warnings. The first run found two test assertion mistakes:
an expected missing record went through XCTUnwrap, which records a failure even when its error
is caught. Direct absence assertions fix those tests. Evidence is in the same VM session's
save-order-run-checks.log and save-order-run-checks-02.log. The retirement change passes in
retirement-run-checks-01.log, including retained partial stages/backups, continued later saves,
restart/export, downgrade refusal and refusal to bypass an uncertain original write. Source
review found no blocking issue. Retired records still block share-wide organization and
location lifecycle changes until their recovery is resolved.

The final integrated M21/M23 candidate passes 346 tests with one optional skip, no failures or
Swift warnings, and all required checks, including six encoder cases. Evidence:
m21-final-checks-01.log. Its personalized app build also passes in m21-final-build.log.

Complete interrupted-upload recovery within the accepted retention policy.
Verify cleanup, storage admission and the distinct waiting/conflict/recovery states. Complete
signed repeated-save and interruption tests and matched recordings before calling M23 complete. No physical-Mac
installation is authorized. The approved disposable VM session remains open.

Decision status: accepted on 2026-10-29. A superseded save proved never to have started original-file
publication may be durably marked never to publish, while its uncertain temporary files and
local copy remain visible and exportable. A newer save may then proceed with the normal
original-file protection. This replaces the requirement that every uncertain remote operation
resolve before any successor publishes. The core implementation and required checks pass;
the signed update-recovery check above passes. Merely missing
a stage identity would still never authorize deletion or imply that no remote request occurred.
