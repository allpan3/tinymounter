# Finder initial folder naming, 2026-10-23

Finder initial folder naming passes the signed VM checks. The app creates folders exclusively
through the accepted SMB client and retains server identity separately from native catalog
identity. Reads and file uploads remain native. All 230 tests and required checks pass.
Keep Both remains a separate unresolved creation flow, so M18 is not ready for installation.

## Implementation

The app owns the direct SMB naming client. It uses macOS-cached NTLM credentials bound to the
account and exact server, and requires encryption for authenticated access. Explicit guest
access is separate. The client opens directory handles without delete sharing, refuses reparse
points, checks the source folder's identity and requests a rename with replacement disabled.
Reads, file uploads and mount management remain native. The extension gains no share access.

The existing app outbox stores the initial naming intent before the operation. It records a
verified reply before the catalog changes and keeps unresolved attempts pending. Recovery
checks the destination identity and name without repeating an uncertain mutation. Native
listings only mark a verified result observed; they cannot establish ownership. Completed
receipts allow replay of the original create without another folder. A new folder gets one
initial naming operation before child creation. The provider does not advertise general rename capability.

The first disposable client check renamed a folder and preserved its identity and child bytes.
The native mount could still report the old path briefly afterward. A completed name therefore
holds a stale parent listing until the new name is observed, preserving the existing item ID.
This is a cache-coherence observation, with uncontrolled cache state and no speed claim.

Catalog version 4 separates the mutable name lookup key from an immutable enumeration key.
Folder pages use the enumeration key and row number, so naming cannot move a cursor. The row
tie-breaker also handles a later new folder with the old name. Migrations from versions 1, 2 and
3 preserve IDs, epochs, anchors, write permission and keep requests. This format change serves
the cursor compatibility requirement. Outbox receipts add an optional naming record and keep
reading receipts from the earlier build; no outbox version field was added.

## VM verification

The setup is macOS VM 1 on macOS 27.0.1 build 26A434. Writes used only the approved disposable
APFS-backed guest SMB fixture on loopback. Cache state was uncontrolled; these are correctness
checks. The original NAS stayed read-only. No VM, network or File Provider daemon was restarted.
Only TinyMounter's app and extension were restarted.

The signed normal app passed Finder New Folder naming, nested naming and a small file copy into
the named nested folder, with matching remote bytes. The final normal build repeated New Folder
successfully. The restricted client preserved empty folders, nonempty folders and files in
collision checks. It preserved a child's bytes through naming, refused a wrong server ID or
creation time, and recovered through read-only identity checks without another mutation.

A separate signed source archive added fixture-only commands and stops in two app files. Its
source changes were checked against the normal source; no test hooks are in the repository.
Read-only enforcement, Unicode and case-only names, stable item/server identity and refusal of
a second rename passed. Stops after saving the creation receipt, after creation verification,
after rename success but before its acknowledgement, and after saving rename verification all
recovered to one completed operation. Attempts stopped before a provable result stayed pending.
Each pending case refused disabling changes, removing the location and changing its source.
Only disposable test receipts were discarded during cleanup.

The final client also checked an existing NAS folder through both recovery entry points using
its server ID and creation time. Authentication and metadata checks passed. Both mutation-sent
flags were zero; no create or rename was sent to the NAS. Real-NAS writes and physical-Mac
behavior remain unverified.

Tools/run-checks.sh passed with the writable fixture enabled: 230 tests, no skips or failures,
the generated-project check, release CLI and benchmark verification, and the unsigned app build.
There were no Swift warnings. Regression coverage includes migration, cursor stability,
server/native ID separation, legacy receipts, lost replies and the initial-naming boundary.

## Cleanup and evidence

The test location, server, grant, local copies and remote fixture data are removed. Exact sharing
records, service override and guest settings are restored. The original NAS connection and both
Cairndex processes stayed running. The final normal signed build remains running in the VM with
zero locations, catalogs, domains, kept items or stages. No test hooks remain registered.

During the final diagnostic, an operator error sent SIGBUS instead of SIGUSR1 to TinyMounter.
The normal app was reopened. Reconciliation found no failed sequence; the original share/session
was retained. This was a test-command error, not an observed application defect.

Before/after recordings use the same Finder New Folder, typed name and Return sequence. They
are results/folder-naming-20261023/before.mp4 and after.mp4 on the development Mac. Name-free
VM evidence is in .local/phase2/m18-folder-create-*.json and m18-folder-runtime-*.json, with the
required-check log m18-folder-create-required-checks.log. Source-hook scope and a local patch
are retained in the ignored evidence directory. Temporary probe binaries and the instrumented
archive were removed. The physical-Mac app remains M16; no install or publication is approved.

## Native identifier mismatch

A read-only check of three existing NAS folders found that native SMB inodes differ from all
three server identity sources: FileAllInformation, FileInternalInformation and the QFid create
context. The three server results agree with each other. All three native inodes match Apple's
name-hash calculation for servers on which native file identifiers have been disabled. These
are correctness checks on the same VM with uncontrolled cache state, not performance results.
No rename or other write was sent to the NAS.
Apple's public [inode calculation](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_smb.c)
and [name hash](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_node.c)
explain the native values. The client also remaps the share root's identifier to 2; none of the
three samples was a root alias.

The earlier native-identity comparison correctly refused those folders. Native name-based identifiers
cannot establish ownership after a rename or another client's replacement at the same path.
The accepted fix uses the direct client for exclusive new-folder creation and initial
naming, retaining its server identity separately from native catalog identity. Native file
uploads and reads stay unchanged. Decision status: accepted. The user approved the additional
folder-creation transport. The new implementation saves the server identity and creation time
while a handle blocks replacement, then records native metadata under that handle. The same
server proof guards initial naming. Its native callback can update the catalog's file ID
without replacing the item's UUID, children or keep requests. An uncertain naming attempt
requires a direct identity check, rather than trusting a name-based native listing.

Existing outbox receipts remain readable. A legacy folder receipt without server proof cannot
authorize naming, and an uncertain legacy create remains pending. No new outbox version field
was added. The VM checks above cover the new implementation and signed Finder behavior.

Initial naming precedes child creation. Once a child creation request exists, the parent cannot
start its initial naming operation. This prevents moving saved child upload paths through a
later general rename. A child request first finishes any already pending parent naming.

Name-free evidence is in the VM's .local/phase2/m18-folder-name-identity-classes.json and
m18-folder-name-native-mapping.json. The
earlier recovery-only probe is m18-folder-name-nas-readonly.json. Neither probe sent a rename.

The old signed M18 app reproduced the Finder failure on the disposable fixture with New Folder,
the name "new-folder" and Return. Finder displayed the requested name, but the server retained
the original untitled folder. The new signed app completed that same sequence with the requested
name on the server and no leftover untitled folder.

A separate regression fix clears a prepared, never-sent naming intent when the user returns
to the original name. It is covered by the final required checks above.
