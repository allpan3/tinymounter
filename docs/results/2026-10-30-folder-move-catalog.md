# Folder-move catalog preparation

Date: 2026-10-30. M22 passes required VM checks and selected signed adapter checks for moves,
collisions and recovery. Two ambiguous-name cases could not run on the fixture. Folder rename
and move remain unavailable in the app pending signed integration checks.

The catalog can snapshot a known subtree and commit a caller-proved move atomically. It keeps
item IDs, enumeration keys and file content versions, including the distinction between f1 and
e1. It updates native lookup IDs, records the root's departure from its old parent and computes
inherited keeps from the current destination. No catalog schema or Settings format changes.

The all-preserved commit requires identity evidence for every known descendant and complete
unchanged-content evidence for each file. Missing or duplicate observations, changed rows, cycles,
collisions and invalid destinations refuse the whole commit. Exact replay writes nothing. The transaction
caller must exclude concurrent catalog reconciliation until local completion is durable.

Review found that identity evidence does not prove directory membership. The commit therefore
clears every moved directory's listing-complete flag. A fresh listing must discover any child
that arrived during the move before the folder can be Available offline. Known downloaded files
keep their versions. A second review found that keep and pause changes could strand recovery;
the commit now preserves current explicit keeps instead of requiring the admission-time policy.
Namespace, content, native fingerprint and listing evidence must still match.

Focused tests cover populated and empty folders, case-only rename, departure pagination,
synthetic pathname-derived native IDs, unchanged versions after relisting, keep and pause changes,
new child discovery, stale descendants, replay and refusal without writes. Tools/run-checks.sh
passes in macOS VM 1 with no failures or Swift warnings, including project generation, release
CLI validation, the unsigned app build and six encoder cases. Evidence:
.local/phase4/m21-20261029/m22-catalog-checks.log. Test data is synthetic, cache state is
uncontrolled, and no performance claim follows.

## Changed descendants during a folder move

A directory move must release handles below the directory, so another client can change its
children before protection is reacquired. A separate atomic settlement API now accepts explicit
outcomes for the known subtree. Proved unchanged files keep their versions. A changed file must
retain its server identity and have different complete contents; a fresh receipt gives it a new
content version even when size and timestamps are unchanged.

A missing or replaced child becomes a tombstone only with a complete listing of its proved
parent. This ends its old catalog binding; it does not claim that the server object was deleted.
A replaced directory requires explicit removal of all its known descendants. New occupants
enter through ordinary reconciliation with new item IDs after settlement. Directory listings
remain incomplete until that discovery finishes. Exact settlement replay changes nothing.

The caller must durably store changed receipts before committing the catalog and block ordinary
reconciliation until local completion is durable. Runtime integration also needs targeted
stale-edit checks for invalidated versions, while preserving legitimate M23 save replay.
Signed checks must establish that File Provider invalidates old local bytes before accepting
the changed version as an editing base. This API enables no runtime folder operation.

Ten added tests cover changed contents with identical timestamps, receipt reuse, incomplete or
contradictory listings, missing/replaced subtrees, pagination, replay and stale catalog rows.
Source review found no blocking defect. Tools/run-checks.sh passes on the integrated candidate
in macOS VM 1: 414 tests, one optional skip, no failures or Swift warnings, project generation,
release CLI validation, unsigned app build and six encoder cases. Evidence:
.local/phase4/m21-20261029/m22-settlement-checks.log. This is catalog evidence only.

The SMB transaction, watch/handle draining, pending-path checks, receipt replay, overlapping
views, provider callbacks and signed Finder checks remain. These catalog APIs alone do not
authorize moving a folder or establish that its remote subtree was preserved.

## Folder transaction core

Folder intents now share the durable rename inventory. Older file-only readers refuse folder
records, including completed history. The transaction records admission evidence before
releasing descendant handles, verifies the moved root by identity, and stores a settlement
before local catalog work. Every retry reloads the durable record. Overlapping views must agree
on each physical descendant's outcome, contents and native lookup evidence.

Completion is tracked per location after its catalog, keeps and replay data are durable.
Completed folder history remains until all participating locations are removed; removing a
non-owner location preserves the owner's completed replay. There is no catalog or Settings
format change. Review strengthened directory-sync retry and agreement across complete listings
and filename aliases. A pre-existing test fixture now admits all participating views at once,
because changing an already saved intent's participants correctly fails.

All required VM checks pass: 472 tests, one optional skip, no failures or Swift warnings,
project generation, release CLI validation, unsigned app build, six encoder cases and 57
SMB-status callback cases. The 31 folder transaction tests include a failure after publishing
the checkpoint file but before syncing its directory; retry cannot proceed until that sync
succeeds. Evidence: .local/phase4/m21-20261029/m22-folder-core-checks-02.log. The first run's
fixture failure remains in m22-folder-core-checks.log. These are simulated-remote checks.

At this checkpoint the core had no runtime adapter or provider wiring. Children changing after
settlement and partial catalog completion caused replay to refuse. The next change addresses
that recovery case before folder moves can be enabled.

## Recovery after partial catalog completion

The transaction now retains its original admission, directory identity and first settlement,
plus one expected and one target state per participating catalog. A fresh protected observation
can replace that bounded recovery plan. Each catalog either applies its expected state to the
target atomically or proves it already matches the target. An untouched catalog can go directly
to the fresh target. Earlier completion markers cannot skip this catch-up.

Changed contents or modification times require fresh edit receipts. Reverting to earlier bytes
also receives a new version. A missing or replaced descendant's old catalog binding stays
retired, even if the same object later reappears. A bounded immutable witness records the first
complete-listing proof, or the retirement of its parent; it does not claim server deletion.
The original moved root can never retire, and replacing it leaves recovery unresolved.

Older readers reject an active `recovering` state. Completed replay remains a no-op; callers
must never apply the original settlement again. Runtime integration must store new receipts
durably before exposing their versions and hold fresh protection through catalog completion.
Source review found no blocking defect. Tests cover repeated recovery, partial commits,
mtime-only changes, permanent retirement, root replacement, collisions and interruption.
The integrated core and adapter pass the required VM checks below. There is no catalog or
Settings format change.

## Protected SMB adapter preparation

The production SMB adapter now implements folder admission, guarded no-replace rename and
fresh settlement/recovery observations. It holds the original directory handle through the
rename and releases descendant handles only after the transaction's durable checkpoint.
Directory parsing retains unsupported entries so a complete listing cannot mistake them for
absence. Native lookup checks compare full metadata and mount identity with the protected SMB
objects. Historical e1 receipt selection remains the admission caller's responsibility.

The app caller below is prepared; provider routing remains disabled. Native metadata queries
while the root and descendant handles stay open require a signed VM check. No transport or
dependency was added; the existing deletion adapter is unchanged. Required VM checks pass with 490 tests, one optional
skip, no failures or Swift warnings, six encoder cases and 57 SMB-status cases. Evidence:
`.local/phase4/m21-20261029/m22-recovery-adapter-checks.log`. This compiles the real adapter but
does not exercise it against SMB; signed adapter and app checks remain.

Review found that an unbrowsed known directory could contain names that settlement rejects,
leaving a successful remote move unresolved. Source verification now lists every known
directory before attempting the rename. Admission, settlement and recovery share the same
aggregate child limit across views. A concurrent arrival can still require recovery. The
correction passes all required VM checks: 491 tests, one optional skip, no failures or Swift
warnings, six encoder cases and 57 SMB-status cases. Evidence:
`.local/phase4/m21-20261029/m22-adapter-review-checks.log`. Signed SMB checks remain blocked
by the fixture recovery described in the [restart report](2026-10-30-vm-graphics-interruption.md).

## App integration preparation

The app now has a folder-move entry point and retries durable folder intents. It checks
configured location roots and pending recovery data, reserves both endpoints, then drains
native reads and directory watches before admission. Verified files retain historical receipts;
unverified files retain their existing content versions. Completion stores receipts before
catalog updates. Saved keep paths are rewritten without SMB or namespace locks, then a fresh
protected session verifies or replans the catalogs before completing the intent.

A later source review found that keeping the SMB client across namespace reacquisition could
deadlock another lane. The revised lock scopes compile and pass the required VM checks with
555 tests and one optional skip (`m24-admission-fixed-checks.log`). A new signed-probe assertion
opens a protected client from the Settings callback while the mover waits. Its corrected run
passes below; the earlier signed results predate this lock repair.

Independent review found no remaining lock-order blocker or false-completion path. The unlocked
Settings interval exposes an existing recovery limit during normal operation: an outside rename
of the moved root or a destination ancestor can leave the intent unresolved on every retry,
blocking listing and writes for the share. The source repair below addresses descendant spelling
and source-only ancestor changes; its signed checks remain. Changed file contents can replan.
The fresh proof also rereads every admitted file under the namespace and global SMB locks.
These recovery and latency limits remain gates for normal-build enablement.

The first signed lock probe passed root exclusions and the active-read timeout, then moved its
first folder and applied the catalog. Its diagnostic connection was refused as `serverUnreachable`
after the mover's roughly 20-second connect marked that shared activity unresponsive. No lock
assertion passed. The helper now uses a separate connection manager with the same namespace for
this assertion; production health handling is unchanged. The failed report, catalog copy and
fixture remain in `m22-lock-inspection` and `m22-lock-fixture-20261030` in the private session.

The corrected signed helper passes both phases on a new marked fixture in macOS VM 1,
macOS 27.0.1. It builds without Swift warnings, passes strict signature verification and uses
unchanged app/provider entitlements. The installed app remains restored and stopped. Cache state
is uncontrolled; this is a correctness check, not a performance measurement.

The main-actor Settings callback acquired the namespace and a fresh protected SMB session three
times while the mover waited. Read/watch draining and the expected admission refusals pass.
The quiet move completes with no recovery plan. The two-view move reaches the injected error
after Settings persistence. Between clean exits, the driver changes one child's contents and
moves another into Hold. Fresh-process recovery completes both domains, preserves unchanged
versions and refuses the stale read and retired-item edit. The independent backing audit matches
the complete expected tree; the moved-out original remains in Hold. Independently copied original
Settings files are byte-identical.

These checks cover a competing protected SMB operation during Settings, not simultaneous deletion
admission, location Add/Close, cancellation during final verification or a one-view-only crash.
They do not exercise the outside-rename gap above or close the remaining Finder gates. Evidence in
the same private session: `m22-lock-probe2-build.log`, `m22-lock2-run.json`,
`m22-lock2-fixture-20261030`, `m22-lock2-inspection`, `m22-lock2-final-inspection`,
`m22-lock2-quiet-receipt.json`, both phase process records and
`m22-lock2-settings-comparison.json`. Both helper processes have exited; evidence and recovery
artifacts remain for the ongoing session.

Namespace checks, pending counts, recovery display and location removal now read the shared
file/folder intent inventory. Edits to deleted catalog rows are refused. The integrated
candidate passes all required VM checks with 492 tests, one optional skip and no failures or
Swift warnings, plus six encoder and 57 SMB-status cases (`m22-app-regression-checks.log`).
The new regression checks file admission and replay beside pending and completed folder history.
Source review found no blocking safety defect. It found a watch-close race: a dropped watch
could leave the dictionary before its descriptor closed. The session now tracks that closure
separately and drains it too. The corrected candidate passes the same 492-test required checks
without Swift warnings (`m22-watch-drain-checks.log`). Provider routing and folder capabilities
remain disabled; draining, protected native queries, local-copy invalidation and interruption
recovery still need signed VM evidence.

An isolated adapter/core helper also compiles without Swift diagnostics
(`m22-adapter-helper-build2.log`). The signed attempts are recorded below. Its checks cover
protected native metadata, moves, collisions, simulated lost replies and partial-catalog
recovery; they do not replace the app and Finder checks.

## Saved keep paths

Settings now has a caller-invoked folder-path rewrite for pending and saved Keep Downloaded
requests on the affected share. It moves the selected folder's request and typed descendants,
preserves descendant spelling, and leaves other shares and neighboring names unchanged.
Case and Unicode aliases use the existing NameKey comparison. The rewrite is idempotent and
refuses overlapping or overlong destinations before changing Settings. There is no format
change. The prepared app caller applies this rewrite during completion. Three focused tests
cover aliases, typed descendants, replay, Settings reload and refusal without partial changes.
All required VM checks pass with 475
tests, one optional skip, no failures or Swift warnings, six encoder cases and 57 SMB-status
cases. Evidence: `.local/phase4/m21-20261029/m22-keeps-checks.log`.

## Signed adapter attempt, 2026-10-30

After fixture recovery, the signed helper passed its initial tree and full-content checks but
deadlocked before renaming a folder. Its root-protection check opened a second production client
in the same process. A process sample showed that call waiting on the transport's existing
client mutex, which the first client holds until disconnect. The task app was stopped with
the source still present and destination absent. This is a helper defect and supplies no
completed folder-move evidence.

The helper now pauses with the root protected while a separate process tests the competing
open through the same production library. The driver must record the exact sharing-violation
status before resuming the app. A second nested client in the collision case now reuses its
existing client. Production transport and locking are unchanged. The corrected helper compiles
in VM 1 without Swift diagnostics. It uses a new fixture and evidence directory; the earlier
attempt remains intact.

Evidence in `.local/phase4/m21-20261029`: `m22-adapter-gate.jsonl`,
`m22-adapter-gate-sample.txt`, `m22-adapter-gate-deadlock.json` and `m22-adapter3-build.log`.
The fixture is synthetic and cache state is uncontrolled. No performance claim follows.

## Signed adapter checks, 2026-10-30

The corrected helper passes its first gate in the signed, sandboxed app in macOS VM 1.
The fixture's starting names and complete contents match. While the app holds the root,
a separate process using the production library receives `STATUS_SHARING_VIOLATION` for a
competing rename-capable open. Native metadata queries succeed with the root alone protected,
with descendant handles held, after source verification and after settlement.

The transaction moves a populated folder once, completes its private catalog and relists it.
All four known items retain their IDs and content versions. The untouched neighbor's identities
and contents match. This closes the protected-native-query gate on this fixture; it does not
verify File Provider callbacks, downloaded copies, watch draining or saved keep paths.

Evidence in `.local/phase4/m21-20261029`: `m22-adapter3-gate.jsonl`,
`m22-adapter3-gate-competitor.json` and the Finder-copied reports in
`m22-adapter3-gate-inspection/M22Adapter-trial3`. The copy was made while the later cases ran;
only its completed gate reports are evidence here.

The next phase passed all 11 cases. Populated and case-only moves completed and retained item
IDs and content versions through relisting. File and folder collisions were refused before
sending a rename. A simulated lost reply left one real move at the durable `moved` checkpoint.
The overlapping-view case updated only its owner catalog. Admission for the two unseen-name
cases stayed `prepared`. Reports copied after the app closed are in
`m22-adapter3-run-inspection/M22Adapter-trial3`.

Between processes, the driver changed two files in place, moved selected original children
outside the moved folder and created a distinct replacement. Its exclusive renames retained
the originals for the preservation check. APFS refused every second name in the three proposed
ambiguous pairs, so neither unseen-name case has a usable collision fixture. Those cases cannot
establish the adapter's refusal of ambiguous directory contents. The setup observations are in
`m22-adapter3-between.json`.

Recovery completed in a fresh app process. Nine cases passed; the two unseen-name cases failed
with `ambiguous-fixture-unavailable`, before any publication attempt. The phase therefore
exited with failure and is not an all-pass result. Its reports are in
`m22-adapter3-resume-inspection/M22Adapter-trial3`.

After the simulated lost reply, recovery sent no second rename. It preserved the unchanged
file's version, assigned the changed file a new version and retired the old bindings for
missing or replaced children. The replacement received a new item ID during relisting.
The original children moved outside the folder retained their identities.

For overlapping views, the first fresh verification refused the stale settlement. Recovery
created a new plan, updated the second catalog, ended its SMB session, then rechecked and
completed both catalogs. The original settlements remained unchanged, and the second recovery
plan retained the first plan's target versions. Completed replays made no adapter calls.

The final audit passed in a fourth app process. Expected tree contents matched, and the
neighbor files and marker retained their complete recorded versions. All five completed
operations replayed without an adapter call. The two unavailable ambiguity cases remained
`prepared`; the audit checked their retained state, not collision behavior. Final reports are in
`m22-adapter3-final-inspection/M22Adapter-trial3`. The task app is closed. The disposable fixture
remains open for the other approved checks, with final teardown and SMB-service restoration owed.

These are adapter/core checks using private catalogs. Reply loss was simulated after a real
successful rename; process boundaries were clean exits. Child changes used the fixture's
backing disk. Finder callbacks, downloaded-copy invalidation, saved keeps, watch/read draining,
real process crashes and ambiguous directory contents remain unverified. Folder capabilities
remain disabled.

## App-level probe preparation, 2026-10-30

`Tools/check-folder-move-app.swift` calls the real `LocationSource.moveFolder` path with
private catalogs and settings. Its companion Python driver prepares a bounded synthetic tree
and checks the backing files between app processes. The suite covers read/watch draining,
pending-write and root exclusions, overlapping catalogs, keeps, and recovery after an injected
error following settings persistence. It does not enable provider capabilities or establish
Finder behavior. Parent review corrected its intent-ID comparison and its assumption that
the fixture's mapped SMB login was a macOS account. The signed checks below use these corrections.

## Signed app checks, 2026-10-30

The app-level helper compiles without Swift diagnostics and passes exercise, fresh-process
recovery and the backing-tree audit in macOS VM 1 (macOS 27.0.1, build 26A434). It runs from a
signed staging bundle with unchanged entitlements and private catalogs/settings; no installed
app or extension was replaced. The original Settings bytes remain unchanged. The loopback
fixture has 11 synthetic files, cache state is uncontrolled, and this is not a performance run.

A held native read forces the move's drain timeout before an intent is saved. Releasing a read
allows a watched folder to move while preserving its item ID and complete file contents.
Configured roots, contained roots, self-descendant moves, differing overlapping views and
pending uploads/saves/retained copies all refuse before admission. The retained-save fixture
contains a local checkpoint only; it creates no remote artifact.

The second move preserves descendant IDs, versions, independent and inherited keeps, and
rewrites pending/saved keep paths across two catalogs. An injected error after settings
persistence leaves a verified pending intent. Between clean app exits, the driver changes
one child's bytes and moves another into the fixture's Hold folder. Fresh-process retry
completes both views, preserves unchanged versions, gives the changed child a new receipt,
and retires the moved-out child's old binding. Relisting and replay preserve that result.
A stale read and an edit to the retired row are refused. The audit confirms the complete
expected tree, including the untouched neighbor and the retained original in Hold.

Evidence in `.local/phase4/m21-20261029`: `m22-app-build.log`, `m22-app-fixture/`,
`m22-app-inspection/` and `m22-app-final-inspection/`. Private settings and catalogs stay in
the VM. The signed helper has exited; the fixture and synthetic recovery copies remain for
the session's final teardown. Finder callbacks, downloaded-copy invalidation, actual crashes,
interruption after only one catalog commit, ambiguous names, and publication of stale saves
after a move remain unverified. Folder capabilities remain disabled.

The integrated source passes `Tools/run-checks.sh`: 492 tests, one optional skip, release CLI
validation, project generation, unsigned app build, six encoder and 57 SMB-status cases, with
no Swift warnings. Evidence: `m22-app-source-checks.log` in the same private session directory.

## Finder routing preparation

The provider now has a disabled route for ordinary-folder organization through the checked
app caller. It carries the existing content/metadata versions and changed-field flags through
a separate XPC selector. Creation-only folder naming retains its existing path. Selected
packages and package destinations are refused. `SourceReaderBridge.folderOrganizationEnabled`
stays false in the normal build; only an isolated disposable Finder candidate may enable it
for the remaining runtime checks. The routing change passes all required VM checks with 492
tests, one optional skip, no Swift warnings, six encoder and 57 SMB-status cases. Evidence:
`m22-provider-routing-checks.log`. The isolated enabled candidate's results follow.

## Signed Finder checks, 2026-10-30

Finder rename, move and case-only rename passed on the disposable loopback SMB fixture.
The normal build remains disabled. New-folder creation failed, and the run did not establish
parent-scoped departure/arrival enumeration, real callback replay or interruption recovery.

The normal app candidate used its original sandbox entitlements, a new location and 11 small
fixture files in macOS VM 1, macOS 27.0.1. Its required checks passed before signing, and strict
signature verification passed before the approved temporary installation. Cache state was
uncontrolled. No physical-Mac or NAS performance claim follows.

The parent browsed the complete fixture, downloaded one ordinary child and the root neighbor,
and kept an independent child and a descendant folder. Baseline fetch callbacks completed
before the first snapshot. Finder then renamed the populated folder, moved it to another
parent, changed only its name's case, and refused both occupied destination names. Both
collision refusals happened in Finder before a provider callback, so they do not establish
provider collision handling in this run.

Independent backing audits through the relisted snapshot matched identities, file contents,
mtimes, modes and attributes. Catalog item IDs, content versions and independent/inherited
keep flags matched. Four downloaded files retained their local device, inode, size and complete
digest with materialization disabled. The fetch hook recorded their initial downloads and no
affected fetch during the preservation interval. The unopened child remained dataless.
All three organization callbacks completed successfully and matched the production
`folder_move` route. There were no trace-failure logs.

The immediate move snapshot lacked completed old-parent departure and new-parent arrival
enumerations. Browsing both parents and the moved descendants again did not supply those
parent-scoped callbacks. Working-set updates and correct visible contents do not close that
gate. No identical repeated mutation callback was observed. Stale changed-base and preserved-base
save publication, a real crash, one-view-only interruption and ambiguous names also remain open.
Before/after recording is unavailable: automatic approval review rejected interaction with
the screen-recording permission prompt. No permission was granted.

New Folder at the location root produced Finder placeholders named `Named` and `untitled folder`.
The first create callback failed with Cocoa error 513 after a successful SMB connection; an
automatic follow-up failed with File Provider error -2005. No initial-name route completed.
The backing tree contained one new empty `untitled folder` with mode 000, but the outbox held
only a `prepared` record without a server identity. The named-stage audit failed with
`newly-named-folder-missing`. This is incomplete creation, not a naming pass. Earlier M19/M20
fixtures also showed mode-000 directory creation; this run did not isolate its server cause.

Source inspection found that the adapter cleared creation uncertainty after access-denied or
permission-denied replies. A server can leave a created directory despite such a reply. The
adapter now retains uncertainty for those responses after sending CREATE. This change does
not establish ownership of the existing directory or repair its permissions. Six deterministic
response/encoding cases now pass in the required VM checks (`m24-admission-fixed-checks.log`).

Direct SMB connections in this run took about 20 seconds and triggered the share's 15-second
unresponsive status. Finder's initial transient error recovered with Try Again. These are
observed loopback connection delays, not a transfer-rate measurement. No server settings changed.

The saved app was restored and re-registered with unchanged entitlements, and remains stopped.
The task location, uncertain create record, empty server directory and all evidence remain for
investigation. The pending-create policy prevents ordinary location removal. Apple SMB-service
restoration and final fixture cleanup remain owed for the ongoing test session.

Private evidence in `.local/phase4/m21-20261029` includes `m22-finder-candidate-checks3.log`,
`m22-finder-runtime.jsonl`, `m22-finder-fixture-20261030`, the `m22-finder-captured-*` snapshots,
`m22-finder-failed-create-inspection` and `m22-finder-app-restore.json`. The failed named audit,
backing metadata and parent-enumeration follow-up are retained beside the successful audits.

## Recovery from descendant spelling and source-ancestor changes

Source recovery now treats a descendant with the same identity but different exact spelling as
departure of the admitted name binding. A complete protected parent listing must prove it.
The old item ID retires; ordinary discovery creates a new ID without transferring the old
download or independent keep request. The same identity under the exact admitted name still
refuses retirement, and preserved descendants keep the existing strict checks.

After a durable `moved`, `verified` or `recovering` checkpoint, protection checks only the
destination ancestor chain. Changes confined to the old source chain no longer block recovery.
Prepared and uncertain attempts still require both chains. Verified/recovering retries skip the
redundant first proof; completion still obtains fresh protection and verifies or replans every
catalog after Settings. No persisted format changed.

Eight regression tests cover spelling changes, directory-descendant retirement, refusal of
unproven retirement and ancestor checks before and after move proof. Independent source review
found no blocker. Required VM checks pass with 565 tests, one optional skip and no Swift warnings
(`m24-review-followups-fixed-checks.log`). The first run found one older assertion that still
rejected proved case-only retirement; it now rejects preservation of that old binding. The new
retirement tests cover discovery with fresh IDs and no transferred keeps. The signed probe's
Settings hook now checks destination parents, matching production. Selected signed Settings-gap
results follow. Root departure and destination-ancestor changes remain unresolved until restored; retiring the
moved root is not authorized.

## Settings-gap runtime checks, 2026-10-30

The signed standalone gap helper builds with zero Swift warnings and passes strict signature
and unchanged-entitlement checks. It uses the same approved loopback fixture in VM 1, with
uncontrolled caches, private catalogs and private Settings. It is not installed.

The first spelling phase completed the case-only move, retired the admitted child binding,
and discovered a new ID with no inherited keep or edit version. It then failed an assertion
after 81.2 seconds: requesting the historical receipt under the new ID correctly throws
`unresolved`, while the helper expected no receipt. The failed-phase audit confirmed object,
byte and metadata preservation within the phase's rename boundary, apart from the allowed Samba
DOS attribute addition; it did not accept a final layout. This is partial evidence, not a
spelling-phase pass. The helper
now checks the retained receipt under the old ID and requires rejection under the new one.

The independent ancestor phase passed after 181.9 seconds, with a passing backing audit.
Renaming and replacing the old source-only ancestor allowed completion without a recovery plan.
Replacing the destination ancestor kept the intent verified and the namespace blocked; restoring
it allowed retry and unchanged completed replay. Raw evidence remains under
`m22-gap-BDD7AB53-431C-41D6-8E27-79977095FBE8*` and `m22-gap-probe-*` in the private session.

The retry phase passed after 222.4 seconds, with a passing backing audit. After the helper
finished the owner view and moved the root away, completion stayed unresolved. Restoring the
root changed its metadata and triggered a metadata-only replan; both views finished with
identities, content versions, keeps and paths preserved. This did not exercise an unchanged
target finishing only its remaining view. A second case injected a Settings failure, saved a
recovery plan before applying it, then completed from that plan unchanged. Both completed
replays passed. These checkpoints were injected; they are not real crashes.

The corrected spelling helper passed the case-only case in fresh run
`0EF3B962-1117-4E6D-8CC2-996BF7D4067C`. It proved exact SMB spelling, retirement of the old ID,
discovery under a new ID without a keep or edit version, the historical receipt's old binding,
unchanged sibling state and completed replay. The saved keep retained its admitted spelling
under the destination. The NFC-to-NFD case was unavailable: the initial native listing already
returned NFD for the NFC backing name, so no move was attempted. The 81.3-second phase exited
unsuccessfully and its full backing-layout audit is **incomplete**, not passed. It nevertheless
checks the passing case's exact layout and the untouched Unicode case.

The corrected `m22-gap-probe2` build and signature checks pass with zero Swift warnings and
unchanged entitlements. An independent Finder copy after both runs confirms original Settings
equality. Evidence remains under the two run IDs above, `m22-gap-probe2-*` and
`m22-gap-settings-comparison.json`. The synthetic audit regression also confirms that a
normalization-only result cannot hide an unexpected sibling rename.

Directory-descendant spelling changes, a usable Unicode-spelling fixture, fresh-process gap
retry, actual controller Settings work, downloaded-copy invalidation, parent-scoped provider
enumeration and real crashes remain unverified. Moved-root retirement remains unauthorized.
These results do not enable folder organization or complete M22.
