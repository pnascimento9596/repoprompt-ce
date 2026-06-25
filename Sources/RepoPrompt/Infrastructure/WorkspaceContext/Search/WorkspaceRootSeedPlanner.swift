import Foundation

enum WorkspaceRootSeedServingPlanningOutcome: Equatable {
    case planned(
        plan: WorkspaceRootSeedPlan,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence
    )
    case fallback(WorkspaceRootSeedFallbackReason)
}

actor WorkspaceRootSeedPlanner {
    private typealias PathKey = WorkspaceRootByteExactPathKey

    static let shared = WorkspaceRootSeedPlanner()

    private struct SeedEntry {
        let mode: String
        let kind: GitTreeEntryKind
        let catalogProjection: RootNeutralTreeInventoryEntry.CatalogProjection?
    }

    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority
    private let limits: WorkspaceRootSeedPlannerLimits

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared,
        limits: WorkspaceRootSeedPlannerLimits = .production
    ) {
        self.gitService = gitService
        self.authority = authority
        self.limits = limits
    }

    func plan(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService
    ) async -> WorkspaceRootSeedPlannerOutcome {
        let result = await planningResult(
            hint: hint,
            service: service,
            retainFinalAuthorityFence: false
        )
        return result.outcome
    }

    func planForServing(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService
    ) async -> WorkspaceRootSeedServingPlanningOutcome {
        let result = await planningResult(
            hint: hint,
            service: service,
            retainFinalAuthorityFence: true
        )
        switch result.outcome {
        case let .fallback(reason):
            return .fallback(reason)
        case let .planned(plan):
            guard let fence = result.authorityFence else {
                return .fallback(.authorityUnstable)
            }
            return .planned(plan: plan, authorityFence: fence)
        }
    }

    private func planningResult(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService,
        retainFinalAuthorityFence: Bool
    ) async -> (outcome: WorkspaceRootSeedPlannerOutcome, authorityFence: GitWorkspacePendingInitializationAuthorityFence?) {
        do {
            try Task.checkCancellation()
            guard let snapshot = await authority.reusableSnapshot(
                identity: hint.creationReceipt.parentSnapshotIdentity,
                expectedCompatibilityKey: hint.creationReceipt.parentCompatibilityKey
            ) else { return (.fallback(.baseEvicted), nil) }

            let receipt = hint.creationReceipt
            let before = try await gitService.generationFencedAuthoritySnapshot(
                layout: receipt.targetLayout,
                prefix: receipt.repositoryRelativeRootPrefix
            )
            let targetCompatibility = WorkspaceRootSeedCompatibilityKey(authority: before)
            guard targetCompatibility.isDeltaCompatible(with: snapshot.compatibilityKey),
                  await service.currentWorkspaceRootCatalogPolicyIdentity() == snapshot.catalogPolicyIdentity
            else {
                return (.fallback(.compatibilityMismatch), nil)
            }

            let treeDelta = try await gitService.diffTrees(
                baseTreeOID: snapshot.compatibilityKey.treeOID,
                targetTreeOID: before.treeOID,
                in: receipt.targetLayout,
                prefix: receipt.repositoryRelativeRootPrefix
            )
            let index = try await gitService.indexManifest(
                in: receipt.targetLayout,
                prefix: receipt.repositoryRelativeRootPrefix
            )
            let status = try await gitService.worktreeStatus(
                in: receipt.targetLayout,
                prefix: receipt.repositoryRelativeRootPrefix
            )

            guard Self.byteExactProjectionIsValid(
                snapshot: snapshot,
                treeDelta: treeDelta,
                index: index,
                status: status,
                verificationFacts: [:],
                copiedRepositoryRelativePaths: receipt.exactCopiedRelativePaths,
                prefix: receipt.repositoryRelativeRootPrefix
            ) else { return (.fallback(.compatibilityMismatch), nil) }
            let policyIgnoredBasePaths = Set(snapshot.inventory.entries.compactMap { entry in
                entry.catalogProjection == .policyIgnoredRegularFile || entry.mode == "120000"
                    ? entry.relativePath
                    : nil
            })
            let verificationScope = try Self.verificationScope(
                treeDelta: treeDelta,
                policyIgnoredBasePaths: policyIgnoredBasePaths,
                status: status,
                copiedRepositoryRelativePaths: receipt.exactCopiedRelativePaths,
                prefix: receipt.repositoryRelativeRootPrefix,
                limits: limits
            )
            let facts = try await service.workspaceRootSeedVerificationFacts(
                relativePaths: verificationScope.paths,
                affectedDirectories: verificationScope.directories,
                allowRepositoryMetadataAtRoot: receipt.repositoryRelativeRootPrefix.value.isEmpty,
                limits: limits
            )

            let authorityFence: GitWorkspacePendingInitializationAuthorityFence?
            let after: GitWorkspaceAuthoritySnapshot
            if retainFinalAuthorityFence {
                let fence = try await gitService.pendingInitializationAuthorityFence(
                    layout: receipt.targetLayout,
                    prefix: receipt.repositoryRelativeRootPrefix
                )
                authorityFence = fence
                after = fence.snapshot
            } else {
                authorityFence = nil
                after = try await gitService.generationFencedAuthoritySnapshot(
                    layout: receipt.targetLayout,
                    prefix: receipt.repositoryRelativeRootPrefix
                )
            }
            guard before == after else {
                if let authorityFence {
                    await gitService.releasePendingInitializationAuthorityFence(authorityFence)
                }
                return (.fallback(.authorityUnstable), nil)
            }
            let outcome = Self.materialize(
                snapshot: snapshot,
                targetTreeOID: before.treeOID,
                treeDelta: treeDelta,
                index: index,
                status: status,
                verificationFacts: facts,
                copiedRepositoryRelativePaths: receipt.exactCopiedRelativePaths,
                prefix: receipt.repositoryRelativeRootPrefix,
                limits: limits
            )
            if case .fallback = outcome, let authorityFence {
                await gitService.releasePendingInitializationAuthorityFence(authorityFence)
                return (outcome, nil)
            }
            return (outcome, authorityFence)
        } catch is CancellationError {
            return (.fallback(.cancellation), nil)
        } catch WorkspaceRootSeedVerificationError.limitExceeded {
            return (.fallback(.verificationLimitExceeded), nil)
        } catch WorkspaceRootSeedVerificationError.invalidPath {
            return (.fallback(.unexplainedFilesystemEntry), nil)
        } catch WorkspaceRootSeedVerificationError.unsupportedTopology {
            return (.fallback(.submoduleOrNestedRepository), nil)
        } catch let reason as GitWorkspaceAuthorityUnavailableReason {
            switch reason {
            case .mutationInProgress, .metadataEventPending:
                return (.fallback(.authorityChanging), nil)
            case .noSnapshot, .monitorCoverageUnavailable, .superseded,
                 .invalidatedDuringCollection, .collectionScopeMismatch:
                return (.fallback(.authorityUnstable), nil)
            }
        } catch let error as GitWorktreeInitializationError {
            switch error.reason {
            case .timeout:
                return (.fallback(.gitTimeout), nil)
            case .cappedOutput, .recordLimitExceeded, .pathLimitExceeded:
                return (.fallback(.gitCappedOutput), nil)
            case .malformedOutput, .invalidRootPrefix:
                return (.fallback(.gitMalformedOutput), nil)
            case .gitError:
                return (.fallback(.gitError), nil)
            case .cancelled:
                return (.fallback(.cancellation), nil)
            }
        } catch {
            return (.fallback(.gitError), nil)
        }
    }

    static func materialize(
        snapshot: WorkspaceRootReusableSnapshot,
        targetTreeOID: GitObjectID,
        treeDelta: [GitTreeDeltaRecord],
        index: GitIndexManifest,
        status: GitStatusPorcelainV2Snapshot,
        verificationFacts: [String: WorkspaceRootSeedVerificationFact],
        copiedRepositoryRelativePaths: [String],
        prefix: GitRepositoryRelativeRootPrefix,
        limits: WorkspaceRootSeedPlannerLimits = .production
    ) -> WorkspaceRootSeedPlannerOutcome {
        guard snapshot.compatibilityKey.repositoryRelativeRootPrefix == prefix,
              index.rootPrefix == prefix,
              snapshot.compatibilityKey.objectFormat == targetTreeOID.objectFormat
        else { return .fallback(.compatibilityMismatch) }

        guard !index.sparseCheckoutEnabled else { return .fallback(.sparseCheckout) }
        guard byteExactProjectionIsValid(
            snapshot: snapshot,
            treeDelta: treeDelta,
            index: index,
            status: status,
            verificationFacts: verificationFacts,
            copiedRepositoryRelativePaths: copiedRepositoryRelativePaths,
            prefix: prefix
        ) else { return .fallback(.compatibilityMismatch) }
        let verificationFactsByKey = Dictionary(uniqueKeysWithValues: verificationFacts.values.map {
            (PathKey($0.relativePath), $0)
        })

        let baseFilePathKeys = Set(snapshot.inventory.entries.compactMap { entry in
            entry.isSearchableFile ? PathKey(entry.relativePath) : nil
        })
        if snapshot.inventory.entries.contains(where: { $0.mode == "160000" || $0.kind == .commit }) {
            return .fallback(.submoduleOrNestedRepository)
        }
        if snapshot.inventory.entries.contains(where: { !supported(mode: $0.mode, kind: $0.kind) }) {
            return .fallback(.symlinkOrSpecialTopology)
        }

        var targetTree: [PathKey: SeedEntry] = [:]
        for entry in snapshot.inventory.entries {
            targetTree[PathKey(entry.relativePath)] = SeedEntry(
                mode: entry.mode,
                kind: entry.kind,
                catalogProjection: entry.catalogProjection
            )
        }
        var changedPathKeys = Set<PathKey>()
        for delta in treeDelta {
            guard delta.status != .unmerged else { return .fallback(.conflictOrUnmergedIndex) }
            guard let destinationPath = rootRelative(delta.repositoryRelativePath, prefix: prefix) else {
                return .fallback(.compatibilityMismatch)
            }
            if case .renamed = delta.status {
                guard let sourcePath = delta.sourceRepositoryRelativePath.flatMap({ rootRelative($0, prefix: prefix) }) else {
                    return .fallback(.gitMalformedOutput)
                }
                let source = PathKey(sourcePath)
                targetTree.removeValue(forKey: source)
                changedPathKeys.insert(source)
            }
            let destination = PathKey(destinationPath)
            if delta.oldMode == "120000" || delta.newMode == "120000" {
                return .fallback(.symlinkOrSpecialTopology)
            }
            if case .deleted = delta.status {
                targetTree.removeValue(forKey: destination)
                changedPathKeys.insert(destination)
                continue
            }
            if delta.newMode == "160000" { return .fallback(.submoduleOrNestedRepository) }
            guard let mode = delta.newMode,
                  delta.newObjectID != nil,
                  let kind = kind(for: mode),
                  supported(mode: mode, kind: kind)
            else { return .fallback(.symlinkOrSpecialTopology) }
            let projection: RootNeutralTreeInventoryEntry.CatalogProjection? =
                kind == .blob && (mode == "100644" || mode == "100755")
                    ? nil
                    : .nonRegularTopology
            targetTree[destination] = SeedEntry(
                mode: mode,
                kind: kind,
                catalogProjection: projection
            )
            changedPathKeys.insert(destination)
        }
        for delta in treeDelta where delta.status == .typeChanged || delta.oldMode != delta.newMode {
            guard let relativePath = rootRelative(delta.repositoryRelativePath, prefix: prefix),
                  let fact = verificationFactsByKey[PathKey(relativePath)]
            else { return .fallback(.unexplainedFilesystemEntry) }
            guard factMatches(mode: delta.newMode, fact: fact) else {
                return .fallback(.symlinkOrSpecialTopology)
            }
        }

        var tracked: [PathKey: SeedEntry] = [:]
        for entry in index.entries {
            guard entry.stage == 0 else { return .fallback(.conflictOrUnmergedIndex) }
            guard !entry.assumeUnchanged else { return .fallback(.assumeUnchangedIndexEntry) }
            guard !entry.skipWorktree else { return .fallback(.sparseCheckout) }
            if entry.mode == "160000" { return .fallback(.submoduleOrNestedRepository) }
            guard let relativePathValue = rootRelative(entry.repositoryRelativePath, prefix: prefix),
                  let kind = kind(for: entry.mode),
                  supported(mode: entry.mode, kind: kind)
            else { return .fallback(.symlinkOrSpecialTopology) }
            let relativePath = PathKey(relativePathValue)
            let projection: RootNeutralTreeInventoryEntry.CatalogProjection? =
                kind == .blob && (entry.mode == "100644" || entry.mode == "100755")
                    ? targetTree[relativePath]?.catalogProjection
                    : .nonRegularTopology
            tracked[relativePath] = SeedEntry(
                mode: entry.mode,
                kind: kind,
                catalogProjection: projection
            )
        }
        let targetTreeFilePaths = Set(targetTree.compactMap { relativePath, entry in
            entry.kind == .blob && (entry.mode == "100644" || entry.mode == "100755")
                ? relativePath
                : nil
        })
        let trackedRegularFilePaths = Set(tracked.compactMap { relativePath, entry in
            entry.kind == .blob && (entry.mode == "100644" || entry.mode == "100755")
                ? relativePath
                : nil
        })
        changedPathKeys.formUnion(targetTreeFilePaths.symmetricDifference(trackedRegularFilePaths))

        var fileKeys = Set<PathKey>()
        var policyIgnoredTrackedPathKeys = Set<PathKey>()
        var explicitFolderKeys = Set<PathKey>()
        for (relativePath, entry) in tracked {
            if entry.mode == "120000" {
                continue
            }
            guard entry.kind == .blob,
                  entry.mode == "100644" || entry.mode == "100755"
            else { continue }
            switch entry.catalogProjection {
            case .searchableRegularFile:
                fileKeys.insert(relativePath)
            case .policyIgnoredRegularFile:
                guard let fact = verificationFactsByKey[relativePath],
                      case .regularFile = fact.kind,
                      fact.isIgnored
                else { return .fallback(.compatibilityMismatch) }
                policyIgnoredTrackedPathKeys.insert(relativePath)
            case .nonRegularTopology, nil:
                guard let fact = verificationFactsByKey[relativePath] else {
                    return .fallback(.unexplainedFilesystemEntry)
                }
                guard applyTrackedFact(
                    fact,
                    expectedMode: entry.mode,
                    files: &fileKeys,
                    folders: &explicitFolderKeys,
                    policyIgnoredTrackedPaths: &policyIgnoredTrackedPathKeys
                ) else { return .fallback(.symlinkOrSpecialTopology) }
            }
        }
        for record in status.pathRecords {
            guard record.kind != .unmerged else { return .fallback(.conflictOrUnmergedIndex) }
            if let submoduleState = record.submoduleState,
               submoduleState.first != "N"
            {
                return .fallback(.submoduleOrNestedRepository)
            }
            guard let relativePathValue = rootRelative(record.path, prefix: prefix) else {
                return .fallback(.compatibilityMismatch)
            }
            let relativePath = PathKey(relativePathValue)
            switch record.kind {
            case .unmerged:
                return .fallback(.conflictOrUnmergedIndex)
            case .ignored:
                continue
            case .untracked:
                changedPathKeys.insert(relativePath)
                guard let fact = verificationFactsByKey[relativePath] else {
                    return .fallback(.unexplainedFilesystemEntry)
                }
                guard applyUntrackedFact(fact, files: &fileKeys, folders: &explicitFolderKeys) else {
                    return .fallback(.symlinkOrSpecialTopology)
                }
            case let .renamedOrCopied(originalPath, score):
                changedPathKeys.insert(relativePath)
                guard let sourceValue = rootRelative(originalPath, prefix: prefix),
                      let fact = verificationFactsByKey[relativePath]
                else { return .fallback(.unexplainedFilesystemEntry) }
                let source = PathKey(sourceValue)
                if score.first == "R" {
                    fileKeys.remove(source)
                    policyIgnoredTrackedPathKeys.remove(source)
                }
                guard applyTrackedFact(
                    fact,
                    expectedMode: record.workTreeMode ?? record.indexMode,
                    files: &fileKeys,
                    folders: &explicitFolderKeys,
                    policyIgnoredTrackedPaths: &policyIgnoredTrackedPathKeys
                ) else { return .fallback(.symlinkOrSpecialTopology) }
                changedPathKeys.insert(source)
            case .ordinary:
                if record.hasWorkTreeChange || record.hasIndexChange {
                    changedPathKeys.insert(relativePath)
                }
                if record.workTreeStatus == "D" {
                    fileKeys.remove(relativePath)
                    policyIgnoredTrackedPathKeys.remove(relativePath)
                    continue
                }
                if record.hasWorkTreeChange || record.hasIndexChange {
                    guard let fact = verificationFactsByKey[relativePath] else {
                        return .fallback(.unexplainedFilesystemEntry)
                    }
                    guard applyTrackedFact(
                        fact,
                        expectedMode: record.workTreeMode ?? record.indexMode,
                        files: &fileKeys,
                        folders: &explicitFolderKeys,
                        policyIgnoredTrackedPaths: &policyIgnoredTrackedPathKeys
                    ) else { return .fallback(.symlinkOrSpecialTopology) }
                }
            }
        }

        let copiedRelativePaths = copiedRepositoryRelativePaths.compactMap { rootRelative($0, prefix: prefix) }
        for relativePathValue in copiedRelativePaths {
            let relativePath = PathKey(relativePathValue)
            guard let fact = verificationFactsByKey[relativePath] else {
                return .fallback(.unknownCopiedPath)
            }
            guard applyUntrackedFact(fact, files: &fileKeys, folders: &explicitFolderKeys) else {
                return .fallback(.symlinkOrSpecialTopology)
            }
            if !fact.isIgnored { changedPathKeys.insert(relativePath) }
        }

        // Receipt-affected directory enumeration may expose additional untracked siblings.
        for fact in verificationFacts.values where !tracked.keys.contains(PathKey(fact.relativePath)) {
            guard applyUntrackedFact(fact, files: &fileKeys, folders: &explicitFolderKeys) else {
                return .fallback(.symlinkOrSpecialTopology)
            }
            if !fact.isIgnored, fact.kind != .missing {
                changedPathKeys.insert(PathKey(fact.relativePath))
            }
        }

        var folderKeys = explicitFolderKeys
        for path in fileKeys {
            folderKeys.formUnion(ancestorKeys(of: path))
        }
        var policyFolderCandidateKeys = Set<PathKey>()
        for path in policyIgnoredTrackedPathKeys {
            policyFolderCandidateKeys.formUnion(ancestorKeys(of: path))
        }
        for (path, entry) in tracked where entry.mode == "120000" {
            policyFolderCandidateKeys.formUnion(ancestorKeys(of: path))
        }
        for fact in verificationFacts.values where fact.isIgnored && fact.kind != .missing {
            policyFolderCandidateKeys.formUnion(ancestorKeys(of: PathKey(fact.relativePath)))
        }
        for candidate in policyFolderCandidateKeys {
            guard let fact = verificationFactsByKey[candidate],
                  fact.kind == .directory
            else { return .fallback(.unexplainedFilesystemEntry) }
            if fact.isIncludedInOrdinaryCrawl {
                folderKeys.insert(candidate)
            }
        }

        guard changedPathKeys.count < limits.maximumOverlayChangedFileCount else {
            return .fallback(.overlayThresholdExceeded)
        }
        guard policyIgnoredTrackedPathKeys.isDisjoint(with: fileKeys) else {
            return .fallback(.compatibilityMismatch)
        }
        let files = Set(fileKeys.map(\.value))
        let folders = Set(folderKeys.map(\.value))
        let baseFilePaths = Set(baseFilePathKeys.map(\.value))
        let changedPaths = Set(changedPathKeys.map(\.value))
        let policyIgnoredTrackedPaths = Set(policyIgnoredTrackedPathKeys.map(\.value))
        guard files.count == fileKeys.count,
              folders.count == folderKeys.count,
              baseFilePaths.count == baseFilePathKeys.count,
              changedPaths.count == changedPathKeys.count,
              policyIgnoredTrackedPaths.count == policyIgnoredTrackedPathKeys.count
        else { return .fallback(.compatibilityMismatch) }
        return .planned(WorkspaceRootSeedPlan(
            snapshotIdentity: snapshot.identity,
            targetTreeOID: targetTreeOID,
            relativeFilePaths: files,
            relativeFolderPaths: folders,
            baseRelativeFilePaths: baseFilePaths,
            changedRelativeFilePaths: changedPaths,
            tombstonedBaseRelativeFilePaths: Set(baseFilePathKeys.subtracting(fileKeys).map(\.value)),
            policyIgnoredTrackedRelativeFilePaths: policyIgnoredTrackedPaths,
            verifiedPathCount: verificationFacts.count
        ))
    }

    private static func ancestorKeys(of path: PathKey) -> Set<PathKey> {
        var result = Set<PathKey>()
        var parent = path.parent
        while let current = parent {
            result.insert(current)
            parent = current.parent
        }
        return result
    }

    private static func byteExactProjectionIsValid(
        snapshot: WorkspaceRootReusableSnapshot,
        treeDelta: [GitTreeDeltaRecord],
        index: GitIndexManifest,
        status: GitStatusPorcelainV2Snapshot,
        verificationFacts: [String: WorkspaceRootSeedVerificationFact],
        copiedRepositoryRelativePaths: [String],
        prefix: GitRepositoryRelativeRootPrefix
    ) -> Bool {
        let snapshotPaths = snapshot.inventory.entries.map(\.relativePath)
        guard WorkspaceRootByteExactPathSet(
            snapshotPaths,
            rejectExactDuplicates: true
        ) != nil else { return false }

        var paths = snapshotPaths
        for delta in treeDelta {
            if let path = rootRelative(delta.repositoryRelativePath, prefix: prefix) {
                paths.append(path)
            }
            if let source = delta.sourceRepositoryRelativePath.flatMap({ rootRelative($0, prefix: prefix) }) {
                paths.append(source)
            }
        }
        for entry in index.entries {
            if let path = rootRelative(entry.repositoryRelativePath, prefix: prefix) {
                paths.append(path)
            }
        }
        for record in status.pathRecords {
            if let path = rootRelative(record.path, prefix: prefix) {
                paths.append(path)
            }
            if case let .renamedOrCopied(originalPath, _) = record.kind,
               let source = rootRelative(originalPath, prefix: prefix)
            {
                paths.append(source)
            }
        }
        paths.append(contentsOf: copiedRepositoryRelativePaths.compactMap {
            rootRelative($0, prefix: prefix)
        })
        for (key, fact) in verificationFacts {
            guard PathKey(key) == PathKey(fact.relativePath) else { return false }
            paths.append(key)
        }
        paths.append(contentsOf: paths.flatMap { ancestorKeys(of: PathKey($0)).map(\.value) })
        return WorkspaceRootByteExactPathSet(paths) != nil
    }

    private static func verificationScope(
        treeDelta: [GitTreeDeltaRecord],
        policyIgnoredBasePaths: Set<String>,
        status: GitStatusPorcelainV2Snapshot,
        copiedRepositoryRelativePaths: [String],
        prefix: GitRepositoryRelativeRootPrefix,
        limits: WorkspaceRootSeedPlannerLimits
    ) throws -> (paths: Set<String>, directories: Set<String>) {
        var pathValues = Array(policyIgnoredBasePaths)
        for record in treeDelta {
            if let relative = rootRelative(record.repositoryRelativePath, prefix: prefix) { pathValues.append(relative) }
            if let source = record.sourceRepositoryRelativePath.flatMap({ rootRelative($0, prefix: prefix) }) {
                pathValues.append(source)
            }
        }
        for record in status.pathRecords {
            if let relative = rootRelative(record.path, prefix: prefix) { pathValues.append(relative) }
            if case let .renamedOrCopied(originalPath, _) = record.kind,
               let source = rootRelative(originalPath, prefix: prefix)
            {
                pathValues.append(source)
            }
        }
        for path in copiedRepositoryRelativePaths {
            if let relative = rootRelative(path, prefix: prefix) { pathValues.append(relative) }
        }
        pathValues.append(contentsOf: pathValues.flatMap { path in
            ancestorKeys(of: PathKey(path)).map(\.value)
        })
        guard let exactPaths = WorkspaceRootByteExactPathSet(pathValues) else {
            throw WorkspaceRootSeedVerificationError.invalidPath
        }

        guard exactPaths.count <= limits.maximumVerificationPathCount else {
            throw WorkspaceRootSeedVerificationError.limitExceeded
        }
        // Creation-interval contents are represented by final Git/index/status
        // authority plus the exact include-copy inventory. The seeded watcher is
        // already attached at the receipt's exact end cut before this plan runs,
        // so witness event paths are neither retained nor required here.
        return (Set(exactPaths.stringValues), [])
    }

    private static func rootRelative(
        _ repositoryRelativePath: String,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> String? {
        WorkspaceRootByteExactPathKey.rootRelativePath(
            repositoryRelativePath: repositoryRelativePath,
            prefix: prefix
        )
    }

    private static func kind(for mode: String) -> GitTreeEntryKind? {
        switch mode {
        case "040000": .tree
        case "100644", "100755", "120000": .blob
        case "160000": .commit
        default: nil
        }
    }

    private static func supported(mode: String, kind: GitTreeEntryKind) -> Bool {
        kind == .tree
            || (kind == .blob && (mode == "100644" || mode == "100755" || mode == "120000"))
    }

    private static func factMatches(
        mode: String?,
        fact: WorkspaceRootSeedVerificationFact
    ) -> Bool {
        switch (mode, fact.kind) {
        case (nil, .missing):
            true
        case ("040000", .directory):
            true
        case ("100644", .regularFile(isExecutable: false)):
            true
        case ("100755", .regularFile(isExecutable: true)):
            true
        default:
            false
        }
    }

    @discardableResult
    private static func applyTrackedFact(
        _ fact: WorkspaceRootSeedVerificationFact,
        expectedMode: String?,
        files: inout Set<PathKey>,
        folders: inout Set<PathKey>,
        policyIgnoredTrackedPaths: inout Set<PathKey>
    ) -> Bool {
        let path = PathKey(fact.relativePath)
        switch fact.kind {
        case .missing:
            files.remove(path)
            policyIgnoredTrackedPaths.remove(path)
            return true
        case let .regularFile(isExecutable):
            if let expectedMode,
               (expectedMode == "100755") != isExecutable,
               expectedMode == "100644" || expectedMode == "100755"
            {
                return false
            }
            if fact.isIgnored {
                files.remove(path)
                policyIgnoredTrackedPaths.insert(path)
            } else {
                policyIgnoredTrackedPaths.remove(path)
                files.insert(path)
            }
            return true
        case .directory:
            files.remove(path)
            policyIgnoredTrackedPaths.remove(path)
            if fact.isIncludedInOrdinaryCrawl {
                folders.insert(path)
            }
            return true
        case .symbolicLink, .special:
            return false
        }
    }

    @discardableResult
    private static func applyUntrackedFact(
        _ fact: WorkspaceRootSeedVerificationFact,
        files: inout Set<PathKey>,
        folders: inout Set<PathKey>
    ) -> Bool {
        if fact.isIgnored, fact.kind != .directory { return true }
        let path = PathKey(fact.relativePath)
        switch fact.kind {
        case .regularFile:
            files.insert(path)
            return true
        case .directory:
            if fact.isIncludedInOrdinaryCrawl {
                folders.insert(path)
            }
            return true
        case .missing:
            return true
        case .symbolicLink, .special:
            return false
        }
    }
}
