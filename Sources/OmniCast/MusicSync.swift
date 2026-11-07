import AppKit
import Foundation
import Observation
import OmniEngine

/// The music apps the stream switches between. Only one is on stream at a time.
enum MusicApp: String, CaseIterable, Identifiable {
    case spotify = "com.spotify.client"
    case appleMusic = "com.apple.Music"
    case youtubeMusic = "music.youtube.com"
    case untitled = "com.untitledinbrackets.untitled-macos"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        case .youtubeMusic: "YouTube Music"
        case .untitled: "[untitled]"
        }
    }

    /// The app whose audio is the music's mixer channel. YouTube Music plays inside
    /// Chrome, so its channel is Chrome's (all of Chrome's sound).
    var channelID: String { self == .youtubeMusic ? "com.google.Chrome" : rawValue }
    var channelName: String { self == .youtubeMusic ? "Google Chrome" : name }

    var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: channelID) != nil }

    /// Whether OmniCast reads the song through Accessibility (the others announce it).
    var needsAccessibility: Bool { self == .untitled || self == .youtubeMusic }
}

/// Makes Muze follow the music playing in the selected music app: Muze Auto Key
/// runs on that app's channel and publishes the key (Muze, set to Key Link:
/// Follow, takes it), and the channel's beat is tracked to give Muze the tempo.
@MainActor
@Observable
final class MusicSync {
    static let shared = MusicSync()

    /// The music app on stream: Muze follows it, the other is muted on stream, and
    /// the now-playing card shows only for Spotify (other apps don't share songs).
    var source = MusicApp(rawValue: UserDefaults.standard.string(forKey: "music.source") ?? "") ?? .spotify {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "music.source")
            Mixer.shared.selectMusicApp(source)
            songChanged()
            applySource()
            SpotifyOverlay.shared.sourceChanged()
        }
    }

    var enabled = UserDefaults.standard.object(forKey: "music.follow") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "music.follow")
            applySource()
        }
    }

    private(set) var bpm: Double?
    private(set) var key: String?
    private(set) var following = false
    var autoKeyInstalled: Bool { omni_music_auto_key_installed() }

    private var readings: [Double] = []
    private var timer: Timer?
    /// The channel Auto Key is on now, so it isn't torn down and reloaded for nothing.
    private var followedIndex: Int32?

    func start() {
        applySource()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { MusicSync.shared.tick() }
        }
    }

    /// Call when the mixer's channels change: follows the music app's channel if it has one.
    func applySource() {
        let index = Mixer.shared.indices[source.channelID]
        following = enabled && index != nil
        let target = following ? index : nil
        if target != followedIndex {
            omni_music_follow(target ?? -1)
            followedIndex = target
        }
        if !following {
            bpm = nil
            readings = []
        }
    }

    /// A new song: its tempo is learned from scratch.
    func songChanged() {
        readings = []
        omni_music_tempo_reset()
    }

    private func tick() {
        var name = [CChar](repeating: 0, count: 64)
        let newKey = omni_music_muze_key(&name, name.count) ? String(cString: name) : nil
        if newKey != key, let newKey {
            print("[OmniCast] Muze key: \(newKey)")
            fflush(stdout)
        }
        key = newKey
        guard following else { return }
        var confidence = 0.0
        let estimate = omni_music_tempo(&confidence)
        guard estimate > 0, confidence > 8 else { return }
        // Median of the last five readings, so one odd window doesn't jump Muze around.
        readings.append(estimate)
        readings = Array(readings.suffix(5))
        var value = readings.sorted()[readings.count / 2]
        if abs(value - value.rounded()) < 0.35 { value = value.rounded() } // songs are almost always whole BPM
        // Small wobble (122 vs 122.5) would re-time Muze's synced effects for nothing.
        if let current = bpm, abs(current - value) < 0.9 { return }
        if bpm != value {
            bpm = value
            omni_music_set_tempo(value)
            print(String(format: "[OmniCast] Music tempo: %.1f BPM (confidence %.0f)", value, confidence))
            fflush(stdout)
        }
    }
}
