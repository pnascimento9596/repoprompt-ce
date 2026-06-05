import Foundation

final class HeadlessWorkspaceStore: @unchecked Sendable {
    private let paths: HeadlessStatePaths
    private let fileManager: FileManager

    init(paths: HeadlessStatePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadWorkspaces() throws -> [HeadlessWorkspaceDocument] {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        guard fileManager.fileExists(atPath: paths.workspacesDirectory.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: paths.workspacesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var documents: [HeadlessWorkspaceDocument] = []
        for file in files where file.pathExtension == "json" {
            let lockFile = workspaceLockFile(forWorkspaceFile: file)
            if let document = try HeadlessFileLock.withExclusiveLock(path: lockFile, {
                try loadWorkspaceUnlocked(file: file)
            }) {
                documents.append(document)
            }
        }
        documents.sort { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return documents
    }

    func loadWorkspace(id: UUID) throws -> HeadlessWorkspaceDocument? {
        try HeadlessFileLock.withExclusiveLock(path: paths.workspaceLockFile(for: id)) {
            try loadWorkspaceUnlocked(file: workspaceFile(for: id))
        }
    }

    @discardableResult
    func save(_ workspace: HeadlessWorkspaceDocument) throws -> HeadlessWorkspaceDocument {
        try HeadlessFileLock.withExclusiveLock(path: paths.workspaceLockFile(for: workspace.id)) {
            try saveUnlocked(workspace)
        }
    }

    func update(id: UUID, _ body: (inout HeadlessWorkspaceDocument) throws -> Void) throws -> HeadlessWorkspaceDocument {
        try HeadlessFileLock.withExclusiveLock(path: paths.workspaceLockFile(for: id)) {
            guard var workspace = try loadWorkspaceUnlocked(file: workspaceFile(for: id)) else {
                throw HeadlessCommandError("No headless workspace found for id \(id.uuidString).", exitCode: 2)
            }
            try body(&workspace)
            workspace.touch()
            return try saveUnlocked(workspace)
        }
    }

    private func loadWorkspaceUnlocked(file: URL) throws -> HeadlessWorkspaceDocument? {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        guard fileManager.fileExists(atPath: file.path) else {
            return nil
        }
        let data = try Data(contentsOf: file)
        var document = try HeadlessJSONFormatting.decoder().decode(HeadlessWorkspaceDocument.self, from: data)
        guard document.schemaVersion == HeadlessWorkspaceDocument.currentSchemaVersion else {
            throw HeadlessCommandError(
                "Unsupported headless workspace schema_version \(document.schemaVersion) in \(file.lastPathComponent); expected \(HeadlessWorkspaceDocument.currentSchemaVersion).",
                exitCode: 2
            )
        }

        let normalizedSelection = HeadlessSelectionNormalizer.normalized(document.selection)
        if normalizedSelection != document.selection {
            document.selection = normalizedSelection
            try saveUnlocked(document, file: file)
        }
        return document
    }

    @discardableResult
    private func saveUnlocked(
        _ workspace: HeadlessWorkspaceDocument,
        file: URL? = nil
    ) throws -> HeadlessWorkspaceDocument {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        var normalizedWorkspace = workspace
        normalizedWorkspace.selection = HeadlessSelectionNormalizer.normalized(workspace.selection)
        let data = try HeadlessJSONFormatting.encoder(prettyPrinted: true).encode(normalizedWorkspace)
        try data.write(to: file ?? workspaceFile(for: workspace.id), options: [.atomic])
        return normalizedWorkspace
    }

    private func workspaceFile(for id: UUID) -> URL {
        paths.workspacesDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func workspaceLockFile(forWorkspaceFile file: URL) -> URL {
        if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) {
            return paths.workspaceLockFile(for: id)
        }
        return file.deletingPathExtension().appendingPathExtension("lock")
    }
}
