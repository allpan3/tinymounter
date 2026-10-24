# libsmb2 for folder creation and initial naming

Source: [libsmb2-6.3](https://github.com/sahlberg/libsmb2/tree/libsmb2-6.3).
The core library and headers are LGPL-2.1-or-later. COPYING and LICENCE-LGPL-2.1.txt contain
the upstream terms. Copyright notices remain in each source file.

TinyMounter builds a separate dynamic library and embeds it in Contents/Frameworks. It uses
this library only for exclusive folder creation and initial naming. Reads, file uploads and mount management remain native.
The checked-in source builds without network access. Release packaging must preserve the
licence notices, source availability and the user's ability to rebuild and relink the library.
Signed distribution remains a separate release gate.

Local changes:

- The GSS adapter uses Apple's cached NTLM credentials, bound to the account and server. It
  handles completed NTLM contexts without requesting another handshake step, releases temporary
  credential handles and reports numeric errors. It uses GSS.framework without deprecated
  Kerberos cache APIs or password acquisition.
- User selection does not load NTLM_USER_FILE. Password files are not part of the app's login.
- An explicit guest session disables signing after the server identifies it as guest. An
  authenticated GSS connection refuses an unexpected guest fallback.
- Challenges, salts, client GUIDs and encryption nonces use macOS's arc4random_buf.

Prototype/SMB/SMBRename.c is the app's restricted entry point. Authenticated connections require
SMB encryption. It opens and checks directory handles, preserves ancestor paths against SMB
deletion/rename while creating or naming, retains server identity and creation time, and sends a rename with
replacement disabled. Only the app calls it, after enforcing the location's explicit write grant.
