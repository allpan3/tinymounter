# New-file publication gate, 2026-10-23

Decision status: M18 and its disposable writable VM fixture are accepted. Implementation is
blocked at the required publication check. The app remains read-only; no production code,
entitlement, settings format or catalog changed.

The native SMB probes returned ENOTSUP, errno 45, for both exclusive rename and
hard-link publication. The volume also reports that neither capability is supported. These
operations cannot yet support the approved guarantee that a complete upload never replaces an
existing destination. An existence check followed by ordinary rename is not a safe substitute.

## Setup and reproduction

The fixture uses File Sharing in macOS VM 1 on macOS 27.0.1, with a disposable local APFS
backing directory and a separate writable guest SMB share mounted hidden through the loopback
interface. Sharing records, service state and guest settings were captured before setup. Only
the disposable share was enabled. The existing NAS connection and Cairndex are outside the fixture.

`Tools/check-upload-publication.py --fixture-root <approved-disposable-directory>` creates its
own temporary directory, uses a 1 MiB synthetic payload and removes that directory afterward.
Run it once through the SMB mount and once directly on the local APFS backing directory. It
checks exclusive path-based and descriptor-based rename, hard links, name collisions, exclusive
folder creation and ordinary rename. Output contains no source names or paths. It is a destructive
fixture check, never a command to run against a production share without permission.

Cache state is uncontrolled. This is a correctness check, with no speed claim.

## Results

| Check | Native SMB mount | Local APFS control |
| --- | --- | --- |
| `renamex_np(RENAME_EXCL)` to a new destination | ENOTSUP, errno 45; final absent and staged bytes intact | Complete bytes published; file identity preserved |
| `renameatx_np(RENAME_EXCL)` to a new destination | ENOTSUP, errno 45; final absent and staged bytes intact | Complete bytes published; file identity preserved |
| `linkat` to a new destination | ENOTSUP, errno 45; final absent and staged bytes intact | Complete bytes published; file identity preserved |
| Same-name collision, all three APIs | EEXIST, errno 17; original and staged bytes unchanged | EEXIST, errno 17; original and staged bytes unchanged |
| Exclusive folder creation on an existing name | EEXIST; existing folder retained | EEXIST; existing folder retained |
| Ordinary rename over a disposable existing file | Replaced the existing bytes | Replaced the existing bytes |
| Probe directory cleanup | Removed | Removed |

The SMB collision results alone are insufficient: the kernel can refuse an already existing
name even when it cannot perform the operation for an absent destination. The positive APFS
control establishes that the same probe can publish complete bytes and reject a collision on a
filesystem that supports the operations. The SMB volume's Foundation capability values were
false for both `volumeSupportsExclusiveRenaming` and `volumeSupportsHardLinks`.

Tools/run-checks.sh passed all 192 tests, project generation, release CLI verification and the
unsigned app build, with no Swift warnings. The final probe passed its SMB-refusal and APFS
control assertions. It ran outside the app sandbox; the capability failure occurs before any
sandboxed upload implementation can be verified.

## Cleanup and evidence

The test mount, probe files, backing directory and share were removed. Original sharing records
match the saved snapshot exactly. The SMB launch override was restored, the service is unloaded
as before, SMB guest access is off and guest login remains off. One original SMB mount remains;
the existing TinyMounter app and Cairndex processes remain present. No File Provider test
location, download or app build was added. No NAS content or physical-Mac app changed.

Sanitized probe, volume-capability, cleanup and final-state JSON is retained under the ignored
host directory results/upload-publication-20261023. The VM holds the corresponding
.local/phase2/m18-*.json records and m18-publication-checks.log. The settings snapshot is private
and root-readable only; it is not copied into the repository. No UI recording is needed because
no app or File Provider behavior changed.

## Consequence for M18

Do not enable writes using a separate existence check or expose a partial final file. The approved
plan requires safe publication before the upload outbox and Finder create UI can be used. Pending
uploads, signed Finder creates, interruption recovery and migrations have not been implemented
or verified. The installed physical-Mac app remains M16.

SMB2 defines a rename with `ReplaceIfExists` false that must refuse an existing destination
([Microsoft specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/52aa0b70-8094-4971-862d-79793f41e6a8)).
The result above is about the tested native mounted path, not an SMB protocol limitation or a
claim about every server. Apple's [exclusive-renaming volume property](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumesupportsexclusiverenaming)
corresponds to `RENAME_EXCL` support.

Next recommendation, decision status: proposed. Evaluate a direct SMB route for safe publication,
including authentication, sandbox access and library licensing before choosing a dependency.
No dependency, transport switch, real-NAS write, publication or physical-Mac installation is
approved by this result.
