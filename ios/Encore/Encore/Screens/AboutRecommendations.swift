// "About recommendations" (the desktop's ui/src/lib/smart/AboutRecommendations.svelte): how the
// recommendations are made (on this iPhone, from your own listening) and the switches that control
// them. Opened from the Made for you hero (and `encore://about-recommendations`).
import SwiftUI

struct AboutRecommendationsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("About recommendations").font(Typo.font(18, .bold)).accessibilityAddTraits(.isHeader)
                .padding(.top, Space.xl).padding(.bottom, Space.l)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    Text("Ztunes's recommendations help you find music you'll love: your mixes, Weekly Discoveries, New Release Mix, Smart Shuffle, radio and autoplay.")
                    Text("They're worked out on this iPhone, from your own listening: what you play and how often, the songs you like, what you skip, what's in your playlists, the artists you follow, and any listening history you imported from Spotify. That history stays on this iPhone. Ztunes only asks YouTube Music for songs related to a few of the tracks you play, then picks and orders them here. There are no ads and no paid promotion in your recommendations.")
                    Text("You're in control").font(Typo.font(16, .bold)).foregroundStyle(Palette.text).padding(.top, Space.s)
                        .accessibilityAddTraits(.isHeader)
                    control("Private session", "nothing you play counts toward your history or recommendations while it's on.", .privacy)
                    control("Explicit content", "turn it off and explicit songs are left out of your mixes and skipped in playback.", .contentDisplay)
                    control("Clear listening history", "forget every play counted on this iPhone. Your mixes start over from your likes and playlists.", .privacy)
                }
                .font(Typo.font(15)).foregroundStyle(Palette.subdued)
                .padding(.horizontal, Space.xl)
            }
            Button { go(.privacy) } label: {
                Text("Open Settings").font(Typo.font(16, .bold)).foregroundStyle(.black)
                    .padding(.horizontal, Space.xxl).frame(height: 48)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(PressScale())
            .padding(.vertical, Space.l)
            .accessibilityIdentifier("about-recs-settings")
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("about-recs")
    }

    private func control(_ title: String, _ text: String, _ page: SettingsPage) -> some View {
        Button { go(page) } label: {
            (Text(title).font(Typo.font(15, .bold)).foregroundColor(Palette.text) + Text(": " + text))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }

    /// Closes the sheet and opens that Settings page on the current tab.
    private func go(_ page: SettingsPage) {
        dismiss()
        app.router.nowPlayingOpen = false
        app.router.push(.settings)
        app.router.push(.settingsPage(page))
    }
}
