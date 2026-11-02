import SwiftUI

struct AudioMixerPanel: View {
    var body: some View {
        Panel(title: "Audio") {
            VStack(spacing: 14) {
                ForEach(AudioChannel.allCases) { ChannelStrip(channel: $0) }
            }
        }
    }
}

struct ChannelStrip: View {
    let channel: AudioChannel
    @State private var fader: Double
    @State private var muted: Bool

    init(channel: AudioChannel) {
        self.channel = channel
        _fader = State(initialValue: Engine.shared.fader(channel))
        _muted = State(initialValue: Engine.shared.isMuted(channel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(channel.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(gainLabel).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textDim)
                Button {
                    muted.toggle()
                    Engine.shared.setMuted(channel, muted)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                        .foregroundStyle(muted ? Theme.record : .white.opacity(0.8))
                }
                .buttonStyle(.borderless)
                .help(muted ? "Unmute" : "Mute")
            }
            LevelMeter(channel: channel, muted: muted)
                .frame(height: 10)
            Slider(value: $fader, in: 0...1)
                .controlSize(.mini)
                .onChange(of: fader) { Engine.shared.setVolume(channel, fader: fader) }
        }
    }

    private var gainLabel: String {
        let db = 20 * log10(pow(fader, 3))
        return db < -60 ? "−∞ dB" : String(format: "%.1f dB", db)
    }
}

/// Stereo peak meter, OBS-style colour zones. Drawn with Canvas from a 30 Hz
/// timeline that reads the audio thread's levels directly, so it never touches
/// observation or re-lays-out the window.
struct LevelMeter: View {
    let channel: AudioChannel
    let muted: Bool
    @State private var hold = MeterHold()

    private static let floor: Float = -60

    private static let zones = Gradient(stops: [
        .init(color: Theme.good, location: 0),
        .init(color: Theme.good, location: 0.62),
        .init(color: Theme.warn, location: 0.78),
        .init(color: Theme.record, location: 0.9),
    ])
    private static let mutedZones = Gradient(colors: [.gray, .gray])

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            SwiftUI.Canvas { gc, size in
                draw(in: &gc, size: size, date: context.date)
            }
        }
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, date: Date) {
        let (l, r) = Engine.shared.levels(channel)
        let shown = hold.update(l, r, at: date)
        let barH = (size.height - 2) / 2
        let fill = GraphicsContext.Shading.linearGradient(
            muted ? Self.mutedZones : Self.zones, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
        for (i, db) in [shown.0, shown.1].enumerated() {
            let y = CGFloat(i) * (barH + 2)
            let track = CGRect(x: 0, y: y, width: size.width, height: barH)
            gc.fill(Path(roundedRect: track, cornerRadius: 1.5), with: .color(.white.opacity(0.06)))
            let fraction = CGFloat(max(0, min(1, (db - Self.floor) / -Self.floor)))
            guard fraction > 0 else { continue }
            let bar = CGRect(x: 0, y: y, width: size.width * fraction, height: barH)
            gc.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: fill)
        }
    }
}

/// Instant attack, smooth fall, so the meter is readable at 30 Hz.
final class MeterHold {
    private var shown: (Float, Float) = (-.infinity, -.infinity)
    private var last = Date()

    func update(_ l: Float, _ r: Float, at date: Date) -> (Float, Float) {
        let fall = Float(date.timeIntervalSince(last)) * 24 // dB per second
        last = date
        shown = (max(l, shown.0 - fall), max(r, shown.1 - fall))
        return shown
    }
}
