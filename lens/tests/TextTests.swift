import Foundation

private func scalar(_ s: String) -> Unicode.Scalar { s.unicodeScalars.first! }
private func texts(_ ps: [[Line]]) -> [[String]] { ps.map { $0.map(\.text) } }

func textTests() async {
    await suite("character classes") {
        await test("isCJKLetter covers kana, kanji, half-width kana and hangul but not punctuation") {
            for c in ["あ", "ぁ", "ゖ", "ア", "ァ", "ヺ", "日", "本", "語", "㐀", "ｱ", "ﾝ", "한", "글"] {
                check(isCJKLetter(scalar(c)), c)
            }
            for c in ["・", "ー", "、", "。", "「", "a", "Z", "1", " ", "Ａ", "ー", "ヽ", "\u{3099}", "!"] {
                check(!isCJKLetter(scalar(c)), c)
            }
        }
        await test("isCJK additionally counts the kana block punctuation") {
            for c in ["あ", "ア", "日", "・", "ー", "ヿ", "ｱ", "한"] { check(isCJK(scalar(c)), c) }
            for c in ["a", "、", "。", "「", "Ａ", "1", " "] { check(!isCJK(scalar(c)), c) }
        }
        await test("range edges") {
            check(isCJKLetter(Unicode.Scalar(0x4E00)!)); check(isCJKLetter(Unicode.Scalar(0x9FFF)!))
            check(!isCJKLetter(Unicode.Scalar(0x4DFF)!)); check(!isCJKLetter(Unicode.Scalar(0xA000)!))
            check(isCJKLetter(Unicode.Scalar(0xAC00)!)); check(isCJKLetter(Unicode.Scalar(0xD7AF)!))
            check(!isCJKLetter(Unicode.Scalar(0xD7B0)!))
        }
        await test("pinned: kanji outside the BMP are not recognized") {
            check(!isCJKLetter(Unicode.Scalar(0x20BB7)!))
        }
    }

    await suite("endsSentence and startsBullet") {
        await test("sentence ends") {
            for s in ["これは文です。", "It ends.", "Really?", "Wow!", "本当？", "すごい！", "Label:", "ラベル：", "x．", "done.  "] {
                check(endsSentence(s), s)
            }
            for s in ["これは、", "no end", "comma,", "open「", "ありがとう", "end」"] { check(!endsSentence(s), s) }
        }
        await test("empty or blank text counts as ended") {
            check(endsSentence("")); check(endsSentence("   "))
        }
        await test("bullets") {
            for s in ["• item", "・項目", "● a", "○ a", "■ a", "□ a", "◆ a", "◇ a", "- a", "– a", "* a", "※ 注意", "★ a", "→ next", "   • indented"] {
                check(startsBullet(s), s)
            }
            for s in ["", "   ", "item", "1. item", "(a) item", "—x", "a - b"] { check(!startsBullet(s), s) }
        }
        await test("the small square bullet is recognized with and without the text variation selector") {
            check(startsBullet("\u{25AA} item"), "plain U+25AA")
            check(startsBullet("\u{25AA}\u{FE0E} item"), "with U+FE0E")
        }
    }

    await suite("joinLines") {
        await test("Japanese lines join without a space") {
            eq(joinLines([L("これは長い", 0, 0, 10, 10), L("文章です", 0, 0, 10, 10)]), "これは長い文章です")
        }
        await test("Latin lines join with one space") {
            eq(joinLines([L("hello", 0, 0, 1, 1), L("world", 0, 0, 1, 1)]), "hello world")
        }
        await test("Latin and CJK join with a space either way") {
            eq(joinLines([L("Wi-Fi", 0, 0, 1, 1), L("設定", 0, 0, 1, 1)]), "Wi-Fi 設定")
            eq(joinLines([L("設定", 0, 0, 1, 1), L("Wi-Fi", 0, 0, 1, 1)]), "設定 Wi-Fi")
        }
        await test("prolonged sound mark and middle dot count as CJK") {
            eq(joinLines([L("コンピュー", 0, 0, 1, 1), L("ター", 0, 0, 1, 1)]), "コンピューター")
            eq(joinLines([L("A・", 0, 0, 1, 1), L("B", 0, 0, 1, 1)]), "A・ B")
            eq(joinLines([L("ア・", 0, 0, 1, 1), L("イ", 0, 0, 1, 1)]), "ア・イ")
        }
        await test("lines are trimmed and the result has no leading space") {
            eq(joinLines([L("  hello  ", 0, 0, 1, 1), L("  world", 0, 0, 1, 1)]), "hello world")
        }
        await test("empty and blank lines add nothing") {
            eq(joinLines([]), "")
            eq(joinLines([L("a", 0, 0, 1, 1), L("", 0, 0, 1, 1), L("b", 0, 0, 1, 1)]), "a b")
            eq(joinLines([L("   ", 0, 0, 1, 1)]), "")
        }
        await test("half-width katakana join without a space") {
            eq(joinLines([L("ｱｲ", 0, 0, 1, 1), L("ｳｴ", 0, 0, 1, 1)]), "ｱｲｳｴ")
        }
        await test("pinned: CJK punctuation at a line end gets a space before the next line") {
            eq(joinLines([L("これは、", 0, 0, 1, 1), L("テスト", 0, 0, 1, 1)]), "これは、 テスト")
        }
        await test("hangul joins without a space") {
            eq(joinLines([L("한국", 0, 0, 1, 1), L("어", 0, 0, 1, 1)]), "한국어")
        }
    }

    await suite("needsTranslation") {
        await test("Japanese source") {
            for s in ["日本語", "こんにちは", "カタカナ", "設定", "Wi-Fi設定", "Google 日本", "あ。", "ｱｲｳ", "日 本", " 設"] {
                check(needsTranslation(s, from: "ja"), s)
            }
            for s in ["", "a", "OK", "Settings", "123", "日", "あ", "ー", "ーー", "・・", "Settings 設", "Ａ１", "\u{1F600}\u{1F600}"] {
                check(!needsTranslation(s, from: "ja"), s)
            }
        }
        await test("a lone CJK glyph next to Latin text is an icon misread, two are text") {
            check(!needsTranslation("File 日", from: "ja"))
            check(needsTranslation("File 日本", from: "ja"))
        }
        await test("hangul and Chinese sources use the same rule") {
            check(needsTranslation("한국어", from: "ko"))
            check(needsTranslation("你好世界", from: "zh"))
            check(!needsTranslation("Hello", from: "zh"))
        }
        await test("pinned: Korean text passes the Japanese filter") {
            check(needsTranslation("한국어", from: "ja"))
        }
        await test("other sources use the language recognizer") {
            check(needsTranslation("Das ist ein kleines Haus und wir gehen heute nach Hause.", from: "de"))
            check(!needsTranslation("This is a small house and we are going home today.", from: "de"))
            check(needsTranslation("This is a small house and we are going home today.", from: "en"))
            check(!needsTranslation("これは日本語の文章です。", from: "en"))
        }
        await test("English source: one character and empty text are skipped") {
            check(!needsTranslation("a", from: "en"))
            check(!needsTranslation("", from: "en"))
        }
        await test("very long input") {
            check(needsTranslation(String(repeating: "日本語のテキスト", count: 20000), from: "ja"))
            check(!needsTranslation(String(repeating: "x", count: 200000), from: "ja"))
        }
    }

    await suite("paragraphs") {
        await test("no lines") { eq(paragraphs([]).count, 0) }
        await test("one line") { eq(texts(paragraphs([L("a", 0, 0, 100, 20)])), [["a"]]) }
        await test("a wrapped paragraph merges") {
            let ps = paragraphs([L("first", 0, 0, 600, 20), L("second", 0, 24, 300, 20)])
            eq(texts(ps), [["first", "second"]])
        }
        await test("input order does not matter") {
            let ps = paragraphs([L("third", 0, 48, 300, 20), L("first", 0, 0, 600, 20), L("second", 0, 24, 600, 20)])
            eq(texts(ps), [["first", "second", "third"]])
        }
        await test("a sentence end splits") {
            let ps = paragraphs([L("first.", 0, 0, 600, 20), L("second", 0, 24, 300, 20)])
            eq(texts(ps), [["first."], ["second"]])
        }
        await test("a line that stops short of the right edge splits") {
            let ps = paragraphs([L("first", 0, 0, 300, 20), L("second", 0, 24, 600, 20)])
            eq(texts(ps), [["first"], ["second"]])
        }
        await test("a line within 2.5 line heights of the right edge still counts as wrapped") {
            let ps = paragraphs([L("a", 0, 0, 551, 20), L("b", 0, 24, 600, 20), L("c", 0, 48, 600, 20)])
            eq(texts(ps), [["a", "b", "c"]])
            let qs = paragraphs([L("a", 0, 0, 549, 20), L("b", 0, 24, 600, 20)])
            eq(texts(qs), [["a"], ["b"]])
        }
        await test("a bullet starts a new paragraph") {
            let ps = paragraphs([L("intro", 0, 0, 600, 20), L("・item one", 0, 24, 600, 20), L("・item two", 0, 48, 300, 20)])
            eq(texts(ps), [["intro"], ["・item one"], ["・item two"]])
        }
        await test("narrow blocks are never merged") {
            let ps = paragraphs([L("Save", 0, 0, 200, 20), L("Cancel", 0, 24, 200, 20)])
            eq(texts(ps), [["Save"], ["Cancel"]])
        }
        await test("different heights make different blocks") {
            let ps = paragraphs([L("title", 0, 0, 600, 40), L("body", 0, 44, 600, 20)])
            eq(texts(ps), [["title"], ["body"]])
        }
        await test("similar heights stay together") {
            let ps = paragraphs([L("a", 0, 0, 600, 20), L("b", 0, 24, 600, 24)])
            eq(texts(ps), [["a", "b"]])
        }
        await test("left edges 1.2 line heights apart are different columns") {
            let ps = paragraphs([L("a", 0, 0, 600, 20), L("b", 25, 24, 600, 20)])
            eq(texts(ps), [["a"], ["b"]])
            let qs = paragraphs([L("a", 0, 0, 600, 20), L("b", 20, 24, 600, 20)])
            eq(texts(qs), [["a", "b"]])
        }
        await test("a large vertical gap splits blocks") {
            let ps = paragraphs([L("a", 0, 0, 600, 20), L("b", 0, 37, 600, 20)])
            eq(texts(ps), [["a"], ["b"]])
            let qs = paragraphs([L("a", 0, 0, 600, 20), L("b", 0, 35, 600, 20)])
            eq(texts(qs), [["a", "b"]])
        }
        await test("lines that overlap vertically by more than 30% split") {
            let ps = paragraphs([L("a", 0, 0, 600, 20), L("b", 0, 12, 600, 20)])
            eq(texts(ps), [["a"], ["b"]])
            let qs = paragraphs([L("a", 0, 0, 600, 20), L("b", 0, 15, 600, 20)])
            eq(texts(qs), [["a", "b"]])
        }
        await test("two columns side by side stay separate") {
            var lines: [Line] = []
            for i in 0..<4 {
                lines.append(L("L\(i)", 0, Double(i) * 24, 600, 20))
                lines.append(L("R\(i)", 800, Double(i) * 24 + 1, 600, 20))
            }
            let ps = texts(paragraphs(lines))
            eq(ps, [["L0", "L1", "L2", "L3"], ["R0", "R1", "R2", "R3"]])
        }
        await test("pinned: duplicate lines at the same position are separate paragraphs") {
            let ps = paragraphs([L("same", 0, 0, 300, 20), L("same", 0, 0, 300, 20)])
            eq(texts(ps), [["same"], ["same"]])
        }
        await test("zero height lines do not crash and stay separate") {
            let ps = paragraphs([L("a", 0, 0, 100, 0), L("b", 0, 0, 100, 0), L("c", 0, 10, 100, 0)])
            eq(ps.count, 3)
        }
        await test("japanese paragraph wraps and joins") {
            let ps = paragraphs([L("これは長い文章の最初の", 0, 0, 600, 20), L("部分で、次の行に続きます", 0, 24, 400, 20),
                                 L("別の段落。", 0, 100, 200, 20)])
            eq(ps.count, 2)
            eq(joinLines(ps[0]), "これは長い文章の最初の部分で、次の行に続きます")
        }
        await test("mixed sentence end ends a wrapped paragraph: full-width and half-width marks") {
            let ps = paragraphs([L("一行目です。", 0, 0, 600, 20), L("二行目", 0, 24, 600, 20)])
            eq(ps.count, 2)
        }
        await test("many lines stay fast") {
            var lines: [Line] = []
            for i in 0..<4000 { lines.append(L("line \(i)", Double((i % 3) * 700), Double(i / 3) * 40, 600, 20)) }
            let t0 = Date()
            let ps = paragraphs(lines)
            check(ps.count > 0)
            check(Date().timeIntervalSince(t0) < 5, "took \(Date().timeIntervalSince(t0)) s")
        }
        await test("a very tall block of one wrapped paragraph") {
            var lines: [Line] = []
            for i in 0..<300 { lines.append(L("w\(i)", 0, Double(i) * 24, 600, 20)) }
            eq(paragraphs(lines).count, 1)
            eq(paragraphs(lines)[0].count, 300)
        }
        await test("every input line comes out exactly once") {
            var lines: [Line] = []
            var seed: UInt64 = 42
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
            for i in 0..<400 { lines.append(L("t\(i)", rnd() * 1000, rnd() * 1000, 50 + rnd() * 500, 10 + rnd() * 30)) }
            let out = paragraphs(lines).flatMap { $0.map(\.text) }
            eq(out.count, 400)
            eq(Set(out).count, 400)
        }
    }
}
