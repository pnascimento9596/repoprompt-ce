@testable import RepoPrompt
import XCTest

final class AgentNavigationHUDSnapshotBuilderTests: XCTestCase {
    func testCurrentWindowItemsPreserveSidebarOrderAndIncludeChildren() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let root = UUID()
        let child = UUID()
        let other = UUID()
        let rows = [
            row(tabID: root, depth: 0, title: "Root"),
            row(tabID: child, depth: 1, title: "Child"),
            row(tabID: other, depth: 0, title: "Other")
        ]
        let attentionTime = Date(timeIntervalSince1970: 500)

        let items = AgentNavigationHUDSnapshotBuilder.currentWindowItems(
            rows: rows,
            currentTabID: child,
            windowID: 3,
            workspaceID: workspaceID,
            workspaceTitle: "Workspace",
            windowTitle: "Window",
            runStateByTabID: [child: .running],
            attentionRunStateByTabID: [other: .completed],
            attentionMarkedAtByTabID: [other: attentionTime]
        )

        XCTAssertEqual(items.map(\.tabID), [root, child, other])
        XCTAssertEqual(items.map(\.depth), [0, 1, 0])
        XCTAssertFalse(items[0].isActiveTab)
        XCTAssertTrue(items[1].isActiveTab)
        XCTAssertEqual(items[1].statusLabel, "Running")
        XCTAssertEqual(items[2].attentionMarkedAt, attentionTime)
        XCTAssertEqual(items[2].statusLabel, "Done")
    }

    func testCurrentWindowItemsRollUpSubagentCountsOntoRoot() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let root = UUID()
        let child = UUID()
        let grandchild = UUID()
        let other = UUID()
        let rows = [
            row(tabID: root, depth: 0, title: "Root"),
            row(tabID: child, depth: 1, title: "Child"),
            row(tabID: grandchild, depth: 2, title: "Grandchild"),
            row(tabID: other, depth: 0, title: "Other")
        ]

        let items = AgentNavigationHUDSnapshotBuilder.currentWindowItems(
            rows: rows,
            currentTabID: root,
            windowID: 3,
            workspaceID: workspaceID,
            workspaceTitle: "Workspace",
            windowTitle: "Window",
            attentionRunStateByTabID: [grandchild: .completed]
        )

        XCTAssertEqual(items[0].tabID, root)
        XCTAssertEqual(items[0].subagentCount, 2)
        XCTAssertEqual(items[0].subagentAttentionCount, 1)
        XCTAssertEqual(items[1].subagentCount, 0)
        XCTAssertEqual(items[2].displayDepth, 2)
        XCTAssertEqual(items[3].subagentCount, 0)
    }

    func testAllAgentsFilteringSortingAndCapAreDeterministic() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let now = Date(timeIntervalSince1970: 10000)
        let stale = item(
            tabID: UUID(),
            workspaceID: workspaceID,
            title: "Stale",
            activityDate: now.addingTimeInterval(-25 * 60 * 60),
            runState: .idle
        )
        let recent = item(
            tabID: UUID(),
            workspaceID: workspaceID,
            title: "Recent",
            activityDate: now.addingTimeInterval(-60),
            runState: .idle
        )
        let activeOlder = item(
            tabID: UUID(),
            workspaceID: workspaceID,
            title: "Active older",
            activityDate: now.addingTimeInterval(-90),
            runState: .waitingForApproval
        )
        let attentionNewest = item(
            tabID: UUID(),
            workspaceID: workspaceID,
            title: "Attention newest",
            activityDate: now.addingTimeInterval(-3 * 60 * 60),
            runState: .idle,
            attentionState: .failed,
            attentionMarkedAt: now
        )
        let filler = (0 ..< 60).map { index in
            item(
                tabID: UUID(),
                workspaceID: workspaceID,
                title: "Filler \(index)",
                activityDate: now.addingTimeInterval(TimeInterval(-120 - index)),
                runState: .idle
            )
        }

        let sorted = AgentNavigationHUDSnapshotBuilder.allAgentsSortedAndCapped(
            [stale, recent, activeOlder, attentionNewest] + filler,
            now: now
        )

        XCTAssertEqual(sorted.count, AgentNavigationHUDSnapshotBuilder.allAgentsCap)
        XCTAssertEqual(sorted.first?.title, "Attention newest")
        XCTAssertTrue(sorted.contains { $0.title == "Recent" })
        XCTAssertTrue(sorted.contains { $0.title == "Active older" })
        XCTAssertFalse(sorted.contains { $0.title == "Stale" })
    }

    func testAllAgentsSortedReturnsUncappedSearchCorpus() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let now = Date(timeIntervalSince1970: 10000)
        let items = (0 ..< 60).map { index in
            item(
                tabID: UUID(),
                workspaceID: workspaceID,
                title: "Searchable older session \(index)",
                activityDate: now.addingTimeInterval(TimeInterval(-120 - index)),
                runState: .idle
            )
        }

        let sorted = AgentNavigationHUDSnapshotBuilder.allAgentsSorted(items, now: now)

        XCTAssertGreaterThan(sorted.count, AgentNavigationHUDSnapshotBuilder.allAgentsCap)
        XCTAssertTrue(sorted.contains { $0.title == "Searchable older session 59" })
    }

    func testSearchTokensSplitWhitespaceAndPreserveQuotedPhrases() {
        XCTAssertEqual(AgentNavigationHUDViewModel.searchTokens(in: "sidebar running"), ["sidebar", "running"])
        XCTAssertEqual(AgentNavigationHUDViewModel.searchTokens(in: "workspace \"review branch\""), ["workspace", "review branch"])
        XCTAssertEqual(AgentNavigationHUDViewModel.searchTokens(in: "  \"unterminated phrase  "), ["unterminated phrase"])
    }

    private func row(tabID: UUID, depth: Int, title: String) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: title,
            lastUserMessageAt: nil,
            activityDate: Date(timeIntervalSince1970: 100),
            isPinned: false,
            sessionID: tabID,
            parentSessionID: nil,
            depth: depth,
            isMCPControlled: false,
            worktree: nil,
            worktreeMergeAttention: nil,
            threadKey: nil,
            hasThreadChildren: false,
            isThreadCollapsed: false,
            hiddenThreadDescendantCount: 0,
            hiddenThreadDescendantAttentionCount: 0,
            threadActivityDate: nil
        )
    }

    private func item(
        tabID: UUID,
        workspaceID: UUID,
        title: String,
        activityDate: Date,
        runState: AgentSessionRunState?,
        attentionState: AgentSessionRunState? = nil,
        attentionMarkedAt: Date? = nil
    ) -> AgentNavigationHUDItem {
        AgentNavigationHUDItem(
            windowID: 1,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: tabID,
            title: title,
            workspaceTitle: "Workspace",
            windowTitle: "Window",
            parentSessionID: nil,
            depth: 0,
            subagentCount: 0,
            subagentAttentionCount: 0,
            isActiveTab: false,
            runState: runState,
            attentionState: attentionState,
            attentionMarkedAt: attentionMarkedAt,
            activityDate: activityDate,
            worktree: nil,
            worktreeLabel: nil,
            mergeAttention: nil,
            mergeLabel: nil,
            isMCPControlled: false
        )
    }
}
