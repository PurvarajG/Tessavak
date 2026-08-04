import Foundation
import Testing
import VaaniCore

@testable import VaaniAdapters

// MARK: - Shared audio helpers

enum ContractAudio {
    static func chunk(frames: Int = 160, start: Int64) throws -> AudioChunk {
        try AudioChunk(
            format: .canonical,
            frameCount: frames,
            startMilliseconds: start,
            endMilliseconds: start + Int64(frames * 1000 / AudioFormat.canonical.sampleRateHertz),
            samples: Array(repeating: 0, count: frames)
        )
    }

    static func chunks(count: Int) throws -> [AudioChunk] {
        try (0..<count).map { try chunk(start: Int64($0 * 10)) }
    }

    static func stream(_ chunks: [AudioChunk]) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

enum ReplayFixtures {
    static func smokeManifest() throws -> ReplayManifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/replay/smoke.json")
        return try JSONDecoder().decode(ReplayManifest.self, from: try Data(contentsOf: url))
    }
}

// MARK: - Reusable contract suite

/// Behavioural contract every `StreamingRecognizer` must satisfy, regardless of
/// whether it is a mock, the replay shim, or a real model adapter. Task 5 runs
/// this against `ReplayStreamingRecognizer`; Task 7 runs it against whisper.
enum StreamingRecognizerContract {

    /// Drives one utterance through `recognizer` and asserts the update-stream
    /// invariants: the stream terminates, exactly the tail update is final, at
    /// least one final arrives, and every candidate carries a model identity.
    static func verify(
        _ recognizer: some StreamingRecognizer,
        chunks: [AudioChunk],
        label: String
    ) async throws {
        var updates: [RecognitionUpdate] = []
        for try await update in recognizer.recognize(ContractAudio.stream(chunks)) {
            updates.append(update)
        }

        #expect(!updates.isEmpty, "\(label): recognizer yielded no updates")
        #expect(updates.contains { $0.isFinal }, "\(label): recognizer never yielded a final update")

        if let finalIndex = updates.firstIndex(where: { $0.isFinal }) {
            #expect(
                finalIndex == updates.count - 1,
                "\(label): recognizer yielded \(updates.count - 1 - finalIndex) update(s) after the final"
            )
        }

        for update in updates {
            #expect(!update.candidate.model.name.isEmpty, "\(label): candidate carries an empty model name")
            #expect(!update.candidate.id.isEmpty, "\(label): candidate carries an empty id")
        }

        #expect(!recognizer.identity.name.isEmpty, "\(label): recognizer identity has an empty model name")
    }

    /// Cancelling the consuming task must terminate the update stream rather
    /// than hang. A hang here fails as a test timeout, which is the intent.
    static func verifyCancellationTerminates(
        _ recognizer: some StreamingRecognizer,
        chunks: [AudioChunk],
        label: String
    ) async throws {
        let stream = recognizer.recognize(ContractAudio.stream(chunks))
        // Signals the first update (or stream end), so cancellation lands
        // mid-stream rather than before the consumer has started.
        let progress = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var count = 0
            defer { progress.continuation.finish() }
            for try await _ in stream {
                count += 1
                progress.continuation.yield(())
            }
            return count
        }

        var iterator = progress.stream.makeAsyncIterator()
        _ = await iterator.next()
        consumer.cancel()
        _ = try? await consumer.value
        #expect(consumer.isCancelled, "\(label): consuming task did not observe cancellation")
    }
}

// MARK: - Mock recognizer

enum MockRecognizerError: Error, Equatable, Sendable {
    case recognitionFailed
}

/// Purpose-built `StreamingRecognizer` for contract and coordinator tests.
/// Behaviour is data-driven so a single type covers the happy path, low
/// confidence, failure, and never-completing cases.
struct MockStreamingRecognizer: StreamingRecognizer {
    enum Behavior: Sendable {
        /// `partialCount` partial updates followed by one final update.
        case partialsThenFinal(partialCount: Int)
        /// A single final update and nothing else.
        case finalOnly
        /// Throws before yielding anything.
        case failsImmediately
        /// Yields one partial, then blocks until the consumer is cancelled.
        case blocksAfterPartial
    }

    let identity: ModelIdentity
    let behavior: Behavior
    let text: String
    let finalConfidence: Double

    init(
        identity: ModelIdentity? = nil,
        behavior: Behavior = .partialsThenFinal(partialCount: 2),
        text: String = "mock transcript",
        finalConfidence: Double = 0.9
    ) throws {
        self.identity =
            try identity ?? ModelIdentity(provider: "mock", name: "mock-recognizer", version: "1")
        self.behavior = behavior
        self.text = text
        self.finalConfidence = finalConfidence
    }

    private func candidate(index: Int, confidence: Double) throws -> RecognitionCandidate {
        try RecognitionCandidate(
            id: "\(identity.name)-\(index)",
            text: text,
            confidence: confidence,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: identity,
            latencyMilliseconds: 0
        )
    }

    func recognize(
        _ audio: AsyncThrowingStream<AudioChunk, Error>
    ) -> AsyncThrowingStream<RecognitionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Drain the audio so the contract also covers consumption.
                    for try await _ in audio {}

                    switch behavior {
                    case .failsImmediately:
                        continuation.finish(throwing: MockRecognizerError.recognitionFailed)

                    case .finalOnly:
                        continuation.yield(
                            RecognitionUpdate(
                                candidate: try candidate(index: 0, confidence: finalConfidence),
                                isFinal: true
                            )
                        )
                        continuation.finish()

                    case .partialsThenFinal(let partialCount):
                        for index in 0..<partialCount {
                            continuation.yield(
                                RecognitionUpdate(
                                    candidate: try candidate(index: index, confidence: 0.4),
                                    isFinal: false
                                )
                            )
                        }
                        continuation.yield(
                            RecognitionUpdate(
                                candidate: try candidate(index: partialCount, confidence: finalConfidence),
                                isFinal: true
                            )
                        )
                        continuation.finish()

                    case .blocksAfterPartial:
                        continuation.yield(
                            RecognitionUpdate(
                                candidate: try candidate(index: 0, confidence: 0.4),
                                isFinal: false
                            )
                        )
                        // Suspends until cancelled — no wall-clock waiting.
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

// MARK: - Mock detector

/// Emits one recogniser-sourced observation per audio chunk and nothing for
/// stream boundaries, which is enough to exercise the protocol shape.
struct MockDetector: Detector {
    var languages: [LanguageTag: Double] = [.english: 1.0]

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

// MARK: - Tests

@Suite struct RecognizerContractTests {

    @Test func mockWithPartialsSatisfiesContract() async throws {
        try await StreamingRecognizerContract.verify(
            try MockStreamingRecognizer(behavior: .partialsThenFinal(partialCount: 3)),
            chunks: try ContractAudio.chunks(count: 4),
            label: "mock/partials"
        )
    }

    @Test func mockWithFinalOnlySatisfiesContract() async throws {
        try await StreamingRecognizerContract.verify(
            try MockStreamingRecognizer(behavior: .finalOnly),
            chunks: try ContractAudio.chunks(count: 2),
            label: "mock/final-only"
        )
    }

    @Test func mockConsumesEveryAudioChunk() async throws {
        let recognizer = try MockStreamingRecognizer(behavior: .finalOnly)
        var updates: [RecognitionUpdate] = []
        for try await update in recognizer.recognize(ContractAudio.stream(try ContractAudio.chunks(count: 5))) {
            updates.append(update)
        }
        #expect(updates.count == 1)
        #expect(updates[0].isFinal)
    }

    @Test func failingRecognizerPropagatesErrorRatherThanFinishingSilently() async throws {
        let recognizer = try MockStreamingRecognizer(behavior: .failsImmediately)
        await #expect(throws: MockRecognizerError.recognitionFailed) {
            for try await _ in recognizer.recognize(ContractAudio.stream(try ContractAudio.chunks(count: 1))) {}
        }
    }

    @Test func cancellationTerminatesCompletedStream() async throws {
        try await StreamingRecognizerContract.verifyCancellationTerminates(
            try MockStreamingRecognizer(behavior: .partialsThenFinal(partialCount: 2)),
            chunks: try ContractAudio.chunks(count: 2),
            label: "mock/partials"
        )
    }

    @Test func cancellationTerminatesBlockedStream() async throws {
        try await StreamingRecognizerContract.verifyCancellationTerminates(
            try MockStreamingRecognizer(behavior: .blocksAfterPartial),
            chunks: try ContractAudio.chunks(count: 2),
            label: "mock/blocking"
        )
    }

    @Test func recognitionUpdateCarriesFinality() throws {
        let candidate = try RecognitionCandidate(
            id: "c1",
            text: "hello",
            confidence: 0.8,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: try ModelIdentity(provider: "mock", name: "m", version: "1"),
            latencyMilliseconds: 0
        )
        #expect(RecognitionUpdate(candidate: candidate, isFinal: true).isFinal)
        #expect(!RecognitionUpdate(candidate: candidate, isFinal: false).isFinal)
    }

    // MARK: - Detector

    @Test func detectorObservesChunksAndIgnoresBoundaries() async throws {
        let detector = MockDetector()
        let started = try await detector.observations(
            for: .speechStarted(atMilliseconds: 0),
            provisionalText: nil
        )
        #expect(started.isEmpty)

        let observed = try await detector.observations(
            for: .chunk(try ContractAudio.chunk(start: 0)),
            provisionalText: "hello"
        )
        #expect(observed.count == 1)
        #expect(observed[0].source == .recognizer)
    }

    // MARK: - ReplayCandidateSource keeps its Phase 1 shape

    @Test func replayRecognizerConformsToReplayCandidateSource() async throws {
        let manifest = try ReplayFixtures.smokeManifest()
        let source: any ReplayCandidateSource = try ReplayRecognizer(manifest: manifest)
        let first = try #require(manifest.utterances.first)
        let candidates = try await source.candidates(for: first.id)
        #expect(candidates == first.candidates)
    }
}
