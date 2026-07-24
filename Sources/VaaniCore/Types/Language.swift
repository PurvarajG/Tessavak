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

    /// Swift's `Dictionary` only decodes/encodes as a JSON object when the
    /// key type is literally `String` or `Int`; a `RawRepresentable<String>`
    /// enum key like `LanguageTag` otherwise falls back to an alternating
    /// key/value array. This dynamic `CodingKey` restores object-shaped JSON
    /// (e.g. `{"en": 0.9, "gu": 0.1}`) for both directions.
    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decoded: [LanguageTag: Double] = [:]
        for key in container.allKeys {
            guard let tag = LanguageTag(rawValue: key.stringValue) else {
                throw VaaniCoreError.invalidConfiguration("unknown language tag: \(key.stringValue)")
            }
            decoded[tag] = try container.decode(Double.self, forKey: key)
        }
        try self.init(values: decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (tag, probability) in values {
            guard let key = DynamicCodingKey(stringValue: tag.rawValue) else { continue }
            try container.encode(probability, forKey: key)
        }
    }
}
