import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapBindingEngineTests: XCTestCase {
    private enum WarmManifestCandidateState: CaseIterable {
        case stagedOnly
        case stagedAndUnstaged
        case untrackedReplacement
        case conflict
        case checkoutTransform
    }

    private var retainedRepositoryFixtures: [ReviewGitRepositoryFixture] = []

    func testBulkCancellationTransitionsEmitExactPathFreeAggregateTelemetry() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/AlreadyCancelled.swift": "struct AlreadyCancelled {}\n",
                "Sources/Active.swift": "struct Active {}\n",
                "Sources/Queued.swift": "struct Queued {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )

        for operation in EngineBulkCancellationOperation.allCases {
            let gate = EngineMultiEntryGate()
            let hookEvents = EngineHookEvents()
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                policy: WorkspaceCodemapBindingEnginePolicy(
                    maximumActiveRequestCountPerRoot: 2,
                    maximumActiveRequestCount: 2,
                    maximumQueuedRequestCountPerRoot: 1,
                    maximumQueuedRequestCount: 1,
                    maximumActiveTaskCountPerRoot: 2,
                    maximumActiveTaskCount: 2,
                    maximumConcurrentMaterializationCountPerRoot: 2,
                    maximumConcurrentMaterializationCount: 2
                ),
                hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
                sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                    await gate.enter()
                    try Task.checkCancellation()
                    throw FileSystemError.failedToReadFile
                }
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected registration for \(operation).")
            }
            for path in ["AlreadyCancelled.swift", "Active.swift", "Queued.swift"] {
                try repository.write(
                    "struct Dirty { let operation = \"\(operation)\" }\n",
                    to: "Sources/\(path)",
                    at: root
                )
            }

            let alreadyCancelled = Task {
                await fixture.engine.demand(fixture.demand(path: "Sources/AlreadyCancelled.swift"))
            }
            let active = Task {
                await fixture.engine.demand(fixture.demand(path: "Sources/Active.swift"))
            }
            let initialReadsEntered = await gate.waitUntilEntered(2)
            XCTAssertTrue(initialReadsEntered)
            let queued = Task {
                await fixture.engine.demand(fixture.demand(path: "Sources/Queued.swift"))
            }
            let requestQueued = await waitForEngineCondition {
                await fixture.engine.accounting().queuedRequestCount == 1
            }
            XCTAssertTrue(requestQueued)

            alreadyCancelled.cancel()
            guard case .cancelled = await alreadyCancelled.value else {
                return XCTFail("Expected caller cancellation for \(operation).")
            }
            XCTAssertTrue(hookEvents.wait(kind: .cancellation, numericValue: 1))
            let preBulk = await fixture.engine.accounting()
            XCTAssertEqual(preBulk.activeRequestCount, 2)
            XCTAssertEqual(preBulk.queuedRequestCount, 0)
            XCTAssertEqual(preBulk.counters.cancellations, 1)

            let shutdown: Task<Void, Never>?
            switch operation {
            case .pathInvalidation:
                let result = await fixture.engine.invalidateModified(
                    rootEpoch: fixture.rootEpoch,
                    standardizedRelativePaths: [
                        "Sources/AlreadyCancelled.swift",
                        "Sources/Active.swift",
                        "Sources/Queued.swift"
                    ]
                )
                XCTAssertEqual(result.cancelledRequestCount, 2)
                shutdown = nil
            case .authorityInvalidation:
                let result = await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
                XCTAssertEqual(result.cancelledRequestCount, 2)
                shutdown = nil
            case .unload:
                await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
                shutdown = nil
            case .shutdown:
                shutdown = Task { await fixture.engine.shutdown() }
            }

            XCTAssertTrue(hookEvents.wait(kind: .cancellation, numericValue: 2))
            let bulkAccounting = await fixture.engine.accounting()
            XCTAssertEqual(bulkAccounting.counters.cancellations, 3)
            let cancellationEvents = hookEvents.values(kind: .cancellation)
            XCTAssertEqual(cancellationEvents.map(\.numericValue), [1, 2])
            XCTAssertTrue(cancellationEvents.allSatisfy {
                $0.rootEpoch == nil && $0.artifactStorageDigest == nil
            })

            await gate.releaseAll()
            await shutdown?.value
            guard case .cancelled = await active.value,
                  case .cancelled = await queued.value
            else { return XCTFail("Expected bulk cancellation for \(operation).") }
            let drained = await waitForEngineCondition {
                await fixture.engine.accounting().activeRequestCount == 0
            }
            XCTAssertTrue(drained)
            let finalAccounting = await fixture.engine.accounting()
            XCTAssertEqual(finalAccounting.counters.cancellations, 3)
            XCTAssertEqual(hookEvents.count(kind: .cancellation), 2)
            XCTAssertEqual(hookEvents.numericTotal(kind: .cancellation), 3)
            await fixture.engine.shutdown()
        }
    }

    func testNonGitRootBecomesUnavailableWithoutArtifactManifestOrBuildWork() async throws {
        let sandbox = try makeRepositoryFixture(name: #function)
        let root = sandbox.sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let artifactRoot = try makeSecureDirectory(in: sandbox.sandbox, named: "artifacts")
        let buildCounter = EngineAsyncCounter()
        let manifestReads = EngineLockedCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { manifestReads.increment() }
            ),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                return .readyNoSymbols
            })
        )
        let service = capabilityService()
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: service,
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                throw FileSystemError.failedToReadFile
            }
        )
        addTeardownBlock { await engine.shutdown() }
        let result = await engine.registerRoot(WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        ))
        guard case let .unavailable(state) = result,
              case .terminalUnavailable(.nonGit) = state
        else { return XCTFail("Expected terminal non-Git capability.") }
        let buildCount = await buildCounter.value
        XCTAssertEqual(buildCount, 0)
        XCTAssertEqual(manifestReads.value, 0)
        let coordinator = await runtime.coordinator.accounting()
        XCTAssertEqual(coordinator.counters.requests, 0)
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.unavailableRootCount, 1)
    }

    func testOneRootServesMultipleLanguagePipelines() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "struct Feature {}\n",
                "Sources/Feature.ts": "export interface Feature {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered(adoptedReadyCount: 0) = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected language-neutral registration.")
        }

        async let swiftResult = fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.swift", language: .swift)
        )
        async let typeScriptResult = fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.ts", language: .ts)
        )
        guard case .ready = await swiftResult,
              case .ready = await typeScriptResult
        else { return XCTFail("Expected both language pipelines to become ready.") }

        let bundleValue = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let bundle = try XCTUnwrap(bundleValue)
        XCTAssertEqual(Set(bundle.entries.map(\.standardizedRelativePath)), [
            "Sources/Feature.swift",
            "Sources/Feature.ts"
        ])
    }

    func testPipelineManifestsRemainDistinct() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "struct Feature {}\n",
                "Sources/Feature.ts": "export interface Feature {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.swift", language: .swift)
        ), case .ready = await fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.ts", language: .ts)
        ) else { return XCTFail("Expected both pipeline manifests to be written.") }

        let capability = try await eligible(fixture.capabilityService.resolve(
            root: fixture.registration.capabilityRequest
        ))
        let swiftNamespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: SyntaxManager.shared.pipelineIdentity(
                for: .swift,
                decoderPolicy: .workspaceAutomaticV1
            )
        )
        let typeScriptNamespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: SyntaxManager.shared.pipelineIdentity(
                for: .ts,
                decoderPolicy: .workspaceAutomaticV1
            )
        )
        XCTAssertNotEqual(swiftNamespace.storageDigestHex, typeScriptNamespace.storageDigestHex)
        let swiftManifest = try await runtime.manifestStore.loadCurrentManifest(
            namespace: swiftNamespace,
            currentAuthority: CodeMapRootManifestAuthority(
                namespace: swiftNamespace,
                token: capability.repositoryAuthority
            )
        )
        let typeScriptManifest = try await runtime.manifestStore.loadCurrentManifest(
            namespace: typeScriptNamespace,
            currentAuthority: CodeMapRootManifestAuthority(
                namespace: typeScriptNamespace,
                token: capability.repositoryAuthority
            )
        )
        guard case let .hit(swiftSnapshot) = swiftManifest,
              case let .hit(typeScriptSnapshot) = typeScriptManifest
        else { return XCTFail("Expected distinct persisted pipeline manifests.") }
        XCTAssertEqual(swiftSnapshot.records.map(\.repositoryRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(typeScriptSnapshot.records.map(\.repositoryRelativePath), ["Sources/Feature.ts"])
    }

    func testRootInvalidationRevokesEveryPipeline() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "struct Feature {}\n",
                "Sources/Feature.ts": "export interface Feature {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard await isReady(fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.swift", language: .swift)
        )), await isReady(fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.ts", language: .ts)
        )) else {
            return XCTFail("Expected both language pipelines to become ready before invalidation.")
        }
        let frozenBeforeInvalidation = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let retainedBundle = try XCTUnwrap(frozenBeforeInvalidation)
        XCTAssertEqual(
            Set(retainedBundle.entries.map(\.standardizedRelativePath)),
            ["Sources/Feature.swift", "Sources/Feature.ts"]
        )
        retainedBundle.close()

        let result = await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
        XCTAssertFalse(result.manifestWriteFailed)
        let snapshotAfterInvalidation = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        let revokedSnapshot = try XCTUnwrap(snapshotAfterInvalidation)
        XCTAssertFalse(revokedSnapshot.authorityIsCurrent)
        XCTAssertTrue(revokedSnapshot.entries.isEmpty)
        let bundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(bundle)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.dirtyManifestCount, 0)
    }

    func testCleanColdBuildPublishesManifestAndWarmRegistrationAdoptsWithoutMaterialization() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Clean.swift": "struct Clean {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let cold = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered(adoptedReadyCount: 0) = await cold.engine.registerRoot(cold.registration) else {
            return XCTFail("Expected cold registration.")
        }
        guard case .ready = await cold.engine.demand(cold.demand(path: "Sources/Clean.swift")) else {
            return XCTFail("Expected clean ready demand.")
        }
        let coldAccounting = await cold.engine.accounting()
        XCTAssertEqual(coldAccounting.counters.materializations, 1)
        XCTAssertEqual(coldAccounting.counters.manifestWrites, 1)
        XCTAssertEqual(coldAccounting.counters.builds, 1)
        await cold.engine.unloadRoot(rootEpoch: cold.rootEpoch)

        let sourceReadCounter = EngineAsyncCounter()
        let trappingReader = WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
            await sourceReadCounter.increment()
            throw CancellationError()
        }
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            sourceReaderOverride: trappingReader
        )
        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(path: "Sources/Clean.swift"))) else {
            return XCTFail("Expected first demand to adopt the warm manifest.")
        }
        let warmAccounting = await warm.engine.accounting()
        XCTAssertEqual(warmAccounting.counters.materializations, 0)
        XCTAssertEqual(warmAccounting.counters.builds, 0)
        XCTAssertEqual(warmAccounting.counters.manifestAdoptions, 1)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        guard case let .ready(source, _, _) = try XCTUnwrap(snapshot.entries.first).state else {
            return XCTFail("Expected adopted ready entry.")
        }
        XCTAssertEqual(source, .cleanManifest)
    }

    func testPathInvalidationDuringBlockedWarmAdoptionRemainsRetryable() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Warm.swift": "struct Warm {}\n",
                "Sources/Trigger.swift": "struct Trigger {}\n",
                "Sources/Other.swift": "struct Other {}\n"
            ]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected warm manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let adoptionGate = EngineFirstResolutionGate()
        let warmRuntime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { await adoptionGate.enter() }
            )
        )
        let warm = try await makeEngineFixture(root: root, runtime: warmRuntime)
        _ = await warm.engine.registerRoot(warm.registration)
        let trigger = Task {
            await warm.engine.demand(warm.demand(path: "Sources/Trigger.swift"))
        }
        let firstAdoptionEntered = await adoptionGate.waitUntilFirstResolution()
        XCTAssertTrue(firstAdoptionEntered)
        let invalidationResult = await warm.engine.invalidateModified(
            rootEpoch: warm.rootEpoch,
            standardizedRelativePaths: ["Sources/Other.swift"]
        )
        XCTAssertFalse(invalidationResult.manifestWriteFailed)
        let replacement = Task {
            await warm.engine.demand(warm.demand(path: "Sources/Warm.swift"))
        }
        guard let replacementResult = await demandResult(
            replacement,
            before: .seconds(5)
        ), await adoptionGate.resolutionCount >= 2,
        isReady(replacementResult)
        else {
            return XCTFail("Expected warm manifest adoption to retry after invalidation.")
        }
        await adoptionGate.releaseFirstResolution()
        guard case .ready = await trigger.value else {
            return XCTFail("Expected unrelated trigger demand to remain active.")
        }
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        let warmEntry = try XCTUnwrap(snapshot.entries.first(where: {
            $0.standardizedRelativePath == "Sources/Warm.swift"
        }))
        guard case .ready = warmEntry.state else {
            return XCTFail("Expected retried warm entry.")
        }
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.manifestLoads, 2)
    }

    func testCancelledManifestAdoptionWaiterReleasesAdmissionWithoutCancellingSharedLoad() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Warm.swift": "struct Warm {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected warm manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let loadGate = EngineBuildGate()
        let sharedLoadCancellation = EngineLockedFlag()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: {
                    await loadGate.enter()
                    sharedLoadCancellation.set(Task.isCancelled)
                }
            )
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumActiveRequestCountPerRoot: 1,
                maximumActiveRequestCount: 1,
                maximumQueuedRequestCountPerRoot: 1,
                maximumQueuedRequestCount: 1,
                maximumActiveTaskCountPerRoot: 1,
                maximumActiveTaskCount: 1,
                maximumConcurrentMaterializationCountPerRoot: 1,
                maximumConcurrentMaterializationCount: 1
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let first = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Warm.swift"))
        }
        let sharedLoadEntered = await loadGate.waitUntilEntered()
        XCTAssertTrue(sharedLoadEntered)
        let second = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Warm.swift"))
        }
        while await fixture.engine.accounting().queuedRequestCount != 1 {
            await Task.yield()
        }

        first.cancel()
        guard case .cancelled = await first.value else {
            return XCTFail("Expected the detached manifest waiter to cancel.")
        }
        let waiterReplaced = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.activeRequestCount == 1 && accounting.queuedRequestCount == 0
        }
        XCTAssertTrue(waiterReplaced)
        let recovered = await fixture.engine.accounting()
        XCTAssertEqual(recovered.activeRequestCount, 1)
        XCTAssertEqual(recovered.queuedRequestCount, 0)
        XCTAssertEqual(recovered.ownerCount, 1)
        XCTAssertEqual(recovered.counters.cancellations, 1)

        await loadGate.release()
        guard await isReady(second.value) else {
            return XCTFail("Expected the remaining waiter to complete from the shared adoption.")
        }
        XCTAssertFalse(sharedLoadCancellation.value)
        let final = await fixture.engine.accounting()
        XCTAssertEqual(final.activeRequestCount, 0)
        XCTAssertEqual(final.queuedRequestCount, 0)
        XCTAssertEqual(final.counters.manifestLoads, 1)
        XCTAssertEqual(final.counters.manifestAdoptions, 1)
        XCTAssertEqual(final.counters.cancellations, 1)
    }

    func testOwnerCancellationImmediatelyReleasesAdmissionWhileBlockedIOGuaranteesDrain() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Blocked.swift": "struct Blocked {}\n",
                "Sources/Replacement.swift": "struct Replacement {}\n"
            ]
        )
        let gate = EngineFirstResolutionGate()
        let fileSystem = try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumActiveRequestCountPerRoot: 1,
                maximumActiveRequestCount: 1,
                maximumQueuedRequestCountPerRoot: 1,
                maximumQueuedRequestCount: 1,
                maximumActiveTaskCountPerRoot: 1,
                maximumActiveTaskCount: 1,
                maximumConcurrentMaterializationCountPerRoot: 1,
                maximumConcurrentMaterializationCount: 1
            ),
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient {
                identity,
                expected,
                maximumBytes,
                ownerID in
                await gate.enter()
                return try await fileSystem.loadValidatedRawContent(
                    ofRelativePath: identity.standardizedRelativePath,
                    expectedFingerprint: FileContentFingerprint(
                        deviceID: expected.device,
                        fileNumber: expected.inode,
                        byteSize: expected.size,
                        modificationSeconds: expected.modificationSeconds,
                        modificationNanoseconds: expected.modificationNanoseconds,
                        statusChangeSeconds: expected.changeSeconds,
                        statusChangeNanoseconds: expected.changeNanoseconds
                    ),
                    maximumBytes: maximumBytes,
                    workloadClass: .codemap,
                    schedulerOwnerID: ownerID
                )
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write("struct Blocked { let dirty = true }\n", to: "Sources/Blocked.swift", at: root)
        try repository.write(
            "struct Replacement { let dirty = true }\n",
            to: "Sources/Replacement.swift",
            at: root
        )
        let blockedOwner = WorkspaceCodemapLiveDemandOwner()
        let blocked = Task {
            await fixture.engine.demand(fixture.demand(
                path: "Sources/Blocked.swift",
                owner: blockedOwner
            ))
        }
        let blockedReadEntered = await gate.waitUntilFirstResolution()
        XCTAssertTrue(blockedReadEntered)
        let replacement = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Replacement.swift"))
        }

        let queued = await waitForEngineCondition {
            await fixture.engine.accounting().queuedRequestCount == 1
        }
        XCTAssertTrue(queued)
        let cancelledCount = await fixture.engine.cancel(owner: blockedOwner)
        XCTAssertEqual(cancelledCount, 1)
        guard case .cancelled = await blocked.value else {
            return XCTFail("Expected logical cancellation before blocked I/O drained.")
        }
        guard let replacementResult = await demandResult(replacement, before: .seconds(5)),
              isReady(replacementResult),
              await gate.resolutionCount >= 2
        else {
            return XCTFail("Expected immediate replacement admission while stale I/O remained blocked.")
        }
        let recovered = await fixture.engine.accounting()
        XCTAssertEqual(recovered.queuedRequestCount, 0)
        XCTAssertEqual(recovered.counters.cancellations, 1)

        await gate.releaseFirstResolution()
        let drained = await waitForEngineCondition {
            await fixture.engine.accounting().activeRequestCount == 0
        }
        XCTAssertTrue(drained)
    }

    func testWarmManifestAdoptionReclassifiesDirtyCandidateAndKeepsOnlyCurrentCleanOID() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Clean.swift": "struct Clean {}\n",
                "Sources/Dirty.swift": "struct Dirty {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Clean.swift")),
              case .ready = await seed.engine.demand(seed.demand(path: "Sources/Dirty.swift"))
        else { return XCTFail("Expected manifest seeds.") }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)
        try repository.write(
            "struct Dirty { let changed = true }\n",
            to: "Sources/Dirty.swift",
            at: root
        )

        let sourceReadCounter = EngineAsyncCounter()
        let trappingReader = WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
            await sourceReadCounter.increment()
            throw CancellationError()
        }
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            sourceReaderOverride: trappingReader
        )
        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(path: "Sources/Clean.swift"))) else {
            return XCTFail("Only the current clean manifest candidate should be adopted on demand.")
        }
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.entries.map(\.standardizedRelativePath), ["Sources/Clean.swift"])
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.materializations, 0)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testWarmManifestMutationDuringClassificationCannotPublishStaleCleanEntry() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Race.swift": "struct Race {}\n",
                "Sources/Trigger.swift": "struct Trigger {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Race.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let mutation = EngineOneShotFileMutation(
            url: root.appendingPathComponent("Sources/Race.swift"),
            contents: "struct Race { let changed = true }\n"
        )
        let sourceReadCounter = EngineAsyncCounter()
        let hookEvents = EngineHookEvents()
        let trappingReader = WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
            await sourceReadCounter.increment()
            throw CancellationError()
        }
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            sourceReaderOverride: trappingReader,
            identityHooks: GitBlobIdentityServiceHooks(
                afterGitCollection: { await mutation.mutateOnce() }
            )
        )
        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(path: "Sources/Trigger.swift"))) else {
            return XCTFail("Expected trigger demand after rejecting the stale warm candidate.")
        }
        XCTAssertEqual(hookEvents.count(kind: .manifestLoadHit), 1)
        let mutationInvocationCount = await mutation.invocationCount
        XCTAssertGreaterThanOrEqual(mutationInvocationCount, 1)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Race.swift" })
        XCTAssertTrue(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Trigger.swift" })
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.materializations, 1)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testWarmManifestMutationAfterClassificationFailsClosedWithoutSourceRead() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Race.swift": "struct Race {}\n",
                "Sources/Trigger.swift": "struct Trigger {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Race.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let mutation = EngineOneShotFileMutation(
            url: root.appendingPathComponent("Sources/Race.swift"),
            contents: "struct Race { let changedAfterClassification = true }\n"
        )
        let sourceReadCounter = EngineAsyncCounter()
        let hookEvents = EngineHookEvents()
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await sourceReadCounter.increment()
                throw CancellationError()
            },
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { await mutation.mutateOnce() }
            )
        )

        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(path: "Sources/Trigger.swift"))) else {
            return XCTFail("Expected trigger demand after the stale candidate failed closed.")
        }
        XCTAssertEqual(hookEvents.count(kind: .manifestLoadHit), 1)
        let mutationInvocationCount = await mutation.invocationCount
        XCTAssertGreaterThanOrEqual(mutationInvocationCount, 1)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Race.swift" })
        XCTAssertTrue(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Trigger.swift" })
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.materializations, 1)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testWarmManifestMutationAfterAuthorityCaptureFailsFinalFenceWithoutSourceRead() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Race.swift": "struct Race {}\n",
                "Sources/Trigger.swift": "struct Trigger {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Race.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let mutation = EngineSecondCatalogResolutionMutation(
            url: root.appendingPathComponent("Sources/Race.swift"),
            contents: "struct Race { let changedAfterAuthority = true }\n"
        )
        let sourceReadCounter = EngineAsyncCounter()
        let hookEvents = EngineHookEvents()
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await sourceReadCounter.increment()
                throw CancellationError()
            },
            catalogResolutionHook: { _ in await mutation.resolve() }
        )

        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(path: "Sources/Trigger.swift"))) else {
            return XCTFail("Expected trigger demand after the final authority fence rejected the candidate.")
        }
        XCTAssertEqual(hookEvents.count(kind: .manifestLoadHit), 1)
        let resolutionCount = await mutation.resolutionCount
        XCTAssertGreaterThanOrEqual(resolutionCount, 2)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Race.swift" })
        XCTAssertTrue(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Trigger.swift" })
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.materializations, 1)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead() async throws {
        for state in WarmManifestCandidateState.allCases {
            let repository = try makeRepositoryFixture(name: "\(#function)-\(state)")
            let path = "Sources/Candidate.swift"
            let triggerPath = "Sources/Trigger.swift"
            let root = try repository.makeRepository(
                named: "repository",
                files: [
                    path: "struct Candidate {}\n",
                    triggerPath: "struct Trigger {}\n"
                ]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let seed = try await makeEngineFixture(root: root, runtime: runtime)
            _ = await seed.engine.registerRoot(seed.registration)
            guard case .ready = await seed.engine.demand(seed.demand(path: path)) else {
                return XCTFail("Expected manifest seed for \(state).")
            }
            let seedRecord = try await persistedManifestRecord(
                fixture: seed,
                runtime: runtime,
                repositoryRelativePath: path
            )
            await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

            switch state {
            case .stagedOnly, .stagedAndUnstaged:
                try repository.write("struct Candidate { let staged = true }\n", to: path, at: root)
                try repository.stage(path, at: root)
                let stagedSeed = try await makeEngineFixture(root: root, runtime: runtime)
                _ = await stagedSeed.engine.registerRoot(stagedSeed.registration)
                guard case .ready = await stagedSeed.engine.demand(stagedSeed.demand(path: path)) else {
                    return XCTFail("Expected staged manifest seed for \(state).")
                }
                _ = try await persistedManifestRecord(
                    fixture: stagedSeed,
                    runtime: runtime,
                    repositoryRelativePath: path
                )
                await stagedSeed.engine.unloadRoot(rootEpoch: stagedSeed.rootEpoch)
                if state == .stagedAndUnstaged {
                    try repository.write(
                        "struct Candidate { let unstaged = true }\n",
                        to: path,
                        at: root
                    )
                }
            case .untrackedReplacement, .conflict, .checkoutTransform:
                try configureWarmManifestCandidate(
                    state,
                    repository: repository,
                    root: root,
                    path: path
                )
                try await republishManifestForCurrentAuthority(
                    record: seedRecord,
                    root: root,
                    runtime: runtime
                )
            }

            let classificationBatch = await GitBlobIdentityService().classify(
                workspaceRoot: root,
                relativePaths: [path]
            )
            let classification = try XCTUnwrap(classificationBatch.classifications.first)
            assertWarmManifestClassification(classification, matches: state)

            let sourceReadCounter = EngineAsyncCounter()
            let hookEvents = EngineHookEvents()
            let warm = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
                sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                    await sourceReadCounter.increment()
                    throw CancellationError()
                }
            )
            guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
                return XCTFail("Expected lazy warm registration for \(state).")
            }
            guard await isReady(warm.engine.demand(warm.demand(path: triggerPath))) else {
                return XCTFail("Expected trigger demand after rejecting \(state).")
            }
            XCTAssertEqual(hookEvents.count(kind: .manifestLoadHit), 1)
            let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
            let snapshot = try XCTUnwrap(snapshotValue)
            XCTAssertFalse(
                snapshot.entries.contains { $0.standardizedRelativePath == path },
                "Unexpected warm entry for \(state)."
            )
            XCTAssertTrue(snapshot.entries.contains { $0.standardizedRelativePath == triggerPath })
            let accounting = await warm.engine.accounting()
            XCTAssertEqual(accounting.counters.materializations, 1)
            XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
            XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
            let sourceReadCount = await sourceReadCounter.value
            XCTAssertEqual(sourceReadCount, 0)
            await warm.engine.unloadRoot(rootEpoch: warm.rootEpoch)
        }
    }

    func testLinkedWorktreeSharesLocatorAndCASButUsesDistinctManifestNamespace() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let canonical = try repository.makeRepository(
            named: "canonical",
            files: ["Sources/Shared.swift": "struct Shared {}\n"]
        )
        let linked = try repository.makeLinkedWorktree(
            from: canonical,
            named: "linked",
            branch: "linked-branch"
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let first = try await makeEngineFixture(root: canonical, runtime: runtime)
        _ = await first.engine.registerRoot(first.registration)
        guard case .ready = await first.engine.demand(first.demand(path: "Sources/Shared.swift")) else {
            return XCTFail("Expected canonical ready result.")
        }
        let second = try await makeEngineFixture(root: linked, runtime: runtime)
        _ = await second.engine.registerRoot(second.registration)
        guard case .ready = await second.engine.demand(second.demand(path: "Sources/Shared.swift")) else {
            return XCTFail("Expected linked ready result.")
        }
        let secondAccounting = await second.engine.accounting()
        XCTAssertEqual(secondAccounting.counters.materializations, 0)
        XCTAssertEqual(secondAccounting.counters.locatorFastPaths, 1)

        let firstCapability = try await eligible(first.capabilityService.state(for: first.rootEpoch))
        let secondCapability = try await eligible(second.capabilityService.state(for: second.rootEpoch))
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let firstNamespace = try CodeMapRootManifestNamespace(
            capability: firstCapability,
            pipelineIdentity: pipeline
        )
        let secondNamespace = try CodeMapRootManifestNamespace(
            capability: secondCapability,
            pipelineIdentity: pipeline
        )
        XCTAssertEqual(firstNamespace.repositoryNamespace, secondNamespace.repositoryNamespace)
        XCTAssertNotEqual(firstNamespace.worktreeIdentity, secondNamespace.worktreeIdentity)
        XCTAssertNotEqual(
            runtime.manifestStore.manifestURL(for: firstNamespace),
            runtime.manifestStore.manifestURL(for: secondNamespace)
        )
    }

    func testDirtyUntrackedAndTransformedFilesUseValidatedSourceAndNeverWriteManifest() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                ".gitattributes": "Sources/Transformed.swift text eol=crlf\n",
                "Notes.txt": "not a supported codemap source\n",
                "Sources/Dirty.swift": "struct Dirty {}\n",
                "Sources/Transformed.swift": "struct Transformed {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write("struct Dirty { let changed = true }\n", to: "Sources/Dirty.swift", at: root)
        try repository.write("struct Untracked {}\n", to: "Sources/Untracked.swift", at: root)

        for path in ["Sources/Dirty.swift", "Sources/Untracked.swift", "Sources/Transformed.swift"] {
            guard case .ready = await fixture.engine.demand(fixture.demand(path: path)) else {
                return XCTFail("Expected source-backed ready result for \(path).")
            }
        }
        guard case .unavailable(.unsupportedFileType) = await fixture.engine.demand(
            fixture.demand(path: "Notes.txt")
        ) else { return XCTFail("Expected typed unsupported outcome.") }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.validatedWorktreeReads, 3)
        XCTAssertEqual(accounting.counters.materializations, 0)
        XCTAssertEqual(accounting.counters.manifestWrites, 0)
        XCTAssertEqual(accounting.counters.overlayReadyPublications, 3)
        XCTAssertEqual(accounting.counters.overlayUnavailablePublications, 0)
        let snapshotValue = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.entries.count, 3)
        for entry in snapshot.entries {
            guard case let .ready(source, _, _) = entry.state else {
                return XCTFail("Expected live ready source.")
            }
            XCTAssertEqual(source, .live)
        }
    }

    func testFanInCancellationRemovesOneAssociationAndSharedBuildCompletesForOtherOwner() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/FanIn.swift": "struct FanIn {}\n"]
        )
        let gate = EngineBuildGate()
        let buildCounter = EngineAsyncCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                await gate.enter()
                return .readyNoSymbols
            })
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        let firstOwner = WorkspaceCodemapLiveDemandOwner()
        let secondOwner = WorkspaceCodemapLiveDemandOwner()
        let first = Task { await fixture.engine.demand(fixture.demand(path: "Sources/FanIn.swift", owner: firstOwner)) }
        _ = await gate.waitUntilEntered()
        let second = Task { await fixture.engine.demand(fixture.demand(path: "Sources/FanIn.swift", owner: secondOwner)) }
        for _ in 0 ..< 200 {
            if await fixture.engine.accounting().activeRequestCount == 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0 ..< 200 {
            if await runtime.coordinator.accounting().counters.joins > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let joinedCount = await runtime.coordinator.accounting().counters.joins
        XCTAssertGreaterThan(joinedCount, 0)
        let cancellationCount = await fixture.engine.cancel(owner: firstOwner)
        XCTAssertEqual(cancellationCount, 1)
        await gate.release()
        guard case .cancelled = await first.value else { return XCTFail("Expected first cancellation.") }
        let secondResult = await second.value
        guard case .ready = secondResult else {
            return XCTFail("Expected joined owner completion, got \(String(describing: secondResult)).")
        }
        let buildCount = await buildCounter.value
        let finalAccounting = await fixture.engine.accounting()
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(finalAccounting.activeRequestCount, 0)
    }

    func testConcurrentExactDuplicateCompletionPublishesOnceAndReleasesDuplicateLease() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Duplicate.swift": "struct Duplicate {}\n"]
        )
        let gate = EngineBuildGate()
        let events = EngineHookEvents()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await gate.enter()
                return .readyNoSymbols
            })
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks(event: { events.record($0) })
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let first = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Duplicate.swift")) }
        _ = await gate.waitUntilEntered()
        let second = Task {
            await fixture.engine.demand(fixture.demand(
                path: "Sources/Duplicate.swift",
                owner: WorkspaceCodemapLiveDemandOwner()
            ))
        }
        for _ in 0 ..< 200 {
            if await runtime.coordinator.accounting().counters.joins > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await gate.release()
        let results = await [first.value, second.value]
        XCTAssertEqual(results.count(where: { if case .ready = $0 { true } else { false } }), 1)
        XCTAssertEqual(results.count(where: { if case .alreadyReady = $0 { true } else { false } }), 1)

        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.overlayReadyPublications, 1)
        XCTAssertEqual(accounting.counters.overlayExactDuplicateCompletions, 1)
        XCTAssertEqual(events.count(kind: .overlayReady), 1)
        XCTAssertEqual(events.count(kind: .overlayExactDuplicate), 1)
        let storeAccounting = await runtime.artifactStore.accounting()
        XCTAssertEqual(storeAccounting.activeLeaseCount, 1)
    }

    func testEditRenameDeleteWatcherAndCheckoutInvalidationsFenceVisibilityWithoutScheduling() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Fenced.swift": "struct Fenced {}\n"]
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Fenced.swift")) else {
            return XCTFail("Expected initial ready result.")
        }
        let modified = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Fenced.swift"]
        )
        XCTAssertEqual(modified.revokedOverlayCount, 1)
        let modifiedBundleValue = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(try XCTUnwrap(modifiedBundleValue).entries.isEmpty)

        let renamed = await fixture.engine.invalidateRenamed(
            rootEpoch: fixture.rootEpoch,
            from: "Sources/Fenced.swift",
            to: "Sources/Renamed.swift"
        )
        XCTAssertFalse(renamed.manifestWriteFailed)
        let deleted = await fixture.engine.invalidateDeleted(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Renamed.swift"]
        )
        XCTAssertFalse(deleted.manifestWriteFailed)
        let watcher = await fixture.engine.invalidateWatcherGap(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(watcher.revokedOverlayCount, 1)
        guard case .rejected(.capabilityUnavailable) = await fixture.engine.demand(
            fixture.demand(path: "Sources/Fenced.swift")
        ) else { return XCTFail("Expected watcher authority fence.") }
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected explicit re-registration after watcher gap.")
        }
        let checkout = await fixture.engine.invalidateCheckout(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(checkout.revokedOverlayCount, 1)
    }

    func testCatalogInvalidationFencesVisibilityWithoutScheduling() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Fenced.swift": "struct Fenced {}\n"]
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Fenced.swift")) else {
            return XCTFail("Expected initial ready result.")
        }
        let before = await fixture.engine.accounting()

        let invalidation = await fixture.engine.invalidateCatalog(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(invalidation.revokedOverlayCount, 1)
        XCTAssertEqual(invalidation.cancelledRequestCount, 0)
        let bundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(bundle)
        guard case .rejected(.capabilityUnavailable) = await fixture.engine.demand(
            fixture.demand(path: "Sources/Fenced.swift")
        ) else {
            return XCTFail("Catalog invalidation must not schedule replacement work.")
        }
        let after = await fixture.engine.accounting()
        XCTAssertEqual(after.rootCount, 1)
        XCTAssertEqual(after.unavailableRootCount, 1)
        XCTAssertEqual(after.counters.builds, before.counters.builds)
        XCTAssertEqual(after.activeRequestCount, 0)
        XCTAssertEqual(after.queuedRequestCount, 0)

        let repeated = await fixture.engine.invalidateCatalog(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(repeated.revokedOverlayCount, 0)
        XCTAssertEqual(repeated.cancelledRequestCount, 0)
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
    }

    func testManifestWriteFailureKeepsVerifiedOverlayReadyAndMarksRetryState() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Failure.swift": "struct Failure {}\n",
                "Sources/Recovery.swift": "struct Recovery {}\n"
            ]
        )
        let fault = EngineManifestFaultOnce()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            manifestStoreHooks: CodeMapRootManifestStoreHooks(faultAction: fault.action)
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Failure.swift")) else {
            return XCTFail("Manifest failure must not discard ready overlay state.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.dirtyManifestCount, 1)
        XCTAssertEqual(accounting.counters.manifestFailures, 1)
        let bundleValue = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(try XCTUnwrap(bundleValue).entries.count, 1)

        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Recovery.swift")) else {
            return XCTFail("Expected newer manifest revision to recover publication.")
        }
        let recoveredAccounting = await fixture.engine.accounting()
        XCTAssertEqual(recoveredAccounting.dirtyManifestCount, 0)
        XCTAssertEqual(recoveredAccounting.counters.manifestWrites, 1)
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)

        let reloaded = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered(adoptedReadyCount: 0) = await reloaded.engine.registerRoot(reloaded.registration) else {
            return XCTFail("Expected lazy recovered registration.")
        }
        guard await isReady(reloaded.engine.demand(
            reloaded.demand(path: "Sources/Failure.swift")
        )) else {
            return XCTFail("Expected recovered manifest to retain both revisions on demand.")
        }
    }

    func testRootBoundsAndPathFreeHooksDoNotLeakPhysicalPaths() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let firstRoot = try repository.makeRepository(
            named: "one",
            files: ["One.swift": "struct One {}\n"]
        )
        let secondRoot = try repository.makeRepository(
            named: "two",
            files: ["Two.swift": "struct Two {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let eventDescriptions = EngineEventDescriptions()
        let first = try await makeEngineFixture(
            root: firstRoot,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(maximumRootCount: 1),
            hooks: WorkspaceCodemapBindingEngineHooks { eventDescriptions.append(String(describing: $0.kind)) }
        )
        guard case .registered = await first.engine.registerRoot(first.registration) else {
            return XCTFail("Expected first root registration.")
        }
        let secondRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: secondRoot,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        guard case .busy = await first.engine.registerRoot(secondRegistration) else {
            return XCTFail("Expected root bound.")
        }
        XCTAssertFalse(eventDescriptions.values.joined().contains(firstRoot.path))
        await first.engine.unloadRoot(rootEpoch: first.rootEpoch)
        let finalAccounting = await first.engine.accounting()
        XCTAssertEqual(finalAccounting.rootCount, 0)
    }

    func testEnginePublicationCountersSaturateWithoutWrapping() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Saturating.swift": "struct Saturating {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            initialCounterValue: .max
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Saturating.swift")) else {
            return XCTFail("Expected ready publication at saturated accounting.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.overlayReadyPublications, .max)
        XCTAssertEqual(accounting.counters.builds, .max)
        XCTAssertEqual(accounting.counters.materializedBytes, .max)
    }

    func testConcurrentRegistrationReservesRootSlotBeforeManifestLoad() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let firstRoot = try repository.makeRepository(
            named: "one",
            files: ["One.swift": "struct One {}\n"]
        )
        let secondRoot = try repository.makeRepository(
            named: "two",
            files: ["Two.swift": "struct Two {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: firstRoot, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "One.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let manifestReads = EngineLockedCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { manifestReads.increment() }
            )
        )
        let fixture = try await makeEngineFixture(
            root: firstRoot,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(maximumRootCount: 1)
        )
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected first registration.")
        }
        XCTAssertEqual(manifestReads.value, 0)
        let second = await fixture.engine.registerRoot(WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: secondRoot,
            catalogGeneration: 1,
            ingressGeneration: 1
        ))
        guard case .busy = second else { return XCTFail("Expected occupied root slot to reject overlap.") }
    }

    func testInvalidationsFenceBlockedCapabilityRegistrationBeforeAwait() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Fenced.swift": "struct Fenced {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )

        for kind in EngineRegistrationInvalidationKind.allCases {
            let gate = EngineBuildGate()
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                    beforeResolution: { await gate.enter() }
                )
            )
            let registration = Task { await fixture.engine.registerRoot(fixture.registration) }
            _ = await gate.waitUntilEntered()

            let result: WorkspaceCodemapBindingInvalidationResult = switch kind {
            case .path:
                await fixture.engine.invalidateModified(
                    rootEpoch: fixture.rootEpoch,
                    standardizedRelativePaths: ["Sources/Fenced.swift"]
                )
            case .watcher:
                await fixture.engine.invalidateWatcherGap(rootEpoch: fixture.rootEpoch)
            case .checkout:
                await fixture.engine.invalidateCheckout(rootEpoch: fixture.rootEpoch)
            case .repository:
                await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
            }
            XCTAssertEqual(result, WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            ))
            guard case .failed = await registration.value else {
                return XCTFail("Expected \(kind) to fence capability registration.")
            }
            let accounting = await fixture.engine.accounting()
            XCTAssertEqual(accounting.rootCount, 0)
            XCTAssertEqual(accounting.eligibleRootCount, 0)
            let capability = await fixture.capabilityService.snapshotForTesting()
            XCTAssertEqual(capability.activeRecordCount, 0)
            XCTAssertEqual(capability.activeFlightCount, 0)
            XCTAssertEqual(capability.waiterCount, 0)
            XCTAssertEqual(capability.resolutionObserverCount, 1)
            await gate.release()
            await fixture.capabilityService.drain()
            let drainedCapability = await fixture.capabilityService.snapshotForTesting()
            XCTAssertEqual(drainedCapability.resolutionObserverCount, 0)
        }
    }

    func testUnloadDuringBlockedCapabilityRegistrationReleasesRootSlotImmediately() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Root.swift": "struct Root {}\n"]
        )
        let gate = EngineFirstResolutionGate()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            ),
            policy: WorkspaceCodemapBindingEnginePolicy(maximumRootCount: 1),
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                beforeResolution: { await gate.enter() }
            )
        )
        let first = Task { await fixture.engine.registerRoot(fixture.registration) }
        _ = await gate.waitUntilFirstResolution()

        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
        guard case .failed = await first.value else {
            return XCTFail("Expected unloaded capability registration to fail without resolver cooperation.")
        }
        let unloadedAccounting = await fixture.engine.accounting()
        XCTAssertEqual(unloadedAccounting.rootCount, 0)
        let released = await fixture.capabilityService.snapshotForTesting()
        XCTAssertEqual(released.activeRecordCount, 0)
        XCTAssertEqual(released.activeFlightCount, 0)
        XCTAssertEqual(released.waiterCount, 0)
        XCTAssertEqual(released.historicalRecordCount, 1)

        let replacement = WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        guard case .registered = await fixture.engine.registerRoot(replacement) else {
            return XCTFail("Expected the synchronously released root slot to admit a replacement.")
        }
        let replacementAccounting = await fixture.engine.accounting()
        XCTAssertEqual(replacementAccounting.rootCount, 1)

        await gate.releaseFirstResolution()
        await fixture.capabilityService.drain()
        let finalCapability = await fixture.capabilityService.snapshotForTesting()
        XCTAssertEqual(finalCapability.activeRecordCount, 1)
        XCTAssertEqual(finalCapability.activeFlightCount, 0)
        XCTAssertEqual(finalCapability.waiterCount, 0)
        XCTAssertEqual(finalCapability.resolutionObserverCount, 0)
        XCTAssertEqual(finalCapability.historicalRecordCount, 1)
    }

    func testRequestReservationAndCancellationDuringValidatedReadReleaseExactlyOnce() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Dirty.swift": "struct Dirty {}\n",
                "Sources/Queued.swift": "struct Queued {}\n"
            ]
        )
        let readGate = EngineBuildGate()
        let buildCounter = EngineAsyncCounter()
        let hookEvents = EngineHookEvents()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                return .readyNoSymbols
            })
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumActiveRequestCountPerRoot: 1,
                maximumActiveRequestCount: 1,
                maximumActiveTaskCountPerRoot: 1,
                maximumActiveTaskCount: 1,
                maximumConcurrentMaterializationCountPerRoot: 1,
                maximumConcurrentMaterializationCount: 1
            ),
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await readGate.enter()
                try Task.checkCancellation()
                throw FileSystemError.failedToReadFile
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write("struct Dirty { let changed = true }\n", to: "Sources/Dirty.swift", at: root)
        let task = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Dirty.swift")) }
        _ = await readGate.waitUntilEntered()
        let queued = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Queued.swift")) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let gated = await fixture.engine.accounting()
        XCTAssertEqual(gated.activeRequestCount, 1)
        XCTAssertEqual(gated.counters.classifications, 1)
        task.cancel()
        await readGate.release()
        guard case .cancelled = await task.value else { return XCTFail("Expected read cancellation.") }
        guard case .ready = await queued.value else { return XCTFail("Expected queued request completion.") }
        for _ in 0 ..< 200 {
            if await fixture.engine.accounting().activeRequestCount == 0 { break }
            await Task.yield()
        }
        let buildCount = await buildCounter.value
        let accounting = await fixture.engine.accounting()
        let snapshot = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(accounting.activeRequestCount, 0)
        XCTAssertEqual(accounting.counters.classifications, 2)
        XCTAssertEqual(accounting.counters.cancellations, 1)
        XCTAssertEqual(hookEvents.count(kind: .cancellation), 1)
        XCTAssertEqual(hookEvents.numericTotal(kind: .cancellation), 1)
        XCTAssertFalse(try XCTUnwrap(snapshot).entries.contains {
            $0.standardizedRelativePath == "Sources/Dirty.swift"
        })
    }

    func testSourceAcquisitionFailureReleasesOverlayPreflightAndActiveRequest() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Failure.swift": "struct Failure {}\n"]
        )
        try repository.write(
            "struct Failure { let dirty = true }\n",
            to: "Sources/Failure.swift",
            at: root
        )
        let overlay = WorkspaceCodemapLiveOverlay()
        let failingReader = WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
            throw POSIXError(.EIO)
        }
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            overlay: overlay,
            sourceReaderOverride: failingReader
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .unavailable(.transient) = await fixture.engine.demand(
            fixture.demand(path: "Sources/Failure.swift")
        ) else { return XCTFail("Expected typed acquisition failure.") }

        let engineAccounting = await fixture.engine.accounting()
        let overlayAccounting = await overlay.accounting()
        XCTAssertEqual(engineAccounting.activeRequestCount, 0)
        XCTAssertEqual(overlayAccounting.pendingEntryCount, 0)
        XCTAssertEqual(overlayAccounting.waiterCount, 0)
        XCTAssertEqual(overlayAccounting.admissionReservationCount, 0)
    }

    func testInvalidationFencesBlockedCompletionBeforeOverlayPublication() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Race.swift": "struct Race {}\n"]
        )
        let buildGate = EngineBuildGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildGate.enter()
                return .readyNoSymbols
            })
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        let demand = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Race.swift")) }
        _ = await buildGate.waitUntilEntered()
        let invalidation = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Race.swift"]
        )
        XCTAssertEqual(invalidation.cancelledRequestCount, 1)
        await buildGate.release()
        guard case .cancelled = await demand.value else { return XCTFail("Expected fenced completion.") }
        let bundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(try XCTUnwrap(bundle).entries.isEmpty)
        let firstInvalidationAccounting = await fixture.engine.accounting()
        XCTAssertEqual(firstInvalidationAccounting.activeRequestCount, 0)
        XCTAssertEqual(firstInvalidationAccounting.counters.cancellations, 1)
        _ = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Race.swift"]
        )
        let repeatedInvalidationAccounting = await fixture.engine.accounting()
        XCTAssertEqual(repeatedInvalidationAccounting.counters.cancellations, 1)
    }

    func testPathInvalidationDoesNotCancelUnrelatedActiveRequest() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Invalidated.swift": "struct Invalidated {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let sourceGate = EngineMultiEntryGate()
        let fileSystem = try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumActiveRequestCountPerRoot: 2,
                maximumActiveRequestCount: 2,
                maximumActiveTaskCountPerRoot: 2,
                maximumActiveTaskCount: 2,
                maximumConcurrentMaterializationCountPerRoot: 2,
                maximumConcurrentMaterializationCount: 2
            ),
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient {
                identity, expected, maximumBytes, ownerID in
                await sourceGate.enter()
                return try await fileSystem.loadValidatedRawContent(
                    ofRelativePath: identity.standardizedRelativePath,
                    expectedFingerprint: FileContentFingerprint(
                        deviceID: expected.device,
                        fileNumber: expected.inode,
                        byteSize: expected.size,
                        modificationSeconds: expected.modificationSeconds,
                        modificationNanoseconds: expected.modificationNanoseconds,
                        statusChangeSeconds: expected.changeSeconds,
                        statusChangeNanoseconds: expected.changeNanoseconds
                    ),
                    maximumBytes: maximumBytes,
                    workloadClass: .codemap,
                    schedulerOwnerID: ownerID
                )
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write(
            "struct Invalidated { let dirty = true }\n",
            to: "Sources/Invalidated.swift",
            at: root
        )
        try repository.write(
            "struct Unrelated { let dirty = true }\n",
            to: "Sources/Unrelated.swift",
            at: root
        )
        let invalidated = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Invalidated.swift"))
        }
        let unrelated = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Unrelated.swift"))
        }
        _ = await sourceGate.waitUntilEntered(2)

        let invalidation = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Invalidated.swift"]
        )
        XCTAssertEqual(invalidation.cancelledRequestCount, 1)
        await sourceGate.releaseAll()

        guard case .cancelled = await invalidated.value else {
            return XCTFail("Expected only the invalidated path to cancel.")
        }
        guard case .ready = await unrelated.value else {
            return XCTFail("Expected the unrelated active request to remain current.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.cancellations, 1)
        XCTAssertEqual(accounting.activeRequestCount, 0)
    }

    func testUnloadCancellationTelemetryCountsActiveRequestExactlyOnce() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Unload.swift": "struct Unload {}\n"]
        )
        let buildGate = EngineBuildGate()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                    await buildGate.enter()
                    return .readyNoSymbols
                })
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let demand = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Unload.swift"))
        }
        await buildGate.waitUntilEntered()

        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
        await buildGate.release()
        guard case .cancelled = await demand.value else {
            return XCTFail("Expected unload to cancel the active request.")
        }
        let drained = await waitForEngineCondition {
            await fixture.engine.accounting().activeRequestCount == 0
        }
        XCTAssertTrue(drained)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.cancellations, 1)
    }

    func testShutdownWaitsForBlockedManifestWriterAndDrainsEngineWork() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Shutdown.swift": "struct Shutdown {}\n"]
        )
        let writeGate = EngineBlockingGate()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
                manifestStoreHooks: CodeMapRootManifestStoreHooks(
                    afterWriteShardAdmission: { writeGate.enterAndWait() }
                )
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let demand = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Shutdown.swift"))
        }
        XCTAssertTrue(writeGate.waitUntilEntered())
        let shutdownFinished = EngineCompletionFlag()
        let shutdown = Task {
            await fixture.engine.shutdown()
            shutdownFinished.finish()
        }
        XCTAssertFalse(shutdownFinished.waitUntilFinished(timeout: 0.1))

        writeGate.release()
        await shutdown.value
        guard case .cancelled = await demand.value else {
            return XCTFail("Expected shutdown to cancel manifest-producing demand.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.rootCount, 0)
        XCTAssertEqual(accounting.activeRequestCount, 0)
        XCTAssertEqual(accounting.queuedRequestCount, 0)
        await fixture.engine.shutdown()
    }

    func testSerializedManifestWriterPersistsNewestRecordSetWhenSecondCompletionArrivesFirst() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": "struct One {}\n",
                "Sources/Two.swift": "struct Two {}\n"
            ]
        )
        let writeGate = EngineBlockingGate()
        let hookEvents = EngineHookEvents()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterWriteShardAdmission: { writeGate.enterAndWait() }
            )
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let first = Task { await fixture.engine.demand(fixture.demand(path: "Sources/One.swift")) }
        XCTAssertTrue(writeGate.waitUntilEntered())
        let second = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Two.swift")) }
        XCTAssertTrue(hookEvents.wait(kind: .manifestRevisionQueued, numericValue: 2))
        writeGate.release()
        guard case .ready = await first.value else { return XCTFail("Expected first ready.") }
        guard case .ready = await second.value else { return XCTFail("Expected second ready.") }
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)

        let reloaded = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered(adoptedReadyCount: 0) = await reloaded.engine.registerRoot(reloaded.registration) else {
            return XCTFail("Expected lazy reloaded registration.")
        }
        guard await isReady(reloaded.engine.demand(
            reloaded.demand(path: "Sources/One.swift")
        )) else {
            return XCTFail("Expected latest two-record manifest snapshot on demand.")
        }
    }

    func testSameNamespaceWriterDrainsUnloadedPredecessorBeforeSuccessor() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let writeGate = EngineBlockingGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterWriteShardAdmission: { writeGate.enterAndWait() }
            )
        )
        let service = capabilityService()
        let firstEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let secondEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let firstFileIDs = EngineFileIDs()
        let secondFileIDs = EngineFileIDs()
        let fileSystem = try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let catalog = WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
            let fileIDs = epoch == firstEpoch ? firstFileIDs : secondFileIDs
            guard epoch == firstEpoch || epoch == secondEpoch,
                  let identity = WorkspaceCodemapArtifactBindingIdentity(
                      rootID: epoch.rootID,
                      rootLifetimeID: epoch.rootLifetimeID,
                      fileID: fileIDs.id(for: relativePath),
                      standardizedRootPath: root.path,
                      standardizedRelativePath: relativePath,
                      standardizedFullPath: root.appendingPathComponent(relativePath).path
                  )
            else { return nil }
            return WorkspaceCodemapManifestBindingCandidate(
                identity: identity,
                requestGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }
        let reader = WorkspaceCodemapValidatedSourceReaderClient { identity, expected, maximumBytes, ownerID in
            try await fileSystem.loadValidatedRawContent(
                ofRelativePath: identity.standardizedRelativePath,
                expectedFingerprint: FileContentFingerprint(
                    deviceID: expected.device,
                    fileNumber: expected.inode,
                    byteSize: expected.size,
                    modificationSeconds: expected.modificationSeconds,
                    modificationNanoseconds: expected.modificationNanoseconds,
                    statusChangeSeconds: expected.changeSeconds,
                    statusChangeNanoseconds: expected.changeNanoseconds
                ),
                maximumBytes: maximumBytes,
                workloadClass: .codemap,
                schedulerOwnerID: ownerID
            )
        }
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: service,
            sourceReader: reader,
            catalogClient: catalog,
            accessEpochSeconds: { 42 }
        )
        addTeardownBlock { await engine.shutdown() }
        let firstRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: firstEpoch.rootID,
            rootLifetimeID: firstEpoch.rootLifetimeID,
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        let secondRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: secondEpoch.rootID,
            rootLifetimeID: secondEpoch.rootLifetimeID,
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        func demand(
            epoch: WorkspaceCodemapRootEpoch,
            fileIDs: EngineFileIDs,
            path: String
        ) -> WorkspaceCodemapBindingDemand {
            WorkspaceCodemapBindingDemand(
                owner: .init(),
                identity: WorkspaceCodemapArtifactBindingIdentity(
                    rootID: epoch.rootID,
                    rootLifetimeID: epoch.rootLifetimeID,
                    fileID: fileIDs.id(for: path),
                    standardizedRootPath: root.path,
                    standardizedRelativePath: path,
                    standardizedFullPath: root.appendingPathComponent(path).path
                )!,
                requestGeneration: 1,
                catalogGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1,
                priority: .demand,
                language: .swift
            )
        }

        _ = await engine.registerRoot(firstRegistration)
        _ = await engine.registerRoot(secondRegistration)
        let first = Task {
            await engine.demand(demand(
                epoch: firstEpoch,
                fileIDs: firstFileIDs,
                path: "Sources/First.swift"
            ))
        }
        XCTAssertTrue(writeGate.waitUntilEntered())
        await engine.unloadRoot(rootEpoch: firstEpoch)
        let second = Task {
            await engine.demand(demand(
                epoch: secondEpoch,
                fileIDs: secondFileIDs,
                path: "Sources/Second.swift"
            ))
        }
        writeGate.release()

        guard case .cancelled = await first.value else {
            return XCTFail("Expected unloaded predecessor demand to cancel.")
        }
        guard case .ready = await second.value else {
            return XCTFail("Expected same-namespace successor demand to complete.")
        }
        let state = await service.state(for: secondEpoch)
        let capability = try eligible(state)
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let namespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: pipeline
        )
        let authority = try CodeMapRootManifestAuthority(
            namespace: namespace,
            token: capability.repositoryAuthority
        )
        guard case let .hit(snapshot) = try await runtime.manifestStore.loadCurrentManifest(
            namespace: namespace,
            currentAuthority: authority
        ) else {
            return XCTFail("Expected same-namespace manifest.")
        }
        XCTAssertEqual(
            Set(snapshot.records.map(\.repositoryRelativePath)),
            ["Sources/First.swift", "Sources/Second.swift"]
        )
    }

    func testPathInvalidationDuringManifestWriteDrainsNewestRevision() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": "struct Feature {}\n"]
        )
        let writeGate = EngineBlockingGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterWriteShardAdmission: { writeGate.enterAndWait() }
            )
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        let demand = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Feature.swift"))
        }
        XCTAssertTrue(writeGate.waitUntilEntered())
        let invalidation = Task {
            await fixture.engine.invalidateModified(
                rootEpoch: fixture.rootEpoch,
                standardizedRelativePaths: ["Sources/Feature.swift"]
            )
        }

        writeGate.release()
        let invalidationResult = await invalidation.value
        XCTAssertFalse(invalidationResult.manifestWriteFailed)
        guard case .cancelled = await demand.value else {
            return XCTFail("Expected the invalidated manifest-producing demand to cancel.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.dirtyManifestCount, 0)
    }

    func testQueuedAndLastOwnerCancellationDrainReservationsAndFairnessHistoryAfterOrdinalRebase() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First {}\n",
                "Sources/Second.swift": "struct Second {}\n"
            ]
        )
        let gate = EngineBuildGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let policy = WorkspaceCodemapBindingEnginePolicy(
            maximumActiveRequestCountPerRoot: 1,
            maximumActiveRequestCount: 1,
            maximumActiveRequestCountPerOwner: 1,
            maximumQueuedRequestCountPerRoot: 1,
            maximumQueuedRequestCountPerOwner: 1,
            maximumQueuedRequestCount: 1,
            maximumActiveTaskCountPerRoot: 1,
            maximumActiveTaskCountPerOwner: 1,
            maximumActiveTaskCount: 1,
            maximumValidatedWorktreeByteCount: 64,
            maximumRetainedSourceByteCountPerRoot: 64,
            maximumRetainedSourceByteCount: 64
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: policy,
            initialQueueOrdinal: .max,
            initialAdmissionOrdinal: .max,
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await gate.enter()
                try Task.checkCancellation()
                throw FileSystemError.failedToReadFile
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write("struct First { let dirty = true }\n", to: "Sources/First.swift", at: root)
        try repository.write("struct Second { let dirty = true }\n", to: "Sources/Second.swift", at: root)
        let firstOwner = WorkspaceCodemapLiveDemandOwner()
        let secondOwner = WorkspaceCodemapLiveDemandOwner()
        let first = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/First.swift", owner: firstOwner))
        }
        _ = await gate.waitUntilEntered()
        let second = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Second.swift", owner: secondOwner))
        }
        while await fixture.engine.accounting().queuedRequestCount == 0 {
            await Task.yield()
        }
        let peak = await fixture.engine.accounting()
        XCTAssertEqual(peak.activeRequestCount, 1)
        XCTAssertEqual(peak.queuedRequestCount, 1)
        XCTAssertEqual(peak.reservedSourceByteCount, 64)
        XCTAssertEqual(peak.ownerCount, 2)
        XCTAssertEqual(peak.rootAdmissionHistoryCount, 1)
        XCTAssertEqual(peak.ownerAdmissionHistoryCount, 1)

        let queuedCancellationCount = await fixture.engine.cancel(owner: secondOwner)
        let activeCancellationCount = await fixture.engine.cancel(owner: firstOwner)
        let duplicateQueuedCancellationCount = await fixture.engine.cancel(owner: secondOwner)
        let duplicateActiveCancellationCount = await fixture.engine.cancel(owner: firstOwner)
        XCTAssertEqual(queuedCancellationCount, 1)
        XCTAssertEqual(activeCancellationCount, 1)
        XCTAssertEqual(duplicateQueuedCancellationCount, 0)
        XCTAssertEqual(duplicateActiveCancellationCount, 0)
        await gate.release()
        guard case .cancelled = await first.value else { return XCTFail("Expected active cancellation.") }
        guard case .cancelled = await second.value else { return XCTFail("Expected queued cancellation.") }
        while await fixture.engine.accounting().activeRequestCount != 0 {
            await Task.yield()
        }
        let drained = await fixture.engine.accounting()
        XCTAssertEqual(drained.activeRequestCount, 0)
        XCTAssertEqual(drained.queuedRequestCount, 0)
        XCTAssertEqual(drained.reservedSourceByteCount, 0)
        XCTAssertEqual(drained.ownerCount, 0)
        XCTAssertEqual(drained.rootAdmissionHistoryCount, 0)
        XCTAssertEqual(drained.ownerAdmissionHistoryCount, 0)
        XCTAssertEqual(drained.counters.cancellations, 2)
    }

    func testSequentialRootsRetainGlobalAdoptionLeaseBudgetUntilUnloadThenRecover() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let firstRoot = try repository.makeRepository(
            named: "first",
            files: ["Sources/A.swift": "struct A {}\n"]
        )
        let secondRoot = try repository.makeRepository(
            named: "second",
            files: ["Sources/B.swift": "struct B {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        for (root, path) in [(firstRoot, "Sources/A.swift"), (secondRoot, "Sources/B.swift")] {
            let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
            _ = await seed.engine.registerRoot(seed.registration)
            guard case .ready = await seed.engine.demand(seed.demand(path: path)) else {
                return XCTFail("Expected manifest seed for \(path).")
            }
            await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)
        }

        let firstEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let secondEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let firstFileIDs = EngineFileIDs()
        let secondFileIDs = EngineFileIDs()
        let catalog = WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
            let root: URL
            let fileIDs: EngineFileIDs
            if epoch == firstEpoch {
                root = firstRoot
                fileIDs = firstFileIDs
            } else if epoch == secondEpoch {
                root = secondRoot
                fileIDs = secondFileIDs
            } else {
                return nil
            }
            guard let identity = WorkspaceCodemapArtifactBindingIdentity(
                rootID: epoch.rootID,
                rootLifetimeID: epoch.rootLifetimeID,
                fileID: fileIDs.id(for: relativePath),
                standardizedRootPath: root.path,
                standardizedRelativePath: relativePath,
                standardizedFullPath: root.appendingPathComponent(relativePath).path
            ) else { return nil }
            return WorkspaceCodemapManifestBindingCandidate(
                identity: identity,
                requestGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }
        let runtime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let service = capabilityService()
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: service,
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                throw FileSystemError.failedToReadFile
            },
            catalogClient: catalog,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumRootCount: 2,
                maximumManifestAdoptionLeaseCountPerRoot: 1,
                maximumManifestAdoptionLeaseCount: 1,
                maximumManifestAdoptionLeaseByteCountPerRoot: .max,
                maximumManifestAdoptionLeaseByteCount: .max
            )
        )
        addTeardownBlock { await engine.shutdown() }
        func demand(
            epoch: WorkspaceCodemapRootEpoch,
            root: URL,
            fileIDs: EngineFileIDs,
            path: String
        ) -> WorkspaceCodemapBindingDemand {
            let identity = WorkspaceCodemapArtifactBindingIdentity(
                rootID: epoch.rootID,
                rootLifetimeID: epoch.rootLifetimeID,
                fileID: fileIDs.id(for: path),
                standardizedRootPath: root.path,
                standardizedRelativePath: path,
                standardizedFullPath: root.appendingPathComponent(path).path
            )!
            return WorkspaceCodemapBindingDemand(
                owner: .init(),
                identity: identity,
                requestGeneration: 1,
                catalogGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1,
                priority: .demand,
                language: .swift
            )
        }
        let firstRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: firstEpoch.rootID,
            rootLifetimeID: firstEpoch.rootLifetimeID,
            loadedRootURL: firstRoot,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        let secondRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: secondEpoch.rootID,
            rootLifetimeID: secondEpoch.rootLifetimeID,
            loadedRootURL: secondRoot,
            catalogGeneration: 1,
            ingressGeneration: 1
        )

        guard case .registered(adoptedReadyCount: 0) = await engine.registerRoot(firstRegistration) else {
            return XCTFail("Expected lazy first registration.")
        }
        guard await isReady(engine.demand(demand(
            epoch: firstEpoch,
            root: firstRoot,
            fileIDs: firstFileIDs,
            path: "Sources/A.swift"
        ))) else {
            return XCTFail("Expected first retained adoption on demand.")
        }
        let firstAccounting = await engine.accounting()
        XCTAssertEqual(firstAccounting.manifestAdoptionLeaseCount, 1)
        XCTAssertGreaterThan(firstAccounting.manifestAdoptionLeaseByteCount, 0)

        guard case .registered(adoptedReadyCount: 0) = await engine.registerRoot(secondRegistration) else {
            return XCTFail("Expected second root to respect the retained global lease bound.")
        }
        _ = await engine.demand(demand(
            epoch: secondEpoch,
            root: secondRoot,
            fileIDs: secondFileIDs,
            path: "Sources/Missing.swift"
        ))
        let boundedAccounting = await engine.accounting()
        XCTAssertEqual(boundedAccounting.manifestAdoptionLeaseCount, 1)
        XCTAssertEqual(
            boundedAccounting.manifestAdoptionLeaseByteCount,
            firstAccounting.manifestAdoptionLeaseByteCount
        )

        await engine.unloadRoot(rootEpoch: firstEpoch)
        let releasedAccounting = await engine.accounting()
        XCTAssertEqual(releasedAccounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(releasedAccounting.manifestAdoptionLeaseByteCount, 0)

        guard await isReady(engine.demand(demand(
            epoch: secondEpoch,
            root: secondRoot,
            fileIDs: secondFileIDs,
            path: "Sources/B.swift"
        ))) else {
            return XCTFail("Expected same-session adoption retry after lease pressure cleared.")
        }
        let recoveredAccounting = await engine.accounting()
        XCTAssertEqual(recoveredAccounting.manifestAdoptionLeaseCount, 1)
        XCTAssertEqual(recoveredAccounting.counters.manifestAdoptions, 2)
    }

    func testUnloadDuringBlockedManifestRegistrationFailsAndReleasesRootAndLeaseState() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Unload.swift": "struct Unload {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Unload.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let loadGate = EngineBuildGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { await loadGate.enter() }
            )
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected lazy registration.")
        }
        let demand = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Unload.swift"))
        }
        _ = await loadGate.waitUntilEntered()
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)

        guard case .cancelled = await demand.value else {
            return XCTFail("Expected unload to cancel blocked manifest adoption demand.")
        }
        while await fixture.engine.accounting().activeRequestCount != 0 {
            await Task.yield()
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.rootCount, 0)
        XCTAssertEqual(accounting.activeRequestCount, 0)
        XCTAssertEqual(accounting.queuedRequestCount, 0)
        XCTAssertEqual(accounting.ownerCount, 0)
        XCTAssertEqual(accounting.reservedSourceByteCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
        XCTAssertEqual(accounting.rootAdmissionHistoryCount, 0)
        XCTAssertEqual(accounting.ownerAdmissionHistoryCount, 0)
        let snapshot = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(snapshot)

        let shutdownFinished = EngineCompletionFlag()
        let shutdown = Task {
            await fixture.engine.shutdown()
            shutdownFinished.finish()
        }
        XCTAssertFalse(shutdownFinished.waitUntilFinished(timeout: 0.1))
        await loadGate.release()
        await shutdown.value
    }

    func testPostCommitManifestAdoptionAuthorityRaceRollsBackOverlaySessionAndLease() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Race.swift": "struct Race {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Race.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let adoptionGate = EngineBuildGate()
        let overlay = WorkspaceCodemapLiveOverlay(
            manifestAdoptionCommitHook: { await adoptionGate.enter() }
        )
        let runtime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let fixture = try await makeEngineFixture(root: root, runtime: runtime, overlay: overlay)
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected lazy registration.")
        }
        let demand = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Race.swift"))
        }
        _ = await adoptionGate.waitUntilEntered()

        let invalidation = Task {
            await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
        }
        while await fixture.engine.accounting().unavailableRootCount == 0 {
            await Task.yield()
        }
        await adoptionGate.release()

        _ = await invalidation.value
        guard case .cancelled = await demand.value else {
            return XCTFail("Expected stale demand to cancel after adoption rollback.")
        }
        let snapshotValue = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.authorityIsCurrent)
        XCTAssertTrue(snapshot.entries.isEmpty)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.manifestAdoptions, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
    }

    private func persistedManifestRecord(
        fixture: EngineFixture,
        runtime: CodeMapArtifactRuntime,
        repositoryRelativePath: String
    ) async throws -> CodeMapRootManifestRecord {
        let capabilityState = await fixture.capabilityService.state(for: fixture.rootEpoch)
        let capability = try eligible(capabilityState)
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let namespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: pipeline
        )
        let authority = try CodeMapRootManifestAuthority(
            namespace: namespace,
            token: capability.repositoryAuthority
        )
        let load = try await runtime.manifestStore.loadCurrentManifest(
            namespace: namespace,
            currentAuthority: authority
        )
        guard case let .hit(snapshot) = load,
              let record = snapshot.records.first(where: {
                  $0.repositoryRelativePath == repositoryRelativePath
              })
        else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        return record
    }

    private func republishManifestForCurrentAuthority(
        record: CodeMapRootManifestRecord,
        root: URL,
        runtime: CodeMapArtifactRuntime
    ) async throws {
        let service = capabilityService()
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let state = await service.resolve(root: WorkspaceCodemapGitCapabilityRequest(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            loadedRootURL: root
        ))
        let capability = try eligible(state)
        let namespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: record.locatorIdentity.pipelineIdentity
        )
        let authority = try CodeMapRootManifestAuthority(
            namespace: namespace,
            token: capability.repositoryAuthority
        )
        let result = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
            ownerID: rootEpoch.rootLifetimeID,
            priority: .explicit,
            target: .artifactKey(record.artifactKey)
        ))
        guard case let .ready(resolution) = result else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
            identity: record.locatorIdentity,
            artifactKey: record.artifactKey,
            casHandle: resolution.handle
        )
        let contribution: CodeMapSelectionGraphContribution? = switch association.outcome {
        case let .ready(artifact):
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                artifact: artifact
            )
        case .readyNoSymbols:
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                definitions: [],
                references: []
            )
        case .oversize, .decodeFailed, .parseFailed:
            nil
        }
        let refreshed = try CodeMapRootManifestRecord.verifiedClean(
            namespace: namespace,
            repositoryRelativePath: record.repositoryRelativePath,
            gitMode: record.gitMode,
            association: association,
            contribution: contribution,
            authority: authority,
            bindingGeneration: record.bindingGeneration
        )
        _ = try await runtime.manifestStore.replaceCurrentManifest(
            namespace: namespace,
            authority: authority,
            records: [refreshed],
            lastAccessEpochSeconds: 42
        )
        await service.release(rootEpoch: rootEpoch)
    }

    private func configureWarmManifestCandidate(
        _ state: WarmManifestCandidateState,
        repository: ReviewGitRepositoryFixture,
        root: URL,
        path: String
    ) throws {
        switch state {
        case .stagedOnly:
            try repository.write("struct Candidate { let staged = true }\n", to: path, at: root)
            try repository.stage(path, at: root)
        case .stagedAndUnstaged:
            try repository.write("struct Candidate { let staged = true }\n", to: path, at: root)
            try repository.stage(path, at: root)
            try repository.write("struct Candidate { let unstaged = true }\n", to: path, at: root)
        case .untrackedReplacement:
            _ = try repository.runGit(["rm", "--cached", "--", path], at: root)
            try repository.write("struct Candidate { let replacement = true }\n", to: path, at: root)
        case .conflict:
            _ = try repository.runGit(["checkout", "-b", "other"], at: root)
            try repository.write("struct Candidate { let side = 1 }\n", to: path, at: root)
            try repository.stage(path, at: root)
            try repository.commit("Other", at: root)
            _ = try repository.runGit(["checkout", "main"], at: root)
            try repository.write("struct Candidate { let side = 2 }\n", to: path, at: root)
            try repository.stage(path, at: root)
            try repository.commit("Main", at: root)
            let merge = try repository.runGitResult(["merge", "other"], at: root)
            XCTAssertNotEqual(merge.terminationStatus, 0)
        case .checkoutTransform:
            try repository.write("\(path) text eol=crlf\n", to: ".gitattributes", at: root)
        }
    }

    private func assertWarmManifestClassification(
        _ classification: GitBlobIdentityClassification,
        matches state: WarmManifestCandidateState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch state {
        case .stagedOnly:
            guard case .oidEligible = classification.outcome else {
                return XCTFail("Expected staged-only OID eligibility.", file: file, line: line)
            }
            XCTAssertTrue(classification.porcelainRecord?.hasIndexChange == true, file: file, line: line)
            XCTAssertFalse(classification.porcelainRecord?.hasWorkTreeChange == true, file: file, line: line)
        case .stagedAndUnstaged:
            XCTAssertEqual(
                classification.outcome,
                .requiresValidatedWorktreeBytes(.stagedAndUnstaged),
                file: file,
                line: line
            )
        case .untrackedReplacement:
            XCTAssertEqual(
                classification.outcome,
                .requiresValidatedWorktreeBytes(.untracked),
                file: file,
                line: line
            )
        case .conflict:
            XCTAssertTrue(classification.hasConflictStages, file: file, line: line)
            XCTAssertEqual(
                classification.outcome,
                .requiresValidatedWorktreeBytes(.unmerged),
                file: file,
                line: line
            )
        case .checkoutTransform:
            XCTAssertEqual(
                classification.outcome,
                .requiresValidatedWorktreeBytes(.checkoutTransformation),
                file: file,
                line: line
            )
            XCTAssertNotEqual(
                classification.checkoutMaterialization,
                .bytePreserving,
                file: file,
                line: line
            )
        }
    }

    private func makeRepositoryFixture(name: String) throws -> ReviewGitRepositoryFixture {
        let fixture = try ReviewGitRepositoryFixture(name: name)
        retainedRepositoryFixtures.append(fixture)
        return fixture
    }

    private func makeEngineFixture(
        root: URL,
        runtime: CodeMapArtifactRuntime,
        policy: WorkspaceCodemapBindingEnginePolicy = .default,
        hooks: WorkspaceCodemapBindingEngineHooks = .none,
        overlay: WorkspaceCodemapLiveOverlay? = nil,
        initialQueueOrdinal: UInt64 = 1,
        initialAdmissionOrdinal: UInt64 = 1,
        initialCounterValue: UInt64 = 0,
        sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient? = nil,
        capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks = .none,
        identityHooks: GitBlobIdentityServiceHooks = .none,
        catalogResolutionHook: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> EngineFixture {
        let rootID = UUID()
        let lifetimeID = UUID()
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: lifetimeID)
        let service = capabilityService(hooks: capabilityHooks)
        let fileSystem = try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let fileIDs = EngineFileIDs()
        let catalog = WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
            await catalogResolutionHook(relativePath)
            guard epoch == rootEpoch,
                  let identity = WorkspaceCodemapArtifactBindingIdentity(
                      rootID: rootID,
                      rootLifetimeID: lifetimeID,
                      fileID: fileIDs.id(for: relativePath),
                      standardizedRootPath: root.path,
                      standardizedRelativePath: relativePath,
                      standardizedFullPath: root.appendingPathComponent(relativePath).path
                  )
            else { return nil }
            return WorkspaceCodemapManifestBindingCandidate(
                identity: identity,
                requestGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }
        let reader = WorkspaceCodemapValidatedSourceReaderClient { identity, expected, maximumBytes, ownerID in
            try await fileSystem.loadValidatedRawContent(
                ofRelativePath: identity.standardizedRelativePath,
                expectedFingerprint: FileContentFingerprint(
                    deviceID: expected.device,
                    fileNumber: expected.inode,
                    byteSize: expected.size,
                    modificationSeconds: expected.modificationSeconds,
                    modificationNanoseconds: expected.modificationNanoseconds,
                    statusChangeSeconds: expected.changeSeconds,
                    statusChangeNanoseconds: expected.changeNanoseconds
                ),
                maximumBytes: maximumBytes,
                workloadClass: .codemap,
                schedulerOwnerID: ownerID
            )
        }
        let registration = WorkspaceCodemapBindingRootRegistration(
            rootID: rootID,
            rootLifetimeID: lifetimeID,
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: service,
            identityService: GitBlobIdentityService(hooks: identityHooks),
            sourceReader: sourceReaderOverride ?? reader,
            catalogClient: catalog,
            overlay: overlay ?? WorkspaceCodemapLiveOverlay(),
            policy: policy,
            hooks: hooks,
            initialQueueOrdinal: initialQueueOrdinal,
            initialAdmissionOrdinal: initialAdmissionOrdinal,
            initialCounterValue: initialCounterValue,
            accessEpochSeconds: { 42 }
        )
        addTeardownBlock { await engine.shutdown() }
        return EngineFixture(
            root: root,
            rootEpoch: rootEpoch,
            registration: registration,
            capabilityService: service,
            fileIDs: fileIDs,
            engine: engine
        )
    }

    private func capabilityService(
        hooks: WorkspaceCodemapGitCapabilityServiceHooks = .none
    ) -> WorkspaceCodemapGitCapabilityService {
        WorkspaceCodemapGitCapabilityService(
            namespaceSalt: Data(repeating: 0x44, count: GitBlobRepositoryNamespace.saltByteCount),
            hooks: hooks
        )
    }

    private func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        let root = parent.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(root.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try root.path.withCString { pointer -> String in
            guard let value = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(value) }
            return String(cString: value)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private func eligible(_ state: WorkspaceCodemapGitCapabilityState) throws -> GitCodemapRootCapability {
        guard case let .eligible(capability) = state else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        return capability
    }

    private func isReady(_ result: WorkspaceCodemapBindingDemandResult) -> Bool {
        switch result {
        case .ready, .alreadyReady:
            true
        default:
            false
        }
    }

    private func demandResult(
        _ task: Task<WorkspaceCodemapBindingDemandResult, Never>,
        before timeout: Duration
    ) async -> WorkspaceCodemapBindingDemandResult? {
        await EngineDemandResultTimeoutRace().wait(for: task, timeout: timeout)
    }

    private func waitForEngineCondition(
        timeout: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private final class EngineDemandResultTimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult?, Never>?
    private var resolved = false

    func wait(
        for task: Task<WorkspaceCodemapBindingDemandResult, Never>,
        timeout: Duration
    ) async -> WorkspaceCodemapBindingDemandResult? {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            Task { [self] in
                await finish(task.value)
            }
            Task { [self] in
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }

    private func finish(_ result: WorkspaceCodemapBindingDemandResult?) {
        let continuation = lock.withLock { () -> CheckedContinuation<WorkspaceCodemapBindingDemandResult?, Never>? in
            guard !resolved else { return nil }
            resolved = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}

private struct EngineFixture {
    let root: URL
    let rootEpoch: WorkspaceCodemapRootEpoch
    let registration: WorkspaceCodemapBindingRootRegistration
    let capabilityService: WorkspaceCodemapGitCapabilityService
    let fileIDs: EngineFileIDs
    let engine: WorkspaceCodemapBindingEngine

    func demand(
        path: String,
        owner: WorkspaceCodemapLiveDemandOwner = WorkspaceCodemapLiveDemandOwner(),
        priority: CodeMapArtifactBuildPriority = .demand,
        language: LanguageType = .swift
    ) -> WorkspaceCodemapBindingDemand {
        let identity = WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            fileID: fileIDs.id(for: path),
            standardizedRootPath: root.path,
            standardizedRelativePath: path,
            standardizedFullPath: root.appendingPathComponent(path).path
        )!
        return WorkspaceCodemapBindingDemand(
            owner: owner,
            identity: identity,
            requestGeneration: 1,
            catalogGeneration: 1,
            pathGeneration: 1,
            ingressGeneration: 1,
            priority: priority,
            language: language
        )
    }
}

private final class EngineFileIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: UUID] = [:]

    func id(for path: String) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[path] { return value }
        let value = UUID()
        values[path] = value
        return value
    }
}

private actor EngineAsyncCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

private final class EngineManifestFaultOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func action(_ point: CodeMapRootManifestStoreFaultPoint) -> CodeMapRootManifestStoreFaultAction {
        lock.withLock {
            guard point == .afterTemporaryWrite, !failed else { return .proceed }
            failed = true
            return .simulateProcessTermination
        }
    }
}

private final class EngineLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class EngineLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }
}

private actor EngineBuildGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        if released { return }
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

private actor EngineOneShotFileMutation {
    private let url: URL
    private let contents: String
    private var didMutate = false
    private(set) var invocationCount = 0

    init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }

    func mutateOnce() {
        invocationCount += 1
        guard !didMutate else { return }
        didMutate = true
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor EngineSecondCatalogResolutionMutation {
    private let url: URL
    private let contents: String
    private(set) var resolutionCount = 0

    init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }

    func resolve() {
        resolutionCount += 1
        guard resolutionCount == 2 else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private final class EngineBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func enterAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered(timeout: TimeInterval = 10) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !entered {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private enum EngineBulkCancellationOperation: CaseIterable {
    case pathInvalidation
    case authorityInvalidation
    case unload
    case shutdown
}

private enum EngineRegistrationInvalidationKind: CaseIterable {
    case path
    case watcher
    case checkout
    case repository
}

private actor EngineMultiEntryGate {
    private var enteredCount = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        enteredCount += 1
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilEntered(
        _ expectedCount: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while enteredCount < expectedCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return enteredCount >= expectedCount
    }

    func releaseAll() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor EngineFirstResolutionGate {
    private(set) var resolutionCount = 0
    private var firstResolutionEntered = false
    private var firstResolutionReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() async {
        resolutionCount += 1
        guard resolutionCount == 1 else { return }
        firstResolutionEntered = true
        if firstResolutionReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFirstResolution(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !firstResolutionEntered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return firstResolutionEntered
    }

    func releaseFirstResolution() {
        firstResolutionReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class EngineHookEvents: @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [WorkspaceCodemapBindingEngineHookEvent] = []

    func record(_ event: WorkspaceCodemapBindingEngineHookEvent) {
        condition.lock()
        events.append(event)
        condition.broadcast()
        condition.unlock()
    }

    func count(kind: WorkspaceCodemapBindingEngineHookKind) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return events.count(where: { $0.kind == kind })
    }

    func numericTotal(kind: WorkspaceCodemapBindingEngineHookKind) -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return events.filter { $0.kind == kind }.reduce(0) { $0 + $1.numericValue }
    }

    func values(kind: WorkspaceCodemapBindingEngineHookKind) -> [WorkspaceCodemapBindingEngineHookEvent] {
        condition.lock()
        defer { condition.unlock() }
        return events.filter { $0.kind == kind }
    }

    func wait(
        kind: WorkspaceCodemapBindingEngineHookKind,
        numericValue: UInt64,
        timeout: TimeInterval = 10
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !events.contains(where: { $0.kind == kind && $0.numericValue == numericValue }) {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}

private final class EngineCompletionFlag: @unchecked Sendable {
    private let condition = NSCondition()
    private var finished = false

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !finished else { return true }
        return condition.wait(until: Date().addingTimeInterval(timeout)) && finished
    }
}

private final class EngineEventDescriptions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
