import Foundation
import Testing
import TessavakCore
import TessavakPacks

@testable import TessavakAdapters

/// Drives the live orchestration path with the replay shim, proving the
/// coordinator reproduces the Phase 1 benchmark outcome offline — before any
/// real recogniser exists.
@Suite struct ReplayCoordinatorTests {

    private func coordinator(for utterance: ReplayUtterance) throws -> LivePipelineCoordinator {
        let pack = try PackLoader.bundledBAPSGujarati()
        let routingPolicy = try RoutingPolicy(
            mode: .evaluation,
            confidentLanguageThreshold: 0.85,
            secondDecodeThreshold: 0.15,
            latencyBudgetMilliseconds: 500
        )
        return LivePipelineCoordinator(
            accumulatorConfiguration: try EvidenceAccumulatorConfiguration(
                enterThreshold: 0.6, exitThreshold: 0.3, historyLimit: 8
            ),
            router: AdaptiveRouter(policy: routingPolicy),
            scorer: try CandidateScorer(latencyBudgetMilliseconds: 500),
            correctionEngine: CorrectionEngine(pack: pack),
            renderer: OutputRenderer(pack: pack),
            protectedTerms: Set(pack.entries.filter(\.protected).map(\.canonical)),
            detector: ReplayDetector(utterance: utterance),
            recognizerForRoute: ReplayStreamingRecognizer.routeLookup(for: utterance)
        )
    }

    /// One chunk per stored observation, so every observation reaches the
    /// accumulator before the plan is built.
    private func events(for utterance: ReplayUtterance) throws -> AsyncStream<SpeechEvent> {
        var events: [SpeechEvent] = [.speechStarted(atMilliseconds: 0)]
        for index in 0..<utterance.observations.count {
            events.append(.chunk(try ContractAudio.chunk(start: Int64(index * 10))))
        }
        events.append(.speechEnded(atMilliseconds: Int64(utterance.observations.count * 10)))
        events.append(.endOfStream)
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    @Test func everySmokeUtteranceRendersItsExpectedText() async throws {
        let manifest = try ReplayFixtures.smokeManifest()
        for utterance in manifest.utterances {
            let result = try await coordinator(for: utterance).process(
                events: try events(for: utterance),
                sessionPolicy: .evaluation,
                outputPolicy: .preserveMixed
            )
            #expect(result.text == utterance.expectedText, "utterance \(utterance.id)")
        }
    }

    @Test func smokeUtterancesRouteAsTheFixtureExpects() async throws {
        let manifest = try ReplayFixtures.smokeManifest()
        for utterance in manifest.utterances {
            let result = try await coordinator(for: utterance).process(
                events: try events(for: utterance),
                sessionPolicy: .evaluation,
                outputPolicy: .preserveMixed
            )
            #expect(result.route.route == utterance.expectedRoute, "utterance \(utterance.id)")
        }
    }

    @Test func dualUtteranceScoresBothStoredCandidates() async throws {
        let manifest = try ReplayFixtures.smokeManifest()
        let utterance = try #require(manifest.utterances.first { $0.candidates.count > 1 })
        let result = try await coordinator(for: utterance).process(
            events: try events(for: utterance),
            sessionPolicy: .evaluation,
            outputPolicy: .preserveMixed
        )
        #expect(result.selection.scores.count == 2)
        #expect(result.diagnostics.events.map(\.code).contains(.secondaryTriggered))
    }

    // MARK: - Contract

    @Test func replayShimSatisfiesTheStreamingRecognizerContract() async throws {
        let manifest = try ReplayFixtures.smokeManifest()
        for utterance in manifest.utterances {
            let candidate = try #require(utterance.candidates.first)
            try await StreamingRecognizerContract.verify(
                ReplayStreamingRecognizer(candidate: candidate),
                chunks: try ContractAudio.chunks(count: 3),
                label: "replay/\(utterance.id)"
            )
        }
    }

    @Test func replayShimTerminatesOnCancellation() async throws {
        let manifest = try ReplayFixtures.smokeManifest()
        let candidate = try #require(manifest.utterances.first?.candidates.first)
        try await StreamingRecognizerContract.verifyCancellationTerminates(
            ReplayStreamingRecognizer(candidate: candidate),
            chunks: try ContractAudio.chunks(count: 3),
            label: "replay/cancellation"
        )
    }

    @Test func replayDetectorEmitsStoredObservationsInOrder() async throws {
        let manifest = try ReplayFixtures.smokeManifest()
        let utterance = try #require(manifest.utterances.first)
        let detector = ReplayDetector(utterance: utterance)

        #expect(try await detector.observations(for: .speechStarted(atMilliseconds: 0), provisionalText: nil).isEmpty)
        var emitted: [EvidenceObservation] = []
        for index in 0..<utterance.observations.count {
            emitted += try await detector.observations(
                for: .chunk(try ContractAudio.chunk(start: Int64(index * 10))), provisionalText: nil
            )
        }
        #expect(emitted == utterance.observations)
        // Exhausted: further chunks emit nothing rather than repeating.
        #expect(
            try await detector.observations(
                for: .chunk(try ContractAudio.chunk(start: 10_000)), provisionalText: nil
            ).isEmpty
        )
    }
}
