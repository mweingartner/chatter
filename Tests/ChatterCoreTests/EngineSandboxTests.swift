import Foundation
import Network
import Testing
@testable import ChatterCore

@Suite("Engine process isolation") struct EngineSandboxTests {
    private struct Outcome { let status: Int32; let error: String }
    private func outcome(_ command: [String], input: String = "") async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process(), error = Pipe(), stdin = Pipe()
            process.executableURL = URL(filePath: command[0])
            process.arguments = Array(command.dropFirst())
            process.standardInput = stdin; process.standardOutput = FileHandle.nullDevice; process.standardError = error
            process.terminationHandler = { process in
                let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: Outcome(status: process.terminationStatus, error: message))
            }
            // Written before launch: it fits the pipe buffer, so it cannot block or meet a reader that already exited.
            do { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try process.run() } catch { continuation.resume(throwing: error); return }
            try? stdin.fileHandleForWriting.close()
        }
    }
    private func run(_ command: [String]) async throws -> Int32 { try await outcome(command).status }
    /// sandbox-exec exits non-zero itself when it rejects the profile or cannot start the command, which
    /// would satisfy `!= 0` without testing a rule, so a refusal only counts when the command really ran.
    private func refused(_ command: [String], sourceLocation: SourceLocation = #_sourceLocation) async throws -> Bool {
        let result = try await outcome(command)
        #expect(!result.error.hasPrefix("sandbox-exec:"), "\(result.error)", sourceLocation: sourceLocation)
        return result.status != 0
    }
    /// Runs `command` under the engine policy, with `command[0]` as the one program it may execute.
    private func sandboxed(_ command: [String], root: URL, bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, temporary: URL? = nil) -> [String] {
        let policy = EngineSandbox.profile(root: root, bundle: bundle, executable: URL(filePath: command[0]), home: home, temporary: temporary)
        return ["/usr/bin/sandbox-exec", "-p", policy] + command
    }
    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try PrivateStorage.directory(root)
        return root
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func resolved(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func helperCannotOpenNetworkConnections() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        defer { listener.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "isolation-listener"))
        }
        let port = try #require(listener.port)
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = ["/usr/bin/nc", "-z", "-G", "1", "127.0.0.1", String(port.rawValue)]
        #expect(try await run(command) == 0)
        #expect(try await refused(sandboxed(command, root: root, bundle: URL(filePath: "/usr/bin"))))
    }
    @Test func helperCanUseMediaButCannotReadCredentialsOrWriteOutsideItsDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "Home"), data = home.appending(path: "Chatter")
        let jobs = data.appending(path: "Jobs"), models = data.appending(path: "Models")
        let scratch = root.appending(path: "Scratch")
        for folder in [jobs, models, scratch] { try PrivateStorage.directory(folder) }
        let credential = data.appending(path: "api-token"), personal = home.appending(path: "personal.txt")
        let model = models.appending(path: "fixture")
        for file in [credential, personal, model] { try PrivateStorage.write(Data("canary".utf8), to: file) }
        func sandbox(_ command: String...) -> [String] { sandboxed(command, root: data, bundle: URL(filePath: "/bin"), home: home, temporary: scratch) }
        #expect(try await run(sandbox("/bin/cat", model.path)) == 0)
        #expect(try await refused(sandbox("/bin/cat", credential.path)))
        #expect(try await refused(sandbox("/bin/cat", personal.path)))
        let allowed = jobs.appending(path: "output"), denied = home.appending(path: "outside")
        #expect(try await run(sandbox("/usr/bin/touch", allowed.path)) == 0)
        #expect(try await refused(sandbox("/usr/bin/touch", denied.path)))
        #expect(exists(allowed))
        #expect(!exists(denied))
    }

    /// Shared caches hold build output and updates that other tools later run, and a link in Logs would
    /// redirect the parent's own writes to the engine log, so the engine may write neither and read no
    /// cache. A write to Jobs shows the policy loaded and the tools ran.
    @Test func helperCannotUseSharedCachesOrTheLogDirectory() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "Home"), data = home.appending(path: "Chatter")
        let caches = home.appending(path: "Library/Caches/com.example.tool"), logs = data.appending(path: "Logs"), jobs = data.appending(path: "Jobs")
        for folder in [caches, logs, jobs] { try PrivateStorage.directory(folder) }
        let cached = caches.appending(path: "entry"), log = logs.appending(path: "engine.log")
        try PrivateStorage.write(Data("canary".utf8), to: cached)
        func sandbox(_ command: String...) -> [String] { sandboxed(command, root: data, bundle: URL(filePath: "/bin"), home: home) }
        #expect(try await run(sandbox("/usr/bin/touch", jobs.appending(path: "output").path)) == 0)
        #expect(try await refused(sandbox("/usr/bin/touch", caches.appending(path: "planted").path)))
        #expect(try await refused(sandbox("/usr/bin/touch", log.path)))
        #expect(try await refused(sandbox("/bin/ln", "-s", home.appending(path: ".zshrc").path, log.path)))
        #expect(try await refused(sandbox("/bin/cat", cached.path)))
        #expect(!exists(caches.appending(path: "planted")) && !exists(log))
    }

    /// cfprefsd writes a preference for whoever asks, so no file rule sees it, and a value in another
    /// app's domain (a Terminal profile's startup command) runs outside the policy. defaults makes the
    /// same CFPreferences calls the engine could make in-process.
    @Test func helperCannotWritePreferences() async throws {
        let root = try scratchRoot()
        let domain = "com.chatter.tests.sandbox-preferences.\(UUID().uuidString)"
        defer {
            let remove = Process()
            remove.executableURL = URL(filePath: "/usr/bin/defaults"); remove.arguments = ["delete", domain]
            remove.standardOutput = FileHandle.nullDevice; remove.standardError = FileHandle.nullDevice
            try? remove.run(); remove.waitUntilExit()
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(domain).plist"))
            try? FileManager.default.removeItem(at: root)
        }
        let write = try await outcome(sandboxed(["/usr/bin/defaults", "write", domain, "key", "planted"], root: root.appending(path: "Chatter"), bundle: URL(filePath: "/usr/bin"), home: root.appending(path: "Home")))
        #expect(write.status != 0 && write.error.contains("Could not write domain"), "\(write.error)")
        #expect(try await run(["/usr/bin/defaults", "read", domain, "key"]) != 0)
    }

    /// Rules for a data root reached through a symlink must name the directory it resolves to, or the
    /// deny for the root would never match. The temporary directory does not exist when the policy is
    /// built, as the engine's may not, so its allow has to anticipate the path it will be created at.
    @Test func rulesFollowASymlinkedDataRootAndDirectoriesCreatedLater() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "Real"), link = root.appending(path: "Link")
        try PrivateStorage.directory(real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let data = link.appending(path: "Chatter"), models = data.appending(path: "Models"), later = link.appending(path: "Later/Temporary")
        try PrivateStorage.directory(models)
        let credential = data.appending(path: "api-token"), model = models.appending(path: "fixture")
        for file in [credential, model] { try PrivateStorage.write(Data("canary".utf8), to: file) }
        func sandbox(_ command: String...) -> [String] { sandboxed(command, root: data, bundle: URL(filePath: "/bin"), home: root.appending(path: "Home"), temporary: later) }
        let touch = sandbox("/usr/bin/touch")
        try PrivateStorage.directory(later)
        for path in [model.path, real.path + "/Chatter/Models/fixture"] { #expect(try await run(sandbox("/bin/cat", path)) == 0, "\(path)") }
        for path in [credential.path, real.path + "/Chatter/api-token"] { #expect(try await refused(sandbox("/bin/cat", path)), "\(path)") }
        #expect(try await run(touch + [later.appending(path: "output").path]) == 0)
    }

    /// A child of the engine would inherit the policy, but the engine has no reason to start one, and
    /// denying exec is what keeps it from running /usr/bin/open, launchctl or osascript on its behalf.
    /// zsh is the allowed executable (/bin/sh is a shim that execs another shell). Every write targets
    /// Jobs, which the engine may write, so only the process rules can stop it.
    @Test func helperCannotForkOrExecuteOtherPrograms() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appending(path: "Chatter"), jobs = data.appending(path: "Jobs")
        try PrivateStorage.directory(jobs)
        func shell(_ script: String) -> [String] { sandboxed(["/bin/zsh", "-c", script], root: data, bundle: URL(filePath: "/bin"), home: root.appending(path: "Home")) }
        let direct = jobs.appending(path: "direct"), executed = jobs.appending(path: "executed"), forked = jobs.appending(path: "forked")
        #expect(try await run(shell("echo ok > '\(direct.path)'")) == 0)
        let exec = try await outcome(shell("/usr/bin/touch '\(executed.path)'"))
        #expect(exec.status != 0 && exec.error.contains("operation not permitted: /usr/bin/touch"), "\(exec.error)")
        // zsh runs a trailing ( … ) subshell in place, so a background job is what forces a fork.
        let fork = try await outcome(shell("echo ok > '\(forked.path)' & wait"))
        #expect(fork.status != 0 && fork.error.contains("fork failed: operation not permitted"), "\(fork.error)")
        #expect(exists(direct))
        #expect(!exists(executed))
        #expect(!exists(forked))
    }

    /// posix_spawn makes a process without fork(2); xargs starts its utility that way. The kernel checks
    /// it as process-fork too, so the engine cannot start even a second copy of itself.
    @Test func helperCannotSpawnEvenItsOwnBinary() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The inner xargs rejects -Z with a usage message, which shows it was started.
        let command = ["/usr/bin/xargs", "/usr/bin/xargs", "-Z"]
        #expect(try await outcome(command, input: "a\n").error.contains("invalid option"))
        let attempt = try await outcome(sandboxed(command, root: root.appending(path: "Chatter"), bundle: URL(filePath: "/usr/bin"), home: root.appending(path: "Home")), input: "a\n")
        #expect(attempt.status != 0)
        #expect(attempt.error.contains("/usr/bin/xargs: Operation not permitted") && !attempt.error.contains("invalid option"), "\(attempt.error)")
    }

    /// Seatbelt matches the executable's resolved path; the temporary directory sits behind the
    /// /var → /private/var symlink, and the link itself must resolve to the binary it names.
    @Test func executableRuleMatchesTheResolvedPath() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appending(path: "engine")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/bin/zsh"))
        #expect(root.path.hasPrefix("/var/"))
        #expect(try await run(sandboxed([link.path, "-c", "exit 7"], root: root.appending(path: "Chatter"), bundle: URL(filePath: "/bin"), home: root.appending(path: "Home"))) == 7)
    }

    /// The exec rule names one file. The engine re-executing itself works, but not a binary beside it,
    /// one whose name extends its own, or one in a directory named after it, which is what a `prefix`
    /// or `subpath` rule would allow. The copies are re-signed ad hoc because launch constraints kill
    /// Apple's binaries anywhere but their system path, which would make every refusal vacuous.
    @Test func executableRuleAllowsThatFileAndNoOther() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appending(path: "Chatter"), jobs = data.appending(path: "Jobs")
        try PrivateStorage.directory(jobs); try PrivateStorage.directory(root.appending(path: "engine.d"))
        let engine = root.appending(path: "engine")
        let others = ["helper", "engine2", "engine.d/child"].map { root.appending(path: $0) }
        for (copy, source) in [(engine, "/bin/zsh")] + others.map({ ($0, "/usr/bin/touch") }) {
            try FileManager.default.copyItem(at: URL(filePath: source), to: copy)
            #expect(try await run(["/usr/bin/codesign", "--force", "--sign", "-", copy.path]) == 0)
        }
        func shell(_ script: String) -> [String] { sandboxed([engine.path, "-c", script], root: data, bundle: root, home: root.appending(path: "Home")) }
        let itself = jobs.appending(path: "itself")
        #expect(try await run(shell("exec '\(engine.path)' -c 'echo ok > \(itself.path)'")) == 0)
        #expect(exists(itself))
        for (index, other) in others.enumerated() {
            let control = jobs.appending(path: "control-\(index)"), marker = jobs.appending(path: "marker-\(index)")
            #expect(try await run([other.path, control.path]) == 0 && exists(control), "\(other.lastPathComponent) does not run at all")
            let attempt = try await outcome(shell("exec '\(other.path)' '\(marker.path)'"))
            #expect(attempt.status != 0 && attempt.error.contains("operation not permitted"), "\(other.lastPathComponent): \(attempt.error)")
            #expect(!exists(marker), "\(other.lastPathComponent)")
        }
    }

    /// Launch Services starts apps as children of launchd, outside the policy, and the engine can reach
    /// it in-process (NSWorkspace) without executing anything, so `lsopen` must be denied by itself.
    /// /usr/bin/open is the allowed executable here and makes the Launch Services call in-process.
    @Test func helperCannotAskLaunchServicesToStartAProgram() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launched = root.appending(path: "launched")
        let app = root.appending(path: "Canary.app"), contents = app.appending(path: "Contents")
        try PrivateStorage.directory(contents.appending(path: "MacOS"))
        let info: [String: Any] = ["CFBundleExecutable": "canary", "CFBundleIdentifier": "com.chatter.tests.sandbox-canary.\(UUID().uuidString)",
                                   "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        let script = contents.appending(path: "MacOS/canary")
        try Data("#!/bin/sh\n/usr/bin/touch '\(launched.path)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let attempt = try await outcome(sandboxed(["/usr/bin/open", "-g", "-n", app.path], root: root.appending(path: "Chatter"), bundle: URL(filePath: "/usr/bin"), home: root.appending(path: "Home")))
        #expect(attempt.status != 0)
        // -54 is permErr: Launch Services refusing a caller whose profile lacks (allow lsopen).
        #expect(attempt.error.contains("-54"), "open failed for another reason: \(attempt.error)")
        try await Task.sleep(for: .seconds(2))
        #expect(!exists(launched))
    }

    /// launchd runs submitted jobs outside the policy. It already refuses sandboxed callers today;
    /// the profile denies job creation itself so that this does not rest on launchd's own policy.
    @Test func helperCannotSubmitLaunchdJobs() async throws {
        let root = try scratchRoot()
        let label = "com.chatter.tests.sandbox-job.\(UUID().uuidString)"
        defer {
            let remove = Process()
            remove.executableURL = URL(filePath: "/bin/launchctl"); remove.arguments = ["remove", label]
            remove.standardOutput = FileHandle.nullDevice; remove.standardError = FileHandle.nullDevice
            try? remove.run(); remove.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let launched = root.appending(path: "launched")
        let submit = ["/bin/launchctl", "submit", "-l", label, "--", "/usr/bin/touch", launched.path]
        #expect(try await refused(sandboxed(submit, root: root.appending(path: "Chatter"), bundle: URL(filePath: "/bin"), home: root.appending(path: "Home"))))
        try await Task.sleep(for: .seconds(2))
        #expect(!exists(launched))
    }

    // MARK: The profile as text

    /// The profile read back strictly: a string may hold only the two escapes `quoted` emits and an atom
    /// only rule-name characters, so a stray quote, comment, escape or parenthesis fails to read.
    indirect enum Form: Equatable { case atom(String), string(String), list([Form]) }
    static func forms(_ profile: String) -> [Form]? {
        let text = Array(profile.unicodeScalars)
        var stack: [[Form]] = [[]], index = 0
        while index < text.count {
            let scalar = text[index]; index += 1
            switch scalar {
            case " ", "\n": continue
            case "(": stack.append([])
            case ")":
                guard stack.count > 1 else { return nil }
                let list = stack.removeLast(); stack[stack.count - 1].append(.list(list))
            case "\"":
                var value = String.UnicodeScalarView()
                while true {
                    guard index < text.count else { return nil }
                    var next = text[index]; index += 1
                    if next == "\"" { break }
                    if next == "\\" {
                        guard index < text.count, text[index] == "\\" || text[index] == "\"" else { return nil }
                        next = text[index]; index += 1
                    }
                    value.append(next)
                }
                stack[stack.count - 1].append(.string(String(value)))
            default:
                var atom = String.UnicodeScalarView([scalar])
                while index < text.count, !" \n()\"".unicodeScalars.contains(text[index]) { atom.append(text[index]); index += 1 }
                guard atom.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "*") }) else { return nil }
                stack[stack.count - 1].append(.atom(String(atom)))
            }
        }
        return stack.count == 1 ? stack[0] : nil
    }
    static func shape(_ form: Form) -> Form {
        switch form { case .string: .string(""); case .list(let items): .list(items.map(shape)); case .atom: form }
    }
    /// Compared as UTF-8, because String equality would let a normalised path pass for the original.
    static func strings(_ forms: [Form]) -> [[UInt8]] {
        forms.flatMap { form -> [[UInt8]] in
            switch form { case .string(let value): [Array(value.utf8)]; case .list(let items): strings(items); case .atom: [] }
        }
    }

    static let hostilePieces = [
        "\"", "\\", "\\\"", "\")", "(", ")", "(allow default)", "\") (allow file-read* (subpath \"", ";", "#|", "|#", "#", "'", "`", "|",
        ":", "\n", "\r", "\t", " ", "%22", "%", "$HOME", "*", "?", "[", "]", "{", "}", "~", "é", "e\u{301}", "😀", "👩‍👩‍👧", "中文",
        "\u{202E}", "\u{200B}", "\u{7F}", "\u{1B}", "\u{FEFF}", "x", "...",
    ]
    /// One file name, so no "/" and short enough for APFS's 255-byte limit with a one-letter prefix.
    static func hostileName(_ rng: inout SeededGenerator) -> String {
        (0..<Int.random(in: 1...6, using: &rng)).map { _ in hostilePieces.randomElement(using: &rng)! }.joined()
    }

    /// Property: whatever a path holds, it stays one string in the rules it was given to. A profile built
    /// with a hostile name in every path must read back to the same forms as one built with a plain name,
    /// with the hostile name, byte for byte, exactly where the plain one was. Byte for byte as Foundation
    /// spells it: file URLs decompose "é", and seatbelt matches either form (checked with sandbox-exec).
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func hostilePathsCannotAddOrAlterRules(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        func profile(_ name: String) -> String {
            EngineSandbox.profile(root: base.appending(path: "R" + name), bundle: base.appending(path: "B" + name), executable: base.appending(path: "E" + name),
                                  home: base.appending(path: "H" + name), temporary: base.appending(path: "T" + name))
        }
        let plain = try #require(Self.forms(profile("PLAIN")))
        for _ in 0..<200 {
            let name = Self.hostileName(&rng), context = "seed \(seed): \(name.debugDescription)"
            let spelled = String(URL(filePath: "/R" + name).path.dropFirst(2))
            let forms = try #require(Self.forms(profile(name)), "\(context)")
            #expect(forms.map(Self.shape) == plain.map(Self.shape), "\(context)")
            #expect(Self.strings(forms) == Self.strings(plain).map { Array(String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "PLAIN", with: spelled).utf8) }, "\(context)")
        }
    }

    /// The same property against sandbox-exec's own parser, with real directories named by seeded names and
    /// by payloads that, if a quote or backslash ever escaped, would end the string and re-allow reading "/".
    /// The profile must still load, every rule must still match the directory it names, and nothing widens.
    @Test func hostilePathsStillLoadAndWidenNothing() async throws {
        var rng = SeededGenerator(seed: 0xC4A7)
        let pinned = ["x\") (subpath \"/\") (literal \"y", "x\\\") (subpath \"/\") (literal \"y\\", "x\")\n(allow file-read* (subpath \"/\"))\n(literal \"y"]
        for name in pinned + (0..<4).map({ _ in Self.hostileName(&rng) }) {
            let root = try scratchRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appending(path: "H" + name), data = home.appending(path: "C" + name)
            let bundle = root.appending(path: "B" + name), temporary = root.appending(path: "T" + name)
            let jobs = data.appending(path: "Jobs"), models = data.appending(path: "Models")
            for folder in [jobs, models, bundle, temporary] { try PrivateStorage.directory(folder) }
            let credential = data.appending(path: "api-token"), personal = home.appending(path: "personal.txt")
            let model = models.appending(path: "fixture"), resource = bundle.appending(path: "resource")
            for file in [credential, personal, model, resource] { try PrivateStorage.write(Data("canary".utf8), to: file) }
            func sandbox(_ command: String...) -> [String] { sandboxed(command, root: data, bundle: bundle, home: home, temporary: temporary) }
            let context = Comment(rawValue: name.debugDescription)
            #expect(try await run(sandbox("/bin/cat", model.path)) == 0, context)
            #expect(try await run(sandbox("/bin/cat", resource.path)) == 0, context)
            #expect(try await refused(sandbox("/bin/cat", credential.path)), context)
            #expect(try await refused(sandbox("/bin/cat", personal.path)), context)
            #expect(try await run(sandbox("/usr/bin/touch", jobs.appending(path: "output").path, temporary.appending(path: "output").path)) == 0, context)
            #expect(try await refused(sandbox("/usr/bin/touch", home.appending(path: "outside").path)), context)
            #expect(!exists(home.appending(path: "outside")), context)
        }
    }

    /// job-creation and appleevent-send cannot be observed safely here: launchd refuses every sandboxed
    /// submitter even under (allow default), and an Apple Event to another app raises a consent prompt.
    /// So the profile is read: seatbelt applies the last matching rule, and after each deny of a way to
    /// have another process act for the engine, the only rule that can match is the one executable.
    @Test func processRulesAreDeniedOutrightAndNeverReallowed() throws {
        let forms = try #require(Self.forms(EngineSandbox.profile(root: URL(filePath: "/private/tmp/Chatter"), bundle: URL(filePath: "/bin"), executable: URL(filePath: "/bin/zsh"))))
        let rules = forms.compactMap { form -> (action: String, operation: String, filters: [Form])? in
            guard case .list(let items) = form, items.count >= 2, case .atom(let action) = items[0], case .atom(let operation) = items[1] else { return nil }
            return (action, operation, Array(items.dropFirst(2)))
        }
        func overlaps(_ a: String, _ b: String) -> Bool {
            func covers(_ wide: String, _ narrow: String) -> Bool { wide == "default" || wide == narrow || (wide.hasSuffix("*") && narrow.hasPrefix(wide.dropLast())) }
            return covers(a, b) || covers(b, a)
        }
        for operation in ["network*", "process-fork", "process-exec*", "lsopen", "job-creation", "appleevent-send", "user-preference-write"] {
            let deny = try #require(rules.firstIndex { $0.action == "deny" && $0.operation == operation && $0.filters.isEmpty }, "\(operation)")
            let reallowed = rules[(deny + 1)...].filter { $0.action == "allow" && overlaps($0.operation, operation) }
            if operation == "process-exec*" {
                #expect(reallowed.map(\.operation) == ["process-exec"] && reallowed.first?.filters == [.list([.atom("literal"), .string("/bin/zsh")])])
            } else {
                #expect(reallowed.isEmpty, "\(operation)")
            }
        }
    }

    /// A rule written before its directory exists must name the path the kernel gives it once created. Each
    /// case builds the profile, creates the directory through the same URL, and looks for its realpath.
    @Test func rulesNameTheResolvedPathOfDirectoriesCreatedLater() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateStorage.directory(root.appending(path: "Real/Sub"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Link"), withDestinationURL: root.appending(path: "Real/Sub"))
        func check(_ temporary: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let profile = EngineSandbox.profile(root: root.appending(path: "Chatter"), bundle: URL(filePath: "/bin"), executable: URL(filePath: "/bin/zsh"),
                                                home: root.appending(path: "Home"), temporary: temporary)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let created = try #require(Self.resolved(temporary.path))
            #expect(Self.strings(try #require(Self.forms(profile))).contains(Array(created.utf8)), "\(temporary.path) is \(created)", sourceLocation: sourceLocation)
        }
        for path in ["A/Temporary", "B/Temporary/", "./C//Temporary", "Link/D", "Link/./E/Temporary/", "Real/../F"] {
            try check(URL(filePath: root.path + "/" + path))
        }
        try check(URL(filePath: "G/Temporary", relativeTo: root))
        withKnownIssue("canonicalPath removes Link/.. by name before realpath, but the kernel resolves the link first") {
            try check(URL(filePath: root.path + "/Link/../H/Temporary"))
        }
    }

    /// Seatbelt does not treat "//x" as "/x" (verified with sandbox-exec), so a rule written with a doubled
    /// slash never matches, and a deny becomes a no-op. A path whose only existing ancestor is "/" must still
    /// come out as an ordinary absolute path.
    @Test func pathsUnderTheFilesystemRootKeepOneLeadingSlash() throws {
        let top = "/chatter-nonexistent-\(UUID().uuidString)"
        let profile = EngineSandbox.profile(root: URL(filePath: top + "/Chatter"), bundle: URL(filePath: "/bin"), executable: URL(filePath: "/bin/zsh"), home: URL(filePath: top))
        let strings = Self.strings(try #require(Self.forms(profile))).map { String(decoding: $0, as: UTF8.self) }
        withKnownIssue("canonicalPath joins realpath(\"/\") and the leaves with \"/\", producing \"//\"") {
            #expect(strings.contains(top) && strings.contains(top + "/Chatter"))
            #expect(!strings.contains { $0.hasPrefix("//") }, "\(strings)")
        }
    }
}
