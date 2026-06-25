import Foundation
#if DEBUG
    import CryptoKit
#endif

enum WorktreeStartupServingControl: Equatable {
    case automatic
    case forceFullCrawl
}

struct WorktreeStartupFeatureFlags: Equatable {
    static let observeDefaultsKey = "observeDiffSeededWorktreeStartup"
    static let serveDefaultsKey = "serveDiffSeededWorktreeStartup"

    let observeDiffSeededWorktreeStartup: Bool
    let serveDiffSeededWorktreeStartup: Bool

    init(
        observeDiffSeededWorktreeStartup: Bool = false,
        serveDiffSeededWorktreeStartup: Bool = false
    ) {
        self.observeDiffSeededWorktreeStartup = observeDiffSeededWorktreeStartup
        // Serving can never be active without observation authority.
        self.serveDiffSeededWorktreeStartup = serveDiffSeededWorktreeStartup
            && observeDiffSeededWorktreeStartup
    }

    static func current(defaults: UserDefaults = .standard) -> Self {
        Self(
            observeDiffSeededWorktreeStartup: defaults.bool(forKey: observeDefaultsKey),
            serveDiffSeededWorktreeStartup: defaults.bool(forKey: serveDefaultsKey)
        )
    }
}

struct WorktreeStartupContext: Equatable {
    let agentSessionID: UUID
    let correlationID: UUID
    let flags: WorktreeStartupFeatureFlags
    let servingControl: WorktreeStartupServingControl

    init(
        agentSessionID: UUID,
        correlationID: UUID = UUID(),
        flags: WorktreeStartupFeatureFlags = .current(),
        servingControl: WorktreeStartupServingControl = .automatic
    ) {
        self.agentSessionID = agentSessionID
        self.correlationID = correlationID
        self.flags = flags
        self.servingControl = servingControl
    }
}

enum WorkspaceRootStartupRoute: String, Equatable {
    case fullCrawl
    case diffSeedObservation
    case diffSeedServing
}

enum WorkspaceRootSeedFallbackReason: String, Equatable {
    case noReceipt
    case expiredReceipt
    case unsupportedDestination
    case baseUnavailable
    case baseEvicted
    case compatibilityMismatch
    case authorityChanging
    case authorityUnstable
    case gitTimeout
    case gitError
    case gitMalformedOutput
    case gitCappedOutput
    case witnessGap
    case witnessDrop
    case witnessOverflow
    case includeCopyFailure
    case unknownCopiedPath
    case changedIgnoreAuthority
    case conflictOrUnmergedIndex
    case assumeUnchangedIndexEntry
    case sparseCheckout
    case submoduleOrNestedRepository
    case symlinkOrSpecialTopology
    case verificationLimitExceeded
    case unexplainedFilesystemEntry
    case projectedSearchMismatch
    case overlayThresholdExceeded
    case ownerSuperseded
    case serviceIngressGenerationChanged
    case watcherRecoveryUncertain
    case watcherActivationFailure
    case watcherDrop
    case watcherOverflow
    case pendingIngressSequenceGap
    case seededShardPreparationFailure
    case cancellation
}

enum WorktreeStartupPhase: String, Equatable {
    case agentRunStarted
    case worktreePreparationStarted
    case bindingTransitionStarted
    case rootLoadStarted
    case shadowVerified
    case seedWatcherAttached
    case seedReplayFenced
    case seedReadyForCommit
    case seedPublished
    case seedFallback
    case rootReady
    case providerStart
    #if DEBUG
        case firstBenchmarkSearchStarted
        case firstBenchmarkSearchCompleted
        case firstBenchmarkReadStarted
        case firstBenchmarkReadCompleted
    #endif
    case failed
}

enum GitProcessCommandFamily: String, Equatable {
    case treeResolution
    case treeInventory
    case treeDelta
    case indexManifest
    case status
    case authorityMetadata
    case codemapAuthority
    case repositoryRead
    case mutation
}

enum WorktreeStartupInstrumentation {
    #if DEBUG
        enum ReceiptSourceLayoutState: String, Equatable {
            case missing
            case mainCheckout
            case linkedWorktree
        }

        enum ReceiptDestinationEligibility: String, Equatable {
            case eligible
            case notAppManaged
            case includeCopyDisabled
        }

        enum ReceiptParentLookupRoute: String, Equatable {
            case notAttempted
            case currentAlias
            case recovered
            case failed
        }

        enum ReceiptParentLookupFailure: String, Equatable {
            case none
            case currentLeaseUnavailable
            case currentSnapshotUnavailable
            case recoveryObservationUnavailable
            case recoveryCollectionUnavailable
            case externalAuthorityChanged
            case recoveryObservationStale
            case recoveryInstallFailed
            case compatibleSnapshotMissing
            case recoveryAdmissionFailed
            case unexpected
        }

        enum ReceiptGateState: String, Equatable {
            case notAttempted
            case succeeded
            case failed
        }

        enum ReceiptMatchState: String, Equatable {
            case notEvaluated
            case match
            case mismatch
        }

        enum ReceiptCreationOutcome: String, Equatable {
            case receiptEmitted
            case receiptAbsent
            case failed
            case cancelled
        }

        enum ReceiptFinalObservation: Equatable {
            case eligible
            case disabled
            case fallback(WorkspaceRootSeedFallbackReason)
        }

        enum ReceiptTerminalStage: String, Equatable {
            case creation
            case coordinator
            case projection
            case consumption
        }

        enum ReceiptDecisionDigestDomain: String {
            case authorityKey = "authority-key"
            case commonDirectory = "common-directory"
            case repositoryID = "repository-id"
            case repositoryNamespace = "repository-namespace"
            case requestedPrefix = "requested-prefix"
            case snapshot
        }

        struct ReceiptCreationDecision: Equatable {
            var sourceLayoutState: ReceiptSourceLayoutState = .missing
            var destinationEligibility: ReceiptDestinationEligibility = .notAppManaged
            var sourceAuthorityKeyDigest: String?
            var sourceCommonDirectoryDigest: String?
            var repositoryIDDigest: String?
            var repositoryNamespaceDigest: String?
            var requestedPrefixDigest: String?
            var currentLeasePresent: Bool?
            var currentLeaseCurrentAtSnapshotLookup: Bool?
            var currentSnapshotPresent: Bool?
            var currentSnapshotContentAddressValid: Bool?
            var currentSnapshotSHA256: String?
            var parentLookupRoute: ReceiptParentLookupRoute = .notAttempted
            var parentLookupFailure: ReceiptParentLookupFailure = .none
            var parentAuthorityKeyMatch: ReceiptMatchState = .notEvaluated
            var parentPrefixMatch: ReceiptMatchState = .notEvaluated
            var targetTreeResolution: ReceiptGateState = .notAttempted
            var witnessRequested: Bool?
            var witnessStarted: Bool?
            var witnessFinished: Bool?
            var witnessStartEventID: UInt64?
            var witnessEndEventID: UInt64?
            var witnessStartEventIDValid: Bool?
            var witnessEndEventIDValid: Bool?
            var witnessStableRootAvailableBeforeMutation: Bool?
            var witnessDestinationAbsentBeforeMutation: Bool?
            var witnessDestinationStrictDescendant: Bool?
            var witnessStableRootUnchangedAfterInitialization: Bool?
            var witnessStreamCreationSucceeded: Bool?
            var witnessActivationFlushCompleted: Bool?
            var witnessActivationCallbackBarrierCompleted: Bool?
            var witnessEndingFlushCompleted: Bool?
            var witnessEndingCallbackBarrierCompleted: Bool?
            var witnessStartAcceptedCallbackWatermark: UInt64?
            var witnessEndAcceptedCallbackWatermark: UInt64?
            var witnessAcceptedCallbackCount: Int?
            var witnessAcceptedEventCount: Int?
            var witnessAcceptedDestinationEventCount: Int?
            var witnessAcceptedNonDestinationEventCount: Int?
            var witnessMustScanSubDirs: Bool?
            var witnessRootChanged: Bool?
            var witnessUserDropped: Bool?
            var witnessKernelDropped: Bool?
            var witnessEventIDsWrapped: Bool?
            var witnessEventIDRegressed: Bool?
            var witnessLifetimeExceeded: Bool?
            var witnessGap: Bool?
            var witnessDrop: Bool?
            var witnessOverflow: Bool?
            var witnessProvesInterval: Bool?
            var includeCopyRequested: Bool?
            var includeCopyResultPresent: Bool?
            var includeCopyComplete: Bool?
            var includeCopyHadFailures: Bool?
            var targetLayoutPresent: Bool?
            var targetLayoutLinked: Bool?
            var targetAuthorityCapture: ReceiptGateState = .notAttempted
            var commonDirectoryMatch: ReceiptMatchState = .notEvaluated
            var repositoryIDMatch: ReceiptMatchState = .notEvaluated
            var repositoryNamespaceMatch: ReceiptMatchState = .notEvaluated
            var targetPrefixMatch: ReceiptMatchState = .notEvaluated
            var targetTreeAuthorityMatch: ReceiptMatchState = .notEvaluated
            var receiptEmitted: Bool = false
            var receiptFallbackReason: WorkspaceRootSeedFallbackReason?
            var initializationFallbackReason: WorkspaceRootSeedFallbackReason?
            var outcome: ReceiptCreationOutcome = .receiptAbsent

            init() {}
        }

        struct ReceiptCoordinatorDecision: Equatable {
            var createResultReceiptCount = 0
            var hintCount = 0
            var bindingCount = 0
            var hintKeyedByCreatedBinding: ReceiptMatchState = .notEvaluated
            var creationFallbackObserved: WorkspaceRootSeedFallbackReason?

            init() {}
        }

        struct ReceiptProjectionDecision: Equatable {
            var suppliedHintCount = 0
            var matchedHintCount = 0
            var allHintKeysMatchedBindings: Bool?
            var validationFallback: WorkspaceRootSeedFallbackReason?

            init() {}
        }

        struct ReceiptConsumptionDecision: Equatable {
            var ownerGenerationMatch: ReceiptMatchState = .notEvaluated
            var hintSessionMatch: ReceiptMatchState = .notEvaluated
            var hintCorrelationMatch: ReceiptMatchState = .notEvaluated
            var hintOwnerMatch: ReceiptMatchState = .notEvaluated
            var ownershipReused: Bool?
            var initialHintObservation: ReceiptFinalObservation?
            var pendingSeededPreparationResult: ReceiptFinalObservation?
            var fullCrawlPerformed: Bool?
            var finalObservation: ReceiptFinalObservation?
            var selectedRoute: WorkspaceRootStartupRoute?

            init() {}
        }

        struct ReceiptDecision: Equatable {
            let correlationID: UUID
            fileprivate(set) var creation: ReceiptCreationDecision?
            fileprivate(set) var coordinator: ReceiptCoordinatorDecision?
            fileprivate(set) var projection: ReceiptProjectionDecision?
            fileprivate(set) var consumption: ReceiptConsumptionDecision?
            fileprivate(set) var terminalStage: ReceiptTerminalStage?
            fileprivate(set) var ambiguousOrDuplicate = false
            fileprivate(set) var creationAttemptCount = 0
        }

        struct BenchmarkMetricTag: Hashable {
            let correlationID: UUID
            let contextID: UUID
            let agentSessionID: UUID
            let logicalRootID: UUID
            let repositoryID: String
            let destinationID: String
        }

        enum BenchmarkMetricAttribution: String, Equatable {
            case unavailable
            case exact
        }

        struct BenchmarkMetricSnapshot: Equatable {
            var gitCommands: [GitCommandMetric] = []
            var filesystemOperationCount = 0
            var filesystemDurationMicroseconds: UInt64 = 0
            var filesystemItemCount = 0
            var contentReadGrantCount = 0
            var contentReadOverloadCount = 0
            var contentReadWaitMicroseconds: UInt64 = 0
            var contentReadExecutionMicroseconds: UInt64 = 0
            var codemapRequestCount = 0
            var codemapBuildCount = 0
            var codemapQueueMicroseconds: UInt64 = 0
            var codemapPermitWaitMicroseconds: UInt64 = 0
            var codemapAttribution: BenchmarkMetricAttribution = .unavailable
        }

        @TaskLocal static var currentBenchmarkMetricTag: BenchmarkMetricTag?
    #endif

    struct Event: Equatable {
        let correlationID: UUID
        let phase: WorktreeStartupPhase
        let route: WorkspaceRootStartupRoute?
        let fallback: WorkspaceRootSeedFallbackReason?
        let observationEnabled: Bool
        let servingEnabled: Bool
        #if DEBUG
            let agentSessionID: UUID
            let timestampNanoseconds: UInt64
            let forcedFullCrawl: Bool
        #endif

        init(
            phase: WorktreeStartupPhase,
            context: WorktreeStartupContext,
            route: WorkspaceRootStartupRoute?,
            fallback: WorkspaceRootSeedFallbackReason?
        ) {
            correlationID = context.correlationID
            self.phase = phase
            self.route = route
            self.fallback = fallback
            observationEnabled = context.flags.observeDiffSeededWorktreeStartup
            servingEnabled = context.flags.serveDiffSeededWorktreeStartup
            #if DEBUG
                agentSessionID = context.agentSessionID
                timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
                forcedFullCrawl = context.servingControl == .forceFullCrawl
            #endif
        }
    }

    struct GitCommandMetric: Equatable {
        let family: GitProcessCommandFamily
        let priority: GitProcessAdmissionPriority
        let queueWaitMicroseconds: Int
        let durationMicroseconds: Int
        let outputByteCount: Int
        let cancelled: Bool
        #if DEBUG
            let timestampNanoseconds: UInt64
        #endif

        init(
            family: GitProcessCommandFamily,
            priority: GitProcessAdmissionPriority,
            queueWaitMicroseconds: Int,
            durationMicroseconds: Int,
            outputByteCount: Int,
            cancelled: Bool
        ) {
            self.family = family
            self.priority = priority
            self.queueWaitMicroseconds = queueWaitMicroseconds
            self.durationMicroseconds = durationMicroseconds
            self.outputByteCount = outputByteCount
            self.cancelled = cancelled
            #if DEBUG
                timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
            #endif
        }
    }

    struct Snapshot: Equatable {
        let events: [Event]
        let gitCommands: [GitCommandMetric]
        let routeCounts: [WorkspaceRootStartupRoute: Int]
        let fallbackCounts: [WorkspaceRootSeedFallbackReason: Int]
        let shadow: ShadowCounters
        let seed: SeedCounters
        #if DEBUG
            let eventEvictionCount: Int
            let gitCommandEvictionCount: Int
            let receiptDecisions: [ReceiptDecision]
            let receiptDecisionEvictionCount: Int
        #endif
    }

    struct ShadowCounters: Equatable {
        var inventoryComparisons = 0
        var inventoryMatches = 0
        var inventoryMismatches = 0
        var projectedSearchComparisons = 0
        var projectedSearchMatches = 0
        var projectedSearchMismatches = 0
        var latestBaseEntryCount = 0
        var latestOverlayEntryCount = 0
        var latestTombstoneCount = 0
    }

    struct SeedCounters: Equatable {
        var receiptJournalCutPresent = 0
        var receiptJournalCutAbsent = 0
        var acceptedReplayPayloadCount = 0
        var acceptedReplayEventCount = 0
        var latestInitializationWatermarkDelta = 0
        var latestServiceSequenceDelta = 0
        var latestReplayChangedPathCount = 0
        var metadataRevalidationChecks = 0
        var metadataRevalidationUses = 0
        var latestProjectedBaseEntryCount = 0
        var latestProjectedOverlayEntryCount = 0
        var latestProjectedTombstoneCount = 0
        var fullCrawlFallbackCount = 0
    }

    private static let lock = NSLock()
    private static let maximumEventCount = 512
    private static let maximumGitCommandMetricCount = 1024
    private static let maximumSeedMetricValue = 1_000_000
    private static var events: [Event] = []
    private static var gitCommands: [GitCommandMetric] = []
    private static var routeCounts: [WorkspaceRootStartupRoute: Int] = [:]
    private static var fallbackCounts: [WorkspaceRootSeedFallbackReason: Int] = [:]
    private static var shadowCounters = ShadowCounters()
    private static var seedCounters = SeedCounters()
    #if DEBUG
        private static let maximumReceiptDecisionCount = 128
        private static var eventEvictionCount = 0
        private static var gitCommandEvictionCount = 0
        private static var storedReceiptDecisions: [ReceiptDecision] = []
        private static var receiptDecisionEvictionCount = 0
        private static var benchmarkMetricsByTag: [BenchmarkMetricTag: BenchmarkMetricSnapshot] = [:]
    #endif

    static func record(
        _ phase: WorktreeStartupPhase,
        context: WorktreeStartupContext,
        route: WorkspaceRootStartupRoute? = nil,
        fallback: WorkspaceRootSeedFallbackReason? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if events.count == maximumEventCount {
            events.removeFirst()
            #if DEBUG
                eventEvictionCount = incremented(eventEvictionCount)
            #endif
        }
        events.append(Event(
            phase: phase,
            context: context,
            route: route,
            fallback: fallback
        ))
        if let route {
            routeCounts[route, default: 0] += 1
        }
        if let fallback {
            fallbackCounts[fallback, default: 0] += 1
        }
    }

    static func recordGitCommand(
        family: GitProcessCommandFamily,
        priority: GitProcessAdmissionPriority,
        queueWaitMicroseconds: Int,
        durationMicroseconds: Int,
        outputByteCount: Int,
        cancelled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        if gitCommands.count == maximumGitCommandMetricCount {
            gitCommands.removeFirst()
            #if DEBUG
                gitCommandEvictionCount = incremented(gitCommandEvictionCount)
            #endif
        }
        gitCommands.append(GitCommandMetric(
            family: family,
            priority: priority,
            queueWaitMicroseconds: queueWaitMicroseconds,
            durationMicroseconds: durationMicroseconds,
            outputByteCount: outputByteCount,
            cancelled: cancelled
        ))
    }

    #if DEBUG
        static func receiptDecisionDigest(
            _ value: String,
            domain: ReceiptDecisionDigestDomain
        ) -> String {
            let material = "rpce-receipt-decision-v1\0\(domain.rawValue)\0\(value)"
            return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        static func recordReceiptCreationDecision(
            correlationID: UUID,
            decision: ReceiptCreationDecision,
            terminal: Bool = false
        ) {
            lock.lock()
            let index = receiptDecisionIndexLocked(correlationID: correlationID)
            storedReceiptDecisions[index].creationAttemptCount = incremented(
                storedReceiptDecisions[index].creationAttemptCount
            )
            if let existing = storedReceiptDecisions[index].creation {
                storedReceiptDecisions[index].ambiguousOrDuplicate = true
                if existing != decision {
                    storedReceiptDecisions[index].ambiguousOrDuplicate = true
                }
            } else {
                storedReceiptDecisions[index].creation = decision
            }
            setReceiptTerminalLocked(index: index, stage: terminal ? .creation : nil)
            lock.unlock()
        }

        static func recordReceiptCoordinatorDecision(
            correlationID: UUID,
            decision: ReceiptCoordinatorDecision,
            terminal: Bool = false
        ) {
            lock.lock()
            let index = receiptDecisionIndexLocked(correlationID: correlationID)
            if let existing = storedReceiptDecisions[index].coordinator {
                if existing != decision {
                    storedReceiptDecisions[index].ambiguousOrDuplicate = true
                }
            } else {
                storedReceiptDecisions[index].coordinator = decision
            }
            setReceiptTerminalLocked(index: index, stage: terminal ? .coordinator : nil)
            lock.unlock()
        }

        static func recordReceiptProjectionDecision(
            correlationID: UUID,
            decision: ReceiptProjectionDecision,
            terminal: Bool = false
        ) {
            lock.lock()
            let index = receiptDecisionIndexLocked(correlationID: correlationID)
            if let existing = storedReceiptDecisions[index].projection {
                if existing != decision {
                    storedReceiptDecisions[index].ambiguousOrDuplicate = true
                }
            } else {
                storedReceiptDecisions[index].projection = decision
            }
            setReceiptTerminalLocked(index: index, stage: terminal ? .projection : nil)
            lock.unlock()
        }

        static func recordReceiptConsumptionDecision(
            correlationID: UUID,
            decision: ReceiptConsumptionDecision,
            terminal: Bool = true
        ) {
            lock.lock()
            let index = receiptDecisionIndexLocked(correlationID: correlationID)
            if let existing = storedReceiptDecisions[index].consumption {
                if existing != decision {
                    storedReceiptDecisions[index].ambiguousOrDuplicate = true
                }
            } else {
                storedReceiptDecisions[index].consumption = decision
            }
            setReceiptTerminalLocked(index: index, stage: terminal ? .consumption : nil)
            lock.unlock()
        }

        static func receiptDecisions(correlationID: UUID? = nil) -> [ReceiptDecision] {
            lock.lock()
            defer { lock.unlock() }
            guard let correlationID else { return storedReceiptDecisions }
            return storedReceiptDecisions.filter { $0.correlationID == correlationID }
        }

        static func currentReceiptDecisionEvictionCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return receiptDecisionEvictionCount
        }

        private static func receiptDecisionIndexLocked(correlationID: UUID) -> Int {
            if let index = storedReceiptDecisions.firstIndex(where: { $0.correlationID == correlationID }) {
                return index
            }
            if storedReceiptDecisions.count == maximumReceiptDecisionCount {
                let evictionIndex = storedReceiptDecisions.firstIndex(where: { $0.terminalStage != nil }) ?? 0
                storedReceiptDecisions.remove(at: evictionIndex)
                receiptDecisionEvictionCount = incremented(receiptDecisionEvictionCount)
            }
            storedReceiptDecisions.append(ReceiptDecision(correlationID: correlationID))
            return storedReceiptDecisions.count - 1
        }

        private static func setReceiptTerminalLocked(index: Int, stage: ReceiptTerminalStage?) {
            guard let stage, storedReceiptDecisions[index].terminalStage == nil else { return }
            storedReceiptDecisions[index].terminalStage = stage
        }

        static func recordBenchmarkGitCommand(
            tag: BenchmarkMetricTag?,
            family: GitProcessCommandFamily,
            priority: GitProcessAdmissionPriority,
            queueWaitMicroseconds: Int,
            durationMicroseconds: Int,
            outputByteCount: Int,
            cancelled: Bool
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            if metrics.gitCommands.count == maximumGitCommandMetricCount {
                metrics.gitCommands.removeFirst()
            }
            metrics.gitCommands.append(GitCommandMetric(
                family: family,
                priority: priority,
                queueWaitMicroseconds: queueWaitMicroseconds,
                durationMicroseconds: durationMicroseconds,
                outputByteCount: outputByteCount,
                cancelled: cancelled
            ))
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkFilesystemWork(
            tag: BenchmarkMetricTag?,
            durationMicroseconds: UInt64,
            itemCount: Int
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            metrics.filesystemOperationCount = incremented(metrics.filesystemOperationCount)
            metrics.filesystemDurationMicroseconds = adding(metrics.filesystemDurationMicroseconds, durationMicroseconds)
            metrics.filesystemItemCount = added(metrics.filesystemItemCount, itemCount)
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkContentReadWork(
            tag: BenchmarkMetricTag?,
            waitMicroseconds: UInt64,
            executionMicroseconds: UInt64,
            overloaded: Bool
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            if overloaded {
                metrics.contentReadOverloadCount = incremented(metrics.contentReadOverloadCount)
            } else {
                metrics.contentReadGrantCount = incremented(metrics.contentReadGrantCount)
                metrics.contentReadWaitMicroseconds = adding(metrics.contentReadWaitMicroseconds, waitMicroseconds)
                metrics.contentReadExecutionMicroseconds = adding(
                    metrics.contentReadExecutionMicroseconds,
                    executionMicroseconds
                )
            }
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkCodemapWork(
            tag: BenchmarkMetricTag?,
            durations: CodeMapArtifactCoordinatorDurations?,
            buildPerformed: Bool,
            exactlyAttributed: Bool
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            metrics.codemapRequestCount = incremented(metrics.codemapRequestCount)
            if !exactlyAttributed {
                metrics.codemapAttribution = .unavailable
            } else if metrics.codemapAttribution != .unavailable || metrics.codemapRequestCount == 1 {
                metrics.codemapAttribution = .exact
                if buildPerformed {
                    metrics.codemapBuildCount = incremented(metrics.codemapBuildCount)
                }
                if let durations {
                    metrics.codemapQueueMicroseconds = adding(
                        metrics.codemapQueueMicroseconds,
                        durations.buildQueueNanoseconds / 1000
                    )
                    metrics.codemapPermitWaitMicroseconds = adding(
                        metrics.codemapPermitWaitMicroseconds,
                        durations.buildPermitNanoseconds / 1000
                    )
                }
            }
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func benchmarkMetricSnapshot(for tag: BenchmarkMetricTag) -> BenchmarkMetricSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
        }

        static func benchmarkMetricTag(correlationID: UUID) -> BenchmarkMetricTag? {
            lock.lock()
            defer { lock.unlock() }
            return benchmarkMetricsByTag.keys.first { $0.correlationID == correlationID }
        }

        static func resetBenchmarkMetrics(correlationID: UUID? = nil) {
            lock.lock()
            if let correlationID {
                benchmarkMetricsByTag = benchmarkMetricsByTag.filter { $0.key.correlationID != correlationID }
            } else {
                benchmarkMetricsByTag.removeAll(keepingCapacity: true)
            }
            lock.unlock()
        }

        private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
        }
    #endif

    static func recordInventoryComparison(matched: Bool) {
        lock.lock()
        shadowCounters.inventoryComparisons = incremented(shadowCounters.inventoryComparisons)
        if matched {
            shadowCounters.inventoryMatches = incremented(shadowCounters.inventoryMatches)
        } else {
            shadowCounters.inventoryMismatches = incremented(shadowCounters.inventoryMismatches)
        }
        lock.unlock()
    }

    static func recordShadowFallback(_ reason: WorkspaceRootSeedFallbackReason) {
        lock.lock()
        fallbackCounts[reason, default: 0] = incremented(fallbackCounts[reason, default: 0])
        lock.unlock()
    }

    static func recordProjectedSearchComparison(
        matched: Bool,
        baseEntryCount: Int,
        overlayEntryCount: Int,
        tombstoneCount: Int
    ) {
        lock.lock()
        shadowCounters.projectedSearchComparisons = incremented(shadowCounters.projectedSearchComparisons)
        if matched {
            shadowCounters.projectedSearchMatches = incremented(shadowCounters.projectedSearchMatches)
        } else {
            shadowCounters.projectedSearchMismatches = incremented(shadowCounters.projectedSearchMismatches)
            fallbackCounts[.projectedSearchMismatch, default: 0] = incremented(
                fallbackCounts[.projectedSearchMismatch, default: 0]
            )
        }
        shadowCounters.latestBaseEntryCount = max(0, baseEntryCount)
        shadowCounters.latestOverlayEntryCount = max(0, overlayEntryCount)
        shadowCounters.latestTombstoneCount = max(0, tombstoneCount)
        lock.unlock()
    }

    static func recordSeedReceiptJournalCut(present: Bool) {
        lock.lock()
        if present {
            seedCounters.receiptJournalCutPresent = incremented(seedCounters.receiptJournalCutPresent)
        } else {
            seedCounters.receiptJournalCutAbsent = incremented(seedCounters.receiptJournalCutAbsent)
        }
        lock.unlock()
    }

    static func recordSeedReplay(
        acceptedPayloadCount: Int,
        acceptedEventCount: Int,
        initializationWatermarkDelta: Int,
        serviceSequenceDelta: Int,
        changedPathCount: Int
    ) {
        lock.lock()
        seedCounters.acceptedReplayPayloadCount = added(
            seedCounters.acceptedReplayPayloadCount,
            acceptedPayloadCount
        )
        seedCounters.acceptedReplayEventCount = added(
            seedCounters.acceptedReplayEventCount,
            acceptedEventCount
        )
        seedCounters.latestInitializationWatermarkDelta = bounded(initializationWatermarkDelta)
        seedCounters.latestServiceSequenceDelta = bounded(serviceSequenceDelta)
        seedCounters.latestReplayChangedPathCount = bounded(changedPathCount)
        lock.unlock()
    }

    static func recordSeedMetadataRevalidation(used: Bool) {
        lock.lock()
        seedCounters.metadataRevalidationChecks = incremented(seedCounters.metadataRevalidationChecks)
        if used {
            seedCounters.metadataRevalidationUses = incremented(seedCounters.metadataRevalidationUses)
        }
        lock.unlock()
    }

    static func recordSeedProjectedPreparation(
        baseEntryCount: Int,
        overlayEntryCount: Int,
        tombstoneCount: Int
    ) {
        lock.lock()
        seedCounters.latestProjectedBaseEntryCount = bounded(baseEntryCount)
        seedCounters.latestProjectedOverlayEntryCount = bounded(overlayEntryCount)
        seedCounters.latestProjectedTombstoneCount = bounded(tombstoneCount)
        lock.unlock()
    }

    static func recordSeedFullCrawlFallback() {
        lock.lock()
        seedCounters.fullCrawlFallbackCount = incremented(seedCounters.fullCrawlFallbackCount)
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
            return Snapshot(
                events: events,
                gitCommands: gitCommands,
                routeCounts: routeCounts,
                fallbackCounts: fallbackCounts,
                shadow: shadowCounters,
                seed: seedCounters,
                eventEvictionCount: eventEvictionCount,
                gitCommandEvictionCount: gitCommandEvictionCount,
                receiptDecisions: storedReceiptDecisions,
                receiptDecisionEvictionCount: receiptDecisionEvictionCount
            )
        #else
            return Snapshot(
                events: events,
                gitCommands: gitCommands,
                routeCounts: routeCounts,
                fallbackCounts: fallbackCounts,
                shadow: shadowCounters,
                seed: seedCounters
            )
        #endif
    }

    private static func incremented(_ value: Int) -> Int {
        value >= maximumSeedMetricValue ? maximumSeedMetricValue : value + 1
    }

    private static func bounded(_ value: Int) -> Int {
        min(max(0, value), maximumSeedMetricValue)
    }

    private static func added(_ current: Int, _ value: Int) -> Int {
        min(maximumSeedMetricValue, current + bounded(value))
    }

    #if DEBUG
        static func resetForTesting() {
            lock.lock()
            events.removeAll(keepingCapacity: true)
            gitCommands.removeAll(keepingCapacity: true)
            routeCounts.removeAll(keepingCapacity: true)
            fallbackCounts.removeAll(keepingCapacity: true)
            shadowCounters = ShadowCounters()
            seedCounters = SeedCounters()
            eventEvictionCount = 0
            gitCommandEvictionCount = 0
            storedReceiptDecisions.removeAll(keepingCapacity: true)
            receiptDecisionEvictionCount = 0
            benchmarkMetricsByTag.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    #endif
}
