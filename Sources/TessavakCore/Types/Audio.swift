import Foundation

/// Describes the PCM layout every TessavakCore audio path speaks.
///
/// The engine is deliberately narrow here: recognisers and detectors are
/// written against one canonical format, and adapters resample at their own
/// boundary rather than pushing format variance into the core.
public struct AudioFormat: Codable, Equatable, Hashable, Sendable {
    /// 16 kHz mono 16-bit PCM — the format every bundled recogniser expects.
    public static let canonical = AudioFormat(
        uncheckedSampleRateHertz: 16_000,
        channelCount: 1,
        bitsPerSample: 16
    )

    private static let supportedBitsPerSample = 16

    public let sampleRateHertz: Int
    public let channelCount: Int
    public let bitsPerSample: Int

    public init(sampleRateHertz: Int, channelCount: Int, bitsPerSample: Int) throws {
        guard sampleRateHertz > 0 else {
            throw TessavakCoreError.invalidAudioFormat(
                "sampleRateHertz must be positive, got \(sampleRateHertz)"
            )
        }
        guard channelCount == 1 else {
            throw TessavakCoreError.invalidAudioFormat(
                "only mono audio is supported, got \(channelCount) channels"
            )
        }
        guard bitsPerSample == Self.supportedBitsPerSample else {
            throw TessavakCoreError.invalidAudioFormat(
                "only \(Self.supportedBitsPerSample)-bit samples are supported, got \(bitsPerSample)"
            )
        }
        self.sampleRateHertz = sampleRateHertz
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
    }

    /// Compile-time-known valid values only, so `canonical` needs no `try`.
    private init(uncheckedSampleRateHertz: Int, channelCount: Int, bitsPerSample: Int) {
        self.sampleRateHertz = uncheckedSampleRateHertz
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRateHertz, channelCount, bitsPerSample
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sampleRateHertz: try container.decode(Int.self, forKey: .sampleRateHertz),
            channelCount: try container.decode(Int.self, forKey: .channelCount),
            bitsPerSample: try container.decode(Int.self, forKey: .bitsPerSample)
        )
    }
}

/// One contiguous span of captured audio.
///
/// `AudioChunk` is intentionally **not** `Codable`: audio never enters a JSON
/// report, a diagnostic event, or any other serialised artefact.
public struct AudioChunk: Equatable, Sendable {
    /// Frame counts rarely land on a whole millisecond, so callers may round
    /// the reported end time in either direction by up to this much.
    private static let durationToleranceMilliseconds = 1.0

    public let format: AudioFormat
    public let frameCount: Int
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let samples: [Int16]

    public init(
        format: AudioFormat,
        frameCount: Int,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        samples: [Int16]
    ) throws {
        guard frameCount > 0 else {
            throw TessavakCoreError.invalidAudioChunk("frameCount must be positive, got \(frameCount)")
        }
        guard startMilliseconds >= 0, endMilliseconds >= startMilliseconds else {
            throw TessavakCoreError.invalidTimeRange(start: startMilliseconds, end: endMilliseconds)
        }
        let expectedSampleCount = frameCount * format.channelCount
        guard samples.count == expectedSampleCount else {
            throw TessavakCoreError.invalidAudioChunk(
                "expected \(expectedSampleCount) samples for \(frameCount) frames, got \(samples.count)"
            )
        }
        let expectedDuration = Double(frameCount) * 1000 / Double(format.sampleRateHertz)
        let reportedDuration = Double(endMilliseconds - startMilliseconds)
        guard abs(reportedDuration - expectedDuration) <= Self.durationToleranceMilliseconds else {
            throw TessavakCoreError.invalidAudioChunk(
                "\(frameCount) frames at \(format.sampleRateHertz) Hz is "
                    + "\(expectedDuration) ms, but the range spans \(reportedDuration) ms"
            )
        }
        self.format = format
        self.frameCount = frameCount
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.samples = samples
    }

    public var durationMilliseconds: Int64 {
        endMilliseconds - startMilliseconds
    }
}

/// One item in an utterance's audio stream.
///
/// Ordering invariants — no chunk before `speechStarted`, monotonic
/// timestamps, nothing after `endOfStream` — belong to the pipeline
/// coordinator that consumes the stream, not to this enum.
public enum SpeechEvent: Equatable, Sendable {
    case speechStarted(atMilliseconds: Int64)
    case chunk(AudioChunk)
    case speechEnded(atMilliseconds: Int64)
    case endOfStream
}
