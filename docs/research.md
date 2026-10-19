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

PolyDrive uses File Provider for cloud/server connectors, but explicitly excludes SMB: its home page says “SMB shares are the one exception: those are mounted as volumes by macOS's own SMB client” [PD1]. Its support page documents mounting at login and remounting after network loss; the app must remain running for that management [PD2]. It therefore covers part of the proposed server volume mode, but its documented SMB path does not supply the persistent offline SMB replica that motivates tinymounter. Do not transfer its cloud-drive pinning claims to native SMB shares.

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

## Research limitations

Live web documentation and current SDK headers establish API contracts, not actual throughput. Search was unreliable, and several sites initially failed the VM's DNS resolution; direct HTTPS retrieval with explicitly resolved public addresses succeeded. No VM DNS settings were changed. Subsequent work measured native SMB and short NAS-backed provider reads and ran signed correctness checks; dated results logs record those separately. Competitor installations, the player matrix, large-file throughput acceptance, and controlled failure experiments remain incomplete, as described in the benchmark plan.
