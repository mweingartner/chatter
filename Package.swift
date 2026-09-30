// swift-tools-version: 6.2
import PackageDescription

// Chatter is all Swift. The app target stays free of MLX; the speech model runs in the
// separately supervised `chatter-engine` helper so a GPU fault cannot take down the
// HTTP/MCP service or the durable queue. Qwen models use MLX with the upstream tokenizer and cache primitives.
let mlx: [Target.Dependency] = [
    .product(name: "MLX", package: "mlx-swift"),
    .product(name: "MLXNN", package: "mlx-swift"),
    .product(name: "MLXFast", package: "mlx-swift"),
    .product(name: "MLXRandom", package: "mlx-swift"),
]

let package = Package(
    name: "Chatter", platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Chatter", targets: ["Chatter"]),
        .executable(name: "chatter-engine", targets: ["ChatterEngineHost"]),
        .executable(name: "chatter-mcp", targets: ["ChatterMCP"]),
        .executable(name: "chatter-tools", targets: ["ChatterTools"]),
    ],
    dependencies: [
        // Complete pinned dependency source is included; no package fetch is required.
        .package(path: "Vendor/Packages/EventSource"),
        .package(path: "Vendor/Packages/mlx-swift"),
        .package(path: "Vendor/Packages/mlx-swift-lm"),
        .package(path: "Vendor/Packages/swift-asn1"),
        .package(path: "Vendor/Packages/swift-collections"),
        .package(path: "Vendor/Packages/swift-crypto"),
        .package(path: "Vendor/Packages/swift-huggingface"),
        .package(path: "Vendor/Packages/swift-jinja"),
        .package(path: "Vendor/Packages/swift-numerics"),
        .package(path: "Vendor/Packages/swift-syntax"),
        .package(path: "Vendor/Packages/swift-transformers"),
        .package(path: "Vendor/Packages/yyjson"),
    ],
    targets: [
        .target(name: "ChatterCore"),
        .target(name: "ChatterAudioKit"),
        .target(name: "ChatterToolingKit"),
        .target(name: "Qwen3CodecSupport", dependencies: mlx + [.product(name: "MLXLMCommon", package: "mlx-swift-lm")]),
        .target(name: "Qwen3Speech", dependencies: mlx + ["Qwen3CodecSupport", .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "Tokenizers", package: "swift-transformers")]),
        .target(name: "ChatterEngine", dependencies: ["Qwen3Speech", "ChatterAudioKit", "ChatterCore"]),
        .executableTarget(name: "ChatterEngineHost", dependencies: ["ChatterEngine", "ChatterCore"]),
        .executableTarget(name: "Chatter", dependencies: ["ChatterCore"]),
        .executableTarget(name: "ChatterMCP", dependencies: ["ChatterToolingKit"]),
        .executableTarget(name: "ChatterTools", dependencies: ["ChatterEngine", "ChatterAudioKit", "ChatterCore", "Qwen3Speech", "ChatterToolingKit"]),
        .testTarget(name: "ChatterCoreTests", dependencies: ["ChatterCore"]),
        .testTarget(name: "ChatterAudioKitTests", dependencies: ["ChatterAudioKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ChatterToolingKitTests", dependencies: ["ChatterToolingKit"]),
        .testTarget(name: "ChatterEngineTests", dependencies: ["ChatterEngine", "ChatterAudioKit", "ChatterCore", "Qwen3Speech"],
                    resources: [.copy("Fixtures")]),
    ]
)
