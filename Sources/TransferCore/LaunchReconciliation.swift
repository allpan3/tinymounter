import Foundation

/// Finishes the domain steps that a crash interrupted. The app runs the steps.
public enum LaunchReconciliation {
    public enum Step: Equatable, Sendable {
        /// Only for a registered domain; the app removes it with `.removeAll`.
        case removeDomain(String)
        /// A catalog that is already gone counts as deleted.
        case deleteCatalog(String)
        case deleteRecord(UUID)
        case clearRetiredDomain(record: UUID)
        /// `NSFileProviderManager.add` with the record's domain ID and name; it is idempotent.
        case addDomain(record: UUID)
    }

    public struct Plan: Equatable, Sendable {
        /// Each sequence runs in order and stops at its first failure; the others still run.
        public let sequences: [[Step]]
        /// Registered domains that no record names: log them, never remove them.
        public let unknownDomains: [String]
    }

    /// `catalogs` and `domains` are domain IDs. Unreadable settings give no steps.
    public static func plan(records: Result<[LocationRecord], any Error>, catalogs: Set<String>,
                            domains: Set<String>) -> Plan {
        guard case .success(let records) = records else { return Plan(sequences: [], unknownDomains: []) }
        var named = Set<String>()
        var sequences: [[Step]] = []
        for record in records {
            named.insert(record.domainID)
            var steps: [Step] = []
            if let retired = record.retiredDomainID {
                named.insert(retired)
                if domains.contains(retired) { steps.append(.removeDomain(retired)) }
                steps.append(.deleteCatalog(retired))
                if !record.removing { steps.append(.clearRetiredDomain(record: record.id)) }
            }
            if record.removing {
                if domains.contains(record.domainID) {
                    steps.append(.removeDomain(record.domainID))
                }
                steps += [.deleteCatalog(record.domainID), .deleteRecord(record.id)]
            } else {
                steps.append(.addDomain(record: record.id))
            }
            sequences.append(steps)
        }
        // A crash between creating a catalog and saving its record leaves the catalog alone.
        sequences += catalogs.subtracting(named).sorted().map { [.deleteCatalog($0)] }
        return Plan(sequences: sequences, unknownDomains: domains.subtracting(named).sorted())
    }
}
