@testable import RepoPrompt
import XCTest

@MainActor
final class AgentSessionSidebarUIStoreTests: XCTestCase {
    func testAttentionTimestampsAreDeterministicAndPreserveDuplicateMarks() {
        let store = AgentSessionSidebarUIStore()
        let tabID = UUID()
        let first = Date(timeIntervalSince1970: 100)
        let duplicate = Date(timeIntervalSince1970: 200)
        let changed = Date(timeIntervalSince1970: 300)

        XCTAssertTrue(store.markRunStateAttention(tabID: tabID, state: .completed, markedAt: first))
        XCTAssertEqual(store.attentionRunState(for: tabID), .completed)
        XCTAssertEqual(store.attentionMarkedAt(for: tabID), first)

        XCTAssertFalse(store.markRunStateAttention(tabID: tabID, state: .completed, markedAt: duplicate))
        XCTAssertEqual(store.attentionMarkedAt(for: tabID), first)

        XCTAssertTrue(store.markRunStateAttention(tabID: tabID, state: .failed, markedAt: changed))
        XCTAssertEqual(store.attentionRunState(for: tabID), .failed)
        XCTAssertEqual(store.attentionMarkedAt(for: tabID), changed)
    }

    func testAttentionClearPathsRemoveTimestamps() {
        let store = AgentSessionSidebarUIStore()
        let firstTab = UUID()
        let secondTab = UUID()
        let markedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(store.markRunStateAttention(tabID: firstTab, state: .completed, markedAt: markedAt))
        XCTAssertTrue(store.markRunStateAttention(tabID: secondTab, state: .waitingForUser, markedAt: markedAt))

        XCTAssertTrue(store.clearRunStateAttention(tabID: firstTab))
        XCTAssertNil(store.attentionRunState(for: firstTab))
        XCTAssertNil(store.attentionMarkedAt(for: firstTab))
        XCTAssertEqual(store.attentionMarkedAt(for: secondTab), markedAt)

        XCTAssertTrue(store.clearRunStateAttention(for: [secondTab]))
        XCTAssertNil(store.attentionRunState(for: secondTab))
        XCTAssertNil(store.attentionMarkedAt(for: secondTab))
    }

    func testIneligibleAttentionDoesNotStoreTimestamp() {
        let store = AgentSessionSidebarUIStore()
        let tabID = UUID()

        XCTAssertFalse(store.markRunStateAttention(tabID: tabID, state: .running, markedAt: Date()))
        XCTAssertNil(store.attentionRunState(for: tabID))
        XCTAssertNil(store.attentionMarkedAt(for: tabID))
    }
}
