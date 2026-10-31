# Permanent-deletion protocol checks

Date: 2026-10-29. Within the approved M21–M26 disposable VM session.

The isolated deletion probe completed successfully, including eleven process-interruption
scenarios and guarded cleanup. It also confirmed a safety limitation: another SMB client can
add attached data while the main file is protected. The user accepted deletion of the whole
object, including data added during the operation, on 2026-10-29. M24 is not enabled.

The [signed production-adapter checks](#signed-adapter-continuation-2026-10-30) also pass on
2026-10-30 for ordinary files, empty directories, changed/replaced-file refusal and recovery.
Production operation storage, catalog updates, recursive deletion and Finder integration remain.

After a lost reply, absence cannot distinguish deletion from a move elsewhere. The probe
reports that state as absent, unconfirmed. This matches the roadmap's existing requirement
to preserve uncertainty; it is not evidence that the object was deleted.

## Setup

macOS VM 1 ran macOS 27.0.1 and the approved loopback-only Samba fixture. The C helper includes
the existing publication probe and adds complete paginated listing and exact-status capture.
The Python runner accepts only the fixed disposable endpoint and backing/mount paths. All
objects are synthetic, within one random subtree, and file payloads are 65,792 bytes. Cache
states were uncontrolled; no performance is claimed. The original NAS remained read-only.

The helper compiled and the Python syntax check passed in the VM. Runtime evidence is in
.local/phase4/m21-20261029/deletion-01, including result.json, the object ledger, neighbor
snapshots and per-interruption receipts. Compilation and execution logs are beside it.

## Observations

| Operation | Result |
| --- | --- |
| File and empty-folder deletion | Protected identity/content checks passed. The name and recorded identity disappeared only after completion. File streams disappeared too; recreating the name did not inherit them. |
| Competing access | SMB read/write/delete opens returned sharing_violation. Native unlink, rename and rmdir returned EBUSY after the object was proved visible. |
| Existing handles | Each incompatible reader, writer and deleter blocked protected deletion. With a deliberately shared reader, the name remained delete_pending after the deleting handle closed, until the last reader closed. |
| Changed/replaced file | Changed complete contents and an identical-byte replacement were refused; both retained objects remained provable. |
| Read-only file | The attribute was set successfully. Delete returned cannot_delete and preserved the file. |
| Arriving child | SMB child creation succeeded both before the delete mark and after it. The mark or close returned directory_not_empty; folder and arriving child survived. |
| Populated folder | The server refused with directory_not_empty and preserved the complete tree. This is not recursive-deletion evidence. |
| Parent replacement | The held parent blocked rename. A later replacement was detected without deleting its occupant. |
| Untouched neighbors | Complete bytes, attached stream, permissions, owner, mode and identity matched the baseline. Complete folder listings matched the ledger. |

The eleven interruption cases killed only probe processes. File/folder crashes before the
delete request allowed a freshly proved retry. Crashes after marking or closing returned
absent, unconfirmed. Competitor rename within the parent, rename elsewhere, replacement,
changed bytes and changed streams produced the expected distinct recovery outcomes. No retry
deleted a replacement or changed object.

DELETE_PENDING mapped to ENOENT in the errno adapter. Production deletion recovery must retain
the exact SMB status, because treating that error as an absent object would be wrong.

## Attached-data decision

The competing client successfully added a named stream while the deny-all main-file handle
was held. The guard observed the stream and the probe preserved it. A further stream change
after a final check would still be possible, so another read cannot close this race.

Decision status: accepted on 2026-10-29. Permanent Delete removes the selected object and all its attached
data at deletion time, including attached data added during the operation. The main contents
still require protected complete-content verification, and in-use files still refuse deletion.
App deletion is not implemented. Without that boundary, the current transport cannot prove the full
concurrent-attached-data guarantee.

## Cleanup and remaining work

The probe removed 51 proved synthetic objects and found four interruption targets already
absent. Cleanup completed with no retained objects from this run. This does not mean the
whole fixture session is closed: its server, credential and dependencies remain for the
approved work, and final restoration is still owed. No Apple sharing/account settings, shared
daemons, VM power state or network settings changed.

The integrated source's required checks already pass with 332 tests, one optional skip and
no Swift warnings. These two probe files add no production capability and need no project
generation. Signed Finder deletion, warning/callback semantics, recursive deletion, runtime
identity admission and exact-status production wiring remain unverified. No installation,
publication or original-NAS write occurred.

## Transaction core, 2026-10-30

A one-object deletion core now models the protected request and its recovery checkpoints.
It reloads durable state on every call and requires identity, complete main-file contents,
the exact name and a complete parent listing before marking deletion. Empty directories also
require a complete empty listing. Changed attached data follows the accepted whole-object policy.

A successful close reply must be durably recorded before later absence can confirm deletion.
Without that acknowledgement, absence remains unconfirmed. Once close is acknowledged, retries
only verify the outcome; they never issue another deletion. A replacement, changed contents,
changed parents or movement to another name prevents automatic retry. Every persistence failure
stops the current call, including failures after the durable write may have succeeded.

The core accepts caller-supplied evidence, a remote interface and atomic persistence callbacks.
It adds no disk format, adapter, catalog mutation or File Provider capability. Endpoint binding,
root and pending-write exclusions, older-reader refusal, recursive progress and UI remain
integration work. On 2026-10-30 the user extended current-name selection to unverified-file
deletion: known details must match, and the admitted object must be protected and verified.
Previously verified files retain historical checks. Recovery never targets a later replacement.

Twenty-seven simulated-remote tests cover request/close/checkpoint interruption, stale callers,
changed or replaced objects, incomplete listings, exact absence classification and arriving
children. Source review found no blocking defect. Tools/run-checks.sh passes on the integrated
source in macOS VM 1: 441 tests, one optional skip, no failures or Swift warnings, project
generation, release CLI validation, unsigned app build and six encoder cases. Evidence:
.local/phase4/m21-20261029/m24-core-checks.log. These are simulated-remote tests, not signed
deletion or SMB adapter evidence; M24 remains incomplete.

## Exact server errors, 2026-10-30

The production SMB client now exposes the exact status from its last failed server reply.
Every operation clears the previous status, including local validation failures and successful
cleanup closes. Transport failures and synthetic timeout/shutdown callbacks provide no server
evidence. Swift copies the status into the error before cleanup; existing filesystem error
codes and collision handling stay unchanged. Failed information queries also stop interpreting
the server's error payload as a successful data reply.

A standalone regression uses the real request encoders and deterministic callbacks without
opening a connection. It covers distinct absence and pending-delete replies, cleanup, local
errors, malformed successful replies and teardown callbacks. All 57 cases pass in VM 1.
The required checks also pass: 441 tests, one optional skip, no failures or Swift warnings,
project generation, release CLI validation, unsigned app build and six encoder cases.
Evidence: .local/phase4/m21-20261029/m24-status-checks.log. The callback tests establish error
classification in the adapter; they do not establish live deletion behavior. This adds no
deletion capability.

## Production adapter preparation

The Swift adapter now implements the one-object deletion contract without exposing a File
Provider capability. A fresh session protects the parent chain and holds the selected file
or empty directory with deny-all sharing. File evidence uses a complete digest and requires
one link. Listings continue through every page. Only an exact name-not-found reply supplies
name absence; delete-pending, path-not-found and transport errors remain distinct.

Deletion and close use the same target handle. Confirmation opens the name afresh after the
acknowledged close. The session retains no stream or native handles on the target. Review found
no unsafe-deletion defect under the fresh-session contract. It also found character-based path
splitting in the shared parent helpers; these now use the existing byte-safe path components,
so a leading combining mark cannot hide a parent separator. Required VM checks pass: 472 tests,
one optional skip, no failures or Swift warnings, project generation, release CLI validation,
unsigned app build, six encoder cases and 57 status cases. Evidence:
.local/phase4/m21-20261029/m24-adapter-checks.log. Initial live adapter results follow below. Durable
operation storage, catalog mutation and the user-facing deletion flow remain unimplemented.

## Signed adapter attempt, 2026-10-30

Two regular-file deletions passed in the signed, sandboxed app in macOS VM 1. Both recorded
an acknowledged close, then confirmed name and identity absence with fresh protected checks.
The run stopped during connection setup for the next case. Empty-folder deletion, paginated
confirmation, changed/replaced-file refusal and interruption recovery were unverified at that
point. The continuation below completed them. No File Provider deletion capability is enabled.

Setup admitted nine targets in a new synthetic subtree. The large directory's complete listing
contained 513 entries with at least 127,086 encoded bytes, exceeding one SMB listing buffer.
Before the run, a controlled in-place write retained one file's identity, and an identical-byte
replacement received a different identity. Its original was retained separately. Cache state
was uncontrolled; this is a correctness check, with no performance claim.

The first setup failed after one admission. A fresh setup passed after its reports were retained
and all 522 fixture files were checked unchanged. The deletion run then completed its first two
cases before another failure. In both failures, logs show a cached credential followed by
`smb_connect result=-1`, surfaced as `NSPOSIXErrorDomain:1`. This locates the failure in connection
setup; it does not establish the underlying cause. The seven remaining intents stayed prepared.

An isolated continuation helper compiles without Swift diagnostics and passes strict signature
verification in the VM with the same sandbox entitlements. It requires the two successful case
reports and the other seven original intents before continuing. It allows at most three
connection attempts, records failures and never retries the deletion body in that loop.
Automatic approval review blocked replacing and registering the VM test app, treating it as
an installation change outside the fixture-session approval. The user subsequently approved
that VM-only update, allowing the continuation below. Production transport and deletion code
are unchanged.

Private evidence in `.local/phase4/m21-20261029` includes `m24-adapter-setup.jsonl`,
`m24-adapter-setup2.jsonl`, `m24-adapter-run.jsonl`, the Finder-copied `m24-adapter-*-inspection`
directories, `m24-adapter-between.json`, `m24-continuation-build.log` and
`m24-continuation-verification.json`. The failed reports and original test app remain intact.
The fixture session remains open; final removal and restoration are still owed.

## Signed adapter continuation, 2026-10-30

All remaining adapter cases passed after the approved test-app update in macOS VM 1. The
continuation, recovery and final audit ran in separate app processes with unchanged sandbox
entitlements. They used the same nine admitted targets and 64 KiB file payloads from the first
attempt. Cache state was uncontrolled; these results make no performance claim.

| Case | Observed result |
| --- | --- |
| Empty directory | Protected empty listing, delete request, acknowledged close and fresh absence checks passed. |
| File in a large directory | Complete parent listings contained 513 entries before deletion and 512 after. Both exceeded one 64 KiB listing buffer; all surviving identities matched the admission listing. |
| Changed file and identical-byte replacement | Both were refused before any delete request. The changed file, replacement and retained original survived. |
| Stop after durable intent, before delete request | The fresh process proved the target again, deleted it and confirmed completion. |
| Stop after durable close acknowledgement | Recovery confirmed deletion without sending another delete or close request. |
| Simulated lost close reply | Recovery recorded `absentUnconfirmed`, without sending another delete or close request. |

The final audit retained the earlier two successful file-deletion results. The untouched
neighbor's identity and complete contents matched admission. A separate backing-folder check
matched all 517 surviving files and their complete bytes, with no unexpected files or folders.
Connection setup failed once in recovery and once in the audit; each succeeded on the helper's
next attempt. The helper retried only connection setup, never a deletion body. The underlying
connection failure remains unexplained.

The interruption points use injected errors and a simulated lost reply, followed by real app
process exits between phases. They do not establish behavior during an actual app crash or
network reply loss. These checks exercise the production adapter and transaction with private
test journals. Production operation storage, catalog removal, recursive deletion and Finder's
warning/callback behavior remain unimplemented or unverified; M24 stays disabled.

Evidence in `.local/phase4/m21-20261029` includes `m24-adapter-final-inspection/M24Adapter`,
`m24-adapter-{finish,resume,audit}.jsonl`, `m24-continuation-results.json` and
`m24-adapter-final-backing.json`. After verification, the previous test app and extension
registration were restored, both builds and all reports were retained, and only the M24
synthetic subtree was removed. `m24-test-app-restored.json` and `m24-adapter-cleanup.json`
record that cleanup. The broader approved fixture session remains open for other checks;
its final removal and SMB-service restoration are still owed. The physical Mac was unchanged.

## Durable recursive core, 2026-10-30

The integrated deletion outbox and recursive transaction compile and pass all 22 new tests in
macOS VM 1. The complete required checks also pass with 520 tests, one optional skip, the release
CLI checks, the generated project, an unsigned app build without Swift warnings, six encoder
cases and 57 SMB-status cases. Evidence is in `m24-core-tests.log` and `m24-core-checks.log`
under the private session directory. These tests use temporary local storage and a simulated
server. They make no SMB runtime or performance claim; cache state was uncontrolled.

The outbox stores an immutable admitted tree and durable per-node progress. The tests cover
child-before-parent processing, arriving and changed children, replacement objects, interrupted
checkpoints, lost close replies, stop, replay, overlapping views and malformed storage. Each
recursive node invokes the existing one-object transaction in a fresh simulated session.

App traversal, catalog settlement, lifecycle and recovery controls remain to be connected.
Compatibility guard paths still default to empty; the app's current readers do not yet recognize
deletion guards. The guard tests simulate older decoders, not real older app builds. Independent
source review is pending. No app caller can start a durable recursive deletion, and no Finder
Delete capability is enabled. Signed recursive SMB and Finder checks remain required.

The subsequent source review found that pre-delete presence evidence could hide uncertainty
after a successful mark, and that removing a secondary location discarded the owner's replay
record. Both are fixed. Presence evidence expires after marking, and settled records remain
until their owner is removed. A process-wide storage lock also serializes guard publication
and reconciliation, and progress cannot carry an acknowledgement into the next node.

Six added regressions pass in VM 1, bringing deletion storage/recursive tests to 28 and the
complete suite to 526 with one optional skip. `Tools/run-checks.sh` passes with no Swift warnings,
including the app build, CLI, project, encoder and status checks. Evidence is
`m24-core-review-checks.log` in the same session directory. These fixes do not enable an app
caller or close the recursive SMB and Finder gates.

## Protected traversal preparation, 2026-10-30

The adapter now captures a complete deletion tree in one protected session, including children
absent from the catalog. It checks every supplied view's known details and retains stricter
identity, contents and mtime checks for previously verified files. Unsupported entries, packages,
repeated identities, multiple links and excess nodes refuse admission. A final listing pass
rejects arrivals observed before preparation. Exact server absence replies for a deletion's
ancestor now report `parentChanged`; other failures retain their existing classification.

Independent source review found no confirmed blocker. The caller must supply all affected views,
persist the plan while protection remains held, close the capture handles and destroy that SMB
session before opening node sessions. Reported reparse points are refused; links hidden by the
server as ordinary objects remain an unverified transport limit. The integrated source passes
`Tools/run-checks.sh` in VM 1: 526 tests, one optional skip, no Swift warnings, the app build,
release CLI, project, six encoder and 57 status cases. Evidence: `m24-traversal-checks.log` in
the same private session. Signed traversal behavior remains unverified; no production deletion
caller is connected.

## Inventory and downgrade-guard preparation, 2026-10-30

The app now supplies `Deletion.edit` and `Deletion.rename` guards to its deletion inventory.
Current readers skip only exact empty, single-link regular guard files. Namespace admission
reads the deletion inventory before permitting writes, and unreadable inventory fails closed.
Pending deletions block location changes and removal; removing a secondary view preserves the
owner's replay record. Launch reconciles guards before opening sources, including inactive and
retired domain IDs.

Independent source review found no concrete defect. The future caller must serialize admission,
check mutation suspension in every affected view and retain all configured roots as protected.
These changes pass all required VM checks with 528 tests, one optional skip and no Swift warnings.
Evidence is `m24-inventory-checks.log` in the same private session. Historical-reader behavior is
modeled in tests, not verified in older signed apps. No execution caller is enabled.

## Catalog settlement preparation, 2026-10-30

Deletion views now retain the catalog epoch, sequence and listing generation captured before
protected admission. Direct tombstones require that state to remain unchanged. Any intervening
change, missing prior result or unconfirmed outcome requires a fresh checked listing. The helper
starts those reads itself, rejects incomplete observations and climbs to a reachable ancestor
when a folder is absent. It retains the normal confirmation policy and never infers a confirmed
remote deletion from a listing.

Source review closed the earlier replacement-loss and premature-completion defects. A kind
mismatch now takes the reconciliation path. If a missing-folder fallback still finds the requested
folder live, it returns unresolved instead of repeatedly listing it. New tests cover both cases;
the integrated helper and all catalog regressions pass in VM 1. The first run required splitting
an expression that exceeded Swift's type-checking limit and correcting a replay test that rebuilt
a changed request. That test now retains the original request and checks that a new one stays blocked.

Catalog completion can preserve a replacement under the selected ID. The app must additionally
require an explicit tombstone for that ID before reporting provider Delete success, including on
completed replay. A live replacement must return a changed-version error. This preserves its
binding and keep flags without introducing a new identity policy. Signed File Provider behavior
remains a gate. The helper is not yet connected to an execution caller.

## Gated admission and execution, 2026-10-30

The app has an unconnected owner-lane entry point for protected admission, immutable replay,
per-node execution, resume and stop. Admission reserves the subtree, drains reads and watches,
then rechecks every affected source, pending write, configured root and catalog claim. The
capture client ends before node sessions begin. Each node runs outside the namespace lock;
the durable record blocks conflicting work while unrelated reads can proceed.

Completion additionally requires the owner's selected catalog row to exist and be tombstoned,
including on completed replay. A preserved replacement returns `versionChanged`; a missing row
remains unresolved. The owner-lane scheduler below connects catalog settlement, Settings cleanup
and lifecycle retry. Recovery controls and provider routing remain unconnected.

Settings has a typed path-removal helper for pending and saved keeps on the affected share.
Callers must supply only confirmed-deleted nodes. It preserves uncertain descendants, other kinds
at the same name and other shares; it does not remove an entire subtree from one folder outcome.
The helper and its persistence/refusal regressions pass in VM 1. All required checks pass with
557 tests, one optional skip and no Swift warnings (`m24-settings-fixed-checks.log`). The helper
is connected to deletion completion by the scheduler below; that wiring is not yet runtime-verified.

Source review found a lock inversion in the existing folder-move caller: it can hold the global
SMB mutex while waiting for the namespace lock, which deletion admission acquires first. That
is repaired by scoping folder-move clients inside the namespace lock and reopening protection
after Settings persistence. The integrated admission, catalog and lock repair pass all required
VM checks: 555 tests, one optional skip, no Swift warnings, release CLI, generated project, six
encoder cases, 57 edit-status cases and six folder-create status cases. Evidence is
`m24-admission-fixed-checks.log` in the same private session. Signed execution remains unverified;
Finder Delete remains disabled.

## App settlement bridge preparation, 2026-10-30

The app now has bounded owner-lane settlement passes over every affected catalog. Each pass
starts new native listings inside the catalog helper and confirms missing names on the same
mount. A retained attempt carries observations and the normal 15-second confirmation holds;
after restart, a new attempt recollects the evidence. The caller schedules returned delays
outside locks instead of waiting inside a namespace or catalog lock.

Completion is separate from reconciliation so confirmed-node keep cleanup can be saved in
Settings without either lock held. It then revalidates roots, endpoints and all catalog
obligations before finishing domains. No bridge result alone authorizes provider success.
The bridge compiles and passes all required VM checks with 557 tests, one optional skip and no
Swift warnings (`m24-settlement-bridge-fixed-checks.log`). Its first app build required qualifying
the descriptor close as `Darwin.close`. Independent source review found that same compile issue
and no logic blocker in the bridge. The caller must reload after
errors, discard observations after a remount, preserve confirmation delays outside locks and
signal every affected view after completion. Participant accounts, roots and initial naming must
be valid before admission; settlement cannot repair a mismatched participant set.
Freshness of the native mount's directory cache remains a signed-runtime gate.

## Owner-lane recovery preparation, 2026-10-30

The scheduler now retains settlement attempts across delayed passes and awaits Settings cleanup
outside the lane and locks. Catalog and Settings failures get three bounded retries; another
remote attempt requires explicit Retry or request replay. Launch and share recovery now settle
only records whose remote work has ended. New provider Delete requests remain disconnected,
so no deletion capability is enabled.

Admission and resume validate every participant's account, mount and configured root. Settings
cleanup rechecks the durable record and current locations, waits for older Keep Downloaded
restoration to finish, and removes only paths whose recorded outcome confirms deletion. Domain
completion follows the bridge's fresh revalidation. A live selected replacement still returns a
changed-version error. Stop cancels active progress before queuing its durable checkpoint;
Dismiss follows the core's uncertainty policy. These APIs are not yet exposed in recovery UI.

The integrated scheduler and Settings callback pass all required VM checks: 557 tests, one optional
skip, no Swift warnings, release CLI validation, project generation, six encoder cases, 57
edit-status cases and six creation-status cases. The first app build required explicit `self`
captures in the delayed-pass closure. Both logs remain in the private session as
`m24-scheduler-checks.log` and `m24-scheduler-fixed-checks.log`.

Source review found that the original launch/reconnect hook could resume a cancelled deletion.
The repair restricts automatic recovery to settlement and observes primary and joined request
cancellation without replacing their Progress handlers. Cancellation queues durable Stop; counted
Stop requests retain replies until the queued checkpoints run. Failed Stop reloads durable state,
unchanged settlement attempts retain their confirmation holds, and failure also signals committed
catalog changes. Storage failure can still prevent durable Stop. Closed sources defer settlement
until reopened. The repair passes all required VM checks with 557 tests, one optional skip and
no Swift warnings (`m24-cancellation-checks.log`). Independent source review found no false
success, lost reply or automatic remote retry after cancellation. Follow-up changes retry
settlement when pending Keep restoration ends and read Progress cancellation outside the recovery
lock. Closing a source does not create a new Stop, but already queued Stops still persist.
The follow-up changes pass all required VM checks with 565 tests, one optional skip, zero failures
and no Swift warnings (`m24-review-followups-fixed-checks.log`). Release CLI, generated-project
equality and all encoder/status checks also pass. Runtime cancellation and callback races remain
unverified.

The bounded recursive runtime helper now uses production admission and the asynchronous scheduler
with private Settings. Its separate phases cover refusals, overlapping views, an injected lost
close reply, restart, competing server changes and replacement preservation. The first signed
refusal phase stopped with `serverUnreachable` after a slow expected refusal, before its next
synthetic replacement. Its 61.7-second failed run is preserved; no deletion phase ran. The helper
now waits off the lane for normal share-health recovery between steps. The backing audit found
no added or removed entries and only the two intentional content changes, which also acquired
Samba DOS and quarantine attributes. The revised audit allows only those additions on deliberate
native writes; neighbors still require exact metadata equality. This is failed-run evidence,
not a recursive-deletion pass.
An independent Finder copy confirms that original Settings remains byte-identical to the saved
baseline. The failed report, process output, exact attribute differences and partial backing audit
remain in the private session under `m24-recursive-5262C027-B5BB-458E-80CD-571EB4549CC7*`.

A second signed refusal run waited 0.29 seconds for normal health recovery, then stopped at the
helper's native exclusive-rename setup. It exited after 61.8 seconds with no added, removed or
moved entries. That setup used an operation already found unsupported by the native SMB mount;
the assertion did not retain its errno. The helper now uses the existing protected SMB
no-replace rename, verifies the moved object's identity and contents, closes its session, then
creates the identical-byte occupant exclusively. The failed run remains under
`m24-recursive-AB759313-41B0-4CA5-B0EA-8A95A5678E53*`; it is not a deletion pass.
A third run verified the protected move, then failed with native ENOENT before creating its
replacement. The backing audit found the original intact under its held name, with one added
Samba DOS attribute. The helper now refreshes both native parent listings before opening the
moved file, matching production move verification. Its audit permits that single attribute
addition only on the deliberately moved fixture file. The failed report and exact differences
remain under `m24-recursive-6445276F-23DB-469D-9EAC-9F722F3EAC8C*`.
Delayed confirmation, cancellation, remounts and callback races remain unverified; these source
changes do not complete M24.

## Partial signed recursive run, 2026-10-30

The fourth run passed refusals, populated-tree deletion in two overlapping views, injected lost
close reply and restart recovery. The competing-change case reached complete catalog settlement
with all eight expected outcomes, then failed its separate native file-identity assertion. It is
not a full case pass; replay and the same-name replacement case have not run.

This used the same approved loopback Samba fixture in VM 1, macOS 27.0.1 (26A434), with
uncontrolled caches. The signed standalone helper was not installed. Its build had no Swift
warnings, and strict signature and unchanged-entitlement checks passed. Evidence remains under
`m24-recursive-3CFEE81C-6483-4499-B311-EA4901FAA7C9*` in the private session.

| Phase | Process time | Result with independent backing audit |
| --- | ---: | --- |
| Refuse | 187.8 s | Eight expected refusals; no deletion records; neighbors unchanged |
| Delete | 101.0 s | Four confirmed deletions; both views complete; keep cleanup and replay passed |
| Interrupt | 60.5 s | Child deleted; selected folder close reply lost after the real close |
| Recover | 20.3 s | Complete catalog settlement; selected outcome remains unconfirmed; guards retained |
| Admit | 20.4 s | Eight-node immutable plan persisted without deletion |
| Compete | 141.1 s | Failed native identity assertion after remote execution and catalog settlement |

The failed compete report did not identify which of three file reads disagreed. A later native
read and a copied catalog both showed the expected replacement identity. The backing audit found
exactly the two expected removals, with the moved subtree, changed file, replacement and new
arrival preserved. A stale pathname lookup is a possible cause, not an established diagnosis.
The helper now obtains identity from an opened descriptor, retains the comparison against a
second opened descriptor, and identifies each check and its numeric stat evidence separately.
The failed run will not be resumed. Original Settings was independently copied through Finder
and remains byte-identical to the saved baseline.

