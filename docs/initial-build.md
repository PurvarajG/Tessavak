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
