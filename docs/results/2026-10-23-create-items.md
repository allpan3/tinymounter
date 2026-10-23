# New files and folders, 2026-10-23

Decision status: M18 scope, disposable writable VM fixture and native exclusive creation are
accepted. The user accepted visibility of partial new files on other devices during upload.

Automatic Finder upload scheduling remains unverified, so M18 is not complete. The implementation
passed 208 VM tests, required builds and signed extension callback/IPC checks. Signed interruption
checks preserved pending data and blocked location removal, source replacement and write-disable.
No new build was installed on the physical Mac, and the original NAS remained read-only.

## Setup and method

The run used macOS VM 1, macOS 27.0.1 build 26A434, with an isolated guest SMB share backed by disposable local
APFS data. Sharing settings were saved before enabling only the fixture. Synthetic file contents
were 1 MiB and 4 MiB. Cache state was uncontrolled; this was a correctness check, with no speed
claim. The VM, network and unrelated app stayed running. macOS file-access prompts were allowed.

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

## Finder scheduling limit

Matched Finder paste recordings show that read-only access refuses a local copy and write access
accepts it locally. The accepted copy did not reach SMB, and no normal create callback arrived.
File Provider's consistency check reported a disk/snapshot mismatch. Recreating the disposable
domain, supported reimport and a temporary disconnect/reconnect did not restore automatic uploads.
A separate local FSEvents observer also received no callbacks for synthetic local changes, although
the global event counter increased. These observations suggest an event-delivery problem, but do
not establish its cause or prove that production code is free of integration defects.

The signed callback probes verify the sandbox, IPC and upload path only. They do not satisfy the
Finder acceptance gate. Finder progress, normal initial-create flags, folder-child scheduling,
user collision handling and other file managers remain unverified. A shared-daemon restart needs
separate approval. Physical-Mac installation, real-NAS writes and publication are not approved.

## Cleanup

The disposable location, test server, native mount, backing files, pending test copies and inbox
are removed. Sharing records and the SMB launch override match the snapshot; the local SMB
service is unloaded, SMB guest access is off and guest login remains off. The original one SMB
connection/session is retained. Final launch reports zero locations, catalogs, domains, items,
keeps, stage files and failed reconciliation sequences. The signed fixture helper cleared its outbox and reported zero inbox files. Final direct
inspection of app-private storage from the shell is privacy-blocked.
The normal signed M18 build runs in the VM, with no test hooks. Cairndex remains running.
Clipboard contents, synthetic input and the private CloudStorage selection file are removed.
The physical-Mac M16 installation is unchanged.

The retained callback/interruption messages passed a private connection/signing-value audit.
The ready host build has a valid strict/deep signature and is absent from both provider and
Launch Services registrations. No shared daemon was restarted; approval for that diagnostic
remains pending.

## Evidence and next step

Private evidence is under ignored results/create-items-20261023 and VM .local/phase2. It includes
m18-final-checks.log, m18-native-final-checks.log, m18-remote-runtime.json, name-free callback/interruption messages, signature
checks, signed-observations.json and matched read-only/write-enabled paste recordings. Info-level
messages rolled out during the run; the message file is partial, and the observations file records
the signed VM tool responses from the task transcript. No connection or signing values
belong in this log or published evidence.

Resolve automatic Finder upload scheduling before claiming M18 works or proposing installation.
