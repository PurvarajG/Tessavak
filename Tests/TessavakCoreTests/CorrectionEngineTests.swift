import Testing

@testable import TessavakCore

@Suite struct CorrectionEngineTests {

    private func makePack() throws -> TerminologyPack {
        try TerminologyPack(
            schemaVersion: 1,
            id: "test-pack",
            version: "1",
            license: "Project-authored; Apache-2.0",
            provenance: "Synthetic fixture for CorrectionEngine tests.",
            entries: [
                try TerminologyEntry(
                    canonical: "Pramukh Swami Maharaj",
                    aliases: ["pramukh swami maharaj"],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: [:],
                    collisionRisk: 0.05
                ),
                try TerminologyEntry(
                    canonical: "Vachanamrut",
                    aliases: ["vachanamrut"],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: [:],
                    collisionRisk: 0.05
                ),
                try TerminologyEntry(
                    canonical: "Akshar-Purushottam",
                    aliases: ["akshar purushottam", "akshar-purushottam"],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: [:],
                    collisionRisk: 0.05
                ),
            ]
        )
    }

    @Test func longestMatchAndCasingAliasReplacement() throws {
        let engine = CorrectionEngine(pack: try makePack())
        let once = engine.correct("pramukh swami maharaj, spoke.")
        let twice = engine.correct(once.text)
        #expect(once.text == "Pramukh Swami Maharaj, spoke.")
        #expect(twice.text == once.text)
        #expect(twice.corrections.isEmpty)
    }

    @Test func recordsCorrectionMetadata() throws {
        let engine = CorrectionEngine(pack: try makePack())
        let result = engine.correct("pramukh swami maharaj spoke.")
        #expect(result.corrections.count == 1)
        #expect(result.corrections[0].original == "pramukh swami maharaj")
        #expect(result.corrections[0].replacement == "Pramukh Swami Maharaj")
        #expect(result.corrections[0].entryCanonical == "Pramukh Swami Maharaj")
    }

    @Test func preservesSurroundingPunctuationAndWhitespace() throws {
        let engine = CorrectionEngine(pack: try makePack())
        let result = engine.correct("  Well, pramukh swami maharaj spoke!  ")
        #expect(result.text == "  Well, Pramukh Swami Maharaj spoke!  ")
    }

    @Test func doesNotMatchInsideLargerToken() throws {
        // "vachanamrutam" is not a recorded alias; the engine must not
        // substring-match "vachanamrut" inside a larger token.
        let engine = CorrectionEngine(pack: try makePack())
        let result = engine.correct("vachanamrutam is not a word we track")
        #expect(result.corrections.isEmpty)
        #expect(result.text == "vachanamrutam is not a word we track")
    }

    @Test func punctuationVariantAliasMatchesHyphenatedCanonical() throws {
        let engine = CorrectionEngine(pack: try makePack())
        let result = engine.correct("akshar purushottam maharaj")
        #expect(result.text == "Akshar-Purushottam maharaj")
    }

    @Test func canonicalTextAlreadyPresentIsUnchanged() throws {
        let engine = CorrectionEngine(pack: try makePack())
        let result = engine.correct("Vachanamrut is a scripture.")
        #expect(result.text == "Vachanamrut is a scripture.")
        #expect(result.corrections.isEmpty)
    }

    @Test func idempotentAcrossRepeatedCorrection() throws {
        let engine = CorrectionEngine(pack: try makePack())
        let first = engine.correct("vachanamrut and pramukh swami maharaj")
        let second = engine.correct(first.text)
        #expect(second.text == first.text)
        #expect(second.corrections.isEmpty)
    }

    @Test func ordinaryEnglishTextIsUntouched() throws {
        let engine = CorrectionEngine(pack: try makePack())
        let result = engine.correct("The weather is nice today.")
        #expect(result.text == "The weather is nice today.")
        #expect(result.corrections.isEmpty)
    }
}
