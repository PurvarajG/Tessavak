import Foundation
import VaaniCore

public protocol Recognizer: Sendable {
    func candidates(for utteranceID: String) async throws -> [RecognitionCandidate]
}

public struct ReplayUtterance: Codable, Equatable, Sendable {
    public let id: String
    public let observations: [EvidenceObservation]
    public let candidates: [RecognitionCandidate]
    public let expectedText: String
    public let expectedRoute: Route
    public let subset: String

    public init(
        id: String,
        observations: [EvidenceObservation],
        candidates: [RecognitionCandidate],
        expectedText: String,
        expectedRoute: Route,
        subset: String
    ) {
        self.id = id
        self.observations = observations
        self.candidates = candidates
        self.expectedText = expectedText
        self.expectedRoute = expectedRoute
        self.subset = subset
    }
}

public struct ReplayManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let utterances: [ReplayUtterance]

    public init(schemaVersion: Int, utterances: [ReplayUtterance]) {
        self.schemaVersion = schemaVersion
        self.utterances = utterances
    }
}

public enum VaaniAdapterError: Error, Equatable, Sendable {
    case duplicateUtteranceID(String)
    case unknownUtteranceID(String)
}

/// A deterministic `Recognizer` backed by a fixed replay manifest. Used to
/// exercise the full detection/routing/scoring/correction pipeline against
/// checked-in fixtures without any real audio capture or model inference.
public actor ReplayRecognizer: Recognizer {
    private let utterancesByID: [String: ReplayUtterance]

    public init(manifest: ReplayManifest) throws {
        var index: [String: ReplayUtterance] = [:]
        for utterance in manifest.utterances {
            guard index[utterance.id] == nil else {
                throw VaaniAdapterError.duplicateUtteranceID(utterance.id)
            }
            index[utterance.id] = utterance
        }
        self.utterancesByID = index
    }

    public func candidates(for utteranceID: String) async throws -> [RecognitionCandidate] {
        guard let utterance = utterancesByID[utteranceID] else {
            throw VaaniAdapterError.unknownUtteranceID(utteranceID)
        }
        return utterance.candidates
    }
}
