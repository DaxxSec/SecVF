//
//  JSONRPC.swift
//  SecVFMCPCore
//
//  JSON-RPC 2.0 framing for MCP. Parses incoming requests, serializes
//  responses. No I/O — pure protocol semantics.
//
//  MCP methods we handle:
//    - `initialize`        — handshake at connection start
//    - `tools/list`        — return the exposed tool catalog
//    - `tools/call`        — invoke a specific tool with arguments
//
//  Standard JSON-RPC 2.0 error codes are surfaced via JSONRPCErrorCode.
//

import Foundation

// MARK: - Request

/// An MCP request ID is either an integer or a string per the JSON-RPC spec.
public enum JSONRPCID: Equatable, Sendable {
    case number(Int)
    case string(String)

    /// Convert back to a JSON-compatible value for response serialization.
    var jsonValue: Any {
        switch self {
        case .number(let n): return n
        case .string(let s): return s
        }
    }
}

/// Decoded MCP request payload, discriminated by method.
public enum JSONRPCPayload: Sendable {
    case initialize
    case toolsList
    case toolsCall(name: String, arguments: [String: Any])
    /// Catch-all for methods we recognize as JSON-RPC but don't implement.
    case other(method: String, params: [String: Any]?)
}

public struct JSONRPCRequest: Sendable {
    public let id: JSONRPCID
    public let method: String
    public let payload: JSONRPCPayload

    /// Parse a JSON-RPC 2.0 request from a string. Validates protocol
    /// version + required fields.
    public static func parse(_ raw: String) throws -> JSONRPCRequest {
        guard let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw JSONRPCParseError.malformedJSON
        }

        guard let jsonrpc = json["jsonrpc"] as? String else {
            throw JSONRPCParseError.missingField("jsonrpc")
        }
        guard jsonrpc == "2.0" else {
            throw JSONRPCParseError.unsupportedVersion(jsonrpc)
        }

        let id: JSONRPCID
        if let n = json["id"] as? Int {
            id = .number(n)
        } else if let s = json["id"] as? String {
            id = .string(s)
        } else {
            throw JSONRPCParseError.missingField("id")
        }

        guard let method = json["method"] as? String else {
            throw JSONRPCParseError.missingField("method")
        }

        let params = json["params"] as? [String: Any]
        let payload = decodePayload(method: method, params: params)

        return JSONRPCRequest(id: id, method: method, payload: payload)
    }

    private static func decodePayload(method: String, params: [String: Any]?) -> JSONRPCPayload {
        switch method {
        case "initialize":
            return .initialize
        case "tools/list":
            return .toolsList
        case "tools/call":
            let name = (params?["name"] as? String) ?? ""
            let args = (params?["arguments"] as? [String: Any]) ?? [:]
            return .toolsCall(name: name, arguments: args)
        default:
            return .other(method: method, params: params)
        }
    }
}

// MARK: - Response

public struct JSONRPCResponse: Sendable {
    public let id: JSONRPCID
    public let result: [String: Any]?
    public let error: JSONRPCError?

    /// Create a success response.
    public static func success(id: JSONRPCID, result: [String: Any]) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    /// Create an error response.
    public static func failure(
        id: JSONRPCID,
        code: Int,
        message: String,
        data: [String: Any]? = nil
    ) -> JSONRPCResponse {
        JSONRPCResponse(
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message, data: data)
        )
    }

    /// Serialize to a single JSON object string suitable for stdio line write.
    public func serialize() throws -> String {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
        ]
        if let result = result {
            obj["result"] = result
        }
        if let err = error {
            var errObj: [String: Any] = [
                "code": err.code,
                "message": err.message,
            ]
            if let data = err.data {
                errObj["data"] = data
            }
            obj["error"] = errObj
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw JSONRPCParseError.encodingFailed
        }
        return s
    }
}

public struct JSONRPCError: Sendable {
    // [String: Any] isn't Sendable in strict mode but the JSON-RPC envelope
    // is single-use across an actor boundary in practice. Marked unchecked
    // for now; revisit when Swift 6 strict-concurrency is the default.
    public let code: Int
    public let message: String
    // swiftlint:disable:next strict_concurrency
    private let _data: [String: Any]?
    public var data: [String: Any]? { _data }

    public init(code: Int, message: String, data: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self._data = data
    }
}

// MARK: - Standard error codes (JSON-RPC 2.0 spec)

public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}

// MARK: - Errors

public enum JSONRPCParseError: Error, Equatable {
    case malformedJSON
    case unsupportedVersion(String)
    case missingField(String)
    case encodingFailed
}
