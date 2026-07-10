//
//  AgentModelsSettingsViewModel.swift
//  RepoPrompt
//
//  View model for AgentModelsSettingsView — the unified home for every
//  agent-mode model decision (Oracle, Built-in Chat, Context Builder agent,
//  and MCP agent role defaults).
//
//  SEARCH-HELPER: Agent Models, Oracle Model, Built-in Chat Model,
//  Context Builder Agent, Agent Role Defaults, Apply Recommended Setup,
//  Planning Model, sync toggle
//
//  Related:
//  - Page:          /RepoPrompt/Views/Settings/AgentModelsSettingsView.swift
//  - Engine:        /RepoPrompt/Services/Recommendations/AutoRecommendationEngine.swift
//  - Role defaults: /RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift
//  - Sync key:      /RepoPrompt/Models/Settings/GlobalSettingsManager.swift
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AgentModelsSettingsViewModel: ObservableObject {
    // MARK: - Dependencies

    let promptVM: PromptViewModel
    let apiSettingsVM: APISettingsViewModel
    let settingsStore: GlobalSettingsStore
    private let notificationCenter: NotificationCenter
    private let engine: AutoRecommendationEngine

    // MARK: - Published state

    @Published private(set) var recommendations: RecommendationSet = .init()
    @Published private(set) var isApplyingAll: Bool = false
    @Published var syncChatWithOracle: Bool {
        didSet {
            guard oldValue != syncChatWithOracle else { return }
            settingsStore.setSyncChatModelWithOracle(syncChatWithOracle, reason: "agent_models.sync_toggle")
            // If turning sync on, mirror Oracle → Built-in Chat so the two agree going forward.
            if syncChatWithOracle {
                let planningRaw = promptVM.planningModelName
                if !planningRaw.isEmpty, planningRaw != promptVM.preferredModel {
                    promptVM.preferredModel = planningRaw
                }
            }
            refresh()
        }
    }

    /// When `true`, MCP `agent_manage list_agents` hides the extra per-agent
    /// compound model catalog while keeping the four sub-agent role labels
    /// (`explore`, `engineer`, `pair`, `design`) and their concrete model
    /// mappings visible. Manually supplied compound model IDs remain accepted by
    /// the resolver for backwards compatibility.
    ///
    /// SEARCH-HELPER: restrict MCP discovery catalog, role-label mappings,
    /// MCP list_agents filtering, hide non-role model IDs
    @Published var restrictMCPAgentDiscoveryToRoleLabels: Bool {
        didSet {
            guard oldValue != restrictMCPAgentDiscoveryToRoleLabels else { return }
            settingsStore.setRestrictMCPAgentDiscoveryToRoleLabels(restrictMCPAgentDiscoveryToRoleLabels)
        }
    }

    // MARK: - Bookkeeping

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        promptVM: PromptViewModel,
        apiSettingsVM: APISettingsViewModel,
        settingsStore: GlobalSettingsStore? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        self.promptVM = promptVM
        self.apiSettingsVM = apiSettingsVM
        self.settingsStore = settingsStore
        _ = defaults // Retained for initializer compatibility while storage lives in GlobalSettingsStore.
        self.notificationCenter = notificationCenter
        engine = AutoRecommendationEngine(
            settingsStore: settingsStore,
            apiSettingsViewModel: apiSettingsVM
        )
        syncChatWithOracle = settingsStore.syncChatModelWithOracle()
        restrictMCPAgentDiscoveryToRoleLabels = settingsStore.restrictMCPAgentDiscoveryToRoleLabels()

        observeNotifications()
        refresh()
    }

    // MARK: - Public Derived Values

    var availability: AgentModelCatalog.AvailabilityContext {
        apiSettingsVM.agentModeAvailabilityContext
    }

    var hasConnectedCLIProvider: Bool {
        !AgentModelCatalog.selectableAgents(availability: availability).isEmpty
    }

    var currentOracleModelName: String {
        promptVM.planningModel.displayName
    }

    var currentBuiltinChatModelName: String {
        promptVM.preferredAIModel.displayName
    }

    var recommendedOracleModelName: String? {
        guard let rec = recommendations.chatModel,
              let option = rec.option(for: rec.defaultBackend) else { return nil }
        let model = option.modelString ?? ""
        if let resolved = AIModel.fromModelName(model) {
            return resolved.displayName
        }
        return option.displayName
    }

    var recommendedContextBuilderDescription: String? {
        guard let rec = recommendations.contextBuilder else { return nil }
        return "\(rec.recommendedAgent.displayName) · \(rec.recommendedModel.displayName)"
    }

    var isOracleRecommendationSatisfied: Bool {
        recommendations.chatModel?.alreadySatisfied ?? true
    }

    var isContextBuilderRecommendationSatisfied: Bool {
        recommendations.contextBuilder?.alreadySatisfied ?? true
    }

    var roleDefaultsResolutions: [MCPAgentRoleDefaultsService.RoleDefaultResolution] {
        MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            settingsStore: settingsStore
        )
    }

    var roleDefaultsHasOverrides: Bool {
        roleDefaultsResolutions.contains(where: \.hasCustomOverride)
    }

    var hasUnsatisfiedRecommendations: Bool {
        recommendations.hasUnsatisfied
    }

    // MARK: - Refresh

    /// Recompute the recommendation set.
    func refresh() {
        guard let workspaceID = promptVM.currentWorkspaceID else {
            recommendations = RecommendationSet()
            return
        }
        let raw = engine.computeRecommendations(for: workspaceID)
        recommendations = engine.applyMutedFlags(raw, workspaceID: workspaceID)
    }

    // MARK: - Destinations

    /// Destination for the Oracle model. Writes `planningModel` and, when the
    /// sync toggle is on, mirrors to `preferredComposeModel`.
    var oracleModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.oracle",
            getter: { [weak self] in
                self?.promptVM.planningModelName ?? ""
            },
            applier: { [weak self] rawValue in
                self?.setOracleModel(raw: rawValue)
            }
        )
    }

    /// Destination for the Built-in Chat model. Writes `preferredComposeModel`
    /// and, when the sync toggle is on, mirrors to `planningModel`.
    var builtinChatModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.builtinChat",
            getter: { [weak self] in
                self?.promptVM.preferredModel ?? ""
            },
            applier: { [weak self] rawValue in
                self?.setBuiltinChatModel(raw: rawValue)
            }
        )
    }

    // MARK: - Oracle / Built-in Chat setters

    func setOracleModel(raw: String) {
        promptVM.planningModelName = raw
        postShouldRefresh()
    }

    func setBuiltinChatModel(raw: String) {
        promptVM.preferredModel = raw
        postShouldRefresh()
    }

    // MARK: - Row-level Apply

    func applyOracleRecommendation() {
        guard let rec = recommendations.chatModel else { return }
        let backend = rec.defaultBackend
        guard let option = rec.option(for: backend), let model = option.modelString, !model.isEmpty else {
            return
        }
        setOracleModel(raw: model)
    }

    func applyContextBuilderRecommendation() {
        guard let rec = recommendations.contextBuilder,
              let workspaceID = promptVM.currentWorkspaceID else { return }
        engine.applyContextBuilderRecommendation(rec)
        notificationCenter.post(
            name: .recommendationsDidApply,
            object: nil,
            userInfo: ["workspaceID": workspaceID]
        )
    }

    func applyRoleDefault(_ resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution) {
        MCPAgentRoleDefaultsService.clearOverride(
            for: resolution.role,
            settingsStore: settingsStore
        )
        postAgentRoleDefaultsChanged()
    }

    func resetAllRoleDefaults() {
        MCPAgentRoleDefaultsService.clearAllOverrides(settingsStore: settingsStore)
        postAgentRoleDefaultsChanged()
    }

    func setRoleDefaultSelection(
        _ selection: AgentModelCatalog.NormalizedAgentSelection,
        for role: AgentModelCatalog.TaskLabelKind
    ) {
        _ = MCPAgentRoleDefaultsService.setSelection(
            selection,
            for: role,
            settingsStore: settingsStore
        )
        postAgentRoleDefaultsChanged()
    }

    // MARK: - Bulk Apply

    func applyAllRecommendations(includePresetExposure: Bool = false) {
        guard let workspaceID = promptVM.currentWorkspaceID else { return }
        isApplyingAll = true
        engine.applyModelRecommendations(
            recommendations,
            workspaceID: workspaceID,
            includePresetExposure: includePresetExposure
        )
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isApplyingAll = false
        }
    }

    // MARK: - Context Builder Menu

    func contextBuilderAgentModelMenuItems(windowID: Int) -> [StableMenuItem] {
        var items = promptVM.availableAgentKinds.map { agent in
            AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: promptVM.contextBuilderModelOptions(for: agent),
                selectedAgent: promptVM.contextBuilderAgent,
                selectedModelRaw: promptVM.contextBuilderAgentModelRaw
            ) { [weak self] selectedAgent, selectedOption in
                guard let self else { return }
                promptVM.contextBuilderAgent = selectedAgent
                promptVM.selectContextBuilderAgentModel(rawModel: selectedOption.rawValue)
                promptVM.commitContextBuilderSettings()
                refresh()
            }
        }
        AgentProviderSettingsMenuAction.appendStableMenuItem(
            to: &items,
            windowID: windowID,
            availableAgents: promptVM.availableAgentKinds
        )
        return items
    }

    func roleDefaultMenuItems(
        for resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution
    ) -> [StableMenuItem] {
        AgentModelCatalog.selectableAgents(availability: availability).map { agent in
            AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: AgentModelCatalog.options(for: agent, availability: availability),
                selectedAgent: resolution.effective.agent,
                selectedModelRaw: resolution.effective.modelRaw,
                includePlaceholderDefault: false,
                flattenSingleCodexGroups: true,
                groupOpenCode: false
            ) { [weak self] selectedAgent, selectedOption in
                guard let self else { return }
                let selection = AgentModelCatalog.NormalizedAgentSelection(
                    agent: selectedAgent,
                    modelRaw: selectedOption.rawValue
                )
                setRoleDefaultSelection(selection, for: resolution.role)
            }
        }
    }

    // MARK: - Private helpers

    private func observeNotifications() {
        notificationCenter.publisher(for: .recommendationsShouldRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .recommendationsDidApply)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func postShouldRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.notificationCenter.post(name: .recommendationsShouldRefresh, object: nil)
        }
    }

    private func postAgentRoleDefaultsChanged() {
        var userInfo: [String: Any] = [
            "reason": "agentRoleDefaultsChanged",
            "scope": "global"
        ]
        if let workspaceID = promptVM.currentWorkspaceID {
            userInfo["workspaceID"] = workspaceID
        }
        notificationCenter.post(
            name: .recommendationsShouldRefresh,
            object: nil,
            userInfo: userInfo
        )
        refresh()
    }
}
