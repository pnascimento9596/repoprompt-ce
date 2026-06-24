import CryptoKit
import Foundation

struct WorkspaceRootSeedCompatibilityKey: Hashable {
    static let currentInventorySchemaVersion = 1

    let repositoryNamespace: GitBlobRepositoryNamespace
    let objectFormat: GitObjectFormat
    let treeOID: GitObjectID
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let inventorySchemaVersion: Int
    let policyIdentity: GitWorkspacePolicyIdentity

    init(
        authority: GitWorkspaceAuthoritySnapshot,
        inventorySchemaVersion: Int = Self.currentInventorySchemaVersion
    ) {
        repositoryNamespace = authority.repositoryNamespace
        objectFormat = authority.objectFormat
        treeOID = authority.treeOID
        repositoryRelativeRootPrefix = authority.repositoryRelativeRootPrefix
        self.inventorySchemaVersion = inventorySchemaVersion
        policyIdentity = authority.policyIdentity
    }

    var searchABI: GitWorkspaceSearchABIIdentity {
        policyIdentity.searchABI
    }
}

struct WorkspaceRootReusableSnapshotIdentity: Hashable {
    let sha256: String
    let searchABI: GitWorkspaceSearchABIIdentity
}

struct RootNeutralTreeInventoryEntry: Hashable {
    enum Provenance: String, Hashable {
        case committedTree
    }

    let ordinal: Int
    let parentOrdinal: Int?
    let relativePath: String
    let mode: String
    let kind: GitTreeEntryKind
    let objectID: GitObjectID
    let provenance: Provenance

    var isSearchableFile: Bool {
        kind == .blob && mode != "120000"
    }
}

struct RootNeutralTreeInventory: Hashable {
    let entries: [RootNeutralTreeInventoryEntry]
}

final class WorkspaceSearchRelativePathBase: @unchecked Sendable {
    let relativePaths: [String]
    let filenames: [String]
    let stableOrdinals: [Int]
    let index: PathSearchIndex

    init(relativePaths: [String], stableOrdinals: [Int]) {
        precondition(relativePaths.count == stableOrdinals.count)
        self.relativePaths = relativePaths
        filenames = relativePaths.map { ($0 as NSString).lastPathComponent }
        self.stableOrdinals = stableOrdinals
        index = PathSearchIndex(paths: relativePaths)
    }
}

final class WorkspaceRootReusableSnapshot: @unchecked Sendable {
    let identity: WorkspaceRootReusableSnapshotIdentity
    let compatibilityKey: WorkspaceRootSeedCompatibilityKey
    let inventory: RootNeutralTreeInventory
    let searchBase: WorkspaceSearchRelativePathBase
    let estimatedByteCount: Int

    init(
        compatibilityKey: WorkspaceRootSeedCompatibilityKey,
        inventory: RootNeutralTreeInventory
    ) {
        self.compatibilityKey = compatibilityKey
        self.inventory = inventory
        let searchable = inventory.entries.filter(\.isSearchableFile)
        searchBase = WorkspaceSearchRelativePathBase(
            relativePaths: searchable.map(\.relativePath),
            stableOrdinals: searchable.map(\.ordinal)
        )
        identity = WorkspaceRootReusableSnapshotIdentity(
            sha256: Self.contentDigest(compatibilityKey: compatibilityKey, inventory: inventory),
            searchABI: compatibilityKey.searchABI
        )
        estimatedByteCount = inventory.entries.reduce(0) { partial, entry in
            partial + entry.relativePath.utf8.count + entry.mode.utf8.count + entry.objectID.lowercaseHex.utf8.count + 96
        } + searchBase.relativePaths.reduce(0) { $0 + $1.utf8.count + 48 }
    }

    func hasValidContentAddress() -> Bool {
        identity.searchABI == compatibilityKey.searchABI
            && identity.sha256 == Self.contentDigest(compatibilityKey: compatibilityKey, inventory: inventory)
    }

    static func make(
        authority: GitWorkspaceAuthoritySnapshot,
        tree: GitTreeInventorySnapshot,
        authoritativeRelativeFilePaths: Set<String>
    ) -> WorkspaceRootReusableSnapshot? {
        guard authority.treeOID == tree.treeOID,
              authority.repositoryRelativeRootPrefix == tree.rootPrefix,
              authority.policyIdentity.searchABI == .current
        else { return nil }

        let prefix = tree.rootPrefix.value
        var relativeEntries: [(source: GitTreeInventoryEntry, relativePath: String)] = []
        relativeEntries.reserveCapacity(tree.entries.count)
        for entry in tree.entries {
            let relativePath: String
            if prefix.isEmpty {
                relativePath = entry.repositoryRelativePath
            } else {
                let requiredPrefix = prefix + "/"
                guard entry.repositoryRelativePath.hasPrefix(requiredPrefix) else { continue }
                relativePath = String(entry.repositoryRelativePath.dropFirst(requiredPrefix.count))
            }
            guard !relativePath.isEmpty else { continue }
            relativeEntries.append((entry, relativePath))
        }
        relativeEntries.sort { $0.relativePath < $1.relativePath }

        var ordinalByPath: [String: Int] = [:]
        var entries: [RootNeutralTreeInventoryEntry] = []
        entries.reserveCapacity(relativeEntries.count)
        for (ordinal, value) in relativeEntries.enumerated() {
            let parentPath = (value.relativePath as NSString).deletingLastPathComponent
            let parentOrdinal = parentPath.isEmpty || parentPath == "." ? nil : ordinalByPath[parentPath]
            let projected = RootNeutralTreeInventoryEntry(
                ordinal: ordinal,
                parentOrdinal: parentOrdinal,
                relativePath: value.relativePath,
                mode: value.source.mode,
                kind: value.source.kind,
                objectID: value.source.objectID,
                provenance: .committedTree
            )
            if projected.isSearchableFile,
               !authoritativeRelativeFilePaths.contains(StandardizedPath.relative(projected.relativePath))
            {
                return nil
            }
            entries.append(projected)
            ordinalByPath[value.relativePath] = ordinal
        }
        return WorkspaceRootReusableSnapshot(
            compatibilityKey: WorkspaceRootSeedCompatibilityKey(authority: authority),
            inventory: RootNeutralTreeInventory(entries: entries)
        )
    }

    private static func contentDigest(
        compatibilityKey: WorkspaceRootSeedCompatibilityKey,
        inventory: RootNeutralTreeInventory
    ) -> String {
        var writer = CanonicalWriter()
        writer.append("workspace-root-reusable-snapshot-v1")
        writer.append(compatibilityKey.repositoryNamespace.rawValue)
        writer.append(compatibilityKey.objectFormat.rawValue)
        writer.append(compatibilityKey.treeOID.lowercaseHex)
        writer.append(compatibilityKey.repositoryRelativeRootPrefix.value)
        writer.append(compatibilityKey.inventorySchemaVersion)
        writer.append(compatibilityKey.policyIdentity.mandatoryIgnorePolicyIdentity)
        writer.append(compatibilityKey.policyIdentity.committedIgnoreControlDigest)
        writer.append(compatibilityKey.policyIdentity.configuredIgnoreAuthorityDigest)
        writer.append(compatibilityKey.policyIdentity.attributePolicyDigest)
        writer.append(compatibilityKey.policyIdentity.sparsePolicyDigest)
        writer.append(compatibilityKey.searchABI.matcherSchemaVersion)
        writer.append(compatibilityKey.searchABI.projectedKeySchemaVersion)
        writer.append(compatibilityKey.searchABI.comparatorSchemaVersion)
        writer.append(compatibilityKey.searchABI.pathNormalizationSchemaVersion)
        writer.append(contentIdentity: compatibilityKey.policyIdentity.resolvedExcludesFileIdentity)
        writer.append(contentIdentity: compatibilityKey.policyIdentity.resolvedAttributesFileIdentity)
        for control in compatibilityKey.policyIdentity.prefixControlIdentities.sorted(by: {
            if $0.repositoryRelativePath != $1.repositoryRelativePath {
                return $0.repositoryRelativePath < $1.repositoryRelativePath
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }) {
            writer.append(control.repositoryRelativePath)
            writer.append(control.kind.rawValue)
            writer.append(contentIdentity: control.content)
        }
        for entry in inventory.entries {
            writer.append(entry.ordinal)
            writer.append(entry.parentOrdinal ?? -1)
            writer.append(entry.relativePath)
            writer.append(entry.mode)
            writer.append(entry.kind.rawValue)
            writer.append(entry.objectID.objectFormat.rawValue)
            writer.append(entry.objectID.lowercaseHex)
            writer.append(entry.provenance.rawValue)
        }
        return Data(SHA256.hash(data: writer.data)).map { String(format: "%02x", $0) }.joined()
    }
}

struct WorkspaceRootReusableSnapshotCacheLimits: Equatable {
    let maximumSnapshotCount: Int
    let maximumSnapshotsPerRepository: Int
    let maximumEstimatedBytes: Int

    static let production = WorkspaceRootReusableSnapshotCacheLimits(
        maximumSnapshotCount: 32,
        maximumSnapshotsPerRepository: 8,
        maximumEstimatedBytes: 512 * 1024 * 1024
    )
}

struct WorkspaceRootMaterializationHint: Equatable, @unchecked Sendable {
    let bindingID: String
    let standardizedTargetPath: String
    let creationReceipt: GitWorktreeCreationReceipt
    let orderedCompatibleBaseCandidates: [WorkspaceRootReusableSnapshotIdentity]
    let agentSessionID: UUID
    let correlationID: UUID
    let standardizedLogicalRootPath: String
    let expectedOwnerBindingGeneration: UInt64
    let validationFallbackReason: WorkspaceRootSeedFallbackReason?

    init(
        bindingID: String,
        standardizedTargetPath: String,
        creationReceipt: GitWorktreeCreationReceipt,
        orderedCompatibleBaseCandidates: [WorkspaceRootReusableSnapshotIdentity]? = nil,
        correlationID: UUID,
        validationFallbackReason: WorkspaceRootSeedFallbackReason? = nil
    ) {
        self.bindingID = bindingID
        self.standardizedTargetPath = StandardizedPath.absolute(standardizedTargetPath)
        self.creationReceipt = creationReceipt
        self.orderedCompatibleBaseCandidates = orderedCompatibleBaseCandidates
            ?? [creationReceipt.parentSnapshotIdentity]
        agentSessionID = creationReceipt.agentSessionID
        self.correlationID = correlationID
        standardizedLogicalRootPath = creationReceipt.standardizedLogicalRootPath
        expectedOwnerBindingGeneration = creationReceipt.expectedOwnerBindingGeneration
        self.validationFallbackReason = validationFallbackReason
    }

    func validated(
        matching binding: AgentSessionWorktreeBinding,
        sessionID: UUID,
        startupContext: WorktreeStartupContext?
    ) -> Self {
        Self(
            bindingID: bindingID,
            standardizedTargetPath: standardizedTargetPath,
            creationReceipt: creationReceipt,
            orderedCompatibleBaseCandidates: orderedCompatibleBaseCandidates,
            correlationID: correlationID,
            validationFallbackReason: fallbackReason(
                matching: binding,
                sessionID: sessionID,
                startupContext: startupContext
            )
        )
    }

    func fallbackReason(
        matching binding: AgentSessionWorktreeBinding,
        sessionID: UUID,
        startupContext: WorktreeStartupContext?
    ) -> WorkspaceRootSeedFallbackReason? {
        guard let startupContext,
              startupContext.agentSessionID == sessionID,
              agentSessionID == sessionID,
              creationReceipt.agentSessionID == sessionID,
              startupContext.correlationID == correlationID,
              binding.id == bindingID,
              correlationID == creationReceipt.correlationID,
              standardizedLogicalRootPath == creationReceipt.standardizedLogicalRootPath,
              StandardizedPath.absolute(binding.logicalRootPath) == standardizedLogicalRootPath,
              StandardizedPath.absolute(binding.worktreeRootPath) == standardizedTargetPath,
              creationReceipt.actualTargetPath == standardizedTargetPath,
              binding.repositoryID == creationReceipt.worktree.repository.repositoryID,
              binding.repoKey == creationReceipt.worktree.repository.repoKey,
              binding.worktreeID == creationReceipt.worktree.worktreeID
        else { return .compatibilityMismatch }
        return creationReceipt.fallbackReason()
    }
}

enum WorkspaceRootMaterializationHintObservation: Equatable {
    case observationDisabled
    case eligible(WorkspaceRootReusableSnapshotIdentity)
    case fallback(WorkspaceRootSeedFallbackReason)
}

private struct CanonicalWriter {
    private(set) var data = Data()

    mutating func append(_ value: Int) {
        append(String(value))
    }

    mutating func append(_ value: String) {
        var count = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(contentsOf: value.utf8)
    }

    mutating func append(contentIdentity value: GitWorkspaceAuthorityContentIdentity?) {
        guard let value else {
            append("nil")
            return
        }
        append(value.exists ? "1" : "0")
        append(value.sha256)
        append(value.byteCount)
    }
}
