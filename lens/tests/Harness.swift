import AppKit

var passedTests = 0, failedTests = 0, skippedTests = 0, assertionCount = 0
var failedNames: [String] = []
var suiteName = ""
var testName = ""
var currentFailed = false
var currentSkipped = false

func shortFile(_ f: StaticString) -> String { (String(describing: f) as NSString).lastPathComponent }

func record(_ ok: Bool, _ msg: @autoclosure () -> String, _ file: StaticString, _ line: UInt) {
    assertionCount += 1
    if !ok {
        currentFailed = true
        print("    FAIL \(shortFile(file)):\(line): \(msg())")
    }
}

func check(_ c: @autoclosure () -> Bool, _ msg: @autoclosure () -> String = "check failed",
           file: StaticString = #filePath, line: UInt = #line) {
    record(c(), msg(), file, line)
}

func eq<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ msg: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    let x = a(), y = b()
    record(x == y, "\(x) != \(y) \(msg)", file, line)
}

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6, _ msg: String = "",
          file: StaticString = #filePath, line: UInt = #line) {
    record(abs(a - b) <= tol, "\(a) is not within \(tol) of \(b) \(msg)", file, line)
}

func finite(_ c: SIMD3<Double>) -> Bool { c.x.isFinite && c.y.isFinite && c.z.isFinite }

/// Runs `body` and returns the error it threw, recording a failure if it did not throw.
func thrown(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> Error? {
    do { try await body() } catch { return error }
    record(false, "expected an error", file, line)
    return nil
}

func skip(_ reason: String) { currentSkipped = true; print("    skip: \(reason)") }

func suite(_ name: String, _ body: () async -> Void) async {
    suiteName = name
    print("== \(name)")
    await body()
}

func test(_ name: String, _ body: () async throws -> Void) async {
    testName = "\(suiteName): \(name)"
    currentFailed = false
    currentSkipped = false
    do { try await body() } catch { currentFailed = true; print("    FAIL threw \(error)") }
    if currentFailed {
        failedTests += 1; failedNames.append(testName); print("  FAIL \(name)")
    } else if currentSkipped {
        skippedTests += 1; print("  SKIP \(name)")
    } else {
        passedTests += 1
    }
}

func printSummary() {
    print("")
    for n in failedNames { print("failed: \(n)") }
    print("swift tests: \(passedTests) passed, \(failedTests) failed, \(skippedTests) skipped (\(assertionCount) assertions)")
}

func L(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, conf: Float = 1) -> Line {
    Line(rect: CGRect(x: x, y: y, width: w, height: h), text: text, confidence: conf)
}

/// A bitmap drawn in top-left-origin coordinates.
func makeImage(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

func fill(_ ctx: CGContext, _ r: CGRect, _ rgb: (Double, Double, Double)) {
    ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
    ctx.fill(r)
}

func pixels(_ w: Int, _ h: Int, bg: (Double, Double, Double), _ draw: (CGContext) -> Void = { _ in }) -> Pixels {
    Pixels(makeImage(w, h) { ctx in fill(ctx, CGRect(x: 0, y: 0, width: w, height: h), bg); draw(ctx) })
}

func jsonBody(_ req: URLRequest) -> Any {
    try! JSONSerialization.jsonObject(with: req.httpBody ?? Data())
}

func httpResponse(_ code: Int) -> URLResponse {
    HTTPURLResponse(url: googleURL, statusCode: code, httpVersion: nil, headerFields: nil)!
}

func jsonData(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
