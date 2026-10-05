import Foundation

public struct PipelineRequest: Sendable {
    public let observations: [EvidenceObservation]
    public let candidates: [RecognitionCandidate]
    public let outputPolicy: OutputPolicy

    public init(
        observations: [EvidenceObservation],
        candidates: [RecognitionCandidate],
        outputPolicy: OutputPolicy
    ) {
        self.observations = observations
        self.candidates = candidates
        self.outputPolicy = outputPolicy
    }
}

public struct PipelineResult: Codable, Equatable, Sendable {
    public let text: String
    public let route: RouteDecision
    public let selection: ScoredSelection
    public let corrections: [AppliedCorrection]
    public let diagnostics: PipelineDiagnostics

    public init(
        text: String,
        route: RouteDecision,
        selection: ScoredSelection,
        corrections: [AppliedCorrection],
        diagnostics: PipelineDiagnostics
    ) {
        self.text = text
        self.route = route
        self.selection = selection
        self.corrections = corrections
        self.diagnostics = diagnostics
    }
}

/// Composes detection, routing, scoring, correction, and output rendering
/// into one deterministic offline pipeline. A fresh evidence accumulator is
/// created for every `process` call so separate requests never leak
/// evidence history into one another; persistent multi-turn context belongs
/// in a later session-scoped API.
public struct TessavakPipeline: Sendable {
    private let accumulatorConfiguration: EvidenceAccumulatorConfiguration
    private let router: AdaptiveRouter
    private let scorer: CandidateScorer
    private let correctionEngine: CorrectionEngine
    private let renderer: OutputRenderer

    /// Canonical, protected terminology terms known to this pipeline's
    /// pack. Exposed so external evaluation tooling (e.g. TessavakBench) can
    /// compute protected-term and false-domain-correction metrics without
    /// re-deriving the terminology pack itself.
    public let protectedTerms: Set<String>

    public init(
        accumulatorConfiguration: EvidenceAccumulatorConfiguration,
        routingPolicy: RoutingPolicy,
        scoringWeights: ScoringWeights = .default,
        terminologyPack: TerminologyPack
    ) throws {
        self.accumulatorConfiguration = accumulatorConfiguration
        self.router = AdaptiveRouter(policy: routingPolicy)
        self.scorer = try CandidateScorer(
            weights: scoringWeights,
            latencyBudgetMilliseconds: routingPolicy.latencyBudgetMilliseconds
        )
        self.correctionEngine = CorrectionEngine(pack: terminologyPack)
        self.renderer = OutputRenderer(pack: terminologyPack)
        self.protectedTerms = Set(terminologyPack.entries.filter(\.protected).map(\.canonical))
    }

    public func process(_ request: PipelineRequest) throws -> PipelineResult {
        var accumulator = EvidenceAccumulator(configuration: accumulatorConfiguration)
        var snapshot: EvidenceSnapshot?
        for observation in request.observations {
            snapshot = try accumulator.ingest(observation)
        }
        guard let evidence = snapshot else {
            throw TessavakCoreError.invalidConfiguration("pipeline request must include at least one observation")
        }

        var events: [DiagnosticEvent] = []

        let routeDecision = router.decide(evidence: evidence)
        events.append(
            try DiagnosticEvent(
                code: decisionCode(for: routeDecision.route),
                elapsedMilliseconds: 0,
                attributes: ["route": routeDecision.route.rawValue]
            )
        )

        let selection = try scorer.select(
            from: request.candidates, evidence: evidence, protectedTerms: protectedTerms
        )
        events.append(
            try DiagnosticEvent(
                code: .candidateSelected,
                elapsedMilliseconds: 0,
                attributes: ["model": selection.selected.model.name]
            )
        )

        let correctionResult = correctionEngine.correct(selection.selected.text)
        events.append(
            try DiagnosticEvent(
                code: .deterministicCorrectionApplied,
                elapsedMilliseconds: 0,
                attributes: ["correctionCount": String(correctionResult.corrections.count)]
            )
        )

        let renderedText = try renderer.render(correctionResult.text, policy: request.outputPolicy)
        events.append(
            try DiagnosticEvent(
                code: .outputPolicyApplied,
                elapsedMilliseconds: 0,
                attributes: ["policy": request.outputPolicy.rawValue]
            )
        )

        return PipelineResult(
            text: renderedText,
            route: routeDecision,
            selection: selection,
            corrections: correctionResult.corrections,
            diagnostics: PipelineDiagnostics(events: events)
        )
    }

    private func decisionCode(for route: Route) -> DecisionCode {
        switch route {
        case .englishStreaming: return .routePrimaryEnglish
        case .multilingual: return .routePrimaryMultilingual
        case .dual: return .routeDual
        }
    }
}
