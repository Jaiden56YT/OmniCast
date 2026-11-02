import SwiftUI

struct DestinationsPanel: View {
    @Bindable private var engine = Engine.shared
    @Binding var editing: Destination?

    var body: some View {
        Panel(title: "Destinations") {
            Menu {
                ForEach(Platform.allCases) { p in
                    Button(p.name) { editing = Destination(platform: p) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(engine.live)
            .help("Add a destination")
        } content: {
            // Re-read once a second while live so the bytes and drop counts tick.
            let _ = engine.live ? engine.stats.total_frames : 0
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($engine.destinations) { $dest in
                        DestinationRow(destination: $dest, state: engine.state(for: dest.id),
                                       stats: engine.outputStats(for: dest.id), locked: engine.live) {
                            editing = dest
                        } onDelete: {
                            dest.key = ""
                            engine.destinations.removeAll { $0.id == dest.id }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

struct DestinationRow: View {
    @Binding var destination: Destination
    let state: OutputState
    let stats: (dropped: Int, bytes: UInt64)?
    let locked: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(String(destination.platform.name.prefix(1)))
                .font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 24)
                .background(destination.platform.tint.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.name).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(detailColor).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(destination.canvas.label)
                .font(.system(size: 10, weight: .medium).monospaced())
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.raised, in: Capsule())
            Menu {
                Button("Edit…", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(locked)
            Toggle("", isOn: $destination.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(locked || !destination.isReady)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.raised.opacity(destination.enabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !locked { onEdit() } }
    }

    private var color: Color {
        switch state {
        case .idle: destination.enabled ? .white.opacity(0.5) : .clear
        case .connecting, .reconnecting: Theme.warn
        case .live: Theme.good
        case .failed: Theme.record
        }
    }

    private var detailColor: Color {
        if case .failed = state { return Theme.record }
        return Theme.textDim
    }

    private var detail: String {
        switch state {
        case .failed(let msg): return msg
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .live:
            if let stats {
                return String(format: "Live · %.0f MB · %d dropped", Double(stats.bytes) / 1_000_000, stats.dropped)
            }
            return "Live"
        case .idle:
            return destination.isReady ? (destination.enabled ? "Ready" : "Off") : "Add a stream key"
        }
    }
}

extension Platform {
    var tint: Color {
        switch self {
        case .youtube: Color(red: 0.90, green: 0.13, blue: 0.13)
        case .twitch: Color(red: 0.57, green: 0.27, blue: 1.0)
        case .kick: Color(red: 0.20, green: 0.75, blue: 0.20)
        case .tiktok: Color(red: 0.15, green: 0.75, blue: 0.80)
        case .instagram: Color(red: 0.85, green: 0.25, blue: 0.55)
        case .custom: Color(white: 0.4)
        }
    }
}

struct DestinationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var destination: Destination
    @State private var key = ""
    let onSave: (Destination) -> Void

    init(destination: Destination, onSave: @escaping (Destination) -> Void) {
        _destination = State(initialValue: destination)
        _key = State(initialValue: destination.key)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Name", text: $destination.name)
            TextField("Server URL", text: $destination.server)
            SecureField("Stream key", text: $key)
            Picker("Canvas", selection: $destination.canvas) {
                Text("Horizontal 16:9").tag(Canvas.horizontal)
                Text("Vertical 9:16").tag(Canvas.vertical)
            }
            Text(destination.platform.keyHelp).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    destination.key = key
                    destination.server = destination.server.trimmingCharacters(in: .whitespaces)
                    if !destination.isReady { destination.enabled = false }
                    else if !key.isEmpty { destination.enabled = true }
                    onSave(destination)
                    dismiss()
                }
            }
        }
    }
}
