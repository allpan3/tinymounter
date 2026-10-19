# Connect in the app (M12) — 2026-10-18

## Outcome

In the signed app in the VM, the user connects a share in tinymounter instead of Finder, and
Finder's sidebar shows only the tinymounter location. macOS shows its own login dialog and share
list, so the app never sees a password. All 8 checks of the
[phase 3 plan](../phase3-plan.md#4-connect-in-the-app-m12) passed.

| Question | Answer |
| --- | --- |
| Can the sandboxed app show macOS's dialogs? | **Yes.** An address with an account that the Keychain didn't have showed macOS's login dialog, with "Remember this password in my keychain". An address with only the server showed macOS's share list. Cancel in either returned -128 (`userCanceledErr`). |
| Does it work with no dialog when the Keychain has the password? | **Yes.** `smb://server/share` with no account mounted in 1.26 s with the Keychain's account, and the open panel opened on the share. Open saved the grant, and a session started 1 s later. |
| Can the app skip the open panel? | **No.** Without the user's selection, the app got EPERM when it opened the mount that it had made. |
| Does Finder show the share? | **No.** With `MNT_DONTBROWSE`, Finder's sidebar showed only the location. A full read of a 307 MB file through the location matched the share by SHA-256. |
| Does a mount by the app stay hidden? | **Yes.** After a forced unmount, the app mounted the share again in 3.1 s, with `nobrowse`. |
| Does Connect work? | **Yes.** After an eject, Connect mounted the saved address in 1.27–1.49 s, and a session started. |
| Leaks | **None.** Removing the server unmounted its hidden mount, and Cancel in the open panel unmounted the share that Add Share had mounted. 0 stage files. No log line held a share, host, account or file name. |

Not established: typing a password in macOS's dialog and its Keychain checkbox, which only the
user does; Finder's Desktop; several shares selected at once in macOS's list; the physical Mac.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434). Personal Team signed Release builds of
  the `connect-in-app` branch; `codesign --verify --deep --strict` passed. The VM's
  `Tools/run-checks.sh` passed: 152 tests, 0 failures, and the required builds.
- One SMB share on the NAS, with its password saved in the VM's Keychain. The location was on the
  M11 test folder. Runs from 17:58 to 18:26 US/Pacific.
- First a spike build with signal triggers answered the unknowns: macOS's dialogs, where the mount
  goes, whether the app can read its own mount, `MNT_DONTBROWSE`, the open panel on a hidden mount,
  and `FileManager.unmountVolume` from the sandbox. Then the M12 build ran the checks in the
  Settings window.
- Addresses went to the VM's clipboard from the saved `smb://` URL, with the account removed or
  replaced with a test account, and were pasted in Add Share. The agent typed no password. Times
  that include a dialog include the agent's clicks.
- Forced unmounts used `umount -f` and ejects `diskutil unmount`, as in M11.

## Data

### Spike

| Try | Result |
| --- | --- |
| `smb://server/share`, password in the Keychain | Status 0 in 1523 ms, in `/Volumes`, with the grant's `f_mntfromname`. `open` of the mount point by the app: EPERM. |
| Test account | macOS's login dialog. Cancel: -128. |
| Only the server | macOS's share list. Cancel: -128. |
| `MNT_DONTBROWSE` | Status 0 in 418 ms, `nobrowse` in the mount table. Not in Finder's sidebar; AppleScript still lists it as a disk. The saved grant started a session on it. |
| Open panel on the hidden mount | It listed the share; Open made a grant. |
| `FileManager.unmountVolume` | Done in 50 ms. macOS posted `willUnmount`, so the app held, as after an eject. |

### Checks

| Time | Step | Result |
| --- | --- | --- |
| 18:13:26 | Connect, after the spike's unmount | Status 0 in 1486 ms, `nobrowse`; session 12 ms later. |
| 18:13:38 | Remove the server | `share_unmount reason=server_removed ok=1`; no smbfs mount. |
| 18:14:06 | Add Share with a test account | Login dialog. Cancel: status -128, no message, no server, no mount. |
| 18:14:30 | Add Share with only the server | Share list; the share selected. Status 0; the panel opened on it. Cancel in the panel: `share_unmount reason=not_selected ok=1`. |
| 18:14:51 | Add Share with `smb://server/share` | No dialog. Status 0 in 1263 ms; the panel opened on the share; Open: grant, session, Connected. |
| 18:16:11 | Add a location | Added; Finder's sidebar showed the location and no share. A full read of a 307 MB file: 3.3 s, SHA-256 equal. |
| 18:23:39 | `umount -f` | Mount again at once; mounted in 3093 ms, `nobrowse`; session. |
| 18:23:52 | `diskutil unmount` | `remount_held`. The location said "Open Servers in tinymounter Settings. Then click Connect." Connect: mounted in 1266 ms, `nobrowse`; session. |
| 18:24:34 | Add Share, share already mounted | Status 17 (EEXIST) in 20.5 ms, with the mount point. The panel opened on it; Open replaced the grant of the same server. |
| — | `afp://server/share` | "This address is not correct. Type an address such as smb://server/share." |
| — | Select Again… | The panel opened on the hidden mount. |
| 18:26:05 | Remove Location | Removed; no CloudStorage folder left. |

## Correctness and limits

- The read through the location matched the share by SHA-256. The test file was evicted after
  the read.
- At the end: one smbfs mount, the saved server's; `stage_files=0` in the app and
  `temp_stage_files=0` in the extension.
- Of the 107 log lines of the M12 build, 20 matched a word from the name check: a common word
  that is both a folder name on the share and part of the app's own log category. No line held a
  share, host, account or file name.
- The first read through the new location waited for a macOS prompt, "VMPal Tools wants to access
  files managed by TinyMounterPrototype". It is for the VM's tools, not for users; after Allow, the
  read ran.
- The "Login Item Added" notice that showed after new builds was not new. macOS posted it on
  2026-10-16, when the [M7 run](2026-10-16-settings-window.md) turned on Open at login. It is a
  pinned alert, and Notification Center showed it again at each display wake until the agent
  closed it. The log of the last 4 days holds no other notice from Background Task Management, and
  `sfltool dumpbtm` lists no login item for the app.
- A hidden share can't be ejected in Finder. There is no Disconnect; Connect brings the share back
  after `diskutil unmount`.
- Times are from one VM and one NAS. They are not performance measurements.

## Evidence

Private, gitignored, in the VM's `.local/phase2/`:

- `m12-checks.log` and `m12-signed-build.log`: the checks and the signed build. `m12-log.txt`:
  the log lines that the name check read.
- Helpers: `m12-read.py` (a read and its SHA-256 against the share), `m12-namelines.py` (the
  matched lines with the names masked), `m12-log.sh`, `spike-log.sh`, `m9-lognames.py`, `evict`.
  `m12-native.txt` and `m12-cloud.txt` hold the location's paths.
- The spike's code is on the local branch `spike-connect`, which is not pushed.

## Next step

The user's run on the physical Mac (M10's second part) with this build: connect in the app,
typing the password in macOS's dialog, then daily use. Then the rest of phase 3.
