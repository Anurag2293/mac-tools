import AppKit
import ApplicationServices

struct ToolError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum Content {
    case text(String)
    case image(Data, mime: String)

    var json: [String: Any] {
        switch self {
        case .text(let t): return ["type": "text", "text": t]
        case .image(let d, let m): return ["type": "image", "data": d.base64EncodedString(), "mimeType": m]
        }
    }
}

/// What the latest observe/screenshot established. Element indices and x,y always refer to these.
enum State {
    static var snapshot: Snapshot?
    static var geometry: Geometry?
    static var axPrepared = Set<pid_t>()
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s.isEmpty ? nil : s }
        if let n = self[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = self[key] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func int(_ key: String) -> Int? { double(key).map { Int($0) } }

    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let s = self[key] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }
}

/// Resolves element indices and screenshot coordinates into screen points.
enum Target {
    static func element(_ args: [String: Any], _ key: String = "element") throws -> (Int, UIElement)? {
        guard let raw = args.string(key) else { return nil }
        guard let index = Int(raw.filter(\.isNumber)) else { throw ToolError("Bad element index '\(raw)'.") }
        guard let snap = State.snapshot else { throw ToolError("No current observation. Call observe first.") }
        guard index >= 1, index <= snap.elements.count else {
            throw ToolError("Element [\(index)] is not in the latest observe (1-\(snap.elements.count)). Call observe again.")
        }
        return (index, snap.elements[index - 1])
    }

    static func onScreen(_ p: CGPoint) -> Bool {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 1, &id, &count) == .success && count > 0
    }

    static func center(of el: UIElement, index: Int) throws -> CGPoint {
        guard var f = el.currentFrame, f.width > 0, f.height > 0 else {
            throw ToolError("Element [\(index)] has no on-screen position. Call observe again.")
        }
        if !onScreen(CGPoint(x: f.midX, y: f.midY)), AX.actions(el.ref).contains("AXScrollToVisible") {
            AX.perform(el.ref, "AXScrollToVisible")
            usleep(250_000)
            f = el.currentFrame ?? f
        }
        let c = CGPoint(x: f.midX, y: f.midY)
        guard onScreen(c) else { throw ToolError("Element [\(index)] is off-screen. Scroll it into view and observe again.") }
        return c
    }

    static func screenPoint(_ x: Double, _ y: Double) throws -> CGPoint {
        guard let g = State.geometry else { throw ToolError("No screenshot yet. Call observe or screenshot first.") }
        guard x >= 0, y >= 0, x <= Double(g.pixelSize.width), y <= Double(g.pixelSize.height) else {
            throw ToolError("(\(Int(x)),\(Int(y))) is outside the latest screenshot (\(Int(g.pixelSize.width))x\(Int(g.pixelSize.height))).")
        }
        if let pid = g.pid, Apps.frontPid() != pid, let app = NSRunningApplication(processIdentifier: pid) {
            try Safety.checkApp(app)
            Apps.activate(app)
        }
        return g.toScreen(CGPoint(x: x, y: y))
    }

    /// An element index or an x,y pair, under the given argument names.
    static func point(_ args: [String: Any], element key: String, x xKey: String, y yKey: String) throws -> CGPoint? {
        if let (index, el) = try element(args, key) {
            let app = try Apps.snapshotApp()
            try Safety.checkApp(app)
            Apps.activate(app)
            return try center(of: el, index: index)
        }
        if let x = args.double(xKey), let y = args.double(yKey) { return try screenPoint(x, y) }
        return nil
    }

    static func describe(_ p: CGPoint) -> String {
        guard let g = State.geometry else { return "" }
        let i = g.toImage(p)
        return "(\(Int(i.x.rounded())),\(Int(i.y.rounded())))"
    }
}

enum Observe {
    /// Roles where AXPress is reliable and returns immediately. Pop-up and menu buttons block
    /// inside AXPress until their menu closes, so those get a real mouse click instead.
    static let pressable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXLink", "AXDisclosureTriangle", "AXTab",
    ]

    /// Electron apps only build their accessibility tree when asked. Returns true if it was just switched on.
    static func prepare(_ pid: pid_t, _ axApp: AXUIElement) -> Bool {
        guard !State.axPrepared.contains(pid) else { return false }
        State.axPrepared.insert(pid)
        return AX.set(axApp, "AXManualAccessibility", kCFBooleanTrue) == .success
    }

    static func windowFrame(_ app: NSRunningApplication) -> (AXUIElement?, CGRect) {
        let window = AX.mainWindow(AX.app(app.processIdentifier))
        let frame = window.flatMap { AX.frame($0) } ?? CGDisplayBounds(CGMainDisplayID())
        return (window, frame)
    }

    static func run(app: NSRunningApplication, activate: Bool, maxElements: Int, maxSize: Int, image: Bool) throws -> [Content] {
        try Safety.checkApp(app)
        if activate {
            Apps.activate(app)
            usleep(150_000)
        }
        let pid = app.processIdentifier
        let axApp = AX.app(pid)
        let justEnabled = prepare(pid, axApp)
        let (window, frame) = windowFrame(app)

        var geometry: Geometry
        var jpeg: Data?
        if image {
            let (img, g) = try Capture.capture(rect: frame, maxSize: maxSize)
            geometry = g
            jpeg = Capture.jpeg(img)
        } else {
            geometry = try Capture.geometry(for: frame, maxSize: maxSize).0
        }
        geometry.pid = pid
        var snap = SnapshotBuilder.build(pid: pid, axApp: axApp, window: window, clip: geometry.rect, maxElements: maxElements)
        // The tree takes a moment to appear after it is switched on.
        if justEnabled && snap.elements.count < 10 {
            usleep(1_500_000)
            snap = SnapshotBuilder.build(pid: pid, axApp: axApp, window: window, clip: geometry.rect, maxElements: maxElements)
        }
        State.snapshot = snap
        State.geometry = geometry

        let w = Int(geometry.pixelSize.width), h = Int(geometry.pixelSize.height)
        var lines: [String] = []
        let front = Apps.frontPid() == pid
        lines.append("App: \(Apps.name(app)) (\(app.bundleIdentifier ?? "-")), pid \(pid)\(front ? ", frontmost" : ", NOT frontmost")")
        lines.append(window == nil ? "No window; showing the main display." : "Window: \"\(window.map(AX.title) ?? "")\"")
        if let jpeg {
            let url = Capture.save(jpeg, name: "observe.jpg")
            lines.append("Screenshot: \(w)x\(h) px, saved to \(url.path). All coordinates are screenshot pixels.")
        } else {
            lines.append("Coordinate space: \(w)x\(h) px (no screenshot taken).")
        }
        if snap.elements.isEmpty {
            lines.append("No accessibility elements found. This app may draw its own UI: use find_text (OCR) or coordinates from the screenshot.")
        } else {
            lines.append("Elements (use the [index] with click, type_text, set_value, scroll, drag):")
            for (i, el) in snap.elements.enumerated() { lines.append(SnapshotBuilder.line(i + 1, el, geometry)) }
            if snap.more { lines.append("… more elements not listed. Scroll, raise max_elements, or use find_text.") }
        }
        var out: [Content] = [.text(lines.joined(separator: "\n"))]
        if let jpeg { out.append(.image(jpeg, mime: "image/jpeg")) }
        return out
    }

    /// OCR over the app's window. Hits are in screen points; the geometry matches what observe would use.
    static func ocr(app: NSRunningApplication, needle: String, activate: Bool = true) throws -> ([TextHit], Geometry) {
        if activate {
            Apps.activate(app)
            usleep(150_000)
        }
        let (_, frame) = windowFrame(app)
        var standard = try Capture.geometry(for: frame, maxSize: Capture.defaultMaxSize).0
        standard.pid = app.processIdentifier
        let (img, native) = try Capture.capture(rect: frame, maxSize: nil)
        return (try OCR.find(needle, in: img, rect: native.rect), standard)
    }

    static func axContains(app: NSRunningApplication, needle: String) -> Bool {
        let pid = app.processIdentifier
        let axApp = AX.app(pid)
        let (window, frame) = windowFrame(app)
        let snap = SnapshotBuilder.build(pid: pid, axApp: axApp, window: window, clip: frame, maxElements: 2000)
        let n = needle.lowercased()
        return snap.elements.contains { $0.searchText.contains(n) }
            || (window.map(AX.title)?.lowercased().contains(n) ?? false)
    }
}
