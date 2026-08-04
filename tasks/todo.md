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

- [ ] Task 1: Core audio and utterance value types (`Audio.swift`, AudioTypesTests)
- [ ] Task 2: Core-owned async `StreamingRecognizer`/`Detector` protocols + reusable contract tests
- [ ] Task 3: `RoutingPlan` and `AdaptiveRouter.plan(for:policy:)`
- [ ] Task 4: `LivePipelineCoordinator` actor (deadline, cancellation, degraded fallback; mock-tested, no wall-clock sleeps)
- [ ] Task 5: `ReplayStreamingRecognizer` shim; contract suite + coordinator end-to-end against `Fixtures/replay/smoke.json`
- [ ] Task 6: Extend `scripts/verify.sh` import scan; docs update for contracts half; full gate green
- [ ] Checkpoint A: Owner review before third-party dependency lands
- [ ] Task 7: `VaaniWhisper` target — whisper.cpp SPM dependency (pinned revision) + `WhisperRecognizer` adapter; model-gated tests skip without `VAANI_WHISPER_MODEL`
- [ ] Task 8: `vaani-live` file-driven CLI harness (WAV in → transcript + decision codes + labelled single-run timing)
- [ ] Final verification: `./scripts/verify.sh`, full suite (+30 tests minimum), docs/README updated, licence + revision recorded
