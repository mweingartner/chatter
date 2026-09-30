import ChatterCore
import Foundation

/// `chatter-tools models install|status [--root <modelsDir>]`
enum Models {
    static func run(_ args: [String]) async throws {
        var root = ChatterPaths.models
        if let index = args.firstIndex(of: "--root"), index + 1 < args.count { root = URL(filePath: args[index + 1]) }
        let installer = ModelInstaller(modelsRoot: root)
        switch args.first {
        case "install":
            try await installer.install { FileHandle.standardOutput.write(Data($0.utf8)) }
        case "status", nil:
            print(installer.isInstalled ? "installed" : "missing \(ByteCountFormatter.string(fromByteCount: installer.missingBytes, countStyle: .file))")
        default:
            throw ToolError.usage("models install|status [--root <modelsDir>]")
        }
    }
}
