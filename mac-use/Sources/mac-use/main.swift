import AppKit
import ApplicationServices

let usage = """
mac-use \(Standard.version) — local computer use for agents (MCP server + CLI)

Usage:
  mac-use [mcp]              Run the MCP server on stdio
  mac-use call <tool> [json] [<tool> [json] ...]
                             Run tools in one process and print their text output.
                             Chain steps here: element indices do not survive between calls.
                             mac-use call observe '{"app":"Finder"}' click '{"element":3}'
  mac-use tools              List tool names
  mac-use status             Permissions, pause state, file locations
  mac-use pause | resume     Stop or allow all agent actions
  mac-use standard           Print the rules agents follow
"""

/// Tools run off the main thread so the main run loop stays free to keep NSWorkspace's app list fresh.
func runInBackground(_ body: @escaping () -> Void) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    Thread { body() }.start()
    RunLoop.main.run()
    exit(0)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "mcp"

switch command {
case "mcp", "serve":
    runInBackground { MCPServer().run() }

case "call":
    // Element indices live in this process, so chain steps in one call: tool [json] tool [json] ...
    var steps: [(String, [String: Any])] = []
    var rest = arguments.dropFirst()
    while let name = rest.popFirst() {
        var args: [String: Any] = [:]
        if let next = rest.first, next.hasPrefix("{") {
            rest.removeFirst()
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(next.utf8))) as? [String: Any] else {
                FileHandle.standardError.write(Data("Arguments for \(name) must be a JSON object.\n".utf8))
                exit(2)
            }
            args = parsed
        }
        steps.append((name, args))
    }
    guard !steps.isEmpty else {
        print(usage)
        exit(2)
    }
    runInBackground {
        for (i, (name, args)) in steps.enumerated() {
            if steps.count > 1 { print("== \(i + 1). \(name)") }
            let (content, isError) = Tools.call(name, args)
            for c in content {
                switch c {
                case .text(let t): print(t)
                case .image(let d, _): print("[image: \(d.count) bytes]")
                }
            }
            if isError { exit(1) }
            if i < steps.count - 1 { usleep(300_000) }
        }
        exit(0)
    }

case "tools":
    for tool in Tools.all { print(tool.name) }

case "status":
    print("mac-use \(Standard.version)")
    print("Accessibility:    \(AXIsProcessTrusted() ? "granted" : "MISSING")")
    print("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "MISSING")")
    let reason = (try? String(contentsOf: Paths.paused, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    print("Paused:           \(Safety.isPaused ? "yes (\(reason ?? ""))" : "no")")
    _ = Config.load()
    print("Config:           \(Paths.config.path)")
    print("Action log:       \(Paths.actionLog.path)")
    print("Screenshots:      \(Paths.caches.path)")

case "pause":
    Safety.pause("paused by the user with `mac-use pause` at \(Safety.timestamp())")
    print("mac-use paused. Agents cannot act until `mac-use resume`.")

case "resume":
    Safety.resume()
    print("mac-use resumed.")

case "standard":
    print(Standard.instructions)

case "-h", "--help", "help":
    print(usage)

default:
    print(usage)
    exit(2)
}
