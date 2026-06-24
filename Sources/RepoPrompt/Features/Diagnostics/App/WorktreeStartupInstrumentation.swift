import Foundation

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

    init(
        agentSessionID: UUID,
        correlationID: UUID = UUID(),
        flags: WorktreeStartupFeatureFlags = .current()
    ) {
        self.agentSessionID = agentSessionID
        self.correlationID = correlationID
        self.flags = flags
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
    case cancellation
}

enum WorktreeStartupPhase: String, Equatable {
    case agentRunStarted
    case worktreePreparationStarted
    case bindingTransitionStarted
    case rootLoadStarted
    case rootReady
    case providerStart
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
    struct Event: Equatable {
        let correlationID: UUID
        let phase: WorktreeStartupPhase
        let route: WorkspaceRootStartupRoute?
        let fallback: WorkspaceRootSeedFallbackReason?
        let observationEnabled: Bool
        let servingEnabled: Bool
    }

    struct GitCommandMetric: Equatable {
        let family: GitProcessCommandFamily
        let priority: GitProcessAdmissionPriority
        let queueWaitMicroseconds: Int
        let durationMicroseconds: Int
        let outputByteCount: Int
        let cancelled: Bool
    }

    struct Snapshot: Equatable {
        let events: [Event]
        let gitCommands: [GitCommandMetric]
        let routeCounts: [WorkspaceRootStartupRoute: Int]
        let fallbackCounts: [WorkspaceRootSeedFallbackReason: Int]
    }

    private static let lock = NSLock()
    private static let maximumEventCount = 512
    private static let maximumGitCommandMetricCount = 1024
    private static var events: [Event] = []
    private static var gitCommands: [GitCommandMetric] = []
    private static var routeCounts: [WorkspaceRootStartupRoute: Int] = [:]
    private static var fallbackCounts: [WorkspaceRootSeedFallbackReason: Int] = [:]

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
        }
        events.append(Event(
            correlationID: context.correlationID,
            phase: phase,
            route: route,
            fallback: fallback,
            observationEnabled: context.flags.observeDiffSeededWorktreeStartup,
            servingEnabled: context.flags.serveDiffSeededWorktreeStartup
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

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            events: events,
            gitCommands: gitCommands,
            routeCounts: routeCounts,
            fallbackCounts: fallbackCounts
        )
    }

    #if DEBUG
        static func resetForTesting() {
            lock.lock()
            events.removeAll(keepingCapacity: true)
            gitCommands.removeAll(keepingCapacity: true)
            routeCounts.removeAll(keepingCapacity: true)
            fallbackCounts.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    #endif
}
