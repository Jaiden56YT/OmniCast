import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit

/// Reads what [untitled] is playing from its player bar, for the now-playing card.
///
/// [untitled] doesn't announce its songs, and macOS keeps the system's Now Playing
/// to Apple's own apps, so this reads the bar through Accessibility (which you
/// allow OmniCast once). The bar is a flat row: artwork, title, the two times,
/// "album · artist", then Previous, Play/Pause, Next; it's found by its Previous
/// button. Artwork is taken from [untitled]'s window with ScreenCaptureKit.
@MainActor
@Observable
final class UntitledNowPlaying {
    static let shared = UntitledNowPlaying()

    /// Whether OmniCast may read other apps' UI (Privacy & Security → Accessibility).
    private(set) var trusted = AXIsProcessTrusted()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var bar: AXUIElement?
    @ObservationIgnored private var asked = false
    /// Where the cover was on screen at the last read, for the artwork grab.
    @ObservationIgnored private var coverRect: CGRect?
    @ObservationIgnored private var pid: pid_t = 0

    /// Polls once a second while [untitled] is the music source.
    func update() {
        let want = MusicSync.shared.source == .untitled
        if want, timer == nil {
            askForAccessOnce()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { UntitledNowPlaying.shared.poll() }
            }
            poll()
        } else if !want {
            timer?.invalidate()
            timer = nil
            bar = nil
        }
    }

    /// The first time a music app that's read through Accessibility is picked.
    func askForAccessOnce() {
        guard !AXIsProcessTrusted(), !asked else { return }
        asked = true
        requestAccess()
    }

    /// Shows macOS's prompt that leads to Privacy & Security → Accessibility.
    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func poll() {
        trusted = AXIsProcessTrusted()
        guard trusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: MusicApp.untitled.rawValue).first
        else { return }
        if app.processIdentifier != pid {
            pid = app.processIdentifier
            bar = nil
        }
        guard let track = read() else { return }
        SpotifyOverlay.shared.received(track)
    }

    // MARK: Reading the player bar

    private func read() -> SpotifyOverlay.Track? {
        if bar == nil || children(bar!).isEmpty { bar = findBar() }
        guard let bar else { return nil }
        let items = children(bar)
        guard let prev = items.firstIndex(where: { string($0, kAXIdentifierAttribute) == "backward.end.fill" }),
              prev + 1 < items.count else {
            self.bar = nil
            return nil
        }
        // Back from Previous to the bar's artwork: title, times, "album · artist".
        var texts: [String] = []
        var art: AXUIElement?
        for e in items[..<prev].reversed() {
            let role = string(e, kAXRoleAttribute)
            if role == kAXImageRole as String { art = e; break }
            if role == kAXStaticTextRole as String, let v = string(e, kAXValueAttribute), !v.isEmpty {
                texts.insert(v, at: 0)
            }
        }
        let isTime = { (s: String) in s.range(of: #"^-?\d+:\d\d(:\d\d)?$"#, options: .regularExpression) != nil }
        let words = texts.filter { !isTime($0) }
        guard let title = words.first else { return nil }
        let subtitle = words.count > 1 ? words.last! : ""
        let parts = subtitle.components(separatedBy: " · ")
        let album = parts.count > 1 ? parts.dropLast().joined(separator: " · ") : ""
        let artist = parts.last ?? ""

        let play = items[prev + 1]
        let playing = (string(play, kAXIdentifierAttribute) ?? "").contains("pause")
            || string(play, kAXDescriptionAttribute) == "Pause"

        coverRect = bigCover(in: items, album: album) ?? art.flatMap(frame)
        return SpotifyOverlay.Track(id: "\(title)|\(subtitle)", name: title, artist: artist, playing: playing,
                                    source: .untitled)
    }

    /// The album page's large cover, when the page shown is the playing album: much
    /// sharper than the player bar's thumbnail.
    private func bigCover(in items: [AXUIElement], album: String) -> CGRect? {
        guard !album.isEmpty,
              let name = items.firstIndex(where: {
                  string($0, kAXRoleAttribute) == kAXTextFieldRole as String && string($0, kAXValueAttribute) == album
              }) else { return nil }
        return items[..<name].lazy
            .filter { self.string($0, kAXRoleAttribute) == kAXImageRole as String }
            .compactMap(frame)
            .first { $0.width > 100 && abs($0.width - $0.height) < 4 }
    }

    /// The view holding the Previous button, searched for in [untitled]'s windows.
    private func findBar() -> AXUIElement? {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var budget = 3000
        func search(_ e: AXUIElement) -> AXUIElement? {
            for c in children(e) {
                budget -= 1
                if budget < 0 { return nil }
                if string(c, kAXIdentifierAttribute) == "backward.end.fill" { return e }
                if let found = search(c) { return found }
            }
            return nil
        }
        let windows = (value(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in windows {
            if let found = search(w) { return found }
        }
        return nil
    }

    private func value(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }

    private func string(_ e: AXUIElement, _ attribute: String) -> String? { value(e, attribute) as? String }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Screen frame, top-left origin (the same space as ScreenCaptureKit's window frames).
    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return size.width > 0 ? CGRect(origin: origin, size: size) : nil
    }

    // MARK: Artwork

    /// The cover as [untitled] shows it, grabbed from its window (it can be behind
    /// other windows). Nil without Screen Recording permission or a visible cover.
    func artwork() async -> NSImage? {
        guard let rect = coverRect, pid != 0,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: {
                  $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.contains(rect)
              }) else { return nil }
        let config = SCStreamConfiguration()
        config.sourceRect = rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        return NSImage(cgImage: image, size: rect.size)
    }
}
