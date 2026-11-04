import AppKit
import ImageIO
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

    // MARK: Camera position

    struct Box: Codable, Equatable {
        var x: Double, y: Double, w: Double, h: Double
    }

    /// Where the engine puts the camera unless you've moved it.
    static func defaultCamera(_ canvas: Canvas) -> Box {
        canvas == .horizontal
            ? Box(x: 1920 - 480 - 27, y: 1080 - 270 - 27, w: 480, h: 270)
            : Box(x: 0, y: 960, w: 1080, h: 960)
    }

    private(set) var cameraBoxes: [Canvas: Box] = {
        var boxes: [Canvas: Box] = [:]
        for c in Canvas.allCases {
            if let data = UserDefaults.standard.data(forKey: "layout.camera.\(c.rawValue)"),
               let box = try? JSONDecoder().decode(Box.self, from: data) { boxes[c] = box }
        }
        return boxes
    }()

    func cameraBox(_ canvas: Canvas) -> Box { cameraBoxes[canvas] ?? Self.defaultCamera(canvas) }

    func updateCamera(_ canvas: Canvas, _ change: (inout Box) -> Void) {
        let size = canvas == .horizontal ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        var box = cameraBox(canvas)
        change(&box)
        box.w = min(max(box.w, 80), size.width)
        box.h = min(max(box.h, 60), size.height)
        box.x = min(max(box.x, -box.w / 2), size.width - box.w / 2)
        box.y = min(max(box.y, -box.h / 2), size.height - box.h / 2)
        cameraBoxes[canvas] = box
        if let data = try? JSONEncoder().encode(box) {
            UserDefaults.standard.set(data, forKey: "layout.camera.\(canvas.rawValue)")
        }
        placeCamera(canvas)
    }

    func resetCamera(_ canvas: Canvas) {
        cameraBoxes[canvas] = nil
        UserDefaults.standard.removeObject(forKey: "layout.camera.\(canvas.rawValue)")
        placeCamera(canvas)
    }

    private func placeCamera(_ canvas: Canvas) {
        let b = cameraBox(canvas)
        omni_camera_place(canvas == .vertical ? OMNI_CANVAS_VERTICAL : OMNI_CANVAS_HORIZONTAL,
                          Float(b.x), Float(b.y), Float(b.w), Float(b.h))
    }
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
        Canvas.allCases.forEach(placeCamera)
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

        if let idlePath = l.idlePath, let idleFrames = Self.frames(at: idlePath) {
            let talkFrames = l.talkPath.flatMap(Self.frames(at:)) ?? idleFrames
            // One crop for every frame of both animations, so they line up exactly
            // and the empty transparent space around the character is gone.
            let crop = Self.opaqueUnion(idleFrames.images + talkFrames.images)
            aspects[member.id] = crop.map { $0.width / max($0.height, 1) }
                ?? Double(idleFrames.images[0].width) / Double(max(idleFrames.images[0].height, 1))
            let dimIdle = dim && member.id != Self.meID // a PNGtuber's idle frames stay full colour
            let idlePaths = Self.writeFrames(idleFrames.images, crop: crop, alpha: dimIdle ? 0.55 : 1,
                                             to: "\(member.id)-idle", in: folder)
            let talkPaths = Self.writeFrames(talkFrames.images, crop: crop, alpha: 1,
                                             to: "\(member.id)-talk", in: folder)
            showFrames(member.id, idlePaths, idleFrames.delays, talkPaths, talkFrames.delays)
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

    private func showFrames(_ id: String, _ idle: [String], _ idleDelays: [Float],
                            _ talk: [String], _ talkDelays: [Float]) {
        guard !idle.isEmpty else { return }
        withCStrings(idle) { idlePtrs in
            withCStrings(talk) { talkPtrs in
                omni_overlay_set_frames(id, idlePtrs, idleDelays, Int32(idle.count),
                                        talkPtrs, talkDelays, Int32(talk.count))
            }
        }
        applyVisibility(id)
        place(id)
        let speaking = id == Self.meID ? meTalking : (shown.first { $0.id == id }?.speaking ?? false)
        omni_overlay_set_speaking(id, speaking)
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

    struct Frames {
        var images: [CGImage]
        var delays: [Float] // seconds
    }

    /// Every frame of an image file with its delay: animated AVIF, GIF, APNG,
    /// WebP and HEICS, or a single frame for a still image.
    static func frames(at path: String) -> Frames? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        var result = Frames(images: [], delays: [])
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            result.images.append(image)
            result.delays.append(frameDelay(source, i))
        }
        return result.images.isEmpty ? nil : result
    }

    /// Each format keeps its timing in its own dictionary ({GIF}, {PNG}, {AVIS}…)
    /// under the same key names, so look in all of them.
    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Float {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else { return 0.1 }
        for case let dict as [String: Any] in props.values {
            for key in ["UnclampedDelayTime", "DelayTime"] {
                if let value = (dict[key] as? NSNumber)?.floatValue, value > 0 { return value }
            }
        }
        return 0.1
    }

    /// Union of the non-transparent pixels of all frames (top-left origin), with a
    /// little margin. Nil when the frames differ in size or are fully transparent.
    private static func opaqueUnion(_ images: [CGImage]) -> CGRect? {
        guard let first = images.first, images.allSatisfy({ $0.width == first.width && $0.height == first.height })
        else { return nil }
        var union: CGRect?
        for image in images {
            guard let r = opaqueRect(image) else { continue }
            union = union.map { $0.union(r) } ?? r
        }
        return union?.insetBy(dx: -4, dy: -4).intersection(CGRect(x: 0, y: 0, width: first.width, height: first.height))
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

    /// Writes cropped frames as PNGs (keeping full alpha) and returns their paths.
    private static func writeFrames(_ images: [CGImage], crop: CGRect?, alpha: CGFloat, to base: String,
                                    in folder: URL) -> [String] {
        images.enumerated().compactMap { i, image in
            guard var frame = crop.flatMap({ image.cropping(to: $0) }) ?? Optional(image) else { return nil }
            if alpha < 1, let faded = faded(frame, alpha) { frame = faded }
            let url = folder.appendingPathComponent("\(base)-\(i).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, frame, nil)
            return CGImageDestinationFinalize(dest) ? url.path : nil
        }
    }

    private static func faded(_ image: CGImage, _ alpha: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAlpha(alpha)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
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

/// Calls body with a C array of C strings that live for the call.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let owned = strings.map { strdup($0) }
    defer { owned.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = owned.isEmpty ? [nil] : owned.map { UnsafePointer($0) }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
