import Foundation

public struct BenchMetrics: Codable, Equatable, Sendable {
    public let utteranceCount: Int
    public let exactMatchRate: Double
    public let protectedTermExactMatchRate: Double
    public let falseDomainCorrectionRate: Double
    public let routeAccuracy: Double
    public let dualDecodeRate: Double
    public let medianFinalLatencyMilliseconds: Double

    public init(
        utteranceCount: Int,
        exactMatchRate: Double,
        protectedTermExactMatchRate: Double,
        falseDomainCorrectionRate: Double,
        routeAccuracy: Double,
        dualDecodeRate: Double,
        medianFinalLatencyMilliseconds: Double
    ) {
        self.utteranceCount = utteranceCount
        self.exactMatchRate = exactMatchRate
        self.protectedTermExactMatchRate = protectedTermExactMatchRate
        self.falseDomainCorrectionRate = falseDomainCorrectionRate
        self.routeAccuracy = routeAccuracy
        self.dualDecodeRate = dualDecodeRate
        self.medianFinalLatencyMilliseconds = medianFinalLatencyMilliseconds
    }
}

public struct Regression: Codable, Equatable, Sendable {
    public let metric: String
    public let baseline: Double
    public let actual: Double
    public let allowedDelta: Double

    public init(metric: String, baseline: Double, actual: Double, allowedDelta: Double) {
        self.metric = metric
        self.baseline = baseline
        self.actual = actual
        self.allowedDelta = allowedDelta
    }
}

public struct BenchReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let manifestSHA256: String
    public let metrics: BenchMetrics
    public let subsetMetrics: [String: BenchMetrics]
    public let regressions: [Regression]

    public init(
        schemaVersion: Int,
        manifestSHA256: String,
        metrics: BenchMetrics,
        subsetMetrics: [String: BenchMetrics],
        regressions: [Regression]
    ) {
        self.schemaVersion = schemaVersion
        self.manifestSHA256 = manifestSHA256
        self.metrics = metrics
        self.subsetMetrics = subsetMetrics
        self.regressions = regressions
    }
}

extension BenchReport {
    public static func load(fromPath path: String) throws -> BenchReport {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BenchReport.self, from: data)
    }

    public func renderJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    public func renderMarkdown() -> String {
        var lines: [String] = []
        lines.append("# VaaniBench Report")
        lines.append("")
        lines.append("Manifest SHA-256: `\(manifestSHA256)`")
        lines.append("")
        lines.append("## Metrics")
        lines.append("")
        lines.append(contentsOf: Self.metricsTable(["overall": metrics].merging(subsetMetrics) { first, _ in first }))
        lines.append("")
        lines.append("## Regressions")
        lines.append("")
        if regressions.isEmpty {
            lines.append("None.")
        } else {
            lines.append("| Metric | Baseline | Actual | Allowed delta |")
            lines.append("| --- | --- | --- | --- |")
            for regression in regressions.sorted(by: { $0.metric < $1.metric }) {
                lines.append(
                    "| \(regression.metric) | \(regression.baseline) | \(regression.actual) "
                        + "| \(regression.allowedDelta) |"
                )
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func metricsTable(_ metricsByGroup: [String: BenchMetrics]) -> [String] {
        var lines: [String] = []
        lines.append(
            "| Group | Utterances | Exact match | Protected term | False domain "
                + "| Route accuracy | Dual decode | Median latency (ms) |"
        )
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        // "overall" always sorts first; remaining groups are subsets sorted lexicographically.
        let orderedKeys = ["overall"] + metricsByGroup.keys.filter { $0 != "overall" }.sorted()
        for key in orderedKeys {
            guard let metrics = metricsByGroup[key] else { continue }
            lines.append(
                "| \(key) | \(metrics.utteranceCount) | \(metrics.exactMatchRate) "
                    + "| \(metrics.protectedTermExactMatchRate) | \(metrics.falseDomainCorrectionRate) "
                    + "| \(metrics.routeAccuracy) | \(metrics.dualDecodeRate) "
                    + "| \(metrics.medianFinalLatencyMilliseconds) |"
            )
        }
        return lines
    }
}
