import Foundation

public enum Route: String, Codable, Equatable, Sendable {
    case englishStreaming, multilingual, dual
}

public struct RouteDecision: Codable, Equatable, Sendable {
    public let route: Route
    public let reasons: [String]

    public init(route: Route, reasons: [String]) {
        self.route = route
        self.reasons = reasons
    }
}

/// Selects a recognition route from accumulated evidence using the injected
/// routing policy thresholds. Reasons are always emitted in a fixed order so
/// callers and diagnostics can rely on positional meaning.
public struct AdaptiveRouter: Sendable {
    private let policy: RoutingPolicy

    public init(policy: RoutingPolicy) {
        self.policy = policy
    }

    public func decide(evidence: EvidenceSnapshot) -> RouteDecision {
        let dominant = evidence.languages.dominant
        let mixedProbability = evidence.languages[.mixed]
        let hasActiveDomain = !evidence.activeDomains.isEmpty

        let domainReason: String
        if evidence.activeDomains.isEmpty {
            domainReason = "domain=none"
        } else {
            domainReason = "domain=" + evidence.activeDomains.sorted().joined(separator: ",")
        }

        let reasons = [
            "dominant=\(dominant.language.rawValue):\(Self.format3(dominant.probability))",
            domainReason,
            "mixed=\(Self.format3(mixedProbability))",
        ]

        // Mixed evidence at or above the second-decode threshold forces dual
        // decoding regardless of dominant language: no single-model route
        // may be returned on ambiguous evidence, for English or Gujarati.
        let route: Route
        if mixedProbability >= policy.secondDecodeThreshold {
            route = .dual
        } else if dominant.language == .english,
            dominant.probability >= policy.confidentLanguageThreshold,
            !hasActiveDomain
        {
            route = .englishStreaming
        } else if dominant.language == .gujarati,
            dominant.probability >= policy.confidentLanguageThreshold
        {
            route = .multilingual
        } else {
            route = .dual
        }

        return RouteDecision(route: route, reasons: reasons)
    }

    private static func format3(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
