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

let config = Config(env: ProcessInfo.processInfo.environment)
let fromLang = config.from
let toLang = config.to
let hotkeySpec = config.hotkey
let engine = config.engine
let toggleNote = Notification.Name("com.anurag.lens.toggle")

// MARK: - Translation

var session: TranslationSession?

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

let translationEngine = Translator(config: config, transport: { try await URLSession.shared.data(for: $0) },
                                   fallback: { pending, each in
    let reqs = pending.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.index)) }
    for try await r in try await translator().translate(batch: reqs) {
        try Task.checkCancellation()
        if let id = r.clientIdentifier, let i = Int(id) { each(i, r.targetText) }
    }
})

@MainActor func translateStreaming(_ blocks: [Block], _ each: (Int, String) -> Void) async throws {
    try await translationEngine.translate(blocks.map(\.original), each)
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyText(blocks), forType: .string)
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
                let focus = focusPoint(mouse: mouse, screenFrame: screen.frame, k: k)
                let view = self.present(on: screen, k: k)
                self.hud.show("Reading…", on: screen)
                let blocks = try await Task.detached { try prepare(img, focus: focus, from: fromLang) }.value
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

final class DoubleTap {
    var detector: DoubleTapDetector
    var tap: CFMachPort?

    init(code: Int64, mask: UInt64) { detector = DoubleTapDetector(code: code, mask: mask) }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let input: DoubleTapDetector.Input = type == .flagsChanged
            ? .flagsChanged(keycode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue)
            : .other
        if detector.handle(input, at: now) { fire() }
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
    guard let k = parseDoubleTap(hotkeySpec) else {
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
        var blocks = try prepare(img, focus: nil, from: fromLang)
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