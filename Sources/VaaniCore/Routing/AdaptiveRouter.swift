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
    private let budgets: SessionBudgets

    public init(policy: RoutingPolicy, budgets: SessionBudgets = .default) {
        self.policy = policy
        self.budgets = budgets
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

    /// Turns the route decision into an executable plan for live recognition.
    ///
    /// Additive: `decide(evidence:)` keeps its exact Phase 1 behaviour, and a
    /// dual decision is what gets split here into an ordered primary and
    /// secondary. The dominant language leads, so the more likely recogniser
    /// produces the first partials.
    public func plan(for evidence: EvidenceSnapshot, policy sessionPolicy: SessionPolicy) throws
        -> RoutingPlan
    {
        let decision = decide(evidence: evidence)
        let budget = budgets.milliseconds(for: sessionPolicy)

        guard decision.route == .dual else {
            return try RoutingPlan(
                primary: decision.route,
                secondary: nil,
                secondaryTrigger: .never,
                latencyBudgetMilliseconds: budget,
                policy: sessionPolicy
            )
        }

        let leadsWithEnglish = evidence.languages.dominant.language == .english
        // Evaluation runs both decoders unconditionally: spec §7 asks for
        // deterministic execution and complete diagnostics, which a
        // confidence-dependent trigger would not give.
        let trigger: SecondaryTrigger =
            sessionPolicy == .evaluation
            ? .immediately
            : .onLowConfidence(threshold: policy.confidentLanguageThreshold)

        return try RoutingPlan(
            primary: leadsWithEnglish ? .englishStreaming : .multilingual,
            secondary: leadsWithEnglish ? .multilingual : .englishStreaming,
            secondaryTrigger: trigger,
            latencyBudgetMilliseconds: budget,
            policy: sessionPolicy
        )
    }

    private static func format3(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
