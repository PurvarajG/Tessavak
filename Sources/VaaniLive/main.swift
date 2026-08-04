import ArgumentParser
import Foundation
import VaaniCore
import VaaniPacks

struct VaaniLiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vaani-live",
        subcommands: [TranscribeCommand.self]
    )
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = try await VaaniLiveCommand.asyncParseAsRoot(arguments)
    if let asyncCommand = command as? any AsyncParsableCommand {
        try await runAsync(asyncCommand)
    } else {
        var mutableCommand = command
        try mutableCommand.run()
    }
} catch {
    VaaniLiveCommand.exit(withError: error)
}

// Mirrors VaaniBench/main.swift: calling `.run()` through an `any
// AsyncParsableCommand` existential resolves to `ParsableCommand`'s
// synchronous default rather than the concrete async override. Opening the
// existential into a generic parameter forces static dispatch to the
// concrete type's `run() async throws`.
func runAsync<Command: AsyncParsableCommand>(_ command: Command) async throws {
    var mutableCommand = command
    try await mutableCommand.run()
}
