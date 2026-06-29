import Foundation

/// A streamed piece of one assistant turn, classified by channel: visible answer `text` or
/// chain-of-thought `reasoning`. A `ModelTurnSession` streams these to the agent (which maps them
/// to `AgentEvent.token` / `AgentEvent.reasoningToken`), so reasoning is surfaced live on its own
/// channel rather than smuggled inline in the answer text.
public enum AgentStreamChunk: Sendable {
    case text(String)
    case reasoning(String)
}

/// Converts between the canonical ``AgentMessage`` and one model's wire format - the framework's
/// mirror of LangChain's per-integration `_convert_message_to_dict` (encode) and
/// `_convert_delta_to_message_chunk` (decode). A `ModelTurnSession` owns a codec and keeps only the
/// transport (running the model / the HTTP call); all model-specific quirks (LFM2's `<think>` and
/// Pythonic tool-call tags, OpenAI's JSON tool_calls and reasoning fields) live in the codec, so a
/// new model is a new codec rather than an edit to the loop.
public protocol MessageCodec: Sendable {
    /// The wire request this codec encodes a conversation into (e.g. chat-template dicts for MLX, a
    /// chat-completions JSON body for OpenAI).
    associatedtype Request
    /// The raw streamed unit the decoder consumes (e.g. a generated token string, or an SSE line).
    associatedtype RawChunk

    /// Encode the canonical history into this model's request.
    func encode(
        _ history: [AgentMessage], systemPrompt: String?, tools: [any AgentTool], supportsVision: Bool
    ) -> Request

    /// A fresh per-turn decoder that reassembles the streamed wire output into one canonical turn.
    func makeDecoder() -> any TurnDecoder<RawChunk>
}

/// Reassembles a model's streamed output into one canonical ``AgentMessage``. Stateful for the
/// duration of a single turn: `ingest` is called per raw chunk and returns the pieces to stream
/// live; `finish` flushes any trailing pieces and returns the assembled assistant message (visible
/// text + reasoning + tool calls + malformed blocks).
public protocol TurnDecoder<RawChunk>: AnyObject {
    associatedtype RawChunk

    /// Consume one raw chunk; return the stream pieces it surfaces (may be empty while buffering).
    func ingest(_ chunk: RawChunk) -> [AgentStreamChunk]

    /// Flush at end of stream: any trailing pieces to stream, plus the assembled canonical message.
    func finish() -> (stream: [AgentStreamChunk], message: AgentMessage)
}
