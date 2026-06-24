import Foundation

actor WorkspaceRootReusableSnapshotCoordinator {
    enum ObservationResult: Equatable {
        case admitted(WorkspaceRootReusableSnapshotIdentity)
        case nonGit
        case unsupportedRoot
        case authorityUnavailable(GitWorkspaceAuthorityUnavailableReason)
        case catalogMismatch
        case failed
    }

    static let shared = WorkspaceRootReusableSnapshotCoordinator()

    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared
    ) {
        self.gitService = gitService
        self.authority = authority
    }

    func observeAuthoritativeFullLoad(
        rootURL: URL,
        authoritativeRelativeFilePaths: Set<String>
    ) async -> ObservationResult {
        guard let layout = Self.gitLayoutContaining(rootURL) else { return .nonGit }
        guard let prefix = try? Self.rootPrefix(rootURL: rootURL, layout: layout) else {
            return .unsupportedRoot
        }

        var discoveryObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var replacementObservation: GitWorkspaceMetadataMonitor.RetainToken?
        do {
            // The base observation stays live until replacement coverage has been
            // installed. A policy-path change during either collection advances
            // the shared watermark and prevents conditional admission.
            let discoveryToken = try await authority.retainMetadataObservation(for: layout)
            discoveryObservation = discoveryToken
            let discovery = try await gitService.workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            let discoveredExternalPaths = Self.canonicalPathSet(
                discovery.metadata.resolvedExternalAuthorityPaths
            )

            let observation = try await authority.retainMetadataObservation(
                for: layout,
                additionalAuthorityPaths: discovery.metadata.resolvedExternalAuthorityPaths
            )
            replacementObservation = observation
            await authority.releaseMetadataObservation(discoveryToken)
            discoveryObservation = nil

            let scope = GitWorkspaceAuthorityScopeKey(
                repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
                repositoryRelativeRootPrefix: prefix
            )
            let captureToken: GitWorkspaceAuthorityCaptureToken
            switch await authority.beginCollection(scopeKey: scope) {
            case let .success(token):
                captureToken = token
            case let .failure(reason):
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(reason)
            }

            let captured = try await gitService.workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            guard Self.canonicalPathSet(captured.metadata.resolvedExternalAuthorityPaths) == discoveredExternalPaths,
                  await authority.metadataObservationIsCurrent(
                      observation,
                      for: layout,
                      additionalAuthorityPaths: captured.metadata.resolvedExternalAuthorityPaths,
                      expectedAcceptedWatermark: captureToken.acceptedMetadataWatermark
                  )
            else {
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(.invalidatedDuringCollection)
            }
            let tree = try await gitService.listTree(
                captured.snapshot.treeOID,
                in: layout,
                prefix: prefix
            )
            let lease: GitWorkspaceAuthorityLease
            switch await authority.install(captured.snapshot, capturedUsing: captureToken) {
            case let .success(installed):
                lease = installed
            case let .failure(reason):
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(reason)
            }
            guard let snapshot = WorkspaceRootReusableSnapshot.make(
                authority: captured.snapshot,
                tree: tree,
                authoritativeRelativeFilePaths: authoritativeRelativeFilePaths
            ) else {
                await authority.releaseMetadataObservation(observation)
                return .catalogMismatch
            }
            replacementObservation = nil
            let admitted = await authority.admitReusableSnapshot(
                snapshot,
                capturedUsing: lease,
                observationToken: observation
            )
            return admitted ? .admitted(snapshot.identity) : .failed
        } catch {
            if let discoveryObservation {
                await authority.releaseMetadataObservation(discoveryObservation)
            }
            if let replacementObservation {
                await authority.releaseMetadataObservation(replacementObservation)
            }
            return .failed
        }
    }

    private nonisolated static func canonicalPathSet(_ paths: [URL]) -> Set<String> {
        Set(paths.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
    }

    private nonisolated static func gitLayoutContaining(_ rootURL: URL) -> GitRepositoryLayout? {
        var candidate = rootURL.standardizedFileURL
        while true {
            if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate) {
                return layout
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private nonisolated static func rootPrefix(
        rootURL: URL,
        layout: GitRepositoryLayout
    ) throws -> GitRepositoryRelativeRootPrefix {
        let rootPath = rootURL.standardizedFileURL.path
        let worktreePath = layout.workTreeRoot.standardizedFileURL.path
        guard rootPath == worktreePath || rootPath.hasPrefix(worktreePath + "/") else {
            throw GitWorktreeInitializationError.invalidRootPrefix
        }
        let relative = rootPath == worktreePath
            ? ""
            : String(rootPath.dropFirst(worktreePath.count + 1))
        return try GitRepositoryRelativeRootPrefix(relative)
    }
}
