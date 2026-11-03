# Folder organization on Linux Samba

Date: 2026-11-03. Status: integration in progress; normal-build folder capabilities remain off.

Signed Finder organization and recovery at all seven tested crash checkpoints now pass in one
registered view. Item IDs, downloads and keeps survive unchanged contents. A concurrent edit
retires a child whose reported creation time changes. A same-identity change preserves its ID,
and a genuine stale save publishes a separate conflict copy. Recovery between two catalogs also
passes. Combined rename/modification-date replay and the parent-enumeration checkpoint repair
pass signed checks. Crashes followed by an independent SMB move or replacement retire both
views' old bindings and keeps; fresh items never inherit their downloaded bytes.
The literal-server-name repair passes signed Unicode-respelling recovery in both views.
Case-colliding and Unicode-equivalent names block recovery without changing original content;
removing the synthetic collisions permits completion with IDs, downloads and keeps preserved.
Folder capabilities stay disabled.

## Setup and evidence

The signed single-client candidate runs in macOS VM 1, macOS 27.0.1, against Samba 4.19.5
on the TinyMounter Samba Test VM. The share requires encryption and uses ext4 with
`acl_xattr` and `streams_xattr`. Caches were uncontrolled; this is a correctness check.
The original NAS and physical-Mac installation were untouched.

`Tools/prepare-folder-candidate.py` prepares a separate VM checkout from committed source.
It reuses the existing Finder callback and materialization probes, enables organization only
when requested, and exports fixture evidence through an explicit local folder-picker grant.
It preserves the normal app lifecycle and sandbox. App/provider sources in that checkout are
generated test instrumentation, not production edits.

The fixture has 11 small files. Four complete local copies were hashed with materialization
disabled, including an independently kept file and a file kept through its parent folder.
The unopened child stayed dataless. The disabled baseline sent real rename callbacks that
returned Cocoa error 513. Finder's Undo restored its original name. On candidate replacement,
macOS replayed that original-name callback successfully before the next rename gesture.
Matched recordings capture the refused and enabled rename attempts.

The enabled attempt renamed the directory on the server but returned File Provider error
-2005. The exported intent is `verified`, with no finished domain. Its parent file ID is
unchanged; the reported creation time changed from 1793708655571160 to 1793709053817444
microseconds since the Unix epoch. Independent Linux `stat` shows an unchanged actual birth
time and inode. The SMB value follows the new directory modification time.
[Samba's documentation](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html#FAKEDIRECTORYCREATETIMES)
describes this directory creation-time behavior. No server setting was changed to suppress it.

Raw evidence stays in the VM's `results/folder-single-20261103/`: exported `baseline/`
snapshots/events, before recordings, build/check logs and `parent-identity-after.json`.
Linux inventories remain under `/tmp/tinymounter-folder-<run>/`. An earlier interrupted
fixture setup remains preserved separately; it never registered a location. The first setup
also exposed two initial SMB connection failures followed by successful ordinary retries.

## Parent evidence checkpoint

The repair records updated parent creation times at the durable `moved` checkpoint, before
closing the original protected parent handles. Paths, names and file IDs must remain unchanged.
After this checkpoint, parent evidence is immutable again. A fresh connection cannot accept
a changed creation time just because the pathname or file ID matches.

The focused package check passes 93 folder catalog/transaction tests on the host. Three added
tests cover checkpoint/retry, refusal after protection is lost, and refusal of replacement
directories or later evidence changes. Signed verification of the repair is next.

A lost connection between the remote rename and this checkpoint can still leave an operation
unresolved on a server with changing creation times. The earlier pending move remains intact;
the repair does not manufacture missing historical evidence. This boundary and the remaining
Finder, crash and overlapping-view checks still gate enablement.

## Signed repair verification, 2026-11-03

Build 14, a separate signed `dev.tinymounter.foldercheck` candidate, completes Finder rename,
cross-folder drag, case-only rename and fresh parent/descendant listings. All 19 original
catalog IDs and content versions survive. The four downloaded files retain their local
inodes and full digests; independent and inherited keeps remain intact. The four initial
downloads have successful fetch traces, with no further fetch during the preservation checks.
Completed working-set batches deliver the moved folder and all five known descendants.
The transaction records are completed, with their domain completion recorded.

Independent Linux inventories after each step preserve all 19 original object identities,
modes, owners, attributes and file contents and modification times. Finder refuses both
occupied folder and file names before a mutation callback, so these gestures do not verify
provider-side collision handling. New Folder followed by naming retains one item ID and
uses the general folder-move route when that capability is enabled. The new empty folder has
server-created mode 0777 and a DOS attribute, unlike the hand-created mode-0700 fixture.
The initial audit's assumptions about this new object's mode and attributes failed; every
preexisting object still matched. No permissions were changed to make that audit pass.

The required VM checks pass at the repair commit: 624 tests, one optional skip, no failures
or Swift warnings, plus project, CLI, app-build and SMB checks. Evidence is in
`results/folder-single-20261103/repair/`, including snapshots, callback events, preservation
reports, route logs and `after-repair-rename.mov`. Independent inventories remain in the
Linux run directory. The earlier failed rename remains preserved in its separate app.

`--crash-checks` in the candidate preparer adds optional stop points for the reserved
`Recovery/` subtree. A control names the run, item, source path, checkpoint and unique control
ID. The app exports its durable intent through the granted evidence directory, then stops
for the operator to kill that exact process. These hooks change only generated candidate
sources. Crash recovery, overlapping views, changed descendants and stale editor saves remain
unverified in this candidate; the loss-before-parent-checkpoint boundary remains open.

## Crash recovery and temporary sharing failures, 2026-11-03

Build 15 stops at the requested durable checkpoint and is killed with SIGKILL. Fresh-process
recovery passes before the server rename, after the moved checkpoint, and after verification.
All 20 catalog IDs and versions, six downloaded local copies and keep selections survive.
Independent Linux inventories match the original objects and contents after each recovery.
Finder retries the interrupted callbacks and receives successful replies.

A crash after catalog settlement leaves the intent verified. The first three recovery attempts
fail with SMB sharing error 26, and no later automatic attempt follows. The server has no
remaining fixture handles when inspected later. Retry Pending Changes then completes without
changing contents or downloads. This establishes a temporary sharing failure and missing retry;
it does not isolate which handle caused the initial refusal.

Pending file and folder renames now schedule another protected recovery attempt after a sharing
error, backing off from two seconds to a maximum of one minute. One timer is active per location;
successful recovery resets the delay, and closing the location cancels it. Other failures retain
their existing handling and every retry still revalidates the durable intent. This repair awaits
the next signed test, including a deliberately held competing file handle.

Build 15 and the required VM checks pass without Swift warnings. Evidence includes the
`fault-control-*`, `fault-hit-*`, `fault-killed-*`, `recovery-*` reports and
`catalog-crash-recovery.log` in the repair directory. The failed first catalog audit remains;
`replay.json` records the successful manual retry, not a claim of automatic recovery.

Build 17 passes the required VM checks and the held-handle test. After the Settings checkpoint,
a second process opens the fixture child for writing without changing bytes. The app is killed
and restarted while that handle stays open. Recovery receives error 26 and schedules retries
after 2, 4, 8 and 16 seconds. After the handle closes, the intent completes without manual retry.
All 20 rows, six local copies, keeps and the independent server inventory match their baseline.
The evidence is `sharing-hold-*`, `sharing-retry-*` and `recovery-settings*` in `repair/`.

Finder still retains the failed callback after this server recovery. Its next rename carries
the earlier metadata version and fails before any server change. The attempted finished-domain
checkpoint therefore never fires; its failed Linux audit is preserved. Successful background
recovery now also signals File Provider that the synchronization error is resolved, so macOS
can replay the original callback and receive its completed receipt. This notification repair
awaits a signed test.

Build 18 passes the repeated held-handle test, including an automatic successful Finder
callback after server recovery. The next rename reaches its catalog checkpoint and recovers
after SIGKILL. Stops after domain completion and immediately before the callback reply also
recover. Together with the earlier runs, all seven instrumented points pass in one view.
The required checks pass with 624 tests, one optional skip and no Swift warnings. Evidence is
`sharing-signal-*`, `recovery-settings-retry*`, `recovery-catalog-retry*`,
`recovery-finished-domain*` and `recovery-before-reply*` in `repair/`.

## Concurrent changes and open documents

With both recovery documents open in TextEdit, the app stops after the Settings checkpoint.
An independent Linux process changes one child in place, then the app is killed and restarted.
Recovery preserves 19 catalog IDs and five unchanged local copies without another fetch.
The changed child's Linux inode survives, but its SMB creation time changes from
1793709716943157 to 1793709716944184 microseconds. The identity check therefore retires its
old binding and discovers a new, dataless item. It does not associate the stale local bytes
with that new item. A same-identity content-change case remains unverified.

TextEdit refuses both saves before a contents callback. Its log records a sandbox extension
failure at the new path during the folder rename. A matched local APFS control, without a
provider or crash, gives the same refusal. Opening the unchanged document again through Finder
restores access in both cases. Its real contents callback then uses the original verified edit
base and publishes to the same server inode. The changed document's unsaved text is exported
through TextEdit to a local file and verified; no stale-base contents callback was observed.
The external server contents remain intact. No sandbox entitlement or permission was changed.

The post-save Linux audit preserves every object identity, mode and owner. Besides the intended
content and timestamp changes, it finds a new `user.DOSATTRIB` on the saved file. It remains failed pending
inspection of the SMB attributes. Evidence includes `concurrent-*`, `textedit-save-refusal.log`,
`stale-document-export*` and `recovery-signal-restored.json` in `repair/`, plus the separate
`sandbox-control/` reports. The helper now exports edit-base attributes for that inspection.

`--overlap-checks` prepares the next candidate. A scoped `overlap-setup` request adds one second
registered view through the normal controller. Snapshots and provider events cover both views,
and catalog/domain crash checkpoints record both catalogs before the kill. The earlier
single-client pending move remains preserved separately.

## Recovery across two registered views

Build 19 passes recovery after a crash between catalog updates and after the first domain
completion. The first stop exports one catalog at the old path and the other at the new path.
The second exports both catalogs at the new path, with only one domain marked finished.
After SIGKILL and ordinary restart, both operations complete automatically in both views.

The primary view preserves all 20 IDs and six downloaded copies. The second view preserves
all 10 known IDs and two downloaded copies, including its inherited Keep Downloaded requests.
Content versions, local file identities and digests survive, with no further fetch callbacks.
Independent Linux inventories preserve all 20 objects and their contents, modes, owners and
attributes. The known saved-file attribute change is already present in this baseline; these
checks do not repair or excuse it. Required VM checks and the candidate build pass without
Swift warnings. Evidence is `overlap-*` and the two corresponding `fault-hit-*` reports in
`repair/`, plus the Linux `overlap-*-audit.json` reports.

## Save work name and hidden attributes

The exported edit base confirms attributes `0x22`, hidden plus archive, on the saved original.
A separate small-file probe uses the built SMB adapter on the same encrypted Samba share,
with uncontrolled caches. Moving a fresh ordinary file to a dot-prefixed work name adds
those flags before any content write. A rename-only control also retains hidden status after
restoring the public name. The Samba source explains the result; see the
[source review](../research.md#samba-hidden-attributes-during-save-2026-11-03).

The matched work name without a leading dot produces only the normal archive flag, `0x20`.
An initially hidden file stays hidden. Identity, complete edited contents and the security
descriptor survive both cases; the Linux audit preserves modes and owners. Private-stage
creation, write and conflict-name publication were also checked. Both dot-prefixed and ordinary
stage names publish without a hidden flag in this configuration.

The implementation changes only the original's work name to `tinymounter-<operation>.work`.
It retains exclusive rename, copy, verification and recovery, and never rewrites attributes.
Other SMB clients may show the work file; the write-setup text now says so. Stage and backup
names remain hidden. Finish or export earlier prototype saves before installing this naming
change. Existing incorrectly hidden files are not silently modified. Evidence is
`save-work-attributes*` and `save-stage-attributes*` under
`results/folder-single-20261103/`, with the separate Linux save-attribute inventory.

Build 20 passes a real TextEdit save on the existing ordinary file. Its server identity survives,
its attributes become archive-only, and both views show the verified new contents without pending
saves. The independent audit preserves every unrelated object and attribute. The required VM
checks pass with 626 tests, one optional skip and no Swift warnings. Evidence is `save-ready*`,
`save-visible*` and `checks-work-name.log`.

## Same-identity changes and a genuine stale save

The completed save gives Samba a stored creation time. At the next folder move's Settings
checkpoint, an independent Linux writer changes that file in place while preserving its
identity and attributes. TextEdit was opened through Finder at the new folder path before
the external edit. Its local save carries the earlier verified content version through a real
contents callback, avoiding the invalid old-path sandbox grant from the previous test.

After SIGKILL and restart, both views preserve the original IDs and unchanged downloaded bytes.
The changed file keeps its SMB identity, receives a new content version and retains its external
contents. The stale local contents publish as one separate conflict file; both views discover it,
and inherited Keep Downloaded applies in the second view. The successful callback requests a
refresh of the original only after conflict publication. Three fetches cover changed contents
and the new conflict; no unchanged file is fetched. Both outboxes have zero pending saves.
The independent Linux audit preserves all original objects, modes, owners and attributes, with
only the deliberate main-content change and new conflict. Evidence is `recovery-same-identity*`,
`same-identity-preservation.json` and the Linux `same-identity-*` reports.

During the concurrent-save test, Finder adds the folder's modification date to its rename replay.
The provider rejects that combination with Cocoa error
513 even though server recovery completed. Organization now permits this specific combination
and returns the modification date as unsupported pending metadata, as the existing metadata-only route
does. It still rejects other unverified combinations. This routing repair awaits signed replay
validation; the saved contents and completed server move remain safe.

Build 21 still rejects replay. Its first repair misidentified field 128 as last-used date;
the installed SDK reports content-modification date as 128 and last-used date as 8. The corrected
route follows those values and requires another signed check. The failed traces remain preserved.

Build 22 passes the combined rename/modification-date replay: the name completes and only the
unsupported date remains pending. Both outboxes are empty. The required VM checks pass with
626 tests, one optional skip and no Swift warnings. Evidence is `recovery-replay-fixed*` and
`checks-modification-date.log`.

## Parent enumeration before the checkpoint

The next cross-folder move reaches verified catalog settlement but never reaches its requested
finished-domain stop. A later test action moves the exact synthetic root aside before that
failure is understood. The intended crash test is invalid: no stop or kill occurred. Its
snapshots and failed commands remain preserved. One accidentally started second app instance
was stopped; the original process and pending intent remain.

The stored parent identity differs from a fresh query only in creation time. Linux timestamps
show that the earlier SMB value matched access time; a later directory read advances it beyond
modification time. A bounded two-directory probe with the installed SMB library reproduces the
change: querying metadata after rename alone is insufficient. Reading both protected directories
first produces values that survive handle closure and reopening. Caches were uncontrolled;
this is correctness evidence, not a performance comparison. The probe's first open failed
because its synthetic directories had the wrong owner; using their existing fixture parent's
owner corrected that setup error.

The adapter now reads one directory page through each still-protected parent handle before
capturing its identity. It retains the same file-ID checks and permits creation-time updates
only while the original rename protection is held. The read is not treated as a complete
listing. Previously unresolved intents do not gain new historical evidence from this fix.
Evidence is `parent-check-first.json`, `parent-check-listing.json` and
`repair/retirement-parent-inspection.json`. Signed verification is next.

Builds 23–24 pass signed cross-folder moves and the following interruption checks. Build 24
adds bounded unique `check-` snapshot labels to avoid rebuilding instrumentation for each
report. The production adapter is unchanged between these builds. The required checks at the
adapter repair pass with 626 tests, one optional skip and no Swift warnings. The single-page
probe also passes; evidence is `parent-check-one-page.json` and `checks-parent-listing.log`.

The earlier pending intent needed explicit restoration of its synthetic parent's modification
time to recover; this was a fixture intervention, not an automatic-recovery success. It then
retired both views' old IDs and keeps, and fresh discovery produced dataless items. That evidence
is `overlap-rediscovered*` and the Linux `retirement-parent-restoration.json`. No production
metadata rewrite or relaxed identity check was added.

## Signed moved-away and replaced-root recovery

A fresh cross-folder move stops after one view finishes. After confirming SIGSTOP and the
durable record, SIGKILL terminates that exact process. A separate SMB client moves the original
folder again. Its first 15 opens receive sharing error 26; after the server releases the old
handles, the same protected no-replace rename succeeds. Ordinary restart completes recovery
in both views. The old folder and three child IDs retire; keeps reset, and fresh discovery
produces new IDs with three dataless children in each view. The four downloaded neighbors
retain their inodes and digests. Both outboxes remain empty and unrelated Settings are intact.

A second run stops between catalog updates. After SIGKILL, the independent SMB client moves
the original aside, then exclusively creates a different folder at the expected destination
with a same-name child containing different bytes. Recovery completes in both views, retires
their four old IDs and keeps, and discovers both folders with new IDs. All four newly discovered
files are dataless in each view. The replacement remains unchanged and the original contents
remain intact at the other pathname. Working-set callbacks deliver all retired IDs. The replay
returns the existing changed-version error instead of reporting a successful original move.

Independent Linux inventories verify every preexisting object identity, file digest, mode,
owner and attribute in both runs. Only the deliberate moves, parent timestamps and new
replacement objects differ. Neither clean run restores a timestamp. Evidence is
`repair/check-parent-*`, `check-retirement-*`, `check-replacement-*` and the associated
`fault-hit-*`/`fault-killed-*` records. Linux audits are `parent-listing-move-audit.json`,
`retirement-smb-recovery-audit.json` and `replacement-smb-recovery-audit.json`.

## Literal server spelling during recovery

After a Settings checkpoint and SIGKILL, an independent libsmb2 client renames an NFC child
to NFD without the app's path normalization. Its no-replace operation preserves the child's
inode and complete digest; the parent has a stored creation time. Restart leaves the folder
intent verified but pending with POSIX error 2. The old child ID and its downloaded copy remain.
The adapter normalized both the requested path and the literal server entry, considered them
equal, then tried to open the now-absent NFC pathname. This also disproves the earlier claim
that no SMB client can distinguish those spellings.

Folder-move admission, settlement and recovery now compare literal server names with the
normalized requested pathname. Complete protected listings can retire the changed binding;
they cannot preserve it merely because Unicode normalization makes the names equivalent.
NFD catalog names still match NFC server names. The focused host suite passes 102 tests,
including server-respelling retirement, refusal to preserve that binding, native catalog
normalization and the special Unicode ranges the client sends unchanged. Evidence is
`check-spelling-*`, `check-unicode-respelling.json` and the independent
Linux name-byte and digest inspection in the same VM session.

Build 25 recovers the pending move in both views. Only the respelled child's old ID retires;
the folders and every other catalog row preserve their IDs, versions and keeps. Working-set
enumeration delivers both old-ID deletions. Each newly discovered child starts dataless, and
the eight downloaded neighbors retain their inodes and digests. Pending moves and saves clear,
with unrelated Settings unchanged. The required VM checks pass with 628 tests, one optional
skip and no Swift warnings (`checks-stored-name.log`).

The new child inherits its parent's keep request, but its server-stored NFD name remains
unsupported for reads. After an independent no-replace SMB rename restores NFC, a fresh fetch
downloads the correct bytes under the new ID; the retired ID stays absent. This does not prove
general support for server-stored NFD names. Evidence is `spelling-preservation-report.json`,
`check-spelling-opened*` and the Linux `spelling-restored-audit.json`.

## Ambiguous directory names

Two fresh moves stop at the durable attempting checkpoint, before the server rename, followed
by confirmed SIGSTOP and SIGKILL. One run adds an unseen case-colliding child pair; the other
adds an unseen NFC/NFD-equivalent pair. Independent complete SMB listings return both exact
names. Every protected parent and the selected root still match their recorded identities,
so a changed root identity cannot explain the refusal.

Restart leaves each move attempting and the original server folder untouched. No original
object, file bytes, ownership or attributes change. Removing only the two recorded test files
and restarting completes the original move in both views. All catalog IDs, versions and keeps
survive, as do the downloaded copies' inodes and complete digests. No pending move or save
remains. The final backing audit finds exactly the original objects under the planned folder
name; all four collision files are removed.

Evidence is `check-case-collision-*`, `check-unicode-collision-*`, both `*-collision-protocol.json`
reports, the crash controls and `collision-preservation-report.json`. Linux creation, cleanup
and final inventories are `case-collision-*`, `unicode-collision-*` and
`collision-final-audit.json`. These checks close the earlier unavailable ambiguous-name cases.
Loss before the protected-parent checkpoint and changed destination ancestors retain their
documented uncertain outcomes; no identity check or capability gate was relaxed.
