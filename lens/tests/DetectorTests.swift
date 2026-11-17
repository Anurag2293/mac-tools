import Foundation

private let cmdFlag: UInt64 = 0x100000, shiftFlag: UInt64 = 0x20000, ctrlFlag: UInt64 = 0x40000, altFlag: UInt64 = 0x80000
private let capsFlag: UInt64 = 0x10000, fnFlag: UInt64 = 0x800000

private typealias Ev = DoubleTapDetector.Input

/// Plays (time, event) pairs through a detector and returns the times at which it fired.
private func play(_ d: inout DoubleTapDetector, _ events: [(Double, Ev)]) -> [Double] {
    var fired: [Double] = []
    for (t, e) in events where d.handle(e, at: 1000 + t) { fired.append((t * 1000).rounded() / 1000) }
    return fired
}

private func rcmd() -> DoubleTapDetector { DoubleTapDetector(code: 54, mask: 0x10) }
private let rcmdDown = Ev.flagsChanged(keycode: 54, flags: cmdFlag | 0x10)
private let rcmdUp = Ev.flagsChanged(keycode: 54, flags: 0)
private let lcmdDown = Ev.flagsChanged(keycode: 55, flags: cmdFlag | 0x08)
private let lcmdUp = Ev.flagsChanged(keycode: 55, flags: 0)
private let shiftDown = Ev.flagsChanged(keycode: 56, flags: shiftFlag | 0x02)
private let shiftUp = Ev.flagsChanged(keycode: 56, flags: 0)

/// One tap: press at t, release at t + hold.
private func tap(_ t: Double, hold: Double = 0.05) -> [(Double, Ev)] { [(t, rcmdDown), (t + hold, rcmdUp)] }

func detectorTests() async {
    await suite("double-tap detector") {
        await test("two quick taps fire on the second release") {
            var d = rcmd()
            eq(play(&d, tap(0) + tap(0.15)), [0.2])
        }
        await test("a single tap does not fire") {
            var d = rcmd()
            eq(play(&d, tap(0)), [])
        }
        await test("the press alone never fires") {
            var d = rcmd()
            eq(play(&d, [(0, rcmdDown), (0.1, rcmdUp), (0.2, rcmdDown)]), [])
        }
        await test("two taps with no gap and a tiny hold fire") {
            var d = rcmd()
            eq(play(&d, tap(0, hold: 0.001) + tap(0.001, hold: 0.001)), [0.002])
        }
        await test("second tap after the window (release to release 0.4 s) does not fire") {
            var d = rcmd()
            eq(play(&d, tap(0) + tap(0.4)), [])
        }
        await test("a late second tap becomes the first tap of a new pair") {
            var d = rcmd()
            eq(play(&d, tap(0) + tap(0.5) + tap(0.7)), [0.75])
        }
        await test("a hold of 0.36 s is not a tap, 0.335 s is") {
            var d = rcmd()
            eq(play(&d, tap(0, hold: 0.01) + tap(0.01, hold: 0.36)), [])
            var e = rcmd()
            eq(play(&e, tap(0, hold: 0.01) + tap(0.01, hold: 0.335)), [0.345])
        }
        await test("a long first hold is not a tap and breaks the pair") {
            var d = rcmd()
            eq(play(&d, tap(0, hold: 0.4) + tap(0.45)), [])
        }
        await test("a long hold between two taps breaks the pair") {
            var d = rcmd()
            eq(play(&d, tap(0) + tap(0.1, hold: 0.6) + tap(0.8)), [])
        }
        await test("gap is measured release to release") {
            var d = rcmd()
            eq(play(&d, tap(0) + [(0.30, rcmdDown), (0.34, rcmdUp)]), [0.34], "second press 0.25 s after the release")
            var e = rcmd()
            eq(play(&e, tap(0, hold: 0.01) + [(0.02, rcmdDown), (0.369, rcmdUp)]), [], "prompt second press held 0.349 s")
        }
        await test("firing resets: three taps fire once, four fire twice") {
            var d = rcmd()
            eq(play(&d, tap(0) + tap(0.1) + tap(0.2)), [0.15])
            var e = rcmd()
            eq(play(&e, tap(0) + tap(0.1) + tap(0.2) + tap(0.3)), [0.15, 0.35])
        }
        await test("long idle between pairs") {
            var d = rcmd()
            eq(play(&d, tap(0) + tap(10) + tap(10.1)), [10.15])
        }
        await test("a key between the taps resets") {
            var d = rcmd()
            eq(play(&d, tap(0) + [(0.08, Ev.other)] + tap(0.1)), [])
        }
        await test("a key while holding invalidates that tap and the pair") {
            var d = rcmd()
            eq(play(&d, tap(0) + [(0.1, rcmdDown), (0.12, Ev.other), (0.15, rcmdUp)] + tap(0.2)), [])
        }
        await test("a key while holding the first press: the next two clean taps still fire") {
            var d = rcmd()
            eq(play(&d, [(0, rcmdDown), (0.02, Ev.other), (0.05, rcmdUp)] + tap(0.1) + tap(0.2)), [0.25])
        }
        await test("mouse clicks are other events") {
            var d = rcmd()
            eq(play(&d, tap(0) + [(0.07, Ev.other)] + tap(0.1)), [])
        }
        await test("another modifier between the taps resets") {
            var d = rcmd()
            eq(play(&d, tap(0) + [(0.06, shiftDown), (0.08, shiftUp)] + tap(0.1)), [])
        }
        await test("left cmd taps never fire the right cmd detector") {
            var d = rcmd()
            eq(play(&d, [(0, lcmdDown), (0.05, lcmdUp), (0.1, lcmdDown), (0.15, lcmdUp)]), [])
        }
        await test("left tap between two right taps resets") {
            var d = rcmd()
            eq(play(&d, tap(0) + [(0.06, lcmdDown), (0.08, lcmdUp)] + tap(0.1)), [])
        }
        await test("the left cmd detector fires on left taps and ignores right taps") {
            var d = DoubleTapDetector(code: 55, mask: 0x08)
            eq(play(&d, [(0, rcmdDown), (0.05, rcmdUp), (0.1, rcmdDown), (0.15, rcmdUp)]), [])
            eq(play(&d, [(1, lcmdDown), (1.05, lcmdUp), (1.1, lcmdDown), (1.15, lcmdUp)]), [1.15])
        }
        await test("shift held while pressing: not a clean tap") {
            var d = rcmd()
            let down = Ev.flagsChanged(keycode: 54, flags: cmdFlag | 0x10 | shiftFlag)
            eq(play(&d, [(0, down), (0.05, rcmdUp), (0.1, down), (0.15, rcmdUp)]), [])
        }
        await test("control or option held while pressing: not a clean tap") {
            for held in [ctrlFlag, altFlag] {
                var d = rcmd()
                let down = Ev.flagsChanged(keycode: 54, flags: cmdFlag | 0x10 | held)
                eq(play(&d, [(0, down), (0.05, rcmdUp), (0.1, down), (0.15, rcmdUp)]), [])
            }
        }
        await test("one tap with a modifier held and one clean tap do not fire") {
            var d = rcmd()
            let dirty = Ev.flagsChanged(keycode: 54, flags: cmdFlag | 0x10 | shiftFlag)
            eq(play(&d, tap(0) + [(0.1, dirty), (0.15, rcmdUp)]), [])
            var e = rcmd()
            eq(play(&e, [(0, dirty), (0.05, rcmdUp)] + tap(0.1)), [])
        }
        await test("caps lock and fn bits do not make a tap dirty") {
            var d = rcmd()
            let down = Ev.flagsChanged(keycode: 54, flags: cmdFlag | 0x10 | capsFlag | fnFlag)
            eq(play(&d, [(0, down), (0.05, rcmdUp), (0.1, down), (0.15, rcmdUp)]), [0.15])
        }
        await test("pinned: holding left cmd does not make a right cmd tap dirty") {
            var d = rcmd()
            let down = Ev.flagsChanged(keycode: 54, flags: cmdFlag | 0x10 | 0x08)
            eq(play(&d, [(0, down), (0.05, rcmdUp), (0.1, down), (0.15, rcmdUp)]), [0.15])
        }
        await test("a release with no press is ignored and keeps the pair intact") {
            var d = rcmd()
            eq(play(&d, tap(0) + [(0.07, rcmdUp)] + tap(0.1)), [0.15])
        }
        await test("a second press without a release restarts the hold") {
            var d = rcmd()
            eq(play(&d, [(0, rcmdDown), (0.3, rcmdDown), (0.35, rcmdUp), (0.4, rcmdDown), (0.45, rcmdUp)]), [0.45])
        }
        await test("every modifier in the table fires on its own key only") {
            check(modifierKeys.count == 8)
            let family: [Int64: UInt64] = [54: cmdFlag, 55: cmdFlag, 56: shiftFlag, 60: shiftFlag,
                                           58: altFlag, 61: altFlag, 59: ctrlFlag, 62: ctrlFlag]
            for (name, k) in modifierKeys {
                var d = DoubleTapDetector(code: k.code, mask: k.mask)
                let down = Ev.flagsChanged(keycode: k.code, flags: family[k.code]! | k.mask)
                let up = Ev.flagsChanged(keycode: k.code, flags: 0)
                eq(play(&d, [(0, down), (0.05, up), (0.1, down), (0.15, up)]), [0.15], name)
                let wrong = Ev.flagsChanged(keycode: k.code == 54 ? 55 : 54, flags: cmdFlag)
                var e = DoubleTapDetector(code: k.code, mask: k.mask)
                eq(play(&e, [(0, wrong), (0.05, rcmdUp), (0.1, wrong), (0.15, rcmdUp)]), [], name)
            }
        }
        await test("table is consistent: unique codes, one bit per mask") {
            eq(Set(modifierKeys.values.map(\.code)).count, 8)
            eq(Set(modifierKeys.values.map(\.mask)).count, 8)
            for (name, k) in modifierKeys { eq(k.mask.nonzeroBitCount, 1, name) }
        }
        await test("modifierFamily maps keys to their generic flag") {
            eq(modifierFamily(54), cmdFlag); eq(modifierFamily(55), cmdFlag)
            eq(modifierFamily(56), shiftFlag); eq(modifierFamily(60), shiftFlag)
            eq(modifierFamily(58), altFlag); eq(modifierFamily(61), altFlag)
            eq(modifierFamily(59), ctrlFlag); eq(modifierFamily(62), ctrlFlag)
        }
        await test("parseDoubleTap") {
            let r = parseDoubleTap("double:rcmd")
            eq(r?.code, 54); eq(r?.mask, 0x10)
            for name in modifierKeys.keys { check(parseDoubleTap("double:" + name) != nil, name) }
            check(parseDoubleTap("double:") == nil)
            check(parseDoubleTap("double:cmd") == nil)
            check(parseDoubleTap("rcmd") == nil)
            check(parseDoubleTap("ctrl+opt+t") == nil)
            check(parseDoubleTap("") == nil)
            check(parseDoubleTap("double:rcmd ") == nil, "trailing space")
        }
        await test("pinned: modifier names are case sensitive for double:") {
            check(parseDoubleTap("double:RCMD") == nil)
            check(parseDoubleTap("Double:rcmd") == nil)
        }
    }
}
