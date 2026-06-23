import Foundation

struct WorkspaceCodemapSelectionGraphRuntimeKey: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32

    init(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        schemaVersion: UInt32 = CodeMapSelectionGraphContribution.currentSchemaVersion,
        policyVersion: UInt32 = CodeMapSelectionGraphContribution.currentPolicyVersion
    ) {
        rootEpoch = snapshot.rootEpoch
        catalogGeneration = snapshot.catalogGeneration
        repositoryAuthority = snapshot.repositoryAuthority
        contributionGeneration = snapshot.contributionGeneration
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
    }
}

struct WorkspaceCodemapSelectionGraphRuntimeSizeAccounting: Hashable {
    static let zero = Self(nodes: 0, postings: 0, edges: 0, bytes: 0)

    let nodes: UInt64
    let postings: UInt64
    let edges: UInt64
    let bytes: UInt64

    init(_ accounting: WorkspaceCodemapSelectionGraphSizeAccounting) {
        nodes = accounting.nodes
        postings = accounting.postings
        edges = accounting.edges
        bytes = accounting.bytes
    }

    init(nodes: UInt64, postings: UInt64, edges: UInt64, bytes: UInt64) {
        self.nodes = nodes
        self.postings = postings
        self.edges = edges
        self.bytes = bytes
    }
}

struct WorkspaceCodemapSelectionGraphRuntimePublishedSummary: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let nodeCount: UInt64
    let uniqueEdgeCount: UInt64
    let sizeAccounting: WorkspaceCodemapSelectionGraphRuntimeSizeAccounting
    let isEmpty: Bool
}

struct WorkspaceCodemapSelectionGraphRuntimePolicy: Hashable {
    static let initial = Self(
        maximumActiveRebuildCount: 1,
        maximumReservedBindingCount: 100_000,
        maximumInputBindingCount: 100_000,
        maximumSelectedSourceCountPerQuery: 4096,
        maximumResolvedTargetCountPerQuery: 100_000,
        maximumReferenceFailureCountPerQuery: 100_000,
        graphSizePolicy: .initial
    )

    let maximumActiveRebuildCount: Int
    let maximumReservedBindingCount: Int
    let maximumInputBindingCount: Int
    let maximumSelectedSourceCountPerQuery: Int
    let maximumResolvedTargetCountPerQuery: Int
    let maximumReferenceFailureCountPerQuery: Int
    let graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy

    init(
        maximumActiveRebuildCount: Int,
        maximumReservedBindingCount: Int,
        maximumInputBindingCount: Int,
        maximumSelectedSourceCountPerQuery: Int,
        maximumResolvedTargetCountPerQuery: Int,
        maximumReferenceFailureCountPerQuery: Int,
        graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy
    ) {
        precondition(maximumActiveRebuildCount > 0)
        precondition(maximumReservedBindingCount > 0)
        precondition(maximumInputBindingCount > 0)
        precondition(maximumSelectedSourceCountPerQuery > 0)
        precondition(maximumResolvedTargetCountPerQuery > 0)
        precondition(maximumReferenceFailureCountPerQuery > 0)
        self.maximumActiveRebuildCount = maximumActiveRebuildCount
        self.maximumReservedBindingCount = maximumReservedBindingCount
        self.maximumInputBindingCount = maximumInputBindingCount
        self.maximumSelectedSourceCountPerQuery = maximumSelectedSourceCountPerQuery
        self.maximumResolvedTargetCountPerQuery = maximumResolvedTargetCountPerQuery
        self.maximumReferenceFailureCountPerQuery = maximumReferenceFailureCountPerQuery
        self.graphSizePolicy = graphSizePolicy
    }
}

enum WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason: Hashable {
    case rootUnloaded
    case authorityRevoked
}

enum WorkspaceCodemapSelectionGraphRuntimeValidationReason: Hashable {
    case bindingNotResolved
    case terminalBinding
    case bindingRootEpochMismatch
    case catalogGenerationMismatch
    case repositoryAuthorityMismatch
    case duplicateFileID
    case duplicateRelativePath
    case inconsistentCompletionAuthority
    case contributionSchemaMismatch
    case contributionPolicyMismatch
}

enum WorkspaceCodemapSelectionGraphRuntimeBusyReason: Hashable {
    case actorActiveRebuildLimit
    case actorReservedBindingLimit
    case processAdmission(CodeMapSelectionGraphAdmissionBusyReason)
}

enum WorkspaceCodemapSelectionGraphRuntimeRejectionReason: Hashable {
    case rootEpochMismatch
    case staleSnapshot(
        received: WorkspaceCodemapSelectionGraphContributionGeneration,
        current: WorkspaceCodemapSelectionGraphContributionGeneration
    )
    case equalGenerationAuthorityConflict
    case rootUnavailable(WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason)
    case invalidSnapshot(WorkspaceCodemapSelectionGraphRuntimeValidationReason)
    case inputBindingLimit(attempted: Int, limit: Int)
    case graphSize(WorkspaceCodemapSelectionGraphSizeRejection)
    case modelStore(WorkspaceCodemapSelectionGraphContributionRejection)
    case edge(WorkspaceCodemapSelectionGraphEdgeRejection)
    case accountingOverflow
}

enum WorkspaceCodemapSelectionGraphRuntimeRebuildDisposition: Hashable {
    case published(WorkspaceCodemapSelectionGraphRuntimePublishedSummary)
    case publishedEmpty(WorkspaceCodemapSelectionGraphRuntimePublishedSummary)
    case busy(
        WorkspaceCodemapSelectionGraphRuntimeKey,
        WorkspaceCodemapSelectionGraphRuntimeBusyReason
    )
    case cancelled(WorkspaceCodemapSelectionGraphRuntimeKey)
    case rejected(
        WorkspaceCodemapSelectionGraphRuntimeKey?,
        WorkspaceCodemapSelectionGraphRuntimeRejectionReason
    )
    case superseded(WorkspaceCodemapSelectionGraphRuntimeKey)
}

struct WorkspaceCodemapSelectionGraphRuntimeQuerySource: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
}

struct WorkspaceCodemapSelectionGraphRuntimeQuery: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let selectedSources: [WorkspaceCodemapSelectionGraphRuntimeQuerySource]
}

struct WorkspaceCodemapSelectionGraphRuntimeEndpoint: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let requestGeneration: UInt64
}

struct WorkspaceCodemapSelectionGraphRuntimeSourceCoverage: Hashable {
    let source: WorkspaceCodemapSelectionGraphRuntimeQuerySource
    let state: WorkspaceCodemapSelectionGraphSourceCoverageState
}

struct WorkspaceCodemapSelectionGraphRuntimeResolution: Hashable {
    let source: WorkspaceCodemapSelectionGraphRuntimeEndpoint
    let target: WorkspaceCodemapSelectionGraphRuntimeEndpoint
}

struct WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord: Hashable {
    let source: WorkspaceCodemapSelectionGraphRuntimeEndpoint
    let referencedName: String
    let failure: WorkspaceCodemapSelectionGraphReferenceFailure
}

struct WorkspaceCodemapSelectionGraphRuntimeQueryResult: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let selectedSources: [WorkspaceCodemapSelectionGraphRuntimeQuerySource]
    let targets: [WorkspaceCodemapSelectionGraphRuntimeEndpoint]
    let resolutions: [WorkspaceCodemapSelectionGraphRuntimeResolution]
    let sourceCoverage: [WorkspaceCodemapSelectionGraphRuntimeSourceCoverage]
    let definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage
    let referenceFailures: [WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord]
    let publishedSummary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary
}

enum WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason: Hashable {
    case notBuilt
    case rebuilding
    case staleCurrentness(currentKey: WorkspaceCodemapSelectionGraphRuntimeKey?)
    case actorAdmissionRejected(WorkspaceCodemapSelectionGraphRuntimeBusyReason)
    case processAdmissionRejected(CodeMapSelectionGraphAdmissionBusyReason)
    case cancelled
    case budgetExceeded
    case invalidSnapshot
    case explicitRootUnavailable(WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason)
    case invalidQuery
}

enum WorkspaceCodemapSelectionGraphRuntimeQueryDisposition: Hashable {
    case readyPartial(WorkspaceCodemapSelectionGraphRuntimeQueryResult)
    case unavailable(WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason)
}

enum WorkspaceCodemapSelectionGraphRuntimeDiagnosticEventKind: Hashable {
    case buildStarted
    case beforePublication
}

struct WorkspaceCodemapSelectionGraphRuntimeDiagnosticEvent: Hashable {
    let operationID: UInt64
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let kind: WorkspaceCodemapSelectionGraphRuntimeDiagnosticEventKind
}

struct WorkspaceCodemapSelectionGraphRuntimeDiagnostics {
    static let none = Self { _ in }

    let handle: @Sendable (WorkspaceCodemapSelectionGraphRuntimeDiagnosticEvent) -> Void
}

struct WorkspaceCodemapSelectionGraphRuntimeAccounting: Equatable {
    let activeRebuildCount: Int
    let reservedInputBindingCount: Int
    let publishedSummary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary?
    let currentObservedKey: WorkspaceCodemapSelectionGraphRuntimeKey?
    let currentUnavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason?
    let publishedCount: UInt64
    let emptyPublishedCount: UInt64
    let actorBusyCount: UInt64
    let processBusyCount: UInt64
    let cancelledCount: UInt64
    let budgetRejectedCount: UInt64
    let invalidSnapshotCount: UInt64
    let supersededPublicationCount: UInt64
}
