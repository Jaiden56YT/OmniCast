import SwiftUI

/// Sources panel row for stream alerts.
struct AlertSourceRow: View {
    @Bindable private var alerts = AlertOverlay.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge").frame(width: 18)
                Text("Alerts").font(.system(size: 12))
                Spacer()
                Menu {
                    Button("Show a test alert") { alerts.test() }
                    Button("Clear the queue") { alerts.clearQueue() }
                    Divider()
                    Toggle("Also on 9:16", isOn: $alerts.showOnVertical)
                    SettingsLink { Text("Alert settings…") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!Engine.shared.running)
                Button { alerts.enabled.toggle() } label: {
                    Image(systemName: alerts.enabled ? "bell" : "bell.slash")
                        .foregroundStyle(alerts.enabled ? .white.opacity(0.8) : Theme.textDim)
                }
                .buttonStyle(.borderless)
                .help(alerts.enabled ? "Turn alerts off" : "Turn alerts on")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            Text(summary)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .padding(.leading, 26)
        }
    }

    private var summary: String {
        if let current = alerts.current { return "Showing: \(current.summary)" }
        if !alerts.enabled { return "Off" }
        if let last = alerts.recent.first { return "Last: \(last.summary)" }
        return "Waiting for follows, subs and tips"
    }
}

/// Settings → Alerts.
struct AlertSettingsView: View {
    @Bindable private var alerts = AlertOverlay.shared
    private var sources: AlertSources { .shared }
    private var chat: ChatHub { .shared }

    var body: some View {
        Form {
            Section {
                Toggle("Show alerts on stream", isOn: $alerts.enabled)
                ForEach(StreamAlert.Kind.allCases) { kind in
                    Toggle(isOn: Binding(get: { alerts.kinds.contains(kind) },
                                         set: { on in
                                             if on { alerts.kinds.insert(kind) } else { alerts.kinds.remove(kind) }
                                         })) {
                        Label(kind.label, systemImage: kind.symbol)
                    }
                    .disabled(!alerts.enabled)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("One at a time from a queue. Nothing is ever posted to any platform.")
            }
            Section("Look") {
                Picker("Each alert stays for", selection: $alerts.seconds) {
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("8 seconds").tag(8.0)
                    Text("12 seconds").tag(12.0)
                }
                Toggle("Also show on 9:16", isOn: $alerts.showOnVertical)
                HStack {
                    Button("Show a test alert") { alerts.test() }
                        .disabled(!Engine.shared.running)
                    Text("Move and resize the card with Arrange on the preview.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                source("Twitch subs, gift subs, bits, raids", status: chat.status[.twitch]?.label ?? "Off")
                source("Twitch follows", status: sources.twitchStatus)
                source("YouTube Super Chats, stickers, memberships, gifts", status: chat.status[.youtube]?.label ?? "Off")
                source("YouTube new subscribers", status: sources.youtubeStatus)
                source("Kick subs, gift subs, Kicks, hosts", status: chat.status[.kick]?.label ?? "Off")
                Button("Reconnect follow feeds") { sources.restart() }
            } header: {
                Text("Where alerts come from")
            } footer: {
                Text("Most alerts arrive with the chat (Settings → Chat). Twitch follows and YouTube subscribers need the account signed in under Accounts. YouTube only lists subscribers whose subscriptions are public. Kick doesn't send follows to apps it hasn't been set up to call back, so Kick follows don't show.")
            }
            if !alerts.recent.isEmpty {
                Section("Recent") {
                    ForEach(alerts.recent) { alert in
                        HStack {
                            Text(alert.summary).lineLimit(1)
                            Spacer()
                            Text(alert.received, style: .time).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func source(_ label: String, status: String) -> some View {
        LabeledContent(label) {
            Text(status)
                .foregroundStyle(status.hasPrefix("Connected") || status.hasPrefix("Listening") || status.hasPrefix("Checking")
                                 ? Theme.good : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

struct AlertArrangeBox: View {
    let canvas: Canvas
    let scale: CGFloat
    private var alerts: AlertOverlay { .shared }

    var body: some View {
        if alerts.enabled, canvas == .horizontal || alerts.showOnVertical {
            ArrangeBox(id: "alert-\(canvas.rawValue)", label: "Alerts", icon: "bell.badge",
                       tint: Theme.warn, scale: scale, keepShape: true, box: alerts.box(canvas),
                       update: { alerts.updateBox(canvas, $0) }, reset: { alerts.resetBox(canvas) })
        }
    }
}
