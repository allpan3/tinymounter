import Darwin
import Foundation

/// On smbfs `mountFrom` holds the account, so never log it.
public struct MountIdentity: Hashable, Sendable {
    public let typeName: String
    public let fsid: UInt64
    public let mountFrom: String

    public init(typeName: String, fsid: UInt64, mountFrom: String) {
        self.typeName = typeName
        self.fsid = fsid
        self.mountFrom = typeName == "smbfs" ? ShareAddress.withoutEmptyPassword(mountFrom) ?? mountFrom : mountFrom
    }

    public init(_ info: statfs) {
        self.init(typeName: Self.string(info.f_fstypename),
                  fsid: UInt64(UInt32(bitPattern: info.f_fsid.val.0)) | UInt64(UInt32(bitPattern: info.f_fsid.val.1)) << 32,
                  mountFrom: Self.string(info.f_mntfromname))
    }

    public init(descriptor: Int32) throws {
        var info = statfs()
        while fstatfs(descriptor, &info) != 0 {
            guard errno == EINTR else { throw posixError("fstatfs") }
        }
        self.init(info)
    }

    public func requireMounted(_ root: Int32) throws {
        // fstatfs fails on a dead descriptor (ENOTSUP), so any failure means the mount is gone.
        guard (try? MountIdentity(descriptor: root)) == self else { throw SourceFailure.notConnected }
    }

    public func guarding<Result>(root: Int32, _ body: () throws -> Result) throws -> Result {
        do {
            return try body()
        } catch {
            // A dead descriptor gives ENOTDIR, EIO or EBADF, which look like other failures.
            try requireMounted(root)
            throw error
        }
    }

    func requireSameMount(_ descriptor: Int32, root: Int32) throws {
        guard try MountIdentity(descriptor: descriptor) != self else { return }
        try requireMounted(root)
        // O_RESOLVE_BENEATH crosses mount points, so a volume mounted inside the share opens too.
        throw SourceFailure.pathRejected
    }

    private static func string<Field>(_ field: Field) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension ReadOnlyFile {
    /// Opens a regular file beneath `locationRoot`: a symlink gives ELOOP, an escape ENOTCAPABLE.
    public convenience init(directoryFD locationRoot: Int32, relativePath: RelativePath, expected: MountIdentity,
                            noCache: Bool = false) throws {
        do {
            try self.init(directoryFD: locationRoot, path: relativePath.string, noCache: noCache)
            try expected.requireSameMount(descriptor, root: locationRoot)
        } catch {
            try expected.requireMounted(locationRoot)
            throw error
        }
    }
}
