import Darwin
import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessSearchServiceTests: XCTestCase {
    func testCatalogTruncationRequiresEligibleOverflowEntry() throws {
        try withFixture { fixture in
            try fixture.write("only.txt", contents: "visible")
            try fixture.write(".git/ignored.txt", contents: "ignored")

            let complete = try HeadlessFileCatalog().scan(roots: [fixture.root], maxEntries: 2)
            XCTAssertEqual(complete.entries.count, 2)
            XCTAssertEqual(complete.entryLimit, 2)
            XCTAssertFalse(complete.wasTruncated)

            try fixture.write("overflow.txt", contents: "visible")
            let truncated = try HeadlessFileCatalog().scan(roots: [fixture.root], maxEntries: 2)
            XCTAssertEqual(truncated.entries.count, 2)
            XCTAssertTrue(truncated.wasTruncated)
        }
    }

    func testBothModeUsesSharedReturnBudgetAndReportsCompleteTotals() throws {
        try withSearchFixture { fixture in
            let result = try HeadlessSearchService().search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: [
                    "pattern": "needle",
                    "mode": "both",
                    "regex": false,
                    "max_results": 2
                ]
            )

            XCTAssertEqual(result.structured["total_path_matches"] as? Int, 1)
            XCTAssertEqual(result.structured["total_content_matches"] as? Int, 4)
            XCTAssertEqual(result.structured["total_matches"] as? Int, 5)
            XCTAssertEqual(result.structured["returned_matches"] as? Int, 2)
            XCTAssertEqual(result.structured["omitted"] as? Int, 3)
            XCTAssertEqual(result.structured["count_only"] as? Bool, false)
            XCTAssertEqual(result.structured["totals_complete"] as? Bool, true)
            XCTAssertEqual(result.structured["totals_are_lower_bounds"] as? Bool, false)

            let pathMatches = try XCTUnwrap(result.structured["path_matches"] as? [[String: Any]])
            let contentMatches = try XCTUnwrap(result.structured["content_matches"] as? [[String: Any]])
            XCTAssertEqual(pathMatches.count + contentMatches.count, 2)
        }
    }

    func testCountOnlyReturnsNoArraysAndReportsOnlyMatchesBeyondMaxResultsAsOmitted() throws {
        try withSearchFixture { fixture in
            let result = try HeadlessSearchService().search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: [
                    "pattern": "needle",
                    "mode": "both",
                    "regex": false,
                    "max_results": 1,
                    "count_only": true
                ]
            )

            XCTAssertEqual(result.structured["total_matches"] as? Int, 5)
            XCTAssertEqual(result.structured["returned_matches"] as? Int, 0)
            XCTAssertEqual(result.structured["omitted"] as? Int, 4)
            XCTAssertEqual(result.structured["count_only"] as? Bool, true)
            XCTAssertEqual((result.structured["path_matches"] as? [[String: Any]])?.count, 0)
            XCTAssertEqual((result.structured["content_matches"] as? [[String: Any]])?.count, 0)
        }
    }

    func testCatalogCapMakesTotalsExplicitLowerBounds() throws {
        try withFixture { fixture in
            try fixture.write("a.txt", contents: "none")
            try fixture.write("b.txt", contents: "none")

            let result = try HeadlessSearchService(maxCatalogEntries: 2).search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: [
                    "pattern": "absent",
                    "mode": "path",
                    "regex": false
                ]
            )

            XCTAssertEqual(result.structured["catalog_entries_scanned"] as? Int, 2)
            XCTAssertEqual(result.structured["catalog_entry_limit"] as? Int, 2)
            XCTAssertEqual(result.structured["catalog_scan_count"] as? Int, 1)
            XCTAssertEqual(result.structured["catalog_truncated"] as? Bool, true)
            XCTAssertEqual(result.structured["totals_complete"] as? Bool, false)
            XCTAssertEqual(result.structured["totals_are_lower_bounds"] as? Bool, true)
            XCTAssertTrue(result.summary.contains("eligible entries remain unscanned"))
        }
    }

    func testCatalogReadFailureMakesTotalsExplicitLowerBounds() throws {
        try withFixture { fixture in
            try fixture.write("unreadable.txt", contents: "needle")
            let unreadable = fixture.directory.appendingPathComponent("unreadable.txt")
            XCTAssertEqual(Darwin.chmod(unreadable.path, 0), 0)
            defer { _ = Darwin.chmod(unreadable.path, S_IRUSR | S_IWUSR) }

            let result = try HeadlessSearchService().search(
                roots: [fixture.root],
                resolver: fixture.resolver,
                arguments: ["pattern": "needle", "mode": "both", "regex": false]
            )

            XCTAssertEqual(result.structured["catalog_skipped_entries"] as? Int, 1)
            XCTAssertEqual(result.structured["totals_complete"] as? Bool, false)
            XCTAssertTrue(result.summary.contains("catalog entry or traversal error"))
        }
    }

    func testDirectoryExpansionRejectsTruncatedSubset() throws {
        try withFixture { fixture in
            try fixture.write("a.txt", contents: "a")
            try fixture.write("b.txt", contents: "b")
            let directory = try fixture.resolver.resolve("Fixture")

            XCTAssertThrowsError(try HeadlessFileCatalog().filesUnder(directory, maxFiles: 1)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Directory expansion exceeded"))
            }
        }
    }

    private func withSearchFixture(_ body: (Fixture) throws -> Void) throws {
        try withFixture { fixture in
            try fixture.write("alpha.txt", contents: "needle\nneedle\n")
            try fixture.write("beta.txt", contents: "needle\n")
            try fixture.write("needle-name.txt", contents: "needle\n")
            try body(fixture)
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptHeadlessSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = HeadlessAllowedRoot(
            id: UUID(),
            name: "Fixture",
            path: directory.path,
            resolvedPath: directory.resolvingSymlinksInPath().standardizedFileURL.path,
            addedAt: Date()
        )
        try body(Fixture(directory: directory, root: root))
    }

    private struct Fixture {
        let directory: URL
        let root: HeadlessAllowedRoot

        var resolver: HeadlessPathResolver {
            HeadlessPathResolver(roots: [root])
        }

        func write(_ relativePath: String, contents: String) throws {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }
}
