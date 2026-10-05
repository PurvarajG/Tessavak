# TessavakCore Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the current replay-based TessavakCore slice safe, semantically validated, reproducible, and trustworthy before adding live audio or recognizer adapters.

**Architecture:** Phase 1 hardens the existing vertical slice without redesigning its public runtime architecture. Validation is moved to the data boundaries, terminology replacements are made terminating and deterministic, benchmark baselines become corpus-bound, configuration invariants are enforced, and CI becomes a single reproducible gate. Phase 2 and Phase 3 are explicitly gated follow-on projects; do not mix them into Phase 1.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation, CryptoKit, GitHub Actions, macOS 15+.

## Global Constraints

- Preserve the current deterministic offline vertical slice and all existing public behavior unless a task explicitly corrects invalid behavior.
- Do not add new third-party runtime dependencies.
- Keep `TessavakCore` free of SwiftUI, AppKit, SwiftData, CoreData, AVFoundation, and CoreML.
- All decoded JSON must pass through throwing validation; synthesized decoding must not bypass invariants.
- Error messages must identify the invalid field and value where safe.
- Transcript and audio content must never enter benchmark reports or diagnostics.
- Use test-driven development: add a focused failing test, run it, implement the smallest fix, then rerun the focused and full suites.
- Preserve existing user changes. At plan creation, `Package.resolved`, `docs/superpowers/plans/`, and `tasks/` were untracked.
- Do not begin Phase 2 live-orchestration work until every Phase 1 acceptance check passes.

---

## File map

### Phase 1 files to modify

- `Sources/TessavakCore/Correction/Terminology.swift` — validate output forms and global phrase ownership.
- `Sources/TessavakCore/Output/OutputPolicy.swift` — guarantee finite, deterministic Roman replacement.
- `Sources/TessavakCore/Scoring/CandidateScorer.swift` — reject invalid scoring weights and totals.
- `Sources/TessavakCore/Types/Evidence.swift` — enforce cross-field snapshot consistency.
- `Sources/TessavakCore/Routing/AdaptiveRouter.swift` — apply mixed-evidence routing symmetrically.
- `Sources/TessavakAdapters/Replay/ReplayRecognizer.swift` — make replay DTO construction and decoding validated.
- `Sources/TessavakBench/BenchManifest.swift` — apply file-size limits and preserve invalid-input classification.
- `Sources/TessavakBench/BenchReport.swift` — validate persisted report schemas and metric ranges.
- `Sources/TessavakBench/BenchRunner.swift` — bind baselines to the current corpus and compare subsets.
- `Sources/TessavakBench/main.swift` — expose useful regression and input-failure diagnostics.
- `.github/workflows/ci.yml` — run the unified verification gate with least privilege.
- `scripts/verify.sh` — one local/CI verification entry point.
- `.gitignore` — strengthen private-corpus defenses.
- `README.md`, `docs/initial-build.md`, `docs/superpowers/specs/2026-07-24-tessavak-design.md` — document the enforced contracts and current status.

### Phase 1 test files

- `Tests/TessavakCoreTests/OutputPolicyTests.swift`
- `Tests/TessavakCoreTests/CorrectionEngineTests.swift`
- `Tests/TessavakCoreTests/CandidateScorerTests.swift`
- `Tests/TessavakCoreTests/CoreTypesTests.swift`
- `Tests/TessavakCoreTests/AdaptiveRouterTests.swift`
- `Tests/TessavakAdaptersTests/ReplayRecognizerTests.swift`
- `Tests/TessavakBenchTests/BenchRunnerTests.swift`

### Phase 2 files to create later

- `Sources/TessavakCore/Recognition/Recognizer.swift`
- `Sources/TessavakCore/Detection/Detector.swift`
- `Sources/TessavakCore/Routing/RoutingPlan.swift`
- `Sources/TessavakCore/Pipeline/LivePipelineCoordinator.swift`
- `Tests/TessavakCoreTests/LivePipelineCoordinatorTests.swift`
- `Tests/TessavakAdaptersTests/RecognizerContractTests.swift`

Phase 2 is a separate implementation plan. Do not create these files during Phase 1.

---

## Phase 1 — Current-slice hardening

### Task 1: Guarantee terminology replacement termination

**Files:**

- Modify: `Sources/TessavakCore/Correction/Terminology.swift:12-40`
- Modify: `Sources/TessavakCore/Output/OutputPolicy.swift:88-110`
- Test: `Tests/TessavakCoreTests/OutputPolicyTests.swift`
- Test: `Tests/TessavakCoreTests/CorrectionEngineTests.swift`

**Interfaces:**

- Consumes: existing `TerminologyEntry.outputForms: [String: String]`.
- Produces: validated non-empty output-form values and a `renderBapsRoman(_:)` implementation that only matches the immutable input.

- [ ] **Step 1: Add output-form validation tests**

Add tests that construct terminology entries with:

```swift
outputForms: ["gujaratiScript": "", "bapsRoman": "roman"]
```

and:

```swift
outputForms: ["gujaratiScript": "અક્ષર", "bapsRoman": ""]
```

Each construction must throw `TessavakCoreError.invalidConfiguration`.

- [ ] **Step 2: Add finite-replacement tests**

Add a test pack whose mapping is:

```swift
outputForms: [
    "gujaratiScript": "અક્ષર",
    "bapsRoman": "અક્ષર-roman",
]
```

Assert:

```swift
let rendered = try OutputRenderer(pack: pack).render("અક્ષર અક્ષર", policy: .bapsRoman)
#expect(rendered == "અક્ષર-roman અક્ષર-roman")
```

This test must complete without a timeout. Also test an identical source/replacement mapping and assert one stable replacement pass rather than repeated mutation.

- [ ] **Step 3: Run the focused tests and confirm the new validation test fails**

Run:

```bash
swift test --filter OutputPolicyTests
swift test --filter CorrectionEngineTests
```

Expected before implementation: at least the empty-output-form test fails because construction succeeds.

- [ ] **Step 4: Validate output-form keys and values**

In `TerminologyEntry.init`, allow only the currently supported keys:

```swift
let supportedOutputForms: Set<String> = ["gujaratiScript", "bapsRoman"]
```

For every pair:

```swift
guard supportedOutputForms.contains(key) else {
    throw TessavakCoreError.invalidConfiguration(
        "terminology entry \(canonical) has unsupported output form '\(key)'"
    )
}
guard !value.isEmpty else {
    throw TessavakCoreError.invalidConfiguration(
        "terminology entry \(canonical) has empty output form '\(key)'"
    )
}
```

Do not reject a replacement merely because it contains the source; the rendering algorithm must remain terminating even for that input.

- [ ] **Step 5: Replace mutation-driven Roman matching**

Change `renderBapsRoman(_:)` to:

1. Build and longest-first sort the reviewed rules.
2. Find all literal ranges in the original `text` without mutating it.
3. Store integer `NSRange` offsets and replacements.
4. Accept non-overlapping ranges, preferring longer phrases and then earlier offsets.
5. Apply accepted ranges in descending location order.

The implementation must never search inside text it has already replaced. It must not use `while let range = result.range(...)`.

- [ ] **Step 6: Run focused and full tests**

Run:

```bash
swift test --filter OutputPolicyTests
swift test --filter CorrectionEngineTests
swift test --parallel
```

Expected: all tests pass; total test count is greater than 115.

- [ ] **Step 7: Commit**

```bash
git add Sources/TessavakCore/Correction/Terminology.swift Sources/TessavakCore/Output/OutputPolicy.swift Tests/TessavakCoreTests/OutputPolicyTests.swift Tests/TessavakCoreTests/CorrectionEngineTests.swift
git commit -m "fix: guarantee terminology rendering termination"
```

---

### Task 2: Enforce global terminology phrase ownership

**Files:**

- Modify: `Sources/TessavakCore/Correction/Terminology.swift:96-129`
- Test: `Tests/TessavakPacksTests/PackLoaderTests.swift`
- Test: `Tests/TessavakCoreTests/CorrectionEngineTests.swift`

**Interfaces:**

- Consumes: `TerminologyPack.entries`.
- Produces: one case-folded phrase-ownership invariant covering canonicals and aliases.

- [ ] **Step 1: Add collision tests**

Create two entries:

```swift
let first = try TerminologyEntry(
    canonical: "Alpha",
    aliases: ["Beta"],
    language: .english,
    script: "Latin",
    protected: true,
    outputForms: [:],
    collisionRisk: 0
)
let second = try TerminologyEntry(
    canonical: "Beta",
    aliases: [],
    language: .english,
    script: "Latin",
    protected: true,
    outputForms: [:],
    collisionRisk: 0
)
```

Assert that constructing a pack containing both throws. Repeat with casing variants such as `"BETA"`.

- [ ] **Step 2: Run the focused test**

Run:

```bash
swift test --filter PackLoaderTests
```

Expected before implementation: the alias-versus-canonical collision test fails because the pack is accepted.

- [ ] **Step 3: Replace separate canonical and alias owner maps**

In `TerminologyPack.init`, build one dictionary:

```swift
var phraseOwners: [String: String] = [:]
```

For every canonical and alias, case-fold the phrase and register its entry canonical. Reject the phrase when an existing different owner is present. Permit same-entry casing variants only when they resolve to the same owner.

Use an error of the form:

```swift
"terminology phrase '\(phrase)' is ambiguous between '\(existingOwner)' and '\(entry.canonical)'"
```

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test --filter PackLoaderTests
swift test --filter CorrectionEngineTests
swift test --parallel
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TessavakCore/Correction/Terminology.swift Tests/TessavakPacksTests/PackLoaderTests.swift Tests/TessavakCoreTests/CorrectionEngineTests.swift
git commit -m "fix: reject terminology phrase ownership collisions"
```

---

### Task 3: Validate replay manifests at construction and decode boundaries

**Files:**

- Modify: `Sources/TessavakAdapters/Replay/ReplayRecognizer.swift`
- Modify: `Sources/TessavakBench/BenchManifest.swift`
- Test: `Tests/TessavakAdaptersTests/ReplayRecognizerTests.swift`
- Test: `Tests/TessavakBenchTests/BenchRunnerTests.swift`

**Interfaces:**

- Produces:

```swift
public static let ReplayManifest.supportedSchemaVersion = 1
public init(schemaVersion: Int, utterances: [ReplayUtterance]) throws
public init(
    id: String,
    observations: [EvidenceObservation],
    candidates: [RecognitionCandidate],
    expectedText: String,
    expectedRoute: Route,
    subset: String
) throws
```

- `ReplayManifest.init(from:)` and `ReplayUtterance.init(from:)` must call the throwing validated initializers.

- [ ] **Step 1: Update test helpers for throwing construction**

Change existing test construction from:

```swift
ReplayManifest(schemaVersion: 1, utterances: utterances)
```

to:

```swift
try ReplayManifest(schemaVersion: 1, utterances: utterances)
```

and make helper functions propagate `throws`.

- [ ] **Step 2: Add manifest rejection tests**

Add construction and JSON-decoding tests for:

- `schemaVersion` other than `1`;
- empty `utterances`;
- duplicate utterance IDs;
- empty utterance ID;
- empty subset;
- empty observations;
- empty candidates.

Each must throw. Verify JSON decoding cannot bypass the same checks.

- [ ] **Step 3: Run the focused tests**

Run:

```bash
swift test --filter ReplayRecognizerTests
```

Expected before implementation: compile failures after adding `try`, followed by behavioral failures until validation exists.

- [ ] **Step 4: Add throwing initializers and custom decoding**

Validation rules:

```text
ReplayManifest.schemaVersion == 1
ReplayManifest.utterances is not empty
ReplayUtterance.id is not empty
ReplayUtterance.subset is not empty
ReplayUtterance.observations is not empty
ReplayUtterance.candidates is not empty
ReplayManifest utterance IDs are unique
```

Keep `expectedText` allowed to be empty because silence/empty-recognition evaluation may be legitimate later.

- [ ] **Step 5: Remove duplicate validation from `ReplayRecognizer`**

After `ReplayManifest` guarantees unique IDs, `ReplayRecognizer.init` should only create its lookup dictionary. Do not maintain two divergent validation implementations.

- [ ] **Step 6: Add a manifest file-size budget**

In `BenchManifestLoader`, inspect file attributes before `Data(contentsOf:)`. Reject files larger than:

```swift
static let maximumManifestBytes = 64 * 1024 * 1024
```

Use a typed `BenchInputError` or the existing CLI-invalid-input error path so this becomes exit `64`, not `70`.

- [ ] **Step 7: Run focused and full tests**

Run:

```bash
swift test --filter ReplayRecognizerTests
swift test --filter BenchRunnerTests
swift test --parallel
```

Expected: all tests pass and malformed manifests fail at load/construction time.

- [ ] **Step 8: Commit**

```bash
git add Sources/TessavakAdapters/Replay/ReplayRecognizer.swift Sources/TessavakBench/BenchManifest.swift Tests/TessavakAdaptersTests/ReplayRecognizerTests.swift Tests/TessavakBenchTests/BenchRunnerTests.swift
git commit -m "fix: validate replay manifests at input boundaries"
```

---

### Task 4: Validate benchmark reports and bind baselines to corpora

**Files:**

- Modify: `Sources/TessavakBench/BenchReport.swift`
- Modify: `Sources/TessavakBench/BenchRunner.swift`
- Modify: `Sources/TessavakBench/main.swift`
- Test: `Tests/TessavakBenchTests/BenchRunnerTests.swift`
- Update generated fixture only if serialization intentionally changes: `Fixtures/expected/smoke-report.json`
- Update baseline only through the explicit compatibility workflow: `Fixtures/baseline/smoke-baseline.json`

**Interfaces:**

- Produces:

```swift
enum BaselineCompatibilityError: Error, Equatable {
    case schemaMismatch(expected: Int, actual: Int)
    case manifestMismatch(expected: String, actual: String)
    case utteranceCountMismatch(expected: Int, actual: Int)
    case subsetMismatch(expected: Set<String>, actual: Set<String>)
}
```

- `BenchReport.load(fromPath:)` must validate its schema and metric invariants.

- [ ] **Step 1: Add report validation tests**

Test rejection of:

- unsupported `schemaVersion`;
- malformed/non-64-character hexadecimal `manifestSHA256`;
- negative `utteranceCount`;
- rates outside `0...1`;
- non-finite metric values;
- negative latency.

- [ ] **Step 2: Add baseline compatibility tests**

Create actual and baseline reports with:

- different manifest hashes;
- different schema versions;
- different utterance counts;
- different subset key sets.

Assert that `BenchRunner.run` throws the corresponding compatibility error before metric comparison.

- [ ] **Step 3: Add subset regression tests**

Create equal overall metrics but worse metrics for one subset. Assert a regression is recorded with a qualified name such as:

```text
subset.baps-terminology.protectedTermExactMatchRate
```

- [ ] **Step 4: Run the focused tests**

Run:

```bash
swift test --filter BenchRunnerTests
```

Expected before implementation: the compatibility and subset-gate tests fail.

- [ ] **Step 5: Implement validated `BenchMetrics` and `BenchReport` decoding**

Use throwing initializers and custom `init(from:)`. Rates must be finite and within `0...1`; count and latency must be non-negative; hashes must contain exactly 64 lowercase or uppercase hexadecimal characters.

- [ ] **Step 6: Canonicalize manifest hashing**

In `manifestSHA256`, encode a copy whose utterances are sorted by ID—the same order used by execution. Reordering equivalent manifest entries must not change the hash.

- [ ] **Step 7: Enforce baseline compatibility before comparison**

When a baseline is supplied:

1. compare schema versions;
2. compare canonical manifest hashes;
3. compare overall utterance counts;
4. compare subset key sets;
5. compare each subset's utterance count;
6. compute overall and subset regressions.

Do not silently rebase a baseline.

- [ ] **Step 8: Print actionable failures**

In `main.swift`, print each regression with metric, baseline, actual, and allowed delta. Compatibility failures must be printed as invalid benchmark input and exit `64`.

- [ ] **Step 9: Run focused, golden, and full tests**

Run:

```bash
swift test --filter BenchRunnerTests
swift test --parallel
swift run -c release tessavak-bench run --manifest Fixtures/replay/smoke.json --output /tmp/tessavak-remediation-smoke --baseline Fixtures/baseline/smoke-baseline.json
```

Expected: tests pass; benchmark exits `0`; `regressions=0`.

- [ ] **Step 10: Commit**

```bash
git add Sources/TessavakBench/BenchReport.swift Sources/TessavakBench/BenchRunner.swift Sources/TessavakBench/main.swift Tests/TessavakBenchTests/BenchRunnerTests.swift Fixtures/expected/smoke-report.json Fixtures/baseline/smoke-baseline.json
git commit -m "fix: bind benchmark baselines to corpus identity"
```

Only stage fixture files if they actually changed and the change is explained in the commit.

---

### Task 5: Enforce routing, evidence, and scoring invariants

**Files:**

- Modify: `Sources/TessavakCore/Scoring/CandidateScorer.swift`
- Modify: `Sources/TessavakCore/Types/Evidence.swift`
- Modify: `Sources/TessavakCore/Routing/AdaptiveRouter.swift`
- Test: `Tests/TessavakCoreTests/CandidateScorerTests.swift`
- Test: `Tests/TessavakCoreTests/CoreTypesTests.swift`
- Test: `Tests/TessavakCoreTests/AdaptiveRouterTests.swift`

**Interfaces:**

- `ScoringWeights.init(values:)` becomes throwing:

```swift
public init(values: [ScoreComponent: Double]) throws
```

- Provide a validated static default without force-try by using a private trusted initializer or a static factory whose literal values are known valid.

- [ ] **Step 1: Add invalid-weight tests**

Assert rejection of:

```swift
[.acousticConfidence: .nan]
[.acousticConfidence: .infinity]
[.hallucinationPenalty: -0.1]
```

Also test a complete valid weight dictionary.

- [ ] **Step 2: Add evidence consistency tests**

Construct an `EvidenceSnapshot` whose `activeDomains` contains `"baps"` while `domains` is empty. Assert construction and JSON decoding both throw.

- [ ] **Step 3: Add Gujarati ambiguity tests**

With:

```swift
confidentLanguageThreshold: 0.60
secondDecodeThreshold: 0.15
languages: [.gujarati: 0.60, .mixed: 0.40]
```

assert route `.dual`, not `.multilingual`. Add the boundary case where mixed probability is just below the threshold and Gujarati may route `.multilingual`.

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter CandidateScorerTests
swift test --filter CoreTypesTests
swift test --filter AdaptiveRouterTests
```

Expected before implementation: new tests fail.

- [ ] **Step 5: Implement finite non-negative scoring validation**

Require every component exactly once, every value finite, and every value `>= 0`. In `select`, defensively reject any non-finite computed total before sorting.

- [ ] **Step 6: Enforce snapshot consistency**

In `EvidenceSnapshot.init`, require:

```swift
activeDomains.isSubset(of: Set(domains.keys))
```

Include unknown domain names in the error without including transcript data.

- [ ] **Step 7: Apply ambiguity symmetrically**

No single-language route may be returned when:

```swift
evidence.languages[.mixed] >= policy.secondDecodeThreshold
```

Apply that rule before both English and Gujarati single-model branches.

- [ ] **Step 8: Run focused and full tests**

Run:

```bash
swift test --filter CandidateScorerTests
swift test --filter CoreTypesTests
swift test --filter AdaptiveRouterTests
swift test --parallel
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/TessavakCore/Scoring/CandidateScorer.swift Sources/TessavakCore/Types/Evidence.swift Sources/TessavakCore/Routing/AdaptiveRouter.swift Tests/TessavakCoreTests/CandidateScorerTests.swift Tests/TessavakCoreTests/CoreTypesTests.swift Tests/TessavakCoreTests/AdaptiveRouterTests.swift
git commit -m "fix: enforce routing and scoring invariants"
```

---

### Task 6: Create one reproducible verification command

**Files:**

- Create: `scripts/verify.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `.gitignore`
- Track: `Package.resolved`
- Modify: `README.md`

**Interfaces:**

- Produces one executable command:

```bash
./scripts/verify.sh
```

- [ ] **Step 1: Create the verification script**

The script must use:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Run, in order:

```bash
swift package resolve
swift build --build-tests
swift test --parallel
swift format lint --recursive --strict Sources Tests Package.swift
```

Then fail if forbidden imports are found:

```bash
if rg -n 'import (SwiftUI|AppKit|SwiftData|CoreData|AVFoundation|CoreML)' Sources/TessavakCore; then
    echo "TessavakCore contains a forbidden framework import" >&2
    exit 1
fi
```

Run the release smoke benchmark into a temporary directory created with `mktemp -d`, and clean it with a trap. Scan tracked files and generated reports for forbidden audio/transcript leakage using the same checks documented in `docs/initial-build.md`.

- [ ] **Step 2: Make the script executable and run it**

Run:

```bash
chmod +x scripts/verify.sh
./scripts/verify.sh
```

Expected: exit `0`.

- [ ] **Step 3: Harden private-corpus ignores**

Extend `.gitignore` to cover case-insensitive/common local audio variants explicitly:

```gitignore
*.wav
*.WAV
*.m4a
*.M4A
*.mp3
*.MP3
*.flac
*.FLAC
*.caf
*.CAF
*.aiff
*.AIFF
*.aac
*.AAC
Corpus/Private/
Corpus/private/
```

The primary rule remains organizational: private manifests, labels, transcripts, and speaker metadata stay outside the repository, not merely ignored.

- [ ] **Step 4: Commit dependency resolution**

Confirm `Package.resolved` resolves `swift-argument-parser` to the expected reviewed revision, then track it. Do not change dependency versions during this task.

- [ ] **Step 5: Harden CI**

At workflow level, add:

```yaml
permissions:
  contents: read
```

Replace separate build/test commands with:

```yaml
- run: ./scripts/verify.sh
```

Pin `actions/checkout` to a reviewed full commit SHA and retain a comment naming the human-readable release. Add artifact upload under `if: always()` once the verification script exposes the report directory.

- [ ] **Step 6: Update README commands**

Make `./scripts/verify.sh` the documented full verification command while retaining focused developer commands.

- [ ] **Step 7: Run final local verification**

Run:

```bash
./scripts/verify.sh
git status --short
```

Expected: verification exits `0`; status contains only intentional plan/task changes.

- [ ] **Step 8: Commit**

```bash
git add scripts/verify.sh .github/workflows/ci.yml .gitignore Package.resolved README.md
git commit -m "ci: add reproducible verification gate"
```

---

### Task 7: Align documentation and durable project status

**Files:**

- Modify: `docs/initial-build.md`
- Modify: `docs/superpowers/specs/2026-07-24-tessavak-design.md`
- Modify: `README.md`
- Track if approved as durable project artifacts: `docs/superpowers/plans/2026-07-24-tessavak-initial-build.md`
- Track if approved as durable project artifacts: `tasks/plan.md`
- Track if approved as durable project artifacts: `tasks/todo.md`

**Interfaces:**

- Produces one unambiguous status story: initial replay slice complete and hardened; live audio milestone pending.

- [ ] **Step 1: Update design status**

Change the design header from `implementation pending` to a precise status such as:

```text
Status: Approved direction; deterministic replay slice implemented; live audio and consumer integration pending
```

- [ ] **Step 2: Add enforced contracts to the handoff**

Document:

- manifest/report schema validation;
- corpus-bound baseline checks;
- terminating output replacement;
- full verification command;
- distinction between synthetic candidate latency and future measured end-to-end latency.

- [ ] **Step 3: Decide which planning artifacts are durable**

Do not silently stage all untracked files. Inspect each artifact. Track it only if it contains durable acceptance criteria or checkpoint evidence; otherwise leave it untracked and mention that decision in the handoff.

- [ ] **Step 4: Run documentation and full checks**

Run:

```bash
rg -n 'implementation pending|swift test --parallel|scripts/verify.sh' README.md docs tasks
./scripts/verify.sh
```

Expected: no stale statement claiming the entire system is unimplemented; verification exits `0`.

- [ ] **Step 5: Commit**

Stage only the selected durable documents:

```bash
git add README.md docs/initial-build.md docs/superpowers/specs/2026-07-24-tessavak-design.md
git commit -m "docs: align initial build and remediation status"
```

If durable plan/checkpoint artifacts are approved, stage them in a separate documentation commit.

---

### Task 8: Phase 1 completion gate

**Files:**

- Verify all Phase 1 files; do not add feature code.

- [ ] **Step 1: Run the complete verification command**

```bash
./scripts/verify.sh
```

Expected: exit `0`.

- [ ] **Step 2: Run adversarial focused checks**

Confirm tests exist and pass for:

- self-containing Roman replacement;
- empty output forms;
- alias/canonical collisions;
- unsupported/empty/duplicate replay manifests;
- malformed benchmark reports;
- baseline hash/schema/subset mismatch;
- NaN/infinite/negative scoring weights;
- phantom active domains;
- Gujarati mixed-evidence routing.

- [ ] **Step 3: Inspect repository state**

```bash
git status --short
git log --oneline -8
```

Expected: no generated `Reports/`, private corpus files, temporary output, or unrelated changes are staged.

- [ ] **Step 4: Produce the Phase 1 handoff**

Report:

- exact commits created;
- test count and verification result;
- any fixture/baseline changes and why;
- remaining Phase 2/3 work;
- explicit confirmation that real accuracy claims are still unsupported by the five synthetic fixtures.

Do not start Phase 2 in the same execution run.

---

## Phase 1 to-do list

- [ ] Make Roman output rendering finite and deterministic.
- [ ] Reject empty/unsupported output forms.
- [ ] Reject canonical/alias ownership collisions.
- [ ] Validate replay schema, IDs, subsets, observations, candidates, and duplicates.
- [ ] Apply a 64 MiB manifest input limit.
- [ ] Validate benchmark report schemas, hashes, metric ranges, and finite values.
- [ ] Bind baselines to canonical manifest hash, corpus cardinality, and subset membership.
- [ ] Gate per-subset regressions.
- [ ] Print actionable benchmark failures.
- [ ] Reject invalid scoring weights and totals.
- [ ] Reject phantom active domains.
- [ ] Route Gujarati mixed evidence to dual decode consistently.
- [ ] Add a single full verification script.
- [ ] Commit the dependency lockfile without upgrading dependencies.
- [ ] Harden CI permissions, action pinning, and report preservation.
- [ ] Strengthen private-corpus protections.
- [ ] Align design, README, and handoff status.
- [ ] Pass the Phase 1 completion gate and stop.

## Phase 1 checking list

- [ ] `swift test --parallel` passes with more than 115 tests.
- [ ] `swift format lint --recursive --strict Sources Tests Package.swift` exits `0`.
- [ ] Release benchmark exits `0` with zero regressions.
- [ ] Reordered equivalent manifests produce the same canonical hash.
- [ ] Wrong-corpus baselines are rejected before metric comparison.
- [ ] One failing subset cannot be hidden by equal overall metrics.
- [ ] No terminology mapping can cause repeated search over mutated output.
- [ ] JSON decoding cannot bypass any new initializer invariant.
- [ ] Invalid benchmark input exits `64`; internal failures remain `70`.
- [ ] TessavakCore contains no forbidden framework imports.
- [ ] Reports and diagnostics contain no transcript/audio fields or content.
- [ ] CI uses least-privilege read permissions and immutable third-party action revisions.
- [ ] `Package.resolved` is tracked and dependency versions did not change.
- [ ] No private corpus or generated report files are tracked.
- [ ] Documentation still describes the fixture as a wiring smoke test, not an accuracy benchmark.

---

## Phase 2 — Separate follow-on plan: live orchestration contracts

Do not implement Phase 2 from this document. First create a focused design and implementation plan covering:

1. Core-owned audio/utterance and streaming recognition types.
2. Async `Detector` and `Recognizer` protocols in TessavakCore.
3. A typed `RoutingPlan` that controls which recognizers run.
4. Cancellation, timeout, second-decode, and degraded-fallback semantics.
5. A `LivePipelineCoordinator` separate from the deterministic replay processor.
6. ReplayRecognizer adaptation to the core contract.
7. Shared adapter contract tests.
8. Monotonic stage and end-to-end timing.

**Phase 2 entry gate:** every Phase 1 checking-list item passes.

**Phase 2 exit gate:** a fake streaming recognizer proves that `.englishStreaming`, `.multilingual`, and `.dual` decisions invoke exactly the intended adapters, including timeout and fallback tests.

---

## Phase 3 — Separate follow-on plans

Create independent plans for:

### Terminology scale and pack trust

- One immutable `TerminologyIndex` shared by scoring, correction, rendering, and metrics.
- Unicode-aware span matching with integer range arbitration.
- `PackSet`, domain/language activation, collision policy, and pack precedence.
- Signed/hashed envelopes and size/count budgets for externally supplied packs.

### Corpus and benchmark maturity

- Separate public/synthetic and private corpus schemas.
- Consent, provenance, speaker-metadata, and storage rules.
- Explicit metric-eligibility labels and normalized protected-term identities.
- Real first-partial, finalization, RTF, memory, and reference-hardware measurements.

### Release and operations

- Semantic versioning and compatibility rules.
- CODEOWNERS for core contracts, packs, and baselines.
- Tagged release automation and changelog.
- Wffl shadow-mode promotion and rollback runbook.

Each Phase 3 area must have its own plan and independently testable completion gate.

---

## Self-review record

- **Audit coverage:** Every P0 audit finding maps to Tasks 1–7. Phase 2 architectural findings and Phase 3 scaling/governance findings are deliberately separated to prevent an unsafe all-at-once rewrite.
- **Placeholder scan:** No implementation step relies on unspecified behavior; validation values, error categories, commands, paths, and expected results are explicit.
- **Type consistency:** `ReplayManifest` and `ReplayUtterance` become throwing at both direct construction and decoding; all test helpers must propagate `throws`. `BenchReport` validation precedes `BenchRunner` compatibility checks. The verification script is introduced before documentation relies on it.
