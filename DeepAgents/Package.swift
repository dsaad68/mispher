// swift-tools-version: 6.1
import PackageDescription

// DeepAgents.swift -- an inference-agnostic agent framework (ReAct loop, middleware system,
// MCP client, generic toolsets) plus two adapters. The pure `DeepAgents` target carries no
// MLX or AppKit dependency; on-device inference lives in `DeepAgentsMLX` and macOS tools in
// `DeepAgentsMacTools`, so the framework can be retargeted to another backend by writing a new
// `ChatModel`. Consumed by the Ripple CLI and the Mispher app via local path dependencies.
let package = Package(
    name: "DeepAgents",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DeepAgents", targets: ["DeepAgents"]),
        .library(name: "DeepAgentsMLX", targets: ["DeepAgentsMLX"]),
        .library(name: "DeepAgentsOpenAI", targets: ["DeepAgentsOpenAI"]),
        .library(name: "DeepAgentsAnthropic", targets: ["DeepAgentsAnthropic"]),
        .library(name: "DeepAgentsMacTools", targets: ["DeepAgentsMacTools"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0", traits: ["Xet"]),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0", traits: ["Xet"]),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0")
    ],
    targets: [
        // The framework -- no MLX, no AppKit. A CI guard (Scripts/check-framework-imports.sh)
        // fails on any `import MLX`/`import AppKit` under this target's sources.
        .target(
            name: "DeepAgents",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: swiftSettings
        ),
        // On-device inference adapter: MlxChatModel + model loading + the LFM2 parser/template
        // and the MLX bridge extensions.
        .target(
            name: "DeepAgentsMLX",
            dependencies: [
                "DeepAgents",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            swiftSettings: swiftSettings
        ),
        // OpenAI-compatible inference adapter: OpenAIChatModel + the streaming chat-completions
        // turn session. Pure Foundation (URLSession) - no MLX, no AppKit. Also serves Azure OpenAI
        // (a deployment-path endpoint + `api-key` auth style on the same chat-completions wire).
        .target(
            name: "DeepAgentsOpenAI",
            dependencies: ["DeepAgents"],
            swiftSettings: swiftSettings
        ),
        // Anthropic Messages adapter: AnthropicChatModel (direct API) and BedrockChatModel
        // (Anthropic models on AWS Bedrock - SigV4-signed, AWS event-stream framing). Both reuse
        // one Messages codec + decoder. Pure Foundation + CryptoKit - no MLX, no AppKit.
        .target(
            name: "DeepAgentsAnthropic",
            dependencies: ["DeepAgents"],
            swiftSettings: swiftSettings
        ),
        // macOS tools adapter: screenshot / clipboard / Apple Notes / mac CLI tools (AppKit,
        // ScreenCaptureKit, osascript). No MLX.
        .target(
            name: "DeepAgentsMacTools",
            dependencies: ["DeepAgents"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DeepAgentsTests",
            dependencies: [
                "DeepAgents",
                "DeepAgentsMLX",
                "DeepAgentsOpenAI",
                "DeepAgentsAnthropic",
                "DeepAgentsMacTools",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DeepAgentsIntegrationTests",
            dependencies: [
                "DeepAgents",
                "DeepAgentsMLX",
                "DeepAgentsOpenAI",
                "DeepAgentsAnthropic",
                "DeepAgentsMacTools",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm")
            ],
            swiftSettings: swiftSettings
        )
    ]
)

// Mirror the app's "Approachable Concurrency" build settings (Swift 6 language mode with the
// curated upcoming features) so code moved out of the app keeps the same concurrency semantics.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .swiftLanguageMode(.v6)
]
