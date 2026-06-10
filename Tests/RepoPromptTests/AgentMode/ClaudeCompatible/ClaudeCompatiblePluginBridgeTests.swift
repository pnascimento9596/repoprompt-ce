import Foundation
@testable import RepoPrompt
import XCTest

final class ClaudeCompatiblePluginBridgeTests: XCTestCase {
    func testOnlyBridgeImportsProviderPackage() throws {
        let repoRoot = try RepoRoot.url()
        let sourcesRoot = repoRoot.appendingPathComponent("Sources/RepoPrompt", isDirectory: true)
        let expected = "Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift"
        let imports = try sourceFilesImportingProviderPackage(under: sourcesRoot, repoRoot: repoRoot)

        XCTAssertEqual(imports, [expected])
    }

    func testBridgeRuntimeSmokeMapsPluginIDsDiscoveryRuntimeAndHeadlessAdapters() throws {
        let cases: [(AgentProviderKind, String)] = [
            (.claudeCode, "claude-code"),
            (.claudeCodeGLM, "zai-claude-code"),
            (.kimiCode, "kimi-claude-code"),
            (.customClaudeCompatible, "custom-claude-compatible")
        ]

        for (agentKind, expectedPluginID) in cases {
            XCTAssertEqual(ClaudeCompatiblePluginBridge.pluginID(for: agentKind)?.rawValue, expectedPluginID)
            XCTAssertEqual(try ClaudeCompatiblePluginBridge.agentKind(for: XCTUnwrap(ClaudeCompatiblePluginBridge.pluginID(for: agentKind))), agentKind)

            let provider = AgentRuntimeProviderService.shared.makeProvider(
                for: agentKind,
                modelString: "sonnet"
            )
            let adapter = try XCTUnwrap(provider as? ClaudeCompatibleHeadlessProviderAdapter)
            XCTAssertEqual(adapter.runtimeConfig.pluginID.rawValue, expectedPluginID)
            XCTAssertEqual(adapter.runtimeConfig.mode.rawValue, "discovery")
            XCTAssertEqual(adapter.runtimeConfig.commandName, "claude")
            XCTAssertEqual(adapter.runtimeConfig.modelString, "sonnet")
        }
        XCTAssertNil(ClaudeCompatiblePluginBridge.pluginID(for: .codexExec))

        let config = try XCTUnwrap(ClaudeCompatiblePluginBridge.discoveryRuntimeConfig(
            agentKind: .claudeCodeGLM,
            modelString: "sonnet",
            enableDebugLogging: true
        ))
        XCTAssertEqual(config.pluginID.rawValue, "zai-claude-code")
        XCTAssertEqual(config.mode.rawValue, "discovery")
        XCTAssertEqual(config.commandName, "claude")
        XCTAssertEqual(config.permissionMode, "bypassPermissions")
        XCTAssertFalse(config.allowNativeBashTool)
        XCTAssertEqual(config.toolContext.rawValue, "discoverRun")
        XCTAssertTrue(config.mcpStrictMode)
        XCTAssertFalse(config.toolSearchEnabled)
        XCTAssertEqual(config.backendConfig?.id.rawValue, "glmZAI")
    }

    func testRootBridgeCatalogRawValueSmokeIsNonMutating() throws {
        XCTAssertEqual(ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: .glmZAI), AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: .kimi), AgentModel.kimiCode.rawValue)
        XCTAssertEqual(ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: .custom), AgentModel.customClaudeCompatible.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.defaultRequestedModelRawValue, AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.haikuRequestedModelRawValue, AgentModel.claudeHaiku.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.opusRequestedModelRawValue, AgentModel.claudeOpus.rawValue)

        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true)
        let snapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .claudeCode,
            availability: availability,
            includeClaudeEffortVariants: false
        ))
        XCTAssertEqual(snapshot.pluginID.rawValue, "claude-code")
        XCTAssertEqual(snapshot.defaultModelRaw, "opus")
        XCTAssertEqual(snapshot.options.first?.rawValue, "default")
        XCTAssertEqual(snapshot.options.first?.isPlaceholderDefault, true)
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "fable" && $0.supportedEffortLevels.contains("xhigh") })
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "claude-fable-5" && $0.supportedEffortLevels.contains("xhigh") })
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "opus" && $0.supportedEffortLevels.contains("xhigh") })
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "claude-opus-4-8" && $0.supportedEffortLevels.contains("xhigh") })

        let options = AgentModelCatalog.options(for: .claudeCode, availability: availability)
        let menu = AgentModelCatalog.claudeMenu(for: options, agentKind: .claudeCode)
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .claudeCode, availability: availability), "opus")
        XCTAssertEqual(menu.defaultOption?.rawValue, "default")
        let groupRaws = Set(menu.groups.map(\.baseModelRaw))
        XCTAssertTrue(groupRaws.contains("fable"))
        XCTAssertTrue(groupRaws.contains("claude-fable-5"))
        XCTAssertTrue(groupRaws.contains("opus[1m]"))
        XCTAssertTrue(groupRaws.contains("opus"))
        XCTAssertTrue(groupRaws.contains("claude-opus-4-8"))
        XCTAssertTrue(groupRaws.contains("sonnet"))
        XCTAssertEqual(Array(AgentModel.modelsForAgent(.claudeCode).map(\.rawValue).prefix(7)), [
            "default",
            "fable",
            "claude-fable-5",
            "opus[1m]",
            "opus",
            "claude-opus-4-8",
            "claude-opus-4-7"
        ])
        XCTAssertEqual(
            AgentModelCatalog.supportedClaudeEfforts(forSelectedModelRaw: "fable", agentKind: .claudeCode),
            [.low, .medium, .high, .max, .xhigh]
        )
        XCTAssertNil(AgentModel.claudeFable.contextWindowTokens)
        XCTAssertEqual(AgentModel.claudeFable.contextWindowTokens(for: .claudeCode), 1_000_000)
        XCTAssertEqual(AgentModel.claudeFable5.contextWindowTokens, 1_000_000)
        XCTAssertNil(AgentModel.claudeOpus.contextWindowTokens)
        XCTAssertEqual(AgentModel.claudeOpus.contextWindowTokens(for: .claudeCode), 1_000_000)
        XCTAssertNil(AgentModel.claudeOpus.contextWindowTokens(for: .claudeCodeGLM))
        XCTAssertEqual(AgentModel.claudeOpus48.contextWindowTokens, 1_000_000)

        let discovery = try XCTUnwrap(AgentModelCatalog.discoveryAgents(availability: availability).first { $0.agent == .claudeCode })
        XCTAssertEqual(discovery.defaults.modelRaw, "opus")
        XCTAssertEqual(discovery.defaults.selectionID?.rawValue, "claudeCode:opus")
        XCTAssertEqual(discovery.runtime, "claude_native")
        XCTAssertTrue(discovery.models.contains { $0.id == "default" })
        XCTAssertTrue(discovery.models.contains { $0.id == "opus" })
        let fableDiscovery = try XCTUnwrap(discovery.models.first { $0.id == "fable" })
        XCTAssertEqual(fableDiscovery.contextWindowTokens, 1_000_000)
        XCTAssertTrue(fableDiscovery.startTargets.contains { $0.modelRaw == "fable:xhigh" })

        let compatibleAvailability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true, zaiConfigured: true)
        let glmDiscovery = try XCTUnwrap(
            AgentModelCatalog.discoveryAgents(availability: compatibleAvailability).first { $0.agent == .claudeCodeGLM }
        )
        let glmOpusDiscovery = try XCTUnwrap(glmDiscovery.models.first { $0.id == "opus" })
        XCTAssertNil(glmOpusDiscovery.contextWindowTokens)
        XCTAssertTrue(glmOpusDiscovery.startTargets.allSatisfy { $0.contextWindowTokens == nil })

        let compatiblePluginOptions = [
            ClaudeCompatiblePluginModelOption(
                rawValue: AgentModel.claudeSonnet.rawValue,
                displayName: "GLM Sonnet",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true,
                supportedEffortLevels: ["low", "medium", "high", "max"]
            ),
            ClaudeCompatiblePluginModelOption(
                rawValue: AgentModel.kimiCode.rawValue,
                displayName: "Kimi Code",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true,
                supportedEffortLevels: []
            ),
            ClaudeCompatiblePluginModelOption(
                rawValue: AgentModel.customClaudeCompatible.rawValue,
                displayName: "CC Custom",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true,
                supportedEffortLevels: []
            )
        ]
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.modelOptions(from: [compatiblePluginOptions[0]], for: .claudeCodeGLM).map(\.rawValue),
            [AgentModel.claudeSonnet.rawValue]
        )
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.modelOptions(from: [compatiblePluginOptions[1]], for: .kimiCode).map(\.rawValue),
            [AgentModel.kimiCode.rawValue]
        )
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.modelOptions(from: [compatiblePluginOptions[2]], for: .customClaudeCompatible).map(\.rawValue),
            [AgentModel.customClaudeCompatible.rawValue]
        )
    }

    private func sourceFilesImportingProviderPackage(
        under sourcesRoot: URL,
        repoRoot: URL
    ) throws -> [String] {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var imports: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard contents.contains("import RepoPromptClaudeCompatibleProvider") else { continue }
            imports.append(RepoRoot.relativePath(for: url, relativeTo: repoRoot))
        }
        return imports.sorted()
    }
}
