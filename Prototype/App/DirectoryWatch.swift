import Darwin
import Foundation

final class DirectoryWatch: @unchecked Sendable {
    /// From the share root, so a folder move can find every watch below it.
    let path: RelativePath
    private let source: DispatchSourceFileSystemObject
    private let closed = DispatchSemaphore(value: 0)

    init(descriptor: Int32, path: RelativePath, changed: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) {
        self.path = path
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            changed(source.data)
        }
        source.setCancelHandler { [closed] in
            close(descriptor)
            closed.signal()
        }
        source.activate()
    }

    func cancel() { source.cancel() }

    /// True once the cancel handler closed the descriptor. Call once, after `cancel`.
    func waitClosed(until deadline: DispatchTime) -> Bool { closed.wait(timeout: deadline) == .success }

    deinit { source.cancel() }
}
