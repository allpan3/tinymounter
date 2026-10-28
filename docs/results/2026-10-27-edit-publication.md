# Existing-file publication gate

Date: 2026-10-27. Decision status: M19 design accepted with a subsequently approved SMB-only writer boundary.

M19 remains blocked at concurrent metadata preservation. The approved Samba fixture exposes
access rules, but a competing SMB client can change them, change the modification time and
write a named stream while the proposed file guard is held, even with all sharing denied.
The main contents stay protected. Editing remains unsupported; the app's safety boundary has
not been relaxed. The temporary server, installation, fixture and credential are removed.

The approved disposable VM probe passed the mixed native/direct SMB publication sequence.
It also proved that a program accessing the server's backing filesystem can change, rename
or unlink a file while SMB protection is held. The user subsequently accepted limiting
editing to folders whose writers all use SMB. No app editing behavior changed.

## Setup and observations

macOS VM 1 reported macOS 27.0.1. The fixture used Apple's SMB server on loopback, guest
access, native SMB payload writes and the vendored libsmb2 for protected handles and renames.
All files were synthetic. Caches were reused and uncontrolled; no performance claim is made.
Fresh user permission covered temporarily starting the unloaded SMB service, disabling the
saved export, enabling guest SMB access, then restoring the exact prior settings.

The initial protocol run passed complete native upload under a direct identity guard,
write/delete exclusion, preservation on rename collision, two no-replace renames, full
readback, stable server identity after reconnect, protected recovery cleanup, and a competing
create in the publication gap. Both remote versions survived the collision, and the staged
edit published under a conflict name. The old pathname was absent between the renames,
as accepted. This was a CLI protocol check, not a signed app or editor test.

A separate backing-filesystem check used a synthetic file owned by the local test user.
That user successfully wrote different bytes, renamed the file and unlinked it while the
SMB handle denied write/delete sharing. The protected handle read the changed bytes and
remained readable after unlink. An earlier attempt against a guest-owned file failed local
write permission; that was an ownership check, not evidence of SMB exclusion.

The committed --check-backing-access probe reproduced the bypass. After a local rename and
same-name replacement, the SMB handle still renamed the checked old file and preserved the
competing pathname. However, its contents had already changed; the local user could then
unlink that recovery file while the SMB handle remained readable. Stable handle identity
therefore did not establish immutable contents or survival at the recovery pathname.

## Implication

SMB share modes protect against the tested SMB clients, not every writer on the server.
Full readback cannot close the interval between validation and mutation, and successful
readback through an open handle does not establish that a pathname still names that file.
Changing payload uploads to libsmb2 would not repair this server-side limitation.

The user accepted an SMB-only deployment boundary after this result. Within that boundary,
same-name publication still requires all remaining checks, including permission preservation.
A general solution covering server-local writers needs server-side coordination; this probe
does not establish it. Saving every edit separately would change normal Save behavior and is
not substituted for the accepted feature.

## Verification and evidence

Tools/run-checks.sh passed again after the probe changes: 232 tests executed, one optional
writable-fixture skip, no failures, successful project/release CLI/benchmark/unsigned app
checks, no Swift warnings.
The C helper compiled without output. Sources are Tools/check-edit-publication.c and .py.
VM evidence is .local/phase2/m19-protocol-first.json, m19-local-interference.json,
m19-protocol-backing.json, m19-probe-build.log and m19-protocol-required-checks-final.log.

Cleanup verified all eight remaining files against their synthetic contents and inventory
before deleting them. The fixture and mount are removed; the saved share dictionary and
launch override match the private snapshot exactly. SMB is unloaded, guest SMB access is off,
and guest login remains off. m19-edit-cleanup.json records those checks. The cleanup helper's
final mount-directory removal found it already absent after unmount; independent checks
confirmed that restoration had completed.

The accepted follow-up is an explicit SMB-only folder boundary: every writer must access the
folder through SMB, including server applications. Existing write-enabled
locations still require a separate editing opt-in.

Signed editor saves, crash/interruption recovery, metadata preservation, ancestor protection
and matched recordings remain unverified. No M19 app build was installed. The original NAS remains read-only for
agent testing; no physical-Mac change, push, publication or merge occurred.

## Follow-up implementation

The user approved reopening the same disposable VM share for the remaining checks. A separate
private snapshot covers this second session. The metadata probe confirms that
an already-open SMB writer prevents acquisition of the replacement guard. Security queries
for owner, group and DACL, individually and together, return STATUS_NOT_SUPPORTED through the
guest connection. Named-stream queries succeed. Permission preservation is not established.
The user approved an authenticated disposable test account. It was temporary and non-admin,
with no login shell or secure token. Its generated password was kept in Keychain and supplied
to the fixture probe in memory.

The local EditOutbox foundation retains each save generation independently, including extended
attributes, with a content and metadata digest. Strong base receipts are immutable and use an
e1 token distinct from existing f1 fingerprints. Incomplete and orphaned content blocks removal;
completion requires the recorded publication identity and complete content. This code is not
yet connected to File Provider callbacks or remote writes. All eight focused EditOutbox tests
passed in macOS VM 1, including metadata retention and replay after reopening the outbox.

The catalog/settings foundation migrates formats 1–4 to 5 to represent separate editing
permission and strong content versions. This compatibility boundary makes older builds refuse
records they cannot preserve. Existing locations retain their write grants and keep requests,
with editing off; catalog rows keep their IDs, epochs, anchors and legacy content versions.
Verified same-item commits preserve item identity and keep requests; conflicts have separate
rows. These operations are not yet exposed by the app. Tools/run-checks.sh passed in VM 1:
244 tests executed, one optional fixture skip, no failures, and all required builds passed
with no Swift warnings. The build emitted the existing AppIntents extraction notice.
Evidence: .local/phase2/m19-foundation-required-checks.log.

## Authenticated metadata check

The direct client authenticated with the temporary account and requested signing and encryption.
The native client mounted the same loopback share using a private password prompt. NetFS returned
EHOSTUNREACH for this connection; mount_smbfs succeeded. No password was put in a URL, command
argument, file or log. The native mount reported SMB 3.0.2 and signing enabled.

The authenticated publication probe again passed native upload under the direct stage guard,
full readback, flush and competing SMB writer/delete exclusion. An already-open writer blocked
the original-file guard. The probe stopped at the permission query before either rename.
Both the complete staged payload and previous remote contents remained intact.

Owner/group/DACL queries returned STATUS_NOT_SUPPORTED, NT status 0xc00000bb, mapped to errno 22.
The same query failed on an empty authenticated-created file and a native-created file. Native
acl_get_fd returned ENOENT, and adding an ACL through the native mount failed. A separate setup
step successfully added an explicit ACL to the synthetic backing file while no guard was held.
Direct SMB still returned STATUS_NOT_SUPPORTED, and native acl_get_fd still returned ENOENT.
Thus a missing native ACL result cannot establish that the backing file has no access rules.
Replacing it using only the native mode bits would not meet the accepted permission guarantee.

Evidence in VM .local/phase2: m19-auth-probe-build.log, m19-auth-publication.json,
m19-auth-metadata.json, m19-native-auth-metadata.json, m19-auth-explicit-acl.json and
m19-auth-backing-acl.json. These are protocol checks with uncontrolled caches, not signed
editor tests or performance measurements. The uncompiled protected-file implementation draft
is retained locally outside the build; it is not part of the app.

Tools/run-checks.sh passed after the authenticated probe update: 244 tests executed, one
optional writable-fixture skip, no failures, matching generated project, release CLI and
benchmark validation, and a successful unsigned app build without Swift warnings. The probe
also passed Python syntax compilation. Evidence: m19-auth-required-checks.log. These checks
do not satisfy M19's signed editor, interruption or matched-recording requirements.

## Second-session cleanup

All six synthetic files matched their expected complete bytes and recorded identities before
removal. The fixture and mount are removed. The saved sharing dictionary and SMB launch override
match the second snapshot, SMB is unloaded, and guest SMB access and guest login are off.
The exact test Keychain item was deleted. No matching cached NTLM credential was found.

macOS refused deletion of the temporary account with eDSPermissionError, including through
sysadminctl and administrator execution. The account was disabled until the user removed it
through an authenticated VM administrator action. A fresh directory-service query confirms
that its record is gone. Sharing, launch settings, fixture removal and absence of the exact
Keychain item were checked again; cleanup is complete. Evidence: m19-auth-cleanup.json and
m19-credential-cleanup.json. The original NAS remains read-only. No shared daemon restart, VM restart,
network interruption, physical-Mac installation or publication occurred.

At the user's request, session cleanup also closed 23 Finder windows and quit the test app.
It removed 18 obsolete build directories, whose allocated sizes totalled 1,561.1 MiB before
removal, while retaining the verified signed M18 app, current build outputs and results evidence.
This is the sum reported by du, not a measurement of physical disk space reclaimed from APFS.
The VM then had zero Finder windows and no running tinymounter test app. Evidence:
vm-cleanup-20261027.json. Future sessions must close their test apps/windows and remove obsolete
artifacts before handoff, preserving user work and useful evidence.

## Replacement fixture

Decision status: accepted. The user approved installation of the replacement test server and
its dependencies. Use a standalone Samba server inside macOS VM 1, bound only to
loopback and serving one disposable synthetic directory. Install the test dependencies only in
the VM, with an inventory for cleanup. Run smbd as a manually started test process with its own
configuration, private account database, logs and state; do not register a background service or
change Apple's saved sharing settings. Use a separate generated test password kept in Keychain.
Keep existing macOS accounts unchanged. Stop the test process and remove its data, credential
and newly installed packages after the checks.

Samba is a test dependency, not linked into or distributed with tinymounter. The current
[Homebrew formula](https://github.com/Homebrew/homebrew-core/blob/main/Formula/s/samba.rb)
provides a macOS build and identifies GPL-3.0-or-later. Its [licence](https://github.com/samba-team/samba/blob/master/COPYING)
permits private execution; distribution obligations would need review before shipping any copy.
Homebrew and Samba 4.25.1 were installed only in the VM and removed after the checks.
The standalone server listened only on loopback; no background service, shell startup change
or Apple sharing change was made.
The formula disables POSIX ACL support: permission handling must first be proved using
Samba's stored SMB ACLs, without assuming that the package satisfies this gate. Existing-file
editing stays disabled until the full protocol and signed workflow checks pass.

The probe checks competing SMB DACL, modification-time and named-stream changes under
the original-file guard. Its connection timeout is 45 seconds because the standalone server
waits for its own hostname lookup during negotiation. This changes only the fixture probe;
the app's connection behavior is unchanged.

The fixture used acl_xattr with stored SMB access rules and streams_xattr, with an everyone
default DACL for synthetic files. A private Samba account mapped to the existing VM user;
no macOS account was added or changed. Its generated password stayed in Keychain and memory.
Authenticated direct connections requested signing and encryption. Guest direct connections
failed at tree connect with STATUS_ACCESS_DENIED and a bad-signature server diagnostic;
the successful checks used the authenticated account. Production cached-GSS authentication
against this new fixture was not tested, and no app transport or guest behavior changed.

Authenticated native uploads, full direct readback, competing data-writer exclusion, exclusive
renames, reconnect identity and protected recovery cleanup passed on Samba. Owner/group/DACL
queries succeeded and the original and stage inherited matching descriptors. A direct FLUSH
through the read/delete stage handle failed with EACCES; the native writer's fsync succeeded.
The probe reports that failure and does not establish the complete durability gate.

The competing metadata check changed the DACL while the original guard denied write/delete
sharing. The altered DACL denied a data writer even after the guard closed; restoring it
allowed that writer again. The same protected file also accepted a modification-time change
and a new named stream. Follow-ups with read sharing allowed and with all sharing denied both
allowed the competing client to write 27 bytes into the stream. Full backing-file checks
confirmed those bytes and the unchanged main contents. The changed DACL still denied data
writes after the guard closed, and its restoration allowed them again. These are competing
SMB operations, so the accepted SMB-only boundary does not exclude them.

Checking permissions and streams again before a rename leaves a race after the check.
Deleting the old recovery file could then discard a concurrent stream change, and the
published file could carry obsolete access rules. The proposed sequence therefore does not
meet M19's preservation guarantee. No extra metadata restriction or separate-copy behavior
has been approved, and no editing callbacks or UI were enabled. A revised publication design
must resolve this before signed editor, interruption and matched-recording work can proceed.
Save Edited Copy was suggested as a smaller alternative but was not approved or implemented.
The current proposal retains normal Save as the goal.

Evidence in VM .local/phase2: m19-samba-auth-publication.json and
m19-samba-auth-metadata-exclusion.json, m19-samba-auth-metadata-stream.json and
m19-samba-auth-exclusive-metadata.json. The final C probe compiled without diagnostics and
the Python probe passed syntax compilation. Tools/run-checks.sh passed with 244 tests, one
optional fixture skip, no failures and no Swift warnings; m19-samba-required-checks.log records
the run. App sources were unchanged by the later fixture-probe amendments.

A separate run of the skipped native-create test failed in Foundation's directory setup with
Cocoa 513 / EACCES. It created an empty fixture directory but did not reach the upload assertions.
The directory was verified empty and removed during cleanup. This optional check is not claimed
as passing; evidence is m19-samba-native-create-test.log. It does not alter the earlier M18
results on Apple's fixture or establish a production regression.

## Standalone fixture cleanup

All six synthetic files, their complete main contents and the extra stream contents were
verified before removal. The native test mount was unmounted, and only the standalone test
server's checked process group was stopped. No listener remains. The private Samba account
database, test state, fixture, mountpoint and exact Keychain item are removed. No matching cached
NTLM credential remained. Apple's saved sharing dictionary and SMB launch override matched
the snapshot; its SMB service remains unloaded. The earlier macOS test account remains removed.

The newly installed Homebrew prefix and its 20 formulas were removed, as was the installation
cache. Their allocated sizes before removal were 300.4 MiB and 115.0 MiB, measured by du.
These are artifact sizes, not measured physical APFS space reclaimed. Eight temporary bundles
and helper files were also removed. Finder has zero windows and the test app is closed; the
verified M18 app and evidence remain. This does not diagnose the user's recurring storage issue.
Evidence: m19-samba-fixture-inventory.json, m19-samba-cleanup.json,
m19-samba-credential-cleanup.json and m19-samba-housekeeping.json. Selected evidence is also
retained locally under results/edit-samba-20261027.

No original-NAS writes, VM restart, shared-daemon restart, network interruption, physical-Mac
installation, push or publication occurred.

## Mac-only design follow-up

The user reaffirmed that tinymounter must run only on the Mac and use the server's existing SMB
service. The failed replacement experiment does not prove that a server component is required.
Normal Save remains the goal; a separate-copy-only workflow has not been accepted.

Source review found a route worth testing: preserve the original file object and its attached
metadata, back up its main contents separately, and update those contents while the original
has a temporary name. SMB COPYCHUNK works through file handles but is not atomic, so a complete
backup and withholding the ordinary name are essential. A backup inside a named stream was
rejected as the general format because common Samba storage imposes small capacity limits.
See [research W11–W13](../research.md#m19-mac-only-revision-review-2026-10-27).

The [revised proposal](../phase4-plan.md#revised-mac-only-save-proposal) requires approval for
modifying the temporarily renamed original, a longer period of unavailability, additional
SMB operations and a boundary reserving newly created transaction files for tinymounter.
That boundary is not enforceable against another program using the same account. It does not
reserve the original user file or permit dropping its concurrent permission/stream changes.
Private staging must also pass before any payload is written; no new compatibility claim is made.

This follow-up changed documentation only. No fixture was reopened, no app code changed and no
new runtime checks ran. The earlier 244-test required-check result remains the evidence for
the unchanged app sources; it does not validate the revised save proposal.
