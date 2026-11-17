import AppKit

/// Renders text into an in-memory bitmap (white background, black text); `y` is the baseline
/// distance from the top of the image. Nothing here touches the screen.
private func textImage(_ w: Int, _ h: Int, _ items: [(String, Double, Double, CGFloat)]) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (text, x, yTop, size) in items {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
        s.draw(at: NSPoint(x: x, y: Double(h) - yTop - Double(size)))
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func visionTests() async {
    await suite("vision on synthetic images") {
        await test("English text is read with top-left pixel coordinates") {
            let img = textImage(900, 400, [("Hello World", 60, 40, 48), ("Second Line Here", 60, 300, 48)])
            let lines = try recognize(img, from: "ja")
            guard lines.count >= 2 else { skip("Vision returned \(lines.count) lines for rendered English text"); return }
            let top = lines.first { $0.text.contains("Hello") }, bottom = lines.first { $0.text.contains("Second") }
            check(top != nil && bottom != nil, "\(lines.map(\.text))")
            if let t = top, let b = bottom {
                check(t.rect.minY < 120, "top line at \(t.rect)")
                check(b.rect.minY > 250, "bottom line at \(b.rect)")
                check(t.rect.minX > 40 && t.rect.maxX < 700, "\(t.rect)")
                check(t.confidence > 0.3)
            }
        }
        await test("Japanese text is read and turned into a block with the right colors") {
            let img = textImage(1000, 300, [("設定を開いてください", 60, 100, 56)])
            let lines = try recognize(img, from: "ja")
            guard lines.contains(where: { $0.text.contains("設定") }) else { skip("Vision did not read the Japanese text: \(lines.map(\.text))"); return }
            let blocks = try prepare(img, focus: nil, from: "ja")
            check(blocks.count >= 1, "\(blocks.count) blocks")
            if let b = blocks.first {
                check(b.original.contains("設定"), b.original)
                let bg = b.bg.usingColorSpace(.sRGB)!, fg = b.fg.usingColorSpace(.sRGB)!
                check(bg.redComponent > 0.95 && fg.redComponent < 0.2, "bg \(bg) fg \(fg)")
                check(b.area.minY > 60 && b.area.maxY < 220, "\(b.area)")
            }
        }
        await test("English-only text yields no blocks for a Japanese source") {
            let img = textImage(900, 200, [("Settings and options", 60, 60, 48)])
            let r8640 = try prepare(img, focus: nil, from: "ja").count
            eq(r8640, 0)
        }
        await test("a blank image yields no lines") {
            let img = makeImage(400, 200) { ctx in fill(ctx, CGRect(x: 0, y: 0, width: 400, height: 200), (1, 1, 1)) }
            let r7563 = try recognize(img, from: "ja").count
            eq(r7563, 0)
            let r3321 = try prepare(img, focus: CGPoint(x: 10, y: 10), from: "ja").count
            eq(r3321, 0)
        }
        await test("a tiny image does not crash") {
            let img = makeImage(2, 2) { ctx in fill(ctx, CGRect(x: 0, y: 0, width: 2, height: 2), (0, 0, 0)) }
            _ = try? recognize(img, from: "ja")
        }
        await test("with a focus the block nearest to it comes first") {
            let img = textImage(1000, 600, [("設定を開く", 60, 40, 48), ("言語を選択", 60, 480, 48)])
            let lines = try recognize(img, from: "ja")
            guard lines.filter({ $0.text.contains("設定") || $0.text.contains("言語") }).count == 2 else {
                skip("Vision did not read both Japanese lines: \(lines.map(\.text))"); return
            }
            let top = try prepare(img, focus: CGPoint(x: 100, y: 50), from: "ja")
            let bottom = try prepare(img, focus: CGPoint(x: 100, y: 540), from: "ja")
            check(top.first?.original.contains("設定") == true, "\(top.map(\.original))")
            check(bottom.first?.original.contains("言語") == true, "\(bottom.map(\.original))")
        }
    }
}
