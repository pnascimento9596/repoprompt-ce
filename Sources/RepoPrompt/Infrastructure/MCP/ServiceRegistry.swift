//
//  ServiceRegistry.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//

/// Instance-owned registry for MCP tool providers. Mutable state stays on the main actor;
/// consumers receive immutable snapshots so request hot paths never scan service catalogs.
@MainActor
final class MCPServiceRegistry {
    enum Scope: Equatable {
        case host
        case window(Int)
    }

    enum Role {
        case ordinary
        case contextRouting
        case appSettings
    }

    /// Immutable after publication. Service identity is retained only for transitional diagnostics
    /// and final registration validation while Item 2 remains in the monolithic app target.
    struct IndexedToolRoute: @unchecked Sendable {
        let serviceIdentity: ObjectIdentifier
        let service: any Service
        let scope: Scope
        let role: Role
        let tool: Tool
    }

    /// Immutable generation-fenced route catalog safe to hand from MainActor to connection actors.
    struct Snapshot: @unchecked Sendable {
        let generation: UInt64
        let orderedRoutes: [IndexedToolRoute]
        let routesByCanonicalName: [String: [IndexedToolRoute]]

        func routes(forCanonicalName name: String) -> [IndexedToolRoute] {
            routesByCanonicalName[name] ?? []
        }
    }

    private var registeredServices: [any Service] = []
    private var requestedGeneration: UInt64 = 0
    private var snapshotNeedsRebuild = false
    private var committedSnapshot = Snapshot(generation: 0, orderedRoutes: [], routesByCanonicalName: [:])
    private var snapshotDidChangeSink: (@Sendable () async -> Void)?
    private var hasPendingSnapshotChangeNotification = false

    nonisolated init() {}

    var services: [any Service] {
        registeredServices
    }

    func setSnapshotDidChangeSink(_ sink: @escaping @Sendable () async -> Void) {
        snapshotDidChangeSink = sink
        guard hasPendingSnapshotChangeNotification else { return }
        hasPendingSnapshotChangeNotification = false
        Task { await sink() }
    }

    func contains(_ service: any Service) -> Bool {
        registeredServices.contains { ($0 as AnyObject) === (service as AnyObject) }
    }

    /// Register a new service so its tools become discoverable.
    func register(_ service: any Service) {
        guard !contains(service) else { return }
        registeredServices.append(service)
        invalidateSnapshot()
        let registrationGeneration = requestedGeneration

        Task { @MainActor [weak self] in
            #if DEBUG || EDIT_FLOW_PERF
                let serviceTools = await EditFlowPerf.measure(EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication) {
                    await service.tools
                }
            #else
                let serviceTools = await service.tools
            #endif
            guard let self, contains(service) else { return }
            await ToolAvailabilityStore.shared.registerTools(serviceTools)
            await publishSnapshotChangeIfCurrent(expectedGeneration: registrationGeneration)
        }
    }

    /// Invalidate a registered service after its cached catalog changes.
    func invalidateCatalog(for service: any Service) {
        guard contains(service) else { return }
        invalidateSnapshot()
        scheduleSnapshotChangePublication(expectedGeneration: requestedGeneration)
    }

    /// Unregister a service and synchronously remove its committed routes.
    func unregister(_ service: any Service) {
        let serviceIdentity = ObjectIdentifier(service as AnyObject)
        guard let index = registeredServices.firstIndex(where: { ($0 as AnyObject) === (service as AnyObject) }) else {
            return
        }
        registeredServices.remove(at: index)
        invalidateSnapshot()
        committedSnapshot = Self.snapshot(
            generation: requestedGeneration,
            routes: committedSnapshot.orderedRoutes.filter { $0.serviceIdentity != serviceIdentity }
        )
        scheduleSnapshotChangePublication(expectedGeneration: requestedGeneration)
    }

    /// Returns the last committed immutable index without rebuilding on a request hot path.
    func routeSnapshot() -> Snapshot {
        committedSnapshot
    }

    /// Rebuilds eagerly after registration or invalidation and commits only the newest generation.
    func awaitCurrentSnapshot() async -> Snapshot {
        while snapshotNeedsRebuild {
            let generation = requestedGeneration
            let services = registeredServices
            var routes: [IndexedToolRoute] = []

            for service in services {
                let scope: Scope = if let windowScoped = service as? WindowScopedService {
                    .window(windowScoped.windowID)
                } else {
                    .host
                }
                let role: Role = if service is WindowRoutingService {
                    .contextRouting
                } else if service is AppSettingsMCPService {
                    .appSettings
                } else {
                    .ordinary
                }
                let serviceIdentity = ObjectIdentifier(service as AnyObject)
                for tool in await service.tools {
                    routes.append(IndexedToolRoute(
                        serviceIdentity: serviceIdentity,
                        service: service,
                        scope: scope,
                        role: role,
                        tool: tool
                    ))
                }
            }

            guard generation == requestedGeneration else { continue }
            committedSnapshot = Self.snapshot(generation: generation, routes: routes)
            snapshotNeedsRebuild = false
        }
        return committedSnapshot
    }

    func committedSnapshotContains(_ service: any Service) -> Bool {
        let identity = ObjectIdentifier(service as AnyObject)
        return committedSnapshot.orderedRoutes.contains { $0.serviceIdentity == identity }
    }

    func isRegistered(serviceIdentity: ObjectIdentifier) -> Bool {
        registeredServices.contains { ObjectIdentifier($0 as AnyObject) == serviceIdentity }
    }

    #if DEBUG
        var debugRequestedGeneration: UInt64 {
            requestedGeneration
        }
    #endif

    private func invalidateSnapshot() {
        requestedGeneration &+= 1
        snapshotNeedsRebuild = true
    }

    private func scheduleSnapshotChangePublication(expectedGeneration: UInt64) {
        Task { @MainActor [weak self] in
            await self?.publishSnapshotChangeIfCurrent(expectedGeneration: expectedGeneration)
        }
    }

    private func publishSnapshotChangeIfCurrent(expectedGeneration: UInt64) async {
        let snapshot = await awaitCurrentSnapshot()
        guard expectedGeneration == requestedGeneration,
              snapshot.generation == expectedGeneration
        else {
            return
        }
        if let snapshotDidChangeSink {
            await snapshotDidChangeSink()
        } else {
            hasPendingSnapshotChangeNotification = true
        }
    }

    private static func snapshot(generation: UInt64, routes: [IndexedToolRoute]) -> Snapshot {
        var routesByCanonicalName: [String: [IndexedToolRoute]] = [:]
        for route in routes {
            let canonicalName = MCPToolNameCanonicalizer.canonicalName(for: route.tool.name)
            routesByCanonicalName[canonicalName, default: []].append(route)
        }
        return Snapshot(
            generation: generation,
            orderedRoutes: routes,
            routesByCanonicalName: routesByCanonicalName
        )
    }
}

/// Transitional forwarding facade for legacy tests and audited call sites.
/// Production MCP paths should use the manager-owned `MCPServiceRegistry` instance.
@MainActor
enum ServiceRegistry {
    static var services: [any Service] {
        ServerNetworkManager.shared.serviceRegistry.services
    }

    static func register(_ service: any Service) {
        ServerNetworkManager.shared.serviceRegistry.register(service)
    }

    static func unregister(_ service: any Service) {
        ServerNetworkManager.shared.serviceRegistry.unregister(service)
    }
}
