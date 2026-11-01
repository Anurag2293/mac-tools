import AppKit
import ApplicationServices

struct Tool {
    let name: String
    let description: String
    var properties: [String: Any] = [:]
    var required: [String] = []
    /// Reports readOnlyHint to clients. Pure reads are also left out of the action log.
    var readOnly = false
    let run: ([String: Any]) throws -> [Content]

    var definition: [String: Any] {
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": required]
        let annotations: [String: Any] = ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]
        return ["name": name, "description": description, "inputSchema": schema, "annotations": annotations]
    }
}

private func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
private func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
private func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
private func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
private func oneOf(_ d: String, _ values: [String]) -> [String: Any] { ["type": "string", "enum": values, "description": d] }

private let appArg = str("App name, bundle id, or pid. Defaults to the frontmost app.")
private let elementArg = int("Element [index] from the latest observe.")
private let xArg = num("X in pixels of the latest screenshot.")
private let yArg = num("Y in pixels of the latest screenshot.")

enum Tools {
    static func find(_ name: String) -> Tool? { all.first { $0.name == name } }

    static func call(_ name: String, _ args: [String: Any]) -> (content: [Content], isError: Bool) {
        guard let tool = find(name) else { return ([.text("Unknown tool '\(name)'.")], true) }
        do {
            if name != "run_script" && name != "list_apps" && !AXIsProcessTrusted() {
                throw ToolError("Accessibility permission is missing for the app running this agent. Grant it in System Settings > Privacy & Security > Accessibility, then restart the agent.")
            }
            if name != "list_apps" { try Safety.checkNotPaused() }
            let out = try tool.run(args)
            if !tool.readOnly { Safety.log(name, args, "ok: " + firstText(out)) }
            return (out, false)
        } catch {
            if !tool.readOnly { Safety.log(name, args, "error: \(error)") }
            return ([.text("\(error)")], true)
        }
    }

    static func firstText(_ content: [Content]) -> String {
        for c in content { if case .text(let t) = c { return t } }
        return ""
    }

    static let all: [Tool] = [
        listApps, openApp, observe, screenshot, click, typeText, setValue, pressKey,
        scroll, drag, hover, findText, waitFor, menu, runScript,
    ]

    static let listApps = Tool(
        name: "list_apps",
        description: "List running apps (name, bundle id, pid, visible window count). * marks the frontmost app.",
        readOnly: true
    ) { _ in
        let counts = Apps.windowCounts()
        let front = Apps.frontPid()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .sorted { Apps.name($0).lowercased() < Apps.name($1).lowercased() }
        let lines = apps.map { a in
            "\(a.processIdentifier == front ? "*" : " ") \(Apps.name(a)) (\(a.bundleIdentifier ?? "-")) pid \(a.processIdentifier), \(counts[a.processIdentifier] ?? 0) window(s)"
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    static let openApp = Tool(
        name: "open_app",
        description: "Launch an app, or bring it to the front if it is already running. Call observe afterwards.",
        properties: ["app": str("App name (e.g. 'Safari'), bundle id, or path to a .app.")],
        required: ["app"]
    ) { args in
        guard let query = args.string("app") else { throw ToolError("'app' is required.") }
        let app = try Apps.open(query)
        try Safety.checkApp(app)
        return [.text("\(Apps.name(app)) is running and was brought to the front. \(Apps.stateLine()) Call observe next.")]
    }

    static let observe = Tool(
        name: "observe",
        description: "Bring an app to the front and return a screenshot of its window plus a numbered list of its UI elements (role, label, value, center in screenshot pixels). Call this before acting and again after acting to verify. Element [index] values and x,y coordinates are only valid until the next observe/screenshot/find_text.",
        properties: [
            "app": appArg,
            "screenshot": bool("Include the screenshot image. Default true; set false for a cheaper element-only refresh."),
            "max_elements": int("Maximum elements to list. Default 250."),
            "max_size": int("Longest screenshot side in pixels. Default 1280."),
            "activate": bool("Bring the app to the front first. Default true."),
        ],
        readOnly: true
    ) { args in
        let app = try Apps.resolve(args.string("app"))
        return try Observe.run(
            app: app,
            activate: args.bool("activate") ?? true,
            maxElements: max(10, args.int("max_elements") ?? 250),
            maxSize: max(400, args.int("max_size") ?? Capture.defaultMaxSize),
            image: args.bool("screenshot") ?? true
        )
    }

    static let screenshot = Tool(
        name: "screenshot",
        description: "Screenshot a whole display (default: the main display). Use observe for a single app; use this to see the desktop, menu bar, or several windows. Subsequent x,y coordinates refer to this image.",
        properties: [
            "display": int("Display number: 0 is the main display. Default 0."),
            "max_size": int("Longest side in pixels. Default 1280."),
        ],
        readOnly: true
    ) { args in
        let front = try Apps.frontmost()
        try Safety.checkApp(front)
        let ids = Capture.displays()
        let index = args.int("display") ?? 0
        guard index >= 0, index < ids.count else { throw ToolError("Display \(index) does not exist; there are \(ids.count).") }
        let bounds = CGDisplayBounds(ids[index])
        let (img, g) = try Capture.capture(rect: bounds, maxSize: max(400, args.int("max_size") ?? Capture.defaultMaxSize))
        State.geometry = g
        let jpeg = Capture.jpeg(img)
        let url = Capture.save(jpeg, name: "screenshot.jpg")
        let text = "Display \(index) of \(ids.count): \(Int(g.pixelSize.width))x\(Int(g.pixelSize.height)) px, saved to \(url.path). Frontmost: \(Apps.name(front)). x,y for click/scroll/drag now refer to this image."
        return [.text(text), .image(jpeg, mime: "image/jpeg")]
    }

    static let click = Tool(
        name: "click",
        description: "Click an element by [index] (preferred), on-screen text found by OCR, or x,y screenshot pixels. Buttons, checkboxes, links, and menu items use an accessibility press by default, which works without moving the mouse.",
        properties: [
            "element": elementArg,
            "text": str("Visible text to click, located by OCR in the app's window."),
            "occurrence": int("Which OCR match to click when text appears more than once. Default 1."),
            "x": xArg,
            "y": yArg,
            "app": str("App for text clicks. Defaults to the frontmost app."),
            "button": oneOf("Mouse button. Default left.", ["left", "right", "middle"]),
            "count": int("Number of clicks, e.g. 2 for a double-click. Default 1."),
            "method": oneOf("auto (default), press (accessibility only), or mouse (real click).", ["auto", "press", "mouse"]),
        ]
    ) { args in
        let button = args.string("button") ?? "left"
        let count = max(1, min(args.int("count") ?? 1, 3))
        let method = args.string("method") ?? "auto"

        if let (index, el) = try Target.element(args) {
            let app = try Apps.snapshotApp()
            try Safety.checkApp(app)
            let canPress = Observe.pressable.contains(el.rawRole) && AX.actions(el.ref).contains(kAXPressAction)
            if method != "mouse" && button == "left" && count == 1 && canPress {
                if AX.perform(el.ref, kAXPressAction) == .success {
                    usleep(200_000)
                    return [.text("Pressed [\(index)] \(el.summary) (accessibility press). \(Apps.stateLine())")]
                }
                if method == "press" { throw ToolError("Accessibility press failed on [\(index)]. Try method mouse.") }
            } else if method == "press" {
                throw ToolError("[\(index)] does not support an accessibility press. Use method mouse.")
            }
            Apps.activate(app)
            let p = try Target.center(of: el, index: index)
            try Safety.checkPoint(p)
            Input.click(p, button: button, count: count)
            usleep(200_000)
            return [.text("Clicked [\(index)] \(el.summary) with the mouse at \(Target.describe(p)). \(Apps.stateLine())")]
        }

        if let text = args.string("text") {
            let app = try Apps.resolve(args.string("app"))
            try Safety.checkApp(app)
            let (hits, g) = try Observe.ocr(app: app, needle: text)
            State.geometry = g
            let n = max(1, args.int("occurrence") ?? 1)
            guard hits.count >= n else {
                throw ToolError(hits.isEmpty ? "Text \"\(text)\" was not found on screen." : "Only \(hits.count) match(es) for \"\(text)\".")
            }
            let hit = hits[n - 1]
            let p = CGPoint(x: hit.rect.midX, y: hit.rect.midY)
            try Safety.checkPoint(p)
            Input.click(p, button: button, count: count)
            usleep(200_000)
            return [.text("Clicked \"\(text)\" (match \(n) of \(hits.count), in \"\(hit.line)\") at \(Target.describe(p)). \(Apps.stateLine())")]
        }

        if let x = args.double("x"), let y = args.double("y") {
            let p = try Target.screenPoint(x, y)
            try Safety.checkPoint(p)
            Input.click(p, button: button, count: count)
            usleep(200_000)
            return [.text("Clicked at (\(Int(x)),\(Int(y))). \(Apps.stateLine())")]
        }
        throw ToolError("Give element, text, or x and y.")
    }

    static let typeText = Tool(
        name: "type_text",
        description: "Type text with the keyboard into the focused field, or into element [index] after focusing it. Newlines press Return. Do not use this for passwords or 2FA codes.",
        properties: [
            "text": str("Text to type."),
            "element": elementArg,
            "app": str("Bring this app to the front before typing."),
            "clear": bool("Select all and delete the field's contents first. Default false."),
            "submit": bool("Press Return after typing. Default false."),
        ],
        required: ["text"]
    ) { args in
        guard let text = args["text"] as? String else { throw ToolError("'text' is required.") }
        if let (index, el) = try Target.element(args) {
            let app = try Apps.snapshotApp()
            try Safety.checkApp(app)
            Apps.activate(app)
            AX.set(el.ref, kAXFocusedAttribute, kCFBooleanTrue)
            if (AX.attr(el.ref, kAXFocusedAttribute) as? NSNumber)?.boolValue != true {
                Input.click(try Target.center(of: el, index: index))
            }
            usleep(120_000)
        } else if let query = args.string("app") {
            let app = try Apps.resolve(query)
            try Safety.checkApp(app)
            Apps.activate(app)
            usleep(120_000)
        }
        let front = try Apps.frontmost()
        try Safety.checkApp(front)
        if args.bool("clear") == true {
            try Input.press("cmd+a")
            try Input.press("backspace")
        }
        guard Input.type(text, shouldStop: Safety.failsafeTripped) else {
            throw ToolError("Typing stopped partway: mac-use was paused (failsafe). Tell the user.")
        }
        let submit = args.bool("submit") == true
        if submit { try Input.press("return") }
        usleep(150_000)
        return [.text("Typed \(text.count) characters into \(Apps.name(front))\(submit ? " and pressed Return" : ""). \(Apps.stateLine())")]
    }

    static let setValue = Tool(
        name: "set_value",
        description: "Set an element's value directly through accessibility (text fields, sliders, steppers). Faster than typing and does not need focus; not every app honors it, so verify with observe.",
        properties: ["element": elementArg, "value": str("New value.")],
        required: ["element", "value"]
    ) { args in
        guard let (index, el) = try Target.element(args) else { throw ToolError("'element' is required.") }
        guard let value = args["value"] as? String ?? args.string("value") else { throw ToolError("'value' is required.") }
        let app = try Apps.snapshotApp()
        try Safety.checkApp(app)
        guard AX.settable(el.ref, kAXValueAttribute) else {
            throw ToolError("[\(index)] does not accept a direct value. Click it and use type_text.")
        }
        let numeric = ["AXSlider", "AXIncrementor", "AXStepper", "AXCheckBox"].contains(el.rawRole)
        let newValue: AnyObject = numeric ? (Double(value).map { NSNumber(value: $0) } ?? value as NSString) : value as NSString
        let err = AX.set(el.ref, kAXValueAttribute, newValue)
        guard err == .success else { throw ToolError("Setting the value of [\(index)] failed (AXError \(err.rawValue)).") }
        return [.text("Set [\(index)] \(el.summary) to \"\(SnapshotBuilder.clean(value, 80))\".")]
    }

    static let pressKey = Tool(
        name: "press_key",
        description: "Press a key or shortcut in the frontmost app, e.g. 'return', 'escape', 'cmd+s', 'cmd+shift+t'. Separate several chords with spaces to press them in order, e.g. 'cmd+a backspace'.",
        properties: [
            "keys": str("Chord(s): modifiers cmd/shift/alt/ctrl/fn joined with + to a key name or character."),
            "app": str("Bring this app to the front first."),
            "repeat": int("Press the whole sequence this many times. Default 1, max 100."),
        ],
        required: ["keys"]
    ) { args in
        guard let keys = args.string("keys") else { throw ToolError("'keys' is required.") }
        let chords = try keys.split(whereSeparator: \.isWhitespace).map { try Input.parse(String($0)) }
        if let query = args.string("app") {
            let app = try Apps.resolve(query)
            try Safety.checkApp(app)
            Apps.activate(app)
            usleep(120_000)
        }
        let front = try Apps.frontmost()
        try Safety.checkApp(front)
        let times = max(1, min(args.int("repeat") ?? 1, 100))
        for _ in 0..<times {
            for chord in chords { Input.press(chord) }
            usleep(30_000)
        }
        usleep(150_000)
        return [.text("Pressed \(keys)\(times > 1 ? " x\(times)" : "") in \(Apps.name(front)). \(Apps.stateLine())")]
    }

    static let scroll = Tool(
        name: "scroll",
        description: "Scroll with the mouse wheel over element [index], over x,y, or over the middle of the app's window.",
        properties: [
            "direction": oneOf("Direction. Default down.", ["up", "down", "left", "right"]),
            "pages": num("How far, in pages of the scrolled area. Fractions allowed. Default 1."),
            "element": elementArg,
            "x": xArg,
            "y": yArg,
            "app": appArg,
        ]
    ) { args in
        let direction = (args.string("direction") ?? "down").lowercased()
        let pages = args.double("pages") ?? 1
        let p: CGPoint
        let area: CGSize
        if let (index, el) = try Target.element(args) {
            let app = try Apps.snapshotApp()
            try Safety.checkApp(app)
            Apps.activate(app)
            p = try Target.center(of: el, index: index)
            area = el.currentFrame?.size ?? CGSize(width: 600, height: 600)
        } else if let x = args.double("x"), let y = args.double("y") {
            p = try Target.screenPoint(x, y)
            area = State.geometry?.rect.size ?? CGSize(width: 600, height: 600)
        } else {
            let app = try Apps.resolve(args.string("app"))
            try Safety.checkApp(app)
            Apps.activate(app)
            let (_, frame) = Observe.windowFrame(app)
            p = CGPoint(x: frame.midX, y: frame.midY)
            area = frame.size
        }
        try Safety.checkPoint(p)
        let dy = Double(min(area.height, 1200)) * 0.8 * pages
        let dx = Double(min(area.width, 1600)) * 0.8 * pages
        switch direction {
        case "up": Input.scroll(at: p, dx: 0, dy: dy)
        case "left": Input.scroll(at: p, dx: dx, dy: 0)
        case "right": Input.scroll(at: p, dx: -dx, dy: 0)
        default: Input.scroll(at: p, dx: 0, dy: -dy)
        }
        usleep(250_000)
        return [.text("Scrolled \(direction) \(pages) page(s) at \(Target.describe(p)). Call observe to see the result.")]
    }

    static let drag = Tool(
        name: "drag",
        description: "Drag with the left mouse button from one element or point to another.",
        properties: [
            "from_element": elementArg, "from_x": xArg, "from_y": yArg,
            "to_element": elementArg, "to_x": xArg, "to_y": yArg,
        ]
    ) { args in
        guard let from = try Target.point(args, element: "from_element", x: "from_x", y: "from_y"),
              let to = try Target.point(args, element: "to_element", x: "to_x", y: "to_y") else {
            throw ToolError("Give from_element or from_x/from_y, and to_element or to_x/to_y.")
        }
        try Safety.checkPoint(from)
        try Safety.checkPoint(to)
        Input.drag(from: from, to: to)
        usleep(200_000)
        return [.text("Dragged from \(Target.describe(from)) to \(Target.describe(to)). \(Apps.stateLine())")]
    }

    static let hover = Tool(
        name: "hover",
        description: "Move the mouse over element [index] or x,y without clicking, e.g. to reveal a tooltip or hover menu.",
        properties: ["element": elementArg, "x": xArg, "y": yArg]
    ) { args in
        guard let p = try Target.point(args, element: "element", x: "x", y: "y") else {
            throw ToolError("Give element or x and y.")
        }
        Input.move(p)
        usleep(300_000)
        return [.text("Mouse is over \(Target.describe(p)).")]
    }

    static let findText = Tool(
        name: "find_text",
        description: "Find visible text in an app's window by OCR and return where it is in screenshot pixels. Leave text empty to read all visible text. Use it when observe lists few elements (canvas apps, games, remote desktops, some Electron apps).",
        properties: [
            "text": str("Text to look for (case-insensitive substring). Empty returns all text."),
            "app": appArg,
        ],
        readOnly: true
    ) { args in
        let app = try Apps.resolve(args.string("app"))
        try Safety.checkApp(app)
        let needle = args.string("text") ?? ""
        let (hits, g) = try Observe.ocr(app: app, needle: needle)
        State.geometry = g
        if hits.isEmpty {
            return [.text(needle.isEmpty ? "No text recognized in \(Apps.name(app))." : "\"\(needle)\" was not found in \(Apps.name(app)).")]
        }
        var lines = ["\(hits.count) match(es) in \(Apps.name(app)); coordinates are pixels of a \(Int(g.pixelSize.width))x\(Int(g.pixelSize.height)) window screenshot (same space as observe):"]
        for (i, hit) in hits.prefix(300).enumerated() {
            let c = g.toImage(CGPoint(x: hit.rect.midX, y: hit.rect.midY))
            lines.append("[t\(i + 1)] \"\(SnapshotBuilder.clean(hit.line, 120))\" (\(Int(c.x.rounded())),\(Int(c.y.rounded())))")
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    static let waitFor = Tool(
        name: "wait_for",
        description: "Wait until text appears in (or disappears from) an app's window, checking accessibility labels and then OCR. Use after actions that load or animate instead of sleeping.",
        properties: [
            "text": str("Text to wait for (case-insensitive substring)."),
            "app": appArg,
            "gone": bool("Wait for the text to disappear instead. Default false."),
            "timeout": num("Seconds to wait, max 60. Default 10."),
            "ocr": bool("Also check with OCR. Default true."),
        ],
        required: ["text"],
        readOnly: true
    ) { args in
        guard let text = args.string("text") else { throw ToolError("'text' is required.") }
        let app = try Apps.resolve(args.string("app"))
        try Safety.checkApp(app)
        Apps.activate(app)
        let gone = args.bool("gone") ?? false
        let useOCR = args.bool("ocr") ?? true
        let timeout = min(max(args.double("timeout") ?? 10, 0.5), 60)
        let start = Date()
        while true {
            var present = Observe.axContains(app: app, needle: text)
            if !present && useOCR {
                present = ((try? Observe.ocr(app: app, needle: text, activate: false))?.0.isEmpty == false)
            }
            let elapsed = Date().timeIntervalSince(start)
            if present != gone {
                return [.text("\"\(text)\" \(gone ? "is gone" : "appeared") after \(String(format: "%.1f", elapsed))s. Call observe before acting.")]
            }
            if elapsed >= timeout {
                throw ToolError("Timed out after \(Int(timeout))s waiting for \"\(text)\" to \(gone ? "disappear" : "appear").")
            }
            usleep(500_000)
        }
    }

    static let menu = Tool(
        name: "menu",
        description: "Use an app's menu bar. With a path to a menu item, e.g. 'File > Export…', it selects that item. With a path to a menu, or no path, it lists the items there with their keyboard shortcuts.",
        properties: [
            "path": str("Menu path separated by '>', e.g. 'View > Show Sidebar'. Empty lists the top-level menus."),
            "app": appArg,
        ]
    ) { args in
        let app = try Apps.resolve(args.string("app"))
        try Safety.checkApp(app)
        let axApp = AX.app(app.processIdentifier)
        guard let bar = AX.element(AX.attr(axApp, kAXMenuBarAttribute)) else {
            throw ToolError("\(Apps.name(app)) has no accessible menu bar.")
        }
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        func submenu(_ el: AXUIElement) -> [AXUIElement] {
            guard let menu = AX.children(el).first(where: { AX.role($0) == "AXMenu" }) else { return [] }
            return AX.children(menu)
        }
        let path = (args.string("path") ?? "").split(separator: ">")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var items = AX.children(bar)
        var current: AXUIElement?
        var walked: [String] = []
        for part in path {
            let p = norm(part)
            guard let match = items.first(where: { norm(AX.title($0)) == p }) ?? items.first(where: { norm(AX.title($0)).hasPrefix(p) }) else {
                let names = items.map(AX.title).filter { !$0.isEmpty }.joined(separator: ", ")
                throw ToolError("No '\(part)' in \(walked.isEmpty ? "the menu bar" : walked.joined(separator: " > ")). Available: \(names)")
            }
            current = match
            walked.append(AX.title(match))
            items = submenu(match)
        }
        if let current, items.isEmpty {
            if (AX.attr(current, kAXEnabledAttribute) as? NSNumber)?.boolValue == false {
                throw ToolError("\(walked.joined(separator: " > ")) is disabled right now.")
            }
            Apps.activate(app)
            let err = AX.perform(current, kAXPressAction)
            guard err == .success else { throw ToolError("Selecting \(walked.joined(separator: " > ")) failed (AXError \(err.rawValue)).") }
            usleep(250_000)
            return [.text("Selected \(walked.joined(separator: " > ")). \(Apps.stateLine())")]
        }
        var lines = ["\(walked.isEmpty ? "Menu bar" : walked.joined(separator: " > ")) in \(Apps.name(app)):"]
        for item in items {
            let title = AX.title(item)
            if title.isEmpty { continue }
            var line = "- \(title)"
            if !submenu(item).isEmpty { line += " >" }
            if let shortcut = shortcut(item) { line += "  [\(shortcut)]" }
            if (AX.attr(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == false { line += "  (disabled)" }
            lines.append(line)
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    static func shortcut(_ item: AXUIElement) -> String? {
        guard let char = AX.string(AX.attr(item, "AXMenuItemCmdChar")), !char.isEmpty else { return nil }
        let mods = (AX.attr(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0
        var parts: [String] = []
        if mods & 4 != 0 { parts.append("ctrl") }
        if mods & 2 != 0 { parts.append("alt") }
        if mods & 1 != 0 { parts.append("shift") }
        if mods & 8 == 0 { parts.append("cmd") }
        parts.append(char.lowercased())
        return parts.joined(separator: "+")
    }

    static let runScript = Tool(
        name: "run_script",
        description: "Run AppleScript or JavaScript for Automation with osascript and return its output. Often the most reliable way to drive scriptable apps (Finder, Mail, Safari, Music, Notes, System Events).",
        properties: [
            "script": str("Script source."),
            "language": oneOf("Default applescript.", ["applescript", "javascript"]),
            "timeout": num("Seconds before the script is killed, max 120. Default 30."),
        ],
        required: ["script"]
    ) { args in
        guard let script = args["script"] as? String, !script.isEmpty else { throw ToolError("'script' is required.") }
        try Safety.checkName(script)
        Paths.ensure()
        let id = UUID().uuidString
        let file = Paths.caches.appendingPathComponent("script-\(id)")
        let outFile = Paths.caches.appendingPathComponent("script-\(id).out")
        let errFile = Paths.caches.appendingPathComponent("script-\(id).err")
        defer { for f in [file, outFile, errFile] { try? FileManager.default.removeItem(at: f) } }
        try script.write(to: file, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let js = (args.string("language") ?? "applescript").lowercased().hasPrefix("j")
        process.arguments = (js ? ["-l", "JavaScript"] : []) + [file.path]
        process.standardOutput = try FileHandle(forWritingTo: outFile)
        process.standardError = try FileHandle(forWritingTo: errFile)
        try process.run()
        let timeout = min(max(args.double("timeout") ?? 30, 1), 120)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            throw ToolError("Script timed out after \(Int(timeout))s. If this is the first script to control that app, macOS may be showing an Automation permission prompt; ask the user to answer it, then retry.")
        }
        let out = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
        if process.terminationStatus != 0 {
            throw ToolError("Script failed (exit \(process.terminationStatus)): \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return [.text(text.isEmpty ? "(no output)" : String(text.prefix(20_000)))]
    }
}
