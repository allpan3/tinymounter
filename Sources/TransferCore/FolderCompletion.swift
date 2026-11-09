import Foundation

/// Folder field completion: the folder to list, and the subfolders to suggest in it.
public struct FolderCompletion: Equatable, Sendable {
    public static let maxSuggestions = 50

    /// The typed text before the last "/".
    public let parent: RelativePath
    /// The typed start of a subfolder name: the text after the last "/".
    public let prefix: String

    /// Nil if the typed parent is not a path in the share.
    public init?(typed: String) {
        // Split on scalars: a combining mark after "/" makes one Character with it.
        let scalars = typed.unicodeScalars
        guard let slash = scalars.lastIndex(of: "/") else {
            parent = .root
            prefix = typed
            return
        }
        guard let parent = LocationRecord.normalizedFolder(String(scalars[..<slash])) else { return nil }
        self.parent = parent
        prefix = String(scalars[scalars.index(after: slash)...])
    }

    /// Paths from the share root, in Finder's order. Names that start with "." need a typed ".".
    public func suggestions(from names: [String]) -> [String] {
        let matches = names.filter { name in
            guard prefix.hasPrefix(".") || !name.hasPrefix(".") else { return false }
            return prefix.isEmpty || name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
        }
        return Array(matches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { parent.appending($0)?.string }
            .prefix(Self.maxSuggestions))
    }
}
