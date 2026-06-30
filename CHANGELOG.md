# Changelog

All notable changes to the Mispher app are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.4] - 2026-06-30

### Changed

- **Auto-end on silence is on by default, after 2.5s.** New installs now finish a Trigger or
  Hold-and-release recording automatically once speech pauses for 2.5 seconds (previously off, with a
  1.6s length). Existing installs keep their current choice; both are adjustable in Settings.

## [1.0.3] - 2026-06-30

### Changed

- **Updated default settings for new installs.**
  - Voice modes (Transcribe / Rewrite / Translate) now use the **Floating** overlay by default, and it
    follows the mouse pointer.
  - **Ask** now uses its own overlay style by default - the **Dynamic Island** - distinct from the
    voice modes.
  - The **Rewrite** and **Translate** models default to **LFM2.5 1.2B Instruct (8-bit)**.
  - The Ask agent's **vision model** defaults to **None** (the planner runs without a VLM until you
    pick one in Settings - Ask).
  - The radial dial stays on and AI dictation cleanup stays off by default.

  Existing installs keep any settings you have already changed.

## [1.0.2] - 2026-06-30

### Fixed

- **Granting microphone access in onboarding now works.** The app runs with the Hardened Runtime
  (required for notarization), which gates the microphone behind the
  `com.apple.security.device.audio-input` entitlement. It was missing - there was no entitlements
  file at all - so macOS blocked the mic and the grant had no effect. Added an app entitlements file
  with that entitlement, plus `com.apple.security.automation.apple-events` so the Ask agent can drive
  Apple Notes. The onboarding Microphone row also gained an "Open Settings" link to recover when
  access was denied earlier (macOS only shows the prompt once).

## [1.0.1] - 2026-06-30

### Packaging

- **Homebrew cask.** Mispher is now installable as a prebuilt, signed + notarized app:
  ```sh
  brew install --cask dsaad68/tap/mispher
  ```
  Each release attaches `Mispher.dmg` to the GitHub Release and bumps the cask formula automatically.
- **Depends on the published DeepAgents-swift package.** The public repo now resolves
  [DeepAgents-swift](https://github.com/dsaad68/deepagents-swift) as a Swift package (pinned to 0.2.4)
  instead of shipping a vendored copy. Local development is unchanged.

## [1.0] - 2026-06-26

### Added

- **Radial mode picker (the "dial").** A radial menu for switching modes, summoned by a hotkey, with
  an editable on-screen layout and size. The onboarding flow gained a fork that teaches the control,
  and window surfacing was improved so the menu and the main window come forward reliably.
- **About pane in Settings.** Shows the Mispher and DeepAgents-swift versions, a link to the
  DeepAgents-swift docs, and author/website links.

### Notes

- Built on the [DeepAgents-swift](https://github.com/dsaad68/deepagents-swift) framework (then
  vendored at `./DeepAgents`, 0.2.3; resolved as a Swift package from 1.0.1 onward).
