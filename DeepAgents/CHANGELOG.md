# Changelog

All notable changes to the DeepAgents Swift framework are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.4] - 2026-06-29

### Added

- **AWS Bedrock bearer-token (API key) authentication.** `BedrockChatModel` now authenticates via a
  new `BedrockAuth` enum -- either AWS SigV4 request signing (`.sigV4(BedrockCredentials)`) or an
  Amazon Bedrock API key sent as `Authorization: Bearer <token>` (`.bearerToken(String)`).
  `BedrockAuth.resolve(bearerToken:)` prefers an explicit token, then the `AWS_BEARER_TOKEN_BEDROCK`
  environment variable, then SigV4 environment credentials. `BedrockChatModel` gains an optional
  `baseURL` used verbatim as the endpoint base (required for bearer auth; SigV4 still derives the
  endpoint from `region`).

### Changed

- **`BedrockChatModel.init` takes `auth: BedrockAuth` instead of `credentials: BedrockCredentials`.**
  Migrate `credentials: creds` call sites to `auth: .sigV4(creds)`.

## [0.2.3] - 2026-06-26

### Added

- **`requireOAuth` on `SwiftSDKMCPSession`.** A new initializer flag that force-attaches the SDK's
  OAuth authorizer to an HTTP server even when its config carries no `oauth` key -- used to drive a
  sign-in against a server whose auth requirement was discovered from a `401` rather than declared up
  front.

### Changed

- **HTTP MCP transport attaches the OAuth authorizer more eagerly.** It is now attached when the
  server is declared `oauth`, when `requireOAuth` is set, **or when a Keychain token already exists**
  for the server. This lets a server that was signed in once reconnect silently (no `oauth` key
  needed) and lets a host discover-then-sign-in a plain HTTP server. The authorizer stays lazy -- it
  only runs the browser flow on a `401`, so attaching it never opens a browser while a token is valid.

## [0.2.2]

- Added the `DeepAgentsVersion.current` constant so host front-ends (the Ripple CLI's `--version`,
  the Mispher app's About pane) can report the framework build they were compiled against.

[0.2.3]: https://github.com/dsaad68/deepagents-swift/releases/tag/0.2.3
[0.2.2]: https://github.com/dsaad68/deepagents-swift/releases/tag/0.2.2
