import CryptoKit
import Foundation

/// AWS Signature Version 4 signing for the Bedrock Runtime endpoint - hand-rolled with CryptoKit
/// (`SHA256` + `HMAC<SHA256>`) so the adapter needs no AWS SDK. Signs only the headers Bedrock
/// requires (`host`, `x-amz-date`, and `x-amz-security-token` when a session token is present).
enum SigV4 {
    /// Sign `request` (URL, method, and body already set) in place: adds `Authorization`,
    /// `X-Amz-Date`, and - when the credentials carry a session token - `X-Amz-Security-Token`.
    static func sign(
        _ request: inout URLRequest, body: Data, credentials: BedrockCredentials, region: String,
        service: String = "bedrock", date: Date = Date()
    ) {
        guard let url = request.url, let host = url.host() else { return }
        let sessionToken = credentials.sessionToken
        let amzDate = amzDateFormatter.string(from: date)
        let dateStamp = dateStampFormatter.string(from: date)
        let method = request.httpMethod ?? "POST"
        let path = url.path(percentEncoded: true)
        let canonicalURI = path.isEmpty ? "/" : path

        var headers: [(name: String, value: String)] = [("host", host), ("x-amz-date", amzDate)]
        if let sessionToken, !sessionToken.isEmpty {
            headers.append(("x-amz-security-token", sessionToken))
        }
        headers.sort { $0.name < $1.name }
        let canonicalHeaders = headers.map { "\($0.name):\($0.value)\n" }.joined()
        let signedHeaders = headers.map(\.name).joined(separator: ";")

        let canonicalRequest = [
            method, canonicalURI, "", canonicalHeaders, signedHeaders, hexSHA256(body)
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, hexSHA256(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = derivedKey(
            secretKey: credentials.secretKey, dateStamp: dateStamp, region: region, service: service
        )
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
    }

    // MARK: - Crypto helpers

    /// The SigV4 derived signing key: HMAC-chain `secret → date → region → service → "aws4_request"`.
    static func derivedKey(secretKey: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
        let kDate = hmac(SymmetricKey(data: Data("AWS4\(secretKey)".utf8)), dateStamp)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        return hmac(kService, "aws4_request")
    }

    private static func hmac(_ key: SymmetricKey, _ string: String) -> SymmetricKey {
        SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: key))
    }

    static func hexSHA256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Date formatters (UTC, fixed POSIX locale)

    private static let amzDateFormatter = fixedFormatter("yyyyMMdd'T'HHmmss'Z'")
    private static let dateStampFormatter = fixedFormatter("yyyyMMdd")

    private static func fixedFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
