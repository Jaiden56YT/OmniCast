import AppKit
import Foundation
import Observation
import OmniEngine

/// Where and how one person sits on the 16:9 canvas. Saved per Discord user, so
/// people land in the same spot every call.
struct MemberLayout: Codable, Equatable {
    /// Centre of the image, in canvas pixels.
    var x: Double
    var y: Double
    /// Box height in canvas pixels; the width follows the image's aspect.
    var size: Double
    var flip = false
    /// Which way the person's image looks without flipping.
    var facesLeft = false
    var idlePath: String?
    var talkPath: String?
}

enum ArrangeStyle: String, CaseIterable, Identifiable {
    case faceRight, faceLeft, faceMiddle
    var id: String { rawValue }

    var label: String {
        switch self {
        case .faceRight: "Row, everyone facing right"
        case .faceLeft: "Row, everyone facing left"
        case .faceMiddle: "Row, facing the middle"
        }
    }
}

/// Puts the people in the Discord call on the 16:9 canvas: one layer each, with
/// an idle and a talking image. Default images come from the Discord avatar.
@MainActor
@Observable
final class CallOverlay {
    static let shared = CallOverlay()

    private let canvasWidth = 1920.0
    private let canvasHeight = 1080.0

    /// The Discord call's people. Your PNGtuber has its own switch (meEnabled).
    var visible = UserDefaults.standard.object(forKey: "overlay.visible") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(visible, forKey: "overlay.visible")
            for member in shown { applyVisibility(member.id) }
        }
    }

    private func applyVisibility(_ id: String) {
        omni_overlay_set_layer_visible(id, id == Self.meID || visible)
    }

    /// Dim people who aren't talking (talking ones stay full brightness).
    var dimQuiet = UserDefaults.standard.object(forKey: "overlay.dimQuiet") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(dimQuiet, forKey: "overlay.dimQuiet")
            for member in shown { loadImages(for: member) }
        }
    }

    /// Edit mode: outlines on the 16:9 preview that can be dragged.
    var arranging = false {
        didSet { sync() }
    }

    /// Placeholder people for arranging when nobody's in a call.
    var showSamples = false {
        didSet { sync() }
    }

    var selected: String?
    private(set) var layouts: [String: MemberLayout] = [:]
    /// Image size per person (from the image file), for the box width.
    private(set) var aspects: [String: Double] = [:]
    private var placed: Set<String> = []

    /// You, as a PNGtuber driven by your own mic (you're left out of the Discord list).
    static let meID = "me"
    static let me = CallMember(id: meID, name: "You", avatarURL: URL(string: "about:blank")!)

    var meEnabled = UserDefaults.standard.object(forKey: "overlay.me") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(meEnabled, forKey: "overlay.me")
            sync()
        }
    }

    /// Mic level (dBFS, after plugins) that counts as talking.
    var meThreshold = UserDefaults.standard.object(forKey: "overlay.meThreshold") as? Double ?? -40 {
        didSet { UserDefaults.standard.set(meThreshold, forKey: "overlay.meThreshold") }
    }

    private(set) var meTalking = false
    private var lastLoud = Date.distantPast
    private var voiceTimer: Timer?

    var hasMeImages: Bool { layouts[Self.meID]?.idlePath != nil }

    static let samples: [CallMember] = [
        CallMember(id: "sample-1", name: "Sample 1", avatarURL: URL(string: "about:blank")!),
        CallMember(id: "sample-2", name: "Sample 2", avatarURL: URL(string: "about:blank")!),
        CallMember(id: "sample-3", name: "Sample 3", avatarURL: URL(string: "about:blank")!),
    ]

    /// Who's on the canvas right now: you (if set up), then the others in the call.
    var shown: [CallMember] {
        let call = DiscordCall.shared
        let others = call.members.filter { $0.id != call.selfID }
        let people = others.isEmpty && showSamples && arranging ? Self.samples : others
        return (meEnabled && hasMeImages ? [Self.me] : []) + people
    }

    private var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniCast/overlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "overlay.layouts"),
           let saved = try? JSONDecoder().decode([String: MemberLayout].self, from: data) {
            layouts = saved
        }
    }

    /// Hooks the overlay to the call; run once the engine is up.
    func start() {
        let call = DiscordCall.shared
        call.onMembersChanged = { [weak self] in self?.sync() }
        call.onSpeaking = { id, speaking in omni_overlay_set_speaking(id, speaking) }
        adoptMeImages()
        sync()
        // 30 checks a second: the mouth keeps up with speech without flicker.
        voiceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { CallOverlay.shared.detectVoice() }
        }
        call.resume()
    }

    /// Talking while the mic is above the threshold, and for a moment after, so
    /// short pauses between words don't snap back to idle.
    private func detectVoice() {
        guard meEnabled, placed.contains(Self.meID) else { return }
        let mutedOnStream = Mixer.shared.channels.first { $0.id == "mic" }?.streamMuted ?? false
        let now = Date()
        if !mutedOnStream, Double(omni_mixer_level(Int32(OMNI_CHANNEL_MIC))) > meThreshold { lastLoud = now }
        let talking = now.timeIntervalSince(lastLoud) < 0.2
        guard talking != meTalking else { return }
        meTalking = talking
        omni_overlay_set_speaking(Self.meID, talking)
    }

    /// Images dropped into the overlay folder as you-idle.* / you-talking.* become
    /// your PNGtuber the first time OmniCast sees them.
    private func adoptMeImages() {
        guard !hasMeImages else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let idle = files.first(where: { $0.deletingPathExtension().lastPathComponent == "you-idle" }) else { return }
        let talk = files.first { $0.deletingPathExtension().lastPathComponent == "you-talking" }
        var l = layouts[Self.meID] ?? MemberLayout(x: 1700, y: 820, size: 420)
        l.idlePath = idle.path
        l.talkPath = talk?.path
        layouts[Self.meID] = l
        save()
    }

    /// Copies a chosen image into OmniCast's own folder, so moving or deleting
    /// the original doesn't break the overlay.
    func importImage(_ url: URL, for id: String, talking: Bool) {
        let name = id == Self.meID ? (talking ? "you-talking" : "you-idle") : "\(id)-\(talking ? "talk" : "idle")-source"
        let dest = folder.appendingPathComponent(name).appendingPathExtension(url.pathExtension)
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.deletingPathExtension().lastPathComponent == name {
            try? FileManager.default.removeItem(at: old)
        }
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return }
        if id == Self.meID, layouts[id] == nil { layouts[id] = MemberLayout(x: 1700, y: 820, size: 420) }
        update(id) { l in
            if talking { l.talkPath = dest.path } else { l.idlePath = dest.path }
        }
        // Same file name, new content: make the engine reload it.
        if let member = shown.first(where: { $0.id == id }) { loadImages(for: member) }
        sync()
    }

    // MARK: Layout

    func layout(for id: String) -> MemberLayout {
        layouts[id] ?? MemberLayout(x: canvasWidth / 2, y: 140, size: 220)
    }

    func boxSize(for id: String) -> CGSize {
        let l = layout(for: id)
        return CGSize(width: l.size * (aspects[id] ?? 1), height: l.size)
    }

    func update(_ id: String, _ change: (inout MemberLayout) -> Void) {
        var l = layout(for: id)
        change(&l)
        l.x = min(max(l.x, 0), canvasWidth)
        l.y = min(max(l.y, 0), canvasHeight)
        l.size = min(max(l.size, 40), canvasHeight)
        let imagesChanged = l.idlePath != layouts[id]?.idlePath || l.talkPath != layouts[id]?.talkPath
        layouts[id] = l
        if !id.hasPrefix("sample-") { save() }
        if imagesChanged, let member = shown.first(where: { $0.id == id }) { loadImages(for: member) }
        place(id)
    }

    /// Lines everyone in the call up across the top, sized to fit, flipped so
    /// they face the chosen way (each image's own facing is taken into account).
    func autoArrange(_ style: ArrangeStyle) {
        let people = shown
        guard !people.isEmpty else { return }
        let slot = canvasWidth / Double(people.count)
        let size = min(260, slot * 0.9)
        for (i, member) in people.enumerated() {
            let x = slot * (Double(i) + 0.5)
            update(member.id) { l in
                l.x = x
                l.y = size / 2 + 24
                l.size = size
                let wantLeft: Bool
                switch style {
                case .faceRight: wantLeft = false
                case .faceLeft: wantLeft = true
                case .faceMiddle: wantLeft = x > canvasWidth / 2
                }
                l.flip = l.facesLeft != wantLeft
            }
        }
    }

    private func save() {
        let real = layouts.filter { !$0.key.hasPrefix("sample-") }
        if let data = try? JSONEncoder().encode(real) {
            UserDefaults.standard.set(data, forKey: "overlay.layouts")
        }
    }

    // MARK: Engine

    /// Adds layers for new people, removes layers for people who left.
    func sync() {
        let people = shown
        let ids = Set(people.map(\.id))
        for gone in placed.subtracting(ids) { omni_overlay_remove(gone) }
        for (i, member) in people.enumerated() where !placed.contains(member.id) {
            if layouts[member.id] == nil {
                layouts[member.id] = freeSpot(index: i, of: people.count)
                if !member.id.hasPrefix("sample-") { save() }
            }
            loadImages(for: member)
        }
        placed = ids
        if let selected, !ids.contains(selected) { self.selected = nil }
    }

    /// Next slot along the top row for someone without a saved spot.
    private func freeSpot(index: Int, of count: Int) -> MemberLayout {
        let slot = canvasWidth / Double(max(count, 4))
        let size = min(220.0, slot * 0.9)
        return MemberLayout(x: slot * (Double(index) + 0.5), y: size / 2 + 24, size: size)
    }

    private func place(_ id: String) {
        let l = layout(for: id)
        let box = boxSize(for: id)
        omni_overlay_place(id, Float(l.x), Float(l.y), Float(box.width), Float(box.height), l.flip,
                           Float(l.size * 0.06))
    }

    /// Writes this person's idle and talking PNGs and hands them to the engine.
    private func loadImages(for member: CallMember) {
        let l = layout(for: member.id)
        let idleURL = folder.appendingPathComponent("\(member.id)-idle.png")
        let talkURL = folder.appendingPathComponent("\(member.id)-talk.png")
        let dim = dimQuiet

        if let idlePath = l.idlePath, let idleFull = NSImage(contentsOfFile: idlePath) {
            let talkFull = l.talkPath.flatMap(NSImage.init(contentsOfFile:)) ?? idleFull
            // Cut away empty transparent space, with one crop for both images so
            // the talking frame lines up exactly with the idle one.
            let (idle, talk) = Self.trimmed(idleFull, talkFull)
            aspects[member.id] = idle.size.width / max(idle.size.height, 1)
            let dimIdle = dim && member.id != Self.meID // a PNGtuber's idle frame stays full colour
            Self.writePNG(Self.render(idle, ring: false, circle: false, alpha: dimIdle ? 0.55 : 1), to: idleURL)
            Self.writePNG(Self.render(talk, ring: false, circle: false, alpha: 1), to: talkURL)
            show(member.id, idleURL, talkURL)
            return
        }

        aspects[member.id] = 1
        if member.id.hasPrefix("sample-") {
            let image = Self.letterAvatar(String(member.name.suffix(1)))
            Self.writePNG(Self.render(image, ring: false, circle: true, alpha: dim ? 0.55 : 1), to: idleURL)
            Self.writePNG(Self.render(image, ring: true, circle: true, alpha: 1), to: talkURL)
            show(member.id, idleURL, talkURL)
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: member.avatarURL),
                  let image = NSImage(data: data) else { return }
            Self.writePNG(Self.render(image, ring: false, circle: true, alpha: dim ? 0.55 : 1), to: idleURL)
            Self.writePNG(Self.render(image, ring: true, circle: true, alpha: 1), to: talkURL)
            // Still in the call by the time the avatar arrived?
            guard self.shown.contains(where: { $0.id == member.id }) else { return }
            self.show(member.id, idleURL, talkURL)
        }
    }

    private func show(_ id: String, _ idle: URL, _ talk: URL) {
        omni_overlay_set_images(id, idle.path, talk.path)
        applyVisibility(id)
        place(id)
        let speaking = shown.first { $0.id == id }?.speaking ?? false
        omni_overlay_set_speaking(id, speaking)
    }

    // MARK: Images

    private static let ringColor = NSColor(red: 0.14, green: 0.65, blue: 0.35, alpha: 1)

    /// Square avatars become circles (with Discord's green ring when talking);
    /// custom images keep their shape. Quiet images are drawn at lower opacity.
    private static func render(_ image: NSImage, ring: Bool, circle: Bool, alpha: CGFloat) -> NSImage {
        let side: CGFloat = 512
        let size = circle ? NSSize(width: side, height: side)
            : NSSize(width: side * image.size.width / max(image.size.height, 1), height: side)
        return NSImage(size: size, flipped: false) { rect in
            let inset: CGFloat = circle ? 24 : 0
            let inner = rect.insetBy(dx: inset, dy: inset)
            NSGraphicsContext.current?.saveGraphicsState()
            if circle { NSBezierPath(ovalIn: inner).addClip() }
            image.draw(in: inner, from: .zero, operation: .sourceOver, fraction: alpha)
            NSGraphicsContext.current?.restoreGraphicsState()
            if ring, circle {
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 10, dy: 10))
                path.lineWidth = 18
                ringColor.setStroke()
                path.stroke()
            }
            return true
        }
    }

    /// Both images cropped to the union of their non-transparent pixels.
    private static func trimmed(_ a: NSImage, _ b: NSImage) -> (NSImage, NSImage) {
        guard let ca = a.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cb = b.cgImage(forProposedRect: nil, context: nil, hints: nil),
              ca.width == cb.width, ca.height == cb.height,
              let ra = opaqueRect(ca), let rb = opaqueRect(cb) else { return (a, b) }
        let r = ra.union(rb).insetBy(dx: -4, dy: -4).intersection(CGRect(x: 0, y: 0, width: ca.width, height: ca.height))
        guard let xa = ca.cropping(to: r), let xb = cb.cropping(to: r) else { return (a, b) }
        return (NSImage(cgImage: xa, size: r.size), NSImage(cgImage: xb, size: r.size))
    }

    /// Bounding box of pixels that aren't (nearly) fully transparent, in image
    /// pixel coordinates (top-left origin, as CGImage cropping expects).
    private static func opaqueRect(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where pixels[row + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        // The bitmap's first row is the image's top row.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func letterAvatar(_ letter: String) -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSColor(red: 0.35, green: 0.40, blue: 0.95, alpha: 1).setFill()
            rect.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 120, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let text = letter as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
                      withAttributes: attrs)
            return true
        }
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }
}
