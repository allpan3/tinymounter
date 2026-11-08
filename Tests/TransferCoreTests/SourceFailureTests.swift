import Darwin
import Foundation
import SQLite3
import XCTest
@testable import TransferCore

final class SourceFailureTests: XCTestCase {
    private let everywhere: [SourceFailure.Context] = [.listing, .fetch]

    func testErrnoRowsOfThePlanTable() {
        // A nil expectation is unknown with the errno.
        let rows: [(condition: String, codes: [Int32], contexts: [SourceFailure.Context], expected: SourceFailure?)] = [
            ("timeout class", [ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ECONNRESET,
                               ECONNREFUSED, EPIPE, ENXIO, ESTALE], everywhere, .serverUnreachable),
            ("EAUTH or ENEEDAUTH", [EAUTH, ENEEDAUTH], everywhere, .notAuthenticated),
            ("EPERM or EACCES", [EPERM, EACCES], everywhere, .noPermission),
            ("ELOOP or ENOTCAPABLE", [ELOOP, ENOTCAPABLE], everywhere, .pathRejected),
            ("ENOENT or ENOTDIR", [ENOENT, ENOTDIR], everywhere, .missing),
            ("not in the table", [EIO, ECANCELED], everywhere, nil),
        ]
        for row in rows {
            for code in row.codes {
                for context in row.contexts {
                    let expected = row.expected ?? .unknown(domain: NSPOSIXErrorDomain, code: Int(code))
                    XCTAssertEqual(SourceFailure.classify(errno: code, context: context), expected,
                                   "\(row.condition): errno \(code) in \(context)")
                    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                    XCTAssertEqual(SourceFailure.classify(error, context: context), expected, row.condition)
                }
            }
        }
    }

    func testErrorRowsOfThePlanTable() {
        let rows: [(condition: String, error: Error, expected: SourceFailure)] = [
            ("version changed during a transfer", TransferError.sourceChanged, .versionChanged),
            ("cancelled", TransferError.cancelled, .cancelled),
            ("file replaced by another kind", TransferError.notRegularFile, .missing),
            ("folder over 100,000 entries", SourceFailure.tooManyEntries, .tooManyEntries),
            ("an already classified failure", SourceFailure.notAuthenticated, .notAuthenticated),
            ("a mount that went away", SourceFailure.notConnected, .notConnected),
            ("a listing that missed a name", SourceFailure.listingIncomplete, .listingIncomplete),
            ("a Swift POSIXError", POSIXError(.ETIMEDOUT), .serverUnreachable),
            ("another domain", NSError(domain: NSCocoaErrorDomain, code: 256),
             .unknown(domain: NSCocoaErrorDomain, code: 256)),
        ]
        for row in rows {
            for context in everywhere {
                XCTAssertEqual(SourceFailure.classify(row.error, context: context), row.expected, row.condition)
            }
        }
        let invalidRange = TransferError.invalidRange as NSError
        XCTAssertEqual(SourceFailure.classify(TransferError.invalidRange, context: .fetch),
                       .unknown(domain: invalidRange.domain, code: invalidRange.code))
    }

    func testCodesOfOtherDomainsStayApartFromErrnos() {
        // The extension maps catalog errors itself; classify only keeps their domain.
        let others: [Error] = [CatalogError.unsupportedSchema, CatalogError.otherDomain, CatalogError.pageExpired,
                               SQLiteError(code: SQLITE_CANTOPEN, operation: "open"), CancellationError(),
                               NSError(domain: NSCocoaErrorDomain, code: Int(EPERM))]
        for error in others {
            let failure = SourceFailure.classify(error, context: .listing)
            let bridged = error as NSError
            XCTAssertEqual(failure, .unknown(domain: bridged.domain, code: bridged.code), "\(error)")
            XCTAssertNotEqual(bridged.domain, NSPOSIXErrorDomain, "\(error)")
            XCTAssertNotEqual(failure, SourceFailure.classify(errno: Int32(bridged.code), context: .listing), "\(error)")
        }
    }

    func testThrownOpenErrorIsClassified() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertThrowsError(try ReadOnlyFile(url: missing)) {
            XCTAssertEqual(SourceFailure.classify($0, context: .fetch), .missing)
        }
    }
}
