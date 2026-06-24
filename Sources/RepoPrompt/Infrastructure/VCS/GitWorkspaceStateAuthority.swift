import Foundation

/// Owns currentness and metadata observation for worktree bootstrap. Collection
/// is always bracketed by a scope-bound capture token and conditional install;
/// reusable snapshot storage/eviction is bounded and remains observation-only.
actor GitWorkspaceStateAuthority {
    static let shared = GitWorkspaceStateAuthority()

    #if DEBUG
        struct Snapshot: Equatable {
            let recordCount: Int
            let publishedScopeCount: Int
            let activeMutationCount: Int
            let metadataEventCount: Int
            let authorityGenerations: [GitWorkspaceAuthorityRepositoryKey: UInt64]
            let reusableSnapshotCount: Int
            let reusableSnapshotAliasCount: Int
            let reusableSnapshotEstimatedBytes: Int
        }
    #endif

    private struct Record {
        var invalidationGeneration: UInt64 = 0
        var mutationDepth: Int = 0
        var metadataEventCount: Int = 0
        var monitorCoverageUnavailable = false
        var snapshotsByScope: [GitWorkspaceAuthorityScopeKey: GitWorkspaceAuthoritySnapshot] = [:]
        var publicationGenerationByScope: [GitWorkspaceAuthorityScopeKey: UInt64] = [:]
        var acceptedWatermarkByScope: [GitWorkspaceAuthorityScopeKey: UInt64] = [:]
    }

    private struct ReusableSnapshotCacheEntry {
        let snapshot: WorkspaceRootReusableSnapshot
        var lastAccessOrdinal: UInt64
    }

    private struct ReusableSnapshotAlias {
        let lease: GitWorkspaceAuthorityLease
        let snapshotIdentity: WorkspaceRootReusableSnapshotIdentity
        let observationToken: GitWorkspaceMetadataMonitor.RetainToken
    }

    private let metadataMonitor: GitWorkspaceMetadataMonitor
    private let reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits
    private var records: [GitWorkspaceAuthorityRepositoryKey: Record] = [:]
    private var activeMutations: [UUID: GitWorkspaceMutationToken] = [:]
    private var reusableSnapshotsByIdentity: [WorkspaceRootReusableSnapshotIdentity: ReusableSnapshotCacheEntry] = [:]
    private var reusableSnapshotAliasesByScope: [GitWorkspaceAuthorityScopeKey: ReusableSnapshotAlias] = [:]
    private var reusableSnapshotAccessOrdinal: UInt64 = 0
    private var reusableSnapshotEstimatedBytes = 0

    init(
        metadataMonitor: GitWorkspaceMetadataMonitor = GitWorkspaceMetadataMonitor(),
        reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits = .production
    ) {
        precondition(reusableSnapshotCacheLimits.maximumSnapshotCount > 0)
        precondition(reusableSnapshotCacheLimits.maximumSnapshotsPerRepository > 0)
        precondition(reusableSnapshotCacheLimits.maximumEstimatedBytes > 0)
        self.metadataMonitor = metadataMonitor
        self.reusableSnapshotCacheLimits = reusableSnapshotCacheLimits
    }

    func collectionMutationFenceReason(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey
    ) -> GitWorkspaceAuthorityUnavailableReason? {
        let record = records[repositoryKey]
        return hasActiveMutation(for: repositoryKey) || (record?.mutationDepth ?? 0) > 0
            ? .mutationInProgress
            : nil
    }

    func beginCollection(
        scopeKey: GitWorkspaceAuthorityScopeKey
    ) -> Result<GitWorkspaceAuthorityCaptureToken, GitWorkspaceAuthorityUnavailableReason> {
        let record = records[scopeKey.repositoryKey] ?? Record()
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        records[scopeKey.repositoryKey] = record
        return .success(GitWorkspaceAuthorityCaptureToken(
            scopeKey: scopeKey,
            invalidationGeneration: record.invalidationGeneration,
            scopePublicationGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            acceptedMetadataWatermark: metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey)
        ))
    }

    func collectAndInstall(
        scopeKey: GitWorkspaceAuthorityScopeKey,
        collector: @Sendable () async throws -> GitWorkspaceAuthoritySnapshot
    ) async throws -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let token: GitWorkspaceAuthorityCaptureToken
        switch beginCollection(scopeKey: scopeKey) {
        case let .success(value): token = value
        case let .failure(reason): return .failure(reason)
        }
        let snapshot = try await collector()
        return install(snapshot, capturedUsing: token)
    }

    @discardableResult
    func install(
        _ snapshot: GitWorkspaceAuthoritySnapshot,
        capturedUsing token: GitWorkspaceAuthorityCaptureToken
    ) -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: snapshot.repositoryKey,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix
        )
        guard scopeKey == token.scopeKey else { return .failure(.collectionScopeMismatch) }
        guard var record = records[scopeKey.repositoryKey] else {
            return .failure(.invalidatedDuringCollection)
        }
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        guard record.invalidationGeneration == token.invalidationGeneration,
              (record.publicationGenerationByScope[scopeKey] ?? 0) == token.scopePublicationGeneration,
              metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey) == token.acceptedMetadataWatermark
        else {
            return .failure(.invalidatedDuringCollection)
        }

        let lease = metadataMonitor.withCurrentAcceptedWatermark(
            for: scopeKey.repositoryKey,
            expected: token.acceptedMetadataWatermark
        ) {
            let publicationGeneration = token.scopePublicationGeneration &+ 1
            record.publicationGenerationByScope[scopeKey] = publicationGeneration
            record.snapshotsByScope[scopeKey] = snapshot
            record.acceptedWatermarkByScope[scopeKey] = token.acceptedMetadataWatermark
            records[scopeKey.repositoryKey] = record
            return GitWorkspaceAuthorityLease(
                scopeKey: scopeKey,
                authorityGeneration: publicationGeneration,
                invalidationGeneration: record.invalidationGeneration,
                acceptedMetadataWatermark: token.acceptedMetadataWatermark,
                snapshot: snapshot
            )
        }
        guard let lease else { return .failure(.invalidatedDuringCollection) }
        return .success(lease)
    }

    /// Test/support convenience for an already collected immutable value. There
    /// is no suspension between token issue and conditional installation.
    @discardableResult
    func install(_ snapshot: GitWorkspaceAuthoritySnapshot) throws -> GitWorkspaceAuthorityLease {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: snapshot.repositoryKey,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix
        )
        let token: GitWorkspaceAuthorityCaptureToken
        switch beginCollection(scopeKey: scopeKey) {
        case let .success(value): token = value
        case let .failure(reason): throw reason
        }
        switch install(snapshot, capturedUsing: token) {
        case let .success(lease): return lease
        case let .failure(reason): throw reason
        }
    }

    func currentLease(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: repositoryKey,
            repositoryRelativeRootPrefix: prefix
        )
        guard let record = records[repositoryKey] else { return .failure(.noSnapshot) }
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        guard let snapshot = record.snapshotsByScope[scopeKey] else { return .failure(.metadataEventPending) }
        let watermark = metadataMonitor.acceptedWatermark(for: repositoryKey)
        guard record.acceptedWatermarkByScope[scopeKey] == watermark else {
            return .failure(.invalidatedDuringCollection)
        }
        return .success(GitWorkspaceAuthorityLease(
            scopeKey: scopeKey,
            authorityGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            invalidationGeneration: record.invalidationGeneration,
            acceptedMetadataWatermark: watermark,
            snapshot: snapshot
        ))
    }

    func isCurrent(_ lease: GitWorkspaceAuthorityLease) -> Bool {
        guard let record = records[lease.repositoryKey] else { return false }
        return !hasActiveMutation(for: lease.repositoryKey)
            && record.mutationDepth == 0
            && !record.monitorCoverageUnavailable
            && record.invalidationGeneration == lease.invalidationGeneration
            && record.publicationGenerationByScope[lease.scopeKey] == lease.authorityGeneration
            && record.snapshotsByScope[lease.scopeKey] == lease.snapshot
            && record.acceptedWatermarkByScope[lease.scopeKey] == lease.acceptedMetadataWatermark
            && metadataMonitor.acceptedWatermark(for: lease.repositoryKey) == lease.acceptedMetadataWatermark
    }

    @discardableResult
    func admitReusableSnapshot(
        _ snapshot: WorkspaceRootReusableSnapshot,
        capturedUsing lease: GitWorkspaceAuthorityLease,
        observationToken: GitWorkspaceMetadataMonitor.RetainToken
    ) async -> Bool {
        guard isCurrent(lease),
              snapshot.hasValidContentAddress(),
              snapshot.compatibilityKey == WorkspaceRootSeedCompatibilityKey(authority: lease.snapshot),
              snapshot.estimatedByteCount <= reusableSnapshotCacheLimits.maximumEstimatedBytes
        else {
            await metadataMonitor.release(observationToken)
            return false
        }

        reusableSnapshotAccessOrdinal &+= 1
        if var existing = reusableSnapshotsByIdentity[snapshot.identity] {
            guard existing.snapshot.compatibilityKey == snapshot.compatibilityKey,
                  existing.snapshot.inventory == snapshot.inventory,
                  existing.snapshot.hasValidContentAddress()
            else {
                await metadataMonitor.release(observationToken)
                return false
            }
            existing.lastAccessOrdinal = reusableSnapshotAccessOrdinal
            reusableSnapshotsByIdentity[snapshot.identity] = existing
        } else {
            reusableSnapshotsByIdentity[snapshot.identity] = ReusableSnapshotCacheEntry(
                snapshot: snapshot,
                lastAccessOrdinal: reusableSnapshotAccessOrdinal
            )
            reusableSnapshotEstimatedBytes += snapshot.estimatedByteCount
        }

        let previous = reusableSnapshotAliasesByScope.updateValue(
            ReusableSnapshotAlias(
                lease: lease,
                snapshotIdentity: snapshot.identity,
                observationToken: observationToken
            ),
            forKey: lease.scopeKey
        )
        let retained = await evictReusableSnapshotsIfNeeded()
        guard retained,
              reusableSnapshotsByIdentity[snapshot.identity] != nil
        else {
            if let previous {
                reusableSnapshotAliasesByScope[lease.scopeKey] = previous
            } else {
                reusableSnapshotAliasesByScope.removeValue(forKey: lease.scopeKey)
            }
            if reusableSnapshotAliasesByScope.values.contains(where: { $0.snapshotIdentity == snapshot.identity }) == false {
                removeUnaliasedReusableSnapshot(snapshot.identity)
            }
            await metadataMonitor.release(observationToken)
            return false
        }
        if let previous {
            await metadataMonitor.release(previous.observationToken)
        }
        return true
    }

    func currentReusableSnapshot(
        capturedUsing lease: GitWorkspaceAuthorityLease
    ) async -> WorkspaceRootReusableSnapshot? {
        guard isCurrent(lease),
              let alias = reusableSnapshotAliasesByScope[lease.scopeKey],
              alias.lease == lease,
              var entry = reusableSnapshotsByIdentity[alias.snapshotIdentity],
              entry.snapshot.hasValidContentAddress(),
              entry.snapshot.compatibilityKey == WorkspaceRootSeedCompatibilityKey(authority: lease.snapshot)
        else {
            if let alias = reusableSnapshotAliasesByScope[lease.scopeKey],
               alias.lease == lease
            {
                reusableSnapshotAliasesByScope.removeValue(forKey: lease.scopeKey)
                await metadataMonitor.release(alias.observationToken)
            }
            return nil
        }
        reusableSnapshotAccessOrdinal &+= 1
        entry.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        reusableSnapshotsByIdentity[alias.snapshotIdentity] = entry
        return entry.snapshot
    }

    func reusableSnapshot(
        compatibleWith snapshot: GitWorkspaceAuthoritySnapshot
    ) -> WorkspaceRootReusableSnapshot? {
        let key = WorkspaceRootSeedCompatibilityKey(authority: snapshot)
        guard let identity = reusableSnapshotsByIdentity.first(where: {
            $0.value.snapshot.compatibilityKey == key && $0.value.snapshot.hasValidContentAddress()
        })?.key else { return nil }
        reusableSnapshotAccessOrdinal &+= 1
        reusableSnapshotsByIdentity[identity]?.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        return reusableSnapshotsByIdentity[identity]?.snapshot
    }

    func reusableSnapshot(
        identity: WorkspaceRootReusableSnapshotIdentity,
        expectedCompatibilityKey: WorkspaceRootSeedCompatibilityKey
    ) -> WorkspaceRootReusableSnapshot? {
        guard identity.searchABI == .current,
              var entry = reusableSnapshotsByIdentity[identity],
              entry.snapshot.compatibilityKey == expectedCompatibilityKey,
              entry.snapshot.hasValidContentAddress()
        else { return nil }
        reusableSnapshotAccessOrdinal &+= 1
        entry.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        reusableSnapshotsByIdentity[identity] = entry
        return entry.snapshot
    }

    private func evictReusableSnapshotsIfNeeded() async -> Bool {
        while reusableSnapshotsByIdentity.count > reusableSnapshotCacheLimits.maximumSnapshotCount
            || reusableSnapshotEstimatedBytes > reusableSnapshotCacheLimits.maximumEstimatedBytes
            || repositorySnapshotCountExceedsLimit()
        {
            let pinnedIdentities = Set(reusableSnapshotAliasesByScope.values.map(\.snapshotIdentity))
            let overfullNamespaces = repositorySnapshotCounts()
                .filter { $0.value > reusableSnapshotCacheLimits.maximumSnapshotsPerRepository }
                .map(\.key)
            let candidates = reusableSnapshotsByIdentity.filter { identity, entry in
                !pinnedIdentities.contains(identity)
                    && (
                        overfullNamespaces.isEmpty
                            || overfullNamespaces.contains(entry.snapshot.compatibilityKey.repositoryNamespace)
                    )
            }
            guard let candidate = candidates.min(by: {
                $0.value.lastAccessOrdinal < $1.value.lastAccessOrdinal
            }) else { return false }
            removeUnaliasedReusableSnapshot(candidate.key)
        }
        return true
    }

    private func repositorySnapshotCountExceedsLimit() -> Bool {
        repositorySnapshotCounts().values.contains {
            $0 > reusableSnapshotCacheLimits.maximumSnapshotsPerRepository
        }
    }

    private func repositorySnapshotCounts() -> [GitBlobRepositoryNamespace: Int] {
        Dictionary(grouping: reusableSnapshotsByIdentity.values) {
            $0.snapshot.compatibilityKey.repositoryNamespace
        }.mapValues(\.count)
    }

    private func removeReusableSnapshot(_ identity: WorkspaceRootReusableSnapshotIdentity) async {
        guard let removed = reusableSnapshotsByIdentity.removeValue(forKey: identity) else { return }
        reusableSnapshotEstimatedBytes = max(0, reusableSnapshotEstimatedBytes - removed.snapshot.estimatedByteCount)
        let aliases = reusableSnapshotAliasesByScope.filter { $0.value.snapshotIdentity == identity }
        for (scopeKey, alias) in aliases {
            reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
            await metadataMonitor.release(alias.observationToken)
        }
    }

    private func removeUnaliasedReusableSnapshot(
        _ identity: WorkspaceRootReusableSnapshotIdentity
    ) {
        guard !reusableSnapshotAliasesByScope.values.contains(where: { $0.snapshotIdentity == identity }),
              let removed = reusableSnapshotsByIdentity.removeValue(forKey: identity)
        else { return }
        reusableSnapshotEstimatedBytes = max(
            0,
            reusableSnapshotEstimatedBytes - removed.snapshot.estimatedByteCount
        )
    }

    func beginMutation(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kind: GitWorkspaceMutationKind,
        correlationID: UUID? = nil
    ) async -> GitWorkspaceMutationToken {
        let affectedKeys = Set(records.keys.filter { Self.sameCommonDirectory($0, repositoryKey) })
            .union([repositoryKey])
        let token = GitWorkspaceMutationToken(
            id: UUID(),
            repositoryKey: repositoryKey,
            affectedRepositoryKeys: affectedKeys,
            kind: kind,
            correlationID: correlationID
        )
        for key in affectedKeys {
            var record = records[key] ?? Record()
            record.mutationDepth += 1
            record.invalidationGeneration &+= 1
            record.snapshotsByScope.removeAll(keepingCapacity: true)
            records[key] = record
        }
        await removeReusableSnapshotAliases(for: affectedKeys)
        activeMutations[token.id] = token
        return token
    }

    /// Completion balances mutation state exactly once. Invalidation occurs at
    /// begin, so a collection spanning even a failed/cancelled mutation cannot
    /// reinstall stale evidence.
    func finishMutation(
        _ token: GitWorkspaceMutationToken,
        outcome _: GitWorkspaceMutationOutcome
    ) {
        guard activeMutations.removeValue(forKey: token.id) != nil else { return }
        for key in token.affectedRepositoryKeys {
            var record = records[key] ?? Record()
            record.mutationDepth = max(0, record.mutationDepth - 1)
            records[key] = record
        }
    }

    func metadataDidChange(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kinds: Set<GitWorkspaceMetadataEventKind>
    ) async {
        var record = records[repositoryKey] ?? Record()
        record.metadataEventCount &+= 1
        record.invalidationGeneration &+= 1
        record.snapshotsByScope.removeAll(keepingCapacity: true)
        if kinds.contains(.monitorGap) {
            record.monitorCoverageUnavailable = true
        }
        records[repositoryKey] = record
        await removeReusableSnapshotAliases(for: [repositoryKey])
    }

    private func removeReusableSnapshotAliases(
        for repositoryKeys: Set<GitWorkspaceAuthorityRepositoryKey>
    ) async {
        let aliases = reusableSnapshotAliasesByScope.filter {
            repositoryKeys.contains($0.key.repositoryKey)
        }
        for (scopeKey, alias) in aliases {
            reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
            await metadataMonitor.release(alias.observationToken)
        }
    }

    func retainMetadataObservation(
        for layout: GitRepositoryLayout,
        additionalAuthorityPaths: [URL] = []
    ) async throws -> GitWorkspaceMetadataMonitor.RetainToken {
        let key = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        let paths = Self.metadataPaths(for: layout) + additionalAuthorityPaths
        let token = try await metadataMonitor.retain(repositoryKey: key, paths: paths) { [weak self] kinds in
            Task { await self?.metadataDidChange(repositoryKey: key, kinds: kinds) }
        }
        var record = records[key] ?? Record()
        if record.monitorCoverageUnavailable {
            record.monitorCoverageUnavailable = false
            record.invalidationGeneration &+= 1
            record.snapshotsByScope.removeAll(keepingCapacity: true)
        }
        records[key] = record
        return token
    }

    func metadataObservationIsCurrent(
        _ token: GitWorkspaceMetadataMonitor.RetainToken,
        for layout: GitRepositoryLayout,
        additionalAuthorityPaths: [URL] = [],
        expectedAcceptedWatermark: UInt64
    ) async -> Bool {
        await metadataMonitor.coverageIsCurrent(
            token,
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            paths: Self.metadataPaths(for: layout) + additionalAuthorityPaths,
            expectedAcceptedWatermark: expectedAcceptedWatermark
        )
    }

    func retireEphemeralAuthorityLease(
        _ lease: GitWorkspaceAuthorityLease,
        observationToken: GitWorkspaceMetadataMonitor.RetainToken
    ) async {
        await metadataMonitor.release(observationToken)
        guard var record = records[lease.repositoryKey],
              record.publicationGenerationByScope[lease.scopeKey] == lease.authorityGeneration,
              record.snapshotsByScope[lease.scopeKey] == lease.snapshot
        else { return }
        record.monitorCoverageUnavailable = true
        record.invalidationGeneration &+= 1
        record.snapshotsByScope.removeAll(keepingCapacity: true)
        records[lease.repositoryKey] = record
        await removeReusableSnapshotAliases(for: [lease.repositoryKey])
    }

    func releaseMetadataObservation(_ token: GitWorkspaceMetadataMonitor.RetainToken) async {
        await metadataMonitor.release(token)
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            Snapshot(
                recordCount: records.count,
                publishedScopeCount: records.values.reduce(0) { $0 + $1.snapshotsByScope.count },
                activeMutationCount: activeMutations.count,
                metadataEventCount: records.values.reduce(0) { $0 + $1.metadataEventCount },
                authorityGenerations: records.mapValues(\.invalidationGeneration),
                reusableSnapshotCount: reusableSnapshotsByIdentity.count,
                reusableSnapshotAliasCount: reusableSnapshotAliasesByScope.count,
                reusableSnapshotEstimatedBytes: reusableSnapshotEstimatedBytes
            )
        }

        func metadataMonitorForTesting() -> GitWorkspaceMetadataMonitor {
            metadataMonitor
        }
    #endif

    private func hasActiveMutation(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey
    ) -> Bool {
        activeMutations.values.contains { token in
            token.affectedRepositoryKeys.contains(where: {
                Self.sameCommonDirectory($0, repositoryKey)
            })
        }
    }

    private nonisolated static func sameCommonDirectory(
        _ lhs: GitWorkspaceAuthorityRepositoryKey,
        _ rhs: GitWorkspaceAuthorityRepositoryKey
    ) -> Bool {
        lhs.standardizedCommonDirectoryPath == rhs.standardizedCommonDirectoryPath
            && lhs.commonDirectoryDevice == rhs.commonDirectoryDevice
            && lhs.commonDirectoryInode == rhs.commonDirectoryInode
    }

    private nonisolated static func metadataPaths(for layout: GitRepositoryLayout) -> [URL] {
        [
            layout.dotGitPath,
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.gitDir.appendingPathComponent("index"),
            layout.gitDir.appendingPathComponent("config.worktree"),
            layout.gitDir.appendingPathComponent("info/sparse-checkout"),
            layout.commonDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("packed-refs"),
            layout.commonDir.appendingPathComponent("refs", isDirectory: true),
            layout.commonDir.appendingPathComponent("config"),
            layout.commonDir.appendingPathComponent("info/exclude"),
            layout.commonDir.appendingPathComponent("info/attributes")
        ]
    }
}
