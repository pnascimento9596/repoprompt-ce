import Foundation

@MainActor
final class ContextBuilderRouteSettlementCoordinator {
    enum Settlement: Equatable {
        case routed
        case completedWithoutRoute
        case failedWithoutRoute(String)
        case routingOwnershipLost
        case cancelled
    }

    struct BufferedEvents {
        let events: [AIStreamResult]
        let droppedTextCharacterCount: Int
        let droppedNonterminalEventCount: Int
    }

    private let maxBufferedTextCharacters: Int
    private let maxBufferedEventCount: Int
    private var bufferedEvents: [AIStreamResult] = []
    private var bufferedTextCharacterCount = 0
    private var droppedTextCharacterCount = 0
    private var droppedNonterminalEventCount = 0
    private var settlement: Settlement?
    private var settlementContinuation: CheckedContinuation<Settlement, Never>?

    init(maxBufferedTextCharacters: Int, maxBufferedEventCount: Int) {
        self.maxBufferedTextCharacters = max(0, maxBufferedTextCharacters)
        self.maxBufferedEventCount = max(0, maxBufferedEventCount)
    }

    var isPending: Bool {
        settlement == nil
    }

    var isRouted: Bool {
        settlement == .routed
    }

    @discardableResult
    func settle(_ candidate: Settlement) -> Bool {
        guard settlement == nil else { return false }
        settlement = candidate
        settlementContinuation?.resume(returning: candidate)
        settlementContinuation = nil
        return true
    }

    func waitForSettlement() async -> Settlement {
        if let settlement {
            return settlement
        }
        precondition(
            settlementContinuation == nil,
            "ContextBuilderRouteSettlementCoordinator supports exactly one settlement waiter."
        )
        return await withCheckedContinuation { continuation in
            if let settlement {
                continuation.resume(returning: settlement)
            } else {
                settlementContinuation = continuation
            }
        }
    }

    func appendWhilePending(_ event: AIStreamResult) {
        guard settlement == nil else { return }

        if isCoalescibleProgressEvent(event),
           let existingIndex = bufferedEvents.lastIndex(where: {
               $0.type == event.type && isCoalescibleProgressEvent($0)
           })
        {
            removeBufferedEvent(at: existingIndex, countsAsDroppedNonterminal: true)
        }

        bufferedEvents.append(event)
        if event.type == "content" {
            bufferedTextCharacterCount += event.text?.count ?? 0
            trimOldestTextIfNeeded()
        }
        trimRedundantNonterminalEventsIfNeeded()
    }

    func drainBufferedEvents() -> BufferedEvents {
        let result = BufferedEvents(
            events: bufferedEvents,
            droppedTextCharacterCount: droppedTextCharacterCount,
            droppedNonterminalEventCount: droppedNonterminalEventCount
        )
        bufferedEvents.removeAll(keepingCapacity: false)
        bufferedTextCharacterCount = 0
        droppedTextCharacterCount = 0
        droppedNonterminalEventCount = 0
        return result
    }

    private func trimOldestTextIfNeeded() {
        while bufferedTextCharacterCount > maxBufferedTextCharacters,
              let index = bufferedEvents.firstIndex(where: { $0.type == "content" })
        {
            removeBufferedEvent(at: index, countsAsDroppedNonterminal: false)
        }
    }

    private func trimRedundantNonterminalEventsIfNeeded() {
        while bufferedEvents.count > maxBufferedEventCount,
              let index = bufferedEvents.firstIndex(where: isRedundantNonterminalEvent)
        {
            removeBufferedEvent(at: index, countsAsDroppedNonterminal: true)
        }
    }

    private func removeBufferedEvent(at index: Int, countsAsDroppedNonterminal: Bool) {
        let removed = bufferedEvents.remove(at: index)
        if removed.type == "content" {
            let removedCount = removed.text?.count ?? 0
            bufferedTextCharacterCount -= removedCount
            droppedTextCharacterCount += removedCount
        }
        if countsAsDroppedNonterminal {
            droppedNonterminalEventCount += 1
        }
    }

    private func isCoalescibleProgressEvent(_ event: AIStreamResult) -> Bool {
        switch event.type {
        case AIStreamResult.lifecycleType, "event", "status":
            true
        default:
            false
        }
    }

    private func isRedundantNonterminalEvent(_ event: AIStreamResult) -> Bool {
        isCoalescibleProgressEvent(event)
            || event.type == "content" && (event.text?.isEmpty ?? true)
    }
}
