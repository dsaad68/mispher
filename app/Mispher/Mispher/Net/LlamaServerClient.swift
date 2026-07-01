import Foundation

/// HTTP client for the local Qwen3-ASR `llama-server` (OpenAI-compatible).
/// Sends audio as a base64 `input_audio` block — the exact shape verified to
/// work in qwen-asr-findings.md.
struct LlamaServerClient: Sendable {
    let baseURL: URL

    /// Instruction tuned for the Chinese engine.
    private let instruction =
        "Transcribe the audio into Chinese text. Only output the transcription text, with no extra words or newlines."

    var port: Int { baseURL.port ?? 80 }

    /// Quick preflight: is a real OpenAI-style ASR server answering on /v1/models?
    /// Requires HTTP 200 *and* a non-empty model list so an unrelated service
    /// squatting on the port (e.g. Docker) isn't mistaken for the Qwen server.
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

    /// Resample mono samples to a 16 kHz WAV and transcribe.
    func transcribe(samples: [Float], sourceRate: Double) async throws -> String {
        guard let wav = WavEncoder.wav16kMonoData(fromMono: samples, sourceRate: sourceRate) else {
            throw AppError.audioEncodingFailed
        }
        return try await transcribe(wav: wav)
    }

    /// POST a WAV blob and return the transcription text.
    func transcribe(wav: Data) async throws -> String {
        let base64 = wav.base64EncodedString()
        let body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": instruction],
                    ["type": "input_audio", "input_audio": ["data": base64, "format": "wav"]]
                ]
            ]],
            "temperature": 0
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.serverUnreachable }
        guard (200 ..< 300).contains(http.statusCode) else { throw AppError.serverHTTP(http.statusCode) }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return Self.extractTranscript(decoded.choices.first?.message.content ?? "")
    }

    /// Qwen3-ASR wraps output as `language <LANG><asr_text><transcript>`.
    /// Pull out just the transcript and drop any structural tags.
    static func extractTranscript(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "<asr_text>") {
            text = String(text[range.upperBound...])
        }
        for tag in ["</asr_text>", "<eou>", "</s>", "<|im_end|>"] {
            if let range = text.range(of: tag) {
                text = String(text[..<range.lowerBound])
            }
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
