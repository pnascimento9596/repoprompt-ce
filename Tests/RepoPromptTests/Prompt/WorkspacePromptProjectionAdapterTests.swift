import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class WorkspacePromptProjectionAdapterTests: XCTestCase {
    private enum TestError: Error {
        case unexpectedCaptureRequest
    }

    func testProjectionPreservesSelectedFolderSliceAndAutoCodemapOrderWithCaptureProvenance() async throws {
        let root = makeRoot()
        let folder = makeFolder(root: root, path: "Sources")
        let selected = makeFile(root: root, path: "Selected.swift")
        let folderSecond = makeFile(root: root, path: "Sources/Second.swift", parentFolderID: folder.id)
        let folderFirst = makeFile(root: root, path: "Sources/First.swift", parentFolderID: folder.id)
        let sliced = makeFile(root: root, path: "Sliced.swift")
        let auto = makeFile(root: root, path: "Auto.swift")
        let ranges = [LineRange(start: 4, end: 8, description: "body")]
        let selection = StoredSelection(
            selectedPaths: [selected.fullPath, folder.fullPath],
            autoCodemapPaths: [auto.fullPath],
            slices: [sliced.fullPath: ranges],
            codemapAutoEnabled: true
        )
        let capture = makeCapture(
            root: root,
            files: [auto, sliced, folderFirst, selected, folderSecond],
            folders: [folder],
            selection: selection,
            selectedPaths: [
                .init(input: selected.fullPath, resolution: .file(selected)),
                .init(input: folder.fullPath, resolution: .folder(
                    folder,
                    descendantFiles: [folderSecond, folderFirst, selected]
                ))
            ],
            autoCodemapPaths: [.init(input: auto.fullPath, resolution: .file(auto))],
            slices: [.init(path: sliced.fullPath, ranges: ranges, file: sliced, issue: nil)],
            codemapSnapshots: [makeCodemap(file: auto, root: root, symbol: "AutoSymbol")]
        )
        let adapter = WorkspacePromptProjectionAdapter { capturedSelection, request, profile in
            guard capturedSelection == selection,
                  request.mode == .none,
                  request.rootScope == .allLoaded,
                  profile == .uiAssisted
            else { throw TestError.unexpectedCaptureRequest }
            return capture
        }

        let projection = try await adapter.project(
            selection: selection,
            codeMapUsage: .auto,
            filePathDisplay: .relative
        )

        XCTAssertEqual(projection.provenance, capture.provenance)
        XCTAssertEqual(projection.entries.map(\.file.id), [
            selected.id,
            folderSecond.id,
            folderFirst.id,
            sliced.id,
            auto.id
        ])
        XCTAssertEqual(projection.entries.map(\.mode), [.full, .full, .full, .slice, .codemap])
        XCTAssertEqual(projection.entries.map(\.ranges), [nil, nil, nil, ranges, nil])
        XCTAssertEqual(projection.entries.map(\.codemapOrigin), [nil, nil, nil, nil, .auto])
        XCTAssertEqual(projection.entries.map(\.metadata.displayPath), [
            "Selected.swift",
            "Sources/Second.swift",
            "Sources/First.swift",
            "Sliced.swift",
            "Auto.swift"
        ])
    }

    func testProjectionUsesCoreSelectedAndCompleteCodemapModesAndOrigins() async throws {
        let root = makeRoot()
        let selectedWithAPI = makeFile(root: root, path: "SelectedWithAPI.swift")
        let selectedWithoutAPI = makeFile(root: root, path: "SelectedWithoutAPI.swift")
        let completeSecond = makeFile(root: root, path: "CompleteSecond.swift")
        let completeFirst = makeFile(root: root, path: "CompleteFirst.swift")
        let selection = StoredSelection(selectedPaths: [selectedWithAPI.fullPath, selectedWithoutAPI.fullPath])
        let capture = makeCapture(
            root: root,
            files: [selectedWithAPI, selectedWithoutAPI, completeSecond, completeFirst],
            selection: selection,
            selectedPaths: [
                .init(input: selectedWithAPI.fullPath, resolution: .file(selectedWithAPI)),
                .init(input: selectedWithoutAPI.fullPath, resolution: .file(selectedWithoutAPI))
            ],
            codemapSnapshots: [
                makeCodemap(file: completeSecond, root: root, symbol: "SecondSymbol"),
                makeCodemap(file: selectedWithAPI, root: root, symbol: "SelectedSymbol"),
                makeCodemap(file: completeFirst, root: root, symbol: "FirstSymbol")
            ]
        )
        let adapter = WorkspacePromptProjectionAdapter { _, _, _ in capture }

        let selectedProjection = try await adapter.project(
            selection: selection,
            codeMapUsage: .selected,
            filePathDisplay: .full
        )
        XCTAssertEqual(selectedProjection.entries.map(\.file.id), [selectedWithAPI.id, selectedWithoutAPI.id])
        XCTAssertEqual(selectedProjection.entries.map(\.mode), [.codemap, .full])
        XCTAssertEqual(selectedProjection.entries.map(\.codemapOrigin), [.selectedMode, nil])

        let completeProjection = try await adapter.project(
            selection: selection,
            codeMapUsage: .complete,
            filePathDisplay: .full
        )
        XCTAssertEqual(completeProjection.entries.map(\.file.id), [
            selectedWithAPI.id,
            selectedWithoutAPI.id,
            completeSecond.id,
            completeFirst.id
        ])
        XCTAssertEqual(completeProjection.entries.map(\.mode), [.full, .full, .codemap, .codemap])
        XCTAssertEqual(completeProjection.entries.map(\.codemapOrigin), [nil, nil, .auto, .auto])
    }

    @MainActor
    func testLiveMappingRequiresCurrentRecordIdentityAndPreservesProjectedModeAndRanges() {
        let root = makeRoot()
        let sliced = makeFile(root: root, path: "Sliced.swift")
        let codemap = makeFile(root: root, path: "Codemap.swift")
        let stale = makeFile(root: root, path: "Stale.swift")
        let ranges = [LineRange(start: 2, end: 3)]
        let slicedViewModel = makeFileViewModel(sliced, root: root)
        let codemapViewModel = makeFileViewModel(codemap, root: root)
        let replacementAtStalePath = makeFileViewModel(
            WorkspaceFileRecord(
                id: UUID(),
                rootID: stale.rootID,
                name: stale.name,
                relativePath: stale.relativePath,
                fullPath: stale.fullPath,
                parentFolderID: stale.parentFolderID
            ),
            root: root
        )
        let projection = WorkspacePromptProjectionAdapter.Projection(
            provenance: makeProvenance(),
            entries: [
                .init(
                    file: sliced,
                    metadata: makeMetadata(file: sliced, root: root),
                    mode: .slice,
                    ranges: ranges,
                    codemapOrigin: nil
                ),
                .init(
                    file: codemap,
                    metadata: makeMetadata(file: codemap, root: root),
                    mode: .codemap,
                    ranges: nil,
                    codemapOrigin: .auto
                ),
                .init(
                    file: stale,
                    metadata: makeMetadata(file: stale, root: root),
                    mode: .full,
                    ranges: nil,
                    codemapOrigin: nil
                )
            ]
        )
        let filesByPath = [
            sliced.standardizedFullPath: slicedViewModel,
            codemap.standardizedFullPath: codemapViewModel,
            stale.standardizedFullPath: replacementAtStalePath
        ]
        let adapter = WorkspacePromptProjectionAdapter { _, _, _ in
            throw TestError.unexpectedCaptureRequest
        }

        let entries = adapter.mapToLivePromptEntries(projection) { file in
            filesByPath[file.standardizedFullPath]
        }

        XCTAssertEqual(entries.map(\.file.id), [sliced.id, codemap.id])
        XCTAssertEqual(entries.map(\.isCodemap), [false, true])
        XCTAssertEqual(entries.map(\.ranges), [ranges, nil])
    }

    private func makeCapture(
        root: WorkspaceRootRecord,
        files: [WorkspaceFileRecord],
        folders: [WorkspaceFolderRecord] = [],
        selection: StoredSelection,
        selectedPaths: [WorkspaceFileContextCapture.SelectionPath],
        autoCodemapPaths: [WorkspaceFileContextCapture.SelectionPath] = [],
        slices: [WorkspaceFileContextCapture.Slice] = [],
        codemapSnapshots: [WorkspaceCodemapSnapshot] = []
    ) -> WorkspaceFileContextCapture {
        let provenance = makeProvenance()
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: provenance.catalogGeneration,
            rootScope: provenance.rootScope,
            rootCount: 1,
            folderCount: folders.count,
            fileCount: files.count
        )
        return WorkspaceFileContextCapture(
            provenance: provenance,
            storedSelection: selection,
            selectedPaths: selectedPaths,
            autoCodemapPaths: autoCodemapPaths,
            slices: slices,
            catalog: WorkspaceSearchCatalogSnapshot(
                generation: provenance.catalogGeneration,
                rootScope: provenance.rootScope,
                roots: [root],
                files: files,
                entries: files.map { WorkspaceSearchCatalogEntry(file: $0, root: root) },
                diagnostics: diagnostics
            ),
            materializedFolders: folders,
            materializedFiles: files,
            codemapSnapshots: codemapSnapshots,
            fileTree: FileTreeSelectionSnapshot(
                roots: [],
                selectedFileIDs: Set(files.map(\.id)),
                mode: "none",
                showFullPaths: false,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false
            )
        )
    }

    private func makeProvenance() -> WorkspaceFileContextCapture.Provenance {
        WorkspaceFileContextCapture.Provenance(
            captureGeneration: 17,
            catalogGeneration: 11,
            catalogValidationToken: 23,
            rootScope: .allLoaded,
            ingressSamples: []
        )
    }

    private func makeRoot() -> WorkspaceRootRecord {
        WorkspaceRootRecord(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Repo",
            fullPath: "/repo"
        )
    }

    private func makeFolder(root: WorkspaceRootRecord, path: String) -> WorkspaceFolderRecord {
        WorkspaceFolderRecord(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            rootID: root.id,
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            fullPath: root.fullPath + "/" + path,
            parentFolderID: nil
        )
    }

    private func makeFile(
        root: WorkspaceRootRecord,
        path: String,
        parentFolderID: UUID? = nil
    ) -> WorkspaceFileRecord {
        WorkspaceFileRecord(
            rootID: root.id,
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            fullPath: root.fullPath + "/" + path,
            parentFolderID: parentFolderID
        )
    }

    private func makeCodemap(
        file: WorkspaceFileRecord,
        root: WorkspaceRootRecord,
        symbol: String
    ) -> WorkspaceCodemapSnapshot {
        WorkspaceCodemapSnapshot(
            fileID: file.id,
            rootID: root.id,
            rootPath: root.fullPath,
            relativePath: file.relativePath,
            fullPath: file.fullPath,
            modificationDate: Date(timeIntervalSince1970: 0),
            fileAPI: FileAPI(
                filePath: file.fullPath,
                imports: [],
                classes: [.init(name: symbol, methods: [], properties: [])],
                functions: [],
                enums: [],
                globalVars: [],
                macros: [],
                referencedTypes: []
            )
        )
    }

    private func makeMetadata(
        file: WorkspaceFileRecord,
        root: WorkspaceRootRecord
    ) -> WorkspaceSelectionProjection.PathMetadata {
        .init(
            displayPath: file.relativePath,
            rootPath: root.fullPath,
            pathWithinRoot: file.relativePath
        )
    }

    @MainActor
    private func makeFileViewModel(
        _ record: WorkspaceFileRecord,
        root: WorkspaceRootRecord
    ) -> FileViewModel {
        FileViewModel(
            file: File(
                id: record.id,
                name: record.name,
                path: record.fullPath,
                modificationDate: Date(timeIntervalSince1970: 0)
            ),
            rootPath: root.fullPath,
            rootIdentifier: root.id,
            rootFolderPath: root.fullPath,
            fileSystemService: nil,
            relativePathOverride: record.relativePath
        )
    }
}
