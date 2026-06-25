import CryptoKit
import Foundation

struct WorkspaceRootByteExactPathKey: Hashable, Comparable {
    let value: String
    private let bytes: [UInt8]

    init(_ value: String) {
        self.value = value
        bytes = Array(value.utf8)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes == rhs.bytes
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bytes.count)
        for byte in bytes {
            hasher.combine(byte)
        }
    }

    static func rootRelativePath(
        repositoryRelativePath: String,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> String? {
        let pathBytes = Array(repositoryRelativePath.utf8)
        let prefixBytes = Array(prefix.value.utf8)
        guard !prefixBytes.isEmpty else { return repositoryRelativePath }
        let requiredPrefix = prefixBytes + [UInt8(ascii: "/")]
        guard pathBytes.starts(with: requiredPrefix), pathBytes.count > requiredPrefix.count else {
            return nil
        }
        return String(decoding: pathBytes.dropFirst(requiredPrefix.count), as: UTF8.self)
    }

    var parent: Self? {
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")), slash > bytes.startIndex else {
            return nil
        }
        return Self(String(decoding: bytes[..<slash], as: UTF8.self))
    }

    func isSameOrDescendant(of ancestor: Self) -> Bool {
        if ancestor.bytes.isEmpty { return true }
        if bytes == ancestor.bytes { return true }
        return bytes.starts(with: ancestor.bytes + [UInt8(ascii: "/")])
    }
}

struct WorkspaceRootByteExactPathSet: Equatable {
    private let valuesByKey: [WorkspaceRootByteExactPathKey: String]

    init?(
        _ paths: some Sequence<String>,
        rejectExactDuplicates: Bool = false
    ) {
        var valuesByKey: [WorkspaceRootByteExactPathKey: String] = [:]
        var canonicalRepresentatives: [String: WorkspaceRootByteExactPathKey] = [:]
        for path in paths {
            let key = WorkspaceRootByteExactPathKey(path)
            if valuesByKey[key] != nil {
                if rejectExactDuplicates { return nil }
                continue
            }
            if let existing = canonicalRepresentatives[path], existing != key {
                return nil
            }
            valuesByKey[key] = path
            canonicalRepresentatives[path] = key
        }
        self.valuesByKey = valuesByKey
    }

    private init(valuesByKey: [WorkspaceRootByteExactPathKey: String]) {
        self.valuesByKey = valuesByKey
    }

    var count: Int {
        valuesByKey.count
    }

    var isEmpty: Bool {
        valuesByKey.isEmpty
    }

    var keys: Set<WorkspaceRootByteExactPathKey> {
        Set(valuesByKey.keys)
    }

    var sortedKeys: [WorkspaceRootByteExactPathKey] {
        valuesByKey.keys.sorted()
    }

    var stringValues: [String] {
        sortedKeys.map(\.value)
    }

    func contains(_ key: WorkspaceRootByteExactPathKey) -> Bool {
        valuesByKey[key] != nil
    }

    func subtracting(_ other: Self) -> Self {
        Self(valuesByKey: valuesByKey.filter { !other.contains($0.key) })
    }
}

struct WorkspaceRootCatalogPolicyIdentity: Hashable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let mandatoryIgnorePolicyIdentity: String
    let globalIgnoreDefaultsDigest: String
    let respectRepoIgnore: Bool
    let respectCursorignore: Bool
    let enableHierarchicalIgnores: Bool
    let skipSymlinks: Bool

    static let canonicalDefaults = WorkspaceRootCatalogPolicyIdentity(
        schemaVersion: currentSchemaVersion,
        mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
        globalIgnoreDefaultsDigest: IgnoreRulesManager.globalIgnoreDefaultsDigest(
            for: IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
        ),
        respectRepoIgnore: true,
        respectCursorignore: true,
        enableHierarchicalIgnores: true,
        skipSymlinks: true
    )
}

enum WorkspaceRootCommittedRegularProjectionDisposition: Equatable {
    case searchableRegularFile
    case policyIgnoredRegularFile
    case ineligible(CatalogRegularFileIneligibilityReason)
}

struct WorkspaceRootCatalogProjectionEvidence: Equatable {
    let policyIdentity: WorkspaceRootCatalogPolicyIdentity
    let dispositionsByRelativePath: [WorkspaceRootByteExactPathKey: WorkspaceRootCommittedRegularProjectionDisposition]
    let ignoreRulesRevision: UInt64
}

struct WorkspaceRootValidatedCatalogProjection {
    let discoverableRelativeFilePaths: WorkspaceRootByteExactPathSet
    let policyIgnoredCommittedRegularRelativePaths: WorkspaceRootByteExactPathSet
    let policyIdentity: WorkspaceRootCatalogPolicyIdentity
}

struct WorkspaceRootSeedCompatibilityKey: Hashable {
    static let currentInventorySchemaVersion = 3

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

    /// Delta reuse deliberately excludes the committed tree object from compatibility.
    /// The planner proves that difference with a bounded tree-to-tree delta; every policy,
    /// prefix, repository, and matcher field must still match exactly.
    func isDeltaCompatible(with other: Self) -> Bool {
        repositoryNamespace == other.repositoryNamespace
            && objectFormat == other.objectFormat
            && repositoryRelativeRootPrefix == other.repositoryRelativeRootPrefix
            && inventorySchemaVersion == other.inventorySchemaVersion
            && policyIdentity == other.policyIdentity
            && searchABI == other.searchABI
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

    enum CatalogProjection: String, Hashable {
        case searchableRegularFile
        case policyIgnoredRegularFile
        case nonRegularTopology
    }

    let ordinal: Int
    let parentOrdinal: Int?
    let relativePath: String
    let mode: String
    let kind: GitTreeEntryKind
    let objectID: GitObjectID
    let provenance: Provenance
    let catalogProjection: CatalogProjection

    init(
        ordinal: Int,
        parentOrdinal: Int?,
        relativePath: String,
        mode: String,
        kind: GitTreeEntryKind,
        objectID: GitObjectID,
        provenance: Provenance,
        catalogProjection: CatalogProjection? = nil
    ) {
        self.ordinal = ordinal
        self.parentOrdinal = parentOrdinal
        self.relativePath = relativePath
        self.mode = mode
        self.kind = kind
        self.objectID = objectID
        self.provenance = provenance
        self.catalogProjection = catalogProjection
            ?? (
                kind == .blob && (mode == "100644" || mode == "100755")
                    ? .searchableRegularFile
                    : .nonRegularTopology
            )
    }

    var isCommittedRegularFile: Bool {
        kind == .blob && (mode == "100644" || mode == "100755")
    }

    var isSearchableFile: Bool {
        isCommittedRegularFile && catalogProjection == .searchableRegularFile
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
        self.relativePaths = relativePaths.map(StandardizedPath.relative)
        filenames = self.relativePaths.map { ($0 as NSString).lastPathComponent }
        self.stableOrdinals = stableOrdinals
        index = PathSearchIndex(paths: self.relativePaths)
    }
}

final class WorkspaceRootReusableSnapshot: @unchecked Sendable {
    let identity: WorkspaceRootReusableSnapshotIdentity
    let compatibilityKey: WorkspaceRootSeedCompatibilityKey
    let inventory: RootNeutralTreeInventory
    let searchBase: WorkspaceSearchRelativePathBase
    let catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity
    let estimatedByteCount: Int

    init(
        compatibilityKey: WorkspaceRootSeedCompatibilityKey,
        inventory: RootNeutralTreeInventory,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity = .canonicalDefaults
    ) {
        self.compatibilityKey = compatibilityKey
        self.inventory = inventory
        self.catalogPolicyIdentity = catalogPolicyIdentity
        let searchable = inventory.entries.filter(\.isSearchableFile)
        searchBase = WorkspaceSearchRelativePathBase(
            relativePaths: searchable.map(\.relativePath),
            stableOrdinals: searchable.map(\.ordinal)
        )
        identity = WorkspaceRootReusableSnapshotIdentity(
            sha256: Self.contentDigest(
                compatibilityKey: compatibilityKey,
                inventory: inventory,
                catalogPolicyIdentity: catalogPolicyIdentity
            ),
            searchABI: compatibilityKey.searchABI
        )
        estimatedByteCount = inventory.entries.reduce(0) { partial, entry in
            partial + entry.relativePath.utf8.count + entry.mode.utf8.count
                + entry.objectID.lowercaseHex.utf8.count + entry.catalogProjection.rawValue.utf8.count + 96
        } + searchBase.relativePaths.reduce(0) { $0 + $1.utf8.count + 48 }
    }

    func hasValidContentAddress() -> Bool {
        identity.searchABI == compatibilityKey.searchABI
            && identity.sha256 == Self.contentDigest(
                compatibilityKey: compatibilityKey,
                inventory: inventory,
                catalogPolicyIdentity: catalogPolicyIdentity
            )
    }

    static func make(
        authority: GitWorkspaceAuthoritySnapshot,
        tree: GitTreeInventorySnapshot,
        catalogProjection: WorkspaceRootValidatedCatalogProjection
    ) -> WorkspaceRootReusableSnapshot? {
        guard authority.treeOID == tree.treeOID,
              authority.repositoryRelativeRootPrefix == tree.rootPrefix,
              authority.policyIdentity.searchABI == .current
        else { return nil }

        var relativeEntries: [(source: GitTreeInventoryEntry, pathKey: WorkspaceRootByteExactPathKey)] = []
        relativeEntries.reserveCapacity(tree.entries.count)
        for entry in tree.entries {
            guard let relativePath = WorkspaceRootByteExactPathKey.rootRelativePath(
                repositoryRelativePath: entry.repositoryRelativePath,
                prefix: tree.rootPrefix
            ), !relativePath.isEmpty else { continue }
            relativeEntries.append((entry, WorkspaceRootByteExactPathKey(relativePath)))
        }
        guard WorkspaceRootByteExactPathSet(
            relativeEntries.map(\.pathKey.value),
            rejectExactDuplicates: true
        ) != nil else {
            return nil
        }
        relativeEntries.sort { $0.pathKey < $1.pathKey }

        var ordinalByPath: [WorkspaceRootByteExactPathKey: Int] = [:]
        var entries: [RootNeutralTreeInventoryEntry] = []
        entries.reserveCapacity(relativeEntries.count)
        for (ordinal, value) in relativeEntries.enumerated() {
            let parentOrdinal = value.pathKey.parent.flatMap { ordinalByPath[$0] }
            let committedRegular = value.source.kind == .blob
                && (value.source.mode == "100644" || value.source.mode == "100755")
            let entryCatalogProjection: RootNeutralTreeInventoryEntry.CatalogProjection
            if committedRegular {
                let isDiscoverable = catalogProjection.discoverableRelativeFilePaths.contains(value.pathKey)
                let isPolicyIgnored = catalogProjection.policyIgnoredCommittedRegularRelativePaths
                    .contains(value.pathKey)
                switch (isDiscoverable, isPolicyIgnored) {
                case (true, false):
                    entryCatalogProjection = .searchableRegularFile
                case (false, true):
                    entryCatalogProjection = .policyIgnoredRegularFile
                case (false, false), (true, true):
                    return nil
                }
            } else {
                entryCatalogProjection = .nonRegularTopology
            }
            let projected = RootNeutralTreeInventoryEntry(
                ordinal: ordinal,
                parentOrdinal: parentOrdinal,
                relativePath: value.pathKey.value,
                mode: value.source.mode,
                kind: value.source.kind,
                objectID: value.source.objectID,
                provenance: .committedTree,
                catalogProjection: entryCatalogProjection
            )
            entries.append(projected)
            ordinalByPath[value.pathKey] = ordinal
        }
        return WorkspaceRootReusableSnapshot(
            compatibilityKey: WorkspaceRootSeedCompatibilityKey(authority: authority),
            inventory: RootNeutralTreeInventory(entries: entries),
            catalogPolicyIdentity: catalogProjection.policyIdentity
        )
    }

    private static func contentDigest(
        compatibilityKey: WorkspaceRootSeedCompatibilityKey,
        inventory: RootNeutralTreeInventory,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity
    ) -> String {
        var writer = CanonicalWriter()
        writer.append("workspace-root-reusable-snapshot-v3")
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
        writer.append(catalogPolicyIdentity.schemaVersion)
        writer.append(catalogPolicyIdentity.mandatoryIgnorePolicyIdentity)
        writer.append(catalogPolicyIdentity.globalIgnoreDefaultsDigest)
        writer.append(catalogPolicyIdentity.respectRepoIgnore ? "1" : "0")
        writer.append(catalogPolicyIdentity.respectCursorignore ? "1" : "0")
        writer.append(catalogPolicyIdentity.enableHierarchicalIgnores ? "1" : "0")
        writer.append(catalogPolicyIdentity.skipSymlinks ? "1" : "0")
        writer.append(contentIdentity: compatibilityKey.policyIdentity.resolvedExcludesFileIdentity)
        writer.append(contentIdentity: compatibilityKey.policyIdentity.resolvedAttributesFileIdentity)
        for control in compatibilityKey.policyIdentity.prefixControlIdentities.sorted(by: {
            let lhsPath = WorkspaceRootByteExactPathKey($0.repositoryRelativePath)
            let rhsPath = WorkspaceRootByteExactPathKey($1.repositoryRelativePath)
            if lhsPath != rhsPath {
                return lhsPath < rhsPath
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
            writer.append(entry.catalogProjection.rawValue)
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
        let expectedPhysicalRootPath = creationReceipt.repositoryRelativeRootPrefix.value.isEmpty
            ? creationReceipt.actualTargetPath
            : URL(fileURLWithPath: creationReceipt.actualTargetPath, isDirectory: true)
            .appendingPathComponent(
                creationReceipt.repositoryRelativeRootPrefix.value,
                isDirectory: true
            )
            .standardizedFileURL.path
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
              expectedPhysicalRootPath == standardizedTargetPath,
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

struct WorkspaceRootSeedPlannerLimits: Equatable {
    let maximumVerificationPathCount: Int
    let maximumOverlayChangedFileCount: Int

    static let production = WorkspaceRootSeedPlannerLimits(
        maximumVerificationPathCount: 512,
        maximumOverlayChangedFileCount: WorkspaceSearchRootPathIndex.maxOverlayChangedFileCount
    )
}

enum WorkspaceRootSeedVerifiedPathKind: Equatable {
    case missing
    case regularFile(isExecutable: Bool)
    case directory
    case symbolicLink
    case special
}

struct WorkspaceRootSeedVerificationFact: Equatable {
    let relativePath: String
    let kind: WorkspaceRootSeedVerifiedPathKind
    let isIgnored: Bool
    let isIncludedInOrdinaryCrawl: Bool

    init(
        relativePath: String,
        kind: WorkspaceRootSeedVerifiedPathKind,
        isIgnored: Bool,
        isIncludedInOrdinaryCrawl: Bool? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.isIgnored = isIgnored
        self.isIncludedInOrdinaryCrawl = isIncludedInOrdinaryCrawl
            ?? (kind == .directory && !isIgnored)
    }
}

struct WorkspaceRootSeedPlan: Equatable {
    let snapshotIdentity: WorkspaceRootReusableSnapshotIdentity
    let targetTreeOID: GitObjectID
    let relativeFilePaths: Set<String>
    let relativeFolderPaths: Set<String>
    let baseRelativeFilePaths: Set<String>
    let changedRelativeFilePaths: Set<String>
    let tombstonedBaseRelativeFilePaths: Set<String>
    let policyIgnoredTrackedRelativeFilePaths: Set<String>
    let verifiedPathCount: Int

    init(
        snapshotIdentity: WorkspaceRootReusableSnapshotIdentity,
        targetTreeOID: GitObjectID,
        relativeFilePaths: Set<String>,
        relativeFolderPaths: Set<String>,
        baseRelativeFilePaths: Set<String>,
        changedRelativeFilePaths: Set<String>,
        tombstonedBaseRelativeFilePaths: Set<String>,
        policyIgnoredTrackedRelativeFilePaths: Set<String> = [],
        verifiedPathCount: Int
    ) {
        self.snapshotIdentity = snapshotIdentity
        self.targetTreeOID = targetTreeOID
        self.relativeFilePaths = relativeFilePaths
        self.relativeFolderPaths = relativeFolderPaths
        self.baseRelativeFilePaths = baseRelativeFilePaths
        self.changedRelativeFilePaths = changedRelativeFilePaths
        self.tombstonedBaseRelativeFilePaths = tombstonedBaseRelativeFilePaths
        self.policyIgnoredTrackedRelativeFilePaths = policyIgnoredTrackedRelativeFilePaths
        self.verifiedPathCount = verifiedPathCount
    }

    var overlayRelativeFilePaths: Set<String> {
        changedRelativeFilePaths.intersection(relativeFilePaths)
    }
}

enum WorkspaceRootSeedPlannerOutcome: Equatable {
    case planned(WorkspaceRootSeedPlan)
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
