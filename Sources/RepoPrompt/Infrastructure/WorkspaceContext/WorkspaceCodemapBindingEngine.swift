import Foundation

/// Inert orchestration for Git-only, artifact-backed workspace codemap bindings.
///
/// One injected instance can own bounded sessions for many roots. It deliberately owns no source
/// catalog and no artifact cache: those remain with the caller and the process-wide artifact runtime.
actor WorkspaceCodemapBindingEngine {
    private final class DemandCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var isCancelled: Bool {
            lock.withLock { storage }
        }

        func cancel() {
            lock.withLock { storage = true }
        }
    }

    private struct RegistrationAttempt {
        let id: UUID
        let registration: WorkspaceCodemapBindingRootRegistration
        var cancelled: Bool
    }

    private struct UnavailableRoot {
        let registration: WorkspaceCodemapBindingRootRegistration
        let state: WorkspaceCodemapGitCapabilityState
    }

    private struct PipelineSession {
        let id: UUID
        let language: LanguageType
        let pipelineIdentity: CodeMapPipelineIdentity
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        var previouslyObservedManifestAuthority: CodeMapRootManifestAuthority?
        var manifestRecords: [String: CodeMapRootManifestRecord]
        var manifestState: WorkspaceCodemapBindingManifestState
        var manifestLoadStarted: Bool
        var manifestLoadFinished: Bool
        var manifestRevision: UInt64
        var persistedManifestRevision: UInt64
        var pendingManifestChanges: [String: PendingManifestChange]
    }

    private struct Session {
        let id: UUID
        let registration: WorkspaceCodemapBindingRootRegistration
        let capability: GitCodemapRootCapability
        let manifestWriterSession: CodeMapRootManifestWriterSessionToken
        var pipelines: [CodeMapPipelineIdentity: PipelineSession]
        var pathGenerations: [String: UInt64]
        var generation: UInt64
        var invalidationGeneration: UInt64
    }

    private struct PipelineScope: Hashable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let pipelineIdentity: CodeMapPipelineIdentity
    }

    private enum ManifestAdoptionOutcome {
        case terminal(adoptedReadyCount: Int)
        case retryable
        case superseded
    }

    private struct ManifestAdoptionAttempt {
        let operationID: UUID
        let scope: PipelineScope
        let sessionID: UUID
        let sessionGeneration: UInt64
        let invalidationGeneration: UInt64
        let pipelineSessionID: UUID
        let catalogGeneration: UInt64
        let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        let manifestRevision: UInt64
    }

    private struct ManifestAdoptionOperation {
        let attempt: ManifestAdoptionAttempt
        let task: Task<ManifestAdoptionOutcome, Never>
        var waiters: [UUID: CheckedContinuation<Void, Never>]
    }

    private struct ActiveRequest {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let demand: WorkspaceCodemapBindingDemand
        let publicOwner: WorkspaceCodemapLiveDemandOwner
        let relativePath: String
        let sessionID: UUID
        let sessionGeneration: UInt64
        let pipelineIdentity: CodeMapPipelineIdentity
        let pipelineSessionID: UUID
        let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
        let reservedSourceBytes: UInt64
        var overlayOwner: WorkspaceCodemapLiveDemandOwner?
        var preflight: WorkspaceCodemapLiveDemandPreflightTicket?
        var ticket: WorkspaceCodemapLiveDemandTicket?
        var task: Task<Void, Never>?
        var continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult, Never>?
        var cancelled: Bool
    }

    private struct QueuedRequest {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let demand: WorkspaceCodemapBindingDemand
        var enqueueOrdinal: UInt64
        var continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult, Never>?
    }

    private struct OwnerKey: Hashable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let owner: WorkspaceCodemapLiveDemandOwner
    }

    private struct ManifestAdoptionContext {
        let operationID: UUID
        let sessionID: UUID
        let sessionGeneration: UInt64
        let invalidationGeneration: UInt64
        let pipelineIdentity: CodeMapPipelineIdentity
        let pipelineSessionID: UUID
        let catalogGeneration: UInt64
        let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        let manifestRevision: UInt64
        let ticket: WorkspaceCodemapLiveManifestAdoptionTicket
    }

    private struct PreparedManifestAdoption {
        let record: CodeMapRootManifestRecord
        let candidate: WorkspaceCodemapManifestBindingCandidate
        let sourceAuthority: WorkspaceCodemapSourceAuthorityToken
        let association: VerifiedGitBlobCodeMapLocatorAssociation
        let lease: CodeMapArtifactLease?
    }

    private struct PendingManifestChange {
        let revision: UInt64
        let record: CodeMapRootManifestRecord?
    }

    private struct ManifestWriterWorkKey: Hashable {
        let scope: PipelineScope
        let sessionID: UUID
        let pipelineSessionID: UUID
    }

    private struct ManifestWriteWaiter {
        let id: UUID
        let workKey: ManifestWriterWorkKey
        let revision: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct ManifestWriterState {
        var writerID: UUID?
        var task: Task<Void, Never>?
        var queuedWork: [ManifestWriterWorkKey] = []
        var queuedWorkSet: Set<ManifestWriterWorkKey> = []
        var inFlightWork: ManifestWriterWorkKey?
        var inFlightRevision: UInt64?
        var waiters: [ManifestWriteWaiter] = []
    }

    private struct AdoptionReservation {
        let id: UUID
        var recordCount: Int
        var leaseBytesByRelativePath: [String: UInt64]

        var leaseCount: Int {
            leaseBytesByRelativePath.count
        }

        var leaseBytes: UInt64 {
            leaseBytesByRelativePath.values.reduce(0) { partial, value in
                let (sum, overflow) = partial.addingReportingOverflow(value)
                return overflow ? .max : sum
            }
        }
    }

    private struct OverlayCancellation {
        let owner: WorkspaceCodemapLiveDemandOwner?
        let ticket: WorkspaceCodemapLiveDemandTicket?
        let preflight: WorkspaceCodemapLiveDemandPreflightTicket?
    }

    private struct SynchronousCancellationBatch {
        let overlayCancellations: [OverlayCancellation]
        let cancelledRequestCount: Int
    }

    private struct ValidatedDemandContext {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let session: Session
        let pipelineIdentity: CodeMapPipelineIdentity
        let pathGeneration: UInt64
    }

    private enum DemandValidation {
        case valid(ValidatedDemandContext)
        case result(WorkspaceCodemapBindingDemandResult)
    }

    private enum RootRecord {
        case registering(RegistrationAttempt)
        case unavailable(UnavailableRoot)
        case eligible(Session)
    }

    private struct ResolvedArtifact {
        let resolution: CodeMapArtifactCoordinatorResolution
        let association: VerifiedGitBlobCodeMapLocatorAssociation?
        let materializedByteCount: UInt64
        let performedBuild: Bool
        let locatorFastPath: Bool
        let casFastPath: Bool
    }

    private let runtime: CodeMapArtifactRuntime
    private let capabilityService: WorkspaceCodemapGitCapabilityService
    private let identityService: GitBlobIdentityService
    private let materializationService: GitBlobSourceMaterializationService
    private let sourceReader: WorkspaceCodemapValidatedSourceReaderClient
    private let catalogClient: WorkspaceCodemapBindingCatalogClient
    private let overlay: WorkspaceCodemapLiveOverlay
    private let policy: WorkspaceCodemapBindingEnginePolicy
    private let hooks: WorkspaceCodemapBindingEngineHooks
    private let accessEpochSeconds: @Sendable () -> UInt64
    private var roots: [WorkspaceCodemapRootEpoch: RootRecord] = [:]
    private var activeRequests: [UUID: ActiveRequest] = [:]
    private var drainingRequestTasks: [UUID: Task<Void, Never>] = [:]
    private var queuedRequests: [UUID: QueuedRequest] = [:]
    private var queueOrder: [UUID] = []
    private var nextQueueOrdinal: UInt64 = 1
    private var nextAdmissionOrdinal: UInt64 = 1
    private var rootLastAdmission: [WorkspaceCodemapRootEpoch: UInt64] = [:]
    private var ownerLastAdmission: [OwnerKey: UInt64] = [:]
    private var consecutiveDemandAdmissions = 0
    private var manifestWriters: [CodeMapRootManifestNamespace: ManifestWriterState] = [:]
    private var adoptionReservations: [PipelineScope: AdoptionReservation] = [:]
    private var retainedAdoptions: [PipelineScope: AdoptionReservation] = [:]
    private var manifestAdoptionOperations: [PipelineScope: ManifestAdoptionOperation] = [:]
    private var drainingManifestAdoptionTasks: [UUID: Task<ManifestAdoptionOutcome, Never>] = [:]
    private var registrationOperations: Set<UUID> = []
    private var replacementCancelledRegistrationAttemptIDs: Set<UUID> = []
    private var registrationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShuttingDown = false
    private var shutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var counters = WorkspaceCodemapBindingEngineCounters()

    init(
        runtime: CodeMapArtifactRuntime,
        capabilityService: WorkspaceCodemapGitCapabilityService,
        identityService: GitBlobIdentityService = GitBlobIdentityService(),
        materializationService: GitBlobSourceMaterializationService = GitBlobSourceMaterializationService(),
        sourceReader: WorkspaceCodemapValidatedSourceReaderClient,
        catalogClient: WorkspaceCodemapBindingCatalogClient = .unavailable,
        overlay: WorkspaceCodemapLiveOverlay = WorkspaceCodemapLiveOverlay(),
        policy: WorkspaceCodemapBindingEnginePolicy = .default,
        hooks: WorkspaceCodemapBindingEngineHooks = .none,
        initialQueueOrdinal: UInt64 = 1,
        initialAdmissionOrdinal: UInt64 = 1,
        initialCounterValue: UInt64 = 0,
        accessEpochSeconds: @escaping @Sendable () -> UInt64 = {
            UInt64(max(0, Date().timeIntervalSince1970))
        }
    ) {
        self.runtime = runtime
        self.capabilityService = capabilityService
        self.identityService = identityService
        self.materializationService = materializationService
        self.sourceReader = sourceReader
        self.catalogClient = catalogClient
        self.overlay = overlay
        self.policy = policy
        self.hooks = hooks
        nextQueueOrdinal = max(1, initialQueueOrdinal)
        nextAdmissionOrdinal = max(1, initialAdmissionOrdinal)
        counters = WorkspaceCodemapBindingEngineCounters(initialValue: initialCounterValue)
        self.accessEpochSeconds = accessEpochSeconds
    }

    func registerRoot(
        _ registration: WorkspaceCodemapBindingRootRegistration
    ) async -> WorkspaceCodemapBindingRegistrationResult {
        guard !isShuttingDown else { return .failed }
        let operationID = UUID()
        registrationOperations.insert(operationID)
        defer { finishRegistrationOperation(operationID) }

        let rootEpoch = registration.capabilityRequest.rootEpoch
        if let current = roots[rootEpoch] {
            switch current {
            case let .registering(attempt):
                return attempt.registration == registration ? .busy : .failed
            case let .unavailable(unavailable):
                let replacesRevokedAuthority = unavailable.registration.capabilityRequest ==
                    registration.capabilityRequest &&
                    registration.catalogGeneration > unavailable.registration.catalogGeneration &&
                    registration.ingressGeneration > unavailable.registration.ingressGeneration
                if case .unresolved = unavailable.state,
                   unavailable.registration == registration || replacesRevokedAuthority
                {
                    roots.removeValue(forKey: rootEpoch)
                } else {
                    return unavailable.registration == registration ? .exactDuplicate : .failed
                }
            case let .eligible(session):
                return session.registration == registration ? .exactDuplicate : .failed
            }
        }
        guard registration.catalogGeneration > 0,
              registration.ingressGeneration > 0,
              roots.count < policy.maximumRootCount
        else {
            recordBusy(rootEpoch)
            return .busy
        }

        let attempt = RegistrationAttempt(id: UUID(), registration: registration, cancelled: false)
        roots[rootEpoch] = .registering(attempt)
        incrementCounter(\.capabilityResolutions)
        var capabilityState = await capabilityService.resolve(root: registration.capabilityRequest)
        guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            return .failed
        }
        if case .transientUnavailable = capabilityState,
           policy.maximumCapabilityRetryCount == 1
        {
            incrementCounter(\.capabilityRetries)
            emit(.capabilityTransientRetry, rootEpoch: rootEpoch)
            capabilityState = await capabilityService.reload(root: registration.capabilityRequest)
            guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
                await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
                finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
                return .failed
            }
        }
        guard case let .eligible(capability) = capabilityState else {
            guard registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
                await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
                finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
                return .failed
            }
            roots[rootEpoch] = .unavailable(UnavailableRoot(
                registration: registration,
                state: capabilityState
            ))
            switch capabilityState {
            case .terminalUnavailable:
                emit(.capabilityTerminalUnavailable, rootEpoch: rootEpoch)
            default:
                emit(.failure, rootEpoch: rootEpoch)
            }
            return .unavailable(capabilityState)
        }

        let registrationDisposition = await overlay.register(
            capability: capabilityState,
            catalogGeneration: registration.catalogGeneration
        )
        guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            return .failed
        }
        switch registrationDisposition {
        case .registered, .exactDuplicate:
            break
        case .busy:
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            recordBusy(rootEpoch)
            return .busy
        case .rejected:
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            recordFailure(rootEpoch)
            return .failed
        }

        let manifestWriterSession: CodeMapRootManifestWriterSessionToken
        do {
            manifestWriterSession = try await runtime.manifestStore.registerManifestWriterSession()
        } catch {
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            recordFailure(rootEpoch)
            return .failed
        }
        guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
            await runtime.manifestStore.endManifestWriterSession(manifestWriterSession)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            return .failed
        }
        roots[rootEpoch] = .eligible(Session(
            id: UUID(),
            registration: registration,
            capability: capability,
            manifestWriterSession: manifestWriterSession,
            pipelines: [:],
            pathGenerations: [:],
            generation: 1,
            invalidationGeneration: 1
        ))
        emit(.capabilityEligible, rootEpoch: rootEpoch)
        return .registered(adoptedReadyCount: 0)
    }

    func demand(_ demand: WorkspaceCodemapBindingDemand) async -> WorkspaceCodemapBindingDemandResult {
        let requestID = UUID()
        let cancellation = DemandCancellationState()
        return await withTaskCancellationHandler {
            if Task.isCancelled || cancellation.isCancelled { return .cancelled }
            return await withCheckedContinuation { continuation in
                admitOrQueue(
                    requestID: requestID,
                    demand: demand,
                    cancellation: cancellation,
                    continuation: continuation
                )
            }
        } onCancel: {
            cancellation.cancel()
            Task {
                if await self.cancelRequest(requestID: requestID) {
                    await self.recordCancellationTelemetry(1)
                }
            }
        }
    }

    @discardableResult
    func cancel(owner: WorkspaceCodemapLiveDemandOwner) async -> Int {
        let requestIDs = queuedRequests.values
            .filter { $0.demand.owner == owner }
            .map(\.id) + activeRequests.values.filter { $0.publicOwner == owner }.map(\.id)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs)
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        return cancellationBatch.cancelledRequestCount
    }

    @discardableResult
    private func cancelRequest(requestID: UUID) async -> Bool {
        let cancellationBatch = synchronouslyCancelRequests([requestID])
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        return cancellationBatch.cancelledRequestCount == 1
    }

    func invalidateModified(
        rootEpoch: WorkspaceCodemapRootEpoch,
        standardizedRelativePaths: Set<String>
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidatePaths(rootEpoch, paths: standardizedRelativePaths, reason: .modified)
    }

    func invalidateDeleted(
        rootEpoch: WorkspaceCodemapRootEpoch,
        standardizedRelativePaths: Set<String>
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidatePaths(rootEpoch, paths: standardizedRelativePaths, reason: .deleted)
    }

    func invalidateRenamed(
        rootEpoch: WorkspaceCodemapRootEpoch,
        from oldPath: String,
        to newPath: String
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidatePaths(rootEpoch, paths: [oldPath, newPath], reason: .renamed)
    }

    func invalidateWatcherGap(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .watcherGap)
    }

    func invalidateCheckout(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .checkoutChanged)
    }

    func invalidateCatalog(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .catalogChanged)
    }

    func invalidateRepositoryAuthority(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .authorityChanged)
    }

    func unloadRoot(rootEpoch: WorkspaceCodemapRootEpoch) async {
        if case .registering? = roots[rootEpoch] {
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.release(rootEpoch: rootEpoch)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            emit(.rootUnload, rootEpoch: rootEpoch)
            return
        }
        let manifestWriterSession: CodeMapRootManifestWriterSessionToken? = if case let .eligible(session)? =
            roots[rootEpoch]
        {
            session.manifestWriterSession
        } else {
            nil
        }
        let requestIDs = queuedRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id) +
            activeRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id)
        roots.removeValue(forKey: rootEpoch)
        detachManifestWriters(rootEpoch: rootEpoch)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs)
        if let manifestWriterSession {
            await runtime.manifestStore.endManifestWriterSession(manifestWriterSession)
        }
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        _ = await overlay.unregister(rootEpoch: rootEpoch)
        adoptionReservations = adoptionReservations.filter { $0.key.rootEpoch != rootEpoch }
        retainedAdoptions = retainedAdoptions.filter { $0.key.rootEpoch != rootEpoch }
        pruneAdmissionHistory()
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        await capabilityService.release(rootEpoch: rootEpoch)
        emit(.rootUnload, rootEpoch: rootEpoch)
    }

    func shutdown() async {
        if shutdownComplete { return }
        if isShuttingDown {
            await waitForShutdownCompletion()
            return
        }

        isShuttingDown = true
        let rootEpochs = Array(roots.keys)
        let manifestWriterSessions = roots.values.compactMap { record -> CodeMapRootManifestWriterSessionToken? in
            guard case let .eligible(session) = record else { return nil }
            return session.manifestWriterSession
        }
        let requestIDs = Array(queuedRequests.keys) + Array(activeRequests.keys)
        roots.removeAll()
        let writerTasks = cancelAllManifestWriters()
        let cancellationBatch = synchronouslyCancelRequests(requestIDs)
        adoptionReservations.removeAll()
        retainedAdoptions.removeAll()
        let adoptionOperations = Array(manifestAdoptionOperations.values)
        manifestAdoptionOperations.removeAll()
        for operation in adoptionOperations {
            operation.task.cancel()
            drainingManifestAdoptionTasks[operation.attempt.operationID] = operation.task
            for waiter in operation.waiters.values {
                waiter.resume()
            }
        }
        let adoptionTasks = Array(drainingManifestAdoptionTasks.values)
        rootLastAdmission.removeAll()
        ownerLastAdmission.removeAll()
        consecutiveDemandAdmissions = 0
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        let requestTasks = Array(drainingRequestTasks.values)

        for writerSession in manifestWriterSessions {
            await runtime.manifestStore.endManifestWriterSession(writerSession)
        }
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        for rootEpoch in rootEpochs {
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await capabilityService.release(rootEpoch: rootEpoch)
        }
        for task in requestTasks {
            await task.value
        }
        for task in writerTasks {
            await task.value
        }
        for task in adoptionTasks {
            _ = await task.value
        }
        await waitForRegistrationOperationsToDrain()
        await capabilityService.drain()

        adoptionReservations.removeAll()
        retainedAdoptions.removeAll()
        drainingManifestAdoptionTasks.removeAll()
        drainingRequestTasks.removeAll()
        pruneAdmissionHistory()
        shutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func snapshot(rootEpoch: WorkspaceCodemapRootEpoch) async -> WorkspaceCodemapLiveRootSnapshot? {
        await overlay.snapshot(rootEpoch: rootEpoch)
    }

    func freeze(rootEpoch: WorkspaceCodemapRootEpoch) async -> WorkspaceCodemapLiveOverlayBundle? {
        await overlay.freeze(rootEpoch: rootEpoch)
    }

    func accounting() -> WorkspaceCodemapBindingEngineAccounting {
        var eligible = 0
        var unavailable = 0
        var active = 0
        var owners = Set<WorkspaceCodemapLiveDemandOwner>()
        var dirty = 0
        for record in roots.values {
            switch record {
            case .registering:
                continue
            case .unavailable:
                unavailable += 1
            case let .eligible(session):
                eligible += 1
                dirty += session.pipelines.values.count(where: {
                    $0.manifestState == .dirtyRetryRequired
                })
            }
        }
        active = activeRequests.count
        owners.formUnion(activeRequests.values.map(\.publicOwner))
        owners.formUnion(queuedRequests.values.map(\.demand.owner))
        let reservedSourceBytes = activeRequests.values.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let adoptionUsage = adoptionLeaseUsage()
        return WorkspaceCodemapBindingEngineAccounting(
            rootCount: roots.count,
            eligibleRootCount: eligible,
            unavailableRootCount: unavailable,
            activeRequestCount: active,
            queuedRequestCount: queuedRequests.count,
            ownerCount: owners.count,
            reservedSourceByteCount: reservedSourceBytes,
            manifestAdoptionLeaseCount: adoptionUsage?.count ?? .max,
            manifestAdoptionLeaseByteCount: adoptionUsage?.bytes ?? .max,
            rootAdmissionHistoryCount: rootLastAdmission.count,
            ownerAdmissionHistoryCount: ownerLastAdmission.count,
            dirtyManifestCount: dirty,
            counters: counters
        )
    }

    private func loadAndAdoptManifest(
        rootEpoch: WorkspaceCodemapRootEpoch,
        attempt: ManifestAdoptionAttempt
    ) async -> ManifestAdoptionOutcome {
        let pipelineIdentity = attempt.scope.pipelineIdentity
        guard attempt.scope.rootEpoch == rootEpoch,
              manifestAdoptionOperations[attempt.scope]?.attempt.operationID == attempt.operationID,
              case let .eligible(initial)? = roots[rootEpoch],
              initial.id == attempt.sessionID,
              initial.generation == attempt.sessionGeneration,
              initial.invalidationGeneration == attempt.invalidationGeneration,
              initial.registration.catalogGeneration == attempt.catalogGeneration,
              initial.capability.repositoryAuthority == attempt.repositoryAuthority,
              let initialPipeline = initial.pipelines[pipelineIdentity],
              initialPipeline.id == attempt.pipelineSessionID,
              initialPipeline.namespace == attempt.namespace,
              initialPipeline.authority == attempt.authority,
              initialPipeline.manifestRevision == attempt.manifestRevision
        else { return .superseded }
        let pipelineScope = attempt.scope
        guard let ticket = await overlay.beginManifestAdoption(
            rootEpoch: rootEpoch,
            namespace: attempt.namespace
        ),
            case let .eligible(afterTicket)? = roots[rootEpoch],
            afterTicket.id == attempt.sessionID,
            afterTicket.pipelines[pipelineIdentity]?.id == attempt.pipelineSessionID,
            afterTicket.generation == attempt.sessionGeneration,
            afterTicket.invalidationGeneration == attempt.invalidationGeneration
        else { return .retryable }
        let context = ManifestAdoptionContext(
            operationID: attempt.operationID,
            sessionID: attempt.sessionID,
            sessionGeneration: attempt.sessionGeneration,
            invalidationGeneration: attempt.invalidationGeneration,
            pipelineIdentity: pipelineIdentity,
            pipelineSessionID: attempt.pipelineSessionID,
            catalogGeneration: attempt.catalogGeneration,
            repositoryAuthority: attempt.repositoryAuthority,
            namespace: attempt.namespace,
            authority: attempt.authority,
            manifestRevision: attempt.manifestRevision,
            ticket: ticket
        )
        guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else { return .superseded }
        incrementCounter(\.manifestLoads)
        let load: CodeMapRootManifestLoadResult
        do {
            load = try await runtime.manifestStore.loadCurrentManifest(
                namespace: initialPipeline.namespace,
                currentAuthority: initialPipeline.authority
            )
        } catch {
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else { return .superseded }
            updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
            incrementCounter(\.manifestFailures)
            emit(.manifestFailure, rootEpoch: rootEpoch)
            return .retryable
        }
        guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else { return .superseded }
        switch load {
        case .miss:
            updatePreviouslyObservedManifestAuthority(nil, context: context, rootEpoch: rootEpoch)
        case let .stale(existingAuthority):
            updatePreviouslyObservedManifestAuthority(
                existingAuthority,
                context: context,
                rootEpoch: rootEpoch
            )
        case let .hit(snapshot):
            updatePreviouslyObservedManifestAuthority(
                snapshot.authority,
                context: context,
                rootEpoch: rootEpoch
            )
        }
        guard case let .hit(snapshot) = load,
              snapshot.records.count <= policy.maximumManifestAdoptionRecordCount
        else {
            updateManifestState(.miss, context: context, rootEpoch: rootEpoch)
            emit(.manifestLoadMiss, rootEpoch: rootEpoch)
            return .terminal(adoptedReadyCount: 0)
        }
        guard let adoptionID = reserveAdoptionRecords(
            snapshot.records.count,
            scope: pipelineScope
        ) else {
            recordBusy(rootEpoch)
            return .retryable
        }
        emit(.manifestLoadHit, rootEpoch: rootEpoch, numericValue: UInt64(snapshot.records.count))

        var prepared: [PreparedManifestAdoption] = []
        for record in snapshot.records {
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard record.locatorIdentity.repositoryNamespace == initial.capability.repositoryNamespace,
                  record.locatorIdentity.blobOID.objectFormat == initial.capability.objectFormat,
                  record.locatorIdentity.pipelineIdentity == initialPipeline.pipelineIdentity,
                  let loadedPath = loadedRootPath(
                      repositoryRelativePath: record.repositoryRelativePath,
                      prefix: initial.capability.repositoryRelativeLoadedRootPrefix
                  ), !loadedPath.isEmpty
            else { continue }
            let candidate = await catalogClient.resolveManifestBinding(rootEpoch, loadedPath)
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard let candidate,
                  candidate.identity.rootID == rootEpoch.rootID,
                  candidate.identity.rootLifetimeID == rootEpoch.rootLifetimeID,
                  candidate.identity.standardizedRootPath ==
                  initial.registration.capabilityRequest.loadedRootURL.path,
                  candidate.identity.standardizedRelativePath == loadedPath,
                  candidate.ingressGeneration == initial.registration.ingressGeneration
            else { continue }

            let classificationBatch = await identityService.classify(
                workspaceRoot: initial.registration.capabilityRequest.loadedRootURL,
                relativePaths: [loadedPath]
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard classificationBatch.failure == nil,
                  classificationBatch.classifications.count == 1,
                  let classification = classificationBatch.classifications.first,
                  manifestClassificationMatches(
                      classification,
                      record: record,
                      candidate: candidate,
                      session: initial
                  )
            else { continue }

            let sourceAuthority = await capabilityService.makeSourceAuthority(
                capability: initial.capability,
                observedRootEpoch: rootEpoch,
                observedRepositoryAuthority: initial.capability.repositoryAuthority,
                candidateRepositoryRelativePath: record.repositoryRelativePath,
                observedPathGeneration: candidate.pathGeneration,
                currentPathGeneration: candidate.pathGeneration,
                observedIngressGeneration: candidate.ingressGeneration,
                currentIngressGeneration: initial.registration.ingressGeneration
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard let sourceAuthority else { continue }

            let coordinatorResult = try? await runtime.coordinator.resolve(
                CodeMapArtifactBuildRequest(
                    ownerID: rootEpoch.rootLifetimeID,
                    priority: .explicit,
                    target: .artifactKey(record.artifactKey)
                )
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard case let .ready(resolution) = coordinatorResult,
                  let association = try? VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                      identity: record.locatorIdentity,
                      artifactKey: record.artifactKey,
                      casHandle: resolution.handle
                  ), let verifiedRecord = try? makeManifestRecord(
                      session: initial,
                      pipeline: initialPipeline,
                      repositoryRelativePath: record.repositoryRelativePath,
                      gitMode: record.gitMode,
                      association: association,
                      bindingGeneration: record.bindingGeneration
                  )
            else { continue }

            guard record.outcome == .ready || record.outcome == .readyNoSymbols else {
                prepared.append(PreparedManifestAdoption(
                    record: verifiedRecord,
                    candidate: candidate,
                    sourceAuthority: sourceAuthority,
                    association: association,
                    lease: nil
                ))
                continue
            }
            guard reserveAdoptionLease(
                relativePath: candidate.identity.standardizedRelativePath,
                bytes: resolution.handle.estimatedResidentByteCount,
                scope: pipelineScope,
                adoptionID: adoptionID
            ) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                recordBusy(rootEpoch)
                return .retryable
            }
            guard let lease = try? await runtime.coordinator.acquireLease(for: resolution) else {
                releaseAdoptionLeaseReservation(
                    relativePath: candidate.identity.standardizedRelativePath,
                    scope: pipelineScope,
                    adoptionID: adoptionID
                )
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .retryable
            }
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await lease.close()
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            prepared.append(PreparedManifestAdoption(
                record: verifiedRecord,
                candidate: candidate,
                sourceAuthority: sourceAuthority,
                association: association,
                lease: lease
            ))
        }

        guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
            await closePreparedManifestAdoptions(prepared)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            return .superseded
        }

        for item in prepared {
            let refreshed = await catalogClient.resolveManifestBinding(
                rootEpoch,
                item.candidate.identity.standardizedRelativePath
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch),
                  let refreshed,
                  manifestBindingCandidateMatches(refreshed, item.candidate)
            else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                if adoptionContextIsCurrent(context, rootEpoch: rootEpoch) {
                    updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
                }
                return .retryable
            }
        }

        if !prepared.isEmpty {
            let finalClassification = await identityService.classify(
                workspaceRoot: initial.registration.capabilityRequest.loadedRootURL,
                relativePaths: prepared.map(\.candidate.identity.standardizedRelativePath)
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch),
                  finalClassification.failure == nil,
                  finalClassification.classifications.count == prepared.count,
                  zip(finalClassification.classifications, prepared).allSatisfy({
                      manifestClassificationMatches(
                          $0.0,
                          record: $0.1.record,
                          candidate: $0.1.candidate,
                          session: initial
                      )
                  })
            else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                if adoptionContextIsCurrent(context, rootEpoch: rootEpoch) {
                    updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
                }
                return .retryable
            }
        }

        let authoritiesAreCurrent = await capabilityService.revalidateSourceAuthorities(
            capability: initial.capability,
            tokens: prepared.map(\.sourceAuthority)
        )
        guard authoritiesAreCurrent,
              adoptionContextIsCurrent(context, rootEpoch: rootEpoch)
        else {
            await closePreparedManifestAdoptions(prepared)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            if adoptionContextIsCurrent(context, rootEpoch: rootEpoch) {
                updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
            }
            return .retryable
        }

        guard finalizeAdoptionRecordReservation(
            prepared.count,
            scope: pipelineScope,
            adoptionID: adoptionID
        ) else {
            await closePreparedManifestAdoptions(prepared)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            recordBusy(rootEpoch)
            return .retryable
        }

        var verifiedRecords: [String: CodeMapRootManifestRecord] = [:]
        var pathGenerations: [String: UInt64] = [:]
        var entries: [WorkspaceCodemapLiveManifestAdoptionEntry] = []
        for item in prepared {
            verifiedRecords[item.record.repositoryRelativePath] = item.record
            pathGenerations[item.candidate.identity.standardizedRelativePath] = item.candidate.pathGeneration
            guard let lease = item.lease else { continue }
            guard let expectation = WorkspaceCodemapSourceExpectation.cleanGitBlob(
                bindingIdentity: item.candidate.identity,
                locatorIdentity: item.record.locatorIdentity,
                sourceAuthority: item.sourceAuthority
            ), let token = WorkspaceCodemapArtifactRequestToken.issue(
                identity: item.candidate.identity,
                requestGeneration: item.candidate.requestGeneration,
                catalogGeneration: initial.registration.catalogGeneration,
                sourceExpectation: expectation
            ), let completion = WorkspaceCodemapArtifactCompletion.cleanGitBlob(
                token: token,
                language: initialPipeline.language,
                association: item.association
            ), var binding = WorkspaceCodemapArtifactBinding(pending: token),
            binding.apply(completion) == .accepted
            else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
                return .retryable
            }
            entries.append(WorkspaceCodemapLiveManifestAdoptionEntry(
                record: item.record,
                binding: binding,
                lease: lease
            ))
        }
        let disposition = await overlay.adoptManifest(
            ticket: ticket,
            snapshot: snapshot,
            readyEntries: entries
        )
        let stillCurrent = adoptionContextIsCurrent(context, rootEpoch: rootEpoch)
        switch disposition {
        case let .adopted(count):
            guard stillCurrent,
                  case var .eligible(session)? = roots[rootEpoch],
                  var pipeline = session.pipelines[pipelineIdentity],
                  adoptionReservations[pipelineScope]?.id == adoptionID,
                  let reservation = adoptionReservations.removeValue(forKey: pipelineScope)
            else {
                _ = await overlay.rollbackManifestAdoption(
                    ticket: ticket,
                    manifestGeneration: snapshot.manifestGeneration
                )
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            pipeline.manifestRecords = verifiedRecords
            for (path, generation) in pathGenerations {
                session.pathGenerations[path] = generation
            }
            pipeline.manifestState = .clean(generation: snapshot.manifestGeneration)
            pipeline.persistedManifestRevision = pipeline.manifestRevision
            session.pipelines[pipelineIdentity] = pipeline
            roots[rootEpoch] = .eligible(session)
            retainedAdoptions[pipelineScope] = reservation
            pruneAdmissionHistory()
            incrementCounter(\.manifestAdoptions)
            emit(.manifestAdopted, rootEpoch: rootEpoch, numericValue: UInt64(count))
            return .terminal(adoptedReadyCount: count)
        case .exactDuplicate:
            await closeAdoptionEntries(entries)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            return .terminal(adoptedReadyCount: 0)
        case .busy, .rejected:
            await closeAdoptionEntries(entries)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            if stillCurrent {
                updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
            }
            return .retryable
        }
    }

    private func ensureManifestAdoption(
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity
    ) async {
        let scope = PipelineScope(rootEpoch: rootEpoch, pipelineIdentity: pipelineIdentity)
        guard case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[pipelineIdentity]
        else { return }
        if pipeline.manifestLoadFinished { return }
        if let operation = manifestAdoptionOperations[scope] {
            await waitForManifestAdoption(
                scope: scope,
                operationID: operation.attempt.operationID
            )
            return
        }
        let attempt = ManifestAdoptionAttempt(
            operationID: UUID(),
            scope: scope,
            sessionID: session.id,
            sessionGeneration: session.generation,
            invalidationGeneration: session.invalidationGeneration,
            pipelineSessionID: pipeline.id,
            catalogGeneration: session.registration.catalogGeneration,
            repositoryAuthority: session.capability.repositoryAuthority,
            namespace: pipeline.namespace,
            authority: pipeline.authority,
            manifestRevision: pipeline.manifestRevision
        )
        pipeline.manifestLoadStarted = true
        session.pipelines[pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
        let task = Task {
            await self.loadAndAdoptManifest(rootEpoch: rootEpoch, attempt: attempt)
        }
        manifestAdoptionOperations[scope] = ManifestAdoptionOperation(
            attempt: attempt,
            task: task,
            waiters: [:]
        )
        Task { [weak self] in
            let outcome = await task.value
            await self?.completeManifestAdoption(
                scope: scope,
                operationID: attempt.operationID,
                outcome: outcome
            )
        }
        await waitForManifestAdoption(scope: scope, operationID: attempt.operationID)
    }

    private func waitForManifestAdoption(
        scope: PipelineScope,
        operationID: UUID
    ) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      var operation = manifestAdoptionOperations[scope],
                      operation.attempt.operationID == operationID
                else {
                    continuation.resume()
                    return
                }
                operation.waiters[waiterID] = continuation
                manifestAdoptionOperations[scope] = operation
            }
        } onCancel: {
            Task {
                await self.detachManifestAdoptionWaiter(
                    scope: scope,
                    operationID: operationID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func detachManifestAdoptionWaiter(
        scope: PipelineScope,
        operationID: UUID,
        waiterID: UUID
    ) {
        guard var operation = manifestAdoptionOperations[scope],
              operation.attempt.operationID == operationID,
              let waiter = operation.waiters.removeValue(forKey: waiterID)
        else { return }
        manifestAdoptionOperations[scope] = operation
        waiter.resume()
    }

    private func completeManifestAdoption(
        scope: PipelineScope,
        operationID: UUID,
        outcome: ManifestAdoptionOutcome
    ) {
        drainingManifestAdoptionTasks.removeValue(forKey: operationID)
        guard let operation = manifestAdoptionOperations[scope],
              operation.attempt.operationID == operationID
        else { return }
        manifestAdoptionOperations.removeValue(forKey: scope)
        let attempt = operation.attempt
        if case var .eligible(current)? = roots[scope.rootEpoch],
           current.id == attempt.sessionID,
           current.generation == attempt.sessionGeneration,
           current.invalidationGeneration == attempt.invalidationGeneration,
           var currentPipeline = current.pipelines[scope.pipelineIdentity],
           currentPipeline.id == attempt.pipelineSessionID,
           currentPipeline.manifestRevision == attempt.manifestRevision
        {
            switch outcome {
            case .terminal:
                currentPipeline.manifestLoadFinished = true
            case .retryable:
                currentPipeline.manifestLoadStarted = false
                currentPipeline.manifestLoadFinished = false
                currentPipeline.manifestState = .dirtyRetryRequired
            case .superseded:
                break
            }
            current.pipelines[scope.pipelineIdentity] = currentPipeline
            roots[scope.rootEpoch] = .eligible(current)
        }
        for waiter in operation.waiters.values {
            waiter.resume()
        }
    }

    private func manifestClassificationMatches(
        _ classification: GitBlobIdentityClassification,
        record: CodeMapRootManifestRecord,
        candidate: WorkspaceCodemapManifestBindingCandidate,
        session: Session
    ) -> Bool {
        guard classification.relativePath == candidate.identity.standardizedRelativePath,
              classification.repositoryRelativePath == record.repositoryRelativePath,
              classification.objectFormat == session.capability.objectFormat,
              classification.porcelainRecord == nil,
              !classification.intentToAdd,
              !classification.hasConflictStages,
              !classification.skipWorktree,
              !classification.assumeUnchanged,
              classification.checkoutMaterialization == .bytePreserving,
              gitMode(classification) == record.gitMode,
              case let .oidEligible(currentOID) = classification.outcome,
              currentOID == record.locatorIdentity.blobOID
        else { return false }
        return true
    }

    private func manifestBindingCandidateMatches(
        _ lhs: WorkspaceCodemapManifestBindingCandidate,
        _ rhs: WorkspaceCodemapManifestBindingCandidate
    ) -> Bool {
        lhs.identity == rhs.identity &&
            lhs.requestGeneration == rhs.requestGeneration &&
            lhs.pathGeneration == rhs.pathGeneration &&
            lhs.ingressGeneration == rhs.ingressGeneration
    }

    private func manifestAdoptionIsCurrent(
        _ context: ManifestAdoptionContext,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> Bool {
        guard adoptionContextIsCurrent(context, rootEpoch: rootEpoch) else { return false }
        guard await overlay.isManifestAdoptionTicketCurrent(context.ticket) else { return false }
        return adoptionContextIsCurrent(context, rootEpoch: rootEpoch)
    }

    private func adoptionContextIsCurrent(
        _ context: ManifestAdoptionContext,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        let scope = PipelineScope(
            rootEpoch: rootEpoch,
            pipelineIdentity: context.pipelineIdentity
        )
        guard manifestAdoptionOperations[scope]?.attempt.operationID == context.operationID,
              case let .eligible(session)? = roots[rootEpoch],
              let pipeline = session.pipelines[context.pipelineIdentity]
        else { return false }
        return session.id == context.sessionID &&
            session.generation == context.sessionGeneration &&
            session.invalidationGeneration == context.invalidationGeneration &&
            pipeline.id == context.pipelineSessionID &&
            session.registration.catalogGeneration == context.catalogGeneration &&
            session.capability.repositoryAuthority == context.repositoryAuthority &&
            pipeline.namespace == context.namespace &&
            pipeline.authority == context.authority &&
            pipeline.manifestRevision == context.manifestRevision
    }

    private func updateManifestState(
        _ state: WorkspaceCodemapBindingManifestState,
        context: ManifestAdoptionContext,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard adoptionContextIsCurrent(context, rootEpoch: rootEpoch),
              case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[context.pipelineIdentity]
        else { return }
        pipeline.manifestState = state
        session.pipelines[context.pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
    }

    private func updatePreviouslyObservedManifestAuthority(
        _ authority: CodeMapRootManifestAuthority?,
        context: ManifestAdoptionContext,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard adoptionContextIsCurrent(context, rootEpoch: rootEpoch),
              case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[context.pipelineIdentity]
        else { return }
        pipeline.previouslyObservedManifestAuthority = authority
        session.pipelines[context.pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
    }

    private func reserveAdoptionRecords(
        _ count: Int,
        scope: PipelineScope
    ) -> UUID? {
        let currentRootRecordCount: Int
        let replacedRecordCount: Int
        if case let .eligible(session)? = roots[scope.rootEpoch] {
            currentRootRecordCount = session.pipelines.values.reduce(0) {
                addingSaturating($0, $1.manifestRecords.count)
            }
            replacedRecordCount = session.pipelines[scope.pipelineIdentity]?.manifestRecords.count ?? 0
        } else {
            currentRootRecordCount = 0
            replacedRecordCount = 0
        }
        let pendingRootCount = adoptionReservations.reduce(0) { partial, item in
            guard item.key.rootEpoch == scope.rootEpoch, item.key != scope else { return partial }
            return addingSaturating(partial, item.value.recordCount)
        }
        let pendingCount = adoptionReservations.values.reduce(0) {
            addingSaturating($0, $1.recordCount)
        }
        guard let projectedRootCount = addingChecked(
            max(0, currentRootRecordCount - replacedRecordCount),
            addingSaturating(pendingRootCount, count)
        ),
            projectedRootCount <= policy.maximumRetainedManifestRecordCountPerRoot,
            adoptionReservations[scope] == nil,
            let reservedCount = addingChecked(
                max(0, retainedManifestRecordCount(excluding: nil) - replacedRecordCount),
                pendingCount
            ),
            let projectedCount = addingChecked(reservedCount, count),
            projectedCount <= policy.maximumRetainedManifestRecordCount
        else { return nil }
        let adoptionID = UUID()
        adoptionReservations[scope] = AdoptionReservation(
            id: adoptionID,
            recordCount: count,
            leaseBytesByRelativePath: [:]
        )
        return adoptionID
    }

    private func finalizeAdoptionRecordReservation(
        _ count: Int,
        scope: PipelineScope,
        adoptionID: UUID
    ) -> Bool {
        guard var reservation = adoptionReservations[scope],
              reservation.id == adoptionID,
              count <= reservation.recordCount,
              count <= policy.maximumRetainedManifestRecordCountPerRoot
        else { return false }
        reservation.recordCount = count
        adoptionReservations[scope] = reservation
        return true
    }

    private func reserveAdoptionLease(
        relativePath: String,
        bytes: UInt64,
        scope: PipelineScope,
        adoptionID: UUID
    ) -> Bool {
        guard var reservation = adoptionReservations[scope],
              reservation.id == adoptionID,
              reservation.leaseBytesByRelativePath[relativePath] == nil,
              let usage = adoptionLeaseUsage(),
              let rootUsage = adoptionLeaseUsage(rootEpoch: scope.rootEpoch),
              let projectedRootCount = addingChecked(rootUsage.count, 1),
              let projectedGlobalCount = addingChecked(usage.count, 1),
              let projectedRootBytes = addingChecked(rootUsage.bytes, bytes),
              let projectedGlobalBytes = addingChecked(usage.bytes, bytes),
              projectedRootCount <= policy.maximumManifestAdoptionLeaseCountPerRoot,
              projectedGlobalCount <= policy.maximumManifestAdoptionLeaseCount,
              projectedRootBytes <= policy.maximumManifestAdoptionLeaseByteCountPerRoot,
              projectedGlobalBytes <= policy.maximumManifestAdoptionLeaseByteCount
        else { return false }
        reservation.leaseBytesByRelativePath[relativePath] = bytes
        adoptionReservations[scope] = reservation
        return true
    }

    private func releaseAdoptionLeaseReservation(
        relativePath: String,
        scope: PipelineScope,
        adoptionID: UUID
    ) {
        guard var reservation = adoptionReservations[scope],
              reservation.id == adoptionID
        else { return }
        reservation.leaseBytesByRelativePath.removeValue(forKey: relativePath)
        adoptionReservations[scope] = reservation
    }

    private func adoptionLeaseUsage() -> (count: Int, bytes: UInt64)? {
        let reservations = Array(adoptionReservations.values) + Array(retainedAdoptions.values)
        var count = 0
        var bytes: UInt64 = 0
        for reservation in reservations {
            guard let nextCount = addingChecked(count, reservation.leaseCount),
                  let nextBytes = addingChecked(bytes, reservation.leaseBytes)
            else { return nil }
            count = nextCount
            bytes = nextBytes
        }
        return (count, bytes)
    }

    private func adoptionLeaseUsage(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> (count: Int, bytes: UInt64)? {
        let reservations = adoptionReservations.filter { $0.key.rootEpoch == rootEpoch }.map(\.value) +
            retainedAdoptions.filter { $0.key.rootEpoch == rootEpoch }.map(\.value)
        var count = 0
        var bytes: UInt64 = 0
        for reservation in reservations {
            guard let nextCount = addingChecked(count, reservation.leaseCount),
                  let nextBytes = addingChecked(bytes, reservation.leaseBytes)
            else { return nil }
            count = nextCount
            bytes = nextBytes
        }
        return (count, bytes)
    }

    private func releaseAdoptionReservation(
        scope: PipelineScope,
        adoptionID: UUID
    ) {
        guard adoptionReservations[scope]?.id == adoptionID else { return }
        adoptionReservations.removeValue(forKey: scope)
        pruneAdmissionHistory()
    }

    private func releaseRetainedAdoptionPaths(
        _ relativePaths: Set<String>,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        for scope in retainedAdoptions.keys where scope.rootEpoch == rootEpoch {
            guard var retained = retainedAdoptions[scope] else { continue }
            var removedRecordCount = 0
            for relativePath in relativePaths {
                if retained.leaseBytesByRelativePath.removeValue(forKey: relativePath) != nil {
                    removedRecordCount += 1
                }
            }
            retained.recordCount = max(0, retained.recordCount - removedRecordCount)
            if retained.leaseBytesByRelativePath.isEmpty, retained.recordCount == 0 {
                retainedAdoptions.removeValue(forKey: scope)
            } else {
                retainedAdoptions[scope] = retained
            }
        }
    }

    private func closePreparedManifestAdoptions(
        _ prepared: [PreparedManifestAdoption]
    ) async {
        for item in prepared {
            await item.lease?.close()
        }
    }

    private func closeAdoptionEntries(
        _ entries: [WorkspaceCodemapLiveManifestAdoptionEntry]
    ) async {
        for entry in entries {
            await entry.lease.close()
        }
    }

    private func retainedManifestRecordCount(excluding rootEpoch: WorkspaceCodemapRootEpoch?) -> Int {
        roots.reduce(0) { partial, item in
            if item.key == rootEpoch { return partial }
            guard case let .eligible(session) = item.value else { return partial }
            return session.pipelines.values.reduce(partial) {
                addingSaturating($0, $1.manifestRecords.count)
            }
        }
    }

    private func admitOrQueue(
        requestID: UUID,
        demand: WorkspaceCodemapBindingDemand,
        cancellation: DemandCancellationState,
        continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult, Never>
    ) {
        guard !cancellation.isCancelled else {
            continuation.resume(returning: .cancelled)
            return
        }
        switch validateDemand(demand) {
        case let .result(result):
            continuation.resume(returning: result)
        case let .valid(context):
            if canAdmit(demand, rootEpoch: context.rootEpoch) {
                startRequest(
                    requestID: requestID,
                    demand: demand,
                    context: context,
                    continuation: continuation
                )
            } else if canQueue(demand, rootEpoch: context.rootEpoch) {
                ensureQueueOrdinalCapacity()
                guard let next = addingChecked(nextQueueOrdinal, 1) else {
                    recordBusy(context.rootEpoch)
                    continuation.resume(returning: .busy(retryAfterMilliseconds: nil))
                    return
                }
                let ordinal = nextQueueOrdinal
                nextQueueOrdinal = next
                queuedRequests[requestID] = QueuedRequest(
                    id: requestID,
                    rootEpoch: context.rootEpoch,
                    demand: demand,
                    enqueueOrdinal: ordinal,
                    continuation: continuation
                )
                queueOrder.append(requestID)
            } else {
                recordBusy(context.rootEpoch)
                continuation.resume(returning: .busy(retryAfterMilliseconds: nil))
            }
        }
    }

    private func validateDemand(_ demand: WorkspaceCodemapBindingDemand) -> DemandValidation {
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: demand.identity.rootID,
            rootLifetimeID: demand.identity.rootLifetimeID
        )
        guard let root = roots[rootEpoch] else { return .result(.rejected(.rootNotRegistered)) }
        guard case let .eligible(session) = root else {
            return .result(.rejected(.capabilityUnavailable))
        }
        guard demand.identity.rootID == session.capability.rootEpoch.rootID,
              demand.identity.rootLifetimeID == session.capability.rootEpoch.rootLifetimeID
        else { return .result(.rejected(.rootEpochMismatch)) }
        guard demand.identity.standardizedRootPath ==
            session.registration.capabilityRequest.loadedRootURL.path
        else { return .result(.rejected(.rootPathMismatch)) }
        guard WorkspaceCodemapArtifactBindingIdentity(
            rootID: demand.identity.rootID,
            rootLifetimeID: demand.identity.rootLifetimeID,
            fileID: demand.identity.fileID,
            standardizedRootPath: demand.identity.standardizedRootPath,
            standardizedRelativePath: demand.identity.standardizedRelativePath,
            standardizedFullPath: demand.identity.standardizedFullPath
        ) == demand.identity
        else { return .result(.rejected(.invalidIdentity)) }
        guard demand.catalogGeneration == session.registration.catalogGeneration else {
            return .result(.rejected(.catalogGenerationMismatch))
        }
        guard demand.requestGeneration > 0 else {
            return .result(.rejected(.requestGenerationInvalid))
        }
        let fileExtension = (demand.identity.standardizedRelativePath as NSString).pathExtension
        guard SyntaxManager.shared.language(forFileExtension: fileExtension) == demand.language else {
            return .result(.unavailable(.unsupportedFileType))
        }
        let pipelineIdentity: CodeMapPipelineIdentity
        do {
            pipelineIdentity = try ensurePipeline(
                rootEpoch: rootEpoch,
                language: demand.language
            )
        } catch {
            return .result(.unavailable(.unsupportedFileType))
        }
        guard case let .eligible(updatedSession)? = roots[rootEpoch] else {
            return .result(.rejected(.staleCompletion))
        }
        let currentPathGeneration = session.pathGenerations[demand.identity.standardizedRelativePath]
            ?? demand.pathGeneration
        guard currentPathGeneration == demand.pathGeneration else {
            return .result(.rejected(.stalePathGeneration))
        }
        guard demand.ingressGeneration == session.registration.ingressGeneration else {
            return .result(.rejected(.staleIngressGeneration))
        }
        return .valid(ValidatedDemandContext(
            rootEpoch: rootEpoch,
            session: updatedSession,
            pipelineIdentity: pipelineIdentity,
            pathGeneration: currentPathGeneration
        ))
    }

    private func ensurePipeline(
        rootEpoch: WorkspaceCodemapRootEpoch,
        language: LanguageType
    ) throws -> CodeMapPipelineIdentity {
        guard case var .eligible(session)? = roots[rootEpoch] else {
            throw WorkspaceCodemapBindingEngineProviderError.unconfigured
        }
        let pipelineIdentity = try SyntaxManager.shared.pipelineIdentity(
            for: language,
            decoderPolicy: .workspaceAutomaticV1
        )
        if let existing = session.pipelines[pipelineIdentity] {
            guard existing.language == language else {
                throw WorkspaceCodemapBindingEngineProviderError.unconfigured
            }
            return pipelineIdentity
        }
        let namespace = try CodeMapRootManifestNamespace(
            capability: session.capability,
            pipelineIdentity: pipelineIdentity
        )
        let authority = try CodeMapRootManifestAuthority(
            namespace: namespace,
            token: session.capability.repositoryAuthority
        )
        session.pipelines[pipelineIdentity] = PipelineSession(
            id: UUID(),
            language: language,
            pipelineIdentity: pipelineIdentity,
            namespace: namespace,
            authority: authority,
            previouslyObservedManifestAuthority: nil,
            manifestRecords: [:],
            manifestState: .miss,
            manifestLoadStarted: false,
            manifestLoadFinished: false,
            manifestRevision: 0,
            persistedManifestRevision: 0,
            pendingManifestChanges: [:]
        )
        roots[rootEpoch] = .eligible(session)
        return pipelineIdentity
    }

    private func canAdmit(
        _ demand: WorkspaceCodemapBindingDemand,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        let rootRequests = activeRequests.values.filter { $0.rootEpoch == rootEpoch }
        let ownerRequests = rootRequests.filter { $0.publicOwner == demand.owner }
        let owners = Set(rootRequests.map(\.publicOwner))
        let sourceBytes = UInt64(policy.maximumValidatedWorktreeByteCount)
        let rootSourceBytes = rootRequests.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let ownerSourceBytes = ownerRequests.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let globalSourceBytes = activeRequests.values.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        return activeRequests.count < policy.maximumActiveRequestCount &&
            rootRequests.count < policy.maximumActiveRequestCountPerRoot &&
            ownerRequests.count < policy.maximumActiveRequestCountPerOwner &&
            activeRequests.count < policy.maximumActiveTaskCount &&
            rootRequests.count < policy.maximumActiveTaskCountPerRoot &&
            ownerRequests.count < policy.maximumActiveTaskCountPerOwner &&
            activeRequests.count < policy.maximumConcurrentMaterializationCount &&
            rootRequests.count < policy.maximumConcurrentMaterializationCountPerRoot &&
            ownerRequests.count < policy.maximumConcurrentMaterializationCountPerOwner &&
            (owners.contains(demand.owner) || owners.count < policy.maximumOwnerCountPerRoot) &&
            addingSaturating(globalSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCount &&
            addingSaturating(rootSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCountPerRoot &&
            addingSaturating(ownerSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCountPerOwner
    }

    private func canQueue(
        _ demand: WorkspaceCodemapBindingDemand,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        let rootCount = queuedRequests.values.count(where: { $0.rootEpoch == rootEpoch })
        let ownerCount = queuedRequests.values.count(where: {
            $0.rootEpoch == rootEpoch && $0.demand.owner == demand.owner
        })
        return queuedRequests.count < policy.maximumQueuedRequestCount &&
            rootCount < policy.maximumQueuedRequestCountPerRoot &&
            ownerCount < policy.maximumQueuedRequestCountPerOwner
    }

    private func startRequest(
        requestID: UUID,
        demand: WorkspaceCodemapBindingDemand,
        context: ValidatedDemandContext,
        continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult, Never>?
    ) {
        guard let pipeline = context.session.pipelines[context.pipelineIdentity] else {
            continuation?.resume(returning: .rejected(.staleCompletion))
            return
        }
        let sourceBytes = UInt64(policy.maximumValidatedWorktreeByteCount)
        activeRequests[requestID] = ActiveRequest(
            id: requestID,
            rootEpoch: context.rootEpoch,
            demand: demand,
            publicOwner: demand.owner,
            relativePath: demand.identity.standardizedRelativePath,
            sessionID: context.session.id,
            sessionGeneration: context.session.generation,
            pipelineIdentity: context.pipelineIdentity,
            pipelineSessionID: pipeline.id,
            repositoryAuthority: context.session.capability.repositoryAuthority,
            reservedSourceBytes: sourceBytes,
            overlayOwner: nil,
            preflight: nil,
            ticket: nil,
            task: nil,
            continuation: continuation,
            cancelled: false
        )
        recordAdmission(demand: demand, rootEpoch: context.rootEpoch)
        let task = Task { await self.executeRequest(requestID: requestID) }
        guard var request = activeRequests[requestID] else {
            task.cancel()
            return
        }
        request.task = task
        activeRequests[requestID] = request
    }

    private func recordAdmission(
        demand: WorkspaceCodemapBindingDemand,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        ensureAdmissionOrdinalCapacity()
        if let next = addingChecked(nextAdmissionOrdinal, 1) {
            let ordinal = nextAdmissionOrdinal
            nextAdmissionOrdinal = next
            rootLastAdmission[rootEpoch] = ordinal
            ownerLastAdmission[OwnerKey(rootEpoch: rootEpoch, owner: demand.owner)] = ordinal
        }
        switch demand.priority {
        case .demand:
            if consecutiveDemandAdmissions < policy.maximumConsecutiveDemandAdmissions {
                consecutiveDemandAdmissions += 1
            }
        case .explicit:
            consecutiveDemandAdmissions = 0
        }
    }

    private func scheduleQueuedRequests() {
        defer { pruneAdmissionHistory() }
        while true {
            var madeProgress = false
            for requestID in queueOrder {
                guard let queued = queuedRequests[requestID] else { continue }
                switch validateDemand(queued.demand) {
                case let .result(result):
                    queuedRequests.removeValue(forKey: requestID)
                    queueOrder.removeAll { $0 == requestID }
                    queued.continuation?.resume(returning: result)
                    madeProgress = true
                case .valid:
                    continue
                }
            }
            if madeProgress { continue }
            guard let requestID = selectQueuedRequest(),
                  let queued = queuedRequests.removeValue(forKey: requestID)
            else { return }
            queueOrder.removeAll { $0 == requestID }
            guard case let .valid(context) = validateDemand(queued.demand) else {
                queued.continuation?.resume(returning: .rejected(.staleCompletion))
                continue
            }
            startRequest(
                requestID: requestID,
                demand: queued.demand,
                context: context,
                continuation: queued.continuation
            )
        }
    }

    private func selectQueuedRequest() -> UUID? {
        let eligible = queueOrder.compactMap { queuedRequests[$0] }.filter {
            canAdmit($0.demand, rootEpoch: $0.rootEpoch)
        }
        guard !eligible.isEmpty else { return nil }
        let hasDemand = eligible.contains { $0.demand.priority == .demand }
        let hasExplicit = eligible.contains { $0.demand.priority == .explicit }
        let preferredPriority: CodeMapArtifactBuildPriority = if hasDemand,
                                                                 !hasExplicit || consecutiveDemandAdmissions < policy.maximumConsecutiveDemandAdmissions
        {
            .demand
        } else {
            .explicit
        }
        return eligible.filter { $0.demand.priority == preferredPriority }.min { lhs, rhs in
            let leftRoot = rootLastAdmission[lhs.rootEpoch] ?? 0
            let rightRoot = rootLastAdmission[rhs.rootEpoch] ?? 0
            if leftRoot != rightRoot { return leftRoot < rightRoot }
            let leftOwner = ownerLastAdmission[
                OwnerKey(rootEpoch: lhs.rootEpoch, owner: lhs.demand.owner)
            ] ?? 0
            let rightOwner = ownerLastAdmission[
                OwnerKey(rootEpoch: rhs.rootEpoch, owner: rhs.demand.owner)
            ] ?? 0
            if leftOwner != rightOwner { return leftOwner < rightOwner }
            return lhs.enqueueOrdinal < rhs.enqueueOrdinal
        }?.id
    }

    private func ensureQueueOrdinalCapacity() {
        guard nextQueueOrdinal == .max else { return }
        var ordinal: UInt64 = 1
        for requestID in queueOrder {
            guard var request = queuedRequests[requestID] else { continue }
            request.enqueueOrdinal = ordinal
            queuedRequests[requestID] = request
            guard let next = addingChecked(ordinal, 1) else { return }
            ordinal = next
        }
        nextQueueOrdinal = ordinal
    }

    private func ensureAdmissionOrdinalCapacity() {
        guard nextAdmissionOrdinal == .max else { return }
        pruneAdmissionHistory()
        var rootOrdinal: UInt64 = 1
        for (key, _) in rootLastAdmission.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let left = lhs.key.rootID.uuidString + lhs.key.rootLifetimeID.uuidString
            let right = rhs.key.rootID.uuidString + rhs.key.rootLifetimeID.uuidString
            return left < right
        }) {
            rootLastAdmission[key] = rootOrdinal
            guard let next = addingChecked(rootOrdinal, 1) else { return }
            rootOrdinal = next
        }
        var ownerOrdinal: UInt64 = 1
        for (key, _) in ownerLastAdmission.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let left = lhs.key.rootEpoch.rootID.uuidString +
                lhs.key.rootEpoch.rootLifetimeID.uuidString + lhs.key.owner.rawValue.uuidString
            let right = rhs.key.rootEpoch.rootID.uuidString +
                rhs.key.rootEpoch.rootLifetimeID.uuidString + rhs.key.owner.rawValue.uuidString
            return left < right
        }) {
            ownerLastAdmission[key] = ownerOrdinal
            guard let next = addingChecked(ownerOrdinal, 1) else { return }
            ownerOrdinal = next
        }
        nextAdmissionOrdinal = max(rootOrdinal, ownerOrdinal)
    }

    private func pruneAdmissionHistory() {
        var retainedRoots = Set(activeRequests.values.map(\.rootEpoch))
        retainedRoots.formUnion(queuedRequests.values.map(\.rootEpoch))
        retainedRoots.formUnion(adoptionReservations.keys.map(\.rootEpoch))
        retainedRoots.formUnion(retainedAdoptions.keys.map(\.rootEpoch))
        rootLastAdmission = rootLastAdmission.filter { retainedRoots.contains($0.key) }

        var retainedOwners = Set(activeRequests.values.map {
            OwnerKey(rootEpoch: $0.rootEpoch, owner: $0.publicOwner)
        })
        retainedOwners.formUnion(queuedRequests.values.map {
            OwnerKey(rootEpoch: $0.rootEpoch, owner: $0.demand.owner)
        })
        ownerLastAdmission = ownerLastAdmission.filter { retainedOwners.contains($0.key) }
        if activeRequests.isEmpty, queuedRequests.isEmpty {
            consecutiveDemandAdmissions = 0
        }
    }

    private func executeRequest(requestID: UUID) async {
        let result: WorkspaceCodemapBindingDemandResult
        do {
            result = try await processRequest(requestID: requestID)
        } catch is CancellationError {
            result = .cancelled
        } catch GitBlobSourceMaterializationError.oversized {
            result = .unavailable(.oversized)
        } catch let error as CodeMapArtifactBuildCoordinatorError {
            if case let .busy(retryAfterMilliseconds) = error {
                if let request = activeRequests[requestID] { recordBusy(request.rootEpoch) }
                result = .busy(retryAfterMilliseconds: retryAfterMilliseconds)
            } else {
                if let request = activeRequests[requestID] { recordFailure(request.rootEpoch) }
                result = .unavailable(.transient)
            }
        } catch {
            if let request = activeRequests[requestID] { recordFailure(request.rootEpoch) }
            result = .unavailable(.transient)
        }
        await finishRequest(requestID: requestID, result: result, cancelOverlay: true)
    }

    private func processRequest(
        requestID: UUID
    ) async throws -> WorkspaceCodemapBindingDemandResult {
        guard let initialRequest = currentRequest(requestID) else { throw CancellationError() }
        await ensureManifestAdoption(
            rootEpoch: initialRequest.rootEpoch,
            pipelineIdentity: initialRequest.pipelineIdentity
        )
        guard let request = currentRequest(requestID),
              case let .eligible(session)? = roots[request.rootEpoch],
              session.pipelines[request.pipelineIdentity]?.id == request.pipelineSessionID
        else { throw CancellationError() }
        try Task.checkCancellation()
        incrementCounter(\.classifications)
        let batch = await identityService.classify(
            workspaceRoot: session.registration.capabilityRequest.loadedRootURL,
            relativePaths: [request.relativePath]
        )
        try Task.checkCancellation()
        guard let current = currentRequest(requestID) else { throw CancellationError() }
        guard batch.failure == nil,
              batch.classifications.count == 1,
              let classification = batch.classifications.first,
              classification.relativePath == current.relativePath,
              let repositoryRelativePath = classification.repositoryRelativePath,
              repositoryRelativePath == repositoryPath(
                  loadedRootRelativePath: current.relativePath,
                  prefix: session.capability.repositoryRelativeLoadedRootPrefix
              )
        else {
            emit(.classificationUnavailable, rootEpoch: current.rootEpoch)
            return .rejected(.classificationMismatch)
        }
        switch classification.outcome {
        case .unavailable:
            return .unavailable(.missing)
        case .securityExcluded:
            return .unavailable(.securityExcluded)
        case .unsupported:
            return .unavailable(.nonRegular)
        case .oidEligible, .requiresValidatedWorktreeBytes:
            break
        }

        let sourceAuthority = await capabilityService.makeSourceAuthority(
            capability: session.capability,
            observedRootEpoch: current.rootEpoch,
            observedRepositoryAuthority: session.capability.repositoryAuthority,
            candidateRepositoryRelativePath: repositoryRelativePath,
            observedPathGeneration: current.demand.pathGeneration,
            currentPathGeneration: current.demand.pathGeneration,
            observedIngressGeneration: current.demand.ingressGeneration,
            currentIngressGeneration: session.registration.ingressGeneration
        )
        try Task.checkCancellation()
        guard let current = currentRequest(requestID) else { throw CancellationError() }
        guard let sourceAuthority else { return .rejected(.sourceAuthorityUnavailable) }
        guard case var .eligible(latest)? = roots[current.rootEpoch], latest.id == current.sessionID else {
            return .rejected(.staleCompletion)
        }
        latest.pathGenerations[current.relativePath] = current.demand.pathGeneration
        roots[current.rootEpoch] = .eligible(latest)

        let preflightDisposition = await preflightOverlayDemand(requestID: requestID)
        let preflight: WorkspaceCodemapLiveDemandPreflightTicket
        switch preflightDisposition {
        case let .reserved(ticket):
            preflight = ticket
        case let .result(result):
            return result
        }

        switch classification.outcome {
        case let .oidEligible(blobOID):
            guard let pipeline = latest.pipelines[current.pipelineIdentity] else {
                return .rejected(.staleCompletion)
            }
            incrementCounter(\.cleanClassifications)
            emit(.classificationClean, rootEpoch: current.rootEpoch)
            return try await processCleanRequest(
                requestID: requestID,
                session: latest,
                pipeline: pipeline,
                classification: classification,
                repositoryRelativePath: repositoryRelativePath,
                blobOID: blobOID,
                sourceAuthority: sourceAuthority,
                preflight: preflight
            )
        case let .requiresValidatedWorktreeBytes(reason):
            incrementCounter(\.worktreeClassifications)
            emit(.classificationWorktree, rootEpoch: current.rootEpoch)
            return try await processWorktreeRequest(
                requestID: requestID,
                reason: reason,
                sourceAuthority: sourceAuthority,
                preflight: preflight
            )
        case .unavailable, .securityExcluded, .unsupported:
            preconditionFailure("Unavailable classifications return before source authority capture.")
        }
    }

    private func processCleanRequest(
        requestID: UUID,
        session: Session,
        pipeline: PipelineSession,
        classification: GitBlobIdentityClassification,
        repositoryRelativePath: String,
        blobOID: GitBlobOID,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken,
        preflight: WorkspaceCodemapLiveDemandPreflightTicket
    ) async throws -> WorkspaceCodemapBindingDemandResult {
        guard let request = currentRequest(requestID) else { throw CancellationError() }
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: session.capability.repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline.pipelineIdentity
        )
        guard let expectation = WorkspaceCodemapSourceExpectation.cleanGitBlob(
            bindingIdentity: request.demand.identity,
            locatorIdentity: locator,
            sourceAuthority: sourceAuthority
        ), let token = WorkspaceCodemapArtifactRequestToken.issue(
            identity: request.demand.identity,
            requestGeneration: request.demand.requestGeneration,
            catalogGeneration: request.demand.catalogGeneration,
            sourceExpectation: expectation
        ) else { return .rejected(.sourceAuthorityUnavailable) }
        let admission = await beginOverlayDemand(
            requestID: requestID,
            token: token,
            preflight: preflight
        )
        switch admission {
        case let .result(result): return result
        case let .ticket(ticket):
            guard let current = currentRequest(requestID) else { throw CancellationError() }
            let manifestRecord = pipeline.manifestRecords[repositoryRelativePath].flatMap {
                $0.locatorIdentity == locator ? $0 : nil
            }
            let resolved = try await Self.resolveClean(
                runtime: runtime,
                materializationService: materializationService,
                capability: session.capability,
                language: current.demand.language,
                locator: locator,
                manifestRecord: manifestRecord,
                ownerID: current.demand.owner.rawValue,
                priority: current.demand.priority
            )
            return try await publishResolution(
                requestID: requestID,
                ticket: ticket,
                token: token,
                resolved: resolved,
                repositoryRelativePath: repositoryRelativePath,
                gitMode: gitMode(classification),
                isClean: true
            )
        }
    }

    private func processWorktreeRequest(
        requestID: UUID,
        reason: GitBlobValidatedWorktreeReason,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken,
        preflight: WorkspaceCodemapLiveDemandPreflightTicket
    ) async throws -> WorkspaceCodemapBindingDemandResult {
        guard let request = currentRequest(requestID) else { throw CancellationError() }
        let validated: ValidatedRawFileContentSnapshot
        do {
            validated = try await sourceReader.read(
                request.demand.identity,
                sourceAuthority.acceptedPostPathFingerprint,
                policy.maximumValidatedWorktreeByteCount,
                request.demand.owner.rawValue
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch FileSystemError.fileTooLarge {
            return .unavailable(.oversized)
        } catch {
            return .unavailable(.transient)
        }
        try Task.checkCancellation()
        guard let current = currentRequest(requestID) else { throw CancellationError() }
        incrementCounter(\.validatedWorktreeReads)
        addToCounter(\.validatedWorktreeBytes, UInt64(validated.data.count))
        let source = CodeMapSourceSnapshot(validatedContent: validated)
        let input: CodeMapArtifactBuildInput
        do {
            input = try CodeMapArtifactBuildInput(source: source, language: current.demand.language)
        } catch {
            recordFailure(current.rootEpoch)
            return .unavailable(.transient)
        }
        guard let expectation = WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: current.demand.identity,
            source: source,
            expectedArtifactKey: input.artifactKey,
            classificationReason: reason,
            sourceAuthority: sourceAuthority
        ), let token = WorkspaceCodemapArtifactRequestToken.issue(
            identity: current.demand.identity,
            requestGeneration: current.demand.requestGeneration,
            catalogGeneration: current.demand.catalogGeneration,
            sourceExpectation: expectation
        ) else { return .rejected(.sourceAuthorityUnavailable) }
        let admission = await beginOverlayDemand(
            requestID: requestID,
            token: token,
            preflight: preflight
        )
        switch admission {
        case let .result(result): return result
        case let .ticket(ticket):
            guard let latest = currentRequest(requestID) else { throw CancellationError() }
            let coordinatorResult = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
                ownerID: latest.demand.owner.rawValue,
                priority: latest.demand.priority,
                target: .source(input)
            ))
            guard case let .ready(resolution) = coordinatorResult else {
                throw CodeMapArtifactBuildCoordinatorError.casVerificationFailed
            }
            return try await publishResolution(
                requestID: requestID,
                ticket: ticket,
                token: token,
                resolved: ResolvedArtifact(
                    resolution: resolution,
                    association: nil,
                    materializedByteCount: 0,
                    performedBuild: resolution.buildProvenance != .notNeeded,
                    locatorFastPath: false,
                    casFastPath: resolution.buildProvenance == .notNeeded
                ),
                repositoryRelativePath: nil,
                gitMode: nil,
                isClean: false
            )
        }
    }

    private enum OverlayPreflight {
        case reserved(WorkspaceCodemapLiveDemandPreflightTicket)
        case result(WorkspaceCodemapBindingDemandResult)
    }

    private func preflightOverlayDemand(requestID: UUID) async -> OverlayPreflight {
        guard var request = currentRequest(requestID) else { return .result(.cancelled) }
        let overlayOwner = WorkspaceCodemapLiveDemandOwner(rawValue: requestID)
        request.overlayOwner = overlayOwner
        activeRequests[requestID] = request
        let disposition = await overlay.preflightDemand(
            owner: overlayOwner,
            identity: request.demand.identity,
            pipelineIdentity: request.pipelineIdentity,
            requestGeneration: request.demand.requestGeneration,
            catalogGeneration: request.demand.catalogGeneration
        )
        guard var current = currentRequest(requestID) else {
            if case let .reserved(ticket) = disposition {
                _ = await overlay.cancelDemandPreflight(ticket)
            }
            return .result(.cancelled)
        }
        switch disposition {
        case let .reserved(ticket):
            current.preflight = ticket
            activeRequests[requestID] = current
            return .reserved(ticket)
        case let .ready(snapshot):
            return .result(.alreadyReady(snapshot))
        case .busy:
            recordBusy(current.rootEpoch)
            return .result(.busy(retryAfterMilliseconds: nil))
        case .rejected:
            return .result(.rejected(.overlayRejected))
        }
    }

    private enum OverlayAdmission {
        case ticket(WorkspaceCodemapLiveDemandTicket)
        case result(WorkspaceCodemapBindingDemandResult)
    }

    private func beginOverlayDemand(
        requestID: UUID,
        token: WorkspaceCodemapArtifactRequestToken,
        preflight: WorkspaceCodemapLiveDemandPreflightTicket
    ) async -> OverlayAdmission {
        guard var request = currentRequest(requestID) else { return .result(.cancelled) }
        let overlayOwner = WorkspaceCodemapLiveDemandOwner(rawValue: requestID)
        request.overlayOwner = overlayOwner
        activeRequests[requestID] = request
        var disposition = await overlay.beginDemand(
            owner: overlayOwner,
            token: token,
            preflight: preflight
        )
        if var afterAdmission = activeRequests[requestID] {
            afterAdmission.preflight = nil
            activeRequests[requestID] = afterAdmission
        }
        if case let .queued(reservation) = disposition {
            guard currentRequest(requestID) != nil else {
                _ = await overlay.cancelDemandReservation(owner: overlayOwner, reservation: reservation)
                return .result(.cancelled)
            }
            disposition = await overlay.resumeDemand(owner: overlayOwner, reservation: reservation)
            if case .queued = disposition {
                _ = await overlay.cancelDemandReservation(owner: overlayOwner, reservation: reservation)
            }
        }
        guard var current = currentRequest(requestID) else {
            switch disposition {
            case let .started(ticket), let .joined(ticket):
                _ = await overlay.cancelDemand(owner: overlayOwner, ticket: ticket)
            default:
                break
            }
            return .result(.cancelled)
        }
        switch disposition {
        case let .started(ticket), let .joined(ticket):
            current.ticket = ticket
            activeRequests[requestID] = current
            return .ticket(ticket)
        case let .ready(snapshot):
            return .result(.alreadyReady(snapshot))
        case .queued, .busy:
            recordBusy(current.rootEpoch)
            return .result(.busy(retryAfterMilliseconds: nil))
        case .rejected:
            return .result(.rejected(.overlayRejected))
        }
    }

    private func publishResolution(
        requestID: UUID,
        ticket: WorkspaceCodemapLiveDemandTicket,
        token: WorkspaceCodemapArtifactRequestToken,
        resolved: ResolvedArtifact,
        repositoryRelativePath: String?,
        gitMode: CodeMapRootManifestGitMode?,
        isClean: Bool
    ) async throws -> WorkspaceCodemapBindingDemandResult {
        try Task.checkCancellation()
        guard let request = currentRequest(requestID) else { throw CancellationError() }
        if resolved.performedBuild {
            incrementCounter(\.builds)
            emit(.build, rootEpoch: request.rootEpoch, artifact: resolved.resolution.handle.key)
        }
        if resolved.locatorFastPath {
            incrementCounter(\.locatorFastPaths)
            emit(.locatorFastPath, rootEpoch: request.rootEpoch, artifact: resolved.resolution.handle.key)
        }
        if resolved.casFastPath {
            incrementCounter(\.casFastPaths)
            emit(.casFastPath, rootEpoch: request.rootEpoch, artifact: resolved.resolution.handle.key)
        }
        if resolved.materializedByteCount > 0 {
            incrementCounter(\.materializations)
            addToCounter(\.materializedBytes, resolved.materializedByteCount)
            emit(.materialization, rootEpoch: request.rootEpoch, numericValue: resolved.materializedByteCount)
        }
        let completion: WorkspaceCodemapArtifactCompletion? = if isClean, let association = resolved.association {
            WorkspaceCodemapArtifactCompletion.cleanGitBlob(
                token: token,
                language: request.demand.language,
                association: association
            )
        } else {
            WorkspaceCodemapArtifactCompletion.validatedWorktree(
                token: token,
                language: request.demand.language,
                outcome: resolved.resolution.handle.outcome
            )
        }
        guard let completion else { return .rejected(.staleCompletion) }
        let lease = try await runtime.coordinator.acquireLease(for: resolved.resolution)
        try Task.checkCancellation()
        guard currentRequest(requestID) != nil else {
            await lease.close()
            throw CancellationError()
        }
        let accepted = await overlay.acceptCompletion(ticket: ticket, completion: completion, lease: lease)
        guard var latest = currentRequest(requestID) else {
            switch accepted {
            case .busy, .rejected:
                await lease.close()
            case .accepted, .acceptedUnavailable, .exactDuplicate:
                break
            }
            throw CancellationError()
        }
        switch accepted {
        case let .accepted(snapshot):
            latest.ticket = nil
            activeRequests[requestID] = latest
            incrementCounter(\.overlayReadyPublications)
            emit(.overlayReady, rootEpoch: request.rootEpoch, artifact: completion.artifactKey)
            if let repositoryRelativePath, let gitMode, let association = resolved.association {
                await persistCleanCompletion(
                    rootEpoch: request.rootEpoch,
                    pipelineIdentity: request.pipelineIdentity,
                    repositoryRelativePath: repositoryRelativePath,
                    gitMode: gitMode,
                    association: association,
                    bindingGeneration: request.demand.requestGeneration
                )
            }
            guard currentRequest(requestID) != nil else { throw CancellationError() }
            return .ready(snapshot)
        case let .exactDuplicate(snapshot):
            latest.ticket = nil
            activeRequests[requestID] = latest
            incrementCounter(\.overlayExactDuplicateCompletions)
            emit(.overlayExactDuplicate, rootEpoch: request.rootEpoch, artifact: completion.artifactKey)
            guard currentRequest(requestID) != nil else { throw CancellationError() }
            return .alreadyReady(snapshot)
        case let .acceptedUnavailable(outcome):
            latest.ticket = nil
            activeRequests[requestID] = latest
            incrementCounter(\.overlayUnavailablePublications)
            emit(.overlayUnavailable, rootEpoch: request.rootEpoch, artifact: completion.artifactKey)
            if let repositoryRelativePath, let gitMode, let association = resolved.association {
                await persistCleanCompletion(
                    rootEpoch: request.rootEpoch,
                    pipelineIdentity: request.pipelineIdentity,
                    repositoryRelativePath: repositoryRelativePath,
                    gitMode: gitMode,
                    association: association,
                    bindingGeneration: request.demand.requestGeneration
                )
            }
            guard currentRequest(requestID) != nil else { throw CancellationError() }
            return .unavailable(.terminalArtifact(outcome))
        case .busy:
            await lease.close()
            recordBusy(request.rootEpoch)
            return .busy(retryAfterMilliseconds: nil)
        case .rejected:
            await lease.close()
            incrementCounter(\.staleCompletionDrops)
            emit(.staleDrop, rootEpoch: request.rootEpoch)
            return .rejected(.staleCompletion)
        }
    }

    private func currentRequest(_ requestID: UUID) -> ActiveRequest? {
        guard let request = activeRequests[requestID], !request.cancelled,
              case let .eligible(session)? = roots[request.rootEpoch],
              session.id == request.sessionID,
              session.generation == request.sessionGeneration,
              session.pipelines[request.pipelineIdentity]?.id == request.pipelineSessionID,
              session.registration.catalogGeneration == request.demand.catalogGeneration,
              session.capability.repositoryAuthority == request.repositoryAuthority
        else { return nil }
        let pathGeneration = session.pathGenerations[request.relativePath]
            ?? request.demand.pathGeneration
        guard pathGeneration == request.demand.pathGeneration,
              session.registration.ingressGeneration == request.demand.ingressGeneration
        else { return nil }
        return request
    }

    private func finishRequest(
        requestID: UUID,
        result: WorkspaceCodemapBindingDemandResult,
        cancelOverlay: Bool
    ) async {
        guard let request = activeRequests.removeValue(forKey: requestID) else {
            if drainingRequestTasks.removeValue(forKey: requestID) != nil {
                scheduleQueuedRequests()
            }
            return
        }
        if let preflight = request.preflight {
            _ = await overlay.cancelDemandPreflight(preflight)
        }
        if cancelOverlay, let owner = request.overlayOwner, let ticket = request.ticket {
            _ = await overlay.cancelDemand(owner: owner, ticket: ticket)
        }
        request.continuation?.resume(returning: request.cancelled ? .cancelled : result)
        scheduleQueuedRequests()
    }

    private static func resolveClean(
        runtime: CodeMapArtifactRuntime,
        materializationService: GitBlobSourceMaterializationService,
        capability: GitCodemapRootCapability,
        language: LanguageType,
        locator: GitBlobCodeMapLocatorIdentity,
        manifestRecord: CodeMapRootManifestRecord?,
        ownerID: UUID,
        priority: CodeMapArtifactBuildPriority
    ) async throws -> ResolvedArtifact {
        if let manifestRecord,
           case let .ready(resolution) = try await runtime.coordinator.resolve(
               CodeMapArtifactBuildRequest(
                   ownerID: ownerID,
                   priority: priority,
                   target: .artifactKey(manifestRecord.artifactKey)
               )
           )
        {
            let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                identity: locator,
                artifactKey: manifestRecord.artifactKey,
                casHandle: resolution.handle
            )
            return ResolvedArtifact(
                resolution: resolution,
                association: association,
                materializedByteCount: 0,
                performedBuild: false,
                locatorFastPath: false,
                casFastPath: true
            )
        }
        if case let .ready(resolution) = try await runtime.coordinator.resolve(
            CodeMapArtifactBuildRequest(ownerID: ownerID, priority: priority, target: .locator(locator))
        ) {
            let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                identity: locator,
                artifactKey: resolution.handle.key,
                casHandle: resolution.handle
            )
            return ResolvedArtifact(
                resolution: resolution,
                association: association,
                materializedByteCount: 0,
                performedBuild: false,
                locatorFastPath: true,
                casFastPath: true
            )
        }
        let validated = try await materializationService.materialize(
            capability: capability,
            blobOID: locator.blobOID
        )
        let byteCount = UInt64(validated.rawBytes.count)
        let source = CodeMapSourceSnapshot(validatedGitBlob: validated)
        let input = try CodeMapArtifactBuildInput(
            source: source,
            language: language,
            locatorIdentity: locator
        )
        let result = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
            ownerID: ownerID,
            priority: priority,
            target: .source(input)
        ))
        guard case let .ready(resolution) = result else {
            throw CodeMapArtifactBuildCoordinatorError.casVerificationFailed
        }
        let association = try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: locator,
            artifactKey: input.artifactKey,
            casHandle: resolution.handle
        )
        return ResolvedArtifact(
            resolution: resolution,
            association: association,
            materializedByteCount: byteCount,
            performedBuild: resolution.buildProvenance != .notNeeded,
            locatorFastPath: false,
            casFastPath: resolution.buildProvenance == .notNeeded
        )
    }

    private func persistCleanCompletion(
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        repositoryRelativePath: String,
        gitMode: CodeMapRootManifestGitMode,
        association: VerifiedGitBlobCodeMapLocatorAssociation,
        bindingGeneration: UInt64
    ) async {
        guard case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[pipelineIdentity],
              let record = try? makeManifestRecord(
                  session: session,
                  pipeline: pipeline,
                  repositoryRelativePath: repositoryRelativePath,
                  gitMode: gitMode,
                  association: association,
                  bindingGeneration: bindingGeneration
              )
        else { return }
        let scope = PipelineScope(rootEpoch: rootEpoch, pipelineIdentity: pipelineIdentity)
        let isNew = pipeline.manifestRecords[repositoryRelativePath] == nil
        if isNew {
            let pendingAdoptionCount = adoptionReservations.values.reduce(0) {
                addingSaturating($0, $1.recordCount)
            }
            let currentRootCount = session.pipelines.values.reduce(0) {
                addingSaturating($0, $1.manifestRecords.count)
            }
            guard let projectedRootCount = addingChecked(currentRootCount, 1),
                  let retainedCount = addingChecked(
                      retainedManifestRecordCount(excluding: rootEpoch),
                      currentRootCount
                  ),
                  let reservedCount = addingChecked(retainedCount, pendingAdoptionCount),
                  let projectedGlobalCount = addingChecked(reservedCount, 1),
                  projectedRootCount <= policy.maximumRetainedManifestRecordCountPerRoot,
                  projectedGlobalCount <= policy.maximumRetainedManifestRecordCount
            else {
                recordBusy(rootEpoch)
                return
            }
        }
        guard pipeline.manifestRevision < UInt64.max else {
            pipeline.manifestState = .dirtyRetryRequired
            session.pipelines[pipelineIdentity] = pipeline
            roots[rootEpoch] = .eligible(session)
            recordFailure(rootEpoch)
            return
        }
        pipeline.manifestRecords[repositoryRelativePath] = record
        pipeline.manifestRevision += 1
        pipeline.manifestState = .dirtyRetryRequired
        let revision = pipeline.manifestRevision
        pipeline.pendingManifestChanges[repositoryRelativePath] = PendingManifestChange(
            revision: revision,
            record: record
        )
        session.pipelines[pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
        emit(.manifestRevisionQueued, rootEpoch: rootEpoch, numericValue: revision)
        let succeeded = await waitForManifestRevision(scope: scope, revision: revision)
        if succeeded {
            emit(.manifestWrite, rootEpoch: rootEpoch, artifact: association.artifactKey)
        }
    }

    private func startManifestWriter(scope: PipelineScope) {
        guard case let .eligible(session)? = roots[scope.rootEpoch],
              let pipeline = session.pipelines[scope.pipelineIdentity],
              !pipeline.pendingManifestChanges.isEmpty
        else { return }
        let namespace = pipeline.namespace
        let workKey = ManifestWriterWorkKey(
            scope: scope,
            sessionID: session.id,
            pipelineSessionID: pipeline.id
        )
        var state = manifestWriters[namespace] ?? ManifestWriterState()
        let inFlightCoversRevision = state.inFlightWork == workKey &&
            (state.inFlightRevision ?? 0) >= pipeline.manifestRevision
        if !inFlightCoversRevision, !state.queuedWorkSet.contains(workKey) {
            state.queuedWork.append(workKey)
            state.queuedWorkSet.insert(workKey)
        }
        guard state.writerID == nil else {
            manifestWriters[namespace] = state
            return
        }
        let writerID = UUID()
        state.writerID = writerID
        manifestWriters[namespace] = state
        let task = Task { await self.runManifestWriter(namespace: namespace, writerID: writerID) }
        guard var current = manifestWriters[namespace], current.writerID == writerID else {
            task.cancel()
            return
        }
        current.task = task
        manifestWriters[namespace] = current
    }

    private func runManifestWriter(
        namespace: CodeMapRootManifestNamespace,
        writerID: UUID
    ) async {
        while !Task.isCancelled {
            guard var writer = manifestWriters[namespace], writer.writerID == writerID else { return }
            guard !writer.queuedWork.isEmpty else {
                writer.writerID = nil
                writer.task = nil
                writer.inFlightWork = nil
                writer.inFlightRevision = nil
                if writer.waiters.isEmpty {
                    manifestWriters.removeValue(forKey: namespace)
                } else {
                    manifestWriters[namespace] = writer
                }
                return
            }
            let workKey = writer.queuedWork.removeFirst()
            writer.queuedWorkSet.remove(workKey)
            let scope = workKey.scope
            guard case let .eligible(session)? = roots[scope.rootEpoch],
                  session.id == workKey.sessionID,
                  let pipeline = session.pipelines[scope.pipelineIdentity],
                  pipeline.id == workKey.pipelineSessionID,
                  pipeline.namespace == namespace,
                  !pipeline.pendingManifestChanges.isEmpty
            else {
                let detached = writer.waiters.filter { $0.workKey == workKey }
                writer.waiters.removeAll { $0.workKey == workKey }
                manifestWriters[namespace] = writer
                for waiter in detached {
                    waiter.continuation.resume(returning: false)
                }
                continue
            }
            let sessionID = session.id
            let pipelineSessionID = pipeline.id
            let revision = pipeline.manifestRevision
            let changes = pipeline.pendingManifestChanges
            let upserts = changes.values.compactMap(\.record)
            let removals = Set(changes.compactMap { path, change in
                change.record == nil ? path : nil
            })
            writer.inFlightWork = workKey
            writer.inFlightRevision = revision
            manifestWriters[namespace] = writer
            do {
                guard let writerAuthority = await runtime.manifestStore.claimManifestWriterAuthority(
                    namespace: namespace,
                    authority: pipeline.authority,
                    writerSession: session.manifestWriterSession
                ) else {
                    throw CodeMapRootManifestStoreError.staleWriterAuthority
                }
                let result = try await mergeManifestChanges(
                    namespace: namespace,
                    authority: pipeline.authority,
                    writerAuthority: writerAuthority,
                    previouslyObservedAuthority: pipeline.previouslyObservedManifestAuthority,
                    upserts: upserts,
                    removals: removals
                )
                guard var currentWriter = manifestWriters[namespace],
                      currentWriter.writerID == writerID
                else { return }
                currentWriter.inFlightWork = nil
                currentWriter.inFlightRevision = nil
                let completed = currentWriter.waiters.filter {
                    $0.workKey == workKey && $0.revision <= revision
                }
                currentWriter.waiters.removeAll {
                    $0.workKey == workKey && $0.revision <= revision
                }
                if case var .eligible(current)? = roots[scope.rootEpoch],
                   current.id == sessionID,
                   var currentPipeline = current.pipelines[scope.pipelineIdentity],
                   currentPipeline.id == pipelineSessionID,
                   currentPipeline.namespace == namespace
                {
                    currentPipeline.previouslyObservedManifestAuthority = currentPipeline.authority
                    for (path, change) in changes
                        where currentPipeline.pendingManifestChanges[path]?.revision == change.revision
                    {
                        currentPipeline.pendingManifestChanges.removeValue(forKey: path)
                    }
                    currentPipeline.persistedManifestRevision = max(
                        currentPipeline.persistedManifestRevision,
                        revision
                    )
                    if currentPipeline.pendingManifestChanges.isEmpty,
                       currentPipeline.manifestRevision == revision
                    {
                        currentPipeline.manifestState = .clean(generation: manifestGeneration(result))
                    } else {
                        currentPipeline.manifestState = .dirtyRetryRequired
                    }
                    current.pipelines[scope.pipelineIdentity] = currentPipeline
                    roots[scope.rootEpoch] = .eligible(current)
                }
                manifestWriters[namespace] = currentWriter
                incrementCounter(\.manifestWrites)
                for waiter in completed {
                    waiter.continuation.resume(returning: true)
                }
            } catch {
                guard var currentWriter = manifestWriters[namespace],
                      currentWriter.writerID == writerID
                else { return }
                currentWriter.inFlightWork = nil
                currentWriter.inFlightRevision = nil
                let failed = currentWriter.waiters.filter {
                    $0.workKey == workKey && $0.revision <= revision
                }
                currentWriter.waiters.removeAll {
                    $0.workKey == workKey && $0.revision <= revision
                }
                manifestWriters[namespace] = currentWriter
                if case var .eligible(current)? = roots[scope.rootEpoch],
                   current.id == sessionID,
                   var currentPipeline = current.pipelines[scope.pipelineIdentity],
                   currentPipeline.id == pipelineSessionID
                {
                    currentPipeline.manifestState = .dirtyRetryRequired
                    current.pipelines[scope.pipelineIdentity] = currentPipeline
                    roots[scope.rootEpoch] = .eligible(current)
                }
                for waiter in failed {
                    waiter.continuation.resume(returning: false)
                }
                incrementCounter(\.manifestFailures)
                emit(.manifestFailure, rootEpoch: scope.rootEpoch)
            }
        }
    }

    private func mergeManifestChanges(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        writerAuthority: CodeMapRootManifestWriterAuthorityToken,
        previouslyObservedAuthority: CodeMapRootManifestAuthority?,
        upserts: [CodeMapRootManifestRecord],
        removals: Set<String>
    ) async throws -> CodeMapRootManifestWriteResult {
        var predecessor = previouslyObservedAuthority
        for attempt in 0 ... 1 {
            do {
                return try await runtime.manifestStore.mergeCurrentManifest(
                    namespace: namespace,
                    authority: authority,
                    writerAuthority: writerAuthority,
                    replacingPreviouslyObservedAuthority: predecessor,
                    upserting: upserts,
                    removing: removals,
                    lastAccessEpochSeconds: accessEpochSeconds()
                )
            } catch CodeMapRootManifestModelError.staleAuthority where attempt == 0 {
                guard await runtime.manifestStore.manifestWriterAuthorityIsCurrent(writerAuthority) else {
                    throw CodeMapRootManifestStoreError.staleWriterAuthority
                }
                let load = try await runtime.manifestStore.loadCurrentManifest(
                    namespace: namespace,
                    currentAuthority: authority
                )
                predecessor = switch load {
                case .miss:
                    nil
                case let .stale(existingAuthority):
                    existingAuthority
                case let .hit(snapshot):
                    snapshot.authority
                }
                if let predecessor, predecessor != authority,
                   predecessor.authorityGeneration >= authority.authorityGeneration
                {
                    throw CodeMapRootManifestModelError.staleAuthority
                }
            }
        }
        throw CodeMapRootManifestModelError.staleAuthority
    }

    private func waitForManifestRevision(
        scope: PipelineScope,
        revision: UInt64
    ) async -> Bool {
        guard case let .eligible(session)? = roots[scope.rootEpoch],
              let pipeline = session.pipelines[scope.pipelineIdentity]
        else { return false }
        if pipeline.persistedManifestRevision >= revision { return true }
        let namespace = pipeline.namespace
        let waiterID = UUID()
        let workKey = ManifestWriterWorkKey(
            scope: scope,
            sessionID: session.id,
            pipelineSessionID: pipeline.id
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                var state = manifestWriters[namespace] ?? ManifestWriterState()
                state.waiters.append(ManifestWriteWaiter(
                    id: waiterID,
                    workKey: workKey,
                    revision: revision,
                    continuation: continuation
                ))
                manifestWriters[namespace] = state
                startManifestWriter(scope: scope)
            }
        } onCancel: {
            Task { await self.cancelManifestWaiter(namespace: namespace, waiterID: waiterID) }
        }
    }

    private func cancelManifestWaiter(
        namespace: CodeMapRootManifestNamespace,
        waiterID: UUID
    ) {
        guard var state = manifestWriters[namespace],
              let index = state.waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = state.waiters.remove(at: index)
        if state.writerID == nil, state.queuedWork.isEmpty, state.waiters.isEmpty {
            manifestWriters.removeValue(forKey: namespace)
        } else {
            manifestWriters[namespace] = state
        }
        waiter.continuation.resume(returning: false)
    }

    private func detachManifestWriters(rootEpoch: WorkspaceCodemapRootEpoch) {
        for namespace in Array(manifestWriters.keys) {
            guard var state = manifestWriters[namespace] else { continue }
            state.queuedWork.removeAll { $0.scope.rootEpoch == rootEpoch }
            state.queuedWorkSet = Set(state.queuedWork)
            let detached = state.waiters.filter { $0.workKey.scope.rootEpoch == rootEpoch }
            state.waiters.removeAll { $0.workKey.scope.rootEpoch == rootEpoch }
            if state.writerID == nil, state.queuedWork.isEmpty, state.waiters.isEmpty {
                manifestWriters.removeValue(forKey: namespace)
            } else {
                manifestWriters[namespace] = state
            }
            for waiter in detached {
                waiter.continuation.resume(returning: false)
            }
        }
    }

    private func cancelAllManifestWriters() -> [Task<Void, Never>] {
        let states = Array(manifestWriters.values)
        manifestWriters.removeAll()
        for state in states {
            state.task?.cancel()
            for waiter in state.waiters {
                waiter.continuation.resume(returning: false)
            }
        }
        return states.compactMap(\.task)
    }

    private func detachManifestAdoptionOperations(rootEpoch: WorkspaceCodemapRootEpoch) {
        for scope in Array(manifestAdoptionOperations.keys) where scope.rootEpoch == rootEpoch {
            guard let operation = manifestAdoptionOperations.removeValue(forKey: scope) else { continue }
            operation.task.cancel()
            drainingManifestAdoptionTasks[operation.attempt.operationID] = operation.task
            for waiter in operation.waiters.values {
                waiter.resume()
            }
        }
    }

    private func invalidatePaths(
        _ rootEpoch: WorkspaceCodemapRootEpoch,
        paths: Set<String>,
        reason: WorkspaceCodemapLiveOverlayInvalidationReason
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        let safePaths = Set(paths.compactMap(safeRelativePath))
        guard !safePaths.isEmpty else {
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        if case let .registering(attempt)? = roots[rootEpoch] {
            replacementCancelledRegistrationAttemptIDs.insert(attempt.id)
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.invalidateForAuthorityReplacement(rootEpoch: rootEpoch)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            emit(.invalidation, rootEpoch: rootEpoch)
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        guard case var .eligible(session)? = roots[rootEpoch] else {
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        guard session.invalidationGeneration < UInt64.max,
              session.pipelines.values.allSatisfy({ $0.manifestRevision < UInt64.max }),
              safePaths.allSatisfy({ (session.pathGenerations[$0] ?? 0) < UInt64.max })
        else {
            return await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .authorityChanged)
        }

        session.invalidationGeneration += 1
        for path in safePaths {
            session.pathGenerations[path] = (
                session.pathGenerations[path] ?? session.registration.ingressGeneration
            ) + 1
        }
        for identity in session.pipelines.keys {
            guard var pipeline = session.pipelines[identity] else { continue }
            pipeline.manifestRevision += 1
            for path in safePaths {
                if let repositoryPath = repositoryPath(
                    loadedRootRelativePath: path,
                    prefix: session.capability.repositoryRelativeLoadedRootPrefix
                ) {
                    pipeline.manifestRecords.removeValue(forKey: repositoryPath)
                    pipeline.pendingManifestChanges[repositoryPath] = PendingManifestChange(
                        revision: pipeline.manifestRevision,
                        record: nil
                    )
                }
            }
            pipeline.manifestState = .dirtyRetryRequired
            session.pipelines[identity] = pipeline
        }
        let revisions = session.pipelines.map { identity, pipeline in
            (PipelineScope(rootEpoch: rootEpoch, pipelineIdentity: identity), pipeline.manifestRevision)
        }
        roots[rootEpoch] = .eligible(session)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
        let requestIDs = activeRequests.values.filter {
            $0.rootEpoch == rootEpoch && safePaths.contains($0.relativePath)
        }.map(\.id)
        let queuedIDs = queuedRequests.values.filter {
            $0.rootEpoch == rootEpoch && safePaths.contains($0.demand.identity.standardizedRelativePath)
        }.map(\.id)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs + queuedIDs)

        let revoked = await overlay.invalidatePaths(
            rootEpoch: rootEpoch,
            standardizedRelativePaths: safePaths,
            reason: reason
        )
        releaseRetainedAdoptionPaths(safePaths, rootEpoch: rootEpoch)
        pruneAdmissionHistory()
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        var failed = false
        for (scope, revision) in revisions {
            if await !waitForManifestRevision(scope: scope, revision: revision) {
                failed = true
            }
        }
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        emit(.invalidation, rootEpoch: rootEpoch, numericValue: UInt64(revoked))
        return WorkspaceCodemapBindingInvalidationResult(
            revokedOverlayCount: revoked,
            cancelledRequestCount: cancellationBatch.cancelledRequestCount,
            manifestWriteFailed: failed
        )
    }

    private func invalidateRootAuthority(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapLiveOverlayInvalidationReason
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        if case let .registering(attempt)? = roots[rootEpoch] {
            replacementCancelledRegistrationAttemptIDs.insert(attempt.id)
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.invalidateForAuthorityReplacement(rootEpoch: rootEpoch)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            emit(.invalidation, rootEpoch: rootEpoch)
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        guard case let .eligible(session)? = roots[rootEpoch] else {
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        let requestIDs = activeRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id)
        let queuedIDs = queuedRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id)
        roots[rootEpoch] = .unavailable(UnavailableRoot(
            registration: session.registration,
            state: .unresolved
        ))
        detachManifestWriters(rootEpoch: rootEpoch)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs + queuedIDs)
        await runtime.manifestStore.endManifestWriterSession(session.manifestWriterSession)

        let revoked = await overlay.invalidateRootAuthority(
            rootEpoch: rootEpoch,
            expectedAuthority: session.capability.repositoryAuthority,
            reason: reason
        )
        adoptionReservations = adoptionReservations.filter { $0.key.rootEpoch != rootEpoch }
        retainedAdoptions = retainedAdoptions.filter { $0.key.rootEpoch != rootEpoch }
        pruneAdmissionHistory()
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        emit(.invalidation, rootEpoch: rootEpoch)
        return WorkspaceCodemapBindingInvalidationResult(
            revokedOverlayCount: revoked ? 1 : 0,
            cancelledRequestCount: cancellationBatch.cancelledRequestCount,
            manifestWriteFailed: false
        )
    }

    private func synchronouslyCancelRequests(
        _ requestIDs: [UUID]
    ) -> SynchronousCancellationBatch {
        var overlayCancellations: [OverlayCancellation] = []
        var cancelledRequestCount = 0
        for requestID in requestIDs {
            if let queued = queuedRequests.removeValue(forKey: requestID) {
                queueOrder.removeAll { $0 == requestID }
                queued.continuation?.resume(returning: .cancelled)
                cancelledRequestCount += 1
                continue
            }
            guard var request = activeRequests.removeValue(forKey: requestID), !request.cancelled else { continue }
            request.cancelled = true
            request.task?.cancel()
            if request.ticket != nil || request.preflight != nil {
                overlayCancellations.append(OverlayCancellation(
                    owner: request.overlayOwner,
                    ticket: request.ticket,
                    preflight: request.preflight
                ))
            }
            request.ticket = nil
            request.preflight = nil
            request.continuation?.resume(returning: .cancelled)
            request.continuation = nil
            if let task = request.task {
                drainingRequestTasks[requestID] = task
            }
            cancelledRequestCount += 1
        }
        scheduleQueuedRequests()
        return SynchronousCancellationBatch(
            overlayCancellations: overlayCancellations,
            cancelledRequestCount: cancelledRequestCount
        )
    }

    private func cancelOverlayAssociations(
        _ associations: [OverlayCancellation]
    ) async {
        for association in associations {
            if let owner = association.owner, let ticket = association.ticket {
                _ = await overlay.cancelDemand(owner: owner, ticket: ticket)
            }
            if let preflight = association.preflight {
                _ = await overlay.cancelDemandPreflight(preflight)
            }
        }
    }

    private func makeManifestRecord(
        session: Session,
        pipeline: PipelineSession,
        repositoryRelativePath: String,
        gitMode: CodeMapRootManifestGitMode,
        association: VerifiedGitBlobCodeMapLocatorAssociation,
        bindingGeneration: UInt64
    ) throws -> CodeMapRootManifestRecord {
        let contribution: CodeMapSelectionGraphContribution? = switch association.outcome {
        case let .ready(artifact):
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                artifact: artifact
            )
        case .readyNoSymbols:
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                definitions: [] as [String],
                references: [] as [String]
            )
        case .oversize, .decodeFailed, .parseFailed:
            nil
        }
        return try CodeMapRootManifestRecord.verifiedClean(
            namespace: pipeline.namespace,
            repositoryRelativePath: repositoryRelativePath,
            gitMode: gitMode,
            association: association,
            contribution: contribution,
            authority: pipeline.authority,
            bindingGeneration: bindingGeneration
        )
    }

    private func gitMode(_ classification: GitBlobIdentityClassification) -> CodeMapRootManifestGitMode? {
        guard let mode = classification.indexEntries.first(where: { $0.stage == 0 })?.mode else {
            return nil
        }
        return try? CodeMapRootManifestGitMode(gitValue: mode)
    }

    private func manifestGeneration(_ result: CodeMapRootManifestWriteResult) -> UInt64 {
        switch result {
        case let .inserted(value), let .replaced(value), let .unchanged(value): value
        }
    }

    private func repositoryPath(loadedRootRelativePath: String, prefix: String) -> String? {
        guard let path = safeRelativePath(loadedRootRelativePath) else { return nil }
        return prefix.isEmpty ? path : prefix + "/" + path
    }

    private func loadedRootPath(repositoryRelativePath: String, prefix: String) -> String? {
        guard let path = safeRelativePath(repositoryRelativePath) else { return nil }
        if prefix.isEmpty { return path }
        guard path.hasPrefix(prefix + "/") else { return nil }
        return String(path.dropFirst(prefix.count + 1))
    }

    private func safeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let standardized = StandardizedPath.relative(path)
        guard standardized == path,
              standardized != ".",
              standardized != "..",
              !standardized.hasPrefix("../")
        else { return nil }
        return standardized
    }

    private func rootEpochPrecedes(_ lhs: WorkspaceCodemapRootEpoch, _ rhs: WorkspaceCodemapRootEpoch) -> Bool {
        let left = lhs.rootID.uuidString + lhs.rootLifetimeID.uuidString
        let right = rhs.rootID.uuidString + rhs.rootLifetimeID.uuidString
        return left < right
    }

    private func finishRegistrationOperation(_ operationID: UUID) {
        registrationOperations.remove(operationID)
        guard registrationOperations.isEmpty else { return }
        let waiters = registrationDrainWaiters
        registrationDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForRegistrationOperationsToDrain() async {
        guard !registrationOperations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            registrationDrainWaiters.append(continuation)
        }
    }

    private func waitForShutdownCompletion() async {
        guard !shutdownComplete else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    private func releaseCapabilityAfterRegistrationFailure(
        _ attempt: RegistrationAttempt,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async {
        if replacementCancelledRegistrationAttemptIDs.remove(attempt.id) != nil {
            return
        }
        await capabilityService.release(rootEpoch: rootEpoch)
    }

    private func registrationAttemptIsCurrent(
        _ attempt: RegistrationAttempt,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        guard case let .registering(current)? = roots[rootEpoch] else { return false }
        return current.id == attempt.id &&
            current.registration == attempt.registration &&
            !current.cancelled
    }

    private func finishRegistrationAttempt(
        _ attempt: RegistrationAttempt,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard case let .registering(current)? = roots[rootEpoch], current.id == attempt.id else {
            return
        }
        roots.removeValue(forKey: rootEpoch)
    }

    private func addingChecked(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private func addingChecked(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private func addingSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private func incrementCounter(
        _ keyPath: WritableKeyPath<WorkspaceCodemapBindingEngineCounters, UInt64>
    ) {
        addToCounter(keyPath, 1)
    }

    private func addToCounter(
        _ keyPath: WritableKeyPath<WorkspaceCodemapBindingEngineCounters, UInt64>,
        _ amount: UInt64
    ) {
        counters[keyPath: keyPath] = addingSaturating(counters[keyPath: keyPath], amount)
    }

    /// Bulk cancellation transitions emit one path-free aggregate event whose value matches the counter delta.
    private func recordCancellationTelemetry(_ count: Int) {
        guard count > 0 else { return }
        addToCounter(\.cancellations, UInt64(count))
        emit(.cancellation, numericValue: UInt64(count))
    }

    private func recordBusy(_ rootEpoch: WorkspaceCodemapRootEpoch?) {
        incrementCounter(\.busyRejections)
        emit(.busy, rootEpoch: rootEpoch)
    }

    private func recordFailure(_ rootEpoch: WorkspaceCodemapRootEpoch?) {
        incrementCounter(\.failures)
        emit(.failure, rootEpoch: rootEpoch)
    }

    private func emit(
        _ kind: WorkspaceCodemapBindingEngineHookKind,
        rootEpoch: WorkspaceCodemapRootEpoch? = nil,
        artifact: CodeMapArtifactKey? = nil,
        numericValue: UInt64 = 0
    ) {
        hooks.event(WorkspaceCodemapBindingEngineHookEvent(
            kind: kind,
            rootEpoch: rootEpoch,
            artifactStorageDigest: artifact?.storageDigestHex,
            numericValue: numericValue
        ))
    }
}
