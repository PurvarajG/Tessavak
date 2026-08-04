# VaaniCore Phase 2 Execution Prompt

You are implementing Phase 2 of VaaniCore in:

`/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore`

Use this implementation plan as the sole task specification:

`/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/docs/superpowers/plans/2026-07-24-vaanicore-phase2-live-contracts.md`

Track progress by checking off items in:

`/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/tasks/todo.md` (Phase 2 section)

Read these context files before changing code:

1. `/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/README.md`
2. `/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/docs/initial-build.md`
3. `/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/docs/superpowers/specs/2026-07-24-vaanicore-design.md` (especially §5 runtime data flow, §7 routing, §15 failure handling)
4. `/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/Sources/VaaniCore/Pipeline/VaaniPipeline.swift`
5. `/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/Sources/VaaniCore/Routing/AdaptiveRouter.swift`
6. `/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/Sources/VaaniAdapters/Replay/ReplayRecognizer.swift`
7. `/Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore/scripts/verify.sh`

## Objective

Execute plan Tasks 1–8 in order. Tasks 1–6 build the live orchestration
contracts (audio types, async StreamingRecognizer/Detector protocols,
RoutingPlan, LivePipelineCoordinator) fully offline-testable with mocks.
**Stop at Checkpoint A after Task 6 and report** — the owner reviews before
the third-party whisper.cpp dependency lands in Tasks 7–8.

## Required execution method

1. Inspect `git status --short` before editing; preserve pre-existing
   untracked files.
2. TDD for every behavior change: focused failing test → run → smallest
   implementation → focused rerun → full suite → commit per task.
3. Swift 6 strict concurrency; all new public types are `Sendable`; all
   new public configuration/decoded types use throwing validating
   initializers and validating `init(from:)` decoders, matching the
   existing Phase 1 pattern (see `Sources/VaaniCore/Types/Recognition.swift`).
4. No wall-clock sleeps in tests — the coordinator uses the plan's injected
   deadline abstraction with a manual test implementation.
5. Never put transcript or audio content in diagnostics or reports.
   `DiagnosticEvent` enforces this; keep every new event compliant.
6. Do not modify Phase 1 fixtures, baselines, or behavior except where the
   plan explicitly says so. Never weaken/delete a test or regenerate a
   baseline to go green.
7. Keep `Sources/VaaniCore` free of SwiftUI, AppKit, SwiftData, CoreData,
   AVFoundation, CoreML, and all third-party imports. whisper.cpp is
   allowed only inside the new `Sources/VaaniWhisper` target and its tests.
   AVFoundation is forbidden everywhere in this phase.
8. If a plan instruction conflicts with the actual code or type system,
   stop that task, explain the conflict with file/line evidence, and
   propose the smallest compatible correction. Do not improvise a
   redesign.
9. Run `swift format lint --recursive --strict Sources Tests Package.swift`
   before each commit.

## Verification

After Task 6 (Checkpoint A) and again after Task 8:

```bash
cd /Users/purvarajsinhgohil/Documents/PROJECTS/VaaniCore
./scripts/verify.sh
swift test --parallel
swift format lint --recursive --strict Sources Tests Package.swift
git status --short && git diff --check
```

Every command exits 0. The final Phase 2 test count must exceed the
pre-Phase-2 count by at least 30. Whisper-model-dependent tests must be
recorded as skipped (not failed) when `VAANI_WHISPER_MODEL` is unset.

## Final response format

1. Concise outcome summary.
2. Task checklist (complete/blocked), mirrored into `tasks/todo.md`.
3. Exact verification results and final test count.
4. Commit hashes and messages.
5. Every file created or changed.
6. The pinned whisper.cpp revision and licence (if Tasks 7–8 ran).
7. Explicit statement that no accuracy or latency claim from mocks or the
   replay fixture is a real-world result, and that `vaani-live` timings are
   single-run, this-machine-only measurements.
