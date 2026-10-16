import Foundation
import XCTest
@testable import TransferCore

final class LaunchReconciliationTests: XCTestCase {
    private let server = UUID()

    func testUnreadableSettingsGiveNoSteps() {
        let record = location()
        let plan = LaunchReconciliation.plan(records: .failure(CocoaError(.fileReadCorruptFile)),
                                             catalogs: [record.domainID, UUID().uuidString],
                                             domains: [record.domainID, UUID().uuidString])
        XCTAssertEqual(plan.sequences, [])
        XCTAssertEqual(plan.unknownDomains, [])
    }

    func testEveryRecordIsAddedAndAMissingDomainComesBack() {
        let registered = location(), missing = location()
        let plan = LaunchReconciliation.plan(records: .success([registered, missing]),
                                             catalogs: [registered.domainID, missing.domainID],
                                             domains: [registered.domainID])
        XCTAssertEqual(plan.sequences, [[.addDomain(record: registered.id)], [.addDomain(record: missing.id)]])
        XCTAssertEqual(plan.unknownDomains, [])
    }

    func testARemovalFinishesFromWhereItStopped() {
        var registered = location(), removed = location()
        registered.removing = true
        removed.removing = true
        let plan = LaunchReconciliation.plan(records: .success([registered, removed]),
                                             catalogs: [registered.domainID], domains: [registered.domainID])
        XCTAssertEqual(plan.sequences, [
            [.removeDomain(registered.domainID), .deleteCatalog(registered.domainID),
             .deleteRecord(registered.id)],
            // The domain is gone; a catalog already deleted counts as deleted.
            [.deleteCatalog(removed.domainID), .deleteRecord(removed.id)],
        ])
    }

    func testARetiredDomainIsRemovedBeforeItsReplacementIsAdded() {
        var registered = location(), removed = location()
        let old = UUID().uuidString, older = UUID().uuidString
        registered.retiredDomainID = old
        removed.retiredDomainID = older
        let plan = LaunchReconciliation.plan(records: .success([registered, removed]),
                                             catalogs: [old, registered.domainID, removed.domainID],
                                             domains: [old, registered.domainID])
        XCTAssertEqual(plan.sequences, [
            [.removeDomain(old), .deleteCatalog(old), .clearRetiredDomain(record: registered.id),
             .addDomain(record: registered.id)],
            [.deleteCatalog(older), .clearRetiredDomain(record: removed.id), .addDomain(record: removed.id)],
        ])
        XCTAssertEqual(plan.unknownDomains, [])
    }

    func testARemovalDuringApplyRemovesBothDomains() {
        var record = location()
        let old = UUID().uuidString
        record.retiredDomainID = old
        record.removing = true
        let plan = LaunchReconciliation.plan(records: .success([record]), catalogs: [old, record.domainID],
                                             domains: [old, record.domainID])
        XCTAssertEqual(plan.sequences, [[
            .removeDomain(old), .deleteCatalog(old),
            .removeDomain(record.domainID), .deleteCatalog(record.domainID),
            .deleteRecord(record.id),
        ]])
    }

    func testCatalogsWithoutRecordsAreDeletedAndUnknownDomainsAreLeft() {
        let record = location()
        let unknown = [UUID().uuidString, UUID().uuidString].sorted()
        // An unknown domain's catalog has no record either: it goes, and the domain stays.
        let orphans = [UUID().uuidString, UUID().uuidString, unknown[0]].sorted()
        let plan = LaunchReconciliation.plan(records: .success([record]), catalogs: Set(orphans + [record.domainID]),
                                             domains: Set(unknown + [record.domainID]))
        XCTAssertEqual(plan.sequences, [[.addDomain(record: record.id)]] + orphans.map { [.deleteCatalog($0)] })
        XCTAssertEqual(plan.unknownDomains, unknown)
    }

    func testTwoLocationsOnOneFolderStayIndependent() {
        var removed = location(), kept = location()
        kept.folder = removed.folder
        removed.removing = true
        let plan = LaunchReconciliation.plan(records: .success([removed, kept]),
                                             catalogs: [removed.domainID, kept.domainID],
                                             domains: [removed.domainID, kept.domainID])
        XCTAssertEqual(plan.sequences, [
            [.removeDomain(removed.domainID), .deleteCatalog(removed.domainID),
             .deleteRecord(removed.id)],
            [.addDomain(record: kept.id)],
        ])
    }

    private func location() -> LocationRecord {
        LocationRecord(name: "Movies", serverID: server, folder: RelativePath("Movies")!)
    }
}
