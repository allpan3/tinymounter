import AppKit

// A nested modal loop would block main-actor cancellation and recovery while Finder waits.
@MainActor
final class PermanentDeletionConfirmation: NSWindowController, NSWindowDelegate {
    private let alert: NSAlert
    private let progress: Progress
    private var completion: ((Bool) -> Void)?
    private var cancellation: NSKeyValueObservation?

    init(_ selection: PermanentDeletionSelection, progress: Progress, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(selection.name)” permanently?"
        alert.informativeText = selection.isFolder
            ? "This removes the folder and its contents from the server for everyone. It does not move them to the Trash and cannot be undone."
            : "This removes the file from the server for everyone. It does not move it to the Trash and cannot be undone."
        alert.addButton(withTitle: UIText.cancel)
        alert.addButton(withTitle: "Delete Permanently").hasDestructiveAction = true
        alert.layout()
        self.alert = alert
        self.progress = progress
        self.completion = completion
        super.init(window: alert.window)
        alert.window.delegate = self
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(respond(_:))
            button.keyEquivalent = index == 0 ? "\r" : ""
        }
        cancellation = progress.observe(\.isCancelled, options: [.initial, .new]) { [weak self] progress, _ in
            if progress.isCancelled { Task { @MainActor in self?.finish(false) } }
        }
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard !progress.isCancelled else { finish(false); return }
        NSApp.activate()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func respond(_ sender: NSButton) { finish(sender.tag == 1) }
    override func cancelOperation(_ sender: Any?) { finish(false) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(false); return false }

    private func finish(_ confirmed: Bool) {
        guard let completion else { return }
        self.completion = nil
        cancellation?.invalidate()
        cancellation = nil
        window?.orderOut(nil)
        completion(confirmed && !progress.isCancelled)
    }
}
