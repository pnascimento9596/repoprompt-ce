import Foundation

struct WorkspaceReadableFileService {
    let store: WorkspaceFileContextStore
    let homeDirectoryURL: URL

    init(
        store: WorkspaceFileContextStore,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.homeDirectoryURL = homeDirectoryURL
    }

    func resolveReadableFile(
        _ userPath: String,
        profile: PathLocateProfile = .mcpRead,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceReadableFileHandle? {
        let trimmed = normalizedInput(userPath)
        guard !trimmed.isEmpty else { return nil }
        switch await store.lookupCatalogFileForExplicitRequest(trimmed, rootScope: rootScope) {
        case let .matched(file):
            return .workspace(file)
        case .ambiguous, .blocked:
            return nil
        case .noCandidate:
            break
        }
        switch try? await store.materializeExplicitlyRequestedFile(trimmed, rootScope: rootScope) {
        case let .some(.materialized(file)):
            return .workspace(file)
        case .some(.ambiguous), .some(.blocked):
            return nil
        case .some(.noCandidate), .none:
            break
        }
        if let workspaceFile = await store.lookupPath(
            WorkspacePathLookupRequest(userPath: trimmed, profile: profile, rootScope: rootScope)
        )?.file {
            return .workspace(workspaceFile)
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return resolveAlwaysReadableExternalFile(atAbsolutePath: trimmed).map { .external($0) }
    }

    func resolveAlwaysReadableExternalFolderDisplayPath(_ userPath: String) -> String? {
        let normalized = normalizedInput(userPath)
        guard normalized.hasPrefix("/"), isAlwaysReadableExternalPath(normalized) else { return nil }
        let absolutePath = normalizedAlwaysReadableAbsolutePath(for: normalized)
        guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return displayPath(forExternalPath: absolutePath)
    }

    func displayPath(forExternalPath userPath: String) -> String {
        AgentSupportDirectoryCatalog.displayPath(for: normalizedInput(userPath), homeDirectoryURL: homeDirectoryURL)
    }

    func isAlwaysReadableExternalPath(_ userPath: String) -> Bool {
        let normalized = normalizedInput(userPath)
        guard normalized.hasPrefix("/") else { return false }
        let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL)
        return directories.contains { AgentSupportDirectoryCatalog.contains(absolutePath: normalized, in: $0) }
    }

    func readAlwaysReadableExternalFile(_ file: WorkspaceExternalReadableFile) async throws -> String {
        let path = file.absolutePath
        return try await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            if let decoded = String(data: data, encoding: .utf8) { return decoded }
            if let decoded = String(data: data, encoding: .unicode) { return decoded }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    func resolveAlwaysReadableExternalFile(atAbsolutePath path: String) -> WorkspaceExternalReadableFile? {
        guard isAlwaysReadableExternalPath(path) else { return nil }
        let absolutePath = normalizedAlwaysReadableAbsolutePath(for: path)
        guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return WorkspaceExternalReadableFile(
            absolutePath: absolutePath,
            displayPath: displayPath(forExternalPath: absolutePath)
        )
    }

    private func normalizedAlwaysReadableAbsolutePath(for path: String) -> String {
        let normalized = AgentSupportDirectoryCatalog.normalizedPath(for: path)
        if FileManager.default.fileExists(atPath: normalized) {
            return AgentSupportDirectoryCatalog.normalizedPath(
                for: URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
        return normalized
    }

    private func normalizedInput(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}
