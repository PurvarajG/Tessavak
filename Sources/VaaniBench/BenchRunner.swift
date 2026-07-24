import CryptoKit
import Foundation
import VaaniAdapters
import VaaniCore

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

        let overall = Self.computeMetrics(perUtterance, protectedTerms: protectedTerms)

        var subsetGroups: [String: [(utterance: ReplayUtterance, result: PipelineResult)]] = [:]
        for entry in perUtterance {
            subsetGroups[entry.utterance.subset, default: []].append(entry)
        }
        var subsetMetrics: [String: BenchMetrics] = [:]
        for subset in subsetGroups.keys.sorted() {
            subsetMetrics[subset] = Self.computeMetrics(subsetGroups[subset]!, protectedTerms: protectedTerms)
        }

        let regressions = baseline.map { Self.compareToBaseline(actual: overall, baseline: $0.metrics) } ?? []

        return BenchReport(
            schemaVersion: BenchReport.currentSchemaVersion,
            manifestSHA256: sha256,
            metrics: overall,
            subsetMetrics: subsetMetrics,
            regressions: regressions
        )
    }

    static func manifestSHA256(_ manifest: ReplayManifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func computeMetrics(
        _ entries: [(utterance: ReplayUtterance, result: PipelineResult)],
        protectedTerms: Set<String>
    ) -> BenchMetrics {
        guard !entries.isEmpty else {
            return BenchMetrics(
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

        return BenchMetrics(
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
}
