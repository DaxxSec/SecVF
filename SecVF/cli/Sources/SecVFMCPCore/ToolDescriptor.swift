//
//  ToolDescriptor.swift
//  SecVFMCPCore
//
//  Each MCP tool is described by a ToolDescriptor — name, capability tier,
//  category, direction (input/output for trust boundary), and a brief
//  description for the agent. The tool catalog is the union of all
//  descriptors registered with the server.
//

import Foundation

/// Category groups the tool catalog into operational families.
public enum ToolCategory: String, Sendable {
    case discovery     // List/status/logs — read-only
    case lifecycle     // start/stop/pause — safe-mutate
    case capture       // Packet capture control — safe-mutate
    case forensics     // logs, packets, summaries — read-only outputs
    case destructive   // create/clone/delete — full tier only
    case workflow      // Composite multi-step (detonate, replay) — safe-mutate
}

/// Direction of data flow relative to the host trust boundary.
///
/// - `.input`  — host → VM (or host-controlled state). Tool parameters are
///                trusted (came from agent's reasoning, not from VM output).
/// - `.output` — VM → host. Returned data is untrusted-by-construction;
///                MUST be wrapped with `trust_boundary: "vm_output"` and
///                treated as data, never as instructions.
public enum ToolDirection: String, Sendable {
    case input
    case output
}

/// Minimum capability tier required to expose this tool.
extension ToolCategory {
    var minimumTier: CapabilityTier {
        switch self {
        case .discovery, .forensics:
            return .readOnly
        case .lifecycle, .capture, .workflow:
            return .safeMutate
        case .destructive:
            return .full
        }
    }
}

// MARK: - Typed input schema
//
// Each tool advertises its parameters in JSON Schema form so MCP clients
// can give the agent a typed tool catalog. The previous `additionalProperties:
// true` shape forced the agent to guess; this lets it call correctly the
// first time.

public struct InputSchemaProperty: Sendable {
    public let type: String        // "string" | "integer" | "boolean" | "object" | "array"
    public let description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

public struct InputSchema: Sendable {
    public let type: String = "object"
    public let properties: [String: InputSchemaProperty]
    public let required: [String]

    public init(
        properties: [String: InputSchemaProperty] = [:],
        required: [String] = []
    ) {
        self.properties = properties
        self.required = required
    }

    /// Empty schema — for tools that take no parameters.
    public static let empty = InputSchema(properties: [:], required: [])

    /// Serialize to the JSON object that MCP `tools/list` expects.
    public func toJSON() -> [String: Any] {
        var props: [String: Any] = [:]
        for (key, prop) in properties {
            props[key] = [
                "type": prop.type,
                "description": prop.description,
            ]
        }
        return [
            "type": type,
            "properties": props,
            "required": required,
            "additionalProperties": false,
        ]
    }
}

/// Describes a single MCP tool. The dispatch closure is intentionally
/// async-throws — every tool can be slow or fail; the server takes care of
/// turning errors into MCP error responses.
public struct ToolDescriptor: Sendable {
    public let name: String
    public let category: ToolCategory
    public let direction: ToolDirection
    public let description: String
    public let inputSchema: InputSchema?

    public init(
        name: String,
        category: ToolCategory,
        direction: ToolDirection,
        description: String,
        inputSchema: InputSchema? = nil
    ) {
        self.name = name
        self.category = category
        self.direction = direction
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Whether this tool is exposed at the given capability tier.
    public func isExposed(at tier: CapabilityTier) -> Bool {
        return category.minimumTier.rank <= tier.rank
    }
}
