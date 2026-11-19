import SwiftUI

/// Sources panel row for the merged chat.
struct ChatSourceRow: View {
    @Bindable private var overlay = ChatOverlay.shared
    private var hub: ChatHub { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right").frame(width: 18)
                Text("Chat").font(.system(size: 12))
                Spacer()
                Menu {
                    Button("Add test messages") { hub.addTestMessages() }
                    Button("Clear chat") { hub.clear() }
                    Divider()
                    Toggle("Also on 9:16", isOn: $overlay.showOnVertical)
                    SettingsLink { Text("Chat settings…") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!Engine.shared.running)
                Button { overlay.visible.toggle() } label: {
                    Image(systemName: overlay.visible ? "eye" : "eye.slash")
                        .foregroundStyle(overlay.visible ? .white.opacity(0.8) : Theme.textDim)
                }
                .buttonStyle(.borderless)
                .help(overlay.visible ? "Hide chat" : "Show chat")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            Text(hub.summary)
                .font(.system(size: 10))
                .foregroundStyle(hub.status.values.contains(.connected) ? Theme.good : Theme.textDim)
                .lineLimit(1)
                .padding(.leading, 26)
                .help(ChatPlatform.allCases.map { "\($0.name): \(hub.status[$0]?.label ?? "Off")" }.joined(separator: "\n"))
        }
    }
}

/// Settings → Chat.
struct ChatSettingsView: View {
    @Bindable private var hub = ChatHub.shared
    @Bindable private var overlay = ChatOverlay.shared
    @State private var youtube = ChatHub.shared.settings.youtube
    @State private var twitch = ChatHub.shared.settings.twitch
    @State private var kick = ChatHub.shared.settings.kick
    @State private var kickRoom = ChatHub.shared.settings.kickChatroom.map(String.init) ?? ""

    var body: some View {
        Form {
            Section {
                channel(.youtube, "YouTube handle", text: $youtube, prompt: "yourhandle")
                channel(.twitch, "Twitch channel", text: $twitch, prompt: "yourchannel")
                channel(.kick, "Kick channel", text: $kick, prompt: "yourchannel")
                Button("Save and reconnect") {
                    var s = hub.settings
                    s.youtube = youtube.trimmingCharacters(in: .whitespaces)
                    s.twitch = twitch.trimmingCharacters(in: .whitespaces)
                    s.kick = kick.trimmingCharacters(in: .whitespaces)
                    s.kickChatroom = Int(kickRoom.trimmingCharacters(in: .whitespaces))
                    if s == hub.settings { hub.restart() } else { hub.settings = s }
                }
            } header: {
                Text("Channels")
            } footer: {
                Text("Chat is read only: nothing is ever posted. YouTube connects once you go live. Instagram doesn't let apps read live chat, so it can't be shown.")
            }
            Section("Look") {
                Picker("Text size", selection: $overlay.size) {
                    Text("Small").tag(ChatOverlay.Size.small)
                    Text("Medium").tag(ChatOverlay.Size.medium)
                    Text("Large").tag(ChatOverlay.Size.large)
                }
                Picker("Fade each message after", selection: $overlay.hideAfter) {
                    Text("Never").tag(0.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                }
                Picker("Fade the chat when quiet for", selection: $overlay.fadeWhenQuiet) {
                    Text("Never").tag(0.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                    Text("15 minutes").tag(900.0)
                }
                HStack {
                    Button("Show test messages") { hub.addTestMessages() }
                        .disabled(!Engine.shared.running)
                    Text("The whole chat fades back in with the next message.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Also show on 9:16", isOn: $overlay.showOnVertical)
                Text("Move and resize the chat with Arrange on the preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("If Kick won't connect") {
                TextField("Kick chatroom ID (optional)", text: $kickRoom)
                Text("Only needed if Kick blocks the channel lookup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func channel(_ p: ChatPlatform, _ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { hub.settings.enabled.contains(p) },
                                 set: { on in
                                     var s = hub.settings
                                     if on { s.enabled.insert(p) } else { s.enabled.remove(p) }
                                     hub.settings = s
                                 })) {
                TextField(label, text: text, prompt: Text(prompt))
            }
            Text(hub.status[p]?.label ?? "Off")
                .font(.caption)
                .foregroundStyle(hub.status[p] == .connected ? Theme.good : .secondary)
                .frame(width: 150, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

/// A draggable, resizable box for Arrange mode. Positions are canvas pixels.
struct ArrangeBox: View {
    let id: String
    let label: String
    let icon: String
    let tint: Color
    let scale: CGFloat
    /// Keep the box's proportions when resizing from the corner.
    var keepShape = false
    let box: CallOverlay.Box
    let update: ((inout CallOverlay.Box) -> Void) -> Void
    let reset: () -> Void

    @State private var dragStart: CallOverlay.Box?
    private var overlay: CallOverlay { .shared }

    var body: some View {
        let selected = overlay.selected == id
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: selected ? [] : [6, 4]))
                .background(tint.opacity(0.06))
                .overlay(alignment: .top) {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                        Text(label)
                        if selected { Button("Reset", action: reset).buttonStyle(.link) }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: Capsule())
                    .offset(y: -10)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = box }
                        overlay.selected = id
                        let start = dragStart!
                        update {
                            $0.x = start.x + value.translation.width / scale
                            $0.y = start.y + value.translation.height / scale
                        }
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture { overlay.selected = id }
            Circle()
                .fill(tint)
                .frame(width: 12, height: 12)
                .offset(x: 6, y: 6)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = box }
                        overlay.selected = id
                        let start = dragStart!
                        update {
                            $0.w = start.w + value.translation.width / scale
                            $0.h = keepShape ? $0.w * start.h / max(start.w, 1) : start.h + value.translation.height / scale
                        }
                    }
                    .onEnded { _ in dragStart = nil })
        }
        .frame(width: box.w * scale, height: box.h * scale)
        .position(x: (box.x + box.w / 2) * scale, y: (box.y + box.h / 2) * scale)
    }
}

struct ChatArrangeBox: View {
    let canvas: Canvas
    let scale: CGFloat
    private var chat: ChatOverlay { .shared }

    var body: some View {
        if chat.visible, canvas == .horizontal || chat.showOnVertical {
            ArrangeBox(id: "chat-\(canvas.rawValue)", label: "Chat", icon: "bubble.left.and.text.bubble.right",
                       tint: Theme.live, scale: scale, box: chat.box(canvas),
                       update: { chat.updateBox(canvas, $0) }, reset: { chat.resetBox(canvas) })
        }
    }
}
