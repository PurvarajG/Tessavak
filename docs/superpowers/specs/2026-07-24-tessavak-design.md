# TessavakCore Design

Date: 2026-07-24
Status: Approved direction; deterministic replay slice implemented and
hardened (Phase 1 audit remediation complete); live audio, recognizer
adapters, and consumer integration pending

## 1. Purpose

TessavakCore is a local-first Swift language-intelligence engine shared by:

- Wffl, where it improves multilingual meeting transcription.
- A rebuilt W1, where it powers low-latency dictation in any macOS application.
- Future applications that need specialised multilingual or industry terminology.

BAPS Gujarati is the first demanding reference domain, not a permanent hardcoded product boundary. The architecture must generalise to additional languages and domain packs without changing the recognition pipeline.

## 2. Product principles

1. Audio and transcript content remain on the device by default.
2. Ordinary English stays fast; expensive inference is reserved for ambiguous speech.
3. Detection happens before and alongside transcription, not only after transcription.
4. Recognition, language detection, domain detection, correction, and presentation remain separate.
5. Deterministic corrections take priority over generative rewriting.
6. Local language models review only uncertain spans and may never silently paraphrase dictated content.
7. Every material accuracy claim must come from a versioned labelled evaluation corpus.
8. Wffl and W1 consume the same core interfaces but retain product-specific user experiences.

## 3. Scope

### Initial release

- Apple Silicon macOS 15 or later.
- English, Gujarati, and English–Gujarati code-switching.
- BAPS terminology, names, scriptures, honorifics, and preferred spellings.
- Gujarati script and BAPS-style Roman Gujarati output policies.
- Streaming recognition suitable for interactive dictation.
- Longer-form recognition suitable for meetings.
- Local evaluation, telemetry-free by default.

### Explicitly deferred

- Windows, iOS, and Android applications.
- Training a foundation speech-recognition model.
- Cloud transcription as a required runtime dependency.
- Autonomous command execution.
- Organisation accounts, synchronisation, and billing.
- Additional industry packs before the core BAPS/Gujarati benchmark meets its acceptance targets.

## 4. Repository boundaries

The repository will contain four independently testable units:

### TessavakCore

A pure Swift package containing:

- audio and utterance types;
- detector and recogniser protocols;
- language/domain evidence aggregation;
- adaptive model routing;
- candidate scoring;
- correction orchestration;
- output-policy handling;
- structured diagnostics.

It must not import SwiftUI, AppKit, persistence frameworks, clipboard APIs, or product-specific state.

### TessavakAdapters

macOS and model integrations:

- FluidAudio/Core ML streaming recognisers;
- whisper.cpp multilingual recogniser;
- voice activity detection;
- model downloading and lifecycle management;
- optional local-LLM provider;
- Wffl and W1 bridge types.

### TessavakPacks

Versioned data packages:

- language metadata;
- BAPS terminology and aliases;
- protected terms;
- phonetic forms;
- decoder-bias candidates;
- deterministic correction rules;
- transliteration policies;
- per-pack evaluation fixtures.

Domain data must be reviewable without reading recognition code. Generated artefacts must identify their source and generator.

### TessavakBench

An offline command-line evaluation tool that:

- runs labelled audio through configured pipelines;
- records latency, memory, routing, and accuracy metrics;
- compares changes against a checked-in baseline;
- produces machine-readable JSON and a human-readable report;
- fails CI when protected quality thresholds regress.

## 5. Runtime data flow

1. Audio capture supplies 16 kHz mono frames with monotonic timestamps.
2. Voice activity detection identifies speech and utterance boundaries.
3. A lightweight detector updates language probabilities from audio and provisional text.
4. The router selects a primary recogniser:
   - fast streaming English recogniser for confident English;
   - multilingual Whisper for confident Gujarati;
   - dual decoding for uncertain or code-switched utterances.
5. Recognisers return structured candidates containing text, token/segment confidence, detected language, timing, and model identity.
6. The scorer ranks candidates using acoustic confidence, language consistency, terminology evidence, phonetic similarity, recent context, and routing cost.
7. The correction engine applies protected-term masking and deterministic pack rules.
8. If an uncertain span remains, an optional small local LLM proposes a constrained substitution.
9. A validator rejects additions, deletions, paraphrases, excessive length changes, and protected-term damage.
10. The selected output policy emits Gujarati script, BAPS Roman Gujarati, or preserved mixed-language output.
11. Consumers receive final text plus structured diagnostics. Raw audio is released unless the host product explicitly enabled local history.

## 6. Adaptive detection

Detection is represented as continuously updated evidence, not a permanent Boolean gate.

The detector produces:

- language probabilities for English, Gujarati, Hindi, other, and mixed;
- zero or more domain probabilities;
- confidence and evidence provenance;
- a recommended route without directly starting inference.

Evidence sources include:

- acoustic language identification;
- recogniser language probabilities;
- Unicode script;
- Roman-Gujarati phonetic patterns;
- exact and approximate pack matches;
- recent utterance and speaker history;
- active application profile;
- explicit temporary user mode;
- locally stored user corrections.

The evidence accumulator uses separate enter and exit thresholds. This hysteresis prevents rapid mode oscillation while still allowing utterance-level code-switching. Meeting consumers may additionally maintain speaker-specific priors.

No corrected output may be fed back as independent evidence for enabling the correction that produced it. Candidate text may contribute only with provenance indicating which recogniser and biases generated it.

## 7. Adaptive routing

The default routing policy optimises expected error subject to a latency budget.

- Confident English uses one streaming recogniser.
- Confident Gujarati uses one multilingual recogniser.
- Ambiguous speech initially runs the likely primary model.
- A second decode starts only when detector confidence, recognition confidence, or terminology evidence falls below configured thresholds.
- Interactive dictation may insert a provisional candidate and replace it only while the host field still contains the unchanged provisional text.
- Meeting transcription waits for candidate selection before finalising a segment.

Routing policies are injected by the host:

- `interactive`: prioritises first-partial and finalisation latency.
- `meeting`: prioritises accuracy and continuity.
- `verbatim`: disables destructive cleanup and generative correction.
- `evaluation`: enables complete diagnostics and deterministic execution.

## 8. Candidate scoring

Candidate scoring must be explainable. Each score includes named components rather than one opaque value:

- acoustic/model confidence;
- language probability agreement;
- script agreement;
- domain-term recall;
- phonetic plausibility;
- context continuity;
- protected-term integrity;
- hallucination and repetition penalties;
- latency/energy cost.

Weights are configuration data and are calibrated against TessavakBench. A scorer change must report which evaluation subsets improved or regressed.

## 9. Terminology and correction

Each pack defines:

- canonical spelling;
- aliases and observed mishearings;
- phonetic representation;
- language and script;
- protected status;
- allowed output forms;
- safe deterministic rules;
- optional decoder-bias priority;
- collision risk with ordinary words.

The correction order is:

1. normalise punctuation without deleting lexical content;
2. mask protected spans;
3. apply exact phrase rules;
4. apply conservative phonetic/fuzzy candidates;
5. score ambiguous substitutions using context;
6. optionally ask the local LLM about only those spans;
7. validate the proposal;
8. restore protected spans;
9. apply the selected output/transliteration policy.

User edits may create local aliases or pronunciation profiles, but must not modify the shipped pack. Users can inspect and delete all learned data.

## 10. Transliteration

Transliteration is a selectable output policy, not a recogniser.

The initial BAPS Roman policy permits ASCII plus `ā` and uses a reviewed lexicon for exceptions. A Unicode syllable walker provides deterministic fallback for unseen Gujarati words. Lexicon-backed output takes precedence where naive word-final schwa deletion or consonant mapping would produce a nonstandard BAPS spelling.

The default `preserveMixed` policy keeps English spans in English and Gujarati spans in Gujarati script. Users and host applications may instead select `gujaratiScript`, `bapsRoman`, or `englishTranslation`. The `bapsRoman` policy preserves English spans while transliterating Gujarati spans only.

## 11. Local-LLM safety

The local LLM is optional and never sits on the ordinary fast path.

Its input contains:

- the original uncertain span;
- a small candidate set;
- bounded neighbouring context;
- relevant pack entries;
- a substitution-only instruction.

Its output is parsed as structured substitutions. A proposal is rejected if it:

- changes words outside the allowed span;
- introduces an unrelated domain term;
- changes too much of the source;
- modifies a protected term incorrectly;
- cannot be represented as the declared substitution;
- times out or returns invalid structure.

Rejection leaves the deterministic result unchanged.

## 12. Consumer integration

### Wffl

Wffl replaces `VocabularyGate` with the TessavakCore evidence accumulator and router. Existing audio capture, meeting persistence, diarisation, cleanup, and summarisation remain product-owned.

The first integration runs TessavakCore in shadow mode: current output remains authoritative while routing and candidate decisions are logged locally for comparison. TessavakCore becomes authoritative only after the meeting benchmark and real-world shadow results meet acceptance targets.

### W1 successor

The rebuilt W1 is a native Swift menu-bar application. It owns:

- permissions and onboarding;
- global push-to-talk/toggle shortcuts;
- live overlay and provisional text;
- focus capture and cross-app insertion;
- snippets and per-app profiles;
- user-facing dictionary and correction history.

It consumes TessavakCore’s `interactive` policy. The first product release excludes command execution and focuses on excellent dictation.

## 13. Evaluation corpus

The corpus manifest records consent/provenance, speaker, language mix, domain, microphone conditions, expected output policy, and transcription.

Required subsets:

- clean English;
- accented English;
- Gujarati script;
- BAPS Roman Gujarati;
- natural English–Gujarati code-switching;
- BAPS names and multiword sacred terminology;
- ordinary English containing collision words;
- silence, music, crosstalk, and low-quality microphones;
- fast dictation with self-corrections;
- long meetings with multiple speakers.

Private audio remains outside Git. The repository contains manifests, hashes, public/synthetic fixtures, and tooling. CI uses redistributable fixtures; full local evaluation can use the private corpus.

## 14. Metrics and acceptance targets

The baseline must record:

- English word error rate;
- Gujarati character and word error rates;
- code-switch boundary F1;
- BAPS protected-term exact-match rate;
- domain-term precision and recall;
- false domain-correction rate on plain English;
- first-partial and final-text latency;
- real-time factor;
- dual-decode rate;
- local-LLM invocation and rejection rates;
- peak memory and energy impact.

Initial release targets on the agreed reference hardware:

- no statistically meaningful English-WER regression against Wffl’s current Parakeet path;
- at least 98% protected-term exact-match on the curated BAPS test subset;
- below 0.2% false domain corrections on the plain-English collision subset;
- at least 90% code-switch boundary F1;
- median first partial below 500 ms for interactive English dictation;
- median final text below 1.2 seconds after speech ends;
- real-time factor below 0.5 for meeting transcription;
- dual decoding on fewer than 25% of ordinary English utterances.

Before implementation benchmarking, “reference hardware” means the primary Apple Silicon development Mac. Its exact model, memory, macOS version, and power mode will be captured in every benchmark report.

## 15. Failure handling

- If the detector fails, route to the configured safe fallback recogniser.
- If a specialist model is unavailable, continue with the primary recogniser and mark degraded mode.
- If dual decoding exceeds the latency budget, return the best completed candidate.
- If correction fails, preserve recogniser output.
- If insertion cannot be verified, retain the text in the W1 overlay for manual paste.
- If a model download is incomplete or fails integrity validation, never load it.
- Diagnostics contain timings and decision codes, not audio or transcript text by default.

## 16. Testing strategy

- Unit tests for evidence accumulation, hysteresis, scoring, correction order, protected terms, transliteration, and validation.
- Contract tests for every recogniser and detector adapter.
- Golden tests for every terminology pack.
- Audio integration tests for routing and timestamps.
- End-to-end W1 tests for hotkeys, focus restoration, insertion, clipboard restoration, and permission recovery.
- Wffl shadow-mode comparisons on complete meetings.
- Performance tests with fixed audio, model versions, thermal state notes, and reference hardware.
- Regression reports generated by TessavakBench for every routing, model, scorer, or pack change.

## 17. Repository and licensing policy

TessavakCore will use the Apache License 2.0. Its permissive reuse terms and explicit patent grant suit a shared engine intended for multiple applications. Terminology packs may carry separate compatible data licences where their sources require them.

FluidVoice is a behavioural and architectural reference only. Its current GPLv3 source will not be copied into TessavakCore, Wffl, or the W1 successor unless the projects intentionally adopt GPLv3. W1’s MIT-licensed data and logic may be ported with attribution after verifying the repository’s complete licence history. Existing Wffl code may be extracted only after preserving its authorship and chosen licence.

Third-party models, datasets, and packages must have recorded licences, versions, hashes, and redistribution conditions.

## 18. Delivery sequence

1. Establish TessavakBench and capture the current Wffl/W1 baseline.
2. Define core protocols, diagnostics, and pack schema.
3. Port the safe BAPS terminology data and correction rules.
4. Implement evidence accumulation and replay it against recorded recogniser outputs.
5. Add recogniser adapters and adaptive routing.
6. Run TessavakCore in Wffl shadow mode.
7. Make TessavakCore authoritative in Wffl after acceptance targets pass.
8. Build the minimal native W1 dictation shell.
9. Add per-app profiles, user learning, snippets, and optional constrained local-LLM correction.
10. Add new language or industry packs only after the BAPS/Gujarati reference implementation is stable.

## 19. Decisions

- The shared engine is a standalone Swift repository named TessavakCore.
- Wffl and W1 remain separate products.
- The W1 successor is native Swift rather than an extension of the current Python shell.
- BAPS is implemented as a domain pack.
- Gujarati is implemented as a language/output-policy combination.
- Preserved mixed-language output is the default; Gujarati script, BAPS Roman Gujarati, and English translation are explicit alternatives.
- Detection is probabilistic and utterance-aware.
- Ambiguous speech uses adaptive dual decoding.
- The local LLM is constrained fallback logic, not the primary recogniser or editor.
- Integration begins in Wffl shadow mode.
- TessavakCore is licensed under Apache-2.0; pack data records its own compatible provenance and licence.
- No implementation begins until this specification is reviewed.
