@testable import RepoPrompt
import XCTest

final class AgentFileTagWorktreeResolutionTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    @MainActor
    func testBoundWorktreeSuggestionIncludesBranchOnlyFileWithLogicalPath() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { lookupContext },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "BranchOnly")

        XCTAssertTrue(suggestions.contains { $0.relativePath == "Sources/BranchOnly.swift" }, String(describing: suggestions))
        XCTAssertFalse(suggestions.contains { $0.relativePath.contains(".worktrees") }, String(describing: suggestions))
        XCTAssertFalse(suggestions.contains { $0.relativePath.contains(fixture.worktreeRoot.path) }, String(describing: suggestions))
    }

    @MainActor
    func testUnboundSuggestionDoesNotReadHiddenSessionWorktreeRoots() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        _ = await makeLookupContext(fixture: fixture) // Materializes the hidden session worktree root in the store.
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "BranchOnly")

        XCTAssertTrue(suggestions.isEmpty, String(describing: suggestions))
    }

    func testProviderTaggedFileContentReadsWorktreeButDisplaysLogicalPathAndDedupes() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let physicalWorktreePath = fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").path

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/App.swift", physicalWorktreePath],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: lookupContext
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("File: Sources/App.swift"), xml)
        XCTAssertTrue(xml.contains("let origin = \"worktree\""), xml)
        XCTAssertFalse(xml.contains("let origin = \"base\""), xml)
        XCTAssertFalse(xml.contains(fixture.worktreeRoot.path), xml)
        XCTAssertEqual(xml.components(separatedBy: "let origin = \"worktree\"").count - 1, 1, xml)
    }

    func testPromotionLogicalizesStalePhysicalSelectionAndDedupesByEffectivePhysicalPath() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let physicalPath = fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").path
        let logicalPath = fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path
        let staleSelection = StoredSelection(
            selectedPaths: [physicalPath],
            autoCodemapPaths: [physicalPath],
            slices: [physicalPath: [LineRange(start: 1, end: 1)]],
            codemapAutoEnabled: false
        )

        let updated = AgentModeViewModel.selectionByPromotingPathsToFullSelection(
            staleSelection,
            paths: [logicalPath],
            lookupContext: lookupContext
        )

        XCTAssertEqual(updated.selectedPaths, [logicalPath])
        XCTAssertTrue(updated.autoCodemapPaths.isEmpty)
        XCTAssertTrue(updated.slices.isEmpty)
        XCTAssertFalse(updated.selectedPaths.contains { $0.contains(fixture.worktreeRoot.path) })
    }

    @MainActor
    func testPartiallyBoundWorkspaceKeepsUnboundRootSuggestionDisplayRelative() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let unboundRoot = try makeTemporaryRoot(name: "AgentFileTagUnbound")
        try write("let unbound = true\n", to: unboundRoot.appendingPathComponent("Sources/Other.swift"))
        _ = try await fixture.store.loadRoot(path: unboundRoot.path)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { lookupContext },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "Other")
        let suggestion = try XCTUnwrap(suggestions.first { $0.relativePath.contains("Other.swift") })
        let logicalRootQualifiedSuggestions = await service.suggestions(for: "\(fixture.logicalRoot.lastPathComponent)/Sources/App")

        XCTAssertFalse(suggestion.relativePath.hasPrefix("/"), String(describing: suggestions))
        XCTAssertFalse(suggestion.relativePath.contains(unboundRoot.path), String(describing: suggestions))
        XCTAssertTrue(
            logicalRootQualifiedSuggestions.contains { $0.relativePath.contains("Sources/App.swift") },
            String(describing: logicalRootQualifiedSuggestions)
        )
        XCTAssertFalse(
            logicalRootQualifiedSuggestions.contains { $0.relativePath.contains(fixture.worktreeRoot.path) },
            String(describing: logicalRootQualifiedSuggestions)
        )
    }

    func testPartiallyBoundWorkspaceKeepsUnboundRootProviderDisplayRelative() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let unboundRoot = try makeTemporaryRoot(name: "AgentFileTagProviderUnbound")
        let unboundFile = unboundRoot.appendingPathComponent("Sources/Other.swift")
        try write("let unbound = true\n", to: unboundFile)
        _ = try await fixture.store.loadRoot(path: unboundRoot.path)
        let lookupContext = await makeLookupContext(fixture: fixture)

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            [unboundFile.path],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: lookupContext
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("let unbound = true"), xml)
        XCTAssertFalse(xml.contains(unboundRoot.path), xml)
    }

    func testNonWorktreeProviderTaggedFileContentPreservesVisibleWorkspaceBehavior() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        _ = await makeLookupContext(fixture: fixture) // Keep hidden worktree loaded; visible lookups must still ignore it.

        let resolvedVisibleXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/App.swift"],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: .visibleWorkspace
        )
        let visibleXML = try XCTUnwrap(resolvedVisibleXML)
        let hiddenXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/BranchOnly.swift"],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: .visibleWorkspace
        )

        XCTAssertTrue(visibleXML.contains("let origin = \"base\""), visibleXML)
        XCTAssertFalse(visibleXML.contains("let origin = \"worktree\""), visibleXML)
        XCTAssertNil(hiddenXML)
    }

    private func makeBoundFixture(includeBranchOnly: Bool) async throws -> (
        logicalRoot: URL,
        worktreeRoot: URL,
        store: WorkspaceFileContextStore,
        sessionID: UUID,
        binding: AgentSessionWorktreeBinding
    ) {
        let logicalRoot = try makeTemporaryRoot(name: "AgentFileTagLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "AgentFileTagWorktree")
        try write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))
        if includeBranchOnly {
            try write("let branchOnly = true\n", to: worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift"))
        }

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let sessionID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        return (logicalRoot, worktreeRoot, store, sessionID, binding)
    }

    private func makeLookupContext(
        fixture: (
            logicalRoot: URL,
            worktreeRoot: URL,
            store: WorkspaceFileContextStore,
            sessionID: UUID,
            binding: AgentSessionWorktreeBinding
        )
    ) async -> WorkspaceLookupContext {
        await AgentWorkspaceLookupContextResolver.lookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: fixture.sessionID,
                worktreeBindings: [fixture.binding]
            ),
            store: fixture.store
        )
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "bind_test",
            repositoryID: "repo_test",
            repoKey: "repo",
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: "worktree_test",
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/test",
            head: "abcdef",
            visualLabel: "test",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
