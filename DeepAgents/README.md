# DeepAgents

An inference-agnostic agent framework for Swift: a ReAct loop, a composable middleware system, an
MCP client, and generic toolsets -- plus interchangeable model backends. The core `DeepAgents`
target carries no MLX and no AppKit dependency, so the framework can be retargeted to any backend
by writing a single `ChatModel` conformance.

## Products

| Product | What it is | Heavy deps |
|---------|------------|-----------|
| `DeepAgents` | The framework: ReAct loop, middleware, MCP client, toolsets | none (Foundation + MCP) |
| `DeepAgentsMLX` | On-device inference via MLX (model loading, LFM2 parser/template) | MLX, Tokenizers |
| `DeepAgentsOpenAI` | OpenAI-compatible chat-completions backend (also Azure OpenAI) | none (URLSession) |
| `DeepAgentsAnthropic` | Anthropic Messages backend + AWS Bedrock (SigV4) | none (CryptoKit) |
| `DeepAgentsMacTools` | macOS tools: screenshot, clipboard, Apple Notes, CLI | AppKit, ScreenCaptureKit |

A CI guard fails the build on any `import MLX` or `import AppKit` under the core target, keeping it
portable.

## Requirements

- macOS 26+
- Swift 6.1+ (Swift 6 language mode)

## Install

```swift
.package(url: "https://github.com/dsaad68/deepagents-swift.git", from: "0.2.3")
```

Then depend on the products you need, e.g. `DeepAgents` + one backend:

```swift
.product(name: "DeepAgents", package: "deepagents-swift"),
.product(name: "DeepAgentsAnthropic", package: "deepagents-swift")
```

## Retargeting the backend

The core has no notion of where tokens come from. Conform a type to `ChatModel` and the ReAct loop,
middleware, and tools work unchanged -- the four adapters above are themselves just `ChatModel`
implementations.

## License

MIT. See `LICENSE`.
