import ArgumentParser
import Foundation
import Testing

@testable import TessavakLive

@Suite struct TranscribeCommandTests {

    @Test func helpParsingSucceeds() throws {
        // `parseAsRoot(["transcribe", "--help"])` parses successfully into
        // ArgumentParser's internal help-command plumbing rather than
        // throwing; *running* that command is what signals the help
        // request. Exercise both steps so a broken `transcribe --help`
        // (crash, wrong subcommand routing) would fail this test, without
        // coupling to ArgumentParser's exact internal error shape.
        var command = try TessavakLiveCommand.parseAsRoot(["transcribe", "--help"])
        #expect(throws: (any Error).self) {
            try command.run()
        }
        let helpText = TessavakLiveCommand.helpMessage(for: TranscribeCommand.self)
        #expect(helpText.contains("transcribe"))
        #expect(helpText.contains("--model"))
        #expect(helpText.contains("--audio"))
    }

    @Test func parsesRequiredOptionsWithDefaults() throws {
        let command = try TranscribeCommand.parse(["--model", "m.bin", "--audio", "a.wav"])
        #expect(command.model == "m.bin")
        #expect(command.audio == "a.wav")
        #expect(command.policy == .interactive)
        #expect(command.language == .auto)
        #expect(command.outputPolicy == .preserveMixed)
    }

    @Test func parsesAllOptions() throws {
        let command = try TranscribeCommand.parse([
            "--model", "m.bin",
            "--audio", "a.wav",
            "--policy", "meeting",
            "--language", "gu",
            "--output-policy", "bapsRoman",
        ])
        #expect(command.policy == .meeting)
        #expect(command.language == .gu)
        #expect(command.outputPolicy == .bapsRoman)
    }

    @Test func missingRequiredOptionsFailsToParse() {
        #expect(throws: (any Error).self) {
            _ = try TranscribeCommand.parse(["--model", "m.bin"])
        }
        #expect(throws: (any Error).self) {
            _ = try TranscribeCommand.parse(["--audio", "a.wav"])
        }
    }

    @Test func rejectsUnknownPolicyValue() {
        #expect(throws: (any Error).self) {
            _ = try TranscribeCommand.parse([
                "--model", "m.bin", "--audio", "a.wav", "--policy", "verbatim",
            ])
        }
    }

    @Test func rejectsUnknownLanguageValue() {
        #expect(throws: (any Error).self) {
            _ = try TranscribeCommand.parse([
                "--model", "m.bin", "--audio", "a.wav", "--language", "fr",
            ])
        }
    }
}
