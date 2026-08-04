import Foundation
import VaaniCore
import VaaniWhisper

/// Builds the recogniser lookup `LivePipelineCoordinator` needs.
///
/// Every route gets the same `WhisperRecognizer`: this harness is
/// single-model, and routing two *real* recognisers against each other is
/// Phase 3 work. The coordinator still plans routes and may trigger a
/// secondary decode, which with one model means the same model decodes twice.
func makeRecognizerFactory(
    modelPath: String,
    language: LanguageOption
) throws -> @Sendable (Route) -> (any StreamingRecognizer)? {
    let recognizer = try WhisperRecognizer(
        modelFileURL: URL(fileURLWithPath: modelPath),
        languageHint: language.whisperLanguageHint
    )
    return { _ in recognizer }
}

extension LanguageOption {
    var whisperLanguageHint: WhisperLanguageHint {
        switch self {
        case .auto: return .auto
        case .en: return .english
        case .gu: return .gujarati
        }
    }
}
