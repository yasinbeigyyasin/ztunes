// Lane P1: "Go to … radio" opens the radio as a page (SYNC-GAPS §2; the desktop's
// `routes/radio/[kind]/[id]`, lane magic-d1). Nothing plays and the queue is left alone until you
// press Play. Header "<Seed> Radio", "With A, B, C and more", Spotless, the song count; the cover
// is the seed's art in a circle on its own colour with "RADIO" under it. Play / Shuffle / Save / ···.
// Data: `radio_tracks` (the same radio `start_radio` plays).
import SwiftUI

/// The radios saved as playlists on this phone (radio key → playlist id), so Save stays filled.
/// Kept in the app's prefs; with none (the mock core in tests) only for this run.
enum RadioSaves {
    static let key = "ios_radio_saves"
    @MainActor private static var memory: [String: String] = [:]
    static func radioKey(kind: String, id: String) -> String { "radio:\(kind):\(id)" }
    @MainActor static func get(_ radioKey: String, defaults: UserDefaults?) -> String? {
        guard let defaults else { return memory[radioKey] }
        return (defaults.dictionary(forKey: key) as? [String: String])?[radioKey]
    }
    @MainActor static func set(_ radioKey: String, _ playlistId: String?, defaults: UserDefaults?) {
        guard let defaults else { memory[radioKey] = playlistId; return }
        var m = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        m[radioKey] = playlistId
        defaults.set(m, forKey: key)
    }
}

struct RadioView: View {
    @Environment(AppModel.self) private var app
    let kind: String
    let id: String
    let name: String?
    @State private var page: RadioPage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var accent: UIColor?
    @State private var moreOpen = false
    @State private var savedTick = 0

    private var radioKey: String { RadioSaves.radioKey(kind: kind, id: id) }
    private var prefs: UserDefaults? { AppModel.defaultPrefs(for: app.core) }
    private var title: String {
        page?.title ?? name.map { $0.hasSuffix(" Radio") ? $0 : "\($0) Radio" } ?? "Radio"
    }
    private var art: String? { page?.thumbnail ?? page?.items.first?.thumbnail }
    private var items: [SongItem] { page?.items ?? [] }
    private var context: PlayContext { PlayContext(kind: .radio, id: page?.playlistId ?? id, title: title) }
    /// The queue this page started (keyed on YouTube's radio id), or the same radio started elsewhere.
    private var playingThis: Bool {
        guard page != nil else { return false }
        return app.player.queue.sourceId == page?.playlistId || app.player.queue.sourceName == title
    }
    /// The playlist this radio was saved as, while it still exists.
    private var savedId: String? {
        _ = savedTick
        guard let pid = RadioSaves.get(radioKey, defaults: prefs) else { return nil }
        return app.library.snapshot.playlists.contains { $0.id == pid } ? pid : nil
    }

    var body: some View {
        EntityScaffold(title: title, artURL: art, isPlayingThis: playingThis, onPlay: onPlay) { off in
            EntityHeader(offset: off, cover: AnyView(cover), title: title, owner: "Ztunes", ownerArt: nil,
                         ownerBadge: AnyView(SpotlessMark(size: 24)), meta: meta, description: page?.description,
                         actions: AnyView(actionIcons), playing: playingThis && !app.player.paused,
                         onShuffle: { play(nil, shuffle: true) }, shuffleOn: playingThis && app.player.shuffle, onPlay: onPlay)
        } content: {
            LazyVStack(spacing: 0) {
                if page == nil {
                    EntityLoadState(failed: failed) { failed = false; attempt += 1 }
                } else if items.isEmpty {
                    VStack(spacing: Space.s) {
                        Text("This radio is empty right now").font(Typo.font(16, .bold))
                        Text("Try again in a moment.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                    }
                    .frame(maxWidth: .infinity).padding(.top, Space.xxl)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                    TrackRow(song: s, context: context) { play(i) }
                }
            }
        }
        .accessibilityIdentifier("radio-page")
        .artAccent(art, into: $accent)
        .task(id: "\(kind):\(id)#\(attempt)") { await load() }
        .sheet(isPresented: $moreOpen) {
            RadioMoreSheet(title: title, art: art, subtitle: page?.description ?? "Ztunes", rows: moreRows)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
    }

    private func load() async {
        do {
            page = try await app.core.radioTracks(kind: kind, id: id, name: name)
        } catch {
            if page == nil { failed = true } else { app.showToast("Couldn't refresh this radio") }
        }
    }

    // MARK: header

    private var meta: String {
        let m = page == nil ? "" : CollectionMeta.songs(items, approx: true)
        return m.isEmpty ? " " : m
    }

    /// Spotify's radio cover: the seed's art in a circle on its own colour, "RADIO" under it.
    private var cover: some View {
        GeometryReader { g in
            let side = g.size.width
            ZStack {
                Rectangle().fill(accent?.surface(value: 0.55, maxSaturation: 0.7) ?? Color(hex: "#535353"))
                VStack(spacing: side * 0.06) {
                    ArtImage(url: art, px: 600, circle: true)
                        .frame(width: side * 0.62, height: side * 0.62)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                    Text("RADIO").font(Typo.font(max(10, side * 0.08), .black)).tracking(side * 0.016)
                        .foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.s))
        .accessibilityIdentifier("radio-cover")
    }

    private var actionIcons: some View {
        HStack(spacing: Space.xl) {
            let saved = savedId != nil
            Button(action: toggleSave) {
                Icon(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 24)
                    .foregroundStyle(saved ? Palette.accent : Palette.subdued)
            }
            .disabled(page == nil)
            .accessibilityLabel(saved ? "Remove from Your Library" : "Save to Your Library")
            .accessibilityIdentifier("radio-save")
            Button { moreOpen = true } label: { Icon(name: "dots-three", size: 24) }
                .disabled(page == nil)
                .accessibilityLabel("More options")
                .accessibilityIdentifier("radio-more")
        }
    }

    private var moreRows: [SheetRow] {
        let list = items, t = title
        return [
            SheetRow(icon: "queue", title: "Add to queue") { app.queue(list, from: t) },
            SheetRow(icon: "list-plus", title: "Play next") { app.playNext(list, from: t) },
            SheetRow(icon: savedId != nil ? "check-circle" : "music-notes-plus", fill: savedId != nil,
                     title: savedId != nil ? "Remove from Your Library" : "Save to Your Library") { toggleSave() },
            SheetRow(icon: "arrow-clockwise", title: "Refresh radio") { Task { await load() } },
        ]
    }

    // MARK: play

    private func onPlay() {
        if playingThis { app.player.togglePause(); return }
        play(nil)
    }

    /// Play the radio from `start` (nil: the top, or a shuffled opener with `shuffle`). The playing
    /// song's own radio started from the top keeps that song and swaps what follows (start_radio's
    /// splice); everything else plays exactly the list on screen, with the radio as its source so
    /// Autoplay continues it.
    private func play(_ start: Int?, shuffle: Bool = false) {
        guard let page, !items.isEmpty else { return }
        if kind == "song", let seed = page.seed, app.player.now?.videoId == seed.videoId, (start ?? 0) == 0, !shuffle {
            Task {
                do { try await app.core.startRadio(kind: "song", id: id, name: name ?? seed.title) }
                catch { app.showToast("Couldn't start radio") }
            }
            return
        }
        let at = start ?? (shuffle ? Int.random(in: 0..<items.count) : 0)
        app.player.play(items, at: at, context: context, shuffle: shuffle)
    }

    // MARK: save

    /// Save: the radio as one of your playlists ("<Seed> Radio"). Pressed again, it is removed, with Undo.
    private func toggleSave() {
        guard let page else { return }
        let key = radioKey
        Haptics.impact(.light)
        Task {
            do {
                if let pid = savedId {
                    try await app.core.deletePlaylist(id: pid)
                    RadioSaves.set(key, nil, defaults: prefs); savedTick += 1
                    await app.library.refresh()
                    app.showToast("Removed from Your Library", action: "Undo") {
                        Task {
                            try? await app.core.restorePlaylist(id: pid)
                            RadioSaves.set(key, pid, defaults: prefs); savedTick += 1
                            await app.library.refresh()
                        }
                    }
                    return
                }
                let p = try await app.core.createPlaylist(name: title)
                if let d = page.description, !d.isEmpty { try? await app.core.updatePlaylist(id: p.id, name: nil, description: d) }
                try await app.core.addToPlaylist(id: p.id, songs: page.items)
                RadioSaves.set(key, p.id, defaults: prefs); savedTick += 1
                await app.library.refresh()
                app.showToast("Added to Your Library", action: "View") { app.router.push(.playlist(p.id)) }
            } catch {
                app.showToast("Couldn't save this radio")
            }
        }
    }
}

/// The radio and Your Mix pages' ··· sheet: the same header and rows as the app's action sheets.
struct RadioMoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let art: String?
    let subtitle: String
    let rows: [SheetRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                ArtImage(url: art, px: 144, radius: Radius.xs).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.font(16, .bold)).lineLimit(1)
                    Text(subtitle).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.xl)
            Divider().overlay(Palette.border).padding(.top, Space.l)
            ForEach(rows) { r in
                Button {
                    Haptics.selection()
                    dismiss()
                    r.action()
                } label: {
                    HStack(spacing: Space.l) {
                        Icon(name: r.icon, fill: r.fill, size: 24).foregroundStyle(Palette.subdued)
                        Text(r.title).font(Typo.sheetItem)
                        Spacer()
                    }
                    .padding(.horizontal, Space.gutter).frame(minHeight: 52).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("action-sheet")
    }
}
