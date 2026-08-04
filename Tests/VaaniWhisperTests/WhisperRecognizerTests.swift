import Foundation
import Testing
import VaaniCore

@testable import VaaniWhisper

@Suite struct WhisperRecognizerTests {
    @Test func initializerRejectsMissingModelFile() throws {
        let missingURL = URL(fileURLWithPath: "/private/tmp/vaani-whisper-missing-model.bin")

        #expect(throws: VaaniCoreError.invalidConfiguration("whisper model file does not exist")) {
            try WhisperRecognizer(modelFileURL: missingURL, languageHint: .auto)
        }
    }

    @Test func initializerRejectsEmptyModelFile() throws {
        let modelURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vaani-whisper-empty-model.bin")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: modelURL) }

        #expect(throws: VaaniCoreError.invalidConfiguration("whisper model file must not be empty")) {
            try WhisperRecognizer(modelFileURL: modelURL, languageHint: .english)
        }
    }

    // MARK: - Magic pre-flight
    //
    // These need no real model: they prove a file the vendored loader would
    // trap on is rejected before a whisper context is ever constructed.

    /// Writes `bytes` to a uniquely named temporary file for one test.
    private func temporaryModel(named name: String, bytes: [UInt8]) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vaani-whisper-\(name)-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        return url
    }

    @Test func initializerRejectsAFileThatIsNotAGGMLModel() throws {
        let modelURL = temporaryModel(named: "junk", bytes: [0xde, 0xad, 0xbe, 0xef, 0x00, 0x01])
        defer { try? FileManager.default.removeItem(at: modelURL) }

        let error = #expect(throws: VaaniCoreError.self) {
            try WhisperRecognizer(modelFileURL: modelURL, languageHint: .auto)
        }
        guard case .invalidConfiguration(let message) = try #require(error) else {
            Issue.record("expected invalidConfiguration")
            return
        }
        #expect(message.contains("not a ggml whisper model"))
        #expect(message.contains("de ad be ef"))
    }

    @Test func initializerRejectsAGGUFModelByName() throws {
        let modelURL = temporaryModel(named: "gguf", bytes: Array("GGUF".utf8) + [0x03, 0x00])
        defer { try? FileManager.default.removeItem(at: modelURL) }

        let error = #expect(throws: VaaniCoreError.self) {
            try WhisperRecognizer(modelFileURL: modelURL, languageHint: .auto)
        }
        guard case .invalidConfiguration(let message) = try #require(error) else {
            Issue.record("expected invalidConfiguration")
            return
        }
        #expect(message.contains("GGUF"))
        #expect(message.contains("ggml-*.bin"))
    }

    @Test func initializerRejectsAFileTooShortToCarryMagic() throws {
        let modelURL = temporaryModel(named: "short", bytes: [0x6c, 0x6d])
        defer { try? FileManager.default.removeItem(at: modelURL) }

        let error = #expect(throws: VaaniCoreError.self) {
            try WhisperRecognizer(modelFileURL: modelURL, languageHint: .auto)
        }
        guard case .invalidConfiguration(let message) = try #require(error) else {
            Issue.record("expected invalidConfiguration")
            return
        }
        #expect(message.contains("too short to identify"))
    }

    @Test(.enabled(if: WhisperTestModel.isAvailable)) func realModelSatisfiesStreamingRecognizerContract()
        async throws
    {
        try await WhisperStreamingRecognizerContract.verify(
            WhisperTestModel.recognizer(),
            chunks: try WhisperWAV.oneSecondSineThenSilenceChunks(),
            label: "whisper.cpp"
        )
    }

    @Test(.enabled(if: WhisperTestModel.isAvailable)) func realModelCancellationTerminates() async throws {
        try await WhisperStreamingRecognizerContract.verifyCancellationTerminates(
            WhisperTestModel.recognizer(),
            chunks: try WhisperWAV.oneSecondSineThenSilenceChunks(),
            label: "whisper.cpp"
        )
    }

    @Test(.enabled(if: WhisperTestModel.isAvailable)) func realModelDecodesGeneratedOneSecondWAV() async throws {
        let recognizer = try WhisperTestModel.recognizer()
        let chunks = try WhisperWAV.oneSecondSineThenSilenceChunks()
        var updates: [RecognitionUpdate] = []

        for try await update in recognizer.recognize(WhisperStreamingRecognizerContract.stream(chunks)) {
            updates.append(update)
        }

        #expect(updates.count == 1)
        #expect(updates[0].isFinal)
        #expect(updates[0].candidate.model.provider == "whisper.cpp")
    }
}

private enum WhisperTestModel {
    static let modelURL: URL? = {
        guard let path = ProcessInfo.processInfo.environment["VAANI_WHISPER_MODEL"], !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard url.pathExtension == "bin",
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            size.intValue > 0
        else {
            return nil
        }
        return url
    }()

    static var isAvailable: Bool { modelURL != nil }

    static func recognizer() throws -> WhisperRecognizer {
        guard let modelURL else {
            throw VaaniCoreError.invalidConfiguration("VAANI_WHISPER_MODEL is unavailable")
        }
        return try WhisperRecognizer(modelFileURL: modelURL, languageHint: .auto)
    }
}

private enum WhisperStreamingRecognizerContract {
    static func stream(_ chunks: [AudioChunk]) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    static func verify(
        _ recognizer: some StreamingRecognizer,
        chunks: [AudioChunk],
        label: String
    ) async throws {
        var updates: [RecognitionUpdate] = []
        for try await update in recognizer.recognize(stream(chunks)) {
            updates.append(update)
        }

        #expect(!updates.isEmpty, "\(label): recognizer yielded no updates")
        #expect(updates.contains { $0.isFinal }, "\(label): recognizer never yielded a final update")
        if let finalIndex = updates.firstIndex(where: { $0.isFinal }) {
            #expect(finalIndex == updates.count - 1, "\(label): update followed the final")
        }
        for update in updates {
            #expect(!update.candidate.model.name.isEmpty, "\(label): empty model name")
            #expect(!update.candidate.id.isEmpty, "\(label): empty candidate ID")
        }
    }

    static func verifyCancellationTerminates(
        _ recognizer: some StreamingRecognizer,
        chunks: [AudioChunk],
        label: String
    ) async throws {
        let stream = recognizer.recognize(stream(chunks))
        let progress = AsyncStream<Void>.makeStream()
        let consumer = Task {
            defer { progress.continuation.finish() }
            for try await _ in stream {
                progress.continuation.yield(())
            }
        }

        var iterator = progress.stream.makeAsyncIterator()
        _ = await iterator.next()
        consumer.cancel()
        _ = try? await consumer.value
        #expect(consumer.isCancelled, "\(label): consumer did not observe cancellation")
    }
}

private enum WhisperWAV {
    static func oneSecondSineThenSilenceChunks() throws -> [AudioChunk] {
        let samples = generatedSamples()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vaani-whisper-\(UUID().uuidString).wav")
        try waveData(samples: samples).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try parseCanonicalPCM(at: url)
    }

    private static func generatedSamples() -> [Int16] {
        let sampleRate = AudioFormat.canonical.sampleRateHertz
        return (0..<sampleRate).map { frame in
            guard frame < sampleRate / 2 else { return 0 }
            let phase = 2 * Double.pi * 440 * Double(frame) / Double(sampleRate)
            return Int16((sin(phase) * 8_000).rounded())
        }
    }

    private static func waveData(samples: [Int16]) -> Data {
        var data = Data()
        let audioByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(36 + audioByteCount, to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(AudioFormat.canonical.sampleRateHertz), to: &data)
        appendLittleEndian(UInt32(AudioFormat.canonical.sampleRateHertz * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(audioByteCount, to: &data)
        for sample in samples {
            appendLittleEndian(UInt16(bitPattern: sample), to: &data)
        }
        return data
    }

    private static func parseCanonicalPCM(at url: URL) throws -> [AudioChunk] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44,
            String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
            String(decoding: data[8..<12], as: UTF8.self) == "WAVE",
            String(decoding: data[12..<16], as: UTF8.self) == "fmt ",
            littleEndianUInt16(data, at: 20) == 1,
            littleEndianUInt16(data, at: 22) == 1,
            littleEndianUInt32(data, at: 24) == UInt32(AudioFormat.canonical.sampleRateHertz),
            littleEndianUInt16(data, at: 34) == 16,
            String(decoding: data[36..<40], as: UTF8.self) == "data"
        else {
            throw VaaniCoreError.invalidAudioFormat("generated WAV was not canonical PCM")
        }
        let byteCount = Int(littleEndianUInt32(data, at: 40))
        guard byteCount % 2 == 0, data.count == 44 + byteCount else {
            throw VaaniCoreError.invalidAudioChunk("generated WAV data length was invalid")
        }
        let samples = stride(from: 44, to: 44 + byteCount, by: 2).map {
            Int16(bitPattern: littleEndianUInt16(data, at: $0))
        }
        return [
            try AudioChunk(
                format: .canonical,
                frameCount: samples.count,
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                samples: samples
            )
        ]
    }

    private static func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
