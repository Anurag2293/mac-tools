import AppKit
import ApplicationServices

/// Thin wrappers over the C accessibility API.
enum AX {
    static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        return app
    }

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ value: AnyObject?) -> [AXUIElement] {
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { element($0) }
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        elements(attr(el, kAXChildrenAttribute))
    }

    static func string(_ value: AnyObject?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let s = value as? NSAttributedString { return s.string }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func role(_ el: AXUIElement) -> String {
        string(attr(el, kAXRoleAttribute)) ?? ""
    }

    static func title(_ el: AXUIElement) -> String {
        string(attr(el, kAXTitleAttribute)) ?? ""
    }

    static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &s) ? s : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(attr(el, kAXPositionAttribute)), let s = size(attr(el, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: AnyObject) -> AXError {
        AXUIElementSetAttributeValue(el, name as CFString, value)
    }

    static func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var result: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &result) == .success && result.boolValue
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return pid
    }

    static func mainWindow(_ app: AXUIElement) -> AXUIElement? {
        if let w = element(attr(app, kAXFocusedWindowAttribute)) { return w }
        if let w = element(attr(app, kAXMainWindowAttribute)) { return w }
        return elements(attr(app, kAXWindowsAttribute)).first
    }
}
