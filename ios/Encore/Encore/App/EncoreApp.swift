// Spotless (working name Encore) for iPhone, on the shared Rust core (`RealCoreClient` over UniFFI). Launch arguments:
//   -mock                 the devmock-fixture core (UI tests, snapshots; no network, no audio). Debug builds only.
//   -coreFail             Debug builds: the core "fails to start", for the error screen's UI test
//   -fail <a,b|*>         with -mock: those store actions fail (`CoreFaults`), for the revert-and-toast tests
//   -volume <0-100>       player volume (tests run at 0 with a real AudioUnit output)
//   -ao <driver>          mpv audio output (`pcm`, `null`; default `audiounit`), -aoFile <path> for pcm
//   -deeplink "<urls>"    open these encore:// links after launch
import SwiftUI

@main
struct EncoreApp: App {
    @State private var boot = CoreBoot()
    /// Portrait, except Now Playing's full-screen music video (`OrientationLock`, stream ios-video).
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var orientation

    var body: some Scene {
        WindowGroup {
            Group {
                switch boot.state {
                case .ready(let app): AppRoot(app: app)
                case .failed(let failure): CoreStartFailedView(failure: failure) { boot.retry() }
                }
            }
            .overlay { LaunchCover() }
        }
    }
}

/// stream: pod-fixes. The launch screen's own picture as the first SwiftUI frame: Info.plist's
/// `UILaunchScreen` (the `LaunchBackground` colour, the `LaunchMark2` image at its 120 pt size,
/// centred in the safe area), faded out once the UI under it is up. The hand-off is then a fade,
/// not a cut to a different picture.
private struct LaunchCover: View {
    @State private var shown = true
    var body: some View {
        if shown {
            ZStack {
                Color("LaunchBackground").ignoresSafeArea()
                Image("LaunchMark2")
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
            .task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeOut(duration: 0.3)) { shown = false }
            }
        }
    }
}

/// The app once a core is up.
private struct AppRoot: View {
    let app: AppModel
    @Environment(\.scenePhase) private var phase
    var body: some View {
        RootView()
            .environment(app)
            .task {
                PlaybackBridge.shared.attach(app)
                DownloadKeeper.shared.attach(app)
                E2E.installProbe(app)
                await app.start()
                PlaybackBridge.shared.seed(from: app.player)
                (app.core as? RealCoreClient)?.uiMounted()
                // The optional first-run step: Spotify import (never under tests or deep-linked launches).
                let env = ProcessInfo.processInfo.environment
                if UserDefaults.standard.string(forKey: "deeplink") == nil, env["XCTestConfigurationFilePath"] == nil,
                   !ProcessInfo.processInfo.arguments.contains("-uitest"), await app.shouldOfferImport() {
                    app.devices.welcomePending = true // "Using Spotless on your Mac too?" once the import closes
                    app.importOpen = true
                }
                // `-deeplink encore://…` launch argument: screenshots and UI tests reach a screen
                // without the system "Open in Spotless?" prompt that `simctl openurl` triggers.
                if let link = UserDefaults.standard.string(forKey: "deeplink") {
                    for part in link.components(separatedBy: " ") {
                        if let u = URL(string: part) { app.router.handle(u, app: app); try? await Task.sleep(nanoseconds: 700_000_000) }
                    }
                }
            }
            .onOpenURL { app.router.handle($0, app: app) }
            // Device sync polls fast in front and slowly behind; coming back syncs at once.
            .onChange(of: phase) { _, p in
                if p == .active { app.devices.setActive(true) } else if p == .background { app.devices.setActive(false) }
            }
    }
}

/// Why the core didn't start: the raw error (logged, and in the diagnostics) and when.
struct CoreStartFailure: Equatable {
    var raw: String
    var at = Date()
}

/// Starting the core. A real build never falls back to the fixtures: a core that fails to start
/// gets an error screen with Try again and Send diagnostics, because a fake library where nothing
/// persists is worse than an honest error. The mock is for tests only.
@MainActor @Observable
final class CoreBoot {
    enum State {
        case ready(AppModel)
        case failed(CoreStartFailure)
    }

    private(set) var state: State
    private(set) var attempts = 0
    @ObservationIgnored private let start: @MainActor () throws -> CoreClient

    init(start: @escaping @MainActor () throws -> CoreClient = CoreBoot.makeCore) {
        self.start = start
        state = .failed(CoreStartFailure(raw: ""))
        // stream: instant: main-thread stalls, for the e2e probe and the Debug console.
        #if DEBUG
        HangWatch.shared.start()
        #else
        if E2E.enabled { HangWatch.shared.start() }
        #endif
        boot()
    }

    var app: AppModel? { if case .ready(let a) = state { a } else { nil } }
    var failure: CoreStartFailure? { if case .failed(let f) = state { f } else { nil } }

    func retry() { if app == nil { boot() } }

    private func boot() {
        attempts += 1
        do {
            state = .ready(AppModel(core: try start()))
        } catch {
            let raw = FriendlyError.raw(error)
            coreLog.fault("core failed to start (attempt \(self.attempts)): \(raw, privacy: .public)")
            AudioTraceFile.append("CORE failed to start (attempt \(attempts)): \(raw)")
            #if DEBUG
            print("ENCORE_CORE failed: \(raw)")
            #endif
            state = .failed(CoreStartFailure(raw: raw))
        }
    }

    /// Tests always get the mock: unit tests run hosted in the app; UI tests pass `-mock`, which
    /// a release build ignores. Everything else is the real core, or the error screen.
    static var usesMock: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-mock")
        #else
        return false
        #endif
    }

    static func makeCore() throws -> CoreClient {
        if usesMock { return MockCoreClient() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-coreFail") {
            throw CoreFailure(message: "database: unable to open database file (code 14) [-coreFail]")
        }
        #endif
        // The session is active before mpv ever opens its AudioUnit (plan §2.3).
        PlaybackBridge.configureSession()
        E2E.resetIfAsked()
        let t0 = Date()
        let core = try RealCoreClient.start()
        let d = UserDefaults.standard
        if let ao = d.string(forKey: "ao") { core.setAudioOutput(ao, pcmFile: d.string(forKey: "aoFile")) }
        if d.object(forKey: "volume") != nil { core.setVolume(d.integer(forKey: "volume")) }
        coreLog.info("core started in \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
        #if DEBUG
        // scripts/verify-wire.sh waits for this line on the simulator console.
        print("ENCORE_CORE started in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        #endif
        return core
    }
}

// MARK: the error screen

/// What a person sees when the core can't start: one plain sentence, Try again, and a way to send
/// the log (the share sheet with `diagnostics.txt`: the error, the device, the recent log lines).
struct CoreStartFailedView: View {
    let failure: CoreStartFailure
    let retry: () -> Void
    @State private var retrying = false

    var body: some View {
        VStack(spacing: Space.m) {
            Spacer()
            Icon(name: "info", fill: true, size: 56).foregroundStyle(Palette.subdued)
                .padding(.bottom, Space.s)
            Text("Ztunes couldn't start").font(Typo.font(22, .bold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("core-failed-title")
            Text("Your library couldn't be opened. Try again. If it keeps happening, send the diagnostics so we can fix it.")
                .font(Typo.font(15)).foregroundStyle(Palette.subdued).multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
            Button {
                retrying = true
                // A beat so the press reads, then the attempt (on the main actor, like launch).
                Task { try? await Task.sleep(nanoseconds: 150_000_000); retry(); retrying = false }
            } label: {
                Group {
                    if retrying { ProgressView().tint(.black) } else { Text("Try again") }
                }
                .font(Typo.font(16, .bold)).foregroundStyle(.black)
                .frame(minWidth: 160).padding(.horizontal, 24).frame(height: 48).background(Capsule().fill(.white))
            }
            .buttonStyle(PressScale())
            .disabled(retrying)
            .padding(.top, Space.l)
            .accessibilityIdentifier("core-retry")
            ShareLink(item: Diagnostics.write(failure), subject: Text("Ztunes diagnostics"),
                      message: Text("Ztunes couldn't start on my iPhone.")) {
                Text("Send diagnostics").font(Typo.font(15, .bold)).foregroundStyle(Palette.text)
                    .padding(.horizontal, 24).frame(height: 44).overlay(Capsule().stroke(Palette.dim))
            }
            .accessibilityIdentifier("core-diagnostics")
            Button {
                UIPasteboard.general.string = Diagnostics.logURL?.path
            } label: {
                Text("Copy log path").font(Typo.font(13, .semibold)).foregroundStyle(Palette.subdued)
            }
            .accessibilityIdentifier("core-copy-log")
            Spacer()
        }
        .padding(Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Palette.text)
        .background(Palette.base.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("core-failed")
    }
}

/// The diagnostics bundle: one text file a person can mail or AirDrop.
enum Diagnostics {
    /// `Library/Caches/Encore/audio.log` (`AudioTraceFile`): audio trace plus logged raw errors.
    static var logURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Encore", isDirectory: true).appendingPathComponent("audio.log")
    }

    static func report(_ failure: CoreStartFailure, logTail: Int = 200) -> String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = [
            "Spotless diagnostics",
            "App: \(version)",
            "iOS: \(os)",
            "When: \(ISO8601DateFormatter().string(from: failure.at))",
            "",
            "Core failed to start:",
            failure.raw,
        ]
        if let url = logURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            lines += ["", "Recent log (\(url.lastPathComponent)):"] + text.split(separator: "\n", omittingEmptySubsequences: false).suffix(logTail).map(String.init)
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the report next to the log and returns its URL (a temp file if Caches is unavailable).
    static func write(_ failure: CoreStartFailure) -> URL {
        let dir = logURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("diagnostics.txt")
        try? report(failure).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
