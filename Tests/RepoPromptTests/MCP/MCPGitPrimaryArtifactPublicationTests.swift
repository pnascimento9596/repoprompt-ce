@testable import RepoPrompt
import XCTest

@MainActor
final class MCPGitPrimaryArtifactPublicationTests: XCTestCase {
    func testCanonicalAndLinkedWorktreeSnapshotsIngressWithoutWatcherAndPreserveSelection() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "MCPGitPrimaryArtifactPublication")
        defer { fixture.cleanup() }

        let canonical = try fixture.makeRepository(named: "canonical")
        let linked = try fixture.makeLinkedWorktree(
            from: canonical,
            named: "linked",
            branch: "feature/artifact-ingress"
        )
        try fixture.write("let value = 2\n", to: "Sources/Feature.swift", at: canonical)
        try fixture.write("let value = 3\n", to: "Sources/Feature.swift", at: linked)

        let workspaceDirectory = fixture.sandbox.appendingPathComponent("workspace", isDirectory: true)
        let gitDataRoot = workspaceDirectory.appendingPathComponent("_git_data", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDataRoot, withIntermediateDirectories: true)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let exactRootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let exactRoot = try XCTUnwrap(exactRootValue)

        let canonicalSet = try await publish(
            repoURL: canonical,
            workspaceDirectory: workspaceDirectory,
            snapshotID: "2026-06-19/2310"
        )
        let linkedTabID = UUID()
        let linkedSet = try await publish(
            repoURL: linked,
            workspaceDirectory: workspaceDirectory,
            snapshotID: "2026-06-19/2311",
            tabID: linkedTabID
        )

        for artifact in canonicalSet.primarySelectionArtifacts + linkedSet.primarySelectionArtifacts {
            let preIngressRecord = await store.exactCatalogFile(
                absolutePath: artifact.absolutePath,
                expectedRoot: exactRoot,
                expectedKind: .workspaceGitData
            )
            XCTAssertNil(preIngressRecord, "Ignored artifact should require explicit ingress: \(artifact.absolutePath)")
        }

        let ingress = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: exactRoot,
                artifacts: canonicalSet.orderedArtifacts + linkedSet.orderedArtifacts
            )
        )
        XCTAssertTrue(ingress.failuresByArtifact.isEmpty)
        XCTAssertEqual(
            ingress.selectionReadyArtifacts(for: canonicalSet),
            canonicalSet.primarySelectionArtifacts
        )
        XCTAssertEqual(
            ingress.selectionReadyArtifacts(for: linkedSet),
            linkedSet.primarySelectionArtifacts
        )

        for artifact in canonicalSet.orderedArtifacts + linkedSet.orderedArtifacts {
            let record = try XCTUnwrap(ingress.recordsByAbsolutePath[artifact.absolutePath])
            let content = await store.readExactCatalogFile(record, expectedRoot: exactRoot)
            XCTAssertNotNil(content)
        }

        let sourcePath = canonical.appendingPathComponent("Sources/Feature.swift").path
        let initial = StoredSelection(
            selectedPaths: [sourcePath],
            autoCodemapPaths: [canonicalSet.map.absolutePath, "/tmp/dependency.swift"],
            slices: [sourcePath: [LineRange(start: 1, end: 1)]],
            codemapAutoEnabled: false
        )
        let readyCandidates = ingress.selectionReadyArtifacts(for: canonicalSet)
            + ingress.selectionReadyArtifacts(for: linkedSet)
        let merge = WorkspaceGitDiffArtifactSelectionService().mergePrimaryArtifacts(
            existing: initial,
            candidates: readyCandidates
        )

        XCTAssertEqual(merge.selection.selectedPaths.first, sourcePath)
        XCTAssertEqual(
            Array(merge.selection.selectedPaths.dropFirst()),
            readyCandidates.map(\.absolutePath)
        )
        XCTAssertEqual(merge.selection.slices, initial.slices)
        XCTAssertEqual(merge.selection.autoCodemapPaths, ["/tmp/dependency.swift"])
        XCTAssertFalse(merge.selection.codemapAutoEnabled)
        XCTAssertEqual(
            merge.newlyAddedArtifacts.compactMap(\.clientAlias),
            readyCandidates.compactMap(\.clientAlias)
        )

        _ = try await store.loadRoot(path: canonical.path, kind: .primaryWorkspace)
        _ = try await store.loadRoot(path: linked.path, kind: .sessionWorktree)
        let canonicalRefValue = await awaitExactRoot(
            store: store,
            path: canonical.path,
            kind: .primaryWorkspace
        )
        let canonicalRef = try XCTUnwrap(canonicalRefValue)
        let linkedRefValue = await awaitExactRoot(
            store: store,
            path: linked.path,
            kind: .sessionWorktree
        )
        let linkedRef = try XCTUnwrap(linkedRefValue)
        let sessionRoots = await store.rootRefs(scope: .sessionBoundWorkspace(
            canonicalRootPaths: [canonical.path],
            physicalRootPaths: [linked.path]
        ))
        XCTAssertEqual(Set(sessionRoots.map(\.id)), Set([canonicalRef.id, linkedRef.id]))
        XCTAssertFalse(sessionRoots.contains { $0.id == exactRoot.id })
        let validatedRoots = await store.rootRefs(scope: .validatedSessionBoundWorkspace(
            canonicalRoots: [canonicalRef],
            physicalRoots: [linkedRef]
        ))
        XCTAssertEqual(Set(validatedRoots.map(\.id)), Set([canonicalRef.id, linkedRef.id]))
        XCTAssertFalse(validatedRoots.contains { $0.id == exactRoot.id })

        await store.unloadRoot(id: linkedRef.id)
        _ = try await store.loadRoot(path: linked.path, kind: .primaryWorkspace)
        let reviewContext = await FrozenPromptGitReviewContext.make(
            workspaceID: UUID(),
            workspaceDirectoryPath: workspaceDirectory.path,
            workspaceRootPaths: [linked.path],
            tabID: linkedTabID,
            sessionID: nil,
            bindings: [],
            base: "HEAD",
            store: store
        )
        let capability = try XCTUnwrap(reviewContext.artifactCapability)
        XCTAssertTrue(capability.boundCheckouts.isEmpty)
        XCTAssertEqual(capability.visibleRootCheckouts.map(\.kind), [.linkedWorktree])

        let advertisedPaths = linkedSet.orderedArtifacts
            .filter {
                $0.selectionDisposition == .primaryAutoSelect
                    || $0.selectionDisposition == .advertisedSelectable
            }
            .map(\.absolutePath)
        let authorization = await SelectedGitDiffArtifactAuthorizationService().authorizeExactPaths(
            ExactSelectedGitArtifactAuthorizationRequest(
                exactAbsolutePaths: advertisedPaths,
                capability: capability,
                store: store
            )
        )
        XCTAssertEqual(
            Set(authorization.dispositions.compactMap { disposition -> String? in
                guard case let .authorized(path, _, _) = disposition else { return nil }
                return path
            }),
            Set(advertisedPaths)
        )

        let canonicalDenied = await SelectedGitDiffArtifactAuthorizationService().authorizeExactPaths(
            ExactSelectedGitArtifactAuthorizationRequest(
                exactAbsolutePaths: canonicalSet.primarySelectionArtifacts.map(\.absolutePath),
                capability: capability,
                store: store
            )
        )
        XCTAssertTrue(canonicalDenied.dispositions.allSatisfy {
            if case .rejected = $0 { return true }
            return false
        })
    }

    func testMultiRepoPartialReadinessNeverClaimsMissingPatch() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "MCPGitMultiRepoArtifactPublication")
        defer { fixture.cleanup() }

        let firstRepo = try fixture.makeRepository(named: "first")
        let secondRepo = try fixture.makeRepository(named: "second")
        try fixture.write("let value = 10\n", to: "Sources/Feature.swift", at: firstRepo)
        try fixture.write("let value = 20\n", to: "Sources/Feature.swift", at: secondRepo)

        let workspaceDirectory = fixture.sandbox.appendingPathComponent("workspace", isDirectory: true)
        let gitDataRoot = workspaceDirectory.appendingPathComponent("_git_data", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDataRoot, withIntermediateDirectories: true)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let exactRootValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let exactRoot = try XCTUnwrap(exactRootValue)

        let firstSet = try await publish(
            repoURL: firstRepo,
            workspaceDirectory: workspaceDirectory,
            snapshotID: "2026-06-19/2320"
        )
        let secondSet = try await publish(
            repoURL: secondRepo,
            workspaceDirectory: workspaceDirectory,
            snapshotID: "2026-06-19/2321"
        )
        let missingPatch = try XCTUnwrap(secondSet.allPatch)
        try FileManager.default.removeItem(atPath: missingPatch.absolutePath)

        let ingress = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: exactRoot,
                artifacts: firstSet.orderedArtifacts + secondSet.orderedArtifacts
            )
        )

        XCTAssertEqual(
            ingress.selectionReadyArtifacts(for: firstSet),
            firstSet.primarySelectionArtifacts
        )
        XCTAssertEqual(ingress.selectionReadyArtifacts(for: secondSet), [secondSet.map])
        XCTAssertEqual(ingress.failuresByArtifact[missingPatch], .missingOnDisk)

        let readyCandidates = ingress.selectionReadyArtifacts(for: firstSet)
            + ingress.selectionReadyArtifacts(for: secondSet)
        let concurrentSource = secondRepo.appendingPathComponent("Sources/Concurrent.swift").path
        let existing = StoredSelection(
            selectedPaths: [concurrentSource],
            slices: [concurrentSource: [LineRange(start: 3, end: 7)]],
            codemapAutoEnabled: true
        )
        let merge = WorkspaceGitDiffArtifactSelectionService().mergePrimaryArtifacts(
            existing: existing,
            candidates: readyCandidates
        )

        XCTAssertTrue(merge.selection.selectedPaths.contains(concurrentSource))
        XCTAssertEqual(merge.selection.slices, existing.slices)
        XCTAssertFalse(merge.selection.selectedPaths.contains(missingPatch.absolutePath))
        XCTAssertFalse(merge.newlyAddedArtifacts.contains(missingPatch))
        XCTAssertEqual(
            Set(merge.newlyAddedArtifacts.map(\.absolutePath)),
            Set(readyCandidates.map(\.absolutePath))
        )

        let snapshotStore = GitDiffSnapshotStore()
        let secondRepoKey = try XCTUnwrap(secondSet.snapshotRef.repoKey)
        let secondManifestValue = try snapshotStore.readManifest(
            workspaceDirectory: workspaceDirectory,
            repoKey: secondRepoKey,
            snapshotID: secondSet.snapshotRef.snapshotID
        )
        let secondManifest = try XCTUnwrap(secondManifestValue)
        let secondProjection = try await MCPGitToolProjection.makeArtifactProjection(
            snapshotDirURL: URL(fileURLWithPath: secondSet.snapshotDirectoryPath),
            snapshotDir: secondSet.snapshotRef.snapshotDirRel,
            manifest: secondManifest,
            compareDisplay: "uncommitted",
            mode: .standard,
            inlineMap: false,
            inlineMode: "brief",
            inlineMaxLines: 20
        )
        let committedAliases = merge.newlyAddedArtifacts.compactMap(\.clientAlias)
        let primaryDTO = try await MCPGitToolProjection.makePrimaryArtifactsDTO(
            snapshotDir: secondSet.snapshotRef.snapshotDirRel,
            artifacts: secondProjection.artifacts,
            manifest: secondManifest,
            autoSelectedPaths: committedAliases
        )
        XCTAssertEqual(primaryDTO.autoSelected, [secondSet.map.clientAlias].compactMap(\.self))
        XCTAssertFalse(primaryDTO.autoSelected?.contains(missingPatch.clientAlias ?? "") == true)

        let readinessWarning = "Git artifact readiness: aggregate patch was not selection-ready."
        let decorated = try await MCPGitToolProjection.decorateArtifactRepoResults(
            [ToolResultDTOs.GitToolReplyDTO.RepoResultDTO(
                repoRoot: secondRepo.path,
                repoKey: GitRepoDescriptor(rootURL: secondRepo).repoKey,
                snapshotId: secondManifest.snapshotID,
                snapshotDir: secondSet.snapshotRef.snapshotDirRel,
                artifacts: secondProjection.artifacts
            )],
            manifestsBySnapshotDir: [secondSet.snapshotRef.snapshotDirRel: secondManifest],
            autoSelectedPaths: committedAliases,
            readinessWarningsBySnapshotDir: [secondSet.snapshotRef.snapshotDirRel: readinessWarning]
        )
        XCTAssertEqual(decorated.first?.warning, readinessWarning)
        XCTAssertEqual(decorated.first?.primaryArtifacts?.autoSelected, primaryDTO.autoSelected)
    }

    private func awaitExactRoot(
        store: WorkspaceFileContextStore,
        path: String,
        kind: WorkspaceRootKind
    ) async -> WorkspaceRootRef? {
        await store.exactRootRef(path: path, kind: kind)
    }

    private func publish(
        repoURL: URL,
        workspaceDirectory: URL,
        snapshotID: String,
        tabID: UUID = UUID()
    ) async throws -> GitDiffPublishedArtifactSet {
        let repo = GitRepoDescriptor(rootURL: repoURL)
        let manifest = try await GitDiffSnapshotPublisher().publish(
            workspaceDirectory: workspaceDirectory,
            repo: repo,
            mode: .standard,
            compareSpec: .uncommitted(base: "HEAD"),
            compareDisplay: "uncommitted",
            compareInput: "uncommitted",
            scope: .all,
            selectedAbsolutePaths: [],
            contextLines: 3,
            detectRenames: false,
            snapshotIDOverride: snapshotID,
            tabID: tabID
        )
        let snapshotStore = GitDiffSnapshotStore()
        let snapshotRef = GitDiffSnapshotStore.GitDiffSnapshotRef(
            repoKey: repo.repoKey,
            snapshotID: manifest.snapshotID
        )
        let snapshotDirectory = snapshotStore.snapshotDir(
            workspaceDirectory: workspaceDirectory,
            repoKey: repo.repoKey,
            snapshotID: manifest.snapshotID
        )
        let allPatchPath = snapshotDirectory.appendingPathComponent("diff/all.patch").path
        return try GitDiffPublishedArtifactSet(
            snapshotDirectoryURL: snapshotDirectory,
            snapshotRef: snapshotRef,
            manifest: manifest,
            allPatchRelativePath: FileManager.default.fileExists(atPath: allPatchPath)
                ? "diff/all.patch"
                : nil
        )
    }
}
