import Foundation

public struct EvidenceAccumulatorConfiguration: Codable, Equatable, Sendable {
    public let enterThreshold: Double
    public let exitThreshold: Double
    public let historyLimit: Int

    public init(enterThreshold: Double, exitThreshold: Double, historyLimit: Int) throws {
        guard enterThreshold >= 0, enterThreshold <= 1 else {
            throw TessavakCoreError.invalidProbability(field: "enterThreshold", value: enterThreshold)
        }
        guard exitThreshold >= 0, exitThreshold <= 1 else {
            throw TessavakCoreError.invalidProbability(field: "exitThreshold", value: exitThreshold)
        }
        guard exitThreshold < enterThreshold else {
            throw TessavakCoreError.invalidConfiguration(
                "exitThreshold (\(exitThreshold)) must be less than enterThreshold (\(enterThreshold))"
            )
        }
        guard historyLimit > 0 else {
            throw TessavakCoreError.invalidConfiguration("historyLimit must be positive, got \(historyLimit)")
        }
        self.enterThreshold = enterThreshold
        self.exitThreshold = exitThreshold
        self.historyLimit = historyLimit
    }

    private enum CodingKeys: String, CodingKey {
        case enterThreshold, exitThreshold, historyLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            enterThreshold: try container.decode(Double.self, forKey: .enterThreshold),
            exitThreshold: try container.decode(Double.self, forKey: .exitThreshold),
            historyLimit: try container.decode(Int.self, forKey: .historyLimit)
        )
    }
}

/// Aggregates language/domain evidence over a bounded sliding window and
/// applies separate enter/exit thresholds so active domains do not flap
/// when evidence oscillates near a single boundary.
public struct EvidenceAccumulator: Sendable {
    private let configuration: EvidenceAccumulatorConfiguration
    private var history: [EvidenceObservation] = []
    private var activeDomains: Set<String> = []
    private var lastTimestampMilliseconds: Int64?

    public init(configuration: EvidenceAccumulatorConfiguration) {
        self.configuration = configuration
    }

    public mutating func ingest(_ observation: EvidenceObservation) throws -> EvidenceSnapshot {
        if let last = lastTimestampMilliseconds, observation.timestampMilliseconds < last {
            throw TessavakCoreError.invalidConfiguration(
                "observation timestamp \(observation.timestampMilliseconds) precedes previous timestamp \(last)"
            )
        }
        lastTimestampMilliseconds = observation.timestampMilliseconds

        history.append(observation)
        if history.count > configuration.historyLimit {
            history.removeFirst(history.count - configuration.historyLimit)
        }

        let languages = try aggregatedLanguages()
        let domainAggregates = aggregatedDomains()
        applyHysteresis(domainAggregates: domainAggregates)

        return try EvidenceSnapshot(
            languages: languages,
            domains: domainAggregates,
            activeDomains: activeDomains,
            observations: history.count
        )
    }

    public mutating func reset() {
        history = []
        activeDomains = []
        lastTimestampMilliseconds = nil
    }

    private func aggregatedLanguages() throws -> LanguageDistribution {
        var sums: [LanguageTag: Double] = [:]
        for tag in LanguageTag.allCases {
            sums[tag] = history.reduce(0) { $0 + $1.weight * $1.languages[tag] }
        }
        let grandTotal = sums.values.reduce(0, +)
        var normalized: [LanguageTag: Double] = [:]
        for (tag, sum) in sums {
            normalized[tag] = grandTotal > 0 ? sum / grandTotal : 0
        }
        return try LanguageDistribution(values: normalized)
    }

    private func aggregatedDomains() -> [String: Double] {
        let totalWeight = history.reduce(0) { $0 + $1.weight }
        var domainKeys = activeDomains
        for entry in history {
            domainKeys.formUnion(entry.domains.keys)
        }

        var aggregates: [String: Double] = [:]
        for domain in domainKeys {
            let sum = history.reduce(0) { $0 + $1.weight * ($1.domains[domain] ?? 0) }
            aggregates[domain] = totalWeight > 0 ? sum / totalWeight : 0
        }
        return aggregates
    }

    private mutating func applyHysteresis(domainAggregates: [String: Double]) {
        var updated = activeDomains
        for (domain, aggregate) in domainAggregates {
            if updated.contains(domain) {
                if aggregate < configuration.exitThreshold {
                    updated.remove(domain)
                }
            } else if aggregate >= configuration.enterThreshold {
                updated.insert(domain)
            }
        }
        activeDomains = updated
    }
}
