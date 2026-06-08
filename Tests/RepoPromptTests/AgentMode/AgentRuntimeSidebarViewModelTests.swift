import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRuntimeSidebarViewModelTests: XCTestCase {
    func testStaleLiveZeroDoesNotMaskNewerManageSelectionCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: 0,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 0)

        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)
    }

    func testUnavailableSelectionCountDoesNotReusePreviousContextCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertNil(store.runtimeVM.snapshot.selectionFileCount)
    }

    func testNewerManageSelectionWinsOverOlderWorkspaceContextSelectionCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let olderWorkspaceContext = try makeWorkspaceContextItem(
            fileCount: 0,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let newerManageSelection = try makeManageSelectionItem(
            fileCount: 8,
            timestamp: Date(timeIntervalSince1970: 200)
        )

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(
                latestWorkspaceContextItem: olderWorkspaceContext,
                latestManageSelectionItem: newerManageSelection
            ),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 8)
        XCTAssertEqual(store.runtimeVM.snapshot.selectionTokens, 80)
    }

    func testFreshLiveZeroRemainsAuthoritativeAfterToolDerivedCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        let snapshot = AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem)
        store.update(
            transcriptSnapshot: snapshot,
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)

        store.update(
            transcriptSnapshot: snapshot,
            codexUsage: nil,
            liveSelectedFileCount: 0,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 0)
    }

    private func makeManageSelectionItem(fileCount: Int, timestamp: Date = Date()) throws -> AgentChatItem {
        let files = makeSelectedFiles(fileCount: fileCount)
        let reply = ToolResultDTOs.SelectionReply(
            files: files,
            totalTokens: fileCount * 10,
            status: "Selection • add • \(fileCount) files"
        )
        let data = try JSONEncoder().encode(reply)
        let json = String(decoding: data, as: UTF8.self)
        return AgentChatItem(
            timestamp: timestamp,
            kind: .toolResult,
            text: json,
            toolName: "manage_selection",
            toolResultJSON: json
        )
    }

    private func makeWorkspaceContextItem(fileCount: Int, timestamp: Date = Date()) throws -> AgentChatItem {
        let files = makeSelectedFiles(fileCount: fileCount)
        let selection = ToolResultDTOs.SelectedFilesReply(
            files: files,
            totalTokens: fileCount * 10,
            fileSlices: nil,
            summary: nil
        )
        let reply = ToolResultDTOs.PromptContextDTO(
            prompt: "",
            selection: selection,
            fileBlocks: nil,
            codeStructure: nil,
            fileTree: nil,
            tokenStats: nil,
            userTokenStats: nil,
            tokenStatsNote: nil,
            copyPreset: nil,
            copyPresets: nil
        )
        let data = try JSONEncoder().encode(reply)
        let json = String(decoding: data, as: UTF8.self)
        return AgentChatItem(
            timestamp: timestamp,
            kind: .toolResult,
            text: json,
            toolName: "workspace_context",
            toolResultJSON: json
        )
    }

    private func makeSelectedFiles(fileCount: Int) -> [ToolResultDTOs.SelectedFileInfo] {
        (0 ..< fileCount).map { index in
            ToolResultDTOs.SelectedFileInfo(
                path: "Sources/File\(index).swift",
                tokens: 10,
                renderMode: "full",
                ranges: nil,
                isAuto: false,
                codemapOrigin: nil,
                copyPreset: nil
            )
        }
    }
}
