# libsmb2 for protected SMB operations

Source: [libsmb2-6.3](https://github.com/sahlberg/libsmb2/tree/libsmb2-6.3).
The core library and headers are LGPL-2.1-or-later. COPYING and LICENCE-LGPL-2.1.txt contain
the upstream terms. Copyright notices remain in each source file.

TinyMounter builds a separate dynamic library and embeds it in Contents/Frameworks. It uses
this library for listing, metadata, reads, uploads, ordinary overwrites and organization.
It signs in with the server's saved password over NTLMSSP; macOS mounts only Server Volume
shares. Saves write the ordinary file, set its
length, flush and close. NAS snapshots/backups own previous-version recovery.
The checked-in source builds without network access. Release packaging must preserve the
licence notices, source availability and the user's ability to rebuild and relink the library.
See [rebuilding and replacing the library](../../docs/rebuild-smb.md).

Local changes:

- The app builds without `HAVE_LIBKRB5` and leaves out krb5-wrapper.c, the GSS adapter.
  Its earlier local changes remain in the source: it used Apple's cached NTLM credentials, bound
  to the account and server, handled completed NTLM contexts without another handshake step,
  released temporary credential handles and reported numeric errors.
- User selection does not load NTLM_USER_FILE. Password files are not part of the app's login.
- Every guest session is refused as `STATUS_LOGON_FAILURE`, also for the user `guest`, so a
  server that maps an unknown account to guest can't turn a refused login into a guest session.
  TinyMounter has no guest sign-in.
- `smb2_clear_password()` zeroes and frees the stored password; `smb2_set_password()` and
  `smb2_destroy_context()` call it. The NTLMSSP context zeroes its password copy, the UTF-16
  password, the NT and NTLMv2 hashes, the response and key-exchange keys and the exported
  session key before it frees or leaves them. `smb2_secure_zero()` does the zeroing.
- A password of the form `ntlm:<32 hex digits>` is an ordinary password. Upstream treated it as
  an NT hash, so an account with such a password could not sign in.
- Challenges, salts, client GUIDs and encryption nonces use macOS's arc4random_buf.
- A SET_INFO rename converts `/` to `\` in the new name. Upstream 6.3 converted the request's
  fixed part instead, where a FileId word of 0x002f became 0x005c.
  Tools/check-set-info-encoding.c checks the encoding without a connection.
- AES-128-CCM uses public CommonCrypto CBC and CTR APIs, retaining the same nonce, associated
  data, ciphertext and tag format. CBC authentication uses a 16 KiB scratch buffer; payload
  encryption/decryption remains in place. API failures stop the request before socket queuing;
  failed authentication clears the decrypted payload. Rejected requests retain their unsent
  message IDs. Encrypted sends use the existing 16 MiB receive bound. Encryption remains
  required. The original
  portable implementation is compiled only for the offline reference test with
  `TINYMOUNTER_CCM_REFERENCE`. Tools/check-smb-ccm.c checks an RFC 3610 vector, portable
  equivalence, altered packets, input bounds, API failures and queue rejection. The public
  [CommonCryptor API](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/CCCryptorCreate.3cc.html)
  and SDK header document CBC without padding and CTR in-place operation; no private CCM API
  or additional dependency is used.
- A mutex guards the list of all contexts, because the app creates and destroys contexts on
  several threads, such as the change-notify thread of each share.
- The synchronous `smb2_echo()` refused every connected context: its socket check was
  inverted. The app's notify connection uses the asynchronous echo.
- A socket connect that fails at once returns its errno, not `EIO`. macOS refuses the connect
  with `EHOSTUNREACH` until the user allows Local Network access, and the app must see that.

Prototype/SMB/SMBRename.c is the app's restricted entry point. Authenticated connections require
SMB encryption. It opens and checks directory handles, preserves ancestor paths against SMB
deletion/rename while creating or naming, retains server identity and creation time, and sends a rename with
replacement disabled. Only the app calls it, after checking that the location is not Read only.

The raw I/O adapter reads the vendored context's credit count and negotiated multi-credit
flag to cap each read/write at the server maximum, available credits and 1 MiB. There is one
request outstanding per connection. This uses the same bounds as the library's high-level
pread/pwrite, while retaining decoded server status for error handling. The adapter and its
tests must use the library's build definitions, without `HAVE_LIBKRB5`, so the context layout
matches.
- `smb2_set_previous_session_id()` sets SESSION_SETUP's PreviousSessionId, which upstream always
  sent as 0, and `smb2_get_session_id()` returns the session's ID. The server then ends that
  earlier session of the same user and closes its open files, so an upload cut off by a network
  loss can open its file again at once.
