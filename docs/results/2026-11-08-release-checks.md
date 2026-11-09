# 0.2.0 release checks, 2026-11-08

## Outcome

The 0.2.0 build (0.2.0, build 6) passes the release checks in the signed VM app. Start Fresh
from a real 0.1.2 setup works, with one limit: **it leaves 0.1.2's hidden share mount in place**
when that mount is live. The user must eject it or restart the Mac ([release
notes](../release.md#update-from-01x-start-fresh-is-required)). The M23, M25 and M26 Finder
checks pass with password sessions. Another client's rename of a folder's only file shows in
1–2 s, while the 15 s confirmation still holds for deleting that file and for renaming a kept
file. An expired password stops after one logon and recovers with Sign In Again…. The
regression pass found no smbfs mount for File Provider locations. No code defect was found.

`Tools/run-checks.sh` in the VM at the last code commit: passed. 521 tests, one optional skip,
no failures, no Swift warnings; SET_INFO 6, edit status 87, folder-create status and CCM 7,205
cases passed. Host `swift test`: 521 tests, one skip.

## Setup

- Client: VMPal `macOS VM 1`, macOS 27.0.1 (26A434). Tag `v0.1.2` and the 0.2.0 commit were
  built unsigned with bundle `dev.tinymounter.releasecheck`, signed on the host, and installed in
  turn at the same path, `~/Applications/TinyMounter-Release.app`.
- Server: VMPal `TinyMounter Samba Test`, Samba 4.19.5-Ubuntu. A disposable account and two
  shares, one for a File Provider location and one for a server volume. The passwords were
  generated inside the VMs, typed through VMPal input and never printed. Global settings
  unchanged. All of it was removed afterwards and `smb.conf` restored byte-for-byte.
- Logon counts come from the fixture's capture, counted with `Tools/count-smb-logons.py`. It now
  also counts other session-setup refusals by NT status.
- Times on the File Provider side come from a reader that lists the location folder every 0.1 s.
  The two VMs' clocks differed by about 0.03 s.

### VM state found

The VM's Keychain held an internet-password item for an older fixture account at the fixture's
address, and Heimdal's `gsstool` listed three held NTLM credentials for it. macOS used that
account for every mount of that address, so 0.1.2's Add and Finder failed with "share does not
exist". The check destroyed those credentials and used a hosts alias for the new account. This
is a VM artefact of earlier runs, not a 0.1.2 or 0.2.0 defect.

## Start Fresh from 0.1.2

| Check | Result |
| --- | --- |
| 0.1.2 setup | 0.1.2 added a File Provider location with its hidden mount (`nobrowse`). Read hash matched; an upload reached the server |
| Pending change | With smbd stopped, a new file showed "Pending changes: 1" |
| 0.2.0 first launch | Pass. Settings refused; General offers Start Fresh |
| Start Fresh, pass 1 | Pass. Finder opened the preserved folder with the pending file, byte-for-byte. The domain was removed; 0 smbfs mounts; 0 `dev.tinymounter.smb` items |
| Start Fresh, pass 2, hidden mount live | Limit. The mount survived quitting 0.1.2 and launching 0.2.0. Start Fresh deleted the 0.2.0 Keychain item (1 → 0) and the domain, but left the mount. `diskutil unmount` removed it (→ 0) |
| New sign-in and location | Pass in both passes. The sign-in sheet, the share list and Add connected; pass 1 had 9 logon attempts, 9 accepted. In pass 2 the new location worked while the old mount was still there |
| macOS's own Keychain item | Stays. Start Fresh deletes only TinyMounter's items, as designed |

In pass 1 the hidden mount had gone by itself while smbd was stopped. On the physical Mac it
will be live. Adding hidden-mount cleanup to 0.2.0 would be code for an earlier version, which
the project's no-migrations rule excludes before release, so the release notes tell the user to
eject it or restart instead. One 0.1.2 Add failed with EIO while the Local Network prompt was
open; the retry worked.

## Finder checks with password sessions

| Check | Result |
| --- | --- |
| M23 ordinary saves | Pass. A 1 MiB overwrite, a shorter save and an empty save each match the server |
| M23 competing edit | Pass. After a server-side edit, the later local save replaced it |
| M23 interrupted upload | Pass. smbd stopped at about 20 MiB of 64 MiB and restarted 15 s later. The upload finished by itself 16 s after the restart, hash matched, no Retry |
| M25 TextEdit saves | Pass. Two saves reached the server with no leftover files |
| M25 Finder file Replace | Pass. The server file has the source hash; no copy |
| M25 Finder folder Replace | Pass. The old folder's file is gone; the new file has the source hash |
| M25 offline rename and saves | Pass. With smbd stopped: a rename, two saves, then app quit and relaunch. After the restart the server had the final bytes under the new name within 1 s; no old name, no copies |
| M26 offline saves of a kept file | Pass. With smbd stopped: two saves, app quit and relaunch. The server changed from the original to the final bytes 3.6 s after the restart; the first save never appeared |
| Offline write to a dataless file | Refused with `ETIMEDOUT`, as expected: an offline edit needs a downloaded file |

## New behaviour

| Check | Result |
| --- | --- |
| Another client renames a folder's only file | Pass. New name shown after 0.98, 1.76 and 1.46 s |
| Another client deletes a folder's only file | Pass. Gone after 16.92 s (15 s confirmation) |
| Another client deletes one of four files | Gone after 1.78 s |
| Another client renames a kept file | Pass. Both names correct after 17.15 s |
| Expired password | Pass. `net sam set pwdmustchangenow` makes Samba answer `STATUS_PASSWORD_MUST_CHANGE`. The location showed "Sign in again." and Sign In Again…, with one notification; about 90 s of capture had 1 attempt and 0 accepted. An upload made after the expiry stayed pending |
| Sign In Again… after the password change | Pass. After `smbpasswd` set a new password, Sign In Again… with it connected the location and the pending upload reached the server; 13 logons, all accepted |

`STATUS_PASSWORD_EXPIRED` was not produced: Samba sends it only under a global maximum password
age, which this check does not change. It rests on the unit test. The sheet's refusal text for
an expired password was not shown in this run.

## Regression

| Check | Result |
| --- | --- |
| Add server, browse, read, upload, rename | Pass (Start Fresh and Finder checks above) |
| Keep Downloaded | Pass. Downloaded, `keep` set |
| Move | Pass. Server file moved, hash unchanged |
| Delete Permanently… | Pass. Confirmation shown; the file was removed from the server |
| Server Volume add | Pass. Mounted visibly at `/Volumes/<share>` with no prompt; read and write worked |
| Disconnect, Show in Finder, eject | Pass. Disconnect left 0 mounts; Show in Finder mounted it again; `diskutil unmount` left 0 |
| No mount for File Provider locations | Pass. The only smbfs mount was the server volume, without `nobrowse` |
| Logons | Server Volume section: 19 attempts, 19 accepted. Idle: 2 accepted in 25 s, one session per operation. One Connect: 6 accepted in about 30 s, idle logons included |
| Logs | Pass. 11,894 lines of the app and extension over 2 h: no password, address, account or file name |

## Skipped

- VM sleep, wake and network-path changes: the brief excludes VM sleep and network loss.
- `change notify = no` and `map to guest`: global fixture settings, excluded by the brief.
- `STATUS_PASSWORD_EXPIRED`: needs the global password policy (see above).
- Preview saves: M25 covered TextEdit and Finder only.

## Decisions to review

- Start Fresh does not eject 0.1.2's hidden mount. The release notes give the user one step
  instead of adding code for an earlier version.
