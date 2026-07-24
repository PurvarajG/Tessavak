# VaaniCore Initial Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first runnable VaaniCore vertical slice: replay structured recogniser candidates through evidence accumulation, adaptive routing, explainable scoring, deterministic BAPS correction, output policy, and a regression-reporting CLI.

**Architecture:** Use one Swift Package Manager workspace with four products: the dependency-free `VaaniCore` library, `VaaniPacks` data library, `VaaniAdapters` protocol-conformance seam, and `VaaniBench` executable. The initial slice is deterministic and fixture-driven; real audio capture, FluidAudio, whisper.cpp, local-LLM, Wffl, and W1 integrations remain outside this plan.

**Tech Stack:** Swift 6.3, Swift Package Manager, Foundation, Swift Testing, ArgumentParser 1.5+, JSON fixtures, GitHub Actions.

## Global Constraints

- Target Apple Silicon macOS 15 or later (`.macOS(.v15)`).
- Keep `VaaniCore` free of SwiftUI, AppKit, persistence frameworks, clipboard APIs, model frameworks, and product state.
- Audio and transcript content remain local; diagnostics contain decision codes and timings, not transcript text by default.
- Preserve mixed English/Gujarati output by default.
- Apply deterministic corrections before any generative correction.
- Make every score and route explainable through named diagnostic components.
- Use strict Swift 6 concurrency checking; exported value types are `Sendable`.
- Do not add real recogniser/model dependencies in this initial build.
- Keep the local-LLM path out of the runtime; define its future seam only if a type requires it.
- Use `Double` probabilities in the closed range `0...1`; reject invalid decoded configuration.

## Initial-build boundary

This plan deliberately implements one complete offline path:

```text
JSON replay fixture
  → language/domain evidence
  → hysteresis accumulator
  → route decision
  → ranked recognition candidate
  → protected/exact deterministic corrections
  → output policy
  → JSON + Markdown benchmark report
```

Deferred to later plans: audio buffers and VAD, live recogniser adapters, fuzzy phonetic correction, local-LLM correction, model downloading, private audio corpus support, Wffl shadow mode, and the W1 application.

## Locked file map

```text
Package.swift
LICENSE
README.md
.gitignore
.github/workflows/ci.yml
Sources/
  VaaniCore/
    Types/Language.swift
    Types/Evidence.swift
    Types/Recognition.swift
    Types/Diagnostics.swift
    Detection/EvidenceAccumulator.swift
    Routing/RoutingPolicy.swift
    Routing/AdaptiveRouter.swift
    Scoring/CandidateScorer.swift
    Correction/Terminology.swift
    Correction/CorrectionEngine.swift
    Output/OutputPolicy.swift
    Pipeline/VaaniPipeline.swift
  VaaniAdapters/
    Replay/ReplayRecognizer.swift
  VaaniPacks/
    PackLoader.swift
    Resources/baps-gujarati-v1.json
  VaaniBench/
    main.swift
    BenchManifest.swift
    BenchRunner.swift
    BenchReport.swift
Tests/
  VaaniCoreTests/
    EvidenceAccumulatorTests.swift
    AdaptiveRouterTests.swift
    CandidateScorerTests.swift
    CorrectionEngineTests.swift
    OutputPolicyTests.swift
    VaaniPipelineTests.swift
  VaaniAdaptersTests/ReplayRecognizerTests.swift
  VaaniPacksTests/PackLoaderTests.swift
  VaaniBenchTests/BenchRunnerTests.swift
Fixtures/
  replay/smoke.json
  expected/smoke-report.json
  baseline/smoke-baseline.json
```

Each file owns one responsibility. Do not merge the accumulator, router, scorer, corrector, or output policy into a single “engine” file.

---

### Task 1: Package scaffold and CI contract

**Files:**
- Create: `Package.swift`
- Create: `LICENSE`
- Create: `.gitignore`
- Create: `README.md`
- Create: `.github/workflows/ci.yml`
- Create: `Sources/VaaniCore/VaaniCore.swift`
- Create: `Sources/VaaniPacks/VaaniPacks.swift`
- Create: `Sources/VaaniAdapters/VaaniAdapters.swift`
- Create: `Sources/VaaniBench/main.swift`
- Create: `Tests/VaaniCoreTests/ScaffoldTests.swift`
- Create: `Tests/VaaniPacksTests/ScaffoldTests.swift`
- Create: `Tests/VaaniAdaptersTests/ScaffoldTests.swift`
- Create: `Tests/VaaniBenchTests/ScaffoldTests.swift`

**Interfaces:**
- Consumes: none.
- Produces: library products `VaaniCore`, `VaaniPacks`, `VaaniAdapters`; executable product `vaani-bench`; matching test targets.

**Acceptance criteria:**
- `swift package describe` lists all four products and eight targets.
- Package platform is macOS 15.
- CI runs build and tests in release-independent deterministic mode.

- [ ] **Step 1: Create the manifest**

Use this target graph:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaaniCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VaaniCore", targets: ["VaaniCore"]),
        .library(name: "VaaniPacks", targets: ["VaaniPacks"]),
        .library(name: "VaaniAdapters", targets: ["VaaniAdapters"]),
        .executable(name: "vaani-bench", targets: ["VaaniBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "VaaniCore"),
        .target(
            name: "VaaniPacks",
            dependencies: ["VaaniCore"],
            resources: [.process("Resources")]
        ),
        .target(name: "VaaniAdapters", dependencies: ["VaaniCore"]),
        .executableTarget(
            name: "VaaniBench",
            dependencies: [
                "VaaniCore",
                "VaaniPacks",
                "VaaniAdapters",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "VaaniCoreTests", dependencies: ["VaaniCore"]),
        .testTarget(name: "VaaniPacksTests", dependencies: ["VaaniPacks"]),
        .testTarget(name: "VaaniAdaptersTests", dependencies: ["VaaniAdapters"]),
        .testTarget(
            name: "VaaniBenchTests",
            dependencies: ["VaaniBench", "VaaniCore", "VaaniPacks", "VaaniAdapters"]
        ),
    ]
)
```

- [ ] **Step 2: Add repository policy files**

Use the canonical Apache-2.0 license text in `LICENSE`. Ignore `.build/`, `.swiftpm/`, `.DS_Store`, `DerivedData/`, `*.xcresult`, private audio (`*.wav`, `*.m4a`, `*.mp3`, `Corpus/Private/`), and generated `Reports/`.

In `README.md`, state the initial-build boundary, prerequisites (`macOS 15+`, Swift 6), and commands:

```bash
swift build
swift test
swift run vaani-bench run --manifest Fixtures/replay/smoke.json --output Reports/smoke
```

- [ ] **Step 3: Add minimal target entry points**

Create one empty public namespace enum in each library entry point, a `main.swift` that prints `VaaniBench scaffold`, and one Swift Testing test per test target that imports its corresponding module and asserts `true`. These files exist only to make the target graph buildable; delete each marker when its first real source/test replaces it.

- [ ] **Step 4: Add CI**

Create one macOS job that checks:

```yaml
- run: swift package resolve
- run: swift build --build-tests
- run: swift test --parallel
- run: swift run vaani-bench run --manifest Fixtures/replay/smoke.json --output Reports/smoke --baseline Fixtures/baseline/smoke-baseline.json
```

- [ ] **Step 5: Verify the scaffold**

Run: `swift package describe && swift test`

Expected: exit 0, products `VaaniCore`, `VaaniPacks`, `VaaniAdapters`, and `vaani-bench`, and four passing scaffold tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift LICENSE README.md .gitignore .github/workflows/ci.yml Sources Tests
git commit -m "build: scaffold VaaniCore Swift package"
```

---

### Task 2: Core value types and decoding invariants

**Files:**
- Create: `Sources/VaaniCore/Types/Language.swift`
- Create: `Sources/VaaniCore/Types/Evidence.swift`
- Create: `Sources/VaaniCore/Types/Recognition.swift`
- Create: `Sources/VaaniCore/Types/Diagnostics.swift`
- Create: `Tests/VaaniCoreTests/CoreTypesTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces:
  - `LanguageTag`, `LanguageDistribution`
  - `EvidenceSource`, `EvidenceObservation`, `EvidenceSnapshot`
  - `RecognitionCandidate`, `RecognitionSegment`, `ModelIdentity`
  - `DecisionCode`, `DiagnosticEvent`, `PipelineDiagnostics`

**Required signatures:**

```swift
public enum LanguageTag: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case gujarati = "gu"
    case hindi = "hi"
    case mixed
    case other
}

public struct LanguageDistribution: Codable, Equatable, Sendable {
    public let values: [LanguageTag: Double]
    public init(values: [LanguageTag: Double]) throws
    public subscript(_ language: LanguageTag) -> Double { get }
    public var dominant: (language: LanguageTag, probability: Double) { get }
}

public enum EvidenceSource: String, Codable, Sendable {
    case acousticLanguageID, recognizer, unicodeScript, romanGujarati
    case terminology, recentContext, applicationProfile, explicitMode, userCorrection
}

public struct EvidenceObservation: Codable, Equatable, Sendable {
    public let languages: LanguageDistribution
    public let domains: [String: Double]
    public let source: EvidenceSource
    public let weight: Double
    public let timestampMilliseconds: Int64
}

public struct EvidenceSnapshot: Codable, Equatable, Sendable {
    public let languages: LanguageDistribution
    public let domains: [String: Double]
    public let activeDomains: Set<String>
    public let observations: Int
}

public struct RecognitionSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let confidence: Double?
}

public struct ModelIdentity: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let name: String
    public let version: String
}

public struct RecognitionCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let confidence: Double
    public let detectedLanguages: LanguageDistribution
    public let segments: [RecognitionSegment]
    public let model: ModelIdentity
    public let latencyMilliseconds: Int
}

public enum DecisionCode: String, Codable, Sendable {
    case routePrimaryEnglish, routePrimaryMultilingual, routeDual
    case candidateSelected, deterministicCorrectionApplied, outputPolicyApplied
    case degradedFallback
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let code: DecisionCode
    public let elapsedMilliseconds: Int
    public let attributes: [String: String]
}

public struct PipelineDiagnostics: Codable, Equatable, Sendable {
    public let events: [DiagnosticEvent]
}
```

`DiagnosticEvent.attributes` must never contain keys named `text`, `transcript`, `audio`, or `rawCandidate`.

- [ ] **Step 1: Write failing invariant tests**

Cover:

```swift
@Test func distributionRejectsOutOfRangeProbability() {
    #expect(throws: (any Error).self) {
        try LanguageDistribution(values: [.english: 1.01])
    }
}

@Test func distributionRejectsNonUnitSum() {
    #expect(throws: (any Error).self) {
        try LanguageDistribution(values: [.english: 0.8, .gujarati: 0.1])
    }
}

@Test func diagnosticsRejectSensitiveAttributeKeys() {
    #expect(throws: (any Error).self) {
        try DiagnosticEvent(
            code: .candidateSelected,
            elapsedMilliseconds: 3,
            attributes: ["text": "private"]
        )
    }
}
```

Permit a sum tolerance of `0.000_001`; missing language keys return `0`. Validate every confidence, weight, probability, non-negative duration, and segment ordering.

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter CoreTypesTests`

Expected: compile failure because the core types do not exist.

- [ ] **Step 3: Implement the value types**

Add a public `VaaniCoreError: Error, Equatable` with cases:

```swift
case invalidProbability(field: String, value: Double)
case invalidDistributionSum(Double)
case invalidTimeRange(start: Int64, end: Int64)
case sensitiveDiagnosticAttribute(String)
case invalidConfiguration(String)
```

Make public initialisers explicit and throwing where validation can fail. Use custom `Codable` initialisers so JSON decoding cannot bypass invariants.

- [ ] **Step 4: Verify**

Run: `swift test --filter CoreTypesTests`

Expected: all CoreTypes tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VaaniCore/Types Tests/VaaniCoreTests/CoreTypesTests.swift
git commit -m "feat(core): add validated recognition and evidence types"
```

---

### Task 3: Evidence accumulation with domain hysteresis

**Files:**
- Create: `Sources/VaaniCore/Detection/EvidenceAccumulator.swift`
- Create: `Tests/VaaniCoreTests/EvidenceAccumulatorTests.swift`

**Interfaces:**
- Consumes: `EvidenceObservation`, `EvidenceSnapshot`.
- Produces:

```swift
public struct EvidenceAccumulatorConfiguration: Codable, Equatable, Sendable {
    public let enterThreshold: Double
    public let exitThreshold: Double
    public let historyLimit: Int
    public init(enterThreshold: Double, exitThreshold: Double, historyLimit: Int) throws
}

public struct EvidenceAccumulator: Sendable {
    public init(configuration: EvidenceAccumulatorConfiguration)
    public mutating func ingest(_ observation: EvidenceObservation) throws -> EvidenceSnapshot
    public mutating func reset()
}
```

**Algorithm contract:**
- Retain at most `historyLimit` observations.
- Compute language/domain means weighted by observation `weight`.
- Normalise the resulting language values to sum to 1.
- Enter a domain when its aggregate is `>= enterThreshold`.
- Keep an active domain until its aggregate is `< exitThreshold`.
- Require `0 <= exitThreshold < enterThreshold <= 1`.
- Never use corrected pipeline output as an evidence source; no such source exists in `EvidenceSource`.

- [ ] **Step 1: Write failing tests**

Test the complete transition sequence:

```swift
@Test func hysteresisPreventsDomainFlapping() throws {
    var accumulator = EvidenceAccumulator(configuration: try .init(
        enterThreshold: 0.70, exitThreshold: 0.40, historyLimit: 2
    ))
    let entered = try accumulator.ingest(observation(domain: 0.80, at: 1))
    #expect(entered.activeDomains == ["baps"])

    let retained = try accumulator.ingest(observation(domain: 0.30, at: 2))
    #expect(retained.activeDomains == ["baps"]) // aggregate 0.55

    let exited = try accumulator.ingest(observation(domain: 0.10, at: 3))
    #expect(exited.activeDomains.isEmpty) // aggregate 0.20
}
```

Also test weighted language aggregation, history eviction, reset, invalid thresholds, and non-monotonic timestamps.

- [ ] **Step 2: Confirm failure**

Run: `swift test --filter EvidenceAccumulatorTests`

Expected: compile failure for missing `EvidenceAccumulator`.

- [ ] **Step 3: Implement the accumulator**

Keep state as private `[EvidenceObservation]`, `Set<String>`, and last timestamp. Sort dictionary keys only when serialising/debugging; numerical aggregation must not depend on dictionary iteration order.

- [ ] **Step 4: Verify**

Run: `swift test --filter EvidenceAccumulatorTests`

Expected: all accumulator tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VaaniCore/Detection Tests/VaaniCoreTests/EvidenceAccumulatorTests.swift
git commit -m "feat(core): accumulate language and domain evidence"
```

---

### Task 4: Adaptive routing and explainable candidate scoring

**Files:**
- Create: `Sources/VaaniCore/Routing/RoutingPolicy.swift`
- Create: `Sources/VaaniCore/Routing/AdaptiveRouter.swift`
- Create: `Sources/VaaniCore/Scoring/CandidateScorer.swift`
- Create: `Tests/VaaniCoreTests/AdaptiveRouterTests.swift`
- Create: `Tests/VaaniCoreTests/CandidateScorerTests.swift`

**Interfaces:**
- Consumes: `EvidenceSnapshot`, `[RecognitionCandidate]`.
- Produces:

```swift
public enum Route: String, Codable, Equatable, Sendable {
    case englishStreaming, multilingual, dual
}

public struct RoutingPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case interactive, meeting, verbatim, evaluation }
    public let mode: Mode
    public let confidentLanguageThreshold: Double
    public let secondDecodeThreshold: Double
    public let latencyBudgetMilliseconds: Int
}

public struct RouteDecision: Codable, Equatable, Sendable {
    public let route: Route
    public let reasons: [String]
}

public struct AdaptiveRouter: Sendable {
    public init(policy: RoutingPolicy)
    public func decide(evidence: EvidenceSnapshot) -> RouteDecision
}

public enum ScoreComponent: String, Codable, CaseIterable, Sendable {
    case acousticConfidence, languageAgreement, scriptAgreement
    case domainTermRecall, protectedTermIntegrity
    case hallucinationPenalty, repetitionPenalty, latencyCost
}

public struct ScoringWeights: Codable, Equatable, Sendable {
    public let values: [ScoreComponent: Double]
    public static let `default`: ScoringWeights
}

public struct CandidateScore: Codable, Equatable, Sendable {
    public let candidateID: String
    public let total: Double
    public let components: [ScoreComponent: Double]
}

public struct ScoredSelection: Codable, Equatable, Sendable {
    public let selected: RecognitionCandidate
    public let scores: [CandidateScore]
}

public struct CandidateScorer: Sendable {
    public init(weights: ScoringWeights = .default, latencyBudgetMilliseconds: Int) throws
    public func select(
        from candidates: [RecognitionCandidate],
        evidence: EvidenceSnapshot,
        protectedTerms: Set<String>
    ) throws -> ScoredSelection
}
```

**Routing table:**
- Dominant English `>= confidentLanguageThreshold`, no active domain, and mixed `< secondDecodeThreshold` → `.englishStreaming`.
- Dominant Gujarati `>= confidentLanguageThreshold` → `.multilingual`.
- Otherwise → `.dual`.
- Empty/invalid evidence is prevented by core invariants; router has no implicit “English by default.”

**Scoring contract:**
- Every candidate reports every `ScoreComponent`.
- Positive components are in `0...1`; penalty/cost components are in `-1...0`.
- `total = Σ(componentValue × weight)`.
- Ties resolve deterministically by lower latency, then lexicographic candidate ID.
- Empty candidates throw `invalidConfiguration("candidate list is empty")`.

- [ ] **Step 1: Write routing tests**

Cover confident English, confident Gujarati, mixed evidence, active BAPS domain ambiguity, and exact reason strings:

```swift
#expect(decision.reasons == ["dominant=en:0.920", "domain=none", "mixed=0.030"])
```

- [ ] **Step 2: Write scoring tests**

Use two candidates where acoustic confidence favours English but language/domain agreement favours Gujarati. Assert every component is present, totals are reproducible to `1e-9`, and tie-breaking is stable.

- [ ] **Step 3: Confirm failure**

Run: `swift test --filter AdaptiveRouterTests && swift test --filter CandidateScorerTests`

Expected: compile failures for missing router/scorer.

- [ ] **Step 4: Implement minimal routing and scoring**

Script agreement uses Unicode scalar ranges to detect Gujarati (`U+0A80...U+0AFF`) and Latin (`U+0041...U+007A`) text. Domain-term recall is exact case-folded token/phrase containment in this task; fuzzy matching is deferred.

Repetition penalty is the fraction of adjacent repeated normalised tokens, negated. Hallucination penalty is `-1` only for an empty/whitespace candidate and `0` otherwise in the initial build. Latency cost is `-min(Double(latency)/Double(latencyBudgetMilliseconds), 1)`. Reject a non-positive latency budget during initialisation.

- [ ] **Step 5: Verify**

Run: `swift test --filter AdaptiveRouterTests && swift test --filter CandidateScorerTests`

Expected: all routing and scoring tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/VaaniCore/Routing Sources/VaaniCore/Scoring Tests/VaaniCoreTests/AdaptiveRouterTests.swift Tests/VaaniCoreTests/CandidateScorerTests.swift
git commit -m "feat(core): add adaptive routing and explainable scoring"
```

---

### Task 5: Versioned pack loading and deterministic correction

**Files:**
- Create: `Sources/VaaniCore/Correction/Terminology.swift`
- Create: `Sources/VaaniCore/Correction/CorrectionEngine.swift`
- Create: `Sources/VaaniPacks/PackLoader.swift`
- Create: `Sources/VaaniPacks/Resources/baps-gujarati-v1.json`
- Create: `Tests/VaaniCoreTests/CorrectionEngineTests.swift`
- Create: `Tests/VaaniPacksTests/PackLoaderTests.swift`

**Interfaces:**
- Consumes: selected candidate text.
- Produces:

```swift
public struct TerminologyEntry: Codable, Equatable, Sendable {
    public let canonical: String
    public let aliases: [String]
    public let language: LanguageTag
    public let script: String
    public let protected: Bool
    public let outputForms: [String: String]
    public let collisionRisk: Double
}

public struct TerminologyPack: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let license: String
    public let provenance: String
    public let entries: [TerminologyEntry]
}

public struct AppliedCorrection: Codable, Equatable, Sendable {
    public let original: String
    public let replacement: String
    public let entryCanonical: String
    public let rule: String
}

public struct CorrectionResult: Codable, Equatable, Sendable {
    public let text: String
    public let corrections: [AppliedCorrection]
}

public struct CorrectionEngine: Sendable {
    public init(pack: TerminologyPack)
    public func correct(_ text: String) -> CorrectionResult
}

public enum PackLoader {
    public static func bundledBAPSGujarati() throws -> TerminologyPack
    public static func load(data: Data) throws -> TerminologyPack
}
```

**Pack seed data:**
- Include a deliberately small, reviewable synthetic seed list: `BAPS`, `Bhagwan Swaminarayan`, `Akshar-Purushottam`, `Pramukh Swami Maharaj`, `Mahant Swami Maharaj`, and `Vachanamrut`.
- Record aliases only when they are obvious casing/punctuation variants; do not invent observed mishearings.
- Use `license: "Project-authored; Apache-2.0"` and provenance explaining that the seed is not yet the curated production terminology corpus.

**Correction contract:**
- Normalise Unicode to NFC.
- Match longest phrases first, case-insensitively, on Unicode word boundaries.
- Never perform substring replacement inside a larger lexical token.
- Canonical/protected phrases already present remain byte-for-byte unchanged.
- Preserve surrounding punctuation and whitespace.
- Record corrections without emitting them to default diagnostics.
- Do not implement fuzzy/phonetic matching in this task.

- [ ] **Step 1: Write failing pack tests**

Decode the bundled resource; assert schema version `1`, unique case-folded canonicals, non-empty provenance/license, collision risk within `0...1`, and every alias maps to only one entry.

- [ ] **Step 2: Write failing correction tests**

Cover longest-match precedence, casing alias replacement, punctuation preservation, collision boundaries, idempotency, and protected-term preservation:

```swift
let once = engine.correct("pramukh swami maharaj, spoke.")
let twice = engine.correct(once.text)
#expect(once.text == "Pramukh Swami Maharaj, spoke.")
#expect(twice.text == once.text)
#expect(twice.corrections.isEmpty)
```

- [ ] **Step 3: Confirm failure**

Run: `swift test --filter PackLoaderTests && swift test --filter CorrectionEngineTests`

Expected: compile failures for missing types.

- [ ] **Step 4: Implement schema validation, loader, and engine**

Reject unsupported schema versions, duplicate aliases, empty IDs/versions/canonical text, and ambiguous alias ownership with `VaaniCoreError.invalidConfiguration`.

- [ ] **Step 5: Verify**

Run: `swift test --filter PackLoaderTests && swift test --filter CorrectionEngineTests`

Expected: all pack and correction tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/VaaniCore/Correction Sources/VaaniPacks Tests/VaaniCoreTests/CorrectionEngineTests.swift Tests/VaaniPacksTests/PackLoaderTests.swift
git commit -m "feat(packs): add BAPS seed pack and deterministic correction"
```

---

### Task 6: Output policies and end-to-end pipeline

**Files:**
- Create: `Sources/VaaniCore/Output/OutputPolicy.swift`
- Create: `Sources/VaaniCore/Pipeline/VaaniPipeline.swift`
- Create: `Tests/VaaniCoreTests/OutputPolicyTests.swift`
- Create: `Tests/VaaniCoreTests/VaaniPipelineTests.swift`

**Interfaces:**
- Consumes: evidence observations, recogniser candidates, terminology pack.
- Produces:

```swift
public enum OutputPolicy: String, Codable, Sendable {
    case preserveMixed, gujaratiScript, bapsRoman
}

public struct OutputRenderer: Sendable {
    public init(pack: TerminologyPack)
    public func render(_ text: String, policy: OutputPolicy) throws -> String
}

public struct PipelineRequest: Sendable {
    public let observations: [EvidenceObservation]
    public let candidates: [RecognitionCandidate]
    public let outputPolicy: OutputPolicy
}

public struct PipelineResult: Codable, Equatable, Sendable {
    public let text: String
    public let route: RouteDecision
    public let selection: ScoredSelection
    public let corrections: [AppliedCorrection]
    public let diagnostics: PipelineDiagnostics
}

public struct VaaniPipeline: Sendable {
    public init(
        accumulatorConfiguration: EvidenceAccumulatorConfiguration,
        routingPolicy: RoutingPolicy,
        scoringWeights: ScoringWeights = .default,
        terminologyPack: TerminologyPack
    ) throws
    public func process(_ request: PipelineRequest) throws -> PipelineResult
}
```

**Initial output-policy contract:**
- `.preserveMixed` returns corrected candidate text unchanged.
- `.bapsRoman` replaces Gujarati terms only when a reviewed `outputForms["bapsRoman"]` exists; otherwise it preserves Gujarati script. This is safe degradation, not full transliteration.
- `.gujaratiScript` replaces recognised Roman pack terms only when `outputForms["gujaratiScript"]` exists; otherwise it preserves input.
- Do not expose `englishTranslation` yet: translation is not available without a translation component and must not be faked.

**Pipeline order:** accumulate all observations → decide route → score candidates → correct selected text → render policy → construct redacted diagnostics.

- [ ] **Step 1: Write output-policy tests**

Test mixed preservation, reviewed form replacement, unknown Gujarati preservation, English-span preservation, and idempotency.

- [ ] **Step 2: Write pipeline integration tests**

Build a request where mixed evidence selects dual route and the multilingual candidate wins due to BAPS terminology. Assert final text, route, selected model, correction list, named score components, event ordering, and absence of transcript text in encoded diagnostics.

- [ ] **Step 3: Confirm failure**

Run: `swift test --filter OutputPolicyTests && swift test --filter VaaniPipelineTests`

Expected: compile failures for missing renderer/pipeline.

- [ ] **Step 4: Implement renderer and pipeline**

Keep pipeline stages as stored value types. Create a fresh accumulator inside `process` so separate requests cannot leak evidence history; persistent meeting context belongs in a later session API.

- [ ] **Step 5: Verify all core tests**

Run: `swift test --filter VaaniCoreTests`

Expected: all VaaniCore tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/VaaniCore/Output Sources/VaaniCore/Pipeline Tests/VaaniCoreTests/OutputPolicyTests.swift Tests/VaaniCoreTests/VaaniPipelineTests.swift
git commit -m "feat(core): compose deterministic Vaani pipeline"
```

---

### Task 7: Replay adapter and deterministic fixture

**Files:**
- Create: `Sources/VaaniAdapters/Replay/ReplayRecognizer.swift`
- Create: `Tests/VaaniAdaptersTests/ReplayRecognizerTests.swift`
- Create: `Fixtures/replay/smoke.json`

**Interfaces:**
- Consumes: fixture JSON.
- Produces:

```swift
public protocol Recognizer: Sendable {
    func candidates(for utteranceID: String) async throws -> [RecognitionCandidate]
}

public struct ReplayUtterance: Codable, Equatable, Sendable {
    public let id: String
    public let observations: [EvidenceObservation]
    public let candidates: [RecognitionCandidate]
    public let expectedText: String
    public let expectedRoute: Route
    public let subset: String
}

public struct ReplayManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let utterances: [ReplayUtterance]
}

public actor ReplayRecognizer: Recognizer {
    public init(manifest: ReplayManifest) throws
    public func candidates(for utteranceID: String) async throws -> [RecognitionCandidate]
}
```

**Fixture contract:**
- Include at least five synthetic utterances: confident English, confident Gujarati, English/Gujarati mixed, BAPS canonical correction, and plain-English collision protection.
- Include no real user audio or transcript.
- Stable IDs and fixed integer timings make reports byte-stable.

- [ ] **Step 1: Write failing replay tests**

Test successful lookup, stable candidate order, duplicate utterance rejection, unknown ID error, and concurrent reads.

- [ ] **Step 2: Confirm failure**

Run: `swift test --filter ReplayRecognizerTests`

Expected: compile failure for missing replay adapter.

- [ ] **Step 3: Implement the adapter and fixture**

Add `VaaniAdapterError` with `duplicateUtteranceID(String)` and `unknownUtteranceID(String)`. Index manifest utterances once during actor initialisation.

- [ ] **Step 4: Verify**

Run: `swift test --filter ReplayRecognizerTests`

Expected: all replay tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VaaniAdapters Tests/VaaniAdaptersTests Fixtures/replay/smoke.json
git commit -m "feat(adapters): add deterministic replay recognizer"
```

---

### Task 8: VaaniBench CLI, reports, and regression gate

**Files:**
- Modify: `Sources/VaaniBench/main.swift`
- Create: `Sources/VaaniBench/BenchManifest.swift`
- Create: `Sources/VaaniBench/BenchRunner.swift`
- Create: `Sources/VaaniBench/BenchReport.swift`
- Create: `Tests/VaaniBenchTests/BenchRunnerTests.swift`
- Create: `Fixtures/expected/smoke-report.json`
- Create: `Fixtures/baseline/smoke-baseline.json`

**Interfaces:**
- Consumes: replay manifest, `VaaniPipeline`, optional baseline.
- Produces:

```swift
public struct BenchMetrics: Codable, Equatable, Sendable {
    public let utteranceCount: Int
    public let exactMatchRate: Double
    public let protectedTermExactMatchRate: Double
    public let falseDomainCorrectionRate: Double
    public let routeAccuracy: Double
    public let dualDecodeRate: Double
    public let medianFinalLatencyMilliseconds: Double
}

public struct BenchReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let manifestSHA256: String
    public let metrics: BenchMetrics
    public let subsetMetrics: [String: BenchMetrics]
    public let regressions: [Regression]
}

public struct Regression: Codable, Equatable, Sendable {
    public let metric: String
    public let baseline: Double
    public let actual: Double
    public let allowedDelta: Double
}

public struct BenchRunner: Sendable {
    public init(pipeline: VaaniPipeline)
    public func run(_ manifest: ReplayManifest, baseline: BenchReport?) throws -> BenchReport
}
```

Task 8 replaces the scaffold `Sources/VaaniBench/main.swift` created in Task 1; it does not create a second entry point.

**CLI contract:**

```text
vaani-bench run
  --manifest <path>
  --output <directory>
  [--baseline <path>]
```

Write `report.json` with sorted keys and `report.md` with a metrics table. Exit:
- `0`: completed with no regression;
- `2`: benchmark regression;
- `64`: invalid command/input;
- `70`: internal pipeline/report failure.

**Regression thresholds for smoke baseline:**
- exact-match and protected-term rates may not decrease.
- false-domain-correction and dual-decode rates may not increase.
- route accuracy may not decrease.
- latency is reported but not gated for replay fixtures because it is synthetic.

- [ ] **Step 1: Write failing metric tests**

Test exact-match, protected term, false domain correction, route accuracy, dual rate, even/odd median, per-subset aggregation, and zero-denominator behaviour (`0`, never NaN).

- [ ] **Step 2: Write failing regression tests**

Use an in-memory baseline; assert the exact `Regression` generated for each worsening metric and no regression for equal/improved values.

- [ ] **Step 3: Confirm failure**

Run: `swift test --filter BenchRunnerTests`

Expected: compile failure for missing bench types.

- [ ] **Step 4: Implement runner and renderers**

Canonicalise JSON before SHA-256 hashing. Use CryptoKit only in `VaaniBench`, not `VaaniCore`. Sort utterances by ID and subset keys lexicographically before aggregation/rendering.

- [ ] **Step 5: Implement CLI**

Use `AsyncParsableCommand`. Load pack and replay manifest, create the evaluation routing policy, run the benchmark, atomically create the output directory files, print a one-line summary, and throw `ExitCode(2)` when regressions are non-empty.

- [ ] **Step 6: Generate and inspect golden outputs**

Run:

```bash
swift run vaani-bench run \
  --manifest Fixtures/replay/smoke.json \
  --output /tmp/vaanicore-smoke
```

Expected: exit 0; `/tmp/vaanicore-smoke/report.json` and `report.md` exist. Inspect both, then copy the reviewed deterministic JSON into `Fixtures/expected/smoke-report.json` and `Fixtures/baseline/smoke-baseline.json`.

- [ ] **Step 7: Add golden and CLI tests**

Assert the produced JSON equals the checked-in expected report after excluding no fields; the report must contain no wall-clock timestamp or machine-specific path.

Run the CLI with the baseline:

```bash
swift run vaani-bench run \
  --manifest Fixtures/replay/smoke.json \
  --output /tmp/vaanicore-smoke-gated \
  --baseline Fixtures/baseline/smoke-baseline.json
```

Expected: exit 0 and `regressions` is empty.

- [ ] **Step 8: Verify**

Run: `swift test --filter VaaniBenchTests`

Expected: all bench tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/VaaniBench Tests/VaaniBenchTests Fixtures/expected Fixtures/baseline
git commit -m "feat(bench): add replay evaluation and regression gate"
```

---

### Task 9: Whole-slice verification and developer handoff

**Files:**
- Modify: `README.md`
- Create: `docs/initial-build.md`

**Interfaces:**
- Consumes: all previous tasks.
- Produces: reproducible developer workflow and evidence that the initial vertical slice works.

**Acceptance criteria:**
- Clean build and full test suite pass.
- Smoke benchmark passes against baseline.
- Core has no forbidden imports.
- No private audio, generated reports, or transcript-bearing diagnostics are committed.
- Documentation identifies deferred work and the next planned milestone.

- [ ] **Step 1: Run format and forbidden-import checks**

Run:

```bash
swift format lint --recursive --strict Sources Tests Package.swift
rg -n 'import (SwiftUI|AppKit|SwiftData|CoreData|AVFoundation|CoreML)' Sources/VaaniCore
```

Expected: format exits 0; `rg` exits 1 with no matches.

- [ ] **Step 2: Run a clean build and all tests**

Run:

```bash
swift package clean
swift build --build-tests
swift test --parallel
```

Expected: all commands exit 0; all tests pass with zero unexpected failures.

- [ ] **Step 3: Run the release smoke benchmark**

Run:

```bash
swift run -c release vaani-bench run \
  --manifest Fixtures/replay/smoke.json \
  --output /tmp/vaanicore-release-smoke \
  --baseline Fixtures/baseline/smoke-baseline.json
```

Expected: exit 0, no regressions, and both report formats generated.

- [ ] **Step 4: Audit privacy and repository contents**

Run:

```bash
rg -n '"(text|transcript|audio|rawCandidate)"\s*:' /tmp/vaanicore-release-smoke/report.json Sources/VaaniCore/Types/Diagnostics.swift
git status --short
git ls-files | rg '\.(wav|m4a|mp3)$|^Reports/|Corpus/Private/'
```

Expected: no private diagnostic payload; only intended documentation changes are uncommitted; no private/generated files are tracked.

- [ ] **Step 5: Document the handoff**

In `docs/initial-build.md`, record:
- exact commands and passing results;
- Swift/macOS version used;
- fixture limitations (synthetic text replay is not an accuracy benchmark);
- implemented boundaries;
- deferred items;
- next milestone: audio/VAD plus real recogniser adapter contract tests, followed by Wffl baseline/shadow mode.

- [ ] **Step 6: Final review**

Review the diff from the design commit:

```bash
git diff --check b4d87c8...HEAD
git log --oneline b4d87c8..HEAD
```

Expected: no whitespace errors; one focused commit per task.

- [ ] **Step 7: Commit**

```bash
git add README.md docs/initial-build.md
git commit -m "docs: document initial VaaniCore build"
```

## Phase checkpoints

### Checkpoint A — Foundation (after Task 3)

The package builds, all public data is validated, diagnostics are privacy-safe, and evidence hysteresis behaves deterministically. Do not proceed if Swift 6 concurrency warnings or invariant bypasses remain.

### Checkpoint B — Core decision path (after Task 6)

An in-memory request executes detection → route → selection → correction → output with explainable, redacted diagnostics. Review public API names here; later fixture and bench work should not force core API churn.

### Checkpoint C — Runnable initial build (after Task 9)

The checked-in smoke fixture runs through `vaani-bench`, produces stable JSON/Markdown, and passes its regression baseline in a clean release build.

## Definition of done

- All nine task commits exist and the worktree is clean.
- `swift test --parallel` passes.
- The release smoke command exits 0.
- The exact checked-in fixture produces byte-stable JSON.
- VaaniCore contains none of the forbidden framework imports.
- Public configuration and decoded data cannot bypass probability/time/schema validation.
- Diagnostics do not contain audio or transcript text by default.
- README and handoff documentation accurately distinguish the deterministic initial slice from real speech-recognition capability.

## Next plan, not part of this one

Create a separate plan for audio/VAD and real recogniser adapters only after Checkpoint C. That plan must begin by capturing actual Wffl/W1 baseline hardware and corpus metadata, then add adapter contract tests before model integration.
