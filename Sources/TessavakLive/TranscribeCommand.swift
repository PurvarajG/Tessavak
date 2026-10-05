import ArgumentParser
import Foundation
import TessavakCore
import TessavakPacks

/// `transcribe`'s `--policy` values. A local wrapper because `SessionPolicy`
/// (a.k.a. `RoutingPolicy.Mode`) is not `ExpressibleByArgument`, and this CLI
/// only ever offers the two policies file-driven batch transcription makes
/// sense for; `verbatim`/`evaluation` stay internal-only for now.
enum PolicyOption: String, ExpressibleByArgument, CaseIterable {
    case interactive, meeting

    var sessionPolicy: SessionPolicy {
        switch self {
        case .interactive: return .interactive
        case .meeting: return .meeting
        }
    }
}

/// `transcribe`'s `--language` values.
enum LanguageOption: String, ExpressibleByArgument, CaseIterable {
    case auto, en, gu
}

/// `transcribe`'s `--output-policy` values, mirroring `TessavakCore.OutputPolicy`.
enum OutputPolicyOption: String, ExpressibleByArgument, CaseIterable {
    case preserveMixed, gujaratiScript, bapsRoman

    var outputPolicy: OutputPolicy {
        switch self {
        case .preserveMixed: return .preserveMixed
        case .gujaratiScript: return .gujaratiScript
        case .bapsRoman: return .bapsRoman
        }
    }
}

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe a 16 kHz mono 16-bit PCM WAV file through the live pipeline."
    )

    @Option(name: .long, help: "Path to the recogniser model file.")
    var model: String

    @Option(name: .long, help: "Path to a 16 kHz mono 16-bit PCM WAV file.")
    var audio: String

    @Option(name: .long, help: "Session policy: interactive or meeting.")
    var policy: PolicyOption = .interactive

    @Option(name: .long, help: "Language hint: auto, en, or gu.")
    var language: LanguageOption = .auto

    @Option(name: .customLong("output-policy"), help: "Output rendering policy.")
    var outputPolicy: OutputPolicyOption = .preserveMixed

    mutating func run() async throws {
        try await TranscribeRunner.run(
            modelPath: model,
            audioPath: audio,
            policy: policy,
            language: language,
            outputPolicy: outputPolicy
        )
    }
}
