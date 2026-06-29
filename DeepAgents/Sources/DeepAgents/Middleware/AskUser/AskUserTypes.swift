import Foundation

/// One predefined option for a `multiple_choice` ask_user question - deepagents' `Choice`.
public struct AskUserChoice: Sendable, Equatable {
    /// The display label for this choice.
    public let value: String

    public init(value: String) { self.value = value }
}

/// The kind of answer an ask_user question expects - deepagents' question `type`, plus Mispher's
/// `multi_select` extension.
public enum AskUserQuestionType: String, Sendable {
    /// A free-form text answer.
    case text
    /// A single pick from `choices`; an "Other" free-text escape is always offered alongside them.
    case multipleChoice = "multiple_choice"
    /// One *or more* picks from `choices` (the answer is the chosen values joined by ", "); an "Other"
    /// free-text value can be added too.
    case multiSelect = "multi_select"

    /// Whether this kind presents `choices` (both pick-from-options kinds do; `text` does not).
    var hasChoices: Bool { self != .text }
}

/// One question the agent poses through the `ask_user` tool - deepagents' `Question`.
public struct AskUserQuestion: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// The question text to display.
    public let question: String
    public let type: AskUserQuestionType
    /// The predefined options for a `multiple_choice` question; empty for `text`.
    public let choices: [AskUserChoice]
    /// Whether the user must answer (vs. may skip). Required by default.
    public let required: Bool

    public init(
        id: UUID = UUID(), question: String, type: AskUserQuestionType,
        choices: [AskUserChoice] = [], required: Bool = true
    ) {
        self.id = id
        self.question = question
        self.type = type
        self.choices = choices
        self.required = required
    }
}

/// The payload surfaced to the host when the agent calls `ask_user` - deepagents' `AskUserRequest`.
/// The host presents the questions, collects answers, and resumes the suspended tool call with an
/// ``AskUserResponse``. There is no separate tool-call id (deepagents threads one through LangGraph's
/// `interrupt`); Mispher's in-process loop links the tool's return value to the call automatically,
/// so `id` exists only to key the host's UI state.
public struct AskUserRequest: Sendable, Identifiable {
    public let id: UUID
    public let questions: [AskUserQuestion]

    public init(id: UUID = UUID(), questions: [AskUserQuestion]) {
        self.id = id
        self.questions = questions
    }
}

/// The host's reply to an ``AskUserRequest`` - deepagents' resume payload (`answered` / `cancelled`,
/// plus an `error` escape for an interaction the host couldn't complete).
public enum AskUserResponse: Sendable {
    /// The user answered; one string per question, in order.
    case answered([String])
    /// The user dismissed the prompt without answering.
    case cancelled
    /// The interaction failed (e.g. the host couldn't present it); `detail` explains why.
    case error(String)
}

/// Presents the agent's questions to the user and returns their answers. The host typically
/// publishes the request, suspends on a continuation, and resumes it when the user submits - the
/// agent run waits inside this call. Mirrors ``ToolApprovalHandler`` (the in-process stand-in for
/// deepagents' LangGraph `interrupt`).
public typealias AskUserHandler = @Sendable (AskUserRequest) async -> AskUserResponse

/// `ask_user` parsing, validation, and answer-formatting - ports of deepagents' question handling
/// (`_validate_questions` / `_parse_answers`).
enum AskUser {
    /// The error a malformed `ask_user` call produces; surfaced to the model as a failed tool result
    /// so it can correct and retry - deepagents raises `ValueError` here.
    struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Validate the questions before surfacing them - deepagents' `_validate_questions`.
    static func validate(_ questions: [AskUserQuestion]) throws {
        guard !questions.isEmpty else {
            throw ValidationError(message: "ask_user requires at least one question")
        }
        for q in questions {
            guard !q.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError(message: "ask_user questions must have non-empty 'question' text")
            }
            if q.type.hasChoices, q.choices.isEmpty {
                throw ValidationError(
                    message: "\(q.type.rawValue) question \"\(q.question)\" requires a non-empty 'choices' list"
                )
            }
            if q.type == .text, !q.choices.isEmpty {
                throw ValidationError(
                    message: "text question \"\(q.question)\" must not define 'choices'"
                )
            }
        }
    }

    /// Parse the model's `questions` argument into typed questions, tolerating the shapes models
    /// actually emit: an object per question (with a few key spellings), `choices` as objects
    /// (`{value}`) or bare strings, and a missing `type` inferred from whether choices are present.
    static func parseQuestions(_ value: AgentJSON?) -> [AskUserQuestion] {
        switch value {
        case .array(let items): return items.compactMap(parseQuestion)
        case .object: return [value!].compactMap(parseQuestion)
        default: return []
        }
    }

    private static func parseQuestion(_ value: AgentJSON) -> AskUserQuestion? {
        guard case .object(let object) = value else { return nil }
        let questionKeys = ["question", "text", "prompt", "title"]
        guard let question = questionKeys.lazy.compactMap({ key -> String? in
            if case .string(let value)? = object[key] { return value } else { return nil }
        }).first else { return nil }

        let choices = parseChoices(object["choices"])
        let rawType: String? = { if case .string(let value)? = object["type"] { return value } else { return nil } }()
        // Honor an explicit type; otherwise infer from whether the model supplied choices.
        let type = rawType.flatMap(AskUserQuestionType.init(rawValue:)) ?? (choices.isEmpty ? .text : .multipleChoice)

        var required = true
        if case .bool(let value)? = object["required"] { required = value }

        return AskUserQuestion(question: question, type: type, choices: choices, required: required)
    }

    private static func parseChoices(_ value: AgentJSON?) -> [AskUserChoice] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item -> AskUserChoice? in
            let label: String?
            switch item {
            case .string(let value): label = value
            case .object(let object):
                label = ["value", "label", "text", "name"].lazy.compactMap { key -> String? in
                    if case .string(let value)? = object[key] { return value } else { return nil }
                }.first
            default: label = nil
            }
            guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return AskUserChoice(value: trimmed)
        }
    }

    /// Format the user's response into the `Q: …\nA: …` result the model reads next turn -
    /// deepagents' `_parse_answers`. `cancelled` / `error` synthesize explicit per-question answers,
    /// and a short `answered` list is padded with `(no answer)`, so the model never sees a silent gap.
    static func format(questions: [AskUserQuestion], response: AskUserResponse) -> String {
        let answers: [String]
        switch response {
        case .answered(let provided):
            answers = provided
        case .cancelled:
            answers = questions.map { _ in "(cancelled)" }
        case .error(let detail):
            let text = detail.isEmpty ? "ask_user interaction failed" : detail
            answers = questions.map { _ in "(error: \(text))" }
        }
        return questions.enumerated().map { index, question in
            "Q: \(question.question)\nA: \(index < answers.count ? answers[index] : "(no answer)")"
        }.joined(separator: "\n\n")
    }
}
