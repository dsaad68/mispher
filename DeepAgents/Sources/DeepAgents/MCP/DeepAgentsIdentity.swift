import Foundation

/// Product branding the host front-end injects once at startup, so the shared MCP code presents the
/// right name instead of a baked-in one. The values default to Mispher (the app), which is why the
/// app needs no setup and its existing Keychain entries keep working; the `ripple` CLI overrides them
/// in `main()` before any MCP / Keychain use, so the macOS Keychain prompt, the OAuth consent client
/// name, and the name sent to MCP servers all read "Ripple".
///
/// The "Signed in" browser page is *not* here - it is already injected per front-end through the
/// `successHTML` parameter (`RippleOAuthPage.signedIn` for the CLI).
///
/// `nonisolated(unsafe)` matches the `Terminal.saved` pattern: set once at launch before any
/// concurrency, then only read, so the unchecked mutable global is safe.
public enum DeepAgentsIdentity {
    /// Keychain service string holding MCP OAuth tokens - shown verbatim in the macOS Keychain prompt.
    public nonisolated(unsafe) static var keychainService = "ai.mispher.mcp.oauth"
    /// Human-readable product name: the OAuth consent client name and the MCP client name.
    public nonisolated(unsafe) static var productName = "Mispher"
    /// OAuth dynamic-registration client id.
    public nonisolated(unsafe) static var oauthClientID = "mispher"
}
