// Share (Spotify iOS: Share in every sheet and in Now Playing → the system share sheet).
// The shared item is the music.youtube.com link, which opens for anyone; a "Copy Ztunes link"
// activity copies the spotless:// link, which opens the same screen in Spotless (Links.swift).
import SwiftUI
import UIKit

/// What is being shared, and its two links.
struct ShareLinks: Equatable {
    var title: String
    var web: URL?
    var app: URL

    static func song(_ s: SongItem) -> ShareLinks {
        if s.isEpisode == true {
            return ShareLinks(title: s.title, web: nil, app: encore("episode", s.videoId))
        }
        return ShareLinks(title: "\(s.title) · \(s.artists)",
                          web: URL(string: "https://music.youtube.com/watch?v=\(s.videoId)"),
                          app: encore("song", s.videoId))
    }

    static func item(_ c: BrowseItem) -> ShareLinks {
        let id = c.id
        switch c.kind {
        case .song: return .song(c.asSong)
        case .album:
            return ShareLinks(title: c.title, web: URL(string: "https://music.youtube.com/browse/\(esc(id))"), app: encore("album", id))
        case .artist:
            return ShareLinks(title: c.title, web: URL(string: "https://music.youtube.com/channel/\(esc(id))"), app: encore("artist", id))
        case .playlist:
            if id == likedPlaylistId { return ShareLinks(title: "Liked Songs", web: nil, app: encore("liked", nil)) }
            // Own playlists live on this phone only: the link opens them here.
            let web = id.hasPrefix("LOCALPLAYLIST") || id.hasPrefix("MFY_") ? nil
                : URL(string: "https://music.youtube.com/playlist?list=\(esc(id.hasPrefix("VL") ? String(id.dropFirst(2)) : id))")
            return ShareLinks(title: c.title, web: web, app: encore("playlist", id))
        case .podcast: return ShareLinks(title: c.title, web: nil, app: encore("show", id))
        case .episode: return ShareLinks(title: c.title, web: nil, app: encore("episode", id))
        case .audiobook: return ShareLinks(title: c.title, web: URL(string: "https://archive.org/details/\(esc(id))"), app: encore("audiobook", id))
        }
    }

    static func show(_ s: PodcastShow) -> ShareLinks {
        ShareLinks(title: s.title, web: s.feedUrl.flatMap(URL.init(string:)), app: encore("show", s.id))
    }
    static func episode(_ e: PodcastEpisode) -> ShareLinks {
        ShareLinks(title: e.title, web: nil, app: encore("episode", e.id))
    }

    private static func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s
    }
    private static func encore(_ host: String, _ id: String?) -> URL {
        URL(string: "spotless://\(host)\(id.map { "/" + esc($0) } ?? "")")!
    }
}

/// The link item, with a title for the share sheet's header (`LPLinkMetadata`-free: the system
/// fetches the page preview itself for https links).
final class ShareItemSource: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    init(url: URL, title: String) { self.url = url; self.title = title }
    func activityViewControllerPlaceholderItem(_ c: UIActivityViewController) -> Any { url }
    func activityViewController(_ c: UIActivityViewController, itemForActivityType t: UIActivity.ActivityType?) -> Any? { url }
    func activityViewController(_ c: UIActivityViewController, subjectForActivityType t: UIActivity.ActivityType?) -> String { title }
}

/// "Copy Ztunes link": the spotless:// link to the same screen.
final class CopyEncoreLinkActivity: UIActivity {
    let link: URL
    init(link: URL) { self.link = link }
    override var activityType: UIActivity.ActivityType? { .init("app.spotlessmusic.ios.copy-link") }
    override var activityTitle: String? { "Copy Ztunes link" }
    override var activityImage: UIImage? { UIImage(systemName: "link") }
    override class var activityCategory: UIActivity.Category { .action }
    override func canPerform(withActivityItems items: [Any]) -> Bool { true }
    override func perform() {
        UIPasteboard.general.url = link
        activityDidFinish(true)
    }
}

enum ShareSheet {
    /// Set by the last presentation; tests and the share deep link read it.
    @MainActor static var lastLinks: ShareLinks?

    /// Present the system share sheet over whatever is on screen (sheets included).
    @MainActor static func present(_ links: ShareLinks, app: AppModel) {
        lastLinks = links
        Haptics.impact(.light)
        let primary = links.web ?? links.app
        let vc = UIActivityViewController(activityItems: [ShareItemSource(url: primary, title: links.title)],
                                          applicationActivities: [CopyEncoreLinkActivity(link: links.app)])
        vc.excludedActivityTypes = [.assignToContact, .addToReadingList, .saveToCameraRoll, .print]
        vc.completionWithItemsHandler = { type, done, _, _ in
            guard done else { return }
            if type == .copyToPasteboard || type?.rawValue == "app.spotlessmusic.ios.copy-link" {
                Task { @MainActor in app.showToast("Link copied") }
            }
        }
        guard let top = topViewController() else { return }
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }

    /// After an action sheet row: wait for the sheet to finish dismissing, then present.
    @MainActor static func presentAfterSheet(_ links: ShareLinks, app: AppModel) {
        Task { try? await Task.sleep(nanoseconds: 450_000_000); present(links, app: app) }
    }

    @MainActor static func topViewController() -> UIViewController? {
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        var top = w?.rootViewController
        while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
        return top
    }
}
