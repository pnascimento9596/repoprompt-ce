import Foundation

/// Persisted binding from a workspace logical root to a Git worktree for one agent session.
///
/// This is storage-only metadata. Runtime path projection/cwd resolution is implemented by later
/// worktree-system items that consume these persisted bindings.
struct AgentSessionWorktreeBinding: Codable, Equatable, Identifiable {
    let id: String
    let repositoryID: String
    let repoKey: String
    let logicalRootPath: String
    let logicalRootName: String?
    let worktreeID: String
    let worktreeRootPath: String
    let worktreeName: String?
    let branch: String?
    let head: String?
    let visualLabel: String?
    let visualColorHex: String?
    let boundAt: Date
    let source: String

    init(
        id: String,
        repositoryID: String,
        repoKey: String,
        logicalRootPath: String,
        logicalRootName: String? = nil,
        worktreeID: String,
        worktreeRootPath: String,
        worktreeName: String? = nil,
        branch: String? = nil,
        head: String? = nil,
        visualLabel: String? = nil,
        visualColorHex: String? = nil,
        boundAt: Date = Date(),
        source: String
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.logicalRootPath = logicalRootPath
        self.logicalRootName = logicalRootName
        self.worktreeID = worktreeID
        self.worktreeRootPath = worktreeRootPath
        self.worktreeName = worktreeName
        self.branch = branch
        self.head = head
        self.visualLabel = visualLabel
        self.visualColorHex = visualColorHex
        self.boundAt = boundAt
        self.source = source
    }

    var summary: AgentSessionWorktreeBindingSummary {
        AgentSessionWorktreeBindingSummary(binding: self)
    }

    func updatingCheckout(branch: String?, head: String?) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: id,
            repositoryID: repositoryID,
            repoKey: repoKey,
            logicalRootPath: logicalRootPath,
            logicalRootName: logicalRootName,
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            worktreeName: worktreeName,
            branch: branch,
            head: head,
            visualLabel: visualLabel,
            visualColorHex: visualColorHex,
            boundAt: boundAt,
            source: source
        )
    }
}

/// Lightweight worktree-binding data copied into session-list/index records so callers can show
/// identity without loading full transcripts.
struct AgentSessionWorktreeBindingSummary: Codable, Equatable, Identifiable {
    let id: String
    let repositoryID: String
    let repoKey: String
    let logicalRootPath: String
    let logicalRootName: String?
    let worktreeID: String
    let worktreeRootPath: String
    let worktreeName: String?
    let branch: String?
    let visualLabel: String?
    let visualColorHex: String?
    let boundAt: Date

    init(
        id: String,
        repositoryID: String,
        repoKey: String,
        logicalRootPath: String,
        logicalRootName: String? = nil,
        worktreeID: String,
        worktreeRootPath: String,
        worktreeName: String? = nil,
        branch: String? = nil,
        visualLabel: String? = nil,
        visualColorHex: String? = nil,
        boundAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.logicalRootPath = logicalRootPath
        self.logicalRootName = logicalRootName
        self.worktreeID = worktreeID
        self.worktreeRootPath = worktreeRootPath
        self.worktreeName = worktreeName
        self.branch = branch
        self.visualLabel = visualLabel
        self.visualColorHex = visualColorHex
        self.boundAt = boundAt
    }

    init(binding: AgentSessionWorktreeBinding) {
        self.init(
            id: binding.id,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            logicalRootPath: binding.logicalRootPath,
            logicalRootName: binding.logicalRootName,
            worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath,
            worktreeName: binding.worktreeName,
            branch: binding.branch,
            visualLabel: binding.visualLabel,
            visualColorHex: binding.visualColorHex,
            boundAt: binding.boundAt
        )
    }
}

struct AgentWorktreeRuntimeWorkspaceError: LocalizedError, Equatable {
    let binding: AgentSessionWorktreeBinding

    var errorDescription: String? {
        let label = binding.visualLabel
            ?? binding.worktreeName
            ?? binding.branch
            ?? binding.worktreeID
        let logicalRoot = binding.logicalRootName ?? binding.logicalRootPath
        return "Agent session is bound to worktree '\(label)' for root '\(logicalRoot)', but the worktree path is unavailable: \(binding.worktreeRootPath). Recreate or repair that Git worktree, bind the session to another worktree, or unbind the session before starting the agent."
    }
}

extension Sequence<AgentSessionWorktreeBinding> {
    var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] {
        map(\.summary)
    }
}
