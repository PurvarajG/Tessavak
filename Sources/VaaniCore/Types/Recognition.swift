import Foundation

public struct RecognitionSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let confidence: Double?

    public init(
        text: String,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        confidence: Double?
    ) throws {
        guard startMilliseconds >= 0, endMilliseconds >= startMilliseconds else {
            throw VaaniCoreError.invalidTimeRange(start: startMilliseconds, end: endMilliseconds)
        }
        if let confidence {
            guard confidence >= 0, confidence <= 1 else {
                throw VaaniCoreError.invalidProbability(field: "segment.confidence", value: confidence)
            }
        }
        self.text = text
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case text, startMilliseconds, endMilliseconds, confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            text: try container.decode(String.self, forKey: .text),
            startMilliseconds: try container.decode(Int64.self, forKey: .startMilliseconds),
            endMilliseconds: try container.decode(Int64.self, forKey: .endMilliseconds),
            confidence: try container.decodeIfPresent(Double.self, forKey: .confidence)
        )
    }
}

public struct ModelIdentity: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let name: String
    public let version: String

    public init(provider: String, name: String, version: String) throws {
        guard !provider.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("model provider must not be empty")
        }
        guard !name.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("model name must not be empty")
        }
        guard !version.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("model version must not be empty")
        }
        self.provider = provider
        self.name = name
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case provider, name, version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: try container.decode(String.self, forKey: .provider),
            name: try container.decode(String.self, forKey: .name),
            version: try container.decode(String.self, forKey: .version)
        )
    }
}

public struct RecognitionCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    /// `nil` when the recogniser exposes no confidence signal at all — which
    /// is not the same as reporting low confidence. Consumers must treat the
    /// absence as "unknown", never as zero.
    public let confidence: Double?
    public let detectedLanguages: LanguageDistribution
    public let segments: [RecognitionSegment]
    public let model: ModelIdentity
    public let latencyMilliseconds: Int

    public init(
        id: String,
        text: String,
        confidence: Double?,
        detectedLanguages: LanguageDistribution,
        segments: [RecognitionSegment],
        model: ModelIdentity,
        latencyMilliseconds: Int
    ) throws {
        guard !id.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("candidate id must not be empty")
        }
        if let confidence {
            guard confidence >= 0, confidence <= 1 else {
                throw VaaniCoreError.invalidProbability(field: "candidate.confidence", value: confidence)
            }
        }
        guard latencyMilliseconds >= 0 else {
            throw VaaniCoreError.invalidConfiguration(
                "latencyMilliseconds must be non-negative, got \(latencyMilliseconds)"
            )
        }
        var previousEnd: Int64?
        for segment in segments {
            if let previousEnd, segment.startMilliseconds < previousEnd {
                throw VaaniCoreError.invalidTimeRange(start: segment.startMilliseconds, end: previousEnd)
            }
            previousEnd = segment.endMilliseconds
        }
        self.id = id
        self.text = text
        self.confidence = confidence
        self.detectedLanguages = detectedLanguages
        self.segments = segments
        self.model = model
        self.latencyMilliseconds = latencyMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, confidence, detectedLanguages, segments, model, latencyMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            text: try container.decode(String.self, forKey: .text),
            confidence: try container.decodeIfPresent(Double.self, forKey: .confidence),
            detectedLanguages: try container.decode(LanguageDistribution.self, forKey: .detectedLanguages),
            segments: try container.decode([RecognitionSegment].self, forKey: .segments),
            model: try container.decode(ModelIdentity.self, forKey: .model),
            latencyMilliseconds: try container.decode(Int.self, forKey: .latencyMilliseconds)
        )
    }
}
