import Foundation
import XCTest
@testable import TransferCore

final class FirstPageTests: XCTestCase {
    private enum Listing: CaseIterable { case never, fresh, old }
    private enum Outcome: CaseIterable { case listed, failed, deadline }

    /// What the enumerator finally does: page the catalog, or finish with an error.
    private enum Effect: Equatable {
        case serve(relist: Bool)
        case serverUnreachable
        case listError
        case other
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let listError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)

    func testEveryCombinationGivesThePlannedAction() {
        for listing in Listing.allCases {
            for connected in [true, false] {
                for outcome in Outcome.allCases {
                    let expected: Effect = switch (listing, connected, outcome) {
                    case (.never, true, .listed): .serve(relist: false)
                    case (.never, true, .failed): .listError
                    case (.never, true, .deadline), (.never, false, _): .serverUnreachable
                    case (.fresh, _, _), (.old, false, _): .serve(relist: false)
                    case (.old, true, _): .serve(relist: true)
                    }
                    XCTAssertEqual(effect(listing, connected: connected, outcome: outcome), expected,
                                   "\(listing) connected=\(connected) \(outcome)")
                }
            }
        }
    }

    func testOnlyAListingOlderThanTheAgeOrInTheFutureIsListedAgain() {
        for (age, relist) in [(0.0, false), (FirstPage.relistAge, false), (FirstPage.relistAge + 0.001, true),
                              (-0.001, true), (-3600, true)] {
            XCTAssertEqual(FirstPage.action(listGen: 1, listedAt: now.addingTimeInterval(-age), readerConnected: true,
                                            now: now), .serve(relist: relist), "\(age)")
        }
        XCTAssertEqual(FirstPage.action(listGen: 1, listedAt: nil, readerConnected: true, now: now),
                       .serve(relist: true))
        XCTAssertEqual(FirstPage.action(listGen: 1, listedAt: nil, readerConnected: false, now: now),
                       .serve(relist: false))
        // listed_at alone doesn't make a folder listed: list_gen comes from a complete listing.
        XCTAssertEqual(FirstPage.action(listGen: nil, listedAt: now, readerConnected: true, now: now), .listFirst)
        XCTAssertEqual(FirstPage.listingWait, .seconds(5))
    }

    private func effect(_ listing: Listing, connected: Bool, outcome: Outcome) -> Effect {
        let listGen: Int64? = listing == .never ? nil : 3
        let listedAt: Date? = switch listing {
        case .never: nil
        case .fresh: now.addingTimeInterval(-10)
        case .old: now.addingTimeInterval(-FirstPage.relistAge - 1)
        }
        switch FirstPage.action(listGen: listGen, listedAt: listedAt, readerConnected: connected, now: now) {
        case .serve(let relist): return .serve(relist: relist)
        case .fail(let failure): return failure == .serverUnreachable ? .serverUnreachable : .other
        case .listFirst:
            let reply: FirstPage.Outcome = switch outcome {
            case .listed: .listed
            case .failed: .failed(listError)
            case .deadline: .deadline
            }
            guard let error = FirstPage.afterListing(reply) else { return .serve(relist: false) }
            if error as? SourceFailure == .serverUnreachable { return .serverUnreachable }
            return error as NSError === listError ? .listError : .other
        }
    }
}
