import Darwin
import Foundation

final class DirectoryWatch: @unchecked Sendable {
    /// From the share root, so a folder move can find every watch below it.
    let path: RelativePath
    private let source: DispatchSourceFileSystemObject

    init(descriptor: Int32, path: RelativePath,
         changed: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void,
         closed: @escaping @Sendable () -> Void) {
        self.path = path
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            changed(source.data)
        }
        source.setCancelHandler {
            close(descriptor)
            closed()
        }
        source.activate()
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}
