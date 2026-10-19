import Foundation

/// The folder enumerator's first page (plan §5). Later pages come from the catalog only.
public enum FirstPage {
    /// A listing older than this is listed again in the background.
    public static let relistAge: TimeInterval = 60
    public static let listingWait = Duration.seconds(5)

    public enum Action: Equatable, Sendable {
        /// Page the catalog now. With `relist`, also send `list` and don't wait for it.
        case serve(relist: Bool)
        /// Send `list`, wait at most `listingWait`, then follow `afterListing`.
        case listFirst
        case fail(SourceFailure)
    }

    public enum Outcome {
        case listed
        /// The reply's error, already in the Cocoa or File Provider domain.
        case failed(any Error)
        /// The app still finishes the listing, then signals the working set.
        case deadline
    }

    /// `listGen` and `listedAt` are the folder row's.
    public static func action(listGen: Int64?, listedAt: Date?, readerConnected: Bool, now: Date,
                              requiresListing: Bool = false) -> Action {
        guard listGen != nil else { return readerConnected ? .listFirst : .fail(.serverUnreachable) }
        if requiresListing { return .serve(relist: readerConnected) }
        guard readerConnected, let listedAt else { return .serve(relist: readerConnected) }
        let age = now.timeIntervalSince(listedAt)
        // A clock set back makes an old listing look new, so a listing in the future is old too.
        return .serve(relist: age > relistAge || age < 0)
    }

    /// nil: page the catalog. Otherwise finish the enumeration with the error.
    public static func afterListing(_ outcome: Outcome) -> (any Error)? {
        switch outcome {
        case .listed: nil
        case .failed(let error): error
        case .deadline: SourceFailure.serverUnreachable
        }
    }
}
