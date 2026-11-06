import AppKit
import Foundation
import Observation
import OmniEngine

/// A "now playing" card for Spotify. It fades in when a song starts (or playback
/// resumes), stays for `holdSeconds`, then fades out; pausing fades it out at once.
///
/// Spotify posts every play/pause/track change as a distributed notification, so
/// this needs no permission or API key. Album art comes from Spotify's public
/// oEmbed endpoint.
@MainActor
@Observable
final class SpotifyOverlay {
    static let shared = SpotifyOverlay()

    enum Corner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topLeft: "Top left"
            case .topRight: "Top right"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            }
        }
        var isTop: Bool { self == .topLeft || self == .topRight }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    }

    struct Track: Equatable {
        var id: String
        var name: String
        var artist: String
        var playing: Bool
    }

    var enabled = UserDefaults.standard.object(forKey: "spotify.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "spotify.enabled")
            if !enabled { fade(to: 0) }
        }
    }

    var corner = Corner(rawValue: UserDefaults.standard.string(forKey: "spotify.corner") ?? "") ?? .bottomLeft {
        didSet {
            UserDefaults.standard.set(corner.rawValue, forKey: "spotify.corner")
            place()
        }
    }

    var showOnVertical = UserDefaults.standard.object(forKey: "spotify.vertical") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showOnVertical, forKey: "spotify.vertical")
            place()
        }
    }

    let holdSeconds: TimeInterval = 30
    private(set) var track: Track?

    private static let key = "spotify"
    private static let cardSize = CGSize(width: 640, height: 152)
    private var opacity: Float = 0
    private var target: Float = 0
    private var fadeTimer: Timer?
    private var hideTimer: Timer?
    private var shownID: String?
    private var renderTask: Task<Void, Never>?
    private var started = false

    private var imageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniCast/overlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spotify-card.png")
    }

    /// Run once the engine is up.
    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { SpotifyOverlay.shared.playbackChanged(info) }
        }
    }

    /// Shows the card now, with the current song or a sample, so it can be checked.
    func preview() {
        show(track ?? Track(id: "", name: "Song title goes here", artist: "Artist name", playing: true))
    }

    private func playbackChanged(_ info: [AnyHashable: Any]) {
        let playing = info["Player State"] as? String == "Playing"
        let new = Track(id: info["Track ID"] as? String ?? "",
                        name: info["Name"] as? String ?? "",
                        artist: info["Artist"] as? String ?? "",
                        playing: playing)
        let resumed = playing && track?.playing == false
        let spotifySelected = MusicSync.shared.source == .spotify
        if new.id != track?.id && spotifySelected { MusicSync.shared.songChanged() }
        track = new
        guard enabled, spotifySelected else { return }
        if !playing {
            shownID = nil
            fade(to: 0)
        } else if new.id != shownID || resumed, !new.name.isEmpty {
            show(new)
        }
    }

    /// The music switch moved: hide the card for other apps, or show the Spotify
    /// song that's already playing when Spotify comes back.
    func sourceChanged() {
        shownID = nil
        if MusicSync.shared.source != .spotify {
            fade(to: 0)
        } else if enabled, let track, track.playing, !track.name.isEmpty {
            show(track)
        }
    }

    // MARK: Showing

    private func show(_ track: Track) {
        shownID = track.id
        renderTask?.cancel()
        renderTask = Task {
            let art = await Self.artwork(for: track.id)
            guard !Task.isCancelled else { return }
            guard Self.writePNG(Self.card(for: track, art: art), to: imageURL) else { return }
            omni_layer_set_image(Self.key, imageURL.path)
            place()
            fade(to: 1)
            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: holdSeconds, repeats: false) { _ in
                MainActor.assumeIsolated { SpotifyOverlay.shared.fade(to: 0) }
            }
        }
    }

    private func place() {
        let size = Self.cardSize
        let margin = 40.0
        // 16:9: the chosen corner.
        let hx = corner.isLeft ? margin : 1920 - size.width - margin
        let hy = corner.isTop ? margin : 1080 - size.height - margin
        omni_layer_place(Self.key, OMNI_CANVAS_HORIZONTAL, true, Float(hx), Float(hy),
                         Float(size.width), Float(size.height))
        // 9:16: centred, at the top or just above the camera (the screen's bottom edge).
        let vx = (1080 - size.width) / 2
        let vy = corner.isTop ? 48 : 960 - size.height - 32
        omni_layer_place(Self.key, OMNI_CANVAS_VERTICAL, showOnVertical, Float(vx), Float(vy),
                         Float(size.width), Float(size.height))
    }

    /// Eases the card's opacity toward `to` over about half a second.
    private func fade(to value: Float) {
        if value == 0 { hideTimer?.invalidate() }
        target = value
        guard fadeTimer == nil, opacity != target else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { SpotifyOverlay.shared.fadeStep() }
        }
    }

    private func fadeStep() {
        let step: Float = 1.0 / 15
        opacity = target > opacity ? min(target, opacity + step) : max(target, opacity - step)
        // Smoothstep, so the fade eases in and out instead of moving linearly.
        let eased = opacity * opacity * (3 - 2 * opacity)
        omni_layer_set_opacity(Self.key, eased)
        if opacity == target {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    // MARK: Card image

    private static let green = NSColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1)

    /// "spotify:track:ID" → album art via oEmbed (no key needed).
    private static func artwork(for trackID: String) async -> NSImage? {
        let parts = trackID.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify",
              var comps = URLComponents(string: "https://open.spotify.com/oembed") else { return nil }
        comps.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let thumb = (json["thumbnail_url"] as? String).flatMap(URL.init(string:)),
              let (imageData, _) = try? await URLSession.shared.data(from: thumb) else { return nil }
        return NSImage(data: imageData)
    }

    /// The card at twice canvas size, for crisp text after scaling.
    private static func card(for track: Track, art: NSImage?) -> NSBitmapImageRep? {
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

        let bounds = CGRect(origin: .zero, size: size)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 26, yRadius: 26)
        NSColor(white: 0.06, alpha: 0.82).setFill()
        card.fill()
        NSColor(white: 1, alpha: 0.10).setStroke()
        card.lineWidth = 1.5
        card.stroke()

        // Album art, or a quiet placeholder.
        let artRect = CGRect(x: 16, y: 16, width: size.height - 32, height: size.height - 32)
        let artPath = NSBezierPath(roundedRect: artRect, xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState()
        artPath.addClip()
        if let art {
            art.draw(in: artRect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSColor(white: 0.18, alpha: 1).setFill()
            artRect.fill()
            let note = NSAttributedString(string: "♪", attributes: [
                .font: NSFont.systemFont(ofSize: 54, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.5),
            ])
            let ns = note.size()
            note.draw(at: CGPoint(x: artRect.midX - ns.width / 2, y: artRect.midY - ns.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()

        let textX = artRect.maxX + 22
        let textWidth = size.width - textX - 24
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail

        // Three-bar equalizer mark + "Now playing".
        var x = textX
        for (i, h) in [10.0, 16.0, 12.0].enumerated() {
            let bar = CGRect(x: x + Double(i) * 6, y: 106, width: 3.5, height: h)
            green.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.75, yRadius: 1.75).fill()
        }
        x += 26
        NSAttributedString(string: "Now playing", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: green,
        ]).draw(at: CGPoint(x: x, y: 103))

        NSAttributedString(string: track.name, attributes: [
            .font: NSFont.systemFont(ofSize: 32, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: truncating,
        ]).draw(in: CGRect(x: textX, y: 56, width: textWidth, height: 42))

        NSAttributedString(string: track.artist, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.62),
            .paragraphStyle: truncating,
        ]).draw(in: CGRect(x: textX, y: 24, width: textWidth, height: 30))
        return rep
    }

    private static func writePNG(_ rep: NSBitmapImageRep?, to url: URL) -> Bool {
        guard let png = rep?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url, options: .atomic)) != nil
    }
}

import SwiftUI

/// Sources panel row for the music: which app is on stream, and the Spotify card.
struct SpotifySourceRow: View {
    @Bindable private var spotify = SpotifyOverlay.shared
    @Bindable private var sync = MusicSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "music.note").frame(width: 18)
                Text("Music").font(.system(size: 12))
                Spacer()
                Menu {
                    Button("Preview card") { spotify.preview() }
                    Picker("Corner", selection: $spotify.corner) {
                        ForEach(SpotifyOverlay.Corner.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Also on 9:16", isOn: $spotify.showOnVertical)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!Engine.shared.running)
                Button { spotify.enabled.toggle() } label: {
                    Image(systemName: spotify.enabled ? "eye" : "eye.slash")
                        .foregroundStyle(spotify.enabled ? .white.opacity(0.8) : Theme.textDim)
                }
                .buttonStyle(.borderless)
                .help(spotify.enabled ? "Hide the now-playing card" : "Show the now-playing card")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))

            Picker("", selection: $sync.source) {
                ForEach(MusicApp.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.leading, 26)
            .disabled(!Engine.shared.running)
            .help("Which app's music is on stream. The other is muted on stream, and Muze follows this one.")

            Group {
                if sync.source != .spotify {
                    Text("No song card: \(sync.source.name) doesn't share what's playing")
                        .foregroundStyle(Theme.textDim)
                } else if let track = spotify.track, track.playing {
                    Text("\(track.name) · \(track.artist)").foregroundStyle(Theme.good)
                } else {
                    Text("Shows for 30 s when a song starts").foregroundStyle(Theme.textDim)
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
            .padding(.leading, 26)
        }
    }
}
