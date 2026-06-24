import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorktreeStartupInstrumentationTests: XCTestCase {
        func testObservationAndServingFlagsDefaultDisabledAndServingRequiresObservation() throws {
            let suiteName = "WorktreeStartupInstrumentationTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            XCTAssertEqual(WorktreeStartupFeatureFlags.current(defaults: defaults), .init())
            defaults.set(true, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            XCTAssertFalse(WorktreeStartupFeatureFlags.current(defaults: defaults).serveDiffSeededWorktreeStartup)
            defaults.set(true, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            XCTAssertEqual(
                WorktreeStartupFeatureFlags.current(defaults: defaults),
                .init(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                )
            )
        }

        func testNonGitMaterializationCarriesCorrelationUsesFullCrawlAndIssuesZeroGitCommands() async throws {
            let sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorktreeStartupInstrumentationTests-\(UUID().uuidString)", isDirectory: true)
            let logicalURL = sandbox.appendingPathComponent("logical", isDirectory: true)
            let physicalURL = sandbox.appendingPathComponent("physical", isDirectory: true)
            try FileManager.default.createDirectory(at: logicalURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: physicalURL, withIntermediateDirectories: true)
            try "struct PlainRoot {}\n".write(
                to: physicalURL.appendingPathComponent("Plain.swift"),
                atomically: true,
                encoding: .utf8
            )
            defer { try? FileManager.default.removeItem(at: sandbox) }

            let store = WorkspaceFileContextStore()
            let logicalRecord = try await store.loadRoot(path: logicalURL.path)
            let logicalRoot = WorkspaceRootRef(
                id: logicalRecord.id,
                name: logicalRecord.name,
                fullPath: logicalRecord.standardizedFullPath
            )
            let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalURL.path)
            let binding = AgentSessionWorktreeBinding(
                id: "instrumentation-binding",
                repositoryID: "non-git",
                repoKey: "non-git",
                logicalRootPath: logicalRoot.standardizedFullPath,
                logicalRootName: logicalRoot.name,
                worktreeID: "plain-root",
                worktreeRootPath: physicalRoot.standardizedFullPath,
                source: "test"
            )
            let context = WorktreeStartupContext(
                agentSessionID: UUID(),
                correlationID: UUID(),
                flags: .init()
            )
            let sessionID = UUID()
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            MCPToolWorkCountDiagnostics.resetForTesting()
            WorktreeStartupInstrumentation.resetForTesting()

            try await MCPToolWorkCountDiagnostics.withGitInvocation(operation: "non_git_worktree_startup") {
                let preparation = try await materializer.prepare(
                    sessionID: sessionID,
                    bindings: [binding],
                    startupContext: context
                )
                _ = try await materializer.commit(preparation)
            }

            let git = try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().git.last)
            XCTAssertEqual(git.commandCount, 0, git.commands.joined(separator: "\n"))
            let instrumentation = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(instrumentation.routeCounts, [.fullCrawl: 1])
            XCTAssertEqual(
                instrumentation.events.map(\.correlationID),
                Array(repeating: context.correlationID, count: instrumentation.events.count)
            )
            XCTAssertEqual(instrumentation.events.map(\.phase), [.rootLoadStarted, .rootReady])
            XCTAssertTrue(instrumentation.events.allSatisfy { !$0.observationEnabled && !$0.servingEnabled })

            await materializer.release(sessionID: sessionID)
            await store.unloadRoot(id: logicalRecord.id)
        }
    }
#endif
