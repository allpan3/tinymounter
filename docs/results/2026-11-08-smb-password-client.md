# SMB password client for 0.2.0 (plan step 2), 2026-11-08

## Outcome

`SMBClient` signs in to SMB shares with an account and password through the vendored libsmb2's
NTLMSSP, with no mount and no GSS credential. Every step 2 check in the
[connection plan](../connection-layer-plan.md#step-2-checks) passed on the disposable Samba
fixture. The app does not use `SMBClient` yet: step 3 moves the callers to it. The mount-credential
path is unchanged and `Tools/run-checks.sh` passes.

| Check | Result |
| --- | --- |
| Sign-in, SMB 3 only, signing and encryption required | Signed in. `smbstatus` on the fixture: SMB3_11, tree encryption AES-128-CCM, signing AES-128-CMAC |
| Wrong password | `notAuthenticated` from one call. A capture on the fixture showed 1 logon attempt and 1 `STATUS_LOGON_FAILURE`; the next correct sign-in was the only other attempt |
| Missing share | `missing` (`BAD_NETWORK_NAME`) |
| Share the account may not open (`valid users` excludes it) | `noPermission` (`ACCESS_DENIED` at tree connect) |
| Disabled account (`[D]`) | `noPermission` |
| Locked account (`[L]`), correct or wrong password | `noPermission` |
| `shareNames` | The 8 disk shares; `IPC$` and the fixture's `tm-step2-admin$` left out |
| Listing, checksum read, upload, overwrite, rename, folder move with proofs, recursive deletion traversal, permanent deletion | Pass, each on its own password session |
| Folder creation and initial naming (M18) on the session's connection | Pass |

Account forms against this standalone Samba (`security = user`), which ignores the domain:

| Form | Result |
| --- | --- |
| `name` | signed in |
| `DOMAIN\name`, `DOMAIN;name`, any domain | signed in |
| `name@domain`, sent as the NTLM user name with no domain | refused, `notAuthenticated` |
| `name@domain`, split into user and domain | signed in; this is what the code does |

## Setup

- `macOS VM 1`, macOS 27.0.1, its own clone with its own derived data. The fixture VM runs Samba
  4.19.5, standalone, `map to guest = Never`, lockout policy 0.
- A disposable account `tmstep2` with a random password generated on the fixture, the
  encrypted share `tm-step2`, the share `tm-step2-denied` (`valid users = tmtest`) and
  `tm-step2-admin$`. The password reached the VM as a file outside the repository; it never
  appeared in a command, log or output. All of these were removed afterwards.
- `Tools/check-smb-password.py` builds `Tools/check-smb-password.swift` against the app's
  `SMBClient`, `SMBEdit` and TransferCore sources and the built `libTinyMounterSMB`, and runs
  each case in a new process. The operations follow the calls of `FileRenameTransaction`, the
  folder move admission and `ItemDeletionTransaction`, without a catalog.
- `Tools/count-smb-logons.py` counts one account's NTLMSSP AUTHENTICATE requests and the
  server's replies in a `tcpdump` capture on the fixture. Session setup precedes encryption, so
  both are readable. Samba's own log records nothing at `log level = 1`. Raising `auth_audit`
  at run time with `smbcontrol` did not reach new connections, which reload the configured
  level; changing `smb.conf` would have affected the other agents.

## Decisions in the code

- **The password reaches C as bytes.** `RemoteClient` takes `password: Data`, not `String`.
  `SMBClient.withLogin` lends the bytes to C; C copies them once into a NUL-terminated buffer
  for `smb2_set_password` and zeroes it. The vendored `smb2_clear_password()` zeroes libsmb2's
  copy right after connect, and the NTLMSSP code zeroes its copies, hashes and keys. A password
  with a NUL byte is refused. Process memory was not inspected.
- **Only `STATUS_LOGON_FAILURE` is `notAuthenticated`**, as the plan says. Locked, disabled,
  expired and restricted accounts, `PASSWORD_EXPIRED` and `PASSWORD_MUST_CHANGE` are
  `noPermission`. A refused guest session is reported as `LOGON_FAILURE`.
- **Encryption is checked after connect.** A session that negotiated less than SMB 3.0 or isn't
  sealed is refused with `ENOTSUP`.
- **A password session has no mount root.** Folder moves and deletion traversals keep their
  mount identity check only for mount-credential sessions; the SMB session is the proof for a
  password session, as the plan describes.
- **M18 folder operations run on the session's connection.** `SMBEdit.createFolder` and
  `nameFolder` use the same C code as the per-call functions. They close the handles they open,
  and after a request without a reply they drop the connection, like every other `SMBEdit` call.
- **The explicit guest branch still works** until step 3 removes it: libsmb2 accepts a guest
  session only for the user `guest`, and the password path refuses that name.

## Not verified

- The guest fallback refusal on a server with `map to guest = bad user`: changing that global
  setting would have affected the other agents. It was read in the code.
- `name@domain` on an Active Directory member or a real NAS; behaviour of other NAS vendors.
- A memory inspection of the zeroing.
- The app's own use of `SMBClient` (step 3) and Finder behaviour.

## Evidence

In the VM's clone, `results/step2/`: `run-checks-*.log`, the build log and each check run's
`results.jsonl`. The first three runs found harness errors (catalog item IDs that weren't UUIDs,
and a listing opened while the move session still held a delete handle) and the `name@domain`
refusal; the fourth passed every case.
