import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class UploadTests: XCTestCase {
    private var root: URL!
    private var remote: URL!
    private var input: URL!
    private var outbox: UploadOutbox!
    private var fd: Int32 = -1
    private let payload = Data((0..<(2 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        remote = root.appending(path: "remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        input = root.appending(path: "input")
        try payload.write(to: input)
        outbox = try UploadOutbox(directory: root.appending(path: "pending"))
        fd = open(remote.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
    }

    override func tearDownWithError() throws {
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(at: root)
    }

    private func prepared(kind: CatalogRow.Kind = .file, name: String = "new.bin",
                          modified: Date? = nil) throws -> PendingUpload {
        let request = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                        name: name, kind: kind, staging: nil, modified: modified)
        return try outbox.prepare(request, path: XCTUnwrap(RelativePath(name)),
                                  contents: kind == .file ? input : nil, progress: Progress())
    }

    private final class DirectRemote: UploadRemote {
        var version: RemoteFileVersion
        var createError: Error?
        var writeError: Error?
        var creates = 0, writes = 0, inspections = 0, resumptions = 0
        var resumedIdentity: RemoteFileIdentity?
        var savedTimes: [Date?] = []

        init(_ record: PendingUpload) throws {
            version = try RemoteFileVersion(identity: RemoteFileIdentity(fileID: 42, birthMicroseconds: 100),
                size: record.size, modifiedMicroseconds: 200,
                changedMicroseconds: 300, attributes: 0)
        }

        func createUpload(path: String) throws -> RemoteFileIdentity {
            creates += 1
            if let createError { throw createError }
            return version.identity
        }

        func writeUpload(path: String, contents: URL, modified: Date?) throws -> RemoteFileVersion {
            writes += 1
            savedTimes.append(modified)
            if let writeError { throw writeError }
            return version
        }

        func inspectUpload(path: String) throws -> RemoteFileVersion {
            inspections += 1
            return version
        }

        func resumeUpload(path: String, contents: URL, identity: RemoteFileIdentity,
                          modified: Date?) throws -> RemoteFileVersion {
            resumptions += 1
            savedTimes.append(modified)
            resumedIdentity = identity
            return version
        }
    }

    func testDirectUploadPersistsIdentityBeforeWritingAndResumesOnlyThatIdentity() throws {
        var record = try prepared()
        let server = try DirectRemote(record)
        server.writeError = TransferError.cancelled
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()))
        outbox = try UploadOutbox(directory: root.appending(path: "pending"))
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertEqual(record.state, .created)
        XCTAssertEqual(record.serverFile, server.version.identity)
        XCTAssertEqual(record.remoteID, server.version.identity.fileID)
        try outbox.upload(&record, remote: server, progress: Progress())
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(server.creates, 1)
        XCTAssertEqual(server.writes, 1)
        XCTAssertEqual(server.inspections, 0)
        XCTAssertEqual(server.resumptions, 1)
        XCTAssertEqual(server.resumedIdentity, record.serverFile)
        try outbox.upload(&record, remote: server, progress: Progress())
        XCTAssertEqual(server.resumptions, 1)
        XCTAssertEqual(server.inspections, 1)
    }

    func testSaveTimeSurvivesRelaunchAndReachesEveryWrite() throws {
        let saved = Date(timeIntervalSince1970: 1_762_600_000.123_456_7)
        var record = try prepared(modified: saved)
        let server = try DirectRemote(record)
        server.writeError = TransferError.cancelled
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()))
        outbox = try UploadOutbox(directory: root.appending(path: "pending"))
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertEqual(record.modified, saved)
        try outbox.upload(&record, remote: server, progress: Progress())
        XCTAssertEqual(server.savedTimes, [saved, saved])
        XCTAssertNil(try prepared(kind: .folder, name: "folder", modified: saved).modified)
    }

    func testRecordWithoutSaveTimeDecodesAndKeepsServerTime() throws {
        var record = try prepared()
        let url = root.appending(path: "pending/\(record.id.uuidString).json")
        // As saved before the field existed.
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(fields["modified"])
        record = try XCTUnwrap(outbox.records().first)
        let server = try DirectRemote(record)
        try outbox.upload(&record, remote: server, progress: Progress())
        XCTAssertEqual(server.savedTimes, [nil])
    }

    func testDirectRecoveryRequiresOwnedIdentityAndCompleteWrite() throws {
        var record = try prepared()
        let server = try DirectRemote(record)
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()) { state in
            if state == .created { throw TransferError.cancelled }
        })
        let full = server.version
        for (birth, size) in [(101, full.size), (100, full.size - 1)] {
            server.version = try RemoteFileVersion(identity: RemoteFileIdentity(fileID: 42, birthMicroseconds: UInt64(birth)),
                size: size, modifiedMicroseconds: 200, changedMicroseconds: 300,
                attributes: 0)
            record = try XCTUnwrap(outbox.records().first)
            XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress())) {
                XCTAssertEqual($0 as? UploadError, .unresolved)
            }
            XCTAssertEqual(record.state, .created)
        }
        XCTAssertEqual(server.creates, 1)
        XCTAssertEqual(server.writes, 0)
        XCTAssertEqual(server.resumptions, 2)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "pending/\(record.id.uuidString).data")), payload)
    }

    func testDirectCollisionAfterLostCreateReplyRemainsUnresolved() throws {
        var record = try prepared()
        let server = try DirectRemote(record)
        server.createError = TransferError.cancelled
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()))
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertEqual(record.state, .attempting)
        XCTAssertNil(record.serverFile)
        server.createError = UploadError.collision
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress())) {
            XCTAssertEqual($0 as? UploadError, .unresolved)
        }
        XCTAssertEqual(try outbox.records().first?.state, .attempting)
        XCTAssertEqual(server.writes, 0)
        XCTAssertEqual(server.inspections, 0)
    }

    func testDirectKnownRefusalAndCollisionKeepSafeRetryStates() throws {
        var record = try prepared()
        let server = try DirectRemote(record)
        server.createError = UploadCreateRefusal(CocoaError(.fileWriteNoPermission))
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()))
        XCTAssertEqual(try outbox.records().first?.state, .prepared)
        server.createError = UploadError.collision
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress())) {
            XCTAssertEqual($0 as? UploadError, .collision)
        }
        XCTAssertEqual(try outbox.records().first?.state, .collision)
        XCTAssertEqual(server.writes, 0)
    }

    func testDirectUploadRejectsDamagedLocalPayloadBeforeRemoteCreate() throws {
        var record = try prepared()
        let server = try DirectRemote(record)
        let staged = root.appending(path: "pending/\(record.id.uuidString).data")
        XCTAssertEqual(chmod(staged.path, 0o600), 0)
        try Data("damaged".utf8).write(to: staged)
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()))
        XCTAssertEqual(try outbox.records().first?.state, .prepared)
        XCTAssertEqual(server.creates, 0)
    }

    func testDirectResumeRejectsDamagedLocalPayloadBeforeRemoteAccess() throws {
        var record = try prepared()
        let server = try DirectRemote(record)
        server.writeError = TransferError.cancelled
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()))
        let staged = root.appending(path: "pending/\(record.id.uuidString).data")
        XCTAssertEqual(chmod(staged.path, 0o600), 0)
        try Data("damaged".utf8).write(to: staged)
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()))
        XCTAssertEqual(server.resumptions, 0)
        XCTAssertEqual(record.state, .created)
    }

    func testAcknowledgedUploadRetainsOriginalNameAfterFinderChoosesDuplicateName() throws {
        var record = try prepared()
        let server = try DirectRemote(record)
        server.writeError = TransferError.cancelled
        XCTAssertThrowsError(try outbox.upload(&record, remote: server, progress: Progress()))
        let renamed = try CreateRequest(template: record.template, parent: record.parent,
                                        name: "new 2.bin", kind: .file, staging: nil)
        let retry = try outbox.prepare(renamed, path: XCTUnwrap(RelativePath(renamed.name)),
                                      contents: input, progress: Progress())
        XCTAssertEqual(retry.name, record.name)
        XCTAssertEqual(retry.path, record.path)
        XCTAssertEqual(retry.serverFile, record.serverFile)
        record.serverFile = nil
        try outbox.save(record)
        XCTAssertThrowsError(try outbox.prepare(renamed, path: XCTUnwrap(RelativePath(renamed.name)),
                                               contents: input, progress: Progress()))
    }

    func testOrphanedStagingBlocksLocationRemoval() throws {
        let orphan = root.appending(path: "pending/\(UUID().uuidString).data")
        try payload.write(to: orphan)
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertTrue(try outbox.records().isEmpty)
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        XCTAssertEqual(try Data(contentsOf: orphan), payload)
    }

    func testSupersededPayloadRemovalIsRepeatableAndRefusesAttemptedUploads() throws {
        var attempted = try prepared()
        attempted.state = .attempting
        try outbox.save(attempted)
        XCTAssertThrowsError(try outbox.discardUnpublishedPayload(attempted.id))
        let retained = root.appending(path: "pending/\(attempted.id.uuidString).data")
        XCTAssertEqual(try Data(contentsOf: retained), payload)
        let local = try prepared(name: "superseded.bin")
        try outbox.discardUnpublishedPayload(local.id)
        try outbox.discardUnpublishedPayload(local.id)
        XCTAssertEqual(try outbox.records().map(\.id), [attempted.id])
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertEqual(try Data(contentsOf: retained), payload)
    }

    func testIncompleteLocalPreparationCanBeRemovedAfterInterruption() throws {
        let request = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                        name: "new.bin", kind: .file, staging: nil)
        XCTAssertThrowsError(try outbox.prepare(request, path: XCTUnwrap(RelativePath("new.bin")), contents: input,
                                               progress: Progress()) { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let record = try XCTUnwrap(outbox.records().first)
        let staged = root.appending(path: "pending/\(record.id.uuidString).data")
        XCTAssertLessThan(try Data(contentsOf: staged).count, payload.count)
        outbox = try UploadOutbox(directory: root.appending(path: "pending"))
        XCTAssertFalse(try outbox.recoverLocalPreparation(record.id, size: record.size, digest: record.digest))
        XCTAssertFalse(try outbox.recoverLocalPreparation(record.id, size: record.size, digest: record.digest))
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try Data(contentsOf: input), payload)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: remote.path).isEmpty)
    }

    func testCompletePayloadSurvivesLostStagingStateAndReplayWithoutAnotherCopy() throws {
        var record = try prepared()
        let staged = root.appending(path: "pending/\(record.id.uuidString).data")
        let original = try ReadOnlyFile(url: staged).snapshot
        record.state = .staging
        try outbox.save(record)
        let request = try CreateRequest(template: record.template, parent: record.parent,
                                        name: record.name, kind: record.kind, staging: nil)
        let replay = try outbox.prepare(request, path: XCTUnwrap(RelativePath(record.path)), contents: input,
                                       progress: Progress()) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertEqual(replay.state, .prepared)
        XCTAssertEqual(try ReadOnlyFile(url: staged).snapshot.inode, original.inode)
        record.state = .staging
        try outbox.save(record)
        XCTAssertTrue(try outbox.recoverLocalPreparation(record.id, size: record.size, digest: record.digest))
        XCTAssertEqual(try outbox.records().first?.state, .prepared)
        XCTAssertEqual(try Data(contentsOf: staged), payload)
        XCTAssertEqual(try ReadOnlyFile(url: staged).snapshot.inode, original.inode)
    }

    func testLocalPreparationRecoveryRetainsPreparedAndUncertainPayloads() throws {
        var record = try prepared()
        let staged = root.appending(path: "pending/\(record.id.uuidString).data")
        XCTAssertEqual(chmod(staged.path, 0o600), 0)
        try Data("short".utf8).write(to: staged)
        XCTAssertThrowsError(try outbox.recoverLocalPreparation(record.id, size: record.size, digest: record.digest))
        XCTAssertEqual(try Data(contentsOf: staged), Data("short".utf8))
        record.state = .attempting
        try outbox.save(record)
        XCTAssertThrowsError(try outbox.recoverLocalPreparation(record.id, size: record.size, digest: record.digest))
        XCTAssertEqual(try outbox.records().first?.state, .attempting)
        record.state = .staging
        try outbox.save(record)
        let changed = Data(repeating: 7, count: payload.count)
        try changed.write(to: staged)
        XCTAssertThrowsError(try outbox.recoverLocalPreparation(record.id, size: record.size, digest: record.digest))
        XCTAssertEqual(try Data(contentsOf: staged), changed)
        try FileManager.default.removeItem(at: root.appending(path: "pending/\(record.id.uuidString).json"))
        XCTAssertThrowsError(try outbox.recoverLocalPreparation(record.id, size: record.size, digest: record.digest))
        XCTAssertEqual(try Data(contentsOf: staged), changed)
    }

    func testRemovalKeepsPendingDataAndDeletesOnlyCompletedReceipts() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        try outbox.complete(&record, item: UUID().uuidString)
        try outbox.removeIfCompleted()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "pending").path))
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), payload)
    }

    func testLocalSpaceFailureBeforeRemoteCreationRetainsSystemInput() throws {
        let request = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                        name: "new.bin", kind: .file, staging: nil)
        XCTAssertThrowsError(try outbox.prepare(request, path: XCTUnwrap(RelativePath("new.bin")), contents: input,
                                               progress: Progress()) { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(try Data(contentsOf: input), payload)
        XCTAssertEqual(try outbox.pendingCount, 1)
        var record = try outbox.prepare(request, path: XCTUnwrap(RelativePath("new.bin")), contents: input,
                                        progress: Progress())
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), payload)
    }

    func testInterruptedStagingRejectsChangedSystemInput() throws {
        let request = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                        name: "new.bin", kind: .file, staging: nil)
        XCTAssertThrowsError(try outbox.prepare(request, path: XCTUnwrap(RelativePath("new.bin")), contents: input,
                                               progress: Progress()) { _ in throw TransferError.cancelled })
        let record = try XCTUnwrap(outbox.records().first)
        let staged = root.appending(path: "pending/\(record.id.uuidString).data")
        let preserved = try Data(contentsOf: staged)
        try Data("other bytes".utf8).write(to: input)
        XCTAssertThrowsError(try outbox.prepare(request, path: XCTUnwrap(RelativePath("new.bin")), contents: input,
                                               progress: Progress()))
        XCTAssertEqual(try Data(contentsOf: staged), preserved)
        XCTAssertEqual(try outbox.records().first?.state, .staging)
    }

    func testNativeSMBCreateAndRecoveryInApprovedFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["TINYMOUNTER_WRITABLE_FIXTURE"] else {
            throw XCTSkip("Needs an approved disposable writable SMB fixture")
        }
        let fixture = URL(fileURLWithPath: path).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let descriptor = open(fixture.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError("open test fixture") }
        defer { close(descriptor) }
        XCTAssertEqual(try FileSystemInfo(fd: descriptor).type, "smbfs")
        var record = try prepared()
        try outbox.upload(&record, locationRoot: descriptor, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: fixture.appending(path: "new.bin")), payload)
        record = try XCTUnwrap(outbox.records().first)
        try outbox.upload(&record, locationRoot: descriptor, progress: Progress())
        let other = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                      name: "new.bin", kind: .file, staging: nil)
        var collision = try outbox.prepare(other, path: XCTUnwrap(RelativePath("new.bin")), contents: input, progress: Progress())
        XCTAssertThrowsError(try outbox.upload(&collision, locationRoot: descriptor, progress: Progress())) {
            XCTAssertEqual($0 as? UploadError, .collision)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.appending(path: "new.bin")), payload)

    }

    func testCompleteFileAndIdempotentAcknowledgement() throws {
        var record = try prepared()
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: record.name)), payload)
        XCTAssertEqual(record.state, .verified)
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        try outbox.complete(&record, item: UUID().uuidString)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(try outbox.records().first?.item, record.item)

    }

    func testCollisionNeverChangesExistingBytes() throws {
        let existing = Data("existing".utf8)
        try existing.write(to: remote.appending(path: "new.bin"))
        var record = try prepared()
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress())) {
            XCTAssertEqual($0 as? UploadError, .collision)
        }
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "pending/\(record.id.uuidString).data").path))
    }

    func testCollisionCanRetryOnlyWhenTheSystemSuppliesANewName() throws {
        let template = UUID().uuidString
        let first = try CreateRequest(template: template, parent: Catalog.rootItemID, name: "new.bin", kind: .file, staging: nil)
        try Data("existing".utf8).write(to: remote.appending(path: "new.bin"))
        var record = try outbox.prepare(first, path: XCTUnwrap(RelativePath("new.bin")), contents: input, progress: Progress())
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()))
        XCTAssertEqual(try outbox.pendingCount, 1)
        let second = try CreateRequest(template: template, parent: Catalog.rootItemID, name: "chosen.bin", kind: .file, staging: nil)
        record = try outbox.prepare(second, path: XCTUnwrap(RelativePath("chosen.bin")), contents: input, progress: Progress())
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "chosen.bin")), payload)
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), Data("existing".utf8))
    }

    func testRefusedCreateCanBeAttemptedAgain() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores the folder's permissions")
        var record = try prepared()
        XCTAssertEqual(chmod(remote.path, 0o555), 0)
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress())) {
            XCTAssertEqual(($0 as NSError).code, Int(EACCES))
        }
        XCTAssertEqual(chmod(remote.path, 0o755), 0)
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertEqual(record.state, .prepared)
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), payload)
    }

    func testCrashBeforeRemoteIdentityCreatesOnlyWhileTheNameIsAbsent() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()) { state in
            if state == .attempting { throw UploadError.unresolved }
        })
        // The interrupted attempt may have created the file; an item at the name stays unresolved.
        let partial = Data("partial".utf8)
        try partial.write(to: remote.appending(path: "new.bin"))
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress())) {
            XCTAssertEqual($0 as? UploadError, .unresolved)
        }
        XCTAssertEqual(try outbox.records().first?.state, .attempting)
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), partial)
        try FileManager.default.removeItem(at: remote.appending(path: "new.bin"))
        record = try XCTUnwrap(outbox.records().first)
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), payload)
    }

    func testStoppedItemKeepsNoContentsAndIsNotPending() throws {
        let record = try prepared()
        try outbox.stop(record.id)
        XCTAssertEqual(try outbox.records().map(\.state), [.stopped])
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(try outbox.contentBytes, 0)
        XCTAssertFalse(try outbox.takeStopped(template: UUID().uuidString))
        XCTAssertTrue(try outbox.takeStopped(template: record.template))
        XCTAssertTrue(try outbox.records().isEmpty)
        XCTAssertFalse(try outbox.takeStopped(template: record.template))
        try outbox.removeIfCompleted()
    }

    func testLocationRemovalTakesOnlyItemsThatDidNotReachTheServer() throws {
        var attempted = try prepared(name: "attempted.bin")
        XCTAssertThrowsError(try outbox.upload(&attempted, locationRoot: fd, progress: Progress()) { state in
            if state == .attempting { throw UploadError.unresolved }
        })
        _ = try prepared()
        XCTAssertThrowsError(try outbox.removeForLocationRemoval())
        // The uncertain attempt finishes once its name proves absent; then only a stoppable item stays.
        attempted = try XCTUnwrap(outbox.records().first { $0.id == attempted.id })
        try outbox.upload(&attempted, locationRoot: fd, progress: Progress())
        try outbox.complete(&attempted, item: UUID().uuidString)
        try outbox.removeForLocationRemoval()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "pending").path))
    }

    func testOnlyAnItemThatDidNotReachTheServerCanBeStopped() throws {
        var attempted = try prepared()
        XCTAssertThrowsError(try outbox.upload(&attempted, locationRoot: fd, progress: Progress()) { state in
            if state == .attempting { throw UploadError.unresolved }
        })
        XCTAssertThrowsError(try outbox.stop(attempted.id))
        XCTAssertEqual(try outbox.records().first?.state, .attempting)
        try Data("taken".utf8).write(to: remote.appending(path: "taken.bin"))
        var collided = try prepared(name: "taken.bin")
        XCTAssertThrowsError(try outbox.upload(&collided, locationRoot: fd, progress: Progress()))
        try outbox.stop(collided.id)
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "taken.bin")), Data("taken".utf8))
    }

    func testCollisionRetryPreservesInputAndEveryExistingDestination() throws {
        let original = Data("original".utf8), alternate = Data("alternate".utf8)
        try original.write(to: remote.appending(path: "new.bin"))
        try alternate.write(to: remote.appending(path: "new 2.bin"))
        var record = try prepared()
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()))
        let pending = root.appending(path: "pending/\(record.id.uuidString).data")
        let retry = try CreateRequest(template: record.template, parent: record.parent,
                                      name: "new 2.bin", kind: .file, staging: nil)
        let changed = root.appending(path: "changed")
        try Data("different input".utf8).write(to: changed)
        XCTAssertThrowsError(try outbox.prepare(retry, path: XCTUnwrap(RelativePath("new 2.bin")),
                                               contents: changed, progress: Progress())) {
            XCTAssertEqual($0 as? UploadError, .unresolved)
        }
        XCTAssertEqual(try outbox.records().first?.state, .collision)
        XCTAssertEqual(try Data(contentsOf: pending), payload)
        record = try outbox.prepare(retry, path: XCTUnwrap(RelativePath("new 2.bin")),
                                    contents: input, progress: Progress())
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress())) {
            XCTAssertEqual($0 as? UploadError, .collision)
        }
        let final = try CreateRequest(template: record.template, parent: record.parent,
                                      name: "new 3.bin", kind: .file, staging: nil)
        record = try outbox.prepare(final, path: XCTUnwrap(RelativePath("new 3.bin")),
                                    contents: input, progress: Progress())
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), original)
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new 2.bin")), alternate)
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new 3.bin")), payload)
        try outbox.complete(&record, item: UUID().uuidString)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testUncertainUploadCannotRetryUnderAnotherName() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()) { state in
            if state == .attempting { throw UploadError.unresolved }
        })
        let retry = try CreateRequest(template: record.template, parent: record.parent,
                                      name: "new 2.bin", kind: .file, staging: nil)
        XCTAssertThrowsError(try outbox.prepare(retry, path: XCTUnwrap(RelativePath("new 2.bin")),
                                               contents: input, progress: Progress())) {
            XCTAssertEqual($0 as? UploadError, .unresolved)
        }
        XCTAssertEqual(try outbox.records().first?.state, .attempting)
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "pending/\(record.id.uuidString).data")), payload)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: remote.path).isEmpty)
    }

    func testPartialRemoteIsNeverReopenedForWriting() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()) { state in
            if state == .created { throw UploadError.unresolved }
        })
        record = try XCTUnwrap(outbox.records().first)
        let target = remote.appending(path: "new.bin")
        XCTAssertEqual(try Data(contentsOf: target).count, 0)
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()))
        XCTAssertEqual(try Data(contentsOf: target).count, 0)
        XCTAssertEqual(try outbox.pendingCount, 1)
    }

    func testCrashAfterUploadVerifiesCompleteContentOnReopen() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()) { state in
            if state == .verified { throw UploadError.unresolved }
        })
        outbox = try UploadOutbox(directory: root.appending(path: "pending"))
        record = try XCTUnwrap(outbox.records().first)
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(try Data(contentsOf: remote.appending(path: "new.bin")), payload)
    }

    func testChangedCompletedRemoteRemainsPending() throws {
        var record = try prepared()
        try outbox.upload(&record, locationRoot: fd, progress: Progress())
        try Data("changed".utf8).write(to: remote.appending(path: "new.bin"))
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()))
        XCTAssertEqual(try outbox.pendingCount, 1)
    }

    func testSymlinkParentCannotEscapeLocation() throws {
        try FileManager.default.createSymbolicLink(atPath: remote.appending(path: "escape").path,
                                                   withDestinationPath: root.path)
        let request = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                        name: "escaped", kind: .file, staging: nil)
        var record = try outbox.prepare(request, path: XCTUnwrap(RelativePath("escape/escaped")),
                                        contents: input, progress: Progress())
        XCTAssertThrowsError(try outbox.upload(&record, locationRoot: fd, progress: Progress()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "escaped").path))
    }

    func testReplayWithDifferentContentsCannotReuseOperation() throws {
        let request = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                        name: "new.bin", kind: .file, staging: nil)
        _ = try outbox.prepare(request, path: XCTUnwrap(RelativePath("new.bin")), contents: input, progress: Progress())
        try Data("other bytes".utf8).write(to: input)
        XCTAssertThrowsError(try outbox.prepare(request, path: XCTUnwrap(RelativePath("new.bin")), contents: input,
                                               progress: Progress()))
    }
}
