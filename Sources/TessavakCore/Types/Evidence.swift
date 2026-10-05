import Foundation

public enum EvidenceSource: String, Codable, Sendable {
    case acousticLanguageID, recognizer, unicodeScript, romanGujarati
    case terminology, recentContext, applicationProfile, explicitMode, userCorrection
}

public struct EvidenceObservation: Codable, Equatable, Sendable {
    public let languages: LanguageDistribution
    public let domains: [String: Double]
    public let source: EvidenceSource
    public let weight: Double
    public let timestampMilliseconds: Int64

    public init(
        languages: LanguageDistribution,
        domains: [String: Double],
        source: EvidenceSource,
        weight: Double,
        timestampMilliseconds: Int64
    ) throws {
        for (domain, probability) in domains {
            guard probability >= 0, probability <= 1 else {
                throw TessavakCoreError.invalidProbability(field: "domains.\(domain)", value: probability)
            }
        }
        guard weight > 0 else {
            throw TessavakCoreError.invalidConfiguration("observation weight must be positive, got \(weight)")
        }
        guard timestampMilliseconds >= 0 else {
            throw TessavakCoreError.invalidConfiguration(
                "timestampMilliseconds must be non-negative, got \(timestampMilliseconds)"
            )
        }
        self.languages = languages
        self.domains = domains
        self.source = source
        self.weight = weight
        self.timestampMilliseconds = timestampMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case languages, domains, source, weight, timestampMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            languages: try container.decode(LanguageDistribution.self, forKey: .languages),
            domains: try container.decode([String: Double].self, forKey: .domains),
            source: try container.decode(EvidenceSource.self, forKey: .source),
            weight: try container.decode(Double.self, forKey: .weight),
            timestampMilliseconds: try container.decode(Int64.self, forKey: .timestampMilliseconds)
        )
    }
}

public struct EvidenceSnapshot: Codable, Equatable, Sendable {
    public let languages: LanguageDistribution
    public let domains: [String: Double]
    public let activeDomains: Set<String>
    public let observations: Int

    public init(
        languages: LanguageDistribution,
        domains: [String: Double],
        activeDomains: Set<String>,
        observations: Int
    ) throws {
        for (domain, probability) in domains {
            guard probability >= 0, probability <= 1 else {
                throw TessavakCoreError.invalidProbability(field: "domains.\(domain)", value: probability)
            }
        }
        guard observations >= 0 else {
            throw TessavakCoreError.invalidConfiguration("observations must be non-negative, got \(observations)")
        }
        let unknownDomains = activeDomains.subtracting(domains.keys)
        guard unknownDomains.isEmpty else {
            throw TessavakCoreError.invalidConfiguration(
                "activeDomains contains domain(s) not present in domains: \(unknownDomains.sorted().joined(separator: ", "))"
            )
        }
        self.languages = languages
        self.domains = domains
        self.activeDomains = activeDomains
        self.observations = observations
    }

    private enum CodingKeys: String, CodingKey {
        case languages, domains, activeDomains, observations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            languages: try container.decode(LanguageDistribution.self, forKey: .languages),
            domains: try container.decode([String: Double].self, forKey: .domains),
            activeDomains: try container.decode(Set<String>.self, forKey: .activeDomains),
            observations: try container.decode(Int.self, forKey: .observations)
        )
    }
}
