import Foundation
import VaaniCore

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
    ) throws {
        guard !id.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("replay utterance id must not be empty")
        }
        guard !subset.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("replay utterance \(id) subset must not be empty")
        }
        guard !observations.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("replay utterance \(id) observations must not be empty")
        }
        guard !candidates.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("replay utterance \(id) candidates must not be empty")
        }
        self.id = id
        self.observations = observations
        self.candidates = candidates
        self.expectedText = expectedText
        self.expectedRoute = expectedRoute
        self.subset = subset
    }

    private enum CodingKeys: String, CodingKey {
        case id, observations, candidates, expectedText, expectedRoute, subset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            observations: try container.decode([EvidenceObservation].self, forKey: .observations),
            candidates: try container.decode([RecognitionCandidate].self, forKey: .candidates),
            expectedText: try container.decode(String.self, forKey: .expectedText),
            expectedRoute: try container.decode(Route.self, forKey: .expectedRoute),
            subset: try container.decode(String.self, forKey: .subset)
        )
    }
}

public enum VaaniAdapterError: Error, Equatable, Sendable {
    case duplicateUtteranceID(String)
    case unknownUtteranceID(String)
}

public struct ReplayManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let utterances: [ReplayUtterance]

    public init(schemaVersion: Int, utterances: [ReplayUtterance]) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw VaaniCoreError.invalidConfiguration(
                "unsupported replay manifest schemaVersion \(schemaVersion); expected \(Self.supportedSchemaVersion)"
            )
        }
        guard !utterances.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("replay manifest utterances must not be empty")
        }
        var seenIDs: Set<String> = []
        for utterance in utterances {
            guard !seenIDs.contains(utterance.id) else {
                throw VaaniAdapterError.duplicateUtteranceID(utterance.id)
            }
            seenIDs.insert(utterance.id)
        }
        self.schemaVersion = schemaVersion
        self.utterances = utterances
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, utterances
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            utterances: try container.decode([ReplayUtterance].self, forKey: .utterances)
        )
    }
}

/// A deterministic `ReplayCandidateSource` backed by a fixed replay manifest.
/// Used to exercise the full detection/routing/scoring/correction pipeline
/// against checked-in fixtures without any real audio capture or model
/// inference.
public actor ReplayRecognizer: ReplayCandidateSource {
    private let utterancesByID: [String: ReplayUtterance]

    public init(manifest: ReplayManifest) throws {
        // ReplayManifest already guarantees unique utterance IDs at
        // construction/decode time; this only builds the lookup index.
        var index: [String: ReplayUtterance] = [:]
        for utterance in manifest.utterances {
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
