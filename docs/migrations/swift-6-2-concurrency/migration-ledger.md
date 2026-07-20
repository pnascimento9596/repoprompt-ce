# Swift 6.2 Concurrency Migration Ledger

Updated: 2026-07-19

## Toolchain and policy

- Active compiler: Apple Swift 6.2.4 (`swift-driver` 1.127.15), arm64-apple-macosx26.0.
- Root package tools version: 6.2; package default remains Swift 5 language mode.
- Migration policy: target-scoped complete strict-concurrency checking first; `.swiftLanguageMode(.v6)` only in a separate compiler- and generated-workspace-proven boundary. No default MainActor or Swift 6.2 execution/isolation feature is adopted by this tranche.

## Completed boundaries

| Boundary | Commit / state | Language/checking | Evidence |
| --- | --- | --- | --- |
| Dependency/grammar upgrade and broad parser-lock removal | `3b330db9fdfad6c23e715c84d47877995214f1c7` | Swift 5 | Exact SwiftTreeSitter 0.10/runtime 0.25.10 and grammar revisions; scanner shim retained after clean-link proof. |
| `RepoPromptRegexCore` | `6feead2fcfbbd53bc9d4b9d0255401ec51bfd374` | Swift 5 + complete | Owner tests, lint, RepoPrompt build, generator contracts, and preflight passed. |
| `RepoPromptCodeMapCore` / owner tests | Item 3 working tree | Swift 5 + complete | Deterministic synchronous parser/query/extraction and canonical artifact core extracted; focused evidence is recorded below and finalized with the Item 3 commit. |

## Item 3 ownership record

Moved to `RepoPromptCodeMapCore`:

- provenance-free decoder policy/raw digest/decoded result vocabulary with pipeline and artifact-key canonical encoding;
- immutable grammar/pipeline descriptors, exact CodeMap-only query bytes, extension registry, parse limits, and synchronous Tree-sitter execution;
- syntax artifact outcomes/builder, capture indexing, extraction memoization, signature/type helpers, language strategies, generator, and path-free canonical artifact rendering;
- invocation-local parser, query cursor, extraction memo, and performance collector state.

Split or retained in `RepoPromptApp`:

- decoder and SHA construction authority, exact raw bytes, validation tokens, Git/worktree provenance, and workspace decoder;
- direct SwiftTreeSitter highlighting linkage and mutable highlight/language caches;
- build permits, priority, pre/post parse cancellation, coordinator flights/fairness, environment flags, and performance aggregation;
- CAS/container/catalog/locator/manifest persistence, workspace/Git authority, token and path/import presentation, selection-graph policy, UI, and MCP.

Test ownership:

- `RepoPromptCodeMapCoreTests` is the sole owner of pure CodeMap parsing fixtures, goldens, canonical byte tests, deterministic negative outcomes, registry/query bytes, and concurrent all-language initialization/build checks.
- `RepoPromptTests` retains adapter, coordinator/cancellation, persistence/CAS, workspace, presentation, highlighting, UI, and MCP integration tests.

## Strict-concurrency diagnostics and escape hatches

- `RepoPromptCodeMapCore` and `RepoPromptCodeMapCoreTests` use `-strict-concurrency=complete` in Swift 5 mode.
- Parser and cursor objects are invocation-local and never cross a Sendable boundary. Public cross-target graphs are package-visible immutable Sendable values.
- `LanguageTypeExtractor` uses narrowly documented `nonisolated(unsafe)` only for immutable, once-initialized standard-library `Regex` values whose type-erased output metadata does not expose Sendable conformance. Matching is nonmutating and no mutable shared cache is hidden by the annotation.
- No `@unchecked Sendable` was added to the core; the app retains its pre-existing closure/client synchronization boundary.

## Item 3 evidence

- Baseline golden: conductor ticket `880de0e6…` — 14 language fixture/golden comparisons passed before extraction.
- Baseline syntax artifact: ticket `b10a0628…` — six deterministic artifact/outcome tests passed before extraction.
- Baseline authoritative test list: ticket `fdb54f9e…`.
- Extracted canonical key/registry/concurrency suite: ticket `d690b814…` — passed under the owner target.
- Complete owner target: ticket `5928f578…` — 16 tests passed (9 canonical key/registry/concurrency, 1 golden corpus test covering 14 files, and 6 artifact/outcome tests); log grep found zero warnings or errors attributed to `Sources/RepoPromptCodeMapCore` or `Tests/RepoPromptCodeMapCoreTests`.
- Focused app integration: ticket `e5eacaf7…` — 95 adapter, app golden/presentation, coordinator, container, store, and workspace-binding tests passed, including 35 coordinator retry/cancellation/CAS tests.
- Byte-identity audit: all 27 moved fixture/golden resources and all 13 CodeMap query literal bodies exactly match `HEAD` before extraction; `Package.resolved` is unchanged.
- Authoritative root test list: ticket `c590972a…`; exact ledger verification passed at 3,451 IDs with final root ticket `3f92a87b…` and provider ticket `4257122f…`.
- SwiftFormat mutation: ticket `e673cfbe…`; strict formatter/lint: final ticket `e7c517b7…`; source/license guardrails passed.
- Coordinated ad-hoc debug package and authorized relaunch: ticket `25a7eb0b…`; package/build/signature/launch completed. The debug app uses documented ephemeral secure storage; no live MCP behavior test was required for the synchronous internal seam.

## Swift 6 language-mode gate

Deferred for Item 3 unless both compiler invocation and generated-workspace behavior are clean. The previously recorded generated Xcode workspace blocker is the upstream `tree-sitter/lib` custom-path issue; therefore a target-mode change must not be bundled with the architectural extraction without fresh contrary proof.
