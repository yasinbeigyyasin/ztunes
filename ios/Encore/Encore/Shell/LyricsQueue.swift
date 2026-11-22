// Lyrics card (under Now Playing), full-screen lyrics, and the queue screen.
import SwiftUI

private func hasArabicScript(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x0600...0x06ff).contains(scalar.value) || (0x0750...0x077f).contains(scalar.value) ||
        (0x08a0...0x08ff).contains(scalar.value) || (0xfb50...0xfdff).contains(scalar.value) ||
        (0xfe70...0xfeff).contains(scalar.value)
    }
}

@MainActor @Observable
final class LyricsModel {
    var lyrics: Lyrics?
    var loadedFor: String?
    func load(_ app: AppModel) async {
        guard let s = app.player.current, s.videoId != loadedFor else { return }
        loadedFor = s.videoId
        lyrics = try? await app.core.getLyrics(videoId: s.videoId, title: s.title, artists: s.artists, duration: s.seconds)
    }
    /// Index of the line being sung (synced lyrics), or nil before the first cue.
    func activeIndex(at seconds: Double) -> Int? { lyrics?.activeIndex(at: seconds) }

    // The ⋯ menu (desktop `pickLyricsSource` / `nudgeLyricsOffset`).
    var providers: [LyricsProvider] = []
    func loadProviders(_ app: AppModel) async {
        if providers.isEmpty { providers = (try? await app.core.lyricsProviders()) ?? [] }
    }
    /// Keep `source`'s lyrics for this song (nil: back to automatic).
    func pickSource(_ source: String?, _ app: AppModel) async {
        guard let s = app.player.current else { return }
        do {
            let l = try await app.core.chooseLyricsSource(videoId: s.videoId, title: s.title, artists: s.artists, duration: s.seconds, source: source)
            guard app.player.current?.videoId == s.videoId else { return }
            if let l { lyrics = l } else if source != nil {
                app.showToast("No lyrics from \(providers.first { $0.id == source }?.name ?? "that source") for this song")
            } else { lyrics = nil }
        } catch { app.showToast("Couldn't load lyrics") }
    }
    /// Nudge the timing by `deltaMs` (positive: lyrics later). Applied at once; the core keeps it.
    func nudge(_ deltaMs: Int, _ app: AppModel) async {
        guard let id = loadedFor, lyrics != nil else { return }
        let want = (lyrics?.offsetMs ?? 0) + deltaMs
        lyrics?.offsetMs = want
        lyrics?.pinned = true
        let kept = (try? await app.core.setLyricsOffset(videoId: id, offsetMs: want)) ?? want
        if loadedFor == id { lyrics?.offsetMs = kept }
    }
    /// Read the song's lyrics again (after the full view changed its source or timing).
    func reload(_ app: AppModel) async {
        loadedFor = nil
        await load(app)
    }
    var lines: [(Int, LyricLine)] { (lyrics?.lines ?? []).enumerated().filter { !$0.element.text.isEmpty }.map { ($0.offset, $0.element) } }
}

struct LyricsCard: View {
    @Environment(AppModel.self) private var app
    @AppStorage("ztunes.lyrics.vazirmatn") private var useVazirmatn = true
    @AppStorage("ztunes.lyrics.rtl") private var alignPersianRight = true
    let accent: UIColor?
    @State private var model = LyricsModel()

    var body: some View {
        let active = model.activeIndex(at: app.player.position)
        VStack(alignment: .leading, spacing: Space.m) {
            // "Lyrics" 16/700 top-left; share and expand at the top-right (Spotify).
            HStack(spacing: Space.s) {
                Text("Lyrics").font(Typo.font(16, .bold))
                Spacer()
                Button { if let s = app.player.current { ShareSheet.present(.song(s), app: app) } } label: {
                    Icon(name: "export", size: 16).frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(0.3)))
                }
                .accessibilityLabel("Share lyrics")
                Button { app.router.lyricsOpen = true } label: {
                    Icon(name: "arrows-out-simple", size: 16).frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(0.3)))
                }
                .accessibilityLabel("Expand lyrics")
                .accessibilityIdentifier("lyrics-expand")
            }
            if model.lines.isEmpty {
                Text(model.lyrics == nil ? "Lyrics aren't available for this song" : "♪").font(Typo.lyricsCard).foregroundStyle(.black.opacity(0.6))
            } else {
                let window = lineWindow(active)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(window, id: \.0) { i, line in
                        Text(line.text).font(useVazirmatn && hasArabicScript(line.text) ? .custom("Vazirmatn-Bold", fixedSize: 22) : Typo.lyricsCard)
                            .environment(\.layoutDirection, alignPersianRight && hasArabicScript(line.text) ? .rightToLeft : .leftToRight)
                            .frame(maxWidth: .infinity, alignment: alignPersianRight && hasArabicScript(line.text) ? .trailing : .leading)
                            .multilineTextAlignment(alignPersianRight && hasArabicScript(line.text) ? .trailing : .leading)
                            .foregroundStyle(lineColor(i, active))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: active)
            }
        }
        .foregroundStyle(Palette.text)
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
            .fill(accent?.surface(value: 0.62, maxSaturation: 0.6) ?? Color(hex: "#5a5a5a")))
        .padding(.horizontal, Space.gutter)
        .task(id: app.player.current?.videoId) { await model.load(app) }
        // The full view may have picked another source or nudged the timing.
        .onChange(of: app.router.lyricsOpen) { _, open in if !open { Task { await model.reload(app) } } }
        .onTapGesture { app.router.lyricsOpen = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("lyrics-card")
    }

    private func lineWindow(_ active: Int?) -> [(Int, LyricLine)] {
        let lines = model.lines
        let pos = lines.firstIndex { $0.0 >= (active ?? 0) } ?? 0
        // ~6 lines, the sung line first (Spotify's card scrolls with playback).
        let start = max(0, min(pos, lines.count - 6))
        return Array(lines[start..<min(lines.count, start + 6)])
    }
}

func lineColor(_ i: Int, _ active: Int?) -> Color {
    guard let a = active else { return .white }
    if i == a { return .white }
    return i < a ? .white.opacity(0.6) : .black.opacity(0.75)
}

struct LyricsFullView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("ztunes.lyrics.vazirmatn") private var useVazirmatn = true
    @AppStorage("ztunes.lyrics.rtl") private var alignPersianRight = true
    let accent: UIColor?
    var insets = EdgeInsets()
    @State private var model = LyricsModel()
    /// A manual scroll pauses auto-follow for ~3 s (Spotify).
    @State private var userScrolledAt: Date?

    var body: some View {
        let active = model.activeIndex(at: app.player.position)
        VStack(spacing: 0) {
            HStack {
                Button { app.router.lyricsOpen = false } label: { Icon(name: "caret-down", size: 24).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close lyrics")
                Color.clear.frame(width: 44, height: 44) // balances the ⋯ so the title stays centred
                Spacer()
                VStack(spacing: 1) {
                    Text(app.player.current?.title ?? "").font(Typo.font(14, .bold)).lineLimit(1)
                    Text(app.player.current?.artists ?? "").font(Typo.font(13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                Button { if let s = app.player.current { ShareSheet.present(.song(s), app: app) } } label: {
                    Icon(name: "export", size: 22).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share lyrics")
                LyricsMenu(model: model)
            }
            .padding(.horizontal, Space.s)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    // 26/700, 6 pt line spacing, 16 pt between lines, insets 24.
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.lines, id: \.0) { i, line in
                            Text(line.text).font(useVazirmatn && hasArabicScript(line.text) ? .custom("Vazirmatn-Bold", fixedSize: 26) : Typo.lyricsFull).lineSpacing(6).foregroundStyle(lineColor(i, active))
                                .environment(\.layoutDirection, alignPersianRight && hasArabicScript(line.text) ? .rightToLeft : .leftToRight)
                                .multilineTextAlignment(alignPersianRight && hasArabicScript(line.text) ? .trailing : .leading)
                                .frame(maxWidth: .infinity, alignment: alignPersianRight && hasArabicScript(line.text) ? .trailing : .leading)
                                .id(i)
                                .accessibilityIdentifier(i == active ? "lyric-active" : "lyric-line")
                                .accessibilityAddTraits(.isButton)
                                .onTapGesture {
                                    if let t = line.timeMs { app.player.seek(Double(t) / 1000) }
                                }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, 120)
                    if let l = model.lyrics, !model.lines.isEmpty {
                        Text(lyricsAttribution(l)).font(Typo.font(12)).foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.xl).padding(.bottom, Space.xl)
                    }
                }
                .modifier(UserScrollWatch { userScrolledAt = Date() })
                .onChange(of: active) { _, a in
                    if let t = userScrolledAt, Date().timeIntervalSince(t) < 3 { return }
                    if let a { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(a, anchor: UnitPoint(x: 0, y: 0.3)) } }
                }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            // Mini scrubber (2 pt) with times, then previous / the 48 pt white play-pause circle / next.
            VStack(spacing: Space.s) {
                Scrubber(trackHeight: 2)
                HStack(spacing: Space.xxl) {
                    Button { app.player.skipPrevious() } label: {
                        Icon(name: "skip-back", fill: true, size: 28).frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Previous")
                    .accessibilityIdentifier("lyrics-prev")
                    PlayCircleButton(playing: !app.player.paused, size: 48, color: .white) { app.player.togglePause() }
                    Button { app.player.skipNext() } label: {
                        Icon(name: "skip-forward", fill: true, size: 28).frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Next")
                    .accessibilityIdentifier("lyrics-next")
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.l + insets.bottom)
        }
        .padding(.top, insets.top)
        .foregroundStyle(.white)
        .background((accent?.surface(value: 0.55, maxSaturation: 0.6) ?? Color(hex: "#5a5a5a")).ignoresSafeArea())
        .task(id: app.player.current?.videoId) { await model.load(app) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics-full")
    }
}

/// The full-screen lyrics ⋯ (desktop lyrics toolbar "…"): Lyrics source ▸ and, for synced
/// lyrics, Timing ▸ in ±0.5 s steps with Reset.
struct LyricsMenu: View {
    @Environment(AppModel.self) private var app
    let model: LyricsModel

    var body: some View {
        let l = model.lyrics
        let pinned = l?.pinned ?? false
        let offset = l?.offsetMs ?? 0
        Menu {
            Menu {
                Button { Task { await model.pickSource(nil, app) } } label: { checked("Automatic", !pinned) }
                Divider()
                ForEach(model.providers.filter(\.on)) { p in
                    Button { Task { await model.pickSource(p.id, app) } } label: { checked(p.name, pinned && l?.provider == p.id) }
                }
            } label: { Label("Lyrics source", systemImage: "music.mic") }
            if l?.synced == true {
                Menu {
                    Button { Task { await model.nudge(-250, app) } } label: { Label("Show lyrics earlier", systemImage: "minus") }
                    Button { Task { await model.nudge(250, app) } } label: { Label("Show lyrics later", systemImage: "plus") }
                    if offset != 0 {
                        Button { Task { await model.nudge(-offset, app) } } label: { Label("Reset timing", systemImage: "arrow.counterclockwise") }
                    }
                } label: { Label(offset == 0 ? "Timing" : "Timing: \(Self.secs(offset))", systemImage: "timer") }
            }
        } label: {
            Icon(name: "dots-three", size: 22).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Lyrics options")
        .accessibilityIdentifier("lyrics-menu")
        .task { await model.loadProviders(app) }
    }

    /// "+0.5 s" / "-1.0 s".
    static func secs(_ ms: Int) -> String { (ms > 0 ? "+" : "") + String(format: "%.1f s", Double(ms) / 1000) }

    @ViewBuilder private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// "Lyrics provided by LRCLIB": the desktop's attribution line (`lyrics.svelte.ts` `attribution`),
/// from the provider's attribution string, else its id.
func lyricsAttribution(_ l: Lyrics) -> String {
    let src = l.source.replacingOccurrences(of: #"^Source:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespaces)
    return "Lyrics provided by \(src.isEmpty ? l.provider : src)"
}

/// Calls `onUserScroll` when the user drags the scroll view (iOS 18+; a no-op before).
struct UserScrollWatch: ViewModifier {
    let onUserScroll: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in if phase == .interacting { onUserScroll() } }
        } else { content }
    }
}

/// The queue (Spotify 9.1.90): a floating dark-glass sheet inset 8 pt over Now Playing, radius ~36,
/// grabber; "Queue" 22/700 with "Playing from: <context>" and an Edit pill; the now-playing row with a
/// white pause circle; "Next in queue" (Clear queue) and "Next from: …" sections with drag handles;
/// three glass footer buttons (Shuffle · Repeat · Timer). Edit adds selection circles and swaps the
/// footer for Remove / Add to playlist.
struct QueueView: View {
    @Environment(AppModel.self) private var app
    var insets = EdgeInsets()
    @State private var selection = Set<Int>()
    @State private var editing = false
    @State private var drag: CGFloat = 0
    @State private var pill: String?
    @State private var pillTask: Task<Void, Never>?

    var body: some View {
        let p = app.player
        let up = p.upcoming
        let queued = up.filter { $0.song.isQueued }
        // Spotify: the context's own rows under "Next from: <context>", then what Autoplay brought
        // in under "Next: Autoplay" (a single pick has only the latter). Once Autoplay starts, the
        // rest goes with it, as on the desktop (`queue.ts`).
        let notQueued = up.filter { !$0.song.isQueued }
        // Podcast up next (the core's predictions, each with its reason): one "Next up" block from
        // the show's own next episode on, as on the desktop (`queue.ts`).
        let autoStart = notQueued.firstIndex { $0.song.autoplay == true || $0.song.reason != nil } ?? notQueued.count
        let upNext = notQueued[autoStart...].first?.song.isEpisode == true
        let rest = Array(notQueued[..<autoStart])
        let auto = Array(notQueued[autoStart...])
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Grabber (36×5 at 6 pt); also the explicit close for VoiceOver.
                    Button { close() } label: {
                        Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 6)
                            .frame(width: 80, height: 16, alignment: .top).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close queue")
                    .accessibilityIdentifier("queue-close")
                    header(p)
                }
                .contentShape(Rectangle())
                .gesture(dismissDrag)
                List(selection: editing ? $selection : nil) {
                    if let cur = p.current {
                        nowRow(cur).moveDisabled(true).selectionDisabled()
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                    }
                    if !queued.isEmpty {
                        Section {
                            ForEach(queued, id: \.index) { row($0.song, index: $0.index).tag($0.index) }
                                .onMove { from, to in move(queued, from, to) }
                        } header: {
                            HStack {
                                sectionTitle("Next in queue")
                                Spacer()
                                // "Queue cleared · Undo" (lane P1; `restore_queued`).
                                Button("Clear queue") { QueueUndo.clear(app) }
                                    .font(Typo.font(14, .bold)).foregroundStyle(Palette.subdued)
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("queue-clear")
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        }
                    }
                    if !rest.isEmpty {
                        Section {
                            ForEach(rest, id: \.index) { row($0.song, index: $0.index).tag($0.index) }
                                .onMove { from, to in move(rest, from, to) }
                        } header: {
                            sectionTitle(p.queue.sourceName.map { "Next from: \($0)" } ?? "Next up")
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        }
                    }
                    if !auto.isEmpty {
                        Section {
                            ForEach(auto, id: \.index) { row($0.song, index: $0.index).tag($0.index) }
                                .onMove { from, to in move(auto, from, to) }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                sectionTitle(upNext ? "Next up" : "Next: Autoplay")
                                if !upNext {
                                    Text("Similar songs keep playing when your music ends.")
                                        .font(Typo.font(13)).foregroundStyle(Palette.subdued)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("queue-autoplay")
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
                .environment(\.defaultMinListRowHeight, 64)
                .tint(Palette.accent)   // accent selection circles
                footer
                    .padding(.horizontal, Space.l).padding(.top, Space.s)
                    .padding(.bottom, max(Space.l, insets.bottom - Space.s))
                    .overlay(alignment: .top) {
                        if let pill {
                            Text(pill).font(Typo.font(13, .bold)).foregroundStyle(Palette.text)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(Color(hex: "#2a2a2a")))
                                .offset(y: -38)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                .accessibilityIdentifier("queue-pill")
                        }
                    }
            }
            .foregroundStyle(Palette.text)
            .background {
                // Dark Liquid Glass: blur of Now Playing behind, darkened so rows stay legible.
                RoundedRectangle(cornerRadius: 36, style: .continuous).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Color(hex: "#121212").opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            }
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.top, insets.top + 8)
            .padding(.bottom, 8)
            .offset(y: drag)
            // The app's toasts sit under Now Playing; the queue shows its own ("Queue cleared · Undo")
            // above the footer buttons.
            if let toast = app.toast {
                ToastView(message: toast)
                    .padding(.horizontal, 8)
                    .padding(.bottom, max(Space.l, insets.bottom - Space.s) + 84)
                    .transition(Motion.slide(.bottom, fade: true))
                    .zIndex(2)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue")
    }

    private func close() {
        editing = false; selection = []
        app.router.queueOpen = false
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { drag = max(0, $0.translation.height) }
            .onEnded { v in
                if v.translation.height > 140 || v.predictedEndTranslation.height > 400 { close() }
                withAnimation(Motion.spring) { drag = 0 }
            }
    }

    private func header(_ p: PlayerStore) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Queue").font(Typo.font(22, .bold))
                if let src = p.queue.sourceName, !src.isEmpty {
                    (Text("Playing from: ").foregroundStyle(Palette.muted) + Text(src).font(Typo.font(14, .bold)))
                        .font(Typo.font(14)).lineLimit(1)
                }
            }
            Spacer(minLength: Space.m)
            Button {
                withAnimation(Motion.quick) { editing.toggle(); if !editing { selection = [] } }
            } label: {
                Text(editing ? "Done" : "Edit").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .accessibilityIdentifier("queue-edit")
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .padding(.top, Space.m).padding(.bottom, Space.s)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(Typo.font(16, .bold)).foregroundStyle(Palette.text).textCase(nil).lineLimit(1)
            .padding(.top, Space.m).padding(.bottom, Space.xs)
    }

    /// Now playing: accent title with the equaliser, and a 32 pt white play/pause circle.
    private func nowRow(_ s: SongItem) -> some View {
        HStack(spacing: Space.m) {
            ArtImage(url: s.thumbnail, px: 144, radius: Radius.xs).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    EqualizerGlyph(animating: !app.player.paused)
                    Text(s.title).font(Typo.rowTitle).foregroundStyle(Palette.accentText).lineLimit(1)
                }
                HStack(spacing: 5) {
                    if s.explicit == true { ExplicitBadge() }
                    Text(s.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { app.player.togglePause() } label: {
                Circle().fill(Color.white).frame(width: 32, height: 32)
                    .overlay(Icon(name: app.player.paused ? "play" : "pause", fill: true, size: 14).foregroundStyle(.black)
                        .offset(x: app.player.paused ? 1 : 0))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(app.player.paused ? "Play" : "Pause")
            .accessibilityIdentifier("queue-play")
        }
        .frame(height: 64)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func row(_ s: SongItem, index: Int) -> some View {
        HStack(spacing: Space.m) {
            ArtImage(url: s.thumbnail, px: 144, radius: Radius.xs).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(Typo.rowTitle).foregroundStyle(Palette.text).lineLimit(1)
                HStack(spacing: 4) {
                    // Smart Shuffle suggestion: accent sparkle before the artist (Spotify).
                    if isSuggestion(s) { Icon(name: "sparkle", fill: true, size: 12).foregroundStyle(Palette.accent) }
                    if s.explicit == true { ExplicitBadge() }
                    Text(s.reason ?? s.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isSuggestion(s) && !editing {
                Button {
                    Haptics.impact(.light)
                    app.settings.smartShuffle.recIds.removeAll { $0 == s.videoId }
                    Task { if let st = try? await app.core.smartShuffleRemove(videoId: s.videoId) { app.settings.smartShuffle = st } }
                    app.showToast("Removed suggestion")
                } label: { Icon(name: "minus-circle", size: 22).foregroundStyle(Palette.subdued).frame(width: 36, height: 44) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove suggestion")
                Button {
                    Haptics.impact(.light)
                    app.settings.smartShuffle.recIds.removeAll { $0 == s.videoId }
                    Task {
                        if let st = try? await app.core.smartShuffleKeep(videoId: s.videoId) { app.settings.smartShuffle = st }
                        if !app.library.isLiked(s.videoId) { app.toggleLike(s) }
                    }
                } label: { Icon(name: "plus-circle", size: 22).foregroundStyle(Palette.subdued).frame(width: 36, height: 44) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Keep suggestion")
            }
        }
        .frame(height: 64)
        .contentShape(Rectangle())
        // A tap plays that row (Spotify); in Edit mode the list's own tap selects it instead.
        .simultaneousGesture(TapGesture().onEnded { app.player.playIndex(index) }, including: editing ? .subviews : .all)
        .accessibilityAddTraits(.isButton)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue-row")
    }

    private func isSuggestion(_ s: SongItem) -> Bool { app.settings.smartShuffle.on && app.settings.smartShuffle.recIds.contains(s.videoId) }

    private func move(_ block: [(index: Int, song: SongItem)], _ from: IndexSet, _ to: Int) {
        guard let f = from.first else { return }
        Haptics.impact(.light)
        // Each block is a contiguous run of the queue; onMove's `to` counts before the removal.
        let t = to > f ? to - 1 : to
        app.player.move(from: block[f].index, to: block[0].index + t)
    }

    private func showPill(_ text: String) {
        withAnimation(Motion.quick) { pill = text }
        pillTask?.cancel()
        pillTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.quick) { pill = nil }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: Space.s) {
            if editing {
                let songs = selection.sorted().compactMap { i in app.player.queue.items.indices.contains(i) ? app.player.queue.items[i] : nil }
                glassButton("Remove", icon: "minus-circle", on: false, enabled: !selection.isEmpty) {
                    for i in selection.sorted(by: >) { app.player.remove(at: i) }
                    selection = []
                }
                glassButton("Add to playlist", icon: "music-notes-plus", on: false, enabled: !selection.isEmpty) {
                    app.sheet = .addToPlaylist(songs); selection = []
                }
            } else {
                glassButton("Shuffle", icon: "shuffle", on: app.player.shuffle) {
                    let on = !app.player.shuffle
                    app.player.toggleShuffle()
                    showPill(on ? "Queue shuffled" : "Shuffle is off")
                }
                glassButton("Repeat", icon: app.player.repeatMode == .one ? "repeat-once" : "repeat", on: app.player.repeatMode != .off) { app.player.cycleRepeat() }
                glassButton("Timer", icon: "timer", on: app.settings.sleep.mode != nil) { app.sheet = .sleepTimer }
            }
        }
    }

    /// ~108×56, radius 12, 24 pt icon over a 12 pt label; accent when active.
    private func glassButton(_ t: String, icon: String, on: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            VStack(spacing: 4) {
                Icon(name: icon, size: 24)
                Text(t).font(Typo.font(12, .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? Palette.accent : Palette.text)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier("queue-\(t.lowercased())")
    }
}
