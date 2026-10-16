import AppKit
import FileProvider
import OSLog
import SwiftUI

/// A test harness for M4 and M5, not the phase 2 UI.
@main
struct TinyMounterPrototypeApp: App {
    @StateObject private var model = PrototypeModel()

    var body: some Scene {
        WindowGroup("tinymounter · Prototype") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Locations").font(.title2.bold())
                Text("A location shows a folder of a share in Finder. tinymounter only reads the files on the server.")
                    .foregroundStyle(.secondary)
                if let problem = model.problem { Text(problem).foregroundStyle(.red) }
                if model.locations.isEmpty {
                    Text("No locations.").foregroundStyle(.secondary)
                }
                ForEach(model.locations, id: \.id) { record in
                    HStack {
                        Text(record.name).font(.headline)
                        if record.removing { Text("The removal is not complete.").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Show in Finder") { model.reveal(record) }.disabled(record.removing)
                        Button("Remove Location") { model.remove(record) }
                    }.disabled(model.busy || !model.ready)
                }
                Divider()
                Text("Add a location").font(.headline)
                Text("Select the share that you connected in Finder. Type a folder in the share and a name. Then click Add Location.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Select Share…", action: model.selectShare)
                    Text("Folder")
                    TextField("Folder", text: $model.folderText, prompt: Text("Full share"))
                        .labelsHidden().frame(maxWidth: 260)
                    Button("Check Location", action: model.checkLocation).disabled(model.grantID == nil || !model.ready)
                    if model.shareBusy { ProgressView().controlSize(.small) }
                }.disabled(model.shareBusy)
                HStack {
                    Text("Name")
                    TextField("Name", text: $model.nameText, prompt: Text(model.defaultName))
                        .labelsHidden().frame(maxWidth: 260)
                    Button("Add Location", action: model.addLocation)
                        .disabled(model.grantID == nil || model.busy || !model.ready)
                    if model.busy { ProgressView().controlSize(.small) }
                }.disabled(model.shareBusy)
                Text(model.shareStatus).font(.callout).textSelection(.enabled)
                Text(model.status).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
                Text("Keep this app open. When it is not open, Finder cannot download files, and it shows only the folders that it showed before.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(minWidth: 670, minHeight: 460)
        }
    }
}

@MainActor
final class PrototypeModel: ObservableObject {
    @Published private(set) var locations: [LocationRecord] = []
    @Published private(set) var problem: String?
    @Published private(set) var grantID: UUID?
    @Published private(set) var ready = false
    @Published var status = ""
    @Published var busy = false
    @Published var folderText = ""
    @Published var nameText = ""
    @Published var shareStatus = ""
    @Published var shareBusy = false
    private let store = SettingsStore()
    private let controller: LocationController
    private static let listingLog = Logger(subsystem: "dev.tinymounter.prototype", category: "listing")

    init() {
        controller = LocationController(store: store)
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onReaderStatus = { [weak self] message in self?.status = message }
        switch store.state {
        case .ready(let settings): grantID = settings.servers.last?.id
        case .unreadable: shareStatus = "tinymounter cannot read its settings file. You cannot add a location."
        }
        refresh()
        Task { await controller.launch() }
    }

    /// The last folder name, or the share's name for the full share.
    var defaultName: String {
        if let folder = LocationRecord.normalizedFolder(folderText),
           let last = folder.string.utf8.split(separator: UInt8(ascii: "/")).last {
            return String(decoding: last, as: UTF8.self)
        }
        return store.settings?.servers.first { $0.id == grantID }?.share ?? ""
    }

    func reveal(_ record: LocationRecord) {
        guard let manager = controller.manager(for: record) else {
            status = "Finder cannot show this location."
            return
        }
        Task {
            do {
                let url = try await manager.getUserVisibleURL(for: .rootContainer)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if !NSWorkspace.shared.open(url) { status = "Finder cannot show this location." }
            } catch {
                status = "Finder cannot show this location (\(logFields(error)))."
            }
        }
    }

    func remove(_ record: LocationRecord) {
        busy = true
        status = ""
        Task {
            defer { busy = false; refresh() }
            do {
                try await controller.remove(record.id)
                status = "The location is removed."
            } catch {
                status = Self.message(for: error)
            }
        }
    }

    func addLocation() {
        guard let grantID else { return }
        guard let folder = LocationRecord.normalizedFolder(folderText) else {
            status = "This folder path is not correct. Type a path in the share."
            return
        }
        let typed = nameText.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? defaultName : typed
        guard RelativePath.isValidComponent(name) else {
            status = "This name is not correct. Type a different name."
            return
        }
        busy = true
        status = ""
        Task {
            defer { busy = false; refresh() }
            do {
                try await controller.add(name: name, folder: folder, grantID: grantID)
                nameText = ""
                status = "The location is added. Click Show in Finder."
            } catch {
                status = Self.message(for: error)
            }
        }
    }

    func selectShare() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Volumes", directoryHint: .isDirectory)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // The share is read-only to tinymounter, and the panel could make a folder on it.
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = "Select the share that you connected in Finder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        shareBusy = true
        shareStatus = ""
        Task {
            defer { shareBusy = false }
            do {
                grantID = try controller.saveGrant(try await ShareAccess.makeGrant(for: url))
                shareStatus = "tinymounter can read this share. Click Check Location or Add Location."
            } catch {
                shareStatus = Self.message(for: error)
            }
        }
    }

    func checkLocation() {
        guard let grantID, let access = controller.share(forGrantID: grantID) else { return }
        guard let folder = LocationRecord.normalizedFolder(folderText) else {
            shareStatus = "This folder path is not correct. Type a path in the share."
            return
        }
        shareBusy = true
        shareStatus = ""
        let checkID = UUID().uuidString
        let started = ContinuousClock.now
        Task {
            defer { shareBusy = false }
            do {
                let check = try await access.perform { session, progressed in
                    try LocationCheck.run(session, folder: folder, resolutions: access.resolutions, progress: progressed)
                }
                let totalMs = started.duration(to: .now) / .milliseconds(1)
                for (index, listed) in check.folders.enumerated() {
                    Self.listingLog.info("""
                        check_location check=\(checkID, privacy: .public) folder=\(index) entries=\(listed.entries) \
                        files=\(listed.files) folders=\(listed.folders) \
                        other=\(listed.entries - listed.files - listed.folders) \
                        list_ms=\(listed.milliseconds, format: .fixed(precision: 1))
                        """)
                }
                Self.listingLog.info("""
                    check_location check=\(checkID, privacy: .public) share=\(access.grantID.uuidString, privacy: .public) \
                    listed=\(check.folders.count) file_depth=\(check.fileDepth) \
                    file_open_ms=\(check.fileMilliseconds, format: .fixed(precision: 1)) \
                    fingerprint_match=\(check.fingerprintMatches ? 1 : 0) \
                    total_ms=\(totalMs, format: .fixed(precision: 1)) \
                    resolutions=\(check.resolutions) stale=\(check.stale ? 1 : 0)
                    """)
                shareStatus = check.summary
            } catch {
                Self.listingLog.error("""
                    check_location check=\(checkID, privacy: .public) share=\(access.grantID.uuidString, privacy: .public) \
                    failed \(logFields(error), privacy: .public) resolutions=\(access.resolutions)
                    """)
                shareStatus = Self.message(for: error)
            }
        }
    }

    private func refresh() {
        locations = store.settings?.locations ?? []
        problem = controller.problem
        ready = controller.isReady
    }

    private static func message(for error: Error) -> String {
        if let refusal = error as? ShareGrantError {
            switch refusal {
            case .notVolumeRoot: return "This folder is not a share. Select the share that you connected in Finder."
            case .notSMBShare: return "This volume is not an SMB share. Select the share that you connected in Finder."
            case .addressRejected: return "tinymounter cannot use the address of this share."
            }
        }
        switch error as? SourceFailure {
        case .notConnected?: return "Connect to the share with Connect to Server in Finder."
        case .notAuthenticated?: return "Select the share again."
        case .serverUnreachable?: return "tinymounter cannot connect to the server. Make sure that the server is on."
        case .missing?: return "This folder is not on the share."
        default: return "tinymounter cannot do this (\(logFields(error)))."
        }
    }
}

/// Counts from one Check Location run on the share's lane. It holds no names.
struct LocationCheck: Sendable {
    struct Folder: Sendable {
        /// Every entry, as `ls -A` counts them.
        let entries: Int
        let files: Int
        let folders: Int
        let milliseconds: Double
    }

    /// The location folder, then up to 3 of its child folders in name-byte order.
    private(set) var folders: [Folder] = []
    /// Components from the share root; 0 if no file at depth 2 or more was listed.
    private(set) var fileDepth = 0
    private(set) var fileMilliseconds = 0.0
    /// The opened file's `fstat` gives the size, mtime and ctime that its listing gave.
    private(set) var fingerprintMatches = false
    let resolutions: Int
    let stale: Bool

    static func run(_ session: ShareSession, folder: RelativePath, resolutions: Int,
                    progress: Progressed) throws -> LocationCheck {
        var check = LocationCheck(resolutions: resolutions, stale: session.stale)
        let fd = try session.openFolder(folder)
        defer { close(fd) }
        progress()
        let top = try check.list(fd, .root, session, progress)
        var children: [(RelativePath, DirectoryListing)] = []
        for entry in top.entries where entry.kind == .folder && children.count < 3 {
            guard let path = RelativePath.root.appending(entry.name) else { continue }
            children.append((path, try check.list(fd, path, session, progress)))
        }
        let depth = folder.isRoot ? 0 : folder.string.utf8.split(separator: UInt8(ascii: "/")).count
        var target: (path: RelativePath, entry: DirectoryListing.Entry, depth: Int)?
        for (path, listing) in children {
            if let file = listing.entries.first(where: { $0.kind == .file }), let filePath = path.appending(file.name) {
                target = (filePath, file, depth + 2)
                break
            }
        }
        if target == nil, depth >= 1, let file = top.entries.first(where: { $0.kind == .file }),
           let filePath = RelativePath.root.appending(file.name) {
            target = (filePath, file, depth + 1)
        }
        guard let target else { return check }
        let started = ContinuousClock.now
        let file = try ReadOnlyFile(directoryFD: fd, relativePath: target.path, expected: session.identity)
        progress()
        check.fileMilliseconds = started.duration(to: .now) / .milliseconds(1)
        check.fileDepth = target.depth
        check.fingerprintMatches = file.snapshot.fingerprint == ContentFingerprint(
            size: target.entry.size, mtimeNs: target.entry.mtimeNs, ctimeNs: target.entry.ctimeNs)
        return check
    }

    private mutating func list(_ fd: Int32, _ path: RelativePath, _ session: ShareSession,
                               _ progress: Progressed) throws -> DirectoryListing {
        let started = ContinuousClock.now
        let listing = try DirectoryListing.list(locationRoot: fd, relativePath: path, expected: session.identity,
                                                progress: progress)
        progress()
        let skipped = listing.skipped
        folders.append(Folder(
            entries: listing.entries.count + listing.unreadable.count + listing.collisionLosers.count
                + skipped.otherKinds + skipped.invalidNames,
            files: listing.entries.count { $0.kind == .file },
            folders: listing.entries.count { $0.kind == .folder },
            milliseconds: started.duration(to: .now) / .milliseconds(1)))
        return listing
    }

    var summary: String {
        var lines = folders.enumerated().map { index, folder in
            let title = index == 0 ? "Folder" : "Folder \(index) in this folder"
            return "\(title): \(folder.entries) items, \(folder.folders) folders, \(folder.files) files."
        }
        lines.append(fileDepth > 0 ? "File opened at depth \(fileDepth)." : "No file at depth 2 or more.")
        lines.append("Times that tinymounter opened access to the share: \(resolutions).")
        return lines.joined(separator: "\n")
    }
}
