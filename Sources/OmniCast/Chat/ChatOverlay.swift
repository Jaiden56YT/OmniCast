import AppKit
import Foundation
import Observation
import OmniEngine

/// Draws the merged chat onto the canvases in OmniCast's chat style:
/// heavy rounded type with a thick black outline,
/// platform icons, role badges and inline emotes, newest line at the bottom.
///
/// Each canvas gets its own image layer, drawn at exactly the box's canvas
/// pixels, redrawn at most ~8 times a second however busy chat gets.
@MainActor
@Observable
final class ChatOverlay {
    static let shared = ChatOverlay()

    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var points: CGFloat { self == .small ? 20 : self == .medium ? 25 : 31 }
    }

    var visible = UserDefaults.standard.object(forKey: "chat.visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(visible, forKey: "chat.visible"); redraw() }
    }
    var showOnVertical = UserDefaults.standard.object(forKey: "chat.vertical") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showOnVertical, forKey: "chat.vertical"); redraw() }
    }
    var size = Size(rawValue: UserDefaults.standard.string(forKey: "chat.size") ?? "") ?? .medium {
        didSet { UserDefaults.standard.set(size.rawValue, forKey: "chat.size"); redraw() }
    }
    /// Seconds a line stays up before it fades out; 0 keeps the latest lines up for good.
    var hideAfter = UserDefaults.standard.object(forKey: "chat.hideAfter") as? Double ?? 300 {
        didSet { UserDefaults.standard.set(hideAfter, forKey: "chat.hideAfter"); redraw() }
    }
    /// Seconds without a new message before the whole chat fades out (it fades
    /// back in with the next message); 0 never fades it.
    var fadeWhenQuiet = UserDefaults.standard.object(forKey: "chat.fadeWhenQuiet") as? Double ?? 300 {
        didSet { UserDefaults.standard.set(fadeWhenQuiet, forKey: "chat.fadeWhenQuiet"); updateQuiet() }
    }

    private(set) var boxes: [Canvas: CallOverlay.Box] = {
        var boxes: [Canvas: CallOverlay.Box] = [:]
        for c in Canvas.allCases {
            if let data = UserDefaults.standard.data(forKey: "chat.box.\(c.rawValue)"),
               let box = try? JSONDecoder().decode(CallOverlay.Box.self, from: data) { boxes[c] = box }
        }
        return boxes
    }()

    static func defaultBox(_ canvas: Canvas) -> CallOverlay.Box {
        canvas == .horizontal
            ? CallOverlay.Box(x: 24, y: 230, w: 470, h: 620)
            : CallOverlay.Box(x: 40, y: 1060, w: 660, h: 560)
    }

    func box(_ canvas: Canvas) -> CallOverlay.Box { boxes[canvas] ?? Self.defaultBox(canvas) }

    func updateBox(_ canvas: Canvas, _ change: (inout CallOverlay.Box) -> Void) {
        let limit = canvas == .horizontal ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        var b = box(canvas)
        change(&b)
        b.w = min(max(b.w, 200), limit.width)
        b.h = min(max(b.h, 120), limit.height)
        b.x = min(max(b.x, -b.w / 2), limit.width - b.w / 2)
        b.y = min(max(b.y, -b.h / 2), limit.height - b.h / 2)
        boxes[canvas] = b
        if let data = try? JSONEncoder().encode(b) { UserDefaults.standard.set(data, forKey: "chat.box.\(canvas.rawValue)") }
        place(canvas)
        redraw()
    }

    func resetBox(_ canvas: Canvas) {
        boxes[canvas] = nil
        UserDefaults.standard.removeObject(forKey: "chat.box.\(canvas.rawValue)")
        place(canvas)
        redraw()
    }

    private var pending = false
    private var lastDraw = Date.distantPast
    private var emotes: [URL: NSImage] = [:]
    private var loading: Set<URL> = []
    private var expiryTimer: Timer?
    /// Lines on screen at the last draw, to redraw when one expires.
    private var drawnLines = 0
    /// The whole chat's fade (quiet chat), eased toward `layerTarget`.
    private var layerOpacity: Float = 1
    private var layerTarget: Float = 1
    private var fadeTimer: Timer?
    /// How long a single line takes to fade out.
    private static let lineFade: TimeInterval = 1.5

    private var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniCast/overlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func key(_ canvas: Canvas) -> String { "chat-\(canvas.rawValue)" }

    func start() {
        ChatHub.shared.onChange = { [weak self] in
            self?.updateQuiet()
            self?.redraw()
        }
        // Lines that fade or expire need a redraw even when nobody's typing.
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { ChatOverlay.shared.checkExpiry() }
        }
        ChatHub.shared.start()
        redraw()
    }

    /// Coalesces bursts: at most one draw per 120 ms.
    func redraw() {
        guard !pending else { return }
        pending = true
        let wait = max(0, 0.12 - Date().timeIntervalSince(lastDraw))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.lastDraw = Date()
            for canvas in Canvas.allCases { self.draw(canvas) }
        }
    }

    /// Lines still up, each with its opacity (below 1 while fading out).
    private func visibleLines(at now: Date = Date()) -> [(ChatMessage, CGFloat)] {
        ChatHub.shared.messages.compactMap { m in
            guard hideAfter > 0 else { return (m, 1) }
            let left = hideAfter - now.timeIntervalSince(m.received)
            return left > 0 ? (m, CGFloat(min(1, left / Self.lineFade))) : nil
        }
    }

    private func checkExpiry() {
        updateQuiet()
        guard hideAfter > 0 else { return }
        let lines = visibleLines()
        if lines.count != drawnLines || lines.contains(where: { $0.1 < 1 }) { redraw() }
    }

    /// Fades the whole chat out once nobody has written for `fadeWhenQuiet`, and back in on a new message.
    private func updateQuiet() {
        let quiet = fadeWhenQuiet > 0
            && Date().timeIntervalSince(ChatHub.shared.messages.last?.received ?? .distantPast) >= fadeWhenQuiet
        let target: Float = quiet ? 0 : 1
        guard target != layerTarget || (fadeTimer == nil && layerOpacity != target) else { return }
        layerTarget = target
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { ChatOverlay.shared.fadeStep() }
        }
    }

    private func fadeStep() {
        // About a second out, half a second back in.
        let step: Float = layerTarget > layerOpacity ? 1.0 / 15 : 1.0 / 30
        layerOpacity = layerTarget > layerOpacity ? min(layerTarget, layerOpacity + step) : max(layerTarget, layerOpacity - step)
        let eased = layerOpacity * layerOpacity * (3 - 2 * layerOpacity)
        for canvas in Canvas.allCases where shown(canvas) && drawnLines > 0 {
            omni_layer_set_opacity(Self.key(canvas), eased)
        }
        if layerOpacity == layerTarget {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    private var easedLayerOpacity: Float { layerOpacity * layerOpacity * (3 - 2 * layerOpacity) }

    private func shown(_ canvas: Canvas) -> Bool { visible && (canvas == .horizontal || showOnVertical) }

    private func place(_ canvas: Canvas) {
        let b = box(canvas)
        let key = Self.key(canvas)
        for c in Canvas.allCases {
            omni_layer_place(key, c == .vertical ? OMNI_CANVAS_VERTICAL : OMNI_CANVAS_HORIZONTAL,
                             c == canvas && shown(canvas), Float(b.x), Float(b.y), Float(b.w), Float(b.h))
        }
    }

    private func draw(_ canvas: Canvas) {
        let key = Self.key(canvas)
        let lines = visibleLines()
        if canvas == .horizontal { drawnLines = lines.count }
        guard shown(canvas), !lines.isEmpty, Engine.shared.running else {
            omni_layer_set_opacity(key, 0)
            return
        }
        let b = box(canvas)
        guard let image = render(lines, size: CGSize(width: b.w, height: b.h)) else { return }
        let url = folder.appendingPathComponent("\(key).png")
        guard let png = image.representation(using: .png, properties: [:]), (try? png.write(to: url, options: .atomic)) != nil
        else { return }
        omni_layer_set_image(key, url.path)
        place(canvas)
        omni_layer_set_opacity(key, easedLayerOpacity)
    }

    // MARK: Drawing

    /// Bright palette picks for names without their own colour.
    private static let palette: [NSColor] = ["#A78BFA", "#D46BFF", "#FF8FD0", "#6E8BFF", "#4ED1A1", "#FF7A59"].map(color)

    private func render(_ lines: [(ChatMessage, CGFloat)], size: CGSize) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let width = size.width - 12
        let gap = self.size.points * 0.35
        var y: CGFloat = 6 // from the bottom up, newest first
        let cg = NSGraphicsContext.current?.cgContext
        for (message, alpha) in lines.reversed() {
            let text = attributed(message)
            let height = ceil(text.boundingRect(with: CGSize(width: width, height: 10_000),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            guard y + height <= size.height else { break }
            let rect = CGRect(x: 6, y: y, width: width, height: height + 4)
            // A fading line is drawn as one layer, so the outline doesn't show through the fill.
            cg?.setAlpha(alpha)
            cg?.beginTransparencyLayer(auxiliaryInfo: nil)
            // Outline pass, then fill: a thick black edge outside the letters, like the art.
            outlined(text).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            cg?.endTransparencyLayer()
            cg?.setAlpha(1)
            y += height + gap
        }
        return rep
    }

    private var font: NSFont {
        let base = NSFont.systemFont(ofSize: size.points, weight: .heavy)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size.points) } ?? base
    }

    private func attributed(_ m: ChatMessage) -> NSAttributedString {
        let f = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.95
        let base: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        let s = NSMutableAttributedString()
        s.append(attachment(Self.platformIcon(m.platform, height: f.pointSize * 0.95), font: f))
        s.append(NSAttributedString(string: " ", attributes: base))
        for badge in m.badges {
            if let icon = Self.badgeIcon(badge, height: f.pointSize * 0.9) {
                s.append(attachment(icon, font: f))
                s.append(NSAttributedString(string: " ", attributes: base))
            }
        }
        var name = base
        name[.foregroundColor] = nameColor(m)
        s.append(NSAttributedString(string: m.author, attributes: name))
        s.append(NSAttributedString(string: "  ", attributes: base))
        for part in m.parts {
            switch part {
            case .text(let t):
                s.append(NSAttributedString(string: t, attributes: base))
            case .emote(let url, let fallback):
                if let image = emotes[url] {
                    s.append(attachment(image, font: f, scale: 1.25))
                } else {
                    load(url)
                    s.append(NSAttributedString(string: fallback, attributes: base))
                }
            }
        }
        return s
    }

    /// The same text with only a black stroke, drawn underneath the fill.
    private func outlined(_ text: NSAttributedString) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: s.length)
        s.addAttributes([.strokeColor: NSColor.black, .strokeWidth: 34], range: all)
        return s
    }

    private func attachment(_ image: NSImage, font: NSFont, scale: CGFloat = 1) -> NSAttributedString {
        let a = NSTextAttachment()
        a.image = image
        let h = font.pointSize * scale
        let w = h * image.size.width / max(image.size.height, 1)
        // Centred on the text's x-height.
        a.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2, width: w, height: h)
        return NSAttributedString(attachment: a)
    }

    private func nameColor(_ m: ChatMessage) -> NSColor {
        // You, in the streamer purple, on every platform.
        if m.badges.contains(.owner) { return Self.color("#B794FF") }
        if let hex = m.color, var c = Optional(Self.color(hex)) {
            // Too-dark colours vanish over game footage: lift them.
            if (c.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.55 {
                c = c.blended(withFraction: 0.45, of: .white) ?? c
            }
            return c
        }
        var hash: UInt32 = 5381
        for b in m.author.utf8 { hash = hash &* 33 &+ UInt32(b) }
        return Self.palette[Int(hash % UInt32(Self.palette.count))]
    }

    private func load(_ url: URL) {
        guard !loading.contains(url) else { return }
        loading.insert(url)
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                self.emotes[url] = image
                self.redraw()
            }
        }
    }

    // MARK: Icons

    static func color(_ hex: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Small platform marks, outlined in black to match the text.
    static func platformIcon(_ platform: ChatPlatform, height: CGFloat) -> NSImage {
        let w = platform == .youtube ? height * 1.4 : height
        return NSImage(size: NSSize(width: w, height: height), flipped: false) { r in
            let body = r.insetBy(dx: 1.5, dy: 1.5)
            let shape = NSBezierPath(roundedRect: body, xRadius: height * 0.26, yRadius: height * 0.26)
            switch platform {
            case .youtube: color("#FF0033").setFill()
            case .twitch: color("#9146FF").setFill()
            case .kick: color("#53FC18").setFill()
            }
            shape.fill()
            NSColor.black.setStroke()
            shape.lineWidth = 2.5
            shape.stroke()
            switch platform {
            case .youtube:
                let t = NSBezierPath()
                t.move(to: CGPoint(x: body.midX - height * 0.18, y: body.midY - height * 0.22))
                t.line(to: CGPoint(x: body.midX - height * 0.18, y: body.midY + height * 0.22))
                t.line(to: CGPoint(x: body.midX + height * 0.24, y: body.midY))
                t.close()
                NSColor.white.setFill()
                t.fill()
            case .twitch:
                // Speech bubble with two bars.
                let bubble = NSBezierPath(rect: CGRect(x: body.minX + height * 0.22, y: body.minY + height * 0.3,
                                                       width: height * 0.52, height: height * 0.44))
                NSColor.white.setFill()
                bubble.fill()
                color("#9146FF").setFill()
                for dx in [0.38, 0.56] {
                    NSBezierPath(rect: CGRect(x: body.minX + height * dx - height * 0.04, y: body.minY + height * 0.42,
                                              width: height * 0.07, height: height * 0.2)).fill()
                }
            case .kick:
                let k = NSAttributedString(string: "K", attributes: [
                    .font: NSFont.systemFont(ofSize: height * 0.72, weight: .black), .foregroundColor: NSColor.black,
                ])
                let ks = k.size()
                k.draw(at: CGPoint(x: body.midX - ks.width / 2, y: body.midY - ks.height / 2))
            }
            return true
        }
    }

    static func badgeIcon(_ badge: ChatMessage.Badge, height: CGFloat) -> NSImage? {
        let (symbol, hex): (String, String) = switch badge {
        case .owner: ("crown.fill", "#FFD54A")
        case .moderator: ("wrench.adjustable.fill", "#6E8BFF")
        case .vip: ("diamond.fill", "#FF5FD2")
        case .member: ("star.fill", "#B58CFF")
        case .verified: ("checkmark.seal.fill", "#E6E6E6")
        }
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: height, weight: .black)) else { return nil }
        return NSImage(size: base.size, flipped: false) { r in
            // Black edge first (the symbol drawn slightly larger), then the colour.
            for (inset, tint) in [(-1.5, NSColor.black), (0.0, color(hex))] {
                let rect = r.insetBy(dx: inset, dy: inset)
                base.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
    }
}
