// The Settings sub-pages (Spotify iOS layout): account, content and display, playback, privacy,
// data-saving and offline, media quality, storage, recover playlists, about, and the equalizer.
// Every switch here does something (stream ios-p2): Canvas, Gapless, notifications and "Recently
// played artists" had nothing behind them on iPhone and are gone.
import SwiftUI

struct SettingsPageView: View {
    @Environment(AppModel.self) private var app
    let page: SettingsPage

    var body: some View {
        SettingsScaffold(title: page.title) {
            switch page {
            case .account: AccountSettings()
            case .contentDisplay: ContentSettings()
            case .playback: PlaybackSettings()
            case .privacy: PrivacySettings()
            case .audioQuality: QualitySettings()
            case .equalizer: EqualizerSettings()
            case .storage: StorageSettings()
            case .dataSaver: DataSaverSettings()
            case .recoverPlaylists: RecoverPlaylistsSettings()
            case .about: AboutSettings()
            case .podcasts: PodcastsSettings()
            }
        }
        .task {
            await app.settings.refresh()
            await app.downloads.refresh()
        }
    }
}

// MARK: account

private struct AccountSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var store = app.account
        let a = store.account
        SettingsHeader(title: "Your profile")
        HStack(spacing: Space.m) {
            ProfileAvatar(size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.localUser).font(Typo.font(16, .bold))
                Text(store.signedIn ? "Connected with Google" : "Local profile")
                    .font(Typo.font(13)).foregroundStyle(Palette.subdued)
            }
        }
        .padding(.horizontal, Space.gutter).padding(.vertical, Space.s)
        SettingsNote(text: "Ztunes works without an account. Your library, likes and history are stored on this iPhone.")
        SettingsHeader(title: "YouTube account")
        if store.signedIn {
            HStack(spacing: Space.m) {
                AccountPhoto(url: a.thumbnail, name: a.displayName ?? "Y", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.displayName ?? "YouTube account").font(Typo.font(16))
                    if let sub = a.handle ?? a.email, sub != a.displayName {
                        Text(sub).font(Typo.font(13)).foregroundStyle(Palette.subdued)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Space.gutter).frame(minHeight: 56)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("youtube-account")
            SettingsNote(text: "Your connected likes, playlists and subscriptions work here. Sign out to go back to this iPhone's library only.")
            pill("Sign out", id: "youtube-signout") { confirmSignOut = true }
        } else if a.signedIn && a.selectionRequired == true {
            SettingsNote(text: "Signed in to Google. Pick which YouTube channel to use.")
            pill("Choose a channel", id: "youtube-choose") {
                Task { store.identities = (try? await app.core.asAccount?.accountIdentities()) ?? []; store.signInOpen = true }
            }
        } else {
            SettingsNote(text: "Optional. Sign in to bring your YouTube Music likes, playlists and subscriptions. You sign in on Google's own page; Ztunes never sees your password.")
            pill("Connect Google account", id: "youtube-signin") { store.signInOpen = true }
        }
        SettingsHeader(title: "Import and export")
        SettingsNavRow(icon: "download-simple", title: "Import from Spotify", subtitle: "Playlists, Liked Songs and listening history") {
            app.importOpen = true
        }
        ExportLibraryRow()
        Color.clear.frame(height: 0)
            .sheet(isPresented: $store.signInOpen) { YouTubeSignInSheet().environment(app) }
            .confirmationDialog("Sign out of YouTube?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        do {
                            try await app.account.signOut()
                            app.showToast("Signed out of YouTube")
                        } catch { app.showToast("Couldn't sign out. Try again.") }
                    }
                }
            } message: {
                Text("Your library on this iPhone stays as it is.")
            }
    }

    private func pill(_ title: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                .padding(.horizontal, Space.l).frame(height: 36)
                .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.s)
        .accessibilityIdentifier(id)
    }
}

extension CoreClient {
    /// The account half of the client (Core/AccountClient.swift).
    var asAccount: AccountClient? { self as? AccountClient }
}

extension AppModel {
    /// "Show unplayable songs" is off: lists leave out the rows `rowBlock` greys.
    var hidesUnplayable: Bool { !settings.bool(SettingKey.showUnplayable, default: true) }
}

extension SettingKey {
    /// "Show unplayable songs" (stream ios-p2): off hides the rows playback steps over. Shared
    /// with the Mac (core `UI_SETTINGS`).
    static let showUnplayable = "show_unplayable"
}

// MARK: content and display

private struct ContentSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let s = app.settings
        SettingsHeader(title: "Explicit content")
        SettingsToggleRow(title: "Allow explicit content", subtitle: "Turn on to play explicit content. Explicit content is labeled with the E tag.",
                          isOn: Binding(get: { !s.smart.explicitFilter }, set: { s.setSmart("explicit_filter", $0 ? "false" : "true") }))
        SettingsHeader(title: "Display")
        SettingsToggleRow(title: "Show unplayable songs",
                          subtitle: "Show songs that can't play right now (hidden, explicit, or not downloaded while offline), greyed out. Turn off to leave them out of lists.",
                          isOn: s.binding(SettingKey.showUnplayable, default: true))
    }
}

// MARK: playback

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app
    @State private var crossfade: Double?

    var body: some View {
        let s = app.settings
        let secs = crossfade ?? Double(s.audio?.crossfadeSecs ?? 0)
        SettingsHeader(title: "Track transitions")
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Crossfade").font(Typo.font(16))
                Spacer()
                Text(secs == 0 ? "Off" : "\(Int(secs)) s").font(Typo.font(14)).foregroundStyle(Palette.subdued).monospacedDigit()
            }
            Text("Lets songs blend into each other.").font(Typo.font(13)).foregroundStyle(Palette.subdued)
            HStack(spacing: Space.m) {
                Text("0 s").font(Typo.font(12)).foregroundStyle(Palette.subdued)
                Slider(value: Binding(get: { secs }, set: { crossfade = $0.rounded() }), in: 0...12, step: 1, onEditingChanged: { editing in
                    if !editing, let c = crossfade { s.setCrossfade(Int(c)); crossfade = nil }
                })
                .tint(Palette.accent)
                .accessibilityIdentifier("crossfade")
                Text("12 s").font(Typo.font(12)).foregroundStyle(Palette.subdued)
            }
        }
        .padding(.horizontal, Space.gutter).padding(.vertical, Space.s)
        SettingsToggleRow(title: "Autoplay similar content", subtitle: "Enjoy nonstop listening. When your audio ends, we'll play you something similar.",
                          isOn: s.binding("autoplay", default: true))
        SettingsHeader(title: "Shuffle")
        SettingsToggleRow(title: "Smart Shuffle suggestions", subtitle: "Shuffle in your own playlists adds recommendations that fit.",
                          isOn: Binding(get: { s.smart.shuffleMode == "smart" }, set: { s.setSmart("shuffle_mode", $0 ? "smart" : "standard") }))
        SettingsToggleRow(title: "Allow explicit content", isOn: Binding(get: { !s.smart.explicitFilter },
                                                                          set: { s.setSmart("explicit_filter", $0 ? "false" : "true") }))
        SettingsHeader(title: "Volume")
        SettingsToggleRow(title: "Normalize volume", subtitle: "Set the same volume level for all songs and podcasts.",
                          isOn: Binding(get: { s.audio?.normalize ?? true }, set: { s.setNormalize($0) }))
        if s.audio?.normalize ?? true {
            ForEach(VolumeLevel.allCases, id: \.self) { l in
                SettingsRadioRow(title: l.rawValue.capitalized, subtitle: l == .loud ? "Might reduce dynamics. Lower quality in loud environments." : nil,
                                 selected: (s.audio?.level ?? .normal) == l) { s.setLevel(l) }
            }
        }
        SettingsHeader(title: "Sound")
        SettingsNavRow(icon: "equalizer", title: "Equalizer", subtitle: "Adjust the sound to your liking",
                       value: (s.audio?.eq.enabled ?? false) ? (s.audio?.eq.preset ?? "Custom") : "Off") {
            app.router.push(.settingsPage(.equalizer))
        }
    }
}

// MARK: privacy

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let s = app.settings
        SettingsHeader(title: "Listening activity")
        SettingsToggleRow(title: "Private session", subtitle: "Plays in a private session don't shape your Home, Made for you or Recently played.",
                          isOn: Binding(get: { s.smart.privateSession }, set: { s.setPrivateSession($0) }))
        SettingsHeader(title: "Listening history")
        SettingsNote(text: "Your listening history stays on this iPhone. Ztunes uses it only to build Home, Made for you and Smart Shuffle; nothing is sent anywhere.")
        SettingsNavRow(icon: "clock-counter-clockwise", title: "Recents", subtitle: "What you've played lately, and your top artists") {
            app.router.push(.history)
        }
        Button {
            app.confirm = ConfirmRequest(title: "Clear listening history?",
                                         message: "Recents, your top artists and the stats built from them start over. Your library stays.",
                                         action: "Clear") {
                Task {
                    do {
                        try await app.core.clearListeningHistory()
                        app.homeSerial += 1
                        app.showToast("Listening history cleared")
                    } catch { app.showToast("Couldn't clear your listening history") }
                }
            }
        } label: {
            Text("Clear listening history").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                .padding(.horizontal, Space.l).frame(height: 36)
                .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.s)
        .accessibilityIdentifier("clear-history")
    }
}

// MARK: data saving and offline

private struct DataSaverSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let s = app.settings
        let d = app.downloads
        SettingsHeader(title: "Data Saver")
        SettingsToggleRow(title: "Data Saver", subtitle: "Sets your streaming quality to Low on Wi-Fi and cellular.",
                          isOn: Binding(get: { s.bool(SettingKey.dataSaver) }, set: { on in
                              s.set(SettingKey.dataSaver, on)
                              StreamQuality.shared.apply()
                          }))
        // stream: video-pods. Data Saver and offline already mean no video; this is the choice.
        SettingsHeader(title: "Video podcasts")
        SettingsToggleRow(title: "Play as audio only", subtitle: "Video podcasts start without the picture. You can still switch to video in Now Playing.",
                          isOn: Binding(get: { s.bool(SettingKey.podcastAudioOnly) }, set: { on in
                              s.set(SettingKey.podcastAudioOnly, on)
                          }))
        SettingsNavRow(icon: "microphone", title: "Podcasts", subtitle: "Skip sponsors • Ad-free episodes • OPML") {
            app.router.push(.settingsPage(.podcasts))
        }
        SettingsHeader(title: "Offline")
        SettingsToggleRow(title: "Offline mode", subtitle: "When you go offline, you'll only be able to play the music and podcasts you've downloaded.",
                          isOn: Binding(get: { d.snapshot.network.offlineMode }, set: { on in
                              d.snapshot.network.offlineMode = on
                              d.set(DownloadSettingsPatch(offlineMode: on))
                          }))
        SettingsToggleRow(title: "Download using cellular", subtitle: "Recommended setting: Off",
                          isOn: Binding(get: { d.snapshot.network.allowMetered }, set: { on in
                              d.snapshot.network.allowMetered = on
                              d.set(DownloadSettingsPatch(allowMetered: on))
                          }))
        SettingsNavRow(icon: "hard-drives", title: "Storage", subtitle: "Downloads and cache") { app.router.push(.settingsPage(.storage)) }
    }
}

// MARK: media quality

private struct QualitySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.settings
        let d = app.downloads
        let saver = s.bool(SettingKey.dataSaver)
        SettingsHeader(title: "Wi-Fi streaming")
        list(SettingKey.streamQuality)
        SettingsHeader(title: "Cellular streaming")
        list(SettingKey.cellularQuality)
        if saver {
            SettingsNote(text: "Data Saver is on: streaming quality is Low. Pick a quality to turn it off.")
        }
        SettingsHeader(title: "Download")
        SettingsRadioRow(title: "Normal", subtitle: "Smaller files, up to about 128 kbit/s", selected: d.snapshot.quality == "LOW") {
            d.snapshot.quality = "LOW"; d.set(DownloadSettingsPatch(quality: "LOW"))
        }
        SettingsRadioRow(title: "High", subtitle: "Best quality YouTube offers, about 160 kbit/s", selected: d.snapshot.quality != "LOW") {
            d.snapshot.quality = "HIGH"; d.set(DownloadSettingsPatch(quality: "HIGH"))
        }
        SettingsToggleRow(title: "Download using cellular", subtitle: "Recommended setting: Off",
                          isOn: Binding(get: { d.snapshot.network.allowMetered }, set: { on in
                              d.snapshot.network.allowMetered = on
                              d.set(DownloadSettingsPatch(allowMetered: on))
                          }))
        SettingsNote(text: "Higher quality uses more data and storage.")
    }

    @ViewBuilder private func list(_ key: String) -> some View {
        let saver = app.settings.bool(SettingKey.dataSaver)
        let cur = saver ? "low" : StreamQuality.normalized(app.settings.values[key])
        ForEach(StreamQuality.choices, id: \.id) { c in
            SettingsRadioRow(title: c.title, selected: cur == c.id) {
                app.settings.set(key, c.id)
                if saver && c.id != "low" { app.settings.set(SettingKey.dataSaver, false) }
                StreamQuality.shared.apply()
            }
            .accessibilityIdentifier("quality-\(key)-\(c.id)")
        }
    }
}

// MARK: storage

private struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @State private var cacheBytes: Double = 0

    var body: some View {
        let dl = app.downloads.snapshot.bytes
        let free = freeSpace
        let total = max(1, dl + cacheBytes + free)
        let fmt: (Double) -> String = { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        VStack(alignment: .leading, spacing: Space.m) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(Palette.accent).frame(width: max(2, g.size.width * dl / total))
                    Rectangle().fill(Palette.announcement).frame(width: max(2, g.size.width * cacheBytes / total))
                    Rectangle().fill(Palette.elevatedHighlight)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            legend(Palette.accent, "Downloads", fmt(dl))
            legend(Palette.announcement, "Cache", fmt(cacheBytes))
            legend(Palette.elevatedHighlight, "Free", fmt(free))
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.xl)
        SettingsHeader(title: "Downloads")
        SettingsNote(text: "\(app.downloads.snapshot.count) songs and episodes, \(fmt(dl)).")
        actionButton("Remove all downloads") {
            app.confirm = ConfirmRequest(title: "Remove all downloads?", message: "You won't be able to play them offline.", action: "Remove") {
                app.downloads.removeAll()
                app.showToast("Downloads removed")
            }
        }
        SettingsHeader(title: "Cache")
        SettingsNote(text: "Temporary audio and artwork that make playback start faster.")
        actionButton("Clear cache") {
            Task {
                try? await app.core.clearCaches()
                cacheBytes = (try? await app.core.cacheSize()) ?? 0
                app.showToast("Cache cleared")
            }
        }
        .task { cacheBytes = (try? await app.core.cacheSize()) ?? 0 }
    }

    private var freeSpace: Double {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(v?.volumeAvailableCapacityForImportantUsage ?? 32_000_000_000)
    }

    private func legend(_ c: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: Space.s) {
            Circle().fill(c).frame(width: 10, height: 10)
            Text(title).font(Typo.font(14))
            Spacer()
            Text(value).font(Typo.font(14)).foregroundStyle(Palette.subdued).monospacedDigit()
        }
    }

    private func actionButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                .padding(.horizontal, Space.l).frame(height: 36)
                .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.s)
    }
}

// MARK: about

private struct AboutSettings: View {
    private var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "0.1.0") (\(i?["CFBundleVersion"] as? String ?? "1"))"
    }
    private let credits: [(String, String)] = [
        ("YouTube Music", "Catalogue, artwork and audio"),
        ("mpv and MPVKit", "Audio playback (LGPL/GPL)"),
        ("UniFFI", "Rust core bindings (MPL-2.0)"),
        ("SponsorBlock", "Skipping sponsor segments in episodes (CC BY-NC-SA)"),
        ("iTunes Search API", "Podcast directory"),
        ("Phosphor Icons", "Icons (MIT)"),
        ("Figtree", "Typeface (OFL)"),
        ("Vazirmatn", "Persian typeface (SIL OFL 1.1)"),
        ("swift-snapshot-testing", "Screen tests (MIT)"),
    ]

    var body: some View {
        HStack {
            Text("Version").font(Typo.font(16))
            Spacer()
            Text(version).font(Typo.font(14)).foregroundStyle(Palette.subdued)
        }
        .padding(.horizontal, Space.gutter).frame(minHeight: 56)
        SettingsNote(text: "Ztunes is free and open source software under the GPL-3.0.")
        SettingsHeader(title: "Credits")
        SettingsNote(text: "Developer: Yasin Beigy")
        SettingsNote(text: "Designer: Yasin Beigy")
        SettingsHeader(title: "Third-party notices")
        ForEach(credits, id: \.0) { name, what in
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Typo.font(16))
                Text(what).font(Typo.font(13)).foregroundStyle(Palette.subdued)
            }
            .padding(.horizontal, Space.gutter).frame(minHeight: 56, alignment: .leading)
        }
        SettingsHeader(title: "Legal")
        SettingsNavRow(icon: "file-text", title: "Licenses", subtitle: "Third-party software notices") {
            if let u = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html") { UIApplication.shared.open(u) }
        }
        SettingsNavRow(icon: "code", title: "Source code", subtitle: "GPL-3.0") {
            if let u = URL(string: "https://github.com/fjenn") { UIApplication.shared.open(u) }
        }
    }
}

// MARK: equalizer

private struct EqualizerSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.settings
        let eq = s.audio?.eq ?? EqState(enabled: false, gains: Array(repeating: 0, count: 6), preset: "Flat", preamp: 0)
        SettingsToggleRow(title: "Equalizer", subtitle: "Tune the sound with six bands or a preset.",
                          isOn: Binding(get: { eq.enabled }, set: { s.setEq(enabled: $0, gains: eq.gains, commit: true) }))
        EqGraph(gains: eq.gains, disabled: !eq.enabled) { gains, commit in
            s.setEq(enabled: true, gains: gains, commit: commit)
        }
        .frame(height: 240)
        .padding(.horizontal, Space.s)
        .padding(.top, Space.m)
        HStack {
            Text(eq.preamp < 0 ? String(format: "Pre-gain %.1f dB", eq.preamp) : " ")
            Spacer()
            Button("Reset") { s.setEqPreset("Flat") }.font(Typo.font(13, .bold)).disabled(!eq.enabled)
        }
        .font(Typo.font(12)).foregroundStyle(Palette.subdued)
        .padding(.horizontal, Space.gutter)
        .opacity(eq.enabled ? 1 : 0.4)
        SettingsHeader(title: "Presets")
        let current = eq.preset ?? "Custom"
        if eq.preset == nil {
            SettingsRadioRow(title: "Custom", selected: true) {}
        }
        ForEach(EQ.presets, id: \.0) { name, _ in
            SettingsRadioRow(title: name, selected: eq.enabled && current == name) { s.setEqPreset(name) }
        }
        .opacity(eq.enabled ? 1 : 0.5)
    }
}

/// The response curve (desktop `EqGraph.svelte`): log frequency axis, ±12 dB (with headroom), a
/// accent curve with a soft fill, and a draggable handle per band at its gain.
struct EqGraph: View {
    let gains: [Double]
    var disabled = false
    /// (gains, commit): commit=false while dragging, true on release.
    var onChange: ([Double], Bool) -> Void
    @State private var live: [Double]?
    @State private var dragging: Int?

    private let padX: CGFloat = 26
    private let padTop: CGFloat = 12
    private let labelH: CGFloat = 24
    private var range: Double { EQ.maxDb * 1.25 }

    var body: some View {
        let g = live ?? gains
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let plotH = h - padTop - labelH - 8
            let x: (Double) -> CGFloat = { padX + CGFloat(EQ.freqToX($0)) * (w - 2 * padX) }
            let y: (Double) -> CGFloat = { padTop + CGFloat((range - max(-range, min(range, $0))) / (2 * range)) * plotH }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    var grid = Path()
                    for db in [EQ.maxDb, -EQ.maxDb] { grid.move(to: CGPoint(x: padX, y: y(db))); grid.addLine(to: CGPoint(x: w - padX, y: y(db))) }
                    for b in EQ.bands { grid.move(to: CGPoint(x: x(b.freq), y: y(range))); grid.addLine(to: CGPoint(x: x(b.freq), y: y(-range))) }
                    ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
                    var zero = Path()
                    zero.move(to: CGPoint(x: padX, y: y(0))); zero.addLine(to: CGPoint(x: w - padX, y: y(0)))
                    ctx.stroke(zero, with: .color(.white.opacity(0.22)), lineWidth: 1)
                    let freqs = EQ.logFrequencies(160)
                    var curve = Path()
                    for (i, f) in freqs.enumerated() {
                        let p = CGPoint(x: x(f), y: y(EQ.responseDb(g, freq: f)))
                        if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                    }
                    var fill = curve
                    fill.addLine(to: CGPoint(x: x(freqs.last!), y: y(0)))
                    fill.addLine(to: CGPoint(x: x(freqs[0]), y: y(0)))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(Gradient(stops: [.init(color: Palette.accent.opacity(0.45), location: 0),
                                                                           .init(color: Palette.accent.opacity(0.12), location: 0.5),
                                                                           .init(color: Palette.accent.opacity(0.45), location: 1)]),
                                                         startPoint: CGPoint(x: 0, y: padTop), endPoint: CGPoint(x: 0, y: padTop + plotH)))
                    ctx.stroke(curve, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(EQ.bands.enumerated()), id: \.offset) { i, b in
                    let gi = i < g.count ? g[i] : 0
                    ZStack {
                        Circle().fill(Palette.accent.opacity(dragging == i ? 0.35 : 0.2)).frame(width: dragging == i ? 30 : 24)
                        Circle().fill(.white).frame(width: 14, height: 14).shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    }
                    .position(x: x(b.freq), y: y(gi))
                    .accessibilityElement()
                    .accessibilityLabel("\(EQ.freqLabel(b.freq)) band")
                    .accessibilityValue(String(format: "%+.1f dB", gi))
                    .accessibilityAdjustableAction { dir in
                        var n = g
                        n[i] = EQ.clamp(gi + (dir == .increment ? 0.5 : -0.5))
                        onChange(n, true)
                    }
                    Text(EQ.freqLabel(b.freq)).font(Typo.font(11, .medium)).foregroundStyle(Palette.subdued)
                        .fixedSize()
                        .position(x: x(b.freq), y: h - labelH / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard !disabled else { return }
                    let i = dragging ?? EQ.bands.indices.min { abs(x(EQ.bands[$0].freq) - v.startLocation.x) < abs(x(EQ.bands[$1].freq) - v.startLocation.x) }!
                    if dragging == nil { dragging = i; Haptics.selection() }
                    let db = range - Double((v.location.y - padTop) / plotH) * 2 * range
                    var n = live ?? gains
                    let next = EQ.clamp((db * 2).rounded() / 2)
                    guard n[i] != next else { return }
                    n[i] = next
                    live = n
                    onChange(n, false)
                }
                .onEnded { _ in
                    if let n = live { onChange(n, true) }
                    dragging = nil
                    live = nil
                })
        }
        .opacity(disabled ? 0.4 : 1)
        .allowsHitTesting(!disabled)
        .accessibilityIdentifier("eq-graph")
    }
}
