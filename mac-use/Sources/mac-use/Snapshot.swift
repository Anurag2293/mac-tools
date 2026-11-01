import AppKit
import ApplicationServices

struct UIElement {
    let ref: AXUIElement
    let rawRole: String
    let role: String
    let label: String
    let value: String?
    let frame: CGRect?
    let enabled: Bool
    let focused: Bool
    /// Untruncated label and value, lowercased, for wait_for.
    let searchText: String

    /// Re-reads the frame so clicks land where the element is now, not where it was at observe time.
    var currentFrame: CGRect? { AX.frame(ref) ?? frame }

    var summary: String { label.isEmpty ? role : "\(role) \"\(label)\"" }
}

final class Snapshot {
    let pid: pid_t
    let elements: [UIElement]
    let more: Bool

    init(pid: pid_t, elements: [UIElement], more: Bool) {
        self.pid = pid
        self.elements = elements
        self.more = more
    }
}

/// Walks an app's accessibility tree and keeps the elements an agent can act on or read.
enum SnapshotBuilder {
    static let fetchNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
        kAXFocusedAttribute, kAXChildrenAttribute, "AXPlaceholderValue", kAXHelpAttribute,
    ]

    static let interactive: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXComboBox",
        "AXPopUpButton", "AXMenuButton", "AXLink", "AXSlider", "AXIncrementor", "AXStepper",
        "AXDisclosureTriangle", "AXMenuItem", "AXColorWell", "AXDateField", "AXTimeField",
        "AXSearchField", "AXTab",
    ]

    static let textual: Set<String> = ["AXStaticText", "AXHeading", "AXImage"]

    static let namedSubroles: Set<String> = [
        "AXSearchField", "AXSecureTextField", "AXSwitch", "AXToggle", "AXTabButton",
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    ]

    static func fetch(_ el: AXUIElement) -> [AnyObject?] {
        var out: CFArray?
        let names = fetchNames as CFArray
        guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let values = out as? [AnyObject], values.count == fetchNames.count else {
            return Array(repeating: nil, count: fetchNames.count)
        }
        return values.map { v in
            if v is NSNull { return nil }
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    static func build(pid: pid_t, axApp: AXUIElement, window: AXUIElement?, clip: CGRect, maxElements: Int) -> Snapshot {
        var roots: [(AXUIElement, CGRect)] = []
        if let window { roots.append((window, clip)) }
        // Open context menus hang off the application element, not the window.
        for child in AX.children(axApp) where AX.role(child) == "AXMenu" {
            roots.append((child, AX.frame(child) ?? clip))
        }

        typealias Item = (el: AXUIElement, parentLabel: String, clip: CGRect)
        var stack: [Item] = roots.reversed().map { ($0.0, "", $0.1) }
        var out: [UIElement] = []
        var visited = 0
        var more = false
        let deadline = Date().addingTimeInterval(5)

        while let item = stack.popLast() {
            if out.count >= maxElements || visited >= 8000 || Date() > deadline {
                more = true
                break
            }
            visited += 1
            let v = fetch(item.el)
            let rawRole = AX.string(v[0]) ?? ""
            let subrole = AX.string(v[1])
            var frame: CGRect?
            if let p = AX.point(v[5]), let s = AX.size(v[6]) { frame = CGRect(origin: p, size: s) }
            // Skip subtrees scrolled out of view; this is what keeps long web pages fast.
            if let f = frame, f.width > 0, f.height > 0, !f.intersects(item.clip) { continue }

            let rawValue = AX.string(v[4])
            var label = nonEmpty(AX.string(v[2])) ?? nonEmpty(AX.string(v[3])) ?? ""
            if label.isEmpty, rawRole == "AXStaticText" || rawRole == "AXHeading" { label = nonEmpty(rawValue) ?? "" }
            if label.isEmpty { label = nonEmpty(AX.string(v[10])) ?? nonEmpty(AX.string(v[11])) ?? "" }
            label = clean(label, 100)

            let isInteractive = interactive.contains(rawRole) || subrole == "AXSearchField"
            let isText = textual.contains(rawRole) && !label.isEmpty && label != item.parentLabel
            let visible = frame.map { $0.width > 1 && $0.height > 1 } ?? false
            var include = (isInteractive || isText) && visible
            if rawRole == "AXMenuItem" && label.isEmpty { include = false }

            if include {
                out.append(UIElement(
                    ref: item.el,
                    rawRole: rawRole,
                    role: displayRole(rawRole, subrole),
                    label: label,
                    value: displayValue(rawRole, subrole, rawValue),
                    frame: frame,
                    enabled: (v[7] as? NSNumber)?.boolValue ?? true,
                    focused: (v[8] as? NSNumber)?.boolValue ?? false,
                    searchText: (label + " " + String((rawValue ?? "").prefix(20_000))).lowercased()
                ))
            }
            let nextLabel = include ? label : item.parentLabel
            for kid in AX.elements(v[9]).reversed() {
                stack.append((kid, nextLabel, item.clip))
            }
        }
        return Snapshot(pid: pid, elements: out, more: more)
    }

    static func line(_ index: Int, _ e: UIElement, _ g: Geometry) -> String {
        var s = "[\(index)] \(e.role)"
        if !e.label.isEmpty { s += " \"\(e.label)\"" }
        if let v = e.value {
            s += (e.rawRole == "AXCheckBox" || e.rawRole == "AXRadioButton") ? " \(v)" : " value=\"\(v)\""
        }
        if let f = e.frame {
            let c = g.toImage(CGPoint(x: f.midX, y: f.midY))
            s += " (\(Int(c.x.rounded())),\(Int(c.y.rounded())))"
        }
        if e.focused { s += " focused" }
        if !e.enabled { s += " disabled" }
        return s
    }

    static func displayRole(_ raw: String, _ sub: String?) -> String {
        let name = (sub.map { namedSubroles.contains($0) } ?? false) ? sub! : raw
        return (name.hasPrefix("AX") ? String(name.dropFirst(2)) : name).lowercased()
    }

    static func displayValue(_ role: String, _ sub: String?, _ v: String?) -> String? {
        guard let v else { return nil }
        if sub == "AXSecureTextField" { return v.isEmpty ? nil : "•••" }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            return v.isEmpty ? nil : clean(v, 120)
        case "AXCheckBox", "AXRadioButton":
            return v == "1" ? "on" : (v == "0" ? "off" : clean(v, 30))
        case "AXSlider", "AXIncrementor", "AXPopUpButton", "AXDateField", "AXTimeField":
            return v.isEmpty ? nil : clean(v, 60)
        default:
            return nil
        }
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func clean(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .newlines).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
