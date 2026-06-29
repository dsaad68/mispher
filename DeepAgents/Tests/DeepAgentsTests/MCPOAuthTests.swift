@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import Testing

// Tests for the MCP OAuth loopback helpers and the `MCPServerConfig` auth field. The browser /
// Keychain / listener side effects aren't exercised here; these cover the pure parsing the flow
// depends on (reading the redirect URI back out of the auth URL, and the callback request line)
// plus the config's tolerant decoding.

@Suite("MCP OAuth loopback parsing")
struct MCPOAuthParsingTests {
    @Test("Reads the loopback redirect URI back out of the authorization URL")
    func redirectURIFromAuthURL() {
        let auth = URL(
            string: "https://auth.example.com/authorize?response_type=code&client_id=mispher"
                + "&redirect_uri=http://127.0.0.1:52345/callback&state=abc&code_challenge=xyz"
        )!
        let redirect = LoopbackBrowserAuthDelegate.redirectURI(from: auth)
        #expect(redirect?.port == 52345)
        #expect(redirect?.path == "/callback")
    }

    @Test("Returns nil when the authorization URL has no redirect_uri")
    func redirectURIMissing() throws {
        let auth = try #require(URL(string: "https://auth.example.com/authorize?response_type=code"))
        #expect(LoopbackBrowserAuthDelegate.redirectURI(from: auth) == nil)
    }

    @Test("Extracts the request target from the callback GET line")
    func requestTarget() {
        let request = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(LoopbackRedirectCatcher.requestTarget(request) == "/callback?code=abc123&state=xyz")
    }

    @Test("Ignores non-GET or malformed request lines")
    func requestTargetRejects() {
        #expect(LoopbackRedirectCatcher.requestTarget("POST /callback HTTP/1.1\r\n") == nil)
        #expect(LoopbackRedirectCatcher.requestTarget("garbage") == nil)
    }
}

@Suite("MCPServerConfig auth codable")
struct MCPServerConfigAuthTests {
    @Test("auth round-trips through JSON")
    func roundTrip() throws {
        let config = MCPServerConfig(
            name: "parallel", kind: .http, url: "https://search.parallel.ai/mcp-oauth",
            auth: .oauth, approvalMode: .ask
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        #expect(decoded.auth == .oauth)
        #expect(decoded.approvalMode == .ask)
    }

    @Test("Older JSON without auth/approvalMode decodes with defaults (no servers dropped)")
    func tolerantDecode() throws {
        let json = Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"old","kind":"http","url":"https://x/mcp"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: json)
        #expect(decoded.auth == MCPServerConfig.Auth.none)
        #expect(decoded.approvalMode == .ask)
        #expect(decoded.isEnabled) // default preserved
    }
}
