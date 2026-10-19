import Darwin
import Foundation

/// Only `list` makes one, and only from a pass that ended with 0 on the expected mount.
public struct DirectoryListing: Sendable {
    public static let defaultLimit = 100_000
    public static let defaultBufferSize = 256 * 1024

    public struct Entry: Sendable {
        /// The raw values are the catalog's `kind` column.
        public enum Kind: Int, Sendable { case folder = 1, file = 2 }

        /// Compare with `utf8`: `==` on `String` treats NFC and NFD forms as equal.
        public let name: String
        public let key: NameKey
        public let kind: Kind
        /// 0 for folders.
        public let size: Int64
        public let mtimeNs: Int64
        public let ctimeNs: Int64
        /// ATTR_CMN_FILEID: evidence only, never a key.
        public let fileID: UInt64

        init(name: String, kind: Kind, size: Int64, mtimeNs: Int64, ctimeNs: Int64, fileID: UInt64) {
            self.name = name
            key = NameKey(name)
            self.kind = kind
            self.size = size
            self.mtimeNs = mtimeNs
            self.ctimeNs = ctimeNs
            self.fileID = fileID
        }
    }

    /// Its attributes couldn't be read, so `reconcile` leaves its live row, if any, as it is.
    public struct Unreadable: Sendable {
        public let name: String
        public let key: NameKey
        /// The ATTR_CMN_ERROR errno, or ENOATTR when a needed attribute came back invalid.
        public let error: Int32

        init(name: String, error: Int32) {
            self.name = name
            key = NameKey(name)
            self.error = error
        }
    }

    public enum Candidate: Sendable {
        case entry(Entry), unreadable(Unreadable)

        public var name: String {
            switch self {
            case .entry(let entry): entry.name
            case .unreadable(let entry): entry.name
            }
        }

        public var key: NameKey {
            switch self {
            case .entry(let entry): entry.key
            case .unreadable(let entry): entry.key
            }
        }
    }

    public struct Skipped: Equatable, Sendable {
        public internal(set) var otherKinds = 0
        public internal(set) var invalidNames = 0
        public internal(set) var collisions = 0
    }

    /// Keys are unique across `entries` and `unreadable`. Every list is in name-byte order.
    public let entries: [Entry]
    public let unreadable: [Unreadable]
    /// Names whose key an earlier name has; kept, because a live row may hold one of them.
    public let collisionLosers: [Candidate]
    public let skipped: Skipped
    public let openDuration: Duration
    public let bulkDuration: Duration
    public let bulkCalls: Int

    enum Parsed {
        case entry(Entry), unreadable(Unreadable), otherKind, invalidName
    }

    init(_ parsed: [Parsed], openDuration: Duration = .zero, bulkDuration: Duration = .zero, bulkCalls: Int = 0) {
        self.openDuration = openDuration
        self.bulkDuration = bulkDuration
        self.bulkCalls = bulkCalls
        var skipped = Skipped()
        var candidates: [Candidate] = []
        for item in parsed {
            switch item {
            case .entry(let entry): candidates.append(.entry(entry))
            case .unreadable(let entry): candidates.append(.unreadable(entry))
            case .otherKind: skipped.otherKinds += 1
            case .invalidName: skipped.invalidNames += 1
            }
        }
        // The listing order is unspecified; byte order makes the first name of a key stable.
        candidates.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        var keys = Set<NameKey>()
        var entries: [Entry] = []
        var unreadable: [Unreadable] = []
        var collisionLosers: [Candidate] = []
        for candidate in candidates {
            guard keys.insert(candidate.key).inserted else {
                skipped.collisions += 1
                collisionLosers.append(candidate)
                continue
            }
            switch candidate {
            case .entry(let entry): entries.append(entry)
            case .unreadable(let entry): unreadable.append(entry)
            }
        }
        self.entries = entries
        self.unreadable = unreadable
        self.collisionLosers = collisionLosers
        self.skipped = skipped
    }

    /// Never partial: a failure, a mount change or over `limit` entries of any kind throws.
    public static func list(locationRoot: Int32, relativePath: RelativePath, expected: MountIdentity,
                            limit: Int = defaultLimit, bufferSize: Int = defaultBufferSize,
                            progress: () -> Void = {}) throws -> DirectoryListing {
        precondition(bufferSize > 0)
        return try expected.guarding(root: locationRoot) {
            let started = ContinuousClock.now
            let fd = try openFolder(locationRoot, relativePath)
            let opened = ContinuousClock.now
            defer { close(fd) }
            try expected.requireSameMount(fd, root: locationRoot)
            let result = try readEntries(fd, limit: limit, bufferSize: bufferSize, progress: progress)
            try expected.requireSameMount(fd, root: locationRoot)
            return DirectoryListing(result.entries, openDuration: started.duration(to: opened),
                                    bulkDuration: result.duration, bulkCalls: result.calls)
        }
    }

    /// Throws `listingIncomplete` if a name from `missingChildren` still holds another object.
    public static func confirmMissing(_ children: [MissingChild], locationRoot: Int32, relativePath: RelativePath,
                                      expected: MountIdentity, progress: () -> Void = {}) throws {
        guard !children.isEmpty else { return }
        try expected.guarding(root: locationRoot) {
            let fd = try openFolder(locationRoot, relativePath)
            defer { close(fd) }
            try expected.requireSameMount(fd, root: locationRoot)
            for child in children {
                guard RelativePath.isValidComponent(child.name) else { throw SourceFailure.pathRejected }
                var info = stat()
                var result: Int32
                repeat {
                    result = fstatat(fd, child.name, &info, AT_SYMLINK_NOFOLLOW)
                } while result != 0 && errno == EINTR
                if result == 0 {
                    let kind = info.st_mode & S_IFMT
                    // A pass can end with 0 yet skip an entry; only a renamed twin or a hidden kind is gone.
                    if (kind == S_IFREG || kind == S_IFDIR) && info.st_ino != child.twinFileID {
                        throw SourceFailure.listingIncomplete
                    }
                } else {
                    let code = errno
                    guard code == ENOENT else { throw SourceFailure.classify(errno: code, context: .listing) }
                }
                progress()
            }
            try expected.requireSameMount(fd, root: locationRoot)
        }
    }

    private static func openFolder(_ locationRoot: Int32, _ relativePath: RelativePath) throws -> Int32 {
        let path = relativePath.isRoot ? "." : relativePath.string
        var fd: Int32
        repeat {
            fd = openat(locationRoot, path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH)
        } while fd < 0 && errno == EINTR
        guard fd >= 0 else { throw posixError("openat listing folder") }
        return fd
    }

    private static let requested = ATTR_CMN_RETURNED_ATTRS | attrgroup_t(
        ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_FILEID)
    private static let needed = attrgroup_t(ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_FILEID)

    private static func readEntries(_ fd: Int32, limit: Int, bufferSize: Int,
                                    progress: () -> Void) throws -> (entries: [Parsed], duration: Duration, calls: Int) {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: requested,
                               volattr: 0, dirattr: 0, fileattr: attrgroup_t(ATTR_FILE_DATALENGTH), forkattr: 0)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var parsed: [Parsed] = []
        var duration = Duration.zero
        var calls = 0
        while true {
            let started = ContinuousClock.now
            let count = getattrlistbulk(fd, &request, buffer.baseAddress!, buffer.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
            let code = errno
            duration += started.duration(to: .now)
            calls += 1
            if count < 0 {
                // A call that returns no entries leaves the directory offset where it was.
                if code == EINTR { continue }
                throw posixError("getattrlistbulk", code: code)
            }
            if count == 0 { return (parsed, duration, calls) }
            guard parsed.count + Int(count) <= limit else { throw SourceFailure.tooManyEntries }
            try parse(UnsafeRawBufferPointer(buffer), count: Int(count), into: &parsed)
            // Per batch, so the 15 s stall limit never marks a share unresponsive for a large folder.
            progress()
        }
    }

    static func parse(_ buffer: UnsafeRawBufferPointer, count: Int, into parsed: inout [Parsed]) throws {
        var start = 0
        for _ in 0..<count {
            guard buffer.count - start >= MemoryLayout<UInt32>.size else { throw malformedEntry() }
            let length = Int(buffer.loadUnaligned(fromByteOffset: start, as: UInt32.self))
            guard length > 0, length <= buffer.count - start else { throw malformedEntry() }
            parsed.append(try parseEntry(UnsafeRawBufferPointer(rebasing: buffer[start..<(start + length)])))
            start += length
        }
    }

    private static func parseEntry(_ bytes: UnsafeRawBufferPointer) throws -> Parsed {
        var fields = FieldReader(bytes: bytes, offset: MemoryLayout<UInt32>.size)
        let returned = try fields.read(attribute_set_t.self)
        // FSOPT_PACK_INVAL_ATTRS packs every common field: ERROR and NAME first, then bit order.
        let error = try fields.read(UInt32.self)
        let nameField = fields.offset
        let nameReference = try fields.read(attrreference_t.self)
        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { throw malformedEntry() }
        // The data offset counts from the attrreference itself, and the length includes the NUL.
        let nameStart = nameField + Int(nameReference.attr_dataoffset)
        guard nameStart >= 0, nameStart <= bytes.count, Int(nameReference.attr_length) <= bytes.count - nameStart,
              let nameEnd = bytes[nameStart..<(nameStart + Int(nameReference.attr_length))].firstIndex(of: 0) else {
            throw malformedEntry()
        }
        guard let name = String(validating: bytes[nameStart..<nameEnd], as: UTF8.self),
              RelativePath.isValidComponent(name) else { return .invalidName }
        if error != 0 { return .unreadable(Unreadable(name: name, error: Int32(bitPattern: error))) }

        let type = try fields.read(fsobj_type_t.self)
        let modified = try fields.read(timespec.self)
        let changed = try fields.read(timespec.self)
        let fileID = try fields.read(UInt64.self)
        guard returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 else {
            return .unreadable(Unreadable(name: name, error: ENOATTR))
        }
        let kind: Entry.Kind
        switch type {
        case VREG.rawValue: kind = .file
        case VDIR.rawValue: kind = .folder
        default: return .otherKind
        }
        var size: Int64 = 0
        var complete = returned.commonattr & needed == needed
        // Folders get no file group at all, even with FSOPT_PACK_INVAL_ATTRS.
        if kind == .file {
            size = try fields.read(off_t.self)
            complete = complete && returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0
        }
        guard complete else { return .unreadable(Unreadable(name: name, error: ENOATTR)) }
        return .entry(Entry(
            name: name, kind: kind, size: size,
            mtimeNs: ContentFingerprint.nanoseconds(seconds: Int64(modified.tv_sec), nanoseconds: Int64(modified.tv_nsec)),
            ctimeNs: ContentFingerprint.nanoseconds(seconds: Int64(changed.tv_sec), nanoseconds: Int64(changed.tv_nsec)),
            fileID: fileID))
    }

    private static func malformedEntry() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EBADMSG), userInfo: [
            NSLocalizedDescriptionKey: "getattrlistbulk: malformed entry"
        ])
    }

    private struct FieldReader {
        let bytes: UnsafeRawBufferPointer
        var offset: Int

        mutating func read<Value: BitwiseCopyable>(_: Value.Type) throws -> Value {
            guard bytes.count - offset >= MemoryLayout<Value>.size else { throw DirectoryListing.malformedEntry() }
            defer { offset += MemoryLayout<Value>.size }
            return bytes.loadUnaligned(fromByteOffset: offset, as: Value.self)
        }
    }
}
