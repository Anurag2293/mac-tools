import CoreGraphics
import Foundation

func registerInputTests() {
    suite("Input: key chord parsing") {
        test("a single character maps to its US-layout key code") {
            expectEqual(try Input.parse("a").key, 0)
            expectEqual(try Input.parse("s").key, 1)
            expectEqual(try Input.parse("z").key, 6)
            expectEqual(try Input.parse("1").key, 18)
            expectEqual(try Input.parse("0").key, 29)
            expectEqual(try Input.parse(";").key, 41)
            expectEqual(try Input.parse("`").key, 50)
            expect(try Input.parse("a").mods.isEmpty)
        }

        test("every letter and digit has a key, and no two characters share a code") {
            let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init) + ["=", "-", "]", "[", "'", ";", "\\", ",", "/", ".", "`"]
            var seen: [CGKeyCode: String] = [:]
            for c in chars {
                guard let code = try? Input.parse(c).key else { expect(false, "no key for \(c)"); continue }
                if let other = seen[code] { expect(false, "\(c) and \(other) share code \(code)") }
                seen[code] = c
            }
        }

        test("named keys use the macOS virtual key codes") {
            let expected: [String: CGKeyCode] = [
                "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51,
                "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
                "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
            ]
            for (name, code) in expected { expectEqual(try Input.parse(name).key, code, name) }
        }

        test("function keys f1 to f12 use their distinct codes") {
            let expected: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            for (i, code) in expected.enumerated() { expectEqual(try Input.parse("f\(i + 1)").key, code, "f\(i + 1)") }
        }

        test("modifier aliases resolve to the same keys and flags") {
            for name in ["cmd", "command"] {
                let c = try Input.parse("\(name)+s")
                expectEqual(c.mods.count, 1)
                expectEqual(c.mods[0].0, 55)
                expectEqual(c.mods[0].1, .maskCommand)
            }
            for name in ["alt", "option", "opt"] { expectEqual(try Input.parse("\(name)+a").mods[0].1, .maskAlternate, name) }
            for name in ["ctrl", "control"] { expectEqual(try Input.parse("\(name)+a").mods[0].1, .maskControl, name) }
            expectEqual(try Input.parse("shift+a").mods[0].1, .maskShift)
            expectEqual(try Input.parse("fn+a").mods[0].1, .maskSecondaryFn)
            expectEqual(try Input.parse("fn+a").mods[0].0, 63)
        }

        test("several modifiers keep their order and the last part is the key") {
            let c = try Input.parse("cmd+shift+t")
            expectEqual(c.mods.map { $0.0 }, [55, 56])
            expectEqual(c.key, 17)
            let d = try Input.parse("ctrl+alt+cmd+delete")
            expectEqual(d.mods.map { $0.0 }, [59, 58, 55])
            expectEqual(d.key, 51)
        }

        test("parsing ignores case") {
            let c = try Input.parse("CMD+Shift+RETURN")
            expectEqual(c.mods.map { $0.0 }, [55, 56])
            expectEqual(c.key, 36)
        }

        test("a bare modifier name presses that modifier key") {
            expectEqual(try Input.parse("shift").key, 56)
            expect(try Input.parse("shift").mods.isEmpty)
            expectEqual(try Input.parse("cmd+shift").key, 56)
        }

        test("a trailing plus is ignored, so cmd+ presses the command key alone (pinned)") {
            let c = try Input.parse("cmd+")
            expect(c.mods.isEmpty)
            expectEqual(c.key, 55)
        }

        test("an empty chord is an error") {
            expectError("Empty key chord.") { try Input.parse("") }
            expectError("Empty key chord.") { try Input.parse("+") }
        }

        test("an unknown modifier is named in the error") {
            expectError("Unknown modifier 'hyper'. Use cmd, shift, alt, ctrl, fn.") { try Input.parse("hyper+a") }
            expectError("Unknown modifier 'a'. Use cmd, shift, alt, ctrl, fn.") { try Input.parse("a+b") }
        }

        test("an unknown key is named in the error and lists what is accepted") {
            let message = "Unknown key 'bogus'. Use return, escape, tab, space, backspace, forwarddelete, up/down/left/right, home, end, pageup, pagedown, f1-f12, or a single character."
            expectError(message) { try Input.parse("bogus") }
            expectError(message) { try Input.parse("cmd+BOGUS") }
            expectErrorContaining("Unknown key 'ab'") { try Input.parse("ab") }
            expectErrorContaining("Unknown key 'é'") { try Input.parse("é") }
            expectErrorContaining("Unknown key 'f13'") { try Input.parse("f13") }
        }

        test("modifier errors win over key errors") {
            expectErrorContaining("Unknown modifier 'hyper'") { try Input.parse("hyper+bogus") }
        }
    }

    suite("Input: key sequences") {
        test("chords are split on whitespace") {
            let chords = try Input.parseSequence("cmd+a  backspace\treturn\nescape")
            expectEqual(chords.map { $0.key }, [0, 51, 36, 53])
            expectEqual(chords[0].mods.count, 1)
        }

        test("a single chord is a sequence of one") {
            expectEqual(try Input.parseSequence("cmd+s").count, 1)
        }

        test("one bad chord rejects the whole sequence") {
            expectErrorContaining("Unknown key 'nope'") { try Input.parseSequence("cmd+a nope return") }
            expectErrorContaining("Unknown modifier 'hyper'") { try Input.parseSequence("a hyper+b") }
        }
    }
}
