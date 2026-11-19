import SwiftUI

/// The Stream info sheet: one title for every platform, and the game on Twitch and Kick.
struct StreamInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var info = StreamInfo.shared
    @State private var updating = false
    @State private var matchNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Stream info").font(.title3.weight(.semibold))
                Spacer()
                if info.loading { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.headline)
                TextField("What are you streaming?", text: $info.title, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 14) {
                    ForEach(ChatPlatform.allCases) { p in
                        Toggle(p.name, isOn: Binding(get: { info.titleOn.contains(p) },
                                                     set: { if $0 { info.titleOn.insert(p) } else { info.titleOn.remove(p) } }))
                            .disabled(!info.isConnected(p))
                            .help(info.isConnected(p) ? "Update the title on \(p.name)" : "Connect \(p.name) in Settings → Accounts")
                    }
                    Spacer()
                    Text("\(info.title.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(info.title.count > 100 ? Theme.warn : .secondary)
                        .help("YouTube allows 100 characters, Twitch 140")
                }
                .font(.callout)
            }

            HStack(alignment: .top, spacing: 16) {
                CategoryPicker(platform: .twitch, selection: $info.twitchGame)
                VStack(alignment: .leading, spacing: 6) {
                    CategoryPicker(platform: .kick, selection: $info.kickGame)
                    Button("Same as Twitch") {
                        Task {
                            let ok = await info.matchKickToTwitch()
                            matchNote = ok ? nil : "Kick doesn't have that game"
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(info.twitchGame == nil || !info.kick.isConnected)
                    if let matchNote { Text(matchNote).font(.caption).foregroundStyle(Theme.warn) }
                }
            }

            ForEach(ChatPlatform.allCases) { p in
                if let outcome = info.results[p] {
                    HStack(spacing: 6) {
                        switch outcome {
                        case .working: ProgressView().controlSize(.mini)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.record)
                        }
                        Text(p.name).fontWeight(.medium)
                        if case .failed(let why) = outcome { Text(why).foregroundStyle(.secondary).lineLimit(2) }
                        if outcome == .done { Text("Updated").foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                }
            }

            if !ChatPlatform.allCases.contains(where: info.isConnected) {
                HStack {
                    Text("Connect your accounts first.").foregroundStyle(.secondary)
                    SettingsLink { Text("Settings → Accounts") }.buttonStyle(.link)
                }
                .font(.callout)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update") {
                    updating = true
                    Task {
                        await info.apply()
                        updating = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(updating || !ChatPlatform.allCases.contains(where: info.isConnected))
            }
        }
        .padding(20)
        .frame(width: 620)
        .task {
            info.clearResults()
            await info.loadCurrent()
        }
    }
}

/// Search a platform's games; shows the pick, recent picks and results with box art.
struct CategoryPicker: View {
    let platform: ChatPlatform
    @Binding var selection: StreamCategory?
    @State private var query = ""
    @State private var results: [StreamCategory] = []
    @State private var searchTask: Task<Void, Never>?
    private var info: StreamInfo { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(platform.name) game").font(.headline)
            if let selection {
                HStack(spacing: 8) {
                    CategoryArt(url: selection.image)
                    Text(selection.name).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Button { self.selection = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Leave the \(platform.name) game as it is")
                }
                .padding(6)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            }
            TextField("Search \(platform.name) games", text: $query)
                .textFieldStyle(.roundedBorder)
                .disabled(!info.isConnected(platform))
                .onChange(of: query) {
                    // Waits for a pause in typing before asking the platform.
                    searchTask?.cancel()
                    let q = query
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        let found = await info.search(q, on: platform)
                        if !Task.isCancelled { results = found }
                    }
                }
            let recent = (info.recents[platform] ?? []).filter { $0.id != selection?.id }
            if query.isEmpty, !recent.isEmpty {
                FlowChips(items: recent) { selection = $0 }
            }
            if !results.isEmpty, !query.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { c in
                            Button {
                                selection = c
                                query = ""
                                results = []
                            } label: {
                                HStack(spacing: 8) {
                                    CategoryArt(url: c.image)
                                    Text(c.name).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            if !info.isConnected(platform) {
                Text("Connect \(platform.name) in Settings → Accounts").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CategoryArt: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "gamecontroller").foregroundStyle(.secondary)
        }
        .frame(width: 22, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct FlowChips: View {
    let items: [StreamCategory]
    let pick: (StreamCategory) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(3)) { c in
                Button(c.name) { pick(c) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Settings → Accounts

struct AccountsSettingsView: View {
    @Bindable private var twitch = TwitchAccount.shared
    @Bindable private var kick = KickAccount.shared
    @Bindable private var youtube = YouTubeAccount.shared
    @State private var kickSecret = ""
    @State private var youtubeSecret = ""
    @State private var busy: ChatPlatform?
    @State private var errors: [ChatPlatform: String] = [:]

    var body: some View {
        Form {
            Section {
                steps([
                    "dev.twitch.tv/console/apps → Register Your Application.",
                    "OAuth Redirect URL: http://localhost:\(LoopbackRedirect.port). Category: Broadcaster Suite. Client Type: Public.",
                    "Copy the Client ID below, then Connect and enter the code Twitch shows.",
                ], link: "https://dev.twitch.tv/console/apps")
                TextField("Client ID", text: $twitch.clientID)
                if let code = twitch.pendingCode {
                    Text("Enter **\(code)** at twitch.tv/activate (opened in your browser).").font(.callout)
                }
                row(.twitch, connected: twitch.login, connect: { try await twitch.connect() }, signOut: twitch.signOut)
            } header: { Text("Twitch") }

            Section {
                steps([
                    "kick.com → Settings → Developer → Create app.",
                    "Redirect URL: \(KickAccount.redirect). Scopes: read user, read channel, write channel.",
                    "Copy the Client ID and Client Secret below, then Connect and allow access.",
                ], link: "https://kick.com/settings/developer")
                TextField("Client ID", text: $kick.clientID)
                SecureField(kick.hasSecret ? "Client Secret (saved)" : "Client Secret", text: $kickSecret)
                    .onSubmit { kick.setSecret(kickSecret) }
                row(.kick, connected: kick.login, connect: {
                    if !kickSecret.isEmpty { kick.setSecret(kickSecret) }
                    try await Task.sleep(for: .milliseconds(200))
                    try await kick.connect()
                }, signOut: kick.signOut)
            } header: { Text("Kick") }

            Section {
                steps([
                    "console.cloud.google.com → new project → enable “YouTube Data API v3”.",
                    "OAuth consent screen: External, add your Google account as a test user.",
                    "Credentials → Create OAuth client ID → Desktop app. Copy the ID and secret below, then Connect.",
                ], link: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")
                TextField("Client ID", text: $youtube.clientID)
                SecureField(youtube.hasSecret ? "Client Secret (saved)" : "Client Secret", text: $youtubeSecret)
                    .onSubmit { youtube.setSecret(youtubeSecret) }
                row(.youtube, connected: youtube.login, connect: {
                    if !youtubeSecret.isEmpty { youtube.setSecret(youtubeSecret) }
                    try await Task.sleep(for: .milliseconds(200))
                    try await youtube.connect()
                }, signOut: youtube.signOut)
            } header: { Text("YouTube") } footer: {
                Text("While the Google app is in testing, Google signs it out after 7 days; just Connect again. Secrets and sign-ins are kept in your keychain.")
            }
        }
        .formStyle(.grouped)
    }

    private func steps(_ lines: [String], link: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text("\(i + 1). \(line)").font(.caption).foregroundStyle(.secondary)
            }
            Link("Open the developer page", destination: URL(string: link)!).font(.caption)
        }
    }

    private func row(_ p: ChatPlatform, connected: String?, connect: @escaping () async throws -> Void,
                     signOut: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let connected {
                    Label("Connected as \(connected)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
                Spacer()
                if busy == p { ProgressView().controlSize(.small) }
                if connected != nil {
                    Button("Sign out", role: .destructive) {
                        signOut()
                        AlertSources.shared.restart()
                    }
                }
                Button(connected == nil ? "Connect" : "Reconnect") {
                    busy = p
                    errors[p] = nil
                    Task {
                        do { try await connect() } catch { errors[p] = error.localizedDescription }
                        busy = nil
                        AlertSources.shared.restart()
                    }
                }
                .disabled(busy != nil)
            }
            if let error = errors[p] { Text(error).font(.caption).foregroundStyle(Theme.record) }
        }
    }
}
