import AppKit
import CoreGraphics

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/mac-use")
    static let logs = home.appendingPathComponent("Library/Logs/mac-use")
    static let caches = home.appendingPathComponent("Library/Caches/mac-use")
    static let config = support.appendingPathComponent("config.json")
    static let paused = support.appendingPathComponent("PAUSED")
    static let actionLog = logs.appendingPathComponent("actions.jsonl")

    static func ensure() {
        for dir in [support, logs, caches] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

struct Config {
    var denyApps: [String]
    var allowApps: [String]

    static let defaultDeny = [
        "com.apple.keychainaccess", "Keychain Access",
        "com.apple.Passwords", "Passwords",
        "com.1password.1password", "com.agilebits.onepassword7", "1Password",
        "com.bitwarden.desktop", "Bitwarden",
    ]

    static func load() -> Config {
        Paths.ensure()
        if !FileManager.default.fileExists(atPath: Paths.config.path) {
            let seed: [String: Any] = [
                "deny_apps": defaultDeny,
                "allow_apps": [String](),
                "_help": "deny_apps: app names or bundle ids mac-use must never touch. allow_apps: when non-empty, mac-use touches only these.",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Paths.config)
            }
        }
        guard let data = try? Data(contentsOf: Paths.config),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Config(denyApps: defaultDeny, allowApps: [])
        }
        return Config(denyApps: obj["deny_apps"] as? [String] ?? defaultDeny,
                      allowApps: obj["allow_apps"] as? [String] ?? [])
    }
}

enum Safety {
    static func matches(_ app: NSRunningApplication, _ list: [String]) -> Bool {
        let ids = [app.bundleIdentifier, app.localizedName].compactMap { $0?.lowercased() }
        return list.contains { ids.contains($0.lowercased()) }
    }

    static func checkApp(_ app: NSRunningApplication?) throws {
        guard let app else { return }
        let config = Config.load()
        let name = Apps.name(app)
        if matches(app, config.denyApps) {
            throw ToolError("mac-use is not allowed to touch \(name) (deny_apps in \(Paths.config.path)). Ask the user to do this step.")
        }
        if !config.allowApps.isEmpty && !matches(app, config.allowApps) {
            throw ToolError("\(name) is not in allow_apps (\(Paths.config.path)). Ask the user to do this step or to allow the app.")
        }
    }

    /// Conservative text check for app names in open_app queries and scripts.
    static func checkName(_ text: String) throws {
        let lower = text.lowercased()
        if let hit = Config.load().denyApps.first(where: { lower.contains($0.lowercased()) }) {
            throw ToolError("This mentions '\(hit)', which is in deny_apps (\(Paths.config.path)). Ask the user to do this step.")
        }
    }

    static func checkPoint(_ p: CGPoint) throws {
        try checkApp(Apps.owner(at: p))
    }

    static var isPaused: Bool { FileManager.default.fileExists(atPath: Paths.paused.path) }

    static func pause(_ reason: String) {
        Paths.ensure()
        try? reason.write(to: Paths.paused, atomically: true, encoding: .utf8)
    }

    static func resume() {
        try? FileManager.default.removeItem(at: Paths.paused)
    }

    /// Moving the mouse into the top-left corner of the main display pauses mac-use.
    static func failsafeTripped() -> Bool {
        if let loc = CGEvent(source: nil)?.location, loc.x <= 2, loc.y <= 2 {
            if !isPaused { pause("failsafe: mouse moved to the top-left corner at \(timestamp())") }
            return true
        }
        return isPaused
    }

    static func checkNotPaused() throws {
        guard failsafeTripped() else { return }
        let reason = ((try? String(contentsOf: Paths.paused, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ToolError("mac-use is paused (\(reason)). Stop and tell the user; they can resume with `mac-use resume`.")
    }

    static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func log(_ tool: String, _ args: [String: Any], _ result: String) {
        Paths.ensure()
        var safeArgs = args
        for key in ["text", "value", "script"] {
            if let s = safeArgs[key] as? String, s.count > 120 { safeArgs[key] = String(s.prefix(120)) + "…" }
        }
        let entry: [String: Any] = [
            "ts": timestamp(), "tool": tool, "args": safeArgs,
            "front": Apps.frontmostName(), "result": String(result.prefix(300)),
        ]
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let line = data + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: Paths.actionLog) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: Paths.actionLog)
        }
    }
}
