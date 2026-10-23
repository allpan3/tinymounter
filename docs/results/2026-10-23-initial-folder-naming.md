# Initial folder naming, 2026-10-23

Initial naming is approved but remains unimplemented. The tested native SMB API cannot perform
an exclusive folder rename, and a create/delete alternative failed a replacement race. An
isolated direct SMB client passed no-overwrite rename checks. Adopting that client needs a
dependency decision; reuse of macOS-managed credentials remains unproven. M18 is not ready
for installation. No production code, dependency or physical-Mac app changed.

## Setup and method

The checks used macOS VM 1 on macOS 27.0.1 build 26A434, with a disposable APFS-backed guest
SMB share on loopback. The native mount was hidden. Sharing records and service state were
saved before setup. Cache state was uncontrolled; these were correctness checks with no speed
claim. The original NAS stayed read-only, and no NAS authentication attempt was made by the
direct client. The VM, network, normal app and Cairndex stayed running.

The native probe called `renamex_np` with `RENAME_EXCL` for an empty folder and a folder with
a child. A separate race probe checked the source identity, created the chosen destination
exclusively, then let another client replace the old source before its path-based removal.

The standalone direct client used `libsmb2-6.3`, built outside the app. The source revision is
retained with private evidence. Stock guest connection reached session setup but failed tree
connect with access denied. Diagnostics showed that it retained signing for a guest session.
Clearing signing after the server identified the session as guest enabled the fixture connection.
This diagnostic library change was isolated to the guest probe; no system or app security policy
changed. An initial development-head build also failed to connect and supplied no rename result.

## Results

| Check | Result |
| --- | --- |
| Native exclusive rename, empty folder | ENOTSUP, errno 45; source retained |
| Native exclusive rename, folder with child | ENOTSUP, errno 45; source retained |
| Create chosen folder, then remove old path | Removed the other client's replacement empty folder after a successful earlier identity check; rejected |
| Direct rename to an absent destination | Succeeded; folder identity and child bytes preserved |
| Direct rename onto an empty folder, nonempty folder or file | EEXIST in all three cases; source and destination identities and existing bytes preserved |
| Direct rename versus a competing local create | All 10 races preserved the winner. The competing create won three; rename won seven. |

The direct check establishes destination collision protection on this fixture. It does not
establish signed app authentication, source identity validation across a competing replacement,
signed or encrypted NAS sessions, catalog updates, restart recovery or Finder's initial-name
callback behavior. Ordinary native rename remains unsuitable because it can replace a destination
created after an existence check.
Delaying creation until a timer expires supplies no reliable signal that Finder's name editor
has finished, so no timing-based implementation was selected.

## Credentials and licence

An unsigned CLI and a signed sandboxed app used public GSS APIs without reading or exporting
passwords. Both could inspect five cached NTLM credentials, but none matched the mounted NAS
account under the tested name comparison. Default unsigned credential acquisition returned no
credential. The signed probe did not attempt named acquisition because no matching handle was
found. These results do not prove that supported credential reuse is impossible. No unmatched
credential was tried against the NAS. A first standalone signed CLI stopped during sandbox
initialization; the same probe in a correctly signed app bundle ran successfully.

The core `libsmb2` library and headers are LGPL-2.1-or-later; its examples use BSD 2-Clause.
Adoption requires notices, source availability and an appropriate relinking arrangement, plus
review of signing and distribution. Built-in NTLM normally takes a password or password file.
That route does not meet the app's password contract. Optional GSS support exists, but its stock
credential path does not establish reuse of the native macOS SMB login. No library was added
to the project. Sources are linked in [research](../research.md#upload-publication).

## Cleanup and evidence

The fixture mount was normally unmounted. Its verified disposable contents, backing directory
and share were removed. Sharing records and the SMB launch override match the snapshot exactly.
The SMB service is unloaded, SMB guest access is off and guest login remains off. The original
one SMB mount, normal app and both Cairndex processes remain. No test location was added.
Downloaded candidate trees and temporary signed probes were removed from both machines.
No VM, network or File Provider daemon restart occurred during this investigation.

Name-free JSON and probe sources are under ignored results/initial-folder-naming-20261023.
The VM retains m18-initial-name-native-gate.json, m18-initial-name-recreation-race.json,
m18-initial-name-direct-rename-checks.json, m18-initial-name-gss-signed-bundle.json,
m18-initial-name-cleanup.json and m18-initial-name-final-state.json in .local/phase2.
The root-only sharing snapshot stays private in the VM. No UI behavior changed, so no new
before/after recording applies. Tools/run-checks.sh passed, with 208 tests, zero failures and
one optional SMB-fixture skip after cleanup. Project generation, release CLI checks and the
unsigned app build passed with no Swift warnings. The log is m18-initial-name-checks.log.

## Next step

Decision status: proposed. Prototype `libsmb2` for initial folder naming, retaining native reads
and uploads. Keep password-free authentication as a gate, then verify source identity, durable
rename recovery, collisions and the signed Finder flow. Dependency adoption needs the user's
approval under AGENTS.md. General renaming remains deferred. Keep Both is a separate unresolved
creation failure and must not be assumed fixed by this route.
