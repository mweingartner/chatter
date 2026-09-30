// Chatter integration tooling (Swift replacement for the former Python helpers).
@testable import ChatterToolingKit
import Foundation
import Testing

@Suite("Command-line parsing (argparse-compatible)")
struct CommandLineTests {
    private let options = ["project", "wait-seconds"]

    @Test("Positionals, --name value, --name=value and unambiguous prefixes")
    func forms() throws {
        let parsed = try CommandLineArguments(["h.json", "--project", "/p", "--wait=5"], options: options)
        #expect(parsed.positionals == ["h.json"] && parsed["project"] == "/p" && parsed["wait-seconds"] == "5")
        let later = try CommandLineArguments(["--project=/a", "--project", "/b", "x"], options: options)
        #expect(later["project"] == "/b" && later.positionals == ["x"])
    }

    @Test("Negative numbers are values; `--` ends options; -h/--help are flags")
    func valuesAndTerminator() throws {
        #expect(try CommandLineArguments(["--wait-seconds", "-1"], options: options)["wait-seconds"] == "-1")
        #expect(try CommandLineArguments(["--", "--project"], options: options).positionals == ["--project"])
        #expect(try CommandLineArguments(["-h"], options: options).helpRequested)
    }

    @Test("Usage errors", arguments: [
        (["--bogus"], CommandLineError.unrecognized("--bogus")),
        (["-x"], .unrecognized("-x")),
        (["--project"], .missingValue("--project")),
        (["--project", "--wait-seconds", "1"], .missingValue("--project")),
    ])
    func errors(arguments: [String], error: CommandLineError) {
        #expect(throws: error) { try CommandLineArguments(arguments, options: options) }
    }

    @Test("Ambiguous prefixes are rejected")
    func ambiguous() {
        #expect(throws: CommandLineError.ambiguous("--b", ["--base-url", "--bridge"])) {
            try CommandLineArguments(["--b", "x"], options: ["base-url", "bridge"])
        }
    }

    private func run(_ arguments: [String]) async -> (Int32, String, String) {
        let output = CapturedOutput(), errors = CapturedOutput()
        let status = await ChatterToolsCommand.run(arguments, environment: [:], output: output, errors: errors)
        return (status, output.text, errors.text)
    }

    @Test("chatter-tools prints usage and exits 2 on bad arguments")
    func usageFailures() async {
        for arguments in [[], ["bogus"], ["verify"], ["verify", "nope"], ["remotion"], ["remotion", "h.json"],
                          ["remotion", "a", "b", "--project", "p"], ["remotion", "h", "--project", "p", "--wait-seconds", "soon"],
                          ["verify", "plugin", "--bridge", "a", "--cli", "b"], ["verify", "api", "extra"],
                          ["verify", "plugin", "--base-url", "x"]] {
            let (status, output, errors) = await run(arguments)
            #expect(status == 2, "\(arguments)")
            #expect(output.isEmpty && errors.contains("usage: chatter-tools") && errors.contains("error:"), "\(arguments)")
        }
        let (_, _, missing) = await run(["remotion"])
        #expect(missing.hasSuffix("chatter-tools remotion: error: the following arguments are required: handoff, --project\n"))
        let (_, _, number) = await run(["remotion", "h", "--project", "p", "--wait-seconds", "soon"])
        #expect(number.contains("argument --wait-seconds: invalid float value: 'soon'"))
    }

    @Test("Help goes to stdout with status 0")
    func help() async {
        let (status, output, _) = await run(["--help"])
        #expect(status == 0 && output == ChatterToolsCommand.usage)
        let (remotionStatus, remotionHelp, _) = await run(["remotion", "--help"])
        #expect(remotionStatus == 0 && remotionHelp.contains("--wait-seconds WAIT_SECONDS"))
        #expect(await run(["verify", "--help"]).0 == 0)
    }

    @Test("Handoff failures print 'Chatter handoff: …' and exit 1")
    func handoffFailures() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (status, _, errors) = await run(["remotion", directory.file("missing.json").path, "--project", directory.url.path])
        #expect(status == 1 && errors.hasPrefix("Chatter handoff: Cannot read "))
        try Data("{".utf8).write(to: directory.file("bad.json"))
        let (badStatus, _, badErrors) = await run(["remotion", directory.file("bad.json").path, "--project", directory.url.path])
        #expect(badStatus == 1)
        #expect(badErrors == "Chatter handoff: Expecting property name enclosed in double quotes: line 1 column 2 (char 1)\n")
        try Data(#"{"scenes":[{"id":"a","jobID":"12345678123456781234567812345678"}]}"#.utf8).write(to: directory.file("h.json"))
        let (projectStatus, _, projectErrors) = await run(["remotion", directory.file("h.json").path, "--project", directory.url.path])
        #expect(projectStatus == 1 && projectErrors == "Chatter handoff: Choose an existing Remotion project containing package.json.\n")
    }

    @Test("The built chatter-tools binary exits non-zero with usage on bad arguments")
    func binary() throws {
        let result = try ChildProcess.run(BuiltProducts.tools, ["verify"])
        #expect(result.status == 2)
        #expect(String(decoding: result.standardError, as: UTF8.self).contains("usage: chatter-tools"))
        #expect(try ChildProcess.run(BuiltProducts.tools, ["--help"]).status == 0)
    }
}
