// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// Minimal argparse-compatible parsing: positionals, `--name value`, `--name=value`, unambiguous
/// prefixes (`--wait` for `--wait-seconds`), `--` to end options, and `-h`/`--help`.
public struct CommandLineArguments: Sendable, Equatable {
    public private(set) var positionals: [String] = []
    /// Last value given for each option, keyed by its full name without dashes.
    public private(set) var values: [String: String] = [:]
    public private(set) var helpRequested = false

    /// Parses `arguments` against the value-taking `options` (names without leading dashes).
    public init(_ arguments: [String], options: [String]) throws(CommandLineError) {
        var remaining = arguments[...]
        var optionsEnded = false
        while let argument = remaining.popFirst() {
            if optionsEnded || !Self.looksLikeOption(argument) {
                positionals.append(argument)
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }
            if argument == "-h" || argument == "--help" {
                helpRequested = true
                continue
            }
            guard argument.hasPrefix("--") else { throw .unrecognized(argument) }
            let body = argument.dropFirst(2)
            let (typed, inlineValue) = body.firstIndex(of: "=").map {
                (String(body[..<$0]), Optional(String(body[body.index(after: $0)...])))
            } ?? (String(body), nil)
            let name: String
            if options.contains(typed) {
                name = typed
            } else {
                let matches = options.filter { $0.hasPrefix(typed) }
                guard !typed.isEmpty, !matches.isEmpty else { throw .unrecognized(argument) }
                guard matches.count == 1 else { throw .ambiguous("--" + typed, matches.map { "--" + $0 }) }
                name = matches[0]
            }
            if let inlineValue {
                values[name] = inlineValue
            } else if let next = remaining.first, !Self.looksLikeOption(next) {
                values[name] = next
                remaining.removeFirst()
            } else {
                throw .missingValue("--" + name)
            }
        }
    }

    /// Like argparse: `-5` or `-0.5` is a value, not an option.
    static func looksLikeOption(_ argument: String) -> Bool {
        argument.hasPrefix("-") && argument != "-" && Double(argument) == nil
    }

    public subscript(option: String) -> String? { values[option] }
}

/// Usage errors, worded like argparse's.
public enum CommandLineError: ChatterToolingFailure, Sendable, Equatable {
    case unrecognized(String)
    case ambiguous(String, [String])
    case missingValue(String)
    case missingRequired([String])
    case invalidNumber(option: String, value: String)
    case unknownCommand(String)

    public var description: String {
        switch self {
        case .unrecognized(let argument): "unrecognized arguments: \(argument)"
        case .ambiguous(let option, let matches):
            "ambiguous option: \(option) could match \(matches.joined(separator: ", "))"
        case .missingValue(let option): "argument \(option): expected one argument"
        case .missingRequired(let names): "the following arguments are required: \(names.joined(separator: ", "))"
        case .invalidNumber(let option, let value): "argument \(option): invalid float value: '\(value)'"
        case .unknownCommand(let command): "unknown command: \(command)"
        }
    }
}
