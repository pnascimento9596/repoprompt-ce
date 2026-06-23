import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceFileContextStoreModernCodemapSeamTests: XCTestCase {
    func testRootLoadSearchAndReadDoNotInvokeModernCodemapRuntimeProvider() async throws {
        let sandbox = try ModernCodemapStoreFixture.makeSandbox(name: #function)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.write("struct Feature {}\n", to: root.appendingPathComponent("Sources/Feature.swift"))

        let providerInvocations = ModernCodemapLockedCounter()
        let graphProbe = ModernCodemapSelectionGraphProbe()
        let store = WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerInvocations.increment()
                throw WorkspaceCodemapBindingEngineProviderError.unconfigured
            },
            selectionGraphFactory: graphProbe.factory
        )

        let loaded = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let search = WorkspaceSearchService()
        _ = await search.rebuildIndex(from: snapshot)
        let searchResult = await search.search("Feature", limit: 10)
        let content = try await store.readContent(
            rootID: loaded.id,
            relativePath: "Sources/Feature.swift"
        )

        XCTAssertEqual(snapshot.files.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(searchResult.results.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(content, "struct Feature {}\n")
        XCTAssertEqual(providerInvocations.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
        XCTAssertEqual(providerInvocations.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
    }

    func testFirstExplicitDemandReturnsStableExactRootPendingTicketAndRegistersOnce() async throws {
        let gate = ModernCodemapResolutionGate()
        let fixture = try ModernCodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let duplicateTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        XCTAssertEqual(firstTicket, duplicateTicket)
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let candidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(firstTicket.rootEpoch, file.standardizedRelativePath)
        XCTAssertEqual(candidate?.identity.fileID, file.id)
        XCTAssertEqual(candidate?.identity.rootID, loaded.id)
        XCTAssertEqual(candidate?.identity.rootLifetimeID, firstTicket.rootEpoch.rootLifetimeID)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        let resolutionCount = await gate.resolutionCount
        XCTAssertEqual(resolutionCount, 1)

        await gate.release()
        let settled = try await settledResult(store: store, ticket: firstTicket)
        assertNonGitTerminal(settled)
        await store.unloadRoot(id: loaded.id)
    }

    func testFrozenPresentationBundleRetainsReadyHandleLeaseAcrossAwaitAndRendersLogicalPaths() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Alpha.swift": """
                protocol AlphaProtocol {
                    func alpha() -> String
                }

                struct Alpha: AlphaProtocol {
                    func alpha() -> String { "alpha" }
                }
                """,
                "Sources/Zeta.swift": """
                protocol ZetaProtocol {
                    func zeta() -> String
                }

                struct Zeta: ZetaProtocol {
                    func zeta() -> String { "zeta" }
                }
                """
            ]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let suspensionGate = ModernCodemapSuspensionGate()
        addTeardownBlock {
            await suspensionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let alpha = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Alpha.swift"
        })
        let zeta = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Zeta.swift"
        })
        let alphaTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: alpha.id)
        )
        let alphaReady = try await readyResult(
            settledResult(store: store, ticket: alphaTicket)
        )
        let zetaTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: zeta.id)
        )
        let zetaReady = try await readyResult(
            settledResult(store: store, ticket: zetaTicket)
        )
        XCTAssertNil(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: root.path,
            standardizedRelativePath: alpha.standardizedRelativePath
        ))
        XCTAssertNil(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: alpha.standardizedFullPath
        ))
        let alphaPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: alpha.standardizedRelativePath
        ))
        let zetaPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Logical Workspace",
            standardizedRelativePath: zeta.standardizedRelativePath
        ))
        let engine = try fixture.runtime().bindingEngine()
        let accountingBeforeFreeze = await engine.accounting()

        var callerBundle: WorkspaceCodemapFrozenPresentationBundle? = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: zetaTicket, logicalPath: zetaPath),
                WorkspaceCodemapPresentationRequest(ticket: alphaTicket, logicalPath: alphaPath)
            ])
        )
        do {
            let bundle = try XCTUnwrap(callerBundle)
            XCTAssertEqual(bundle.rootEpoch, alphaTicket.rootEpoch)
            XCTAssertEqual(
                bundle.entries.map(\.logicalPath.displayPath),
                ["Logical Workspace/Sources/Alpha.swift", "Logical Workspace/Sources/Zeta.swift"]
            )
            XCTAssertEqual(
                bundle.entries.map(\.artifactKey),
                [alphaReady.snapshot.artifactKey, zetaReady.snapshot.artifactKey]
            )
            XCTAssertEqual(
                bundle.entries.map(\.artifactKey.pipelineIdentity),
                [
                    alphaReady.snapshot.artifactKey.pipelineIdentity,
                    zetaReady.snapshot.artifactKey.pipelineIdentity
                ]
            )

            let rendered = try await renderedPresentationEntries(
                store.renderCodemapPresentation(bundle)
            )
            XCTAssertEqual(
                rendered.map(\.logicalPath.displayPath),
                ["Logical Workspace/Sources/Alpha.swift", "Logical Workspace/Sources/Zeta.swift"]
            )
            XCTAssertTrue(rendered[0].text.contains("File: Logical Workspace/Sources/Alpha.swift"))
            XCTAssertTrue(rendered[1].text.contains("File: Logical Workspace/Sources/Zeta.swift"))
            XCTAssertFalse(rendered.contains { $0.text.contains(root.path) })
            XCTAssertTrue(rendered.allSatisfy { $0.tokenCount > 0 })

            let accountingAfterRender = await engine.accounting()
            XCTAssertEqual(
                accountingAfterRender.counters.validatedWorktreeReads,
                accountingBeforeFreeze.counters.validatedWorktreeReads
            )
            XCTAssertEqual(accountingAfterRender.counters.builds, accountingBeforeFreeze.counters.builds)
            XCTAssertEqual(
                accountingAfterRender.counters.manifestLoads,
                accountingBeforeFreeze.counters.manifestLoads
            )
            XCTAssertEqual(fixture.buildCount.value, 2)
        }

        var suspendedRenderTask: Task<WorkspaceCodemapPresentationRenderDisposition, Never>?
        if let bundle = callerBundle {
            suspendedRenderTask = Task { [bundle] in
                await suspensionGate.enterAndWait()
                return await store.renderCodemapPresentation(bundle)
            }
        }
        let suspensionEntered = await suspensionGate.waitUntilEntered()
        XCTAssertTrue(suspensionEntered)
        if let bundle = callerBundle {
            let bundleReleased = await store.releaseCodemapPresentation(bundle)
            XCTAssertTrue(bundleReleased)
        } else {
            XCTFail("The caller bundle must remain alive until its gated owner captures it.")
        }
        callerBundle = nil

        await store.unloadRoot(id: loaded.id)
        let runtime = try fixture.runtime()
        let callerRetainedAccounting = await runtime.artifactStore.accounting()
        XCTAssertEqual(callerRetainedAccounting.activeLeaseCount, 2)
        XCTAssertGreaterThan(callerRetainedAccounting.activeLeaseBytes, 0)

        await suspensionGate.release()
        let suspendedRender = await suspendedRenderTask?.value
        if let suspendedRender {
            assertPresentationRenderUnavailable(suspendedRender, equals: .bundleNotRetained)
        } else {
            XCTFail("The suspended caller render task must exist.")
        }
        suspendedRenderTask = nil

        let fullyReleasedAccounting = await runtime.artifactStore.accounting()
        XCTAssertEqual(fullyReleasedAccounting.activeLeaseCount, 0)
        XCTAssertEqual(fullyReleasedAccounting.activeLeaseBytes, 0)
    }

    func testPresentationFreezeRejectsPendingForeignEpochDuplicateAndLogicalPathMismatch() async throws {
        let resolutionGate = ModernCodemapResolutionGate()
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let firstRoot = try repositoryFixture.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "struct First {}\n"]
        )
        let secondRoot = try repositoryFixture.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "struct Second {}\n"]
        )
        let fixture = try ModernCodemapStoreFixture(
            name: #function,
            resolutionGate: resolutionGate
        )
        addTeardownBlock {
            await resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let firstPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "First Logical Root",
            standardizedRelativePath: firstFile.standardizedRelativePath
        ))
        let secondPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Second Logical Root",
            standardizedRelativePath: secondFile.standardizedRelativePath
        ))
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)

        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ]),
            equals: .pending(firstTicket)
        )

        await resolutionGate.release()
        let firstReady = try await readyResult(
            settledResult(store: store, ticket: firstTicket)
        )
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))

        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath),
                WorkspaceCodemapPresentationRequest(ticket: secondTicket, logicalPath: secondPath)
            ]),
            equals: .mixedRootEpoch
        )
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath),
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ]),
            equals: .duplicateFileID(firstFile.id)
        )

        let mismatchedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "First Logical Root",
            standardizedRelativePath: "Sources/Elsewhere.swift"
        ))
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: firstTicket,
                    logicalPath: mismatchedPath
                )
            ]),
            equals: .logicalPathMismatch(firstFile.id)
        )

        let unretainedEntry = WorkspaceCodemapFrozenPresentationEntry(
            ticket: firstTicket,
            logicalPath: firstPath,
            artifactKey: firstReady.snapshot.artifactKey,
            outcome: firstReady.snapshot.outcome
        )
        let unretainedBundle = WorkspaceCodemapFrozenPresentationBundle(
            rootEpoch: firstTicket.rootEpoch,
            entries: [unretainedEntry],
            handles: [firstReady.handle]
        )
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(unretainedBundle),
            equals: .bundleNotRetained
        )

        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Plain.swift": "struct Plain {}\n"
        ])
        let plainLoaded = try await store.loadRoot(path: plainRoot.path)
        let plainFiles = await store.files(inRoot: plainLoaded.id)
        let plainFile = try XCTUnwrap(plainFiles.first)
        let plainTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: plainFile.id)
        )
        let plainSettled = try await settledResult(store: store, ticket: plainTicket)
        assertNonGitTerminal(plainSettled)
        let plainPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Plain Logical Root",
            standardizedRelativePath: plainFile.standardizedRelativePath
        ))
        await assertPresentationFreezeUnavailable(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: plainTicket, logicalPath: plainPath)
            ]),
            equals: .demandUnavailable(plainTicket, .gitTerminal(.nonGit))
        )

        let validBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: firstTicket, logicalPath: firstPath)
            ])
        )
        let validBundleReleased = await store.releaseCodemapPresentation(validBundle)
        XCTAssertTrue(validBundleReleased)
        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
        await store.unloadRoot(id: plainLoaded.id)
    }

    func testPresentationRenderFailsClosedAfterDemandCancellationCatalogAdvanceAndUnload() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let cancellationRoot = try repositoryFixture.makeRepository(
            named: "cancellation",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let catalogRoot = try repositoryFixture.makeRepository(
            named: "catalog",
            files: ["Sources/Catalog.swift": "struct Catalog {}\n"]
        )
        let unloadRoot = try repositoryFixture.makeRepository(
            named: "unload",
            files: ["Sources/Unload.swift": "struct Unload {}\n"]
        )
        let cancellationGate = ModernCodemapSuspensionGate()
        let fixture = try ModernCodemapStoreFixture(name: #function)
        addTeardownBlock {
            await cancellationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(cancellationCleanupHook: { _ in
            await cancellationGate.enterAndWait()
        })

        let cancellationLoaded = try await store.loadRoot(path: cancellationRoot.path)
        let cancellationFiles = await store.files(inRoot: cancellationLoaded.id)
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
        XCTAssertEqual(cancellationFiles.count, 2)
        let firstCancellationTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: cancellationFiles[0].id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: firstCancellationTicket)
        )
        let secondCancellationTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: cancellationFiles[1].id)
        )
        _ = try await readyResult(
            settledResult(store: store, ticket: secondCancellationTicket)
        )
        let cancellationBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: firstCancellationTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Cancellation Logical Root",
                        standardizedRelativePath: cancellationFiles[0].standardizedRelativePath
                    ))
                ),
                WorkspaceCodemapPresentationRequest(
                    ticket: secondCancellationTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Cancellation Logical Root",
                        standardizedRelativePath: cancellationFiles[1].standardizedRelativePath
                    ))
                )
            ])
        )

        let cancellationTask = Task {
            await store.cancelCodemapArtifactDemand(firstCancellationTicket)
        }
        let cancellationEntered = await cancellationGate.waitUntilEntered()
        XCTAssertTrue(cancellationEntered)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(cancellationBundle),
            equals: .bundleNotRetained
        )
        await cancellationGate.release()
        let cancellationResult = await cancellationTask.value
        XCTAssertTrue(cancellationResult)

        let catalogLoaded = try await store.loadRoot(path: catalogRoot.path)
        let catalogFiles = await store.files(inRoot: catalogLoaded.id)
        let catalogFile = try XCTUnwrap(catalogFiles.first)
        let catalogTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: catalogFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: catalogTicket))
        let catalogPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Catalog Logical Root",
            standardizedRelativePath: catalogFile.standardizedRelativePath
        ))
        let releaseBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: catalogTicket, logicalPath: catalogPath)
            ])
        )
        let catalogBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: catalogTicket, logicalPath: catalogPath)
            ])
        )
        let firstRelease = await store.releaseCodemapPresentation(releaseBundle)
        let secondRelease = await store.releaseCodemapPresentation(releaseBundle)
        XCTAssertTrue(firstRelease)
        XCTAssertFalse(secondRelease)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(releaseBundle),
            equals: .bundleNotRetained
        )

        try Self.write(
            "struct Added {}\n",
            to: catalogRoot.appendingPathComponent("Sources/Added.swift")
        )
        _ = await store.ensureIndexedFiles(paths: [
            catalogRoot.appendingPathComponent("Sources/Added.swift").path
        ])
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(catalogBundle),
            equals: .bundleNotRetained
        )

        let unloadLoaded = try await store.loadRoot(path: unloadRoot.path)
        let unloadFiles = await store.files(inRoot: unloadLoaded.id)
        let unloadFile = try XCTUnwrap(unloadFiles.first)
        let unloadTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: unloadFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: unloadTicket))
        let unloadBundle = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(
                    ticket: unloadTicket,
                    logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: "Unload Logical Root",
                        standardizedRelativePath: unloadFile.standardizedRelativePath
                    ))
                )
            ])
        )
        await store.unloadRoot(id: unloadLoaded.id)
        await assertPresentationRenderUnavailable(
            store.renderCodemapPresentation(unloadBundle),
            equals: .bundleNotRetained
        )

        await store.unloadRoot(id: cancellationLoaded.id)
        await store.unloadRoot(id: catalogLoaded.id)
    }

    func testAcceptedReadyOverlayLazilyBuildsOneExactEpochGraphAndReturnsPartial() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Pending.swift": "struct Pending {}\n"
            ]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let firstPublicationGate = ModernCodemapArmableSuspensionGate()
        let pendingPublicationGate = ModernCodemapArmableSuspensionGate()
        let initialGraphPolicy = WorkspaceCodemapSelectionGraphRuntimePolicy.initial
        let graphProbe = ModernCodemapSelectionGraphProbe(runtimePolicy: .init(
            maximumActiveRebuildCount: initialGraphPolicy.maximumActiveRebuildCount,
            maximumReservedBindingCount: initialGraphPolicy.maximumReservedBindingCount,
            maximumInputBindingCount: initialGraphPolicy.maximumInputBindingCount,
            maximumSelectedSourceCountPerQuery: 1,
            maximumResolvedTargetCountPerQuery: initialGraphPolicy.maximumResolvedTargetCountPerQuery,
            maximumReferenceFailureCountPerQuery: initialGraphPolicy.maximumReferenceFailureCountPerQuery,
            graphSizePolicy: initialGraphPolicy.graphSizePolicy
        ))
        addTeardownBlock {
            await firstPublicationGate.release()
            await pendingPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            readyPublicationHook: { _ in
                await firstPublicationGate.enterIfArmedAndWait()
                await pendingPublicationGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let pending = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Pending.swift"
        })

        await firstPublicationGate.arm()
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        let firstPublicationEntered = await firstPublicationGate.waitUntilEntered()
        XCTAssertTrue(firstPublicationEntered)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await firstPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))

        let targetTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: target.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let sourceQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket)
        ])
        let result = try await readyGraphQuery(store: store, query: sourceQuery)
        XCTAssertEqual(result.roots.count, 1)
        let rootResult = try XCTUnwrap(result.roots.first)
        XCTAssertEqual(rootResult.rootEpoch, sourceTicket.rootEpoch)
        XCTAssertEqual(rootResult.result.key.rootEpoch, sourceTicket.rootEpoch)
        XCTAssertTrue(rootResult.partialReasons.contains(.definitionUniverseIncomplete))
        XCTAssertEqual(rootResult.result.publishedSummary.nodeCount, 2)
        XCTAssertTrue(rootResult.result.targets.allSatisfy {
            $0.rootEpoch == sourceTicket.rootEpoch
        })
        XCTAssertTrue(rootResult.result.resolutions.allSatisfy {
            $0.source.rootEpoch == sourceTicket.rootEpoch &&
                $0.target.rootEpoch == sourceTicket.rootEpoch
        })
        XCTAssertEqual(graphProbe.factoryCount, 1)
        let budgetedQuery = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: sourceTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: targetTicket)
            ])
        )
        XCTAssertEqual(
            budgetedQuery,
            .budget(.runtime(
                rootEpoch: sourceTicket.rootEpoch,
                reason: .budgetExceeded
            ))
        )

        await pendingPublicationGate.arm()
        let pendingTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: pending.id)
        )
        let pendingPublicationEntered = await pendingPublicationGate.waitUntilEntered()
        XCTAssertTrue(pendingPublicationEntered)
        let whilePending = try await readyGraphQuery(store: store, query: sourceQuery)
        XCTAssertFalse(whilePending.roots.flatMap(\.result.targets).contains {
            $0.fileID == pending.id
        })
        let pendingQuery = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: pendingTicket)
            ])
        )
        XCTAssertEqual(pendingQuery, .unavailable(.sourceNotReady(pending.id)))
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await pendingPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: pendingTicket))

        try Self.write(
            "struct CatalogAdvance {}\n",
            to: root.appendingPathComponent("Sources/CatalogAdvance.swift")
        )
        _ = await store.ensureIndexedFiles(paths: [
            root.appendingPathComponent("Sources/CatalogAdvance.swift").path
        ])
        let staleAfterCatalogAdvance = await store.queryCodemapSelectionGraph(sourceQuery)
        XCTAssertEqual(
            staleAfterCatalogAdvance,
            .stale(.currentness(sourceTicket.rootEpoch))
        )
        await store.unloadRoot(id: loaded.id)
    }

    func testGraphQueryRejectsForeignEpochAndUnreadySourcesWithoutCrossRootTargets() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRoot = try firstRepository.makeRepository(
            named: "same-name",
            files: [
                "Sources/ForeignReference.swift":
                    "struct ForeignReference { let value: SharedDefinition }\n"
            ]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "same-name",
            files: [
                "Sources/SharedDefinition.swift": "struct SharedDefinition {}\n"
            ]
        )
        XCTAssertEqual(firstRoot.lastPathComponent, secondRoot.lastPathComponent)

        let fixture = try ModernCodemapStoreFixture(name: #function)
        let graphProbe = ModernCodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let firstLoaded = try await store.loadRoot(path: firstRoot.path)
        let secondLoaded = try await store.loadRoot(path: secondRoot.path)
        let firstFiles = await store.files(inRoot: firstLoaded.id)
        let secondFiles = await store.files(inRoot: secondLoaded.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))

        let firstOnly = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
            ])
        )
        XCTAssertEqual(firstOnly.roots.count, 1)
        let firstRootResult = try XCTUnwrap(firstOnly.roots.first)
        XCTAssertFalse(firstRootResult.result.targets.contains {
            $0.fileID == secondFile.id
        })
        XCTAssertTrue(firstRootResult.result.targets.allSatisfy {
            $0.rootEpoch == firstTicket.rootEpoch
        })

        let combined = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: secondTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
            ])
        )
        XCTAssertEqual(Set(combined.roots.map(\.rootEpoch)), [
            firstTicket.rootEpoch,
            secondTicket.rootEpoch
        ])
        for rootResult in combined.roots {
            XCTAssertTrue(rootResult.result.targets.allSatisfy {
                $0.rootEpoch == rootResult.rootEpoch
            })
            XCTAssertTrue(rootResult.result.resolutions.allSatisfy {
                $0.source.rootEpoch == rootResult.rootEpoch &&
                    $0.target.rootEpoch == rootResult.rootEpoch
            })
        }
        XCTAssertEqual(graphProbe.factoryCount, 2)

        let foreign = await store.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(
                    rootEpoch: secondTicket.rootEpoch,
                    ticket: firstTicket
                )
            ])
        )
        XCTAssertEqual(foreign, .unavailable(.foreignRootEpoch(firstFile.id)))

        let resolutionGate = ModernCodemapResolutionGate()
        let pendingFixture = try ModernCodemapStoreFixture(
            name: #function + "-pending",
            resolutionGate: resolutionGate
        )
        let pendingProbe = ModernCodemapSelectionGraphProbe()
        addTeardownBlock {
            await resolutionGate.release()
            await pendingFixture.shutdown()
        }
        let pendingStore = pendingFixture.makeStore(selectionGraphFactory: pendingProbe.factory)
        let pendingLoaded = try await pendingStore.loadRoot(path: firstRoot.path)
        let pendingFiles = await pendingStore.files(inRoot: pendingLoaded.id)
        let pendingFile = try XCTUnwrap(pendingFiles.first)
        let unreadyTicket = try await pendingTicket(
            pendingStore.requestCodemapArtifact(forFileID: pendingFile.id)
        )
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let unready = await pendingStore.queryCodemapSelectionGraph(
            WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unreadyTicket)
            ])
        )
        XCTAssertEqual(unready, .unavailable(.sourceNotReady(pendingFile.id)))
        XCTAssertEqual(pendingProbe.factoryCount, 0)
        await resolutionGate.release()
        _ = try await settledResult(store: pendingStore, ticket: unreadyTicket)
        await pendingStore.unloadRoot(id: pendingLoaded.id)

        await store.unloadRoot(id: firstLoaded.id)
        await store.unloadRoot(id: secondLoaded.id)
    }

    func testMultiRootGraphQueryEnforcesAggregateBudgetBeforeNPlusOneMaterialization() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let thirdRepository = try ReviewGitRepositoryFixture(name: #function + "-third")
        let firstRoot = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/Source.swift": "struct First { let value: MissingFirst }\n"]
        )
        let secondRoot = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Source.swift": "struct Second { let value: MissingSecond }\n"]
        )
        let thirdRoot = try thirdRepository.makeRepository(
            named: "third",
            files: ["Sources/Source.swift": "struct Third { let value: MissingThird }\n"]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let graphProbe = ModernCodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
            thirdRepository.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 100,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 2
            )
        )

        var loadedRoots: [WorkspaceRootRecord] = []
        var tickets: [WorkspaceCodemapArtifactDemandTicket] = []
        for root in [firstRoot, secondRoot, thirdRoot] {
            let loaded = try await store.loadRoot(path: root.path)
            loadedRoots.append(loaded)
            let files = await store.files(inRoot: loaded.id)
            let file = try XCTUnwrap(files.first)
            let ticket = try await pendingTicket(
                store.requestCodemapArtifact(forFileID: file.id)
            )
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
            tickets.append(ticket)
        }
        for ticket in tickets {
            let published = await graphProbe.waitUntilPublished(rootEpoch: ticket.rootEpoch)
            XCTAssertTrue(published)
        }

        let firstTwoQuery = WorkspaceCodemapStoreSelectionGraphQuery(
            selectedSources: tickets
                .prefix(2)
                .map(WorkspaceCodemapStoreSelectionGraphSourceIdentity.init(ticket:))
        )
        let firstTwo = await store.queryCodemapSelectionGraph(firstTwoQuery)
        guard case let .readyPartial(firstTwoResult) = firstTwo else {
            return XCTFail("Expected the N-root query to fit the aggregate budget.")
        }
        XCTAssertEqual(firstTwoResult.roots.count, 2)
        XCTAssertEqual(
            firstTwoResult.roots.reduce(0) { $0 + $1.result.referenceFailures.count },
            2
        )
        let afterNMaterializations = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterNMaterializations, 2)

        let nPlusOneQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: tickets.map(
            WorkspaceCodemapStoreSelectionGraphSourceIdentity.init(ticket:)
        ))
        let nPlusOne = await store.queryCodemapSelectionGraph(nPlusOneQuery)
        XCTAssertEqual(
            nPlusOne,
            .budget(.referenceFailureLimit(attempted: 3, limit: 2))
        )
        let afterNPlusOneMaterializations = await graphProbe.materializedQueryResultCount()
        XCTAssertEqual(afterNPlusOneMaterializations - afterNMaterializations, 2)

        for loaded in loadedRoots {
            await store.unloadRoot(id: loaded.id)
        }
    }

    func testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second { let first: First }\n"
            ]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let buildGate = ModernCodemapSelectionGraphBuildGate()
        let graphProbe = ModernCodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let first = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let second = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: first.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: firstTicket))
        let blockedGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())
        let oldGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: firstTicket.rootEpoch))
        let firstQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
        ])
        let whileInitialBuildQueued = await store.queryCodemapSelectionGraph(firstQuery)
        XCTAssertEqual(
            whileInitialBuildQueued,
            .busy(.runtime(
                rootEpoch: firstTicket.rootEpoch,
                reason: .rebuilding
            ))
        )

        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: second.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: secondTicket))
        let query = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: firstTicket)
        ])
        let queryClock = ContinuousClock()
        let queryStarted = queryClock.now
        let whileNewerContributionQueued = await store.queryCodemapSelectionGraph(query)
        let queryDuration = queryStarted.duration(to: queryClock.now)
        guard case .stale(.runtime(
            rootEpoch: firstTicket.rootEpoch,
            reason: .staleCurrentness
        )) = whileNewerContributionQueued else {
            return XCTFail("Expected the newer desired contribution to hide the queued older shard.")
        }
        XCTAssertLessThan(queryDuration, .seconds(1))

        let unloadTask = Task {
            await store.unloadRoot(id: loaded.id)
        }
        let afterRevocation = await store.queryCodemapSelectionGraph(query)
        XCTAssertEqual(afterRevocation, .stale(.currentness(firstTicket.rootEpoch)))
        buildGate.release(generation: blockedGeneration)
        buildGate.releaseAll()
        await unloadTask.value

        let oldAccounting = await oldGraph.accounting()
        XCTAssertEqual(oldAccounting.publishedCount, 0)
        XCTAssertEqual(oldAccounting.emptyPublishedCount, 0)
        XCTAssertEqual(
            oldAccounting.currentUnavailableReason,
            .explicitRootUnavailable(.rootUnloaded)
        )

        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFirst = try XCTUnwrap(reloadedFiles.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let reloadedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: reloadedFirst.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: reloadedTicket))
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: reloadedTicket)
            ])
        )
        XCTAssertNotEqual(reloadedTicket.rootEpoch, firstTicket.rootEpoch)
        XCTAssertEqual(graphProbe.factoryCount, 2)
        let oldLifetimeQuery = await store.queryCodemapSelectionGraph(query)
        XCTAssertEqual(oldLifetimeQuery, .stale(.currentness(firstTicket.rootEpoch)))
        await store.unloadRoot(id: reloaded.id)
    }

    func testNonGitDemandBecomesTerminalWithoutSourceReadManifestBuildOrGraphWork() async throws {
        let fixture = try ModernCodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let graphProbe = ModernCodemapSelectionGraphProbe()
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )

        let settled = try await settledResult(store: store, ticket: ticket)
        assertNonGitTerminal(settled)
        let runtime = try fixture.runtime()
        let engine = try runtime.bindingEngine()
        let accounting = await engine.accounting()
        let coordinator = await runtime.coordinator.accounting()

        XCTAssertEqual(accounting.counters.capabilityResolutions, 1)
        XCTAssertEqual(accounting.counters.classifications, 0)
        XCTAssertEqual(accounting.counters.validatedWorktreeReads, 0)
        XCTAssertEqual(accounting.counters.builds, 0)
        XCTAssertEqual(accounting.counters.manifestLoads, 0)
        XCTAssertEqual(accounting.counters.manifestWrites, 0)
        XCTAssertEqual(accounting.counters.materializations, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(coordinator.counters.requests, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)

        await store.unloadRoot(id: loaded.id)
    }

    func testCatalogAdvanceFencesPendingTicketAndExactRegistryRoute() async throws {
        let gate = ModernCodemapResolutionGate()
        let fixture = try ModernCodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let routed = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(ticket.rootEpoch, file.standardizedRelativePath)
        XCTAssertEqual(routed?.identity.fileID, file.id)

        try Self.write("struct Added {}\n", to: root.appendingPathComponent("Sources/Added.swift"))
        let replayTask = Task {
            await store.ensureIndexedFiles(paths: [
                root.appendingPathComponent("Sources/Added.swift").path
            ])
        }

        let routeUnavailable = await routeBecomesUnavailable(
            registry: fixture.registry,
            ticket: ticket,
            relativePath: file.standardizedRelativePath
        )
        XCTAssertTrue(routeUnavailable)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        await gate.release()
        await replayTask.value
        try await assertEngineRootCount(0, fixture: fixture)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadAndReloadFenceOldLifetimeAndDrainModernRootState() async throws {
        let gate = ModernCodemapResolutionGate()
        let fixture = try ModernCodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": "struct Feature {}\n"
        ])
        let store = fixture.makeStore()
        let firstRoot = try await store.loadRoot(path: root.path)
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let firstFile = try XCTUnwrap(firstFiles.first)
        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let unloadTask = Task {
            await store.unloadRoot(id: firstRoot.id)
        }
        let routeUnavailable = await routeBecomesUnavailable(
            registry: fixture.registry,
            ticket: firstTicket,
            relativePath: firstFile.standardizedRelativePath
        )
        XCTAssertTrue(routeUnavailable)
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))
        await gate.release()
        await unloadTask.value

        let secondRoot = try await store.loadRoot(path: root.path)
        let secondFiles = await store.files(inRoot: secondRoot.id)
        let secondFile = try XCTUnwrap(secondFiles.first)
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )

        XCTAssertNotEqual(secondRoot.id, firstRoot.id)
        XCTAssertNotEqual(secondTicket.rootEpoch, firstTicket.rootEpoch)
        await assertStale(store.codemapArtifactDemandStatus(firstTicket))
        try await assertNonGitTerminal(settledResult(store: store, ticket: secondTicket))
        await store.unloadRoot(id: secondRoot.id)
        let engineRootCountIsZero = try await engineRootCountBecomesZero(fixture: fixture)
        XCTAssertTrue(engineRootCountIsZero)
    }

    func testReadyDemandsReuseInjectedRuntimeRegistryAndEngineSingletons() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let firstFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/First.swift"
        })
        let secondFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Second.swift"
        })

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: firstFile.id)
        )
        let firstReady = try await readyResult(
            settledResult(store: store, ticket: firstTicket)
        )
        let secondTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: secondFile.id)
        )
        let secondReady = try await readyResult(
            settledResult(store: store, ticket: secondTicket)
        )

        XCTAssertEqual(firstTicket.rootEpoch, secondTicket.rootEpoch)
        XCTAssertEqual(firstReady.identity.fileID, firstFile.id)
        XCTAssertEqual(firstReady.snapshot.fileID, firstFile.id)
        XCTAssertEqual(try firstReady.handle.artifactKey(), firstReady.snapshot.artifactKey)
        XCTAssertEqual(secondReady.identity.fileID, secondFile.id)
        XCTAssertEqual(secondReady.snapshot.fileID, secondFile.id)
        XCTAssertEqual(try secondReady.handle.artifactKey(), secondReady.snapshot.artifactKey)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        XCTAssertTrue(try fixture.runtime().bindingIntegrationRegistry === fixture.registry)

        let firstCandidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(
                firstTicket.rootEpoch,
                firstFile.standardizedRelativePath
            )
        let secondCandidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(
                secondTicket.rootEpoch,
                secondFile.standardizedRelativePath
            )
        XCTAssertEqual(firstCandidate?.identity.fileID, firstFile.id)
        XCTAssertEqual(secondCandidate?.identity.fileID, secondFile.id)

        await store.unloadRoot(id: loaded.id)
        XCTAssertThrowsError(try firstReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        XCTAssertThrowsError(try secondReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
    }

    func testCancellationAfterReadyRevokesRetainedHandleIdempotently() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let ready = try await readyResult(
            settledResult(store: store, ticket: ticket)
        )
        let runtime = try fixture.runtime()
        let accountingBeforeCancellation = await runtime.artifactStore.accounting()
        XCTAssertEqual(accountingBeforeCancellation.activeLeaseCount, 1)
        XCTAssertGreaterThan(accountingBeforeCancellation.activeLeaseBytes, 0)

        let firstCancellation = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertTrue(firstCancellation)
        await assertCancelled(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let accountingAfterFirstCancellation = await runtime.artifactStore.accounting()
        XCTAssertEqual(accountingAfterFirstCancellation.activeLeaseCount, 1)
        XCTAssertEqual(
            accountingAfterFirstCancellation.activeLeaseBytes,
            accountingBeforeCancellation.activeLeaseBytes
        )

        let secondCancellation = await store.cancelCodemapArtifactDemand(ticket)
        XCTAssertTrue(secondCancellation)
        await assertCancelled(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let accountingAfterSecondCancellation = await runtime.artifactStore.accounting()
        XCTAssertEqual(accountingAfterSecondCancellation.activeLeaseCount, 1)
        XCTAssertEqual(
            accountingAfterSecondCancellation.activeLeaseBytes,
            accountingBeforeCancellation.activeLeaseBytes
        )

        await store.unloadRoot(id: loaded.id)
    }

    func testReadyCancellationCleanupCannotCancelSamePathSuccessor() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let cancellationGate = ModernCodemapSuspensionGate()
        let successorPublicationGate = ModernCodemapArmableSuspensionGate()
        let graphProbe = ModernCodemapSelectionGraphProbe()
        addTeardownBlock {
            await cancellationGate.release()
            await successorPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            cancellationCleanupHook: { _ in
                await cancellationGate.enterAndWait()
            },
            readyPublicationHook: { _ in
                await successorPublicationGate.enterIfArmedAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let cancelledTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let cancelledReady = try await readyResult(
            settledResult(store: store, ticket: cancelledTicket)
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: cancelledTicket)
            ])
        )
        let epochGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: cancelledTicket.rootEpoch))
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await successorPublicationGate.arm()

        let cancellationTask = Task {
            await store.cancelCodemapArtifactDemand(cancelledTicket)
        }
        let cancellationEntered = await cancellationGate.waitUntilEntered()
        XCTAssertTrue(cancellationEntered)
        await assertCancelled(store.codemapArtifactDemandStatus(cancelledTicket))
        XCTAssertThrowsError(try cancelledReady.handle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }

        let successorTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        XCTAssertNotEqual(successorTicket, cancelledTicket)
        let successorPublicationEntered = await successorPublicationGate.waitUntilEntered()
        XCTAssertTrue(successorPublicationEntered)

        await cancellationGate.release()
        let cancellationResult = await cancellationTask.value
        XCTAssertTrue(cancellationResult)
        await successorPublicationGate.release()
        let successorReady = try await readyResult(
            settledResult(store: store, ticket: successorTicket)
        )
        XCTAssertEqual(successorReady.ticket, successorTicket)
        XCTAssertEqual(try successorReady.handle.artifactKey(), successorReady.snapshot.artifactKey)
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: successorTicket)
            ])
        )
        XCTAssertTrue(graphProbe.graph(rootEpoch: successorTicket.rootEpoch) === epochGraph)
        XCTAssertEqual(graphProbe.factoryCount, 1)

        await store.unloadRoot(id: loaded.id)
        let reloaded = try await store.loadRoot(path: root.path)
        let reloadedFiles = await store.files(inRoot: reloaded.id)
        let reloadedFile = try XCTUnwrap(reloadedFiles.first)
        let reloadedTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: reloadedFile.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: reloadedTicket))
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: reloadedTicket)
            ])
        )
        XCTAssertNotEqual(reloadedTicket.rootEpoch, successorTicket.rootEpoch)
        XCTAssertEqual(graphProbe.factoryCount, 2)
        await store.unloadRoot(id: reloaded.id)
    }

    func testWatcherRenamePairFencesOnlyOldAndNewPaths() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Old.swift": "struct Old {}\n",
                "Sources/Unrelated.swift": "func unrelated() {}\n"
            ]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let graphProbe = ModernCodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let old = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Old.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let oldTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: old.id))
        let oldReady = try await readyResult(settledResult(store: store, ticket: oldTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        let unrelatedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: unrelated.standardizedRelativePath
        ))
        let unrelatedPresentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: unrelatedTicket, logicalPath: unrelatedPath)
            ])
        )
        let unrelatedQuery = WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
            WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
        ])
        _ = try await readyGraphQuery(store: store, query: unrelatedQuery)

        try FileManager.default.moveItem(
            at: root.appendingPathComponent(old.standardizedRelativePath),
            to: root.appendingPathComponent("Sources/New.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [
                .fileRemoved(old.standardizedRelativePath),
                .fileAdded("Sources/New.swift")
            ]
        )

        await assertStale(store.codemapArtifactDemandStatus(oldTicket))
        XCTAssertThrowsError(try oldReady.handle.artifactKey())
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(unrelatedPresentation)
        )
        _ = try await readyGraphQuery(store: store, query: unrelatedQuery)
        XCTAssertEqual(graphProbe.factoryCount, 1)

        let renamedValue = await store.file(rootID: loaded.id, relativePath: "Sources/New.swift")
        let renamed = try XCTUnwrap(renamedValue)
        let renamedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: renamed.id))
        XCTAssertGreaterThan(renamedTicket.pathGeneration, oldTicket.pathGeneration)
        _ = try await readyResult(settledResult(store: store, ticket: renamedTicket))
        await store.unloadRoot(id: loaded.id)
    }

    func testPathRepairPublishesReadyContributionCompletedDuringRebuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Affected.swift": "struct Affected {}\n",
                "Sources/Late.swift": "struct Late { let survivor: Survivor }\n",
                "Sources/Survivor.swift": "struct Survivor {}\n"
            ]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let buildGate = ModernCodemapSelectionGraphBuildGate()
        let graphProbe = ModernCodemapSelectionGraphProbe(buildGate: buildGate)
        addTeardownBlock {
            buildGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let affected = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Affected.swift" })
        let late = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Late.swift" })
        let survivor = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Survivor.swift" })
        let survivorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: survivor.id))
        _ = try await readyResult(settledResult(store: store, ticket: survivorTicket))
        let initialGeneration = try XCTUnwrap(buildGate.waitUntilFirstBlocked())
        buildGate.release(generation: initialGeneration)
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: survivorTicket)
            ])
        )

        try Self.write(
            "struct Affected { let changed = true }\n",
            to: root.appendingPathComponent(affected.standardizedRelativePath)
        )
        let repairTask = Task {
            await store.replayObservedFileSystemDeltas(
                rootID: loaded.id,
                deltas: [.fileModified(affected.standardizedRelativePath, nil)]
            )
        }
        let repairGeneration = try XCTUnwrap(
            buildGate.waitUntilBlocked(after: initialGeneration)
        )

        let lateTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: late.id))
        _ = try await readyResult(settledResult(store: store, ticket: lateTicket))
        buildGate.release(generation: repairGeneration)
        buildGate.releaseAll()
        await repairTask.value

        let result = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: lateTicket)
            ])
        )
        let rootResult = try XCTUnwrap(result.roots.first)
        XCTAssertEqual(rootResult.result.publishedSummary.nodeCount, 2)
        XCTAssertTrue(rootResult.result.sourceCoverage.contains {
            $0.source.fileID == late.id && $0.state == .covered
        })
        await store.unloadRoot(id: loaded.id)
    }

    func testWatcherModifyDeleteAndGapAwaitPresentationGraphAndEngineFences() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Affected.swift": "func affected() {}\n",
                "Sources/Unrelated.swift": "func unrelated() {}\n"
            ]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let graphProbe = ModernCodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let affected = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Affected.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let affectedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: affected.id))
        let affectedReady = try await readyResult(settledResult(store: store, ticket: affectedTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        let unrelatedPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: unrelated.standardizedRelativePath
        ))
        let unrelatedPresentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: unrelatedTicket, logicalPath: unrelatedPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: affectedTicket),
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: affectedTicket.rootEpoch))

        try Self.write(
            "struct Affected { let changed = true }\n",
            to: root.appendingPathComponent(affected.standardizedRelativePath)
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified(affected.standardizedRelativePath, nil)]
        )

        await assertStale(store.codemapArtifactDemandStatus(affectedTicket))
        XCTAssertThrowsError(try affectedReady.handle.artifactKey())
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await renderedPresentationEntries(
            store.renderCodemapPresentation(unrelatedPresentation)
        )
        let unrelatedGraph = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )
        XCTAssertEqual(unrelatedGraph.roots.first?.rootEpoch, unrelatedTicket.rootEpoch)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        try await assertEngineRootCount(1, fixture: fixture)

        let successorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: affected.id))
        XCTAssertGreaterThan(successorTicket.pathGeneration, affectedTicket.pathGeneration)
        _ = try await readyResult(settledResult(store: store, ticket: successorTicket))
        try FileManager.default.removeItem(at: root.appendingPathComponent(unrelated.standardizedRelativePath))
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileRemoved(unrelated.standardizedRelativePath)]
        )
        await assertStale(store.codemapArtifactDemandStatus(unrelatedTicket))
        XCTAssertThrowsError(try unrelatedReady.handle.artifactKey())

        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: successorTicket.rootEpoch.rootLifetimeID,
            deltas: [],
            requiresFullResync: true
        )
        await assertStale(store.codemapArtifactDemandStatus(successorTicket))
        try await assertEngineRootCount(1, fixture: fixture)
        let graphAccounting = await graph.accounting()
        XCTAssertEqual(graphAccounting.currentUnavailableReason, .explicitRootUnavailable(.authorityRevoked))
        XCTAssertEqual(graphAccounting.activeRebuildCount, 0)
        let route = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            successorTicket.rootEpoch,
            affected.standardizedRelativePath
        )
        XCTAssertNil(route)
        await store.unloadRoot(id: loaded.id)
    }

    func testStoreEditRenameAndDeleteAwaitModernAuthorityFenceBeforeReturning() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Mutable.swift": "struct Mutable {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let graphProbe = ModernCodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let initialFiles = await store.files(inRoot: loaded.id)
        let mutable = try XCTUnwrap(initialFiles.first { $0.standardizedRelativePath == "Sources/Mutable.swift" })
        let unrelated = try XCTUnwrap(initialFiles.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })
        let mutableTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: mutable.id))
        _ = try await readyResult(settledResult(store: store, ticket: mutableTicket))
        let unrelatedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: unrelated.id))
        let unrelatedReady = try await readyResult(settledResult(store: store, ticket: unrelatedTicket))
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )

        _ = try await store.editFile(
            rootID: loaded.id,
            relativePath: mutable.standardizedRelativePath,
            newContent: "struct Mutable { let edited = true }\n"
        )
        await assertStale(store.codemapArtifactDemandStatus(mutableTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)

        let editedFileValue = await store.file(
            rootID: loaded.id,
            relativePath: mutable.standardizedRelativePath
        )
        let editedFile = try XCTUnwrap(editedFileValue)
        let editedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: editedFile.id))
        _ = try await readyResult(settledResult(store: store, ticket: editedTicket))
        try await store.moveFile(
            rootID: loaded.id,
            from: mutable.standardizedRelativePath,
            to: "Sources/Renamed.swift"
        )
        await assertStale(store.codemapArtifactDemandStatus(editedTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)

        let renamedFileValue = await store.file(
            rootID: loaded.id,
            relativePath: "Sources/Renamed.swift"
        )
        let renamedFile = try XCTUnwrap(renamedFileValue)
        let renamedTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: renamedFile.id))
        _ = try await readyResult(settledResult(store: store, ticket: renamedTicket))
        try await store.deleteFile(rootID: loaded.id, relativePath: "Sources/Renamed.swift")
        await assertStale(store.codemapArtifactDemandStatus(renamedTicket))
        XCTAssertEqual(try unrelatedReady.handle.artifactKey(), unrelatedReady.snapshot.artifactKey)
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: unrelatedTicket)
            ])
        )
        try await assertEngineRootCount(1, fixture: fixture)
        XCTAssertEqual(graphProbe.factoryCount, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testCheckoutAndCatalogAdvanceFenceOldAuthorityBeforeSuccessorDemand() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let graphProbe = ModernCodemapSelectionGraphProbe()
        let scanStarts = ModernCodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        await store.setCodemapScanWillStartHandlerForTesting { _ in scanStarts.increment() }
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let feature = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: feature.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: feature.standardizedRelativePath
        ))
        let presentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: logicalPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: ticket)
            ])
        )
        let oldGraph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))

        let service = WorkspaceCheckoutRefreshService(
            store: store,
            searchService: WorkspaceSearchService()
        )
        _ = await service.refreshAfterCheckoutMutation(rootPath: root.path)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey())
        if case .ready = await store.renderCodemapPresentation(presentation) {
            XCTFail("Checkout must revoke the retained presentation before returning.")
        }
        try await assertEngineRootCount(1, fixture: fixture)
        let oldGraphAccounting = await oldGraph.accounting()
        XCTAssertEqual(oldGraphAccounting.activeRebuildCount, 0)
        XCTAssertEqual(scanStarts.value, 0)

        let successorFileValue = await store.file(
            rootID: loaded.id,
            relativePath: feature.standardizedRelativePath
        )
        let successorFile = try XCTUnwrap(successorFileValue)
        let successorTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: successorFile.id))
        XCTAssertGreaterThan(successorTicket.catalogGeneration, ticket.catalogGeneration)
        let successorResult = try await settledResult(store: store, ticket: successorTicket)
        guard case .ready = successorResult else {
            return XCTFail("Expected checkout successor ready, got \(successorResult).")
        }
        _ = try await store.createFile(
            rootID: loaded.id,
            relativePath: "Sources/CatalogReplacement.swift",
            content: "struct CatalogReplacement {}\n"
        )
        await assertStale(store.codemapArtifactDemandStatus(successorTicket))
        try await assertEngineRootCount(1, fixture: fixture)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadAwaitsPresentationGraphAndEngineRevocationBeforeReturning() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let fixture = try ModernCodemapStoreFixture(name: #function)
        let graphProbe = ModernCodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let feature = try XCTUnwrap(loadedFiles.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: feature.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "Workspace",
            standardizedRelativePath: feature.standardizedRelativePath
        ))
        let presentation = try await frozenPresentationBundle(
            store.freezeCodemapPresentation([
                WorkspaceCodemapPresentationRequest(ticket: ticket, logicalPath: logicalPath)
            ])
        )
        _ = try await readyGraphQuery(
            store: store,
            query: WorkspaceCodemapStoreSelectionGraphQuery(selectedSources: [
                WorkspaceCodemapStoreSelectionGraphSourceIdentity(ticket: ticket)
            ])
        )
        let graph = try XCTUnwrap(graphProbe.graph(rootEpoch: ticket.rootEpoch))

        await store.unloadRoot(id: loaded.id)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        XCTAssertThrowsError(try ready.handle.artifactKey())
        if case .ready = await store.renderCodemapPresentation(presentation) {
            XCTFail("Unload must revoke the retained presentation before returning.")
        }
        let graphAccounting = await graph.accounting()
        XCTAssertEqual(graphAccounting.currentUnavailableReason, .explicitRootUnavailable(.rootUnloaded))
        XCTAssertEqual(graphAccounting.activeRebuildCount, 0)
        try await assertEngineRootCount(0, fixture: fixture)
        let route = await fixture.registry.makeBindingCatalogClient().resolveManifestBinding(
            ticket.rootEpoch,
            feature.standardizedRelativePath
        )
        XCTAssertNil(route)
    }

    private func pendingTicket(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandTicket {
        guard case let .pending(ticket) = result else {
            throw ModernCodemapStoreTestError.expectedPending
        }
        return ticket
    }

    private func readyResult(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandReady {
        guard case let .ready(ready) = result else {
            throw ModernCodemapStoreTestError.expectedReady
        }
        return ready
    }

    private func frozenPresentationBundle(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition
    ) throws -> WorkspaceCodemapFrozenPresentationBundle {
        guard case let .ready(bundle) = disposition else {
            throw ModernCodemapStoreTestError.expectedFrozenPresentationBundle
        }
        return bundle
    }

    private func renderedPresentationEntries(
        _ disposition: WorkspaceCodemapPresentationRenderDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [WorkspaceCodemapRenderedPresentationEntry] {
        guard case let .ready(entries) = disposition else {
            if case let .unavailable(reason) = disposition {
                XCTFail(
                    "Expected rendered presentation entries, got \(reason).",
                    file: file,
                    line: line
                )
            }
            throw ModernCodemapStoreTestError.expectedRenderedPresentationEntries
        }
        return entries
    }

    private func assertPresentationFreezeUnavailable(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition,
        equals expected: WorkspaceCodemapPresentationFreezeUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = disposition else {
            return XCTFail(
                "Expected presentation freeze unavailability.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertPresentationRenderUnavailable(
        _ disposition: WorkspaceCodemapPresentationRenderDisposition,
        equals expected: WorkspaceCodemapPresentationRenderUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = disposition else {
            return XCTFail(
                "Expected presentation render unavailability.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func readyGraphQuery(
        store: WorkspaceFileContextStore,
        query: WorkspaceCodemapStoreSelectionGraphQuery,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapStoreSelectionGraphQueryResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var latest: WorkspaceCodemapStoreSelectionGraphQueryDisposition?
        while clock.now < deadline {
            let disposition = await store.queryCodemapSelectionGraph(query)
            latest = disposition
            if case let .readyPartial(result) = disposition {
                return result
            }
            switch disposition {
            case .busy, .stale(.runtime), .unavailable(.runtime):
                try await Task.sleep(for: .milliseconds(10))
            case .readyPartial, .unavailable, .stale, .budget:
                throw ModernCodemapStoreTestError.expectedReadyGraph(disposition)
            }
        }
        if let latest {
            throw ModernCodemapStoreTestError.expectedReadyGraph(latest)
        }
        throw ModernCodemapStoreTestError.timedOut
    }

    private func settledResult(
        store: WorkspaceFileContextStore,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapArtifactDemandResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let result = await store.codemapArtifactDemandStatus(ticket)
            if case .pending = result {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return result
        }
        throw ModernCodemapStoreTestError.timedOut
    }

    private func routeBecomesUnavailable(
        registry: WorkspaceCodemapBindingIntegrationRegistry,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        relativePath: String
    ) async -> Bool {
        for _ in 0 ..< 500 {
            let candidate = await registry.makeBindingCatalogClient()
                .resolveManifestBinding(ticket.rootEpoch, relativePath)
            if candidate == nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func assertEngineRootCount(
        _ expected: Int,
        fixture: ModernCodemapStoreFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let engine = try fixture.runtime().bindingEngine()
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.rootCount, expected, file: file, line: line)
    }

    private func engineRootCountBecomesZero(
        fixture: ModernCodemapStoreFixture
    ) async throws -> Bool {
        let engine = try fixture.runtime().bindingEngine()
        for _ in 0 ..< 500 {
            if await engine.accounting().rootCount == 0 { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await engine.accounting().rootCount == 0
    }

    private func assertNonGitTerminal(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.gitTerminal(.nonGit)) = result else {
            return XCTFail("Expected terminal non-Git unavailability.", file: file, line: line)
        }
    }

    private func assertCancelled(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.cancelled) = result else {
            return XCTFail("Expected cancelled unavailability.", file: file, line: line)
        }
    }

    private func assertStale(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.staleCurrentness) = result else {
            return XCTFail("Expected stale currentness.", file: file, line: line)
        }
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum ModernCodemapStoreTestError: Error {
    case expectedFrozenPresentationBundle
    case expectedPending
    case expectedReady
    case expectedRenderedPresentationEntries
    case expectedReadyGraph(WorkspaceCodemapStoreSelectionGraphQueryDisposition)
    case timedOut
}

private final class ModernCodemapStoreFixture: @unchecked Sendable {
    let registry = WorkspaceCodemapBindingIntegrationRegistry()
    let providerAccessCount = ModernCodemapLockedCounter()
    let runtimeFactoryCount = ModernCodemapLockedCounter()
    let engineFactoryCount = ModernCodemapLockedCounter()
    let manifestReadCount = ModernCodemapLockedCounter()
    let buildCount = ModernCodemapLockedCounter()

    private let sandbox: URL
    private let runtimeProvider: CodeMapArtifactRuntimeProvider

    init(name: String, resolutionGate: ModernCodemapResolutionGate? = nil) throws {
        let sandbox = try Self.makeSandbox(name: name)
        let artifactRoot = try Self.makeSecureDirectory(in: sandbox, named: "artifacts")
        let registry = registry
        let runtimeFactoryCount = runtimeFactoryCount
        let engineFactoryCount = engineFactoryCount
        let manifestReadCount = manifestReadCount
        let buildCount = buildCount
        let defaultBuilder = CodeMapArtifactBuilderClient()
        runtimeProvider = CodeMapArtifactRuntimeProvider {
            runtimeFactoryCount.increment()
            return try CodeMapArtifactRuntime(
                rootURL: artifactRoot,
                manifestStoreHooks: CodeMapRootManifestStoreHooks(
                    afterReadAdmission: {
                        manifestReadCount.increment()
                    }
                ),
                builder: CodeMapArtifactBuilderClient(execute: { input, ownerID, priority in
                    buildCount.increment()
                    return try await defaultBuilder.execute(input, ownerID, priority)
                }),
                bindingIntegrationRegistry: registry,
                bindingEngineFactory: { runtime in
                    engineFactoryCount.increment()
                    return WorkspaceCodemapBindingEngine(
                        runtime: runtime,
                        capabilityService: WorkspaceCodemapGitCapabilityService(
                            namespaceSalt: Data(
                                repeating: 0x6C,
                                count: GitBlobRepositoryNamespace.saltByteCount
                            ),
                            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                                beforeResolution: {
                                    await resolutionGate?.enterAndWait()
                                }
                            )
                        ),
                        sourceReader: registry.makeValidatedSourceReaderClient(),
                        catalogClient: registry.makeBindingCatalogClient()
                    )
                }
            )
        }
        self.sandbox = sandbox
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeStore(
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
        selectionGraphQueryBudgetPolicy: WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy = .initial,
        cancellationCleanupHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        readyPublicationHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in }
    ) -> WorkspaceFileContextStore {
        let providerAccessCount = providerAccessCount
        let runtimeProvider = runtimeProvider
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerAccessCount.increment()
                return try runtimeProvider.runtime()
            },
            selectionGraphFactory: selectionGraphFactory,
            selectionGraphQueryBudgetPolicy: selectionGraphQueryBudgetPolicy,
            modernCodemapCancellationCleanupHook: cancellationCleanupHook,
            modernCodemapReadyPublicationHook: readyPublicationHook
        )
    }

    func makePlainRoot(files: [String: String]) throws -> URL {
        let root = sandbox.appendingPathComponent(
            "plain-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            try Self.write(
                contents,
                to: root.appendingPathComponent(relativePath)
            )
        }
        return root
    }

    func runtime() throws -> CodeMapArtifactRuntime {
        try runtimeProvider.runtime()
    }

    func shutdown() async {
        if let runtime = try? runtimeProvider.runtime(),
           let engine = try? runtime.bindingEngine()
        {
            await engine.shutdown()
        }
    }

    static func makeSandbox(name: String) throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceFileContextStoreModernCodemapSeamTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    private static func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try directory.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private final class ModernCodemapSelectionGraphProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let admission = CodeMapSelectionGraphAdmission(policy: .init(
        maximumActiveReservationCount: 8,
        maximumReservedBindingCount: 100_000
    ))
    private let buildGate: ModernCodemapSelectionGraphBuildGate?
    private let runtimePolicy: WorkspaceCodemapSelectionGraphRuntimePolicy
    private var graphsByRootEpoch: [WorkspaceCodemapRootEpoch: WorkspaceCodemapSelectionGraph] = [:]
    private var factoryInvocationCount = 0

    init(
        buildGate: ModernCodemapSelectionGraphBuildGate? = nil,
        runtimePolicy: WorkspaceCodemapSelectionGraphRuntimePolicy = .initial
    ) {
        self.buildGate = buildGate
        self.runtimePolicy = runtimePolicy
    }

    var factory: WorkspaceCodemapSelectionGraphFactory {
        WorkspaceCodemapSelectionGraphFactory { [self] rootEpoch in
            lock.withLock {
                factoryInvocationCount += 1
                let graph = WorkspaceCodemapSelectionGraph(
                    rootEpoch: rootEpoch,
                    policy: runtimePolicy,
                    admission: admission,
                    diagnostics: buildGate?.diagnostics ?? .none
                )
                graphsByRootEpoch[rootEpoch] = graph
                return graph
            }
        }
    }

    var factoryCount: Int {
        lock.withLock { factoryInvocationCount }
    }

    func graph(rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph? {
        lock.withLock { graphsByRootEpoch[rootEpoch] }
    }

    func waitUntilPublished(
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let graph = graph(rootEpoch: rootEpoch),
               await (graph.accounting()).publishedSummary != nil
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func materializedQueryResultCount() async -> UInt64 {
        let graphs = lock.withLock { Array(graphsByRootEpoch.values) }
        var count: UInt64 = 0
        for graph in graphs {
            await count += (graph.accounting()).materializedQueryResultCount
        }
        return count
    }
}

private final class ModernCodemapSelectionGraphBuildGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blockedGenerations: [UInt64] = []
    private var releasedGenerations = Set<UInt64>()
    private var isOpen = false

    var diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics {
        WorkspaceCodemapSelectionGraphRuntimeDiagnostics { [self] event in
            guard event.kind == .beforePublication else { return }
            block(generation: event.key.contributionGeneration.rawValue)
        }
    }

    func waitUntilFirstBlocked() -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 10)
        while blockedGenerations.isEmpty {
            guard condition.wait(until: deadline) else { return nil }
        }
        return blockedGenerations[0]
    }

    func waitUntilBlocked(after generation: UInt64) -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 10)
        while !blockedGenerations.contains(where: { $0 > generation }) {
            guard condition.wait(until: deadline) else { return nil }
        }
        return blockedGenerations.first(where: { $0 > generation })
    }

    func release(generation: UInt64) {
        condition.lock()
        releasedGenerations.insert(generation)
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    private func block(generation: UInt64) {
        condition.lock()
        guard !isOpen else {
            condition.unlock()
            return
        }
        blockedGenerations.append(generation)
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 10)
        while !isOpen, !releasedGenerations.contains(generation) {
            guard condition.wait(until: deadline) else { break }
        }
        condition.unlock()
    }
}

private final class ModernCodemapLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private actor ModernCodemapSuspensionGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ModernCodemapArmableSuspensionGate {
    private var armed = false
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
    }

    func enterIfArmedAndWait() async {
        guard armed else { return }
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ModernCodemapResolutionGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var resolutionCount = 0

    func enterAndWait() async {
        resolutionCount += 1
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
