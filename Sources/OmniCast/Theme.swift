import SwiftUI

/// Dark control-room palette. The previews are the brightest thing on screen;
/// everything around them stays quiet so the picture reads first.
enum Theme {
    static let stage = Color(white: 0.045)
    static let background = Color(white: 0.085)
    static let panel = Color(white: 0.12)
    static let raised = Color(white: 0.16)
    static let hairline = Color.white.opacity(0.07)
    static let textDim = Color.white.opacity(0.55)

    static let record = Color(red: 0.95, green: 0.23, blue: 0.21)
    static let live = Color(red: 0.93, green: 0.27, blue: 0.55)
    static let good = Color(red: 0.30, green: 0.80, blue: 0.47)
    static let warn = Color(red: 0.98, green: 0.76, blue: 0.25)
}

struct Panel<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textDim)
                Spacer(minLength: 0)
                accessory
            }
            .frame(height: 20)
            content
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        accessory = EmptyView()
        self.content = content()
    }
}

/// Small rounded status label, e.g. "REC 00:01:23".
struct Badge: View {
    let text: String
    let color: Color

    // No pulsing animation on purpose: it would make SwiftUI redraw every display
    // frame while recording, for nothing.
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .bold).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
}

func formatBytes(_ bytes: some BinaryInteger) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
