import Testing

@testable import VaaniCore

@Suite struct CandidateScorerTests {

    private func model(_ name: String) throws -> ModelIdentity {
        try ModelIdentity(provider: "replay", name: name, version: "1")
    }

    private func snapshot(_ values: [LanguageTag: Double], activeDomains: Set<String> = []) throws -> EvidenceSnapshot {
        try EvidenceSnapshot(
            languages: try LanguageDistribution(values: values),
            domains: [:],
            activeDomains: activeDomains,
            observations: 1
        )
    }

    @Test func domainEvidenceOutweighsRawAcousticConfidence() throws {
        let scorer = try CandidateScorer(latencyBudgetMilliseconds: 500)
        let evidence = try snapshot([.english: 0.10, .gujarati: 0.85, .mixed: 0.05])

        let candidateA = try RecognitionCandidate(
            id: "c-en",
            text: "The weather is nice today",
            confidence: 0.95,
            detectedLanguages: try LanguageDistribution(values: [.english: 0.95, .gujarati: 0.02, .mixed: 0.03]),
            segments: [],
            model: try model("fastEnglish"),
            latencyMilliseconds: 80
        )

        let candidateB = try RecognitionCandidate(
            id: "c-gu",
            text: "Pramukh Swami Maharaj gave blessings today",
            confidence: 0.70,
            detectedLanguages: try LanguageDistribution(values: [.english: 0.05, .gujarati: 0.90, .mixed: 0.05]),
            segments: [],
            model: try model("multilingual"),
            latencyMilliseconds: 220
        )

        let selection = try scorer.select(
            from: [candidateA, candidateB],
            evidence: evidence,
            protectedTerms: ["Pramukh Swami Maharaj"]
        )

        #expect(selection.selected.id == "c-gu")
        #expect(selection.scores.count == 2)
        for score in selection.scores {
            #expect(Set(score.components.keys) == Set(ScoreComponent.allCases))
        }

        let repeated = try scorer.select(
            from: [candidateA, candidateB],
            evidence: evidence,
            protectedTerms: ["Pramukh Swami Maharaj"]
        )
        let firstSorted = selection.scores.sorted { $0.candidateID < $1.candidateID }
        let secondSorted = repeated.scores.sorted { $0.candidateID < $1.candidateID }
        for (first, second) in zip(firstSorted, secondSorted) {
            #expect(abs(first.total - second.total) < 1e-9)
        }
    }

    @Test func everyCandidateReportsEveryScoreComponent() throws {
        let scorer = try CandidateScorer(latencyBudgetMilliseconds: 500)
        let evidence = try snapshot([.english: 1.0])
        let candidate = try RecognitionCandidate(
            id: "c1",
            text: "hello world",
            confidence: 0.9,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 50
        )
        let selection = try scorer.select(from: [candidate], evidence: evidence, protectedTerms: [])
        #expect(Set(selection.scores[0].components.keys) == Set(ScoreComponent.allCases))
    }

    @Test func emptyCandidateListThrows() throws {
        let scorer = try CandidateScorer(latencyBudgetMilliseconds: 500)
        let evidence = try snapshot([.english: 1.0])
        #expect(throws: (any Error).self) {
            try scorer.select(from: [], evidence: evidence, protectedTerms: [])
        }
    }

    @Test func nonPositiveLatencyBudgetRejectedAtInit() {
        #expect(throws: (any Error).self) {
            try CandidateScorer(latencyBudgetMilliseconds: 0)
        }
    }

    @Test func missingComponentWeightRejectedAtInit() throws {
        let incomplete = try ScoringWeights(values: [.acousticConfidence: 1.0])
        #expect(throws: (any Error).self) {
            try CandidateScorer(weights: incomplete, latencyBudgetMilliseconds: 500)
        }
    }

    // MARK: - ScoringWeights validation

    @Test func scoringWeightsRejectsNaN() {
        #expect(throws: VaaniCoreError.self) {
            _ = try ScoringWeights(values: [.acousticConfidence: .nan])
        }
    }

    @Test func scoringWeightsRejectsInfinity() {
        #expect(throws: VaaniCoreError.self) {
            _ = try ScoringWeights(values: [.acousticConfidence: .infinity])
        }
    }

    @Test func scoringWeightsRejectsNegativeValue() {
        #expect(throws: VaaniCoreError.self) {
            _ = try ScoringWeights(values: [.hallucinationPenalty: -0.1])
        }
    }

    @Test func scoringWeightsAcceptsCompleteValidDictionary() throws {
        let weights = try ScoringWeights(
            values: Dictionary(uniqueKeysWithValues: ScoreComponent.allCases.map { ($0, 0.1) })
        )
        #expect(weights.values.count == ScoreComponent.allCases.count)
    }

    @Test func hallucinationPenaltyAppliesOnlyToEmptyText() throws {
        let scorer = try CandidateScorer(latencyBudgetMilliseconds: 500)
        let evidence = try snapshot([.english: 1.0])
        let empty = try RecognitionCandidate(
            id: "empty",
            text: "   ",
            confidence: 0.5,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 10
        )
        let selection = try scorer.select(from: [empty], evidence: evidence, protectedTerms: [])
        #expect(selection.scores[0].components[.hallucinationPenalty] == -1)
    }

    @Test func repetitionPenaltyDetectsAdjacentRepeats() throws {
        let scorer = try CandidateScorer(latencyBudgetMilliseconds: 500)
        let evidence = try snapshot([.english: 1.0])
        let repeated = try RecognitionCandidate(
            id: "rep",
            text: "the the cat sat sat",
            confidence: 0.5,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 10
        )
        let selection = try scorer.select(from: [repeated], evidence: evidence, protectedTerms: [])
        // Tokens: the,the,cat,sat,sat -> 4 adjacent pairs, 2 repeats -> -0.5
        #expect(selection.scores[0].components[.repetitionPenalty] == -0.5)
    }

    // MARK: - Tie-breaking

    private func zeroWeightScorer() throws -> CandidateScorer {
        let zero = try ScoringWeights(
            values: Dictionary(uniqueKeysWithValues: ScoreComponent.allCases.map { ($0, 0.0) })
        )
        return try CandidateScorer(weights: zero, latencyBudgetMilliseconds: 500)
    }

    @Test func tieBreaksByLowerLatencyWhenTotalsTie() throws {
        let scorer = try zeroWeightScorer()
        let evidence = try snapshot([.english: 1.0])
        let languages = try LanguageDistribution(values: [.english: 1.0])
        let slower = try RecognitionCandidate(
            id: "b-candidate",
            text: "hello",
            confidence: 0.5,
            detectedLanguages: languages,
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 100
        )
        let faster = try RecognitionCandidate(
            id: "a-candidate",
            text: "hello",
            confidence: 0.9,
            detectedLanguages: languages,
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 50
        )
        let selection = try scorer.select(from: [slower, faster], evidence: evidence, protectedTerms: [])
        #expect(selection.selected.id == "a-candidate")
    }

    @Test func tieBreaksByLexicographicIDWhenLatencyAlsoTies() throws {
        let scorer = try zeroWeightScorer()
        let evidence = try snapshot([.english: 1.0])
        let languages = try LanguageDistribution(values: [.english: 1.0])
        let first = try RecognitionCandidate(
            id: "zzz",
            text: "hello",
            confidence: 0.5,
            detectedLanguages: languages,
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 100
        )
        let second = try RecognitionCandidate(
            id: "aaa",
            text: "hello",
            confidence: 0.9,
            detectedLanguages: languages,
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 100
        )
        let selection = try scorer.select(from: [first, second], evidence: evidence, protectedTerms: [])
        #expect(selection.selected.id == "aaa")
    }
}
