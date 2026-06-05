import Foundation

final class HeadlessWorkspaceStore {
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
            let data = try Data(contentsOf: file)
            let document = try HeadlessJSONFormatting.decoder().decode(HeadlessWorkspaceDocument.self, from: data)
            guard document.schemaVersion == HeadlessWorkspaceDocument.currentSchemaVersion else {
                throw HeadlessCommandError(
                    "Unsupported headless workspace schema_version \(document.schemaVersion) in \(file.lastPathComponent); expected \(HeadlessWorkspaceDocument.currentSchemaVersion).",
                    exitCode: 2
                )
            }
            documents.append(document)
        }
        documents.sort { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return documents
    }

    func loadWorkspace(id: UUID) throws -> HeadlessWorkspaceDocument? {
        let file = workspaceFile(for: id)
        guard fileManager.fileExists(atPath: file.path) else {
            return nil
        }
        let data = try Data(contentsOf: file)
        let document = try HeadlessJSONFormatting.decoder().decode(HeadlessWorkspaceDocument.self, from: data)
        guard document.schemaVersion == HeadlessWorkspaceDocument.currentSchemaVersion else {
            throw HeadlessCommandError(
                "Unsupported headless workspace schema_version \(document.schemaVersion) in \(file.lastPathComponent); expected \(HeadlessWorkspaceDocument.currentSchemaVersion).",
                exitCode: 2
            )
        }
        return document
    }

    @discardableResult
    func save(_ workspace: HeadlessWorkspaceDocument) throws -> HeadlessWorkspaceDocument {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let data = try HeadlessJSONFormatting.encoder(prettyPrinted: true).encode(workspace)
        try data.write(to: workspaceFile(for: workspace.id), options: [.atomic])
        return workspace
    }

    func update(id: UUID, _ body: (inout HeadlessWorkspaceDocument) throws -> Void) throws -> HeadlessWorkspaceDocument {
        guard var workspace = try loadWorkspace(id: id) else {
            throw HeadlessCommandError("No headless workspace found for id \(id.uuidString).", exitCode: 2)
        }
        try body(&workspace)
        workspace.touch()
        return try save(workspace)
    }

    private func workspaceFile(for id: UUID) -> URL {
        paths.workspacesDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}
