import Foundation
import Testing
import VaaniAdapters
import VaaniCore
import VaaniPacks

@testable import VaaniBench

@Suite struct BenchRunnerTests {

    // MARK: - Fixtures

    private func model() throws -> ModelIdentity {
        try ModelIdentity(provider: "replay", name: "test", version: "1")
    }

    private func candidate(id: String, latency: Int) throws -> RecognitionCandidate {
        try RecognitionCandidate(
            id: id,
            text: "irrelevant",
            confidence: 0.9,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: try model(),
            latencyMilliseconds: latency
        )
    }

    private func utterance(
        id: String,
        expectedText: String,
        expectedRoute: Route,
        subset: String
    ) throws -> ReplayUtterance {
        try ReplayUtterance(
            id: id,
            observations: [
                try EvidenceObservation(
                    languages: try LanguageDistribution(values: [.english: 1.0]),
                    domains: [:],
                    source: .recognizer,
                    weight: 1.0,
                    timestampMilliseconds: 0
                )
            ],
            candidates: [try candidate(id: "\(id)-c1", latency: 10)],
            expectedText: expectedText,
            expectedRoute: expectedRoute,
            subset: subset
        )
    }

    private func result(
        text: String,
        route: Route,
        latency: Int,
        corrections: [AppliedCorrection] = []
    ) throws -> PipelineResult {
        let selected = try candidate(id: "sel", latency: latency)
        let score = CandidateScore(
            candidateID: selected.id,
            total: 1.0,
            components: Dictionary(uniqueKeysWithValues: ScoreComponent.allCases.map { ($0, 0.0) })
        )
        return PipelineResult(
            text: text,
            route: RouteDecision(route: route, reasons: []),
            selection: ScoredSelection(selected: selected, scores: [score]),
            corrections: corrections,
            diagnostics: PipelineDiagnostics(events: [])
        )
    }

    // MARK: - computeMetrics

    @Test func exactMatchRateCountsIdenticalText() throws {
        let entries = [
            (
                try utterance(id: "u1", expectedText: "hello", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "hello", route: .englishStreaming, latency: 10)
            ),
            (
                try utterance(id: "u2", expectedText: "world", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "nope", route: .englishStreaming, latency: 10)
            ),
        ]
        let metrics = BenchRunner.computeMetrics(entries, protectedTerms: [])
        #expect(metrics.exactMatchRate == 0.5)
    }

    @Test func routeAccuracyCountsMatchingRoutes() throws {
        let entries = [
            (
                try utterance(id: "u1", expectedText: "a", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "a", route: .englishStreaming, latency: 10)
            ),
            (
                try utterance(id: "u2", expectedText: "b", expectedRoute: .multilingual, subset: "s"),
                try result(text: "b", route: .dual, latency: 10)
            ),
        ]
        let metrics = BenchRunner.computeMetrics(entries, protectedTerms: [])
        #expect(metrics.routeAccuracy == 0.5)
    }

    @Test func dualDecodeRateCountsDualRoutes() throws {
        let entries = [
            (
                try utterance(id: "u1", expectedText: "a", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "a", route: .dual, latency: 10)
            ),
            (
                try utterance(id: "u2", expectedText: "b", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "b", route: .englishStreaming, latency: 10)
            ),
            (
                try utterance(id: "u3", expectedText: "c", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "c", route: .dual, latency: 10)
            ),
        ]
        let metrics = BenchRunner.computeMetrics(entries, protectedTerms: [])
        #expect(abs(metrics.dualDecodeRate - (2.0 / 3.0)) < 1e-9)
    }

    @Test func protectedTermExactMatchRateRequiresCaseExactPresence() throws {
        let protectedTerms: Set<String> = ["BAPS"]
        let entries = [
            (
                try utterance(id: "u1", expectedText: "BAPS talk", expectedRoute: .multilingual, subset: "s"),
                try result(text: "BAPS talk", route: .multilingual, latency: 10)
            ),
            (
                try utterance(id: "u2", expectedText: "BAPS event", expectedRoute: .multilingual, subset: "s"),
                try result(text: "baps event", route: .multilingual, latency: 10)
            ),
        ]
        let metrics = BenchRunner.computeMetrics(entries, protectedTerms: protectedTerms)
        #expect(metrics.protectedTermExactMatchRate == 0.5)
    }

    @Test func protectedTermExactMatchRateIsZeroWhenNoUtteranceHasProtectedTerms() throws {
        let entries = [
            (
                try utterance(id: "u1", expectedText: "hello", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "hello", route: .englishStreaming, latency: 10)
            )
        ]
        let metrics = BenchRunner.computeMetrics(entries, protectedTerms: ["BAPS"])
        #expect(metrics.protectedTermExactMatchRate == 0)
    }

    @Test func falseDomainCorrectionRateCountsUnexpectedCorrections() throws {
        let protectedTerms: Set<String> = ["BAPS"]
        let correction = AppliedCorrection(original: "x", replacement: "y", entryCanonical: "y", rule: "test")
        let entries = [
            (
                try utterance(id: "u1", expectedText: "plain text", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "plain text", route: .englishStreaming, latency: 10, corrections: [correction])
            ),
            (
                try utterance(id: "u2", expectedText: "other text", expectedRoute: .englishStreaming, subset: "s"),
                try result(text: "other text", route: .englishStreaming, latency: 10)
            ),
        ]
        let metrics = BenchRunner.computeMetrics(entries, protectedTerms: protectedTerms)
        #expect(metrics.falseDomainCorrectionRate == 0.5)
    }

    @Test func falseDomainCorrectionRateIgnoresUtterancesWithProtectedTerms() throws {
        let protectedTerms: Set<String> = ["BAPS"]
        let correction = AppliedCorrection(original: "x", replacement: "BAPS", entryCanonical: "BAPS", rule: "test")
        let entries = [
            (
                try utterance(id: "u1", expectedText: "BAPS talk", expectedRoute: .multilingual, subset: "s"),
                try result(text: "BAPS talk", route: .multilingual, latency: 10, corrections: [correction])
            )
        ]
        let metrics = BenchRunner.computeMetrics(entries, protectedTerms: protectedTerms)
        // No plain-English-eligible utterances at all, so the rate must be 0, not NaN.
        #expect(metrics.falseDomainCorrectionRate == 0)
    }

    @Test func medianHandlesOddCount() {
        #expect(BenchRunner.median([3, 1, 2]) == 2)
    }

    @Test func medianHandlesEvenCount() {
        #expect(BenchRunner.median([1, 2, 3, 4]) == 2.5)
    }

    @Test func medianOfEmptyIsZeroNotNaN() {
        let value = BenchRunner.median([])
        #expect(value == 0)
        #expect(!value.isNaN)
    }

    @Test func computeMetricsOnEmptyEntriesIsZeroNotNaN() {
        let metrics = BenchRunner.computeMetrics([], protectedTerms: [])
        #expect(metrics.utteranceCount == 0)
        #expect(metrics.exactMatchRate == 0)
        #expect(metrics.protectedTermExactMatchRate == 0)
        #expect(metrics.falseDomainCorrectionRate == 0)
        #expect(metrics.routeAccuracy == 0)
        #expect(metrics.dualDecodeRate == 0)
        #expect(metrics.medianFinalLatencyMilliseconds == 0)
        #expect(!metrics.exactMatchRate.isNaN)
    }

    // MARK: - Regression comparison

    private func metrics(
        exactMatch: Double = 1.0,
        protectedTerm: Double = 1.0,
        falseDomain: Double = 0.0,
        routeAccuracy: Double = 1.0,
        dualDecode: Double = 0.0
    ) -> BenchMetrics {
        BenchMetrics(
            utteranceCount: 5,
            exactMatchRate: exactMatch,
            protectedTermExactMatchRate: protectedTerm,
            falseDomainCorrectionRate: falseDomain,
            routeAccuracy: routeAccuracy,
            dualDecodeRate: dualDecode,
            medianFinalLatencyMilliseconds: 100
        )
    }

    @Test func noRegressionsWhenMetricsAreEqual() {
        let baseline = metrics()
        let actual = metrics()
        #expect(BenchRunner.compareToBaseline(actual: actual, baseline: baseline).isEmpty)
    }

    @Test func noRegressionsWhenMetricsImprove() {
        let baseline = metrics(exactMatch: 0.8, falseDomain: 0.1, routeAccuracy: 0.8, dualDecode: 0.3)
        let actual = metrics(exactMatch: 0.9, falseDomain: 0.05, routeAccuracy: 0.9, dualDecode: 0.1)
        #expect(BenchRunner.compareToBaseline(actual: actual, baseline: baseline).isEmpty)
    }

    @Test func exactMatchRegressionIsReportedExactly() {
        let baseline = metrics(exactMatch: 0.9)
        let actual = metrics(exactMatch: 0.8)
        let regressions = BenchRunner.compareToBaseline(actual: actual, baseline: baseline)
        #expect(regressions == [Regression(metric: "exactMatchRate", baseline: 0.9, actual: 0.8, allowedDelta: 0)])
    }

    @Test func protectedTermRegressionIsReportedExactly() {
        let baseline = metrics(protectedTerm: 1.0)
        let actual = metrics(protectedTerm: 0.9)
        let regressions = BenchRunner.compareToBaseline(actual: actual, baseline: baseline)
        #expect(
            regressions == [
                Regression(metric: "protectedTermExactMatchRate", baseline: 1.0, actual: 0.9, allowedDelta: 0)
            ]
        )
    }

    @Test func falseDomainCorrectionRegressionIsReportedExactly() {
        let baseline = metrics(falseDomain: 0.0)
        let actual = metrics(falseDomain: 0.1)
        let regressions = BenchRunner.compareToBaseline(actual: actual, baseline: baseline)
        #expect(
            regressions == [
                Regression(metric: "falseDomainCorrectionRate", baseline: 0.0, actual: 0.1, allowedDelta: 0)
            ]
        )
    }

    @Test func routeAccuracyRegressionIsReportedExactly() {
        let baseline = metrics(routeAccuracy: 1.0)
        let actual = metrics(routeAccuracy: 0.8)
        let regressions = BenchRunner.compareToBaseline(actual: actual, baseline: baseline)
        #expect(regressions == [Regression(metric: "routeAccuracy", baseline: 1.0, actual: 0.8, allowedDelta: 0)])
    }

    @Test func dualDecodeRegressionIsReportedExactly() {
        let baseline = metrics(dualDecode: 0.1)
        let actual = metrics(dualDecode: 0.3)
        let regressions = BenchRunner.compareToBaseline(actual: actual, baseline: baseline)
        #expect(regressions == [Regression(metric: "dualDecodeRate", baseline: 0.1, actual: 0.3, allowedDelta: 0)])
    }

    @Test func multipleRegressionsAreSortedByMetricName() {
        let baseline = metrics(exactMatch: 0.9, routeAccuracy: 0.9)
        let actual = metrics(exactMatch: 0.8, routeAccuracy: 0.8)
        let regressions = BenchRunner.compareToBaseline(actual: actual, baseline: baseline)
        #expect(regressions.map(\.metric) == ["exactMatchRate", "routeAccuracy"])
    }

    // MARK: - Integration against the checked-in smoke fixture

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func makePipeline() throws -> VaaniPipeline {
        let pack = try PackLoader.bundledBAPSGujarati()
        let routingPolicy = try RoutingPolicy(
            mode: .evaluation,
            confidentLanguageThreshold: 0.85,
            secondDecodeThreshold: 0.15,
            latencyBudgetMilliseconds: 500
        )
        let accumulatorConfiguration = try EvidenceAccumulatorConfiguration(
            enterThreshold: 0.6, exitThreshold: 0.3, historyLimit: 5
        )
        return try VaaniPipeline(
            accumulatorConfiguration: accumulatorConfiguration,
            routingPolicy: routingPolicy,
            terminologyPack: pack
        )
    }

    @Test func smokeFixtureProducesExpectedGoldenReport() throws {
        let manifestData = try Data(contentsOf: fixtureURL("Fixtures/replay/smoke.json"))
        let manifest = try JSONDecoder().decode(ReplayManifest.self, from: manifestData)

        let runner = BenchRunner(pipeline: try makePipeline())
        let report = try runner.run(manifest, baseline: nil)

        let expectedData = try Data(contentsOf: fixtureURL("Fixtures/expected/smoke-report.json"))
        let expected = try JSONDecoder().decode(BenchReport.self, from: expectedData)

        #expect(report == expected)
        // The report must never leak transcript text; only the manifest hash,
        // metrics, and regressions are present.
        let reportText = String(data: try report.renderJSON(), encoding: .utf8) ?? ""
        #expect(!reportText.contains("Pramukh Swami Maharaj gave a talk on Vachanamrut"))
        #expect(!reportText.contains("pramukh swami maharaj"))
    }

    @Test func rejectsManifestFilesLargerThanSizeLimit() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaanicore-oversized-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let oversized = Data(repeating: 0x20, count: 64 * 1024 * 1024 + 1)
        try oversized.write(to: tempURL)
        #expect(throws: (any Error).self) {
            _ = try BenchManifestLoader.load(fromPath: tempURL.path)
        }
    }

    @Test func smokeFixturePassesCheckedInBaselineWithNoRegressions() throws {
        let manifestData = try Data(contentsOf: fixtureURL("Fixtures/replay/smoke.json"))
        let manifest = try JSONDecoder().decode(ReplayManifest.self, from: manifestData)
        let baseline = try BenchReport.load(fromPath: fixtureURL("Fixtures/baseline/smoke-baseline.json").path)

        let runner = BenchRunner(pipeline: try makePipeline())
        let report = try runner.run(manifest, baseline: baseline)

        #expect(report.regressions.isEmpty)
    }
}
