import Darwin
import Foundation

public enum Staging {
    private static let prefix = "tinymounter-"
    private static let suffix = ".stage"

    static func stageFileName(_ id: UUID) -> String { prefix + id.uuidString + suffix }

    public static func isStageFileName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              let id = UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) else {
            return false
        }
        return stageFileName(id).utf8.elementsEqual(name.utf8)
    }

    public static func retainExtendedAttributes(_ attributes: [String: Data], at url: URL) throws {
        guard !attributes.isEmpty else { return }
        guard attributes.keys.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open staged attributes") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError("inspect staged attributes") }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
              try FileSystemInfo(fd: fd).isLocal else { throw CocoaError(.fileWriteNoPermission) }
        for (name, value) in attributes {
            let result = value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
            guard result == 0 else { throw posixError("retain staged attribute") }
        }
    }

    /// Only regular files with `Transfer.run`'s stage-file names go; symlinks and folders stay.
    public static func removeLeftoverStageFiles(in directory: URL, createdBefore cutoff: Date,
                                                excluding excluded: Set<String> = []) throws -> Int {
        guard let stream = directory.withUnsafeFileSystemRepresentation({ opendir($0!) }) else {
            throw posixError("open staging directory")
        }
        defer { closedir(stream) }
        let directoryFD = dirfd(stream)
        var removed = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError("read staging directory") }
                return removed
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard isStageFileName(name), !excluded.contains(name) else { continue }
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw posixError("stat stage file")
            }
            let birth = info.st_birthtimespec
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  Date(timeIntervalSince1970: Double(birth.tv_sec) + Double(birth.tv_nsec) / 1e9) < cutoff else {
                continue
            }
            guard unlinkat(directoryFD, name, 0) == 0 else {
                if errno == ENOENT { continue }
                throw posixError("remove stage file")
            }
            removed += 1
        }
    }
}
