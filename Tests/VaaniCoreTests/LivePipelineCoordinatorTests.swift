import Foundation
import Testing

@testable import VaaniCore

// MARK: - Test doubles

private enum LiveMockError: Error, Equatable {
    case recognitionFailed
}

/// Streaming recogniser whose behaviour is data-driven, so one type covers the
/// happy path, low confidence, failure, and never-completing cases.
private struct LiveMockRecognizer: StreamingRecognizer {
    enum Behavior: Sendable {
        case final
        case failsImmediately
        case blocksForever
    }

    let identity: ModelIdentity
    let behavior: Behavior
    let text: String
    let confidence: Double
    let languages: [LanguageTag: Double]

    init(
        name: String,
        behavior: Behavior = .final,
        text: String = "mock transcript",
        confidence: Double = 0.9,
        languages: [LanguageTag: Double] = [.english: 1.0]
    ) throws {
        self.identity = try ModelIdentity(provider: "mock", name: name, version: "1")
        self.behavior = behavior
        self.text = text
        self.confidence = confidence
        self.languages = languages
    }

    func recognize(
        _ audio: AsyncThrowingStream<AudioChunk, Error>
    ) -> AsyncThrowingStream<RecognitionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await _ in audio {}
                    switch behavior {
                    case .failsImmediately:
                        continuation.finish(throwing: LiveMockError.recognitionFailed)
                    case .final:
                        let candidate = try RecognitionCandidate(
                            id: "cand-\(identity.name)",
                            text: text,
                            confidence: confidence,
                            detectedLanguages: try LanguageDistribution(values: languages),
                            segments: [],
                            model: identity,
                            latencyMilliseconds: 0
                        )
                        continuation.yield(RecognitionUpdate(candidate: candidate, isFinal: true))
                        continuation.finish()
                    case .blocksForever:
                        // Suspends until cancelled; no wall-clock waiting.
                        let gate = AsyncStream<Never>.makeStream()
                        for await _ in gate.stream {}
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct LiveMockDetector: Detector {
    let languages: [LanguageTag: Double]

    func observations(for event: SpeechEvent, provisionalText: String?) async throws
        -> [EvidenceObservation]
    {
        guard case .chunk(let chunk) = event else { return [] }
        return [
            try EvidenceObservation(
                languages: try LanguageDistribution(values: languages),
                domains: [:],
                source: .recognizer,
                weight: 1.0,
                timestampMilliseconds: chunk.startMilliseconds
            )
        ]
    }
}

/// Runs the operation with no budget pressure at all.
private struct NeverExpiringScheduler: DeadlineScheduler {
    func withDeadline<T: Sendable>(
        milliseconds: Int,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await operation()
    }
}

/// Expires before the operation can produce anything.
private struct AlreadyExpiredScheduler: DeadlineScheduler {
    func withDeadline<T: Sendable>(
        milliseconds: Int,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        throw DeadlineExceeded(budgetMilliseconds: milliseconds)
    }
}

/// Expires when the test signals it. Because the coordinator records a
/// candidate before publishing the matching progress event, signalling from an
/// observer makes "budget expired after N candidates" deterministic.
private struct SignalledScheduler: DeadlineScheduler {
    let signal: AsyncStream<Void>

    func withDeadline<T: Sendable>(
        milliseconds: Int,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                var iterator = signal.makeAsyncIterator()
                _ = await iterator.next()
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw DeadlineExceeded(budgetMilliseconds: milliseconds)
            }
            return value
        }
    }
}

// MARK: - Suite

@Suite struct LivePipelineCoordinatorTests {

    private func pack() throws -> TerminologyPack {
        try TerminologyPack(
            schemaVersion: 1,
            id: "test-pack",
            version: "1",
            license: "Project-authored; Apache-2.0",
            provenance: "Synthetic fixture for LivePipelineCoordinator tests.",
            entries: [
                try TerminologyEntry(
                    canonical: "Pramukh Swami Maharaj",
                    aliases: ["pramukh swami maharaj"],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: [:],
                    collisionRisk: 0.05
                )
            ]
        )
    }

    private func makeCoordinator(
        detectorLanguages: [LanguageTag: Double],
        recognizers: [Route: LiveMockRecognizer],
        scheduler: any DeadlineScheduler = NeverExpiringScheduler(),
        progressObserver: LiveProgressObserver? = nil
    ) throws -> LivePipelineCoordinator {
        let terminologyPack = try pack()
        let routingPolicy = try RoutingPolicy(
            mode: .interactive,
            confidentLanguageThreshold: 0.85,
            secondDecodeThreshold: 0.15,
            latencyBudgetMilliseconds: 500
        )
        return LivePipelineCoordinator(
            accumulatorConfiguration: try EvidenceAccumulatorConfiguration(
                enterThreshold: 0.6, exitThreshold: 0.3, historyLimit: 5
            ),
            router: AdaptiveRouter(policy: routingPolicy),
            scorer: try CandidateScorer(latencyBudgetMilliseconds: 500),
            correctionEngine: CorrectionEngine(pack: terminologyPack),
            renderer: OutputRenderer(pack: terminologyPack),
            protectedTerms: Set(terminologyPack.entries.filter(\.protected).map(\.canonical)),
            detector: LiveMockDetector(languages: detectorLanguages),
            recognizerForRoute: { route in recognizers[route] },
            scheduler: scheduler,
            progressObserver: progressObserver
        )
    }

    private func chunk(start: Int64, frames: Int = 160) throws -> AudioChunk {
        try AudioChunk(
            format: .canonical,
            frameCount: frames,
            startMilliseconds: start,
            endMilliseconds: start + Int64(frames * 1000 / AudioFormat.canonical.sampleRateHertz),
            samples: Array(repeating: 0, count: frames)
        )
    }

    private func utterance(chunks: Int = 2) throws -> AsyncStream<SpeechEvent> {
        var events: [SpeechEvent] = [.speechStarted(atMilliseconds: 0)]
        for index in 0..<chunks {
            events.append(.chunk(try chunk(start: Int64(index * 10))))
        }
        events.append(.speechEnded(atMilliseconds: Int64(chunks * 10)))
        events.append(.endOfStream)
        return stream(events)
    }

    private func stream(_ events: [SpeechEvent]) -> AsyncStream<SpeechEvent> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private func codes(_ result: PipelineResult) -> [DecisionCode] {
        result.diagnostics.events.map(\.code)
    }

    // MARK: - Happy path

    @Test func singleRouteUtteranceProducesTranscript() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [.englishStreaming: try LiveMockRecognizer(name: "en", text: "hello world")]
        )
        let result = try await coordinator.process(
            events: try utterance(), sessionPolicy: .interactive, outputPolicy: .preserveMixed
        )

        #expect(result.text == "hello world")
        #expect(result.route.route == .englishStreaming)
        #expect(result.selection.scores.count == 1)
        #expect(codes(result).contains(.routePrimaryEnglish))
        #expect(codes(result).contains(.budgetRespected))
        #expect(codes(result).contains(.secondarySkipped))
        #expect(!codes(result).contains(.degradedFallback))
    }

    @Test func deterministicCorrectionStillAppliesOnTheLivePath() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [
                .englishStreaming: try LiveMockRecognizer(
                    name: "en", text: "we met pramukh swami maharaj today"
                )
            ]
        )
        let result = try await coordinator.process(
            events: try utterance(), sessionPolicy: .interactive, outputPolicy: .preserveMixed
        )
        #expect(result.text.contains("Pramukh Swami Maharaj"))
        #expect(!result.corrections.isEmpty)
    }

    // MARK: - Secondary trigger

    @Test func lowPrimaryConfidenceTriggersSecondary() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.55, .mixed: 0.4, .other: 0.05],
            recognizers: [
                .englishStreaming: try LiveMockRecognizer(
                    name: "en", text: "low confidence text", confidence: 0.3
                ),
                .multilingual: try LiveMockRecognizer(
                    name: "ml", text: "high confidence text", confidence: 0.95
                ),
            ]
        )
        let result = try await coordinator.process(
            events: try utterance(), sessionPolicy: .interactive, outputPolicy: .preserveMixed
        )

        #expect(result.route.route == .dual)
        #expect(codes(result).contains(.secondaryTriggered))
        #expect(result.selection.scores.count == 2)
    }

    @Test func confidentPrimarySkipsSecondary() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.55, .mixed: 0.4, .other: 0.05],
            recognizers: [
                .englishStreaming: try LiveMockRecognizer(
                    name: "en", text: "confident text", confidence: 0.97
                ),
                .multilingual: try LiveMockRecognizer(name: "ml", text: "second opinion"),
            ]
        )
        let result = try await coordinator.process(
            events: try utterance(), sessionPolicy: .interactive, outputPolicy: .preserveMixed
        )

        #expect(codes(result).contains(.secondarySkipped))
        #expect(result.selection.scores.count == 1)
        #expect(result.text == "confident text")
    }

    @Test func evaluationPolicyRunsBothRecognizers() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.55, .mixed: 0.4, .other: 0.05],
            recognizers: [
                .englishStreaming: try LiveMockRecognizer(
                    name: "en", text: "english text", confidence: 0.97
                ),
                .multilingual: try LiveMockRecognizer(name: "ml", text: "multilingual text"),
            ]
        )
        let result = try await coordinator.process(
            events: try utterance(), sessionPolicy: .evaluation, outputPolicy: .preserveMixed
        )

        #expect(codes(result).contains(.secondaryTriggered))
        #expect(result.selection.scores.count == 2)
    }

    // MARK: - Budget

    @Test func budgetExhaustionKeepsTheCompletedCandidate() async throws {
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.55, .mixed: 0.4, .other: 0.05],
            recognizers: [
                .englishStreaming: try LiveMockRecognizer(name: "en", text: "completed text"),
                .multilingual: try LiveMockRecognizer(name: "ml", behavior: .blocksForever),
            ],
            scheduler: SignalledScheduler(signal: signal),
            progressObserver: { event in
                if case .finalCandidateRecorded = event {
                    continuation.yield(())
                }
            }
        )

        // `.evaluation` runs both routes concurrently, so the blocked
        // secondary is still outstanding when the budget expires.
        let result = try await coordinator.process(
            events: try utterance(), sessionPolicy: .evaluation, outputPolicy: .preserveMixed
        )

        #expect(result.text == "completed text")
        #expect(codes(result).contains(.budgetExhausted))
        #expect(result.selection.scores.count == 1)
    }

    @Test func budgetExhaustionWithoutAnyCandidateThrows() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [.englishStreaming: try LiveMockRecognizer(name: "en", behavior: .blocksForever)],
            scheduler: AlreadyExpiredScheduler()
        )

        await #expect(throws: LivePipelineError.budgetExhaustedWithoutCandidate(budgetMilliseconds: 800)) {
            try await coordinator.process(
                events: try utterance(), sessionPolicy: .interactive, outputPolicy: .preserveMixed
            )
        }
    }

    // MARK: - Degraded operation

    @Test func missingPrimaryRecognizerFallsBackToSecondary() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.55, .mixed: 0.4, .other: 0.05],
            recognizers: [.multilingual: try LiveMockRecognizer(name: "ml", text: "fallback text")]
        )
        let result = try await coordinator.process(
            events: try utterance(), sessionPolicy: .interactive, outputPolicy: .preserveMixed
        )

        #expect(result.text == "fallback text")
        #expect(codes(result).contains(.degradedFallback))
    }

    @Test func noAvailableRecognizerThrows() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [:]
        )
        await #expect(throws: (any Error).self) {
            try await coordinator.process(
                events: try utterance(), sessionPolicy: .interactive, outputPolicy: .preserveMixed
            )
        }
    }

    @Test func failingPrimaryFallsBackToSecondaryRatherThanFailingTheUtterance() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.55, .mixed: 0.4, .other: 0.05],
            recognizers: [
                .englishStreaming: try LiveMockRecognizer(name: "en", behavior: .failsImmediately),
                .multilingual: try LiveMockRecognizer(name: "ml", text: "recovered text"),
            ]
        )
        let result = try await coordinator.process(
            events: try utterance(), sessionPolicy: .interactive, outputPolicy: .preserveMixed
        )

        #expect(result.text == "recovered text")
        #expect(codes(result).contains(.degradedFallback))
        #expect(codes(result).contains(.secondaryTriggered))
    }

    // MARK: - Event-ordering invariants

    @Test func chunkBeforeSpeechStartThrows() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [.englishStreaming: try LiveMockRecognizer(name: "en")]
        )
        let events = stream([.chunk(try chunk(start: 0)), .endOfStream])

        await #expect(throws: LivePipelineError.chunkBeforeSpeechStart) {
            try await coordinator.process(
                events: events, sessionPolicy: .interactive, outputPolicy: .preserveMixed
            )
        }
    }

    @Test func nonMonotonicTimestampsThrow() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [.englishStreaming: try LiveMockRecognizer(name: "en")]
        )
        let events = stream([
            .speechStarted(atMilliseconds: 100),
            .chunk(try chunk(start: 0)),
            .endOfStream,
        ])

        await #expect(throws: LivePipelineError.nonMonotonicTimestamp(previous: 100, next: 0)) {
            try await coordinator.process(
                events: events, sessionPolicy: .interactive, outputPolicy: .preserveMixed
            )
        }
    }

    @Test func eventsAfterEndOfStreamThrow() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [.englishStreaming: try LiveMockRecognizer(name: "en")]
        )
        let events = stream([
            .speechStarted(atMilliseconds: 0),
            .endOfStream,
            .speechEnded(atMilliseconds: 10),
        ])

        await #expect(throws: LivePipelineError.eventAfterEndOfStream) {
            try await coordinator.process(
                events: events, sessionPolicy: .interactive, outputPolicy: .preserveMixed
            )
        }
    }

    @Test func utteranceWithoutEvidenceThrows() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [.englishStreaming: try LiveMockRecognizer(name: "en")]
        )
        let events = stream([.speechStarted(atMilliseconds: 0), .endOfStream])

        await #expect(throws: LivePipelineError.noEvidenceObserved) {
            try await coordinator.process(
                events: events, sessionPolicy: .interactive, outputPolicy: .preserveMixed
            )
        }
    }

    // MARK: - Cancellation

    @Test func externalCancellationTerminatesProcessing() async throws {
        let coordinator = try makeCoordinator(
            detectorLanguages: [.english: 0.92, .mixed: 0.03, .other: 0.05],
            recognizers: [.englishStreaming: try LiveMockRecognizer(name: "en", behavior: .blocksForever)]
        )
        let events = try utterance()

        let task = Task {
            try await coordinator.process(
                events: events, sessionPolicy: .interactive, outputPolicy: .preserveMixed
            )
        }
        task.cancel()
        // A hang here fails as a test timeout, which is the point.
        _ = try? await task.value
        #expect(task.isCancelled)
    }
}
