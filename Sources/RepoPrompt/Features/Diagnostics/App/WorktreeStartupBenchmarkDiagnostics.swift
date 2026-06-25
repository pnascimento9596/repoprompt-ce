#if DEBUG
    import Foundation

    enum DebugWorktreeStartupBenchmarkError: Error, Equatable {
        case disabled
        case invalidScope
        case invalidControl
        case invalidToken
        case expired
        case alreadyConsumed
        case invalidTransition
        case sampleNotFound
        case startIdentityMismatch
        case baseSnapshotUnavailable(BaseSnapshotFailure)

        struct BaseSnapshotFailure: Equatable {
            enum Reason: String, Equatable {
                case nonGit = "non_git"
                case unsupportedRoot = "unsupported_root"
                case authorityUnavailable = "authority_unavailable"
                case catalogMismatch = "catalog_mismatch"
                case failed
            }

            let reason: Reason
            let stage: WorkspaceRootReusableSnapshotCoordinator.ObservationFailureStage?
            let cause: String?
        }

        var code: String {
            switch self {
            case .disabled: "disabled"
            case .invalidScope: "scope_mismatch"
            case .invalidControl: "invalid_control"
            case .invalidToken: "invalid_token"
            case .expired: "expired"
            case .alreadyConsumed: "already_consumed"
            case .invalidTransition: "invalid_transition"
            case .sampleNotFound: "sample_not_found"
            case .startIdentityMismatch: "start_identity_mismatch"
            case .baseSnapshotUnavailable: "base_snapshot_unavailable"
            }
        }
    }

    final class WorktreeStartupBenchmarkGate: @unchecked Sendable {
        static let shared = WorktreeStartupBenchmarkGate()

        private let lock = NSLock()
        private var enabled = false
        private var generation: UInt64 = 0

        @discardableResult
        func setEnabled(_ value: Bool) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            guard enabled != value else { return generation }
            enabled = value
            generation &+= 1
            return generation
        }

        func requireEnabled<T>(_ body: (UInt64) throws -> T) throws -> T {
            lock.lock()
            defer { lock.unlock() }
            guard enabled else { throw DebugWorktreeStartupBenchmarkError.disabled }
            return try body(generation)
        }

        func isCurrentEnabledGeneration(_ expected: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return enabled && generation == expected
        }

        func snapshot() -> (enabled: Bool, generation: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            return (enabled, generation)
        }
    }

    struct DebugWorktreeStartupBenchmarkScope: Hashable {
        let windowID: Int
        let workspaceID: UUID
        let contextID: UUID
        let rootID: UUID
    }

    struct DebugWorktreeStartupBenchmarkRootIdentity: Hashable {
        let scope: DebugWorktreeStartupBenchmarkScope
        let standardizedLogicalRootPath: String
        let repositoryID: String
        let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    }

    struct DebugWorktreeStartupBenchmarkExpectedStart: Hashable {
        let rootIdentity: DebugWorktreeStartupBenchmarkRootIdentity
        let requestedBranch: String?
        let requestedBaseRef: String?
    }

    struct DebugWorktreeStartupBenchmarkValidatedStart: Hashable {
        let scope: DebugWorktreeStartupBenchmarkScope
        let logicalRootID: UUID
        let standardizedLogicalRootPath: String
        let repositoryID: String
        let repositoryKey: GitWorkspaceAuthorityRepositoryKey
        let requestedBranch: String?
        let requestedBaseRef: String?
        let standardizedDestinationPath: String
        let standardizedAppManagedContainerPath: String
        let destinationID: String
        let agentSessionID: UUID
        let startAttemptID: UUID
    }

    struct DebugWorktreeStartupBenchmarkPendingStart: Hashable {
        let token: UUID
        let startAttemptID: UUID
    }

    struct DebugWorktreeStartupBenchmarkRoutingProvenance: Equatable {
        let connectionID: UUID
        let boundWindowID: Int
        let boundWorkspaceID: UUID
        let boundContextID: UUID

        func authorize(
            connectionID: UUID,
            windowID: Int,
            hiddenWindowID: Int,
            workspaceID: UUID,
            contextID: UUID,
            benchmarkContextID: UUID
        ) throws {
            guard self.connectionID == connectionID,
                  boundWindowID == windowID,
                  boundWindowID == hiddenWindowID,
                  boundWorkspaceID == workspaceID,
                  boundContextID == contextID,
                  boundContextID == benchmarkContextID
            else { throw DebugWorktreeStartupBenchmarkError.invalidScope }
        }
    }

    final class WorktreeStartupBenchmarkDiagnostics: @unchecked Sendable {
        static let shared = WorktreeStartupBenchmarkDiagnostics()
        static let enabledDefaultsKey = "enableWorktreeStartupBenchmarkDiagnostics"
        static let requiredWorkspaceNamePrefix = "RPCE 8E Bench "
        @TaskLocal static var currentPendingStart: DebugWorktreeStartupBenchmarkPendingStart?

        struct RouteControl: Equatable {
            let observe: Bool
            let serve: Bool
            let forceFullCrawl: Bool

            init(observe: Bool, serve: Bool, forceFullCrawl: Bool) {
                self.observe = observe || serve
                self.serve = serve
                self.forceFullCrawl = forceFullCrawl
            }

            var flags: WorktreeStartupFeatureFlags {
                WorktreeStartupFeatureFlags(
                    observeDiffSeededWorktreeStartup: observe,
                    serveDiffSeededWorktreeStartup: serve
                )
            }

            var servingControl: WorktreeStartupServingControl {
                forceFullCrawl ? .forceFullCrawl : .automatic
            }

            var name: String {
                if forceFullCrawl { return "forcedFullCrawl" }
                if serve { return "diffSeedServing" }
                if observe { return "diffSeedObservation" }
                return "fullCrawl"
            }
        }

        struct ControlResult: Equatable {
            let controlID: UUID
            let expiresAtNanoseconds: UInt64
            let previousControlID: UUID?
            let route: RouteControl
        }

        struct PreparedControlResult: Equatable {
            let control: ControlResult
            let baseSnapshotPrepared: Bool
            let baseSnapshotIdentity: WorkspaceRootReusableSnapshotIdentity?
        }

        struct ArmResult: Equatable {
            let token: UUID
            let correlationID: UUID
            let expiresAtNanoseconds: UInt64
            let route: RouteControl
        }

        struct Consumption: Equatable {
            let correlationID: UUID
            let flags: WorktreeStartupFeatureFlags
            let servingControl: WorktreeStartupServingControl
            let routeName: String
            let metricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag
        }

        struct Preflight: Equatable {
            let expectedStart: DebugWorktreeStartupBenchmarkExpectedStart
            let correlationID: UUID
            let flags: WorktreeStartupFeatureFlags
            let servingControl: WorktreeStartupServingControl
        }

        private struct ControlLease {
            let id: UUID
            let scope: DebugWorktreeStartupBenchmarkScope
            let route: RouteControl
            let expiresAtNanoseconds: UInt64
            let previousID: UUID?
        }

        private struct TokenLease {
            let token: UUID
            let correlationID: UUID
            let expectedStart: DebugWorktreeStartupBenchmarkExpectedStart
            let route: RouteControl
            let scenario: String
            let invocation: Int
            let ordinal: Int
            let warmup: Bool
            let expiresAtNanoseconds: UInt64
            let gateGeneration: UInt64
            var consumed: Bool
        }

        private struct SampleState {
            let correlationID: UUID
            let expectedStart: DebugWorktreeStartupBenchmarkExpectedStart
            let route: RouteControl
            let scenario: String
            let invocation: Int
            let ordinal: Int
            let warmup: Bool
            let armedAtNanoseconds: UInt64
            let baselineEventEvictionCount: Int
            let baselineReceiptDecisionEvictionCount: Int
            var agentSessionID: UUID?
            var startAttemptID: UUID?
            var metricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?

            var scope: DebugWorktreeStartupBenchmarkScope {
                expectedStart.rootIdentity.scope
            }
        }

        private let lock = NSLock()
        private var currentControlIDByScope: [DebugWorktreeStartupBenchmarkScope: UUID] = [:]
        private var controlsByID: [UUID: ControlLease] = [:]
        private var tokensByID: [UUID: TokenLease] = [:]
        private var samplesByCorrelationID: [UUID: SampleState] = [:]

        static func synchronizeGateFromDefaults(_ defaults: UserDefaults = .standard) {
            setGateEnabled(defaults.bool(forKey: enabledDefaultsKey))
        }

        static func setGateEnabled(_ enabled: Bool) {
            WorktreeStartupBenchmarkGate.shared.setEnabled(enabled)
            guard !enabled else { return }
            shared.revokeAll()
        }

        func setFlags(
            scope: DebugWorktreeStartupBenchmarkScope,
            observe: Bool,
            serve: Bool,
            forceFullCrawl: Bool,
            expiresSeconds: Int
        ) throws -> ControlResult {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                let now = DispatchTime.now().uptimeNanoseconds
                let expires = Self.deadline(now: now, seconds: expiresSeconds)
                let route = RouteControl(observe: observe, serve: serve, forceFullCrawl: forceFullCrawl)
                lock.lock()
                purgeExpiredLocked(now: now)
                let previous = currentControlIDByScope[scope].flatMap { controlsByID[$0] }
                let lease = ControlLease(
                    id: UUID(),
                    scope: scope,
                    route: route,
                    expiresAtNanoseconds: expires,
                    previousID: previous?.id
                )
                controlsByID[lease.id] = lease
                currentControlIDByScope[scope] = lease.id
                lock.unlock()
                scheduleControlExpiry(lease.id, expiresAtNanoseconds: expires)
                return ControlResult(
                    controlID: lease.id,
                    expiresAtNanoseconds: expires,
                    previousControlID: previous?.id,
                    route: route
                )
            }
        }

        func setFlagsPreparingBaseSnapshot(
            scope: DebugWorktreeStartupBenchmarkScope,
            observe: Bool,
            serve: Bool,
            forceFullCrawl: Bool,
            expiresSeconds: Int,
            store: WorkspaceFileContextStore,
            expectedStandardizedRootPath: String
        ) async throws -> PreparedControlResult {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in }
            let shouldPrepareBaseSnapshot = (observe || serve) && !forceFullCrawl
            var baseSnapshotIdentity: WorkspaceRootReusableSnapshotIdentity?
            if shouldPrepareBaseSnapshot {
                let observation = try await store.admitReusableSnapshotForLoadedRoot(
                    rootID: scope.rootID,
                    expectedStandardizedPath: expectedStandardizedRootPath
                )
                switch observation {
                case let .admitted(identity):
                    baseSnapshotIdentity = identity
                case .nonGit:
                    throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                        reason: .nonGit,
                        stage: nil,
                        cause: nil
                    ))
                case .unsupportedRoot:
                    throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                        reason: .unsupportedRoot,
                        stage: nil,
                        cause: nil
                    ))
                case let .authorityUnavailable(stage, reason):
                    throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                        reason: .authorityUnavailable,
                        stage: stage,
                        cause: reason.benchmarkDiagnosticCode
                    ))
                case .catalogMismatch:
                    throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                        reason: .catalogMismatch,
                        stage: nil,
                        cause: nil
                    ))
                case let .failed(failure):
                    throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                        reason: .failed,
                        stage: failure.stage,
                        cause: failure.cause.code
                    ))
                }
            }
            let control = try setFlags(
                scope: scope,
                observe: observe,
                serve: serve,
                forceFullCrawl: forceFullCrawl,
                expiresSeconds: expiresSeconds
            )
            return PreparedControlResult(
                control: control,
                baseSnapshotPrepared: shouldPrepareBaseSnapshot,
                baseSnapshotIdentity: baseSnapshotIdentity
            )
        }

        @discardableResult
        func restoreFlags(scope: DebugWorktreeStartupBenchmarkScope, controlID: UUID) throws -> UUID? {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard let lease = controlsByID[controlID], lease.scope == scope,
                      currentControlIDByScope[scope] == controlID
                else { throw DebugWorktreeStartupBenchmarkError.invalidControl }
                controlsByID.removeValue(forKey: controlID)
                return restorePreviousLocked(for: lease, now: now)
            }
        }

        func arm(
            expectedStart: DebugWorktreeStartupBenchmarkExpectedStart,
            controlID: UUID,
            scenario: String,
            invocation: Int,
            ordinal: Int,
            warmup: Bool,
            expiresSeconds: Int
        ) throws -> ArmResult {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { gateGeneration in
                let now = DispatchTime.now().uptimeNanoseconds
                lock.lock()
                purgeExpiredLocked(now: now)
                let scope = expectedStart.rootIdentity.scope
                guard let control = controlsByID[controlID],
                      control.scope == scope,
                      currentControlIDByScope[scope] == controlID
                else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.invalidControl
                }
                let expires = min(
                    control.expiresAtNanoseconds,
                    Self.deadline(now: now, seconds: expiresSeconds)
                )
                let instrumentation = WorktreeStartupInstrumentation.snapshot()
                let token = UUID()
                let correlationID = UUID()
                tokensByID[token] = TokenLease(
                    token: token,
                    correlationID: correlationID,
                    expectedStart: expectedStart,
                    route: control.route,
                    scenario: scenario,
                    invocation: invocation,
                    ordinal: ordinal,
                    warmup: warmup,
                    expiresAtNanoseconds: expires,
                    gateGeneration: gateGeneration,
                    consumed: false
                )
                samplesByCorrelationID[correlationID] = SampleState(
                    correlationID: correlationID,
                    expectedStart: expectedStart,
                    route: control.route,
                    scenario: scenario,
                    invocation: invocation,
                    ordinal: ordinal,
                    warmup: warmup,
                    armedAtNanoseconds: now,
                    baselineEventEvictionCount: instrumentation.eventEvictionCount,
                    baselineReceiptDecisionEvictionCount: instrumentation.receiptDecisionEvictionCount,
                    agentSessionID: nil,
                    startAttemptID: nil,
                    metricTag: nil
                )
                lock.unlock()
                scheduleTokenExpiry(token, expiresAtNanoseconds: expires)
                return ArmResult(
                    token: token,
                    correlationID: correlationID,
                    expiresAtNanoseconds: expires,
                    route: control.route
                )
            }
        }

        func preflight(token: UUID) throws -> Preflight {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { gateGeneration in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard let lease = tokensByID[token] else {
                    throw DebugWorktreeStartupBenchmarkError.invalidToken
                }
                guard !lease.consumed else { throw DebugWorktreeStartupBenchmarkError.alreadyConsumed }
                guard lease.expiresAtNanoseconds > now, lease.gateGeneration == gateGeneration else {
                    throw DebugWorktreeStartupBenchmarkError.expired
                }
                return Preflight(
                    expectedStart: lease.expectedStart,
                    correlationID: lease.correlationID,
                    flags: lease.route.flags,
                    servingControl: lease.route.servingControl
                )
            }
        }

        func consume(
            token: UUID,
            validatedStart: DebugWorktreeStartupBenchmarkValidatedStart
        ) throws -> Consumption {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { gateGeneration in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard var lease = tokensByID[token] else {
                    throw DebugWorktreeStartupBenchmarkError.invalidToken
                }
                guard !lease.consumed else { throw DebugWorktreeStartupBenchmarkError.alreadyConsumed }
                guard lease.expiresAtNanoseconds > now, lease.gateGeneration == gateGeneration else {
                    throw DebugWorktreeStartupBenchmarkError.expired
                }
                let expected = lease.expectedStart
                let actualContainer = validatedStart.standardizedAppManagedContainerPath
                let actualDestination = validatedStart.standardizedDestinationPath
                guard expected.rootIdentity.scope == validatedStart.scope,
                      expected.rootIdentity.scope.contextID == validatedStart.scope.contextID,
                      expected.rootIdentity.scope.rootID == validatedStart.logicalRootID,
                      expected.rootIdentity.standardizedLogicalRootPath == validatedStart.standardizedLogicalRootPath,
                      expected.rootIdentity.repositoryID == validatedStart.repositoryID,
                      expected.rootIdentity.repositoryKey == validatedStart.repositoryKey,
                      expected.requestedBranch == validatedStart.requestedBranch,
                      expected.requestedBaseRef == validatedStart.requestedBaseRef,
                      Self.isPath(actualDestination, inside: actualContainer)
                else { throw DebugWorktreeStartupBenchmarkError.startIdentityMismatch }
                let tag = WorktreeStartupInstrumentation.BenchmarkMetricTag(
                    correlationID: lease.correlationID,
                    contextID: validatedStart.scope.contextID,
                    agentSessionID: validatedStart.agentSessionID,
                    logicalRootID: validatedStart.logicalRootID,
                    repositoryID: validatedStart.repositoryID,
                    destinationID: validatedStart.destinationID
                )
                lease.consumed = true
                tokensByID[token] = lease
                guard var sample = samplesByCorrelationID[lease.correlationID], sample.metricTag == nil else {
                    throw DebugWorktreeStartupBenchmarkError.invalidTransition
                }
                sample.agentSessionID = validatedStart.agentSessionID
                sample.startAttemptID = validatedStart.startAttemptID
                sample.metricTag = tag
                samplesByCorrelationID[lease.correlationID] = sample
                return Consumption(
                    correlationID: lease.correlationID,
                    flags: lease.route.flags,
                    servingControl: lease.route.servingControl,
                    routeName: lease.route.name,
                    metricTag: tag
                )
            }
        }

        func mark(
            scope: DebugWorktreeStartupBenchmarkScope,
            correlationID: UUID,
            phase: WorktreeStartupPhase
        ) throws {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                let context: WorktreeStartupContext
                lock.lock()
                let sample = samplesByCorrelationID[correlationID]
                let instrumentation = WorktreeStartupInstrumentation.snapshot()
                guard let sample, sample.scope == scope, let sessionID = sample.agentSessionID else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.sampleNotFound
                }
                let phases = Set(
                    instrumentation.events.lazy
                        .filter { $0.correlationID == correlationID }
                        .map(\.phase)
                )
                let valid = switch phase {
                case .firstBenchmarkSearchStarted:
                    !phases.contains(.firstBenchmarkSearchStarted)
                case .firstBenchmarkSearchCompleted:
                    phases.contains(.firstBenchmarkSearchStarted) && !phases.contains(.firstBenchmarkSearchCompleted)
                case .firstBenchmarkReadStarted:
                    phases.contains(.firstBenchmarkSearchCompleted) && !phases.contains(.firstBenchmarkReadStarted)
                case .firstBenchmarkReadCompleted:
                    phases.contains(.firstBenchmarkReadStarted) && !phases.contains(.firstBenchmarkReadCompleted)
                default:
                    false
                }
                guard valid else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.invalidTransition
                }
                context = WorktreeStartupContext(
                    agentSessionID: sessionID,
                    correlationID: correlationID,
                    flags: sample.route.flags,
                    servingControl: sample.route.servingControl
                )
                lock.unlock()
                WorktreeStartupInstrumentation.record(phase, context: context)
            }
        }

        func snapshotPayload(
            scope: DebugWorktreeStartupBenchmarkScope,
            correlationID: UUID,
            export: Bool
        ) throws -> [String: Any] {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard let sample = samplesByCorrelationID[correlationID], sample.scope == scope else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.sampleNotFound
                }
                lock.unlock()

                let instrumentation = WorktreeStartupInstrumentation.snapshot()
                let events = instrumentation.events.filter { $0.correlationID == correlationID }
                let eventTimes = Dictionary(grouping: events, by: \.phase).compactMapValues {
                    $0.first?.timestampNanoseconds
                }
                let routeCounts = Dictionary(grouping: events.compactMap(\.route), by: { $0.rawValue })
                    .mapValues(\.count)
                let fallbackCounts = Dictionary(grouping: events.compactMap(\.fallback), by: { $0.rawValue })
                    .mapValues(\.count)
                let eventEvicted = instrumentation.eventEvictionCount > sample.baselineEventEvictionCount
                let receiptDecisions = instrumentation.receiptDecisions.filter { $0.correlationID == correlationID }
                let terminalReceiptDecisionCount = receiptDecisions.count(where: { $0.terminalStage != nil })
                let receiptDecisionEvicted = instrumentation.receiptDecisionEvictionCount
                    > sample.baselineReceiptDecisionEvictionCount
                let receiptDecisionAmbiguous = receiptDecisions.contains {
                    $0.ambiguousOrDuplicate || $0.creationAttemptCount > 1
                }
                let rootReady = eventTimes[.rootReady] != nil
                let receiptDecisionValid = !receiptDecisionEvicted
                    && receiptDecisions.count <= 1
                    && !receiptDecisionAmbiguous
                    && (!rootReady || terminalReceiptDecisionCount == 1)
                let metrics = sample.metricTag.map(WorktreeStartupInstrumentation.benchmarkMetricSnapshot)
                let git = metrics?.gitCommands ?? []
                let gitFamilies = Dictionary(grouping: git, by: { $0.family.rawValue }).mapValues(\.count)
                let gitPriorities = Dictionary(grouping: git, by: { String(describing: $0.priority) }).mapValues(\.count)

                var payload: [String: Any] = [
                    "ok": true,
                    "schema_version": 4,
                    "action": export ? "export" : "snapshot",
                    "scope": [
                        "window_id": scope.windowID,
                        "workspace_id": scope.workspaceID.uuidString,
                        "context_id": scope.contextID.uuidString,
                        "root_id": scope.rootID.uuidString
                    ],
                    "sample": [
                        "correlation_id": correlationID.uuidString,
                        "agent_session_id": sample.agentSessionID.map { $0.uuidString as Any } ?? NSNull(),
                        "start_attempt_id": sample.startAttemptID.map { $0.uuidString as Any } ?? NSNull(),
                        "configured_route": sample.route.name,
                        "scenario": sample.scenario,
                        "invocation": sample.invocation,
                        "ordinal": sample.ordinal,
                        "warmup": sample.warmup,
                        "root_ready": rootReady,
                        "first_search_complete": eventTimes[.firstBenchmarkSearchCompleted] != nil,
                        "first_read_complete": eventTimes[.firstBenchmarkReadCompleted] != nil,
                        "route_counts": routeCounts,
                        "fallback_counts": fallbackCounts,
                        "milestones_us": Self.milestonePayload(eventTimes, baseline: sample.armedAtNanoseconds),
                        "durations_us": Self.durationPayload(eventTimes),
                        "event_buffer_evicted": eventEvicted,
                        "valid": !eventEvicted && sample.metricTag != nil && receiptDecisionValid
                    ],
                    "receipt_decision_count": receiptDecisions.count,
                    "terminal_receipt_decision_count": terminalReceiptDecisionCount,
                    "receipt_decision_buffer_evicted": receiptDecisionEvicted,
                    "receipt_decision_ambiguous": receiptDecisionAmbiguous,
                    "receipt_decisions": receiptDecisions.map(Self.receiptDecisionPayload),
                    "git": Self.gitPayload(git, families: gitFamilies, priorities: gitPriorities),
                    "work": Self.workPayload(metrics)
                ]
                if export {
                    payload["bounded"] = true
                    payload["contains_paths"] = false
                }
                return payload
            }
        }

        func reset(scope: DebugWorktreeStartupBenchmarkScope) throws -> [String: Int] {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                let controlIDs = controlsByID.values.filter { $0.scope == scope }.map(\.id)
                let tokenIDs = tokensByID.values.filter { $0.expectedStart.rootIdentity.scope == scope }.map(\.token)
                let samples = samplesByCorrelationID.values.filter { $0.scope == scope }
                controlIDs.forEach { controlsByID.removeValue(forKey: $0) }
                tokenIDs.forEach { tokensByID.removeValue(forKey: $0) }
                for sample in samples {
                    samplesByCorrelationID.removeValue(forKey: sample.correlationID)
                    WorktreeStartupInstrumentation.resetBenchmarkMetrics(correlationID: sample.correlationID)
                }
                currentControlIDByScope.removeValue(forKey: scope)
                return [
                    "control_count": controlIDs.count,
                    "token_count": tokenIDs.count,
                    "sample_count": samples.count
                ]
            }
        }

        func revokeAll() {
            lock.lock()
            currentControlIDByScope.removeAll(keepingCapacity: true)
            controlsByID.removeAll(keepingCapacity: true)
            tokensByID.removeAll(keepingCapacity: true)
            samplesByCorrelationID.removeAll(keepingCapacity: true)
            lock.unlock()
            WorktreeStartupInstrumentation.resetBenchmarkMetrics()
        }

        private func scheduleControlExpiry(_ id: UUID, expiresAtNanoseconds: UInt64) {
            Task { [weak self] in
                let now = DispatchTime.now().uptimeNanoseconds
                if expiresAtNanoseconds > now {
                    try? await Task.sleep(nanoseconds: expiresAtNanoseconds - now)
                }
                self?.expireControl(id)
            }
        }

        private func scheduleTokenExpiry(_ token: UUID, expiresAtNanoseconds: UInt64) {
            Task { [weak self] in
                let now = DispatchTime.now().uptimeNanoseconds
                if expiresAtNanoseconds > now {
                    try? await Task.sleep(nanoseconds: expiresAtNanoseconds - now)
                }
                self?.expireToken(token)
            }
        }

        private func expireControl(_ id: UUID) {
            lock.lock()
            defer { lock.unlock() }
            guard let lease = controlsByID[id], lease.expiresAtNanoseconds <= DispatchTime.now().uptimeNanoseconds else {
                return
            }
            controlsByID.removeValue(forKey: id)
            if currentControlIDByScope[lease.scope] == id {
                _ = restorePreviousLocked(for: lease, now: DispatchTime.now().uptimeNanoseconds)
            }
        }

        private func expireToken(_ token: UUID) {
            lock.lock()
            defer { lock.unlock() }
            guard let lease = tokensByID[token],
                  !lease.consumed,
                  lease.expiresAtNanoseconds <= DispatchTime.now().uptimeNanoseconds
            else { return }
            tokensByID.removeValue(forKey: token)
        }

        private func purgeExpiredLocked(now: UInt64) {
            let expiredTokenIDs = tokensByID.values
                .filter { !$0.consumed && $0.expiresAtNanoseconds <= now }
                .map(\.token)
            for tokenID in expiredTokenIDs {
                tokensByID.removeValue(forKey: tokenID)
            }
            let expiredControls = controlsByID.values.filter { $0.expiresAtNanoseconds <= now }
            for lease in expiredControls {
                controlsByID.removeValue(forKey: lease.id)
                if currentControlIDByScope[lease.scope] == lease.id {
                    _ = restorePreviousLocked(for: lease, now: now)
                }
            }
        }

        private func restorePreviousLocked(for lease: ControlLease, now: UInt64) -> UUID? {
            if let previousID = lease.previousID,
               let previous = controlsByID[previousID],
               previous.expiresAtNanoseconds > now
            {
                currentControlIDByScope[lease.scope] = previous.id
                return previous.id
            }
            currentControlIDByScope.removeValue(forKey: lease.scope)
            return nil
        }

        private static func receiptDecisionPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptDecision
        ) -> [String: Any] {
            var payload: [String: Any] = [
                "correlation_id": decision.correlationID.uuidString,
                "terminal_stage": optionalRawValue(decision.terminalStage),
                "ambiguous_or_duplicate": decision.ambiguousOrDuplicate,
                "creation_attempt_count": decision.creationAttemptCount
            ]
            payload["creation"] = decision.creation.map(receiptCreationPayload) ?? NSNull()
            payload["coordinator"] = decision.coordinator.map(receiptCoordinatorPayload) ?? NSNull()
            payload["projection"] = decision.projection.map(receiptProjectionPayload) ?? NSNull()
            payload["consumption"] = decision.consumption.map(receiptConsumptionPayload) ?? NSNull()
            return payload
        }

        private static func receiptCreationPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptCreationDecision
        ) -> [String: Any] {
            [
                "source_layout_state": decision.sourceLayoutState.rawValue,
                "destination_eligibility": decision.destinationEligibility.rawValue,
                "source_authority_key_digest": optional(decision.sourceAuthorityKeyDigest),
                "source_common_directory_digest": optional(decision.sourceCommonDirectoryDigest),
                "repository_id_digest": optional(decision.repositoryIDDigest),
                "repository_namespace_digest": optional(decision.repositoryNamespaceDigest),
                "requested_prefix_digest": optional(decision.requestedPrefixDigest),
                "current_lease_present": optional(decision.currentLeasePresent),
                "current_lease_current_at_snapshot_lookup": optional(decision.currentLeaseCurrentAtSnapshotLookup),
                "current_snapshot_present": optional(decision.currentSnapshotPresent),
                "current_snapshot_content_address_valid": optional(decision.currentSnapshotContentAddressValid),
                "current_snapshot_sha256": optional(decision.currentSnapshotSHA256),
                "parent_lookup_route": decision.parentLookupRoute.rawValue,
                "parent_lookup_failure": decision.parentLookupFailure.rawValue,
                "parent_authority_key_match": decision.parentAuthorityKeyMatch.rawValue,
                "parent_prefix_match": decision.parentPrefixMatch.rawValue,
                "target_tree_resolution": decision.targetTreeResolution.rawValue,
                "witness_requested": optional(decision.witnessRequested),
                "witness_started": optional(decision.witnessStarted),
                "witness_finished": optional(decision.witnessFinished),
                "witness_start_event_id": optional(decision.witnessStartEventID),
                "witness_end_event_id": optional(decision.witnessEndEventID),
                "witness_start_event_id_valid": optional(decision.witnessStartEventIDValid),
                "witness_end_event_id_valid": optional(decision.witnessEndEventIDValid),
                "witness_stable_root_available_before_mutation": optional(
                    decision.witnessStableRootAvailableBeforeMutation
                ),
                "witness_destination_absent_before_mutation": optional(
                    decision.witnessDestinationAbsentBeforeMutation
                ),
                "witness_destination_strict_descendant": optional(
                    decision.witnessDestinationStrictDescendant
                ),
                "witness_stable_root_unchanged_after_initialization": optional(
                    decision.witnessStableRootUnchangedAfterInitialization
                ),
                "witness_stream_creation_succeeded": optional(decision.witnessStreamCreationSucceeded),
                "witness_activation_flush_completed": optional(decision.witnessActivationFlushCompleted),
                "witness_activation_callback_barrier_completed": optional(
                    decision.witnessActivationCallbackBarrierCompleted
                ),
                "witness_ending_flush_completed": optional(decision.witnessEndingFlushCompleted),
                "witness_ending_callback_barrier_completed": optional(
                    decision.witnessEndingCallbackBarrierCompleted
                ),
                "witness_start_accepted_callback_watermark": optional(
                    decision.witnessStartAcceptedCallbackWatermark
                ),
                "witness_end_accepted_callback_watermark": optional(
                    decision.witnessEndAcceptedCallbackWatermark
                ),
                "witness_accepted_callback_count": optional(decision.witnessAcceptedCallbackCount),
                "witness_accepted_event_count": optional(decision.witnessAcceptedEventCount),
                "witness_accepted_destination_event_count": optional(
                    decision.witnessAcceptedDestinationEventCount
                ),
                "witness_accepted_non_destination_event_count": optional(
                    decision.witnessAcceptedNonDestinationEventCount
                ),
                "witness_must_scan_sub_dirs": optional(decision.witnessMustScanSubDirs),
                "witness_root_changed": optional(decision.witnessRootChanged),
                "witness_user_dropped": optional(decision.witnessUserDropped),
                "witness_kernel_dropped": optional(decision.witnessKernelDropped),
                "witness_event_ids_wrapped": optional(decision.witnessEventIDsWrapped),
                "witness_event_id_regressed": optional(decision.witnessEventIDRegressed),
                "witness_lifetime_exceeded": optional(decision.witnessLifetimeExceeded),
                "witness_gap": optional(decision.witnessGap),
                "witness_drop": optional(decision.witnessDrop),
                "witness_overflow": optional(decision.witnessOverflow),
                "witness_proves_interval": optional(decision.witnessProvesInterval),
                "include_copy_requested": optional(decision.includeCopyRequested),
                "include_copy_result_present": optional(decision.includeCopyResultPresent),
                "include_copy_complete": optional(decision.includeCopyComplete),
                "include_copy_had_failures": optional(decision.includeCopyHadFailures),
                "target_layout_present": optional(decision.targetLayoutPresent),
                "target_layout_linked": optional(decision.targetLayoutLinked),
                "target_authority_capture": decision.targetAuthorityCapture.rawValue,
                "common_directory_match": decision.commonDirectoryMatch.rawValue,
                "repository_id_match": decision.repositoryIDMatch.rawValue,
                "repository_namespace_match": decision.repositoryNamespaceMatch.rawValue,
                "target_prefix_match": decision.targetPrefixMatch.rawValue,
                "target_tree_authority_match": decision.targetTreeAuthorityMatch.rawValue,
                "receipt_emitted": decision.receiptEmitted,
                "receipt_fallback_reason": optionalRawValue(decision.receiptFallbackReason),
                "initialization_fallback_reason": optionalRawValue(decision.initializationFallbackReason),
                "outcome": decision.outcome.rawValue
            ]
        }

        private static func receiptCoordinatorPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptCoordinatorDecision
        ) -> [String: Any] {
            [
                "create_result_receipt_count": decision.createResultReceiptCount,
                "hint_count": decision.hintCount,
                "binding_count": decision.bindingCount,
                "hint_keyed_by_created_binding": decision.hintKeyedByCreatedBinding.rawValue,
                "creation_fallback_observed": optionalRawValue(decision.creationFallbackObserved)
            ]
        }

        private static func receiptProjectionPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptProjectionDecision
        ) -> [String: Any] {
            [
                "supplied_hint_count": decision.suppliedHintCount,
                "matched_hint_count": decision.matchedHintCount,
                "all_hint_keys_matched_bindings": optional(decision.allHintKeysMatchedBindings),
                "validation_fallback": optionalRawValue(decision.validationFallback)
            ]
        }

        private static func receiptConsumptionPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptConsumptionDecision
        ) -> [String: Any] {
            [
                "owner_generation_match": decision.ownerGenerationMatch.rawValue,
                "hint_session_match": decision.hintSessionMatch.rawValue,
                "hint_correlation_match": decision.hintCorrelationMatch.rawValue,
                "hint_owner_match": decision.hintOwnerMatch.rawValue,
                "ownership_reused": optional(decision.ownershipReused),
                "initial_hint_observation": receiptObservationPayload(decision.initialHintObservation),
                "pending_seeded_preparation_result": receiptObservationPayload(
                    decision.pendingSeededPreparationResult
                ),
                "full_crawl_performed": optional(decision.fullCrawlPerformed),
                "final_observation": receiptObservationPayload(decision.finalObservation),
                "selected_route": optionalRawValue(decision.selectedRoute)
            ]
        }

        private static func receiptObservationPayload(
            _ observation: WorktreeStartupInstrumentation.ReceiptFinalObservation?
        ) -> Any {
            guard let observation else { return NSNull() }
            switch observation {
            case .eligible:
                return ["state": "eligible"]
            case .disabled:
                return ["state": "disabled"]
            case let .fallback(reason):
                return ["state": "fallback", "fallback_reason": reason.rawValue]
            }
        }

        private static func optional(_ value: (some Any)?) -> Any {
            guard let value else { return NSNull() }
            return value
        }

        private static func optionalRawValue<T: RawRepresentable>(_ value: T?) -> Any where T.RawValue == String {
            guard let value else { return NSNull() }
            return value.rawValue
        }

        private static func gitPayload(
            _ git: [WorktreeStartupInstrumentation.GitCommandMetric],
            families: [String: Int],
            priorities: [String: Int]
        ) -> [String: Any] {
            [
                "available": true,
                "command_count": git.count,
                "families": families,
                "priorities": priorities,
                "queue_wait_us": git.reduce(0) { $0 + $1.queueWaitMicroseconds },
                "duration_us": git.reduce(0) { $0 + $1.durationMicroseconds },
                "output_bytes": git.reduce(0) { $0 + $1.outputByteCount },
                "cancelled_count": git.count(where: \.cancelled)
            ]
        }

        private static func workPayload(
            _ metrics: WorktreeStartupInstrumentation.BenchmarkMetricSnapshot?
        ) -> [String: Any] {
            guard let metrics else {
                return [
                    "filesystem": ["available": false],
                    "content_read_admission": ["available": false],
                    "codemap": ["available": false]
                ]
            }
            let codemapAvailable = metrics.codemapAttribution == .exact
            return [
                "filesystem": [
                    "available": metrics.filesystemOperationCount > 0,
                    "operation_count": metrics.filesystemOperationCount,
                    "duration_us": metrics.filesystemDurationMicroseconds,
                    "item_count": metrics.filesystemItemCount
                ],
                "content_read_admission": [
                    "available": metrics.contentReadGrantCount + metrics.contentReadOverloadCount > 0,
                    "grant_count": metrics.contentReadGrantCount,
                    "overload_count": metrics.contentReadOverloadCount,
                    "wait_us": metrics.contentReadWaitMicroseconds,
                    "execution_us": metrics.contentReadExecutionMicroseconds
                ],
                "codemap": [
                    "available": codemapAvailable,
                    "attribution": metrics.codemapAttribution.rawValue,
                    "request_count": metrics.codemapRequestCount,
                    "build_count": codemapAvailable ? metrics.codemapBuildCount as Any : NSNull(),
                    "queue_us": codemapAvailable ? metrics.codemapQueueMicroseconds as Any : NSNull(),
                    "permit_wait_us": codemapAvailable ? metrics.codemapPermitWaitMicroseconds as Any : NSNull()
                ]
            ]
        }

        private static func deadline(now: UInt64, seconds: Int) -> UInt64 {
            let delta = UInt64(max(1, seconds)) * 1_000_000_000
            return now > UInt64.max - delta ? UInt64.max : now + delta
        }

        private static func isPath(_ path: String, inside container: String) -> Bool {
            path == container || path.hasPrefix(container.hasSuffix("/") ? container : container + "/")
        }

        private static func milestonePayload(
            _ events: [WorktreeStartupPhase: UInt64],
            baseline: UInt64
        ) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: events.map { phase, timestamp in
                (phase.rawValue, timestamp >= baseline ? (timestamp - baseline) / 1000 : 0)
            })
        }

        private static func durationPayload(_ events: [WorktreeStartupPhase: UInt64]) -> [String: UInt64] {
            var values: [String: UInt64] = [:]
            func add(_ name: String, _ start: WorktreeStartupPhase, _ end: WorktreeStartupPhase) {
                guard let startTime = events[start], let endTime = events[end], endTime >= startTime else { return }
                values[name] = (endTime - startTime) / 1000
            }
            add("materialize_to_root_ready", .bindingTransitionStarted, .rootReady)
            add("materialize_to_provider_start", .bindingTransitionStarted, .providerStart)
            add("materialize_to_first_search", .bindingTransitionStarted, .firstBenchmarkSearchCompleted)
            add("materialize_to_first_read", .bindingTransitionStarted, .firstBenchmarkReadCompleted)
            add("root_ready_to_first_search", .rootReady, .firstBenchmarkSearchCompleted)
            add("first_search", .firstBenchmarkSearchStarted, .firstBenchmarkSearchCompleted)
            add("first_read", .firstBenchmarkReadStarted, .firstBenchmarkReadCompleted)
            return values
        }
    }

    private extension GitWorkspaceAuthorityUnavailableReason {
        var benchmarkDiagnosticCode: String {
            switch self {
            case .noSnapshot: "no_snapshot"
            case .mutationInProgress: "mutation_in_progress"
            case .metadataEventPending: "metadata_event_pending"
            case .monitorCoverageUnavailable: "monitor_coverage_unavailable"
            case .superseded: "superseded"
            case .invalidatedDuringCollection: "invalidated_during_collection"
            case .collectionScopeMismatch: "collection_scope_mismatch"
            }
        }
    }
#endif
