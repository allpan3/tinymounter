# Finder initial folder naming, 2026-10-23

Initial naming is implemented, but the NAS identity check blocks installation. Signed Finder
verification is still pending. The extension
accepts a folder's initial filename callback, and the app requires a completed create receipt,
the same parent, a fresh write grant and the expected remote identity. General renaming,
moving, file modification and deletion remain denied. M18 is not ready for installation.

## Implementation

The app owns the direct SMB naming client. It uses macOS-cached NTLM credentials bound to the
account and exact server, and requires encryption for authenticated access. Explicit guest
access is separate. The client opens directory handles without delete sharing, refuses reparse
points, checks the source folder's identity and requests a rename with replacement disabled.
Reads, uploads and mount management remain native. The extension gains no share access.

The existing app outbox stores the initial naming intent before the operation. It records a
verified reply before the catalog changes and keeps unresolved attempts pending. Recovery
checks the destination identity and name without repeating an uncertain mutation. A complete
listing can also confirm the result. Completed receipts allow replay of the original create
without another folder. Each completed new folder gets one initial naming operation; the
provider does not advertise general rename capability.

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

## Verification in progress

The setup is macOS VM 1 on macOS 27.0.1 build 26A434. Writes use only the approved disposable
APFS-backed guest SMB fixture on loopback. The original NAS stays read-only. Cache state is
uncontrolled; these are correctness checks. No VM, network or File Provider daemon restart is
authorized for this run.

Regression tests cover collision preservation, definite pre-send failures, interrupted attempts,
lost acknowledgements, stale listings, create replay, request validation and legacy receipts.
Catalog tests cover migration and cursor stability, including two rows with the same original
enumeration key. Required checks and signed Finder results are pending.

Before/after recording, final cleanup and private evidence will be recorded when the VM checks
finish. The physical-Mac app remains M16. No publication or physical-Mac installation is approved.

## Remaining M18 checks

Verify normal New Folder naming, collisions, read-only enforcement and recovery in the signed
app. Keep Both remains a separate unresolved creation flow; this fix does not claim to resolve it.

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

The current identity guard correctly refuses those folders. Native name-based identifiers
cannot establish ownership after a rename or another client's replacement at the same path.
The recommended fix is to use the direct client for exclusive new-folder creation and initial
naming, retaining its server identity separately from native catalog identity. Native file
uploads and reads would stay unchanged. Decision status: proposed; the user must approve the
additional folder-creation transport before implementation.

Name-free evidence is in the VM's .local/phase2/m18-folder-name-identity-classes.json and
m18-folder-name-native-mapping.json. The
earlier recovery-only probe is m18-folder-name-nas-readonly.json. Neither probe sent a rename.

The old signed M18 app reproduced the Finder failure on the disposable fixture with New Folder,
the name "new-folder" and Return. Finder displayed the requested name, but direct inspection of
the fixture backing directory found only the original untitled folder. The before recording
uses that sequence; an after recording is pending. The test location, server, grant and data
were removed, and the fixture's sharing records, service override and guest settings were
restored. The original NAS mount and both Cairndex processes remained running.

A separate regression fix clears a prepared, never-sent naming intent when the user returns
to the original name. All 11 focused naming tests passed with no Swift warnings. The required
Tools/run-checks.sh also passed: 220 tests passed, the optional native SMB fixture test was
skipped after fixture cleanup, and the required builds and benchmark verification passed with
no Swift warnings. This does not verify the signed candidate's Finder behavior. No candidate
app was launched during this follow-up.

The before recording is results/folder-naming-20261023/before.mp4 on the development Mac.
The required-check log remains in the VM at .local/phase2/m18-folder-name-required-checks.log.
Temporary authentication probe apps, source downloads and binaries were removed.
