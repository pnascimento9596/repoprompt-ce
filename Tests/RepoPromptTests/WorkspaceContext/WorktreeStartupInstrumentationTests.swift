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

            let automatic = WorktreeStartupContext(agentSessionID: UUID())
            XCTAssertEqual(automatic.servingControl, .automatic)
            let forced = WorktreeStartupContext(
                agentSessionID: UUID(),
                flags: .init(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                ),
                servingControl: .forceFullCrawl
            )
            XCTAssertEqual(forced.servingControl, .forceFullCrawl)
            XCTAssertTrue(forced.flags.serveDiffSeededWorktreeStartup)
        }

        func testScopedControlPreparesExactLoadedRootAndRejectsStaleScopeBeforeLease() async throws {
            let repositories = try ReviewGitRepositoryFixture(name: #function)
            let root = try repositories.makeRepository(
                named: "repository",
                files: ["Sources/App.swift": "struct ScopedControl {}\n"]
            )
            defer { repositories.cleanup() }

            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let store = WorkspaceFileContextStore()
            let loadedRoot = try await store.loadRoot(path: root.path)
            let exactScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 501,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: loadedRoot.id
            )

            let prepared = try await diagnostics.setFlagsPreparingBaseSnapshot(
                scope: exactScope,
                observe: false,
                serve: true,
                forceFullCrawl: false,
                expiresSeconds: 120,
                store: store,
                expectedStandardizedRootPath: loadedRoot.standardizedFullPath
            )
            XCTAssertTrue(prepared.baseSnapshotPrepared)
            let snapshotIdentity = try XCTUnwrap(prepared.baseSnapshotIdentity)
            XCTAssertFalse(snapshotIdentity.sha256.isEmpty)
            XCTAssertEqual(snapshotIdentity.searchABI, .current)
            XCTAssertEqual(prepared.control.route.name, "diffSeedServing")
            XCTAssertEqual(try diagnostics.reset(scope: exactScope)["control_count"], 1)

            let crossRootScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 502,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: loadedRoot.id
            )
            do {
                _ = try await diagnostics.setFlagsPreparingBaseSnapshot(
                    scope: crossRootScope,
                    observe: true,
                    serve: false,
                    forceFullCrawl: false,
                    expiresSeconds: 120,
                    store: store,
                    expectedStandardizedRootPath: root.deletingLastPathComponent().path
                )
                XCTFail("A mismatched loaded-root path must not create a benchmark control.")
            } catch {
                XCTAssertEqual(
                    error as? DebugWorktreeStartupBenchmarkError,
                    .baseSnapshotUnavailable(.init(
                        reason: .failed,
                        stage: .loadedRootValidation,
                        cause: "stale_currentness"
                    ))
                )
            }
            XCTAssertEqual(try diagnostics.reset(scope: crossRootScope)["control_count"], 0)

            await store.unloadRoot(id: loadedRoot.id)
            let staleScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 503,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: loadedRoot.id
            )
            do {
                _ = try await diagnostics.setFlagsPreparingBaseSnapshot(
                    scope: staleScope,
                    observe: true,
                    serve: false,
                    forceFullCrawl: false,
                    expiresSeconds: 120,
                    store: store,
                    expectedStandardizedRootPath: loadedRoot.standardizedFullPath
                )
                XCTFail("An unloaded root must not create a benchmark control.")
            } catch {
                XCTAssertEqual(
                    error as? DebugWorktreeStartupBenchmarkError,
                    .baseSnapshotUnavailable(.init(
                        reason: .failed,
                        stage: .loadedRootValidation,
                        cause: "stale_currentness"
                    ))
                )
            }
            XCTAssertEqual(try diagnostics.reset(scope: staleScope)["control_count"], 0)

            let forcedScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 504,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let forced = try await diagnostics.setFlagsPreparingBaseSnapshot(
                scope: forcedScope,
                observe: true,
                serve: true,
                forceFullCrawl: true,
                expiresSeconds: 120,
                store: store,
                expectedStandardizedRootPath: "/not-loaded"
            )
            XCTAssertFalse(forced.baseSnapshotPrepared)
            XCTAssertNil(forced.baseSnapshotIdentity)
            XCTAssertEqual(forced.control.route.name, "forcedFullCrawl")
            XCTAssertEqual(try diagnostics.reset(scope: forcedScope)["control_count"], 1)
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

        func testShadowCountersAreBoundedAndPathFree() {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupInstrumentation.recordInventoryComparison(matched: true)
            WorktreeStartupInstrumentation.recordInventoryComparison(matched: false)
            WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                matched: true,
                baseEntryCount: 90,
                overlayEntryCount: 3,
                tombstoneCount: 2
            )
            WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                matched: false,
                baseEntryCount: 89,
                overlayEntryCount: 4,
                tombstoneCount: 3
            )

            let snapshot = WorktreeStartupInstrumentation.snapshot()
            let counters = snapshot.shadow
            XCTAssertEqual(counters.inventoryComparisons, 2)
            XCTAssertEqual(counters.inventoryMatches, 1)
            XCTAssertEqual(counters.inventoryMismatches, 1)
            XCTAssertEqual(counters.projectedSearchComparisons, 2)
            XCTAssertEqual(counters.projectedSearchMatches, 1)
            XCTAssertEqual(counters.projectedSearchMismatches, 1)
            XCTAssertEqual(counters.latestBaseEntryCount, 89)
            XCTAssertEqual(counters.latestOverlayEntryCount, 4)
            XCTAssertEqual(counters.latestTombstoneCount, 3)
            XCTAssertEqual(snapshot.fallbackCounts[.projectedSearchMismatch], 1)
        }

        func testSeedCountersAreBoundedPathFreeAndCountFallbackOnce() {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: true)
            WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: false)
            WorktreeStartupInstrumentation.recordSeedReplay(
                acceptedPayloadCount: Int.max,
                acceptedEventCount: 7,
                initializationWatermarkDelta: 5,
                serviceSequenceDelta: 4,
                changedPathCount: 3
            )
            WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(used: false)
            WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(used: true)
            WorktreeStartupInstrumentation.recordSeedProjectedPreparation(
                baseEntryCount: 90,
                overlayEntryCount: 3,
                tombstoneCount: 2
            )
            WorktreeStartupInstrumentation.recordSeedFullCrawlFallback()

            let seed = WorktreeStartupInstrumentation.snapshot().seed
            XCTAssertEqual(seed.receiptJournalCutPresent, 1)
            XCTAssertEqual(seed.receiptJournalCutAbsent, 1)
            XCTAssertEqual(seed.acceptedReplayPayloadCount, 1_000_000)
            XCTAssertEqual(seed.acceptedReplayEventCount, 7)
            XCTAssertEqual(seed.latestInitializationWatermarkDelta, 5)
            XCTAssertEqual(seed.latestServiceSequenceDelta, 4)
            XCTAssertEqual(seed.latestReplayChangedPathCount, 3)
            XCTAssertEqual(seed.metadataRevalidationChecks, 2)
            XCTAssertEqual(seed.metadataRevalidationUses, 1)
            XCTAssertEqual(seed.latestProjectedBaseEntryCount, 90)
            XCTAssertEqual(seed.latestProjectedOverlayEntryCount, 3)
            XCTAssertEqual(seed.latestProjectedTombstoneCount, 2)
            XCTAssertEqual(seed.fullCrawlFallbackCount, 1)
        }

        func testBenchmarkTokenRejectsCrossRootExternalDestinationAndReplay() throws {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 91,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(
                scope: scope,
                observe: true,
                serve: true,
                forceFullCrawl: false,
                expiresSeconds: 120
            )
            let arm = try diagnostics.arm(
                expectedStart: expected,
                controlID: control.controlID,
                scenario: "clean_same_tree",
                invocation: 1,
                ordinal: 1,
                warmup: false,
                expiresSeconds: 120
            )
            let valid = benchmarkValidatedStart(expected: expected)
            var wrongRoot = benchmarkValidatedStart(expected: expected)
            wrongRoot = DebugWorktreeStartupBenchmarkValidatedStart(
                scope: DebugWorktreeStartupBenchmarkScope(
                    windowID: scope.windowID,
                    workspaceID: scope.workspaceID,
                    contextID: scope.contextID,
                    rootID: UUID()
                ),
                logicalRootID: UUID(),
                standardizedLogicalRootPath: valid.standardizedLogicalRootPath,
                repositoryID: valid.repositoryID,
                repositoryKey: valid.repositoryKey,
                requestedBranch: valid.requestedBranch,
                requestedBaseRef: valid.requestedBaseRef,
                standardizedDestinationPath: valid.standardizedDestinationPath,
                standardizedAppManagedContainerPath: valid.standardizedAppManagedContainerPath,
                destinationID: valid.destinationID,
                agentSessionID: valid.agentSessionID,
                startAttemptID: valid.startAttemptID
            )
            XCTAssertThrowsError(try diagnostics.consume(token: arm.token, validatedStart: wrongRoot))

            let external = DebugWorktreeStartupBenchmarkValidatedStart(
                scope: valid.scope,
                logicalRootID: valid.logicalRootID,
                standardizedLogicalRootPath: valid.standardizedLogicalRootPath,
                repositoryID: valid.repositoryID,
                repositoryKey: valid.repositoryKey,
                requestedBranch: valid.requestedBranch,
                requestedBaseRef: valid.requestedBaseRef,
                standardizedDestinationPath: "/tmp/external-worktree",
                standardizedAppManagedContainerPath: valid.standardizedAppManagedContainerPath,
                destinationID: valid.destinationID,
                agentSessionID: valid.agentSessionID,
                startAttemptID: valid.startAttemptID
            )
            XCTAssertThrowsError(try diagnostics.consume(token: arm.token, validatedStart: external))
            XCTAssertEqual(try diagnostics.consume(token: arm.token, validatedStart: valid).correlationID, arm.correlationID)
            XCTAssertThrowsError(try diagnostics.consume(token: arm.token, validatedStart: valid))
        }

        func testDisablingBenchmarkGateImmediatelyRevokesArmedToken() throws {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let scope = DebugWorktreeStartupBenchmarkScope(windowID: 92, workspaceID: UUID(), contextID: UUID(), rootID: UUID())
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(scope: scope, observe: true, serve: false, forceFullCrawl: false, expiresSeconds: 120)
            let arm = try diagnostics.arm(expectedStart: expected, controlID: control.controlID, scenario: "clean_same_tree", invocation: 1, ordinal: 1, warmup: false, expiresSeconds: 120)
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false)
            XCTAssertThrowsError(try diagnostics.preflight(token: arm.token)) { error in
                XCTAssertEqual(error as? DebugWorktreeStartupBenchmarkError, .disabled)
            }
            XCTAssertThrowsError(try diagnostics.consume(token: arm.token, validatedStart: benchmarkValidatedStart(expected: expected)))
        }

        func testRoutingProvenanceRejectsForgedWindowAndContext() throws {
            let connectionID = UUID()
            let workspaceID = UUID()
            let contextID = UUID()
            let provenance = DebugWorktreeStartupBenchmarkRoutingProvenance(
                connectionID: connectionID,
                boundWindowID: 7,
                boundWorkspaceID: workspaceID,
                boundContextID: contextID
            )
            XCTAssertNoThrow(try provenance.authorize(connectionID: connectionID, windowID: 7, hiddenWindowID: 7, workspaceID: workspaceID, contextID: contextID, benchmarkContextID: contextID))
            XCTAssertThrowsError(try provenance.authorize(connectionID: connectionID, windowID: 8, hiddenWindowID: 7, workspaceID: workspaceID, contextID: contextID, benchmarkContextID: contextID))
            XCTAssertThrowsError(try provenance.authorize(connectionID: connectionID, windowID: 7, hiddenWindowID: 7, workspaceID: workspaceID, contextID: UUID(), benchmarkContextID: contextID))
        }

        func testBenchmarkMetricsAreCorrelationIsolatedAndAmbiguousCodemapIsUnavailable() {
            WorktreeStartupInstrumentation.resetForTesting()
            let tagA = benchmarkMetricTag(correlationID: UUID())
            let tagB = benchmarkMetricTag(correlationID: UUID())
            WorktreeStartupInstrumentation.recordBenchmarkFilesystemWork(tag: tagA, durationMicroseconds: 11, itemCount: 2)
            WorktreeStartupInstrumentation.recordBenchmarkFilesystemWork(tag: tagB, durationMicroseconds: 99, itemCount: 50)
            WorktreeStartupInstrumentation.recordBenchmarkContentReadWork(tag: tagA, waitMicroseconds: 3, executionMicroseconds: 7, overloaded: false)
            WorktreeStartupInstrumentation.recordBenchmarkContentReadWork(tag: tagB, waitMicroseconds: 30, executionMicroseconds: 70, overloaded: false)
            WorktreeStartupInstrumentation.recordBenchmarkCodemapWork(tag: tagA, durations: nil, buildPerformed: false, exactlyAttributed: false)
            let snapshot = WorktreeStartupInstrumentation.benchmarkMetricSnapshot(for: tagA)
            XCTAssertEqual(snapshot.filesystemDurationMicroseconds, 11)
            XCTAssertEqual(snapshot.filesystemItemCount, 2)
            XCTAssertEqual(snapshot.contentReadWaitMicroseconds, 3)
            XCTAssertEqual(snapshot.contentReadExecutionMicroseconds, 7)
            XCTAssertEqual(snapshot.codemapAttribution, .unavailable)
        }

        func testReceiptDecisionBufferCapsAt128AndEvictsOldestTerminalBeforeNonterminal() {
            WorktreeStartupInstrumentation.resetForTesting()
            let oldestTerminal = UUID()
            let oldestNonterminal = UUID()
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: oldestTerminal,
                decision: .init(),
                terminal: true
            )
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: oldestNonterminal,
                decision: .init()
            )
            for _ in 0 ..< 126 {
                WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                    correlationID: UUID(),
                    decision: .init()
                )
            }
            let newest = UUID()
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: newest,
                decision: .init()
            )

            let snapshot = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(snapshot.receiptDecisions.count, 128)
            XCTAssertEqual(snapshot.receiptDecisionEvictionCount, 1)
            XCTAssertTrue(snapshot.receiptDecisions.contains { $0.correlationID == oldestNonterminal })
            XCTAssertTrue(snapshot.receiptDecisions.contains { $0.correlationID == newest })
            XCTAssertFalse(snapshot.receiptDecisions.contains { $0.correlationID == oldestTerminal })

            WorktreeStartupInstrumentation.resetForTesting()
            let oldest = UUID()
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: oldest,
                decision: .init()
            )
            for _ in 0 ..< 128 {
                WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                    correlationID: UUID(),
                    decision: .init()
                )
            }
            XCTAssertFalse(
                WorktreeStartupInstrumentation.receiptDecisions().contains { $0.correlationID == oldest }
            )
        }

        func testReceiptDecisionStagesAreCorrelationIsolatedAndAggregateOnce() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            let first = UUID()
            let second = UUID()
            var creation = WorktreeStartupInstrumentation.ReceiptCreationDecision()
            creation.sourceLayoutState = .linkedWorktree
            creation.outcome = .receiptEmitted
            creation.receiptEmitted = true
            var coordinator = WorktreeStartupInstrumentation.ReceiptCoordinatorDecision()
            coordinator.createResultReceiptCount = 1
            coordinator.hintCount = 1
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: first,
                decision: creation
            )
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: first,
                decision: coordinator
            )
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: second,
                decision: .init()
            )

            let firstDecision = try XCTUnwrap(
                WorktreeStartupInstrumentation.receiptDecisions(correlationID: first).first
            )
            XCTAssertEqual(firstDecision.creation, creation)
            XCTAssertEqual(firstDecision.coordinator, coordinator)
            XCTAssertNil(firstDecision.projection)
            XCTAssertEqual(firstDecision.creationAttemptCount, 1)
            XCTAssertFalse(firstDecision.ambiguousOrDuplicate)
            XCTAssertEqual(WorktreeStartupInstrumentation.receiptDecisions().count, 2)
        }

        func testReceiptDecisionDuplicateConflictInvalidatesAndFirstTerminalWins() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            let correlationID = UUID()
            var coordinator = WorktreeStartupInstrumentation.ReceiptCoordinatorDecision()
            coordinator.bindingCount = 1
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: correlationID,
                decision: coordinator,
                terminal: true
            )
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: correlationID,
                decision: coordinator,
                terminal: true
            )
            XCTAssertFalse(try XCTUnwrap(
                WorktreeStartupInstrumentation.receiptDecisions(correlationID: correlationID).first
            ).ambiguousOrDuplicate)

            var conflicting = coordinator
            conflicting.hintCount = 1
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: correlationID,
                decision: conflicting
            )
            WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                correlationID: correlationID,
                decision: .init(),
                terminal: true
            )
            let decision = try XCTUnwrap(
                WorktreeStartupInstrumentation.receiptDecisions(correlationID: correlationID).first
            )
            XCTAssertTrue(decision.ambiguousOrDuplicate)
            XCTAssertEqual(decision.coordinator, coordinator)
            XCTAssertNotNil(decision.consumption)
            XCTAssertEqual(decision.terminalStage, .coordinator)

            let duplicateCreationID = UUID()
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: duplicateCreationID,
                decision: .init()
            )
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: duplicateCreationID,
                decision: .init()
            )
            let duplicate = try XCTUnwrap(
                WorktreeStartupInstrumentation.receiptDecisions(correlationID: duplicateCreationID).first
            )
            XCTAssertTrue(duplicate.ambiguousOrDuplicate)
            XCTAssertEqual(duplicate.creationAttemptCount, 2)
        }

        func testReceiptDecisionSchemaV4ExportIsTerminalBoundedAndPathFree() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 611,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(
                scope: scope,
                observe: true,
                serve: true,
                forceFullCrawl: false,
                expiresSeconds: 120
            )
            let arm = try diagnostics.arm(
                expectedStart: expected,
                controlID: control.controlID,
                scenario: "receipt_path_privacy",
                invocation: 1,
                ordinal: 1,
                warmup: false,
                expiresSeconds: 120
            )
            let consumed = try diagnostics.consume(
                token: arm.token,
                validatedStart: benchmarkValidatedStart(expected: expected)
            )
            let pathSentinel = "/private/receipt-path-sentinel"
            var creation = WorktreeStartupInstrumentation.ReceiptCreationDecision()
            creation.sourceLayoutState = .linkedWorktree
            creation.sourceCommonDirectoryDigest = WorktreeStartupInstrumentation.receiptDecisionDigest(
                pathSentinel,
                domain: .commonDirectory
            )
            creation.outcome = .receiptEmitted
            creation.receiptEmitted = true
            creation.witnessStartEventID = 100
            creation.witnessEndEventID = 200
            creation.witnessStartAcceptedCallbackWatermark = 2
            creation.witnessEndAcceptedCallbackWatermark = 4
            creation.witnessAcceptedCallbackCount = 4
            creation.witnessAcceptedEventCount = 300
            creation.witnessAcceptedDestinationEventCount = 257
            creation.witnessAcceptedNonDestinationEventCount = 43
            creation.witnessMustScanSubDirs = false
            creation.witnessRootChanged = false
            creation.witnessUserDropped = false
            creation.witnessKernelDropped = false
            creation.witnessEventIDsWrapped = false
            creation.witnessEventIDRegressed = false
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: arm.correlationID,
                decision: creation
            )
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: arm.correlationID,
                decision: .init()
            )
            WorktreeStartupInstrumentation.recordReceiptProjectionDecision(
                correlationID: arm.correlationID,
                decision: .init()
            )
            var consumption = WorktreeStartupInstrumentation.ReceiptConsumptionDecision()
            consumption.finalObservation = .eligible
            consumption.selectedRoute = .diffSeedServing
            consumption.fullCrawlPerformed = false
            WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                correlationID: arm.correlationID,
                decision: consumption
            )
            let context = WorktreeStartupContext(
                agentSessionID: consumed.metricTag.agentSessionID,
                correlationID: arm.correlationID,
                flags: consumed.flags,
                servingControl: consumed.servingControl
            )
            WorktreeStartupInstrumentation.record(.rootReady, context: context, route: .diffSeedServing)

            let payload = try diagnostics.snapshotPayload(
                scope: scope,
                correlationID: arm.correlationID,
                export: true
            )
            XCTAssertEqual(payload["schema_version"] as? Int, 4)
            XCTAssertEqual(payload["bounded"] as? Bool, true)
            XCTAssertEqual(payload["contains_paths"] as? Bool, false)
            XCTAssertEqual(payload["receipt_decision_count"] as? Int, 1)
            XCTAssertEqual(payload["terminal_receipt_decision_count"] as? Int, 1)
            XCTAssertEqual(payload["receipt_decision_buffer_evicted"] as? Bool, false)
            XCTAssertEqual(payload["receipt_decision_ambiguous"] as? Bool, false)
            let sample = try XCTUnwrap(payload["sample"] as? [String: Any])
            XCTAssertEqual(sample["valid"] as? Bool, true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let exported = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(exported.contains(pathSentinel))
            XCTAssertTrue(exported.contains("source_common_directory_digest"))
            XCTAssertTrue(exported.contains("\"witness_start_event_id\":100"))
            XCTAssertTrue(exported.contains("\"witness_end_event_id\":200"))
            XCTAssertTrue(exported.contains("\"witness_accepted_destination_event_count\":257"))
            XCTAssertTrue(exported.contains("\"witness_accepted_non_destination_event_count\":43"))
            XCTAssertTrue(exported.contains("\"witness_user_dropped\":false"))
        }

        func testReceiptDecisionEvictionInvalidatesBenchmarkSampleAndResetClearsState() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 612,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(
                scope: scope,
                observe: true,
                serve: false,
                forceFullCrawl: false,
                expiresSeconds: 120
            )
            let arm = try diagnostics.arm(
                expectedStart: expected,
                controlID: control.controlID,
                scenario: "receipt_eviction",
                invocation: 1,
                ordinal: 1,
                warmup: false,
                expiresSeconds: 120
            )
            _ = try diagnostics.consume(
                token: arm.token,
                validatedStart: benchmarkValidatedStart(expected: expected)
            )
            WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                correlationID: arm.correlationID,
                decision: .init()
            )
            for _ in 0 ..< 128 {
                WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                    correlationID: UUID(),
                    decision: .init()
                )
            }

            let payload = try diagnostics.snapshotPayload(
                scope: scope,
                correlationID: arm.correlationID,
                export: false
            )
            XCTAssertEqual(payload["receipt_decision_buffer_evicted"] as? Bool, true)
            XCTAssertEqual((payload["sample"] as? [String: Any])?["valid"] as? Bool, false)

            WorktreeStartupInstrumentation.resetForTesting()
            let resetSnapshot = WorktreeStartupInstrumentation.snapshot()
            XCTAssertTrue(resetSnapshot.receiptDecisions.isEmpty)
            XCTAssertEqual(resetSnapshot.receiptDecisionEvictionCount, 0)
        }

        private func benchmarkExpectedStart(
            scope: DebugWorktreeStartupBenchmarkScope
        ) -> DebugWorktreeStartupBenchmarkExpectedStart {
            let root = "/benchmark/root-\(scope.rootID.uuidString)"
            let layout = GitRepositoryLayout(
                workTreeRoot: URL(fileURLWithPath: root),
                dotGitPath: URL(fileURLWithPath: root + "/.git"),
                gitDir: URL(fileURLWithPath: root + "/.git"),
                commonDir: URL(fileURLWithPath: root + "/.git"),
                isWorktree: false
            )
            let repository = GitWorktreeIdentity.repositoryIdentity(commonGitDir: layout.commonDir, mainWorktreeRoot: layout.workTreeRoot)
            return DebugWorktreeStartupBenchmarkExpectedStart(
                rootIdentity: DebugWorktreeStartupBenchmarkRootIdentity(
                    scope: scope,
                    standardizedLogicalRootPath: root,
                    repositoryID: repository.repositoryID,
                    repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout)
                ),
                requestedBranch: "bench",
                requestedBaseRef: "HEAD"
            )
        }

        private func benchmarkValidatedStart(
            expected: DebugWorktreeStartupBenchmarkExpectedStart
        ) -> DebugWorktreeStartupBenchmarkValidatedStart {
            let container = "/benchmark/.repoprompt-worktrees/root"
            return DebugWorktreeStartupBenchmarkValidatedStart(
                scope: expected.rootIdentity.scope,
                logicalRootID: expected.rootIdentity.scope.rootID,
                standardizedLogicalRootPath: expected.rootIdentity.standardizedLogicalRootPath,
                repositoryID: expected.rootIdentity.repositoryID,
                repositoryKey: expected.rootIdentity.repositoryKey,
                requestedBranch: expected.requestedBranch,
                requestedBaseRef: expected.requestedBaseRef,
                standardizedDestinationPath: container + "/agent-session",
                standardizedAppManagedContainerPath: container,
                destinationID: "wt-test",
                agentSessionID: UUID(),
                startAttemptID: UUID()
            )
        }

        private func benchmarkMetricTag(correlationID: UUID) -> WorktreeStartupInstrumentation.BenchmarkMetricTag {
            WorktreeStartupInstrumentation.BenchmarkMetricTag(
                correlationID: correlationID,
                contextID: UUID(),
                agentSessionID: UUID(),
                logicalRootID: UUID(),
                repositoryID: "repo",
                destinationID: "worktree"
            )
        }
    }
#endif
