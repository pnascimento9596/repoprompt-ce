import Foundation

final class HeadlessConfigurationStore {
    let paths: HeadlessStatePaths
    private let fileManager: FileManager

    init(paths: HeadlessStatePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadOrCreate() throws -> HeadlessConfigurationDocument {
        try HeadlessFileLock.withExclusiveLock(path: paths.configLockFile) {
            try loadOrCreateUnlocked()
        }
    }

    @discardableResult
    func update(_ body: (inout HeadlessConfigurationDocument) throws -> Void) throws -> HeadlessConfigurationDocument {
        try HeadlessFileLock.withExclusiveLock(path: paths.configLockFile) {
            var document = try loadOrCreateUnlocked()
            try body(&document)
            document.touch()
            try saveUnlocked(document)
            return document
        }
    }

    func save(_ document: HeadlessConfigurationDocument) throws {
        try HeadlessFileLock.withExclusiveLock(path: paths.configLockFile) {
            try saveUnlocked(document)
        }
    }

    private func loadOrCreateUnlocked() throws -> HeadlessConfigurationDocument {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        guard fileManager.fileExists(atPath: paths.configFile.path) else {
            let document = HeadlessConfigurationDocument()
            try saveUnlocked(document)
            return document
        }

        let data = try Data(contentsOf: paths.configFile)
        let document = try HeadlessJSONFormatting.decoder().decode(HeadlessConfigurationDocument.self, from: data)
        guard document.schemaVersion == HeadlessConfigurationDocument.currentSchemaVersion else {
            throw HeadlessCommandError(
                "Unsupported headless config schema_version \(document.schemaVersion); expected \(HeadlessConfigurationDocument.currentSchemaVersion).",
                exitCode: 2
            )
        }
        return document
    }

    private func saveUnlocked(_ document: HeadlessConfigurationDocument) throws {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let data = try HeadlessJSONFormatting.encoder(prettyPrinted: true).encode(document)
        try data.write(to: paths.configFile, options: [.atomic])
    }
}
