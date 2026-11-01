// ferry-peek: show a macOS-style floating thumbnail in the bottom-right corner whenever a new
// phone screenshot lands in the Syncthing-mirrored folder (~/Pictures/PhoneScreenshots).
//
//   ferry-peek               watch the folder (what the launchd agent runs)
//   ferry-peek --show FILE [--reveal]
//                               preview one file now, exit when it is dismissed; with --reveal a
//                               click shows it in Finder and, for images, also opens it (used by
//                               ferryd for files shared from the phone). Non-image files show
//                               their icon and name.
//   ferry-peek --text [--sensitive]
//                               notification-style card in the top-right corner for text copied on
//                               the phone (text on stdin, so it never shows up in `ps`). Click opens
//                               it if it is a single link, otherwise dismisses; right-click has
//                               Copy Again / Open Link. --sensitive (a password manager marked the
//                               clip) hides the text.
//
// Thumbnail: click = open (default app, usually Preview); drag = drop the file into any app;
// swipe sideways or the x button = dismiss; right-click = Open / Copy / Show in Finder / Close.
// It hides itself after a few seconds unless the pointer is over it.

import AppKit

let env = ProcessInfo.processInfo.environment
let watchDir = URL(fileURLWithPath: env["FERRY_PEEK_DIR"] ?? NSHomeDirectory() + "/Pictures/PhoneScreenshots")
let maxAge: TimeInterval = Double(env["FERRY_PEEK_MAX_AGE"] ?? "") ?? 900  // ignore screenshots older than this (s)
let showSeconds: TimeInterval = Double(env["FERRY_PEEK_SECONDS"] ?? "") ?? 7
let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic"]
let maxSide: CGFloat = 230
let margin: CGFloat = 18

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write("\(f.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

// MARK: - Thumbnail window

final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PeekView: NSView, NSDraggingSource {
    let url: URL
    let image: NSImage
    weak var controller: PeekController?
    private let closeButton = NSButton()
    private var downPoint: NSPoint?
    private var dragStarted = false
    private var swipeX: CGFloat = 0

    init(frame: NSRect, url: URL, image: NSImage, isIcon: Bool) {
        self.url = url; self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
        layer?.backgroundColor = NSColor.black.cgColor

        let iv = NSImageView(frame: isIcon ? NSRect(x: 20, y: 34, width: bounds.width - 40, height: bounds.height - 44) : bounds)
        if isIcon {
            layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
            let label = NSTextField(labelWithString: url.lastPathComponent)
            label.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 20)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.textColor = .white
            label.font = .systemFont(ofSize: 12, weight: .medium)
            addSubview(label)
        }
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        iv.unregisterDraggedTypes()  // the view itself handles drags
        addSubview(iv)

        closeButton.frame = NSRect(x: 6, y: bounds.height - 28, width: 22, height: 22)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular)
                .applying(.init(paletteColors: [.white, NSColor(white: 0.2, alpha: 0.85)])))
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.autoresizingMask = [.minYMargin]
        closeButton.isHidden = true
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v === closeButton ? v : (v == nil ? nil : self)
    }

    @objc func closeClicked() { controller?.dismiss(animated: true) }

    override func mouseEntered(with e: NSEvent) { closeButton.isHidden = false; controller?.pauseTimer() }
    override func mouseExited(with e: NSEvent) { closeButton.isHidden = true; controller?.resumeTimer() }

    override func mouseDown(with e: NSEvent) { downPoint = e.locationInWindow; dragStarted = false }

    override func mouseDragged(with e: NSEvent) {
        guard let d = downPoint, !dragStarted else { return }
        if hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) < 4 { return }
        dragStarted = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: e, source: self)
        controller?.window?.alphaValue = 0.25
    }

    override func mouseUp(with e: NSEvent) {
        defer { downPoint = nil }
        guard !dragStarted, downPoint != nil else { return }
        controller?.primaryAction()
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation {
        c == .outsideApplication ? .copy : []
    }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        if operation == [] { controller?.window?.alphaValue = 1; controller?.resumeTimer() }
        else { controller?.dismiss(animated: false) }
    }

    override func scrollWheel(with e: NSEvent) {
        guard e.hasPreciseScrollingDeltas else { return }
        if e.phase == .began { swipeX = 0 }
        swipeX += e.scrollingDeltaX
        if abs(swipeX) > 35 && abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) {
            swipeX = 0
            controller?.dismiss(animated: true)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Open", action: #selector(menuOpen), keyEquivalent: "").target = self
        m.addItem(withTitle: "Copy", action: #selector(menuCopy), keyEquivalent: "").target = self
        m.addItem(withTitle: "Show in Finder", action: #selector(menuReveal), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closeClicked), keyEquivalent: "").target = self
        controller?.pauseTimer()
        return m
    }
    @objc func menuOpen() { controller?.open() }
    @objc func menuCopy() { controller?.copy(); controller?.dismiss(animated: true) }
    @objc func menuReveal() { NSWorkspace.shared.activateFileViewerSelecting([url]); controller?.dismiss(animated: true) }
}

final class PeekController {
    let url: URL
    var window: PeekPanel?
    private var timer: Timer?
    private var onClose: (() -> Void)?
    private var closing = false

    let reveal: Bool
    private(set) var isIcon = false

    init?(url: URL, reveal: Bool = false, onClose: @escaping () -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var image = NSImage(contentsOf: url)
        var isIcon = false
        if image == nil || image!.size.width <= 0 || image!.size.height <= 0 {
            guard reveal else { return nil }   // the screenshot watcher only previews images
            image = NSWorkspace.shared.icon(forFile: url.path)
            image!.size = NSSize(width: 256, height: 256)
            isIcon = true
        }
        let img = image!
        self.url = url; self.reveal = reveal; self.onClose = onClose
        self.isIcon = isIcon
        let size: NSSize
        if isIcon {
            size = NSSize(width: 170, height: 150)
        } else {
            let s = min(maxSide / img.size.width, maxSide / img.size.height)
            size = NSSize(width: round(img.size.width * s), height: round(img.size.height * s))
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let target = NSRect(x: vf.maxX - margin - size.width, y: vf.minY + margin, width: size.width, height: size.height)

        let w = PeekPanel(contentRect: target.offsetBy(dx: size.width + margin * 2, dy: 0),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isMovable = false
        w.hidesOnDeactivate = false
        let v = PeekView(frame: NSRect(origin: .zero, size: size), url: url, image: img, isIcon: isIcon)
        v.controller = self
        w.contentView = v
        window = w

        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.28
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(target, display: true)
        }
        resumeTimer(after: showSeconds)
    }

    func pauseTimer() { timer?.invalidate(); timer = nil }
    func resumeTimer(after t: TimeInterval = 3) {
        pauseTimer()
        timer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.dismiss(animated: true) }
    }

    func open() {
        NSWorkspace.shared.open(url)
        dismiss(animated: true)
    }

    /// Screenshots: open. Shared files: show in Finder, and images also open on top of it.
    func primaryAction() {
        guard reveal else { open(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if isIcon {
            dismiss(animated: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in open() }
        }
    }

    func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        let ext = url.pathExtension.lowercased()
        if let data = try? Data(contentsOf: url) {
            item.setData(data, forType: ext == "png" ? .png : NSPasteboard.PasteboardType("public.jpeg"))
        }
        item.setString(url.absoluteString, forType: .fileURL)
        pb.writeObjects([item])
    }

    func dismiss(animated: Bool) {
        guard !closing, let w = window else { return }
        closing = true
        pauseTimer()
        let finish = { [self] in
            w.orderOut(nil)
            window = nil
            onClose?(); onClose = nil
        }
        guard animated else { finish(); return }
        var f = w.frame
        f.origin.x += f.width + margin * 2
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.22
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(f, display: true)
            w.animator().alphaValue = 0
        }, completionHandler: finish)
    }
}

// MARK: - Folder watcher

final class Watcher {
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pending = false
    private var current: PeekController?

    func start() {
        known = Set(listing())
        log("watching \(watchDir.path) (\(known.count) files)")
        attach()
        // Fallback rescan: covers the folder being recreated or events being missed.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.source == nil { self.attach() }
            self.scan()
        }
    }

    private func listing() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: watchDir.path)) ?? []
    }

    private func attach() {
        fd = open(watchDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            if s.data.contains(.delete) || s.data.contains(.rename) { s.cancel(); return }
            self.scheduleScan()
        }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1; self?.source = nil
        }
        s.resume()
        source = s
    }

    private func scheduleScan() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.pending = false; self?.scan() }
    }

    private func scan() {
        let names = listing()
        guard !names.isEmpty || known.isEmpty else { return }  // folder briefly missing: keep state
        let now = Set(names)
        let added = now.subtracting(known)
        known = now
        let fresh: [(URL, Date)] = added.compactMap { name in
            guard !name.hasPrefix("."), imageExts.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            let u = watchDir.appendingPathComponent(name)
            guard let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(m) < maxAge else { return nil }
            return (u, m)
        }
        guard let newest = fresh.max(by: { $0.1 < $1.1 }) else { return }
        log("new screenshot: \(newest.0.lastPathComponent)" + (fresh.count > 1 ? " (+\(fresh.count - 1) more)" : ""))
        show(newest.0)
    }

    func show(_ url: URL) {
        current?.dismiss(animated: false)
        var c: PeekController?
        c = PeekController(url: url) { [weak self] in if self?.current === c { self?.current = nil } }
        if c == nil { log("could not load \(url.lastPathComponent)") }
        current = c
    }
}

// MARK: - Text card (top-right, for text copied on the phone)

let toastWidth: CGFloat = 344
let toastSeconds: TimeInterval = Double(env["FERRY_PEEK_TEXT_SECONDS"] ?? "") ?? 5
let ferryGreen = NSColor(srgbRed: 0x19 / 255.0, green: 0xB3 / 255.0, blue: 0x94 / 255.0, alpha: 1)

// Background (non-frontmost) apps can't change the cursor unless their window-server connection
// has this private property; window managers and annotation tools use the same switch.
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

func allowCursorInBackground() {
    let cid = _CGSDefaultConnection()
    let err = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    if err != 0 { log("SetsCursorInBackground failed: \(err)") }
}

final class ToastView: NSView {
    weak var controller: TextToast?
    private let closeButton = NSButton()
    private var swipeX: CGFloat = 0
    private var down = false
    private let isLink: Bool

    init(text: String, sensitive: Bool, link: URL?) {
        isLink = link != nil
        let pad: CGFloat = 14, iconSide: CGFloat = 34
        let textX = pad + iconSide + 11, textW = toastWidth - textX - pad

        let title = NSTextField(labelWithString: sensitive ? "Copied on your phone" : "Copied from your phone")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        let when = NSTextField(labelWithString: "now")
        when.font = .systemFont(ofSize: 11)
        when.textColor = .secondaryLabelColor
        when.sizeToFit()

        let body = NSTextField(wrappingLabelWithString: "")
        body.maximumNumberOfLines = 4
        body.lineBreakMode = .byWordWrapping
        body.cell?.wraps = true
        body.cell?.truncatesLastVisibleLine = true
        body.font = .systemFont(ofSize: 13)
        if sensitive {
            body.stringValue = "Hidden because the phone marked it sensitive. Paste works as usual."
            body.textColor = .secondaryLabelColor
        } else {
            // Collapse runs of blank lines and trim, so a 4-line preview shows actual content.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            body.stringValue = lines.joined(separator: "\n")
            body.textColor = link != nil ? ferryGreen : .labelColor
        }
        body.preferredMaxLayoutWidth = textW
        let bodyH = min(ceil(body.sizeThatFits(NSSize(width: textW, height: 400)).height), 4 * 17 + 2)

        var footer: NSTextField?
        if !sensitive {
            let n = text.count
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            var bits: [String] = []
            if link != nil { bits.append("Click to open the link") }
            else if n > 160 { bits.append("\(n.formatted()) characters, \(words.formatted()) words") }
            if !bits.isEmpty {
                let f = NSTextField(labelWithString: bits.joined(separator: " · "))
                f.font = .systemFont(ofSize: 11)
                f.textColor = .secondaryLabelColor
                footer = f
            }
        }

        let titleH: CGFloat = 17, gap: CGFloat = 3, footerH: CGFloat = footer == nil ? 0 : 18
        let height = max(pad + titleH + gap + bodyH + footerH + pad, pad * 2 + iconSide)
        super.init(frame: NSRect(x: 0, y: 0, width: toastWidth, height: height))

        let fx = NSVisualEffectView(frame: bounds)
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor(white: 0.5, alpha: 0.35).cgColor
        fx.autoresizingMask = [.width, .height]
        addSubview(fx)

        // App-icon-like badge: Ferry green rounded square with a clipboard glyph.
        let badge = NSView(frame: NSRect(x: pad, y: height - pad - iconSide, width: iconSide, height: iconSide))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 8
        let g = CAGradientLayer()
        g.frame = badge.bounds
        g.colors = [NSColor(srgbRed: 0x14 / 255.0, green: 0xA3 / 255.0, blue: 0x7F / 255.0, alpha: 1).cgColor,
                    NSColor(srgbRed: 0x0B / 255.0, green: 0x4A / 255.0, blue: 0x4C / 255.0, alpha: 1).cgColor]
        g.cornerRadius = 8
        badge.layer?.addSublayer(g)
        let glyph = NSImageView(frame: badge.bounds.insetBy(dx: 7, dy: 7))
        glyph.image = NSImage(systemSymbolName: sensitive ? "lock.fill" : "doc.on.clipboard.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [.white])))
        glyph.imageScaling = .scaleProportionallyDown
        badge.addSubview(glyph)
        addSubview(badge)

        let top = height - pad
        title.frame = NSRect(x: textX, y: top - titleH, width: textW - when.frame.width - 6, height: titleH)
        when.frame = NSRect(x: toastWidth - pad - when.frame.width, y: top - titleH + 1, width: when.frame.width, height: 15)
        body.frame = NSRect(x: textX, y: top - titleH - gap - bodyH, width: textW, height: bodyH)
        addSubview(title); addSubview(when); addSubview(body)
        if let f = footer {
            f.frame = NSRect(x: textX, y: body.frame.minY - footerH, width: textW, height: 15)
            addSubview(f)
        }

        closeButton.frame = NSRect(x: -3, y: height - 19, width: 22, height: 22)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)
                .applying(.init(paletteColors: [.labelColor, NSColor.windowBackgroundColor])))
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                              .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v === closeButton ? v : (v == nil ? nil : self)
    }
    @objc func closeClicked() { controller?.dismiss() }

    // Pointing hand over a link card. The panel never becomes key, so cursor rects don't apply and
    // the frontmost app may reset the cursor; set it again on every move while inside.
    private func updateCursor(_ e: NSEvent) {
        guard isLink else { return }
        let overClose = !closeButton.isHidden && closeButton.frame.contains(convert(e.locationInWindow, from: nil))
        (overClose ? NSCursor.arrow : NSCursor.pointingHand).set()
    }
    override func cursorUpdate(with e: NSEvent) { updateCursor(e) }
    override func mouseMoved(with e: NSEvent) { updateCursor(e) }
    override func mouseEntered(with e: NSEvent) { closeButton.isHidden = false; controller?.pauseTimer(); updateCursor(e) }
    override func mouseExited(with e: NSEvent) {
        closeButton.isHidden = true; controller?.resumeTimer()
        if isLink { NSCursor.arrow.set() }
    }
    override func mouseDown(with e: NSEvent) { down = true }
    override func mouseUp(with e: NSEvent) {
        guard down else { return }
        down = false
        controller?.primaryAction()
    }
    override func scrollWheel(with e: NSEvent) {
        guard e.hasPreciseScrollingDeltas else { return }
        if e.phase == .began { swipeX = 0 }
        swipeX += e.scrollingDeltaX
        if abs(swipeX) > 35 && abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) { swipeX = 0; controller?.dismiss() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        if controller?.link != nil { m.addItem(withTitle: "Open Link", action: #selector(menuOpen), keyEquivalent: "").target = self }
        m.addItem(withTitle: "Copy Again", action: #selector(menuCopy), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closeClicked), keyEquivalent: "").target = self
        controller?.pauseTimer()
        return m
    }
    @objc func menuOpen() { controller?.primaryAction() }
    @objc func menuCopy() { controller?.copyAgain(); controller?.dismiss() }
}

final class TextToast {
    let text: String
    let link: URL?
    private var window: PeekPanel?
    private var timer: Timer?
    private var closing = false

    init(text: String, sensitive: Bool) {
        self.text = text
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sensitive, !t.contains(where: { $0.isWhitespace }), let u = URL(string: t),
           let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host != nil {
            link = u
        } else {
            link = nil
        }
        let v = ToastView(text: text, sensitive: sensitive, link: link)
        v.controller = self
        let size = v.frame.size

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let target = NSRect(x: vf.maxX - margin - size.width, y: vf.maxY - margin + 4 - size.height,
                            width: size.width, height: size.height)
        let w = PeekPanel(contentRect: target.offsetBy(dx: size.width + margin * 2, dy: 0),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isMovable = false
        w.hidesOnDeactivate = false
        w.contentView = v
        w.acceptsMouseMovedEvents = true
        window = w
        w.orderFrontRegardless()
        if env["FERRY_PEEK_PRINT_WINDOW"] != nil { print(w.windowNumber); fflush(stdout) }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.3
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(target, display: true)
        }
        resumeTimer(after: toastSeconds)
    }

    func pauseTimer() { timer?.invalidate(); timer = nil }
    func resumeTimer(after t: TimeInterval = 2.5) {
        pauseTimer()
        timer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    func primaryAction() {
        if let u = link { NSWorkspace.shared.open(u) }
        dismiss()
    }

    func copyAgain() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func dismiss() {
        guard !closing, let w = window else { return }
        closing = true
        pauseTimer()
        var f = w.frame
        f.origin.x += f.width + margin * 2
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.22
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(f, display: true)
            w.animator().alphaValue = 0
        }, completionHandler: { exit(0) })
    }
}

// MARK: - main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = CommandLine.arguments
var keep: AnyObject?

if (args.count == 3 || (args.count == 4 && args[3] == "--reveal")) && args[1] == "--show" {
    let u = URL(fileURLWithPath: args[2])
    guard let c = PeekController(url: u, reveal: args.count == 4, onClose: { exit(0) }) else { log("could not load \(u.path)"); exit(1) }
    keep = c
} else if args.count >= 2 && args[1] == "--text" && args.dropFirst(2).allSatisfy({ $0 == "--sensitive" }) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { exit(1) }
    allowCursorInBackground()
    keep = TextToast(text: text, sensitive: args.contains("--sensitive"))
} else if args.count == 1 {
    let w = Watcher()
    w.start()
    keep = w
} else {
    print("usage: ferry-peek [--show FILE [--reveal] | --text [--sensitive] < TEXT]")
    exit(2)
}
app.run()
