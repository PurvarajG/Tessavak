import Testing

@testable import VaaniCore

@Suite struct RoutingPlanTests {

    private func policy(
        mode: RoutingPolicy.Mode = .interactive,
        confidentLanguageThreshold: Double = 0.85,
        secondDecodeThreshold: Double = 0.15,
        latencyBudgetMilliseconds: Int = 500
    ) throws -> RoutingPolicy {
        try RoutingPolicy(
            mode: mode,
            confidentLanguageThreshold: confidentLanguageThreshold,
            secondDecodeThreshold: secondDecodeThreshold,
            latencyBudgetMilliseconds: latencyBudgetMilliseconds
        )
    }

    private func snapshot(
        languages values: [LanguageTag: Double],
        activeDomains: Set<String> = []
    ) throws -> EvidenceSnapshot {
        let domains = Dictionary(uniqueKeysWithValues: activeDomains.map { ($0, 1.0) })
        return try EvidenceSnapshot(
            languages: try LanguageDistribution(values: values),
            domains: domains,
            activeDomains: activeDomains,
            observations: 1
        )
    }

    // MARK: - RoutingPlan invariants

    @Test func planRejectsNonPositiveBudget() throws {
        #expect(throws: (any Error).self) {
            try RoutingPlan(
                primary: .englishStreaming,
                secondary: nil,
                secondaryTrigger: .never,
                latencyBudgetMilliseconds: 0,
                policy: .interactive
            )
        }
    }

    @Test func planRejectsSecondaryWithoutTrigger() throws {
        #expect(throws: (any Error).self) {
            try RoutingPlan(
                primary: .englishStreaming,
                secondary: .multilingual,
                secondaryTrigger: .never,
                latencyBudgetMilliseconds: 500,
                policy: .interactive
            )
        }
    }

    @Test func planRejectsTriggerWithoutSecondary() throws {
        #expect(throws: (any Error).self) {
            try RoutingPlan(
                primary: .englishStreaming,
                secondary: nil,
                secondaryTrigger: .immediately,
                latencyBudgetMilliseconds: 500,
                policy: .interactive
            )
        }
    }

    @Test func planRejectsSecondaryEqualToPrimary() throws {
        #expect(throws: (any Error).self) {
            try RoutingPlan(
                primary: .multilingual,
                secondary: .multilingual,
                secondaryTrigger: .immediately,
                latencyBudgetMilliseconds: 500,
                policy: .interactive
            )
        }
    }

    @Test func planRejectsOutOfRangeConfidenceThreshold() throws {
        #expect(throws: (any Error).self) {
            try RoutingPlan(
                primary: .englishStreaming,
                secondary: .multilingual,
                secondaryTrigger: .onLowConfidence(threshold: 1.5),
                latencyBudgetMilliseconds: 500,
                policy: .interactive
            )
        }
    }

    @Test func planAcceptsSingleRouteConfiguration() throws {
        let plan = try RoutingPlan(
            primary: .englishStreaming,
            secondary: nil,
            secondaryTrigger: .never,
            latencyBudgetMilliseconds: 500,
            policy: .interactive
        )
        #expect(plan.secondary == nil)
        #expect(plan.secondaryTrigger == .never)
        #expect(plan.latencyBudgetMilliseconds == 500)
    }

    // MARK: - Budgets

    @Test func interactiveBudgetIsTighterThanMeeting() {
        let budgets = SessionBudgets.default
        #expect(budgets.milliseconds(for: .interactive) < budgets.milliseconds(for: .meeting))
        for mode in [RoutingPolicy.Mode.interactive, .meeting, .verbatim, .evaluation] {
            #expect(budgets.milliseconds(for: mode) > 0)
        }
    }

    @Test func budgetsRejectNonPositiveValues() {
        #expect(throws: (any Error).self) {
            try SessionBudgets(interactive: 0, meeting: 2_500, verbatim: 2_500, evaluation: 10_000)
        }
        #expect(throws: (any Error).self) {
            try SessionBudgets(interactive: 800, meeting: -1, verbatim: 2_500, evaluation: 10_000)
        }
    }

    // MARK: - AdaptiveRouter.plan(for:policy:)

    @Test func confidentEnglishPlansSingleRoute() throws {
        let router = AdaptiveRouter(policy: try policy())
        let plan = try router.plan(
            for: try snapshot(languages: [.english: 0.92, .mixed: 0.03, .other: 0.05]),
            policy: .interactive
        )
        #expect(plan.primary == .englishStreaming)
        #expect(plan.secondary == nil)
        #expect(plan.secondaryTrigger == .never)
        #expect(plan.policy == .interactive)
    }

    @Test func confidentGujaratiPlansSingleMultilingualRoute() throws {
        let router = AdaptiveRouter(policy: try policy())
        let plan = try router.plan(
            for: try snapshot(languages: [.gujarati: 0.9, .mixed: 0.05, .other: 0.05]),
            policy: .meeting
        )
        #expect(plan.primary == .multilingual)
        #expect(plan.secondary == nil)
        #expect(plan.secondaryTrigger == .never)
    }

    @Test func mixedEvidencePlansDualWithLowConfidenceTrigger() throws {
        let configured = try policy()
        let router = AdaptiveRouter(policy: configured)
        let plan = try router.plan(
            for: try snapshot(languages: [.english: 0.55, .mixed: 0.4, .other: 0.05]),
            policy: .interactive
        )
        #expect(plan.primary == .englishStreaming)
        #expect(plan.secondary == .multilingual)
        #expect(
            plan.secondaryTrigger == .onLowConfidence(threshold: configured.confidentLanguageThreshold)
        )
    }

    @Test func mixedGujaratiDominantPlansMultilingualFirst() throws {
        let router = AdaptiveRouter(policy: try policy())
        let plan = try router.plan(
            for: try snapshot(languages: [.gujarati: 0.55, .mixed: 0.4, .other: 0.05]),
            policy: .interactive
        )
        #expect(plan.primary == .multilingual)
        #expect(plan.secondary == .englishStreaming)
    }

    @Test func uncertainEvidencePlansDual() throws {
        let router = AdaptiveRouter(policy: try policy())
        let plan = try router.plan(
            for: try snapshot(languages: [.english: 0.5, .gujarati: 0.45, .other: 0.05]),
            policy: .interactive
        )
        #expect(plan.secondary != nil)
        #expect(plan.secondaryTrigger != .never)
    }

    @Test func evaluationPolicyRunsSecondaryImmediately() throws {
        let router = AdaptiveRouter(policy: try policy(mode: .evaluation))
        let plan = try router.plan(
            for: try snapshot(languages: [.english: 0.55, .mixed: 0.4, .other: 0.05]),
            policy: .evaluation
        )
        #expect(plan.secondaryTrigger == .immediately)
    }

    @Test func budgetFollowsSessionPolicy() throws {
        let router = AdaptiveRouter(policy: try policy())
        let evidence = try snapshot(languages: [.english: 0.92, .mixed: 0.03, .other: 0.05])
        let interactive = try router.plan(for: evidence, policy: .interactive)
        let meeting = try router.plan(for: evidence, policy: .meeting)
        #expect(interactive.latencyBudgetMilliseconds == SessionBudgets.default.milliseconds(for: .interactive))
        #expect(meeting.latencyBudgetMilliseconds == SessionBudgets.default.milliseconds(for: .meeting))
        #expect(interactive.latencyBudgetMilliseconds < meeting.latencyBudgetMilliseconds)
    }

    @Test func injectedBudgetsOverrideDefaults() throws {
        let budgets = try SessionBudgets(
            interactive: 250, meeting: 1_000, verbatim: 1_000, evaluation: 5_000
        )
        let router = AdaptiveRouter(policy: try policy(), budgets: budgets)
        let plan = try router.plan(
            for: try snapshot(languages: [.english: 0.92, .mixed: 0.03, .other: 0.05]),
            policy: .interactive
        )
        #expect(plan.latencyBudgetMilliseconds == 250)
    }

    @Test func planDoesNotChangeExistingRouteDecision() throws {
        let router = AdaptiveRouter(policy: try policy())
        let evidence = try snapshot(languages: [.english: 0.55, .mixed: 0.4, .other: 0.05])
        #expect(router.decide(evidence: evidence).route == .dual)
        // The plan splits that dual decision into ordered routes without
        // altering the decision itself.
        #expect(try router.plan(for: evidence, policy: .interactive).primary == .englishStreaming)
    }
}
