import Foundation
import Testing

@testable import VaaniCore

@Suite struct EvidenceAccumulatorTests {

    private func observation(
        domain: Double,
        at timestamp: Int64,
        englishProbability: Double = 1.0,
        weight: Double = 1.0
    ) throws -> EvidenceObservation {
        let languages: LanguageDistribution
        if englishProbability >= 1.0 {
            languages = try LanguageDistribution(values: [.english: 1.0])
        } else {
            languages = try LanguageDistribution(values: [
                .english: englishProbability, .gujarati: 1.0 - englishProbability,
            ])
        }
        return try EvidenceObservation(
            languages: languages,
            domains: ["baps": domain],
            source: .terminology,
            weight: weight,
            timestampMilliseconds: timestamp
        )
    }

    @Test func hysteresisPreventsDomainFlapping() throws {
        var accumulator = EvidenceAccumulator(
            configuration: try .init(
                enterThreshold: 0.70, exitThreshold: 0.40, historyLimit: 2
            ))

        let entered = try accumulator.ingest(observation(domain: 0.80, at: 1))
        #expect(entered.activeDomains == ["baps"])

        let retained = try accumulator.ingest(observation(domain: 0.30, at: 2))
        #expect(retained.activeDomains == ["baps"])  // aggregate 0.55

        let exited = try accumulator.ingest(observation(domain: 0.10, at: 3))
        #expect(exited.activeDomains.isEmpty)  // aggregate 0.20
    }

    @Test func domainNeverReachingEnterThresholdStaysInactive() throws {
        var accumulator = EvidenceAccumulator(
            configuration: try .init(enterThreshold: 0.70, exitThreshold: 0.40, historyLimit: 3)
        )
        let snapshot1 = try accumulator.ingest(observation(domain: 0.50, at: 1))
        #expect(snapshot1.activeDomains.isEmpty)
        let snapshot2 = try accumulator.ingest(observation(domain: 0.60, at: 2))
        #expect(snapshot2.activeDomains.isEmpty)
    }

    @Test func weightedLanguageAggregation() throws {
        var accumulator = EvidenceAccumulator(
            configuration: try .init(enterThreshold: 0.9, exitThreshold: 0.1, historyLimit: 5)
        )
        _ = try accumulator.ingest(
            try observation(domain: 0.0, at: 1, englishProbability: 1.0, weight: 3.0)
        )
        let snapshot = try accumulator.ingest(
            try observation(domain: 0.0, at: 2, englishProbability: 0.0, weight: 1.0)
        )
        // Weighted mean: (3*1.0 + 1*0.0) / 4 = 0.75 English, 0.25 Gujarati.
        #expect(abs(snapshot.languages[.english] - 0.75) < 1e-9)
        #expect(abs(snapshot.languages[.gujarati] - 0.25) < 1e-9)
    }

    @Test func historyEvictionDropsOldestObservations() throws {
        var accumulator = EvidenceAccumulator(
            configuration: try .init(enterThreshold: 0.9, exitThreshold: 0.1, historyLimit: 1)
        )
        _ = try accumulator.ingest(
            try observation(domain: 0.0, at: 1, englishProbability: 1.0)
        )
        let snapshot = try accumulator.ingest(
            try observation(domain: 0.0, at: 2, englishProbability: 0.0)
        )
        // historyLimit=1 means only the latest observation contributes.
        #expect(snapshot.languages[.english] == 0)
        #expect(snapshot.languages[.gujarati] == 1)
        #expect(snapshot.observations == 1)
    }

    @Test func resetClearsHistoryAndActiveDomains() throws {
        var accumulator = EvidenceAccumulator(
            configuration: try .init(enterThreshold: 0.70, exitThreshold: 0.40, historyLimit: 2)
        )
        _ = try accumulator.ingest(observation(domain: 0.9, at: 1))
        accumulator.reset()
        let snapshot = try accumulator.ingest(observation(domain: 0.9, at: 1))
        #expect(snapshot.observations == 1)
        #expect(snapshot.activeDomains == ["baps"])
    }

    @Test func configurationRejectsExitGreaterOrEqualToEnter() {
        #expect(throws: (any Error).self) {
            try EvidenceAccumulatorConfiguration(enterThreshold: 0.5, exitThreshold: 0.5, historyLimit: 2)
        }
    }

    @Test func configurationRejectsOutOfRangeThresholds() {
        #expect(throws: (any Error).self) {
            try EvidenceAccumulatorConfiguration(enterThreshold: 1.2, exitThreshold: 0.1, historyLimit: 2)
        }
    }

    @Test func configurationRejectsNonPositiveHistoryLimit() {
        #expect(throws: (any Error).self) {
            try EvidenceAccumulatorConfiguration(enterThreshold: 0.7, exitThreshold: 0.4, historyLimit: 0)
        }
    }

    @Test func nonMonotonicTimestampsThrow() throws {
        var accumulator = EvidenceAccumulator(
            configuration: try .init(enterThreshold: 0.70, exitThreshold: 0.40, historyLimit: 2)
        )
        _ = try accumulator.ingest(observation(domain: 0.5, at: 10))
        #expect(throws: (any Error).self) {
            try accumulator.ingest(try observation(domain: 0.5, at: 5))
        }
    }

    @Test func equalTimestampsAreAccepted() throws {
        var accumulator = EvidenceAccumulator(
            configuration: try .init(enterThreshold: 0.70, exitThreshold: 0.40, historyLimit: 2)
        )
        _ = try accumulator.ingest(observation(domain: 0.5, at: 10))
        let snapshot = try accumulator.ingest(observation(domain: 0.5, at: 10))
        #expect(snapshot.observations == 2)
    }
}
