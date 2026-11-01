import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// Maps between screenshot pixels (what the model sees) and global screen points (what events use).
struct Geometry {
    var rect: CGRect
    var pixelSize: CGSize
    var pid: pid_t?

    var pointsPerPixel: CGFloat { rect.width / max(pixelSize.width, 1) }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * pointsPerPixel, y: rect.minY + p.y * pointsPerPixel)
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / pointsPerPixel, y: (p.y - rect.minY) / pointsPerPixel)
    }
}

enum Capture {
    static let defaultMaxSize = 1280

    static func displayID(containing p: CGPoint) -> CGDirectDisplayID {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 { return id }
        return CGMainDisplayID()
    }

    static func displays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let active = Array(ids.prefix(Int(count)))
        let main = CGMainDisplayID()
        return [main] + active.filter { $0 != main }
    }

    static func backingScale(_ id: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    /// The coordinate space a capture of `rect` would have, without capturing.
    static func geometry(for rect: CGRect, maxSize: Int?) throws -> (Geometry, CGDirectDisplayID) {
        let id = displayID(containing: CGPoint(x: rect.midX, y: rect.midY))
        let clipped = rect.intersection(CGDisplayBounds(id))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else {
            throw ToolError("The target window is off-screen.")
        }
        let scale = backingScale(id)
        let long = max(clipped.width, clipped.height)
        var k = scale
        if let maxSize, long * scale > CGFloat(maxSize) { k = CGFloat(maxSize) / long }
        let size = CGSize(width: (clipped.width * k).rounded(), height: (clipped.height * k).rounded())
        return (Geometry(rect: clipped, pixelSize: size, pid: nil), id)
    }

    /// Captures what is on screen inside `rect`, so sheets, popovers, and menus on top are included.
    static func capture(rect: CGRect, maxSize: Int?) throws -> (CGImage, Geometry) {
        var (g, id) = try geometry(for: rect, maxSize: maxSize)
        let content: SCShareableContent = try blocking { done in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { done($0, $1) }
        }
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw ToolError("Display \(id) is not available for capture.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = g.rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(g.pixelSize.width)
        config.height = Int(g.pixelSize.height)
        config.showsCursor = false
        let image: CGImage = try blocking { done in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { done($0, $1) }
        }
        g.pixelSize = CGSize(width: image.width, height: image.height)
        return (image, g)
    }

    static func jpeg(_ image: CGImage) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @discardableResult
    static func save(_ data: Data, name: String) -> URL {
        Paths.ensure()
        let url = Paths.caches.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    /// Bridges ScreenCaptureKit's completion handlers onto the calling thread.
    static func blocking<T>(_ body: (@escaping (T?, Error?) -> Void) -> Void) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: T?
        var failure: Error?
        body { value, error in
            result = value
            failure = error
            sem.signal()
        }
        if sem.wait(timeout: .now() + 8) == .timedOut { throw ToolError("Timed out waiting for screen capture.") }
        if let result { return result }
        throw ToolError("Screen capture failed: \(failure?.localizedDescription ?? "unknown error"). Check Screen Recording permission for the app running the agent.")
    }
}

struct TextHit {
    let line: String
    let rect: CGRect // global screen points
    let exact: Bool
}

enum OCR {
    /// Finds `needle` in the image (all text when empty). `rect` is the screen area the image shows.
    static func find(_ needle: String, in image: CGImage, rect: CGRect) throws -> [TextHit] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        func toScreen(_ b: CGRect) -> CGRect {
            CGRect(x: rect.minX + b.minX * rect.width,
                   y: rect.minY + (1 - b.maxY) * rect.height,
                   width: b.width * rect.width,
                   height: b.height * rect.height)
        }

        let n = needle.trimmingCharacters(in: .whitespaces)
        var hits: [TextHit] = []
        for obs in request.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let s = candidate.string
            if n.isEmpty {
                hits.append(TextHit(line: s, rect: toScreen(obs.boundingBox), exact: false))
                continue
            }
            var start = s.startIndex
            while start < s.endIndex,
                  let r = s.range(of: n, options: [.caseInsensitive, .diacriticInsensitive], range: start..<s.endIndex) {
                let box = (try? candidate.boundingBox(for: r))?.boundingBox ?? obs.boundingBox
                let exact = s.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(n) == .orderedSame
                hits.append(TextHit(line: s, rect: toScreen(box), exact: exact))
                start = r.upperBound
            }
        }
        return hits.sorted { a, b in
            if a.exact != b.exact { return a.exact }
            return (a.rect.minY, a.rect.minX) < (b.rect.minY, b.rect.minX)
        }
    }
}
