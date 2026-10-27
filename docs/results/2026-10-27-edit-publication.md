# Existing-file publication gate

Date: 2026-10-27. Decision status: M19 design accepted; exclusion gate blocked.

The approved disposable VM probe passed the mixed native/direct SMB publication sequence.
It also proved that a program accessing the server's backing filesystem can change, rename
or unlink a file while SMB protection is held. This server/path cannot meet the accepted
exclusion requirement. Editing remains unsupported; no app behavior changed.

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

Do not enable same-name publication on this fixture. The next design decision is whether to
restrict editing to a separately established SMB-only deployment boundary, or save edits as
separate copies where exclusion cannot be established. The latter changes normal Save
behavior and is not silently substituted for the accepted feature. A general solution needs
server-side coordination covering all permitted writers; it is not established by this probe.

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

The proposed follow-up is an explicit SMB-only folder boundary: every writer must access the
folder through SMB, including server applications. That scope decision is awaiting the user;
permission to create the temporary fixture did not approve a weaker safety boundary.

Signed editor saves, crash/interruption recovery, metadata preservation, ancestor protection
and matched recordings remain unverified. No M19 app build was installed. The original NAS remains read-only for
agent testing; no physical-Mac change, push, publication or merge occurred.
