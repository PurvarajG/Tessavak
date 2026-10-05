import ArgumentParser
import Foundation
import TessavakCore
import TessavakPacks

struct TessavakLiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tessavak-live",
        subcommands: [TranscribeCommand.self]
    )
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = try await TessavakLiveCommand.asyncParseAsRoot(arguments)
    if let asyncCommand = command as? any AsyncParsableCommand {
        try await runAsync(asyncCommand)
    } else {
        var mutableCommand = command
        try mutableCommand.run()
    }
} catch {
    TessavakLiveCommand.exit(withError: error)
}

// Mirrors TessavakBench/main.swift: calling `.run()` through an `any
// AsyncParsableCommand` existential resolves to `ParsableCommand`'s
// synchronous default rather than the concrete async override. Opening the
// existential into a generic parameter forces static dispatch to the
// concrete type's `run() async throws`.
func runAsync<Command: AsyncParsableCommand>(_ command: Command) async throws {
    var mutableCommand = command
    try await mutableCommand.run()
}
