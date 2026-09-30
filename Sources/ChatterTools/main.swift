import ChatterToolingKit
import Foundation

// Developer and verification commands for Chatter's Swift engine.
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "qwen-check": try QwenCheck.run(Array(arguments.dropFirst()))
    case "models": try await Models.run(Array(arguments.dropFirst()))
    case "transcribe": try await TranscribeCommand.run(Array(arguments.dropFirst()))
    case "assist": try await AssistCommand.run(Array(arguments.dropFirst()))
    case "remotion", "verify", "help", "-h", "--help", nil:
        // Integration commands (Remotion staging, installed-app verification).
        exit(await ChatterToolsCommand.run(arguments))
    default:
        FileHandle.standardError.write(Data("usage: chatter-tools remotion|verify|models|qwen-check|transcribe|assist …\n".utf8)); exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
}

enum ToolError: LocalizedError { case usage(String)
 var errorDescription: String? { switch self { case .usage(let message): message } }
}
