# App-owned SMB password login (0.2.0 spike)

Date: 2026-11-08. Decision status: proposed. This is a feasibility spike; nothing is wired into
the product.

The vendored libsmb2 logs in with an explicit account and password, with no macOS mount and no
GSS credential lookup. On the fixture share that requires encryption, it negotiated SMB 3.1.1
and sealed every request. A signed, sandboxed probe app stored the password in its own Keychain
item, logged in from that item without a prompt, and removed it with Forget.

The material limit is the Keychain implementation. The data protection keychain needs a
provisioning profile, and TinyMounter is signed with the free Personal Team without one. Without
a profile it returns `errSecMissingEntitlement` (-34018). With `keychain-access-groups` the app is
killed at launch. The file-based keychain, reached through the same `SecItem` API, works with
today's signing. Free provisioning profiles expire after 7 days, so the recommendation is the
file-based keychain until the project has a paid membership. The user should confirm that
choice before implementation.

## Setup

- macOS VM 1, macOS 27.0.1, with no `smbfs` mount during the tests. The disposable Samba
  fixture VM runs Samba 4.19.5 as a standalone server (`security = USER`, `map to guest` at its
  default, Never, and lockout policy 0).
- Accounts: the fixture's test account on `tinymounter-single` (`server smb encrypt = required`).
  For failure cases, a disposable account with a random password generated on the fixture, and
  its own read-only share that requires encryption. The account, the share and the password
  file were removed afterwards.
- Probes (kept under `Tools/`, not in the product build):
  - `probe-password-login.c`: a CLI that reads the password on stdin and connects with NTLMSSP.
    It also has a `--current` mode that calls today's `tm_smb_begin_edit` (cached GSS credential).
  - `probe-keychain-login.swift`: built as `TinyMounter-LoginSpike.app`
    (`dev.tinymounter.loginspike`), signed on the host with the development identity and run
    sandboxed in the VM. It stores, reads, deletes and logs in from a Keychain item.
  - `build-password-login-probe.sh` builds both against the vendored libsmb2 sources with the
    product's defines (`HAVE_LIBKRB5=1`). `run-password-login-probe.sh` runs the CLI cases with
    the fixture password read once from the VM's login keychain.
- Signing variants (host, Apple Development certificate, hardened runtime, no profile):
  `plain` (sandbox and network client only), `base` (plus `application-identifier` and the
  team-prefixed App Group, as in the product) and `kag` (base plus `keychain-access-groups`).

## Findings

### 1. Login, signing and encryption

| Case | `smb2_connect_share` | NTSTATUS | Result |
| --- | --- | --- | --- |
| Password, share requires encryption | 0 | SUCCESS | dialect 3.1.1, sealed, root listing returned 22 entries |
| Same, domain `WORKGROUP` or an unrelated domain | 0 | SUCCESS | same (a standalone Samba ignores the domain) |
| Same, from the sandboxed app with the password from its Keychain item | 0 | SUCCESS | same |
| Wrong password, unknown user, or empty password | -61 (`ECONNREFUSED`) | `0xC000006D` LOGON_FAILURE | refused at session setup |
| Missing share | -2 (`ENOENT`) | `0xC00000CC` BAD_NETWORK_NAME | refused at tree connect |
| Account locked (`[L]`), wrong password | -5 (`EIO`) | `0xC0000234` ACCOUNT_LOCKED_OUT | refused before the password check |
| Closed TCP port | -1 | none | `ENOTCONN` after POLLHUP |
| No host at the address | -1 | none | `ENOTCONN` after the 10 s timeout |
| Unresolvable name | -5 (`EIO`) | none | resolver error |
| Current GSS path (`--current`), no mount | context returned | — | connected, sealed |

The password path sets the same options as `connect_folder_share` (`smb2_set_sign(1)`,
`smb2_set_seal(1)`, signing enabled and required) plus `smb2_set_authentication(SMB2_SEC_NTLMSSP)`,
user, optional domain and password. With sealing, libsmb2 clears its separate signing flag,
because SMB 3 encryption also authenticates each message. The 3.1.1 session setup still verifies
the server's signature.

Two observations matter for the error mapping:

- A wrong password returns `-ECONNREFUSED`, because libsmb2 maps LOGON_FAILURE to it. A refused TCP
  connection returns -1. The app must decide from `smb2_get_nterror()`, never from the errno.
- Samba returned ACCOUNT_LOCKED_OUT even with a wrong password. Samba status codes for
  account states that need the correct password were checked with `smbclient` on the fixture:
  disabled (`[D]`) gives ACCOUNT_DISABLED and "must change now" gives PASSWORD_MUST_CHANGE.
  libsmb2 maps ACCOUNT_DISABLED and PASSWORD_EXPIRED to `EACCES`, and ACCOUNT_LOCKED_OUT and
  PASSWORD_MUST_CHANGE to `EIO`.

The current GSS path also connected with no mount: macOS kept a cached NTLM credential from an
earlier session. That path works only while such a credential exists. The spike did not destroy
the cached credential, because another agent was using the VM.

### 2. The vendored libsmb2

The NTLMSSP password path (`ntlmssp.c`, NTLMv2) is built and usable as is. It doesn't use
GSS.framework: `smb2_set_authentication(SMB2_SEC_NTLMSSP)` bypasses `krb5-wrapper.c`, which the
build still compiles because of `HAVE_LIBKRB5`. The M19 edit-publication checks already used this
path with a password against a loopback fixture.

Recommended local changes in `Vendor/libsmb2`, each to be listed in its README:

1. **Refuse a guest session for a password login.** `session_setup_cb` accepts
   `SMB2_SESSION_FLAG_IS_GUEST` for NTLMSSP and turns signing off. It refuses guest only for the
   GSS path. A server with `map to guest = bad user` could turn a failed login into a guest
   session. 0.2.0 has no guest support, so refuse every guest session with `EACCES`. This was read
   in the code and not reproduced: changing the fixture's global `map to guest` would have
   affected the other agent.
2. **Zero secrets before freeing them** (see section 5).
3. **Remove the `ntlm:<32 hex>` branch** of `NTOWFv2`. A password of that exact form is
   treated as an NT hash, so a user with such a password couldn't sign in.

The GSS code (`cached_principal`, `krb5-wrapper.c`, the GSS framework link) can be removed later.
`HAVE_LIBKRB5` changes the layout of `struct smb2_context`, so the define must change in the
library and in every probe and adapter that reads the context at the same time.

### 3. Keychain from the sandboxed, development-signed app

| Variant | Data protection keychain | File-based keychain (`SecItem` without `kSecUseDataProtectionKeychain`) |
| --- | --- | --- |
| `plain` | add/delete -34018 (missing entitlement) | add, read, delete pass; no prompt |
| `base` (product entitlements) | add/read/delete -34018 | add, read, delete pass; no prompt |
| `kag` | process killed (SIGKILL) at launch | not reachable |

The data protection keychain rejects an `application-identifier` claim that no profile
authorizes. A restricted entitlement without a profile (`keychain-access-groups`) stops the
process at launch. This matches Apple DTS guidance ([SecItem: Fundamentals](https://developer.apple.com/forums/thread/724023),
[App Groups: macOS vs iOS](https://developer.apple.com/forums/thread/721701)). TN3137's text did
not load, but the post quotes it: "The file-based keychain is on the road to deprecation". That
refers to the implementation, not to the `SecItem` API. No macOS 26 or 27 change was found.

The file-based keychain results with the product's entitlements:

- **No entitlement needed.** The sandboxed app created, read and deleted its own item with no
  prompt.
- **App update.** Build 2 (new `CFBundleVersion`, re-signed with the same certificate) read build
  1's item with no prompt. The item's ACL trusts the app's designated requirement: bundle
  identifier plus the certificate's common name. An ad-hoc re-sign (a different designated
  requirement) first showed macOS's "differs from previously opened versions" container dialog,
  then a keychain prompt that asked for the login keychain password. Denying it returned -128.
  A renewed development certificate with the same common name should keep access; this is
  untested.
- **Item collision.** A query by server, account and SMB protocol matched the Internet password
  that already existed for the fixture. Because the file-based keychain is shared, TinyMounter
  must not use that class and key: a read could return Finder's item, and Forget could delete it.
  The probe's own item is a generic password: service `TinyMounter`, account
  `smb://<account>@<server>`. After Forget deleted it, the existing Internet password was still
  present.

### 4. Reading the password Finder saved

The sandboxed app could read the attributes of the existing Internet password without a prompt.
Reading its data showed "TinyMounter Login Spike wants to use your confidential information
stored in <server> in your keychain", with a field for the login keychain password. `/usr/bin/security`
got the same prompt, so the item's ACL trusts only the app that saved it. A Deny
returned -128. The data protection keychain cannot see these items. This route is possible
but prompts on first use. The plan does not build on it.

### 5. Memory hygiene

libsmb2 copies the password and its derived secrets as follows:

| Copy | Lifetime | Zeroed today |
| --- | --- | --- |
| `smb2->password` (`strdup` in `smb2_set_password`) | until replaced or the context is destroyed | no |
| `auth_data->password` (`strdup` in `ntlmssp_init_context`) | negotiate until the end of connect | no |
| UTF-16 copy in `NTOWFv1`, the NT hash and `ResponseKeyNT` | the stack and heap during session setup | no |
| session, signing and encryption keys | the session | needed while connected |

libsmb2 doesn't reconnect by itself, so `smb2->password` is not needed after
`smb2_connect_share` returns. The probe zeroes it with `memset_s` and then calls
`smb2_set_password(NULL)`. That reads the private struct, so the product needs a vendored
`smb2_clear_password()` instead, plus zeroing in `smb2_set_password`,
`smb2_destroy_context`, `ntlmssp_destroy_context` and the NTOWF buffers. Runtime inspection of
process memory was not done.

On the app side, `SecItemCopyMatching` returns an immutable `CFData` that only Security.framework
can free; it cannot be zeroed. Pass its bytes directly (`withUnsafeBytes`) to a C helper. The
helper copies them into a NUL-terminated buffer, calls `smb2_set_password` and zeroes the
buffer. Never convert the password to a Swift `String`. Read the item again for each connection
instead of caching it. The sign-in sheet's `SecureField` text is a `String`; convert it once to
`Data`, store it, and reset the `Data`.

## Recommended implementation

**Who needs the item.** Only the app. All SMB I/O runs in the app. The File Provider
extension connects to `SourceReaderService` over XPC (`Registration.connect`) and doesn't link the
SMB library, so it needs no Keychain access.

**Keychain item** (`SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`):

- `kSecClass`: `kSecClassGenericPassword`
- `kSecAttrService`: `"TinyMounter"`
- `kSecAttrAccount`: `"smb://<account>@<server>"`, so that another protocol can use the same
  shape later
- `kSecAttrLabel`: a readable name, for Keychain Access
- `kSecValueData`: the UTF-8 password
- `kSecAttrAccessible`: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable
- Store the domain, if any, in the account string (`DOMAIN\user`) and pass it to
  `smb2_set_domain`. Leave it empty by default: the fixture accepted any domain, but a domain
  member server may not.
- Forget and Start Fresh delete with this exact service and account. Never delete by server
  alone.
- No new entitlements. Keep the current `App.entitlements`.

If the project later uses a paid membership and a Developer ID profile, the same item can move to
the data protection keychain by adding `kSecUseDataProtectionKeychain`. That move is a one-time
re-entry or copy, not a format change.

**libsmb2 calls.** In order: `smb2_set_timeout(10)`,
`smb2_set_version(SMB2_VERSION_ANY3)` (the tests didn't set it, but it refuses SMB 2 dialects
that can't encrypt), `smb2_set_authentication(SMB2_SEC_NTLMSSP)`, `smb2_set_user`,
`smb2_set_domain` when set, `smb2_set_password`, `smb2_set_sign(1)`, `smb2_set_seal(1)`,
`smb2_set_security_mode(SIGNING_ENABLED | SIGNING_REQUIRED)`, `smb2_connect_share`, then clear the
password. Apply the three vendored changes in section 2.

**Error mapping**, from `smb2_get_nterror()` first and the return value second:

| Condition | User-visible result | Password |
| --- | --- | --- |
| LOGON_FAILURE | "Sign In Again…" | keep until replaced; don't retry automatically |
| PASSWORD_EXPIRED, PASSWORD_MUST_CHANGE | change the password on the NAS, then Sign In Again… | keep |
| ACCOUNT_LOCKED_OUT, ACCOUNT_DISABLED, ACCOUNT_RESTRICTION, INVALID_LOGON_HOURS | the account can't sign in now | keep; don't prompt |
| BAD_NETWORK_NAME | the share isn't available | keep |
| ACCESS_DENIED at tree connect | the account has no access to this share (not tested) | keep |
| return -1, `ETIMEDOUT`, resolver `EIO` with status 0 | server not reachable; retry with the existing backoff | keep |
| unexpected guest session (after change 1) | treat as LOGON_FAILURE | keep |

Each rejected attempt counts toward a NAS lockout policy. After one LOGON_FAILURE, stop
reconnecting with that password until the user signs in again.

## Not verified

- Physical Mac and the real NAS. Lockout and expiry behavior on a real NAS (not Samba).
- Guest fallback on a `map to guest = bad user` server, and ACCESS_DENIED at tree connect.
- Access after certificate renewal, and Developer ID signing.
- Data protection keychain with a provisioning profile.
- Process-memory inspection of the zeroing.
- Removing a cached GSS credential to show the current path failing.

## Evidence and cleanup

Local evidence: `results/password-login-20261108/vm-logs/` (CLI cases, Keychain variants,
re-sign, Finder item and end-to-end logs, with the server address replaced) and
`sign-login-spike.py`. The signed bundles were deleted after the tests.

Cleanup: the fixture's disposable account, share, data and password file were removed. Its
`smb.conf` matches the backup taken before the test, and smbd is active. In the VM, the probe app,
its LaunchServices entry, its Keychain items, build products and transfer files were removed.
No File Provider domain was created. The empty sandbox container
`~/Library/Containers/dev.tinymounter.loginspike` remains. macOS container protection refused its
removal, even as root, and it holds no data. The Keychain prompts and a Finder window opened during
the test were closed.
