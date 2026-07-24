import Foundation
import Testing
import VaaniCore

@testable import VaaniAdapters

@Suite struct ReplayRecognizerTests {

    private func makeCandidate(id: String) throws -> RecognitionCandidate {
        try RecognitionCandidate(
            id: id,
            text: "hello world",
            confidence: 0.9,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: try ModelIdentity(provider: "replay", name: "test", version: "1"),
            latencyMilliseconds: 10
        )
    }

    private func makeObservation() throws -> EvidenceObservation {
        try EvidenceObservation(
            languages: try LanguageDistribution(values: [.english: 1.0]),
            domains: [:],
            source: .recognizer,
            weight: 1.0,
            timestampMilliseconds: 0
        )
    }

    private func makeUtterance(id: String, candidateIDs: [String]) throws -> ReplayUtterance {
        ReplayUtterance(
            id: id,
            observations: [try makeObservation()],
            candidates: try candidateIDs.map { try makeCandidate(id: $0) },
            expectedText: "hello world",
            expectedRoute: .englishStreaming,
            subset: "test"
        )
    }

    @Test func successfulLookupReturnsCandidates() async throws {
        let utterance = try makeUtterance(id: "utt-1", candidateIDs: ["utt-1-c1", "utt-1-c2"])
        let manifest = ReplayManifest(schemaVersion: 1, utterances: [utterance])
        let recognizer = try ReplayRecognizer(manifest: manifest)
        let candidates = try await recognizer.candidates(for: "utt-1")
        #expect(candidates.count == 2)
    }

    @Test func candidateOrderIsStableAcrossRepeatedLookups() async throws {
        let utterance = try makeUtterance(id: "utt-1", candidateIDs: ["utt-1-c1", "utt-1-c2", "utt-1-c3"])
        let manifest = ReplayManifest(schemaVersion: 1, utterances: [utterance])
        let recognizer = try ReplayRecognizer(manifest: manifest)
        let first = try await recognizer.candidates(for: "utt-1")
        let second = try await recognizer.candidates(for: "utt-1")
        #expect(first.map(\.id) == ["utt-1-c1", "utt-1-c2", "utt-1-c3"])
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test func duplicateUtteranceIDIsRejectedAtInit() throws {
        let first = try makeUtterance(id: "dup", candidateIDs: ["c1"])
        let second = try makeUtterance(id: "dup", candidateIDs: ["c2"])
        let manifest = ReplayManifest(schemaVersion: 1, utterances: [first, second])
        #expect(throws: VaaniAdapterError.duplicateUtteranceID("dup")) {
            try ReplayRecognizer(manifest: manifest)
        }
    }

    @Test func unknownUtteranceIDThrows() async throws {
        let utterance = try makeUtterance(id: "utt-1", candidateIDs: ["c1"])
        let manifest = ReplayManifest(schemaVersion: 1, utterances: [utterance])
        let recognizer = try ReplayRecognizer(manifest: manifest)
        await #expect(throws: VaaniAdapterError.unknownUtteranceID("missing")) {
            try await recognizer.candidates(for: "missing")
        }
    }

    @Test func concurrentReadsReturnConsistentResults() async throws {
        let utterances = try (0..<10).map { index in
            try makeUtterance(id: "utt-\(index)", candidateIDs: ["utt-\(index)-c1"])
        }
        let manifest = ReplayManifest(schemaVersion: 1, utterances: utterances)
        let recognizer = try ReplayRecognizer(manifest: manifest)

        try await withThrowingTaskGroup(of: (Int, [RecognitionCandidate]).self) { group in
            for index in 0..<10 {
                group.addTask {
                    let candidates = try await recognizer.candidates(for: "utt-\(index)")
                    return (index, candidates)
                }
            }
            for try await (index, candidates) in group {
                #expect(candidates.map(\.id) == ["utt-\(index)-c1"])
            }
        }
    }

    // MARK: - Fixture decoding

    @Test func smokeFixtureDecodesWithFiveUtterances() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/replay/smoke.json")
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ReplayManifest.self, from: data)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.utterances.count == 5)
        let subsets = Set(manifest.utterances.map(\.subset))
        #expect(
            subsets == [
                "clean-english", "gujarati-script", "code-switch", "baps-terminology", "collision-protection",
            ]
        )
    }

    @Test func smokeFixtureLoadsIntoReplayRecognizer() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/replay/smoke.json")
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ReplayManifest.self, from: data)
        let recognizer = try ReplayRecognizer(manifest: manifest)
        let candidates = try await recognizer.candidates(for: "utt-en-confident")
        #expect(candidates.count == 1)
        #expect(candidates[0].text == "Please schedule the meeting for tomorrow morning")
    }
}
