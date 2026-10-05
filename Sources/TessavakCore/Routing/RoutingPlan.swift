import Foundation

/// The session-level intent a plan is built for. These are the design-spec §7
/// policies; `RoutingPolicy.Mode` already names them, so the plan reuses that
/// type rather than introducing a parallel enum.
public typealias SessionPolicy = RoutingPolicy.Mode

/// When, if ever, the secondary route runs.
public enum SecondaryTrigger: Equatable, Sendable {
    case never
    case onLowConfidence(threshold: Double)
    case immediately
}

/// Per-policy latency budgets for one utterance, end to end.
///
/// These are configuration, not measurements: `interactive` is the tightest
/// because design spec §14 targets fast finalisation for dictation, while
/// `meeting` and `verbatim` trade latency for accuracy and `evaluation` runs
/// with the budget effectively out of the way.
public struct SessionBudgets: Codable, Equatable, Sendable {
    public static let `default` = SessionBudgets(
        uncheckedInteractive: 800,
        meeting: 2_500,
        verbatim: 2_500,
        evaluation: 10_000
    )

    public let interactive: Int
    public let meeting: Int
    public let verbatim: Int
    public let evaluation: Int

    public init(interactive: Int, meeting: Int, verbatim: Int, evaluation: Int) throws {
        for (name, value) in [
            ("interactive", interactive), ("meeting", meeting),
            ("verbatim", verbatim), ("evaluation", evaluation),
        ] {
            guard value > 0 else {
                throw TessavakCoreError.invalidConfiguration(
                    "\(name) latency budget must be positive, got \(value)"
                )
            }
        }
        self.interactive = interactive
        self.meeting = meeting
        self.verbatim = verbatim
        self.evaluation = evaluation
    }

    private init(uncheckedInteractive: Int, meeting: Int, verbatim: Int, evaluation: Int) {
        self.interactive = uncheckedInteractive
        self.meeting = meeting
        self.verbatim = verbatim
        self.evaluation = evaluation
    }

    public func milliseconds(for policy: SessionPolicy) -> Int {
        switch policy {
        case .interactive: return interactive
        case .meeting: return meeting
        case .verbatim: return verbatim
        case .evaluation: return evaluation
        }
    }

    private enum CodingKeys: String, CodingKey {
        case interactive, meeting, verbatim, evaluation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            interactive: try container.decode(Int.self, forKey: .interactive),
            meeting: try container.decode(Int.self, forKey: .meeting),
            verbatim: try container.decode(Int.self, forKey: .verbatim),
            evaluation: try container.decode(Int.self, forKey: .evaluation)
        )
    }
}

/// An executable form of a `RouteDecision`: which recogniser leads, whether a
/// second one runs and on what condition, and how long the whole utterance may
/// take.
public struct RoutingPlan: Equatable, Sendable {
    public let primary: Route
    public let secondary: Route?
    public let secondaryTrigger: SecondaryTrigger
    public let latencyBudgetMilliseconds: Int
    public let policy: SessionPolicy

    public init(
        primary: Route,
        secondary: Route?,
        secondaryTrigger: SecondaryTrigger,
        latencyBudgetMilliseconds: Int,
        policy: SessionPolicy
    ) throws {
        guard latencyBudgetMilliseconds > 0 else {
            throw TessavakCoreError.invalidConfiguration(
                "latencyBudgetMilliseconds must be positive, got \(latencyBudgetMilliseconds)"
            )
        }
        switch (secondary, secondaryTrigger) {
        case (.some, .never):
            throw TessavakCoreError.invalidConfiguration(
                "a secondary route requires a trigger other than .never"
            )
        case (.none, .onLowConfidence), (.none, .immediately):
            throw TessavakCoreError.invalidConfiguration(
                "a secondary trigger requires a secondary route"
            )
        default:
            break
        }
        if let secondary, secondary == primary {
            throw TessavakCoreError.invalidConfiguration(
                "secondary route must differ from primary route (\(primary.rawValue))"
            )
        }
        if case .onLowConfidence(let threshold) = secondaryTrigger {
            guard threshold >= 0, threshold <= 1 else {
                throw TessavakCoreError.invalidProbability(
                    field: "secondaryTrigger.threshold", value: threshold
                )
            }
        }
        self.primary = primary
        self.secondary = secondary
        self.secondaryTrigger = secondaryTrigger
        self.latencyBudgetMilliseconds = latencyBudgetMilliseconds
        self.policy = policy
    }
}
