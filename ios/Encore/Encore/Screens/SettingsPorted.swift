// Settings ported from the desktop (parity audit): the Podcasts page (SponsorBlock and its
// categories, ad-free YouTube versions, OPML import/export) and Export library (Account page).
import SwiftUI
import UniformTypeIdentifiers

// MARK: podcasts

/// Settings › Podcasts (desktop Settings › Podcasts).
struct PodcastsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var pods: PodcastSettings?
    @State private var twins = true
    @State private var importing = false

    var body: some View {
        let s = app.settings
        SettingsHeader(title: "Sponsored segments")
        SettingsToggleRow(title: "Skip sponsored segments", subtitle: "Skip sponsor reads and other segments in YouTube podcast episodes (SponsorBlock).",
                          isOn: Binding(get: { pods?.sponsorblock ?? false }, set: { on in patch(sponsorblock: on) }))
            .disabled(pods == nil)
        if let pods, pods.sponsorblock {
            ChipFlow(spacing: Space.s) {
                ForEach(sponsorBlockCategories, id: \.id) { c in
                    let on = pods.sponsorblockCategories.contains(c.id)
                    Chip(title: c.label, selected: on) {
                        Haptics.selection()
                        patch(categories: on ? pods.sponsorblockCategories.filter { $0 != c.id } : pods.sponsorblockCategories + [c.id])
                    }
                    .accessibilityIdentifier("sb-\(c.id)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
        }
        SettingsHeader(title: "Ad-free episodes")
        SettingsToggleRow(title: "Play ad-free YouTube versions", subtitle: "When a podcast episode is also on YouTube, play that version, without the ads inserted into the feed.",
                          isOn: Binding(get: { twins }, set: { on in
                              twins = on
                              Task { twins = (try? await app.core.podcastSetYouTubeMatch(on)) ?? !on }
                          }))
        SettingsHeader(title: "Video podcasts")
        SettingsToggleRow(title: "Play as audio only", subtitle: "Video podcasts start without the picture. You can still switch to video in Now Playing.",
                          isOn: Binding(get: { s.bool(SettingKey.podcastAudioOnly) }, set: { s.set(SettingKey.podcastAudioOnly, $0) }))
        SettingsHeader(title: "Your shows")
        SettingsNote(text: "Move the podcasts you follow between Ztunes and other podcast apps with an OPML file.")
        HStack(spacing: Space.s) {
            SettingsPill(title: "Import OPML", id: "opml-import") { importing = true }
            SettingsPill(title: "Export OPML", id: "opml-export") { exportOpml() }
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.s)
        Color.clear.frame(height: 0)
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml, .plainText]) { result in
                if case .success(let url) = result { importOpml(url) }
            }
            .task {
                pods = try? await app.core.podcastSettings()
                twins = (try? await app.core.podcastYouTubeMatch()) ?? true
            }
    }

    private func patch(sponsorblock: Bool? = nil, categories: [String]? = nil) {
        let prev = pods
        if let sponsorblock { pods?.sponsorblock = sponsorblock }
        if let categories { pods?.sponsorblockCategories = categories }
        Task {
            do { pods = try await app.core.podcastSetSettings(sponsorblock: sponsorblock, categories: categories) } catch {
                pods = prev
                app.showToast("Couldn't change that setting")
            }
        }
    }

    private func importOpml(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return app.showToast("Couldn't read that file")
        }
        Task {
            do {
                let r = try await app.core.podcastOpmlImport(xml: xml)
                app.showToast(r.added == 0 ? "You already follow all \(r.found) podcasts"
                              : "Following \(r.added) new \(r.added == 1 ? "podcast" : "podcasts")")
            } catch {
                app.showToast((error as? CoreFailure)?.message ?? "Couldn't import that file")
            }
        }
    }

    private func exportOpml() {
        Task {
            do {
                let xml = try await app.core.podcastOpmlExport()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ztunes Podcasts.opml")
                try Data(xml.utf8).write(to: url, options: .atomic)
                ShareSheet.presentFile(url)
            } catch { app.showToast("Couldn't export your podcasts") }
        }
    }
}

// MARK: export library

/// Settings › Account › "Export library" (desktop Settings › Library): Liked Songs and playlists as
/// CSV, M3U and XSPF in a zip, handed to the share sheet (Save to Files, AirDrop, …).
struct ExportLibraryRow: View {
    @Environment(AppModel.self) private var app
    @State private var busy = false

    var body: some View {
        SettingsNavRow(icon: "export", title: busy ? "Exporting…" : "Export library", subtitle: "Liked Songs and playlists as CSV, M3U and XSPF files") {
            guard !busy else { return }
            busy = true
            Task {
                defer { busy = false }
                let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ztunes Library \(day).zip")
                try? FileManager.default.removeItem(at: url)
                do {
                    let r = try await app.core.libExport(path: url.path)
                    ShareSheet.presentFile(URL(fileURLWithPath: r.path))
                } catch { app.showToast("Couldn't export your library") }
            }
        }
    }
}

// MARK: helpers

/// The outlined pill button the settings pages use for actions.
struct SettingsPill: View {
    let title: String
    var id: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                .padding(.horizontal, Space.l).frame(height: 36)
                .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
        }
        .accessibilityIdentifier(id ?? title)
    }
}

/// Chips that wrap onto as many rows as they need.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

extension ShareSheet {
    /// Share a file the app just wrote (an export): Save to Files, AirDrop, Mail, …
    @MainActor static func presentFile(_ url: URL) {
        Haptics.impact(.light)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.excludedActivityTypes = [.assignToContact, .addToReadingList, .saveToCameraRoll]
        guard let top = topViewController() else { return }
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }
}
