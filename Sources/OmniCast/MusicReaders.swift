import AppKit
import ApplicationServices
import Foundation

/// Apple Music's current song. Music posts every play/pause/track change as a
/// distributed notification (like Spotify), so this needs no permission.
@MainActor
enum AppleMusicNowPlaying {
    static func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { received(info) }
        }
    }

    private static func received(_ info: [AnyHashable: Any]) {
        let name = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        let id = (info["PersistentID"].map { "\($0)" }) ?? "\(name)|\(artist)"
        SpotifyOverlay.shared.received(SpotifyOverlay.Track(
            id: id, name: name, artist: artist,
            playing: info["Player State"] as? String == "Playing", source: .appleMusic))
    }
}

/// YouTube Music's current song, read from its window title. YouTube Music runs in
/// Chrome (as an installed web app or a tab), so it has no app of its own to ask:
/// the window title is "<song> | YouTube Music", and Chrome adds "Audio playing"
/// while it's playing. Needs Accessibility, like [untitled].
@MainActor
final class YouTubeMusicNowPlaying {
    static let shared = YouTubeMusicNowPlaying()

    private var timer: Timer?

    /// Polls once a second while YouTube Music is the music source.
    func update() {
        let want = MusicSync.shared.source == .youtubeMusic
        if want, timer == nil {
            UntitledNowPlaying.shared.askForAccessOnce()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { YouTubeMusicNowPlaying.shared.poll() }
            }
            poll()
        } else if !want {
            timer?.invalidate()
            timer = nil
        }
    }

    private func poll() {
        guard AXIsProcessTrusted(),
              let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: MusicApp.youtubeMusic.channelID).first
        else { return }
        let root = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var value: AnyObject?
        AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
        for window in (value as? [AXUIElement]) ?? [] {
            var title: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            if let title = title as? String, let track = Self.track(fromTitle: title) {
                SpotifyOverlay.shared.received(track)
                return
            }
        }
    }

    /// Window titles look like "Wubbaduck - Danger | YouTube Music - Audio playing -
    /// Google Chrome - Profile" (Chrome adds "Audio playing" while it plays; some
    /// titles instead start with "YouTube Music - " and end with " 🔊"). The page
    /// title is "Artist - Song"; when it has more or fewer " - " than that, it's an
    /// upload's own title, shown whole with "YouTube Music" underneath.
    static func track(fromTitle raw: String) -> SpotifyOverlay.Track? {
        var title = raw.replacingOccurrences(of: " 🔊", with: "")
        if title.hasPrefix("YouTube Music - ") { title.removeFirst("YouTube Music - ".count) }
        guard let marker = title.range(of: " | YouTube Music") ?? title.range(of: " - YouTube Music") else {
            return nil
        }
        let page = String(title[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !page.isEmpty, page != "YouTube Music" else { return nil }
        let playing = raw.contains("Audio playing") || raw.contains("🔊")
        let parts = page.components(separatedBy: " - ")
        let (name, artist) = parts.count == 2 ? (parts[1], parts[0]) : (page, "YouTube Music")
        return SpotifyOverlay.Track(id: page, name: name, artist: artist, playing: playing, source: .youtubeMusic)
    }
}

/// Album art from Apple's public iTunes Search API (no key), for apps that don't
/// hand over their own artwork. Finds released songs; uploads usually come back
/// empty and the card shows its placeholder.
@MainActor
enum ArtworkSearch {
    static func image(song: String, artist: String) async -> NSImage? {
        let term = artist == "YouTube Music" ? song : "\(artist) \(song)"
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let small = first["artworkUrl100"] as? String,
              let big = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600")),
              let (imageData, _) = try? await URLSession.shared.data(from: big) else { return nil }
        return NSImage(data: imageData)
    }
}
