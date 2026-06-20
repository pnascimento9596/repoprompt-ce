import Foundation

enum SelectedGitDiffArtifactPolicy {
    case includeBeforeGitInclusion
    case respectGitInclusion
}

struct PromptContextPreAssemblyRequest {
    let cfg: PromptContextResolved
    let selection: StoredSelection
    let store: WorkspaceFileContextStore
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeFileTreeLegend: Bool
    let showCodeMapMarkers: Bool
    let codeMapUsage: CodeMapUsage
    let entryResolutionProfile: PathLocateProfile
    let selectedGitDiffFolderPolicy: SelectedGitDiffFolderPolicy
    let selectedGitDiffLookupProfile: PathLocateProfile
    /// Compatibility input retained for callers that previously requested hidden local-definition discovery.
    /// Canonical codemap inclusion is now controlled exclusively by `selection.autoCodemapPaths`.
    let includeLocalDefinitionsInFileTree: Bool
    let selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy
    let reviewGitContext: FrozenPromptGitReviewContext
    let selectedGitDiffProvider: (AutomaticReviewGitDiffRequest) async -> AutomaticReviewGitDiffResult
    let completeGitDiffProvider: () async -> String?

    init(
        cfg: PromptContextResolved,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeFileTreeLegend: Bool = true,
        showCodeMapMarkers: Bool,
        codeMapUsage: CodeMapUsage? = nil,
        entryResolutionProfile: PathLocateProfile = .uiAssisted,
        selectedGitDiffFolderPolicy: SelectedGitDiffFolderPolicy,
        selectedGitDiffLookupProfile: PathLocateProfile? = nil,
        includeLocalDefinitionsInFileTree: Bool = false,
        selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy = .includeBeforeGitInclusion,
        reviewGitContext: FrozenPromptGitReviewContext,
        selectedGitDiffProvider: @escaping (AutomaticReviewGitDiffRequest) async -> AutomaticReviewGitDiffResult,
        completeGitDiffProvider: @escaping () async -> String?
    ) {
        self.cfg = cfg
        self.selection = selection
        self.store = store
        self.lookupContext = lookupContext
        self.filePathDisplay = filePathDisplay
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeFileTreeLegend = includeFileTreeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.codeMapUsage = codeMapUsage ?? cfg.codeMapUsage
        self.entryResolutionProfile = entryResolutionProfile
        self.selectedGitDiffFolderPolicy = selectedGitDiffFolderPolicy
        self.selectedGitDiffLookupProfile = selectedGitDiffLookupProfile ?? entryResolutionProfile
        self.includeLocalDefinitionsInFileTree = includeLocalDefinitionsInFileTree
        self.selectedGitDiffArtifactPolicy = selectedGitDiffArtifactPolicy
        self.reviewGitContext = reviewGitContext
        self.selectedGitDiffProvider = selectedGitDiffProvider
        self.completeGitDiffProvider = completeGitDiffProvider
    }
}

enum PromptGitDiffResolution: Equatable {
    case none
    case selectedArtifact(String)
    case automatic(AutomaticReviewGitDiffResult)
    case complete(String?)

    var text: String? {
        switch self {
        case .none:
            nil
        case let .selectedArtifact(text):
            text
        case let .automatic(result):
            result.text
        case let .complete(text):
            text
        }
    }
}

struct PromptContextPreAssemblyResult {
    let physicalSelection: StoredSelection
    let entries: [ResolvedPromptFileEntry]
    let missingPaths: [String]
    let invalidPaths: [String]
    let codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle
    let fileTreeContent: String?
    let gitDiff: String?
    let gitDiffResolution: PromptGitDiffResolution
    let selectedGitArtifactDispositions: [SelectedGitArtifactDisposition]
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay

    func displayPath(for entry: ResolvedPromptFileEntry) -> String? {
        lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: entry.file.standardizedFullPath,
            display: filePathDisplay
        )
    }
}

enum PromptContextPreAssemblyService {
    static func resolve(_ request: PromptContextPreAssemblyRequest) async -> PromptContextPreAssemblyResult {
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let ordinaryRootScope = request.lookupContext.rootScope.excludingWorkspaceGitData
        let artifactAuthorization = await authorizeSelectedGitArtifacts(
            request: request,
            physicalSelection: physicalSelection
        )
        let ordinarySelection = selection(
            physicalSelection,
            excluding: artifactAuthorization.consumedSelectionPaths
        )
        let codemapSnapshotBundle = await request.store.codemapSnapshotBundle(
            rootScope: ordinaryRootScope
        )
        let accountingService = PromptContextAccountingService()
        let resolution = await accountingService.resolveEntries(
            selection: ordinarySelection,
            store: request.store,
            rootScope: ordinaryRootScope,
            profile: request.entryResolutionProfile,
            codeMapUsage: request.codeMapUsage,
            codemapSnapshotBundle: codemapSnapshotBundle
        )
        let fileTreeContent = await resolveFileTreeContent(
            request: request,
            physicalSelection: ordinarySelection,
            codemapSnapshotBundle: codemapSnapshotBundle,
            rootScope: ordinaryRootScope
        )
        let allEntries = artifactAuthorization.entries + resolution.entries
        let gitDiffResolution = await resolveGitDiff(
            request: request,
            physicalSelection: ordinarySelection,
            entries: allEntries,
            rootScope: ordinaryRootScope
        )
        let packagingEntries = entriesForPackaging(request: request, entries: allEntries)

        return PromptContextPreAssemblyResult(
            physicalSelection: physicalSelection,
            entries: packagingEntries,
            missingPaths: resolution.missingPaths,
            invalidPaths: resolution.invalidPaths,
            codemapSnapshotBundle: codemapSnapshotBundle,
            fileTreeContent: fileTreeContent,
            gitDiff: gitDiffResolution.text,
            gitDiffResolution: gitDiffResolution,
            selectedGitArtifactDispositions: artifactAuthorization.dispositions,
            lookupContext: request.lookupContext,
            filePathDisplay: request.filePathDisplay
        )
    }

    private static func authorizeSelectedGitArtifacts(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection
    ) async -> SelectedGitArtifactAuthorizationResult {
        guard let capability = request.reviewGitContext.artifactCapability else {
            return SelectedGitArtifactAuthorizationResult(
                entries: [],
                consumedSelectionPaths: [],
                dispositions: []
            )
        }
        return await SelectedGitDiffArtifactAuthorizationService().authorize(
            SelectedGitArtifactAuthorizationRequest(
                physicalSelection: physicalSelection,
                capability: capability,
                store: request.store,
                delegationConsumer: request.reviewGitContext.artifactDelegationConsumer
            )
        )
    }

    private static func selection(
        _ selection: StoredSelection,
        excluding consumedPaths: Set<String>
    ) -> StoredSelection {
        guard !consumedPaths.isEmpty else { return selection }
        let normalizedConsumed = Set(consumedPaths.compactMap(StoredSelectionPathNormalization.standardizedPath))
        func isConsumed(_ path: String) -> Bool {
            consumedPaths.contains(path)
                || StoredSelectionPathNormalization.standardizedPath(path).map(normalizedConsumed.contains) == true
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.filter { !isConsumed($0) },
            autoCodemapPaths: selection.autoCodemapPaths.filter { !isConsumed($0) },
            slices: selection.slices.filter { !isConsumed($0.key) },
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private static func resolveFileTreeContent(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle,
        rootScope: WorkspaceLookupRootScope
    ) async -> String? {
        guard request.cfg.rendersFileTree else { return nil }

        let rawFileTreeSnapshot = await request.store.makeFileTreeSelectionSnapshot(
            selection: physicalSelection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: WorkspaceFileTreeSnapshotMode(fileTreeOption: request.cfg.effectiveFileTreeMode),
                filePathDisplay: request.filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
                includeLegend: request.includeFileTreeLegend,
                showCodeMapMarkers: request.showCodeMapMarkers,
                rootScope: rootScope
            ),
            codemapSnapshotBundle: codemapSnapshotBundle,
            profile: request.entryResolutionProfile
        )
        let fileTreeSnapshot = request.lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(rawFileTreeSnapshot) ?? rawFileTreeSnapshot
        let tree = CodeMapExtractor.generateFileTree(using: fileTreeSnapshot)
        return tree.isEmpty ? nil : tree
    }

    private static func entriesForPackaging(
        request: PromptContextPreAssemblyRequest,
        entries: [ResolvedPromptFileEntry]
    ) -> [ResolvedPromptFileEntry] {
        guard request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
              request.cfg.gitInclusion == .none
        else { return entries }
        let (_, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        return codeEntries
    }

    private static func resolveGitDiff(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        entries: [ResolvedPromptFileEntry],
        rootScope: WorkspaceLookupRootScope
    ) async -> PromptGitDiffResolution {
        let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        if request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
           request.cfg.gitInclusion == .none
        {
            return .none
        }

        return await PromptPackagingService.resolveGitDiffResolution(fromDiffEntries: diffEntries) {
            switch request.cfg.gitInclusion {
            case .none:
                return .none
            case .selected:
                let pathResolution = await WorkspaceGitDiffSelectionResolver.resolveSelectedGitDiffPaths(
                    for: physicalSelection,
                    store: request.store,
                    rootScope: rootScope,
                    folderPolicy: request.selectedGitDiffFolderPolicy,
                    profile: request.selectedGitDiffLookupProfile,
                    allowFilesystemFallback: rootScope.allowsSelectedGitDiffFilesystemFallback,
                    excluding: []
                )
                let result = await request.selectedGitDiffProvider(
                    AutomaticReviewGitDiffRequest(
                        pathResolution: pathResolution,
                        compareIntent: request.reviewGitContext.compareIntent,
                        displayContext: request.reviewGitContext.displayContext
                    )
                )
                return .automatic(result)
            case .complete:
                if request.lookupContext.bindingProjection != nil {
                    return .complete(PromptContextGitDiffPolicy.deferredCompleteWorktreeGitDiffMessage)
                }
                return await .complete(request.completeGitDiffProvider())
            }
        }
    }
}

extension WorkspaceLookupRootScope {
    var excludingWorkspaceGitData: WorkspaceLookupRootScope {
        switch self {
        case .visibleWorkspace, .sessionBoundWorkspace, .validatedSessionBoundWorkspace:
            self
        case .visibleWorkspacePlusGitData:
            .visibleWorkspace
        case .allLoaded, .allLoadedExcludingGitData:
            .allLoadedExcludingGitData
        }
    }
}
