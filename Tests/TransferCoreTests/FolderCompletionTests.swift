import XCTest
@testable import TransferCore

final class FolderCompletionTests: XCTestCase {
    func testSplitsAtTheLastSlash() throws {
        let nested = try XCTUnwrap(FolderCompletion(typed: "/Media/Films/Ac"))
        XCTAssertEqual(nested.parent.string, "Media/Films")
        XCTAssertEqual(nested.prefix, "Ac")
        let trailing = try XCTUnwrap(FolderCompletion(typed: "Media/"))
        XCTAssertEqual(trailing.parent.string, "Media")
        XCTAssertEqual(trailing.prefix, "")
        let top = try XCTUnwrap(FolderCompletion(typed: "Me"))
        XCTAssertTrue(top.parent.isRoot)
        XCTAssertEqual(top.prefix, "Me")
        XCTAssertTrue(try XCTUnwrap(FolderCompletion(typed: "")).parent.isRoot)
        XCTAssertTrue(try XCTUnwrap(FolderCompletion(typed: "/")).parent.isRoot)
        XCTAssertEqual(try XCTUnwrap(FolderCompletion(typed: "Café/\u{301}x")).prefix, "\u{301}x")
    }

    func testRejectsAParentThatIsNotAPath() {
        XCTAssertNil(FolderCompletion(typed: "Media/../x"))
        XCTAssertNil(FolderCompletion(typed: "a//b/c"))
    }

    func testSuggestsMatchingNamesInFinderOrder() throws {
        let names = ["action", "Archive", "Action 10", "Action 9", "Drama", ".hidden", "Ação"]
        let completion = try XCTUnwrap(FolderCompletion(typed: "Films/ac"))
        XCTAssertEqual(completion.suggestions(from: names), ["Films/action", "Films/Action 9", "Films/Action 10"])
        XCTAssertEqual(try XCTUnwrap(FolderCompletion(typed: "Aç")).suggestions(from: names), ["Ação"])
        XCTAssertEqual(try XCTUnwrap(FolderCompletion(typed: "")).suggestions(from: names).count, 6)
        XCTAssertEqual(try XCTUnwrap(FolderCompletion(typed: "Films/.h")).suggestions(from: names), ["Films/.hidden"])
    }

    func testSuggestsAtMostFifty() throws {
        let names = (1...80).map { "Season \($0)" }
        let suggestions = try XCTUnwrap(FolderCompletion(typed: "TV/Season")).suggestions(from: names)
        XCTAssertEqual(suggestions.count, FolderCompletion.maxSuggestions)
        XCTAssertEqual(suggestions.first, "TV/Season 1")
        XCTAssertEqual(suggestions.last, "TV/Season 50")
    }
}
