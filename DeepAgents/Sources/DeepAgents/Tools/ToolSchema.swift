import Foundation

/// A tool's JSON Schema, carried as a loosely-typed dictionary — the exact shape a chat
/// template renders into the `function.parameters` block (`{"type": "function", "function":
/// {"name", "description", "parameters"}}`).
///
/// Framework-owned: the agent core no longer depends on `MLXLMCommon.ToolSpec`. Because that
/// type is itself `[String: any Sendable]`, the `DeepAgentsMLX` adapter passes a `ToolSchema`
/// straight to the model with no conversion.
public typealias ToolSchema = [String: any Sendable]
