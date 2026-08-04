import ArgumentParser
import Foundation
import VaaniCore
import VaaniPacks

/// Wires a decoded WAV file through `LivePipelineCoordinator` and prints the
/// result, following `vaani-bench`'s exit-code convention: `0` success, `64`
/// invalid input (bad WAV, missing/empty/non-ggml model file), `70` internal
/// failure.
enum TranscribeRunner {
    static func run(
        modelPath: String,
        audioPath: String,
        policy: PolicyOption,
        language: LanguageOption,
        outputPolicy: OutputPolicyOption
    ) async throws {
        try validateModelFile(atPath: modelPath)

        let wav: WAVFile
        do {
            let audioData = try readFile(atPath: audioPath, kind: "audio")
            wav = try WAVFile(data: audioData)
        } catch let error as WAVFileError {
            FileHandle.standardError.write(Data("vaani-live: invalid audio file: \(error.userMessage)\n".utf8))
            throw ExitCode(64)
        } catch let error as CLIInputError {
            FileHandle.standardError.write(Data("vaani-live: \(error.message)\n".utf8))
            throw ExitCode(64)
        }

        let events: [SpeechEvent]
        do {
            events = try SpeechEventBuilder.buildEvents(samples: wav.samples)
        } catch {
            FileHandle.standardError.write(
                Data("vaani-live: internal failure building the utterance stream: \(error)\n".utf8)
            )
            throw ExitCode(70)
        }

        // Built before the rest of the pipeline: a model file the recogniser
        // can identify as unusable is bad *input*, so it exits 64 like a bad
        // WAV, not 70.
        let recognizerFactory: @Sendable (Route) -> (any StreamingRecognizer)?
        do {
            recognizerFactory = try makeRecognizerFactory(modelPath: modelPath, language: language)
        } catch let error as VaaniCoreError {
            let detail: String
            if case .invalidConfiguration(let message) = error {
                detail = message
            } else {
                detail = "\(error)"
            }
            FileHandle.standardError.write(Data("vaani-live: invalid model file: \(detail)\n".utf8))
            throw ExitCode(64)
        }

        let coordinator: LivePipelineCoordinator
        do {
            let pack = try PackLoader.bundledBAPSGujarati()
            let accumulatorConfiguration = try EvidenceAccumulatorConfiguration(
                enterThreshold: 0.6, exitThreshold: 0.3, historyLimit: 5
            )
            let routingPolicy = try RoutingPolicy(
                mode: policy.sessionPolicy,
                confidentLanguageThreshold: 0.85,
                secondDecodeThreshold: 0.15,
                latencyBudgetMilliseconds: 500
            )
            // File-driven batch decode is not real-time dictation, so this
            // CLI uses much more generous per-policy budgets than the live
            // `SessionBudgets.default` interactive/meeting values — those are
            // tuned for a live typing session, not for a whole-file whisper
            // decode.
            let budgets = try SessionBudgets(
                interactive: 60_000, meeting: 120_000, verbatim: 120_000, evaluation: 300_000
            )
            let router = AdaptiveRouter(policy: routingPolicy, budgets: budgets)
            let scorer = try CandidateScorer(latencyBudgetMilliseconds: 500)
            let correctionEngine = CorrectionEngine(pack: pack)
            let renderer = OutputRenderer(pack: pack)
            let protectedTerms = Set(pack.entries.filter(\.protected).map(\.canonical))
            let detector = try LanguageHintDetector(language: language)

            coordinator = LivePipelineCoordinator(
                accumulatorConfiguration: accumulatorConfiguration,
                router: router,
                scorer: scorer,
                correctionEngine: correctionEngine,
                renderer: renderer,
                protectedTerms: protectedTerms,
                detector: detector,
                recognizerForRoute: recognizerFactory
            )
        } catch {
            FileHandle.standardError.write(
                Data("vaani-live: internal failure setting up the pipeline: \(error)\n".utf8)
            )
            throw ExitCode(70)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let result: PipelineResult
        do {
            result = try await coordinator.process(
                events: SpeechEventBuilder.stream(from: events),
                sessionPolicy: policy.sessionPolicy,
                outputPolicy: outputPolicy.outputPolicy
            )
        } catch {
            FileHandle.standardError.write(Data("vaani-live: transcription failed: \(error)\n".utf8))
            throw ExitCode(70)
        }
        let elapsed = clock.now - start

        printResult(result, elapsed: elapsed)
    }

    // MARK: - Input validation

    private struct CLIInputError: Error {
        let message: String
    }

    private static func validateModelFile(atPath path: String) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            FileHandle.standardError.write(
                Data("vaani-live: model file not found at '\(path)'\n".utf8)
            )
            throw ExitCode(64)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > 0 else {
            FileHandle.standardError.write(
                Data("vaani-live: model file at '\(path)' is empty\n".utf8)
            )
            throw ExitCode(64)
        }
    }

    private static func readFile(atPath path: String, kind: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIInputError(message: "\(kind) file not found at '\(path)'")
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CLIInputError(message: "could not read \(kind) file at '\(path)': \(error)")
        }
    }

    // MARK: - Output

    private static func printResult(_ result: PipelineResult, elapsed: Duration) {
        print("Final text:")
        print("  \(result.text)")
        print()
        print("Route: \(result.route.route.rawValue) (\(result.route.reasons.joined(separator: ", ")))")
        print()
        print("Decision codes:")
        for event in result.diagnostics.events {
            let attributes = event.attributes.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            print("  - \(event.code.rawValue)" + (attributes.isEmpty ? "" : " [\(attributes)]"))
        }
        print()
        if result.corrections.isEmpty {
            print("Applied corrections: none")
        } else {
            print("Applied corrections:")
            for correction in result.corrections {
                print("  - '\(correction.original)' -> '\(correction.replacement)' (\(correction.rule))")
            }
        }
        print()
        let elapsedMilliseconds =
            Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        print(
            String(
                format: "Decode time: %.1f ms (measured on this machine, single run, not a benchmark)",
                elapsedMilliseconds)
        )
    }
}
