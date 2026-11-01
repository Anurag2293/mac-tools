import Foundation

/// Minimal MCP server over stdio: newline-delimited JSON-RPC 2.0, tools only.
final class MCPServer {
    func run() {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let msg = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(msg)
        }
        exit(0)
    }

    func handle(_ msg: [String: Any]) {
        // Notifications have no id and need no reply; responses to us have no method.
        guard let id = msg["id"], let method = msg["method"] as? String else { return }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "mac-use", "version": Standard.version],
                "instructions": Standard.instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": Tools.all.map(\.definition)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (content, isError) = Tools.call(name, args)
            reply(id, ["content": content.map(\.json), "isError": isError])
        case "resources/list":
            reply(id, ["resources": [Any]()])
        case "prompts/list":
            reply(id, ["prompts": [Any]()])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
