import Foundation
import JSONSchema
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPRuntimeSessionRegistryTests: XCTestCase {
    func testPendingEnableInsertionOrderDrainingAndRetirement() {
        let registry = MCPRuntimeSessionRegistry()
        let first = Self.makeWindowWithoutAutoStart()
        let second = Self.makeWindowWithoutAutoStart()
        defer {
            let sharedRegistry = ServerNetworkManager.shared.runtimeSessionRegistry
            sharedRegistry.remove(windowID: first.windowID)
            sharedRegistry.remove(windowID: second.windowID)
        }

        registry.setMCPEnabled(windowID: first.windowID, enabled: true)
        registry.register(windowState: first)
        registry.register(windowState: second)
        registry.setMCPEnabled(windowID: second.windowID, enabled: true)

        var snapshot = registry.routingSnapshot()
        XCTAssertEqual(snapshot.orderedActiveWindowIDs, [first.windowID, second.windowID])
        XCTAssertEqual(snapshot.firstMCPEnabledWindowID, first.windowID)
        XCTAssertTrue(snapshot.isMultiWindowModeEffectivelyActive)

        registry.beginDraining(windowID: first.windowID)
        snapshot = registry.routingSnapshot()
        XCTAssertEqual(snapshot.orderedActiveWindowIDs, [second.windowID])
        XCTAssertEqual(snapshot.firstMCPEnabledWindowID, second.windowID)
        XCTAssertFalse(registry.isInvocationAllowed(windowID: first.windowID))

        registry.remove(windowID: first.windowID)
        registry.setMCPEnabled(windowID: first.windowID, enabled: true)
        registry.register(windowState: first)
        XCTAssertFalse(registry.hasActiveWindow(id: first.windowID))
        #if DEBUG
            XCTAssertTrue(registry.debugIsRetired(windowID: first.windowID))
        #endif
    }

    private static func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }
}

@MainActor
final class MCPServiceRegistryTests: XCTestCase {
    func testRegistriesAreInstanceOwnedAndIndexCanonicalNames() async {
        let firstRegistry = MCPServiceRegistry()
        let secondRegistry = MCPServiceRegistry()
        let service = StaticToolService(tools: [Self.makeTool(name: "discover_prompt")])

        firstRegistry.register(service)
        let firstSnapshot = await firstRegistry.awaitCurrentSnapshot()
        let secondSnapshot = secondRegistry.routeSnapshot()

        XCTAssertEqual(firstSnapshot.routes(forCanonicalName: "prompt").map(\.tool.name), ["discover_prompt"])
        XCTAssertTrue(secondSnapshot.orderedRoutes.isEmpty)
    }

    func testUnregisterSynchronouslyFiltersCommittedRoutes() async {
        let registry = MCPServiceRegistry()
        let service = StaticToolService(tools: [Self.makeTool(name: "read_file")])

        registry.register(service)
        _ = await registry.awaitCurrentSnapshot()
        XCTAssertEqual(registry.routeSnapshot().routes(forCanonicalName: "read_file").count, 1)

        registry.unregister(service)
        XCTAssertTrue(registry.routeSnapshot().routes(forCanonicalName: "read_file").isEmpty)
    }

    func testRegistrySourceKeepsGenerationGate() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("guard generation == requestedGeneration else { continue }"))
        XCTAssertTrue(source.contains("routesByCanonicalName[canonicalName, default: []].append(route)"))
        XCTAssertTrue(source.contains("committedSnapshot.orderedRoutes.filter { $0.serviceIdentity != serviceIdentity }"))
    }

    private static func makeTool(name: String) -> Tool {
        Tool(
            name: name,
            description: "test",
            inputSchema: .object(properties: [:])
        ) { _ in
            ["ok": true]
        }
    }
}

private final class StaticToolService: Service {
    let storedTools: [Tool]

    init(tools: [Tool]) {
        storedTools = tools
    }

    var tools: [Tool] {
        get async { storedTools }
    }
}
