import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sources panel row for the Discord call overlay.
struct CallSourceRow: View {
    private var call: DiscordCall { .shared }
    @Bindable private var overlay = CallOverlay.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2").frame(width: 18)
                Text("Discord call").font(.system(size: 12))
                Spacer()
                Button { overlay.visible.toggle() } label: {
                    Image(systemName: overlay.visible ? "eye" : "eye.slash")
                        .foregroundStyle(overlay.visible ? .white.opacity(0.8) : Theme.textDim)
                }
                .buttonStyle(.borderless)
                .help(overlay.visible ? "Hide the Discord call's people" : "Show the Discord call's people")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                status
                Spacer(minLength: 4)
                Button(overlay.arranging ? "Done" : "Arrange") { overlay.arranging.toggle() }
                    .buttonStyle(.link)
                    .disabled(!Engine.shared.running)
            }
            .font(.system(size: 10))
            .padding(.leading, 26)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch call.status {
        case .notSetUp:
            SettingsLink { Text("Set up in Settings") }.buttonStyle(.link)
        case .inCall(let name):
            Text("\(call.members.count) in \(name)").foregroundStyle(Theme.good).lineLimit(1)
        case .noCall: Text("Not in a call").foregroundStyle(Theme.textDim)
        case .connecting: Text("Connecting…").foregroundStyle(Theme.textDim)
        case .waitingForApproval: Text("Approve in Discord…").foregroundStyle(Theme.warn)
        case .disconnected: Button("Connect") { call.connect() }.buttonStyle(.link)
        case .failed(let message): Text(message).foregroundStyle(Theme.record).lineLimit(1).help(message)
        }
    }
}

/// Drawn over the 16:9 preview while arranging: one outline per person, drag to
/// move, drag the corner to resize, click to select.
struct CallArrangeLayer: View {
    @Bindable private var overlay = CallOverlay.shared
    @State private var dragStart: CGPoint?
    @State private var sizeStart: Double?
    private let canvasWidth = 1920.0

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / canvasWidth
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001) // catches clicks on empty space
                    .onTapGesture { overlay.selected = nil }
                CameraArrangeBox(canvas: .horizontal, scale: scale)
                ForEach(overlay.shown) { member in
                    box(member, scale: scale)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            CallArrangePanel().padding(8)
        }
    }

    private func box(_ member: CallMember, scale: CGFloat) -> some View {
        let layout = overlay.layout(for: member.id)
        let size = overlay.boxSize(for: member.id)
        let w = size.width * scale, h = size.height * scale
        let selected = overlay.selected == member.id
        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? Theme.camera : .white.opacity(0.7),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 4]))
                .background(Color.white.opacity(0.04))
                .overlay(alignment: .top) {
                    Text(member.name + (layout.flip ? "  ⇋" : ""))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .offset(y: -10)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = CGPoint(x: layout.x, y: layout.y) }
                        overlay.selected = member.id
                        overlay.update(member.id) {
                            $0.x = dragStart!.x + value.translation.width / scale
                            $0.y = dragStart!.y + value.translation.height / scale
                        }
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture { overlay.selected = member.id }
            // Resize handle.
            Circle()
                .fill(selected ? Theme.camera : .white)
                .frame(width: 10, height: 10)
                .offset(x: 5, y: 5)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if sizeStart == nil { sizeStart = layout.size }
                        overlay.selected = member.id
                        overlay.update(member.id) { $0.size = sizeStart! + value.translation.height / scale }
                    }
                    .onEnded { _ in sizeStart = nil })
        }
        .frame(width: w, height: h)
        .position(x: layout.x * scale, y: layout.y * scale)
    }
}

struct CallArrangePanel: View {
    @Bindable private var overlay = CallOverlay.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Arrange call").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Done") { overlay.arranging = false }.controlSize(.small)
            }
            if DiscordCall.shared.members.isEmpty {
                Text("Nobody's in a call right now.").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Toggle("Show sample people", isOn: $overlay.showSamples).controlSize(.small)
            }
            Menu("Auto-arrange") {
                ForEach(ArrangeStyle.allCases) { style in
                    Button(style.label) { overlay.autoArrange(style) }
                }
            }
            .controlSize(.small)
            .disabled(overlay.shown.isEmpty)
            Toggle("Dim people who aren't talking", isOn: $overlay.dimQuiet).controlSize(.small)

            if let id = overlay.selected, let member = overlay.shown.first(where: { $0.id == id }) {
                Divider()
                MemberInspector(member: member)
            } else if !overlay.shown.isEmpty {
                Text("Drag people to move them, drag a corner to resize. Click one for more.")
                    .font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(width: 230)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MemberInspector: View {
    let member: CallMember
    private var overlay: CallOverlay { .shared }

    var body: some View {
        let layout = overlay.layout(for: member.id)
        VStack(alignment: .leading, spacing: 6) {
            Text(member.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            HStack {
                Text("Size")
                Slider(value: Binding(get: { layout.size }, set: { v in overlay.update(member.id) { $0.size = v } }),
                       in: 60...700)
                    .controlSize(.mini)
            }
            Toggle("Flip", isOn: Binding(get: { layout.flip }, set: { v in overlay.update(member.id) { $0.flip = v } }))
                .controlSize(.small)
            Picker("Image faces", selection: Binding(get: { layout.facesLeft },
                                                    set: { v in overlay.update(member.id) { $0.facesLeft = v } })) {
                Text("Right").tag(false)
                Text("Left").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .help("Which way this person's image looks before flipping; auto-arrange uses it")
            HStack {
                Button("Idle image…") { pick { overlay.importImage($0, for: member.id, talking: false) } }
                Button("Talking…") { pick { overlay.importImage($0, for: member.id, talking: true) } }
            }
            .controlSize(.small)
            if member.id != CallOverlay.meID, layout.idlePath != nil || layout.talkPath != nil {
                Button("Use Discord avatar") {
                    overlay.update(member.id) {
                        $0.idlePath = nil
                        $0.talkPath = nil
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    private func pick(_ done: (URL) -> Void) {
        if let url = pickImage(for: member.name) { done(url) }
    }
}

/// Settings tab: registering a Discord app and connecting.
struct DiscordSettingsView: View {
    @State private var clientID = DiscordCall.shared.clientID
    @State private var secret = DiscordCall.shared.clientSecret
    private var call: DiscordCall { .shared }

    var body: some View {
        Form {
            Section {
                Text("Discord only shares who's in your call with an app you register yourself. It's free and takes a minute:")
                    .font(.caption)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Open the Developer Portal and click New Application.")
                    Text("2. Under OAuth2, add the redirect http://localhost and save.")
                    Text("3. Copy the Client ID and Client Secret into the fields below.")
                    Text("4. Click Connect, then Authorize in the window Discord shows.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Link("Open the Discord Developer Portal",
                     destination: URL(string: "https://discord.com/developers/applications")!)
            }
            Section {
                TextField("Client ID", text: $clientID)
                SecureField(call.isSetUp ? "Client Secret (saved)" : "Client Secret", text: $secret)
                HStack {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if case .disconnected = call.status {
                        connectButton
                    } else if case .notSetUp = call.status {
                        connectButton
                    } else if case .failed = call.status {
                        connectButton
                    } else {
                        Button("Disconnect") { call.disconnect() }
                    }
                }
                Button("Sign out of Discord", role: .destructive) { call.signOut() }
                    .buttonStyle(.link)
                    .font(.caption)
            } footer: {
                Text("The secret and Discord's sign-in token are kept in your keychain.")
            }
        }
        .formStyle(.grouped)
    }

    private var connectButton: some View {
        Button("Connect") {
            call.clientID = clientID
            if !secret.isEmpty { call.clientSecret = secret }
            call.connect()
        }
        .disabled(clientID.isEmpty || (secret.isEmpty && !call.isSetUp))
    }

    private var statusText: String {
        switch call.status {
        case .notSetUp: "Not set up"
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .waitingForApproval: "Click Authorize in Discord"
        case .noCall: "Connected, not in a call"
        case .inCall(let name): "Connected · \(name)"
        case .failed(let message): message
        }
    }
}

@MainActor
func pickImage(for name: String) -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, UTType("public.avif")].compactMap { $0 }
    panel.message = "Choose an image for \(name). PNG or AVIF with transparency works best."
    return panel.runModal() == .OK ? panel.url : nil
}

/// Sources panel row for your own PNGtuber, which talks when your mic does.
struct YouSourceRow: View {
    @Bindable private var overlay = CallOverlay.shared

    private static let sensitivities: [(String, Double)] = [("High", -50), ("Medium", -40), ("Low", -30)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").frame(width: 18)
                Text("You").font(.system(size: 12))
                Circle()
                    .fill(overlay.meTalking ? Theme.good : Theme.textDim.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .help("Lights up when your mic makes your PNGtuber talk")
                Spacer()
                Menu {
                    Button("Idle image…") {
                        if let url = pickImage(for: "you") { overlay.importImage(url, for: CallOverlay.meID, talking: false) }
                    }
                    Button("Talking image…") {
                        if let url = pickImage(for: "you") { overlay.importImage(url, for: CallOverlay.meID, talking: true) }
                    }
                    Picker("Mic sensitivity", selection: $overlay.meThreshold) {
                        ForEach(Self.sensitivities, id: \.1) { Text($0.0).tag($0.1) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!Engine.shared.running)
                Button { overlay.meEnabled.toggle() } label: {
                    Image(systemName: overlay.meEnabled ? "eye" : "eye.slash")
                        .foregroundStyle(overlay.meEnabled ? .white.opacity(0.8) : Theme.textDim)
                }
                .buttonStyle(.borderless)
                .help(overlay.meEnabled ? "Hide your PNGtuber" : "Show your PNGtuber")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            Text(overlay.hasMeImages ? "PNGtuber · talks with your mic" : "Pick idle and talking images in ⋯")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
                .padding(.leading, 26)
        }
    }
}

/// The 9:16 preview while arranging: only the camera moves there.
struct VerticalArrangeLayer: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).onTapGesture { CallOverlay.shared.selected = nil }
                CameraArrangeBox(canvas: .vertical, scale: geo.size.width / 1080)
            }
        }
    }
}

/// Drag to move the camera, drag the corner to resize. On 16:9 the box keeps the
/// camera's shape; on 9:16 it can be any shape (the camera fills it, cropped).
struct CameraArrangeBox: View {
    let canvas: Canvas
    let scale: CGFloat
    @Bindable private var overlay = CallOverlay.shared
    @State private var dragStart: CallOverlay.Box?

    private var id: String { "camera-\(canvas.rawValue)" }

    var body: some View {
        let box = overlay.cameraBox(canvas)
        let selected = overlay.selected == id
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.camera, style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: selected ? [] : [6, 4]))
                .background(Theme.camera.opacity(0.06))
                .overlay(alignment: .top) {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                        Text("Camera")
                        if selected {
                            Button("Reset") { overlay.resetCamera(canvas) }
                                .buttonStyle(.link)
                        }
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
                        overlay.updateCamera(canvas) {
                            $0.x = start.x + value.translation.width / scale
                            $0.y = start.y + value.translation.height / scale
                        }
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture { overlay.selected = id }
            Circle()
                .fill(Theme.camera)
                .frame(width: 12, height: 12)
                .offset(x: 6, y: 6)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = box }
                        overlay.selected = id
                        let start = dragStart!
                        let keepShape = canvas == .horizontal
                        overlay.updateCamera(canvas) {
                            $0.w = start.w + value.translation.width / scale
                            $0.h = keepShape ? $0.w * start.h / max(start.w, 1)
                                : start.h + value.translation.height / scale
                        }
                    }
                    .onEnded { _ in dragStart = nil })
        }
        .frame(width: box.w * scale, height: box.h * scale)
        .position(x: (box.x + box.w / 2) * scale, y: (box.y + box.h / 2) * scale)
    }
}
