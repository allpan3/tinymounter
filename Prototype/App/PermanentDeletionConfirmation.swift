import AppKit

// A nested modal loop would block main-actor cancellation and recovery while Finder waits.
@MainActor
final class PermanentDeletionConfirmation: NSObject {
    private let alert: NSAlert
    private let progress: Progress
    private var completion: ((Bool) -> Void)?
    private var cancellation: NSKeyValueObservation?
    private var escapeMonitor: Any?
    private var isPresented = false

    init(_ selection: PermanentDeletionSelection, progress: Progress, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(selection.name)” permanently?"
        alert.informativeText = selection.isFolder
            ? "This removes the folder and its contents from the server for everyone. It does not move them to the Trash and cannot be undone."
            : "This removes the file from the server for everyone. It does not move it to the Trash and cannot be undone."
        alert.addButton(withTitle: UIText.cancel)
        alert.addButton(withTitle: "Delete Permanently").hasDestructiveAction = true
        self.alert = alert
        self.progress = progress
        self.completion = completion
        super.init()
        for (index, button) in alert.buttons.enumerated() {
            button.keyEquivalent = index == 0 ? "\r" : ""
        }
        cancellation = progress.observe(\.isCancelled, options: [.initial, .new]) { [weak self] progress, _ in
            if progress.isCancelled { Task { @MainActor in self?.finish(false) } }
        }
    }

    func show(in parent: NSWindow?) {
        guard completion != nil, !isPresented, let parent else { return }
        guard !progress.isCancelled else { finish(false); return }
        guard parent.attachedSheet == nil else { finish(false); return }
        isPresented = true
        // Return owns Cancel's key equivalent, so handle Escape only in this sheet.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.alert.window else { return event }
            self.finish(false)
            return nil
        }
        NSApp.activate()
        parent.deminiaturize(nil)
        parent.makeKeyAndOrderFront(nil)
        // An active Settings field editor can consume the sheet's first Escape.
        guard parent.makeFirstResponder(nil) else { finish(false); return }
        alert.beginSheetModal(for: parent) { [weak self] response in
            self?.finish(response == .alertSecondButtonReturn)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, _ in
            Task { @MainActor in
                guard self?.completion != nil else { return }
                self?.alert.window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func finish(_ confirmed: Bool) {
        guard let completion else { return }
        self.completion = nil
        cancellation?.invalidate()
        cancellation = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
        alert.window.orderOut(nil)
        completion(confirmed && !progress.isCancelled)
    }
}
