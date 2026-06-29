import Foundation

/// One typed part of a message's content - the framework's mirror of LangChain's content blocks.
/// A message's `content` is a list of these, so reasoning and images are first-class parts rather
/// than text smuggled inline or carried in side fields. `tool_call`s stay a dedicated attribute on
/// ``AgentMessage`` (as in LangChain), so they are not modeled here.
public enum AgentContentBlock: Sendable, Hashable {
    /// Visible answer text.
    case text(String)
    /// Chain-of-thought reasoning (LangChain's `reasoning` block; dropped when replaying history).
    case reasoning(String)
    /// An image (LangChain's `ImageContentBlock`): a URL, inline base64, or a provider file id.
    case image(AgentImage)
}

/// An image part - the framework's mirror of LangChain's `ImageContentBlock`. The three sources are
/// mutually exclusive: a remote/file `url`, inline `base64` data, or a provider `fileID`. `mimeType`
/// (e.g. `image/png`) describes the bytes for the base64 / file forms.
public struct AgentImage: Sendable, Hashable, Codable {
    public var url: URL?
    public var base64: String?
    public var mimeType: String?
    public var fileID: String?

    public init(url: URL? = nil, base64: String? = nil, mimeType: String? = nil, fileID: String? = nil) {
        self.url = url
        self.base64 = base64
        self.mimeType = mimeType
        self.fileID = fileID
    }
}

extension AgentContentBlock: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, reasoning, image }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = try .text(container.decode(String.self, forKey: .text))
        case "reasoning": self = try .reasoning(container.decode(String.self, forKey: .reasoning))
        case "image": self = try .image(container.decode(AgentImage.self, forKey: .image))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown content block type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .reasoning(let reasoning):
            try container.encode("reasoning", forKey: .type)
            try container.encode(reasoning, forKey: .reasoning)
        case .image(let image):
            try container.encode("image", forKey: .type)
            try container.encode(image, forKey: .image)
        }
    }
}
