import AppKit
import FileProvider
import SwiftUI

@main
struct TinyMounterPrototypeApp: App {
    @StateObject private var model = PrototypeModel()

    var body: some Scene {
        WindowGroup("tinymounter · Performance Prototype") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Test a file from your NAS").font(.title2.bold())
                Text("Choose one unchanged test file from a mounted SMB share, or a local file for setup. It appears in a separate, read-only Finder location.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Choose Test File…", action: model.chooseFile).disabled(model.busy)
                    Button("Refresh List", action: model.reload)
                    if model.busy { ProgressView().controlSize(.small) }
                }
                Divider()
                if model.domains.isEmpty {
                    Text("No test locations registered.").foregroundStyle(.secondary)
                }
                ForEach(model.domains, id: \.identifier.rawValue) { domain in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(domain.displayName).font(.headline)
                        HStack {
                            Button("Open in Finder") { model.reveal(domain) }
                            Button("Keep Downloaded") { model.setPinned(true, domain: domain) }
                            Button("Allow Removal") { model.setPinned(false, domain: domain) }
                            Button("Remove Test Location") { model.remove(domain) }
                        }.disabled(model.busy)
                    }
                }
                Text(model.status).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
                Text("Keep Downloaded schedules a full download. Check completion in Finder before testing offline access. This prototype does not upload edits or discover remote changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(minWidth: 670, minHeight: 340)
            .onAppear { model.reload() }
        }
    }
}

@MainActor
final class PrototypeModel: ObservableObject {
    @Published var domains: [NSFileProviderDomain] = []
    @Published var status = ""
    @Published var busy = false

    func reload() {
        NSFileProviderManager.getDomainsWithCompletionHandler { [weak self] domains, error in
            Task { @MainActor in
                self?.domains = domains.sorted { $0.displayName < $1.displayName }
                if let error { self?.status = error.localizedDescription }
            }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = "Choose an immutable test file. tinymounter will only read the source."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        status = "Reading test-file metadata…"
        // A disconnected SMB mount can block POSIX calls; never run those on the UI thread.
        Task {
            do {
                let config = try await Task.detached {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let file = try ReadOnlyFile(url: url)
                    let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil, relativeTo: nil)
                    let config = FixtureConfiguration(domainID: UUID().uuidString,
                        filename: url.lastPathComponent, bookmark: bookmark, snapshot: file.snapshot)
                    try config.save()
                    return config
                }.value
                let domain = NSFileProviderDomain(identifier: .init(config.domainID),
                    displayName: "tinymounter Test \(config.domainID.prefix(6))")
                do {
                    try await NSFileProviderManager.add(domain)
                } catch {
                    try? FileManager.default.removeItem(at: FixtureConfiguration.url(for: config.domainID))
                    throw error
                }
                busy = false
                status = "Test location registered. Open it in Finder to start reading."
                reload()
            } catch {
                busy = false
                status = error.localizedDescription
            }
        }
    }

    func reveal(_ domain: NSFileProviderDomain) {
        NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer) { [weak self] url, error in
            Task { @MainActor in
                if let url { NSWorkspace.shared.open(url) }
                else { self?.status = error?.localizedDescription ?? "Finder location unavailable." }
            }
        }
    }

    func setPinned(_ pinned: Bool, domain: NSFileProviderDomain) {
        do {
            var config = try FixtureConfiguration.load(domainID: domain.identifier.rawValue)
            guard config.generation < UInt64.max else { throw CocoaError(.fileWriteUnknown) }
            config.keepDownloaded = pinned
            config.generation += 1
            try config.save()
            guard let manager = NSFileProviderManager(for: domain) else { throw CocoaError(.fileReadUnknown) }
            manager.signalEnumerator(for: .workingSet) { [weak self] error in
                Task { @MainActor in
                    self?.status = error?.localizedDescription ?? (pinned
                        ? "Keep Downloaded requested. Wait for Finder to finish downloading before going offline."
                        : "Automatic download removal is allowed. Finder’s Remove Download can reset this test file.")
                }
            }
        } catch { status = error.localizedDescription }
    }

    func remove(_ domain: NSFileProviderDomain) {
        busy = true
        let domainID = domain.identifier.rawValue
        NSFileProviderManager.remove(domain, mode: .preserveDownloadedUserData) { [weak self] preserved, error in
            if error == nil { try? FileManager.default.removeItem(at: FixtureConfiguration.url(for: domainID)) }
            Task { @MainActor in
                self?.busy = false
                self?.status = error?.localizedDescription ?? preserved.map { "Downloaded files preserved at \($0.path)" } ?? "Test location removed."
                self?.reload()
            }
        }
    }
}
