import Foundation

// MARK: - Errors

public enum LivePipelineError: Error, Equatable, Sendable {
    case chunkBeforeSpeechStart
    case nonMonotonicTimestamp(previous: Int64, next: Int64)
    case eventAfterEndOfStream
    case noEvidenceObserved
    case noRecognizerAvailable(primary: Route, secondary: Route?)
    case budgetExhaustedWithoutCandidate(budgetMilliseconds: Int)
    case recognitionProducedNoCandidate
}

// MARK: - Deadline

/// Bounds how long an operation may run. Injected so the coordinator's budget
/// behaviour can be tested without waiting on a real clock.
public protocol DeadlineScheduler: Sendable {
    /// Runs `operation`, cancelling it once `milliseconds` elapse. Rethrows
    /// whatever `operation` throws; throws `DeadlineExceeded` if the budget
    /// runs out first.
    func withDeadline<T: Sendable>(
        milliseconds: Int,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T
}

public struct DeadlineExceeded: Error, Equatable, Sendable {
    public let budgetMilliseconds: Int

    public init(budgetMilliseconds: Int) {
        self.budgetMilliseconds = budgetMilliseconds
    }
}

/// Production scheduler: races the operation against `ContinuousClock`.
public struct ContinuousClockDeadlineScheduler: DeadlineScheduler {
    public init() {}

    public func withDeadline<T: Sendable>(
        milliseconds: Int,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(milliseconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DeadlineExceeded(budgetMilliseconds: milliseconds)
            }
            guard let value = first else {
                throw DeadlineExceeded(budgetMilliseconds: milliseconds)
            }
            return value
        }
    }
}

// MARK: - Progress

/// Milestones reached while one utterance is processed.
///
/// Live consumers use these to show provisional state; tests use them to
/// synchronise deterministically, because each milestone is delivered *after*
/// the coordinator has recorded the corresponding state.
public enum LiveProgressEvent: Equatable, Sendable {
    case planReady(RoutingPlan)
    case finalCandidateRecorded(route: Route)
    case secondaryStarted(route: Route)
}

public typealias LiveProgressObserver = @Sendable (LiveProgressEvent) async -> Void

// MARK: - Audio fan-out

/// Buffers an utterance's chunks and replays them to every recogniser that
/// subscribes, so a secondary decode started later still sees the whole
/// utterance.
private actor AudioBroadcast {
    private var buffered: [AudioChunk] = []
    private var continuations: [UUID: AsyncThrowingStream<AudioChunk, Error>.Continuation] = [:]
    private var isFinished = false

    func append(_ chunk: AudioChunk) {
        buffered.append(chunk)
        for continuation in continuations.values {
            continuation.yield(chunk)
        }
    }

    func finish() {
        isFinished = true
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    func subscribe() -> AsyncThrowingStream<AudioChunk, Error> {
        let id = UUID()
        let replay = buffered
        let finished = isFinished
        return AsyncThrowingStream { continuation in
            for chunk in replay {
                continuation.yield(chunk)
            }
            if finished {
                continuation.finish()
                return
            }
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

// MARK: - Coordinator

/// Orchestrates one utterance end to end: detect → route → recognise → score
/// → correct → render.
///
/// A fresh `EvidenceAccumulator` is used per utterance, matching
/// `TessavakPipeline`. All timing is expressed through the injected
/// `DeadlineScheduler`; the coordinator never reads a wall clock itself.
public actor LivePipelineCoordinator {
    private let accumulatorConfiguration: EvidenceAccumulatorConfiguration
    private let router: AdaptiveRouter
    private let scorer: CandidateScorer
    private let correctionEngine: CorrectionEngine
    private let renderer: OutputRenderer
    private let protectedTerms: Set<String>
    private let detector: any Detector
    private let recognizerForRoute: @Sendable (Route) -> (any StreamingRecognizer)?
    private let scheduler: any DeadlineScheduler
    private let progressObserver: LiveProgressObserver?

    /// Final candidates recorded so far, in completion order. Actor-isolated,
    /// so a candidate is always durably recorded before the matching progress
    /// event is delivered.
    private var recordedCandidates: [(route: Route, candidate: RecognitionCandidate)] = []

    public init(
        accumulatorConfiguration: EvidenceAccumulatorConfiguration,
        router: AdaptiveRouter,
        scorer: CandidateScorer,
        correctionEngine: CorrectionEngine,
        renderer: OutputRenderer,
        protectedTerms: Set<String>,
        detector: any Detector,
        recognizerForRoute: @escaping @Sendable (Route) -> (any StreamingRecognizer)?,
        scheduler: any DeadlineScheduler = ContinuousClockDeadlineScheduler(),
        progressObserver: LiveProgressObserver? = nil
    ) {
        self.accumulatorConfiguration = accumulatorConfiguration
        self.router = router
        self.scorer = scorer
        self.correctionEngine = correctionEngine
        self.renderer = renderer
        self.protectedTerms = protectedTerms
        self.detector = detector
        self.recognizerForRoute = recognizerForRoute
        self.scheduler = scheduler
        self.progressObserver = progressObserver
    }

    public func process(
        events: AsyncStream<SpeechEvent>,
        sessionPolicy: SessionPolicy,
        outputPolicy: OutputPolicy
    ) async throws -> PipelineResult {
        recordedCandidates = []

        var diagnostics: [DiagnosticEvent] = []
        var accumulator = EvidenceAccumulator(configuration: accumulatorConfiguration)
        var snapshot: EvidenceSnapshot?
        var speechStarted = false
        var streamClosed = false
        var lastTimestamp: Int64 = -1

        let broadcast = AudioBroadcast()

        for await event in events {
            guard !streamClosed else {
                throw LivePipelineError.eventAfterEndOfStream
            }

            switch event {
            case .speechStarted(let milliseconds):
                try Self.requireMonotonic(previous: lastTimestamp, next: milliseconds)
                lastTimestamp = milliseconds
                speechStarted = true

            case .chunk(let chunk):
                guard speechStarted else {
                    throw LivePipelineError.chunkBeforeSpeechStart
                }
                try Self.requireMonotonic(previous: lastTimestamp, next: chunk.startMilliseconds)
                lastTimestamp = chunk.endMilliseconds
                await broadcast.append(chunk)

            case .speechEnded(let milliseconds):
                try Self.requireMonotonic(previous: lastTimestamp, next: milliseconds)
                lastTimestamp = milliseconds

            case .endOfStream:
                streamClosed = true
            }

            for observation in try await detector.observations(for: event, provisionalText: nil) {
                snapshot = try accumulator.ingest(observation)
            }
        }

        await broadcast.finish()

        guard let evidence = snapshot else {
            throw LivePipelineError.noEvidenceObserved
        }

        let decision = router.decide(evidence: evidence)
        let plan = try router.plan(for: evidence, policy: sessionPolicy)
        diagnostics.append(
            try DiagnosticEvent(
                code: Self.decisionCode(for: decision.route),
                elapsedMilliseconds: 0,
                attributes: ["route": decision.route.rawValue, "plannedPrimary": plan.primary.rawValue]
            )
        )
        await progressObserver?(.planReady(plan))

        let execution = try resolveExecution(for: plan)
        if execution.isDegraded {
            diagnostics.append(
                try DiagnosticEvent(
                    code: .degradedFallback,
                    elapsedMilliseconds: 0,
                    attributes: ["reason": "recognizerUnavailable", "route": execution.primaryRoute.rawValue]
                )
            )
        }

        let budgetOutcome = await runRecognition(
            plan: plan,
            execution: execution,
            broadcast: broadcast
        )
        diagnostics.append(contentsOf: try budgetOutcome.diagnostics())

        let candidates = recordedCandidates.map(\.candidate)
        guard !candidates.isEmpty else {
            if case .exhausted = budgetOutcome.budget {
                throw LivePipelineError.budgetExhaustedWithoutCandidate(
                    budgetMilliseconds: plan.latencyBudgetMilliseconds
                )
            }
            throw LivePipelineError.recognitionProducedNoCandidate
        }

        let selection = try scorer.select(
            from: candidates, evidence: evidence, protectedTerms: protectedTerms
        )
        diagnostics.append(
            try DiagnosticEvent(
                code: .candidateSelected,
                elapsedMilliseconds: 0,
                attributes: ["model": selection.selected.model.name]
            )
        )

        let corrected = correctionEngine.correct(selection.selected.text)
        diagnostics.append(
            try DiagnosticEvent(
                code: .deterministicCorrectionApplied,
                elapsedMilliseconds: 0,
                attributes: ["correctionCount": String(corrected.corrections.count)]
            )
        )

        let renderedText = try renderer.render(corrected.text, policy: outputPolicy)
        diagnostics.append(
            try DiagnosticEvent(
                code: .outputPolicyApplied,
                elapsedMilliseconds: 0,
                attributes: ["policy": outputPolicy.rawValue]
            )
        )

        return PipelineResult(
            text: renderedText,
            route: decision,
            selection: selection,
            corrections: corrected.corrections,
            diagnostics: PipelineDiagnostics(events: diagnostics)
        )
    }

    // MARK: - Recognition

    private struct Execution {
        let primaryRoute: Route
        let primary: any StreamingRecognizer
        let secondaryRoute: Route?
        let secondary: (any StreamingRecognizer)?
        let isDegraded: Bool
    }

    private struct RecognitionOutcome {
        enum Budget {
            case respected
            case exhausted(milliseconds: Int)
        }

        let budget: Budget
        let secondaryRan: Bool
        let primaryFailed: Bool

        func diagnostics() throws -> [DiagnosticEvent] {
            var events: [DiagnosticEvent] = []
            switch budget {
            case .respected:
                events.append(
                    try DiagnosticEvent(
                        code: .budgetRespected, elapsedMilliseconds: 0, attributes: [:]
                    )
                )
            case .exhausted(let milliseconds):
                events.append(
                    try DiagnosticEvent(
                        code: .budgetExhausted,
                        elapsedMilliseconds: 0,
                        attributes: ["budgetMilliseconds": String(milliseconds)]
                    )
                )
            }
            events.append(
                try DiagnosticEvent(
                    code: secondaryRan ? .secondaryTriggered : .secondarySkipped,
                    elapsedMilliseconds: 0,
                    attributes: [:]
                )
            )
            if primaryFailed {
                events.append(
                    try DiagnosticEvent(
                        code: .degradedFallback,
                        elapsedMilliseconds: 0,
                        attributes: ["reason": "primaryRecognizerFailed"]
                    )
                )
            }
            return events
        }
    }

    /// Resolves the plan's routes to available recognisers, falling back to
    /// the other route when one is missing (design spec §15).
    private func resolveExecution(for plan: RoutingPlan) throws -> Execution {
        let primary = recognizerForRoute(plan.primary)
        let secondary = plan.secondary.flatMap { recognizerForRoute($0) }

        if let primary {
            return Execution(
                primaryRoute: plan.primary,
                primary: primary,
                secondaryRoute: secondary == nil ? nil : plan.secondary,
                secondary: secondary,
                isDegraded: plan.secondary != nil && secondary == nil
            )
        }
        if let secondary, let secondaryRoute = plan.secondary {
            return Execution(
                primaryRoute: secondaryRoute,
                primary: secondary,
                secondaryRoute: nil,
                secondary: nil,
                isDegraded: true
            )
        }
        throw LivePipelineError.noRecognizerAvailable(primary: plan.primary, secondary: plan.secondary)
    }

    private func runRecognition(
        plan: RoutingPlan,
        execution: Execution,
        broadcast: AudioBroadcast
    ) async -> RecognitionOutcome {
        var secondaryRan = false
        var primaryFailed = false

        do {
            let result = try await scheduler.withDeadline(milliseconds: plan.latencyBudgetMilliseconds) {
                [self] in
                var ranSecondary = false
                var failedPrimary = false

                if case .immediately = plan.secondaryTrigger,
                    let secondary = execution.secondary,
                    let secondaryRoute = execution.secondaryRoute
                {
                    ranSecondary = true
                    await progressObserver?(.secondaryStarted(route: secondaryRoute))
                    await withTaskGroup(of: Bool.self) { group in
                        group.addTask { [self] in
                            await consume(
                                recognizer: execution.primary,
                                route: execution.primaryRoute,
                                broadcast: broadcast
                            )
                        }
                        group.addTask { [self] in
                            await consume(
                                recognizer: secondary, route: secondaryRoute, broadcast: broadcast
                            )
                        }
                        for await succeeded in group where !succeeded {
                            failedPrimary = true
                        }
                    }
                    return (ranSecondary, failedPrimary)
                }

                let primarySucceeded = await consume(
                    recognizer: execution.primary,
                    route: execution.primaryRoute,
                    broadcast: broadcast
                )
                failedPrimary = !primarySucceeded

                if let secondary = execution.secondary, let secondaryRoute = execution.secondaryRoute {
                    let shouldRun: Bool
                    switch plan.secondaryTrigger {
                    case .never:
                        shouldRun = false
                    case .immediately:
                        shouldRun = true
                    case .onLowConfidence(let threshold):
                        // A failed primary leaves nothing to compare against,
                        // so the secondary is the fallback path (§15).
                        //
                        // A recogniser that reports no confidence at all does
                        // not trigger a second decode: absence of a signal is
                        // not evidence of a low one. Callers who want both
                        // decoders unconditionally have their own lever —
                        // `.immediately`, which `.evaluation` policy selects.
                        let best = await bestConfidence(for: execution.primaryRoute)
                        shouldRun = !primarySucceeded || (best.map { $0 < threshold } ?? false)
                    }
                    if shouldRun {
                        ranSecondary = true
                        await progressObserver?(.secondaryStarted(route: secondaryRoute))
                        _ = await consume(
                            recognizer: secondary, route: secondaryRoute, broadcast: broadcast
                        )
                    }
                }
                return (ranSecondary, failedPrimary)
            }
            secondaryRan = result.0
            primaryFailed = result.1
            return RecognitionOutcome(
                budget: .respected, secondaryRan: secondaryRan, primaryFailed: primaryFailed
            )
        } catch let exceeded as DeadlineExceeded {
            return RecognitionOutcome(
                budget: .exhausted(milliseconds: exceeded.budgetMilliseconds),
                secondaryRan: secondaryRan,
                primaryFailed: primaryFailed
            )
        } catch {
            // Recognition itself failed outright; recorded candidates (if any)
            // still stand and the caller decides.
            return RecognitionOutcome(
                budget: .respected, secondaryRan: secondaryRan, primaryFailed: true
            )
        }
    }

    /// Consumes one recogniser's updates, recording every final candidate.
    /// Returns `false` if the recogniser failed before producing a final.
    private func consume(
        recognizer: any StreamingRecognizer,
        route: Route,
        broadcast: AudioBroadcast
    ) async -> Bool {
        let audio = await broadcast.subscribe()
        var sawFinal = false
        do {
            for try await update in recognizer.recognize(audio) where update.isFinal {
                record(candidate: update.candidate, route: route)
                sawFinal = true
                await progressObserver?(.finalCandidateRecorded(route: route))
            }
        } catch {
            return false
        }
        return sawFinal
    }

    private func record(candidate: RecognitionCandidate, route: Route) {
        recordedCandidates.append((route: route, candidate: candidate))
    }

    /// Highest confidence recorded for `route`, or `nil` when none of that
    /// route's candidates reported one.
    private func bestConfidence(for route: Route) -> Double? {
        recordedCandidates
            .filter { $0.route == route }
            .compactMap(\.candidate.confidence)
            .max()
    }

    // MARK: - Helpers

    private static func requireMonotonic(previous: Int64, next: Int64) throws {
        guard next >= previous else {
            throw LivePipelineError.nonMonotonicTimestamp(previous: previous, next: next)
        }
    }

    private static func decisionCode(for route: Route) -> DecisionCode {
        switch route {
        case .englishStreaming: return .routePrimaryEnglish
        case .multilingual: return .routePrimaryMultilingual
        case .dual: return .routeDual
        }
    }
}
