import AppKit

private func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ original: String = "原文",
                   translated: String? = nil, lineHeight: Double? = nil) -> Block {
    Block(area: CGRect(x: x, y: y, width: w, height: h), lineHeight: lineHeight ?? h, confidence: 1,
          original: original, translated: translated, bg: .white, fg: .black)
}

private func renderedHeight(_ text: String, _ size: CGFloat, width: CGFloat) -> CGFloat {
    attributed(text, size, .black).boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]).height
}

private func render(_ blocks: [Block], width: Int, height: Int, k: CGFloat = 1) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.translateBy(x: 0, y: CGFloat(height))
    ctx.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    drawBlocks(blocks, k: k)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private func rgba(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
}

func blockTests() async {
    await suite("blocks") {
        let px = pixels(1000, 600, bg: (1, 1, 1))

        await test("makeBlocks keeps only text that needs translation") {
            let lines = [L("設定を開く", 10, 10, 300, 20, conf: 0.9), L("Settings", 10, 100, 200, 20), L("日", 10, 200, 20, 20)]
            let bs = makeBlocks(lines, px, from: "ja")
            eq(bs.count, 1); eq(bs[0].original, "設定を開く")
        }
        await test("a block spans its lines, takes the minimum confidence and the median line height") {
            let lines = [L("これは長い文章の", 10, 10, 600, 20, conf: 0.9), L("続きの部分です", 10, 34, 600, 22, conf: 0.6),
                         L("さらにその続き", 10, 60, 600, 30, conf: 0.8)]
            let bs = makeBlocks(lines, px, from: "ja")
            eq(bs.count, 1)
            eq(bs[0].area, CGRect(x: 10, y: 10, width: 600, height: 80))
            eq(bs[0].confidence, 0.6)
            eq(bs[0].lineHeight, 22)
            eq(bs[0].original, "これは長い文章の続きの部分ですさらにその続き")
        }
        await test("with an even number of lines the upper median is used") {
            let lines = [L("これは長い文章の", 10, 10, 600, 20), L("続きの部分です", 10, 34, 600, 26)]
            eq(makeBlocks(lines, px, from: "ja")[0].lineHeight, 26)
        }
        await test("a block gets the sampled background and text colors") {
            let img = pixels(400, 100, bg: (0.1, 0.1, 0.1)) { ctx in fill(ctx, CGRect(x: 30, y: 30, width: 100, height: 20), (1, 1, 1)) }
            let b = makeBlocks([L("設定を開く", 28, 28, 104, 24)], img, from: "ja")[0]
            let bg = b.bg.usingColorSpace(.sRGB)!, fg = b.fg.usingColorSpace(.sRGB)!
            near(Double(bg.redComponent), 0.1, 0.02); near(Double(fg.redComponent), 1, 0.02)
        }
        await test("no lines, no blocks") { eq(makeBlocks([], px, from: "ja").count, 0) }
        await test("untouched text has no translation yet") {
            check(makeBlocks([L("設定を開く", 10, 10, 300, 20)], px, from: "ja")[0].translated == nil)
        }

        let focus = CGPoint(x: 500, y: 300)
        await test("sortedByFocus: the block under the pointer is first") {
            let bs = [block(0, 0, 100, 20, "a"), block(450, 290, 100, 20, "b"), block(900, 500, 100, 20, "c")]
            eq(sortedByFocus(bs, focus).first?.original, "b")
        }
        await test("sortedByFocus: vertical distance counts four times a horizontal one") {
            let beside = block(700, 290, 50, 20, "beside")     // dx = 200
            let below = block(480, 400, 50, 20, "below")       // dy = 100 -> 4 * 100^2 = 40000 = 200^2
            let nearBelow = block(480, 390, 50, 20, "nearBelow")  // dy = 90
            eq(sortedByFocus([beside, nearBelow], focus).map(\.original), ["nearBelow", "beside"])
            eq(sortedByFocus([below, beside], focus).count, 2)
        }
        await test("sortedByFocus: a row to the side beats a row far above") {
            let side = block(600, 290, 50, 20, "side")
            let above = block(480, 100, 50, 20, "above")
            eq(sortedByFocus([above, side], focus).map(\.original), ["side", "above"])
        }
        await test("sortedByFocus keeps all blocks, including duplicates, and handles empty input") {
            eq(sortedByFocus([], focus).count, 0)
            let bs = (0..<50).map { block(Double($0 * 10), Double($0 * 7), 30, 20, "b\($0)") }
            eq(Set(sortedByFocus(bs, focus).map(\.original)).count, 50)
            eq(sortedByFocus([block(0, 0, 1, 1), block(0, 0, 1, 1)], focus).count, 2)
        }
        await test("focusPoint on the main display") {
            let f = CGRect(x: 0, y: 0, width: 1440, height: 900)
            eq(focusPoint(mouse: CGPoint(x: 720, y: 450), screenFrame: f, k: 0.5), CGPoint(x: 1440, y: 900))
            eq(focusPoint(mouse: CGPoint(x: 0, y: 900), screenFrame: f, k: 0.5), CGPoint(x: 0, y: 0))
            eq(focusPoint(mouse: CGPoint(x: 1440, y: 0), screenFrame: f, k: 0.5), CGPoint(x: 2880, y: 1800))
            eq(focusPoint(mouse: CGPoint(x: 100, y: 800), screenFrame: f, k: 1), CGPoint(x: 100, y: 100))
        }
        await test("focusPoint on displays with an offset origin") {
            let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
            eq(focusPoint(mouse: CGPoint(x: 1440, y: 1080), screenFrame: right, k: 1), CGPoint(x: 0, y: 0))
            let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
            eq(focusPoint(mouse: CGPoint(x: -1000, y: 500), screenFrame: left, k: 0.5), CGPoint(x: 1840, y: 760))
        }
        await test("pixelRect converts Vision's normalized bottom-left boxes") {
            eq(pixelRect(fromVision: CGRect(x: 0, y: 0, width: 1, height: 1), width: 100, height: 50), CGRect(x: 0, y: 0, width: 100, height: 50))
            let r = pixelRect(fromVision: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1), width: 100, height: 50)
            near(r.minX, 10); near(r.minY, 5); near(r.width, 20); near(r.height, 5)
            let bottom = pixelRect(fromVision: CGRect(x: 0, y: 0, width: 0.5, height: 0.1), width: 200, height: 100)
            near(bottom.minY, 90); near(bottom.maxY, 100)
        }
        await test("visionLanguages") {
            eq(visionLanguages(from: "ja"), ["ja-JP", "en-US"])
            eq(visionLanguages(from: "en"), ["en-US"])
            eq(visionLanguages(from: "zh"), ["zh-Hans", "en-US"])
            eq(visionLanguages(from: "xx"), ["xx", "en-US"])
            eq(visionLanguages(from: ""), ["", "en-US"])
        }
    }

    await suite("copyText") {
        await test("reading order, blank line between blocks, untranslated blocks skipped") {
            let bs = [block(0, 200, 10, 10, translated: "third"), block(0, 0, 10, 10, translated: "first"),
                      block(0, 100, 10, 10, translated: nil), block(300, 100, 10, 10, translated: "second")]
            eq(copyText(bs), "first\n\nsecond\n\nthird")
        }
        await test("no blocks") { eq(copyText([]), "") }
        await test("a single block has no separators") { eq(copyText([block(0, 0, 1, 1, translated: "only")]), "only") }
        await test("same top edge sorts left to right") {
            eq(copyText([block(500, 10, 1, 1, translated: "right"), block(0, 10, 1, 1, translated: "left")]), "left\n\nright")
        }
        await test("pinned: a block one pixel lower on the same row sorts after its right neighbour") {
            eq(copyText([block(0, 11, 1, 1, translated: "left"), block(500, 10, 1, 1, translated: "right")]), "right\n\nleft")
        }
    }

    await suite("fit") {
        await test("short text keeps the original box plus padding and the largest font") {
            var b = block(100, 100, 400, 20, translated: "Settings")
            fit(&b, maxRight: 1000, others: [])
            near(Double(b.fontPx), 17)
            let p = 20 * Double(pad)
            eq(b.rect, CGRect(x: 100 - p, y: 100 - p, width: 400 + 2 * p, height: 20 + 2 * p))
        }
        await test("no translation yet fits as empty text") {
            var b = block(100, 100, 400, 20)
            fit(&b, maxRight: 1000, others: [])
            near(Double(b.fontPx), 17)
        }
        await test("a long single line widens to the right up to 2.5 times the box") {
            var b = block(100, 100, 100, 20, translated: "A considerably longer translation than the original")
            fit(&b, maxRight: 5000, others: [])
            check(b.rect.width > 100 + 2 * 20 * pad, "widened: \(b.rect)")
            check(b.rect.width <= (100 + 2 * 20 * Double(pad)) * 2.5 + 0.001, "at most 2.5x: \(b.rect)")
            near(Double(b.rect.minX), 100 - 20 * Double(pad))
        }
        await test("widening stops at maxRight") {
            var b = block(100, 100, 100, 20, translated: "A considerably longer translation than the original")
            fit(&b, maxRight: 250, others: [])
            check(b.rect.maxX <= 250 + 0.001, "\(b.rect)")
        }
        await test("widening stops before text to the right on the same row") {
            var b = block(100, 100, 100, 20, translated: "A considerably longer translation than the original")
            fit(&b, maxRight: 5000, others: [CGRect(x: 260, y: 98, width: 80, height: 24)])
            check(b.rect.maxX <= 260 - 20 * Double(pad) + 0.001, "\(b.rect)")
        }
        await test("text on other rows or to the left does not limit widening") {
            var free = block(100, 100, 100, 20, translated: "A considerably longer translation than the original")
            fit(&free, maxRight: 5000, others: [])
            var b = free
            b.rect = .zero
            fit(&b, maxRight: 5000, others: [CGRect(x: 260, y: 200, width: 80, height: 24), CGRect(x: 0, y: 98, width: 50, height: 24)])
            eq(b.rect, free.rect)
        }
        await test("the box never gets narrower than the original, even when maxRight is tight") {
            var b = block(100, 100, 100, 20, translated: "A considerably longer translation than the original")
            fit(&b, maxRight: 120, others: [])
            check(b.rect.width >= 100 + 2 * 20 * Double(pad) - 0.001, "\(b.rect)")
        }
        await test("a neighbour overlapping the box does not shrink it") {
            var b = block(100, 100, 100, 20, translated: "A considerably longer translation than the original")
            fit(&b, maxRight: 5000, others: [CGRect(x: 150, y: 98, width: 80, height: 24)])
            check(b.rect.width >= 100 + 2 * 20 * Double(pad) - 0.001)
        }
        await test("multi-line areas grow downward instead of widening") {
            var b = block(100, 100, 100, 60, translated: String(repeating: "A long translated sentence. ", count: 8), lineHeight: 20)
            fit(&b, maxRight: 5000, others: [])
            near(Double(b.rect.width), 100 + 2 * 20 * Double(pad))
            check(b.rect.height > 60, "grew: \(b.rect)")
            check(b.fontPx >= 20 * 0.6 - 0.001 && b.fontPx <= 20 * 0.85)
            let inner = b.rect.height - 2 * 20 * pad
            near(Double(inner), Double(renderedHeight(b.translated!, b.fontPx, width: b.rect.width - 2 * 20 * pad)), 0.01)
        }
        await test("the font stays between 60% and 85% of the line height") {
            for text in ["x", "Short", "A medium length sentence here", String(repeating: "word ", count: 60)] {
                var b = block(10, 10, 150, 30, translated: text, lineHeight: 30)
                fit(&b, maxRight: 2000, others: [])
                check(b.fontPx >= 30 * 0.6 - 0.001 && b.fontPx <= 30 * 0.85 + 0.001, "\(b.fontPx) for \(text.count) chars")
            }
        }
        await test("the painted box always contains the original area") {
            for text in ["", "x", "A medium length sentence here", String(repeating: "word ", count: 60)] {
                var b = block(10, 10, 150, 30, translated: text, lineHeight: 30)
                fit(&b, maxRight: 2000, others: [])
                check(b.rect.contains(b.area), "\(b.rect) vs \(b.area) for \(text.count) chars")
            }
        }
        await test("if the rect is not grown, the text fits in it") {
            var b = block(10, 10, 300, 30, translated: "Fits easily", lineHeight: 30)
            fit(&b, maxRight: 2000, others: [])
            let inner = b.rect.insetBy(dx: 30 * pad, dy: 30 * pad)
            check(renderedHeight("Fits easily", b.fontPx, width: inner.width) <= inner.height)
        }
        await test("very long text finishes and grows the box") {
            var b = block(10, 10, 300, 20, translated: String(repeating: "Lorem ipsum dolor sit amet. ", count: 300))
            let t0 = Date()
            fit(&b, maxRight: 2000, others: [])
            check(b.rect.height > 100)
            check(Date().timeIntervalSince(t0) < 10, "took \(Date().timeIntervalSince(t0)) s")
        }
        await test("Japanese, emoji and empty translations are fitted without trouble") {
            for t in ["", "日本語の翻訳", "\u{1F600}\u{1F600}", "العربية", "a\u{200B}b"] {
                var b = block(10, 10, 100, 20, translated: t)
                fit(&b, maxRight: 500, others: [])
                check(b.fontPx > 0 && b.rect.width > 0 && b.rect.height > 0, "\(t)")
            }
        }
    }

    await suite("drawBlocks") {
        await test("paints the background of a translated block and leaves the rest clear") {
            var b = block(20, 20, 60, 20, translated: "Hi")
            b.bg = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            fit(&b, maxRight: 200, others: [])
            let rep = render([b], width: 120, height: 80)
            let inside = rgba(rep, Int(b.rect.maxX) - 3, Int(b.rect.maxY) - 3)
            check(inside.0 > 0.95 && inside.1 < 0.05 && inside.3 > 0.95, "inside \(inside)")
            let outside = rgba(rep, 2, 2)
            check(outside.3 < 0.01, "outside \(outside)")
        }
        await test("scale k maps image pixels to drawing units") {
            var b = block(20, 20, 60, 20, translated: "Hi")
            b.bg = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            fit(&b, maxRight: 200, others: [])
            let rep = render([b], width: 60, height: 40, k: 0.5)
            let inside = rgba(rep, Int(b.rect.maxX * 0.5) - 2, Int(b.rect.maxY * 0.5) - 2)
            check(inside.1 > 0.95 && inside.3 > 0.95, "inside \(inside)")
            check(rgba(rep, 2, 2).3 < 0.01)
            check(rgba(rep, Int(b.rect.maxX * 0.5) + 6, Int(b.rect.maxY * 0.5) + 6).3 < 0.01)
        }
        await test("blocks without a translation, or equal to the original, are not painted") {
            var a = block(10, 10, 60, 20, "same", translated: "same"); a.rect = a.area
            var b = block(10, 50, 60, 20, "x", translated: nil); b.rect = b.area
            a.bg = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1); b.bg = a.bg
            let rep = render([a, b], width: 100, height: 100)
            check(rgba(rep, 30, 18).3 < 0.01); check(rgba(rep, 30, 58).3 < 0.01)
        }
        await test("the first block of the list ends up on top") {
            var a = block(10, 10, 60, 40, "a", translated: "A"); a.rect = a.area; a.fontPx = 10
            var b = block(10, 10, 60, 40, "b", translated: "B"); b.rect = b.area; b.fontPx = 10
            a.bg = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            b.bg = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            let rep = render([a, b], width: 100, height: 80)
            let p = rgba(rep, 68, 48)
            check(p.0 > 0.95 && p.1 < 0.05, "a is on top: \(p)")
        }
        await test("no blocks draws nothing") {
            let rep = render([], width: 20, height: 20)
            check(rgba(rep, 5, 5).3 < 0.01)
        }
    }
}
