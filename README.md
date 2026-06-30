<p align="center">
  <img src="logo.png" width="140" alt="Mispher">
</p>

<h1 align="center">Mispher</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.1%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.1+">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-555555?style=flat-square&logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/License-MIT-22c55e?style=flat-square" alt="MIT">
</p>

<p align="center">
  <b>Voice to text, and an agent. Entirely on your Mac.</b><br>
  On-device transcription, dictation cleanup, rewrite-in-place, translation, and an on-device
  agent. No cloud, no accounts. Runs <a href="https://huggingface.co/LiquidAI">LFM2.5</a> models
  locally on Apple Silicon via MLX, built on
  <a href="https://github.com/dsaad68/deepagents-swift">DeepAgents-swift</a>.
</p>

<p align="center">
  <a href="https://dsaad68.github.io/mispher/">Website</a> &middot;
  <a href="https://github.com/dsaad68/mispher/releases/latest">Releases</a> &middot;
  <a href="CHANGELOG.md">Changelog</a>
</p>

---

## Install

**Homebrew (recommended)** -- a signed, notarized build, no Xcode required:

```sh
brew install --cask dsaad68/tap/mispher
```

**Direct download** -- grab the latest signed `Mispher.dmg` from the
[releases page](https://github.com/dsaad68/mispher/releases/latest) (or the
[website](https://dsaad68.github.io/mispher/)), open it, and drag **Mispher** to Applications.

Models come from your local Hugging Face cache; pre-fetch a planner first, e.g.:

```sh
hf download LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

## Features

- **The dial** -- a hotkey-summoned radial menu for switching modes, with an editable layout.
- **On-device transcription** -- voice to text on Apple Silicon, no network round-trip.
- **Dictation cleanup & rewrite-in-place** -- tidy a transcript or rewrite selected text where it sits.
- **Translation** -- across languages, on device.
- **An on-device agent** -- a DeepAgents ReAct loop with an MCP client and tool middleware: vision /
  screenshot understanding, Apple Notes, filesystem, clipboard, and screen capture.
- **Global hotkey** -- summon Mispher from anywhere.

Everything runs locally on Apple Silicon. No cloud, no accounts.

## Requirements

- macOS 26+ (Tahoe), Apple Silicon (arm64)

## Build from source

Open the app project in Xcode and build the `Mispher` scheme:

```sh
open app/Mispher/Mispher.xcodeproj
```

Xcode resolves the [DeepAgents-swift](https://github.com/dsaad68/deepagents-swift) Swift package on
first build (one-time network fetch). Xcode 26+ is required -- its build system emits MLX's Metal
shader library, which `swift build` does not co-locate.

## License

MIT -- see [`LICENSE`](LICENSE). Copyright (c) Daniel Saad.

Mispher depends on the [DeepAgents-swift](https://github.com/dsaad68/deepagents-swift) framework
(MIT), maintained separately and resolved as a Swift package.
