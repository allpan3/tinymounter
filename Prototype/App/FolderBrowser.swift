import SwiftUI

/// What Select… opened: the folders of one share, for one location or draft.
struct FolderBrowserRequest: Identifiable {
    let id = UUID()
    let entryID: UUID
    let share: String
    let start: RelativePath
    /// The names of the subfolders of a folder in the share.
    let folderNames: (RelativePath) async throws -> [String]
}

/// Connection-layer plan decision 3: lists a share's folders one level at a time, in the app.
struct FolderBrowser: View {
    let request: FolderBrowserRequest
    let choose: (RelativePath) -> Void
    let cancel: () -> Void

    @State private var path: RelativePath
    @State private var names: [String] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var failed = false

    init(request: FolderBrowserRequest, choose: @escaping (RelativePath) -> Void, cancel: @escaping () -> Void) {
        self.request = request
        self.choose = choose
        self.cancel = cancel
        _path = State(initialValue: request.start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(UIText.selectFolderTitle(request.share)).font(.headline)
            HStack {
                Button { open(parent) } label: { Image(systemName: "chevron.left") }
                    .disabled(path.isRoot)
                    .help(UIText.enclosingFolder)
                    .accessibilityLabel(UIText.enclosingFolder)
                Text(([request.share] + path.components).joined(separator: " › "))
                    .lineLimit(1).truncationMode(.head)
            }
            List(names, id: \.self, selection: $selection) { name in
                Label(name, systemImage: "folder")
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { selected in
                if let name = selected.first, let folder = path.appending(name) { open(folder) }
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if failed {
                    Text(UIText.cannotListFolders).foregroundStyle(.secondary)
                } else if names.isEmpty {
                    Text(UIText.noFolders).foregroundStyle(.secondary)
                }
            }
            .frame(height: 280)
            Text(UIText.folderBrowserHint).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(UIText.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(UIText.choose) { choose(selected) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(id: path) { await load() }
    }

    /// As in an Open panel: the selected folder, else the folder that the list shows.
    private var selected: RelativePath {
        selection.flatMap { path.appending($0) } ?? path
    }

    private var parent: RelativePath {
        RelativePath(path.components.dropLast().joined(separator: "/")) ?? .root
    }

    private func open(_ folder: RelativePath) {
        selection = nil
        path = folder
    }

    private func load() async {
        loading = true
        failed = false
        names = []
        do {
            let listed = try await request.folderNames(path)
            guard !Task.isCancelled else { return }
            // As in Finder and the Open panel, hidden folders don't show. The Folder field takes them.
            names = listed.filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
        loading = false
    }
}
