# VaaniCore

VaaniCore is a local-first Swift language-intelligence engine for multilingual
transcription, terminology correction, and adaptive routing between
recognisers. See `docs/superpowers/specs/2026-07-24-vaanicore-design.md` for
the approved product and architecture specification.

## Initial-build boundary

This repository currently implements one complete, deterministic, offline
vertical slice:

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

This slice has been hardened per a Phase 1 audit remediation pass —
manifest/report schema validation, corpus-bound benchmark baselines,
terminating output rendering, and a single reproducible verification gate.

## Live orchestration contracts

Phase 2's first half adds the live layer VaaniCore owns: audio and utterance
value types, async `StreamingRecognizer` and `Detector` protocols, a
`RoutingPlan` derived from the existing route decision, and a
`LivePipelineCoordinator` actor with cancellation, latency-budget, and
degraded-fallback semantics.

This layer is **contract-level except for the optional VaaniWhisper adapter**.
`WhisperRecognizer` buffers a caller-provided utterance and performs one
whole-utterance whisper.cpp decode from a local model file; no model is
bundled or downloaded by the package. All other recognisers exercised by the
standard suite are mocks or replay shims, all coordinator timing goes through
an injected `DeadlineScheduler`, and nothing captures audio from a device —
so recognition accuracy and latency on real speech remain unmeasured.

Real audio capture, voice activity detection, FluidAudio, true streaming
whisper partials, local-LLM correction, model downloading, Wffl shadow mode,
and the W1 application are **not** implemented yet. See
`docs/initial-build.md` for the full boundary, enforced contracts, and
deferred work.

## `vaani-live` — file-driven harness

`vaani-live transcribe` runs one 16 kHz mono 16-bit PCM WAV file through the
live pipeline end to end:

```bash
swift run vaani-live transcribe --model <path.bin> --audio <path.wav> \
  [--policy interactive|meeting] [--language auto|en|gu] \
  [--output-policy preserveMixed|gujaratiScript|bapsRoman]
```

`--model` takes a whisper.cpp ggml model file; `VaaniWhisper` serves every
route (single-model — routing two real recognisers against each other is
Phase 3). **No model ships with this package and none is downloaded**, so
the harness cannot run until you supply one. A WAV outside 16 kHz
mono 16-bit PCM is rejected with the exact `ffmpeg -ar 16000 -ac 1` command
needed to convert it. Exit codes match `vaani-bench`: `0` success, `64`
invalid input, `70` internal failure. A model file that is not a ggml
whisper model is rejected by header check before any decode; a model with
valid magic but corrupt contents still aborts the process, because the
vendored loader traps rather than returning an error — see
`docs/initial-build.md`.

## Prerequisites

- macOS 15 or later (Apple Silicon)
- Swift 6 toolchain

## Commands

The full local and CI verification gate is one command:

```bash
./scripts/verify.sh
```

It resolves dependencies, builds, runs the full test suite, lints, checks
`VaaniCore` for forbidden framework imports, runs the release smoke
benchmark, and scans for transcript/audio/private-corpus leakage. It exits
non-zero on any failure.

Focused developer commands, run individually while iterating:

```bash
swift build
swift test --parallel
swift run vaani-bench run --manifest Fixtures/replay/smoke.json --output Reports/smoke
swift run vaani-bench run \
  --manifest Fixtures/replay/smoke.json \
  --output Reports/smoke \
  --baseline Fixtures/baseline/smoke-baseline.json
swift format lint --recursive --strict Sources Tests Package.swift
```

`vaani-bench run` exits `0` on success, `2` if `--baseline` detects a
regression, `64` for invalid input (including an incompatible baseline), and
`70` for an internal failure. See [`docs/initial-build.md`](docs/initial-build.md)
for the full developer handoff, including exact verification commands and
their results.
