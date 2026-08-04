import Foundation
import VaaniCore

/// Turns the CLI's `--language` flag into the one piece of evidence
/// `LivePipelineCoordinator` needs to plan a route.
///
/// This is a stand-in, not real language identification: acoustic/script-
/// based detection (VAD, language ID) is explicitly deferred to a later
/// phase. `auto` reports mixed evidence, which the router's existing
/// second-decode threshold turns into a dual-route plan — the router runs
/// both single-model routes.
struct LanguageHintDetector: Detector {
    private let distribution: LanguageDistribution

    init(language: LanguageOption) throws {
        switch language {
        case .en:
            distribution = try LanguageDistribution(values: [.english: 1.0])
        case .gu:
            distribution = try LanguageDistribution(values: [.gujarati: 1.0])
        case .auto:
            distribution = try LanguageDistribution(values: [.mixed: 1.0])
        }
    }

    func observations(
        for event: SpeechEvent,
        provisionalText: String?
    ) async throws -> [EvidenceObservation] {
        guard case .speechStarted(let atMilliseconds) = event else { return [] }
        return [
            try EvidenceObservation(
                languages: distribution,
                domains: [:],
                source: .explicitMode,
                weight: 1.0,
                timestampMilliseconds: atMilliseconds
            )
        ]
    }
}
