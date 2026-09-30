// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// `chatter-tools`: `remotion …` and `verify api|queue|tones|plugin`.
/// Exit status: 0 success, 1 failure, 2 usage error (argparse convention).
public enum ChatterToolsCommand {
    public static let name = "chatter-tools"

    public static let usage = """
        usage: chatter-tools <command> [options]

        commands:
          remotion HANDOFF --project PROJECT [--wait-seconds WAIT_SECONDS]
              Stage completed Chatter jobs as local Remotion assets with sample-derived timing.
          verify api [--base-url URL] [--token-file PATH] [--support-dir DIR] [--bridge PATH] [--output PATH]
              Exercise the installed app's API, MCP endpoint and the chatter-mcp stdio bridge.
          verify queue [--base-url URL] [--token-file PATH] [--support-dir DIR]
                       [--app-process NAME] [--engine-process NAME]
              Fill the 1,000-job queue while the engine is suspended, then cancel every test job.
          verify tones [--base-url URL] [--token-file PATH] [--support-dir DIR] [--output PATH]
              Verify the tone catalog and create three saved WAVs (voice: $CHATTER_TEST_VOICE or Ryan).
          verify plugin [--bridge PATH | --cli PATH] [--voice VOICE] [--output PATH]
              Drive the MCP stdio transport end to end and save a narration WAV.

        Defaults: --base-url http://127.0.0.1:18423, --support-dir ~/Library/Application Support/Chatter,
        --token-file <support-dir>/api-token, --bridge chatter-mcp beside this executable,
        --app-process Chatter, --engine-process chatter-engine. Tokens are never printed.
        Run "chatter-tools <command> --help" for details.

        """

    public static let remotionUsage = """
        usage: chatter-tools remotion [-h] --project PROJECT [--wait-seconds WAIT_SECONDS] handoff

        Stage completed Chatter jobs as local Remotion assets with sample-derived timing.

        Does not synthesize, edit visuals, or contact cloud services.
        Uses the same CHATTER_URL / CHATTER_TOKEN_FILE settings as the MCP bridge.

        positional arguments:
          handoff               JSON containing fps, optional tailSeconds, and scenes with id/title/jobID

        options:
          -h, --help            show this help message and exit
          --project PROJECT
          --wait-seconds WAIT_SECONDS
                                Optional deadline for already queued jobs; default: require completion

        """

    /// Options each `verify` check accepts.
    static let verifyOptions: [String: [String]] = [
        "api": ["base-url", "token-file", "support-dir", "bridge", "output"],
        "queue": ["base-url", "token-file", "support-dir", "app-process", "engine-process"],
        "tones": ["base-url", "token-file", "support-dir", "output"],
        "plugin": ["bridge", "cli", "voice", "output"],
    ]

    /// Runs the command line `arguments` (without the program name) and returns the exit status.
    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: any TextOutput = FileHandleOutput.standardOutput,
        errors: any TextOutput = FileHandleOutput.standardError
    ) async -> Int32 {
        let command = arguments.first ?? ""
        switch command {
        case "remotion":
            return await remotion(Array(arguments.dropFirst()), environment: environment, output: output, errors: errors)
        case "verify":
            return await verification(Array(arguments.dropFirst()), environment: environment, output: output, errors: errors)
        case "-h", "--help", "help":
            return (try? output.write(usage)) == nil ? 1 : 0
        default:
            let problem = command.isEmpty ? "a command is required" : CommandLineError.unknownCommand(command).description
            return usageFailure(usage, "\(name): error: \(problem)", errors)
        }
    }

    // MARK: remotion

    static func remotion(_ arguments: [String], environment: [String: String], output: any TextOutput, errors: any TextOutput) async -> Int32 {
        let usageLine = remotionUsage.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let parsed: CommandLineArguments
        do {
            parsed = try CommandLineArguments(arguments, options: ["project", "wait-seconds"])
        } catch {
            return usageFailure(usageLine + "\n", "\(name) remotion: error: \(error.description)", errors)
        }
        if parsed.helpRequested { return (try? output.write(remotionUsage)) == nil ? 1 : 0 }
        let missing = (parsed.positionals.isEmpty ? ["handoff"] : []) + (parsed["project"] == nil ? ["--project"] : [])
        guard missing.isEmpty else {
            return usageFailure(usageLine + "\n", "\(name) remotion: error: \(CommandLineError.missingRequired(missing))", errors)
        }
        guard parsed.positionals.count == 1 else {
            let extra = parsed.positionals.dropFirst().joined(separator: " ")
            return usageFailure(usageLine + "\n", "\(name) remotion: error: \(CommandLineError.unrecognized(extra))", errors)
        }
        var waitSeconds = 0.0
        if let text = parsed["wait-seconds"] {
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
                let problem = CommandLineError.invalidNumber(option: "--wait-seconds", value: text)
                return usageFailure(usageLine + "\n", "\(name) remotion: error: \(problem)", errors)
            }
            waitSeconds = value
        }
        let handoff = parsed.positionals[0]
        let project = parsed["project"] ?? ""
        do {
            let data: Data
            do {
                data = try Data(contentsOf: URL(filePath: handoff))
            } catch {
                throw RemotionHandoffError.fileSystem("Cannot read \(handoff): \(error.localizedDescription)")
            }
            let stager = RemotionStager(source: ChatterServiceJobSource(environment: environment))
            let manifest = try await stager.prepare(plan: try JSONValue.parse(data), project: project, waitSeconds: waitSeconds)
            let summary: JSONValue = [
                "manifest": .string(RemotionStager.manifestURL(project: project).path),
                "scenes": .int(manifest["scenes"]?.arrayValue?.count ?? 0), "fps": manifest["fps"] ?? .null,
                "durationInFrames": manifest["durationInFrames"] ?? .null,
            ]
            try output.line(summary.encoded())
            return 0
        } catch {
            try? errors.line("Chatter handoff: \(errorMessage(error))")
            return 1
        }
    }

    // MARK: verify

    static func verification(_ arguments: [String], environment: [String: String], output: any TextOutput, errors: any TextOutput) async -> Int32 {
        let check = arguments.first ?? ""
        guard let options = verifyOptions[check] else {
            if check == "-h" || check == "--help" { return (try? output.write(usage)) == nil ? 1 : 0 }
            let problem = check.isEmpty ? "choose api, queue, tones or plugin" : "unknown check: \(check)"
            return usageFailure(usage, "\(name) verify: error: \(problem)", errors)
        }
        let parsed: CommandLineArguments
        do {
            parsed = try CommandLineArguments(Array(arguments.dropFirst()), options: options)
            if let extra = parsed.positionals.first { throw CommandLineError.unrecognized(extra) }
            if parsed["bridge"] != nil, parsed["cli"] != nil {
                throw CommandLineError.unrecognized("--cli (not allowed with --bridge)")
            }
        } catch {
            return usageFailure(usage, "\(name) verify \(check): error: \(errorMessage(error))", errors)
        }
        if parsed.helpRequested { return (try? output.write(usage)) == nil ? 1 : 0 }

        let home = FileManager.default.homeDirectoryForCurrentUser
        func path(_ option: String) -> URL? {
            parsed[option].map { URL(filePath: ChatterConnection.expandTilde($0, home: home)) }
        }
        var settings = VerificationSettings(
            baseURL: parsed["base-url"] ?? ChatterAPIClient.defaultBaseURL,
            supportDirectory: path("support-dir") ?? ChatterConnection.supportDirectory(home: home),
            tokenFile: path("token-file"), environment: environment)
        if let bridge = path("bridge") { settings.bridgeExecutable = bridge.path }
        do {
            switch check {
            case "api":
                try await APIVerification(settings: settings, report: path("output") ?? URL(filePath: APIVerification.defaultReport))
                    .run(output: output)
            case "queue":
                let engine = ChatterEngineProcess(
                    appName: parsed["app-process"] ?? ChatterEngineProcess.defaultAppName,
                    engineName: parsed["engine-process"] ?? ChatterEngineProcess.defaultEngineName)
                try await QueueVerification(settings: settings, engine: engine).run(output: output)
            case "tones":
                try await ToneVerification(settings: settings, report: path("output") ?? URL(filePath: ToneVerification.defaultReport))
                    .run(output: output)
            default:
                let transport: PluginVerification.Transport =
                    parsed["cli"].map { .codexCLI($0) } ?? .executable(settings.bridgeExecutable)
                try await PluginVerification(
                    settings: settings, transport: transport, voice: parsed["voice"] ?? PluginVerification.defaultVoice,
                    report: path("output") ?? URL(filePath: PluginVerification.defaultReport)
                ).run(output: output)
            }
            return 0
        } catch {
            try? errors.line("verify \(check) FAILED: \(errorMessage(error))")
            return 1
        }
    }

    private static func usageFailure(_ usage: String, _ message: String, _ errors: any TextOutput) -> Int32 {
        try? errors.write(usage + message + "\n")
        return 2
    }
}
