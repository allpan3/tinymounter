# New-file publication gate, 2026-10-23

Decision status: M18 and its disposable writable VM fixture are accepted. The staged-rename
route failed its required publication check. Native exclusive creation works, with a remote
visibility tradeoff that needs a decision before implementation. The app remains read-only;
no production code, entitlement, settings format or catalog changed.

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

## Native API follow-up

The user's follow-up asked why this failed and challenged treating it as a fundamental obstacle.
The original conclusion was too broad: native SMB writes work. The failure concerns the extra
atomic publication guarantee in the accepted plan, not permission to write through SMB.

Apple's published [XNU rename dispatch](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/kpi_vfs.c)
uses `VNOP_RENAMEX` for `RENAME_EXCL`. The published [SMB vnode operation table](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_vnops.c)
implements ordinary rename but has no exclusive-rename entry. Its hard-link handler also rejects
that operation. This explains the observed ENOTSUP result and capability values; it is not a
server write-permission failure. The [SMB2 rename implementation](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_smb_2.c)
sets `replace_if_exists` to zero internally. Ordinary POSIX rename can still replace a target
because the vnode handler first removes a known existing destination. Published source is
supporting evidence, not a claim that the installed kernel is byte-identical to that revision.

A disposable command-line helper called the installed Foundation FileManager. An interposed
ordinary-rename wrapper inserted a synthetic competing file immediately before the actual
rename. Only this diagnostic process loaded the wrapper; no app or system process was modified.

| Installed FileManager check | Result |
| --- | --- |
| Move to an absent destination on SMB | Succeeded; complete bytes and file identity preserved |
| Move with an existing SMB destination | Cocoa error 516; original and pending bytes preserved |
| Create destination after preflight, before ordinary rename on SMB | Move succeeded and replaced the competing file |
| Same injected race on APFS | Also replaced the competing file |

The installed FileManager called ordinary `rename`, so its usual existence check does not supply
atomic protection against a competing create. The public [Foundation implementation](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/FileManager/FileOperations.swift)
likewise checks the destination before ordinary rename. No private API, system tracing or
sandbox bypass was used.

The installed NSData header explicitly disallows combining atomic writes with the
without-overwriting option. It therefore does not supply an alternate supported combination
for this requirement.

Native `open` with `O_CREAT | O_EXCL` is a viable alternative for new-file uploads. In 20 races
between the writable SMB mount and its local backing directory, exactly one creator won, the
other received EEXIST, and the final bytes matched the winner. Existing files were not changed.
A separate interrupted-write check wrote and flushed 16 KiB of an intended 64 KiB file. The
backing path could read that partial file, which confirms the visibility tradeoff.

This route preserves the no-overwrite requirement and can keep a durable local pending copy.
The app must report an upload incomplete until it finishes. Other devices can see a partial new
file during upload, including after interruption. That differs from the accepted requirement
that only a complete file appears under its final name. The user accepted this specific change on 2026-10-23. Implementation and signed runtime
verification are tracked in the phase 4 plan.

The follow-up fixture, mount, test files and share are removed. Original sharing records and
launch override match their snapshot, the SMB service is unloaded as before, and guest settings
are off. One original SMB mount and the existing app/Cairndex processes remain present. The
follow-up evidence is m18-fm-*.json, m18-fm-*.trace, m18-exclusive-create.json,
m18-native-cleanup.json and m18-native-final-state.json under the same VM evidence directory.
Only synthetic names occur in the diagnostic trace, and its output records API names and flags.
Tools/run-checks.sh passed again after the follow-up: all 192 tests, project generation, release
CLI verification and the unsigned app build, with no Swift warnings. The log is
.local/phase2/m18-native-checks.log.

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

Next recommendation, decision status: proposed. Keep native SMB and use exclusive creation if
the user accepts partial new-file visibility during upload. Keep the durable pending copy and
no-overwrite requirement. A transport change is not justified by this check alone. Direct SMB
remains an alternative if complete-file atomic publication stays mandatory. No dependency,
transport switch, real-NAS write, publication or physical-Mac installation is approved here.

## Follow-up, 2026-10-23

The user accepted native exclusive creation and partial new-file visibility during upload.
The create/recovery implementation and its remaining Finder scheduling gate are recorded in
[the M18 results](2026-10-23-create-items.md). The earlier publication checks above still describe
the measured native API limits; complete-file exclusive rename is not used.
