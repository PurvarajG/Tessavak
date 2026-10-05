import Foundation
import Testing

@testable import TessavakCore

@Suite struct AudioTypesTests {

    // MARK: - Helpers

    private func samples(_ count: Int) -> [Int16] {
        Array(repeating: 0, count: count)
    }

    /// One canonical-format chunk: 16 kHz mono, `frames` frames starting at `start` ms.
    private func canonicalChunk(frames: Int, start: Int64) throws -> AudioChunk {
        try AudioChunk(
            format: .canonical,
            frameCount: frames,
            startMilliseconds: start,
            endMilliseconds: start + Int64(frames * 1000 / AudioFormat.canonical.sampleRateHertz),
            samples: samples(frames)
        )
    }

    // MARK: - AudioFormat

    @Test func canonicalFormatIs16kHzMono16Bit() {
        #expect(AudioFormat.canonical.sampleRateHertz == 16_000)
        #expect(AudioFormat.canonical.channelCount == 1)
        #expect(AudioFormat.canonical.bitsPerSample == 16)
    }

    @Test func formatRejectsNonPositiveSampleRate() {
        #expect(throws: (any Error).self) {
            try AudioFormat(sampleRateHertz: 0, channelCount: 1, bitsPerSample: 16)
        }
        #expect(throws: (any Error).self) {
            try AudioFormat(sampleRateHertz: -16_000, channelCount: 1, bitsPerSample: 16)
        }
    }

    @Test func formatRejectsMultipleChannels() {
        #expect(throws: (any Error).self) {
            try AudioFormat(sampleRateHertz: 16_000, channelCount: 2, bitsPerSample: 16)
        }
    }

    @Test func formatRejectsUnsupportedSampleWidth() {
        #expect(throws: (any Error).self) {
            try AudioFormat(sampleRateHertz: 16_000, channelCount: 1, bitsPerSample: 24)
        }
    }

    @Test func formatRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(AudioFormat.canonical)
        let decoded = try JSONDecoder().decode(AudioFormat.self, from: data)
        #expect(decoded == AudioFormat.canonical)
    }

    @Test func formatJSONDecodingCannotBypassValidation() {
        let badJSON = Data(#"{"sampleRateHertz": 16000, "channelCount": 2, "bitsPerSample": 16}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AudioFormat.self, from: badJSON)
        }
    }

    // MARK: - AudioChunk

    @Test func chunkAcceptsConsistentFramesAndTimeRange() throws {
        let chunk = try canonicalChunk(frames: 160, start: 0)
        #expect(chunk.frameCount == 160)
        #expect(chunk.startMilliseconds == 0)
        #expect(chunk.endMilliseconds == 10)
        #expect(chunk.samples.count == 160)
        #expect(chunk.durationMilliseconds == 10)
    }

    @Test func chunkRejectsNonPositiveFrameCount() {
        #expect(throws: (any Error).self) {
            try AudioChunk(
                format: .canonical,
                frameCount: 0,
                startMilliseconds: 0,
                endMilliseconds: 0,
                samples: []
            )
        }
    }

    @Test func chunkRejectsNegativeStart() {
        #expect(throws: (any Error).self) {
            try AudioChunk(
                format: .canonical,
                frameCount: 160,
                startMilliseconds: -10,
                endMilliseconds: 0,
                samples: samples(160)
            )
        }
    }

    @Test func chunkRejectsNonMonotonicTimeRange() {
        #expect(throws: (any Error).self) {
            try AudioChunk(
                format: .canonical,
                frameCount: 160,
                startMilliseconds: 20,
                endMilliseconds: 10,
                samples: samples(160)
            )
        }
    }

    @Test func chunkRejectsSampleCountMismatchedToFrames() {
        #expect(throws: (any Error).self) {
            try AudioChunk(
                format: .canonical,
                frameCount: 160,
                startMilliseconds: 0,
                endMilliseconds: 10,
                samples: samples(159)
            )
        }
    }

    @Test func chunkRejectsDurationInconsistentWithFrameCount() {
        // 160 frames at 16 kHz is 10 ms; 50 ms is far outside the ±1 ms tolerance.
        #expect(throws: (any Error).self) {
            try AudioChunk(
                format: .canonical,
                frameCount: 160,
                startMilliseconds: 0,
                endMilliseconds: 50,
                samples: samples(160)
            )
        }
    }

    @Test func chunkAllowsRoundingWithinOneMillisecond() throws {
        // 161 frames at 16 kHz is 10.0625 ms; both 10 ms and 11 ms are within tolerance.
        let rounded = try AudioChunk(
            format: .canonical,
            frameCount: 161,
            startMilliseconds: 0,
            endMilliseconds: 10,
            samples: samples(161)
        )
        #expect(rounded.frameCount == 161)

        let roundedUp = try AudioChunk(
            format: .canonical,
            frameCount: 161,
            startMilliseconds: 0,
            endMilliseconds: 11,
            samples: samples(161)
        )
        #expect(roundedUp.endMilliseconds == 11)
    }

    @Test func chunkHonoursNonCanonicalSampleRate() throws {
        let format = try AudioFormat(sampleRateHertz: 8_000, channelCount: 1, bitsPerSample: 16)
        let chunk = try AudioChunk(
            format: format,
            frameCount: 80,
            startMilliseconds: 100,
            endMilliseconds: 110,
            samples: samples(80)
        )
        #expect(chunk.durationMilliseconds == 10)

        // The same frame count at 16 kHz would be 5 ms, so it must fail against this format.
        #expect(throws: (any Error).self) {
            try AudioChunk(
                format: format,
                frameCount: 80,
                startMilliseconds: 100,
                endMilliseconds: 105,
                samples: samples(80)
            )
        }
    }

    // MARK: - SpeechEvent

    @Test func speechEventCarriesChunkAndBoundaries() throws {
        let chunk = try canonicalChunk(frames: 160, start: 10)
        let events: [SpeechEvent] = [
            .speechStarted(atMilliseconds: 0),
            .chunk(chunk),
            .speechEnded(atMilliseconds: 20),
            .endOfStream,
        ]

        guard case .speechStarted(let start) = events[0] else {
            Issue.record("expected speechStarted")
            return
        }
        #expect(start == 0)

        guard case .chunk(let carried) = events[1] else {
            Issue.record("expected chunk")
            return
        }
        #expect(carried == chunk)

        guard case .speechEnded(let end) = events[2] else {
            Issue.record("expected speechEnded")
            return
        }
        #expect(end == 20)

        #expect(events[3] == .endOfStream)
    }

    @Test func speechEventDoesNotValidateOrdering() throws {
        // Ordering is the coordinator's job (Task 4); the enum itself accepts any sequence.
        let chunk = try canonicalChunk(frames: 160, start: 0)
        let outOfOrder: [SpeechEvent] = [.chunk(chunk), .speechStarted(atMilliseconds: 100)]
        #expect(outOfOrder.count == 2)
    }
}
