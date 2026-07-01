import DeepAgents
import Foundation

/// HTTP client for a local `llama-server` (llama.cpp, OpenAI-compatible) running
/// the LiquidAI LFM2.5 instruct GGUF — the same infrastructure as the Qwen ASR
/// server, just a text-only chat completion (no audio). Used for the optional
/// "translate the finished transcript to English" pass.
///
/// Same request shape as `LlamaServerClient` minus the `input_audio` block; the
/// server applies the model's chat template, so we just send role/content text.
struct TranslationClient: Sendable {
    let baseURL: URL

    /// Keep the model on-task: translate, output nothing but the translation. Shares the
    /// on-device agent's prompt (``TranslationPrompt``); this server path is English-only.
    private let systemPrompt = TranslationPrompt.system(targetLanguage: "English")

    var port: Int { baseURL.port ?? 80 }

    /// Quick preflight: is an OpenAI-style server answering on /v1/models with a
    /// non-empty model list? Mirrors `LlamaServerClient.isReachable()`.
    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            guard let models = try? JSONDecoder().decode(ModelsResponse.self, from: data) else { return false }
            return !models.data.isEmpty
        } catch {
            return false
        }
    }

    /// Translate `text` to English and return just the translation.
    func translate(_ text: String) async throws -> String {
        // Output is roughly the length of the input; cap it so a stray run-on
        // can't stall, but give short utterances headroom.
        let maxTokens = min(2048, max(256, text.count))
        // No `model` field: llama-server serves whatever GGUF it was launched
        // with (matching how `LlamaServerClient` talks to the Qwen server).
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.1,
            "top_p": 0.1,
            "repeat_penalty": 1.05, // llama.cpp's name for repetition_penalty
            "max_tokens": maxTokens
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.serverUnreachable }
        guard (200 ..< 300).contains(http.statusCode) else { throw AppError.serverHTTP(http.statusCode) }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return Self.clean(decoded.choices.first?.message.content ?? "")
    }

    /// Trim whitespace and drop a stray trailing chat-end token, just in case the
    /// server leaks one into the content.
    static func clean(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "<|im_end|>") {
            text = String(text[..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    let choices: [Choice]
}

private struct ModelsResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}
