import Foundation

/// Incremental decoder for the AWS `vnd.amazon.eventstream` framing that Bedrock's
/// `invoke-with-response-stream` returns. Each frame wraps one Anthropic Messages event; for a
/// `chunk` message the payload is `{"bytes": "<base64>"}` whose decoded bytes are the event JSON
/// (`content_block_delta`, …). Feed it whatever byte chunks arrive - frames are reassembled across
/// chunk boundaries - and it yields the inner event payloads (plus any error/exception frame text).
struct BedrockEventStreamParser {
    private var buffer = Data()

    /// Frame layout (big-endian): [total length: 4][headers length: 4][prelude CRC: 4]
    /// [headers][payload][message CRC: 4]. The CRCs are not verified (the transport is trusted).
    mutating func ingest(_ chunk: Data) -> (events: [Data], errors: [String]) {
        buffer.append(chunk)
        var events: [Data] = []
        var errors: [String] = []
        while buffer.count >= 4 {
            let total = Int(Self.beUInt32(buffer, at: 0))
            guard total >= 16, buffer.count >= total else { break }
            let frame = buffer.subdata(in: buffer.startIndex ..< buffer.startIndex + total)
            buffer.removeFirst(total)
            switch Self.parse(frame) {
            case .event(let data): events.append(data)
            case .error(let message): errors.append(message)
            case .none: break
            }
        }
        return (events, errors)
    }

    private enum Parsed {
        case event(Data)
        case error(String)
        case none
    }

    private static func parse(_ frame: Data) -> Parsed {
        guard frame.count >= 16 else { return .none }
        let total = Int(beUInt32(frame, at: 0))
        let headersLength = Int(beUInt32(frame, at: 4))
        let payloadStart = 12 + headersLength
        let payloadEnd = total - 4
        guard headersLength >= 0, payloadStart <= payloadEnd, payloadEnd <= frame.count else { return .none }
        let payload = frame.subdata(in: frame.startIndex + payloadStart ..< frame.startIndex + payloadEnd)

        // A `chunk` message wraps the event JSON as base64 in a `bytes` field; anything else
        // (an exception or error message) is surfaced as the raw payload text.
        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let base64 = object["bytes"] as? String, let inner = Data(base64Encoded: base64) {
            return .event(inner)
        }
        let text = String(data: payload, encoding: .utf8) ?? ""
        return text.isEmpty ? .none : .error(text)
    }

    private static func beUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let index = data.startIndex + offset
        return (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }
}
