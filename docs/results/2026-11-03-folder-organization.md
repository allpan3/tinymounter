# Folder organization on Linux Samba

Date: 2026-11-03. Status: integration in progress; normal-build folder capabilities remain off.

Signed Finder organization and recovery at all seven tested crash checkpoints now pass in one
registered view. Item IDs, downloads and keeps survive unchanged contents. A concurrent edit
retires a child whose reported creation time changes; genuine stale-save callbacks remain open.
Recovery between two catalogs also passes. Folder capabilities stay disabled.

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
