import Foundation
@preconcurrency import SwiftWhisper
import TessavakCore

/// The language whisper should prefer while decoding an utterance.
public enum WhisperLanguageHint: String, Codable, Sendable {
    case auto
    case english = "en"
    case gujarati = "gu"

    public init(value: String) throws {
        guard let hint = Self(rawValue: value) else {
            throw TessavakCoreError.invalidConfiguration(
                "whisper language hint must be en, gu, or auto"
            )
        }
        self = hint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(value: try container.decode(String.self))
    }
}

/// A whole-utterance whisper.cpp recogniser.
///
/// The underlying SwiftWhisper context is confined to `WhisperSession`, which
/// serializes decode calls because a whisper context may process only one
/// utterance at a time.
public struct WhisperRecognizer: StreamingRecognizer {
    public let identity: ModelIdentity

    private let languageHint: WhisperLanguageHint
    private let session: WhisperSession

    public init(modelFileURL: URL, languageHint: WhisperLanguageHint) throws {
        guard modelFileURL.isFileURL else {
            throw TessavakCoreError.invalidConfiguration("whisper model URL must be a file URL")
        }
        guard FileManager.default.fileExists(atPath: modelFileURL.path) else {
            throw TessavakCoreError.invalidConfiguration("whisper model file does not exist")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: modelFileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw TessavakCoreError.invalidConfiguration("whisper model URL must identify a regular file")
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            throw TessavakCoreError.invalidConfiguration("whisper model file must not be empty")
        }

        try Self.requireGGMLMagic(at: modelFileURL)

        let modelName = modelFileURL.deletingPathExtension().lastPathComponent
        self.identity = try ModelIdentity(
            provider: "whisper.cpp",
            name: modelName,
            version: Self.pinnedRevision
        )
        self.languageHint = languageHint
        self.session = WhisperSession(modelFileURL: modelFileURL, languageHint: languageHint)
    }

    public func recognize(
        _ audio: AsyncThrowingStream<AudioChunk, Error>
    ) -> AsyncThrowingStream<RecognitionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let samples = try await Self.bufferedSamples(from: audio)
                    try Task.checkCancellation()
                    let decoded = try await session.decode(samples: samples)
                    try Task.checkCancellation()

                    let candidate = try RecognitionCandidate(
                        id: "\(identity.name)-final",
                        text: decoded.text,
                        confidence: decoded.confidence,
                        detectedLanguages: languageDistribution,
                        segments: decoded.segments,
                        model: identity,
                        latencyMilliseconds: 0
                    )
                    continuation.yield(RecognitionUpdate(candidate: candidate, isFinal: true))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let pinnedRevision = "c340197966ebd264f3135d3955874b40f8ed58bc"

    /// The vendored loader reads the first four bytes as a little-endian
    /// `uint32` and rejects anything but this value (`whisper_model_load`,
    /// "verify magic"). It does so by returning `false`, which SwiftWhisper
    /// force-unwraps into a trap — so the check has to happen here, before a
    /// context is ever constructed.
    private static let ggmlMagic: UInt32 = 0x6767_6d6c

    /// Reads only the 4-byte header, never the model body: a `.bin` model is
    /// hundreds of megabytes and this runs before every session.
    ///
    /// This is a header check and nothing more. A file with valid magic whose
    /// contents are corrupt or truncated still traps inside the loader.
    private static func requireGGMLMagic(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = Array((try handle.read(upToCount: 4)) ?? Data())
        guard header.count == 4 else {
            throw TessavakCoreError.invalidConfiguration(
                "whisper model file is too short to identify: needed 4 magic bytes, read \(header.count)"
            )
        }

        let magic =
            UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16
            | UInt32(header[3]) << 24
        guard magic != ggmlMagic else { return }

        if header == Array("GGUF".utf8) {
            throw TessavakCoreError.invalidConfiguration(
                "whisper model file is in GGUF format; this build vendors a pre-GGUF "
                    + "whisper.cpp and requires a ggml-*.bin model"
            )
        }
        let found = header.map { String(format: "%02x", $0) }.joined(separator: " ")
        throw TessavakCoreError.invalidConfiguration(
            "whisper model file is not a ggml whisper model: expected magic 6c 6d 67 67, found \(found)"
        )
    }

    private var languageDistribution: LanguageDistribution {
        // SwiftWhisper passes `.auto` through to whisper.cpp, but its public
        // API does not surface the resulting language ID. Preserve that lack
        // of a confidence-bearing result as `other`, rather than inventing a
        // detected language.
        let value: [LanguageTag: Double] =
            switch languageHint {
            case .english: [.english: 1]
            case .gujarati: [.gujarati: 1]
            case .auto: [.other: 1]
            }
        // Every branch above is a complete probability distribution.
        return try! LanguageDistribution(values: value)
    }

    private static func bufferedSamples(
        from audio: AsyncThrowingStream<AudioChunk, Error>
    ) async throws -> [Float] {
        var samples: [Float] = []
        for try await chunk in audio {
            guard chunk.format == .canonical else {
                throw TessavakCoreError.invalidAudioFormat(
                    "whisper recognizer requires canonical 16 kHz mono PCM"
                )
            }
            samples.reserveCapacity(samples.count + chunk.samples.count)
            samples.append(contentsOf: chunk.samples.map { Float($0) / 32_768 })
        }
        return samples
    }
}

private struct WhisperDecodeResult: Sendable {
    let text: String
    /// Always `nil`: SwiftWhisper's `Segment` exposes only start time, end
    /// time, and text, so there is no confidence signal to report. `nil` says
    /// "unknown"; reporting 0 would say "certainly bad".
    let confidence: Double?
    let segments: [RecognitionSegment]
}

private actor WhisperSession {
    private let whisper: Whisper
    private var decoding = false
    private var waitingDecoders: [CheckedContinuation<Void, Never>] = []

    init(modelFileURL: URL, languageHint: WhisperLanguageHint) {
        let parameters = WhisperParams()
        parameters.language =
            switch languageHint {
            case .auto: .auto
            case .english: .english
            case .gujarati: .gujarati
            }
        self.whisper = Whisper(fromFileURL: modelFileURL, withParams: parameters)
    }

    func decode(samples: [Float]) async throws -> WhisperDecodeResult {
        await acquireDecoder()
        defer { releaseDecoder() }

        let decodedSegments = try await withTaskCancellationHandler(
            operation: {
                try await whisper.transcribe(audioFrames: samples)
            },
            onCancel: {
                Task { await self.cancelInFlightDecode() }
            }
        )
        let segments = try decodedSegments.map { segment in
            try RecognitionSegment(
                text: segment.text,
                startMilliseconds: Int64(segment.startTime),
                endMilliseconds: Int64(segment.endTime),
                confidence: nil
            )
        }
        return WhisperDecodeResult(
            text: segments.map(\.text).joined(),
            confidence: nil,
            segments: segments
        )
    }

    private func cancelInFlightDecode() async {
        guard whisper.inProgress else { return }
        try? await whisper.cancel()
    }

    private func acquireDecoder() async {
        guard decoding else {
            decoding = true
            return
        }
        await withCheckedContinuation { continuation in
            waitingDecoders.append(continuation)
        }
    }

    private func releaseDecoder() {
        guard let next = waitingDecoders.first else {
            decoding = false
            return
        }
        waitingDecoders.removeFirst()
        next.resume()
    }
}
