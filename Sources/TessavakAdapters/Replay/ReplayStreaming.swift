import Foundation
import TessavakCore

/// Serves one stored replay candidate through the live `StreamingRecognizer`
/// contract.
///
/// The audio stream is drained and discarded: replay fixtures carry no audio,
/// and the point of this shim is to prove the live orchestration path is
/// exercisable offline, before any real model exists.
public struct ReplayStreamingRecognizer: StreamingRecognizer {
    public let identity: ModelIdentity
    private let candidate: RecognitionCandidate

    public init(candidate: RecognitionCandidate) {
        self.identity = candidate.model
        self.candidate = candidate
    }

    public func recognize(
        _ audio: AsyncThrowingStream<AudioChunk, Error>
    ) -> AsyncThrowingStream<RecognitionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await _ in audio {}
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

extension ReplayStreamingRecognizer {
    /// Builds the route lookup a `LivePipelineCoordinator` needs for one
    /// replay utterance.
    ///
    /// With two or more stored candidates the first serves the English route
    /// and the second the multilingual route, which reproduces the dual-decode
    /// comparison the benchmark performs. A lone candidate answers whichever
    /// route is asked for. This is a fixture convention for offline testing,
    /// not a claim about how real models map to routes.
    public static func routeLookup(
        for utterance: ReplayUtterance
    ) -> @Sendable (Route) -> (any StreamingRecognizer)? {
        let candidates = utterance.candidates
        return { route in
            guard candidates.count > 1 else {
                return candidates.first.map { ReplayStreamingRecognizer(candidate: $0) }
            }
            switch route {
            case .englishStreaming:
                return ReplayStreamingRecognizer(candidate: candidates[0])
            case .multilingual:
                return ReplayStreamingRecognizer(candidate: candidates[1])
            case .dual:
                return nil
            }
        }
    }
}

/// Replays an utterance's stored observations as the coordinator consumes
/// audio: one observation per chunk, in fixture order, nothing on stream
/// boundaries.
public actor ReplayDetector: Detector {
    private var pending: [EvidenceObservation]

    public init(utterance: ReplayUtterance) {
        self.pending = utterance.observations
    }

    public func observations(for event: SpeechEvent, provisionalText: String?) async throws
        -> [EvidenceObservation]
    {
        guard case .chunk = event, !pending.isEmpty else { return [] }
        return [pending.removeFirst()]
    }
}
