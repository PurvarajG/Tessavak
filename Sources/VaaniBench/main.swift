import ArgumentParser
import Foundation
import VaaniAdapters
import VaaniCore
import VaaniPacks

struct VaaniBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vaani-bench",
        subcommands: [RunCommand.self]
    )
}

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run")

    @Option(name: .long, help: "Path to the replay manifest JSON file.")
    var manifest: String

    @Option(name: .long, help: "Directory to write report.json and report.md into.")
    var output: String

    @Option(name: .long, help: "Path to a baseline BenchReport JSON file to gate regressions against.")
    var baseline: String?

    mutating func run() async throws {
        let replayManifest: ReplayManifest
        do {
            replayManifest = try BenchManifestLoader.load(fromPath: manifest)
        } catch {
            FileHandle.standardError.write(Data("vaani-bench: invalid manifest: \(error)\n".utf8))
            throw ExitCode(64)
        }

        var baselineReport: BenchReport?
        if let baselinePath = baseline {
            do {
                baselineReport = try BenchReport.load(fromPath: baselinePath)
            } catch {
                FileHandle.standardError.write(Data("vaani-bench: invalid baseline: \(error)\n".utf8))
                throw ExitCode(64)
            }
        }

        let report: BenchReport
        do {
            let pack = try PackLoader.bundledBAPSGujarati()
            let routingPolicy = try RoutingPolicy(
                mode: .evaluation,
                confidentLanguageThreshold: 0.85,
                secondDecodeThreshold: 0.15,
                latencyBudgetMilliseconds: 500
            )
            let accumulatorConfiguration = try EvidenceAccumulatorConfiguration(
                enterThreshold: 0.6, exitThreshold: 0.3, historyLimit: 5
            )
            let pipeline = try VaaniPipeline(
                accumulatorConfiguration: accumulatorConfiguration,
                routingPolicy: routingPolicy,
                terminologyPack: pack
            )
            let runner = BenchRunner(pipeline: pipeline)
            report = try runner.run(replayManifest, baseline: baselineReport)
        } catch let error as BaselineCompatibilityError {
            FileHandle.standardError.write(
                Data("vaani-bench: baseline is incompatible with the current manifest: \(error)\n".utf8)
            )
            throw ExitCode(64)
        } catch {
            FileHandle.standardError.write(Data("vaani-bench: benchmark failed: \(error)\n".utf8))
            throw ExitCode(70)
        }

        do {
            try writeReport(report, toDirectory: output)
        } catch {
            FileHandle.standardError.write(Data("vaani-bench: failed to write report: \(error)\n".utf8))
            throw ExitCode(70)
        }

        print(
            "vaani-bench: \(report.metrics.utteranceCount) utterances, "
                + "exactMatchRate=\(report.metrics.exactMatchRate), regressions=\(report.regressions.count)"
        )

        if !report.regressions.isEmpty {
            for regression in report.regressions {
                print(
                    "vaani-bench: regression \(regression.metric): "
                        + "baseline=\(regression.baseline) actual=\(regression.actual) "
                        + "allowedDelta=\(regression.allowedDelta)"
                )
            }
            throw ExitCode(2)
        }
    }

    private func writeReport(_ report: BenchReport, toDirectory directory: String) throws {
        let directoryURL = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let jsonURL = directoryURL.appendingPathComponent("report.json")
        let markdownURL = directoryURL.appendingPathComponent("report.md")
        try report.renderJSON().write(to: jsonURL, options: .atomic)
        try Data(report.renderMarkdown().utf8).write(to: markdownURL, options: .atomic)
    }
}

// Calling `.run()` through an `any AsyncParsableCommand` existential
// resolves to `ParsableCommand`'s inherited synchronous default (which just
// throws `CleanExit.helpRequest`), not the concrete async override — an
// existential-dispatch quirk with this refined-protocol pair. Opening the
// existential into a generic parameter forces static dispatch to the
// concrete type's `run() async throws` instead.
func runAsync<Command: AsyncParsableCommand>(_ command: Command) async throws {
    var mutableCommand = command
    try await mutableCommand.run()
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = try await VaaniBenchCommand.asyncParseAsRoot(arguments)
    if let asyncCommand = command as? any AsyncParsableCommand {
        try await runAsync(asyncCommand)
    } else {
        var mutableCommand = command
        try mutableCommand.run()
    }
} catch {
    VaaniBenchCommand.exit(withError: error)
}
