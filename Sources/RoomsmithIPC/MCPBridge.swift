import Foundation
import RoomsmithCore

public enum RoomsmithMCP {
    public static let version = "0.1.0"
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// Rules sent to every agent in the MCP `initialize` result (see docs/AGENT_GUIDE.md §5).
    public static let instructions = """
        Roomsmith rules for agents:
        - When the user gives photos of real furniture, windows, doors or fixed parts (kitchen, bath, floor, walls), \
        rebuild them exactly as in the photos: shape, legs, handles, frames, materials, colours and proportions, \
        not a generic stand-in.
        - Take sizes only from the user, the project or source plan, or a reliable product sheet. Never guess a \
        size; if one is missing, say so and ask.
        - Build windows and balcony or terrace doors openable, with real frames and handles as in the photos.
        - Ignore furniture in photos that the user says is not theirs.
        - Lengths are millimetres. List or get before you change, and prefer dryRun for big edits.
        """
}

/// MCP (JSON-RPC 2.0, one message per line) front end for the agent tool API.
public actor MCPBridge {
    private let transport: any AgentTransport
    private let serverVersion: String

    public init(transport: any AgentTransport, serverVersion: String = RoomsmithMCP.version) {
        self.transport = transport
        self.serverVersion = serverVersion
    }

    /// Handles one incoming line; returns the response line, or nil for notifications.
    public func handle(line: String) async -> String? {
        guard let message = try? JSONValue.parse(Data(line.utf8)) else {
            return Self.failure(id: .null, code: -32700, message: "Parse error")
        }
        guard case .object = message else {
            return Self.failure(id: .null, code: -32600, message: "Invalid Request")
        }
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            // A response from the client, or garbage.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.failure(id: id ?? .null, code: -32600, message: "Invalid Request")
        }
        let params = message["params"] ?? .object([:])

        switch method {
        case "initialize":
            guard let id else { return nil }
            return Self.success(id: id, result: initializeResult(params))
        case "ping":
            guard let id else { return nil }
            return Self.success(id: id, result: .object([:]))
        case "tools/list":
            guard let id else { return nil }
            return await listTools(id: id)
        case "tools/call":
            guard let id else { return nil }
            return await callTool(id: id, params: params)
        default:
            guard let id else { return nil }
            return Self.failure(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap { RoomsmithMCP.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? RoomsmithMCP.supportedProtocolVersions[0]
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "roomsmith", "version": .string(serverVersion)],
            "instructions": .string(RoomsmithMCP.instructions),
        ]
    }

    private func listTools(id: JSONValue) async -> String {
        do {
            let raw = try await transport.call(agentListToolsName, .object([:]))
            let descriptors = try raw.decode([ToolDescriptor].self)
            let tools: [JSONValue] = descriptors.map { tool in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "annotations": ["readOnlyHint": .bool(tool.readOnly)],
                ]
            }
            return Self.success(id: id, result: ["tools": .array(tools)])
        } catch let error as AgentError {
            return Self.failure(id: id, code: -32603, message: error.description, data: ["code": .string(error.code)])
        } catch {
            return Self.failure(id: id, code: -32603, message: "Cannot read tool list: \(error)")
        }
    }

    private func callTool(id: JSONValue, params: JSONValue) async -> String {
        guard let name = params["name"]?.stringValue, !name.isEmpty else {
            return Self.failure(id: id, code: -32602, message: "tools/call requires params.name")
        }
        let arguments = params["arguments"] ?? .object([:])
        do {
            var result = try await transport.call(name, arguments)
            // Render tools return `image: {mimeType, base64}`; MCP clients get it as an image block instead of JSON text.
            var image: JSONValue?
            if case .object(var o) = result, let img = o["image"], let mime = img["mimeType"]?.stringValue,
               let data = img["base64"]?.stringValue {
                image = ["type": "image", "data": .string(data), "mimeType": .string(mime)]
                o["image"] = nil
                result = .object(o)
            }
            var content: [JSONValue] = [["type": "text", "text": .string(result.jsonString(pretty: true))]]
            if let image { content.append(image) }
            var payload: [String: JSONValue] = ["content": .array(content), "isError": false]
            if case .object = result { payload["structuredContent"] = result }
            return Self.success(id: id, result: .object(payload))
        } catch let error as AgentError {
            var text = "\(error.code): \(error.message)"
            if let details = error.details { text += "\n" + details.jsonString(pretty: true) }
            return Self.success(id: id, result: [
                "content": [["type": "text", "text": .string(text)]],
                "isError": true,
            ])
        } catch {
            return Self.success(id: id, result: [
                "content": [["type": "text", "text": .string("\(AgentError.internal): \(error)")]],
                "isError": true,
            ])
        }
    }

    private static func success(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonString()
    }

    private static func failure(id: JSONValue, code: Int64, message: String, data: JSONValue? = nil) -> String {
        var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        return JSONValue.object(["jsonrpc": "2.0", "id": id, "error": .object(error)]).jsonString()
    }
}
