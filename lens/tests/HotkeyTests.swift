import Carbon.HIToolbox
import Foundation

private func hk(_ spec: String) -> (UInt32, UInt32)? {
    guard let r = parseHotkey(spec) else { return nil }
    return (r.key, r.mods)
}

private func mods(_ m: Int...) -> UInt32 { UInt32(m.reduce(0, |)) }

func hotkeyTests() async {
    await suite("parseHotkey") {
        await test("the documented chord") {
            let r = hk("ctrl+opt+t")
            eq(r?.0, UInt32(kVK_ANSI_T)); eq(r?.1, mods(controlKey, optionKey))
        }
        await test("every modifier and alias") {
            eq(hk("ctrl+a")?.1, mods(controlKey)); eq(hk("control+a")?.1, mods(controlKey))
            eq(hk("opt+a")?.1, mods(optionKey)); eq(hk("option+a")?.1, mods(optionKey)); eq(hk("alt+a")?.1, mods(optionKey))
            eq(hk("cmd+a")?.1, mods(cmdKey)); eq(hk("command+a")?.1, mods(cmdKey))
            eq(hk("shift+a")?.1, mods(shiftKey))
            eq(hk("cmd+shift+ctrl+opt+a")?.1, mods(cmdKey, shiftKey, controlKey, optionKey))
        }
        await test("letters, digits, space, punctuation and function keys") {
            eq(hk("cmd+a")?.0, UInt32(kVK_ANSI_A)); eq(hk("cmd+z")?.0, UInt32(kVK_ANSI_Z))
            eq(hk("cmd+0")?.0, UInt32(kVK_ANSI_0)); eq(hk("cmd+9")?.0, UInt32(kVK_ANSI_9))
            eq(hk("cmd+space")?.0, UInt32(kVK_Space))
            eq(hk("cmd+/")?.0, UInt32(kVK_ANSI_Slash)); eq(hk("cmd+.")?.0, UInt32(kVK_ANSI_Period)); eq(hk("cmd+,")?.0, UInt32(kVK_ANSI_Comma))
            eq(hk("ctrl+f1")?.0, UInt32(kVK_F1)); eq(hk("ctrl+f12")?.0, UInt32(kVK_F12)); eq(hk("ctrl+f5")?.0, UInt32(kVK_F5))
        }
        await test("all letters and digits are distinct keys") {
            var seen = Set<UInt32>()
            for c in "abcdefghijklmnopqrstuvwxyz0123456789" {
                guard let r = hk("cmd+\(c)") else { check(false, "\(c)"); continue }
                check(seen.insert(r.0).inserted, "\(c) duplicates a key code")
            }
            eq(seen.count, 36)
        }
        await test("case and order do not matter") {
            eq(hk("Ctrl+Opt+T")?.0, UInt32(kVK_ANSI_T)); eq(hk("CMD+SHIFT+SPACE")?.1, mods(cmdKey, shiftKey))
            eq(hk("t+ctrl+opt")?.0, UInt32(kVK_ANSI_T)); eq(hk("t+ctrl+opt")?.1, mods(controlKey, optionKey))
        }
        await test("repeated modifiers count once") {
            eq(hk("cmd+cmd+a")?.1, mods(cmdKey)); eq(hk("cmd+command+a")?.1, mods(cmdKey))
        }
        await test("no key, or an empty spec, is invalid") {
            for s in ["", "ctrl", "ctrl+opt", "+", "++", "ctrl+", "+a+" == "" ? "" : "cmd+shift+"] { check(hk(s) == nil, s) }
        }
        await test("a bare key without modifiers is accepted") {
            let r = hk("f5"); eq(r?.0, UInt32(kVK_F5)); eq(r?.1, 0)
        }
        await test("unknown keys are invalid") {
            for s in ["ctrl+f13", "ctrl+enter", "cmd+tab", "ctrl+aa", "ctrl+-", "ctrl+Ａ", "ctrl+日", "double:rcmd", "ctrl + t", "ctrl+ t"] {
                check(hk(s) == nil, s)
            }
        }
        await test("an unknown token anywhere makes the spec invalid") {
            for s in ["ctrl+bogus+t", "bogus+ctrl+t", "ctrl+t+bogus", "ctrl+shfit+t", "ctrl+opt+tt+t"] {
                check(hk(s) == nil, s)
            }
        }
        await test("pinned: with two keys the last one wins") {
            eq(hk("cmd+a+b")?.0, UInt32(kVK_ANSI_B))
        }
        await test("very long spec") {
            check(hk(String(repeating: "ctrl+", count: 10000) + "t") != nil)
            check(hk(String(repeating: "x", count: 100000)) == nil)
        }
    }
}
