// Settings and privacy (Spotify iOS 2025/26 layout): the avatar side menu, the settings list, the
// shared row components the pages use, and the sleep timer sheet (Now Playing ⋯ / queue Timer).
import SwiftUI

// MARK: scaffold + rows

/// A pushed settings page: back chevron, centred 16/700 title, scrolling content on #121212.
struct SettingsScaffold<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(Typo.font(16, .bold)).lineLimit(1).padding(.horizontal, 56)
                HStack {
                    Button { dismiss() } label: {
                        Icon(name: "caret-left", size: 22).frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("back")
                    Spacer()
                }
                .padding(.horizontal, Space.xs)
            }
            .frame(height: 48)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.bottom, Space.xl)
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.base.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .chromeInset()
    }
}

/// Bold section header inside a page ("Audio quality", "Downloads").
struct SettingsHeader: View {
    let title: String
    var body: some View {
        Text(title).font(Typo.font(18, .bold))
            .padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.s)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A short subdued explainer paragraph under a header or a row.
struct SettingsNote: View {
    let text: String
    var body: some View {
        Text(text).font(Typo.font(13)).foregroundStyle(Palette.subdued)
            .padding(.horizontal, Space.gutter).padding(.vertical, Space.xs)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func rowText(_ title: String, _ subtitle: String?) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title).font(Typo.font(16)).foregroundStyle(Palette.text)
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle).font(Typo.font(13)).foregroundStyle(Palette.subdued).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) { rowText(title, subtitle) }
            .tint(Palette.accent)
            .padding(.horizontal, Space.gutter)
            .frame(minHeight: 60)
            .accessibilityIdentifier("toggle-\(title)")
    }
}

/// Navigation row: optional icon, title, subtitle, caret.
struct SettingsNavRow: View {
    var icon: String? = nil
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.l) {
                if let icon { Icon(name: icon, size: 24).foregroundStyle(Palette.subdued) }
                rowText(title, subtitle)
                Spacer(minLength: Space.s)
                if let value { Text(value).font(Typo.font(14)).foregroundStyle(Palette.subdued) }
                Icon(name: "caret-right", size: 16).foregroundStyle(Palette.dim)
            }
            .padding(.horizontal, Space.gutter)
            .frame(minHeight: icon == nil ? 56 : 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .accessibilityIdentifier("settings-row-\(title)")
    }
}

/// One choice in a Spotify radio list (empty ring / accent check).
struct SettingsRadioRow: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    var action: () -> Void
    var body: some View {
        Button { action() } label: {
            HStack(spacing: Space.l) {
                rowText(title, subtitle)
                Spacer(minLength: Space.s)
                ZStack {
                    if selected {
                        Circle().fill(Palette.accent).frame(width: 22, height: 22)
                            .overlay(Icon(name: "check", size: 13).foregroundStyle(.black))
                    } else {
                        Circle().stroke(Palette.dim, lineWidth: 1.5).frame(width: 22, height: 22)
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Palette.tinted : .clear)
    }
}

extension SettingsStore {
    func binding(_ key: String, default d: Bool = false) -> Binding<Bool> {
        Binding(get: { self.bool(key, default: d) }, set: { self.set(key, $0) })
    }
}

// MARK: settings list

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showZtunesAppearance = false

    private let rows: [(SettingsPage, String, String)] = [
        (.account, "user-circle", "Google account • Import • Export library"),
        (.contentDisplay, "device-mobile", "Explicit content • Unplayable songs"),
        (.playback, "play-circle", "Crossfade • Autoplay • Equalizer"),
        (.podcasts, "microphone", "Skip sponsors • Ad-free episodes • OPML"),
        (.privacy, "lock", "Private session • Listening history"),
        (.dataSaver, "cell-signal-full", "Data Saver • Offline mode"),
        (.audioQuality, "waveform", "Wi-Fi • Cellular • Downloads"),
        (.storage, "hard-drives", "Downloads • Cache"),
        (.recoverPlaylists, "arrow-counter-clockwise", "Restore playlists you deleted"),
        (.about, "info", "Version • Credits • Licenses"),
    ]

    var body: some View {
        SettingsScaffold(title: "Settings and privacy") {
            SettingsNavRow(icon: "sliders-horizontal", title: "Customization", subtitle: "Accent color • Persian lyrics") {
                showZtunesAppearance = true
            }
            // First, so linking a Mac is easy to find (Screens/Devices.swift).
            DevicesSection()
            Button { app.router.push(.settingsPage(.account)) } label: {
                HStack(spacing: Space.m) {
                    ProfileAvatar(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.localUser).font(Typo.font(18, .bold))
                        Text(profileSubtitle(app)).font(Typo.font(13)).foregroundStyle(Palette.subdued)
                    }
                    Spacer()
                    Icon(name: "caret-right", size: 16).foregroundStyle(Palette.dim)
                }
                .padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
            .padding(.bottom, Space.s)
            ForEach(rows, id: \.0) { page, icon, sub in
                SettingsNavRow(icon: icon, title: page.title, subtitle: sub) { app.router.push(.settingsPage(page)) }
            }
        }
        .sheet(isPresented: $showZtunesAppearance) { ZtunesAppearanceSettings() }
        .task { await app.settings.refresh(); await app.devices.refresh() }
    }
}

/// Under your name: the YouTube handle when signed in, else that the profile is local.
@MainActor func profileSubtitle(_ app: AppModel) -> String {
    guard app.account.signedIn else { return "Local profile" }
    let a = app.account.account
    return a.handle ?? a.email ?? "YouTube account"
}

// MARK: avatar side menu

/// Spotify's left drawer from the avatar: profile, What's new (with the New dot), Settings and privacy.
struct SideMenu: View {
    @Environment(AppModel.self) private var app
    @State private var dx: CGFloat = 0

    var body: some View {
        let open = app.router.sideMenuOpen
        GeometryReader { geo in
            let w = min(geo.size.width * 0.85, 340)
            ZStack(alignment: .leading) {
                Color.black.opacity(open ? 0.6 * Double(1 + min(0, dx) / w) : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .allowsHitTesting(open)
                panel
                    .frame(width: w)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Palette.highlight.ignoresSafeArea())
                    .offset(x: open ? min(0, dx) : -w - 20)
                    .gesture(DragGesture(minimumDistance: 8)
                        .onChanged { dx = min(0, $0.translation.width) }
                        .onEnded { v in
                            if v.translation.width < -w * 0.3 || v.predictedEndTranslation.width < -w * 0.6 { close() }
                            withAnimation(Motion.spring) { dx = 0 }
                        })
            }
            .animation(Motion.spring, value: open)
        }
        .allowsHitTesting(open)
        .accessibilityHidden(!open)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                ProfileAvatar(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.localUser).font(Typo.font(18, .bold))
                    Text(profileSubtitle(app)).font(Typo.font(13)).foregroundStyle(Palette.subdued)
                }
                Spacer()
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.l).padding(.bottom, Space.l)
            Divider().overlay(Palette.border)
            menuRow("lightning", "What's new", dot: app.settings.whatsNewCount > 0) { go(.whatsNew) }
            menuRow("clock-counter-clockwise", "Recents", dot: false) { go(.history) }
            menuRow("chart-bar", "Listening stats", dot: false) { go(.stats) }
            menuRow("gear", "Settings and privacy", dot: false) { go(.settings) }
            // Device sync: link a Mac, or (linked) its status at the top of Settings.
            menuRow("devices", DeviceSyncText.menuTitle(paired: app.devices.paired), dot: false) {
                if app.devices.paired { go(.settings) } else { close(); app.devices.open() }
            }
            .accessibilityIdentifier("side-menu-devices")
            Spacer()
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side-menu")
    }

    private func menuRow(_ icon: String, _ title: String, dot: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.l) {
                Icon(name: icon, size: 24)
                Text(title).font(Typo.font(16, .medium))
                if dot { Circle().fill(Palette.announcement).frame(width: 8, height: 8).accessibilityLabel("New") }
                Spacer()
            }
            .padding(.horizontal, Space.gutter).frame(height: 56).contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
    }

    private func go(_ r: Route) {
        app.router.push(r)
        close()
    }

    private func close() { withAnimation(Motion.spring) { app.router.sideMenuOpen = false } }
}

// MARK: sleep timer

/// Spotify's sleep timer list. When a timer runs, a live countdown header and "Turn off timer".
struct SleepTimerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    private let options: [(String, Int?)] = [("5 minutes", 5), ("10 minutes", 10), ("15 minutes", 15), ("30 minutes", 30),
                                            ("45 minutes", 45), ("1 hour", 60), ("End of track", nil)]

    var body: some View {
        let sleep = app.settings.sleep
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let mode = sleep.mode {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sleep timer").font(Typo.font(16, .bold))
                            Text(mode.kind == "endOfTrack" ? "Stops at the end of this track"
                                 : "\(timecode(max(0, (mode.endsAt ?? 0) - ctx.date.timeIntervalSince1970))) left")
                                .font(Typo.font(14)).foregroundStyle(Palette.accentText).monospacedDigit()
                        }
                    }
                } else {
                    Text("Sleep timer").font(Typo.font(16, .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Space.xl).padding(.bottom, Space.m)
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sleep.mode != nil {
                        row("Turn off timer") { app.settings.cancelSleep(); app.showToast("Sleep timer is off") }
                    }
                    ForEach(options, id: \.0) { title, minutes in
                        row(title) {
                            app.settings.setSleep(minutes: minutes, endOfTrack: minutes == nil)
                            app.showToast(minutes == nil ? "Sleep timer set: end of track" : "Sleep timer set: \(title)")
                        }
                    }
                }
                .padding(.vertical, Space.xs)
            }
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sleep-timer")
    }

    private func row(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            dismiss()
            action()
        } label: {
            Text(title).font(Typo.sheetItem).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.gutter).frame(height: 52).contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
    }
}

// Ztunes-specific appearance settings, persisted on the device.
private struct ZtunesAppearanceSettings: View {
    @AppStorage("ztunes.accent") private var accent = "red"
    @AppStorage("ztunes.lyrics.vazirmatn") private var useVazirmatn = true
    @AppStorage("ztunes.lyrics.rtl") private var alignPersianRight = true
    private let colors = [("red", "Red"), ("blue", "Blue"), ("green", "Green"),
                          ("amber", "Amber"), ("violet", "Violet")]
    var body: some View {
        SettingsScaffold(title: "Customization") {
            SettingsHeader(title: "Accent color")
            ForEach(colors, id: \.0) { key, label in
                SettingsRadioRow(title: label, selected: accent == key) { accent = key }
            }
            SettingsNote(text: "Some screens may need to be reopened to show the new accent.")
            SettingsHeader(title: "Lyrics")
            Toggle("Vazirmatn for Persian lyrics", isOn: $useVazirmatn)
                .tint(Palette.accent).padding(.horizontal, Space.gutter).frame(minHeight: 56)
            Toggle("Align Persian lyrics right", isOn: $alignPersianRight)
                .tint(Palette.accent).padding(.horizontal, Space.gutter).frame(minHeight: 56)
        }
    }
}
