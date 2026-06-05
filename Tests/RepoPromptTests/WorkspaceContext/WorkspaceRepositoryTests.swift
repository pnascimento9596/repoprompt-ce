import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceRepositoryTests: XCTestCase {
    func testSnapshotPreservesIndexOrderAndSkipsMissingEntries() async throws {
        let root = try makeTemporaryDirectory()
        let first = WorkspaceModel(name: "First", repoPaths: ["/tmp/first"])
        let missing = WorkspaceModel(name: "Missing", repoPaths: ["/tmp/missing"])
        let second = WorkspaceModel(name: "Second", repoPaths: ["/tmp/second"])
        try writeWorkspace(first, under: root)
        try writeWorkspace(second, under: root)
        try writeIndex([entry(first), entry(missing), entry(second)], under: root)

        let repository = WorkspaceRepository(rootProvider: { root })
        let snapshot = await repository.loadWorkspaceSnapshotFromDisk()

        XCTAssertEqual(snapshot.map(\.id), [first.id, second.id])
    }

    func testSnapshotLoadsCustomStoragePath() async throws {
        let root = try makeTemporaryDirectory()
        let customRoot = try makeTemporaryDirectory()
        let workspace = WorkspaceModel(
            name: "Custom",
            repoPaths: ["/tmp/custom"],
            customStoragePath: customRoot
        )
        try JSONEncoder().encode(workspace).write(
            to: customRoot.appendingPathComponent("workspace.json"),
            options: .atomic
        )
        try writeIndex([entry(workspace)], under: root)

        let repository = WorkspaceRepository(rootProvider: { root })
        let snapshot = await repository.loadWorkspaceSnapshotFromDisk()

        XCTAssertEqual(snapshot.map(\.id), [workspace.id])
        XCTAssertEqual(snapshot.first?.repoPaths, ["/tmp/custom"])
    }

    private func entry(_ workspace: WorkspaceModel) -> WorkspaceIndexEntry {
        WorkspaceIndexEntry(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath,
            isSystemWorkspace: workspace.isSystemWorkspace,
            isHiddenInMenus: workspace.isHiddenInMenus
        )
    }

    private func writeWorkspace(_ workspace: WorkspaceModel, under root: URL) throws {
        let directory = root.appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(
            to: directory.appendingPathComponent("workspace.json"),
            options: .atomic
        )
    }

    private func writeIndex(_ entries: [WorkspaceIndexEntry], under root: URL) throws {
        try JSONEncoder().encode(entries).write(
            to: root.appendingPathComponent("workspacesIndex.json"),
            options: .atomic
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRepositoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
