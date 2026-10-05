# TessavakCore Phase 1 Execution Prompt

You are implementing Phase 1 of the TessavakCore audit remediation in:

`/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore`

Use this implementation plan as the sole task specification:

`/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/docs/superpowers/plans/2026-07-24-tessavak-audit-remediation.md`

Read these context files before changing code:

1. `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/README.md`
2. `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/docs/initial-build.md`
3. `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/docs/superpowers/specs/2026-07-24-tessavak-design.md`
4. `/tmp/deep-audit-tessavak/report.md` if it still exists. The saved implementation plan remains authoritative if the temporary report is unavailable.

## Objective

Complete **Phase 1 only**: make the existing deterministic replay slice safe, semantically validated, reproducible, and trustworthy.

Do not start the Phase 2 live-audio or recognizer architecture. Do not add AVFoundation, Core ML, model dependencies, streaming recognizers, fuzzy correction, local LLMs, or consumer application code.

## Required execution method

1. Inspect `git status --short` before editing.
2. Preserve all pre-existing user changes and untracked files. At planning time, `Package.resolved`, `docs/superpowers/plans/`, and `tasks/` were untracked.
3. Execute Tasks 1 through 8 in the exact order written in the plan.
4. Use TDD for every behavior change:
   - add the focused failing test;
   - run it and record the expected failure;
   - implement the minimum production change;
   - rerun the focused test;
   - run the full suite;
   - commit the task.
5. Use `apply_patch` for manual file edits.
6. Do not rewrite unrelated code or reformat untouched files.
7. Do not weaken a test, delete a test, silently regenerate a baseline, or change a fixture merely to make CI green.
8. If a plan instruction conflicts with the actual type system or current code, stop that task, explain the concrete conflict with file and line evidence, and propose the smallest compatible correction. Do not improvise a broad redesign.

## Files in scope

Production:

- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakCore/Correction/Terminology.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakCore/Output/OutputPolicy.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakCore/Scoring/CandidateScorer.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakCore/Types/Evidence.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakCore/Routing/AdaptiveRouter.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakAdapters/Replay/ReplayRecognizer.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakBench/BenchManifest.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakBench/BenchReport.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakBench/BenchRunner.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Sources/TessavakBench/main.swift`

Tests:

- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Tests/TessavakCoreTests/OutputPolicyTests.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Tests/TessavakCoreTests/CorrectionEngineTests.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Tests/TessavakCoreTests/CandidateScorerTests.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Tests/TessavakCoreTests/CoreTypesTests.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Tests/TessavakCoreTests/AdaptiveRouterTests.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Tests/TessavakPacksTests/PackLoaderTests.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Tests/TessavakAdaptersTests/ReplayRecognizerTests.swift`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Tests/TessavakBenchTests/BenchRunnerTests.swift`

Build, CI, and documentation:

- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/scripts/verify.sh`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/.github/workflows/ci.yml`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/.gitignore`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/Package.resolved`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/README.md`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/docs/initial-build.md`
- `/Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore/docs/superpowers/specs/2026-07-24-tessavak-design.md`

Do not modify files outside this list unless the plan explicitly requires a golden fixture update. If a fixture must change, explain exactly which serialized contract changed and obtain a clean before/after diff.

## Non-negotiable outcomes

- Roman output replacement cannot loop or repeatedly search mutated output.
- Empty or unsupported output forms are rejected.
- Canonical and alias phrases have one unambiguous owner.
- Replay manifests reject unsupported schemas, empty collections, empty IDs/subsets, and duplicate utterance IDs.
- JSON decoding cannot bypass direct-construction validation.
- Manifest input is capped at 64 MiB.
- Benchmark reports reject invalid schemas, hashes, counts, ranges, and non-finite values.
- Baselines must match canonical manifest hash, schema, overall count, and subset membership.
- Subset regressions are independently gated.
- Invalid benchmark inputs exit 64; internal failures exit 70.
- Scoring weights and computed totals are finite and non-negative.
- Active domains must exist in the domain probability map.
- Gujarati mixed evidence obeys the same second-decode threshold as English.
- `./scripts/verify.sh` performs the complete local and CI gate.
- `Package.resolved` is tracked without upgrading dependencies.
- GitHub Actions use `contents: read` and immutable action revisions.
- Private audio/corpus material and generated reports remain untracked.
- Documentation states that the five synthetic fixtures are a wiring smoke test, not evidence of real recognition accuracy.

## Verification

At the end, run:

```bash
cd /Users/purvarajsinhgohil/Documents/PROJECTS/TessavakCore
./scripts/verify.sh
swift test --parallel
swift format lint --recursive --strict Sources Tests Package.swift
git status --short
git diff --check
```

The final test count must be greater than 115 and every command must exit 0.

Also run:

```bash
swift run -c release tessavak-bench run \
  --manifest Fixtures/replay/smoke.json \
  --output /tmp/tessavak-remediation-smoke \
  --baseline Fixtures/baseline/smoke-baseline.json
```

Expected: exit 0 and zero regressions.

## Final response format

Return:

1. A concise outcome summary.
2. A checklist of Tasks 1–8 marked complete or blocked.
3. Exact test and verification results, including final test count.
4. The commit hashes and messages created.
5. Every file changed.
6. Any fixture or baseline change with its justification.
7. Remaining Phase 2 and Phase 3 work.
8. Explicit confirmation that no real-world accuracy claim is supported yet.

Stop after Phase 1. Do not begin Phase 2.
