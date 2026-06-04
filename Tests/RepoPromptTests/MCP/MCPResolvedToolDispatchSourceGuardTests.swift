import Foundation
@testable import RepoPrompt
import XCTest

final class MCPResolvedToolDispatchSourceGuardTests: XCTestCase {
    func testOrdinaryCallToolHandlerInvokesResolvedToolDirectlyInBothDispatchBranches() throws {
        let source = try String(
            contentsOf: RepoRoot.url()
                .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift"),
            encoding: .utf8
        )
        let callToolHandler = try XCTUnwrap(source.slice(
            from: "        await server.withMethodHandler(CallTool.self) { [weak self] params in\n",
            to: "    /// Update the enabled state and notify clients\n"
        ))

        XCTAssertEqual(callToolHandler.occurrenceCount(of: "await service.tools"), 0)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "for indexedRoute in indexedTools.routes(forCanonicalName: toolName)"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "let toolDef = indexedRoute.tool"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "let selectedSchemaDeclaresWindowID ="), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "routingWindowID != nil"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "capturedArguments[\"window_id\"] == nil"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "capturedArgsForFormatter[\"window_id\"] == nil"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "self.schemaDeclaresWindowID(schema: toolDef.inputSchema)"), 1)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "schemaDeclaresWindowID: selectedSchemaDeclaresWindowID"), 2)
        XCTAssertEqual(callToolHandler.occurrenceCount(of: "try await toolDef.callAsFunction(effectiveArgs)"), 2)
        XCTAssertFalse(callToolHandler.contains("service.call("))
        XCTAssertTrue(callToolHandler.contains("if let wsSvc, shouldTrackToolOwnership"))
        XCTAssertTrue(callToolHandler.contains("// Not window-scoped → no ownership tracking needed"))
    }

    func testOrdinaryCallToolHandlerPreservesWindowRoutingPriorityBeforeInvocation() throws {
        let source = try String(
            contentsOf: RepoRoot.url()
                .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift"),
            encoding: .utf8
        )
        let callToolHandler = try XCTUnwrap(source.slice(
            from: "        await server.withMethodHandler(CallTool.self) { [weak self] params in\n",
            to: "    /// Update the enabled state and notify clients\n"
        ))

        try assertMarkersAppearInOrder([
            "// PRIORITY 0: _windowID is a strong per-call override",
            "if !bypassWindowRouting, let requestedWindowID = capturedWindowID {",
            "// PRIORITY 1: Use existing connection mapping (no override requested)",
            "if !bypassWindowRouting, chosenID == nil, let mapped = existingMapping {",
            "// PRIORITY 2: Use clientName to find existing window assignment (for same client, new connection)",
            "let windowID = await self.reusableWindowForClient(newConnectionID: connectionID, clientName: clientName)",
            "// PRIORITY 2b: Same-process live run affinity, then persisted window affinity.",
            "if let liveAffinity = await self.preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey),",
            "} else if let preferredWindowID = await self.preferredWindowID(for: clientName, sessionKey: sessionKey),",
            "// PRIORITY 3: Auto-route to active window when:",
            "if !bypassWindowRouting && chosenID == nil && (!multiWindowModeEffective || connectedDuringSingleWindow) {",
            "let activeWindowID = runtimeSessions.firstMCPEnabledWindowID",
            "// Only require explicit window selection when multi-window mode is effectively active.",
            "multiWindowModeEffective,",
            "chosenID == nil,",
            "message: Self.multiWindowSelectionGuidance(",
            "// Run-scoped tab rebind fallback on reconnect handovers",
            "// Legacy compatibility: sticky tab binding via hidden _tabID for unmigrated tools only",
            "@Sendable func dispatchResolvedProvider"
        ], in: callToolHandler)
        XCTAssertFalse(callToolHandler.contains("WindowStatesManager.shared"))
        XCTAssertFalse(callToolHandler.contains("ServiceRegistry.services"))
    }

    private func assertMarkersAppearInOrder(
        _ markers: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var cursor = source.startIndex
        for marker in markers {
            let remaining = cursor ..< source.endIndex
            let range = try XCTUnwrap(
                source.range(of: marker, range: remaining),
                "Missing or out-of-order routing marker: \(marker)",
                file: file,
                line: line
            )
            cursor = range.upperBound
        }
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let startRange = range(of: startMarker),
              let endRange = range(of: endMarker, range: startRange.upperBound ..< endIndex)
        else {
            return nil
        }
        return String(self[startRange.lowerBound ..< endRange.lowerBound])
    }

    func occurrenceCount(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
