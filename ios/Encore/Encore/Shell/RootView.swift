// The app shell: one NavigationStack per tab (all kept alive), the bottom chrome (fade, mini player,
// custom tab bar), toasts, bottom-sheet menus, and the Now Playing cover above everything.
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("ztunes.accent") private var ztAccent = "red"

    var body: some View {
        @Bindable var app = app
        @Bindable var router = app.router
        ZStack(alignment: .bottom) {
            Palette.base.ignoresSafeArea()
            ForEach([Tab.home, .search, .library], id: \.self) { tab in
                NavigationStack(path: router.binding(tab)) {
                    tabRoot(tab)
                        .navigationDestination(for: Route.self) { destination($0) }
                }
                .opacity(router.tab == tab ? 1 : 0)
                .allowsHitTesting(router.tab == tab)
                .accessibilityHidden(router.tab != tab)
            }
            BottomChrome()
                .background(alignment: .bottom) {
                    // Black fade behind the tab bar and the mini player.
                    LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.85), location: 0.38),
                                           .init(color: .black, location: 0.62)], startPoint: .top, endPoint: .bottom)
                        .frame(height: chromeHeight(app) + 110)
                        .offset(y: 34)
                        .allowsHitTesting(false)
                }
            SideMenu()
                .zIndex(2.5)
            NowPlayingCover()
                .zIndex(3)
            // Above Now Playing too, so an Undo from its ··· menu is visible (Spotify shows it there).
            if let toast = app.toast {
                ToastView(message: toast)
                    .padding(.bottom, app.router.nowPlayingOpen ? 40 : chromeHeight(app) + 8)
                    .transition(Motion.slide(.bottom, fade: true))
                    .zIndex(4)
            }
        }
        .ignoresSafeArea(.keyboard)
        .sheet(item: $app.sheet) { subject in
            sheetContent(subject)
                .modifier(SheetDetents(detents: detents(subject)))
                .presentationDragIndicator(.visible)
                // Spotify 9.1.90: floating dark Liquid Glass sheets, inset 8 pt, radius ~36.
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
        .fullScreenCover(isPresented: $app.importOpen, onDismiss: { app.devices.importClosed() }) { ImportOnboarding().environment(app) }
        // Device sync: link a Mac (Screens/Devices.swift), and the first-run offer after the import.
        .sheet(isPresented: Bindable(app.devices).sheetOpen, onDismiss: { app.devices.closed() }) {
            LinkDeviceSheet().environment(app)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
        .fullScreenCover(isPresented: Bindable(app.devices).welcomeOpen) { DeviceLinkWelcome().environment(app) }
        #if DEBUG
        .sheet(isPresented: Bindable(app.router).debugOpen) { DebugAudioMenu() }
        #endif
        .alert(app.confirm?.title ?? "", isPresented: Binding(get: { app.confirm != nil }, set: { if !$0 { app.confirm = nil } }),
               presenting: app.confirm) { c in
            Button("Cancel", role: .cancel) {}
            Button(c.action, role: .destructive) { c.run() }
        } message: { c in
            if let m = c.message { Text(m) }
        }
        .tint(Palette.accent(for: ztAccent))
        .preferredColorScheme(.dark)
        // Like Spotify, the app's type is fixed-size (Typo uses fixedSize fonts); system text inside
        // it stops growing at xxxLarge so rows and sheets keep their layout.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private func sheetContent(_ s: SheetSubject) -> some View {
        switch s {
        case .sleepTimer: SleepTimerSheet()
        case .speed: SpeedSheet()
        case .chapters: ChaptersSheet()
        case .effects: EffectsSheet()
        case .aboutRecommendations: AboutRecommendationsSheet()
        case .newFolder: NameSheet(kind: .folder)
        case .newPlaylist: NameSheet(kind: .playlist)
        case .editPlaylist(let id): EditPlaylistSheet(id: id)
        case .addSongs(let id, let name): AddSongsSheet(id: id, name: name)
        case .create, .sort: FittedActionSheet(subject: s)
        case .addToPlaylist(let songs): AddToPlaylistSheet(songs: songs)
        default: ActionSheet(subject: s)
        }
    }

    /// nil: the sheet sets its own (content-fitted) detent.
    private func detents(_ s: SheetSubject) -> Set<PresentationDetent>? {
        switch s {
        case .create, .sort: nil
        case .sleepTimer: [.height(470)]
        case .speed: [.height(420)]
        case .effects: [.large]
        case .aboutRecommendations: [.large]
        case .newFolder, .newPlaylist, .addToPlaylist, .editPlaylist, .addSongs: [.large]
        default: [.medium, .large]
        }
    }

    @ViewBuilder private func tabRoot(_ tab: Tab) -> some View {
        switch tab {
        case .home: HomeView()
        case .search: SearchView()
        case .library: LibraryView()
        case .create: EmptyView()
        }
    }

    @ViewBuilder private func destination(_ r: Route) -> some View {
        switch r {
        case .album(let id): AlbumView(id: id)
        case .artist(let id): ArtistView(id: id)
        case .playlist(let id): PlaylistView(id: id)
        case .dailyMix(let id, let title, let subtitle, let art): DailyMixView(id: id, title: title, subtitle: subtitle, art: art)
        case .liked: PlaylistView(id: likedPlaylistId)
        case .searchResults(let q): SearchResultsView(query: q)
        case .mood(let params, let title): MoodView(params: params, title: title)
        // stream: audiobooks — a chapter's "show" is its book.
        case .show(let id): if let b = audiobookId(fromShow: id) { AudiobookView(id: b) } else { ShowView(id: id) }
        case .audiobook(let id): AudiobookView(id: id)
        case .episode(let id): EpisodeView(id: id)
        case .yourEpisodes: EpisodeListView(kind: .saved)
        case .newEpisodes: EpisodeListView(kind: .new)
        case .madeForYou: MadeForYouView()
        case .whatsNew: WhatsNewView()
        case .charts: ChartsView()
        case .newReleases: NewReleasesView()
        case .folder(let id): FolderView(id: id)
        case .settings: SettingsView()
        case .settingsPage(let p): SettingsPageView(page: p)
        // #27 "Show all" on Home shelves.
        case .shelf(let id, let title): ShelfGridView(id: id, title: title)
        case .radio(let kind, let id, let name): RadioView(kind: kind, id: id, name: name)
        case .history: HistoryView()
        case .stats: StatsView()
        }
    }
}

/// Dark glass behind sheets: the page blurs through, tinted near #1f1f1f so rows stay legible.
struct SheetGlass: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(hex: "#1c1c1c").opacity(0.78)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct SheetDetents: ViewModifier {
    let detents: Set<PresentationDetent>?
    func body(content: Content) -> some View {
        if let detents { content.presentationDetents(detents) } else { content }
    }
}

/// Bottom space screens reserve so content scrolls clear of the mini player, the offline bar and
/// the tab bar.
@MainActor func chromeHeight(_ app: AppModel) -> CGFloat {
    Metrics.tabBarHeight + (app.player.hasTrack ? Metrics.miniPlayerHeight + Metrics.miniGap : 0)
        + (app.downloads.offline ? OfflineBanner.height + Metrics.miniGap : 0)
}

struct ChromeInset: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: chromeHeight(app) + 16) }
    }
}

extension View {
    func chromeInset() -> some View { modifier(ChromeInset()) }
}

struct BottomChrome: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: Metrics.miniGap) {
            if app.downloads.offline {
                OfflineBanner(offlineMode: app.downloads.snapshot.network.offlineMode)
                    .padding(.horizontal, Metrics.miniPlayerInset)
                    .transition(Motion.slide(.bottom, fade: true))
            }
            if app.player.hasTrack {
                MiniPlayer().padding(.horizontal, Metrics.miniPlayerInset)
                    .transition(Motion.slide(.bottom, fade: true))
            }
            TabBar()
        }
        .animation(Motion.spring, value: app.player.hasTrack)
        .animation(Motion.spring, value: app.downloads.offline)
        .onChange(of: app.downloads.offline) { was, now in
            guard was != now else { return }
            // VoiceOver hears the flip either way; the bar itself is the sighted cue.
            UIAccessibility.post(notification: .announcement,
                                 argument: now ? OfflineBanner.text(offlineMode: app.downloads.snapshot.network.offlineMode) : "Back online")
        }
    }
}

/// Spotify's offline cue: a slim dark bar above the mini player for as long as there's no
/// connection (or Offline mode is on). Only downloads play meanwhile; rows that can't are greyed.
struct OfflineBanner: View {
    static let height: CGFloat = 32
    let offlineMode: Bool

    static func text(offlineMode: Bool) -> String { offlineMode ? "Offline mode is on" : "No internet connection" }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "wifi.slash").font(.system(size: 13, weight: .semibold))
            Text(Self.text(offlineMode: offlineMode)).font(Typo.font(13, .bold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Space.m)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color(hex: "#2a2a2a")))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offline-banner")
    }
}

struct TabBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let selected = app.router.tab == tab && tab != .create
                Button {
                    if tab == .create { app.sheet = .create } else { app.router.select(tab) }
                } label: {
                    VStack(spacing: 3) {
                        Group {
                            switch tab {
                            case .home: Icon(name: "house", fill: selected, size: Metrics.tabIcon)
                            case .search: Icon(name: "magnifying-glass", fill: selected, size: Metrics.tabIcon)
                            case .library: LibraryGlyph(filled: selected, size: Metrics.tabIcon)
                            case .create: Icon(name: "plus", size: Metrics.tabIcon)
                            }
                        }
                        Text(tab.title).font(Typo.tabLabel).lineLimit(1)
                    }
                    .foregroundStyle(selected ? Palette.text : Palette.subdued)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale(scale: 0.92))
                .accessibilityIdentifier("tab-\(tab.rawValue)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: Metrics.tabBarHeight)
        .padding(.top, 2)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app
    let message: ToastMessage
    var body: some View {
        HStack(spacing: Space.m) {
            // White toast, black 14/400 text; the action ("Change") 14/700 black at the right (Spotify).
            Text(message.text).font(Typo.font(14)).foregroundStyle(.black).lineLimit(2)
            Spacer(minLength: 0)
            if let action = message.action {
                Text(action).font(Typo.font(14, .bold)).foregroundStyle(.black)
            }
        }
        .padding(.horizontal, Space.l)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Color.white))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.horizontal, Space.s)
        .onTapGesture {
            let run = message.run
            withAnimation(Motion.quick) { app.toast = nil }
            run?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(message.run != nil ? .isButton : [])
        .accessibilityIdentifier("toast")
    }
}
