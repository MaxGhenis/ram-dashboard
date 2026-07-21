import Foundation
import RambarKit
import RambarSystem

/// Minimal MCP stdio server: newline-delimited JSON-RPC 2.0. Gives agents —
/// including the sessions being measured — read access to the fleet's memory
/// ledger. Register with: claude mcp add rambar -- rambar mcp
func runMCPServer() {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else { continue }

        let id = message["id"]
        if method.hasPrefix("notifications/") { continue }

        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            let version = params?["protocolVersion"] as? String ?? "2024-11-05"
            reply(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "rambar", "version": "2.0.0"],
            ])
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": toolDefinitions])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            reply(id: id, result: callTool(name: name, arguments: arguments))
        default:
            replyError(id: id, code: -32601, message: "method not found: \(method)")
        }
    }
}

private let toolDefinitions: [[String: Any]] = [
    [
        "name": "memory_status",
        "description": "System memory: total, used, compressed, kernel pressure level.",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "list_sessions",
        "description": "Active agent sessions (Claude Code, Codex, Gemini) with per-session memory footprint, process count, hosting mode, and project.",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "session_history",
        "description": "Footprint history for one session key over the last N minutes.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "session key from list_sessions"],
                "minutes": ["type": "number", "description": "window, default 60"],
            ],
            "required": ["key"],
        ],
    ],
]

private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
    let text: String
    switch name {
    case "memory_status":
        if let (system, source) = currentSystem() {
            struct Output: Codable {
                let source: String
                let system: SystemJSON
            }
            text = encodeJSON(Output(source: source.rawValue, system: SystemJSON(system)))
        } else {
            text = #"{"error": "system memory unavailable"}"#
        }
    case "list_sessions":
        let (sessions, source) = currentSessions()
        struct Output: Codable {
            let source: String
            let sessions: [SessionJSON]
        }
        text = encodeJSON(Output(source: source.rawValue, sessions: sessions.map(SessionJSON.init)))
    case "session_history":
        guard let key = arguments["key"] as? String, let store = openStore() else {
            return toolError("session_history requires a key and a populated store")
        }
        let minutes = arguments["minutes"] as? Double ?? 60
        let since = Date().timeIntervalSince1970 - minutes * 60
        struct Point: Codable {
            let ts: Double
            let footprintBytes: UInt64
        }
        let points = store.sessionHistory(key: key, since: since)
            .map { Point(ts: $0.time, footprintBytes: $0.bytes) }
        text = encodeJSON(points)
    default:
        return toolError("unknown tool: \(name)")
    }
    return ["content": [["type": "text", "text": text]]]
}

private func toolError(_ message: String) -> [String: Any] {
    ["content": [["type": "text", "text": message]], "isError": true]
}

private func reply(id: Any?, result: [String: Any]) {
    var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
    response["id"] = id ?? NSNull()
    emit(response)
}

private func replyError(id: Any?, code: Int, message: String) {
    var response: [String: Any] = [
        "jsonrpc": "2.0",
        "error": ["code": code, "message": message],
    ]
    response["id"] = id ?? NSNull()
    emit(response)
}

private func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
