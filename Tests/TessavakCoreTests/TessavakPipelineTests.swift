import Foundation
import Testing

@testable import TessavakCore

@Suite struct TessavakPipelineTests {

    private func makePack() throws -> TerminologyPack {
        try TerminologyPack(
            schemaVersion: 1,
            id: "test-pack",
            version: "1",
            license: "Project-authored; Apache-2.0",
            provenance: "Synthetic fixture for TessavakPipeline tests.",
            entries: [
                try TerminologyEntry(
                    canonical: "Pramukh Swami Maharaj",
                    aliases: ["pramukh swami maharaj"],
                    language: .gujarati,
                    script: "Latin",
                    protected: true,
                    outputForms: [:],
                    collisionRisk: 0.05
                )
            ]
        )
    }

    private func model(_ name: String) throws -> ModelIdentity {
        try ModelIdentity(provider: "replay", name: name, version: "1")
    }

    @Test func mixedEvidenceSelectsDualRouteAndBAPSTerminologyWins() throws {
        let pipeline = try TessavakPipeline(
            accumulatorConfiguration: try EvidenceAccumulatorConfiguration(
                enterThreshold: 0.6, exitThreshold: 0.3, historyLimit: 5
            ),
            routingPolicy: try RoutingPolicy(
                mode: .evaluation,
                confidentLanguageThreshold: 0.85,
                secondDecodeThreshold: 0.15,
                latencyBudgetMilliseconds: 500
            ),
            terminologyPack: try makePack()
        )

        let observation = try EvidenceObservation(
            languages: try LanguageDistribution(values: [.english: 0.48, .gujarati: 0.47, .mixed: 0.05]),
            domains: [:],
            source: .recognizer,
            weight: 1.0,
            timestampMilliseconds: 0
        )

        let englishCandidate = try RecognitionCandidate(
            id: "c-en",
            text: "The weather is nice today",
            confidence: 0.90,
            detectedLanguages: try LanguageDistribution(values: [.english: 0.95, .gujarati: 0.02, .mixed: 0.03]),
            segments: [],
            model: try model("fastEnglish"),
            latencyMilliseconds: 80
        )

        let multilingualCandidate = try RecognitionCandidate(
            id: "c-gu",
            text: "pramukh swami maharaj gave a talk",
            confidence: 0.65,
            detectedLanguages: try LanguageDistribution(values: [.english: 0.10, .gujarati: 0.85, .mixed: 0.05]),
            segments: [],
            model: try model("multilingual"),
            latencyMilliseconds: 200
        )

        let request = PipelineRequest(
            observations: [observation],
            candidates: [englishCandidate, multilingualCandidate],
            outputPolicy: .preserveMixed
        )

        let result = try pipeline.process(request)

        #expect(result.text == "Pramukh Swami Maharaj gave a talk")
        #expect(result.route.route == .dual)
        #expect(result.selection.selected.id == "c-gu")
        #expect(result.selection.selected.model.name == "multilingual")
        #expect(result.corrections.count == 1)
        #expect(result.corrections[0].original == "pramukh swami maharaj")
        #expect(result.corrections[0].replacement == "Pramukh Swami Maharaj")

        #expect(result.selection.scores.count == 2)
        for score in result.selection.scores {
            #expect(Set(score.components.keys) == Set(ScoreComponent.allCases))
        }

        let eventCodes = result.diagnostics.events.map(\.code)
        #expect(
            eventCodes == [
                .routeDual, .candidateSelected, .deterministicCorrectionApplied, .outputPolicyApplied,
            ]
        )

        let diagnosticsJSON = try JSONEncoder().encode(result.diagnostics)
        let diagnosticsText = String(data: diagnosticsJSON, encoding: .utf8) ?? ""
        #expect(!diagnosticsText.contains("The weather is nice today"))
        #expect(!diagnosticsText.contains("pramukh swami maharaj gave a talk"))
        #expect(!diagnosticsText.contains("Pramukh Swami Maharaj gave a talk"))
    }

    @Test func emptyObservationsThrow() throws {
        let pipeline = try TessavakPipeline(
            accumulatorConfiguration: try EvidenceAccumulatorConfiguration(
                enterThreshold: 0.6, exitThreshold: 0.3, historyLimit: 5
            ),
            routingPolicy: try RoutingPolicy(
                mode: .evaluation,
                confidentLanguageThreshold: 0.85,
                secondDecodeThreshold: 0.15,
                latencyBudgetMilliseconds: 500
            ),
            terminologyPack: try makePack()
        )
        let candidate = try RecognitionCandidate(
            id: "c1",
            text: "hello",
            confidence: 0.9,
            detectedLanguages: try LanguageDistribution(values: [.english: 1.0]),
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 10
        )
        let request = PipelineRequest(observations: [], candidates: [candidate], outputPolicy: .preserveMixed)
        #expect(throws: (any Error).self) {
            try pipeline.process(request)
        }
    }

    @Test func separateProcessCallsDoNotLeakEvidenceHistory() throws {
        let pipeline = try TessavakPipeline(
            accumulatorConfiguration: try EvidenceAccumulatorConfiguration(
                enterThreshold: 0.6, exitThreshold: 0.3, historyLimit: 5
            ),
            routingPolicy: try RoutingPolicy(
                mode: .evaluation,
                confidentLanguageThreshold: 0.85,
                secondDecodeThreshold: 0.15,
                latencyBudgetMilliseconds: 500
            ),
            terminologyPack: try makePack()
        )
        let candidate = try RecognitionCandidate(
            id: "c1",
            text: "hello world",
            confidence: 0.95,
            detectedLanguages: try LanguageDistribution(values: [.english: 0.95, .mixed: 0.05]),
            segments: [],
            model: try model("test"),
            latencyMilliseconds: 10
        )
        let confidentEnglish = try EvidenceObservation(
            languages: try LanguageDistribution(values: [.english: 0.95, .mixed: 0.05]),
            domains: [:],
            source: .recognizer,
            weight: 1.0,
            timestampMilliseconds: 0
        )
        let firstRequest = PipelineRequest(
            observations: [confidentEnglish], candidates: [candidate], outputPolicy: .preserveMixed
        )
        let secondRequest = PipelineRequest(
            observations: [confidentEnglish], candidates: [candidate], outputPolicy: .preserveMixed
        )
        let first = try pipeline.process(firstRequest)
        let second = try pipeline.process(secondRequest)
        #expect(first.route.route == second.route.route)
        #expect(first.route.reasons == second.route.reasons)
    }
}
