import Foundation
import VaaniCore

/// Wraps one decoded WAV file as the `SpeechEvent` sequence for exactly one
/// utterance: `speechStarted` at 0 ms, fixed-size chunks, `speechEnded`, then
/// `endOfStream`. `LivePipelineCoordinator` validates ordering and monotonic
/// timestamps strictly, so every boundary here is derived from the same
/// frame-offset-to-milliseconds formula on both sides of a chunk boundary —
/// that keeps a chunk's reported end exactly equal to the next chunk's
/// reported start, satisfying the coordinator's `next >= previous` check
/// even though millisecond rounding is not exact at 16 kHz for
/// non-multiple-of-16 frame offsets.
enum SpeechEventBuilder {
    /// 100 ms per chunk at 16 kHz — a chunk count high enough to look like a
    /// real stream, small enough to keep tests and file-driven runs fast.
    static let defaultChunkFrameCount = 1_600

    static func buildEvents(
        samples: [Int16],
        chunkFrameCount: Int = defaultChunkFrameCount
    ) throws -> [SpeechEvent] {
        precondition(chunkFrameCount > 0, "chunkFrameCount must be positive")
        let sampleRate = AudioFormat.canonical.sampleRateHertz
        func milliseconds(atFrame frame: Int) -> Int64 {
            Int64((Double(frame) * 1_000 / Double(sampleRate)).rounded())
        }

        var events: [SpeechEvent] = [.speechStarted(atMilliseconds: 0)]
        let totalFrames = samples.count
        var offset = 0
        while offset < totalFrames {
            let count = min(chunkFrameCount, totalFrames - offset)
            let chunkSamples = Array(samples[offset..<(offset + count)])
            let chunk = try AudioChunk(
                format: .canonical,
                frameCount: count,
                startMilliseconds: milliseconds(atFrame: offset),
                endMilliseconds: milliseconds(atFrame: offset + count),
                samples: chunkSamples
            )
            events.append(.chunk(chunk))
            offset += count
        }
        events.append(.speechEnded(atMilliseconds: milliseconds(atFrame: totalFrames)))
        events.append(.endOfStream)
        return events
    }

    static func stream(from events: [SpeechEvent]) -> AsyncStream<SpeechEvent> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
