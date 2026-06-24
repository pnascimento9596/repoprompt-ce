import Foundation

actor WorkspaceRootMaterializationHintEvaluator {
    static let shared = WorkspaceRootMaterializationHintEvaluator()

    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared
    ) {
        self.gitService = gitService
        self.authority = authority
    }

    func observe(
        _ hint: WorkspaceRootMaterializationHint?,
        observationEnabled: Bool
    ) async -> WorkspaceRootMaterializationHintObservation {
        guard observationEnabled else { return .observationDisabled }
        guard let hint else { return .fallback(.noReceipt) }
        if let reason = hint.validationFallbackReason ?? hint.creationReceipt.fallbackReason() {
            return .fallback(reason)
        }
        guard hint.orderedCompatibleBaseCandidates.contains(hint.creationReceipt.parentSnapshotIdentity) else {
            return .fallback(.baseUnavailable)
        }
        guard await authority.reusableSnapshot(
            identity: hint.creationReceipt.parentSnapshotIdentity,
            expectedCompatibilityKey: hint.creationReceipt.parentCompatibilityKey
        ) != nil else {
            return .fallback(.baseEvicted)
        }

        do {
            let current = try await gitService.generationFencedAuthoritySnapshot(
                layout: hint.creationReceipt.targetLayout,
                prefix: hint.creationReceipt.repositoryRelativeRootPrefix
            )
            guard current == hint.creationReceipt.targetAuthorityAfter else {
                return .fallback(.authorityUnstable)
            }
            let currentCompatibility = WorkspaceRootSeedCompatibilityKey(authority: current)
            guard currentCompatibility == hint.creationReceipt.parentCompatibilityKey,
                  currentCompatibility.searchABI == .current
            else {
                return .fallback(.compatibilityMismatch)
            }
            return .eligible(hint.creationReceipt.parentSnapshotIdentity)
        } catch let reason as GitWorkspaceAuthorityUnavailableReason {
            switch reason {
            case .mutationInProgress, .metadataEventPending:
                return .fallback(.authorityChanging)
            case .noSnapshot, .monitorCoverageUnavailable, .superseded,
                 .invalidatedDuringCollection, .collectionScopeMismatch:
                return .fallback(.authorityUnstable)
            }
        } catch let error as GitWorktreeInitializationError {
            switch error.reason {
            case .timeout:
                return .fallback(.gitTimeout)
            case .cappedOutput, .recordLimitExceeded, .pathLimitExceeded:
                return .fallback(.gitCappedOutput)
            case .malformedOutput, .invalidRootPrefix:
                return .fallback(.gitMalformedOutput)
            case .gitError:
                return .fallback(.gitError)
            case .cancelled:
                return .fallback(.cancellation)
            }
        } catch {
            return .fallback(.gitError)
        }
    }
}
