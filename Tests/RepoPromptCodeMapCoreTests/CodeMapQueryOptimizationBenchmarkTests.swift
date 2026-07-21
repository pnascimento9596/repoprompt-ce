import Foundation
import XCTest
@testable import RepoPromptCodeMapCore

final class CodeMapQueryOptimizationBenchmarkTests: XCTestCase {
    func testSyntheticSwiftAndTypeScriptAttribution() throws {
        let cases: [(name: String, language: LanguageType, source: String)] = [
            ("swift", .swift, Self.swiftSource(declarationCount: 200)),
            ("typescript", .ts, Self.typeScriptSource(declarationCount: 200)),
        ]

        for benchmark in cases {
            for _ in 0 ..< 2 {
                _ = try build(source: benchmark.source, language: benchmark.language)
            }

            var samplesMS: [Double] = []
            for _ in 0 ..< 5 {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try build(source: benchmark.source, language: benchmark.language)
                samplesMS.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            samplesMS.sort()
            let collector = CodeMapPerformanceCollector(collectsCaptureNames: true)
            _ = try build(
                source: benchmark.source,
                language: benchmark.language,
                options: .countersOnly,
                collector: collector
            )
            XCTAssertEqual(collector.syntaxQueryExecutes, 1)
            XCTAssertGreaterThan(collector.syntaxCaptures, 0)

            print(
                [
                    "CODEMAP_QUERY_BENCHMARK",
                    "language=\(benchmark.name)",
                    "declarations=200",
                    "median_ms=\(String(format: "%.3f", samplesMS[samplesMS.count / 2]))",
                    "max_ms=\(String(format: "%.3f", samplesMS.last ?? 0))",
                    "parse_ms=\(Self.milliseconds(collector.syntaxParseDuration))",
                    "query_ms=\(Self.milliseconds(collector.syntaxQueryExecuteDuration))",
                    "materialize_ms=\(Self.milliseconds(collector.syntaxCaptureMaterializationDuration))",
                    "capture_name_count_ms=\(Self.milliseconds(collector.syntaxCaptureNameCountingDuration))",
                    "index_ms=\(Self.milliseconds(collector.captureIndexDuration))",
                    "capture_loop_ms=\(Self.milliseconds(collector.captureLoopDuration))",
                    "captures=\(collector.syntaxCaptures)",
                    "lte_function_calls=\(collector.lteMatchAnyFunctionCalls)",
                    "lte_variable_calls=\(collector.lteMatchAnyVariableCalls)",
                    "jsts_calls=\(collector.jstsSignatureCallsFunctionLike + collector.jstsSignatureCallsStatementLike)",
                    "ts_duplicate_suppressions=\(collector.tsDuplicateFunctionVariableSuppressions)",
                    "swift_bodies=\(collector.syntaxCaptureCountsByName["swift.function.body", default: 0])",
                    "swift_returns=\(collector.syntaxCaptureCountsByName["swift.function.return_type", default: 0])",
                    "swift_property_types=\(collector.syntaxCaptureCountsByName["swift.property.type", default: 0])",
                    "ts_variables=\(collector.syntaxCaptureCountsByName["variable.global", default: 0])",
                ].joined(separator: " ")
            )
        }
    }

    func testStructuralFastPathsPreserveRoutingAndTypes() throws {
        let swiftCollector = CodeMapPerformanceCollector(collectsCaptureNames: true)
        let swiftSource = """
        struct Example {
            let result: Result<[String: Int], BenchError> = .success([:])
            func transform<T>(
                _ input: T,
                fallback: @autoclosure () -> String = "}"
            ) async throws -> Result<T, BenchError> where T: Sendable {
                _ = fallback()
                return .success(input)
            }
        }
        """
        let swiftArtifact = try build(
            source: swiftSource,
            language: .swift,
            options: .countersOnly,
            collector: swiftCollector
        )
        XCTAssertEqual(swiftArtifact.classes.first?.properties.first?.typeName, "Result<[String: Int], BenchError>")
        XCTAssertTrue(swiftArtifact.classes.first?.methods.first?.definitionLine.contains("async throws -> Result<T, BenchError> where T: Sendable") == true)
        XCTAssertEqual(
            swiftArtifact.classes.first?.methods.first?.parameters.map(\.typeName),
            ["T", "@autoclosure () -> String"]
        )
        XCTAssertEqual(swiftCollector.syntaxCaptureCountsByName["swift.param.type", default: 0], 0)
        XCTAssertEqual(swiftCollector.syntaxCaptureCountsByName["function.definition", default: 0], 0)
        XCTAssertEqual(swiftCollector.lteMatchAnyVariableCalls, 1)

        let tsCollector = CodeMapPerformanceCollector(collectsCaptureNames: true)
        let tsSource = """
        export const transform = async <T>(input: T): Promise<{ value: T }> => {
            return { value: input };
        };
        export const payload: { marker: string } = { marker: "=>" };
        """
        let tsArtifact = try build(
            source: tsSource,
            language: .ts,
            options: .countersOnly,
            collector: tsCollector
        )
        XCTAssertEqual(tsArtifact.functions.map(\.name), ["transform"])
        XCTAssertEqual(tsArtifact.globalVars.count, 1)
        XCTAssertTrue(tsArtifact.globalVars[0].definitionLine.contains("payload"))
        XCTAssertEqual(tsCollector.tsDuplicateFunctionVariableSuppressions, 1)

        let tsxCollector = CodeMapPerformanceCollector(collectsCaptureNames: true)
        let tsxSource = """
        export const Card = (props: { title: string }) => <div>{props.title}</div>;
        export const marker: { text: string } = { text: "=>" };
        """
        let tsxArtifact = try build(
            source: tsxSource,
            language: .tsx,
            options: .countersOnly,
            collector: tsxCollector
        )
        XCTAssertEqual(tsxArtifact.functions.map(\.name), ["Card"])
        XCTAssertEqual(tsxArtifact.globalVars.count, 1)
        XCTAssertEqual(tsxCollector.tsDuplicateFunctionVariableSuppressions, 1)
    }

    func testTypeScriptUncontainedMembersFallThroughBeforeExtraction() throws {
        let source = """
        class Example {
            value: string = "value";
            method(): void {}
        }
        interface Shape {
            property: string;
            method(): void;
            (): void;
            new (): Shape;
            [key: string]: unknown;
        }
        """
        let outcome = try CodeMapSyntaxEngine.shared.codeMap(content: source, language: .ts)
        guard case let .captures(captures) = outcome else {
            return XCTFail("Expected TypeScript query captures, got \(outcome)")
        }
        let targetNames: Set<String> = [
            "method",
            "variable.field",
            "method_signature",
            "property_signature",
            "call_signature",
            "construct_signature",
            "index_signature",
        ]
        let targetCaptures = captures.filter { targetNames.contains($0.name) }
        XCTAssertEqual(Set(targetCaptures.map(\.name)), targetNames)
        let index = CodeMapCaptureIndex(captures)
        let nsContent = source as NSString

        for capture in targetCaptures {
            var classesByLine: [Int: ClassInfo] = [:]
            var interfacesByLine: [Int: InterfaceInfo] = [:]
            var globalFunctions: [FunctionInfo] = []
            var globalVariables: [VariableInfo] = []
            var referencedTypes = ReferencedTypesAccumulator(language: .ts)
            var extractionMemo = CodeMapExtractionMemo()
            var trimmedLineCalls = 0

            let handled = TypeScriptCodeMapStrategy.handleCapture(
                capture,
                context: .init(),
                index: index,
                content: source,
                nsContent: nsContent,
                boundaries: [0],
                lineNo: 1,
                language: .ts,
                getTrimmedLine: { _ in
                    trimmedLineCalls += 1
                    return "unexpected"
                },
                classesByLine: &classesByLine,
                interfaceBoundaries: &interfacesByLine,
                globalFunctions: &globalFunctions,
                globalVariables: &globalVariables,
                referencedTypes: &referencedTypes,
                extractionMemo: &extractionMemo
            )

            XCTAssertFalse(handled, "Expected \(capture.name) to fall through without a container")
            XCTAssertEqual(trimmedLineCalls, 0)
            XCTAssertTrue(classesByLine.isEmpty)
            XCTAssertTrue(interfacesByLine.isEmpty)
            XCTAssertTrue(globalFunctions.isEmpty)
            XCTAssertTrue(globalVariables.isEmpty)
            XCTAssertTrue(referencedTypes.types.isEmpty)
        }
    }

    private enum BenchmarkError: Error {
        case notReady(CodeMapSyntaxArtifactOutcome)
    }

    private func build(
        source: String,
        language: LanguageType,
        options: CodeMapPerfOptions = .disabled,
        collector: CodeMapPerformanceCollector? = nil
    ) throws -> CodeMapSyntaxArtifact {
        let outcome = try CodeMapSyntaxArtifactBuilder.build(
            source: CodeMapFixtureRunner.makeSourceSnapshot(content: source),
            language: language,
            performanceOptions: options,
            performanceCollector: collector
        )
        guard case let .ready(artifact) = outcome else {
            throw BenchmarkError.notReady(outcome)
        }
        return artifact
    }

    private static func milliseconds(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration * 1_000)
    }

    private static func swiftSource(declarationCount: Int) -> String {
        (0 ..< declarationCount).map { index in
            """
            struct SwiftBench\(index) {
                let value\(index): Result<[String: Int], BenchError> = .success([:])
                func transform\(index)<T>(_ input: T, fallback: @autoclosure () -> String = "}") async throws -> Result<T, BenchError> where T: Sendable {
                    _ = fallback()
                    return .success(input)
                }
            }
            """
        }.joined(separator: "\n")
    }

    private static func typeScriptSource(declarationCount: Int) -> String {
        (0 ..< declarationCount).map { index in
            """
            export interface TypeBench\(index)<T> {
                value\(index): Promise<Record<string, T>>;
                transform\(index)(input: T, fallback?: () => { value: T }): Promise<{ value: T }>;
            }
            export const transform\(index) = async <T>(input: T): Promise<{ value: T }> => {
                return { value: input };
            };
            export const payload\(index): Record<string, number> = { value: \(index) };
            """
        }.joined(separator: "\n")
    }
}
