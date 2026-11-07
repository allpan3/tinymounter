# Research notes and sources

Reviewed 2026-10-10. These notes distinguish documented behavior, user observations, and engineering hypotheses. No competitor was installed or benchmarked and no NAS was mounted during this research.

## Findings

**A File Provider location is a synchronization filesystem interface.** A native SMB read goes through Apple's network filesystem client. File Provider instead exposes local APFS objects, asks an extension to fetch missing content, and serves materialized bytes locally. There is extra scheduling and local writing on a miss, but cached reads can be faster than the network. It is not merely the same SMB mount with an icon [A1–A3].

**There is a documented streaming mechanism.** `NSFileProviderPartialContentFetching` is available from macOS 12.3. Apple explicitly gives video streaming as an example. However, its documentation says: “To trigger a partial download, an app must use POSIX read operations to read part of the file. If you clone the entire file, or read the file using file coordination, the system requests the entire file.” This makes application behavior a first-class benchmark variable [A1].

**The byte handoff can avoid another full physical copy.** The SDK requires a same-volume regular staging file with bytes at the reported offsets, and states that the system clones and unlinks that file. The provider cannot mutate it after callback completion. The API permits a larger aligned extent than the requested minimum and specifies strict versioning. It also exposes `NSExtensionFileProviderDownloadPipelineDepth` (1–128 per domain); that setting is not itself a guarantee of efficient per-file SMB pipelining [A2].

**No reviewed source establishes a 10–20 MB/s or 80 MB/s File Provider ceiling.** A suitable implementation might approach native throughput, subject to local disk, CPU, request scheduling, API behavior, and application reads. A throughput guarantee requires measurement. Serial small reads, mismatched security settings, slow metadata work, copying, or whole-file hydration are plausible explanations, not proven diagnoses.

**Offline availability needs a retention policy.** A partially read video is not a complete offline file. Ordinary downloaded content may be evicted. A keep-downloaded content policy exists; macOS 27 also adds eager namespace materialization, important for unvisited subfolders of a pinned tree [A4].

**The user environment is specific enough to start a spike.** The user reports macOS 27 and a UGREEN NAS running Debian. The development VM is `macOS VM 1`, macOS 27.0.1 build 26A434, with Xcode 27.0 build 27A266a. VMPal reported `adminExecutionAvailable: true`. The workspace was empty. VM throughput cannot be assumed to match the physical Mac.

## Runtime follow-up, 2026-10-10

The [signed-provider experiment](results/2026-10-10-provider-runtime.md) now distinguishes three permission layers: shared App Group access, source bookmark scope, and Network Volumes privacy. A team-prefixed macOS App Group plus read-only document-scoped bookmarks passed local fetching. Foreground saved-bookmark access to the NAS passed, while the extension's source open was denied by TCC, which explicitly reported that this extension point cannot prompt. This is direct evidence from this VM, not an assertion about every macOS/NAS configuration.

The installed SDK documents that app-scoped bookmarks grant access only to their creating sandboxed app; document-scoped bookmarks can be used by another sandboxed app with access to both bookmark and owning document. Keep that owning document stable across pin metadata updates [A6–A7]. Public process I/O policy controls whether ordinary reads can materialize dataless content [A8]. Neither source permissions nor download policy establishes network throughput.

The subsequently approved [app-owned reader experiment](results/2026-10-10-app-reader.md) uses a restricted File Provider service to connect the main app and extension [A9]. The app reads the NAS; the extension hands staged bytes to macOS. NAS checksums and app-relaunch recovery now pass without broader privacy access. Short File Provider reads remain slow, improving from a 6.3 MB/s median at 4 MiB extents to 23.1 MB/s at 16 MiB. This locates an integration cost in this prototype/VM; it neither establishes an unavoidable Apple limit nor diagnoses competitor code.

## Delay follow-up, 2026-10-11

[Per-read tracing](results/2026-10-11-provider-delay.md) correlates local and NAS reader stalls with `fileproviderd`'s “Materialization or eviction waiting for flush” and subsequent database batch timer. Reads resume about 2–4 ms after its flush-complete event. This is observed behavior on this VM/build, not a documented universal API latency. Larger returned extents improve throughput at the expense of first-byte delay; the signed prototype has been restored to 16 MiB after the diagnostic controls.

The public manager API can request a particular range to be downloaded [A10]. Its completion acknowledges scheduling, not hydration completion. The [read-ahead experiment](results/2026-10-11-player-readahead.md) used it: `fileproviderd` delivered speculative fetches about 50 ms after each request, flagged as system requests. It held a pending seek for as long as speculative requests for that file kept arriving back to back, up to about 2.7 s, and delivered it about 0.1 s after they paused. One reader fault that coincided with a finishing speculative materialization made `fileproviderd` log `materializationFailed`, fail the read and fall back to a full download. These are observations on this build, not documented behaviour. No supported API to bypass the observed internal database flush was found in the reviewed headers.

`fetchPartialContents` documentation also describes `NSFileProviderExtensionNonMaterializingProcessNames`, a UserDefaults key naming processes whose POSIX or coordinated reads must not fetch content [A2]. With Finder listed, Finder's coordinated open failed with `EPERM` and Finder didn't launch the app, so the key can't turn a Finder open into a streamed one. Listing `ScopedBookmarkAgent` instead stops its recent-file bookmark resolution from downloading whole files, and the bookmarks still resolve (M5 follow-up, 2026-10-15).

## Recovery and race follow-up, 2026-10-15

The [runtime follow-up](results/2026-10-15-runtime-followup.md) reproduced the materialization
race in 5/5 moving-boundary reads with the approved 128 MiB window. A temporary 16 MiB window
had 0/5 failures. The [window comparison](results/2026-10-15-read-ahead-window.md) added 0/6
and adopted the 16 MiB window. This is a stress workload in the VM, not a real-player failure
rate or proof that one chunk eliminates the race.

The manager header says replicated providers must signal the working set; individual container
signals are ignored. `signalErrorResolved` cancels error throttling, without guaranteeing a Finder
retry [A11]. A full-range download request on a dataless directory enumerates only one level and
leaves its children dataless [A10]. A diagnostic request restored the failed folder's 24 children,
but Finder retained its error banner. The pending set did not expose that failed folder. These
observations do not establish a complete supported automatic recovery path.

## File types and access patterns

Choose the full-versus-partial path from the application's actual request and the user's download intent, not just the file extension. Video and audio are obvious streaming candidates, but readers may also request metadata or indexes near EOF. PDF is not categorically a whole-file workload: Adobe documents linearized PDFs as optimized for page-served network access [P1]. That establishes a format capability, not how Preview or another macOS viewer accesses this provider. Test each viewer with representative documents; a coordinated open still requests full materialization under Apple's documented rules [A1].

## Competitor research

### Mountain Duck

Mountain Duck 5's Integrated mode uses File Provider on macOS and Cloud Files on Windows. Its documentation distinguishes that from Online and Smart Synchronization modes. Integrated mode behaves as a local directory, supports offline content and background uploads, and does not honor custom mount locations [M1].

Its SMB documentation says connections sign and encrypt requests when supported by SMBv3 by default [M2]. This is an important comparison variable against native Finder SMB. The open Cyberduck SMB implementation imports SMBJ and configures its signing/encryption options; that identifies a public related implementation, not proof of the exact bottleneck or exact code in the user's installed binary [M3].

The public download page advertised 5.3.2 at review time. The user's tested version is unknown. The reported 10–20 MB/s and stalled videos remain user observations; neither the API docs nor competitor docs alone explain them.

### Driio

Correct product: [driio.app](https://driio.app/), [App Store](https://apps.apple.com/us/app/driio/id6757922119). The vendor identifies it as a File Provider app with direct server connections, SMB2/3, connection pooling, parallel file transfers, and Keychain credentials [D1]. That does not establish how it pipelines one file or whether it implements Apple's partial-content protocol.

Its documentation describes configurable polling; release 2.4 adds SMB2 change notifications, fallback for unsupported or silent watches, and a watcher kept in the app because a background helper may be suspended. Release 2.7 describes macOS 27 recursive folder pinning using eager materialization [D2]. These are useful real-world lifecycle/metadata lessons, not independently tested performance evidence.

The site lists macOS release 2.7.4 dated 2026-10-06; the general App Store page retrieved showed 2.7.3 with iOS-oriented notes, so do not conflate those with the installed Mac version. The 80 MB/s figure is user-reported.

The vendor reports macOS 27 local-network permission failures affecting the Finder extension independently of the main app [D1–D2]. Treat this as a vendor report to reproduce, not a confirmed diagnosis of this VM. Include a clean-install permission test. No suggested system-cache deletion or system-daemon reset was performed.

### AutoMounter

AutoMounter documents login/reconnection behavior, network rules, VPN/Wi-Fi matching, wake-on-LAN, remounting between Wi-Fi and Ethernet, discovery, custom mount points, and hidden/read-only mounts. Its App Store version uses a helper for some capabilities; its direct version has different packaging [N1]. It is the model for a later mount-management mode, not evidence that ordinary native mounts provide persistent offline files.

### PolyDrive — reviewed 2026-10-11

PolyDrive uses File Provider for cloud/server connectors, but explicitly excludes SMB: its home page says “SMB shares are the one exception: those are mounted as volumes by macOS's own SMB client” [PD1]. Its support page documents mounting at login and remounting after network loss; the app must remain running for that management [PD2]. It therefore covers part of the proposed server volume mode, but its documented SMB path does not supply the persistent offline SMB replica that motivates TinyMounter. Do not transfer its cloud-drive pinning claims to native SMB shares.

For File Provider connectors, PolyDrive advertises file/folder **Keep Available Offline**, on-demand ranges and local-copy removal. The App Store listing retrieved shows **2.1, September 18**, with release notes adding offline folder listings on macOS 27 [PD4]. It supports macOS 15.4 or later on Apple Silicon/Intel; two cloud drives and unlimited SMB shares are free. The FAQ lists a US$19.99 one-time unlock for additional cloud drives; this is a vendor-listed price, subject to storefront/region changes [PD2].

The vendor's comparison reports 4 MiB arriving for a 64 KiB seek into an R2 file. It explicitly excludes speed comparisons against another provider. It also says VLC/IINA's own Open command can use ranges, while Finder double-click/Open With materializes the whole file before launch [PD3]. Treat the Finder claim as a vendor observation to test on our macOS build, not a universal Apple API guarantee; Apple's documented distinction is POSIX partial reads versus coordinated/whole-file access [A1]. This is directly relevant to the user's desired click-to-play behavior.

No reviewed page establishes ≥90% native throughput for an offline-caching SMB path, network-interface preference/switching rules, or durable offline-edit upload/conflict handling. The advertised “up to 7×” improvement concerns parallel folder transfers of small files, not a single large SMB file [PD2, PD5]. PolyDrive was not installed, connected to the NAS or benchmarked for this review.

## Alternative approaches

- **Replicated File Provider:** strongest fit for iCloud-like integration with Finder and other file managers and local offline files. Selected, subject to measured performance/player behavior.
- **Server volume (native SMB) alone:** best performance reference and the later server volume mode. Does not fulfill durable offline caching.
- **Native SMB behind File Provider:** valuable controlled experiment and possible production transport. Requires staging plus validated sandbox, mount ownership, cancellation, and helper behavior.
- **Direct async SMB behind File Provider:** removes an internal mount and offers explicit range/scheduling control. Requires proving transport performance, feature compatibility, and licensing.
- **FSKit / macFUSE custom filesystem:** greater filesystem control but requires designing cache, consistency, offline state, and file-manager integration. FSKit is a current public user-space filesystem framework and mentions network resources [F1]; dismissing it as categorically unable to handle a network resource would be incorrect. It is not a ready-made cloud-sync/offline system and is not the first architecture to implement here.
- **WebDAV/localhost relay over SMB:** unnecessary extra server/protocol in the critical path for an SMB-only first release.
- **Server-side companion service:** could eventually provide immutable versions/change journals/conditional writes, but violates the simple bring-your-own-SMB starting point. Keep optional and later.

## Source register

### Local storage and File Provider retries

- **S1:** Installed Xcode 27 `NSFileProviderManager.h`, read 2026-10-21. `signalErrorResolved` lists authentication, server quota, reachability, synchronization and exclusion errors; it does not list local disk-full errors. `requestDownloadForItem` is the supported route used to request blocked kept files again.
- **S2:** Installed SDK `NSURL.h` distinguishes ordinary free capacity from important/opportunistic capacity estimates that can include purgeable space. M16 reads fresh `volumeAvailableCapacity` values and handles write failures even after admission. `NSFileProviderErrorInsufficientQuota` describes server-account upload quota, so it is not used for local storage pressure.

### Native SMB directory monitoring

- **C1:** [DispatchSourceFileSystemObject](https://developer.apple.com/documentation/dispatch/dispatchsourcefilesystemobject) and [Apple's kernel-queue guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/KernelQueues/KernelQueues.html), read on 2026-10-19. Public vnode sources observe a descriptor, with O_EVTONLY suitable for notification-only access.
- **C2:** Apple's published [smbfs_vnop_monitor](https://github.com/apple-oss-distributions/smb/blob/main/kernel/smbfs/smbfs_vnops.c) calls the native change-notify setup for directories. The published [notify filters](https://github.com/apple-oss-distributions/smb/blob/main/kernel/smbfs/smbfs_notify_change.c) omit ordinary size and last-write changes. These sources establish a route and a coverage limit, not the installed kernel's exact implementation. A standalone read-only loopback SMB probe in the VM delivered two directory events for an orchestrated add/edit/delete sequence; periodic reconciliation remains necessary.

### Apple File Provider

- **A1:** [NSFileProviderPartialContentFetching](https://developer.apple.com/documentation/fileprovider/nsfileproviderpartialcontentfetching) — availability, POSIX limitation, video example. Read the official DocC payload at `https://developer.apple.com/tutorials/data/documentation/fileprovider/nsfileproviderpartialcontentfetching.json`.
- **A2:** [fetchPartialContents](https://developer.apple.com/documentation/fileprovider/nsfileproviderpartialcontentfetching/fetchpartialcontents(for:version:request:minimalrange:aligningto:options:completionhandler:)) and installed Xcode 27 SDK headers: `FileProvider.framework/Headers/NSFileProviderReplicatedExtension.h`, `NSFileProviderDefines.h`, `NSFileProviderItem.h`, `NSFileProviderManager.h`. Local headers supplied the detailed same-volume layout, handoff, alignment, cancellation, strict-version, and pipeline-depth contracts. The DocC payload documents `NSFileProviderExtensionNonMaterializingProcessNames` and its coverage of coordinated reads since macOS 11.4.
- **A3:** [WWDC21: Sync files to the cloud with FileProvider on macOS](https://developer.apple.com/videos/play/wwdc2021/10182/) — official transcript read; APFS materialization, subsequent local reads, uploads, eviction, working set, sync anchors. This older talk predates the partial-content API; use A1/A2 for current range support.
- **A4:** [NSFileProviderContentPolicy](https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy), [NSFileProviderNamespacePolicy](https://developer.apple.com/documentation/fileprovider/nsfileprovidernamespacepolicy) — content-policy documentation plus installed SDK header definitions; namespace API availability in the SDK is macOS 27.0. `downloadEagerlyAndKeepDownloaded` prevents disk-pressure eviction; `materializeEagerly` controls eager folder enumeration. Reviewed again on 2026-10-19; M14 verified automatic nested-folder enumeration and file downloads in the signed VM app ([results](results/2026-10-19-folder-keeps.md)).
- **A5:** [Synchronizing files using file provider extensions](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions) — official sample documentation read; App Groups/team setup, domains, enumeration, change anchors, domain removal, target organization. Useful starting reference, not a production SMB sync engine.

- **A6:** [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) — macOS supports `<team identifier>.<group name>` without registering that form in the Developer portal. Runtime group-container diagnostics confirmed the prefix requirement for the tested signing configuration.
- **A7:** Installed Xcode 27 `Foundation.framework/Headers/NSURL.h`, bookmark creation/resolution contracts; [Apple sandbox entitlement reference](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) — `com.apple.security.files.bookmarks.document-scope`, owning document access, and read-only scope. `NSFileProviderManager.h` documents the security scope of `getUserVisibleURL` results.
- **A8:** Installed Xcode 27 SDK `usr/include/sys/resource.h` — `getiopolicy_np`, `setiopolicy_np`, `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` and process scope; `sys/stat.h` — `SF_DATALESS`. Actual inherited OFF policy and opt-in ON behavior were tested in the runtime experiment.
- **A9:** Installed Xcode 27 SDK `FileProvider.framework/Headers/NSFileProviderService.h` and `NSFileProviderReplicatedExtension.h` — `NSFileProviderServicing`, anonymous listener endpoints, restricted services available to domain managers, and `NSFileProviderManager.getService`. `Foundation.framework/Headers/NSFileManager.h` documents `NSFileProviderService.getFileProviderConnection`; `NSXPCConnection.h` documents peer code-signing requirements. These public APIs bootstrap the app-owned reader without a Mach lookup exception or separate helper. Runtime proved the expected signed peers connect; adversarial peer rejection remains untested.
- **A10:** Installed Xcode 27 SDK `FileProvider.framework/Headers/NSFileProviderManager.h`, Materialize category, and the framework Swift interface — `requestDownloadForItem(withIdentifier:requestedRange:completionHandler:)`, available on macOS 13. Range requests schedule partial fetches; completion is scheduling acknowledgement. `NSFileProviderReplicatedExtension.h` documents valid range layout and `knownSparseRanges`: that flag applies to complete-file sparse content, not a way to mark unfetched holes as downloaded. `NSFileProviderRequest.h` restricts requesting-executable information to managed deployments; it cannot serve as a general player-position signal.
- **A11:** Installed Xcode 27 SDK `FileProvider.framework/Headers/NSFileProviderManager.h`, reviewed 2026-10-15 — working-set-only signaling for replicated providers, `signalErrorResolved` removes throttling, and directory `requestDownloadForItem` performs one-level enumeration. The reimport API can widen its scope and restarts the extension; it is not a targeted Finder error reset.

- **A12:** Installed Xcode 27 `FileProvider.framework/Headers/NSFileProviderManager.h` and `Foundation.framework/Headers/NSURL.h`, reviewed 2026-10-19. `getUserVisibleURL` returns security scope; content reads and child listings require file coordination. The materialized-set notification supports local-copy refresh. `URLUbiquitousItemDownloadingStatus.current` means the latest version known to the device, not a live source check. The signed VM probe found that returned materialized items' download flags and content versions cannot establish completeness; public URL metadata distinguished a complete file from a partial file. The manager's public `waitForStabilization` waits for filesystem changes and provider changes up to the call to be applied. It supplies a consistency barrier before querying local-copy metadata; it is not a live source scan.
- **A13:** Installed Xcode 27 `Foundation.framework/Headers/NSProgress.h` and `FileProvider.framework/Headers/NSFileProviderItem.h`, reviewed 2026-10-19. A published file progress with a file URL can be observed by other processes; downloading is a public file-operation kind. Replicated providers' item downloaded/downloading flags are ignored. A signed VM comparison verified that progress publication displays Finder's native circle during kept transfers ([results](results/2026-10-19-keep-download-progress.md)); the headers alone do not promise that UI.

### Vendors and SMB implementations

- **P1:** [Adobe Acrobat SDK, `PDSaveFlags`](https://opensource.adobe.com/dc-acrobat-sdk-docs/acrobatsdk/apireference/PD_Layer/General.html#PDSaveFlags) — reviewed 2026-10-11. `PDSaveLinearized` writes a PDF “optimized for page-served remote (network) access.” This does not establish macOS Preview's access pattern or File Provider performance.

- **M1:** [Mountain Duck connect-mode comparison](https://docs.mountainduck.io/mountainduck/connect/), [Integrated mode](https://docs.mountainduck.io/mountainduck/connect/integrated/), [product/download page](https://mountainduck.io/).
- **M2:** [Cyberduck/Mountain Duck SMB documentation](https://docs.mountainduck.io/protocols/smb/) — supported SMB use, authentication, signing/encryption defaults.
- **M3:** [Cyberduck SMBSession source](https://github.com/iterate-ch/cyberduck/blob/master/smb/src/main/java/ch/cyberduck/core/smb/SMBSession.java) — live master inspected on the research date; related open-source client configuration, not a pinned version of Mountain Duck.
- **D1:** [Driio product](https://driio.app/), [documentation](https://driio.app/docs), [App Store](https://apps.apple.com/us/app/driio/id6757922119).
- **D2:** [Driio changelog](https://driio.app/changelog) — especially 2.4, 2.7, and 2.7.4. Vendor-reported behavior and fixes.
- **PD1:** [PolyDrive home](https://polydrive.net/) — read 2026-10-11; the “How it works” section explicitly separates native SMB volumes from File Provider connectors.
- **PD2:** [PolyDrive support and FAQ](https://polydrive.net/support) — read 2026-10-11; SMB login/remount behavior, app lifecycle, file/folder pinning, supported OS and price/tier claims.
- **PD3:** [PolyDrive comparison, “What a seek costs”](https://polydrive.net/compare#seeking) — read 2026-10-11; vendor range-size observations and Finder-versus-player opening limitation. Not an independent performance benchmark.
- **PD4:** [PolyDrive Mac App Store listing](https://apps.apple.com/us/app/polydrive/id6797990515) — read 2026-10-11; displayed version 2.1 dated September 18, macOS 27 offline folder-listing changes, and native SMB mount/reconnect description.
- **PD5:** [PolyDrive troubleshooting](https://polydrive.net/troubleshooting) — read 2026-10-11; separates folder-transfer claims from first-open/range behavior and confirms macOS handles SMB mounting. No suggested daemon resets or system changes were performed.
- **L1:** [libsmb2](https://github.com/sahlberg/libsmb2) — live README reviewed; recommended async API, SMB2/3 support, signing/encryption, LGPL-2.1. Performance descriptions are project claims until measured.
- **L2:** [AMSMB2](https://github.com/amosavian/AMSMB2) — Swift wrapper README reviewed; includes a dependency/linkage licensing warning. Shipping legal/distribution review is still required.

### Mount management and alternatives

- **N1:** [AutoMounter](https://www.pixeleyes.co.nz/automounter/) — product features and packaging; installed SDK `NetFS.framework/Headers/NetFS.h` — `NetFSMountURLAsync`, mount flags, request cancellation.
- **N2:** [Apple: Configure SMB Multichannel behavior](https://support.apple.com/en-us/102010) — default support from macOS 11.3, redundancy, interface preference and limitations. No system configuration changes made.
- **N3:** [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) — official API descriptions read; network observations and per-user helper registration.
- **F1:** [FSKit](https://developer.apple.com/documentation/fskit) — official framework overview read; user-space filesystem modules, resources, and current design flows.

### Upload publication

- **W1:** Installed Xcode 27 SDK `sys/stdio.h`, `sys/attr.h` and Foundation `NSURL.h`, reviewed
  2026-10-23. `RENAME_EXCL` and `VOL_CAP_INT_RENAME_EXCL` describe exclusive rename support.
  Apple's [volumeSupportsExclusiveRenaming](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumesupportsexclusiverenaming)
  property reflects support for that rename option. The [VM fixture check](results/2026-10-23-upload-publication.md)
  found the capability absent on native SMB and present on APFS; these are runtime results for
  that fixture, not a compatibility claim about every server.
- **W2:** Microsoft's [FileRenameInformation for SMB2](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/52aa0b70-8094-4971-862d-79793f41e6a8),
  reviewed 2026-10-23. `ReplaceIfExists` false requires a failure when the destination exists.
  This establishes a protocol operation to investigate, not a verified direct-client upload path.

- **W3:** Apple's published [XNU rename dispatch](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/kpi_vfs.c),
  [SMB vnode operations](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_vnops.c)
  and [SMB2 rename](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_smb_2.c),
  reviewed 2026-10-23. Exclusive rename uses a vnode operation absent from the SMB table. Ordinary
  rename can remove an existing destination before sending a protocol rename with replacement
  disabled. These source paths explain the observed behavior; they are not a verified identity
  match to the installed kernel build.
- **W4:** Installed Xcode 27 `Foundation/NSData.h` explicitly disallows combining atomic writes
  and without-overwriting. The published [FileManager move implementation](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/FileManager/FileOperations.swift)
  performs a preflight check followed by ordinary rename. An isolated probe of the installed
  Foundation confirmed that a competing create between these steps can be overwritten on SMB
  and APFS. See the [follow-up results](results/2026-10-23-upload-publication.md#native-api-follow-up).

- **W5:** `libsmb2-6.3` [rename implementation](https://github.com/sahlberg/libsmb2/blob/libsmb2-6.3/lib/libsmb2.c)
  sets `replace_if_exist` to zero. Its [COPYING](https://github.com/sahlberg/libsmb2/blob/libsmb2-6.3/COPYING)
  assigns LGPL-2.1-or-later to the core library and headers. An isolated client with a guest-session
  signing fix passed the [folder rename checks](results/2026-10-23-initial-folder-naming.md).
  Installed Xcode 27 `GSS.framework` headers expose credential iteration and acquisition without
  password export. Metadata probes did not establish reuse of the mounted NAS credentials.

### M19 source review, 2026-10-27

The following sources support the [M19 design](phase4-plan.md#m19-online-editing),
not a runtime claim. SDK inspection and public HTTPS retrieval ran in macOS VM 1. No share
configuration, app installation or remote content changed.

- **W6:** Microsoft's [SMB2 rename structure](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/52aa0b70-8094-4971-862d-79793f41e6a8)
  supplies ReplaceIfExists and a destination name, with no expected destination revision.
  False requires failure if a different file occupies the destination. The
  [FileRenameInformation algorithm](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fsa/87f86c9b-6c2a-4803-84b7-131a74a434fa)
  requires DELETE access on the source open and can reject replacement of a target with an
  existing open. These contracts do not establish a conditional atomic replacement.
- **W7:** Microsoft's [SMB2 CREATE request](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/e8fb45c1-a03d-44ca-b7ae-47385cfd7997)
  defines FILE_SHARE_WRITE and FILE_SHARE_DELETE, including rename under delete sharing, and
  FILE_CREATE's failure when the name exists. Share-mode protection concerns SMB opens;
  enforcement against server-local and other-protocol writers needs separate evidence.
- **W8:** Apple's published [smbfs_vnop_rename](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_vnops.c)
  was retrieved again. Its existing-target branch calls smbfs_remove before smbfs_smb_rename.
  This agrees with the earlier native investigation, without identifying the installed kernel
  as that exact source revision. The vendored libsmb2 raw API exposes rename with replacement
  disabled; the app's approved entry points currently restrict it to M18 folders.
- **W9:** Installed Xcode SDK NSFileProviderReplicatedExtension.h, read in the VM: modifyItem's
  baseVersion describes the last version reflected on disk; filename and contents should sync
  together; callback URLs are unlinked after completion; failOnConflict delegates resolution
  back to the system. Returning nil without error or returning different content can remove
  or replace local data, so preservation must precede conflict acknowledgement. Apple's
  [NSDocument save description](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/AdvancedTopics/AdvancedTopics.html)
  describes temporary-directory and old-revision rename routes in writeSafelyToURL. These
  establish workflows to test, not the actual callback sequence of an editor in this build.

- **W10:** Samba's [share-mode checks](https://github.com/samba-team/samba/blob/master/source3/smbd/open.c),
  reviewed 2026-10-27. share_conflict considers data read/write/append, execution and deletion
  access. WRITE_DAC, WRITE_OWNER, WRITE_ATTRIBUTES and WRITE_EA are outside that mask. Stronger
  share modes therefore do not establish metadata exclusion. The [disposable Samba check](results/2026-10-27-edit-publication.md)
  confirmed concurrent DACL, modification-time and nonempty named-stream changes even with all
  sharing denied. This does not authorize relaxing the accepted preservation requirement.

### M19 Mac-only revision review, 2026-10-27

Public documentation and Samba 4.25.1 source were inspected without opening a writable fixture.
These findings support a proposed experiment, not an implemented or verified save method.

- **W11:** Microsoft's [server-side copy procedure](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/cd0162e4-7650-4293-8a2a-d696923203ef)
  uses source and destination opens in the same session, requires data access, and processes
  chunks sequentially. Failure can leave copied data; it is not atomic publication. Samba's
  [network IOCTL handler](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/smbd/smb2_ioctl_network_fs.c)
  dispatches COPYCHUNK to its offload-write path. Its
  [default implementation](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/modules/vfs_default.c)
  falls back to reads/writes, including for alternate streams. This supports investigating
  main-content updates on a protected, temporarily renamed original, with a verified separate
  backup. It does not establish server compatibility, durability or crash recovery.
- **W12:** A whole-file backup in an attached stream is unsuitable as the general recovery
  format. Samba's [streams_xattr documentation](https://www.samba.org/samba/docs/current/man-html/vfs_streams_xattr.8.html)
  warns of filesystem limits on stream capacity; its default is one xattr per stream.
  [Stream sharing rules](https://learn.microsoft.com/en-us/windows/win32/fileio/file-streams)
  also couple main-file DELETE access to delete sharing on other streams. Samba's
  [open implementation](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/smbd/open.c)
  checks this through open_streams_for_delete. Do not require server reconfiguration or assume
  that a small stream test establishes capacity for ordinary files.
- **W13:** The [SMB2_CREATE_SD_BUFFER context](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/bb8da54a-7d5a-491f-a5a0-04aa2c6cf56f)
  supplies access rules when a new file is created. Unsupported servers can reject or ignore
  them, so successful creation alone cannot prove private staging. Samba's
  [CREATE handler](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/smbd/smb2_create.c)
  decodes this descriptor. The proposed gate must prove restricted access before writing
  content, including after interruption. Permissions identify accounts, not applications;
  they cannot protect temporary files from other programs using the same account.

### Samba folder creation review, 2026-10-31

The [everyday-use review](results/2026-10-31-everyday-use-review.md) reproduced failed directory
creation through the production adapter and native SMB on the disposable Samba 4.25.1 fixture.
The sources below explain a plausible Darwin-specific failure path. A supported configuration
comparison fixes both clients, but no captured server log confirms the exact fallback branch.

- **W14:** Samba 4.25.1's [`mkdir_internal`](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/smbd/open.c)
  creates a temporary directory and publishes it with no-replace rename. Its fallback can create
  the final directory with mode 000 before ordinary rename. The
  [replacement helpers](https://github.com/samba-team/samba/blob/samba-4.25.1/lib/replace/replace.c)
  and [default VFS implementation](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/modules/vfs_default.c)
  establish the Darwin rename route and error handling. Published
  [XNU destination authorization](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/vfs/vfs_subr.c)
  checks permissions before directory replacement. That source release corresponds to macOS 26;
  it is not an exact source match for the VM's macOS 27.0.1 kernel.
- **W15:** Samba documents [`vfs mkdir use tmp name`](https://github.com/samba-team/samba/blob/samba-4.25.1/docs-xml/smbdotconf/vfs/vfsmkdirusetmpname.xml)
  as the switch for temporary-name directory creation. Setting it to `no` creates at the final
  name before final metadata is applied. On the isolated fixture it removed `EACCES` and the
  mode-000 leftovers while retaining the original ACL and stream configuration. The brief
  metadata visibility window is acceptable for this fixture. This is not a production server
  requirement, a transport change or a general compatibility claim.
- **W16:** Samba's [`auth_generic_prepare`](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/auth/auth_generic.c)
  obtains the server DNS name and domain. Both paths call
  [`get_mydnsfullname`](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/lib/util_sock.c),
  which resolves the local hostname and caches only success. Preparation runs during
  [NEGOTIATE](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/smbd/smb2_negprot.c)
  and the first [SESSION_SETUP](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/smbd/smb2_sesssetup.c).
  This explains four repeated hostname lookups before a connection completes. On the fixture,
  lookup failed after five seconds, and packet timing showed two ten-second reply gaps.
  Temporary IPv4 and IPv6 hostname entries removed the lookup wait and reduced complete
  adapter operations to under 0.2 s. This establishes a fixture problem; NAS connection
  latency remains unmeasured.

### SMB close attributes, 2026-11-02

- **W17:** The SMB2 [CLOSE request](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/f84053b0-bcb2-4f85-9717-536dae2b02bd)
  can request attributes with `SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB`. The
  [response](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/c0c15c57-3f3e-452b-b51c-9cc650a13f7b)
  includes creation, modification and change times, size and attributes when that flag is set.
  [Server processing](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/f2b4183a-29c2-4fc0-a5de-fe290408f68c)
  permits a response without attributes when they cannot be fetched. The client must check the
  response flag. These fields do not prove identity or content after a reopen; those still need
  independent verification. A disposable Samba 4.19.5/ext4 probe returned close timestamps that
  matched a reopened handle, while pre-close queries returned earlier values after a flush.

### Native SMB caches, 2026-11-03

- **W18:** Apple's published [`smb_hashget`](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_node.c)
  matches cached nodes by file ID when the server supports them. The native
  [`smbfs_remove`](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_vnops.c)
  removes that entry before deletion, with a comment citing immediate ID reuse by Samba and
  NetApp. A failed delete reinserts it. A direct SMB mutation does not execute this native
  vnode operation. These public sources explain the isolated wrong-path metadata probe;
  they are not a verified match to the installed macOS kernel. The
  [November 3 results](results/2026-11-02-samba-names-and-uploads.md#native-cache-investigation-2026-11-03)
  separate runtime observations from source-based interpretation.

### Samba hidden attributes during save, 2026-11-03

Samba 4.19.5 derives hidden status from dot-prefixed names in
[`dos_mode_from_name`](https://github.com/samba-team/samba/blob/samba-4.19.5/source3/smbd/dosmode.c).
Its [rename implementation](https://github.com/samba-team/samba/blob/samba-4.19.5/source3/smbd/smb2_reply.c)
reads attributes after changing the handle's name, then writes them with the archive flag.
[`fileio.c`](https://github.com/samba-team/samba/blob/samba-4.19.5/source3/smbd/fileio.c)
also sets archive status on writes. This can persist name-derived hidden status on an existing
file. A rename-only disposable-fixture control reproduces the effect. Removing the leading
dot from the work name avoids it without rewriting user metadata. Private-stage conflict
publication does not retain hidden status in the tested configuration. See the
[folder/save results](results/2026-11-03-folder-organization.md#save-work-name-and-hidden-attributes).

### Finder replacement callbacks, 2026-11-03

The installed Xcode 27 `NSFileProviderReplicatedExtension.h` exposes only `recursive` for
deletion options. Its reimport flag, `mayAlreadyExist`, is not replacement authorization.
`NSFileProviderRequest.h` explicitly excludes create/modify/delete from the valid uses of
`isSystemRequest` and `isFileViewerRequest`. The request's domain version identifies when the
system observed an event, not its purpose. These headers were read on 2026-11-03. The signed
[Finder observation](results/2026-11-03-editor-replacement.md) sent separate delete/create
callbacks for Replace; no supported intent/base binding was found in the reviewed interfaces.

## Research limitations

Live web documentation and current SDK headers establish API contracts, not actual throughput. Search was unreliable, and several sites initially failed the VM's DNS resolution; direct HTTPS retrieval with explicitly resolved public addresses succeeded. No VM DNS settings were changed. Subsequent work measured native SMB and short NAS-backed provider reads and ran signed correctness checks; dated results logs record those separately. Competitor installations, the player matrix, large-file throughput acceptance, and controlled failure experiments remain incomplete, as described in the benchmark plan.
