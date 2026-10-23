# Password-free folder naming connection, 2026-10-23

The authentication blocker in the earlier naming investigation was a probe defect. A corrected
probe acquired the server-bound credential without a password, then connected and read the share
root in a signed sandboxed app. Initial folder naming itself remains unimplemented. The user
asked to continue the fix after the dependency explanation. A limited `libsmb2` prototype is
accepted; native reads and uploads remain unchanged.

## Setup and findings

The checks used macOS VM 1 on macOS 27.0.1 build 26A434 and the existing native SMB connection.
The direct client only connected and queried root metadata. It did not create, rename, delete
or write any NAS item. No mount, sharing setting, network or service changed. Cache state was
uncontrolled; this was an authentication check with no speed claim.

The earlier probe split the credential display name at its last backslash before separating
the user from the domain. This treated a backslash in the server-bound domain as a username
separator. All four credentials visible in this follow-up contained the expected account and
server. Separating the user first and requiring an exact server suffix found all four matches.
Named acquisition through public GSS APIs succeeded. The earlier zero-match result cannot
establish a credential-access limitation.

The isolated `libsmb2-6.3` client required two GSS adapter corrections. It acquired the NTLM
mechanism using the matched principal, and stopped calling GSS after the context completed.
An extra call after NTLM completion had crashed the probe. The corrected client connected and
queried root metadata with no password acquisition. Both calls returned zero in a correctly
signed sandboxed probe bundle. A further unsigned check requiring SMB encryption also connected
and queried root metadata successfully. No credential name, UUID, token or key was printed.

## Implementation boundary and remaining checks

The prototype library is separate from the extension. Its app entry point accepts the approved
endpoint, source, destination and expected folder identity. The app must enforce a fresh write
grant and completed-create provenance before calling it. It must preserve durable naming intent
and reconcile an ambiguous result. A successful isolated connection does not establish those
checks or Finder behavior.

The library uses GSS.framework without deprecated Kerberos cache calls or password files.
Authenticated naming requires encryption. Explicit guest naming is separate and must refuse an
unexpected guest fallback from authenticated access. Native reads and uploads do not use this
library. The core and headers are LGPL-2.1-or-later. The checked-in source, notices and dynamic
linkage support the prototype; source availability, relinking and signed distribution remain
requirements for any release.

## Evidence and next step

Name-free VM evidence is in .local/phase2/m18-naming-auth-*.json. It includes the corrected
exact-match check, unsigned connection, signed sandboxed connection and encrypted connection.
Temporary probe builds remain isolated from the installed app. No new File Provider location or
fixture has been added by these authentication checks.

Next, verify the restricted rename entry point on disposable VM data, implement durable initial
naming and check the normal signed Finder flow. Keep Both remains a separate unresolved flow.
