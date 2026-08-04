# VaaniCore Task List

## Initial build (complete)

- [x] Task 1: Package scaffold and CI contract
- [x] Task 2: Core value types and decoding invariants
- [x] Task 3: Evidence accumulation with domain hysteresis
- [x] Checkpoint A: Foundation review
- [x] Task 4: Adaptive routing and explainable candidate scoring
- [x] Task 5: Versioned pack loading and deterministic correction
- [x] Task 6: Output policies and end-to-end pipeline
- [x] Checkpoint B: Core decision-path review
- [x] Task 7: Replay adapter and deterministic fixture
- [x] Task 8: VaaniBench CLI, reports, and regression gate
- [x] Task 9: Whole-slice verification and developer handoff
- [x] Checkpoint C: Runnable initial-build review

## Phase 1 audit remediation (complete)

- [x] Tasks 1–8 per `docs/superpowers/plans/2026-07-24-vaanicore-audit-remediation.md`

## Phase 2 — live orchestration contracts and first real recognizer

Plan: `docs/superpowers/plans/2026-07-24-vaanicore-phase2-live-contracts.md`

- [x] Task 1: Core audio and utterance value types (`Audio.swift`, AudioTypesTests)
- [x] Task 2: Core-owned async `StreamingRecognizer`/`Detector` protocols + reusable contract tests
- [x] Task 3: `RoutingPlan` and `AdaptiveRouter.plan(for:policy:)`
- [x] Task 4: `LivePipelineCoordinator` actor (deadline, cancellation, degraded fallback; mock-tested, no wall-clock sleeps)
- [x] Task 5: `ReplayStreamingRecognizer` shim; contract suite + coordinator end-to-end against `Fixtures/replay/smoke.json`
- [x] Task 6: Extend `scripts/verify.sh` import scan; docs update for contracts half; full gate green
- [x] Checkpoint A: Owner review before third-party dependency lands
- [x] Task 7: `VaaniWhisper` target — whisper.cpp SPM dependency (pinned revision) + `WhisperRecognizer` adapter; model-gated tests skip without `VAANI_WHISPER_MODEL`
- [x] Task 8: `vaani-live` file-driven CLI harness (WAV in → transcript + decision codes + labelled single-run timing)
- [x] Final verification: `./scripts/verify.sh`, full suite (253 tests, +35), docs/README updated, licence + revision recorded

Landed beyond the plan, from running the code rather than testing it:

- [x] `RecognitionCandidate.confidence` is `Double?` — absent confidence is no
      longer scored as zero, and no longer trips the low-confidence secondary
- [x] `WhisperRecognizer` rejects non-ggml model files by header magic before
      the vendored loader traps on them; `vaani-live` exits 64, not 70

## Gating the Phase 2 merge to `main`

- [ ] Run the three model-gated tests at least once against a real
      `ggml-*.bin` — they have never executed, so no test has yet exercised
      the recogniser adapter against a real decode
- [ ] One real `vaani-live` decode: segment timings, language mapping, and
      whether the real API populates `confidence` or leaves it `nil`
- [ ] Only then merge Phase 2 to `main`

Model constraint: the vendored whisper.cpp hardcodes `WHISPER_N_MEL 80`
(`whisper.h:24`, asserted at `whisper.cpp:1430`). **`large-v3` and
`large-v3-turbo` are 128-mel and will not work** — their magic is valid, so
the header pre-flight passes and the failure lands in the documented hole.
Use v2 or below.

## Deferred to Phase 3

Mic capture/AVFoundation, VAD, FluidAudio/Parakeet as a second *real*
recogniser (which is what makes dual routing meaningful rather than the
current single-model stand-in), streaming partials, fuzzy correction, the
labelled corpus, latency benchmarking on reference hardware, and process
isolation for the corrupt-model abort documented in `docs/initial-build.md`.
