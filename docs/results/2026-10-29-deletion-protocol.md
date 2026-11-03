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

Source review found an early native absence check in the separate cancellation helper. Its
uncertain phase now defers that check to the backing audit; the next phase tests production
reconciliation. It also checks exact Settings callback counts and drained recovery state.
Compilation and signed cancellation evidence remain pending.

The fifth run repeated the first five passing phases, then failed at the replacement's native
read after 141.1 seconds. Its first open reported the original inode; a second open reported the
replacement inode. The backing audit identifies both values and confirms the complete expected
final layout, bytes and metadata. Original Settings remains byte-identical. Evidence is retained
under `m24-recursive-84AAA845-0AEC-4B43-B2EB-D3514365B668*`; neither later phase ran.

The helper now pins replacement reads to the catalog identity captured after completed
settlement, requires that identity to differ from the admitted original, and allows at most
three read-only opens with 0.25-second pauses outside sessions. Every mismatch is recorded and
the pin never changes. This checks eventual native read consistency; it does not establish
immediate native consistency or alter the production settlement gate. A final native read must
still match that identity and the complete expected bytes, followed by the independent backing
audit. Reports now also replace the pre-settlement summary with the completed record.

## Signed recursive checks, 2026-10-30

All eight phases passed with successful process exit and independent backing audits in run
`2503A259-BB74-4B98-966E-C9C6F9833A6B`. This used the same VM, loopback fixture and uncontrolled
caches described above. The standalone `m24-recursive6` helper built with zero Swift warnings,
passed strict signature and entitlement-equality checks, and was not installed. Original Settings
remains byte-identical after an independent Finder copy.

| Case | Verified result |
| --- | --- |
| Refusals | Eight expected refusals, with no deletion plan and unchanged neighbors |
| Populated tree | Four confirmed deletions; both overlapping views complete; keeps cleaned; replay unchanged |
| Lost close reply | Restart completes catalog settlement but keeps the selected outcome unconfirmed and retains guards |
| Competing changes | All eight expected outcomes; moved subtree, changed file, replacement and arrival survive; replay unchanged |
| Same-name replacement | Completed settlement retains the live selected ID; completion and replay return `versionChanged`; replay makes no Settings call |

The competing-change phase took 141.4 seconds. Its first native replacement open reported the
old inode; the second matched the fixed settled-catalog identity and complete expected bytes.
The final replacement case needed no observation retry. These results establish the bounded
native observation described above, not immediate cache consistency. The full reports, process
records, backing audits and source archive remain in the private session under
`m24-recursive-2503A259-BB74-4B98-966E-C9C6F9833A6B*` and `m24-recursive6-*`.

The first signed cancellation attempt stopped before admission after 0.4 seconds. Its generic
change callback also receives admission's parent-listing notifications and tried to inspect a
deletion record too early. The fixture inventory is unchanged. The helper now waits for the
scheduler to register the request's Progress before forcing cancellation or close, and reports
an early request failure without waiting for the admission watchdog. The failed report remains
under `m24-cancellation-E48A3264-F023-4C1B-8FCA-4ABBEC93798E*`.

Cancellation, delayed confirmation, remounts, actual controller Settings persistence, recovery
controls, File Provider callbacks and real crash/network-loss checks remain open. These checks
do not enable Finder Delete or complete M24.

## Signed cancellation and settlement recovery, 2026-10-30

All seven phases passed with independent backing audits in run
`C1B34BF5-38CF-4F4B-8121-CF679E9406BA`. The corrected standalone `m24-cancel-probe2` helper
built with zero Swift warnings and passed strict signature and unchanged-entitlement checks.
It used the same approved VM fixture with uncontrolled caches and was not installed. An
independent Finder copy confirms that original Settings remains byte-identical.

- Cancellation after durable admission stopped every node before deletion and returned cancelled.
- Cancelling a joined request while Settings was suspended delivered both replies once, after
  confirmed deletion and completed settlement. It made one Settings call and write.
- Closing the source after admission left the plan unsettled and created no token-driven Stop.
- Automatic recovery left that unsettled plan alone. Two explicit Stops survived closure with
  observed counts of 2, 1 and 0; both replies arrived once.
- Reopening completed the stopped record's catalog and Settings work. Replay remained cancelled
  and made no new Settings call.
- An injected lost close reply followed by Stop retained uncertainty. A later process completed
  catalog settlement while preserving the unconfirmed outcome, saved keep and guard. Replay
  remained unresolved.

Every phase checked exact reply and Settings counts after a two-second observation window,
drained recovery state, unchanged foreign records, catalog outcomes, keeps and guards. The
uncertain phase deferred native absence to the independent backing audit; the following phase
checked it after production reconciliation. Raw reports and audits remain under
`m24-cancellation-C1B34BF5-38CF-4F4B-8121-CF679E9406BA*`, with build/signing evidence under
`m24-cancel-probe2-*` in the private session.

These are forced orderings, not exhaustive race coverage. Cancellation inside an active protected
node, the KVO/completion race, closure during delayed Settings, explicit unsettled Retry, Dismiss,
controller lifecycle callbacks, remounts and real storage/network failures remain unverified.
The helper uses private Settings, so it does not validate the controller's actual persistence
callback. Recovery controls and provider routing remain disabled.

## Final validation and service restoration, 2026-10-30

After integrating the recursive, cancellation and folder-gap probe fixes, `Tools/run-checks.sh`
passed in macOS VM 1: 565 tests, one optional fixture skip, no failures or Swift warnings, the
release CLI checks, generated-project equality, the unsigned app build, six SET_INFO encoder
cases, 57 SMB-status cases and six folder-create status cases. The VM checkout remained clean.
Evidence: `m24-recursive-cancellation-gap-checks.log` in the same private session directory.
The final documentation update did not change code or test inputs.

The active fixture session has ended. Its mount was released normally and the exact task-owned
Samba process tree stopped. Apple `com.apple.smbd` was restored to its saved loaded, inactive
state with its enable override unchanged. The backing root retained its device and inode.
`session-release-mount.json` and `session-smb-restoration.json` record these steps. The installed
app remains restored and stopped; the independent Settings comparisons after the runtime runs
remain byte-identical. No installation, push or publication occurred during this continuation.

Artifact disposal is not complete. The backing fixtures, uncertain creation/deletion records,
synthetic catalogs, private credentials, helper builds and reports remain for investigation.
No uncertain record was dismissed or removed to clear a guard. Reopening writable runtime work
requires fresh session approval. M22, M23 and M24 remain incomplete; the remaining signed
provider, lifecycle and recovery gates still apply.

## Review fixes, host validation, 2026-11-02

The two provider review defects and both smaller settlement findings are fixed in the gated
candidate. Busy deletion admission and full reader queues return a transient Cocoa error;
other pending-write refusals retain `cannotSynchronize`. Reader release and disconnection no
longer cancel deletion progress. Explicit provider cancellation and Settings Stop Deleting
retain durable Stop, while a completed stopped replay returns `deletionRejected`.
Incomplete records defer terminal refusals until every view finishes settlement. A surviving
unconfirmed selected item gets one metadata refresh after fresh reconciliation, preserving
its ID, content version and keeps. Its old callback still replays the unconfirmed outcome.

Validation used the arm64 host on macOS 27.0.1, build 26A434, with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. These were debug Swift package
checks with incremental build caches, local temporary storage and simulated deletion remotes.
No VM, app build, SMB fixture or physical-Mac installation was used. The first sandboxed test
attempt failed before compilation because the compiler cache was not writable; the permitted
package commands then ran with cache access.

`swift build` passed. `swift test` ran 589 tests with zero failures and one skip for the optional
writable SMB fixture. Neither completed command emitted warnings. Focused runs also passed:
45 busy/outbox/recovery tests, 28 cancellation/recursive tests, and 38 catalog/recovery tests.
Regression coverage includes blocked admission through partial domain settlement and restart,
stopped replay after dismissal, incomplete-record refusal mapping, and an unconfirmed survivor's
metadata refresh and unchanged replay. The app XPC and KVO paths received source review only.
No persisted format or generated-project change was needed.

Raw local logs are in `results/m24-review-findings-2026-11-02/`, ignored by Git.
Reproduce with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` and
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
The [integration checklist](../m24-integration-checklist.md) cites the SDK header and specifies
the remaining signed concurrency, timeout/disconnection, explicit Stop, survivor refresh and
partial-refusal checks. The coordinator must run those and `Tools/run-checks.sh` in the VM.
App compilation, Finder retry timing, item restoration and XPC lifecycle behavior remain
unverified. `SourceReaderBridge.deletionEnabled` remains false.

## Finder deletion and parent checkpoints, 2026-11-03

Signed Finder checks pass for the permanent warning, Cancel, verified and unopened files, and
an empty folder. Recursive deletion safely stopped after removing its two files because Samba
changed a parent directory's synthetic creation time. The protected-parent checkpoint repair
now passes signed nested-deletion and recovery checks described below. Normal deletion
capabilities stay disabled, and the single-client branch remains a VM-only experiment.

Setup: macOS VM 1, macOS 27.0.1, signed FolderCheck builds 26–29, with Samba 4.19.5 on ext4 in
TinyMounter Samba Test. Both registered views use the approved disposable November 3 fixture.
These were correctness checks with existing catalog/mount caches; server caches were not reset.
The verified file was downloaded and kept, the unopened file remained dataless, and the nested
tree was unlisted before admission. Independent Linux inventories checked remote objects.

With deletion disabled, Terminal unlink initially removed the local file but left the remote
object intact. Returning a bare `deletionRejected` made macOS retry without restoring the file.
Build 28 uses `fileProviderErrorForRejectedDeletion(of:)` with the surviving catalog item.
Replay restored the file's complete contents, ID, versions and keep request; macOS recreated its
local inode. Six downloaded neighbors retained their inodes, digests, flags and sizes. One
corrected callback appeared, with no further retry during the approximately 88-second observation.
No deletion operation was admitted, and the Linux inventory retained all 34 fixture objects.
Terminal's temporary File Provider privacy permission was reset afterward.

The corrected deletion-enabled build 29 exposed Finder's **Move to Trash** command. It opened
this warning: “This item will be deleted immediately. You can’t undo this action.” Buttons were
**Cancel** and **Delete**. Cancel produced no deletion callback, durable operation or remote
mutation. Confirmed deletion removed the verified file, the unopened file and an empty folder,
settled both catalogs, and cleared the confirmed file's keep. No retention copy was created.
Existing Finder capabilities needed a metadata refresh after the test update; this procedure
is not evidence that normal capability rollout is handled.

Deleting the nested tree sent one recursive callback and admitted four nodes. Both files were
removed; the nested folder was reported replaced and the selected tree remained nonempty.
Linux retained both original directory inodes and all unrelated objects. The completed partial
operation remains unchanged, including its two exceptions. The failed final-audit assertion is
not a pass; the subsequent partial audit confirms exactly five removed objects across the basic
checks and 29 remaining objects.

The repair reads and re-queries parent identities through their still-protected handles after
confirmed child absence. It atomically records those observations with child completion in
`DeletionProgress.parentUpdates`. Later nodes use these identities, including when selecting
a now-empty directory. The admitted plan and child list remain immutable. Stored observations
cannot retarget a parent, alter its server spelling, precede confirmed deletion or discard earlier
evidence. A new handle must still match the recorded identity exactly; losing protection before
checkpointing can retain an unconfirmed outcome and refuse later work.

Required VM checks on the refusal repair passed: 629 package tests, two optional skips, no
failures or Swift warnings, plus project, CLI, unsigned app and SMB encoder/status/crypto checks.
The parent-checkpoint repair then passed 72 focused host package tests with incremental build
caches and simulated remotes. Coverage includes restart, same-file-ID replacement, a lost
checkpoint, arriving children, malformed saved parents and equivalent client/server Unicode
spellings. Required checks subsequently passed in macOS VM 1 with 635 tests, two optional skips,
zero failures or Swift warnings, and all project, CLI, unsigned app and SMB checks. The signed
candidate adds fixture-bound stops before and after deletion checkpoints for recovery testing.

Private evidence is under `results/folder-single-20261103/` in macOS VM 1 and the matching Linux
fixture evidence directory. It includes `checks-deletion-refusal.log`, `repair/deletion-refusal-report.json`,
`check-deletion-*.json`, callback logs, disabled/enabled Finder recordings, and the Linux
`deletion-disabled-audit.json`, `deletion-cancelled-audit.json`, `deletion-verified-audit.json`
and `deletion-basic-partial-audit.json`. Host focused output is
`/private/tmp/tinymounter-deletion-parents-tests-03.log`. No screen recording remains active.

### Signed parent-checkpoint verification

Build 30 passed four fresh nested-tree checks on the same VM/Samba setup. Each tree contained
two files and two folders, with no pre-existing downloads. The candidate built without Swift
warnings; the vendor C conversion and App Intents extraction warnings remain in its build log.

| Check | Result |
| --- | --- |
| Finder nested deletion | Four confirmed deletions, no exceptions, both views settled. Independent audit preserved all 41 remaining objects. |
| Kill after the first child's parent checkpoint | Durable progress held five parent observations. Finder replay after restart completed all four nodes using the identical plan. Audit preserved 37 remaining objects. |
| Kill before the first child's parent checkpoint | The close acknowledgement survived, but parent observations did not. Replay retained an unconfirmed first child, refused the nested directory with a sharing violation, deleted the independently verified sibling, and retained the nonempty root. Both views settled; neither surviving directory was removed. |
| Replace the selected folder after checkpoint and process exit | The original was retained outside the share and a different folder placed at its name. Replay reported parent changes for the three remaining nodes. Both views settled and all 33 replacement/neighbor objects remained unchanged. |

The earlier partial tree record remained unchanged throughout. The last replacement check does
not prove same-file-ID reuse on the live server; that case has simulated-remote coverage.
Finder replay, rather than Settings Retry, resumed the interrupted operations in these runs.
Settings, concurrency and further lifecycle cases remain outstanding.

The first stopped-state audit ran after restart and failed because replay had already completed.
A later lost-checkpoint audit expected only the first removal and failed because the independent
sibling also deleted. Neither failed assertion wrote a success report. Snapshots and the next
independent inventory record the actual outcomes above.

Evidence includes `build-30.log`, `checks-deletion-parents.log`,
`repair/deletion-nested-fixed.mov`, `check-deletion-parent-*.json`,
`check-deletion-restart-*.json`, `check-deletion-replaced-after*.json`, scoped
`deletion-fault-hit-*.json`, and the matching Linux `deletion-parents-seed.json`,
`deletion-parent-fixed-audit.json`, `deletion-restart-after-complete-audit.json`,
`deletion-restart-before-stopped-audit.json` and `deletion-replacement-*.json`.
No fault control or recording remains active. The signed candidate stays installed only in the VM.

Settings showed the lost-checkpoint operation as one confirmed deletion out of four, with an
unconfirmed first child, an in-use nested folder and a nonempty selected root. Remove Location
refused and named that operation. Dismiss Notice explained that it neither restores items nor
confirms uncertainty. Dismissing the lost-checkpoint and replacement-refusal notices changed only
their `dismissed` flags; all eight plans and all outcomes remained. Both views agreed, and the
peer Settings view hid those two notices while retaining the earlier partial tree notice.
`repair/deletion-dismissal-report.json` and `check-deletion-dismiss-*.json` retain the comparison.
Restart/replay after dismissal remains to be checked.

### Concurrent requests and Settings recovery, 2026-11-03

Signed build 31 passes delayed Settings completion and explicit Retry on the same VM/Samba
fixture, with existing caches. Holding the first of three independent deletions after its
remote work admitted only that record. Finder received eight transient busy replies for the
other two items, which remained intact on the server. Releasing Settings let all three finish
without user Retry. Both catalogs settled, and an independent audit preserved 40 remaining
objects' identities, permissions, attached data and file contents.

A process stop after successful remote close but before its acknowledgement checkpoint left
one attempting node. After restart, Finder replay completed settlement with an unconfirmed
outcome. Settings showed zero confirmed deletions and an explicit uncertainty notice. This
was Finder replay, not automatic resumption by the app's launch settlement. A separate failure
after admission left a prepared request; its Settings Retry deleted only the admitted file
and completed both views. Independent inventories preserved the other 38 objects.

Stop Deleting exposed a defect. It durably stopped an untouched request, completed both views
and advanced the survivor's metadata version, but Finder kept the file locally hidden. The
previous `cannotSynchronize` callback needed `signalErrorResolved`; enumeration updates alone
did not restart it. The server file and all neighbors remained unchanged. An initial backing
audit lacked traversal permission and failed; the administrator inventory then passed.

The repair signals File Provider after durable settlement, and once during launch/reconnect
when completed records exist. Completed replay sends no signal, avoiding a retry loop for
unconfirmed outcomes. Settings Retry no longer signals before incomplete recovery has finished.
The VM-only helper adds a stop between durable completion and its notification. Signed repair
checks and required VM checks are pending. Normal deletion capabilities remain disabled.

Evidence is in the same private `repair/` directory: `deletion-concurrency-held-report.json`,
`check-deletion-gate-held.json`, `check-deletion-busy-complete.json`,
`check-deletion-lost-reply*.json`, `check-deletion-settings-retried*.json` and
`check-deletion-settings-stopped*.json`. Linux inventories include `deletion-gates-complete-audit.json`,
`deletion-retry-after-audit.json` and `deletion-stop-after-audit.json`.

### Refreshed deletion callback, 2026-11-03

Build 32 failed the stopped-file preservation check. On restart, the new retry signal made
Finder resend the selected item with metadata version 309 instead of its original 287.
The content version and item ID were unchanged. The candidate admitted this as a new request
and deleted the synthetic file. Independent Linux inspection confirmed that removal and
preserved the other 37 objects. A metadata-version change therefore does not prove a new user
Delete action. Normal deletion remains disabled. Do not install this candidate for user data.

Required VM checks had passed with 635 tests, two optional skips, no failures or Swift warnings,
plus the project, CLI, unsigned app and SMB checks. These do not cover Finder's rebasing of a
pending deletion. The signed failure supersedes any assumption that the notification repair
alone makes Stop safe. Evidence includes `check-deletion-notification-launch*.json`, the
`delete-begin`/`delete-end` callback events, and `deletion-stop-unexpected-removal-audit.json`.
The before recording is `repair/deletion-stop-before.mov`.

The SDK offers `NSFileProviderRequest.domainVersion`: the domain version when the triggering
local event was observed. `NSFileProviderDomainState` defines how the system learns that version
from completions and working-set enumeration. The next isolated probe implements this protocol
and captures request/current versions while refusing every fixture deletion before app/server
work. A bounded mapping from catalog sequence to successive domain versions is probe-only.
It is not a production persistence design. Requests `check-domain-retry` and
`check-domain-reject` signal the existing callback; the latter enables terminal refusal so
Finder can restore the item. Verify replay and a fresh user action before changing admission.

Sources are the macOS SDK headers `NSFileProviderRequest.h` and
`NSFileProviderReplicatedExtension.h`, protocol `NSFileProviderDomainState`. Actor flags in the
request are explicitly unavailable for create/modify/delete and cannot distinguish replay.

### Stable deletion events, 2026-11-03

Signed build 33 passes the non-mutating domain-version probe in macOS VM 1 against the same
Samba 4.19.5/ext4 fixture, with the existing catalogs and downloads. Every deletion callback
was intercepted before app or server work. The original event version survived target and
neighbor metadata changes, retry signals and app/extension restart. Terminal rejection restored
the selected file. A subsequent explicit Finder Delete carried a newer event version. All
39 server objects survived the independent Linux audit. Versions were compared after secure
Apple decoding; archive byte equality does not establish semantic equality.

The implementation now persists the current Apple domain version in each catalog and requires
the original event archive in deletion IPC and durable plans. Replay uses owner, item and event,
ignoring refreshed item bases. Fresh admission still checks those bases. Settlement advances
the domain version before completion, and launch recovery republishes completed outcomes before
signaling retry. It no longer changes item metadata merely to separate deletion requests.
Missing, malformed, future or ambiguously matched events refuse mutation. Old events for other
items remain eligible for first admission. Fresh test state is required; earlier evidence and
pending records must remain preserved. Integrated VM checks and signed Stop/replay verification
are pending, and the normal deletion gate remains off.

Evidence includes `check-domain-baseline.json`, `check-domain-changed.json`,
`check-domain-retry.json`, `check-domain-restarted.json`, `check-domain-reject.json`,
`check-domain-new-action.json`, their callback events, and the independent
`deletion-domain-refusals-audit.json`. This result validates the event protocol, not the complete
production deletion recovery path.

### Integrated event replay and Stop recovery, 2026-11-03

The repair passes signed recovery checks in a fresh `dev.tinymounter.eventcheck` installation
in macOS VM 1, macOS 27.0.1, against the same Samba 4.19.5/ext4 server. Two locations overlap
one new disposable subtree. The original foldercheck installation and its evidence remain
preserved. Selected files initially had no downloads; the final replay check uses a verified,
kept local copy. These are correctness checks, not performance measurements.

- Stop before any remote attempt remained durable while the real Settings completion waited.
  The backing audit preserved the selected file and all neighbors. Changing only its server
  modification time before release did not permit deletion. Finder retried the original event,
  received the stopped refusal and restored the file.
- A subsequent explicit Finder Delete carried a different event version and completed a separate
  operation. The original stopped record remained unchanged.
- A second Stop reached durable completion in both views, then the test killed the app before
  its retry notification. After a controlled modification-time change and app/extension restart,
  launch recovery woke Finder, replay returned the original stopped result, and the file returned.
  Independent backing audits preserved all 12 remaining objects.
- A signed helper replayed that stopped event with the current catalog content/metadata versions
  and an equivalent XML archive. The production app route returned `ItemDeletionError.stopped`
  without changing any durable record. It passed before Dismiss Notice, after dismissal and
  after another restart. The catalog ID, content/metadata versions, keep request, local inode
  and full downloaded digest stayed identical across those checks.

The real Finder retries in these runs retained their original item bases. Refreshed-base app
routing is therefore established by the signed constructed request, together with the earlier
real Finder rebasing failure and stable-event protocol probe. Do not describe the constructed
request as a Finder callback. Semantic event comparison confirmed that retries retain one event
and the later deliberate action uses another.

The first trial's one-shot injected failure was retried after six seconds, before Stop was
clicked. Finder completed that still-authorized deletion; the independent audit preserved the
other 13 objects. That trial does not establish Stop behavior. The test control now supports
repeated admission failure and a separate Settings hold so subsequent Stop trials are
independent of GUI timing. An accidental edit to a test location's draft folder was reverted
without Apply; the snapshots confirm preserved settings.

All required VM checks pass with 644 tests, two optional skips, no failures and no Swift warnings.
The secure archive comparator, CLI, project, unsigned app and SMB checks also pass. The signed
candidate builds have no Swift warnings. Normal deletion remains disabled pending the remaining
concurrency, cancellation and controller-lifecycle gates.

Evidence is in `results/folder-single-20261103/event-recovery/`: `check-event-stop-held*.json`,
`check-event-stop-complete*.json`, `check-event-new-delete*.json`,
`check-event-crash-held*.json`, `check-event-crash-restarted*.json`,
`check-stopped-replay-*.json`, `stopped-replay-preservation-report.json`,
`event-comparison.txt`, `stop-recovery-after.mov`, and the scoped checkpoint captures.
The earlier failed build's recording remains the before comparison. Linux evidence is under
`/tmp/tinymounter-event-RUN`, with `stop-held-audit.json`, `stop-complete-audit.json`,
`new-delete-audit.json`, `crash-restarted-audit.json` and
`dismissed-replay-restarted-audit.json`. Build logs are `build-eventcheck-1.log` through
`build-eventcheck-3.log`; required checks are in `checks-deletion-event-final.log`.
No deletion fault control or screen recording remains active at the end of these replay checks.

### Concurrent deletions in overlapping views, 2026-11-03

The eventcheck candidate also passes three overlapping requests from two domains. Holding the
first request's Settings completion left only that request admitted and only its file removed.
The two peer requests received seven transient `NSCocoaErrorDomain/4101` replies while their
server files remained unchanged. After release, all three completed without manual Retry,
with one record per selected item and both views settled. The independent audit preserved all
11 remaining objects, and the unrelated kept file retained its complete local copy.

One peer-selected child was absent from the owner's catalog at the initial snapshot. Admission
listed it in both catalogs before recording its plan. An assertion expecting one admitted view
failed and wrote no success report; the corrected report states both facts. This run therefore
does not establish settlement for a selected item still unlisted in a participating view at
admission. The earlier recursive checks cover unlisted descendants. Delaying a second catalog
and filling the reader job queue remain separate checks.

Evidence includes `check-concurrency-baseline*.json`, `check-concurrency-held*.json`,
`check-concurrency-finished*.json`, `concurrency-report.json`, callback events and the Linux
`concurrency-held-audit.json` and `concurrency-finished-audit.json`. The Settings hold control
is archived and inactive.

### Reader capacity, 2026-11-03

The signed eventcheck build passes the full-reader-queue check on the same macOS/Samba VMs,
with uncontrolled caches and no performance claim. Four constructed reads occupied the actual
connected reader session while its worker queue was suspended. A real Finder deletion returned
four transient busy replies, admitted no operation and left the independent server inventory
unchanged. Releasing one read let Finder retry and complete the deletion, with three reads still
occupying their slots. Both views settled. Draining the remaining reads produced exactly one
cancellation reply for each of the four reads, zero jobs and zero queued operations.

The first trial established busy refusal and automatic retry after drain, but drained the last
three reads before the successful callback. It therefore did not establish that one freed slot
was sufficient. The second trial retained those reads through success and passed that check.
The server audit preserved the other 37 objects, including their contents, identity, permissions
and attached data. The deletion used Finder/XPC; only the held reads used constructed requests.

Evidence is in `event-recovery`: `check-reader-jobs-*-second*.json`,
`check-reader-second-full*.json`, `check-deletion-session-state-queue-success*.json`, callback
events and the earlier `reader-capacity-first-report.json`. Linux evidence includes
`lifecycle-seed.json`, `queue-second-full-audit.json` and `queue-second-success-audit.json`.
The queue is resumed. Builds 4 and 5 have no Swift warnings. Required VM checks in
`checks-reader-capacity.log` and `checks-deletion-lifecycle.log` pass all 644 tests with two
optional skips, plus the project, CLI, app-build and SMB encoder/status checks.

### Timeout and connection lifecycle, 2026-11-03

Six real Finder recursive deletions pass in signed eventcheck build 5: the provider's response
timeout, reader XPC invalidation and extension termination, each before marking the first
protected child and after its successful mark but before close. Only the transaction worker
was held. The main app and provider remained responsive; no provider Progress was explicitly
cancelled. The timeout runs returned `NSFileProviderErrorDomain/-1004` after the normal deadline.
XPC invalidation returned the same connection error. The extension termination runs recorded
replay from a new provider process while the app kept the original transaction.

At each held checkpoint, the durable plan and in-flight progress remained identical, with no
cancelled transaction Progress or queued Stop. After release, the original three-node plan
completed in both views and Finder received success. None admitted a second deletion, recorded
Stop or changed the unrelated kept file's ID, versions, keep flags, inode or complete digest.
Independent server audits confirmed only the selected trees disappeared and preserved all
remaining objects. These checks cover reply timeout and loss of the provider connection; they
do not simulate SMB connection loss or app-source closure.

Evidence includes `deletion-lifecycle-report.json`, `check-*-finished*.json`,
`check-deletion-session-state-*.json`, archived hold controls, both provider termination
reports and callback events. Linux `*-finished-audit.json` files compare against
`lifecycle-seed.json`; the final audit preserves 19 remaining objects. All holds are released
and their controls archived. Explicit cancellation, joined waiters and delayed-Settings source
closure remain to be checked against the current integrated app.

### Explicit provider cancellation, 2026-11-03

The signed build 6 checks pass for cancellation before marking and after marking the first
protected child. A fixture/item/event-bound test command cancelled the Progress returned by a
real Finder callback; this is a constructed cancellation trigger, not a Finder cancellation UI
test. Each original callback completed once with `NSUserCancelledError`. While protection was
held, the app observed cancelled progress and a queued Stop, but had not yet persisted Stop.

After release, both three-node plans settled in both views. The first node remained unconfirmed
and the later file and parent were stopped. The before-mark audit preserved every object. The
after-mark audit found only the active file removed and preserved the other 18 objects. Neither
run claimed the uncertain result was confirmed. Finder replay returned a stopped refusal with
the surviving folder, restored that folder, and ceased repeating cancellation errors.

The real Settings Dismiss Notice confirmation explicitly preserves uncertainty. Dismissal changed
only the durable `dismissed` flag in each record; plans and node outcomes remained unchanged.
An initial comparison incorrectly included derived `pending` and `canDismiss` flags and failed;
the corrected check compares persistent state and records those expected visibility changes.
Post-restart replay of these two records and Settings Stop during active Retry remain separate.

Evidence is `provider-cancellation-report.json`, `check-provider-cancel-*.json`,
`check-deletion-session-state-cancel-*.json`, `check-cancel-*.json`, the consumed cancellation
commands and callback events. Linux evidence is `cancel-before-*-audit.json` and
`cancel-after-finished-audit.json`. All holds and cancellation commands are consumed or archived.
Build 6 has no Swift warnings; `checks-deletion-cancellation.log` passes the required VM checks.

### Joined requests and source closure, 2026-11-03

Signed build 7 passes the joined-request check. A real Finder deletion awaited its Settings
callback while three constructed requests joined the same event in the connected reader session.
A fifth constructed request and a second real Finder deletion received busy replies. Detaching
one waiter did not request Stop. Cancelling another queued Stop without changing the already
confirmed outcome. Releasing Settings produced three single correct replies and zero jobs;
the second Finder deletion then completed automatically. This tests joined cancellation after
remote deletion, not during a protected mutation.

The job verifier passed, but its enclosing catalog snapshot failed because the second deletion
finished during capture. The subsequent `check-joined-finished` snapshots show both original
records complete in both views. Independent server audits preserve all remaining objects.

Closing the actual controller-created source while its real Settings callback waited returned
`serverUnreachable`, drained recovery waiters and preserved the exact durable record without
Stop. Releasing the delayed callback did not change that record. Normal app relaunch completed
the original plan in both views. The server audit preserved all 15 remaining objects. This
constructed source-close call is distinct from Remove Location, which blocks pending deletion.
Post-restart constructed replay also preserved both dismissed cancellation records and the
earlier kept survivor, including a refreshed item base and equivalent XML event archive.

Evidence includes `check-joined-jobs-*-jobs.json`, `check-joined-finished*.json`,
`check-source-close-state.json`, `check-source-closed-state-state.json`,
`check-source-close-reopened*.json`, `check-stopped-replay-cancel-restarted-replay.json`,
callback events and the Linux `joined-*-audit.json` and `source-close-reopened-audit.json`.
`checks-deletion-joined.log` passes all 644 tests with two optional skips and the required checks.

### Unconfirmed selected survivor, 2026-11-03

The signed build 7 test found a surviving selected file hidden in Finder after completed Stop.
The disposable file was verified and kept locally before deletion. An injected failure after
the attempting checkpoint prevented its mark. Settings Stop settled the single node as
unconfirmed in both catalogs. The independent Linux audit preserved every object and the file's
full contents. Finder replay received `cannotSynchronize`; working-set enumeration returned no
updated row because fresh listing found unchanged metadata. The local URL remained unavailable.
The earlier stopped-folder checks do not cover this selected-unconfirmed case.

The first candidate advanced the surviving selected row's change sequence after fresh
reconciliation. Signed build 8 delivered that updated row through the working set, but Finder
still kept the file hidden while its callback returned `cannotSynchronize`. The durable record
and independent server inventory remained unchanged. Constructed replay with current item bases
and equivalent XML archives preserved both unconfirmed records. All 644 tests and required VM
checks passed, showing why the signed behavior check was necessary. The ineffective metadata
change is removed.

The next candidate returns `deletionRejected` for a completed unconfirmed selected object only
when its reconciled catalog row is still live. The provider attaches that row through Apple's
rejected-deletion API. Incomplete records and absent selected rows retain `cannotSynchronize`.
The durable node outcome, uncertainty notice and replay binding stay unchanged. This corrects
the checklist's earlier assumption that a working-set update could restore a survivor while
retaining `cannotSynchronize`; it does not permit a successful deletion response. Signed
verification of this response passes in build 9, as detailed below. Normal deletion remains disabled.

The first Delete in each trial was safely rejected before
admission because Finder still held the metadata version preceding Keep Downloaded. A second
explicit action reached the intended injected checkpoint.

Evidence is `check-survivor-*.json`, `unconfirmed-control.json`, its checkpoint capture and
callback events. Linux `survivor-seed.json` and `unconfirmed-stopped-audit.json` preserve the
independent baseline. `unconfirmed-settled-audit.json` confirms the inventory after Stop.
The second trial uses `check-survivor-fixed-*.json`, `check-unconfirmed-replay-fixed-replay.json`,
`survivor-fixed-seed.json` and `unconfirmed-fixed-settled-audit.json`. The before recording shows
the missing file and uncertainty notice; the notification-only result is also recorded.

### Settings Stop during Retry, 2026-11-03

Signed build 7 passes the actual Settings Retry/Stop check. Repeated failure after admission
left a fresh three-node folder request prepared. Clicking Retry resumed that original plan;
a hold after the first attempting checkpoint kept its protected file active. Stop Deleting
remained enabled during Retry, and its confirmation queued Stop and cancelled transaction
Progress while durable Stop still waited for protection to end. After release, the first node
remained unconfirmed and both later nodes stopped. Both views settled and Finder restored the
selected folder. The independent audit preserved all 19 server objects.

Evidence includes `check-deletion-session-state-retry-*.json`, `check-retry-stop-finished*.json`,
the archived admission/hold controls, callback events and `retry-stop-finished-audit.json`.

### Restoring unconfirmed survivors, 2026-11-03

Signed build 9 restores both previously hidden selected files on launch recovery. Finder receives
the completed refusal with the surviving item. Both durable records remain unconfirmed and
unchanged; IDs, content versions and keeps survive. The independent Linux audit preserves all
20 server objects, including their identities and file contents. The unrelated kept neighbor
retains its entire catalog row, local inode and readable bytes.

macOS recreates the selected local files with new inodes and fetches their contents again. An
initial verifier incorrectly required unchanged local inodes and failed. One restored file still
had `SF_DATALESS` after its successful fetch callback; an explicit verified full read completed,
after which both files hashed with materialization disabled. This proves restored readable
contents, not immediate offline availability or uninterrupted retention of downloaded bytes.
The first file's metadata version stays unchanged. The second retains the earlier build-8
notification experiment's increment; build 9 adds none.

Actual Settings dismissal changes only the second record's `dismissed` flag. Scoped app/extension
restart and constructed replay with refreshed item bases and equivalent XML event archives
preserve both records. A new Finder Delete of the restored second file creates a separate record
and completes in both views. Secure decoding and Apple's domain-version comparison establish
that this explicit action has a newer event version. The server audit finds only that file
removed and preserves the other 19 objects. Subsequent replay of the old dismissed record
returns unresolved for its now-absent selected row; the other live survivor still returns the
completed refusal. Neither old record changes.

Evidence includes `check-survivor-restored-verified-report.json`, `survivor-read.jsonl`,
`check-unconfirmed-replay-{restored,dismissed,restarted,after-new-delete}*.json`,
`check-unconfirmed-new-delete.json`, `survivor-event-comparison.txt` and the Linux
`unconfirmed-{restored,new-delete}-audit.json` reports. The before, notification-only and after
recordings compare Finder contents and Settings notices; they do not record an entire continuous
deletion workflow. A fresh same-process Finder Delete, injected pre-mark failure and actual
Settings Stop also restore the original file without a restart. Its new record is complete
in both views and unconfirmed; the restored bytes hash with materialization disabled.
Evidence is `check-survivor-immediate-{before,finished}*.json` and the archived control.

`checks-deletion-restoration-2.log` passes all 644 tests, with two optional skips, and the required
project, CLI, unsigned app and SMB checks. It and `build-eventcheck-9.log` contain no Swift
warnings. The first compilation caught a missing exhaustive-switch case, fixed before this run.
A host package attempt could not start compilation because sandboxed compiler caches were
unavailable; no app was built on the host.

### Delayed catalogs and actual reconnect, 2026-11-03

Signed build 12 passes the incomplete-catalog response check. A real Finder folder deletion
confirmed its first child before an injected failure left the second child unconfirmed. Actual
Settings Stop left the parent stopped. The first catalog reconciled, while a repeated failure
before the second catalog prevented completion. Constructed replay through the connected reader
session returned `cannotSynchronize` for injected `versionChanged`, read-only and invalid-request
errors. All three preserved the immutable plan and durable progress. This verifies error
ordering through the signed app; it does not reproduce a physical root replacement or permission
change. The independent server audit finds only the first child removed and preserves the other
24 objects.

After removing the injection, force-unmounting only the disposable VM share and reconnecting
through Finder produced actual controller recovery callbacks for both locations. The original
record then completed in both catalogs without another remote deletion, preserving the uncertain
child and stopped parent. Both views removed only the confirmed-deleted child. There was no
Settings Retry or app restart. Automatic remount was not established: Finder supplied the new
connection. A snapshot while disconnected failed; the post-reconnect snapshot passed.

An earlier version of this trial completed during test-app launch, before the evidence picker
enabled injection. Its replay probes correctly failed because no incomplete record remained.
A new explicit deletion in the same process provided the valid trial above. A snapshot during
concurrent catalog changes also failed and was repeated after settling. The first probe build
had one unused-binding Swift warning, corrected before build 12; build 12 has no Swift warnings.

Evidence includes `check-incomplete-deletion-*-second*.json`, the archived catalog controls,
`check-controller-reconnected-complete*.json`, `controller-reconnect-report.json`,
`controller-unmount.txt`, `controller-recovered` callback events and the Linux
`catalog-second-partial-audit.json` and `controller-reconnect-audit.json` inventories.
`checks-deletion-controller.log` passes all 644 tests, with two optional skips, and required checks.

### Older Keep Downloaded restoration, 2026-11-03

Signed build 13 passes the controller ordering check. A constructed fixture request seeds three
typed pending keeps in both locations and holds the actual older restore after it enters the
controller's restoring set. A real Finder folder Delete then confirms the first child. An
injected failure before marking the second child, followed by actual Settings Stop, leaves that
child unconfirmed and its parent stopped. Both catalogs reconcile, but Settings settlement
remains incomplete while the older restore is held. Both locations retain all three pending
keep requests during that interval.

Releasing the older restore automatically finishes the original record in both views. Settings
removes only the confirmed-deleted first child's keep. The two surviving requests remain pending
because the older restore encountered the still-pending deletion. Reconnect completes those
requests. Catalog keeps, IDs and content versions survive, and the final local copies hash with
materialization disabled. An immediate snapshot caught the selected folder's surviving child
before Finder restored it; macOS recreates that owner's local child. The unrelated kept file
retains its inode and bytes. The independent server audit preserves all 23 remaining objects and records only the
two deliberate first-child deletions across this and the preceding catalog trial.

The first control used the App Group path, where the VM driver was correctly denied write
access. That run did not hold restoration and was not used as ordering evidence. The corrected
control uses the existing security-scoped evidence folder. A readiness check also caught one
older pending keep; reconnect completed it before the valid trial. No sandbox permission changed.
Build 13 compiles with no Swift warnings. Evidence includes `check-keep-restore-start-second`,
`check-keep-restoration-{blocked,finished,reconnected}*.json`, `keep-restoration-report.json`, the hold/release
and node controls, and Linux `keep-restoration-audit.json`.

### Successful location removal, 2026-11-03

Signed build 15 passes actual Settings removal of both fixture locations. Dismissing the remaining
completed notices changes only their persistent dismissal flags. All 26 owner records retain
their plans and outcomes. Removing the secondary location, without saving its disposable keep
list, removes its registration, Settings entry and catalog while preserving every owner record.
Constructed replay still returns the original outcomes for seven live stopped selections and
three unconfirmed records. Their replay reports pass; the enclosing dual-view snapshots fail
because the secondary location has deliberately been removed.

Removing the owner through the same Settings confirmation then removes its registration, catalog
and settled deletion records. The dedicated post-removal report verifies durable Settings and
preservation of all unrelated settings. The independent server inventory still contains the same
23 objects with unchanged identities, file contents, permissions and attached data. No new
deletion occurred during removal. Both fixture domains are now removed; evidence remains local.

Evidence is `check-removal-state-*-state.json`, `check-*-replay-peer-removed-replay.json`,
`removal-report.json` and Linux `location-removal-audit.json`. Build 15 has no Swift warnings.
Build 14 caught a non-Codable probe report field before runtime; the report now uses the existing
deletion snapshot type. Physical root replacement and permission loss during incomplete signed
settlement remain unverified as complete scenarios; the injected error-class checks above verify
their completion-response ordering. Normal-build deletion stays disabled while Finder Replace
is observed, because unbound delete/create callbacks cannot authorize a safe replacement.


## Root replacement during incomplete settlement, 2026-11-03

Signed OfflineCheck build 4 in macOS VM 1 held the second catalog's settlement after an actual
Finder deletion and confirmed Stop. The record retained one confirmed child deletion, one
unconfirmed child and a stopped parent. Replacing the configured Linux fixture root with a
copy containing different inodes, then releasing the hold, completed catalog settlement in
both views without deleting any replacement object. The immutable plan and outcomes stayed
unchanged. Independent backing audits checked identities, contents, ownership, modes, times
and xattrs. This is recovery evidence, not permission to enable ordinary deletion.

The probe expected recovery to remain pending and failed that expectation. Inspection instead
found legitimate completed settlement with `stopped` / `deletionRejected`. The failed probe is
retained alongside the independent successful audit; it was not a production mutation defect.
The original root was restored and the replacement preserved outside the share. A later ordinary
Delete was refused before admission, so it does not establish permission-loss recovery. All
failure controls were archived; the server is running and permission-loss testing remains.

Evidence is in the VM's `results/deletion-final-20261103/` run directory and the Linux
`/tmp/tinymounter-deletion-final-` directory with the same run UUID. Relevant files include
`check-deletion-stop-confirmed`, `check-root-replaced-stable`, their peer snapshots,
`root-swap-audit.json` and `root-restored-control.json`. The superseded
`check-incomplete-deletion-root-replaced` expectation remains marked failed.
