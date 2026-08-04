import Foundation
import Testing

@testable import VaaniLive

@Suite struct WAVFileTests {

    // MARK: - Byte-level WAV builder

    /// Hand-builds minimal WAV bytes so tests don't depend on any file on
    /// disk. `extraChunk`, when supplied, is spliced in between 'fmt ' and
    /// 'data' to prove the parser walks chunks rather than assuming a fixed
    /// layout.
    private func wavBytes(
        audioFormatTag: UInt16 = 1,
        channelCount: UInt16 = 1,
        sampleRate: UInt32 = 16_000,
        bitsPerSample: UInt16 = 16,
        pcmSamples: [Int16] = [0, 100, -100, 32_767, -32_768],
        extraChunk: (id: String, data: [UInt8])? = nil
    ) -> Data {
        var fmtChunk = Data()
        fmtChunk.append(le(audioFormatTag))
        fmtChunk.append(le(channelCount))
        fmtChunk.append(le(sampleRate))
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample) / 8
        fmtChunk.append(le(byteRate))
        let blockAlign = channelCount * bitsPerSample / 8
        fmtChunk.append(le(blockAlign))
        fmtChunk.append(le(bitsPerSample))

        var dataChunk = Data()
        for sample in pcmSamples {
            dataChunk.append(le(UInt16(bitPattern: sample)))
        }

        var body = Data()
        body.append(chunk(id: "fmt ", payload: fmtChunk))
        if let extraChunk {
            body.append(chunk(id: extraChunk.id, payload: Data(extraChunk.data)))
        }
        body.append(chunk(id: "data", payload: dataChunk))

        var file = Data()
        file.append(Data("RIFF".utf8))
        file.append(le(UInt32(4 + body.count)))
        file.append(Data("WAVE".utf8))
        file.append(body)
        return file
    }

    private func chunk(id: String, payload: Data) -> Data {
        precondition(id.utf8.count == 4)
        var result = Data(id.utf8)
        result.append(le(UInt32(payload.count)))
        result.append(payload)
        if payload.count % 2 != 0 {
            result.append(0)
        }
        return result
    }

    private func le(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private func le(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    // MARK: - Valid files

    @Test func validFileRoundTripsToExpectedFrames() throws {
        let samples: [Int16] = [0, 100, -100, 32_767, -32_768]
        let wav = try WAVFile(data: wavBytes(pcmSamples: samples))
        #expect(wav.sampleRateHertz == 16_000)
        #expect(wav.channelCount == 1)
        #expect(wav.bitsPerSample == 16)
        #expect(wav.samples == samples)
    }

    @Test func parserWalksChunksAroundAnUnknownExtraChunk() throws {
        let samples: [Int16] = [1, 2, 3]
        let wav = try WAVFile(
            data: wavBytes(pcmSamples: samples, extraChunk: (id: "LIST", data: [0x01, 0x02, 0x03]))
        )
        #expect(wav.samples == samples)
    }

    @Test func parserHandlesOddSizedExtraChunkPadding() throws {
        // A 3-byte payload chunk is padded to 4 bytes in the file; the
        // parser must skip the pad byte to find 'data' afterward.
        let samples: [Int16] = [42]
        let wav = try WAVFile(
            data: wavBytes(pcmSamples: samples, extraChunk: (id: "fact", data: [0xAA, 0xBB, 0xCC]))
        )
        #expect(wav.samples == samples)
    }

    // MARK: - Format rejections

    @Test func rejectsWrongSampleRate() {
        #expect(throws: WAVFileError.unsupportedSampleRate(44_100)) {
            try WAVFile(data: wavBytes(sampleRate: 44_100))
        }
    }

    @Test func rejectsWrongChannelCount() {
        #expect(throws: WAVFileError.unsupportedChannelCount(2)) {
            try WAVFile(data: wavBytes(channelCount: 2))
        }
    }

    @Test func rejectsWrongBitDepth() {
        #expect(throws: WAVFileError.unsupportedBitsPerSample(8)) {
            try WAVFile(data: wavBytes(bitsPerSample: 8, pcmSamples: []))
        }
    }

    @Test func rejectsNonPCMFormatTag() {
        #expect(throws: WAVFileError.unsupportedAudioFormatTag(3)) {
            try WAVFile(data: wavBytes(audioFormatTag: 3))
        }
    }

    @Test func rejectsEmptyAudio() {
        #expect(throws: WAVFileError.emptyAudio) {
            try WAVFile(data: wavBytes(pcmSamples: []))
        }
    }

    // MARK: - Malformed / truncated / garbage input

    @Test func rejectsTruncatedHeader() {
        #expect(throws: WAVFileError.truncatedHeader) {
            try WAVFile(data: Data([0x52, 0x49, 0x46]))
        }
    }

    @Test func rejectsGarbageThatIsNotRIFF() {
        #expect(throws: WAVFileError.notRIFF) {
            try WAVFile(data: Data(repeating: 0xFF, count: 64))
        }
    }

    @Test func rejectsRIFFThatIsNotWAVE() {
        var bytes = Data("RIFF".utf8)
        bytes.append(le(UInt32(4)))
        bytes.append(Data("FAKE".utf8))
        #expect(throws: WAVFileError.notWAVE) {
            try WAVFile(data: bytes)
        }
    }

    @Test func rejectsMissingFormatChunk() {
        var body = Data()
        body.append(chunk(id: "data", payload: Data([0, 0])))
        var file = Data("RIFF".utf8)
        file.append(le(UInt32(4 + body.count)))
        file.append(Data("WAVE".utf8))
        file.append(body)
        #expect(throws: WAVFileError.missingFormatChunk) {
            try WAVFile(data: file)
        }
    }

    @Test func rejectsMissingDataChunk() {
        let fmtOnly = wavBytes(pcmSamples: [1])
        // Strip the trailing 'data' chunk (fmt chunk is 8 + 16 = 24 bytes
        // after the 12-byte RIFF header).
        let truncated = fmtOnly.prefix(12 + 24)
        #expect(throws: WAVFileError.missingDataChunk) {
            try WAVFile(data: truncated)
        }
    }

    @Test func rejectsTruncatedDataChunk() {
        var body = Data()
        let fmt = wavBytes(pcmSamples: [1]).dropFirst(12).prefix(24)
        body.append(fmt)
        // Claim a data chunk of 100 bytes but supply none.
        body.append(Data("data".utf8))
        body.append(le(UInt32(100)))
        var file = Data("RIFF".utf8)
        file.append(le(UInt32(4 + body.count)))
        file.append(Data("WAVE".utf8))
        file.append(body)
        #expect(throws: WAVFileError.truncatedDataChunk) {
            try WAVFile(data: file)
        }
    }

    @Test func rejectsOddLengthPCMData() {
        var body = Data()
        let fmt = wavBytes(pcmSamples: [1]).dropFirst(12).prefix(24)
        body.append(fmt)
        body.append(Data("data".utf8))
        body.append(le(UInt32(3)))
        body.append(Data([1, 2, 3]))
        var file = Data("RIFF".utf8)
        file.append(le(UInt32(4 + body.count)))
        file.append(Data("WAVE".utf8))
        file.append(body)
        #expect(throws: WAVFileError.oddLengthPCMData(byteCount: 3)) {
            try WAVFile(data: file)
        }
    }

    // MARK: - Error messages

    @Test func formatErrorsMentionFFmpegConversion() {
        #expect(WAVFileError.unsupportedSampleRate(8_000).userMessage.contains("ffmpeg"))
        #expect(WAVFileError.unsupportedSampleRate(8_000).userMessage.contains("-ar 16000 -ac 1"))
        #expect(WAVFileError.unsupportedChannelCount(2).userMessage.contains("-ar 16000 -ac 1"))
        #expect(WAVFileError.unsupportedBitsPerSample(8).userMessage.contains("-ar 16000 -ac 1"))
    }
}
