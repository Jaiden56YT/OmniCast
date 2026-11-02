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

    var visible = UserDefaults.standard.object(forKey: "overlay.visible") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(visible, forKey: "overlay.visible")
            omni_overlay_set_visible(visible)
        }
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

    static let samples: [CallMember] = [
        CallMember(id: "sample-1", name: "Sample 1", avatarURL: URL(string: "about:blank")!),
        CallMember(id: "sample-2", name: "Sample 2", avatarURL: URL(string: "about:blank")!),
        CallMember(id: "sample-3", name: "Sample 3", avatarURL: URL(string: "about:blank")!),
    ]

    /// Who's on the canvas right now.
    var shown: [CallMember] {
        let call = DiscordCall.shared.members
        return call.isEmpty && showSamples && arranging ? Self.samples : call
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
        omni_overlay_set_visible(visible)
        call.resume()
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

        if let idlePath = l.idlePath, let idle = NSImage(contentsOfFile: idlePath) {
            let talk = l.talkPath.flatMap(NSImage.init(contentsOfFile:)) ?? idle
            aspects[member.id] = idle.size.width / max(idle.size.height, 1)
            Self.writePNG(Self.render(idle, ring: false, circle: false, alpha: dim ? 0.55 : 1), to: idleURL)
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
