import AppKit
import ApplicationServices

enum Apps {
    static func frontPid() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        if let app = AX.element(AX.attr(system, kAXFocusedApplicationAttribute)) {
            let pid = AX.pid(app)
            if pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func frontmost() throws -> NSRunningApplication {
        if let pid = frontPid(), let app = NSRunningApplication(processIdentifier: pid) { return app }
        throw ToolError("Could not determine the frontmost app.")
    }

    static func name(_ app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
    }

    static func frontmostName() -> String {
        (try? frontmost()).map(name) ?? "?"
    }

    static func find(_ query: String) -> NSRunningApplication? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let pid = Int32(q), let app = NSRunningApplication(processIdentifier: pid) { return app }
        let lower = q.lowercased()
        let bare = lower.hasSuffix(".app") ? String(lower.dropLast(4)) : lower
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        return apps.first { $0.bundleIdentifier?.lowercased() == lower }
            ?? apps.first { $0.localizedName?.lowercased() == bare }
            ?? apps.first { $0.bundleURL?.path.lowercased() == lower }
            ?? apps.first { $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == (bare as NSString).lastPathComponent }
    }

    static func resolve(_ query: String?) throws -> NSRunningApplication {
        guard let query, !query.isEmpty else { return try frontmost() }
        if let app = find(query) { return app }
        throw ToolError("App '\(query)' is not running. Use open_app first, or list_apps to see what is running.")
    }

    static func snapshotApp() throws -> NSRunningApplication {
        guard let snap = State.snapshot,
              let app = NSRunningApplication(processIdentifier: snap.pid), !app.isTerminated else {
            throw ToolError("No current observation. Call observe first.")
        }
        return app
    }

    static func waitForFront(_ pid: pid_t, _ tries: Int) {
        var n = 0
        while frontPid() != pid && n < tries {
            usleep(50_000)
            n += 1
        }
    }

    static func activate(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if app.isHidden { app.unhide() }
        let axApp = AX.app(pid)
        if let window = AX.mainWindow(axApp),
           (AX.attr(window, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true {
            AX.set(window, kAXMinimizedAttribute, kCFBooleanFalse)
        }
        if frontPid() == pid { return }
        AX.set(axApp, kAXFrontmostAttribute, kCFBooleanTrue)
        if let window = AX.mainWindow(axApp) { AX.perform(window, kAXRaiseAction) }
        waitForFront(pid, 20)
        if frontPid() != pid {
            app.activate(options: [.activateAllWindows])
            waitForFront(pid, 20)
        }
    }

    static func open(_ query: String) throws -> NSRunningApplication {
        try Safety.checkName(query)
        if let app = find(query) {
            activate(app)
            return app
        }
        let looksLikeBundleID = query.contains(".") && !query.contains(" ") && !query.contains("/")
            && !query.lowercased().hasSuffix(".app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = looksLikeBundleID ? ["-b", query] : ["-a", query]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError("Could not open '\(query)': \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let deadline = Date().addingTimeInterval(15)
        var app: NSRunningApplication?
        while Date() < deadline {
            app = find(query)
            if let app, AX.mainWindow(AX.app(app.processIdentifier)) != nil { break }
            usleep(200_000)
        }
        guard let app else { throw ToolError("Opened '\(query)' but could not find it running. Call list_apps.") }
        activate(app)
        return app
    }

    /// The app owning the topmost window under a screen point.
    static func owner(at p: CGPoint) -> NSRunningApplication? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard layer < 1000, alpha > 0.01,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(p),
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    static func windowCounts() -> [pid_t: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var counts: [pid_t: Int] = [:]
        for w in list where (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
            if let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value { counts[pid, default: 0] += 1 }
        }
        return counts
    }

    /// One line describing what is in front now, so callers can sanity-check an action cheaply.
    static func stateLine() -> String {
        guard let app = try? frontmost() else { return "" }
        let title = AX.mainWindow(AX.app(app.processIdentifier)).map(AX.title) ?? ""
        return "Frontmost: \(name(app))" + (title.isEmpty ? "" : " — \"\(title)\"") + "."
    }
}
