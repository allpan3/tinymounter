# New files and folders, 2026-10-23

Decision status: M18 scope, disposable writable VM fixture and native exclusive creation are
accepted. The user accepted visibility of partial new files on other devices during upload.

Normal Finder file and nested-folder uploads passed after an approved VM File Provider daemon
restart. New Folder naming and Keep Both still fail, so M18 is not complete. The implementation
passed 208 VM tests, required builds and signed extension callback/IPC checks. Signed interruption
checks preserved pending data and blocked location removal, source replacement and write-disable.
No new build was installed on the physical Mac, and the original NAS remained read-only.

## Setup and method

The run used macOS VM 1, macOS 27.0.1 build 26A434, with an isolated guest SMB share backed by disposable local
APFS data. Sharing settings were saved before enabling only the fixture. Synthetic file contents
were 502 KiB, 1 MiB, 4 MiB and 128 MiB. Cache state was uncontrolled; this was a correctness check,
with no speed claim. The VM, network and unrelated app stayed running. macOS file-access prompts
were allowed.

The signed development app retained the installed team and bundle identity. The app uses Apple's
user-selected read-write entitlement; existing bookmarks remain read-only. The provider's
entitlements are unchanged. Strict/deep signature checks passed. The installed settings/catalog
formats migrated without changing the test location's domain. Unit tests also checked IDs,
epoch, anchors and keep requests across migrations from the supported earlier formats.

A separate signed archive added fixture-only callback probes and app stops. The probes invoked
the production create callback inside the extension and used its authenticated IPC to the app.
They did not simulate macOS scheduling that callback. App stops interrupted local staging,
immediately before exclusive remote creation, after creation and after full verification but
before acknowledgement. Each stopped app process was killed and reopened. Test hooks are absent
from the production source and ready build.

## Results

| Check | Result |
| --- | --- |
| Write permission | Existing location stayed read-only. Cancelling Enable Changes kept it read-only. Disabling changes later made signed file/folder callbacks return Cocoa permission error 513. Selecting the exact share root enabled creation. A trailing-slash comparison defect was fixed using existing path normalization. |
| Signed file/folder callbacks | Both completed through authenticated IPC. The remote 1 MiB file matched all input bytes; the folder existed on SMB. Modify and delete callbacks still returned permission errors. |
| Signed app upload and replay | A 4 MiB file matched the remote hash. Replaying the same request returned its completed receipt without another upload or pending copy. |
| Existing destination | The signed app refused a known collision. Existing fixture bytes stayed unchanged. Core native SMB tests also covered exclusive-create collisions and read-only recovery. |
| Interrupt local staging | The request and partial staging copy survived. Replay with matching complete system input restaged and uploaded the original request. Changed input is rejected by a permanent regression test. |
| Interrupt before remote create | The full local pending copy survived. No destination appeared. The ambiguous attempted operation stayed pending on replay. |
| Interrupt after create | The remote file stayed at zero bytes. Replay did not reopen it for writing; the full local pending copy stayed. |
| Interrupt after full verification | The remote 4 MiB hash matched. Replay verified identity/content and completed the original operation, then removed its pending bytes. |
| Pending lifecycle guards | Disable Changes, Remove Location and Apply each refused while pending data existed. Records and full pending copies stayed. Unknown orphan data also blocks removal. A core regression test verifies that finished-location cleanup deletes completed receipts and refuses pending data. |
| Required checks | Tools/run-checks.sh passed all 208 tests, including the native SMB fixture test, project generation, release CLI verification and the unsigned app build. No Swift warnings or skipped tests in the native-fixture run. The final check after fixture cleanup skips that optional SMB test; it had already passed with unchanged core code. |

The local staging check found a recovery defect during development. A request is now saved before
staging starts, so replay can identify and replace an incomplete staging copy only after checking
that the complete system input matches. An uncertain remote attempt is still read-only during
recovery. Only a known filename collision can accept a different destination name supplied by
macOS; the app never chooses a new name for an ambiguous upload.

## Finder follow-up after the daemon restart

The initial matched Finder paste recordings showed that read-only access refused a local copy
and write access accepted it locally. The accepted copy did not reach SMB, and no normal create
callback arrived.
File Provider's consistency check reported a disk/snapshot mismatch. Recreating the disposable
domain, supported reimport and a temporary disconnect/reconnect did not restore automatic uploads.
A separate local FSEvents observer also received no callbacks for synthetic local changes, although
the global event counter increased. These observations suggest an event-delivery problem, but do
not establish its cause or prove that production code is free of integration defects.

The user then approved restarting only the VM's File Provider daemon. The old daemon terminated,
and launchctl started a replacement. The original SMB mount and both Cairndex processes stayed.
No VM, network or other shared-service restart occurred. This cleared the scheduling failure in
the following trial; the cause of the earlier stale state remains unknown.

The follow-up used the normal signed M18 build, with no callback probes or app stops. A fresh
disposable location showed Read only by default. Its paste made no local or remote copy. Enable
Changes selected the exact fixture share root for a fresh write grant. The repeated Finder paste
then invoked the normal create callback and uploaded a 1 MiB file with a matching full hash.
Copying a nested folder created both parent folders and its 502 KiB child with a matching hash.
A 128 MiB copy showed Finder's native progress circle and matched the remote hash. File Provider
then reported isUploaded=1 and isUploading=0 for the completed file and nested-folder copies.
These checks establish normal initial-create dispatch and child scheduling for these VM inputs.

Two Finder flows remain unresolved:

- New Folder created an untitled folder remotely. Typing a name sent a separate modify callback,
  which M18 rejects because renaming is outside its approved scope. Finder kept the typed name
  locally with isUploaded=0, isUploading=1 and Cocoa permission error 513. The remote folder kept
  its initial name. A proposal to handle initial folder naming awaits the user's decision.
- Keep Both failed with Finder error code 0 for two file types. No new create callback arrived,
  and no alternative destination appeared. Both existing remote files retained their full hashes.
  A focused Finder filesystem trace reached input metadata reads but established no cause for
  the failure. Do not infer that supporting folder renaming will fix Keep Both.

VMPal initially returned inconsistent text and images. Resizing its VM window and restoring the
size refreshed capture. Matched read-only/write-enabled paste recordings and the progress
recording were captured after that refresh. Other file managers remain unverified. Physical-Mac
installation, real-NAS writes and publication are not approved.

## Cleanup

The disposable location, test server, native mount, backing files, pending test copies and inbox
are removed. Sharing records and the SMB launch override match the snapshot; the local SMB
service is unloaded, SMB guest access is off and guest login remains off. The original one SMB
connection/session is retained. Final launch reports zero locations, catalogs, domains, items,
keeps, stage files and failed reconciliation sequences. The signed fixture helper cleared its outbox and reported zero inbox files. Final direct
inspection of app-private storage from the shell is privacy-blocked.
The normal signed M18 build runs in the VM, with no test hooks. Cairndex remains running.
The follow-up fixture, including its nested and 128 MiB copies, is also removed. Sharing records
and the launch override again match their snapshot; SMB guest access and guest login are off.
The original SMB mount and both Cairndex processes remain. Clipboard contents, synthetic input
and the private CloudStorage selection file are removed.
The physical-Mac M16 installation is unchanged.

The retained callback/interruption messages passed a private connection/signing-value audit.
The ready host build has a valid strict/deep signature and is absent from both provider and
Launch Services registrations. Only the separately approved File Provider daemon was restarted.

## Evidence and next step

Private evidence is under ignored results/create-items-20261023 and VM .local/phase2. It includes
m18-final-checks.log, m18-native-final-checks.log, m18-remote-runtime.json, name-free callback/interruption messages, signature
checks, signed-observations.json and matched read-only/write-enabled paste recordings. Info-level
messages rolled out during the run; the message file is partial, and the observations file records
the signed VM tool responses from the task transcript. No connection or signing values
belong in this log or published evidence.

The daemon follow-up adds name-free m18-daemon-*.json and runtime messages in the VM, matched
paste recordings and a native-progress recording. Tools/run-checks.sh passed again on the
follow-up documentation commit, with 208 tests, zero failures, one optional SMB-fixture skip
after cleanup, all required builds and no Swift warnings. Its log is m18-daemon-checks.log.
No production code changed in this follow-up.
Resolve initial folder naming and Keep Both before claiming M18 works or proposing installation.

## Initial naming follow-up, 2026-10-23

The user approved initial folder naming while leaving general renaming deferred. The
[naming investigation](2026-10-23-initial-folder-naming.md) records the failed native rename and
create/delete routes, a passing isolated direct SMB rename, and the remaining dependency and
credential questions. No production naming code has been added. Keep Both remains unresolved.

## Keep Both follow-up, 2026-10-25

File Keep Both now passes in the final signed VM app, including repeated collisions and complete
byte comparisons. The [follow-up](2026-10-25-keep-both.md) records the permission metadata fix,
collision-error payload, limits and restored fixture state. All 232 tests and required checks
passed. The physical-Mac app remains M16.
