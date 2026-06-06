import Foundation
import RepoPromptCore

struct WorkspacePromptProjectionAdapter {
    enum Error: Swift.Error {
        case missingSelectionProjection
    }

    struct Entry: Equatable {
        let file: WorkspaceFileRecord
        let metadata: WorkspaceSelectionProjection.PathMetadata
        let mode: WorkspaceSelectionProjection.RenderMode
        let ranges: [LineRange]?
        let codemapOrigin: WorkspaceSelectionProjection.CodemapOrigin?
    }

    struct Projection: Equatable {
        let provenance: WorkspaceFileContextCapture.Provenance
        let entries: [Entry]
    }

    typealias CaptureOperation = @Sendable (
        _ selection: StoredSelection,
        _ fileTreeRequest: WorkspaceFileTreeSnapshotRequest,
        _ profile: PathLocateProfile
    ) async throws -> WorkspaceFileContextCapture

    private let capture: CaptureOperation

    init(store: WorkspaceFileContextStore) {
        capture = { selection, fileTreeRequest, profile in
            try await store.captureWorkspaceFileContext(
                selection: selection,
                fileTreeRequest: fileTreeRequest,
                profile: profile
            )
        }
    }

    init(capture: @escaping CaptureOperation) {
        self.capture = capture
    }

    func project(
        selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay
    ) async throws -> Projection {
        let capture = capture
        let service = WorkspaceContextProjectionService(
            capture: {
                try await capture(
                    selection,
                    WorkspaceFileTreeSnapshotRequest(
                        mode: .none,
                        filePathDisplay: filePathDisplay,
                        onlyIncludeRootsWithSelectedFiles: false,
                        includeLegend: false,
                        showCodeMapMarkers: false,
                        rootScope: .allLoaded
                    ),
                    .uiAssisted
                )
            },
            materializer: Self.materializeSelectionProjection
        )
        let projection = try await service.project(.init(
            sections: [.selection],
            filePathDisplay: filePathDisplay,
            codeMapUsage: codeMapUsage
        ))
        guard let selectionProjection = projection.selection else {
            throw Error.missingSelectionProjection
        }

        return Projection(
            provenance: selectionProjection.provenance,
            entries: selectionProjection.value.files.compactMap { file in
                guard file.mode != .hidden else { return nil }
                return Entry(
                    file: file.file,
                    metadata: file.metadata,
                    mode: file.mode,
                    ranges: file.ranges,
                    codemapOrigin: file.codemapOrigin
                )
            }
        )
    }

    @MainActor
    func mapToLivePromptEntries(
        _ projection: Projection,
        resolveFile: (WorkspaceFileRecord) -> FileViewModel?
    ) -> [PromptFileEntry] {
        projection.entries.compactMap { entry in
            guard let file = resolveFile(entry.file),
                  file.id == entry.file.id,
                  file.standardizedFullPath == entry.file.standardizedFullPath
            else { return nil }

            return PromptFileEntry(
                file: file,
                isCodemap: entry.mode == .codemap,
                ranges: entry.mode == .slice ? entry.ranges : nil
            )
        }
    }

    private static func materializeSelectionProjection(
        _ request: WorkspaceContextProjectionMaterializationRequest
    ) async throws -> WorkspaceContextProjectionMaterialization {
        WorkspaceContextProjectionMaterialization(
            provenance: request.provenance,
            occurrences: request.occurrences.map { occurrence in
                let displayTokens = occurrence.mode == .codemap
                    ? occurrence.codemap?.tokens ?? 0
                    : 0
                return .init(
                    id: occurrence.id,
                    content: nil,
                    tokenFacts: .init(
                        displayTokens: displayTokens,
                        fullTokens: 0
                    )
                )
            }
        )
    }
}
