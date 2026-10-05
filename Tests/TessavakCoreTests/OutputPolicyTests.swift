import Testing

@testable import TessavakCore

@Suite struct OutputPolicyTests {

    private func makePack() throws -> TerminologyPack {
        try TerminologyPack(
            schemaVersion: 1,
            id: "test-pack",
            version: "1",
            license: "Project-authored; Apache-2.0",
            provenance: "Synthetic fixture for OutputRenderer tests.",
            entries: [
                try TerminologyEntry(
                    canonical: "Vachanamrut",
                    aliases: ["vachanamrut"],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: ["gujaratiScript": "વચનામૃત", "bapsRoman": "Vachanamrut"],
                    collisionRisk: 0.05
                ),
                try TerminologyEntry(
                    canonical: "Akshar-Purushottam",
                    aliases: ["akshar purushottam", "akshar-purushottam"],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: ["gujaratiScript": "અક્ષર-પુરુષોત્તમ"],
                    collisionRisk: 0.05
                ),
                try TerminologyEntry(
                    canonical: "BAPS",
                    aliases: ["baps"],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: [:],
                    collisionRisk: 0.1
                ),
            ]
        )
    }

    @Test func preserveMixedReturnsTextUnchanged() throws {
        let renderer = OutputRenderer(pack: try makePack())
        let text = "Vachanamrut teaches BAPS values, વચનામૃત is central."
        let rendered = try renderer.render(text, policy: .preserveMixed)
        #expect(rendered == text)
    }

    @Test func gujaratiScriptReplacesReviewedRomanTerm() throws {
        let renderer = OutputRenderer(pack: try makePack())
        let rendered = try renderer.render("Reading the Vachanamrut today", policy: .gujaratiScript)
        #expect(rendered == "Reading the વચનામૃત today")
    }

    @Test func gujaratiScriptPreservesUnreviewedRomanTerm() throws {
        let renderer = OutputRenderer(pack: try makePack())
        // BAPS has no reviewed gujaratiScript output form, so it must be preserved.
        let rendered = try renderer.render("BAPS is a global organization", policy: .gujaratiScript)
        #expect(rendered == "BAPS is a global organization")
    }

    @Test func gujaratiScriptPreservesEnglishSpans() throws {
        let renderer = OutputRenderer(pack: try makePack())
        let text = "The weather is nice today"
        let rendered = try renderer.render(text, policy: .gujaratiScript)
        #expect(rendered == text)
    }

    @Test func bapsRomanReplacesReviewedGujaratiTerm() throws {
        let renderer = OutputRenderer(pack: try makePack())
        let rendered = try renderer.render("Reading the વચનામૃત today", policy: .bapsRoman)
        #expect(rendered == "Reading the Vachanamrut today")
    }

    @Test func bapsRomanPreservesGujaratiScriptWithoutReviewedForm() throws {
        let renderer = OutputRenderer(pack: try makePack())
        // Akshar-Purushottam has no reviewed bapsRoman output form, so its
        // Gujarati script must be preserved (safe degradation).
        let text = "અક્ષર-પુરુષોત્તમ is central to BAPS theology"
        let rendered = try renderer.render(text, policy: .bapsRoman)
        #expect(rendered == text)
    }

    @Test func bapsRomanPreservesEnglishSpans() throws {
        let renderer = OutputRenderer(pack: try makePack())
        let text = "The weather is nice today"
        let rendered = try renderer.render(text, policy: .bapsRoman)
        #expect(rendered == text)
    }

    @Test func gujaratiScriptRenderingIsIdempotent() throws {
        let renderer = OutputRenderer(pack: try makePack())
        let once = try renderer.render("Reading the Vachanamrut today", policy: .gujaratiScript)
        let twice = try renderer.render(once, policy: .gujaratiScript)
        #expect(twice == once)
    }

    @Test func bapsRomanRenderingIsIdempotent() throws {
        let renderer = OutputRenderer(pack: try makePack())
        let once = try renderer.render("Reading the વચનામૃત today", policy: .bapsRoman)
        let twice = try renderer.render(once, policy: .bapsRoman)
        #expect(twice == once)
    }

    @Test func emptyGujaratiScriptOutputFormThrows() {
        #expect(throws: TessavakCoreError.self) {
            _ = try TerminologyEntry(
                canonical: "Test",
                aliases: [],
                language: .gujarati,
                script: "Latin",
                protected: true,
                outputForms: ["gujaratiScript": "", "bapsRoman": "roman"],
                collisionRisk: 0
            )
        }
    }

    @Test func emptyBapsRomanOutputFormThrows() {
        #expect(throws: TessavakCoreError.self) {
            _ = try TerminologyEntry(
                canonical: "Test",
                aliases: [],
                language: .gujarati,
                script: "Latin",
                protected: true,
                outputForms: ["gujaratiScript": "અક્ષર", "bapsRoman": ""],
                collisionRisk: 0
            )
        }
    }

    @Test func unsupportedOutputFormKeyThrows() {
        #expect(throws: TessavakCoreError.self) {
            _ = try TerminologyEntry(
                canonical: "Test",
                aliases: [],
                language: .gujarati,
                script: "Latin",
                protected: true,
                outputForms: ["englishTranslation": "test"],
                collisionRisk: 0
            )
        }
    }

    @Test func selfContainingBapsRomanReplacementTerminates() throws {
        let pack = try TerminologyPack(
            schemaVersion: 1,
            id: "test-pack",
            version: "1",
            license: "Project-authored; Apache-2.0",
            provenance: "Synthetic fixture for self-containing replacement test.",
            entries: [
                try TerminologyEntry(
                    canonical: "Akshar",
                    aliases: [],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: ["gujaratiScript": "અક્ષર", "bapsRoman": "અક્ષર-roman"],
                    collisionRisk: 0.05
                )
            ]
        )
        let renderer = OutputRenderer(pack: pack)
        let rendered = try renderer.render("અક્ષર અક્ષર", policy: .bapsRoman)
        #expect(rendered == "અક્ષર-roman અક્ષર-roman")
    }

    @Test func identicalSourceAndReplacementIsStableSinglePass() throws {
        let pack = try TerminologyPack(
            schemaVersion: 1,
            id: "test-pack",
            version: "1",
            license: "Project-authored; Apache-2.0",
            provenance: "Synthetic fixture for identity replacement test.",
            entries: [
                try TerminologyEntry(
                    canonical: "Same",
                    aliases: [],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: ["gujaratiScript": "same", "bapsRoman": "same"],
                    collisionRisk: 0.05
                )
            ]
        )
        let renderer = OutputRenderer(pack: pack)
        let rendered = try renderer.render("same text", policy: .bapsRoman)
        #expect(rendered == "same text")
    }
}
