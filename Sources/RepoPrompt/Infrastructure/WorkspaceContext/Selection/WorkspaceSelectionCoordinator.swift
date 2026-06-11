import Combine
import Foundation

private struct WorkspaceSelectionMirrorTarget: Equatable {
    let workspaceID: UUID
    let tabID: UUID
    let selection: StoredSelection
    let contextRevision: UInt64
}

@MainActor
protocol WorkspaceSelectionHost: AnyObject {
    var activeWorkspace: WorkspaceModel? { get }
    var selectionMirrorContextRevision: UInt64 { get }
    func composeTab(with id: UUID) -> ComposeTabState?
    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool)
    func updateComposeTabStoredOnly(_ tab: ComposeTabState)
    func applySelectionMirrorAttempt(
        _ selection: StoredSelection,
        forTabID tabID: UUID,
        workspaceID: UUID
    ) async
}

private extension WorkspaceSelectionHost {
    func activeSelectionMirrorTarget() -> WorkspaceSelectionMirrorTarget? {
        guard let workspace = activeWorkspace,
              let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id,
              let tab = workspace.composeTabs.first(where: { $0.id == tabID })
        else { return nil }
        return WorkspaceSelectionMirrorTarget(
            workspaceID: workspace.id,
            tabID: tabID,
            selection: tab.selection,
            contextRevision: selectionMirrorContextRevision
        )
    }
}

extension WorkspaceManagerViewModel: WorkspaceSelectionHost {}

/// Window-scoped coordinator that makes compose-tab `StoredSelection` the runtime
/// selection source while the WorkspaceFiles UI adapter still owns checkbox state.
@MainActor
final class WorkspaceSelectionCoordinator {
    struct Snapshot: Equatable {
        let tabID: UUID?
        let selection: StoredSelection
        let isVirtual: Bool
    }

    struct Change: Equatable {
        let tabID: UUID?
        let selection: StoredSelection
        let source: Source
    }

    enum Source: String, Equatable {
        case uiFlush
        case runtimeMutation
        case virtual
        case mcpTabContext
        case mirror
    }

    private weak var workspaceManager: (any WorkspaceSelectionHost)?
    let store: WorkspaceFileContextStore
    let mutationService: WorkspaceSelectionMutationService
    private let changeSubject = PassthroughSubject<Change, Never>()
    private var applyingSelectionMirrorDepth = 0
    private struct MCPSelectionMirrorTail {
        let id: UInt64
        /// `nil` denotes a coalesced repair that resolves the latest active target when it runs.
        let target: WorkspaceSelectionMirrorTarget?
        let task: Task<Void, Never>
    }

    private var nextSelectionRevision: UInt64 = 0
    private var selectionRevisionByTabID: [UUID: UInt64] = [:]
    private var nextSelectionMirrorTaskID: UInt64 = 0
    private var mcpSelectionMirrorTail: MCPSelectionMirrorTail?

    var changes: AnyPublisher<Change, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    var isApplyingSelectionMirror: Bool {
        applyingSelectionMirrorDepth > 0
    }

    init(
        workspaceManager: (any WorkspaceSelectionHost)? = nil,
        store: WorkspaceFileContextStore,
        mutationService: WorkspaceSelectionMutationService? = nil
    ) {
        self.workspaceManager = workspaceManager
        self.store = store
        self.mutationService = mutationService ?? WorkspaceSelectionMutationService(store: store)
    }

    func attachWorkspaceManager(_ workspaceManager: any WorkspaceSelectionHost) {
        self.workspaceManager = workspaceManager
    }

    func activeTabID() -> UUID? {
        guard let workspaceManager else { return nil }
        return workspaceManager.activeWorkspace?.activeComposeTabID
            ?? workspaceManager.activeWorkspace?.composeTabs.first?.id
    }

    func activeSelectionSnapshot(flushPendingUI: Bool = true) -> Snapshot {
        if flushPendingUI {
            flushPendingUISelectionToActiveTab()
        }
        guard let workspaceManager, let tabID = activeTabID() else {
            return Snapshot(tabID: nil, selection: StoredSelection(), isVirtual: false)
        }
        return Snapshot(
            tabID: tabID,
            selection: workspaceManager.composeTab(with: tabID)?.selection ?? StoredSelection(),
            isVirtual: false
        )
    }

    func virtualSelectionSnapshot(tabID: UUID, selection: StoredSelection) -> Snapshot {
        Snapshot(tabID: tabID, selection: selection, isVirtual: true)
    }

    func selectionSnapshot(for tabID: UUID, flushPendingUIIfActive: Bool = true) -> Snapshot? {
        if tabID == activeTabID() {
            return activeSelectionSnapshot(flushPendingUI: flushPendingUIIfActive)
        }
        guard let selection = workspaceManager?.composeTab(with: tabID)?.selection else { return nil }
        return Snapshot(tabID: tabID, selection: selection, isVirtual: true)
    }

    func flushPendingUISelectionToActiveTab() {
        guard !isApplyingSelectionMirror, let workspaceManager else { return }
        let previousTabID = activeTabID()
        let previousSelection = previousTabID.flatMap { workspaceManager.composeTab(with: $0)?.selection } ?? StoredSelection()
        workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        let snapshot = activeSelectionSnapshot(flushPendingUI: false)
        guard snapshot.tabID != previousTabID || snapshot.selection != previousSelection else { return }
        if let tabID = snapshot.tabID {
            recordSelectionRevision(for: tabID)
        }
        changeSubject.send(Change(tabID: snapshot.tabID, selection: snapshot.selection, source: .uiFlush))
    }

    @discardableResult
    func persistActiveSelection(
        _ selection: StoredSelection,
        source: Source = .runtimeMutation,
        mirrorToUI: Bool = true
    ) async -> StoredSelection {
        guard let workspaceManager, let tabID = activeTabID() else { return selection }
        if workspaceManager.composeTab(with: tabID)?.selection == selection {
            if mirrorToUI, source == .mcpTabContext {
                let revision = recordSelectionRevision(for: tabID)
                await enqueueMCPSelectionMirror(selection, forTabID: tabID, revision: revision)
            }
            return selection
        }

        guard let revision = persist(selection, for: tabID, markDirty: true) else { return selection }
        let change = Change(tabID: tabID, selection: selection, source: source)
        if mirrorToUI, source == .mcpTabContext {
            changeSubject.send(change)
            await enqueueMCPSelectionMirror(selection, forTabID: tabID, revision: revision)
        } else if mirrorToUI {
            await applySelectionMirror {
                changeSubject.send(change)
            }
        } else {
            changeSubject.send(change)
        }
        return selection
    }

    @discardableResult
    func persistSelection(
        _ selection: StoredSelection,
        for tabID: UUID,
        source: Source = .runtimeMutation,
        mirrorToUIIfActive: Bool = true
    ) async -> StoredSelection {
        if tabID == activeTabID() {
            return await persistActiveSelection(selection, source: source, mirrorToUI: mirrorToUIIfActive)
        }
        return persistVirtualSelection(selection, for: tabID, source: source)
    }

    @discardableResult
    func persistVirtualSelection(
        _ selection: StoredSelection,
        for tabID: UUID,
        source: Source = .virtual
    ) -> StoredSelection {
        guard persist(selection, for: tabID, markDirty: true) != nil else { return selection }
        changeSubject.send(Change(tabID: tabID, selection: selection, source: source))
        return selection
    }

    @discardableResult
    func replaceActiveSelection(_ selection: StoredSelection) async -> StoredSelection {
        await persistActiveSelection(selection, source: .runtimeMutation)
    }

    @discardableResult
    func addPathsToActiveSelection(
        paths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceAddSelectionResult {
        let current = activeSelectionSnapshot(flushPendingUI: true).selection
        let result = await mutationService.addPaths(
            existing: current,
            paths: paths,
            rawPaths: paths,
            mode: mode,
            rootScope: rootScope
        )
        if result.mutated {
            _ = await persistActiveSelection(result.selection, source: .runtimeMutation)
        }
        return result
    }

    @discardableResult
    func removePathsFromActiveSelection(
        paths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceRemoveSelectionResult {
        let current = activeSelectionSnapshot(flushPendingUI: true).selection
        let result = await mutationService.removePaths(
            existing: current,
            paths: paths,
            rawPaths: paths,
            mode: mode,
            rootScope: rootScope
        )
        if result.mutated {
            _ = await persistActiveSelection(result.selection, source: .runtimeMutation)
        }
        return result
    }

    func withApplyingSelectionMirror<T>(_ operation: () async throws -> T) async rethrows -> T {
        applyingSelectionMirrorDepth += 1
        defer { applyingSelectionMirrorDepth = max(0, applyingSelectionMirrorDepth - 1) }
        return try await operation()
    }

    private func applySelectionMirror(_ operation: () async -> Void) async {
        await withApplyingSelectionMirror {
            await operation()
        }
    }

    func mirrorSelectionToActiveUI(_ selection: StoredSelection, forTabID tabID: UUID) async {
        guard let workspaceManager,
              let target = workspaceManager.activeSelectionMirrorTarget(),
              target.tabID == tabID,
              target.selection == selection
        else { return }
        let revision = selectionRevisionByTabID[tabID]
        await enqueueSelectionMirror(target, selectionRevision: revision == 0 ? nil : revision)
    }

    private func enqueueMCPSelectionMirror(
        _ selection: StoredSelection,
        forTabID tabID: UUID,
        revision: UInt64
    ) async {
        guard let workspaceManager,
              let target = workspaceManager.activeSelectionMirrorTarget(),
              target.tabID == tabID,
              target.selection == selection
        else { return }
        await enqueueSelectionMirror(target, selectionRevision: revision)
    }

    private func enqueueSelectionMirror(
        _ target: WorkspaceSelectionMirrorTarget,
        selectionRevision: UInt64?
    ) async {
        let predecessor = mcpSelectionMirrorTail?.task
        let taskID = allocateSelectionMirrorTaskID()
        // The internal task owns its completion after canonical persistence, even if the
        // originating request is cancelled. Each task performs at most one suppressed apply.
        let task = Task { @MainActor [weak self, weak workspaceManager] in
            await predecessor?.value
            guard let self, let workspaceManager else { return }

            let revisionIsCurrent = selectionRevision.map {
                selectionRevisionByTabID[target.tabID] == $0
            } ?? true
            var attemptedTarget: WorkspaceSelectionMirrorTarget?
            if revisionIsCurrent,
               workspaceManager.activeSelectionMirrorTarget() == target
            {
                attemptedTarget = target
                await applySelectionMirror {
                    await workspaceManager.applySelectionMirrorAttempt(
                        target.selection,
                        forTabID: target.tabID,
                        workspaceID: target.workspaceID
                    )
                }
            }
            finishSelectionMirrorTask(taskID, attemptedTarget: attemptedTarget)
        }
        mcpSelectionMirrorTail = MCPSelectionMirrorTail(id: taskID, target: target, task: task)
        await task.value
    }

    /// Coalesces post-suspension churn into one latest-target successor. The completed request
    /// does not await this repair, so sustained switching cannot wedge the MCP drain.
    private func scheduleSelectionMirrorRepair(after predecessor: Task<Void, Never>?) {
        let taskID = allocateSelectionMirrorTaskID()
        let task = Task { @MainActor [weak self, weak workspaceManager] in
            await predecessor?.value
            guard let self, let workspaceManager else { return }

            let target = workspaceManager.activeSelectionMirrorTarget()
            if let target {
                await applySelectionMirror {
                    await workspaceManager.applySelectionMirrorAttempt(
                        target.selection,
                        forTabID: target.tabID,
                        workspaceID: target.workspaceID
                    )
                }
            }
            finishSelectionMirrorTask(taskID, attemptedTarget: target)
        }
        mcpSelectionMirrorTail = MCPSelectionMirrorTail(id: taskID, target: nil, task: task)
    }

    private func finishSelectionMirrorTask(
        _ taskID: UInt64,
        attemptedTarget: WorkspaceSelectionMirrorTarget?
    ) {
        let currentTarget = workspaceManager?.activeSelectionMirrorTarget()
        if currentTarget == attemptedTarget {
            if mcpSelectionMirrorTail?.id == taskID {
                mcpSelectionMirrorTail = nil
            }
            return
        }

        if let successor = mcpSelectionMirrorTail, successor.id != taskID {
            // An exact canonical successor or an existing latest-target repair already owns it.
            guard successor.target != currentTarget, successor.target != nil else { return }
            scheduleSelectionMirrorRepair(after: successor.task)
        } else if currentTarget != nil {
            scheduleSelectionMirrorRepair(after: nil)
        } else if mcpSelectionMirrorTail?.id == taskID {
            mcpSelectionMirrorTail = nil
        }
    }

    private func allocateSelectionMirrorTaskID() -> UInt64 {
        nextSelectionMirrorTaskID &+= 1
        return nextSelectionMirrorTaskID
    }

    @discardableResult
    private func recordSelectionRevision(for tabID: UUID) -> UInt64 {
        nextSelectionRevision &+= 1
        selectionRevisionByTabID[tabID] = nextSelectionRevision
        return nextSelectionRevision
    }

    private func persist(_ selection: StoredSelection, for tabID: UUID, markDirty: Bool) -> UInt64? {
        guard let workspaceManager, var tab = workspaceManager.composeTab(with: tabID) else { return nil }
        guard tab.selection != selection else { return nil }
        tab.selection = selection
        tab.lastModified = Date()
        workspaceManager.updateComposeTabStoredOnly(tab)
        return recordSelectionRevision(for: tabID)
    }
}
