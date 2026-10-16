import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class ShareMountTests: XCTestCase {
    private var root: URL!
    private var rootFD: Int32 = -1
    private var identity: MountIdentity!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "dir"), withIntermediateDirectories: true)
        let file = root.appending(path: "dir/file.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data("bytes".utf8)))
        rootFD = open(root.path(percentEncoded: false), O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(rootFD, 0)
        identity = try MountIdentity(descriptor: rootFD)
    }

    override func tearDownWithError() throws {
        if rootFD >= 0 { close(rootFD) }
        try FileManager.default.removeItem(at: root)
    }

    func testAFileSystemMountedInsideTheShareIsRejected() throws {
        // Like a volume mounted inside a share, the data volume (temporary folders) is below "/".
        let system = open("/", O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(system, 0)
        defer { close(system) }
        let systemIdentity = try MountIdentity(descriptor: system)
        try XCTSkipIf(systemIdentity == identity, "The temporary folder is on the system volume.")
        let real = try XCTUnwrap(realpath(root.path(percentEncoded: false), nil))
        defer { free(real) }
        let below = try XCTUnwrap(RelativePath(String(String(cString: real).dropFirst())))
        let folder = try XCTUnwrap(below.appending("dir"))

        for path in [below, folder] {
            XCTAssertThrowsError(try DirectoryListing.list(locationRoot: system, relativePath: path,
                                                           expected: systemIdentity)) {
                XCTAssertEqual($0 as? SourceFailure, .pathRejected)
            }
            XCTAssertThrowsError(try DirectoryListing.confirmMissing([MissingChild(name: "gone")], locationRoot: system, relativePath: path,
                                                                     expected: systemIdentity)) {
                XCTAssertEqual($0 as? SourceFailure, .pathRejected)
            }
        }
        XCTAssertThrowsError(try ReadOnlyFile(directoryFD: system, relativePath: XCTUnwrap(folder.appending("file.bin")),
                                              expected: systemIdentity)) {
            XCTAssertEqual($0 as? SourceFailure, .pathRejected)
        }

        let dir = try XCTUnwrap(RelativePath("dir"))
        let listing = try DirectoryListing.list(locationRoot: rootFD, relativePath: dir, expected: identity)
        XCTAssertEqual(listing.entries.count, 1)
        try DirectoryListing.confirmMissing([MissingChild(name: "gone")], locationRoot: rootFD, relativePath: dir, expected: identity)
        let file = try ReadOnlyFile(directoryFD: rootFD, relativePath: XCTUnwrap(dir.appending("file.bin")),
                                    expected: identity)
        XCTAssertEqual(file.snapshot.size, 5)
    }

    func testEveryCallGivesNotConnectedOnceTheMountIsGone() throws {
        let other = MountIdentity(typeName: identity.typeName, fsid: identity.fsid ^ 1, mountFrom: identity.mountFrom)
        let dead = try deadDescriptor()
        defer { close(dead) }
        // Without the check these succeed or fail with ENOENT, ENOTDIR or notRegularFile.
        for (label, locationRoot, expected) in [("other mount", rootFD, other), ("dead root", dead, identity!)] {
            for path in ["", "dir", "missing", "dir/file.bin"] {
                let relative = try XCTUnwrap(RelativePath(path))
                XCTAssertThrowsError(try DirectoryListing.list(locationRoot: locationRoot, relativePath: relative,
                                                               expected: expected)) {
                    XCTAssertEqual($0 as? SourceFailure, .notConnected, "\(label) \(path)")
                }
                XCTAssertThrowsError(try DirectoryListing.confirmMissing([MissingChild(name: "gone")], locationRoot: locationRoot,
                                                                         relativePath: relative, expected: expected)) {
                    XCTAssertEqual($0 as? SourceFailure, .notConnected, "\(label) \(path)")
                }
                XCTAssertThrowsError(try ReadOnlyFile(directoryFD: locationRoot, relativePath: relative,
                                                      expected: expected)) {
                    XCTAssertEqual($0 as? SourceFailure, .notConnected, "\(label) \(path)")
                }
            }
            XCTAssertThrowsError(try expected.requireMounted(locationRoot)) {
                XCTAssertEqual($0 as? SourceFailure, .notConnected, label)
            }
        }
    }

    func testASourceThatChangesDuringATransferGivesSourceChangedAndItsNewSnapshot() throws {
        let path = root.appending(path: "dir/file.bin")
        try Data(repeating: 7, count: 3 << 20).write(to: path)
        let file = try ReadOnlyFile(directoryFD: rootFD, relativePath: XCTUnwrap(RelativePath("dir/file.bin")),
                                    expected: identity, noCache: true)
        let progress = Progress()
        let observation = progress.observe(\.completedUnitCount) { progress, _ in
            guard progress.completedUnitCount == 1 << 20, let handle = try? FileHandle(forWritingTo: path) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data([1]))
            try? handle.close()
        }
        defer { observation.invalidate() }
        let staging = root.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        XCTAssertThrowsError(try Transfer.run(source: file, range: ByteRange(offset: 0, length: 3 << 20, fileSize: 3 << 20),
                                              stagingDirectory: staging, progress: progress)) {
            XCTAssertEqual($0 as? TransferError, .sourceChanged)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false)), [])
        let now = try file.currentSnapshot()
        XCTAssertEqual(now.size, (3 << 20) + 1)
        XCTAssertEqual(now.inode, file.snapshot.inode)
        XCTAssertNotEqual(now.fingerprint, file.snapshot.fingerprint)
    }

    func testGuardingKeepsTheErrorWhileTheRootIsMounted() throws {
        let original = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        XCTAssertNoThrow(try identity.requireMounted(rootFD))
        XCTAssertEqual(try identity.guarding(root: rootFD) { 7 }, 7)
        XCTAssertThrowsError(try identity.guarding(root: rootFD) { throw original }) {
            XCTAssertEqual($0 as NSError, original)
        }
        XCTAssertThrowsError(try identity.guarding(root: rootFD) { throw SourceFailure.tooManyEntries }) {
            XCTAssertEqual($0 as? SourceFailure, .tooManyEntries)
        }
        let dead = try deadDescriptor()
        defer { close(dead) }
        XCTAssertThrowsError(try identity.guarding(root: dead) { throw original }) {
            XCTAssertEqual($0 as? SourceFailure, .notConnected)
        }
    }

    /// revoke(2) leaves the descriptor on a dead vnode, as an unmount leaves a held O_EVTONLY one.
    private func deadDescriptor() throws -> Int32 {
        let controller = posix_openpt(O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(controller, 0)
        defer { close(controller) }
        XCTAssertEqual(grantpt(controller), 0)
        XCTAssertEqual(unlockpt(controller), 0)
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(ptsname_r(controller, &name, name.count), 0)
        let fd = open(name, O_EVTONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(revoke(name), 0)
        var info = statfs()
        XCTAssertNotEqual(fstatfs(fd, &info), 0)
        return fd
    }
}
