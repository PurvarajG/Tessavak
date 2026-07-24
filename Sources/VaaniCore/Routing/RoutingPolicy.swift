import Foundation

public struct RoutingPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case interactive, meeting, verbatim, evaluation
    }

    public let mode: Mode
    public let confidentLanguageThreshold: Double
    public let secondDecodeThreshold: Double
    public let latencyBudgetMilliseconds: Int

    public init(
        mode: Mode,
        confidentLanguageThreshold: Double,
        secondDecodeThreshold: Double,
        latencyBudgetMilliseconds: Int
    ) throws {
        guard confidentLanguageThreshold >= 0, confidentLanguageThreshold <= 1 else {
            throw VaaniCoreError.invalidProbability(
                field: "confidentLanguageThreshold", value: confidentLanguageThreshold
            )
        }
        guard secondDecodeThreshold >= 0, secondDecodeThreshold <= 1 else {
            throw VaaniCoreError.invalidProbability(field: "secondDecodeThreshold", value: secondDecodeThreshold)
        }
        guard latencyBudgetMilliseconds > 0 else {
            throw VaaniCoreError.invalidConfiguration(
                "latencyBudgetMilliseconds must be positive, got \(latencyBudgetMilliseconds)"
            )
        }
        self.mode = mode
        self.confidentLanguageThreshold = confidentLanguageThreshold
        self.secondDecodeThreshold = secondDecodeThreshold
        self.latencyBudgetMilliseconds = latencyBudgetMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case mode, confidentLanguageThreshold, secondDecodeThreshold, latencyBudgetMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: try container.decode(Mode.self, forKey: .mode),
            confidentLanguageThreshold: try container.decode(Double.self, forKey: .confidentLanguageThreshold),
            secondDecodeThreshold: try container.decode(Double.self, forKey: .secondDecodeThreshold),
            latencyBudgetMilliseconds: try container.decode(Int.self, forKey: .latencyBudgetMilliseconds)
        )
    }
}
