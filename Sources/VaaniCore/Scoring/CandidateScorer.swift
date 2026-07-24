import Foundation

public enum ScoreComponent: String, Codable, CaseIterable, Hashable, Sendable {
    case acousticConfidence, languageAgreement, scriptAgreement
    case domainTermRecall, protectedTermIntegrity
    case hallucinationPenalty, repetitionPenalty, latencyCost
}

public struct ScoringWeights: Codable, Equatable, Sendable {
    public let values: [ScoreComponent: Double]

    public init(values: [ScoreComponent: Double]) throws {
        for (component, value) in values {
            guard value.isFinite, value >= 0 else {
                throw VaaniCoreError.invalidConfiguration(
                    "scoring weight for \(component.rawValue) must be finite and non-negative, got \(value)"
                )
            }
        }
        self.values = values
    }

    /// Bypasses validation for the literal, known-valid default weights
    /// below, so `.default` never needs `try!`.
    private init(trustedValues: [ScoreComponent: Double]) {
        self.values = trustedValues
    }

    public static let `default` = ScoringWeights(trustedValues: [
        .acousticConfidence: 0.30,
        .languageAgreement: 0.20,
        .scriptAgreement: 0.10,
        .domainTermRecall: 0.15,
        .protectedTermIntegrity: 0.15,
        .hallucinationPenalty: 0.04,
        .repetitionPenalty: 0.03,
        .latencyCost: 0.03,
    ])

    private enum CodingKeys: String, CodingKey {
        case values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values: try container.decode([ScoreComponent: Double].self, forKey: .values))
    }
}

public struct CandidateScore: Codable, Equatable, Sendable {
    public let candidateID: String
    public let total: Double
    public let components: [ScoreComponent: Double]

    public init(candidateID: String, total: Double, components: [ScoreComponent: Double]) {
        self.candidateID = candidateID
        self.total = total
        self.components = components
    }
}

public struct ScoredSelection: Codable, Equatable, Sendable {
    public let selected: RecognitionCandidate
    public let scores: [CandidateScore]

    public init(selected: RecognitionCandidate, scores: [CandidateScore]) {
        self.selected = selected
        self.scores = scores
    }
}

/// Produces an explainable score for every candidate and deterministically
/// selects the best one. Every candidate always reports every `ScoreComponent`
/// so downstream diagnostics can show why a candidate won or lost.
public struct CandidateScorer: Sendable {
    private static let gujaratiRange: ClosedRange<UInt32> = 0x0A80...0x0AFF
    private static let latinRange: ClosedRange<UInt32> = 0x0041...0x007A

    private let weights: ScoringWeights
    private let latencyBudgetMilliseconds: Int

    public init(weights: ScoringWeights = .default, latencyBudgetMilliseconds: Int) throws {
        guard latencyBudgetMilliseconds > 0 else {
            throw VaaniCoreError.invalidConfiguration(
                "latencyBudgetMilliseconds must be positive, got \(latencyBudgetMilliseconds)"
            )
        }
        for component in ScoreComponent.allCases where weights.values[component] == nil {
            throw VaaniCoreError.invalidConfiguration("missing weight for component \(component.rawValue)")
        }
        self.weights = weights
        self.latencyBudgetMilliseconds = latencyBudgetMilliseconds
    }

    public func select(
        from candidates: [RecognitionCandidate],
        evidence: EvidenceSnapshot,
        protectedTerms: Set<String>
    ) throws -> ScoredSelection {
        guard !candidates.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("candidate list is empty")
        }

        let scores = candidates.map { candidate in
            score(candidate: candidate, evidence: evidence, protectedTerms: protectedTerms)
        }

        for score in scores where !score.total.isFinite {
            throw VaaniCoreError.invalidConfiguration(
                "computed score total for candidate \(score.candidateID) is not finite: \(score.total)"
            )
        }

        let bestIndex = scores.indices.min { lhsIndex, rhsIndex in
            let lhs = scores[lhsIndex]
            let rhs = scores[rhsIndex]
            if lhs.total != rhs.total {
                return lhs.total > rhs.total
            }
            let lhsCandidate = candidates[lhsIndex]
            let rhsCandidate = candidates[rhsIndex]
            if lhsCandidate.latencyMilliseconds != rhsCandidate.latencyMilliseconds {
                return lhsCandidate.latencyMilliseconds < rhsCandidate.latencyMilliseconds
            }
            return lhsCandidate.id < rhsCandidate.id
        }!

        return ScoredSelection(selected: candidates[bestIndex], scores: scores)
    }

    private func score(
        candidate: RecognitionCandidate,
        evidence: EvidenceSnapshot,
        protectedTerms: Set<String>
    ) -> CandidateScore {
        let dominantLanguage = evidence.languages.dominant.language

        var components: [ScoreComponent: Double] = [:]
        components[.acousticConfidence] = candidate.confidence
        components[.languageAgreement] = languageAgreement(candidate: candidate, evidence: evidence)
        components[.scriptAgreement] = scriptAgreement(candidate: candidate, dominantLanguage: dominantLanguage)
        components[.domainTermRecall] = domainTermRecall(candidate: candidate, protectedTerms: protectedTerms)
        components[.protectedTermIntegrity] = protectedTermIntegrity(
            candidate: candidate, protectedTerms: protectedTerms
        )
        components[.hallucinationPenalty] = hallucinationPenalty(candidate: candidate)
        components[.repetitionPenalty] = repetitionPenalty(candidate: candidate)
        components[.latencyCost] = latencyCost(candidate: candidate)

        let total = ScoreComponent.allCases.reduce(0.0) { partial, component in
            partial + (components[component] ?? 0) * (weights.values[component] ?? 0)
        }

        return CandidateScore(candidateID: candidate.id, total: total, components: components)
    }

    private func languageAgreement(candidate: RecognitionCandidate, evidence: EvidenceSnapshot) -> Double {
        LanguageTag.allCases.reduce(0) { partial, tag in
            partial + min(candidate.detectedLanguages[tag], evidence.languages[tag])
        }
    }

    private func scriptAgreement(candidate: RecognitionCandidate, dominantLanguage: LanguageTag) -> Double {
        var gujaratiCount = 0
        var latinCount = 0
        for scalar in candidate.text.unicodeScalars {
            if Self.gujaratiRange.contains(scalar.value) {
                gujaratiCount += 1
            } else if Self.latinRange.contains(scalar.value) {
                latinCount += 1
            }
        }
        let total = gujaratiCount + latinCount
        guard total > 0 else { return 0 }
        switch dominantLanguage {
        case .gujarati:
            return Double(gujaratiCount) / Double(total)
        case .english:
            return Double(latinCount) / Double(total)
        default:
            return Double(max(gujaratiCount, latinCount)) / Double(total)
        }
    }

    private func domainTermRecall(candidate: RecognitionCandidate, protectedTerms: Set<String>) -> Double {
        guard !protectedTerms.isEmpty else { return 0 }
        let hits = protectedTerms.filter { Self.containsWholeWordCaseInsensitive(candidate.text, $0) }.count
        return Double(hits) / Double(protectedTerms.count)
    }

    private func protectedTermIntegrity(candidate: RecognitionCandidate, protectedTerms: Set<String>) -> Double {
        guard !protectedTerms.isEmpty else { return 1.0 }
        let folded = candidate.text.folding(options: .caseInsensitive, locale: nil)
        var violations = 0
        for term in protectedTerms {
            let foldedTerm = term.folding(options: .caseInsensitive, locale: nil)
            guard !foldedTerm.isEmpty, folded.contains(foldedTerm) else { continue }
            if !Self.containsWholeWordCaseInsensitive(candidate.text, term) {
                violations += 1
            }
        }
        guard violations > 0 else { return 1.0 }
        return max(0, 1.0 - Double(violations) / Double(protectedTerms.count))
    }

    private func hallucinationPenalty(candidate: RecognitionCandidate) -> Double {
        candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? -1 : 0
    }

    private func repetitionPenalty(candidate: RecognitionCandidate) -> Double {
        let tokens = candidate.text.lowercased().split(separator: " ").map(String.init)
        guard tokens.count > 1 else { return 0 }
        var repeats = 0
        for index in 1..<tokens.count where tokens[index] == tokens[index - 1] {
            repeats += 1
        }
        return -(Double(repeats) / Double(tokens.count - 1))
    }

    private func latencyCost(candidate: RecognitionCandidate) -> Double {
        -min(Double(candidate.latencyMilliseconds) / Double(latencyBudgetMilliseconds), 1)
    }

    private static func containsWholeWordCaseInsensitive(_ text: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
