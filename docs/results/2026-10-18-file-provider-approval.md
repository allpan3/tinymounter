# Enable a disabled File Provider — 2026-10-18

## Outcome

The physical Mac's File Provider was disabled. Enabling TinyMounterPrototype's File Provider
switch in System Settings restored Connected without restarting the app or replacing the
location. The system dump changed from `user-disabled` and `enabled: no` to `enabled: yes`.
When or why it was disabled is not established.

The app now shows "File Provider is off.", enable instructions, and Open System Settings… in
that state. In the signed VM build, the button opened Login Items. Enabling the switch restored
Connected and Show in Finder on the same domain. A small read matched the source, and all 156
tests and required checks passed. The new signed Mac build is ready; its UI has not run on the
physical Mac.

## Setup and method

- Physical Mac and VMPal `macOS VM 1`, macOS 27.0.1 (26A434), on 2026-10-18, about 22:54 to
  23:05 US/Pacific. The host ran the installed connection-management build; the VM ran signed
  Release builds before and after this UI change.
- Inspected the File Provider daemon's state and the system switch. On both machines, Login Items
  showed TinyMounterPrototype under Extensions; its detail sheet contained the File Provider
  switch. Only that app's switch changed. Other apps were left alone.
- In the VM, added one location on the existing small test folder, disabled the provider, and
  repeated the header action before and after the change. Enabled it again through System
  Settings, returned to the app, and read a 2,016-byte file through the location.
- No cache reset or performance claim. The NAS remained read-only; no password was handled.

## Data

| Check | Result |
| --- | --- |
| Physical Mac diagnosis | The daemon reported `user-disabled`, a disabled backend and `domainDisabled` errors. The File Provider switch was off. |
| Physical Mac recovery | The switch stayed on, the daemon reported an enabled backend, and the existing app changed to Connected without a relaunch. |
| Old VM UI | Reported that the location was turned off, with Show in Finder. It gave no setting instructions. Show in Finder opened Finder, where the system also offered Enable. A separate file-access prompt was allowed. |
| New VM UI, provider off | Showed the shorter status, instructions to open TinyMounterPrototype in Extensions, and Open System Settings… instead of Show in Finder. |
| Open System Settings | Opened Login Items through `SMAppService.openSystemSettingsLoginItems()`. |
| System switch enabled | Connected and Show in Finder returned through the existing domain-change observer. The domain ID stayed the same; no location was removed or added for recovery. |
| Read after recovery | All 2,016 bytes matched native SMB by SHA-256. |
| Required checks | `Tools/run-checks.sh` passed in the VM: 156 tests, 0 failures, generated-project check, Release CLI/benchmark checks and unsigned Release app build. No Swift compiler warnings. |
| Signing | Deep, strict signature verification passed for the signed VM app and the ready physical-Mac build. |

## Correctness and limits

`NSFileProviderDomain.userEnabled` is read-only and reports the system's disabled state. The UI
continues to use that value; it does not conceal the failure or override system approval. The
system switch controls File Provider separately from Open at login.

The temporary VM location and its downloaded copy were removed after the read. One saved server
and its hidden mount remain. The File Provider switch is enabled on both machines. All 23 captured
app log lines passed the check for private hosts, accounts, shares, folder components and test
file names, with no nonzero stage-file count in the captured diagnostics.

Not verified: the new recovery button on the physical Mac, or a different macOS version. The
physical Mac's original location now works according to the app and system state; a physical-Mac
file read and the remaining M10 daily-use checks were not part of this fix.

## Evidence

- Local before/after header-action recordings: `results/provider-disabled-20261018/before.mp4`
  and `after.mp4`, with private names masked. Each starts from a disabled location and uses the
  header action. A captured baseline frame precedes the action recording.
- VM logs: `.local/phase2/provider-recovery-checks.log`, `provider-recovery-signed.log` and
  `provider-recovery-runtime.log`.
- Host signed-build log: `results/provider-disabled-20261018/host-signed-build.log`.

## Next step

Install the UI update on the physical Mac after approval. Publication of the local branch update
and merge of PR #8 remain unapproved.

## Physical Mac installation and repeat setup, 23:07 US/Pacific

The user approved installation and asked to restore the disabled state for another try. The
running app quit normally. Its signed replacement passed strict, deep signature verification,
matched the ready executable, and ran from Applications. The previous app is backed up under
`.build/app-backups/`.

Launch reconciliation retained one location, catalog and domain, with no failed sequence.
TinyMounterPrototype's File Provider switch was then turned off in System Settings. The new app
shows "File Provider is off." and Open System Settings…, with the existing location retained.
It is left in that state for the user to repeat the recovery. The button's path and re-enable
step on this Mac remain the user's check. No saved connection or location was removed.

Local installation evidence is in `results/provider-disabled-20261018/host-install-check.txt`
and `installed-backup.txt`.
