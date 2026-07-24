import CryptoKit
import Foundation
import VaaniAdapters
import VaaniCore

/// Baseline reports must describe the same corpus as the manifest being
/// evaluated before their metrics can be compared. Any mismatch here means
/// the baseline was recorded against a different manifest and must not be
/// used to gate regressions.
public enum BaselineCompatibilityError: Error, Equatable, Sendable {
    case schemaMismatch(expected: Int, actual: Int)
    case manifestMismatch(expected: String, actual: String)
    case utteranceCountMismatch(expected: Int, actual: Int)
    case subsetMismatch(expected: Set<String>, actual: Set<String>)
}

/// Runs a replay manifest through a `VaaniPipeline`, aggregates accuracy and
/// routing metrics overall and per subset, and compares against an optional
/// baseline report to detect regressions.
public struct BenchRunner: Sendable {
    private let pipeline: VaaniPipeline

    public init(pipeline: VaaniPipeline) {
        self.pipeline = pipeline
    }

    public func run(_ manifest: ReplayManifest, baseline: BenchReport?) throws -> BenchReport {
        let sha256 = try Self.manifestSHA256(manifest)
        let protectedTerms = pipeline.protectedTerms

        var perUtterance: [(utterance: ReplayUtterance, result: PipelineResult)] = []
        for utterance in manifest.utterances.sorted(by: { $0.id < $1.id }) {
            let request = PipelineRequest(
                observations: utterance.observations,
                candidates: utterance.candidates,
                outputPolicy: .preserveMixed
            )
            let result = try pipeline.process(request)
            perUtterance.append((utterance, result))
        }

        let overall = try Self.computeMetrics(perUtterance, protectedTerms: protectedTerms)

        var subsetGroups: [String: [(utterance: ReplayUtterance, result: PipelineResult)]] = [:]
        for entry in perUtterance {
            subsetGroups[entry.utterance.subset, default: []].append(entry)
        }
        var subsetMetrics: [String: BenchMetrics] = [:]
        for subset in subsetGroups.keys.sorted() {
            subsetMetrics[subset] = try Self.computeMetrics(subsetGroups[subset]!, protectedTerms: protectedTerms)
        }

        var regressions: [Regression] = []
        if let baseline {
            try Self.checkBaselineCompatibility(
                manifestSHA256: sha256, overall: overall, subsetMetrics: subsetMetrics, baseline: baseline
            )
            regressions.append(contentsOf: Self.compareToBaseline(actual: overall, baseline: baseline.metrics))
            regressions.append(
                contentsOf: Self.compareSubsetsToBaseline(actual: subsetMetrics, baseline: baseline.subsetMetrics)
            )
        }

        return try BenchReport(
            schemaVersion: BenchReport.currentSchemaVersion,
            manifestSHA256: sha256,
            metrics: overall,
            subsetMetrics: subsetMetrics,
            regressions: regressions
        )
    }

    /// A baseline is only meaningful for the exact corpus it was recorded
    /// against. Every check below must pass before any metric is compared,
    /// so a stale or mismatched baseline can never silently gate (or fail
    /// to gate) a regression.
    static func checkBaselineCompatibility(
        manifestSHA256: String,
        overall: BenchMetrics,
        subsetMetrics: [String: BenchMetrics],
        baseline: BenchReport
    ) throws {
        guard baseline.schemaVersion == BenchReport.currentSchemaVersion else {
            throw BaselineCompatibilityError.schemaMismatch(
                expected: BenchReport.currentSchemaVersion, actual: baseline.schemaVersion
            )
        }
        guard baseline.manifestSHA256 == manifestSHA256 else {
            throw BaselineCompatibilityError.manifestMismatch(
                expected: manifestSHA256, actual: baseline.manifestSHA256
            )
        }
        guard baseline.metrics.utteranceCount == overall.utteranceCount else {
            throw BaselineCompatibilityError.utteranceCountMismatch(
                expected: overall.utteranceCount, actual: baseline.metrics.utteranceCount
            )
        }
        let actualSubsets = Set(subsetMetrics.keys)
        let baselineSubsets = Set(baseline.subsetMetrics.keys)
        guard actualSubsets == baselineSubsets else {
            throw BaselineCompatibilityError.subsetMismatch(expected: actualSubsets, actual: baselineSubsets)
        }
        for subset in actualSubsets.sorted() {
            guard let actualCount = subsetMetrics[subset]?.utteranceCount,
                let baselineCount = baseline.subsetMetrics[subset]?.utteranceCount
            else { continue }
            guard actualCount == baselineCount else {
                throw BaselineCompatibilityError.utteranceCountMismatch(
                    expected: actualCount, actual: baselineCount
                )
            }
        }
    }

    /// Hashes a canonical form of the manifest (utterances sorted by ID, the
    /// same order execution uses) so that reordering equivalent manifest
    /// entries never changes the corpus identity hash.
    static func manifestSHA256(_ manifest: ReplayManifest) throws -> String {
        let canonical = try ReplayManifest(
            schemaVersion: manifest.schemaVersion,
            utterances: manifest.utterances.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canonical)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func computeMetrics(
        _ entries: [(utterance: ReplayUtterance, result: PipelineResult)],
        protectedTerms: Set<String>
    ) throws -> BenchMetrics {
        guard !entries.isEmpty else {
            return try BenchMetrics(
                utteranceCount: 0,
                exactMatchRate: 0,
                protectedTermExactMatchRate: 0,
                falseDomainCorrectionRate: 0,
                routeAccuracy: 0,
                dualDecodeRate: 0,
                medianFinalLatencyMilliseconds: 0
            )
        }

        var exactMatches = 0
        var routeMatches = 0
        var dualCount = 0
        var latencies: [Double] = []

        var protectedTermEligible = 0
        var protectedTermHits = 0
        var plainEnglishEligible = 0
        var falseCorrections = 0

        for (utterance, result) in entries {
            if result.text == utterance.expectedText {
                exactMatches += 1
            }
            if result.route.route == utterance.expectedRoute {
                routeMatches += 1
            }
            if result.route.route == .dual {
                dualCount += 1
            }
            latencies.append(Double(result.selection.selected.latencyMilliseconds))

            let expectedProtectedTerms = Self.protectedTermsPresent(protectedTerms, in: utterance.expectedText)
            if expectedProtectedTerms.isEmpty {
                plainEnglishEligible += 1
                if !result.corrections.isEmpty {
                    falseCorrections += 1
                }
            } else {
                protectedTermEligible += 1
                let actualProtectedTerms = Self.protectedTermsPresent(protectedTerms, in: result.text)
                if expectedProtectedTerms.isSubset(of: actualProtectedTerms) {
                    protectedTermHits += 1
                }
            }
        }

        return try BenchMetrics(
            utteranceCount: entries.count,
            exactMatchRate: Double(exactMatches) / Double(entries.count),
            protectedTermExactMatchRate: protectedTermEligible > 0
                ? Double(protectedTermHits) / Double(protectedTermEligible) : 0,
            falseDomainCorrectionRate: plainEnglishEligible > 0
                ? Double(falseCorrections) / Double(plainEnglishEligible) : 0,
            routeAccuracy: Double(routeMatches) / Double(entries.count),
            dualDecodeRate: Double(dualCount) / Double(entries.count),
            medianFinalLatencyMilliseconds: Self.median(latencies)
        )
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return sorted[count / 2]
        }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }

    static func protectedTermsPresent(_ terms: Set<String>, in text: String) -> Set<String> {
        var present: Set<String> = []
        for term in terms {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b") else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                present.insert(term)
            }
        }
        return present
    }

    static func compareToBaseline(actual: BenchMetrics, baseline: BenchMetrics) -> [Regression] {
        let allowedDelta = 0.0
        var regressions: [Regression] = []

        func recordIfDecreased(_ metric: String, _ actualValue: Double, _ baselineValue: Double) {
            guard actualValue < baselineValue - allowedDelta else { return }
            regressions.append(
                Regression(metric: metric, baseline: baselineValue, actual: actualValue, allowedDelta: allowedDelta)
            )
        }

        func recordIfIncreased(_ metric: String, _ actualValue: Double, _ baselineValue: Double) {
            guard actualValue > baselineValue + allowedDelta else { return }
            regressions.append(
                Regression(metric: metric, baseline: baselineValue, actual: actualValue, allowedDelta: allowedDelta)
            )
        }

        recordIfDecreased("exactMatchRate", actual.exactMatchRate, baseline.exactMatchRate)
        recordIfDecreased(
            "protectedTermExactMatchRate", actual.protectedTermExactMatchRate, baseline.protectedTermExactMatchRate
        )
        recordIfIncreased(
            "falseDomainCorrectionRate", actual.falseDomainCorrectionRate, baseline.falseDomainCorrectionRate
        )
        recordIfDecreased("routeAccuracy", actual.routeAccuracy, baseline.routeAccuracy)
        recordIfIncreased("dualDecodeRate", actual.dualDecodeRate, baseline.dualDecodeRate)

        return regressions.sorted { $0.metric < $1.metric }
    }

    /// Compares subset metrics independently and qualifies each regression
    /// with its subset name (e.g. `subset.baps-terminology.exactMatchRate`)
    /// so a per-subset regression can never be hidden by an unchanged or
    /// improved overall average.
    static func compareSubsetsToBaseline(
        actual: [String: BenchMetrics],
        baseline: [String: BenchMetrics]
    ) -> [Regression] {
        var regressions: [Regression] = []
        for subset in actual.keys.sorted() {
            guard let actualSubset = actual[subset], let baselineSubset = baseline[subset] else { continue }
            let subsetRegressions = compareToBaseline(actual: actualSubset, baseline: baselineSubset)
            regressions.append(
                contentsOf: subsetRegressions.map { regression in
                    Regression(
                        metric: "subset.\(subset).\(regression.metric)",
                        baseline: regression.baseline,
                        actual: regression.actual,
                        allowedDelta: regression.allowedDelta
                    )
                }
            )
        }
        return regressions
    }
}
