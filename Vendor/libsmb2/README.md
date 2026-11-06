# libsmb2 for protected SMB operations

Source: [libsmb2-6.3](https://github.com/sahlberg/libsmb2/tree/libsmb2-6.3).
The core library and headers are LGPL-2.1-or-later. COPYING and LICENCE-LGPL-2.1.txt contain
the upstream terms. Copyright notices remain in each source file.

TinyMounter builds a separate dynamic library and embeds it in Contents/Frameworks. It uses
this library for listing, metadata, reads, uploads, ordinary overwrites and organization.
macOS still owns mount management and credentials. Saves write the ordinary file, set its
length, flush and close. NAS snapshots/backups own previous-version recovery.
The checked-in source builds without network access. Release packaging must preserve the
licence notices, source availability and the user's ability to rebuild and relink the library.
The 0.1.0 personal-use package includes these notices and a matching complete source archive.
See [rebuilding and replacing the library](../../docs/release.md#rebuild-and-replace-the-library).

Local changes:

- The GSS adapter uses Apple's cached NTLM credentials, bound to the account and server. It
  handles completed NTLM contexts without requesting another handshake step, releases temporary
  credential handles and reports numeric errors. It uses GSS.framework without deprecated
  Kerberos cache APIs or password acquisition.
- User selection does not load NTLM_USER_FILE. Password files are not part of the app's login.
- An explicit guest session disables signing after the server identifies it as guest. An
  authenticated GSS connection refuses an unexpected guest fallback.
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

Prototype/SMB/SMBRename.c is the app's restricted entry point. Authenticated connections require
SMB encryption. It opens and checks directory handles, preserves ancestor paths against SMB
deletion/rename while creating or naming, retains server identity and creation time, and sends a rename with
replacement disabled. Only the app calls it, after enforcing the location's explicit write grant.

The raw I/O adapter reads the vendored context's credit count and negotiated multi-credit
flag to cap each read/write at the server maximum, available credits and 1 MiB. There is one
request outstanding per connection. This uses the same bounds as the library's high-level
pread/pwrite, while retaining decoded server status for error handling. The adapter and its
tests must use the library's `HAVE_LIBKRB5` definition so the context layout matches.
