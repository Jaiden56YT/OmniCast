import AppKit
import Foundation
import Observation
import OmniEngine

/// Shows follows, subs, tips and raids on the canvases, one at a time from a
/// queue: each card slides in, stays a few seconds and fades out.
///
/// One image layer carries the card on both canvases; the card is redrawn per
/// alert and kept at a fixed 4:1 shape so one image fits either box.
@MainActor
@Observable
final class AlertOverlay {
    static let shared = AlertOverlay()

    var enabled = UserDefaults.standard.object(forKey: "alerts.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "alerts.enabled")
            if !enabled { queue.removeAll() }
            AlertSources.shared.update()
        }
    }
    var showOnVertical = UserDefaults.standard.object(forKey: "alerts.vertical") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showOnVertical, forKey: "alerts.vertical"); place() }
    }
    /// Seconds each alert stays fully shown.
    var seconds = UserDefaults.standard.object(forKey: "alerts.seconds") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(seconds, forKey: "alerts.seconds") }
    }
    var kinds: Set<StreamAlert.Kind> = {
        guard let saved = UserDefaults.standard.stringArray(forKey: "alerts.kinds") else {
            return Set(StreamAlert.Kind.allCases)
        }
        return Set(saved.compactMap(StreamAlert.Kind.init(rawValue:)))
    }() {
        didSet {
            UserDefaults.standard.set(kinds.map(\.rawValue).sorted(), forKey: "alerts.kinds")
            AlertSources.shared.update()
        }
    }

    /// Waiting to be shown, oldest first.
    private(set) var queue: [StreamAlert] = []
    private(set) var current: StreamAlert?
    /// The last alerts received (shown or not), newest first, for Settings.
    private(set) var recent: [StreamAlert] = []

    static let key = "alert"
    /// The card's shape; boxes keep it.
    static let cardSize = CGSize(width: 800, height: 200)
    private static let maxQueue = 40

    // MARK: Boxes

    private(set) var boxes: [Canvas: CallOverlay.Box] = {
        var boxes: [Canvas: CallOverlay.Box] = [:]
        for c in Canvas.allCases {
            if let data = UserDefaults.standard.data(forKey: "alerts.box.\(c.rawValue)"),
               let box = try? JSONDecoder().decode(CallOverlay.Box.self, from: data) { boxes[c] = box }
        }
        return boxes
    }()

    /// Top centre on 16:9; on 9:16 in the upper half, clear of the camera below.
    static func defaultBox(_ canvas: Canvas) -> CallOverlay.Box {
        canvas == .horizontal
            ? CallOverlay.Box(x: (1920 - 760) / 2, y: 48, w: 760, h: 190)
            : CallOverlay.Box(x: 60, y: 260, w: 960, h: 240)
    }

    func box(_ canvas: Canvas) -> CallOverlay.Box { boxes[canvas] ?? Self.defaultBox(canvas) }

    func updateBox(_ canvas: Canvas, _ change: (inout CallOverlay.Box) -> Void) {
        let limit = canvas == .horizontal ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        var b = box(canvas)
        change(&b)
        b.w = min(max(b.w, 320), limit.width)
        b.h = b.w * Self.cardSize.height / Self.cardSize.width
        b.x = min(max(b.x, -b.w / 2), limit.width - b.w / 2)
        b.y = min(max(b.y, -b.h / 2), limit.height - b.h / 2)
        boxes[canvas] = b
        if let data = try? JSONEncoder().encode(b) { UserDefaults.standard.set(data, forKey: "alerts.box.\(canvas.rawValue)") }
        place()
    }

    func resetBox(_ canvas: Canvas) {
        boxes[canvas] = nil
        UserDefaults.standard.removeObject(forKey: "alerts.box.\(canvas.rawValue)")
        place()
    }

    // MARK: Queue

    func start() {
        AlertSources.shared.start()
        showNext()
    }

    /// An event from a platform. Dropped if alerts or its kind are off.
    func post(_ alert: StreamAlert) {
        recent.insert(alert, at: 0)
        if recent.count > 25 { recent.removeLast(recent.count - 25) }
        guard enabled, kinds.contains(alert.kind) else { return }
        enqueue(alert)
    }

    /// A made-up alert, shown even when alerts are off, to see and place the card.
    func test() {
        let samples: [StreamAlert] = [
            StreamAlert(platform: .twitch, kind: .follow, name: "deku_vt", action: "just followed"),
            StreamAlert(platform: .twitch, kind: .subscription, name: "Mr_Seasalt", action: "resubscribed for",
                        highlight: "9 months", message: "It's been 9 hours and 20 minutes 😭"),
            StreamAlert(platform: .youtube, kind: .money, name: "BrandonSaber", action: "sent a Super Chat",
                        highlight: "$5.00", message: "wait you mean 1400 right?"),
            StreamAlert(platform: .kick, kind: .gift, name: "ItsSoraval", action: "gifted", highlight: "5 subs"),
            StreamAlert(platform: .twitch, kind: .money, name: "T3mpex", action: "cheered", highlight: "500 bits"),
            StreamAlert(platform: .twitch, kind: .raid, name: "YourFriend", action: "raided with", highlight: "42 viewers"),
            StreamAlert(platform: .youtube, kind: .subscription, name: "eepers", action: "just became a member"),
        ]
        testIndex = (testIndex + 1) % samples.count
        enqueue(samples[testIndex])
    }
    private var testIndex = -1

    func clearQueue() { queue.removeAll() }

    private func enqueue(_ alert: StreamAlert) {
        queue.append(alert)
        if queue.count > Self.maxQueue { queue.removeFirst(queue.count - Self.maxQueue) }
        if current == nil { showNext() }
    }

    // MARK: Showing

    private enum Phase { case idle, entering, holding, leaving }
    private var phase = Phase.idle
    private var phaseStart = Date()
    private var tick: Timer?
    /// 0…1 for the fade; the card also slides by `slide` canvas pixels.
    private var opacity: Float = 0
    private var slide: Double = 0

    private static let enterTime = 0.35, leaveTime = 0.45, gapTime = 0.6

    private var imageURL: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniCast/overlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("alert.png")
    }

    private func showNext() {
        guard current == nil, Engine.shared.running, !queue.isEmpty else { return }
        let alert = queue.removeFirst()
        guard let png = Self.card(for: alert)?.representation(using: .png, properties: [:]),
              (try? png.write(to: imageURL, options: .atomic)) != nil else { return showNext() }
        current = alert
        omni_layer_set_image(Self.key, imageURL.path)
        phase = .entering
        phaseStart = Date()
        step()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { AlertOverlay.shared.step() }
        }
    }

    private func step() {
        let t = Date().timeIntervalSince(phaseStart)
        switch phase {
        case .idle:
            return
        case .entering:
            let p = min(t / Self.enterTime, 1)
            let eased = 1 - pow(1 - p, 3) // ease out
            opacity = Float(eased)
            slide = -36 * (1 - eased)
            if p >= 1 { phase = .holding; phaseStart = Date() }
        case .holding:
            opacity = 1
            slide = 0
            if t >= max(seconds, 1) { phase = .leaving; phaseStart = Date() }
        case .leaving:
            let p = min(t / Self.leaveTime, 1)
            let eased = p * p
            opacity = Float(1 - eased)
            slide = -18 * eased
            if p >= 1 {
                phase = .idle
                opacity = 0
                tick?.invalidate()
                tick = nil
                omni_layer_set_opacity(Self.key, 0)
                current = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.gapTime) {
                    MainActor.assumeIsolated { AlertOverlay.shared.showNext() }
                }
                return
            }
        }
        place()
        omni_layer_set_opacity(Self.key, opacity)
    }

    private func place() {
        guard current != nil else { return }
        for canvas in Canvas.allCases {
            let b = box(canvas)
            let show = canvas == .horizontal || showOnVertical
            // Slide in proportion to the box, so it looks the same on either canvas.
            let dy = slide * b.w / Self.cardSize.width
            omni_layer_place(Self.key, canvas == .vertical ? OMNI_CANVAS_VERTICAL : OMNI_CANVAS_HORIZONTAL,
                             show, Float(b.x), Float(b.y + dy), Float(b.w), Float(b.h))
        }
    }

    // MARK: Card image

    /// The card at twice its canvas size, for crisp text after scaling.
    static func card(for alert: StreamAlert) -> NSBitmapImageRep? {
        let scale: CGFloat = 2
        let size = cardSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let accent = ChatOverlay.color(alert.kind.accent)
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
        let card = NSBezierPath(roundedRect: bounds, xRadius: 30, yRadius: 30)
        NSColor(white: 0.05, alpha: 0.9).setFill()
        card.fill()
        accent.withAlphaComponent(0.9).setStroke()
        card.lineWidth = 4
        card.stroke()

        // The kind's mark in an accent disc, with the platform's icon on its edge.
        let disc = CGRect(x: 30, y: (size.height - 132) / 2, width: 132, height: 132)
        accent.setFill()
        NSBezierPath(ovalIn: disc).fill()
        if let symbol = NSImage(systemSymbolName: alert.kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 58, weight: .black)) {
            let s = symbol.size
            let r = CGRect(x: disc.midX - s.width / 2, y: disc.midY - s.height / 2, width: s.width, height: s.height)
            let tinted = NSImage(size: s, flipped: false) { rect in
                symbol.draw(in: rect)
                NSColor(white: 0.06, alpha: 1).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: r)
        }
        let icon = ChatOverlay.platformIcon(alert.platform, height: 44)
        icon.draw(in: CGRect(x: disc.maxX - icon.size.width + 8, y: disc.minY - 4,
                             width: icon.size.width, height: icon.size.height))

        let textX = disc.maxX + 30
        let textWidth = size.width - textX - 36
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail

        let nameFont = rounded(50, .heavy)
        let actionFont = rounded(32, .bold)
        let messageFont = NSFont.systemFont(ofSize: 24, weight: .medium)

        // Without a message the two lines sit in the middle; with one, three lines fill the card.
        let hasMessage = !(alert.message ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let nameY: CGFloat = hasMessage ? 104 : 88
        let actionY: CGFloat = hasMessage ? 64 : 42

        NSAttributedString(string: alert.name, attributes: [
            .font: nameFont, .foregroundColor: NSColor.white, .paragraphStyle: truncating,
        ]).draw(with: CGRect(x: textX, y: nameY, width: textWidth, height: 64), options: [.usesLineFragmentOrigin])

        let line = NSMutableAttributedString(string: alert.action, attributes: [
            .font: actionFont, .foregroundColor: NSColor(white: 1, alpha: 0.86), .paragraphStyle: truncating,
        ])
        if let highlight = alert.highlight, !highlight.isEmpty {
            line.append(NSAttributedString(string: " " + highlight, attributes: [
                .font: actionFont, .foregroundColor: accent, .paragraphStyle: truncating,
            ]))
        }
        line.draw(with: CGRect(x: textX, y: actionY, width: textWidth, height: 42), options: [.usesLineFragmentOrigin])

        if hasMessage, let message = alert.message {
            NSAttributedString(string: message, attributes: [
                .font: messageFont, .foregroundColor: NSColor(white: 1, alpha: 0.62), .paragraphStyle: truncating,
            ]).draw(with: CGRect(x: textX, y: 24, width: textWidth, height: 32), options: [.usesLineFragmentOrigin])
        }
        return rep
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}
