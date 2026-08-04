# VaaniCore Initial Build — Developer Handoff

Status: Checkpoint C complete; Phase 1 audit remediation complete. This
document records what the initial vertical slice implements, how it was
verified, and what is deliberately deferred to the next plan.

## Environment used for verification

- Swift: 6.3.3 (`swiftlang-6.3.3.1.3 clang-2100.1.1.101`), swift-driver 1.148.6
- Target platform: `arm64-apple-macosx26.0` (Apple Silicon)
- Host OS: macOS 26.5.2 (build 25F84)
- Package platform requirement: `.macOS(.v15)` (this repository targets macOS 15+; the
  build/verification host happened to run a later macOS release)

## What this build implements

One complete, deterministic, offline vertical slice:

```text
JSON replay fixture
  → language/domain evidence (EvidenceAccumulator, with enter/exit hysteresis)
  → route decision (AdaptiveRouter)
  → ranked recognition candidate (CandidateScorer, 8 named components)
  → protected/exact deterministic corrections (CorrectionEngine + BAPS seed pack)
  → output policy (OutputRenderer: preserveMixed / gujaratiScript / bapsRoman)
  → JSON + Markdown benchmark report with a regression gate (VaaniBench)
```

Four independently testable products, matching the design spec's repository
boundaries:

- **VaaniCore** — pure Swift library. No SwiftUI/AppKit/SwiftData/CoreData/
  AVFoundation/CoreML imports (verified by `rg`, see below). All public
  configuration and decoded JSON goes through throwing, validating
  initializers — invariants (probabilities in `0...1`, non-negative
  durations, ordered segments, non-empty required fields, schema version,
  duplicate/ambiguous terminology entries) cannot be bypassed by decoding
  crafted JSON directly.
- **VaaniAdapters** — `ReplayRecognizer`, a deterministic actor-based
  `Recognizer` backed by a fixed JSON manifest. No live audio or model
  adapters exist yet.
- **VaaniPacks** — versioned terminology pack loading plus a small,
  reviewable BAPS/Gujarati seed pack (`baps-gujarati-v1.json`, schema
  version 1, 6 entries: BAPS, Bhagwan Swaminarayan, Akshar-Purushottam,
  Pramukh Swami Maharaj, Mahant Swami Maharaj, Vachanamrut).
- **VaaniBench** — `vaani-bench run` CLI: runs a replay manifest through a
  `VaaniPipeline`, computes overall and per-subset metrics, and gates on a
  checked-in baseline.

## Exact commands run and results

```bash
swift package clean
swift build --build-tests
# Build complete, no errors.

swift test --parallel
# Test run with 115 tests in 10 suites passed after ~0.01s.

swift format lint --recursive --strict Sources Tests Package.swift
# Exit 0, no findings (see .swift-format: 4-space indent / 120-col length,
# matching this codebase's existing style rather than swift-format's
# 2-space default).

rg -n 'import (SwiftUI|AppKit|SwiftData|CoreData|AVFoundation|CoreML)' Sources/VaaniCore
# Exit 1 (no matches) — VaaniCore has none of the forbidden framework imports.

swift run -c release vaani-bench run \
  --manifest Fixtures/replay/smoke.json \
  --output /tmp/vaanicore-release-smoke \
  --baseline Fixtures/baseline/smoke-baseline.json
# vaani-bench: 5 utterances, exactMatchRate=1.0, regressions=0
# Exit 0.

rg -n '"(text|transcript|audio|rawCandidate)"\s*:' \
  /tmp/vaanicore-release-smoke/report.json Sources/VaaniCore/Types/Diagnostics.swift
# Exit 1 (no matches) — no transcript/audio content in the report or in the
# diagnostics type definition itself (DiagnosticEvent rejects these
# attribute keys at construction time).

git ls-files | rg '\.(wav|m4a|mp3)$|^Reports/|Corpus/Private/'
# Exit 1 (no matches) — no private audio or generated report files tracked.
```

## Phase 1 audit remediation — enforced contracts

The initial vertical slice above has been hardened against the P0 findings
of an audit pass (see
`docs/superpowers/plans/2026-07-24-vaanicore-audit-remediation.md`). The
following contracts are now enforced, not merely documented:

- **Manifest and report schema validation.** `ReplayManifest`,
  `ReplayUtterance`, `BenchReport`, and `BenchMetrics` all validate at both
  direct construction and JSON decoding — schema version, non-empty
  required fields, duplicate IDs, metric ranges, finiteness, and hash format
  cannot be bypassed by decoding crafted JSON.
- **Corpus-bound baseline checks.** `BenchRunner.run` computes a canonical
  manifest hash (utterances sorted by ID, so reordering equivalent entries
  never changes the hash) and rejects an incompatible baseline —
  mismatched schema version, manifest hash, utterance count, or subset
  membership — with a typed `BaselineCompatibilityError` before any metric
  is compared. A regression in one subset is gated independently
  (`subset.<name>.<metric>`) and can never be hidden by an unchanged or
  improved overall average.
- **Terminating output replacement.** `OutputRenderer`'s Roman-Gujarati
  rendering only ever scans the immutable source text; it collects
  non-overlapping replacement ranges and applies them once in descending
  order, so a replacement that contains its own search phrase cannot cause
  unbounded rescanning.
- **One full verification command.** `./scripts/verify.sh` is the single
  local/CI gate: dependency resolution, build, full test suite, strict
  lint, a forbidden-framework-import scan, the release smoke benchmark, and
  a transcript/audio/private-corpus leakage scan. CI runs exactly this
  script under least-privilege (`contents: read`) permissions with pinned
  action revisions.
- **Latency is synthetic, not measured.** Every candidate's
  `latencyMilliseconds` in the replay fixtures is a hand-authored constant
  used to exercise routing/scoring logic deterministically. It is not a
  measurement of real recognizer latency, first-partial time, or real-time
  factor. Those require the live audio/recognizer work in Phase 2 and the
  reference-hardware benchmarking in Phase 3; no latency or real-time-factor
  claim from this fixture may be quoted as a performance result.

## Fixture limitations — read before quoting any metric

`Fixtures/replay/smoke.json` contains **five synthetic, hand-authored
utterances** (confident English, confident Gujarati, English/Gujarati code-
switching, a BAPS terminology correction, and a plain-English collision-
protection case). Every candidate's text, confidence, detected-language
distribution, and latency was chosen by hand to exercise specific pipeline
behaviour deterministically.

**This is a pipeline-wiring smoke test, not an accuracy benchmark.** The
100% `exactMatchRate` and `routeAccuracy` in the checked-in baseline reflect
that the fixture was authored to match this implementation's exact
deterministic behaviour — they say nothing about real-world recognition
accuracy, and must never be quoted as such. The design spec's real
acceptance targets (§14) require a labelled, provenance-tracked evaluation
corpus with real or realistic audio, which does not exist yet.

## Implemented boundaries (per the design spec)

- Deterministic corrections only (exact/alias phrase matching on Unicode
  word boundaries); no fuzzy/phonetic matching.
- `preserveMixed` is the default output policy; `gujaratiScript` and
  `bapsRoman` only replace text when the pack provides a reviewed output
  form for the matched entry, otherwise they preserve input unchanged
  (safe degradation, not a transliteration engine). `englishTranslation` is
  not exposed.
- Diagnostics carry decision codes, timings, and small enum/count
  attributes only; `DiagnosticEvent` rejects `text`, `transcript`, `audio`,
  and `rawCandidate` attribute keys at construction time.
- A fresh `EvidenceAccumulator` is created per `VaaniPipeline.process` call,
  so separate requests never leak evidence history into one another.
- Swift 6 strict concurrency throughout; exported value types are
  `Sendable`; `ReplayRecognizer` is an `actor`.

## Deferred (explicitly out of scope for this plan)

- Real audio capture, voice activity detection, and utterance
  segmentation.
- Live recognisers: FluidAudio/Core ML streaming, whisper.cpp multilingual.
- Fuzzy/phonetic correction matching.
- The local-LLM constrained-correction fallback.
- Model downloading and lifecycle management.
- The private, labelled evaluation corpus and its manifest tooling.
- Wffl shadow-mode integration and the W1 dictation shell.
- Additional language/domain packs beyond the BAPS/Gujarati seed.

## Phase 2, first half — live orchestration contracts (complete)

Tasks 1–6 of
`docs/superpowers/plans/2026-07-24-vaanicore-phase2-live-contracts.md` are
implemented. VaaniCore now owns the live orchestration layer:

- `AudioFormat` / `AudioChunk` / `SpeechEvent` (`Types/Audio.swift`) —
  validating initializers; `AudioChunk` is deliberately **not** `Codable`, so
  audio cannot reach a report or a diagnostic event.
- `StreamingRecognizer`, `RecognitionUpdate`, and `Detector` — the live
  contracts. The Phase 1 `Recognizer` protocol moved into VaaniCore
  unchanged in shape under its accurate name, `ReplayCandidateSource`.
- `RoutingPlan` + `SessionBudgets` + `AdaptiveRouter.plan(for:policy:)` —
  turns a `RouteDecision` into an executable plan (ordered primary/secondary
  routes, secondary trigger, per-policy latency budget).
  `decide(evidence:)` behaviour is unchanged.
- `LivePipelineCoordinator` — an actor that processes one utterance:
  validates speech-event ordering, accumulates evidence via an injected
  `Detector`, plans a route, runs primary and conditionally secondary
  recognisers, then scores, corrects, and renders through the existing
  Phase 1 components.
- `ReplayStreamingRecognizer` / `ReplayDetector` (VaaniAdapters) — replay
  fixtures driven through the live path.

What this half does **not** establish:

- **No real audio and no real model.** Every recogniser exercised here is a
  mock or a replay shim. Recognition accuracy on real speech remains
  entirely unmeasured.
- **No measured latency.** All timing goes through an injected
  `DeadlineScheduler`; the tests use schedulers that never expire, expire
  immediately, or expire on a signal. No number produced by this half is a
  performance result.
- **No microphone capture and no VAD.** `SpeechEvent` streams are
  constructed by callers; nothing produces them from a device.

Enforced contracts:

- `verify.sh` now fails if `Sources/VaaniCore` imports anything but
  `Foundation`, and if whisper appears in VaaniCore, VaaniAdapters,
  VaaniPacks, or VaaniBench (Task 7 confines it to `VaaniWhisper`).
- The `StreamingRecognizer` contract suite is adapter-agnostic and runs
  against both the mock and the replay shim: at least one final update, no
  update after the final, non-empty model identity, stream termination, and
  termination under mid-stream cancellation.
- Coordinator invariants are tested with mocks and no wall-clock sleeps:
  event ordering, degraded fallback for a missing or failing recogniser,
  secondary triggered/skipped by confidence, budget exhaustion with and
  without a completed candidate, and external cancellation.
- Driving `Fixtures/replay/smoke.json` through the coordinator reproduces
  each utterance's expected text and route, matching the Phase 1 benchmark
  outcome via the live path.

Test count after this half: 218 (up from 155).

## Phase 2, Task 7 — whisper.cpp adapter

`VaaniWhisper` is the only target that imports the real recogniser binding.
It provides `WhisperRecognizer`, a whole-utterance `StreamingRecognizer`
that validates a non-empty local model file, buffers canonical 16 kHz mono
PCM, converts its `Int16` samples to `Float`, and produces one final update.
Its whisper context is serialized behind an actor; no transcript or audio
content is emitted as diagnostics. The candidate's latency field is set to
zero as an unavailable value, not a measured performance result.

The preferred `ggml-org/whisper.cpp` repository did not contain a root
`Package.swift` at the revision evaluated for this task, so the approved SPM
fallback is pinned exactly to:

- `https://github.com/exPHAT/SwiftWhisper`
- revision `c340197966ebd264f3135d3955874b40f8ed58bc`

SwiftWhisper supplies its bundled whisper.cpp sources, and its `LICENSE` and
the bundled `whisper.cpp/LICENSE` are MIT licenses. The adapter's
`ModelIdentity` intentionally reports provider `whisper.cpp` and the exact
revision above. SwiftWhisper's public API exposes segment timings but not
segment confidence or the auto-detected language ID; those unavailable
values are represented as `nil` confidence and an `.other` language
distribution for the `auto` hint rather than fabricated values.

`Tests/VaaniWhisperTests` always exercises missing and empty model-path
validation. Its streaming-contract, cancellation, and generated one-second
sine/silence PCM WAV decode tests use Swift Testing `.enabled(if:)` and skip
unless `VAANI_WHISPER_MODEL` points to an existing non-empty `.bin` model.
No model is downloaded by CI. Three of those tests are model-gated and skip
without that environment variable.

**First real-model run (2026-08-04).** All three gated tests pass against
`ggml-base.bin` (multilingual, 148 MB), and `vaani-live` transcribed a real
16 kHz mono utterance correctly end to end, with `--language auto`
auto-detecting `en` at p = 0.98. Two things this pinned down that mocks
could not: SwiftWhisper converts segment times from centiseconds to
milliseconds (`* 10`), so the adapter's `Int64(segment.startTime)` mapping
is in the right unit; and the real API populates no confidence at all, so
`RecognitionCandidate.confidence` is `nil` on every whisper candidate in
practice, not just in principle.

**Model constraint.** The vendored whisper.cpp hardcodes `WHISPER_N_MEL 80`
(`whisper.h:24`, asserted at `whisper.cpp:1430`, and rejected in
`whisper_set_mel`). The 128-mel models — `large-v3` and `large-v3-turbo` —
carry valid ggml magic, so they pass the header pre-flight and then fail
inside the loader. Use v2 or below.

**Language detection is discarded.** whisper.cpp auto-detects the spoken
language and writes it back into `params.language`, but the adapter reports
`.other` for the `auto` hint because SwiftWhisper's `Segment` exposes no
language. The detected value is reachable through `Whisper.params.language`
after a decode; wiring it into `LanguageDistribution` would replace a
placeholder with a real signal. Not done here.

## Phase 2, Task 8 — `vaani-live` file-driven harness

`Sources/VaaniLive` adds an executable target, `vaani-live`, with a
`transcribe` subcommand that reads a caller-supplied WAV file, wraps it as
one utterance's `SpeechEvent` stream, and drives it through
`LivePipelineCoordinator` with the bundled BAPS pack:

```bash
swift run vaani-live transcribe --model <path.bin> --audio <path.wav> \
  [--policy interactive|meeting] [--language auto|en|gu] \
  [--output-policy preserveMixed|gujaratiScript|bapsRoman]
```

- **WAV parsing.** `Sources/VaaniLive/WAVFile.swift` is a minimal
  hand-written RIFF/WAVE chunk-walking parser — no AVFoundation. It accepts
  only 16 kHz mono 16-bit PCM and rejects everything else (wrong sample
  rate, channel count, bit depth, non-PCM format tag, truncated/garbage
  headers, missing `fmt `/`data` chunks) with a message naming the exact
  `ffmpeg -ar 16000 -ac 1` conversion needed.
- **Utterance framing.** `SpeechEventBuilder` chunks the decoded samples into
  100 ms `AudioChunk`s and emits `speechStarted` → chunks → `speechEnded` →
  `endOfStream`, computing every timestamp from the same frame-offset
  formula on both sides of a chunk boundary so the coordinator's monotonic-
  ordering check is always satisfied despite millisecond rounding.
  `LanguageHintDetector` is a placeholder that turns `--language` directly
  into one evidence observation (real acoustic/script-based language ID
  remains deferred).
- **Recogniser.** `Sources/VaaniLive/RecognizerFactory.swift` builds a
  `VaaniWhisper.WhisperRecognizer` from `--model` and `--language` and
  returns it for every route. The harness is single-model; routing two real
  recognisers against each other is Phase 3. No model ships with the package
  and none is downloaded, so `vaani-live` cannot run without a caller-
  supplied ggml model file.
- **Exit codes** match `vaani-bench`: `0` success, `64` invalid input, `70`
  internal failure. `64` covers input the program can *identify* as invalid:
  a bad or unreadable WAV, a missing or empty model file, and a model file
  whose 4-byte header is not the ggml magic the vendored loader requires
  (`WhisperRecognizer` checks it before constructing a context, including a
  named case for GGUF files, which this pre-GGUF build cannot load).

  **A model with valid ggml magic but corrupt or truncated contents aborts
  the process instead of exiting `64`.** The vendored loader signals a failed
  load by returning `false`, and SwiftWhisper force-unwraps that into a trap,
  so there is no error for the adapter to catch and turn into an exit code.
  The header pre-flight narrows this to files that are plausibly models; it
  does not close it. Running the decode in a separate process and treating a
  non-zero child status as invalid input is the known complete fix. It is not
  taken here.

- **Timing.** The printed decode time is always labelled `measured on this
  machine, single run, not a benchmark`. It is one unrepeated wall-clock
  reading on whatever machine ran it — not a benchmark, and not comparable
  across machines or runs.
- Tests: `Tests/VaaniLiveTests/WAVFileTests.swift` builds WAV byte streams by
  hand to cover a valid round trip, chunk-walking around unknown/odd-padded
  chunks, every rejected format dimension, and truncated/garbage headers.
  `Tests/VaaniLiveTests/TranscribeCommandTests.swift` covers `--help`
  parsing and argument validation (required options, unknown enum values).

Test count after Tasks 7 and 8 together: 250 (up from 218).

## Next milestone

Phase 1 (this hardening pass) is complete; Phase 2 (live orchestration
contracts — core-owned audio/utterance types, async `Detector`/`Recognizer`
protocols, `RoutingPlan`, `LivePipelineCoordinator`, cancellation/timeout/
degraded-fallback semantics) and Phase 3 (terminology scale, corpus/
benchmark maturity, release operations) are separate follow-on plans gated
on this plan's completion — see
`docs/superpowers/plans/2026-07-24-vaanicore-audit-remediation.md`. Per the
canonical design-spec delivery sequence: add audio/VAD and real recogniser
adapter contract tests next, beginning by capturing actual Wffl/W1 baseline
hardware and corpus metadata — then proceed to Wffl shadow mode.
