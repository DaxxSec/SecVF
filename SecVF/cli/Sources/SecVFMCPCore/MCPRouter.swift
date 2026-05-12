//
//  MCPRouter.swift
//  SecVFMCPCore
//
//  Translates raw JSON-RPC request strings into MCP method handling.
//  Sits between the stdio loop (bytes in / bytes out) and the Dispatcher
//  (typed tool call → typed response).
//
//  Methods handled:
//    - `initialize`     — handshake; reply with server info + protocol version
//    - `tools/list`     — return the current tier's exposed tool catalog
//    - `tools/call`     — dispatch to the right handler
//
//  Unknown methods → JSON-RPC methodNotFound (-32601).
//  Malformed JSON   → JSON-RPC parseError (-32700).
//

import Foundation

/// Server name + version exposed via `initialize`.
public enum MCPServerInfo {
    public static let name = "secvf-mcp"
    public static let version = "0.1.0"
    /// MCP protocol version we implement (kept current with the spec).
    public static let protocolVersion = "2024-11-05"
}

public final class MCPRouter: @unchecked Sendable {
    private let tier: CapabilityTier
    private let registry: ToolRegistry
    private let dispatcher: Dispatcher

    public init(
        tier: CapabilityTier,
        handlers: [String: ToolHandler],
        auditLogger: MCPAuditLogger,
        clientPid: Int,
        matcher: CommandPatternMatcher? = nil,
        hook: ConfirmationHook? = nil
    ) {
        self.tier = tier
        self.registry = ToolRegistry(tier: tier)
        self.dispatcher = Dispatcher(
            tier: tier,
            handlers: handlers,
            auditLogger: auditLogger,
            clientPid: clientPid,
            registry: registry,
            matcher: matcher,
            hook: hook
        )
    }

    /// Entry point from the stdio loop. Takes one raw JSON-RPC request
    /// string and returns the serialized response string to write back.
    public func handle(rawRequest: String) async -> String {
        // Parse + handle parse errors.
        let request: JSONRPCRequest
        do {
            request = try JSONRPCRequest.parse(rawRequest)
        } catch {
            let response = JSONRPCResponse.failure(
                id: .number(0),  // we don't know the id if parse failed
                code: JSONRPCErrorCode.parseError,
                message: "Parse error: \(error)"
            )
            return (try? response.serialize()) ?? ""
        }

        // Route by method.
        let response: JSONRPCResponse
        switch request.payload {
        case .initialize:
            response = handleInitialize(id: request.id)

        case .toolsList:
            response = handleToolsList(id: request.id)

        case .toolsCall(let name, let arguments):
            response = await handleToolsCall(
                id: request.id,
                toolName: name,
                arguments: arguments
            )

        case .other(let method, _):
            response = JSONRPCResponse.failure(
                id: request.id,
                code: JSONRPCErrorCode.methodNotFound,
                message: "Method not found: \(method)"
            )
        }

        return (try? response.serialize()) ?? ""
    }

    // MARK: - Method handlers

    private func handleInitialize(id: JSONRPCID) -> JSONRPCResponse {
        let result: [String: Any] = [
            "protocolVersion": MCPServerInfo.protocolVersion,
            "capabilities": [
                "tools": [
                    "listChanged": false,
                ],
            ],
            "serverInfo": [
                "name": MCPServerInfo.name,
                "version": MCPServerInfo.version,
            ],
        ]
        return JSONRPCResponse.success(id: id, result: result)
    }

    private func handleToolsList(id: JSONRPCID) -> JSONRPCResponse {
        let tools: [[String: Any]] = registry.descriptors.map { desc in
            // Each descriptor carries a typed InputSchema so the agent
            // sees real parameter types + required-fields constraints
            // when it discovers the tool catalog. Descriptors without
            // a schema fall back to "no params" (.empty equivalent).
            let schemaJSON = (desc.inputSchema ?? .empty).toJSON()
            return [
                "name": desc.name,
                "description": desc.description,
                "inputSchema": schemaJSON,
            ]
        }
        return JSONRPCResponse.success(id: id, result: ["tools": tools])
    }

    private func handleToolsCall(
        id: JSONRPCID,
        toolName: String,
        arguments: [String: Any]
    ) async -> JSONRPCResponse {
        let result = await dispatcher.dispatch(tool: toolName, params: arguments)

        switch result {
        case .success(let payload):
            // MCP convention: structured returns go in `structuredContent`,
            // human-readable summary in `content`. Agents that understand
            // structured content get the typed object; clients without can
            // still see a text rendering.
            let summary: String
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ),
               let s = String(data: data, encoding: .utf8) {
                summary = s
            } else {
                summary = "(result is not JSON-serializable)"
            }
            return JSONRPCResponse.success(id: id, result: [
                "structuredContent": payload,
                "content": [[
                    "type": "text",
                    "text": summary,
                ]],
            ])

        case .error(let code, let message):
            return JSONRPCResponse.failure(
                id: id,
                code: JSONRPCErrorCode.internalError,
                message: message,
                data: ["code": code]
            )
        }
    }
}
