import Foundation

actor WorkspaceCodemapSelectionGraph {
    private let rootEpoch: WorkspaceCodemapRootEpoch
    private let policy: WorkspaceCodemapSelectionGraphRuntimePolicy
    private let admission: CodeMapSelectionGraphAdmission
    private let diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics

    private var observedKey: WorkspaceCodemapSelectionGraphRuntimeKey?
    private var observationSerial: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var latestOperationID: UInt64?
    private var publishedShard: ImmutableShard?
    private var activeOperations: [UInt64: ActiveOperation] = [:]
    private var activeRebuildCount = 0
    private var reservedInputBindingCount = 0
    private var lastUnavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason?
    private var revokedReason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason?
    private var hasCurrentnessConflict = false

    private var publishedCount: UInt64 = 0
    private var emptyPublishedCount: UInt64 = 0
    private var actorBusyCount: UInt64 = 0
    private var processBusyCount: UInt64 = 0
    private var cancelledCount: UInt64 = 0
    private var budgetRejectedCount: UInt64 = 0
    private var invalidSnapshotCount: UInt64 = 0
    private var supersededPublicationCount: UInt64 = 0

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        policy: WorkspaceCodemapSelectionGraphRuntimePolicy = .initial,
        admission: CodeMapSelectionGraphAdmission = .processWide,
        diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics = .none
    ) {
        self.rootEpoch = rootEpoch
        self.policy = policy
        self.admission = admission
        self.diagnostics = diagnostics
    }

    func rebuild(
        from snapshot: WorkspaceCodemapLiveGraphSnapshot
    ) async -> WorkspaceCodemapSelectionGraphRuntimeRebuildDisposition {
        let key = WorkspaceCodemapSelectionGraphRuntimeKey(snapshot: snapshot)
        guard !Task.isCancelled else { return .cancelled(key) }
        guard snapshot.rootEpoch == rootEpoch else {
            return .rejected(key, .rootEpochMismatch)
        }
        if let revokedReason {
            return .rejected(key, .rootUnavailable(revokedReason))
        }
        if let current = observedKey {
            if key.contributionGeneration < current.contributionGeneration {
                return .rejected(
                    key,
                    .staleSnapshot(
                        received: key.contributionGeneration,
                        current: current.contributionGeneration
                    )
                )
            }
            if key.contributionGeneration == current.contributionGeneration {
                if key != current {
                    lastUnavailableReason = .invalidSnapshot
                    hasCurrentnessConflict = true
                    increment(&invalidSnapshotCount)
                    _ = advanceObservationSerial()
                    for operation in activeOperations.values {
                        operation.task.cancel()
                    }
                    return .rejected(key, .equalGenerationAuthorityConflict)
                }
                if hasCurrentnessConflict {
                    return .rejected(key, .equalGenerationAuthorityConflict)
                }
            }
        }

        if observedKey != key {
            observedKey = key
            lastUnavailableReason = nil
            hasCurrentnessConflict = false
            guard advanceObservationSerial() else {
                return .rejected(key, .rootUnavailable(.authorityRevoked))
            }
        }
        let operationObservationSerial = observationSerial

        guard snapshot.bindings.count <= policy.maximumInputBindingCount else {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(
                key,
                .inputBindingLimit(
                    attempted: snapshot.bindings.count,
                    limit: policy.maximumInputBindingCount
                )
            )
        }

        guard activeRebuildCount < policy.maximumActiveRebuildCount else {
            let reason = WorkspaceCodemapSelectionGraphRuntimeBusyReason.actorActiveRebuildLimit
            lastUnavailableReason = .actorAdmissionRejected(reason)
            increment(&actorBusyCount)
            return .busy(key, reason)
        }
        let (nextReservedCount, reservedOverflow) = reservedInputBindingCount.addingReportingOverflow(
            snapshot.bindings.count
        )
        guard !reservedOverflow else {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }
        guard nextReservedCount <= policy.maximumReservedBindingCount else {
            let reason = WorkspaceCodemapSelectionGraphRuntimeBusyReason.actorReservedBindingLimit
            lastUnavailableReason = .actorAdmissionRejected(reason)
            increment(&actorBusyCount)
            return .busy(key, reason)
        }

        let permit: CodeMapSelectionGraphAdmissionPermit
        do {
            permit = try admission.reserve(bindingCount: snapshot.bindings.count)
        } catch let CodeMapSelectionGraphAdmissionError.busy(reason) {
            lastUnavailableReason = .processAdmissionRejected(reason)
            increment(&processBusyCount)
            return .busy(key, .processAdmission(reason))
        } catch {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }

        guard let operationID = issueOperationID() else {
            permit.close()
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }
        activeRebuildCount += 1
        reservedInputBindingCount = nextReservedCount
        latestOperationID = operationID
        if publishedShard?.key != key {
            lastUnavailableReason = .rebuilding
        }

        let sizePolicy = policy.graphSizePolicy
        let operationDiagnostics = diagnostics
        let task = Task.detached(priority: .utility) {
            operationDiagnostics.handle(.init(
                operationID: operationID,
                key: key,
                kind: .buildStarted
            ))
            let output = Self.buildShard(snapshot: snapshot, key: key, sizePolicy: sizePolicy)
            guard case .success = output else { return output }
            guard !Task.isCancelled else { return .cancelled }
            operationDiagnostics.handle(.init(
                operationID: operationID,
                key: key,
                kind: .beforePublication
            ))
            return Task.isCancelled ? .cancelled : output
        }
        activeOperations[operationID] = ActiveOperation(key: key, task: task)

        let output = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        activeOperations.removeValue(forKey: operationID)
        activeRebuildCount -= 1
        reservedInputBindingCount -= snapshot.bindings.count
        permit.close()

        if Task.isCancelled || output == .cancelled {
            if observedKey == key, publishedShard?.key != key {
                lastUnavailableReason = .cancelled
            }
            increment(&cancelledCount)
            return .cancelled(key)
        }

        guard revokedReason == nil,
              !hasCurrentnessConflict,
              operationObservationSerial == observationSerial,
              observedKey == key,
              latestOperationID == operationID
        else {
            increment(&supersededPublicationCount)
            return .superseded(key)
        }

        switch output {
        case let .success(shard):
            publishedShard = shard
            lastUnavailableReason = nil
            if shard.summary.isEmpty {
                increment(&emptyPublishedCount)
                return .publishedEmpty(shard.summary)
            }
            increment(&publishedCount)
            return .published(shard.summary)
        case let .rejected(reason):
            recordRejection(reason, key: key)
            return .rejected(key, reason)
        case .cancelled:
            increment(&cancelledCount)
            lastUnavailableReason = .cancelled
            return .cancelled(key)
        }
    }

    func query(
        _ query: WorkspaceCodemapSelectionGraphRuntimeQuery
    ) -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition {
        if let revokedReason {
            return .unavailable(.explicitRootUnavailable(revokedReason))
        }
        guard let observedKey else { return .unavailable(.notBuilt) }
        guard query.key == observedKey else {
            return .unavailable(.staleCurrentness(currentKey: observedKey))
        }
        guard !hasCurrentnessConflict else { return .unavailable(.invalidSnapshot) }
        if let shard = publishedShard, shard.key == observedKey {
            return queryShard(query, in: shard)
        }
        if activeOperations.values.contains(where: { $0.key == observedKey }) {
            return .unavailable(.rebuilding)
        }
        return .unavailable(lastUnavailableReason ?? .notBuilt)
    }

    func invalidateCurrentness(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason
    ) -> Bool {
        guard rootEpoch == self.rootEpoch, revokedReason == nil else { return false }
        revokedReason = reason
        lastUnavailableReason = .explicitRootUnavailable(reason)
        advanceObservationSerial()
        for operation in activeOperations.values {
            operation.task.cancel()
        }
        return true
    }

    func accounting() -> WorkspaceCodemapSelectionGraphRuntimeAccounting {
        let unavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason? = if let revokedReason {
            .explicitRootUnavailable(revokedReason)
        } else if hasCurrentnessConflict {
            .invalidSnapshot
        } else if publishedShard?.key == observedKey {
            nil
        } else if let observedKey,
                  activeOperations.values.contains(where: { $0.key == observedKey })
        {
            .rebuilding
        } else {
            lastUnavailableReason
        }
        return WorkspaceCodemapSelectionGraphRuntimeAccounting(
            activeRebuildCount: activeRebuildCount,
            reservedInputBindingCount: reservedInputBindingCount,
            publishedSummary: publishedShard?.summary,
            currentObservedKey: observedKey,
            currentUnavailableReason: unavailableReason,
            publishedCount: publishedCount,
            emptyPublishedCount: emptyPublishedCount,
            actorBusyCount: actorBusyCount,
            processBusyCount: processBusyCount,
            cancelledCount: cancelledCount,
            budgetRejectedCount: budgetRejectedCount,
            invalidSnapshotCount: invalidSnapshotCount,
            supersededPublicationCount: supersededPublicationCount
        )
    }

    private func queryShard(
        _ query: WorkspaceCodemapSelectionGraphRuntimeQuery,
        in shard: ImmutableShard
    ) -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition {
        guard query.selectedSources.count <= policy.maximumSelectedSourceCountPerQuery else {
            return .unavailable(.budgetExceeded)
        }

        var generationsByFileID: [UUID: UInt64] = [:]
        for source in query.selectedSources {
            if let generation = generationsByFileID[source.fileID], generation != source.requestGeneration {
                return .unavailable(.invalidQuery)
            }
            generationsByFileID[source.fileID] = source.requestGeneration
        }
        let selectedSources = generationsByFileID.map {
            WorkspaceCodemapSelectionGraphRuntimeQuerySource(
                fileID: $0.key,
                requestGeneration: $0.value
            )
        }.sorted(by: querySourcePrecedes)
        guard selectedSources.count <= policy.maximumSelectedSourceCountPerQuery else {
            return .unavailable(.budgetExceeded)
        }

        let selectedFileIDs = Set(generationsByFileID.keys)
        var coverage: [WorkspaceCodemapSelectionGraphRuntimeSourceCoverage] = []
        var resolutions: [IndexedResolution] = []
        var targetIndices = Set<Int>()
        var failures: [IndexedFailure] = []

        for source in selectedSources {
            guard let sourceIndex = shard.nodeIndexByFileID[source.fileID] else {
                coverage.append(.init(source: source, state: .missing))
                continue
            }
            let sourceNode = shard.nodes[sourceIndex]
            guard sourceNode.requestGeneration == source.requestGeneration else {
                coverage.append(.init(source: source, state: .stale))
                continue
            }
            coverage.append(.init(source: source, state: .covered))
            let sourceEndpoint = shard.endpoint(at: sourceIndex)

            for targetIndex in shard.adjacency[sourceIndex, default: []] {
                guard shard.nodes.indices.contains(targetIndex) else {
                    failures.append(.init(
                        sourceIndex: sourceIndex,
                        record: .init(
                            source: sourceEndpoint,
                            referencedName: "",
                            failure: .staleTarget
                        )
                    ))
                    guard failures.count <= policy.maximumReferenceFailureCountPerQuery else {
                        return .unavailable(.budgetExceeded)
                    }
                    continue
                }
                let targetNode = shard.nodes[targetIndex]
                guard !selectedFileIDs.contains(targetNode.fileID) else { continue }
                let insertedTarget = targetIndices.insert(targetIndex).inserted
                guard !insertedTarget || targetIndices.count <= policy.maximumResolvedTargetCountPerQuery else {
                    return .unavailable(.budgetExceeded)
                }
                resolutions.append(.init(
                    sourceIndex: sourceIndex,
                    targetIndex: targetIndex,
                    value: .init(source: sourceEndpoint, target: shard.endpoint(at: targetIndex))
                ))
            }
            for failure in shard.referenceFailures[sourceIndex, default: []] {
                failures.append(.init(
                    sourceIndex: sourceIndex,
                    record: .init(
                        source: sourceEndpoint,
                        referencedName: failure.referencedName,
                        failure: failure.failure
                    )
                ))
                guard failures.count <= policy.maximumReferenceFailureCountPerQuery else {
                    return .unavailable(.budgetExceeded)
                }
            }
        }

        resolutions.sort {
            if $0.sourceIndex != $1.sourceIndex { return $0.sourceIndex < $1.sourceIndex }
            return $0.targetIndex < $1.targetIndex
        }
        failures.sort {
            if $0.sourceIndex != $1.sourceIndex { return $0.sourceIndex < $1.sourceIndex }
            return utf8Precedes($0.record.referencedName, $1.record.referencedName)
        }
        let targets = targetIndices.sorted().map(shard.endpoint(at:))
        return .readyPartial(.init(
            key: shard.key,
            selectedSources: selectedSources,
            targets: targets,
            resolutions: resolutions.map(\.value),
            sourceCoverage: coverage,
            definitionUniverseCoverage: .partial(
                indexedNodes: shard.summary.nodeCount,
                candidateCount: .unknown
            ),
            referenceFailures: failures.map(\.record),
            publishedSummary: shard.summary
        ))
    }

    private func recordRejection(
        _ reason: WorkspaceCodemapSelectionGraphRuntimeRejectionReason,
        key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) {
        guard observedKey == key, publishedShard?.key != key else { return }
        switch reason {
        case .inputBindingLimit, .graphSize, .accountingOverflow:
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
        case .invalidSnapshot, .modelStore, .edge, .equalGenerationAuthorityConflict:
            lastUnavailableReason = .invalidSnapshot
            increment(&invalidSnapshotCount)
        case let .rootUnavailable(reason):
            lastUnavailableReason = .explicitRootUnavailable(reason)
        case .rootEpochMismatch, .staleSnapshot:
            break
        }
    }

    private func issueOperationID() -> UInt64? {
        guard nextOperationID < .max else { return nil }
        nextOperationID += 1
        return nextOperationID
    }

    @discardableResult
    private func advanceObservationSerial() -> Bool {
        guard observationSerial < .max else {
            if revokedReason == nil {
                revokedReason = .authorityRevoked
                lastUnavailableReason = .explicitRootUnavailable(.authorityRevoked)
            }
            for operation in activeOperations.values {
                operation.task.cancel()
            }
            return false
        }
        observationSerial += 1
        return true
    }

    private func increment(_ value: inout UInt64) {
        if value < .max {
            value += 1
        }
    }

    private static func buildShard(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        key: WorkspaceCodemapSelectionGraphRuntimeKey,
        sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy
    ) -> BuildOutput {
        do {
            try Task.checkCancellation()
            let bindings = try validatedSortedBindings(snapshot: snapshot, key: key)
            if bindings.isEmpty {
                let summary = WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                    key: key,
                    nodeCount: 0,
                    uniqueEdgeCount: 0,
                    sizeAccounting: .zero,
                    isEmpty: true
                )
                return .success(.init(
                    key: key,
                    nodes: [],
                    nodeIndexByFileID: [:],
                    adjacency: [:],
                    referenceFailures: [:],
                    summary: summary
                ))
            }

            guard let store = WorkspaceCodemapSelectionGraphModelStore.authorized(
                by: bindings[0],
                contributionGeneration: key.contributionGeneration,
                schemaVersion: key.schemaVersion,
                policyVersion: key.policyVersion,
                sizePolicy: sizePolicy
            ) else {
                return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
            }

            var graphNodes: [WorkspaceCodemapSelectionGraphNode] = []
            for binding in bindings {
                try Task.checkCancellation()
                switch store.accept(binding) {
                case let .accepted(node, _):
                    graphNodes.append(node)
                case let .exactDuplicate(node, _):
                    graphNodes.append(node)
                case let .rejected(.sizeLimitExceeded(rejection)):
                    return .rejected(.graphSize(rejection))
                case let .rejected(rejection):
                    return .rejected(.modelStore(rejection))
                }
            }

            let nodes = graphNodes.map {
                ImmutableNode(fileID: $0.identity.fileID, requestGeneration: $0.identity.requestGeneration)
            }
            let indexByIdentity = Dictionary(uniqueKeysWithValues: graphNodes.indices.map {
                (graphNodes[$0].identity, $0)
            })
            let nodeIndexByFileID = Dictionary(uniqueKeysWithValues: nodes.indices.map {
                (nodes[$0].fileID, $0)
            })
            var lookupCache: [String: CachedLookup] = [:]
            var uniqueEdges = Set<LocalEdge>()
            var adjacency: [Int: [Int]] = [:]
            var referenceFailures: [Int: [ImmutableReferenceFailure]] = [:]

            for sourceIndex in graphNodes.indices {
                let source = graphNodes[sourceIndex]
                for referencedName in source.references {
                    try Task.checkCancellation()
                    let lookup: CachedLookup
                    if let cached = lookupCache[referencedName] {
                        lookup = cached
                    } else {
                        switch store.definitionCandidates(named: referencedName, among: graphNodes) {
                        case let .candidates(candidates) where candidates.orderedCandidates.isEmpty:
                            lookup = .failure(.unresolvedDefinitionUniverse)
                        case let .candidates(candidates):
                            lookup = .targets(candidates.orderedCandidates)
                        case .candidateOverflow:
                            lookup = .failure(.candidateOverflow)
                        case .graphMismatch:
                            return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
                        }
                        lookupCache[referencedName] = lookup
                    }

                    switch lookup {
                    case let .failure(failure):
                        referenceFailures[sourceIndex, default: []].append(.init(
                            referencedName: referencedName,
                            failure: failure
                        ))
                    case let .targets(targets):
                        for targetIdentity in targets {
                            try Task.checkCancellation()
                            guard let targetIndex = indexByIdentity[targetIdentity] else {
                                return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
                            }
                            let localEdge = LocalEdge(sourceIndex: sourceIndex, targetIndex: targetIndex)
                            guard uniqueEdges.insert(localEdge).inserted else { continue }
                            switch store.makeEdge(source: source.identity, target: targetIdentity) {
                            case .edge:
                                adjacency[sourceIndex, default: []].append(targetIndex)
                            case let .rejected(.sizeLimitExceeded(rejection)):
                                return .rejected(.graphSize(rejection))
                            case let .rejected(rejection):
                                return .rejected(.edge(rejection))
                            }
                        }
                    }
                }
            }
            for sourceIndex in Array(adjacency.keys) {
                adjacency[sourceIndex]?.sort()
            }
            for sourceIndex in Array(referenceFailures.keys) {
                referenceFailures[sourceIndex]?.sort {
                    utf8Precedes($0.referencedName, $1.referencedName)
                }
            }
            try Task.checkCancellation()

            let accounting = WorkspaceCodemapSelectionGraphRuntimeSizeAccounting(store.accounting)
            let summary = WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                key: key,
                nodeCount: accounting.nodes,
                uniqueEdgeCount: accounting.edges,
                sizeAccounting: accounting,
                isEmpty: false
            )
            return .success(.init(
                key: key,
                nodes: nodes,
                nodeIndexByFileID: nodeIndexByFileID,
                adjacency: adjacency,
                referenceFailures: referenceFailures,
                summary: summary
            ))
        } catch is CancellationError {
            return .cancelled
        } catch let BuildValidationError.reason(reason) {
            return .rejected(.invalidSnapshot(reason))
        } catch {
            return .rejected(.accountingOverflow)
        }
    }

    private static func validatedSortedBindings(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) throws -> [WorkspaceCodemapArtifactBinding] {
        var fileIDs = Set<UUID>()
        var relativePaths = Set<String>()
        for binding in snapshot.bindings {
            try Task.checkCancellation()
            guard binding.identity.rootID == key.rootEpoch.rootID,
                  binding.identity.rootLifetimeID == key.rootEpoch.rootLifetimeID
            else { throw BuildValidationError.reason(.bindingRootEpochMismatch) }
            guard fileIDs.insert(binding.identity.fileID).inserted else {
                throw BuildValidationError.reason(.duplicateFileID)
            }
            guard relativePaths.insert(binding.identity.standardizedRelativePath).inserted else {
                throw BuildValidationError.reason(.duplicateRelativePath)
            }
            switch binding.availability {
            case .pending:
                throw BuildValidationError.reason(.bindingNotResolved)
            case .unsupported:
                throw BuildValidationError.reason(.terminalBinding)
            case let .resolved(completion):
                guard completion.token.isFactoryValidated,
                      completion.sourceProof.isFactoryValidated,
                      completion.token.identity == binding.identity,
                      completion.sourceProof == completion.token.sourceExpectation
                else { throw BuildValidationError.reason(.inconsistentCompletionAuthority) }
                guard completion.sourceProof.sourceAuthority.rootEpoch == key.rootEpoch else {
                    throw BuildValidationError.reason(.bindingRootEpochMismatch)
                }
                guard completion.token.catalogGeneration == key.catalogGeneration else {
                    throw BuildValidationError.reason(.catalogGenerationMismatch)
                }
                guard completion.sourceProof.sourceAuthority.repositoryAuthority == key.repositoryAuthority else {
                    throw BuildValidationError.reason(.repositoryAuthorityMismatch)
                }
                switch completion.outcome {
                case .ready, .readyNoSymbols:
                    guard key.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion else {
                        throw BuildValidationError.reason(.contributionSchemaMismatch)
                    }
                    guard key.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion else {
                        throw BuildValidationError.reason(.contributionPolicyMismatch)
                    }
                case .oversize, .decodeFailed, .parseFailed:
                    throw BuildValidationError.reason(.terminalBinding)
                }
            }
        }
        return snapshot.bindings.sorted {
            if $0.identity.standardizedRelativePath != $1.identity.standardizedRelativePath {
                return utf8Precedes(
                    $0.identity.standardizedRelativePath,
                    $1.identity.standardizedRelativePath
                )
            }
            if $0.identity.fileID != $1.identity.fileID {
                return uuidPrecedes($0.identity.fileID, $1.identity.fileID)
            }
            return requestGeneration(of: $0) < requestGeneration(of: $1)
        }
    }
}

private struct ImmutableNode: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
}

private struct ImmutableReferenceFailure: Hashable {
    let referencedName: String
    let failure: WorkspaceCodemapSelectionGraphReferenceFailure
}

private struct ImmutableShard: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let nodes: [ImmutableNode]
    let nodeIndexByFileID: [UUID: Int]
    let adjacency: [Int: [Int]]
    let referenceFailures: [Int: [ImmutableReferenceFailure]]
    let summary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary

    func endpoint(at index: Int) -> WorkspaceCodemapSelectionGraphRuntimeEndpoint {
        let node = nodes[index]
        return .init(rootEpoch: key.rootEpoch, fileID: node.fileID, requestGeneration: node.requestGeneration)
    }
}

private struct LocalEdge: Hashable {
    let sourceIndex: Int
    let targetIndex: Int
}

private enum CachedLookup {
    case targets([WorkspaceCodemapSelectionGraphNodeIdentity])
    case failure(WorkspaceCodemapSelectionGraphReferenceFailure)
}

private enum BuildOutput: Equatable {
    case success(ImmutableShard)
    case rejected(WorkspaceCodemapSelectionGraphRuntimeRejectionReason)
    case cancelled
}

private enum BuildValidationError: Error {
    case reason(WorkspaceCodemapSelectionGraphRuntimeValidationReason)
}

private struct ActiveOperation {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let task: Task<BuildOutput, Never>
}

private struct IndexedResolution {
    let sourceIndex: Int
    let targetIndex: Int
    let value: WorkspaceCodemapSelectionGraphRuntimeResolution
}

private struct IndexedFailure {
    let sourceIndex: Int
    let record: WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord
}

private func querySourcePrecedes(
    _ lhs: WorkspaceCodemapSelectionGraphRuntimeQuerySource,
    _ rhs: WorkspaceCodemapSelectionGraphRuntimeQuerySource
) -> Bool {
    if lhs.fileID != rhs.fileID { return uuidPrecedes(lhs.fileID, rhs.fileID) }
    return lhs.requestGeneration < rhs.requestGeneration
}

private func requestGeneration(of binding: WorkspaceCodemapArtifactBinding) -> UInt64 {
    switch binding.availability {
    case let .pending(token): token.requestGeneration
    case let .resolved(completion): completion.token.requestGeneration
    case .unsupported: 0
    }
}

private func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString.utf8.lexicographicallyPrecedes(rhs.uuidString.utf8)
}

private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
