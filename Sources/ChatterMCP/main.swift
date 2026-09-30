// Chatter integration tooling (Swift replacement for the former Python helpers).
// chatter-mcp: stdio JSON-RPC ↔ POST <CHATTER_URL>/mcp. One line in, at most one line out; exits 0 at EOF.
import ChatterToolingKit
import Foundation

do {
    try await MCPBridge().run()
} catch {
    // stdout/stderr closed: nothing left to report to.
    exit(1)
}
