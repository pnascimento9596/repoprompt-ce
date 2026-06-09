import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class MCPAgentPolicyAdmissionRaceTests: XCTestCase {
    private let manager = ServerNetworkManager.shared
    private let clientName = AgentProviderKind.openCodeMCPClientID

    override func tearDown() async throws {
        #if DEBUG
            await manager.debugResumePendingPolicyRouteInstallation()
            await manager.debugResumePendingPolicyCommit()
        #endif
        try await super.tearDown()
    }

    func testHelperIdentityTransitionWaitsForLateExpectedPIDRegistration() async throws {
        #if DEBUG
            let processTree = try makeSleepingProcessTree()
            defer { processTree.terminate() }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61001
            await installPolicy(runID: runID, windowID: windowID)
            await manager.debugClearRunRoutingHistoryForTesting()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(processTree.childPID),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 1.0,
                    requireRunRouting: false
                )
            }

            let waitStarted = await waitForEvent("pid_gate_wait_started", runID: runID)
            XCTAssertTrue(waitStarted)
            await manager.registerExpectedAgentPID(processTree.parentPID, for: clientName, runID: runID)
            let result = await application.value

            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            XCTAssertEqual(result.windowID, windowID)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let waitCompleted = await waitForEvent("pid_gate_wait_completed", runID: runID)
            let policyApplied = await waitForEvent("policy_applied", runID: runID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(mappedRunID, runID)
            XCTAssertTrue(waitCompleted)
            XCTAssertTrue(policyApplied)
            XCTAssertFalse(pending.contains { $0.runID == runID })

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: processTree.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testWrongPIDCannotConsumeRunPolicy() async throws {
        #if DEBUG
            let expectedTree = try makeSleepingProcessTree()
            let unrelatedTree = try makeSleepingProcessTree()
            defer {
                expectedTree.terminate()
                unrelatedTree.terminate()
            }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61002
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(expectedTree.parentPID, for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(unrelatedTree.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "rejected:ownership_timeout")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: expectedTree.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testWrongClientCannotConsumeOpenCodePolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61003
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: "unrelated-client",
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "fallback")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: getpid())
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testParallelSameProviderRunsConsumeOnlyTheirRunSpecificPIDPolicy() async throws {
        #if DEBUG
            let firstProcess = try makeSleepingProcessTree()
            let secondProcess = try makeSleepingProcessTree()
            defer {
                firstProcess.terminate()
                secondProcess.terminate()
            }

            let firstRunID = UUID()
            let secondRunID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstWindowID = 61004
            let secondWindowID = 61005
            await installPolicy(runID: firstRunID, windowID: firstWindowID)
            await installPolicy(runID: secondRunID, windowID: secondWindowID)
            await manager.registerExpectedAgentPID(firstProcess.parentPID, for: clientName, runID: firstRunID)
            await manager.registerExpectedAgentPID(secondProcess.parentPID, for: clientName, runID: secondRunID)

            async let first = manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: firstConnectionID,
                clientPid: Int(firstProcess.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            async let second = manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: secondConnectionID,
                clientPid: Int(secondProcess.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            let (firstResult, secondResult) = await (first, second)

            XCTAssertEqual(firstResult.outcome, "applied")
            XCTAssertEqual(firstResult.runID, firstRunID)
            XCTAssertEqual(firstResult.windowID, firstWindowID)
            XCTAssertEqual(secondResult.outcome, "applied")
            XCTAssertEqual(secondResult.runID, secondRunID)
            XCTAssertEqual(secondResult.windowID, secondWindowID)
            let mappedFirstRunID = await manager.runIDForConnection(firstConnectionID)
            let mappedSecondRunID = await manager.runIDForConnection(secondConnectionID)
            XCTAssertEqual(mappedFirstRunID, firstRunID)
            XCTAssertEqual(mappedSecondRunID, secondRunID)

            await cleanup(
                runID: firstRunID,
                connectionID: firstConnectionID,
                windowID: firstWindowID,
                expectedPID: firstProcess.parentPID
            )
            await cleanup(
                runID: secondRunID,
                connectionID: secondConnectionID,
                windowID: secondWindowID,
                expectedPID: secondProcess.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testMixedQueuePrioritizesConsumablePIDGatedRunPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61006
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: [],
                oneShot: true,
                reason: "non-gated mixed queue fixture",
                ttl: 10,
                purpose: .unknown,
                requiresExpectedAgentPID: false
            )
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            XCTAssertEqual(pending.count, 1)
            XCTAssertNil(pending.first?.runID)

            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID)
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: getpid())
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testKnownAgentBootstrapTimesOutInsteadOfFallingBackWhenLiveAffinityIsUnusable() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let bootstrapConnectionID = UUID()
            let windowID = 61009
            let sessionKey = "bootstrap-timeout-\(UUID().uuidString)"
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let readiness = await manager.debugBootstrapPolicyAdmissionStatus(
                bootstrapClientName: clientName,
                connectionID: bootstrapConnectionID,
                sessionKey: sessionKey,
                clientPid: Int(getpid()),
                timeout: 0.01
            )

            XCTAssertEqual(readiness, "timedOut")
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: nil
            )
            await manager.removeConnection(bootstrapConnectionID)
        #else
            throw XCTSkip("Bootstrap admission diagnostics require DEBUG helpers.")
        #endif
    }

    func testSessionTokenAlreadyBoundToLiveRunCannotConsumeAnotherRunPolicy() async throws {
        #if DEBUG
            let firstRunID = UUID()
            let secondRunID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstWindowID = 61007
            let secondWindowID = 61008
            let sessionKey = "routing-isolation-\(UUID().uuidString)"
            await installPolicy(runID: firstRunID, windowID: firstWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: firstRunID)

            let firstResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: firstConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(firstResult.outcome, "applied")
            XCTAssertEqual(firstResult.runID, firstRunID)

            await installPolicy(runID: secondRunID, windowID: secondWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: secondRunID)
            let secondResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: secondConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            XCTAssertEqual(secondResult.outcome, "rejected:session_token_bound_to_other_run")
            XCTAssertEqual(secondResult.runID, secondRunID)
            let secondMappedRunID = await manager.runIDForConnection(secondConnectionID)
            XCTAssertNil(secondMappedRunID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == secondRunID })

            await cleanup(
                runID: firstRunID,
                connectionID: firstConnectionID,
                windowID: firstWindowID,
                expectedPID: getpid()
            )
            await cleanup(
                runID: secondRunID,
                connectionID: secondConnectionID,
                windowID: secondWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testRouteMappingFailureRejectsAndRestoresOneShotPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let missingWindowID = 61999
            await installPolicy(runID: runID, windowID: missingWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertEqual(result.outcome, "rejected:route_mapping_failed")
            XCTAssertEqual(result.restrictedTools, [])
            XCTAssertEqual(result.additionalTools, [])
            XCTAssertEqual(result.purpose, .unknown)
            XCTAssertNil(result.windowID)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: missingWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testSuspendedRouteInstallationReservesOneShotPolicyAndRollbackRestoresIt() async throws {
        #if DEBUG
            let runID = UUID()
            let firstConnectionID = UUID()
            let competingConnectionID = UUID()
            let retryConnectionID = UUID()
            let missingWindowID = 61998
            await installPolicy(runID: runID, windowID: missingWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyRouteInstallation()

            let firstApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: firstConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }

            let suspended = await waitUntil {
                await self.manager.debugIsPendingPolicyRouteInstallationSuspended()
            }
            XCTAssertTrue(suspended)

            let competingResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: competingConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            let reservedSnapshot = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(competingResult.outcome, "rejected:policy_reserved")
            XCTAssertTrue(reservedSnapshot.contains { $0.runID == runID })

            await manager.debugResumePendingPolicyRouteInstallation()
            let firstResult = await firstApplication.value
            XCTAssertEqual(firstResult.outcome, "rejected:route_mapping_failed")

            let retryResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: retryConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(retryResult.outcome, "applied")
            XCTAssertEqual(retryResult.runID, runID)
            let consumedSnapshot = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(consumedSnapshot.contains { $0.runID == runID })

            await manager.removeConnection(firstConnectionID)
            await manager.removeConnection(competingConnectionID)
            await cleanup(
                runID: runID,
                connectionID: retryConnectionID,
                windowID: missingWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Pending policy reservation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testRoutingSignalWaitsForOneShotPolicyCommit() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)

            let routeWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 5)
            }
            let didRegisterRouteWaiter = await waitUntil {
                await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
            }
            XCTAssertTrue(didRegisterRouteWaiter)

            await manager.debugSuspendNextPendingPolicyCommit()
            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)

            let pendingBeforeCommit = await manager.debugPendingPolicySnapshot(for: clientName)
            let waiterCountBeforeCommit = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertTrue(pendingBeforeCommit.contains { $0.runID == runID })
            XCTAssertEqual(waiterCountBeforeCommit, 1)

            await manager.debugResumePendingPolicyCommit()
            let result = await application.value
            let didRoute = await routeWaiter.value
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertTrue(didRoute)

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Pending policy commit diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleConnectionAfterRouteInstallRollsBackWithoutConsumingOrFailingRun() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let staleConnectionID = UUID()
            let retryConnectionID = UUID()
            let windowID = window.windowID
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)

            let routeWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 5)
            }
            let didRegisterRouteWaiter = await waitUntil {
                await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
            }
            XCTAssertTrue(didRegisterRouteWaiter)

            await manager.debugSuspendNextPendingPolicyCommit()
            let staleApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: staleConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            let mappedBeforeInvalidation = await MainActor.run {
                window.mcpServer.connectionID(forRunID: runID)
            }
            XCTAssertEqual(mappedBeforeInvalidation, staleConnectionID)

            await manager.debugInvalidatePendingPolicyApplication(connectionID: staleConnectionID)
            await manager.debugResumePendingPolicyCommit()
            let staleResult = await staleApplication.value
            XCTAssertEqual(staleResult.outcome, "rejected:stale_connection")

            let pendingAfterRollback = await manager.debugPendingPolicySnapshot(for: clientName)
            let mappedAfterRollback = await MainActor.run {
                window.mcpServer.connectionID(forRunID: runID)
            }
            let waiterCountAfterRollback = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertTrue(pendingAfterRollback.contains { $0.runID == runID })
            XCTAssertNil(mappedAfterRollback)
            XCTAssertEqual(waiterCountAfterRollback, 1)

            let retryResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: retryConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            let didRoute = await routeWaiter.value
            XCTAssertEqual(retryResult.outcome, "applied")
            XCTAssertTrue(didRoute)

            await manager.removeConnection(staleConnectionID)
            await cleanup(
                runID: runID,
                connectionID: retryConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Pending policy commit diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleTabContextCleanupPreservesSilentReplacementRunMapping() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let staleConnectionID = UUID()
            let replacementConnectionID = UUID()
            let snapshot = ComposeTabState()
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)
            addTeardownBlock {
                await MCPRoutingWaiter.cleanup(runID: runID)
            }
            let routeWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 1)
            }
            let didRegisterWaiter = await waitUntil {
                await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
            }
            XCTAssertTrue(didRegisterWaiter)

            window.mcpServer.installTabContext(
                clientID: staleConnectionID.uuidString,
                clientName: clientName,
                windowID: window.windowID,
                workspaceID: nil,
                snapshot: snapshot,
                runID: runID,
                signalRouting: false
            )
            let didRegisterReplacement = window.mcpServer.registerRunIDMapping(
                connectionID: replacementConnectionID,
                runID: runID,
                windowID: window.windowID,
                signalRouting: false
            )
            window.mcpServer.removeTabContext(
                forConnectionID: staleConnectionID,
                clientName: clientName,
                windowID: window.windowID,
                runID: runID
            )

            let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertTrue(didRegisterReplacement)
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], replacementConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[replacementConnectionID], runID)
            XCTAssertEqual(waiterCount, 1)

            await MCPRoutingWaiter.notifyRouted(runID: runID)
            let didRoute = await routeWaiter.value
            XCTAssertTrue(didRoute)
        #else
            throw XCTSkip("Tab-context routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testPolicyCleanupWhileWaitingRejectsWithoutFallbackBinding() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61006
            await installPolicy(runID: runID, windowID: windowID)
            await manager.debugClearRunRoutingHistoryForTesting()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 1.0,
                    requireRunRouting: false
                )
            }

            let waitStarted = await waitForEvent("pid_gate_wait_started", runID: runID)
            XCTAssertTrue(waitStarted)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
            let result = await application.value

            XCTAssertEqual(result.outcome, "rejected:policy_removed")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertNil(mappedRunID)
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: nil)
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    #if DEBUG
        @MainActor
        private func makeWindow() -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            return window
        }

        private func installPolicy(runID: UUID, windowID: Int) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "OpenCode routing race test",
                ttl: 10,
                tabID: nil,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
        }

        private func cleanup(
            runID: UUID,
            connectionID: UUID,
            windowID: Int,
            expectedPID: pid_t?
        ) async {
            if let expectedPID {
                await manager.clearExpectedAgentPID(expectedPID, for: clientName, runID: runID)
            }
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
            await manager.removeConnection(connectionID)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        }

        private func waitUntil(
            timeout: TimeInterval = 1.0,
            condition: @escaping () async -> Bool
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if await condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            return false
        }

        private func waitForEvent(
            _ event: String,
            runID: UUID,
            timeout: TimeInterval = 1.0
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 100)
                let events = payload["events"] as? [[String: Any]] ?? []
                if events.contains(where: { $0["event"] as? String == event }) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            return false
        }

        private struct SleepingProcessTree {
            let parent: Process
            let childPID: pid_t
            let parentExited: DispatchSemaphore

            var parentPID: pid_t {
                parent.processIdentifier
            }

            func terminate() {
                _ = Darwin.kill(childPID, SIGTERM)
                _ = Darwin.kill(parentPID, SIGTERM)
                guard parentExited.wait(timeout: .now() + 0.25) == .timedOut else {
                    parent.waitUntilExit()
                    return
                }

                _ = Darwin.kill(childPID, SIGKILL)
                _ = Darwin.kill(parentPID, SIGKILL)
                if parentExited.wait(timeout: .now() + 1.0) == .success {
                    parent.waitUntilExit()
                }
            }
        }

        private func makeSleepingProcessTree() throws -> SleepingProcessTree {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3",
                "-c",
                "import subprocess; child=subprocess.Popen(['/bin/sleep','30']); print(child.pid, flush=True); child.wait()"
            ]
            process.standardOutput = stdout
            let parentExited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in parentExited.signal() }
            try process.run()
            var data = Data()
            while data.count < 32 {
                guard let byte = try stdout.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
                if byte == Data([0x0A]) { break }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8),
                  let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                process.terminate()
                process.waitUntilExit()
                throw NSError(
                    domain: "MCPAgentPolicyAdmissionRaceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read child PID from process-tree fixture."]
                )
            }
            return SleepingProcessTree(parent: process, childPID: childPID, parentExited: parentExited)
        }
    #endif
}
