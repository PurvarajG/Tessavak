import Foundation

/// Everything that can go wrong parsing or validating a caller-supplied WAV
/// file. `tessavak-live` never links AVFoundation, so this is a minimal
/// hand-written RIFF/WAVE reader, not a general-purpose decoder: it accepts
/// exactly 16 kHz mono 16-bit PCM, matching `AudioFormat.canonical`, and
/// rejects everything else with a message that tells the caller how to fix
/// it rather than a bare parse failure.
enum WAVFileError: Error, Equatable, Sendable {
    case truncatedHeader
    case notRIFF
    case notWAVE
    case missingFormatChunk
    case truncatedFormatChunk
    case missingDataChunk
    case truncatedDataChunk
    case oddLengthPCMData(byteCount: Int)
    case emptyAudio
    case unsupportedAudioFormatTag(Int)
    case unsupportedChannelCount(Int)
    case unsupportedSampleRate(Int)
    case unsupportedBitsPerSample(Int)

    private static let ffmpegHint =
        "convert it first with: ffmpeg -i <input> -ar 16000 -ac 1 -sample_fmt s16 <output.wav>"

    /// A message safe to print directly to the user: explains what was wrong
    /// and, for format mismatches, exactly how to fix it with `ffmpeg`.
    var userMessage: String {
        switch self {
        case .truncatedHeader:
            return "the file is too short to contain a WAV header"
        case .notRIFF:
            return "the file does not start with a RIFF header — it is not a WAV file"
        case .notWAVE:
            return "the RIFF file is not WAVE-formatted"
        case .missingFormatChunk:
            return "the WAV file has no 'fmt ' chunk"
        case .truncatedFormatChunk:
            return "the WAV file's 'fmt ' chunk is truncated"
        case .missingDataChunk:
            return "the WAV file has no 'data' chunk"
        case .truncatedDataChunk:
            return "the WAV file's 'data' chunk is truncated"
        case .oddLengthPCMData(let byteCount):
            return "16-bit PCM data must have an even byte count, got \(byteCount) bytes"
        case .emptyAudio:
            return "the WAV file contains no audio frames"
        case .unsupportedAudioFormatTag(let tag):
            return "tessavak-live only accepts uncompressed PCM WAV (format tag 1), got format tag \(tag); "
                + Self.ffmpegHint
        case .unsupportedChannelCount(let count):
            return "tessavak-live only accepts mono audio, got \(count) channel(s); " + Self.ffmpegHint
        case .unsupportedSampleRate(let rate):
            return "tessavak-live only accepts 16 kHz audio, got \(rate) Hz; " + Self.ffmpegHint
        case .unsupportedBitsPerSample(let bits):
            return "tessavak-live only accepts 16-bit PCM samples, got \(bits)-bit; " + Self.ffmpegHint
        }
    }
}

/// A parsed, format-validated WAV file: always 16 kHz mono 16-bit PCM by the
/// time construction succeeds.
struct WAVFile: Equatable, Sendable {
    let sampleRateHertz: Int
    let channelCount: Int
    let bitsPerSample: Int
    let samples: [Int16]

    private static let pcmFormatTag = 1
    private static let requiredSampleRateHertz = 16_000
    private static let requiredChannelCount = 1
    private static let requiredBitsPerSample = 16
    private static let riffHeaderSize = 12

    /// Parses and validates `data` as a 16 kHz mono 16-bit PCM WAV file.
    /// Walks RIFF chunks so 'fmt ' and 'data' may be preceded or separated by
    /// other chunks (e.g. 'LIST', 'fact') a real encoder may have written.
    init(data: Data) throws {
        guard data.count >= Self.riffHeaderSize else {
            throw WAVFileError.truncatedHeader
        }
        guard data[data.startIndex..<data.startIndex + 4].elementsEqual(Array("RIFF".utf8)) else {
            throw WAVFileError.notRIFF
        }
        let waveTagStart = data.startIndex + 8
        guard data[waveTagStart..<waveTagStart + 4].elementsEqual(Array("WAVE".utf8)) else {
            throw WAVFileError.notWAVE
        }

        var offset = data.startIndex + Self.riffHeaderSize
        var formatChunk: (audioFormat: Int, channelCount: Int, sampleRate: Int, bitsPerSample: Int)?
        var dataChunk: Data?

        while offset + 8 <= data.endIndex {
            let chunkID = data[offset..<offset + 4]
            let sizeBytes = data[offset + 4..<offset + 8]
            let chunkSize = Int(Self.readUInt32LE(sizeBytes))
            let chunkDataStart = offset + 8
            guard chunkDataStart + chunkSize <= data.endIndex else {
                if chunkID.elementsEqual(Array("data".utf8)) {
                    throw WAVFileError.truncatedDataChunk
                }
                throw WAVFileError.truncatedFormatChunk
            }
            let chunkData = data[chunkDataStart..<chunkDataStart + chunkSize]

            if chunkID.elementsEqual(Array("fmt ".utf8)) {
                guard chunkSize >= 16 else { throw WAVFileError.truncatedFormatChunk }
                let base = chunkData.startIndex
                formatChunk = (
                    audioFormat: Int(Self.readUInt16LE(chunkData[base..<base + 2])),
                    channelCount: Int(Self.readUInt16LE(chunkData[base + 2..<base + 4])),
                    sampleRate: Int(Self.readUInt32LE(chunkData[base + 4..<base + 8])),
                    bitsPerSample: Int(Self.readUInt16LE(chunkData[base + 14..<base + 16]))
                )
            } else if chunkID.elementsEqual(Array("data".utf8)) {
                dataChunk = chunkData
            }

            // RIFF chunks are padded to an even byte count.
            offset = chunkDataStart + chunkSize + (chunkSize % 2)
        }

        guard let format = formatChunk else {
            throw WAVFileError.missingFormatChunk
        }
        guard let audioData = dataChunk else {
            throw WAVFileError.missingDataChunk
        }
        guard format.audioFormat == Self.pcmFormatTag else {
            throw WAVFileError.unsupportedAudioFormatTag(format.audioFormat)
        }
        guard format.channelCount == Self.requiredChannelCount else {
            throw WAVFileError.unsupportedChannelCount(format.channelCount)
        }
        guard format.sampleRate == Self.requiredSampleRateHertz else {
            throw WAVFileError.unsupportedSampleRate(format.sampleRate)
        }
        guard format.bitsPerSample == Self.requiredBitsPerSample else {
            throw WAVFileError.unsupportedBitsPerSample(format.bitsPerSample)
        }
        guard audioData.count % 2 == 0 else {
            throw WAVFileError.oddLengthPCMData(byteCount: audioData.count)
        }
        guard !audioData.isEmpty else {
            throw WAVFileError.emptyAudio
        }

        var samples: [Int16] = []
        samples.reserveCapacity(audioData.count / 2)
        var index = audioData.startIndex
        while index < audioData.endIndex {
            let sample = Int16(bitPattern: Self.readUInt16LE(audioData[index..<index + 2]))
            samples.append(sample)
            index += 2
        }

        self.sampleRateHertz = format.sampleRate
        self.channelCount = format.channelCount
        self.bitsPerSample = format.bitsPerSample
        self.samples = samples
    }

    private static func readUInt16LE(_ bytes: Data.SubSequence) -> UInt16 {
        let a = UInt16(bytes[bytes.startIndex])
        let b = UInt16(bytes[bytes.startIndex + 1])
        return a | (b << 8)
    }

    private static func readUInt32LE(_ bytes: Data.SubSequence) -> UInt32 {
        let a = UInt32(bytes[bytes.startIndex])
        let b = UInt32(bytes[bytes.startIndex + 1])
        let c = UInt32(bytes[bytes.startIndex + 2])
        let d = UInt32(bytes[bytes.startIndex + 3])
        return a | (b << 8) | (c << 16) | (d << 24)
    }
}
