import Foundation

/// Process-owned read seam for persisted workspace inventory.
///
/// Persistence writes intentionally remain in `WorkspaceManagerViewModel` during
/// Item 3. This repository removes MCP routing's dependency on borrowing the first
/// visible window solely to read the shared workspace inventory.
@MainActor
final class WorkspaceRepository {
    typealias RootProvider = @MainActor () -> URL

    private let rootProvider: RootProvider

    nonisolated init(rootProvider: @escaping RootProvider = WorkspaceRepository.defaultRoot) {
        self.rootProvider = rootProvider
    }

    var currentRoot: URL {
        rootProvider()
    }

    func loadWorkspaceSnapshotFromDisk(baseRoot: URL? = nil) async -> [WorkspaceModel] {
        let resolvedRoot = baseRoot ?? currentRoot
        return await Task.detached(priority: .utility) {
            Self.loadWorkspaceSnapshotFromDiskSync(baseRoot: resolvedRoot)
        }.value
    }

    nonisolated static func defaultRoot() -> URL {
        if let path = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return WorkspaceStoragePaths.defaultRoot
    }

    private nonisolated static func loadWorkspaceSnapshotFromDiskSync(baseRoot: URL) -> [WorkspaceModel] {
        let indexURL = baseRoot.appendingPathComponent("workspacesIndex.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }

        let entries: [WorkspaceIndexEntry]
        do {
            let data = try Data(contentsOf: indexURL)
            entries = try JSONDecoder().decode([WorkspaceIndexEntry].self, from: data)
        } catch {
            print("Failed to load workspaceIndex.json: \(error)")
            return []
        }

        var loaded: [WorkspaceModel] = []
        for entry in entries {
            let workspaceFileURL: URL = if let customURL = entry.customStoragePath {
                customURL.appendingPathComponent("workspace.json")
            } else {
                baseRoot
                    .appendingPathComponent("Workspace-\(entry.name)-\(entry.id.uuidString)")
                    .appendingPathComponent("workspace.json")
            }

            guard FileManager.default.fileExists(atPath: workspaceFileURL.path) else {
                print("[WorkspaceSnapshot] File not found: \(workspaceFileURL.path)")
                continue
            }

            do {
                let workspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: workspaceFileURL)
                print("[WorkspaceSnapshot] Loaded \(workspace.name): \(workspace.repoPaths.count) repoPaths")
                loaded.append(workspace)
            } catch {
                print("[WorkspaceSnapshot] Failed to load from \(workspaceFileURL.path): \(error)")
            }
        }
        return loaded
    }
}
