# Existing-file publication gate

Date: 2026-10-27. Decision status: M19 design accepted with a subsequently approved SMB-only writer boundary.

M19 remains blocked at permission preservation. Authenticated queries on the disposable
Apple SMB server return STATUS_NOT_SUPPORTED, including for a file with an explicit backing
ACL. Native SMB also fails to expose that ACL. Editing remains unsupported.

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

## Proposed replacement fixture

Decision status: proposed. Use a standalone Samba server inside macOS VM 1, bound only to
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
The VM currently has neither Homebrew nor Samba, so installation needs approval. The formula
disables POSIX ACL support: permission handling must first be proved using Samba's stored SMB
ACLs, without assuming that the package satisfies this gate. No test-server installation has
been performed. Existing-file editing stays disabled until the full protocol and signed
workflow checks pass.
