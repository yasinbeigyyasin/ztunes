// Stream ios-p2: the optional YouTube account (desktop: `src-tauri/src/session.rs`).
//
// Sign-in is Google's own page in a `WKWebView`: the user types into Google, never into Spotless,
// and the app never sees the password. When the web view lands back on music.youtube.com, the
// youtube.com cookies are read out of `WKHTTPCookieStore` and handed to the core as one `Cookie`
// header (`account_sign_in`), which validates them, picks the channel and seals them into the
// Keychain, the same path as the desktop's login window.
//
// The web view's store is persistent (`WKWebsiteDataStore.default()`), like the desktop's: when
// YouTube rejects the session later (`session-rejected`), a hidden web view reloads
// music.youtube.com from that same store, Google rotates the short-lived cookies, and the fresh
// jar is signed in again for the same account (`refresh_session`).
import SwiftUI
import WebKit

// MARK: store

@MainActor @Observable
final class AccountStore {
    @ObservationIgnored let core: CoreClient
    @ObservationIgnored let settings: SettingsStore
    var account: YouTubeAccount = .signedOut
    /// The account's library and playlist edits (stream ios-sync2, App/YouTubeLibrary.swift).
    let youtube: YouTubeLibrary
    /// A multi-channel login waiting for its channel (`selectionRequired`).
    var identities: [AccountIdentity] = []
    /// The sign-in sheet.
    var signInOpen = false
    var busy = false

    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refresher: SessionRefresher?

    init(core: CoreClient, settings: SettingsStore) {
        self.core = core
        self.settings = settings
        youtube = YouTubeLibrary(core: core)
    }

    private var client: AccountClient? { core as? AccountClient }
    /// The mock (UI tests, previews) signs in from a canned page in a throwaway cookie store.
    var isMock: Bool { core is MockCoreClient }

    var signedIn: Bool { account.signedIn && account.selectionRequired != true }

    func start() async {
        await refresh()
        if account.signedIn { try? await client?.accountWatch() }
    }

    func refresh() async {
        guard let a = try? await client?.getAccount() else { return }
        apply(a)
    }

    /// Core events this store follows (`auth-changed`, `session-rejected`).
    func handle(event name: String) {
        switch name {
        case "auth-changed": Task { await refresh() }
        case "session-rejected": Task { await refreshSession() }
        default: break
        }
    }

    /// The cookies the sign-in web view holds, once it's back on music.youtube.com. Answers false
    /// while they're not signed in yet (no SAPISID), so the caller keeps watching.
    @discardableResult
    func complete(with cookies: [HTTPCookie]) async throws -> Bool {
        let header = YouTubeCookies.header(cookies)
        guard YouTubeCookies.sapisid(header) != nil, let client else { return false }
        busy = true
        defer { busy = false }
        let a = try await client.accountSignIn(cookie: header, expectAccount: nil)
        apply(a)
        if a.selectionRequired == true { identities = (try? await client.accountIdentities()) ?? [] }
        return true
    }

    func pick(_ identity: AccountIdentity) async throws {
        guard let client else { return }
        busy = true
        defer { busy = false }
        apply(try await client.switchAccount(selectionKey: identity.selectionKey))
        identities = []
    }

    /// Sign out: back to no account. The phone forgets the Google session too (the web view's
    /// google.com / youtube.com data), so the next sign-in asks Google again instead of walking
    /// straight back into this account.
    func signOut() async throws {
        guard let client else { return }
        apply(try await client.signOut())
        identities = []
        await WebSession.forget(store: isMock ? WebSession.mockStore : .default())
    }

    private func apply(_ a: YouTubeAccount) {
        let was = signedIn ? account.channelId ?? account.displayName : nil
        account = a
        // The account's library follows the account: loaded on sign-in or a channel switch, gone on sign-out.
        let now = signedIn ? a.channelId ?? a.displayName : nil
        if now != was {
            if now == nil { youtube.clear() } else { Task { await youtube.load(account: a.name ?? a.displayName) } }
        }
        // Your own name across the app ("Playlist • <you>", Made for <you>): `AppModel.localUser`.
        let name = a.selectionRequired == true ? "" : a.displayName ?? ""
        if settings.string(SettingKey.youtubeAccount) != name { settings.set(SettingKey.youtubeAccount, name) }
    }

    /// `refresh_session`: re-mint the jar from the web view's own Google session, at most every
    /// five minutes (Google rotates hourly; a burst of 401s is one dead cookie, not many).
    func refreshSession() async {
        guard account.signedIn, !isMock, refresher == nil else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < 300 { return }
        lastRefresh = Date()
        let r = SessionRefresher()
        refresher = r
        defer { refresher = nil }
        guard let cookies = await r.run() else { return }
        let header = YouTubeCookies.header(cookies)
        guard let sapisid = YouTubeCookies.sapisid(header) else { return }
        if let a = try? await client?.accountSignIn(cookie: header, expectAccount: sapisid) { apply(a) }
    }
}

// MARK: web session

enum WebSession {
    /// Google's sign-in, continuing to YouTube Music (the desktop's `LOGIN_URL`).
    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com/")!
    static let musicURL = URL(string: "https://music.youtube.com/")!
    /// Mobile Safari's own UA: WKWebView's default lacks the `Version/… Safari` tokens, and Google
    /// refuses sign-in from what it takes for an embedded browser (desktop `LOGIN_UA`, tuned for iPhone).
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    /// One throwaway store per launch for the mock (nothing reaches disk).
    @MainActor static let mockStore = WKWebsiteDataStore.nonPersistent()

    /// Every cookie the store holds (the header keeps only youtube.com's).
    @MainActor static func cookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies()
    }

    /// Drop the Google / YouTube data from a store (sign-out).
    @MainActor static func forget(store: WKWebsiteDataStore) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let google = records.filter { r in ["google", "youtube", "gstatic", "googleusercontent"].contains { r.displayName.contains($0) } }
        await store.removeData(ofTypes: types, for: google)
    }

    @MainActor static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.defaultWebpagePreferences.preferredContentMode = .mobile
        return c
    }
}

/// The hidden web view behind `refreshSession`: loads YouTube Music from the persistent store
/// and answers its cookies once the page settles (nil on timeout or failure).
@MainActor
private final class SessionRefresher: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var done: CheckedContinuation<[HTTPCookie]?, Never>?

    func run() async -> [HTTPCookie]? {
        let store = WKWebsiteDataStore.default()
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: WebSession.configuration(store: store))
        w.customUserAgent = WebSession.userAgent
        w.navigationDelegate = self
        web = w
        return await withCheckedContinuation { c in
            done = c
            w.load(URLRequest(url: WebSession.musicURL))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                self?.finish(nil)
            }
        }
    }

    private func finish(_ cookies: [HTTPCookie]?) {
        web?.stopLoading()
        web = nil
        done?.resume(returning: cookies)
        done = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.host == WebSession.musicURL.host else { return }
        Task {
            // The rotated cookies can land a beat after the load finishes.
            try? await Task.sleep(for: .seconds(1.5))
            finish(await WebSession.cookies(webView.configuration.websiteDataStore))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
}

// MARK: sign-in sheet

/// "Sign in to YouTube Music": Google's page full screen, Cancel at the top. Lands on
/// music.youtube.com → reads the cookies → signs in → (picks a channel) → closes.
struct YouTubeSignInSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var failed: String?

    var body: some View {
        let store = app.account
        VStack(spacing: 0) {
            ZStack {
                Text(store.identities.isEmpty ? "Connect to Ztunes" : "Choose a channel").font(Typo.font(16, .bold))
                HStack {
                    Button("Cancel") { dismiss() }.font(Typo.font(15)).foregroundStyle(Palette.accentText).accessibilityIdentifier("signin-cancel")
                    Spacer()
                    if loading || store.busy { ProgressView().tint(Palette.subdued) }
                }
            }
            .padding(.horizontal, Space.gutter).frame(height: 52)
            Divider().overlay(Palette.border)
            if !store.identities.isEmpty {
                ChannelPicker()
            } else if let failed {
                VStack(spacing: Space.m) {
                    Text("Couldn't sign in").font(Typo.font(18, .bold))
                    Text(failed).font(Typo.font(14)).foregroundStyle(Palette.subdued).multilineTextAlignment(.center)
                    Button("Try again") { self.failed = nil }.font(Typo.font(15, .bold))
                }
                .padding(Space.xl).frame(maxHeight: .infinity)
            } else {
                SignInWebView(mock: store.isMock, loading: $loading) { cookies in
                    do {
                        guard try await store.complete(with: cookies) else { return false }
                        if store.identities.isEmpty { finish() }
                        return true
                    } catch {
                        failed = "Google signed you in, but YouTube Music didn't accept the session. Try again in a moment."
                        return true
                    }
                }
                .accessibilityIdentifier("signin-web")
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.sheet.ignoresSafeArea())
        .onChange(of: store.signedIn) { _, on in if on { finish() } }
    }

    private func finish() {
        guard app.account.signedIn else { return }
        dismiss()
        if let n = app.account.account.displayName { app.showToast("Signed in as \(n)") }
    }
}

/// A multi-channel Google account: pick the channel to use (desktop `ChannelPicker`).
private struct ChannelPicker: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsNote(text: "This Google account has more than one YouTube channel. Pick the one Ztunes should use.")
                    .padding(.vertical, Space.s)
                ForEach(app.account.identities) { idn in
                    Button {
                        Task {
                            do { try await app.account.pick(idn) } catch { app.showToast("Couldn't switch to that channel") }
                        }
                    } label: {
                        HStack(spacing: Space.m) {
                            AccountPhoto(url: idn.thumbnail, name: idn.name, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(idn.name).font(Typo.font(16))
                                if let h = idn.handle ?? idn.email { Text(h).font(Typo.font(13)).foregroundStyle(Palette.subdued) }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Space.gutter).frame(minHeight: 64).contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsPressStyle())
                    .accessibilityIdentifier("channel-\(idn.selectionKey)")
                }
            }
        }
    }
}

/// The web view. `onLanded` gets the store's cookies each time a page on music.youtube.com
/// finishes, polled a few times (they can appear a beat late, as on the desktop); it answers
/// true once it's done with them.
private struct SignInWebView: UIViewRepresentable {
    let mock: Bool
    @Binding var loading: Bool
    let onLanded: @MainActor ([HTTPCookie]) async -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let store: WKWebsiteDataStore = mock ? WebSession.mockStore : .default()
        let w = WKWebView(frame: .zero, configuration: WebSession.configuration(store: store))
        w.customUserAgent = WebSession.userAgent
        w.navigationDelegate = context.coordinator
        w.isOpaque = false
        w.backgroundColor = .clear
        if mock {
            // The mock stands in for Google: it puts a signed-in jar in the (throwaway) cookie
            // store and "lands" on music.youtube.com, so everything after the password runs for real.
            Task { @MainActor in
                for (name, value) in [("SAPISID", "mocksapisid"), ("SID", "mocksid"), ("__Secure-3PSIDTS", "mockts")] {
                    if let c = HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: name, .value: value,
                                                       .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]) {
                        await store.httpCookieStore.setCookie(c)
                    }
                }
                w.loadHTMLString(Self.mockPage, baseURL: WebSession.musicURL)
            }
        } else {
            w.load(URLRequest(url: WebSession.loginURL))
        }
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.parent = self }

    static let mockPage = """
    <html><head><meta name="viewport" content="width=device-width"></head>
    <body style="background:#121212;color:#fff;font-family:-apple-system;text-align:center;padding-top:30vh">
    <p>Test sign-in (mock core)</p></body></html>
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SignInWebView
        private var handled = false
        init(_ p: SignInWebView) { parent = p }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            guard !handled, webView.url?.host == WebSession.musicURL.host else { return }
            Task {
                for _ in 0..<6 where !handled {
                    let cookies = await WebSession.cookies(webView.configuration.websiteDataStore)
                    if await parent.onLanded(cookies) { handled = true; return }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                // On music.youtube.com but not signed in yet: keep watching the next loads.
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }
    }
}

// MARK: avatar

/// The account's photo (a circle), else the initial on a tinted disc.
struct AccountPhoto: View {
    let url: String?
    let name: String
    var size: CGFloat = 48
    var body: some View {
        if let url, !url.isEmpty {
            ArtImage(url: url, px: Int(size * 3), radius: 0, circle: true, placeholderIcon: "ph-user")
                .frame(width: size, height: size)
        } else {
            Circle().fill(Color(hex: "#ff6437"))
                .overlay(Text(String(name.prefix(1)).uppercased()).font(Typo.font(size * 0.45, .bold)).foregroundStyle(.black))
                .frame(width: size, height: size)
        }
    }
}

/// The profile avatar in Settings: the YouTube account's photo when signed in, else the app's.
struct ProfileAvatar: View {
    @Environment(AppModel.self) private var app
    let size: CGFloat
    var body: some View {
        if app.account.signedIn {
            AccountPhoto(url: app.account.account.thumbnail, name: app.localUser, size: size)
        } else {
            Avatar(size: size, opensMenu: false)
        }
    }
}
