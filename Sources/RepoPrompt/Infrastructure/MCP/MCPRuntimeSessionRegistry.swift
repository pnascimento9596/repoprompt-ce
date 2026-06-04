import Foundation

/// Transitional MCP routing projection for the app's window-backed runtime sessions.
/// Window IDs remain the compatibility routing IDs until the reusable core session graph lands.
@MainActor
final class MCPRuntimeSessionRegistry {
    enum Lifecycle {
        case active
        case draining
    }

    struct RoutingSnapshot: Sendable {
        let generation: UInt64
        let orderedActiveWindowIDs: [Int]
        let mcpEnabledWindowIDs: Set<Int>

        var activeWindowCount: Int {
            orderedActiveWindowIDs.count
        }

        var isMultiWindowModeEffectivelyActive: Bool {
            activeWindowCount > 1
        }

        var firstMCPEnabledWindowID: Int? {
            orderedActiveWindowIDs.first { mcpEnabledWindowIDs.contains($0) }
        }

        func hasActiveWindow(_ windowID: Int) -> Bool {
            orderedActiveWindowIDs.contains(windowID)
        }

        func hasMCPEnabledWindow(_ windowID: Int) -> Bool {
            hasActiveWindow(windowID) && mcpEnabledWindowIDs.contains(windowID)
        }
    }

    private final class Entry {
        let windowID: Int
        weak var windowState: WindowState?
        var lifecycle: Lifecycle
        var isMCPEnabled: Bool

        init(windowState: WindowState, isMCPEnabled: Bool) {
            windowID = windowState.windowID
            self.windowState = windowState
            lifecycle = .active
            self.isMCPEnabled = isMCPEnabled
        }
    }

    private var entriesByID: [Int: Entry] = [:]
    private var orderedIDs: [Int] = []
    private var pendingEnabledByUnknownID: [Int: Bool] = [:]
    private var retiredIDs: Set<Int> = []
    private var generation: UInt64 = 0

    nonisolated init() {}

    func register(windowState: WindowState) {
        let windowID = windowState.windowID
        guard !retiredIDs.contains(windowID) else { return }
        if let existing = entriesByID[windowID] {
            existing.windowState = windowState
            existing.lifecycle = .active
            existing.isMCPEnabled = pendingEnabledByUnknownID.removeValue(forKey: windowID)
                ?? windowState.mcpServer.windowToolsEnabled
            generation &+= 1
            return
        }

        let isEnabled = pendingEnabledByUnknownID.removeValue(forKey: windowID)
            ?? windowState.mcpServer.windowToolsEnabled
        entriesByID[windowID] = Entry(windowState: windowState, isMCPEnabled: isEnabled)
        orderedIDs.append(windowID)
        generation &+= 1
    }

    func setMCPEnabled(windowID: Int, enabled: Bool) {
        if retiredIDs.contains(windowID) {
            return
        }
        guard let entry = entriesByID[windowID] else {
            pendingEnabledByUnknownID[windowID] = enabled
            return
        }
        if entry.lifecycle == .draining, enabled {
            return
        }
        guard entry.isMCPEnabled != enabled else { return }
        entry.isMCPEnabled = enabled
        generation &+= 1
    }

    func beginDraining(windowID: Int) {
        guard let entry = entriesByID[windowID], entry.lifecycle == .active else { return }
        entry.lifecycle = .draining
        entry.isMCPEnabled = false
        generation &+= 1
    }

    func remove(windowID: Int) {
        if entriesByID.removeValue(forKey: windowID) != nil {
            orderedIDs.removeAll { $0 == windowID }
            generation &+= 1
        }
        pendingEnabledByUnknownID.removeValue(forKey: windowID)
        retiredIDs.insert(windowID)
    }

    func routingSnapshot() -> RoutingSnapshot {
        let activeIDs = orderedIDs.filter { windowID in
            guard let entry = entriesByID[windowID],
                  entry.lifecycle == .active,
                  entry.windowState != nil
            else {
                return false
            }
            return true
        }
        let enabledIDs = Set(activeIDs.filter { entriesByID[$0]?.isMCPEnabled == true })
        return RoutingSnapshot(
            generation: generation,
            orderedActiveWindowIDs: activeIDs,
            mcpEnabledWindowIDs: enabledIDs
        )
    }

    func window(withID windowID: Int, includeDraining: Bool = false) -> WindowState? {
        guard let entry = entriesByID[windowID],
              includeDraining || entry.lifecycle == .active
        else {
            return nil
        }
        return entry.windowState
    }

    func windowStates(includeDraining: Bool = false) -> [WindowState] {
        orderedIDs.compactMap { window(withID: $0, includeDraining: includeDraining) }
    }

    func hasActiveWindow(id windowID: Int) -> Bool {
        window(withID: windowID) != nil
    }

    func hasMCPEnabledWindow(id windowID: Int) -> Bool {
        guard let entry = entriesByID[windowID],
              entry.lifecycle == .active,
              entry.isMCPEnabled,
              entry.windowState != nil
        else {
            return false
        }
        return true
    }

    func isInvocationAllowed(windowID: Int) -> Bool {
        hasMCPEnabledWindow(id: windowID)
    }

    #if DEBUG
        func debugIsRetired(windowID: Int) -> Bool {
            retiredIDs.contains(windowID)
        }
    #endif
}
