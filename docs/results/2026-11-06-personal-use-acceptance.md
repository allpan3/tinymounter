# TinyMounter 0.1.0 acceptance

Date: 2026-11-06. Restart retention, Preview/Xcode saves, low-space refusal, Finder
deletion/Replace and combined rename/content saves have signed VM evidence. Required checks
pass: 518 tests, one optional skip, no Swift warnings, benchmark verification, SET_INFO/edit/
folder-create checks and 7,205 CCM cases. Logo selection and release packaging remain open.

## Scope and setup

The user accepted thorough VM testing followed by their own physical-Mac daily-use feedback.
Version 0.1.0 is for personal use. Public distribution, notarization, an updater, a dedicated
uninstaller, an accessibility audit and broad NAS compatibility are deferred. The visible app,
bundle filename, executable and scheme are now TinyMounter. Signing identifiers, App Group,
sandbox entitlements and persistent data remain unchanged. The version was already 0.1.0.
Logo selection belongs to the user after functional work.

Tests use macOS VM 1 (macOS 27.0.1), the isolated SimplifyCheck identity and the existing Linux
Samba fixture. The original NAS and installed physical-Mac app are untouched. The first checks
use the merged simplification build. Later callback checks use the renamed candidate with the
existing fixture instrumentation and ordinary deletion enabled only in that candidate.

## Observations

- **Full OS restart:** saved an edit with Samba stopped, restarted macOS, verified the boot time
  changed and the exact local bytes survived before restoring Samba. The app reopened through
  window restoration. Restoring Samba uploaded the exact bytes without Retry; an independent
  server hash matched. This does not claim automatic startup after an intentional Quit.
- **Preview and Xcode:** Preview PNG/PDF each received two rotate-and-save operations and Save
  As. Xcode received two source edits/saves and Save As. All six resulting local file hashes
  matched independent server reads. PNG and source copies matched their originals; PDF Save As
  re-encoded the document. This covers those ordinary actions, not every format feature.
- **Low-space refusal:** the signed candidate's existing test hook reported capacity below the
  staging reserve. The provider returned Cocoa error 640, kept the complete local edit pending,
  and left the server contents unchanged. Releasing the hook uploaded the exact retained edit.
  Separately, filling a disposable 128 MiB APFS image produced actual ENOSPC; an input outside
  that image survived and copied successfully after removing the filler. This latter check is
  a filesystem check, not an end-to-end provider disk-exhaustion test.
- **Finder deletion:** Command–Delete displayed an immediate, irreversible-deletion warning.
  Cancel was exercised before confirmation. Confirmed file, empty-folder and populated-folder
  deletion completed. No Trash capability is advertised.
- **Finder Replace:** replacing an existing file used the ordinary delete/create sequence.
  Independent server inspection found the incoming contents at the requested name without
  a conflict copy. A second, downloaded destination was replaced with a 64 MiB input. Stopping
  Samba after 2 MiB reached the server left the complete input local. After app/provider restart
  and reconnection, the exact 64 MiB input uploaded. Native reconnection required the intervention
  described below; this trial does not establish fully automatic recovery.
- **Combined saves:** editing and renaming while disconnected produced a callback containing
  contents and filename fields. Reconnection completed the rename and overwrite with the exact
  local contents. A second callback combined contents, filename and parent after listing the
  destination. The old path disappeared and the new path contained the expected bytes. Moving
  into an unlisted destination while offline failed; listing it online before retry resolved
  that prerequisite.

## Operation contract

Finder Replace may delete the old destination before the incoming upload finishes. Failure can
leave no destination or partial incoming contents; NAS snapshots/backups own previous versions.
Exclusive new-file creation, identity-bound retries, containment, read-only enforcement and
pending local contents remain required. No generic create request gains overwrite permission.

A combined rename/save stages its input first, renames through the existing identity-bound
operation, then overwrites the same catalog item. Success requires both. If the write fails,
the callback stays pending; retry skips an already-applied rename. It is not an atomic operation.
Optional fail-on-conflict requests retain their original base version.

## Native reconnection limitation

During the repeated-outage Replace test, the server was reachable but the native mount was
absent. Both TinyMounter and Finder connection attempts stalled. A sample of NetAuthSysAgent
showed `GetNetworkAccountSID` / `LsarGetUserName` waiting inside Apple's SMB/DCERPC stack.
Terminating that service in the VM restored native mounting; TinyMounter then completed the
retained upload with matching bytes. No production code manages this system service. This
qualifies the interrupted-Replace result; the earlier full-restart test recovered automatically.

## Remaining checks and evidence

System-wide pressure eviction has not been repeated. Automatic approval review rejected a large
APFS reservation on the VM's main container because it could disrupt the VM. No reserve volume
was created. The earlier build's successful eviction test is historical evidence, not proof for
this implementation. The bounded-volume and injected-capacity checks do not close that gap.

Raw evidence is private under `results/acceptance-20261106/` in macOS VM 1, including restart
hashes, editor local hashes, callback events, low-space snapshots and the candidate build log.
Independent server audits are `/tmp/acceptance-20261106-*.json` in the Samba VM.

## Cleanup

The callback-test location was removed after a connected snapshot reported zero pending items.
Both new server fixture subtrees and the bounded disk image were removed; raw evidence remains.
Older fixtures and pending data were preserved. Samba is running. Its previous 40 GB host limit
prevented startup before testing; the limit is now 50 GB because allocated storage still exceeds
40 GB after guest trimming. The macOS VM retains the current signed candidate. Host signing
removed its loose app bundle after packaging. The physical-Mac app is unchanged.
