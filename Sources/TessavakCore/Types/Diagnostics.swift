import Foundation

public enum DecisionCode: String, Codable, Sendable {
    case routePrimaryEnglish, routePrimaryMultilingual, routeDual
    case candidateSelected, deterministicCorrectionApplied, outputPolicyApplied
    case degradedFallback
    case secondaryTriggered, secondarySkipped
    case budgetRespected, budgetExhausted
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public static let sensitiveAttributeKeys: Set<String> = ["text", "transcript", "audio", "rawCandidate"]

    public let code: DecisionCode
    public let elapsedMilliseconds: Int
    public let attributes: [String: String]

    public init(
        code: DecisionCode,
        elapsedMilliseconds: Int,
        attributes: [String: String]
    ) throws {
        guard elapsedMilliseconds >= 0 else {
            throw TessavakCoreError.invalidConfiguration(
                "elapsedMilliseconds must be non-negative, got \(elapsedMilliseconds)"
            )
        }
        for key in attributes.keys {
            guard !Self.sensitiveAttributeKeys.contains(key) else {
                throw TessavakCoreError.sensitiveDiagnosticAttribute(key)
            }
        }
        self.code = code
        self.elapsedMilliseconds = elapsedMilliseconds
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey {
        case code, elapsedMilliseconds, attributes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            code: try container.decode(DecisionCode.self, forKey: .code),
            elapsedMilliseconds: try container.decode(Int.self, forKey: .elapsedMilliseconds),
            attributes: try container.decode([String: String].self, forKey: .attributes)
        )
    }
}

public struct PipelineDiagnostics: Codable, Equatable, Sendable {
    public let events: [DiagnosticEvent]

    public init(events: [DiagnosticEvent]) {
        self.events = events
    }
}
