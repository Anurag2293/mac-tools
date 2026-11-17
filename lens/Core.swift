// Pure logic of lens: OCR geometry, paragraphs, colors, Google request and response handling,
// translation cache, fitting and the double-tap state machine. No top-level code, so the test
// runner (test.sh) can compile this file on its own.

import AppKit
import Carbon.HIToolbox
import NaturalLanguage
import Vision

struct Config {
    var from: String
    var to: String
    var hotkey: String
    var engine: String  // google | apple

    init(env: [String: String]) {
        from = env["LENS_FROM"] ?? "ja"
        to = env["LENS_TO"] ?? "en"
        hotkey = env["LENS_HOTKEY"] ?? "double:rcmd"
        engine = env["LENS_ENGINE"] ?? "google"
    }
}

var logSink: (String) -> Void = { FileHandle.standardError.write(($0 + "\n").data(using: .utf8)!) }

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    logSink("\(f.string(from: Date())) \(s)")
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

func visionLanguages(from fromLang: String) -> [String] {
    let map = ["ja": "ja-JP", "zh": "zh-Hans", "ko": "ko-KR", "en": "en-US", "de": "de-DE",
               "fr": "fr-FR", "es": "es-ES", "it": "it-IT", "pt": "pt-BR", "ru": "ru-RU"]
    var langs = [map[fromLang] ?? fromLang]
    if fromLang != "en" { langs.append("en-US") }
    return langs
}

/// Vision's normalized, bottom-left-origin box to image pixels with a top-left origin.
func pixelRect(fromVision b: CGRect, width w: CGFloat, height h: CGFloat) -> CGRect {
    CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
}

func recognize(_ img: CGImage, from fromLang: String) throws -> [Line] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = visionLanguages(from: fromLang)
    req.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: img).perform([req])
    let w = CGFloat(img.width), h = CGFloat(img.height)
    return (req.results ?? []).compactMap { o in
        guard let c = o.topCandidates(1).first else { return nil }
        return Line(rect: pixelRect(fromVision: o.boundingBox, width: w, height: h), text: c.string, confidence: c.confidence)
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
    guard let u = s.trimmingCharacters(in: .whitespaces).unicodeScalars.first else { return false }
    return "•・●○■□◆◇\u{25AA}-–*※★→".unicodeScalars.contains(u)
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

func needsTranslation(_ s: String, from fromLang: String) -> Bool {
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
    var fg = top.isEmpty ? bg : top.reduce(SIMD3<Double>(0, 0, 0)) { $0 + $1.1 } / Double(top.count)
    if abs(luminance(fg) - luminance(bg)) < 0.35 {
        fg = luminance(bg) > 0.5 ? SIMD3(0, 0, 0) : SIMD3(1, 1, 1)
    }
    return (bg, fg)
}

// MARK: - Blocks

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

/// Paragraphs and colors for every OCR line group that needs translating.
func makeBlocks(_ lines: [Line], _ px: Pixels, from fromLang: String) -> [Block] {
    var blocks: [Block] = []
    for lines in paragraphs(lines) {
        let text = joinLines(lines)
        guard needsTranslation(text, from: fromLang) else { continue }
        let area = lines.map(\.rect).reduce(lines[0].rect) { $0.union($1) }
        let heights = lines.map { $0.rect.height }.sorted()
        let (bg, fg) = sampleColors(area, px)
        blocks.append(Block(area: area, lineHeight: heights[heights.count / 2],
                            confidence: lines.map(\.confidence).min() ?? 0,
                            original: text, bg: nsColor(bg), fg: nsColor(fg)))
    }
    return blocks
}

/// Nearest to `focus` (image pixels) first, rows near the pointer before columns beside it.
func sortedByFocus(_ blocks: [Block], _ f: CGPoint) -> [Block] {
    func dist(_ r: CGRect) -> CGFloat {
        let dx = max(r.minX - f.x, 0, f.x - r.maxX), dy = max(r.minY - f.y, 0, f.y - r.maxY)
        return dx * dx + 4 * dy * dy
    }
    return blocks.sorted { dist($0.area) < dist($1.area) }
}

/// OCR, paragraphs and colors for everything that needs translating, nearest to `focus`
/// (image pixels) first so the text under the pointer is translated first.
func prepare(_ img: CGImage, focus: CGPoint?, from fromLang: String) throws -> [Block] {
    let blocks = makeBlocks(try recognize(img, from: fromLang), Pixels(img), from: fromLang)
    if let f = focus { return sortedByFocus(blocks, f) }
    return blocks
}

/// The pointer in image pixels: `mouse` is in Cocoa screen coordinates (bottom-left origin),
/// `k` is points per image pixel.
func focusPoint(mouse: CGPoint, screenFrame f: CGRect, k: CGFloat) -> CGPoint {
    CGPoint(x: (mouse.x - f.minX) / k, y: (f.maxY - mouse.y) / k)
}

func copyText(_ blocks: [Block]) -> String {
    blocks.sorted { ($0.area.minY, $0.area.minX) < ($1.area.minY, $1.area.minX) }
        .compactMap(\.translated).joined(separator: "\n\n")
}

// MARK: - Google

// The endpoint Chrome's built-in page translation uses. One request carries the whole screen
// (about 0.3 s) and takes HTML, so text is escaped going in and unescaped coming back.
let googleURL = URL(string: "https://translate-pa.googleapis.com/v1/translateHtml")!
let googleKey = "AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520"  // Chrome's public translate key

typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func htmlUnescape(_ s: String) -> String {
    guard s.contains("&") else { return s }
    let named = ["lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'", "nbsp": " "]
    let re = try! NSRegularExpression(pattern: "&(?:#(x?)([0-9a-fA-F]+)|([a-z]+));")
    let ns = s as NSString
    var out = "", last = 0
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        var decoded: String?
        if m.range(at: 3).location != NSNotFound {
            decoded = named[ns.substring(with: m.range(at: 3))]
        } else if let v = UInt32(ns.substring(with: m.range(at: 2)), radix: m.range(at: 1).length == 1 ? 16 : 10),
                  let u = Unicode.Scalar(v) {
            decoded = String(u)
        }
        out += decoded ?? ns.substring(with: m.range)
        last = m.range.location + m.range.length
    }
    return out + ns.substring(from: last)
}

/// Index ranges of at most 100 texts / ~8000 characters per request.
func googleChunks(_ texts: [String]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var start = 0
    while start < texts.count {
        var end = start, chars = 0
        while end < texts.count && end - start < 100 && (end == start || chars + texts[end].count < 8000) {
            chars += texts[end].count; end += 1
        }
        out.append(start..<end)
        start = end
    }
    return out
}

func googleRequest(_ chunk: [String], from: String, to: String) throws -> URLRequest {
    var req = URLRequest(url: googleURL, timeoutInterval: 8)
    req.httpMethod = "POST"
    req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
    req.setValue(googleKey, forHTTPHeaderField: "X-Goog-API-Key")
    req.httpBody = try JSONSerialization.data(withJSONObject: [[chunk.map(htmlEscape), from, to], "te_lib"])
    return req
}

func parseGoogleResponse(_ data: Data, _ resp: URLResponse, expecting count: Int) throws -> [String] {
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [Any],
          let list = json.first as? [String], list.count == count else {
        throw LensError("Google Translate failed (HTTP \(code)): \(String(decoding: data.prefix(200), as: UTF8.self))")
    }
    return list.map(htmlUnescape)
}

func googleTranslate(_ texts: [String], from: String, to: String, via transport: Transport) async throws -> [String] {
    var out: [String] = []
    for range in googleChunks(texts) {
        let chunk = Array(texts[range])
        let (data, resp) = try await transport(try googleRequest(chunk, from: from, to: to))
        out += try parseGoogleResponse(data, resp, expecting: chunk.count)
    }
    return out
}

// MARK: - Translation

/// Translations by original text. Google by default (engine "apple" for on-device only); if
/// Google fails, `fallback` translates on-device.
final class Translator {
    typealias Fallback = (_ pending: [(index: Int, text: String)], _ each: (Int, String) -> Void) async throws -> Void

    var cache: [String: String] = [:]
    var config: Config
    var transport: Transport
    var fallback: Fallback

    init(config: Config, transport: @escaping Transport, fallback: @escaping Fallback) {
        self.config = config; self.transport = transport; self.fallback = fallback
    }

    /// Calls `each(index, translation)` as results arrive; cached texts come back immediately.
    func translate(_ texts: [String], _ each: (Int, String) -> Void) async throws {
        if cache.count > 5000 { cache.removeAll() }
        var pending: [Int] = []
        for (i, t) in texts.enumerated() {
            if let c = cache[t] { each(i, c) } else { pending.append(i) }
        }
        guard !pending.isEmpty else { return }
        if config.engine == "google" {
            do {
                let out = try await googleTranslate(pending.map { texts[$0] }, from: config.from, to: config.to, via: transport)
                try Task.checkCancellation()
                for (i, t) in zip(pending, out) { cache[texts[i]] = t; each(i, t) }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("\(error); falling back to on-device translation")
            }
        }
        try await fallback(pending.map { (index: $0, text: texts[$0]) }) { i, t in
            self.cache[texts[i]] = t
            each(i, t)
        }
    }
}

// MARK: - Painting

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
        default:
            guard let k = keys[part] else { return nil }
            key = k
        }
    }
    guard let key else { return nil }
    return (UInt32(key), UInt32(mods))
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

/// `double:` plus a modifier name, as in LENS_HOTKEY=double:rcmd.
func parseDoubleTap(_ spec: String) -> (code: Int64, mask: UInt64)? {
    guard spec.hasPrefix("double:") else { return nil }
    return modifierKeys[String(spec.dropFirst("double:".count))]
}

/// The generic flag of a modifier key, so holding it is not counted as "another modifier".
func modifierFamily(_ code: Int64) -> UInt64 {
    switch code {
    case 54, 55: return UInt64(CGEventFlags.maskCommand.rawValue)
    case 56, 60: return UInt64(CGEventFlags.maskShift.rawValue)
    case 58, 61: return UInt64(CGEventFlags.maskAlternate.rawValue)
    default: return UInt64(CGEventFlags.maskControl.rawValue)
    }
}

struct DoubleTapDetector {
    enum Input {
        case other                                   // any key or mouse button
        case flagsChanged(keycode: Int64, flags: UInt64)
    }

    let code: Int64, mask: UInt64
    var downAt: TimeInterval?        // our key went down cleanly at this time
    var lastTapAt: TimeInterval = 0  // end of the previous clean tap

    init(code: Int64, mask: UInt64) { self.code = code; self.mask = mask }

    /// True when this event completes a double tap.
    mutating func handle(_ input: Input, at now: TimeInterval) -> Bool {
        guard case let .flagsChanged(keycode, flags) = input else { downAt = nil; lastTapAt = 0; return false }
        guard keycode == code else { downAt = nil; lastTapAt = 0; return false }  // another modifier
        if flags & mask != 0 {
            // Pressed: only clean if no other modifier is held.
            let others = flags & UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
                | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue) & ~modifierFamily(code)
            downAt = others == 0 ? now : nil
        } else if let d = downAt {
            downAt = nil
            guard now - d < tapWindow else { lastTapAt = 0; return false }
            if now - lastTapAt < tapWindow {
                lastTapAt = 0
                return true
            }
            lastTapAt = now
        }
        return false
    }
}
