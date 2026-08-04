import Foundation
import Testing

@testable import VaaniCore

@Suite struct CoreTypesTests {

    // MARK: - LanguageDistribution

    @Test func distributionRejectsOutOfRangeProbability() {
        #expect(throws: (any Error).self) {
            try LanguageDistribution(values: [.english: 1.01])
        }
    }

    @Test func distributionRejectsNonUnitSum() {
        #expect(throws: (any Error).self) {
            try LanguageDistribution(values: [.english: 0.8, .gujarati: 0.1])
        }
    }

    @Test func distributionAllowsSumWithinTolerance() throws {
        let distribution = try LanguageDistribution(values: [.english: 0.5, .gujarati: 0.5000005])
        #expect(abs(distribution[.english] + distribution[.gujarati] - 1) <= 0.000_001)
    }

    @Test func distributionMissingKeyReturnsZero() throws {
        let distribution = try LanguageDistribution(values: [.english: 1.0])
        #expect(distribution[.gujarati] == 0)
        #expect(distribution[.hindi] == 0)
    }

    @Test func distributionDominantPicksHighestThenLexicographic() throws {
        let distribution = try LanguageDistribution(values: [.english: 0.5, .gujarati: 0.5])
        let dominant = distribution.dominant
        #expect(dominant.language == .english)
        #expect(dominant.probability == 0.5)
    }

    @Test func distributionRoundTripsThroughJSON() throws {
        let distribution = try LanguageDistribution(values: [.english: 0.9, .gujarati: 0.1])
        let data = try JSONEncoder().encode(distribution)
        let decoded = try JSONDecoder().decode(LanguageDistribution.self, from: data)
        #expect(decoded == distribution)
    }

    @Test func distributionJSONDecodingCannotBypassValidation() {
        let badJSON = Data(#"{"en": 1.5}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LanguageDistribution.self, from: badJSON)
        }
    }

    // MARK: - RecognitionCandidate confidence

    @Test func absentCandidateConfidenceRoundTripsWithTheKeyOmitted() throws {
        let candidate = try RecognitionCandidate(
            id: "c1",
            text: "hello",
            confidence: nil,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: try ModelIdentity(provider: "whisper.cpp", name: "tiny", version: "1"),
            latencyMilliseconds: 0
        )

        let data = try JSONEncoder().encode(candidate)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("confidence"))

        let decoded = try JSONDecoder().decode(RecognitionCandidate.self, from: data)
        #expect(decoded.confidence == nil)
        #expect(decoded == candidate)
    }

    @Test func candidateConfidenceStillRejectsOutOfRangeValues() {
        #expect(throws: (any Error).self) {
            try RecognitionCandidate(
                id: "c1",
                text: "hello",
                confidence: 1.5,
                detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
                segments: [],
                model: try ModelIdentity(provider: "mock", name: "m", version: "1"),
                latencyMilliseconds: 0
            )
        }
    }

    // MARK: - DiagnosticEvent

    @Test func diagnosticsRejectSensitiveAttributeKeys() {
        #expect(throws: (any Error).self) {
            try DiagnosticEvent(
                code: .candidateSelected,
                elapsedMilliseconds: 3,
                attributes: ["text": "private"]
            )
        }
    }

    @Test func diagnosticsRejectEachSensitiveKey() {
        for key in ["text", "transcript", "audio", "rawCandidate"] {
            #expect(throws: (any Error).self) {
                try DiagnosticEvent(code: .candidateSelected, elapsedMilliseconds: 0, attributes: [key: "x"])
            }
        }
    }

    @Test func diagnosticsRejectNegativeElapsed() {
        #expect(throws: (any Error).self) {
            try DiagnosticEvent(code: .candidateSelected, elapsedMilliseconds: -1, attributes: [:])
        }
    }

    @Test func diagnosticsAllowSafeAttributes() throws {
        let event = try DiagnosticEvent(
            code: .routeDual,
            elapsedMilliseconds: 12,
            attributes: ["reason": "mixed evidence"]
        )
        #expect(event.attributes["reason"] == "mixed evidence")
    }

    // MARK: - EvidenceObservation

    private func validDistribution() throws -> LanguageDistribution {
        try LanguageDistribution(values: [.english: 1.0])
    }

    @Test func evidenceObservationRejectsNonPositiveWeight() throws {
        let languages = try validDistribution()
        #expect(throws: (any Error).self) {
            try EvidenceObservation(
                languages: languages, domains: [:], source: .recognizer, weight: 0, timestampMilliseconds: 0
            )
        }
    }

    @Test func evidenceObservationRejectsNegativeTimestamp() throws {
        let languages = try validDistribution()
        #expect(throws: (any Error).self) {
            try EvidenceObservation(
                languages: languages, domains: [:], source: .recognizer, weight: 1, timestampMilliseconds: -5
            )
        }
    }

    @Test func evidenceObservationRejectsOutOfRangeDomainProbability() throws {
        let languages = try validDistribution()
        #expect(throws: (any Error).self) {
            try EvidenceObservation(
                languages: languages,
                domains: ["baps": 1.5],
                source: .recognizer,
                weight: 1,
                timestampMilliseconds: 0
            )
        }
    }

    @Test func evidenceObservationAcceptsValidInput() throws {
        let languages = try validDistribution()
        let observation = try EvidenceObservation(
            languages: languages,
            domains: ["baps": 0.8],
            source: .recognizer,
            weight: 1,
            timestampMilliseconds: 10
        )
        #expect(observation.domains["baps"] == 0.8)
    }

    // MARK: - RecognitionSegment

    @Test func segmentRejectsInvalidTimeRange() {
        #expect(throws: (any Error).self) {
            try RecognitionSegment(text: "hi", startMilliseconds: 10, endMilliseconds: 5, confidence: nil)
        }
    }

    @Test func segmentRejectsNegativeStart() {
        #expect(throws: (any Error).self) {
            try RecognitionSegment(text: "hi", startMilliseconds: -1, endMilliseconds: 5, confidence: nil)
        }
    }

    @Test func segmentRejectsOutOfRangeConfidence() {
        #expect(throws: (any Error).self) {
            try RecognitionSegment(text: "hi", startMilliseconds: 0, endMilliseconds: 5, confidence: 1.2)
        }
    }

    @Test func segmentAllowsNilConfidence() throws {
        let segment = try RecognitionSegment(text: "hi", startMilliseconds: 0, endMilliseconds: 5, confidence: nil)
        #expect(segment.confidence == nil)
    }

    // MARK: - ModelIdentity

    @Test func modelIdentityRejectsEmptyProvider() {
        #expect(throws: (any Error).self) {
            try ModelIdentity(provider: "", name: "whisper", version: "1.0")
        }
    }

    @Test func modelIdentityRejectsEmptyName() {
        #expect(throws: (any Error).self) {
            try ModelIdentity(provider: "openai", name: "", version: "1.0")
        }
    }

    @Test func modelIdentityRejectsEmptyVersion() {
        #expect(throws: (any Error).self) {
            try ModelIdentity(provider: "openai", name: "whisper", version: "")
        }
    }

    // MARK: - RecognitionCandidate

    private func makeModel() throws -> ModelIdentity {
        try ModelIdentity(provider: "replay", name: "fixture", version: "1")
    }

    @Test func candidateRejectsEmptyID() throws {
        let model = try makeModel()
        let languages = try validDistribution()
        #expect(throws: (any Error).self) {
            try RecognitionCandidate(
                id: "",
                text: "hello",
                confidence: 0.9,
                detectedLanguages: languages,
                segments: [],
                model: model,
                latencyMilliseconds: 10
            )
        }
    }

    @Test func candidateRejectsOutOfRangeConfidence() throws {
        let model = try makeModel()
        let languages = try validDistribution()
        #expect(throws: (any Error).self) {
            try RecognitionCandidate(
                id: "c1",
                text: "hello",
                confidence: 1.5,
                detectedLanguages: languages,
                segments: [],
                model: model,
                latencyMilliseconds: 10
            )
        }
    }

    @Test func candidateRejectsNegativeLatency() throws {
        let model = try makeModel()
        let languages = try validDistribution()
        #expect(throws: (any Error).self) {
            try RecognitionCandidate(
                id: "c1",
                text: "hello",
                confidence: 0.9,
                detectedLanguages: languages,
                segments: [],
                model: model,
                latencyMilliseconds: -1
            )
        }
    }

    @Test func candidateRejectsOutOfOrderSegments() throws {
        let model = try makeModel()
        let languages = try validDistribution()
        let first = try RecognitionSegment(text: "a", startMilliseconds: 0, endMilliseconds: 100, confidence: nil)
        let second = try RecognitionSegment(text: "b", startMilliseconds: 50, endMilliseconds: 150, confidence: nil)
        #expect(throws: (any Error).self) {
            try RecognitionCandidate(
                id: "c1",
                text: "hello",
                confidence: 0.9,
                detectedLanguages: languages,
                segments: [first, second],
                model: model,
                latencyMilliseconds: 10
            )
        }
    }

    @Test func candidateAcceptsWellOrderedSegments() throws {
        let model = try makeModel()
        let languages = try validDistribution()
        let first = try RecognitionSegment(text: "a", startMilliseconds: 0, endMilliseconds: 100, confidence: nil)
        let second = try RecognitionSegment(text: "b", startMilliseconds: 100, endMilliseconds: 150, confidence: nil)
        let candidate = try RecognitionCandidate(
            id: "c1",
            text: "hello",
            confidence: 0.9,
            detectedLanguages: languages,
            segments: [first, second],
            model: model,
            latencyMilliseconds: 10
        )
        #expect(candidate.segments.count == 2)
    }

    @Test func candidateJSONDecodingCannotBypassValidation() throws {
        let model = try makeModel()
        let modelData = try JSONEncoder().encode(model)
        let modelJSON = String(data: modelData, encoding: .utf8)!
        let badJSON = Data(
            """
            {
              "id": "c1",
              "text": "hello",
              "confidence": 5.0,
              "detectedLanguages": {"en": 1.0},
              "segments": [],
              "model": \(modelJSON),
              "latencyMilliseconds": 10
            }
            """.utf8
        )
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RecognitionCandidate.self, from: badJSON)
        }
    }

    // MARK: - EvidenceSnapshot

    @Test func snapshotRejectsNegativeObservationCount() throws {
        let languages = try validDistribution()
        #expect(throws: (any Error).self) {
            try EvidenceSnapshot(languages: languages, domains: [:], activeDomains: [], observations: -1)
        }
    }

    @Test func snapshotAcceptsValidInput() throws {
        let languages = try validDistribution()
        let snapshot = try EvidenceSnapshot(
            languages: languages, domains: ["baps": 0.9], activeDomains: ["baps"], observations: 3
        )
        #expect(snapshot.activeDomains == ["baps"])
    }

    @Test func snapshotRejectsPhantomActiveDomain() throws {
        let languages = try validDistribution()
        #expect(throws: (any Error).self) {
            try EvidenceSnapshot(languages: languages, domains: [:], activeDomains: ["baps"], observations: 1)
        }
    }

    @Test func snapshotJSONDecodingRejectsPhantomActiveDomain() {
        let badJSON = Data(
            """
            {"languages": {"en": 1.0}, "domains": {}, "activeDomains": ["baps"], "observations": 1}
            """.utf8
        )
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EvidenceSnapshot.self, from: badJSON)
        }
    }
}
