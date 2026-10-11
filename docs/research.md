# Research notes and sources

Reviewed 2026-10-10. These notes distinguish documented behavior, user observations, and engineering hypotheses. No competitor was installed or benchmarked and no NAS was mounted during this research.

## Findings

**Integrated mode is a synchronization filesystem interface.** A native SMB read goes through Apple's network filesystem client. File Provider instead exposes local APFS objects, asks an extension to fetch missing content, and serves materialized bytes locally. There is extra scheduling and local writing on a miss, but cached reads can be faster than the network. It is not merely the same SMB mount with an icon [A1–A3].

**There is a documented streaming mechanism.** `NSFileProviderPartialContentFetching` is available from macOS 12.3. Apple explicitly gives video streaming as an example. However, its documentation says: “To trigger a partial download, an app must use POSIX read operations to read part of the file. If you clone the entire file, or read the file using file coordination, the system requests the entire file.” This makes application behavior a first-class benchmark variable [A1].

**The byte handoff can avoid another full physical copy.** The SDK requires a same-volume regular staging file with bytes at the reported offsets, and states that the system clones and unlinks that file. The provider cannot mutate it after callback completion. The API permits a larger aligned extent than the requested minimum and specifies strict versioning. It also exposes `NSExtensionFileProviderDownloadPipelineDepth` (1–128 per domain); that setting is not itself a guarantee of efficient per-file SMB pipelining [A2].

**No reviewed source establishes a 10–20 MB/s or 80 MB/s File Provider ceiling.** A suitable implementation might approach native throughput, subject to local disk, CPU, request scheduling, API behavior, and application reads. A throughput guarantee requires measurement. Serial small reads, mismatched security settings, slow metadata work, copying, or whole-file hydration are plausible explanations, not proven diagnoses.

**Offline availability needs a retention policy.** A partially read video is not a complete offline file. Ordinary downloaded content may be evicted. A keep-downloaded content policy exists; macOS 27 also adds eager namespace materialization, important for unvisited subfolders of a pinned tree [A4].

**The user environment is specific enough to start a spike.** The user reports macOS 27 and a UGREEN NAS running Debian. The development VM is `macOS VM 1`, macOS 27.0.1 build 26A434, with Xcode 27.0 build 27A266a. VMPal reported `adminExecutionAvailable: true`. The workspace was empty. VM throughput cannot be assumed to match the physical Mac.

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

## Alternative approaches

- **Replicated File Provider:** strongest fit for iCloud-like integration with Finder and other file managers and local offline files. Selected, subject to measured performance/player behavior.
- **Native SMB alone:** best performance reference and later automount mode. Does not fulfill durable offline caching.
- **Native SMB behind File Provider:** valuable controlled experiment and possible production transport. Requires staging plus validated sandbox, mount ownership, cancellation, and helper behavior.
- **Direct async SMB behind File Provider:** removes an internal mount and offers explicit range/scheduling control. Requires proving transport performance, feature compatibility, and licensing.
- **FSKit / macFUSE custom filesystem:** greater filesystem control but requires designing cache, consistency, offline state, and file-manager integration. FSKit is a current public user-space filesystem framework and mentions network resources [F1]; dismissing it as categorically unable to handle a network resource would be incorrect. It is not a ready-made cloud-sync/offline system and is not the first architecture to implement here.
- **WebDAV/localhost relay over SMB:** unnecessary extra server/protocol in the critical path for an SMB-only first release.
- **Server-side companion service:** could eventually provide immutable versions/change journals/conditional writes, but violates the simple bring-your-own-SMB starting point. Keep optional and later.

## Source register

### Apple File Provider

- **A1:** [NSFileProviderPartialContentFetching](https://developer.apple.com/documentation/fileprovider/nsfileproviderpartialcontentfetching) — availability, POSIX limitation, video example. Read the official DocC payload at `https://developer.apple.com/tutorials/data/documentation/fileprovider/nsfileproviderpartialcontentfetching.json`.
- **A2:** [fetchPartialContents](https://developer.apple.com/documentation/fileprovider/nsfileproviderpartialcontentfetching/fetchpartialcontents(for:version:request:minimalrange:aligningto:options:completionhandler:)) and installed Xcode 27 SDK headers: `FileProvider.framework/Headers/NSFileProviderReplicatedExtension.h`, `NSFileProviderDefines.h`, `NSFileProviderItem.h`, `NSFileProviderManager.h`. Local headers supplied the detailed same-volume layout, handoff, alignment, cancellation, strict-version, and pipeline-depth contracts.
- **A3:** [WWDC21: Sync files to the cloud with FileProvider on macOS](https://developer.apple.com/videos/play/wwdc2021/10182/) — official transcript read; APFS materialization, subsequent local reads, uploads, eviction, working set, sync anchors. This older talk predates the partial-content API; use A1/A2 for current range support.
- **A4:** [NSFileProviderContentPolicy](https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy), [NSFileProviderNamespacePolicy](https://developer.apple.com/documentation/fileprovider/nsfileprovidernamespacepolicy) — content-policy documentation plus installed SDK header definitions; namespace API availability in the SDK is macOS 27.0. `downloadEagerlyAndKeepDownloaded` prevents disk-pressure eviction; `materializeEagerly` controls eager folder enumeration.
- **A5:** [Synchronizing files using file provider extensions](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions) — official sample documentation read; App Groups/team setup, domains, enumeration, change anchors, domain removal, target organization. Useful starting reference, not a production SMB sync engine.

### Vendors and SMB implementations

- **M1:** [Mountain Duck connect-mode comparison](https://docs.mountainduck.io/mountainduck/connect/), [Integrated mode](https://docs.mountainduck.io/mountainduck/connect/integrated/), [product/download page](https://mountainduck.io/).
- **M2:** [Cyberduck/Mountain Duck SMB documentation](https://docs.mountainduck.io/protocols/smb/) — supported SMB use, authentication, signing/encryption defaults.
- **M3:** [Cyberduck SMBSession source](https://github.com/iterate-ch/cyberduck/blob/master/smb/src/main/java/ch/cyberduck/core/smb/SMBSession.java) — live master inspected on the research date; related open-source client configuration, not a pinned version of Mountain Duck.
- **D1:** [Driio product](https://driio.app/), [documentation](https://driio.app/docs), [App Store](https://apps.apple.com/us/app/driio/id6757922119).
- **D2:** [Driio changelog](https://driio.app/changelog) — especially 2.4, 2.7, and 2.7.4. Vendor-reported behavior and fixes.
- **L1:** [libsmb2](https://github.com/sahlberg/libsmb2) — live README reviewed; recommended async API, SMB2/3 support, signing/encryption, LGPL-2.1. Performance descriptions are project claims until measured.
- **L2:** [AMSMB2](https://github.com/amosavian/AMSMB2) — Swift wrapper README reviewed; includes a dependency/linkage licensing warning. Shipping legal/distribution review is still required.

### Mount management and alternatives

- **N1:** [AutoMounter](https://www.pixeleyes.co.nz/automounter/) — product features and packaging; installed SDK `NetFS.framework/Headers/NetFS.h` — `NetFSMountURLAsync`, mount flags, request cancellation.
- **N2:** [Apple: Configure SMB Multichannel behavior](https://support.apple.com/en-us/102010) — default support from macOS 11.3, redundancy, interface preference and limitations. No system configuration changes made.
- **N3:** [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) — official API descriptions read; network observations and per-user helper registration.
- **F1:** [FSKit](https://developer.apple.com/documentation/fskit) — official framework overview read; user-space filesystem modules, resources, and current design flows.

## Research limitations

Live web documentation and current SDK headers establish API contracts, not actual throughput. Search was unreliable, and several sites initially failed the VM's DNS resolution; direct HTTPS retrieval with explicitly resolved public addresses succeeded. No VM DNS settings were changed. The app installations, NAS security/settings inspection, player matrix, and controlled performance experiments remain future work, described in the benchmark plan.
