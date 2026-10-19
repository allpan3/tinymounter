import Darwin
import Foundation

final class DirectoryWatch: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    init(descriptor: Int32, changed: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) {
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            changed(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        source.activate()
    }

    deinit { source.cancel() }
}
