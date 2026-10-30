# Pending-save ordering

Date: 2026-10-29. M23 implementation in progress; not a completed milestone.

The baseline VM regression reproduced an older save publishing while a newer complete local
save was waiting. The ordering fix passes the required VM checks, including the same regression.
Signed workflows, the storage bound and recovery interface are still incomplete.

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
location lifecycle changes; an evidence-based recovery-cleanup action remains to be implemented.

Complete interrupted-upload recovery within the accepted retention policy.
Complete bounded storage, distinct waiting/conflict/recovery states, signed repeated-save and
interruption tests, and matched recordings before calling M23 complete. No physical-Mac
installation is authorized. The approved disposable VM session remains open.

Decision status: accepted on 2026-10-29. A superseded save proved never to have started original-file
publication may be durably marked never to publish, while its uncertain temporary files and
local copy remain visible and exportable. A newer save may then proceed with the normal
original-file protection. This replaces the requirement that every uncertain remote operation
resolve before any successor publishes. The core implementation and required checks pass;
the signed workflow remains unverified. Merely missing
a stage identity would still never authorize deletion or imply that no remote request occurred.
