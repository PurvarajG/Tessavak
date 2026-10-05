# TessavakCore Phase 2 — Live Orchestration Contracts and First Real Recognizer

Date: 2026-07-24
Status: Approved plan; gated on Phase 1 audit remediation (complete).

**Architecture:** Phase 2 turns the deterministic replay slice into a live-capable engine in two halves. Tasks 1–6 build the core-owned live orchestration layer — audio/utterance value types, async `Detector`/`Recognizer` protocols, `RoutingPlan`, and a `LivePipelineCoordinator` with cancellation, timeout, and degraded-fallback semantics — all fully deterministic and offline-testable with mock recognizers and a controllable clock. Tasks 7–8 are the de-risking spike the product needs most: a whisper.cpp adapter and a file-driven `tessavak-live` CLI harness so real Gujarati/code-switched audio can be transcribed end-to-end for the first time. No microphone capture, VAD models, or consumer apps in this phase.

**Tech Stack:** Swift 6 (strict concurrency), Swift Package Manager, Swift Testing, Foundation, swift-argument-parser. Task 7 adds whisper.cpp as an SPM dependency confined to a new `TessavakWhisper` target. AVFoundation remains forbidden everywhere in this phase (file decode in the CLI uses whisper.cpp's own WAV reading or a minimal hand-written PCM WAV parser).

## Global constraints

- `Sources/TessavakCore` stays free of SwiftUI, AppKit, SwiftData, CoreData, AVFoundation, CoreML, and any third-party import. `scripts/verify.sh` already enforces this; do not weaken it.
- whisper.cpp may be imported **only** inside the new `Sources/TessavakWhisper` target and its tests. TessavakCore, TessavakAdapters, TessavakPacks, and TessavakBench must not depend on it.
- All new public types use throwing, validating initializers and custom `init(from:)` decoders, matching the Phase 1 pattern (invariants cannot be bypassed by decoding crafted JSON).
- All coordinator behavior must be testable without real time: inject a clock/timeout abstraction; never `Task.sleep` against the wall clock in tests.
- TDD for every behavior change: focused failing test → run it → smallest implementation → focused rerun → full suite → commit.
- Diagnostics carry decision codes, timings, and counts only — never transcript or audio content (`DiagnosticEvent` already rejects those keys; keep it that way in every new event you emit).
- No latency number produced by mocks or the replay path may be described as a measured performance result. Only Task 8's real-audio harness may print wall-clock timings, and its report must label the hardware and model.
- Do not modify Phase 1 behavior, fixtures, or baselines except where a task explicitly says so. Never regenerate a baseline to make a gate pass.
- Existing tests (currently >115) must keep passing after every task.

## File map

### New production files

- `Sources/TessavakCore/Types/Audio.swift` — `AudioFormat`, `AudioChunk`, `SpeechEvent`.
- `Sources/TessavakCore/Recognition/Recognizer.swift` — core-owned `Recognizer` + `StreamingRecognizer` protocols and `RecognitionUpdate`.
- `Sources/TessavakCore/Detection/Detector.swift` — async `Detector` protocol over `SpeechEvent`s.
- `Sources/TessavakCore/Routing/RoutingPlan.swift` — typed plan produced by `AdaptiveRouter` for live execution.
- `Sources/TessavakCore/Pipeline/LivePipelineCoordinator.swift` — actor orchestrating detect → route → recognize → score → correct → render for one utterance stream.
- `Sources/TessavakWhisper/WhisperRecognizer.swift` — whisper.cpp adapter (Task 7).
- `Sources/TessavakLive/main.swift` — `tessavak-live` file-driven CLI harness (Task 8).

### New test files

- `Tests/TessavakCoreTests/AudioTypesTests.swift`
- `Tests/TessavakCoreTests/RoutingPlanTests.swift`
- `Tests/TessavakCoreTests/LivePipelineCoordinatorTests.swift`
- `Tests/TessavakAdaptersTests/RecognizerContractTests.swift`
- `Tests/TessavakWhisperTests/WhisperRecognizerTests.swift` (skips when no model file present)

### Modified files

- `Package.swift` — new targets `TessavakWhisper`, `TessavakLive`, their test targets, whisper.cpp dependency.
- `Sources/TessavakAdapters/Replay/ReplayRecognizer.swift` — conform to the new core `Recognizer` protocol; the local protocol definition moves to TessavakCore.
- `scripts/verify.sh` — extend forbidden-import scan to keep whisper.cpp out of TessavakCore/TessavakAdapters/TessavakBench; build the new targets.
- `README.md`, `docs/initial-build.md` — document the new boundary at the end.

---

## Task 1: Core audio and utterance value types

**Files:** create `Sources/TessavakCore/Types/Audio.swift`, `Tests/TessavakCoreTests/AudioTypesTests.swift`.

Define, with throwing validating initializers and validating decoders:

- `AudioFormat`: sample rate (Hz, must be > 0; canonical constant `AudioFormat.canonical` = 16 000 Hz mono 16-bit), channel count (must be 1 for now), sample width.
- `AudioChunk`: `format`, `frameCount` (> 0), `startMilliseconds`/`endMilliseconds` monotonic and consistent with `frameCount` at the given rate (±1 ms tolerance), and an opaque `samples: [Int16]` whose count matches `frameCount × channels`. `AudioChunk` is deliberately **not** `Codable` — audio never enters JSON reports or diagnostics.
- `SpeechEvent`: enum with `speechStarted(atMilliseconds:)`, `chunk(AudioChunk)`, `speechEnded(atMilliseconds:)`, `endOfStream`. Ordering invariants (no chunk before start, monotonic timestamps) are validated by the coordinator, not the enum.

Tests: valid construction, each invariant violation throws the right `TessavakCoreError`, and `AudioChunk` sample-count/time-range consistency edge cases.

## Task 2: Core-owned async Recognizer and Detector protocols

**Files:** create `Sources/TessavakCore/Recognition/Recognizer.swift`, `Sources/TessavakCore/Detection/Detector.swift`; modify `Sources/TessavakAdapters/Replay/ReplayRecognizer.swift`.

- Move the existing `Recognizer` protocol (currently declared in `ReplayRecognizer.swift`) into TessavakCore unchanged in shape (`func candidates(for utteranceID: String) async throws -> [RecognitionCandidate]` becomes the *replay* protocol `ReplayCandidateSource`, kept for TessavakBench), and add the live protocols:

```swift
public struct RecognitionUpdate: Sendable {
    public let candidate: RecognitionCandidate
    public let isFinal: Bool
}

public protocol StreamingRecognizer: Sendable {
    var identity: ModelIdentity { get }
    /// Consumes one utterance's audio and yields partial then final updates.
    func recognize(_ audio: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<RecognitionUpdate, Error>
}

public protocol Detector: Sendable {
    /// Updates evidence from audio and/or provisional text; pure with respect to injected state.
    func observations(for event: SpeechEvent, provisionalText: String?) async throws -> [EvidenceObservation]
}
```

- `ReplayRecognizer` conforms to `ReplayCandidateSource` exactly as today; TessavakBench keeps compiling with only the protocol's new name/import path changing.
- Add `Tests/TessavakAdaptersTests/RecognizerContractTests.swift`: a reusable contract-test helper (generic over `StreamingRecognizer`) asserting: at least one final update per utterance; no updates after a final; candidates carry non-empty model identity; stream terminates; cancellation of the consuming task terminates the stream without hanging. Exercise it against a purpose-built `MockStreamingRecognizer` (place the mock in the test target so both this suite and Task 4 reuse it).

## Task 3: RoutingPlan

**Files:** create `Sources/TessavakCore/Routing/RoutingPlan.swift`, `Tests/TessavakCoreTests/RoutingPlanTests.swift`; modify `Sources/TessavakCore/Routing/AdaptiveRouter.swift` (additive only).

- `RoutingPlan` (Sendable, Equatable): `primary: Route`, `secondary: Route?`, `secondaryTrigger: SecondaryTrigger` (enum: `never`, `onLowConfidence(threshold: Double)`, `immediately`), `latencyBudgetMilliseconds: Int` (> 0), `policy: SessionPolicy` (enum: `interactive`, `meeting`, `verbatim`, `evaluation` — matching design spec §7).
- Add `AdaptiveRouter.plan(for:policy:)` that wraps the existing `RouteDecision` logic into a `RoutingPlan`: confident single-route decisions produce `secondary: nil`; the existing dual-decode decision produces primary + secondary with `onLowConfidence` using the router's configured threshold; `interactive` policy gets a tighter default budget than `meeting` (constants in configuration, validated > 0). Do not change any existing `RouteDecision` behavior or test.
- Tests: plan derivation for confident English, confident Gujarati, mixed/uncertain evidence; policy-dependent budgets; invalid budget rejected.

## Task 4: LivePipelineCoordinator

**Files:** create `Sources/TessavakCore/Pipeline/LivePipelineCoordinator.swift`, `Tests/TessavakCoreTests/LivePipelineCoordinatorTests.swift`.

An `actor LivePipelineCoordinator` that, given a `Detector`, primary/secondary `StreamingRecognizer` lookup (`@Sendable (Route) -> StreamingRecognizer?`), the existing `CandidateScorer`, `CorrectionEngine`, `OutputRenderer`, and an injected timeout abstraction, processes **one utterance**:

1. Consume a `SpeechEvent` stream; validate ordering (chunk before `speechStarted`, non-monotonic timestamps, or events after `endOfStream` throw typed errors).
2. Feed events to the `Detector`, accumulate evidence (fresh `EvidenceAccumulator` per utterance, same as `TessavakPipeline`), obtain a `RoutingPlan` once `speechEnded` arrives (or earlier if the plan's policy is `interactive` and a confident route emerges — expose this as a decision code, keep the logic simple).
3. Run the primary recognizer; start the secondary only when the plan's trigger fires (low final-candidate confidence below threshold, or `immediately`).
4. Enforce `latencyBudgetMilliseconds` via the injected timeout: on budget exhaustion, cancel outstanding recognition and proceed with the best completed candidate; if none completed, throw a typed `budgetExhaustedWithoutCandidate` error.
5. If the selected recognizer for a route is unavailable (`nil` lookup), fall back to the other available route and emit a `degradedMode` decision-code diagnostic (design spec §15).
6. Score all final candidates with `CandidateScorer`, correct, render, and return the existing `PipelineResult` plus diagnostics (decision codes for: route chosen, plan trigger fired or not, degraded mode, budget outcome, cancellation).

Timeout abstraction: `protocol DeadlineScheduler: Sendable { func withDeadline<T: Sendable>(milliseconds: Int, _ body: ...) async throws -> T }` (or an equivalent shape that fits Swift 6 concurrency cleanly) with a production `ContinuousClock` implementation and a manual test implementation that fires deterministically.

Tests (all with mocks, no wall-clock sleeps): happy path single route; secondary triggered by low confidence and its candidate winning; secondary not triggered above threshold; budget exhaustion with one completed candidate; budget exhaustion with none (typed error); degraded fallback when a recognizer is missing; malformed event ordering; external cancellation propagates and leaves no leaked tasks; recognizer stream error on primary falls back per §15 rather than failing the utterance when the secondary succeeds.

## Task 5: Contract-test the replay path against the live protocols

**Files:** modify `Sources/TessavakAdapters/Replay/ReplayRecognizer.swift`; extend `Tests/TessavakAdaptersTests/RecognizerContractTests.swift`.

Add a thin `ReplayStreamingRecognizer` adapter in TessavakAdapters: wraps `ReplayRecognizer` + a fixed utterance ID, ignores the audio stream's content, and yields the replay candidates as one final `RecognitionUpdate` each (highest-scoring last is not assumed — order as stored). Run the Task 2 contract suite against it. This proves the contract tests are adapter-agnostic before a real model exists, and gives the coordinator an offline end-to-end test: add one `LivePipelineCoordinatorTests` case driving the coordinator with `ReplayStreamingRecognizer`s built from `Fixtures/replay/smoke.json` utterances and asserting the final text equals the fixture's `expectedText`.

## Task 6: Verification-gate and documentation update for the contracts half

**Files:** modify `scripts/verify.sh`, `README.md`, `docs/initial-build.md`.

- Extend the forbidden-import scan: TessavakCore additionally rejects `import whisper`/`SwiftWhisper`/any third-party module; assert TessavakAdapters/TessavakBench do not import whisper either.
- Update README and `docs/initial-build.md`: the live orchestration contracts exist and are mock-tested; real audio quality and latency remain unmeasured.
- Run `./scripts/verify.sh` — everything green before starting Task 7.

**Checkpoint A (stop for owner review before Task 7):** Tasks 1–6 are pure-Swift and dependency-free. Task 7 adds a third-party native dependency; the owner may want to choose the whisper.cpp packaging (see Task 7 options) before it lands.

## Task 7: WhisperRecognizer adapter (first real model)

**Files:** modify `Package.swift`; create `Sources/TessavakWhisper/WhisperRecognizer.swift`, `Tests/TessavakWhisperTests/WhisperRecognizerTests.swift`.

- Dependency: prefer `https://github.com/ggml-org/whisper.cpp` via SPM (it ships a `Package.swift`). If its current SPM support fails to build on this toolchain, fall back to `https://github.com/exPHAT/SwiftWhisper`. Pin an exact revision either way and record it in `docs/initial-build.md`. If neither builds, stop and report — do not vendor sources.
- `WhisperRecognizer: StreamingRecognizer` (an actor or a Sendable wrapper around a serialized context): init takes a model file URL (must exist, non-empty; validated) and a language hint (`en`, `gu`, or auto). `recognize` buffers the utterance's chunks (whole-utterance decode is acceptable for this phase; true streaming partials are Phase 3), converts `Int16` → `Float` PCM, runs whisper, and yields one final `RecognitionUpdate` whose `RecognitionCandidate` carries segment timings, whisper's language detection mapped into the existing `LanguageProbability` shape, per-segment confidence where the API exposes it, and `ModelIdentity(provider: "whisper.cpp", name: <model file stem>, version: <pinned revision>)`.
- Tests: model-path validation failures; and — **only when** the environment variable `TESSAVAK_WHISPER_MODEL` points at an existing `.bin` model — run the Task 2 contract suite plus one real decode of a generated 1-second sine/silence WAV asserting the stream completes with a final update. When the variable is unset, record these as skipped (Swift Testing `.enabled(if:)`), never as failures. CI does not download models.

## Task 8: `tessavak-live` file-driven harness

**Files:** modify `Package.swift`; create `Sources/TessavakLive/main.swift`.

A small executable target (depends on TessavakCore, TessavakPacks, TessavakWhisper, ArgumentParser):

```bash
swift run tessavak-live transcribe --model <path.bin> --audio <path.wav> \
  [--policy interactive|meeting] [--language auto|en|gu] [--output-policy preserveMixed|gujaratiScript|bapsRoman]
```

- Reads a 16 kHz mono 16-bit PCM WAV (minimal hand-written RIFF parser with validation; reject other formats with a clear message telling the user the required `ffmpeg -ar 16000 -ac 1` conversion — no AVFoundation).
- Wraps the file as one utterance's `SpeechEvent` stream, runs it through `LivePipelineCoordinator` with `WhisperRecognizer` as both routes' recognizer (single-model; dual real routing is Phase 3), the BAPS seed pack correction engine, and the chosen output policy.
- Prints the final text, route/decision codes, applied corrections, and wall-clock decode time labelled `measured on this machine, single run, not a benchmark`.
- Exit codes follow the tessavak-bench convention: 0 success, 64 invalid input (bad WAV, missing model), 70 internal failure.
- No automated test beyond `--help` parsing (add a minimal argument-validation test if trivial); real-audio validation is the owner's manual step.

## Final verification (after Task 8)

```bash
cd /Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore
./scripts/verify.sh
swift test --parallel
swift format lint --recursive --strict Sources Tests Package.swift
swift build -c release
git status --short && git diff --check
```

All exit 0; final test count must exceed the pre-Phase-2 count by at least 30. Then update `README.md` and `docs/initial-build.md`: what Phase 2 added, the whisper pinned revision and its licence (MIT) recorded per design spec §17, the model-file requirement, and the still-deferred list (mic capture, VAD, FluidAudio streaming recogniser, fuzzy correction, local LLM, corpus, Wffl shadow mode, W1 shell).

## Explicitly deferred to Phase 3

Microphone capture and AVFoundation, VAD models, FluidAudio/Parakeet streaming adapter, true streaming partials from whisper, dual *real* recognizer routing, fuzzy/phonetic correction, local-LLM fallback, model download/lifecycle management, labelled evaluation corpus, latency benchmarking on reference hardware, Wffl shadow mode, W1 app.
