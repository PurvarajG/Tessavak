import Testing

@testable import VaaniCore

@Suite struct AdaptiveRouterTests {

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
        let languages = try LanguageDistribution(values: values)
        return try EvidenceSnapshot(languages: languages, domains: [:], activeDomains: activeDomains, observations: 1)
    }

    @Test func confidentEnglishRoutesToEnglishStreaming() throws {
        let router = AdaptiveRouter(policy: try policy())
        let evidence = try snapshot(languages: [.english: 0.92, .mixed: 0.03, .other: 0.05])
        let decision = router.decide(evidence: evidence)
        #expect(decision.route == .englishStreaming)
        #expect(decision.reasons == ["dominant=en:0.920", "domain=none", "mixed=0.030"])
    }

    @Test func confidentGujaratiRoutesToMultilingual() throws {
        let router = AdaptiveRouter(policy: try policy())
        let evidence = try snapshot(languages: [.english: 0.05, .gujarati: 0.90, .mixed: 0.02, .other: 0.03])
        let decision = router.decide(evidence: evidence)
        #expect(decision.route == .multilingual)
        #expect(decision.reasons[0] == "dominant=gu:0.900")
    }

    @Test func mixedEvidenceRoutesToDual() throws {
        let router = AdaptiveRouter(policy: try policy())
        let evidence = try snapshot(languages: [.english: 0.5, .gujarati: 0.3, .mixed: 0.2])
        let decision = router.decide(evidence: evidence)
        #expect(decision.route == .dual)
    }

    @Test func activeDomainForcesDualEvenWithConfidentEnglish() throws {
        let router = AdaptiveRouter(policy: try policy())
        let evidence = try snapshot(
            languages: [.english: 0.95, .mixed: 0.01, .other: 0.04],
            activeDomains: ["baps"]
        )
        let decision = router.decide(evidence: evidence)
        #expect(decision.route == .dual)
        #expect(decision.reasons[1] == "domain=baps")
    }

    @Test func mixedAtSecondDecodeThresholdForcesDual() throws {
        // english (0.85) meets confidentLanguageThreshold exactly, but mixed
        // (0.15) is not strictly below secondDecodeThreshold (0.15).
        let router = AdaptiveRouter(policy: try policy())
        let evidence = try snapshot(languages: [.english: 0.85, .mixed: 0.15])
        let decision = router.decide(evidence: evidence)
        #expect(decision.route == .dual)
    }

    @Test func multipleActiveDomainsAreSortedInReason() throws {
        let router = AdaptiveRouter(policy: try policy())
        let evidence = try snapshot(
            languages: [.gujarati: 0.9, .other: 0.1],
            activeDomains: ["zeta", "baps"]
        )
        let decision = router.decide(evidence: evidence)
        #expect(decision.reasons[1] == "domain=baps,zeta")
    }

    @Test func routingPolicyRejectsOutOfRangeConfidentThreshold() {
        #expect(throws: (any Error).self) {
            try RoutingPolicy(
                mode: .interactive,
                confidentLanguageThreshold: 1.5,
                secondDecodeThreshold: 0.1,
                latencyBudgetMilliseconds: 500
            )
        }
    }

    @Test func routingPolicyRejectsOutOfRangeSecondDecodeThreshold() {
        #expect(throws: (any Error).self) {
            try RoutingPolicy(
                mode: .interactive,
                confidentLanguageThreshold: 0.8,
                secondDecodeThreshold: -0.1,
                latencyBudgetMilliseconds: 500
            )
        }
    }

    @Test func routingPolicyRejectsNonPositiveLatencyBudget() {
        #expect(throws: (any Error).self) {
            try RoutingPolicy(
                mode: .interactive,
                confidentLanguageThreshold: 0.8,
                secondDecodeThreshold: 0.1,
                latencyBudgetMilliseconds: 0
            )
        }
    }
}
