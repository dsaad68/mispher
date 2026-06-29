import Foundation

/// The type of a ``ToolParameter``, used to derive its JSON Schema fragment. Framework-owned
/// mirror of the schema vocabulary a chat template expects (an inference-agnostic replacement
/// for `MLXLMCommon.ToolParameterType`).
public indirect enum ToolParameterType: Sendable {
    case string
    case bool
    case int
    case double
    case array(elementType: ToolParameterType)
    case object(properties: [ToolParameter])
    case data

    var schemaType: [String: any Sendable] {
        switch self {
        case .string: return ["type": "string"]
        case .bool: return ["type": "boolean"]
        case .int: return ["type": "integer"]
        case .double: return ["type": "number"]
        case .data: return ["type": "string", "contentEncoding": "base64"]
        case .array(let elementType):
            return ["type": "array", "items": elementType.schemaType]
        case .object(let properties):
            var props = [String: any Sendable]()
            var required = [String]()
            for param in properties {
                props[param.name] = param.schema
                if param.isRequired { required.append(param.name) }
            }
            return ["type": "object", "properties": props, "required": required]
        }
    }
}

/// One parameter in a tool's interface: a name, a typed schema, a description, and whether
/// it's required. Tools declare `[ToolParameter]` and the default ``AgentTool/toolSchema()``
/// assembles them into the `function.parameters` object.
public struct ToolParameter: Sendable {
    public let name: String
    public let type: ToolParameterType
    public let description: String
    public let isRequired: Bool
    public let extraProperties: [String: any Sendable]

    /// The JSON Schema fragment for this parameter (its type schema plus `description` and any
    /// extra constraints).
    public var schema: [String: any Sendable] {
        var schema = type.schemaType
        schema["description"] = description
        for (key, value) in extraProperties { schema[key] = value }
        return schema
    }

    public static func required(
        _ name: String,
        type: ToolParameterType,
        description: String,
        extraProperties: [String: any Sendable] = [:]
    ) -> ToolParameter {
        ToolParameter(
            name: name, type: type, description: description,
            isRequired: true, extraProperties: extraProperties
        )
    }

    public static func optional(
        _ name: String,
        type: ToolParameterType,
        description: String,
        extraProperties: [String: any Sendable] = [:]
    ) -> ToolParameter {
        ToolParameter(
            name: name, type: type, description: description,
            isRequired: false, extraProperties: extraProperties
        )
    }
}
