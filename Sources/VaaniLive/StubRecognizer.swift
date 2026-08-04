import Foundation
import VaaniCore

/// Placeholder `StreamingRecognizer` used until a real recogniser is wired
/// in. It drains the audio stream (so timing/backpressure behaviour matches
/// a real recogniser) and yields exactly one final, clearly-fake candidate.
///
/// `TranscribeRunner` prints an unmissable warning whenever this recogniser
/// produced the printed transcript — never silently pass this text off as a
/// real transcription.
struct StubStreamingRecognizer: StreamingRecognizer {
    static let placeholderText = "[STUB TRANSCRIPT — no recognizer wired yet]"

    let identity: ModelIdentity

    init() throws {
        identity = try ModelIdentity(provider: "vaani-live-stub", name: "no-recognizer-wired", version: "0")
    }

    func recognize(
        _ audio: AsyncThrowingStream<AudioChunk, Error>
    ) -> AsyncThrowingStream<RecognitionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await _ in audio {}
                    let candidate = try RecognitionCandidate(
                        id: "stub-0",
                        text: Self.placeholderText,
                        confidence: 0.5,
                        detectedLanguages: try LanguageDistribution(values: [.other: 1.0]),
                        segments: [],
                        model: identity,
                        latencyMilliseconds: 0
                    )
                    continuation.yield(RecognitionUpdate(candidate: candidate, isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Builds the recogniser lookup `LivePipelineCoordinator` needs.
///
/// ================================================================
/// SEAM FOR TASK 7 (built in a separate worktree; do not touch here):
/// replace the body of `makeRecognizerFactory` with one that constructs
/// `VaaniWhisper.WhisperRecognizer(modelPath: modelPath, language: language)`
/// and returns it for every route (single-model routing; real dual-model
/// routing is Phase 3). `modelPath` and `language` are already threaded
/// through from the CLI for exactly this purpose — nothing else in
/// `vaani-live` needs to change.
/// ================================================================
func makeRecognizerFactory(
    modelPath: String,
    language: LanguageOption
) throws -> @Sendable (Route) -> (any StreamingRecognizer)? {
    let recognizer = try StubStreamingRecognizer()
    return { _ in recognizer }
}
