import Foundation

/// Turns stream events — and any provisional text a recogniser has produced so
/// far — into evidence observations for the accumulator.
///
/// Implementations are pure with respect to any state the caller injects: the
/// coordinator owns the `EvidenceAccumulator` and decides how observations are
/// weighted over an utterance.
public protocol Detector: Sendable {
    func observations(
        for event: SpeechEvent,
        provisionalText: String?
    ) async throws -> [EvidenceObservation]
}
