// lens: translate everything on screen in place, like Google Translate's screen translation on
// Android. Press the hotkey: the display under the pointer is captured, text is read with Vision
// OCR, translated with Google Translate (Chrome's page-translation endpoint; Apple's on-device
// Translation framework as the fallback), and painted over the original text in a full-screen
// overlay.
//
//   Lens                     resident agent (what launchd runs): listens for the hotkey
//   Lens --toggle            show or dismiss the overlay in the running agent
//   Lens --file IMG [--out PNG]
//                            run OCR and translation on an image, print the blocks, and with
//                            --out write the translated rendering as a PNG (for testing)
//
// Overlay: Esc, click, scroll, or the hotkey again dismisses; hold Option to see the original;
// Cmd-C copies all translated text.
//
// Environment: LENS_FROM (default ja), LENS_TO (default en), LENS_HOTKEY (default double:rcmd,
// double-tap right Command; or a chord such as ctrl+opt+t),
// LENS_ENGINE (google, the default, or apple for on-device only).

import AppKit
import Carbon.HIToolbox
import NaturalLanguage
import ScreenCaptureKit
import Translation
import Vision

let env = ProcessInfo.processInfo.environment
let fromLang = env["LENS_FROM"] ?? "ja"
let toLang = env["LENS_TO"] ?? "en"
let hotkeySpec = env["LENS_HOTKEY"] ?? "double:rcmd"
let engine = env["LENS_ENGINE"] ?? "google"  // google | apple
let toggleNote = Notification.Name("com.anurag.lens.toggle")

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write("\(f.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

struct LensError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

// MARK: - OCR

/// One OCR line, in image pixels with a top-left origin.
struct Line {
    var rect: CGRect
    var text: String
    var confidence: Float
}

func visionLanguages() -> [String] {
    let map = ["ja": "ja-JP", "zh": "zh-Hans", "ko": "ko-KR", "en": "en-US", "de": "de-DE",
               "fr": "fr-FR", "es": "es-ES", "it": "it-IT", "pt": "pt-BR", "ru": "ru-RU"]
    var langs = [map[fromLang] ?? fromLang]
    if fromLang != "en" { langs.append("en-US") }
    return langs
}

func recognize(_ img: CGImage) throws -> [Line] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = visionLanguages()
    req.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: img).perform([req])
    let w = CGFloat(img.width), h = CGFloat(img.height)
    return (req.results ?? []).compactMap { o in
        guard let c = o.topCandidates(1).first else { return nil }
        let b = o.boundingBox
        let r = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        return Line(rect: r, text: c.string, confidence: c.confidence)
    }
}

// MARK: - Paragraphs

/// Kana, kanji and hangul letters (not CJK punctuation such as ・ or ー).
func isCJKLetter(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x3041...0x3096, 0x30A1...0x30FA, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF66...0xFF9D, 0xAC00...0xD7AF: return true
    default: return false
    }
}

func isCJK(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF66...0xFF9F, 0xAC00...0xD7AF: return true
    default: return false
    }
}

func endsSentence(_ s: String) -> Bool {
    guard let c = s.trimmingCharacters(in: .whitespaces).last else { return true }
    return "。．.!?！？:：".contains(c)
}

func startsBullet(_ s: String) -> Bool {
    guard let c = s.trimmingCharacters(in: .whitespaces).first else { return false }
    return "•・●○■□◆◇▪︎-–*※★→".contains(c)
}

/// Groups OCR lines into paragraphs: lines stacked closely, left-aligned and of similar height
/// form a block, and a block splits wherever a line stops short of the block's right edge
/// (it did not wrap) or ends a sentence.
func paragraphs(_ lines: [Line]) -> [[Line]] {
    var blocks: [[Line]] = []
    for l in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
        let h = l.rect.height
        if let i = blocks.lastIndex(where: { b in
            let p = b.last!
            let gap = l.rect.minY - p.rect.maxY
            let hmax = max(h, p.rect.height)
            return gap > -0.3 * hmax && gap < 0.8 * hmax
                && abs(l.rect.minX - p.rect.minX) < 1.2 * hmax
                && abs(h - p.rect.height) < 0.35 * hmax
        }) {
            blocks[i].append(l)
        } else {
            blocks.append([l])
        }
    }
    var out: [[Line]] = []
    for b in blocks {
        let right = b.map { $0.rect.maxX }.max()!
        let left = b.map { $0.rect.minX }.min()!
        var cur: [Line] = []
        for l in b {
            if let p = cur.last {
                let h = p.rect.height
                let wide = right - left > 20 * h
                let wrapped = wide && p.rect.maxX >= right - 2.5 * h && !endsSentence(p.text) && !startsBullet(l.text)
                if !wrapped { out.append(cur); cur = [] }
            }
            cur.append(l)
        }
        out.append(cur)
    }
    return out
}

func joinLines(_ lines: [Line]) -> String {
    var s = ""
    for l in lines {
        let t = l.text.trimmingCharacters(in: .whitespaces)
        if let a = s.unicodeScalars.last, let b = t.unicodeScalars.first, !(isCJK(a) && isCJK(b)) {
            s += " "
        }
        s += t
    }
    return s
}

func needsTranslation(_ s: String) -> Bool {
    guard s.count >= 2 else { return false }
    switch fromLang {
    case "ja", "zh", "ko":
        // One stray CJK glyph next to Latin text is usually an icon or emoji misread by OCR.
        let cjk = s.unicodeScalars.filter(isCJKLetter).count
        let latin = s.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        return cjk >= 2 || (cjk == 1 && latin == 0)
    default:
        let r = NLLanguageRecognizer(); r.processString(s)
        return r.dominantLanguage?.rawValue.hasPrefix(fromLang) ?? false
    }
}

// MARK: - Colors

/// RGBA8 copy of the captured image for sampling background and text colors.
final class Pixels {
    let w: Int, h: Int
    var data: [UInt8]

    init(_ img: CGImage) {
        w = img.width; h = img.height
        data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// (r, g, b) in 0...1 at a top-left-origin pixel.
    func at(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let cx = min(max(x, 0), w - 1), cy = min(max(y, 0), h - 1)
        let i = (cy * w + cx) * 4
        return SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])) / 255
    }
}

func luminance(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

func nsColor(_ c: SIMD3<Double>) -> NSColor {
    NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
}

/// Background = median of a ring just outside the rect; text = mean of the pixels inside that
/// differ most from it, falling back to black or white when that has too little contrast.
func sampleColors(_ r: CGRect, _ px: Pixels) -> (bg: SIMD3<Double>, fg: SIMD3<Double>) {
    let ring = r.insetBy(dx: -3, dy: -3)
    var border: [SIMD3<Double>] = []
    let step = max(1, Int(ring.width / 60))
    for x in stride(from: Int(ring.minX), through: Int(ring.maxX), by: step) {
        border.append(px.at(x, Int(ring.minY))); border.append(px.at(x, Int(ring.maxY)))
    }
    for y in stride(from: Int(ring.minY), through: Int(ring.maxY), by: max(1, Int(ring.height / 20))) {
        border.append(px.at(Int(ring.minX), y)); border.append(px.at(Int(ring.maxX), y))
    }
    func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
    let bg = SIMD3(median(border.map(\.x)), median(border.map(\.y)), median(border.map(\.z)))

    var inside: [(Double, SIMD3<Double>)] = []
    let sx = max(1, Int(r.width / 120)), sy = max(1, Int(r.height / 24))
    for y in stride(from: Int(r.minY), to: Int(r.maxY), by: sy) {
        for x in stride(from: Int(r.minX), to: Int(r.maxX), by: sx) {
            let c = px.at(x, y)
            let d = c - bg
            inside.append(((d * d).sum(), c))
        }
    }
    inside.sort { $0.0 > $1.0 }
    let top = inside.prefix(max(1, inside.count / 12))
    var fg = top.reduce(SIMD3<Double>(0, 0, 0)) { $0 + $1.1 } / Double(top.count)
    if abs(luminance(fg) - luminance(bg)) < 0.35 {
        fg = luminance(bg) > 0.5 ? SIMD3(0, 0, 0) : SIMD3(1, 1, 1)
    }
    return (bg, fg)
}

// MARK: - Translation

struct Block {
    var area: CGRect          // original text, image pixels, top-left origin
    var rect: CGRect = .zero  // painted box after fitting
    var lineHeight: CGFloat   // pixels
    var confidence: Float
    var original: String
    var translated: String? = nil
    var bg: NSColor
    var fg: NSColor
    var fontPx: CGFloat = 0
}

/// OCR, paragraphs and colors for everything that needs translating, nearest to `focus`
/// (image pixels) first so the text under the pointer is translated first.
func prepare(_ img: CGImage, focus: CGPoint?) throws -> [Block] {
    let px = Pixels(img)
    var blocks: [Block] = []
    for lines in paragraphs(try recognize(img)) {
        let text = joinLines(lines)
        guard needsTranslation(text) else { continue }
        let area = lines.map(\.rect).reduce(lines[0].rect) { $0.union($1) }
        let heights = lines.map { $0.rect.height }.sorted()
        let (bg, fg) = sampleColors(area, px)
        blocks.append(Block(area: area, lineHeight: heights[heights.count / 2],
                            confidence: lines.map(\.confidence).min() ?? 0,
                            original: text, bg: nsColor(bg), fg: nsColor(fg)))
    }
    if let f = focus {
        func dist(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - f.x, 0, f.x - r.maxX), dy = max(r.minY - f.y, 0, f.y - r.maxY)
            return dx * dx + 4 * dy * dy  // rows near the pointer before columns beside it
        }
        blocks.sort { dist($0.area) < dist($1.area) }
    }
    return blocks
}

var session: TranslationSession?
var cache: [String: String] = [:]

@MainActor func translator() async throws -> TranslationSession {
    if let session { return session }
    let st = await LanguageAvailability().status(from: Locale.Language(identifier: fromLang),
                                                 to: Locale.Language(identifier: toLang))
    guard st == .installed else {
        throw LensError("\(fromLang)→\(toLang) is not downloaded: System Settings > General > Language & Region > Translation Languages")
    }
    let s = TranslationSession(installedSource: Locale.Language(identifier: fromLang),
                               target: Locale.Language(identifier: toLang))
    session = s
    return s
}

// Google: the endpoint Chrome's built-in page translation uses. One request carries the whole
// screen (about 0.3 s) and takes HTML, so text is escaped going in and unescaped coming back.
let googleURL = URL(string: "https://translate-pa.googleapis.com/v1/translateHtml")!
let googleKey = "AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520"  // Chrome's public translate key

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func htmlUnescape(_ s: String) -> String {
    guard s.contains("&") else { return s }
    let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
    var out = s
    for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
    let re = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
    for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
        let hex = (out as NSString).substring(with: m.range(at: 1)) == "x"
        let num = (out as NSString).substring(with: m.range(at: 2))
        if let v = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(v),
           let r = Range(m.range, in: out) { out.replaceSubrange(r, with: String(u)) }
    }
    return out.replacingOccurrences(of: "&amp;", with: "&")
}

func googleTranslate(_ texts: [String]) async throws -> [String] {
    var out: [String] = []
    var start = 0
    while start < texts.count {  // chunks of at most 100 texts / ~8000 characters
        var end = start, chars = 0
        while end < texts.count && end - start < 100 && (end == start || chars + texts[end].count < 8000) {
            chars += texts[end].count; end += 1
        }
        let chunk = Array(texts[start..<end])
        var req = URLRequest(url: googleURL, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(googleKey, forHTTPHeaderField: "X-Goog-API-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: [[chunk.map(htmlEscape), fromLang, toLang], "te_lib"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              let list = json.first as? [String], list.count == chunk.count else {
            throw LensError("Google Translate failed (HTTP \(code)): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        out += list.map(htmlUnescape)
        start = end
    }
    return out
}

/// Calls `each(index, translation)` as results arrive; cached texts come back immediately.
/// Google by default (LENS_ENGINE=apple for on-device only); if Google fails, falls back to
/// Apple's on-device translation, which streams at roughly 0.7 s per sentence.
@MainActor func translateStreaming(_ blocks: [Block], _ each: (Int, String) -> Void) async throws {
    if cache.count > 5000 { cache.removeAll() }
    var pending: [Int] = []
    for (i, b) in blocks.enumerated() {
        if let c = cache[b.original] { each(i, c) } else { pending.append(i) }
    }
    guard !pending.isEmpty else { return }
    if engine == "google" {
        do {
            let out = try await googleTranslate(pending.map { blocks[$0].original })
            try Task.checkCancellation()
            for (i, t) in zip(pending, out) { cache[blocks[i].original] = t; each(i, t) }
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("\(error); falling back to on-device translation")
        }
    }
    let reqs = pending.map { TranslationSession.Request(sourceText: blocks[$0].original, clientIdentifier: String($0)) }
    for try await r in try await translator().translate(batch: reqs) {
        try Task.checkCancellation()
        cache[r.sourceText] = r.targetText
        if let id = r.clientIdentifier, let i = Int(id) { each(i, r.targetText) }
    }
}

func attributed(_ s: String, _ fontPx: CGFloat, _ color: NSColor) -> NSAttributedString {
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byWordWrapping
    p.lineHeightMultiple = 0.95
    return NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: fontPx), .foregroundColor: color, .paragraphStyle: p,
    ])
}

let pad: CGFloat = 0.12  // of the line height, around each block

/// Fits the translation into the original text's area: font from 85% down to 70% of the
/// original line height; if it still overflows, a single-line box widens (up to 2.5x, never past
/// `maxRight` or into other text on the same row), then the font goes down to 60%, then the box
/// grows downward.
func fit(_ b: inout Block, maxRight: CGFloat, others: [CGRect]) {
    let text = b.translated ?? ""
    let padPx = b.lineHeight * pad
    var box = b.area.insetBy(dx: -padPx, dy: -padPx)
    func needed(_ s: CGFloat, _ w: CGFloat) -> CGSize {
        attributed(text, s, .black).boundingRect(
            with: CGSize(width: w - 2 * padPx, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    }
    func fits(_ s: CGFloat) -> Bool { needed(s, box.width).height <= box.height - 2 * padPx }
    var size = b.lineHeight * 0.85
    while size > b.lineHeight * 0.7 && !fits(size) { size -= 0.5 }
    if !fits(size) {
        if b.area.height < 1.6 * b.lineHeight {
            var right = min(box.minX + box.width * 2.5, maxRight)
            for o in others where o.minX > b.area.maxX - 1 && o.minY < b.area.maxY && o.maxY > b.area.minY {
                right = min(right, o.minX - padPx)
            }
            let oneLine = needed(size, .greatestFiniteMagnitude).width + 2 * padPx + 2
            box.size.width = min(max(box.width, oneLine), max(box.width, right - box.minX))
        }
        while size > b.lineHeight * 0.6 && !fits(size) { size -= 0.5 }
        if !fits(size) { box.size.height = needed(size, box.width).height + 2 * padPx }
    }
    b.rect = box
    b.fontPx = size
}

/// Draws translated blocks into the current (flipped) graphics context; k = units per image pixel.
func drawBlocks(_ blocks: [Block], k: CGFloat) {
    for b in blocks.reversed() {  // nearest-first order, so the pointer's block ends up on top
        guard let t = b.translated, t != b.original else { continue }
        let r = CGRect(x: b.rect.minX * k, y: b.rect.minY * k, width: b.rect.width * k, height: b.rect.height * k)
        b.bg.setFill()
        NSBezierPath(roundedRect: r, xRadius: 3 * k, yRadius: 3 * k).fill()
        let padPx = b.lineHeight * pad * k
        attributed(t, b.fontPx * k, b.fg).draw(
            with: r.insetBy(dx: padPx, dy: padPx), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

// MARK: - Overlay

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    var blocks: [Block] = [] { didSet { needsDisplay = true } }
    var k: CGFloat = 0.5
    var showOriginal = false { didSet { needsDisplay = true } }
    var onDismiss: () -> Void = {}

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.06).setFill()  // also makes the whole screen catch clicks
        bounds.fill()
        if !showOriginal { drawBlocks(blocks, k: k) }
    }

    override func mouseDown(with event: NSEvent) { onDismiss() }
    override func rightMouseDown(with event: NSEvent) { onDismiss() }
    override func scrollWheel(with event: NSEvent) { onDismiss() }
    override func flagsChanged(with event: NSEvent) { showOriginal = event.modifierFlags.contains(.option) }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            let text = blocks.sorted { ($0.area.minY, $0.area.minX) < ($1.area.minY, $1.area.minX) }
                .compactMap(\.translated).joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        onDismiss()
    }
}

/// A small pill at the top of the screen for progress and errors.
final class HUD {
    let panel: NSPanel
    let label = NSTextField(labelWithString: "")
    var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        v.layer?.cornerRadius = 15
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        panel.contentView = v
    }

    func show(_ text: String, on screen: NSScreen, for seconds: TimeInterval? = nil) {
        hideWork?.cancel()
        label.stringValue = text
        let w = label.intrinsicContentSize.width + 36
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - 46, width: w, height: 30), display: true)
        panel.orderFrontRegardless()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() { hideWork?.cancel(); panel.orderOut(nil) }
}

@MainActor final class Lens {
    var overlay: OverlayPanel?
    var task: Task<Void, Never>?
    var previousApp: NSRunningApplication?
    let hud = HUD()

    func toggle() {
        if overlay != nil || task != nil { dismiss(); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        task = Task { @MainActor in
            defer { self.task = nil }
            do {
                let img = try await self.capture(screen)
                try Task.checkCancellation()
                let k = screen.frame.width / CGFloat(img.width)
                let focus = CGPoint(x: (mouse.x - screen.frame.minX) / k, y: (screen.frame.maxY - mouse.y) / k)
                let view = self.present(on: screen, k: k)
                self.hud.show("Reading…", on: screen)
                let blocks = try await Task.detached { try prepare(img, focus: focus) }.value
                try Task.checkCancellation()
                if blocks.isEmpty {
                    self.dismiss()
                    let name = Locale.current.localizedString(forLanguageCode: fromLang) ?? fromLang
                    self.hud.show("No \(name) text on screen", on: screen, for: 1.8)
                    return
                }
                view.blocks = blocks
                let areas = blocks.map(\.area)
                var done = 0
                self.hud.show("Translating 0/\(blocks.count)", on: screen)
                let t0 = Date()
                try await translateStreaming(blocks) { i, t in
                    view.blocks[i].translated = t
                    fit(&view.blocks[i], maxRight: CGFloat(img.width), others: areas)
                    done += 1
                    self.hud.show("Translating \(done)/\(blocks.count)", on: screen)
                }
                log(String(format: "%d blocks in %.1fs", blocks.count, Date().timeIntervalSince(t0)))
                self.hud.hide()
            } catch is CancellationError {
            } catch {
                log("error: \(error)")
                self.dismiss()
                self.hud.show("\(error)", on: screen, for: 4)
            }
        }
    }

    func capture(_ screen: NSScreen) async throws -> CGImage {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw LensError("Allow Screen Recording for Lens in System Settings > Privacy & Security")
        }
        let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == did }) else {
            throw LensError("Display not found")
        }
        let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
        cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    func present(on screen: NSScreen, k: CGFloat) -> OverlayView {
        let p = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.setFrame(screen.frame, display: false)
        let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.k = k
        v.onDismiss = { [weak self] in self?.dismiss() }
        p.contentView = v
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(v)
        overlay = p
        return v
    }

    func dismiss() {
        task?.cancel()
        task = nil
        hud.hide()
        guard let p = overlay else { return }
        overlay = nil
        p.orderOut(nil)
        if let app = previousApp, app.processIdentifier != getpid() { app.activate() }
        previousApp = nil
    }
}

// MARK: - Hotkey

func parseHotkey(_ spec: String) -> (key: UInt32, mods: UInt32)? {
    let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "/": kVK_ANSI_Slash, ".": kVK_ANSI_Period, ",": kVK_ANSI_Comma,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
    var mods = 0, key: Int?
    for part in spec.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "ctrl", "control": mods |= controlKey
        case "opt", "option", "alt": mods |= optionKey
        case "cmd", "command": mods |= cmdKey
        case "shift": mods |= shiftKey
        default: key = keys[part]
        }
    }
    guard let key else { return nil }
    return (UInt32(key), UInt32(mods))
}

let lensApp = Lens()
var hotKeyRef: EventHotKeyRef?

func fire() { DispatchQueue.main.async { MainActor.assumeIsolated { lensApp.toggle() } } }

func registerHotkey() {
    if hotkeySpec.hasPrefix("double:") { startDoubleTap(); return }
    guard let hk = parseHotkey(hotkeySpec) else { log("bad LENS_HOTKEY: \(hotkeySpec)"); return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in fire(); return noErr }, 1, &spec, nil, nil)
    let st = RegisterEventHotKey(hk.key, hk.mods, EventHotKeyID(signature: 0x4C454E53, id: 1),
                                 GetApplicationEventTarget(), 0, &hotKeyRef)
    log(st == noErr ? "hotkey \(hotkeySpec), \(fromLang)→\(toLang) via \(engine)" : "hotkey \(hotkeySpec) is taken (\(st))")
}

// Double-tapping one modifier key (LENS_HOTKEY=double:rcmd and so on), seen through a listen-only
// event tap, which needs Input Monitoring. A tap is a press and release with no other key or
// modifier in between, so shortcuts like right-cmd+C never count.

/// Key code and device-dependent flag bit (IOLLEvent.h NX_DEVICE*KEYMASK) for each modifier.
let modifierKeys: [String: (code: Int64, mask: UInt64)] = [
    "rcmd": (54, 0x10), "lcmd": (55, 0x08), "rshift": (60, 0x04), "lshift": (56, 0x02),
    "ropt": (61, 0x40), "lopt": (58, 0x20), "rctrl": (62, 0x2000), "lctrl": (59, 0x01),
]
let tapWindow: TimeInterval = 0.35  // max hold for a tap, and max gap between the two taps

final class DoubleTap {
    let code: Int64, mask: UInt64
    var downAt: TimeInterval?        // our key went down cleanly at this time
    var lastTapAt: TimeInterval = 0  // end of the previous clean tap
    var tap: CFMachPort?

    init(code: Int64, mask: UInt64) { self.code = code; self.mask = mask }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { downAt = nil; lastTapAt = 0; return }  // any other key
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        guard keycode == code else { downAt = nil; lastTapAt = 0; return }  // another modifier
        if flags & mask != 0 {
            // Pressed: only clean if no other modifier is held.
            let others = flags & UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
                | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue) & ~modifierFamily(flags)
            downAt = others == 0 ? now : nil
        } else if let d = downAt {
            downAt = nil
            guard now - d < tapWindow else { lastTapAt = 0; return }
            if now - lastTapAt < tapWindow {
                lastTapAt = 0
                fire()
            } else {
                lastTapAt = now
            }
        }
    }

    /// The generic flag of our own key, so holding it is not counted as "another modifier".
    func modifierFamily(_ flags: UInt64) -> UInt64 {
        switch code {
        case 54, 55: return UInt64(CGEventFlags.maskCommand.rawValue)
        case 56, 60: return UInt64(CGEventFlags.maskShift.rawValue)
        case 58, 61: return UInt64(CGEventFlags.maskAlternate.rawValue)
        default: return UInt64(CGEventFlags.maskControl.rawValue)
        }
    }

    /// Creates the tap, retrying every 3 s until Input Monitoring is granted.
    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ctx in
            Unmanaged<DoubleTap>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
            log("waiting for Input Monitoring permission (System Settings > Privacy & Security)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.start() }
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            log("Input Monitoring is off: allow Lens in System Settings > Privacy & Security > Input Monitoring")
        }
        log("hotkey \(hotkeySpec) (double-tap), \(fromLang)→\(toLang) via \(engine)")
    }
}

var doubleTap: DoubleTap?

func startDoubleTap() {
    let name = String(hotkeySpec.dropFirst("double:".count))
    guard let k = modifierKeys[name] else {
        log("bad LENS_HOTKEY \(hotkeySpec): use double: plus one of \(modifierKeys.keys.sorted().joined(separator: ", "))")
        return
    }
    doubleTap = DoubleTap(code: k.code, mask: k.mask)
    doubleTap!.start()
}

// MARK: - Main

let args = CommandLine.arguments

if args.contains("--toggle") {
    DistributedNotificationCenter.default().postNotificationName(toggleNote, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        log("cannot read \(args[i + 1])"); exit(1)
    }
    do {
        let t0 = Date()
        var blocks = try prepare(img, focus: nil)
        let areas = blocks.map(\.area)
        let t1 = Date()
        try await translateStreaming(blocks) { i, t in
            blocks[i].translated = t
            fit(&blocks[i], maxRight: CGFloat(img.width), others: areas)
        }
        log(String(format: "%d blocks: ocr %.2fs, translate %.2fs", blocks.count, t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)))
        for b in blocks {
            print(String(format: "[%d,%d %dx%d %.0fpx conf %.2f] ", Int(b.rect.minX), Int(b.rect.minY), Int(b.rect.width),
                         Int(b.rect.height), b.fontPx, b.confidence) + b.original + "\n    → " + (b.translated ?? "-"))
        }
        if let j = args.firstIndex(of: "--out"), j + 1 < args.count {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: img.width, pixelsHigh: img.height,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!
            ctx.cgContext.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            ctx.cgContext.translateBy(x: 0, y: CGFloat(img.height))
            ctx.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
            drawBlocks(blocks, k: 1)
            NSGraphicsContext.current = nil
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[j + 1]))
        }
    } catch {
        log("error: \(error)"); exit(1)
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
registerHotkey()
DistributedNotificationCenter.default().addObserver(forName: toggleNote, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { lensApp.toggle() }
}
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
app.run()
