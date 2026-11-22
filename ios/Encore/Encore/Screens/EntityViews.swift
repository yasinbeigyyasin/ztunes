// Playlist / album / artist pages. One scaffold: cover-colour gradient header, cover that shrinks and
// fades on scroll, title moving into a tinted nav bar, and the accent play button that sticks under
// the nav bar once its row scrolls away.
import SwiftUI

private struct OffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
/// Where the page title's bottom edge is on screen (the scroll view's space, which starts at the top
/// of the screen; `.global` reads wrong once a TextField is in the header): the nav bar title fades
/// in once it passes under.
private struct TitleYKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
struct TitleAnchor: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in Color.clear.preference(key: TitleYKey.self, value: g.frame(in: .named("entity")).maxY) })
    }
}
private struct PlayYKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

struct EntityScaffold<Header: View, Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let title: String
    let artURL: String?
    var fixedTint: Color? = nil
    var heroHeader = false
    let isPlayingThis: Bool
    let onPlay: () -> Void
    /// Called once each time the page is pulled down past the top (overscroll of ~64 pt).
    var onPullDown: (() -> Void)? = nil
    @ViewBuilder let header: (_ offset: CGFloat) -> Header
    @ViewBuilder let content: () -> Content

    @State private var accent: UIColor?
    @State private var offset: CGFloat = 0
    @State private var playY: CGFloat = .infinity
    @State private var titleY: CGFloat = .infinity

    private var tint: Color { fixedTint ?? accent?.surface(value: 0.45, maxSaturation: 0.7) ?? Color(hex: "#3a3a3a") }
    private let navHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { g in Color.clear.preference(key: OffsetKey.self, value: -g.frame(in: .named("entity")).minY) }
                        .frame(height: 0)
                    header(offset)
                    content()
                }
            }
            .coordinateSpace(name: "entity")
            .onPreferenceChange(OffsetKey.self) { offset = $0 }
            .onChange(of: offset < -64) { _, pulled in if pulled { onPullDown?() } }
            .modifier(PullDownWatch(onPullDown: onPullDown))
            .onPreferenceChange(PlayYKey.self) { playY = $0 }
            .onPreferenceChange(TitleYKey.self) { titleY = $0 }
            .background(alignment: .top) {
                if !heroHeader {
                    LinearGradient(colors: [tint, Palette.base], startPoint: .top, endPoint: .bottom)
                        .frame(height: 460 + top)
                        .offset(y: -max(0, offset) * 0.6)
                        .ignoresSafeArea()
                }
            }
            .background(Palette.base)
            .overlay(alignment: .top) { navBar(top: top, progress: navProgress(top: top)) }
            .overlay(alignment: .topTrailing) {
                // Sticky play: shown once the inline button passes under the nav bar.
                if playY < top + navHeight - Metrics.playButton / 2 + 4 {
                    PlayCircleButton(playing: isPlayingThis && !app.player.paused, action: onPlay)
                        .padding(.trailing, Space.gutter)
                        .padding(.top, top + navHeight - Metrics.playButton / 2)
                        .accessibilityIdentifier("sticky-play")
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .toolbar(.hidden, for: .navigationBar)
        .foregroundStyle(Palette.text)
        .chromeInset()
        .artAccent(artURL, into: $accent)
    }

    /// 0 → 1 as the page title slides under the nav bar (Spotify's threshold), over ~24 pt of scroll.
    private func navProgress(top: CGFloat) -> Double {
        guard titleY.isFinite else { return min(1, max(0, (offset - (heroHeader ? 220 : 300)) / 40)) }
        return min(1, max(0, Double((top + navHeight + 8 - titleY) / 24)))
    }

    /// Back chevron (in a 32 pt dark circle over full-bleed images, plain over cover headers) and the
    /// centred 16/700 title on the tinted bar that fades in on scroll.
    private func navBar(top: CGFloat, progress: Double) -> some View {
        ZStack {
            Text(title).font(Typo.font(16, .bold)).lineLimit(1).padding(.horizontal, 56)
                .opacity(progress)
            HStack {
                Button { dismiss() } label: {
                    Icon(name: "caret-left", size: 24).frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(heroHeader ? 0.4 * (1 - progress) : 0)))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
                .accessibilityIdentifier("back")
                Spacer()
            }
            .padding(.horizontal, Space.s - 2)
        }
        .frame(height: navHeight)
        .padding(.top, top)
        .background((heroHeader ? (accent?.surface(value: 0.4) ?? Color(hex: "#3a3a3a")) : tint.mix(with: .black, by: 0.35)).opacity(progress))
        .animation(.easeOut(duration: 0.15), value: progress >= 1)
    }
}

extension Color {
    func mix(with other: Color, by f: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0, r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f)
    }
}

/// The scroll view's own overscroll (iOS 18+), which also sees a pull the content-frame preference
/// misses; either one firing calls `onPullDown`.
private struct PullDownWatch: ViewModifier {
    let onPullDown: (() -> Void)?
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let onPullDown {
            content.onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.contentInsets.top < -64 } action: { _, pulled in
                if pulled { onPullDown() }
            }
        } else {
            content
        }
    }
}

/// Measures where the inline play button sits, for the sticky copy.
struct PlayAnchor: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in Color.clear.preference(key: PlayYKey.self, value: g.frame(in: .named("entity")).minY) })
    }
}

/// Cover + title + meta + action row: the standard (non-artist) entity header.
struct EntityHeader: View {
    let offset: CGFloat
    let cover: AnyView
    let title: String
    var owner: String?
    var ownerArt: String?
    /// A badge in place of owner art (Made for you: our mark).
    var ownerBadge: AnyView? = nil
    let meta: String
    var description: String?
    let actions: AnyView
    let playing: Bool
    let onShuffle: () -> Void
    var shuffleOn = false
    let onPlay: () -> Void
    /// Above the cover, under the nav bar (a playlist's Find in playlist / Sort bar).
    var accessory: AnyView? = nil

    /// Spotify: the cover is ~2/3 of the screen width (260 pt at 390).
    static var coverSize: CGFloat { (UIScreen.main.bounds.width * 2 / 3).rounded() }

    var body: some View {
        // On scroll the cover shrinks to ~60 % and fades, centred, drifting up a little.
        let shrink = max(0.6, min(1, 1 - offset / 400))
        let side = Self.coverSize
        VStack(alignment: .leading, spacing: Space.s) {
            if let accessory { accessory.padding(.top, 104).transition(.opacity) }
            cover
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .scaleEffect(shrink, anchor: .bottom)
                .opacity(Double(min(1, max(0, 1.4 - offset / 220))))
                .frame(maxWidth: .infinity)
                .padding(.top, accessory == nil ? 60 : Space.l)
                .padding(.bottom, Space.s)
            Text(title).font(Typo.pageTitle).lineLimit(2).accessibilityAddTraits(.isHeader)
                .modifier(TitleAnchor())
            if let description, !description.isEmpty {
                Text(description).font(Typo.meta).foregroundStyle(Palette.subdued).lineLimit(2)
            }
            if let owner {
                HStack(spacing: Space.s) {
                    if let ownerBadge { ownerBadge } else if let ownerArt { ArtImage(url: ownerArt, px: 72, circle: true).frame(width: 24, height: 24) }
                    Text(owner).font(Typo.metaBold)
                }
            }
            Text(meta).font(Typo.meta).foregroundStyle(Palette.subdued)
            // Action row: 56 pt, 24 pt icons on a 48 pt pitch; shuffle, 20 pt, then the 48 pt play button.
            HStack(spacing: Space.l + 4) {
                actions
                Spacer()
                Button(action: onShuffle) {
                    Icon(name: "shuffle", size: 24).foregroundStyle(shuffleOn ? Palette.accent : Palette.subdued)
                        .overlay(alignment: .bottom) {
                            if shuffleOn { Circle().fill(Palette.accent).frame(width: 4, height: 4).offset(y: 8) }
                        }
                }
                .accessibilityLabel("Shuffle play")
                PlayCircleButton(playing: playing, action: onPlay).modifier(PlayAnchor())
                    .accessibilityIdentifier("entity-play")
            }
            .frame(height: 56)
            .foregroundStyle(Palette.subdued)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.s)
    }
}

/// Under the header while a page loads (spinner), or when it could not load (offline / network):
/// a centred 16/700 line, a subdued line and a white "Try again" pill.
struct EntityLoadState: View {
    let failed: Bool
    let retry: () -> Void
    var body: some View {
        VStack(spacing: Space.s) {
            if failed {
                Text("Couldn't load this page").font(Typo.font(16, .bold))
                Text("Check your connection and try again.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                Button(action: retry) {
                    Text("Try again").font(Typo.font(14, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 24).frame(height: 40).background(Capsule().fill(.white))
                }
                .buttonStyle(PressScale())
                .padding(.top, Space.s)
                .accessibilityIdentifier("entity-retry")
            } else {
                ProgressView().tint(Palette.subdued).accessibilityIdentifier("entity-loading")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xxl)
    }
}

/// An empty list (the desktop's EmptyState): an optional icon, a 24/700 title, a subdued line
/// and an optional white pill.
struct EntityEmptyState: View {
    var icon: String?
    let title: String
    let line: String
    var action: String?
    var onAction: () -> Void = {}
    var body: some View {
        VStack(spacing: Space.m) {
            if let icon { Icon(name: icon, size: 56).foregroundStyle(Palette.subdued).padding(.bottom, Space.xs) }
            Text(title).font(Typo.font(24, .bold))
            Text(line).font(Typo.font(16)).foregroundStyle(Palette.subdued)
            if let action {
                Button(action: onAction) {
                    Text(action).font(Typo.button).foregroundStyle(.black)
                        .padding(.horizontal, 32).frame(height: 48).background(Capsule().fill(.white))
                }
                .buttonStyle(PressScale())
                .padding(.top, Space.s)
                .accessibilityIdentifier("entity-empty-action")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .padding(.horizontal, Space.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entity-empty")
    }
}

// MARK: playlist

struct PlaylistView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var page: PlaylistPage?
    @State private var failed = false
    @State private var attempt = 0
    // Find in playlist + Sort by (gap #25).
    @State private var sort: PlaylistViewSort = .custom
    @State private var addedAt: [String: Int64]?
    @State private var findOpen = false
    @State private var query = ""
    @State private var sortOpen = false
    @FocusState private var findFocused: Bool
    // The "Recommended" footer (gap #4).
    @State private var recs: [Recommendation] = []
    @State private var recsBatch = 0
    @State private var recsLoading = false
    // Chips, Enhance and paging (I-B2; PlaylistSmarts.swift).
    @State private var smarts = PlaylistSmarts()

    var context: PlayContext { PlayContext(kind: id == likedPlaylistId ? .liked : .playlist, id: id, title: page?.title ?? "") }
    var playingThis: Bool { app.player.queue.sourceId == id }
    var isLiked: Bool { id == likedPlaylistId }
    var isMfy: Bool { isMadeForYouId(id) }
    var isLocal: Bool { id.hasPrefix("LOCALPLAYLIST:") }
    /// Your own playlist (on this phone, or yours on YouTube): it gets the Recommended footer.
    var isOwn: Bool { page?.owned == true && !isLiked && !isMfy }

    /// The rows in the chosen order; this is also the order Play and a row tap play in.
    var ordered: [SongItem] {
        let items = page?.items ?? []
        switch sort {
        case .custom: return items
        // Liked Songs comes newest first; elsewhere wait for the added-at times.
        case .recentlyAdded: return isLiked ? items : addedAt.map { sort.apply(items, addedAt: $0) } ?? items
        default: return sort.apply(items)
        }
    }

    /// Enhance and chips: own playlists and Liked Songs (chips: Liked Songs only).
    var canEnhance: Bool { isOwn || isLiked }

    var body: some View {
        let finding = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let all = smarts.queue(ordered, finding: finding)
        let rows = smarts.rows(ordered, query: query)
        EntityScaffold(title: page?.title ?? "", artURL: page?.thumbnail, fixedTint: isLiked ? Palette.likedHeader : nil,
                       isPlayingThis: playingThis, onPlay: play,
                       // Spotify: pulling the page down past the top reveals Find in playlist and Sort.
                       onPullDown: {
                           guard !findOpen, page != nil else { return }
                           withAnimation(Motion.quick) { findOpen = true }
                           Haptics.impact(.light)
                       }) { off in
            EntityHeader(offset: off, cover: AnyView(cover), title: page?.title ?? " ",
                         owner: isMfy ? "Ztunes" : isLiked || page?.owned == true ? app.localUser : ownerName, ownerArt: nil,
                         ownerBadge: isMfy ? AnyView(SpotlessMark(size: 24))
                            : (isLiked || page?.owned == true) ? AnyView(Avatar(size: 24, opensMenu: false)) : nil,
                         meta: isMfy ? "Made for \(app.localUser) • " + meta : meta, description: isLiked ? nil : page?.description,
                         actions: AnyView(actionIcons), playing: playingThis && !app.player.paused,
                         onShuffle: { shufflePlay() }, shuffleOn: playingThis && app.player.shuffle, onPlay: play,
                         accessory: findOpen ? AnyView(PlaylistFindBar(query: $query, focused: $findFocused) { findFocused = false; sortOpen = true }) : nil)
        } content: {
            LazyVStack(spacing: 0) {
                if page?.owned == true && !isLiked && !finding {
                    Button { app.sheet = .addSongs(id, page?.title ?? "") } label: {
                        HStack(spacing: Space.m) {
                            RoundedRectangle(cornerRadius: Radius.xs).fill(Palette.tinted).frame(width: 48, height: 48)
                                .overlay(Icon(name: "plus", size: 24))
                            Text("Add to this playlist").font(Typo.rowTitle)
                            Spacer()
                        }
                        .padding(.horizontal, Space.gutter).frame(height: Metrics.rowHeight).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("add-to-this-playlist")
                }
                if isLiked && !smarts.chips.chips.isEmpty && page != nil {
                    SmartChipsBar(chips: smarts.chips.chips, selected: $smarts.chip)
                }
                ForEach(rows) { row in
                    if row.suggestion {
                        EnhanceSuggestionRow(song: row.song, onAdd: {
                            Task { await smarts.keep(app, id: id, song: row.song, liked: isLiked, title: page?.title ?? "playlist") }
                        }, onRemove: {
                            Task { await smarts.remove(app, id: id, song: row.song) }
                        }) { playQueue(all, at: row.index) }
                    } else {
                        TrackRow(song: row.song, context: context) { playQueue(all, at: row.index) }
                            .onAppear { if smarts.continuation != nil && row.index >= all.count - 10 { loadMore() } }
                    }
                }
                if smarts.loadingMore { ProgressView().tint(Palette.subdued).frame(maxWidth: .infinity).frame(height: 56) }
                if finding && rows.isEmpty { FindNoMatch(query: query) }
                if page == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                // The desktop's empty states: Liked Songs points at Search; someone else's says so.
                if let p = page, p.items.isEmpty, !finding {
                    if isLiked {
                        EntityEmptyState(icon: "heart", title: "Songs you like will appear here",
                                         line: "Save songs by tapping the heart icon.", action: "Find songs") { app.router.select(.search) }
                    } else if p.owned != true && !isMfy {
                        EntityEmptyState(title: "This playlist is empty", line: "There's nothing here yet.")
                    }
                }
                if isOwn && !finding && page != nil && (recsLoading || !recs.isEmpty) {
                    RecommendedSection(recs: recs, loading: recsLoading, onAdd: addRecommendation) { recsBatch += 1 }
                }
            }
        }
        .task(id: "\(id)#\(attempt)") {
            restoreSort()
            page = await app.loadPlaylist(id)
            failed = page == nil
            // A long YouTube playlist pages in as you near the end.
            if let p = page, !isLocal, !isLiked, !isMfy { await smarts.loadContinuation(app, id: id, count: p.items.count) }
        }
        .task(id: "\(id)#chips-\(app.library.likedIds.count)") { if isLiked { await smarts.loadChips(app) } }
        .task(id: "\(id)#enhance-\(canEnhance)") { if canEnhance { await smarts.loadEnhance(app, id: id) } }
        .task(id: "\(id)#sort-\(sort.rawValue)#\(page?.items.count ?? -1)") { await loadAddedAt() }
        .task(id: "\(id)#recs-\(recsBatch)#\(isOwn)") { await loadRecommendations() }
        .sheet(isPresented: $sortOpen) {
            PlaylistSortSheet(options: PlaylistViewSort.options(liked: isLiked), selected: sort) { setSort($0) }
        }
        .onChange(of: app.library.likedIds) { _, _ in
            if isLiked { Task { page = try? await app.core.getPlaylist(id: id) } }
        }
        // An own playlist edited anywhere (add, edit, rename): reload its page. One on the YouTube
        // account says so through the core's `touched` stamp.
        .onChange(of: app.library.snapshot.playlists.first { $0.id == id }) { _, p in
            if p != nil { Task { page = try? await app.core.getPlaylist(id: id) } }
        }
        .onChange(of: app.library.snapshot.lastTouched?[id]) { _, t in
            if t != nil && !isLocal && !isLiked { Task { page = try? await app.core.getPlaylist(id: id) } }
        }
    }

    // MARK: sort / find

    private var defaultSort: PlaylistViewSort { isLiked ? .recentlyAdded : .custom }

    /// The order this playlist was last shown in, or what a `playlist?find=&sort=` link asks for
    /// (a link's order is not remembered).
    private func restoreSort() {
        sort = PlaylistViewSort.stored(for: id) ?? defaultSort
        if let f = app.router.playlistFind, f.id == id {
            app.router.playlistFind = nil
            if let s = f.sort { sort = s }
            if let q = f.query { findOpen = true; query = q }
        }
    }

    private func setSort(_ s: PlaylistViewSort) {
        sort = s
        PlaylistViewSort.store(s == defaultSort ? nil : s, for: id)
        // A playlist you own on YouTube keeps the order there too, so every client shows it.
        if page?.owned == true && !isLocal && !isLiked && !isMfy {
            Task { try? await app.core.setPlaylistSort(playlistId: id, sort: s.server) }
        }
    }

    /// Recently added needs each row's added time: a playlist on this phone has it per entry;
    /// YouTube's order is asked of YouTube.
    private func loadAddedAt() async {
        guard sort == .recentlyAdded, !isLiked, page != nil else { return }
        if isLocal {
            let entries = (try? await app.core.playlistEntries(id: id)) ?? []
            addedAt = Dictionary(entries.map { ($0.song.videoId, $0.addedAt) }, uniquingKeysWith: max)
        } else if let p = try? await app.core.getPlaylist(id: id, sort: PlaylistViewSort.recentlyAdded.server, desc: false) {
            let n = Int64(p.items.count)
            addedAt = Dictionary(p.items.enumerated().map { ($1.videoId, n - Int64($0)) }, uniquingKeysWith: max)
        }
    }

    // MARK: recommended

    private func loadRecommendations() async {
        guard isOwn else { recs = []; return }
        // The page first: recommendations are seeded by its songs.
        while page == nil && !failed && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(150)) }
        // An empty playlist still gets suggestions: the core seeds them from your listening.
        guard page != nil else { recs = []; return }
        recsLoading = true
        let got = (try? await app.core.playlistRecommendations(playlistId: id, n: 10, refresh: recsBatch)) ?? []
        guard !Task.isCancelled else { return }
        let have = Set(page?.items.map(\.videoId) ?? [])
        withAnimation(Motion.quick) { recs = got.filter { !have.contains($0.song.videoId) } }
        recsLoading = false
    }

    /// + on a recommendation: add it, and the row leaves the list (Spotify).
    private func addRecommendation(_ r: Recommendation) {
        Haptics.impact(.light)
        withAnimation(.easeOut(duration: 0.22)) { recs.removeAll { $0.song.videoId == r.song.videoId } }
        Task {
            do {
                try await app.core.addToPlaylist(id: id, songs: [r.song])
                app.showToast("Added to \(page?.title ?? "playlist")")
            } catch {
                withAnimation { recs.insert(r, at: 0) }
                app.showToast("Couldn't add that song. Try again.")
            }
        }
    }

    private var ownerName: String? {
        // The subtitle mixes owner, counts and years ("Playlist • YouTube Music • 50 tracks • 2024"): keep the owner.
        page?.subtitle?.components(separatedBy: " • ").first { part in
            let l = part.lowercased()
            return !["song", "track", "view", "playlist", "episode", "hour", "minute"].contains { l.contains($0) }
                && !(l.first?.isNumber ?? true)
        }
    }

    /// The desktop's meta line: "N songs, about 1 hr 2 min"; a long YouTube playlist still paging
    /// in says only its full count (from YouTube's subtitle), as the desktop does.
    private var meta: String {
        guard let p = page, !p.items.isEmpty else { return " " }
        if smarts.continuation != nil, let m = p.subtitle?.firstMatch(of: /([\d,.]+)\s*(songs?|tracks?)/),
           let n = Int(m.1.filter(\.isNumber)) {
            return "\(n.formatted(.number.locale(Locale(identifier: "en_US")))) songs"
        }
        return CollectionMeta.songs(p.items, approx: true)
    }

    @ViewBuilder private var cover: some View {
        if isLiked { LikedCover(size: EntityHeader.coverSize) }
        // A picked image (Edit playlist › Change image, `set_playlist_cover`) wins over the collage.
        else if let c = page?.cover, !c.isEmpty { ArtImage(url: c, px: 720, radius: Radius.s) }
        else if page?.owned == true, let four = MosaicCover.covers(page?.items ?? []) { MosaicCover(urls: four) }
        else { ArtImage(url: page?.thumbnail, px: 720, radius: Radius.s) }
    }

    private var actionIcons: some View {
        HStack(spacing: Space.xl) {
            if canEnhance && page != nil && query.isEmpty && smarts.chip == nil {
                EnhancePill(on: smarts.enhance?.on == true, busy: smarts.enhanceBusy) {
                    Task { await smarts.toggleEnhance(app, id: id, length: page?.items.count ?? 0) }
                }
            }
            if !isLiked && page?.owned != true {
                let saved = app.inLibrary(BrowseItem(kind: .playlist, id: id, title: ""))
                Button {
                    let on = app.toggleInLibrary(BrowseItem(kind: .playlist, id: id, title: page?.title ?? "", subtitle: page?.subtitle, thumbnail: page?.thumbnail))
                    Haptics.impact(.light)
                    app.showToast(on ? "Added to Your Library" : "Removed from Your Library")
                } label: {
                    Icon(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 24).foregroundStyle(saved ? Palette.accent : Palette.subdued)
                }
                .accessibilityLabel(saved ? "Remove from Your Library" : "Save to Your Library")
            }
            DownloadButton(item: BrowseItem(kind: .playlist, id: id, title: page?.title ?? "", subtitle: page?.subtitle, thumbnail: page?.thumbnail))
            Button { app.sheet = .collection(BrowseItem(kind: .playlist, id: id, title: page?.title ?? "", subtitle: page?.subtitle, thumbnail: page?.thumbnail)) } label: {
                Icon(name: "dots-three", size: 24)
            }
            .accessibilityLabel("More options")
        }
    }

    /// Play from a row of the shown list (a chip's set, or the list with Enhance's suggestions).
    private func playQueue(_ items: [SongItem], at i: Int) { app.player.play(items, at: i, context: context) }

    private func loadMore() {
        Task {
            guard var p = page else { return }
            await smarts.loadMore(app, into: &p.items)
            page = p
        }
    }

    private func play() {
        // Under a chip the filtered set is its own context: Play starts it rather than pausing.
        if playingThis && smarts.chip == nil { app.player.togglePause(); return }
        let items = smarts.queue(ordered, finding: !query.trimmingCharacters(in: .whitespaces).isEmpty)
        if !items.isEmpty { app.player.play(items, at: 0, context: context); return }
        // Tapped before the page arrived: load it, then play (never a dead button).
        Task { if let p = try? await app.core.getPlaylist(id: id), !p.items.isEmpty { page = p; app.player.play(ordered, at: 0, context: context) } }
    }
    private func shufflePlay() {
        let items = smarts.queue(ordered, finding: !query.trimmingCharacters(in: .whitespaces).isEmpty)
        guard !items.isEmpty else { return }
        app.player.play(items, at: Int.random(in: 0..<items.count), context: context, shuffle: true)
    }
}

// MARK: album

struct AlbumView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var page: AlbumPage?
    @State private var failed = false
    @State private var attempt = 0

    var context: PlayContext { PlayContext(kind: .album, id: id, title: page?.title ?? "") }
    var playingThis: Bool { app.player.queue.sourceId == id }

    var body: some View {
        let items = page?.items ?? []
        EntityScaffold(title: page?.title ?? "", artURL: page?.thumbnail, isPlayingThis: playingThis, onPlay: play) { off in
            EntityHeader(offset: off, cover: AnyView(ArtImage(url: page?.thumbnail, px: 720, radius: Radius.s)),
                         title: page?.title ?? " ", owner: page?.artist, ownerArt: page?.artistThumbnail,
                         meta: (page?.subtitle ?? " ").replacingOccurrences(of: " • ", with: " • "),
                         actions: AnyView(actionIcons), playing: playingThis && !app.player.paused,
                         onShuffle: shufflePlay, shuffleOn: playingThis && app.player.shuffle, onPlay: play)
        } content: {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                    TrackRow(song: s, showArt: false, context: context) { app.player.play(items, at: i, context: context) }
                }
                if page == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                // Footer: "N songs, 1 hr 2 min" (14 subdued), as under Spotify's album track list.
                if let second = page?.secondSubtitle {
                    Text(second).font(Typo.font(14)).foregroundStyle(Palette.subdued).padding(.horizontal, Space.gutter).padding(.top, Space.l)
                }
                ForEach(page?.sections ?? [], id: \.title) { s in
                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionTitle(title: s.title)
                        CardShelf(items: s.items)
                    }
                    .padding(.top, Space.xl)
                }
            }
        }
        .task(id: "\(id)#\(attempt)") { page = await app.loadAlbum(id); failed = page == nil }
    }

    private var actionIcons: some View {
        // Spotify's video-preview thumbnail is skipped (spec): save · download · more.
        HStack(spacing: Space.xl) {
            let saved = app.inLibrary(BrowseItem(kind: .album, id: id, title: ""))
            Button {
                let on = app.toggleInLibrary(BrowseItem(kind: .album, id: id, title: page?.title ?? "", subtitle: page?.artist, thumbnail: page?.thumbnail))
                Haptics.impact(.light)
                app.showToast(on ? "Added to Your Library" : "Removed from Your Library")
            } label: {
                Icon(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 24).foregroundStyle(saved ? Palette.accent : Palette.subdued)
            }
            .accessibilityLabel(saved ? "Remove from Your Library" : "Save to Your Library")
            DownloadButton(item: BrowseItem(kind: .album, id: id, title: page?.title ?? "", subtitle: page?.artist, thumbnail: page?.thumbnail))
            Button { app.sheet = .collection(BrowseItem(kind: .album, id: id, title: page?.title ?? "", subtitle: page?.artist, thumbnail: page?.thumbnail)) } label: {
                Icon(name: "dots-three", size: 24)
            }
            .accessibilityLabel("More options")
        }
    }

    private func play() {
        if playingThis { app.player.togglePause(); return }
        if let items = page?.items, !items.isEmpty { app.player.play(items, at: 0, context: context); return }
        // Tapped before the page arrived: load it, then play (never a dead button).
        Task { if let p = try? await app.core.getAlbum(id: id), !p.items.isEmpty { page = p; app.player.play(p.items, at: 0, context: context) } }
    }
    private func shufflePlay() {
        guard let items = page?.items, !items.isEmpty else { return }
        app.player.play(items, at: Int.random(in: 0..<items.count), context: context, shuffle: true)
    }
}

// MARK: artist

struct ArtistView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var page: ArtistPage?
    @State private var showAllPopular = false
    @State private var failed = false
    @State private var attempt = 0
    // Discography (gap #26): the block's chip, and the full page pushed over this one.
    @State private var discoFilter: Discography.Filter = .popular
    @State private var showDiscography = false
    @State private var discographyStart: Discography.Filter?
    @State private var disco = Discography.empty
    /// Releases by others the artist is on (Spotify's "Appears on"; the desktop's `getArtistAppearsOn`).
    @State private var appearsOn: [BrowseItem] = []

    var context: PlayContext { PlayContext(kind: .artist, id: id, title: page?.name ?? "") }
    var playingThis: Bool { app.player.queue.sourceId == id }

    var body: some View {
        let top = page?.topSongs ?? []
        EntityScaffold(title: page?.name ?? "", artURL: page?.thumbnail, heroHeader: true, isPlayingThis: playingThis, onPlay: play) { off in
            hero(off)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if page == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                if !top.isEmpty { Text("Popular").font(Typo.font(22, .bold)).padding(.horizontal, Space.gutter).padding(.top, Space.l).padding(.bottom, Space.s) }
                ForEach(Array(top.prefix(showAllPopular ? 10 : 5).enumerated()), id: \.offset) { i, s in
                    TrackRow(song: s, index: i + 1, showPlays: true, context: context) { app.player.play(top, at: i, context: context) }
                }
                if top.count > 5 {
                    // A plain text button under the five rows (Spotify), not a pill.
                    Button(showAllPopular ? "Show less" : "See more") { withAnimation { showAllPopular.toggle() } }
                        .font(Typo.font(14, .bold)).foregroundStyle(Palette.subdued)
                        .frame(height: 44)
                        .padding(.horizontal, Space.gutter)
                }
                // Spotify's order: Popular, Discography, then the rest (Featuring, Fans also like…).
                if !disco.filters.isEmpty {
                    DiscographyBlock(disco: disco, filter: $discoFilter) {
                        discographyStart = discoFilter == .popular ? nil : discoFilter
                        showDiscography = true
                    }
                }
                ForEach((page?.sections ?? []).filter { $0.kind != "albums" && $0.kind != "singles" }, id: \.title) { s in
                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionTitle(title: s.title)
                        CardShelf(items: s.items)
                    }
                    .padding(.top, Space.xl)
                }
                if !appearsOn.isEmpty {
                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionTitle(title: "Appears on")
                        CardShelf(items: appearsOn)
                    }
                    .padding(.top, Space.xl)
                    .accessibilityIdentifier("artist-appears-on")
                }
                if let d = page?.description {
                    VStack(alignment: .leading, spacing: Space.m) {
                        Text("About").font(Typo.sectionTitle)
                        VStack(alignment: .leading, spacing: Space.s) {
                            ArtImage(url: page?.thumbnail, px: 1080, radius: 0).frame(height: 180).clipped()
                            Text(page?.monthlyListeners?.replacingOccurrences(of: "audience", with: "listeners") ?? "").font(Typo.metaBold)
                                .padding(.horizontal, Space.l)
                            Text(d).font(Typo.font(14)).foregroundStyle(Palette.subdued).lineLimit(4)
                                .padding(.horizontal, Space.l).padding(.bottom, Space.l)
                        }
                        .background(Palette.highlight)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xl)
                }
            }
        }
        .task(id: "\(id)#\(attempt)") {
            page = try? await app.core.getArtist(id: id)
            failed = page == nil
            disco = page.map(Discography.of) ?? .empty
            // Not the artist's own releases, which the shelves above already show.
            if let p = page, let songs = p.topSongsId, let got = try? await app.core.getArtistAppearsOn(id: id, songsId: songs) {
                let own = Set(p.sections.flatMap { $0.items.map(\.id) })
                appearsOn = got.filter { !own.contains($0.id) }
            }
        }
        .navigationDestination(isPresented: $showDiscography) { DiscographyView(artistId: id, initial: discographyStart) }
        // `spotless://discography/<id>`: this page, then the full discography over it.
        .task(id: app.router.discography) {
            guard let r = app.router.discography, r.artistId == id else { return }
            app.router.discography = nil
            discographyStart = r.filter
            try? await Task.sleep(for: .milliseconds(400))
            showDiscography = true
        }
    }

    /// Hero image that stretches on overscroll, the name on it, then listeners + actions.
    private func hero(_ offset: CGFloat) -> some View {
        let stretch = max(0, -offset)
        let up = max(0, offset)
        let h = (UIScreen.main.bounds.width * 0.82).rounded()
        return VStack(alignment: .leading, spacing: Space.m) {
            ZStack(alignment: .bottomLeading) {
                // Overscroll stretches the photo from the top; scrolling moves it at half speed and fades it.
                ArtImage(url: page?.thumbnail, px: 1080, radius: 0)
                    .frame(height: h + stretch)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .offset(y: -stretch + up * 0.5)
                    .padding(.bottom, -stretch)
                    .opacity(Double(max(0, 1 - up / (h * 0.9))))
                LinearGradient(colors: [.clear, Palette.base.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                Text(page?.name ?? "").font(Typo.font(48, .extraBold)).lineLimit(2).minimumScaleFactor(32.0 / 48)
                    .padding(.horizontal, Space.gutter).padding(.bottom, Space.m)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(TitleAnchor())
            }
            .frame(height: h)
            .clipped()
            Text(page?.monthlyListeners?.replacingOccurrences(of: "audience", with: "listeners") ?? " ").font(Typo.meta).foregroundStyle(Palette.subdued)
                .padding(.horizontal, Space.gutter)
            // Follow outline pill (32 pt, 14/700, white 70 % border) · `…` · shuffle · play.
            HStack(spacing: Space.l + 4) {
                let following = app.inLibrary(BrowseItem(kind: .artist, id: id, title: ""))
                Button(following ? "Following" : "Follow") {
                    app.toggleInLibrary(BrowseItem(kind: .artist, id: id, title: page?.name ?? "", subtitle: "Artist", thumbnail: page?.thumbnail))
                    Haptics.impact(.light)
                }
                .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                .padding(.horizontal, 16).frame(height: 32)
                .overlay(Capsule().stroke(following ? Palette.text : Palette.muted, lineWidth: 1))
                .accessibilityIdentifier("artist-follow")
                Button { app.sheet = .collection(BrowseItem(kind: .artist, id: id, title: page?.name ?? "", subtitle: "Artist", thumbnail: page?.thumbnail)) } label: {
                    Icon(name: "dots-three", size: 24).foregroundStyle(Palette.subdued)
                }
                .accessibilityLabel("More options")
                Spacer()
                Button { shufflePlay() } label: { Icon(name: "shuffle", size: 24).foregroundStyle(Palette.subdued) }
                    .accessibilityLabel("Shuffle play")
                PlayCircleButton(playing: playingThis && !app.player.paused, action: play).modifier(PlayAnchor())
                    .accessibilityIdentifier("entity-play")
            }
            .padding(.horizontal, Space.gutter)
        }
    }

    private func play() {
        if playingThis { app.player.togglePause() } else if let items = page?.topSongs, !items.isEmpty { app.player.play(items, at: 0, context: context) }
    }
    private func shufflePlay() {
        guard let items = page?.topSongs, !items.isEmpty else { return }
        app.player.play(items, at: Int.random(in: 0..<items.count), context: context, shuffle: true)
    }
}

/// Spotify's cover for your own playlist: the first four different album covers in a 2×2 grid
/// (one cover until there are four).
struct MosaicCover: View {
    let urls: [String]
    static func covers(_ items: [SongItem]) -> [String]? {
        var seen = Set<String>(), out: [String] = []
        for s in items {
            guard let t = s.thumbnail, !t.isEmpty else { continue }
            let key = s.albumId ?? t
            if seen.insert(key).inserted { out.append(t) }
            if out.count == 4 { return out }
        }
        return nil
    }
    var body: some View {
        GeometryReader { g in
            let half = g.size.width / 2
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { c in
                            ArtImage(url: urls[r * 2 + c], px: 360, radius: 0).frame(width: half, height: half).clipped()
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .accessibilityHidden(true)
    }
}
