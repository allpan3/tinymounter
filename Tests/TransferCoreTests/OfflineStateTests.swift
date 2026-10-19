import Foundation
import XCTest
@testable import TransferCore

final class OfflineStateTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 123)

    func testPartialContentDoesNotBecomeAvailableFromLogicalSize() {
        XCTAssertEqual(state(status: .notDownloaded), .requested)
        XCTAssertEqual(state(status: .notDownloaded, downloading: true), .updateInProgress)
        XCTAssertEqual(state(status: nil), .requested)
    }

    func testAvailableRequiresCompleteCurrentMatchingMetadata() {
        XCTAssertEqual(state(), .availableOffline)
        XCTAssertEqual(state(status: .downloaded), .updateInProgress)
        XCTAssertEqual(state(downloading: true), .updateInProgress)
        XCTAssertEqual(state(size: 72), .updateInProgress)
        XCTAssertEqual(state(modified: date.addingTimeInterval(1)), .updateInProgress)
    }

    func testMissingOrNonProviderMetadataCannotRetainAvailable() {
        XCTAssertEqual(state(ubiquitous: false), .requested)
        XCTAssertEqual(state(ubiquitous: nil), .requested)
        XCTAssertEqual(state(downloading: nil), .requested)
        XCTAssertEqual(state(size: nil), .requested)
        XCTAssertEqual(OfflineState(status: .current, downloading: false, ubiquitous: true, size: 73,
                                    modified: nil, expectedSize: 73, expectedModified: date), .requested)
    }

    func testCompleteEmptyFileIsAvailableButEmptyPlaceholderIsNot() {
        XCTAssertEqual(OfflineState(status: .current, downloading: false, ubiquitous: true, size: 0,
                                    modified: date, expectedSize: 0, expectedModified: date), .availableOffline)
        XCTAssertEqual(OfflineState(status: .notDownloaded, downloading: false, ubiquitous: true, size: 0,
                                    modified: date, expectedSize: 0, expectedModified: date), .requested)
    }

    private func state(status: URLUbiquitousItemDownloadingStatus? = .current, downloading: Bool? = false,
                       ubiquitous: Bool? = true, size: Int? = 73, modified: Date = Date(timeIntervalSince1970: 123)) -> OfflineState {
        OfflineState(status: status, downloading: downloading, ubiquitous: ubiquitous, size: size,
                     modified: modified, expectedSize: 73, expectedModified: date)
    }
}
