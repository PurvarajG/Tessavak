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

Real audio capture, voice activity detection, live recogniser adapters
(FluidAudio, whisper.cpp), local-LLM correction, model downloading, Wffl
shadow mode, and the W1 application are **not** implemented yet. See
`docs/initial-build.md` for the full boundary and deferred work.

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
