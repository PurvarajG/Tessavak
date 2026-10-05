import Foundation

/// A fixture-backed source of pre-computed candidates for one utterance.
///
/// This is the Phase 1 replay contract, unchanged in shape; it exists so the
/// benchmark path can keep running without audio. Live adapters implement
/// `StreamingRecognizer` instead.
public protocol ReplayCandidateSource: Sendable {
    func candidates(for utteranceID: String) async throws -> [RecognitionCandidate]
}

/// One recognition result on the way to a final transcript.
///
/// Partial updates may be superseded; exactly one final update ends an
/// utterance's stream.
public struct RecognitionUpdate: Equatable, Sendable {
    public let candidate: RecognitionCandidate
    public let isFinal: Bool

    public init(candidate: RecognitionCandidate, isFinal: Bool) {
        self.candidate = candidate
        self.isFinal = isFinal
    }
}

/// A live recogniser: consumes one utterance's audio and yields partial then
/// final updates.
///
/// Contract, enforced by the adapter-agnostic suite in `TessavakAdaptersTests`:
/// - at least one update is final, and no update follows the final one;
/// - every candidate carries a non-empty `ModelIdentity` and id;
/// - the update stream always terminates, including when the consuming task
///   is cancelled.
public protocol StreamingRecognizer: Sendable {
    var identity: ModelIdentity { get }

    func recognize(
        _ audio: AsyncThrowingStream<AudioChunk, Error>
    ) -> AsyncThrowingStream<RecognitionUpdate, Error>
}
