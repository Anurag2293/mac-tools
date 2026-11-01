import AppKit
import CoreGraphics

/// Synthesized mouse and keyboard events, posted at the HID level like real input.
enum Input {
    static let source = CGEventSource(stateID: .hidSystemState)

    static func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clickState: Int = 1) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e?.post(tap: .cghidEventTap)
    }

    static func move(_ p: CGPoint) {
        mouse(.mouseMoved, p)
        usleep(40_000)
    }

    static func click(_ p: CGPoint, button: String = "left", count: Int = 1) {
        let down: CGEventType, up: CGEventType, btn: CGMouseButton
        switch button {
        case "right": (down, up, btn) = (.rightMouseDown, .rightMouseUp, .right)
        case "middle": (down, up, btn) = (.otherMouseDown, .otherMouseUp, .center)
        default: (down, up, btn) = (.leftMouseDown, .leftMouseUp, .left)
        }
        move(p)
        for i in 1...max(1, count) {
            mouse(down, p, btn, clickState: i)
            usleep(25_000)
            mouse(up, p, btn, clickState: i)
            usleep(40_000)
        }
    }

    static func drag(from a: CGPoint, to b: CGPoint) {
        move(a)
        mouse(.leftMouseDown, a)
        usleep(100_000)
        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            usleep(15_000)
        }
        usleep(100_000)
        mouse(.leftMouseUp, b)
    }

    /// Positive dy scrolls toward the top of the content, positive dx toward the left.
    static func scroll(at p: CGPoint, dx: Double, dy: Double) {
        move(p)
        let steps = 10
        for _ in 0..<steps {
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(dy / Double(steps)), wheel2: Int32(dx / Double(steps)), wheel3: 0)
            e?.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }

    // MARK: Keyboard

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static let modifiers: [String: (CGKeyCode, CGEventFlags)] = [
        "cmd": (55, .maskCommand), "command": (55, .maskCommand),
        "shift": (56, .maskShift),
        "alt": (58, .maskAlternate), "option": (58, .maskAlternate), "opt": (58, .maskAlternate),
        "ctrl": (59, .maskControl), "control": (59, .maskControl),
        "fn": (63, .maskSecondaryFn),
    ]

    struct Chord {
        let mods: [(CGKeyCode, CGEventFlags)]
        let key: CGKeyCode
    }

    static func parse(_ chord: String) throws -> Chord {
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last else { throw ToolError("Empty key chord.") }
        var mods: [(CGKeyCode, CGEventFlags)] = []
        for m in parts.dropLast() {
            guard let info = modifiers[m] else { throw ToolError("Unknown modifier '\(m)'. Use cmd, shift, alt, ctrl, fn.") }
            mods.append(info)
        }
        guard let code = keyCodes[keyName] ?? modifiers[keyName]?.0 else {
            throw ToolError("Unknown key '\(keyName)'. Use return, escape, tab, space, backspace, forwarddelete, up/down/left/right, home, end, pageup, pagedown, f1-f12, or a single character.")
        }
        return Chord(mods: mods, key: code)
    }

    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(12_000)
    }

    static func press(_ chord: Chord) {
        var flags: CGEventFlags = []
        for (code, flag) in chord.mods {
            flags.insert(flag)
            key(code, down: true, flags: flags)
        }
        key(chord.key, down: true, flags: flags)
        key(chord.key, down: false, flags: flags)
        for (code, flag) in chord.mods.reversed() {
            flags.remove(flag)
            key(code, down: false, flags: flags)
        }
    }

    static func press(_ chord: String) throws {
        press(try parse(chord))
    }

    /// Types text as Unicode key events. Returns false if `shouldStop` interrupted it.
    static func type(_ text: String, shouldStop: () -> Bool) -> Bool {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for (i, ch) in normalized.enumerated() {
            if i % 25 == 0 && shouldStop() { return false }
            switch ch {
            case "\n":
                key(36, down: true, flags: [])
                key(36, down: false, flags: [])
            case "\t":
                key(48, down: true, flags: [])
                key(48, down: false, flags: [])
            default:
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.flags = []
                    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e?.post(tap: .cghidEventTap)
                }
                usleep(4_000)
            }
        }
        return true
    }
}
