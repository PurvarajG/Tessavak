import Foundation

public enum VaaniCoreError: Error, Equatable, Sendable {
    case invalidProbability(field: String, value: Double)
    case invalidDistributionSum(Double)
    case invalidTimeRange(start: Int64, end: Int64)
    case sensitiveDiagnosticAttribute(String)
    case invalidConfiguration(String)
}

public enum LanguageTag: String, Codable, CaseIterable, Hashable, Sendable {
    case english = "en"
    case gujarati = "gu"
    case hindi = "hi"
    case mixed
    case other
}

public struct LanguageDistribution: Codable, Equatable, Sendable {
    private static let sumTolerance = 0.000_001

    public let values: [LanguageTag: Double]

    public init(values: [LanguageTag: Double]) throws {
        for (tag, probability) in values {
            guard probability >= 0, probability <= 1 else {
                throw VaaniCoreError.invalidProbability(field: "languages.\(tag.rawValue)", value: probability)
            }
        }
        let sum = values.values.reduce(0, +)
        guard abs(sum - 1) <= Self.sumTolerance else {
            throw VaaniCoreError.invalidDistributionSum(sum)
        }
        self.values = values
    }

    public subscript(_ language: LanguageTag) -> Double {
        values[language] ?? 0
    }

    public var dominant: (language: LanguageTag, probability: Double) {
        let ranked = values.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key.rawValue < rhs.key.rawValue
        }
        guard let top = ranked.first else {
            return (.other, 0)
        }
        return (top.key, top.value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([LanguageTag: Double].self)
        try self.init(values: decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}
