import Foundation
import MCP
import Network
import OSLog
import Security

/// Errors from the MCP OAuth loopback sign-in flow.
enum MCPOAuthError: LocalizedError {
    case missingRedirectURI
    case invalidRedirect
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingRedirectURI:
            return "The authorization request did not include a loopback redirect URI to listen on."
        case .invalidRedirect:
            return "The browser sign-in redirect could not be read."
        case .timedOut:
            return "Timed out waiting for the browser sign-in to complete."
        }
    }
}

/// A ``TokenStorage`` that persists an MCP server's OAuth token (and its refresh token) in the
/// macOS Keychain, keyed per server, so a signed-in server stays signed in across launches and
/// re-connects without reopening the browser. `OAuthAccessToken` is `Codable`, so the whole token
/// round-trips as JSON.
public final class KeychainTokenStorage: TokenStorage, @unchecked Sendable {
    private let account: String
    private static let log = Logger(subsystem: "Mispher", category: "MCP.OAuth")

    public init(serverID: String) { account = serverID }

    public func save(_ token: OAuthAccessToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Self.log.error("Keychain save failed (\(status))") }
    }

    public func load() -> OAuthAccessToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(OAuthAccessToken.self, from: data)
    }

    public func clear() { SecItemDelete(baseQuery as CFDictionary) }

    /// Whether a token is currently stored for this server - drives the "Signed in" status.
    public var hasToken: Bool { load() != nil }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: DeepAgentsIdentity.keychainService,
            kSecAttrAccount as String: account
        ]
    }
}

/// An ``OAuthAuthorizationDelegate`` that signs the user in through the system browser and catches
/// the OAuth redirect on a loopback HTTP listener.
///
/// It self-configures from the authorization URL: the SDK defaults the redirect to a random
/// `http://127.0.0.1:<port>/callback` and embeds it as the request's `redirect_uri`, so the
/// delegate reads that back, listens on that loopback port, opens the browser, and returns the
/// captured redirect (with `code` and `state`). Needs no setup and works in both the app and the
/// ripple CLI - no custom URL scheme to register.
public struct LoopbackBrowserAuthDelegate: OAuthAuthorizationDelegate {
    /// How long to wait for the user to finish signing in before giving up.
    private let timeout: Duration
    /// Opens the authorization URL in the user's browser. Injected so the framework carries no
    /// UI-framework dependency — the app and `ripple` CLI pass `NSWorkspace.shared.open`.
    private let openURL: @Sendable (URL) -> Void
    /// The HTML the browser lands on after the redirect (the "Signed in" page). Injected so each
    /// front-end can serve its own branding; defaults to the Mispher page.
    private let successHTML: String

    public init(
        timeout: Duration = .seconds(300), openURL: @escaping @Sendable (URL) -> Void,
        successHTML: String = MCPOAuthSuccessPage.mispher
    ) {
        self.timeout = timeout
        self.openURL = openURL
        self.successHTML = successHTML
    }

    public func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard let redirect = Self.redirectURI(from: url),
              let portValue = redirect.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue))
        else { throw MCPOAuthError.missingRedirectURI }

        let catcher = LoopbackRedirectCatcher(port: port, successHTML: successHTML)
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await catcher.waitForRedirect() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MCPOAuthError.timedOut
            }
            openURL(url)
            defer {
                group.cancelAll()
                catcher.cancel()
            }
            guard let result = try await group.next() else { throw MCPOAuthError.invalidRedirect }
            return result
        }
    }

    /// The `redirect_uri` the SDK put in the authorization request - the loopback URI we listen on.
    static func redirectURI(from authURL: URL) -> URL? {
        guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
        else { return nil }
        return URL(string: value)
    }
}

/// Listens on `127.0.0.1:<port>` for the browser's single GET to the OAuth callback, then returns
/// the full redirect URL (path + `code`/`state` query). All mutable state is confined to `queue`,
/// so the unchecked `Sendable` is sound.
final class LoopbackRedirectCatcher: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private let successHTML: String
    private let queue = DispatchQueue(label: "ai.mispher.mcp.oauth.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false

    init(port: NWEndpoint.Port, successHTML: String) {
        self.port = port
        self.successHTML = successHTML
    }

    func waitForRedirect() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.start(continuation) }
        }
    }

    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

    private func start(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in self?.receive(on: connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.finish(.failure(error)) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            finish(.failure(error))
        }
    }

    private func receive(on connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let request = String(data: data, encoding: .utf8),
               let target = Self.requestTarget(request) {
                connection.send(
                    content: Data(httpResponse.utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                if let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(target)") {
                    finish(.success(url))
                } else {
                    finish(.failure(MCPOAuthError.invalidRedirect))
                }
            } else {
                connection.cancel()
                if let error { finish(.failure(error)) }
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    /// The request-target (path + query) from the HTTP request line, e.g.
    /// `/callback?code=…&state=…`. Only a `GET` is accepted.
    static func requestTarget(_ request: String) -> String? {
        guard let line = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    /// The HTTP/1.1 response wrapping ``successHTML`` (served once, then the connection closes).
    private var httpResponse: String {
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(successHTML.utf8.count)\r\nConnection: close\r\n\r\n\(successHTML)"
    }
}

/// The "Signed in" page the browser lands on after the OAuth loopback redirect. Self-contained
/// (inline CSS/SVG, no external assets) since the loopback listener serves it once and then closes.
/// A front-end passes its own page through ``SwiftSDKMCPSession`` / ``makeMCPOAuthAuthorizer``;
/// the framework default is ``mispher``.
public enum MCPOAuthSuccessPage {
    /// Mispher's dark glass + cyan/green palette (the framework default, used by the app).
    public static let mispher = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Mispher - Signed in</title>
    <style>
      :root { --accent:#73d6e8; --success:#40d199; --fg:#eef2f6; --fg2:#97a3b0; }
      * { box-sizing:border-box; margin:0; }
      html, body { height:100%; }
      body {
        font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;
        color:var(--fg);
        background:
          radial-gradient(1100px 680px at 50% -12%, rgba(115,214,232,.10), transparent 60%),
          radial-gradient(820px 560px at 86% 116%, rgba(64,209,153,.09), transparent 55%),
          linear-gradient(160deg,#0d0f15,#101317 55%,#121a20);
        display:flex; align-items:center; justify-content:center; padding:24px;
        -webkit-font-smoothing:antialiased;
      }
      .card {
        width:min(440px,92vw); text-align:center; padding:46px 40px 34px;
        background:linear-gradient(180deg, rgba(22,26,33,.86), rgba(13,15,21,.86));
        border:1px solid rgba(255,255,255,.08); border-radius:22px;
        box-shadow:0 26px 70px -24px rgba(0,0,0,.65), inset 0 1px 0 rgba(255,255,255,.05);
        backdrop-filter:blur(14px); animation:rise .55s cubic-bezier(.2,.8,.2,1) both;
      }
      .badge {
        width:74px; height:74px; margin:0 auto 24px; border-radius:50%; display:grid; place-items:center;
        background:radial-gradient(circle at 50% 34%, rgba(64,209,153,.30), rgba(64,209,153,.05));
        box-shadow:0 0 0 1px rgba(64,209,153,.35), 0 0 44px rgba(64,209,153,.28);
        animation:pop .5s .12s cubic-bezier(.2,1.3,.4,1) both;
      }
      .badge svg {
        width:36px; height:36px; fill:none; stroke:var(--success); stroke-width:3.1;
        stroke-linecap:round; stroke-linejoin:round;
        stroke-dasharray:30; stroke-dashoffset:30; animation:draw .5s .32s ease forwards;
      }
      h1 { font-size:22px; font-weight:600; letter-spacing:-.012em; }
      p { margin-top:11px; font-size:13.5px; line-height:1.55; color:var(--fg2); }
      .brand {
        margin-top:28px; font-size:11px; letter-spacing:.22em; text-transform:uppercase; font-weight:700;
        background:linear-gradient(90deg,var(--accent),var(--success));
        -webkit-background-clip:text; background-clip:text; color:transparent; opacity:.9;
      }
      @keyframes rise { from{opacity:0; transform:translateY(12px) scale(.985)} to{opacity:1; transform:none} }
      @keyframes pop  { from{opacity:0; transform:scale(.6)} to{opacity:1; transform:none} }
      @keyframes draw { to{stroke-dashoffset:0} }
    </style>
    </head>
    <body>
      <main class="card">
        <div class="badge"><svg viewBox="0 0 24 24"><path d="M5 12.5l4.2 4.2L19 7"/></svg></div>
        <h1>Signed in</h1>
        <p>You're connected. You can close this window and return to Mispher.</p>
        <div class="brand">Mispher</div>
      </main>
      <script>setTimeout(function(){ try { window.close(); } catch (e) {} }, 2200);</script>
    </body>
    </html>
    """
}

/// Build the OAuth authorizer for an `oauth` server: the browser authorization-code flow
/// (``LoopbackBrowserAuthDelegate``) with Keychain-persisted tokens. The SDK handles discovery,
/// dynamic client registration (RFC 7591), PKCE, and proactive refresh; the cached token is reused
/// so the browser only reopens when there's no valid token.
func makeMCPOAuthAuthorizer(
    for config: MCPServerConfig, openURL: @escaping @Sendable (URL) -> Void,
    successHTML: String = MCPOAuthSuccessPage.mispher
) -> OAuthAuthorizer {
    let oauth = OAuthConfiguration(
        grantType: .authorizationCode,
        authentication: .none(clientID: DeepAgentsIdentity.oauthClientID),
        clientName: DeepAgentsIdentity.productName,
        authorizationDelegate: LoopbackBrowserAuthDelegate(openURL: openURL, successHTML: successHTML)
    )
    return OAuthAuthorizer(
        configuration: oauth,
        tokenStorage: KeychainTokenStorage(serverID: config.id.uuidString)
    )
}
