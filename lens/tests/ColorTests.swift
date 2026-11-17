import AppKit

private func close(_ c: SIMD3<Double>, _ r: Double, _ g: Double, _ b: Double, tol: Double = 0.02) -> Bool {
    abs(c.x - r) <= tol && abs(c.y - g) <= tol && abs(c.z - b) <= tol
}

func colorTests() async {
    await suite("luminance") {
        await test("anchors and weights") {
            near(luminance(SIMD3(0, 0, 0)), 0)
            near(luminance(SIMD3(1, 1, 1)), 1)
            near(luminance(SIMD3(1, 0, 0)), 0.2126)
            near(luminance(SIMD3(0, 1, 0)), 0.7152)
            near(luminance(SIMD3(0, 0, 1)), 0.0722)
        }
        await test("monotonic in each channel") {
            check(luminance(SIMD3(0.5, 0.5, 0.5)) < luminance(SIMD3(0.6, 0.5, 0.5)))
            check(luminance(SIMD3(0.5, 0.5, 0.5)) < luminance(SIMD3(0.5, 0.6, 0.5)))
            check(luminance(SIMD3(0.5, 0.5, 0.5)) < luminance(SIMD3(0.5, 0.5, 0.6)))
        }
    }

    await suite("Pixels") {
        await test("reads colors at top-left-origin coordinates") {
            let px = pixels(10, 10, bg: (1, 1, 1)) { ctx in
                fill(ctx, CGRect(x: 0, y: 0, width: 5, height: 5), (1, 0, 0))
                fill(ctx, CGRect(x: 5, y: 5, width: 5, height: 5), (0, 0, 1))
            }
            check(close(px.at(1, 1), 1, 0, 0)); check(close(px.at(8, 8), 0, 0, 1))
            check(close(px.at(8, 1), 1, 1, 1)); check(close(px.at(1, 8), 1, 1, 1))
        }
        await test("coordinates outside the image clamp to the edge") {
            let px = pixels(10, 10, bg: (1, 1, 1)) { ctx in fill(ctx, CGRect(x: 0, y: 0, width: 1, height: 1), (1, 0, 0)) }
            check(close(px.at(-50, -50), 1, 0, 0)); check(close(px.at(500, 500), 1, 1, 1))
            check(close(px.at(0, 0), 1, 0, 0))
        }
        await test("size") {
            let px = pixels(7, 3, bg: (0, 0, 0))
            eq(px.w, 7); eq(px.h, 3); eq(px.data.count, 7 * 3 * 4)
        }
    }

    await suite("sampleColors") {
        await test("black text on white") {
            let px = pixels(300, 100, bg: (1, 1, 1)) { ctx in fill(ctx, CGRect(x: 60, y: 40, width: 120, height: 20), (0, 0, 0)) }
            let c = sampleColors(CGRect(x: 50, y: 30, width: 140, height: 40), px)
            check(close(c.bg, 1, 1, 1), "bg \(c.bg)"); check(close(c.fg, 0, 0, 0), "fg \(c.fg)")
        }
        await test("white text on a dark background") {
            let px = pixels(300, 100, bg: (0.1, 0.1, 0.12)) { ctx in fill(ctx, CGRect(x: 60, y: 40, width: 120, height: 20), (1, 1, 1)) }
            let c = sampleColors(CGRect(x: 50, y: 30, width: 140, height: 40), px)
            check(close(c.bg, 0.1, 0.1, 0.12), "bg \(c.bg)"); check(close(c.fg, 1, 1, 1), "fg \(c.fg)")
        }
        await test("colored text keeps its color when contrast is enough") {
            let px = pixels(300, 100, bg: (1, 1, 0.9)) { ctx in fill(ctx, CGRect(x: 60, y: 40, width: 120, height: 20), (0.7, 0, 0)) }
            let c = sampleColors(CGRect(x: 50, y: 30, width: 140, height: 40), px)
            check(close(c.fg, 0.7, 0, 0), "fg \(c.fg)")
        }
        await test("text with too little contrast falls back to black on light") {
            let px = pixels(300, 100, bg: (1, 1, 1)) { ctx in fill(ctx, CGRect(x: 60, y: 40, width: 120, height: 20), (0.8, 0.8, 0.8)) }
            let c = sampleColors(CGRect(x: 50, y: 30, width: 140, height: 40), px)
            check(close(c.fg, 0, 0, 0), "fg \(c.fg)")
        }
        await test("text with too little contrast falls back to white on dark") {
            let px = pixels(300, 100, bg: (0.2, 0.2, 0.2)) { ctx in fill(ctx, CGRect(x: 60, y: 40, width: 120, height: 20), (0.3, 0.3, 0.3)) }
            let c = sampleColors(CGRect(x: 50, y: 30, width: 140, height: 40), px)
            check(close(c.fg, 1, 1, 1), "fg \(c.fg)")
        }
        await test("a uniform dark-ish area has no text and takes white") {
            let px = pixels(300, 100, bg: (0.9, 0.2, 0.2))
            let c = sampleColors(CGRect(x: 50, y: 30, width: 140, height: 40), px)
            check(close(c.bg, 0.9, 0.2, 0.2), "bg \(c.bg)"); check(close(c.fg, 1, 1, 1), "fg \(c.fg)")
        }
        await test("the background is the median of the ring, so neighbouring ink is outvoted") {
            let px = pixels(300, 100, bg: (1, 1, 1)) { ctx in
                fill(ctx, CGRect(x: 60, y: 40, width: 120, height: 20), (0, 0, 0))
                fill(ctx, CGRect(x: 40, y: 0, width: 8, height: 100), (0, 0, 0))
            }
            let c = sampleColors(CGRect(x: 50, y: 30, width: 140, height: 40), px)
            check(close(c.bg, 1, 1, 1), "bg \(c.bg)")
        }
        await test("a rect touching the image edge or partly outside stays finite") {
            let px = pixels(100, 50, bg: (1, 1, 1)) { ctx in fill(ctx, CGRect(x: 0, y: 0, width: 30, height: 10), (0, 0, 0)) }
            for r in [CGRect(x: 0, y: 0, width: 40, height: 15), CGRect(x: 80, y: 40, width: 60, height: 30),
                      CGRect(x: -20, y: -20, width: 40, height: 40), CGRect(x: 500, y: 500, width: 30, height: 10)] {
                let c = sampleColors(r, px)
                check(finite(c.bg) && finite(c.fg), "\(r)")
            }
        }
        await test("a very small rect keeps colors finite") {
            let px = pixels(100, 50, bg: (1, 1, 1)) { ctx in fill(ctx, CGRect(x: 10, y: 10, width: 30, height: 10), (0, 0, 0)) }
            for r in [CGRect(x: 10, y: 10.2, width: 50, height: 0.5), CGRect(x: 10, y: 10, width: 0, height: 0),
                      CGRect(x: 12.4, y: 12.4, width: 0.3, height: 0.3)] {
                let c = sampleColors(r, px)
                check(finite(c.bg) && finite(c.fg), "\(r): bg \(c.bg) fg \(c.fg)")
            }
        }
        await test("a huge rect on a large image is sampled, not scanned") {
            let px = pixels(3000, 2000, bg: (1, 1, 1)) { ctx in fill(ctx, CGRect(x: 100, y: 100, width: 2000, height: 40), (0, 0, 0)) }
            let t0 = Date()
            let c = sampleColors(CGRect(x: 90, y: 90, width: 2800, height: 1800), px)
            check(finite(c.bg) && finite(c.fg))
            check(Date().timeIntervalSince(t0) < 2)
        }
        await test("nsColor round trip") {
            let c = nsColor(SIMD3(0.25, 0.5, 0.75)).usingColorSpace(.sRGB)!
            near(Double(c.redComponent), 0.25, 1e-4); near(Double(c.greenComponent), 0.5, 1e-4)
            near(Double(c.blueComponent), 0.75, 1e-4); near(Double(c.alphaComponent), 1)
        }
    }
}
