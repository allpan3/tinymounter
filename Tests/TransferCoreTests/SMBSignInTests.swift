import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class SMBSignInTests: XCTestCase {
    func testStatusDecidesBeforeErrno() {
        // With the errno libsmb2 maps each status to.
        let rows: [(status: UInt32, errno: Int32, expected: SourceFailure)] = [
            (0xC000_006D, ECONNREFUSED, .notAuthenticated), // LOGON_FAILURE, also a refused guest session
            (0xC000_0234, EIO, .noPermission), // ACCOUNT_LOCKED_OUT
            (0xC000_0072, EACCES, .noPermission), // ACCOUNT_DISABLED
            (0xC000_0071, EACCES, .notAuthenticated), // PASSWORD_EXPIRED
            (0xC000_0224, EIO, .notAuthenticated), // PASSWORD_MUST_CHANGE
            (0xC000_006F, EACCES, .noPermission), // INVALID_LOGON_HOURS
            (0xC000_00CC, ENOENT, .missing), // BAD_NETWORK_NAME at tree connect
            (0xC000_0022, EACCES, .noPermission), // ACCESS_DENIED at tree connect
        ]
        for row in rows {
            XCTAssertEqual(SMBSignIn.failure(status: row.status, errno: row.errno), row.expected,
                           String(format: "status 0x%08x", row.status))
        }
    }

    func testWithoutStatusTheConnectionErrnoDecides() {
        for code in [ENOTCONN, ETIMEDOUT, ECONNREFUSED, ECONNRESET, EHOSTUNREACH] {
            XCTAssertEqual(SMBSignIn.failure(status: 0, errno: code), .serverUnreachable, "errno \(code)")
        }
        XCTAssertEqual(SMBSignIn.failure(status: 0, errno: EACCES), .noPermission)
        XCTAssertEqual(SMBSignIn.failure(status: 0, errno: EIO), .unknown(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        // A refused login is never mistaken for an unreachable server.
        XCTAssertNotEqual(SMBSignIn.failure(status: 0xC000_006D, errno: ENOTCONN), .serverUnreachable)
    }

    func testDiskSharesOnly() {
        let listed: [(name: String, type: UInt32)] = [
            ("Media", 0), ("IPC$", 0x8000_0003), ("ADMIN$", 0x8000_0000), ("print$", 0), ("C$", 0x8000_0000),
            ("Laser", 1), ("Device", 2), ("Pipe", 3), ("Scratch", 0x4000_0000), ("Hidden", 0x8000_0000),
            ("Photos", 0), ("", 0), ("a/b", 0),
        ]
        XCTAssertEqual(SMBSignIn.diskShareNames(listed), ["Media", "Scratch", "Photos"])
    }
}
