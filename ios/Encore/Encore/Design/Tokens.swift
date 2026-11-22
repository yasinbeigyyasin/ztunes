// Design tokens: the desktop palette (`docs/spotify-spec/tokens.json`) in Swift, plus iOS sizes in
// points from `docs/spotify-spec/ios/` (estimates from public references until re-measured on the
// owner's screenshots, plan §4.2).
import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xff) / 255; g = Double((v >> 16) & 0xff) / 255
            b = Double((v >> 8) & 0xff) / 255; a = Double(v & 0xff) / 255
        } else {
            r = Double((v >> 16) & 0xff) / 255; g = Double((v >> 8) & 0xff) / 255; b = Double(v & 0xff) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

enum Palette {
    // surfaces
    static let app = Color(hex: "#000000")
    static let base = Color(hex: "#121212")
    static let highlight = Color(hex: "#1f1f1f")
    static let elevated = Color(hex: "#1f1f1f")
    static let elevatedHighlight = Color(hex: "#2a2a2a")
    static let menu = Color(hex: "#282828")
    static let sheet = Color(hex: "#282828")
    static let tinted = Color.white.opacity(0.10)
    static let tintedHighlight = Color.white.opacity(0.14)
    static let tintedPress = Color.white.opacity(0.21)
    // text
    static let text = Color.white
    static let subdued = Color(hex: "#b3b3b3")
    static let meta = Color(hex: "#cdcdcd")
    static let muted = Color.white.opacity(0.7)
    static let dim = Color(hex: "#7c7c7c")
    // Ztunes accent selection is stored locally. Red is the default.
    static func accent(for name: String) -> Color {
        switch name {
        case "blue": Color(hex: "#4b8dff")
        case "green": Color(hex: "#36c778")
        case "amber": Color(hex: "#f5aa3c")
        case "violet": Color(hex: "#a577ff")
        default: Color(hex: "#ff4b4b")
        }
    }
    static var accent: Color { accent(for: UserDefaults.standard.string(forKey: "ztunes.accent") ?? "red") }
    static var accentHover: Color { accent }
    static var accentPress: Color { accent }
    static var accentText: Color { accent }
    static let accentTile = Color(hex: "#5a1515")
    static let accentTileDeep = Color(hex: "#330a0a")
    /// Semantic "went up" (chart trends): deliberately not the brand, so it can't be confused with
    /// the red "down" arrow.
    static let positive = Color(hex: "#34d399")
    static let announcement = Color(hex: "#539df5")
    static let negative = Color(hex: "#f3727f")
    // progress
    static let progressTrack = Color.white.opacity(0.3)
    static let border = Color.white.opacity(0.10)
    static let likedCover = LinearGradient(colors: [Color(hex: "#ff4b4b"), Color(hex: "#6a1b9a")],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
    static let likedHeader = Color(red: 80 / 255, green: 56 / 255, blue: 160 / 255)
}

/// Figtree (OFL) stands in for Spotify Mix; static instances bundled from the desktop's fontsource files.
enum Typo {
    enum Weight: String { case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold", extraBold = "ExtraBold", black = "Black" }
    static func font(_ size: CGFloat, _ w: Weight = .regular) -> Font { .custom("Figtree-\(w.rawValue)", fixedSize: size) }

    // roles (pt), iOS scale: tokens-ios.json
    static let largeTitle = font(24, .bold)        // "Search", "Your Library" header
    static let pageTitle = font(24, .bold)         // entity title under the cover
    static let sectionTitle = font(24, .bold)      // shelf titles
    static let rowTitle = font(16, .regular)
    static let rowTitleMedium = font(16, .medium)
    static let rowSubtitle = font(14, .regular)
    static let cardTitle = font(14, .bold)
    static let cardSubtitle = font(14, .regular)
    static let shortcut = font(14, .bold)
    static let chip = font(14, .medium)
    static let tabLabel = font(10, .medium)
    static let miniTitle = font(14, .bold)
    static let miniArtist = font(14, .regular)
    static let npTitle = font(22, .bold)
    static let npArtist = font(16, .regular)
    static let time = font(11, .regular)
    static let meta = font(13, .regular)
    static let metaBold = font(13, .bold)
    static let button = font(14, .bold)
    static let sheetItem = font(16, .regular)
    static let lyricsCard = font(22, .bold)
    static let lyricsFull = font(26, .bold)
}

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Screen side gutter.
    static let gutter: CGFloat = 16
}

enum Radius {
    static let xs: CGFloat = 2
    static let s: CGFloat = 4
    static let m: CGFloat = 6
    static let l: CGFloat = 8
    static let xl: CGFloat = 12
    static let sheet: CGFloat = 12
    /// Floating glass sheets (Create, `…`, queue): concentric with the display corners.
    static let glassSheet: CGFloat = 36
}

enum Metrics {
    static let tabBarHeight: CGFloat = 50           // above the home-indicator inset
    static let tabIcon: CGFloat = 24
    static let miniPlayerHeight: CGFloat = 56
    static let miniPlayerInset: CGFloat = 8
    static let miniCover: CGFloat = 40
    static let miniGap: CGFloat = 2                // gap between mini player and tab bar
    static let rowHeight: CGFloat = 64             // track row with 48pt art
    static let rowArt: CGFloat = 48
    static let libraryRowArt: CGFloat = 64
    static let chipHeight: CGFloat = 32
    static let shortcutHeight: CGFloat = 56
    static let card: CGFloat = 160
    static let cardSmall: CGFloat = 128
    static let playButton: CGFloat = 48
    static let npPlayButton: CGFloat = 64
    static let searchField: CGFloat = 46
}

/// Animations. With Reduce Motion on, springs become short fades and slides become cross-fades
/// (Apple HIG; Spotify follows the system setting for its sheet and player transitions).
enum Motion {
    static var reduce: Bool { UIAccessibility.isReduceMotionEnabled }
    static var spring: Animation { reduce ? .easeInOut(duration: 0.18) : .spring(response: 0.35, dampingFraction: 0.86) }
    static var quick: Animation { reduce ? .linear(duration: 0.12) : .easeOut(duration: 0.2) }
    /// A slide in from `edge`, or a fade with Reduce Motion.
    static func slide(_ edge: Edge, fade: Bool = false) -> AnyTransition {
        if reduce { return .opacity }
        return fade ? .move(edge: edge).combined(with: .opacity) : .move(edge: edge)
    }
}
