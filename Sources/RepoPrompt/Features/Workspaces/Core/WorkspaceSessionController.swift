import Foundation

struct WorkspaceSessionBindingCandidate: Equatable {
    let tabID: UUID
    let workspaceID: UUID
    let workspaceName: String
    let isActiveInWorkspace: Bool
    let repoPaths: [String]
}

/// Transitional reusable backing port for workspace session state.
///
/// The app adapter remains `WorkspaceManagerViewModel` during Item 3. Keeping this
/// protocol narrow prevents the reusable session graph from retaining or naming
/// that observable UI adapter directly.
@MainActor
protocol WorkspaceSessionBacking: WorkspaceSelectionHost {
    func sessionBindingCandidate(forContextID id: UUID) -> WorkspaceSessionBindingCandidate?
    func sessionBindingCandidates(matchingWorkingDirs dirs: [String], includeHidden: Bool) -> [WorkspaceSessionBindingCandidate]
}

/// Window-independent workspace projection owned by a core session.
///
/// Item 3 stages the controller with a weak app backing. Item 4/5 can move state
/// ownership behind this API without changing MCP routing or selection callers.
@MainActor
final class WorkspaceSessionController: WorkspaceSelectionHost {
    private weak var backing: (any WorkspaceSessionBacking)?
    private let accessPolicy: any WorkspaceAccessPolicy

    init(accessPolicy: any WorkspaceAccessPolicy) {
        self.accessPolicy = accessPolicy
    }

    var activeWorkspace: WorkspaceModel? {
        backing?.activeWorkspace
    }

    func attach(backing: any WorkspaceSessionBacking) {
        self.backing = backing
    }

    func detach() {
        backing = nil
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        backing?.composeTab(with: id)
    }

    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool) {
        backing?.publishActiveComposeTabSnapshot(commitToMemory: commitToMemory, touchModified: touchModified)
    }

    func updateComposeTabStoredOnly(_ tab: ComposeTabState) {
        backing?.updateComposeTabStoredOnly(tab)
    }

    func bindingCandidate(forContextID id: UUID) -> WorkspaceSessionBindingCandidate? {
        backing?.sessionBindingCandidate(forContextID: id).map(applyingAccessPolicy(to:))
    }

    func bindingCandidates(matchingWorkingDirs dirs: [String], includeHidden: Bool = false) -> [WorkspaceSessionBindingCandidate] {
        backing?.sessionBindingCandidates(matchingWorkingDirs: dirs, includeHidden: includeHidden)
            .map(applyingAccessPolicy(to:)) ?? []
    }

    private func applyingAccessPolicy(to candidate: WorkspaceSessionBindingCandidate) -> WorkspaceSessionBindingCandidate {
        WorkspaceSessionBindingCandidate(
            tabID: candidate.tabID,
            workspaceID: candidate.workspaceID,
            workspaceName: candidate.workspaceName,
            isActiveInWorkspace: candidate.isActiveInWorkspace,
            repoPaths: candidate.repoPaths.filter { accessPolicy.allowsWorkspaceRoot(URL(fileURLWithPath: $0)) }
        )
    }
}

extension WorkspaceManagerViewModel: WorkspaceSessionBacking {
    func sessionBindingCandidate(forContextID id: UUID) -> WorkspaceSessionBindingCandidate? {
        bindingCandidate(forContextID: id).map(Self.sessionBindingCandidate(from:))
    }

    func sessionBindingCandidates(matchingWorkingDirs dirs: [String], includeHidden: Bool) -> [WorkspaceSessionBindingCandidate] {
        bindingCandidates(matchingWorkingDirs: dirs, includeHidden: includeHidden).map(Self.sessionBindingCandidate(from:))
    }

    private static func sessionBindingCandidate(from candidate: ComposeTabBindingCandidate) -> WorkspaceSessionBindingCandidate {
        WorkspaceSessionBindingCandidate(
            tabID: candidate.tabID,
            workspaceID: candidate.workspaceID,
            workspaceName: candidate.workspaceName,
            isActiveInWorkspace: candidate.isActiveInWorkspace,
            repoPaths: candidate.repoPaths
        )
    }
}
