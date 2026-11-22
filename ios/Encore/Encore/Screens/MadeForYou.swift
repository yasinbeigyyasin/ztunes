// Made for you hub (hero header + shelves of the generated mixes) and What's New (the Home bell):
// Spotify iOS layouts over the smart2 commands (`madeForYou`, `whatsNew`, `whatsNewMarkSeen`).
import SwiftUI

/// Our mark: the dark-pink disc and black beamed note of the Spotless master
/// (assets/brand/spotless.svg; the app icon puts it on a black tile). The "Spotless" owner badge
/// on Made for you pages and the corner of generated covers; `size` is the disc's diameter.
/// `SpotlessGlyph` is the master's note in its 100 box; the `gen-brand` lines are rewritten by
/// scripts/brand/gen-brand.py ship.
struct SpotlessMark: View {
    var size: CGFloat = 24
    static let disc = Color(hex: "#FF4B4B") // gen-brand
    static let ink = Color(hex: "#000000") // gen-brand
    static let discShare: CGFloat = 0.8 // gen-brand
    var body: some View {
        Circle().fill(Self.disc)
            .frame(width: size, height: size)
            .overlay(
                Image("SpotlessGlyph").resizable().renderingMode(.template).foregroundStyle(Self.ink)
                    .frame(width: size / Self.discShare, height: size / Self.discShare)
            )
            .accessibilityHidden(true)
    }
}

func isMadeForYouId(_ id: String) -> Bool { id.hasPrefix("MFY_") || id == "LIMUSIC_ON_REPEAT" }
/// Home's live Your Mix tiles (core kind `daily_mix`, before Made for you's first build): a
/// `smart_mix` page, not a playlist.
func isDailyMixId(_ id: String) -> Bool { id.hasPrefix("dailymix:") }

/// Back chevron in a dark disc, for pages with their own header.
struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Icon(name: "caret-left", size: 22).foregroundStyle(Palette.text).frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .accessibilityLabel("Back")
        .accessibilityIdentifier("back")
    }
}

// MARK: Made for you

struct MadeForYouView: View {
    @Environment(AppModel.self) private var app
    @State private var cards: [MfyCard] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var attempt = 0

    private func items(_ kinds: [MfyKind]) -> [BrowseItem] {
        cards.filter { kinds.contains($0.kind) }.map {
            BrowseItem(kind: .playlist, id: $0.id, title: $0.title, subtitle: $0.description, thumbnail: $0.thumbnail)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                hero
                if cards.isEmpty {
                    if loaded && !failed {
                        VStack(spacing: Space.s) {
                            Text("Your mixes are on the way").font(Typo.font(16, .bold))
                            Text("Play some music you like and Made for you fills up with mixes built from it.")
                                .font(Typo.font(14)).foregroundStyle(Palette.subdued).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.horizontal, Space.gutter)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("mfy-empty")
                    } else {
                        EntityLoadState(failed: failed) { failed = false; loaded = false; attempt += 1 }
                    }
                }
                shelf("Your Mixes", items([.daily]))
                shelf("Discover new music", items([.discoverWeekly, .releaseRadar]))
                shelf("Unique for you", items([.onRepeat, .repeatRewind]))
                Text("Made for you updates on its own: Your Mixes every day, Weekly Discoveries on Mondays, New Release Mix on Fridays.")
                    .font(Typo.meta).foregroundStyle(Palette.subdued)
                    .padding(.horizontal, Space.gutter)
            }
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, Space.s + 2).padding(.top, 4) }
        .background(Palette.base)
        .foregroundStyle(Palette.text)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: attempt) {
            // The cached mixes show at once; the fresh list replaces them. A failed read keeps the
            // cache, and only an empty page turns into the error with Try again.
            if cards.isEmpty { cards = app.settings.madeForYou }
            do {
                let c = try await app.core.madeForYou()
                cards = c; app.settings.madeForYou = c
                failed = false
                loaded = true
            } catch let error where !FriendlyError.isCancellation(error) {
                _ = friendlyError(error, "Couldn't load Made for you")
                failed = true
                loaded = true
            } catch {}
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hex: "#2d46b9"), Color(hex: "#1e3264").opacity(0.85), Palette.base],
                           startPoint: .top, endPoint: .bottom)
            // A fan of the first covers, Spotify-hub style.
            HStack(spacing: -40) {
                ForEach(Array(cards.prefix(3).enumerated()), id: \.offset) { i, c in
                    ArtImage(url: c.thumbnail, px: 320, radius: Radius.s).frame(width: 110, height: 110)
                        .rotationEffect(.degrees(Double(i - 1) * 8))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
                        .zIndex(i == 1 ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 120)
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Made for you").font(Typo.font(40, .black)).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Space.s) {
                    SpotlessMark(size: 22)
                    Text("Made for \(app.localUser)").font(Typo.metaBold)
                }
                Button { app.sheet = .aboutRecommendations } label: {
                    HStack(spacing: Space.xs) {
                        Icon(name: "info", size: 16)
                        Text("About recommendations").font(Typo.metaBold)
                    }
                    .foregroundStyle(Palette.subdued)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mfy-about-recs")
            }
            .padding(.horizontal, Space.gutter)
        }
        .frame(height: 360)
    }

    @ViewBuilder private func shelf(_ title: String, _ items: [BrowseItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionTitle(title: title)
                CardShelf(items: items)
            }
        }
    }
}

// MARK: What's New

struct WhatsNewView: View {
    @Environment(AppModel.self) private var app
    @State private var data: WhatsNew?
    @State private var filter: String?
    @State private var failed = false
    @State private var attempt = 0

    private var music: [WhatsNewRelease] { filter == "Podcasts & Shows" ? [] : data?.music ?? [] }
    private var pods: [WhatsNewEpisode] { filter == "Music" ? [] : data?.podcasts ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                BackButton()
                Text("What's New").font(Typo.font(20, .bold))
                Spacer()
            }
            .padding(.horizontal, Space.s + 2)
            .frame(height: 44)
            Text("The latest releases from artists, podcasts, and shows you follow.")
                .font(Typo.meta).foregroundStyle(Palette.subdued)
                .padding(.horizontal, Space.gutter).padding(.top, Space.s)
            HStack(spacing: Space.s) {
                if filter != nil {
                    Button { withAnimation(Motion.quick) { filter = nil } } label: {
                        Icon(name: "x", size: 16).frame(width: Metrics.chipHeight, height: Metrics.chipHeight).background(Circle().fill(Color(hex: "#2a2a2a")))
                    }
                    .accessibilityLabel("Clear filter")
                }
                ForEach(["Music", "Podcasts & Shows"].filter { filter == nil || filter == $0 }, id: \.self) { c in
                    Chip(title: c, selected: filter == c) { withAnimation(Motion.quick) { filter = filter == c ? nil : c } }
                }
            }
            .padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if data == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                    section("New", music.filter(\.isNew), pods.filter(\.isNew))
                    section("Earlier", music.filter { !$0.isNew }, pods.filter { !$0.isNew })
                    if data != nil && music.isEmpty && pods.isEmpty {
                        Text("Nothing new yet").font(Typo.font(16, .bold)).frame(maxWidth: .infinity).padding(.top, 80)
                            .accessibilityIdentifier("whatsnew-empty")
                    }
                }
            }
        }
        .background(Palette.base)
        .foregroundStyle(Palette.text)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            do { data = try await app.core.whatsNewRefreshed(); failed = false } catch let error where !FriendlyError.isCancellation(error) {
                // Pulled on purpose: say it didn't work, keep what's on screen.
                app.fail(friendlyError(error, "Couldn't check for new releases"))
                if data == nil { failed = true }
            } catch {}
        }
        .task(id: attempt) {
            do {
                data = try await app.core.whatsNew()
                failed = false
            } catch let error where !FriendlyError.isCancellation(error) {
                _ = friendlyError(error, "Couldn't load What's New")
                failed = true
                return
            } catch { return }
            // Nothing stored yet but you follow someone (the scheduled scan runs every few hours):
            // scan now, like a pull to refresh, instead of "Nothing new yet" for a new follow.
            let follows = app.library.snapshot.saved.contains { $0.kind == .artist } || !app.podcasts.follows.isEmpty
            if follows, data.map({ $0.music.isEmpty && $0.podcasts.isEmpty }) ?? true {
                do { data = try await app.core.whatsNewRefreshed() } catch {
                    // The stored (empty) list still shows; the scheduled scan tries again.
                    if !FriendlyError.isCancellation(error) { _ = friendlyError(error, "Couldn't check for new releases") }
                }
            }
            // Opening the page clears the bell's dot; this visit still shows what was new.
            do { try await app.core.whatsNewMarkSeen(); app.settings.whatsNewCount = 0 } catch {
                if !FriendlyError.isCancellation(error) { _ = friendlyError(error, "Couldn't clear the What's New dot") }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ m: [WhatsNewRelease], _ p: [WhatsNewEpisode]) -> some View {
        if !m.isEmpty || !p.isEmpty {
            Text(title).font(Typo.font(20, .bold)).padding(.horizontal, Space.gutter).padding(.top, Space.l).padding(.bottom, Space.xs)
            // Spotify interleaves by date; releases first, then episodes, both newest first.
            ForEach(m) { ReleaseRow(release: $0) }
            ForEach(p) { NewEpisodeRow(episode: $0.episode) }
        }
    }
}

/// "Today", "2 days ago", "3 weeks ago", else the year (a release first filed at the first scan);
/// the desktop's `releaseWhen`.
func whatsNewWhen(_ firstSeen: Double, year: Int, now: Double = Date().timeIntervalSince1970) -> String {
    guard firstSeen > 0 else { return String(year) }
    let days = Int(((now - firstSeen) / 86_400).rounded(.down))
    if days <= 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days < 7 { return "\(days) days ago" }
    if days < 30 { return "\(days / 7) week\(days < 14 ? "" : "s") ago" }
    return String(year)
}

private struct ReleaseRow: View {
    @Environment(AppModel.self) private var app
    let release: WhatsNewRelease
    private var card: BrowseItem {
        BrowseItem(kind: .album, id: release.id, title: release.title, subtitle: release.artist, thumbnail: release.thumbnail)
    }
    var body: some View {
        let saved = app.library.isSaved(release.id)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.m) {
                ArtImage(url: release.thumbnail, px: 200, radius: Radius.s).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(whatsNewWhen(release.firstSeen, year: release.year)).font(Typo.font(12, .semibold)).foregroundStyle(Palette.subdued)
                    Text(release.title).font(Typo.font(16, .bold)).lineLimit(2)
                    Text("\(release.releaseType) • \(release.artist)").font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Space.l + 4) {
                Button {
                    let on = app.library.toggleSaved(card)
                    Haptics.impact(.light)
                    app.showToast(on ? "Added to Your Library" : "Removed from Your Library")
                } label: {
                    Icon(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 24).foregroundStyle(saved ? Palette.accent : Palette.subdued)
                }
                .accessibilityLabel(saved ? "Remove from Your Library" : "Save to Your Library")
                Button { app.sheet = .collection(card) } label: {
                    Icon(name: "dots-three", size: 24).foregroundStyle(Palette.subdued)
                }
                .accessibilityLabel("More options")
                Spacer()
                PlayCircleButton(playing: app.player.queue.sourceId == release.id && !app.player.paused, size: 32, color: .white) { play() }
            }
            .padding(.leading, 64 + Space.m)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.m)
        .contentShape(Rectangle())
        .onTapGesture { app.router.push(.album(release.id)) }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("whatsnew-release")
    }
    private func play() {
        if app.player.queue.sourceId == release.id { app.player.togglePause(); return }
        Task {
            do {
                let page = try await app.core.getAlbum(id: release.id)
                guard !page.items.isEmpty else { app.fail("This release has no songs to play yet."); return }
                app.player.play(page.items, at: 0, context: PlayContext(kind: .album, id: release.id, title: page.title ?? release.title))
            } catch {
                app.fail(friendlyError(error, "Couldn't play this"))
            }
        }
    }
}

private struct NewEpisodeRow: View {
    @Environment(AppModel.self) private var app
    let episode: PodcastEpisode
    var body: some View {
        let saved = app.podcasts.isSaved(episode)
        let playing = app.player.now?.videoId == episode.id
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.m) {
                ArtImage(url: episode.thumbnail, px: 200, radius: Radius.s).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title).font(Typo.font(16, .bold)).foregroundStyle(playing ? Palette.accentText : Palette.text).lineLimit(2)
                    Text(episode.showTitle).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text([episodeDate(episode.publishedAt), episode.durationSecs.map(episodeLength) ?? ""].filter { !$0.isEmpty }.joined(separator: " • "))
                .font(Typo.meta).foregroundStyle(Palette.subdued)
            HStack(spacing: Space.l + 4) {
                Button {
                    let on = app.podcasts.toggleSaved(episode)
                    Haptics.impact(.light)
                    app.showToast(on ? "Added to Your Episodes" : "Removed from Your Episodes")
                } label: {
                    Icon(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 24).foregroundStyle(saved ? Palette.accent : Palette.subdued)
                }
                .accessibilityLabel(saved ? "Remove from Your Episodes" : "Save to Your Episodes")
                Button { app.sheet = .episode(episode) } label: {
                    Icon(name: "dots-three", size: 24).foregroundStyle(Palette.subdued)
                }
                .accessibilityLabel("More options")
                Spacer()
                PlayCircleButton(playing: playing && !app.player.paused, size: 32, color: .white) {
                    if playing { app.player.togglePause() } else {
                        app.player.play([episode.song], at: 0, context: PlayContext(kind: .song, id: nil, title: episode.showTitle))
                    }
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.m)
        .contentShape(Rectangle())
        .onTapGesture { app.router.push(.episode(episode.id)) }
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Your Mix

/// A Home "Your Mix" tile as a page: the desktop's `routes/mix/[id]` in the playlist page's
/// layout (EntityScaffold). Songs from `smart_mix`; Play / Shuffle play them with a `daily_mix`
/// context, as the desktop does, so the mix lands in Recents and Home's shortcuts.
struct DailyMixView: View {
    @Environment(AppModel.self) private var app
    let id: String
    let title: String
    let subtitle: String?
    let art: String?
    @State private var songs: [SongItem]?
    @State private var failed = false
    @State private var attempt = 0
    @State private var moreOpen = false

    private var items: [SongItem] { songs ?? [] }
    private var cover: String? { art ?? songs?.first?.thumbnail }
    private var context: PlayContext { PlayContext(kind: .dailyMix, id: id, title: title) }
    /// The core keeps no source id for a mix (it is no YouTube playlist): the queue named after it.
    private var playingThis: Bool {
        songs != nil && app.player.queue.sourceId == nil && app.player.queue.sourceName == title
    }
    private var meta: String {
        let m = items.isEmpty ? "" : CollectionMeta.songs(items, approx: true)
        return m.isEmpty ? "Made for \(app.localUser)" : "Made for \(app.localUser) • " + m
    }

    var body: some View {
        EntityScaffold(title: title, artURL: cover, isPlayingThis: playingThis, onPlay: onPlay) { off in
            EntityHeader(offset: off, cover: AnyView(ArtImage(url: cover, px: 720, radius: Radius.s)), title: title,
                         owner: "Ztunes", ownerArt: nil, ownerBadge: AnyView(SpotlessMark(size: 24)), meta: meta,
                         description: subtitle, actions: AnyView(actionIcons), playing: playingThis && !app.player.paused,
                         onShuffle: { play(nil, shuffle: true) }, shuffleOn: playingThis && app.player.shuffle, onPlay: onPlay)
        } content: {
            LazyVStack(spacing: 0) {
                if songs == nil {
                    EntityLoadState(failed: failed) { failed = false; attempt += 1 }
                } else if items.isEmpty {
                    VStack(spacing: Space.s) {
                        Text("This mix is empty right now").font(Typo.font(16, .bold))
                        Text("Play a few more songs and try again.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                    }
                    .frame(maxWidth: .infinity).padding(.top, Space.xxl)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                    TrackRow(song: s, context: context) { play(i) }
                }
            }
        }
        .accessibilityIdentifier("mix-page")
        .task(id: "\(id)#\(attempt)") { await load() }
        .sheet(isPresented: $moreOpen) {
            RadioMoreSheet(title: title, art: cover, subtitle: subtitle ?? "Ztunes", rows: moreRows)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
    }

    private func load() async {
        do {
            songs = try await app.core.smartMix(id: id, size: nil)
        } catch where !FriendlyError.isCancellation(error) {
            if songs == nil { failed = true } else { app.showToast("Couldn't refresh this mix") }
        } catch {}
    }

    private var actionIcons: some View {
        Button { moreOpen = true } label: { Icon(name: "dots-three", size: 24) }
            .disabled(items.isEmpty)
            .accessibilityLabel("More options")
            .accessibilityIdentifier("mix-more")
    }

    private var moreRows: [SheetRow] {
        let list = items, t = title
        return [
            SheetRow(icon: "queue", title: "Add to queue") { app.queue(list, from: t) },
            SheetRow(icon: "list-plus", title: "Play next") { app.playNext(list, from: t) },
            SheetRow(icon: "music-notes-plus", title: "Save as playlist") { save(list) },
            SheetRow(icon: "arrow-clockwise", title: "Refresh mix") { attempt += 1 },
        ]
    }

    private func onPlay() {
        if playingThis { app.player.togglePause(); return }
        play(nil)
    }

    private func play(_ start: Int?, shuffle: Bool = false) {
        guard !items.isEmpty else { return }
        let at = start ?? (shuffle ? Int.random(in: 0..<items.count) : 0)
        app.player.play(items, at: at, context: context, shuffle: shuffle)
    }

    private func save(_ list: [SongItem]) {
        Task {
            do {
                let p = try await app.core.createPlaylist(name: title)
                try await app.core.addToPlaylist(id: p.id, songs: list)
                await app.library.refresh()
                app.showToast("Added to Your Library", action: "View") { app.router.push(.playlist(p.id)) }
            } catch {
                app.showToast("Couldn't save this mix")
            }
        }
    }
}
