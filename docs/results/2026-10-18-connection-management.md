# Server removal and existing connections — 2026-10-18

## Outcome

The signed VM app ejects a share when Disconnect is clicked and ejects associated shares before
removing a server. A failed eject keeps the entry and its controls. An existing connection can
be selected directly, including a hidden mount or a connection made in Finder. The user no
longer needs to eject a leftover mount in Finder before adding it again.

Server addresses are now saved separately from share grants. An update migrated an existing
location and reopened its catalog and File Provider domain. A small read through that location
matched the native source. All 156 tests and the required builds and checks passed in the VM.
The signed physical-Mac build is ready but has not been installed or run.

## Setup and method

- VMPal `macOS VM 1`, Apple silicon, macOS 27.0.1 (26A434), on 2026-10-18 from about 20:24 to
  20:45 US/Pacific. Signed Release builds on `connect-in-app`; `codesign --verify --deep --strict`
  passed. The host build also passed signature verification.
- Two existing SMB shares on the same NAS. Passwords stayed with macOS and the Keychain. No
  remote file was changed. Tests used the small existing test folder; the large fixture was
  not used. Caches were not reset, and these checks make no performance claim.
- First reproduced the old Remove behavior with a process holding the mount's root directory
  open. Then added a location in the old build and opened the new build to check migration.
  Used normal OS unmounts throughout; no eject was forced.
- The before/after recordings repeat selecting the server and clicking Remove while the same
  folder is held open. The old build has no confirmation; the new build does. For the recording,
  the old source used a separate settings filename so it could run beside version 2 settings
  without overwriting them. Its connection and removal code was unchanged.

## Data

| Check | Observed result |
| --- | --- |
| Old Remove, busy hidden mount | The entry disappeared; the OS mount remained. The unmount logged error 769 (`NSFileManagerUnmountBusyError`). |
| Update from version 1 with a location | One record, one catalog and one domain reopened, with no failed launch sequence. The existing bookmark started a session. A 2,016-byte file read through the location matched native SMB by SHA-256. |
| Add Server with only a server address | Saved the server with no share grant and no SMB mount. Add Share then showed macOS's share selector. |
| Disconnect, busy share | Showed an error, kept the connection, and restarted the session after macOS's failed unmount. |
| Disconnect, then Connect | The mount table contained zero SMB mounts after Disconnect. Connect restored the saved share with `nobrowse`. |
| Remove, busy share | Showed an error and kept the server, grant and connection controls. After releasing the holder, retry ejected the volume and removed the entry. |
| Remove, then add again | Added the server and share again through the app without manual OS cleanup. |
| Existing hidden mount | Add Share offered Use Share. Cancelling its open panel kept the existing mount. |
| Another server address | An explicit confirmation preceded the open panel. Cancel left the association unchanged; Use Share and Open moved the existing grant to the selected server. The session retained its grant ID. |
| Finder connection without a grant | Other Connected Shares showed Use Share and Disconnect. Use Share granted the visible mount without a new connection. A new location on it read the same small file with a matching checksum. |
| Server used by a location | Remove was disabled. Removing the last location enabled Remove without restarting the app. |
| Two shares on one server, second busy | Remove ejected the first, failed on the second, and kept both saved entries with their actual connection states. Releasing the holder and retrying removed the remaining mount and the server. |
| Cancel after macOS mounted two shares | Both new mounts were removed; the saved server remained. Cleanup is restricted to new mounts returned by that connection request. |
| Automated checks | `Tools/run-checks.sh`: 156 tests, 0 failures; generated project, Release CLI/benchmark checks and unsigned Release app build passed, with no Swift compiler warnings. |

The run found a UI observation defect: Remove did not enable after the last location was
removed. The view now reads the observed location and grant lists. The successful repeat above
used that fix. Review also restricted cancellation cleanup to mount paths returned by NetFS,
so an unrelated connection made concurrently is not treated as part of the request.

## Correctness and limits

- Unit tests check version 1 migration of grant IDs, bookmarks, mount addresses, location and
  domain IDs, pending and saved Keep Downloaded lists, and private file mode. A failed migration
  leaves the previous settings bytes intact. Version 2 rejects a grant without its server.
  The signed migration check used a location without kept files.
- The app never guesses that two hostnames or addresses identify the same server. Selecting a
  connection associates it explicitly. Remove can therefore eject a connection also used by
  another app; its confirmation says so. It never force-ejects a busy volume.
- Removal of several shares is sequential. An earlier successful eject stays ejected if a later
  eject fails. All saved entries remain, so the user can reconnect or retry removal.
- At the end: one saved server and its hidden SMB mount, no test location, no test download,
  and zero stage files in the captured diagnostics. The holder processes were stopped.
- Of 195 captured app log lines, none contained the checked hosts, accounts, share names, test
  folder components or its file names.
- Unverified: this fix on the physical Mac; a failed eject of an unselected mount during
  cancellation; a concurrent external mount during cleanup. Password entry remains the user's
  check. The earlier first-use picker delay remains unexplained. Physical-Mac daily use, sleep
  and wake, a network change and a macOS restart still need the user's run.

## Evidence

- Local recordings: `results/connection-management-20261018/before.mp4` and `after.mp4`, with
  private names masked. Both use the busy-removal sequence described above.
- VM logs in `~/Developer/tinymounter/.local/phase2/`: `manage-connections-final-checks.log`,
  `manage-connections-signed.log` and `manage-runtime-all-log.txt`.
- Host signed-build log: `results/connection-management-20261018/host-signed-build.log`.

## Next step

After approval, install and open the signed build on the physical Mac. Repeat removal and
re-add with the user's existing connection, then continue M10's daily-use and restart checks.
The branch update remains local until publication is approved.

## Physical Mac installation, 22:23 US/Pacific

After the user approved installation, the running app quit normally. The previous app was
backed up, and the ready signed build replaced `/Applications/TinyMounterPrototype.app`.
The team and bundle ID matched. Signature verification passed, and the installed executable
matched the verified build.

One app process ran from Applications and opened its Settings window. Launch reconciliation
reported zero records, catalogs and domains, with no failed sequence; launch diagnostics showed
zero saved shares and stage files. This verifies installation and launch. The user still needs
to check connection reuse, removal and re-add on this Mac, followed by the remaining M10 checks.
Local evidence: `results/connection-management-20261018/host-install-check.txt` and
`installed-backup.txt`.
