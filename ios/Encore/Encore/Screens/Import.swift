// Spotify import onboarding: the optional first-run step (desktop `settings/Welcome.svelte`).
// Stream onboard redesigned it to Spotify sign-up calm: one idea per screen, one big primary
// button, short plain copy (docs/streams/onboard.md).
//
//   welcome  "Bring your music from Spotify?"
//            [Paste your Spotify profile link] all your public playlists
//            [Use your Spotify data file] also private playlists and Liked Songs      Not now
//   link     "Paste your profile link" (or any playlist or album link): one field + Continue;
//            "Show me how" opens a 4-step sheet on copying the profile link in Spotify
//   export   3 numbered steps + Choose file
//   preview  what to bring (a single list skips the checklist)
//   progress one ring                                review  "N songs matched ✓" [Looks good]
//   check    the uncertain / not found rows (and, on request, the matched ones)
//   done     a short summary + Go to Your Library
//
// Reopened from Settings or `encore://import`.
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class ImportFlow {
    static let shared = ImportFlow()
    enum Step { case welcome, link, export, preview, progress, review, check, done }

    var step: Step = .welcome
    var link = ""
    var preview: ImportPreview?
    var picked: Set<Int> = []
    var snapshot: ImportSnapshot?
    var error: String?
    var busy = false
    /// `import_create` sent for this job.
    var creating = false
    /// Tests freeze the progress step by turning polling off.
    var live = true
    // Review (streams ios-import-review, onboard): the rows loaded per tier, the calls made in this
    // sitting (`true` kept, `false` left out) and the row whose candidates are open.
    var tiers: [String: [ImportRow]] = [:]
    var rowsLoading = false
    var settled: [String: Bool] = [:]
    var choosing: ImportRow?
    /// Review options (the desktop's): the single playlist's name, and signed in, YouTube Music
    /// rather than this phone.
    var name = ""
    var onAccount = false
    /// `encore://import?…&step=done`: skip the review and create with the best picks.
    var autoCreate = false
    /// The link step's "Show me how" sheet (how to copy your profile link in Spotify).
    var guide = false
    /// `encore://import?…&step=check`: open the check list once matching is done (screenshots, tests).
    var autoCheck = false
    /// `import_cancel` in flight (the Cancel button shows a spinner and can't be pressed twice).
    var cancelling = false
    private var polling = false

    /// Uncertain first, then not found, then (once asked for) the matched ones.
    var rows: [ImportRow] { ["check", "missing", "matched"].flatMap { tiers[$0] ?? [] } }

    func reset() {
        step = .welcome; live = true; link = ""; preview = nil; picked = []; snapshot = nil; error = nil; busy = false; creating = false
        tiers = [:]; rowsLoading = false; settled = [:]; choosing = nil; autoCreate = false; autoCheck = false; cancelling = false
        guide = false
    }

    func go(_ s: Step) {
        error = nil
        withAnimation(live ? Motion.spring : nil) { step = s }
    }

    /// Where the back arrow goes.
    var back: Step? {
        switch step {
        case .link, .export: .welcome
        case .preview: .welcome
        case .check: .review
        default: nil
        }
    }

    func read(_ app: AppModel) async {
        let links = link.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," }).map(String.init)
        guard !links.isEmpty else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var merged: ImportPreview?
            for l in links {
                let p = try await app.core.importRead(link: l)
                if var m = merged { m.lists += p.lists; m.profile = m.profile ?? p.profile; merged = m } else { merged = p }
            }
            show(merged)
        } catch {
            errorLog.error("import read: \(FriendlyError.raw(error), privacy: .public)")
            self.error = FriendlyError.isUnreachable(FriendlyError.raw(error)) ? FriendlyError.words.unreachable
                : "That link didn't work. In Spotify, use Share › Copy link."
        }
    }

    func readFile(_ url: URL, _ app: AppModel) async {
        busy = true; error = nil
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { show(try await app.core.importReadFile(url: url)) } catch {
            errorLog.error("import file: \(FriendlyError.raw(error), privacy: .public)")
            self.error = "That file couldn't be read. Choose my_spotify_data.zip from Spotify's email."
        }
    }

    private func show(_ p: ImportPreview?) {
        guard let p else { return }
        preview = p
        picked = Set(p.lists.indices)
        go(.preview)
    }

    func start(_ app: AppModel) async {
        do {
            snapshot = try await app.core.importStart(lists: picked.sorted())
            go(.progress)
        } catch {
            self.error = friendlyError(error, "The import couldn't start")
        }
    }

    /// Stops the import (`import_cancel`): the matches found so far stay remembered, and the done
    /// step says it stopped. A refusal stays on the progress step with the reason.
    @discardableResult
    func cancel(_ app: AppModel) async -> Bool {
        guard !cancelling else { return false }
        cancelling = true
        defer { cancelling = false }
        let actions = CoreActions(core: app.core)
        if let e = await actions.attempt("importCancel", { try await app.core.importCancel() }) {
            error = friendlyError(e, "Couldn't stop the import")
            return false
        }
        snapshot?.phase = "cancelled"
        go(.done)
        return true
    }

    /// Polls the job while the progress step shows (`import-progress` events arrive too).
    func poll(_ app: AppModel) async {
        // One loop at a time: the progress view's task and `create` both start it.
        guard !polling else { return }
        polling = true
        defer { polling = false }
        while live && step == .progress && !Task.isCancelled {
            if let s = try? await app.core.importStatus(), live, step == .progress {
                snapshot = s
                // Matching finished: the review step, where picks can change before anything is
                // written (`create`). Links asking for `step=done` take the best picks straight away.
                if s.phase == "review", !creating {
                    if autoCreate { await create(app); continue }
                    await openReview(app)
                    if autoCheck { await openCheck(app) }
                    return
                }
                if ["done", "failed", "cancelled"].contains(s.phase) { go(.done); return }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// `encore://import?step=link|export|preview|progress|review|done&link=…` (screenshots, tests).
    func handle(_ params: [String: String], app: AppModel) {
        reset()
        // encore://import?file=<path>[&step=progress|review|check|done]: the Files-picker path with a known
        // file (simulator end-to-end with a synthetic export; also "Open in Spotless" from Files).
        if let f = params["file"] {
            let start = ["progress", "review", "check", "done"].contains(params["step"] ?? "")
            autoCreate = params["step"] == "done"
            autoCheck = params["step"] == "check"
            Task {
                // A bare name is in Documents (where Files puts it; tests stay valid across reinstalls,
                // which move the app's container).
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = f.hasPrefix("file:") ? URL(string: f)! : f.hasPrefix("/") ? URL(fileURLWithPath: f) : docs.appendingPathComponent(f)
                await readFile(url, app)
                if start { await self.start(app) }
            }
            return
        }
        if let l = params["link"] { link = l }
        switch params["step"] {
        case "link": step = .link
        case "export": step = .export
        case "preview", "progress", "review", "done":
            let target = params["step"]!
            autoCreate = target == "done"
            Task {
                if link.isEmpty { link = "https://open.spotify.com/user/alex" }
                await read(app)
                if target != "preview" { await start(app) }
            }
        default: break
        }
    }
}

// MARK: shared pieces

/// The one big accent button at the foot of a step.
struct OnboardPrimaryButton: View {
    let title: String
    var detail: String?
    var busy = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if busy { ProgressView().tint(.black) }
                VStack(spacing: 1) {
                    Text(title).font(Typo.font(16, .bold))
                    if let detail { Text(detail).font(Typo.font(13)).opacity(0.7) }
                }
            }
            .foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: detail == nil ? 52 : 60)
            .background(Capsule().fill(enabled ? Palette.accent : Palette.accent.opacity(0.4)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled || busy)
    }
}

/// The outlined second choice (Spotify's "Continue with…" buttons).
struct OnboardSecondaryButton: View {
    let title: String
    var detail: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(Typo.font(16, .bold)).foregroundStyle(Palette.text)
                if let detail { Text(detail).font(Typo.font(13)).foregroundStyle(Palette.subdued) }
            }
            .frame(maxWidth: .infinity).frame(height: detail == nil ? 52 : 60)
            .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }
}

/// A quiet text button ("Not now", "Check 5 uncertain ones").
struct OnboardTextButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.font(15, .bold)).foregroundStyle(Palette.subdued)
                .frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

/// A step's big title and its one line underneath.
struct OnboardHeader: View {
    let title: String
    var line: String?
    var center = false
    var body: some View {
        VStack(alignment: center ? .center : .leading, spacing: Space.s) {
            Text(title).font(Typo.font(28, .bold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let line {
                Text(line).font(Typo.font(16)).foregroundStyle(Palette.subdued).fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: center ? .center : .leading)
    }
}

/// Where onboarding shows the Spotless logo (the brand mark, 64 pt).
struct OnboardLogoSpot: View {
    var body: some View {
        SpotlessMark(size: 64)
    }
}

/// Spotify's own pages inside the app (SFSafariViewController): the user signs in there
/// themselves; Spotless never sees the page, its cookies or anything typed into it.
struct SafariPage: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Palette.accent)
        vc.preferredBarTintColor = UIColor(Palette.base)
        vc.dismissButtonStyle = .done
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}


// MARK: the flow

struct ImportOnboarding: View {
    @Environment(AppModel.self) private var app
    @State private var flow = ImportFlow.shared

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch flow.step {
                case .welcome: ImportWelcome(flow: flow, notNow: { finish(toLibrary: false) })
                case .link: ImportLinkStep(flow: flow)
                case .export: ImportExportStep(flow: flow)
                case .preview: ImportPreviewStep(flow: flow)
                case .progress: ImportProgressStep(flow: flow)
                case .review: ImportReviewStep(flow: flow)
                case .check: ImportCheckStep(flow: flow)
                case .done: ImportDoneStep(flow: flow, finish: finish)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.base.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import")
    }

    /// Back on the left where there is a way back; a close X on the review summary ("later": the
    /// matches wait in the core). Everything else ends with its own button.
    private var topBar: some View {
        HStack {
            if let b = flow.back {
                Button { flow.go(b) } label: { Icon(name: "caret-left", size: 24).frame(width: 44, height: 44) }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("import-back")
            }
            Spacer()
            if flow.step == .review {
                Button { finish(toLibrary: false) } label: { Icon(name: "x", size: 22).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("import-close")
            }
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Space.s)
        .frame(height: 48)
    }

    private func finish(toLibrary: Bool) {
        app.importOfferAnswered()
        app.importOpen = false
        if toLibrary {
            app.router.dismissOverlays()
            app.router.tab = .library
            app.router.paths[.library] = []
            Task { await app.library.refresh() }
        }
        Task { try? await Task.sleep(nanoseconds: 600_000_000); flow.reset() }
    }
}

/// A step's scrolling body with its buttons pinned to the bottom (above the keyboard too).
private struct StepLayout<Content: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Space.s) { footer }
                .padding(.horizontal, Space.xl).padding(.top, Space.m).padding(.bottom, Space.s)
                .background(Palette.base)
        }
    }
}

// MARK: 1. welcome

private struct ImportWelcome: View {
    @Bindable var flow: ImportFlow
    let notNow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.xl)
            OnboardLogoSpot().padding(.bottom, Space.xl)
            OnboardHeader(title: "Bring your music from Spotify?",
                          line: "Your playlists and Liked Songs, ready to play here. No Spotify login.", center: true)
            Spacer(minLength: Space.xl)
            Spacer(minLength: 0)
            VStack(spacing: Space.m) {
                OnboardPrimaryButton(title: "Paste your Spotify profile link", detail: "Brings in all your public playlists") { flow.go(.link) }
                    .accessibilityIdentifier("import-link")
                OnboardSecondaryButton(title: "Use your Spotify data file", detail: "Also private playlists and Liked Songs") { flow.go(.export) }
                    .accessibilityIdentifier("import-everything")
                OnboardTextButton(title: "Not now", action: notNow)
                    .accessibilityIdentifier("import-skip")
            }
            .padding(.bottom, Space.s)
        }
        .padding(.horizontal, Space.xl)
    }
}

// MARK: 2a. link

private struct ImportLinkStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var flow: ImportFlow
    @FocusState private var focused: Bool

    var body: some View {
        StepLayout {
            VStack(alignment: .leading, spacing: Space.xl) {
                OnboardHeader(title: "Paste your profile link", line: "Or any playlist or album link.")
                HStack(spacing: Space.s) {
                    TextField("", text: $flow.link, prompt: Text("open.spotify.com/…").foregroundStyle(Palette.dim), axis: .vertical)
                        .font(Typo.font(16)).lineLimit(1...4)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .submitLabel(.go).tint(Palette.accent)
                        .focused($focused)
                        .accessibilityLabel("Spotify link")
                        .accessibilityIdentifier("import-link-field")
                    if flow.link.isEmpty {
                        Button("Paste") {
                            if let s = UIPasteboard.general.string { flow.link = s }
                        }
                        .font(Typo.font(14, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(Capsule().fill(Palette.text))
                        .accessibilityIdentifier("import-paste")
                    } else {
                        Button { flow.link = "" } label: { Icon(name: "x-circle-fill", size: 22).foregroundStyle(Palette.dim) }
                            .accessibilityLabel("Clear")
                    }
                }
                .padding(.leading, Space.l).padding(.trailing, Space.s).padding(.vertical, Space.s)
                .frame(minHeight: 56)
                .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Palette.elevatedHighlight))
                Button { flow.guide = true } label: {
                    HStack(spacing: Space.s) {
                        Icon(name: "info", size: 18)
                        Text("Show me how").font(Typo.font(14, .bold))
                    }
                    .foregroundStyle(Palette.text).padding(.horizontal, Space.l).frame(height: 36)
                    .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("import-show-how")
                if let e = flow.error {
                    Text(e).font(Typo.font(14)).foregroundStyle(Palette.negative).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("import-error")
                }
            }
        } footer: {
            OnboardPrimaryButton(title: "Continue", busy: flow.busy, enabled: !flow.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                focused = false
                Task { await flow.read(app) }
            }
            .accessibilityIdentifier("import-continue")
        }
        .sheet(isPresented: $flow.guide) {
            ProfileLinkGuide { flow.guide = false }
                .presentationDragIndicator(.visible)
                .presentationBackground(Palette.base)
        }
    }
}

/// "Show me how": finding and copying your profile link in the Spotify app, four numbered rows.
private struct ProfileLinkGuide: View {
    let done: () -> Void
    /// The sheet hugs its content (measured), so there's no empty half-screen under the steps.
    @State private var height: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            OnboardHeader(title: "Copy your profile link", line: "It takes a few seconds in the Spotify app.")
            VStack(alignment: .leading, spacing: Space.xl) {
                row(1, "user-circle", "Tap your profile picture", "Open Spotify. It's at the top left.")
                row(2, "user", "Tap View profile", "At the top of the menu, under your name.")
                row(3, "share-network", "Tap ⋯, then Share", "⋯ is next to Edit. Then tap Copy link.")
                row(4, "link", "Come back and tap Paste", "All your public playlists come with it.")
            }
            OnboardPrimaryButton(title: "Got it", action: done)
                .accessibilityIdentifier("import-guide-done")
        }
        .padding(.horizontal, Space.xl).padding(.top, Space.xxl).padding(.bottom, Space.s)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.text)
        .presentationDetents([.height(height)])
    }

    private func row(_ n: Int, _ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: Space.l) {
            Icon(name: icon, size: 24).foregroundStyle(Palette.text)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Palette.elevatedHighlight))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(n)").font(Typo.font(12, .bold)).foregroundStyle(.black)
                        .frame(width: 20, height: 20).background(Circle().fill(Palette.accent))
                        .offset(x: 6, y: 6)
                }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(Typo.font(17, .bold))
                Text(body).font(Typo.font(15)).foregroundStyle(Palette.subdued).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(n). \(title). \(body)")
    }
}

// MARK: 2b. data file

private struct ImportExportStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var flow: ImportFlow
    @State private var picking = false
    @State private var page = false

    static let privacy = URL(string: "https://www.spotify.com/account/privacy/")!

    var body: some View {
        StepLayout {
            VStack(alignment: .leading, spacing: Space.xxl) {
                OnboardHeader(title: "Get your Spotify data file",
                              line: "It has everything: private playlists, Liked Songs and what you play most.")
                VStack(alignment: .leading, spacing: 0) {
                    step(1, "Ask Spotify for it", "Sign in on Spotify's privacy page and request your account data.", last: false) {
                        Button { page = true } label: {
                            Text("Open Spotify").font(Typo.font(14, .bold))
                            .foregroundStyle(Palette.text).padding(.horizontal, Space.l).frame(height: 36)
                            .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
                        }
                        .buttonStyle(PressScale())
                        .accessibilityIdentifier("import-open-spotify")
                    }
                    step(2, "Wait for the email", "It usually takes a few days. You can close Ztunes meanwhile.", last: false) { EmptyView() }
                    step(3, "Choose the file", "Save my_spotify_data.zip from the email to Files, then choose it below.", last: true) { EmptyView() }
                }
                if let e = flow.error {
                    Text(e).font(Typo.font(14)).foregroundStyle(Palette.negative).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("import-error")
                }
            }
        } footer: {
            OnboardPrimaryButton(title: "Choose file", busy: flow.busy) { picking = true }
                .accessibilityIdentifier("import-choose-file")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .json, .commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result { Task { await flow.readFile(url, app) } }
        }
        .sheet(isPresented: $page) { SafariPage(url: Self.privacy).ignoresSafeArea() }
    }

    /// One numbered step on a thin line that joins it to the next.
    private func step<Extra: View>(_ n: Int, _ title: String, _ body: String, last: Bool, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(spacing: 0) {
                Text("\(n)").font(Typo.font(15, .bold)).foregroundStyle(.black)
                    .frame(width: 32, height: 32).background(Circle().fill(Palette.text))
                if !last { Rectangle().fill(Palette.elevatedHighlight).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(Typo.font(17, .bold)).padding(.top, 5)
                Text(body).font(Typo.font(15)).foregroundStyle(Palette.subdued).fixedSize(horizontal: false, vertical: true)
                extra().padding(.top, Space.s)
            }
            .padding(.bottom, last ? 0 : Space.xl)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: 3. what to bring

private struct ImportPreviewStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var flow: ImportFlow

    var body: some View {
        let lists = flow.preview?.lists ?? []
        StepLayout {
            if lists.count == 1 { single(lists[0]) } else { many(lists) }
        } footer: {
            OnboardPrimaryButton(title: buttonTitle, enabled: !flow.picked.isEmpty) { Task { await flow.start(app) } }
                .accessibilityIdentifier("import-start")
        }
    }

    /// One playlist or album link: no checklist, just what it is.
    private func single(_ l: ImportListPreview) -> some View {
        VStack(spacing: Space.l) {
            Group {
                if l.kind == "liked" { LikedCover(size: 200) } else {
                    ArtImage(url: l.cover, px: 600, radius: Radius.s).frame(width: 200, height: 200)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            .padding(.top, Space.xl)
            OnboardHeader(title: l.name, line: l.count > 0 ? "\(l.count.formatted()) songs" : nil, center: true)
            if l.truncated {
                Text("Spotify shares the first 100 songs of a link. Your data file has all of them.")
                    .font(Typo.font(13)).foregroundStyle(Palette.dim).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func many(_ lists: [ImportListPreview]) -> some View {
        let p = flow.preview
        let all = flow.picked.count == lists.count
        return VStack(alignment: .leading, spacing: Space.l) {
            if let prof = p?.profile {
                HStack(spacing: Space.m) {
                    Circle().fill(Color(hex: "#f573a0")).frame(width: 48, height: 48)
                        .overlay(Text(String(prof.name.prefix(1))).font(Typo.font(22, .bold)).foregroundStyle(.black))
                    Text(prof.name).font(Typo.font(16, .bold))
                    Spacer(minLength: 0)
                }
            }
            OnboardHeader(title: "Choose what to bring", line: "Tap to leave anything out.")
            HStack {
                Text("\(flow.picked.count) of \(lists.count) selected").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                Spacer()
                Button(all ? "Clear all" : "Select all") {
                    flow.picked = all ? [] : Set(lists.indices)
                }
                .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
            }
            VStack(spacing: 0) {
                ForEach(Array(lists.enumerated()), id: \.offset) { i, l in listRow(i, l) }
            }
            .padding(.horizontal, -Space.xl)
            if let note { Text(note).font(Typo.font(13)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// The one small print line: what else comes along, or what a profile page leaves out.
    private var note: String? {
        guard let p = flow.preview else { return nil }
        var parts: [String] = []
        if let h = p.history, !p.lists.contains(where: { $0.kind == "history" }) {
            parts.append("Your listening history (\(h.plays.formatted()) plays) shapes Home from day one.")
        }
        if let a = p.albums, let r = p.artists, a + r > 0 {
            parts.append("Your \(a) saved \(a == 1 ? "album" : "albums") and \(r) followed \(r == 1 ? "artist" : "artists") come along too.")
        }
        if let prof = p.profile, prof.total > prof.playlists.count {
            parts.append("Spotify shows \(prof.playlists.count) of your \(prof.total) playlists on a profile. Your data file has the rest.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var buttonTitle: String {
        let lists = flow.preview?.lists ?? []
        let n = flow.picked.count
        if lists.count == 1 { return lists[0].kind == "album" ? "Import album" : "Import playlist" }
        let allPlaylists = flow.picked.allSatisfy { lists.indices.contains($0) && lists[$0].kind == "playlist" }
        return allPlaylists ? "Import \(n) playlist\(n == 1 ? "" : "s")" : "Import \(n) item\(n == 1 ? "" : "s")"
    }

    private func listRow(_ i: Int, _ l: ImportListPreview) -> some View {
        let on = flow.picked.contains(i)
        return HStack(spacing: Space.m) {
            if l.kind == "liked" { LikedCover(size: 48) } else if l.kind == "history" { HistoryTile() } else {
                ArtImage(url: l.cover, px: 144, radius: Radius.xs).frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(l.kind == "history" ? "Listening history" : l.name).font(Typo.rowTitle).lineLimit(1)
                Text(subtitle(l)).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
            }
            Spacer(minLength: 0)
            Icon(name: on ? "check-circle" : "plus-circle", fill: on, size: 26).foregroundStyle(on ? Palette.accent : Palette.dim)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .opacity(on ? 1 : 0.6)
        .onTapGesture {
            Haptics.selection()
            if on { flow.picked.remove(i) } else { flow.picked.insert(i) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("import-list-\(i)")
    }

    private func subtitle(_ l: ImportListPreview) -> String {
        if l.kind == "history", let h = flow.preview?.history {
            return "\(h.plays.formatted()) plays since \(monthYear(h.from))"
        }
        let kind = l.kind == "liked" ? "Your likes" : l.kind.capitalized
        if l.lazy == true || l.count == 0 { return kind }
        return "\(kind) • \(l.count.formatted()) songs"
    }
}

func monthYear(_ unix: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "MMM yyyy"
    return f.string(from: Date(timeIntervalSince1970: unix))
}

// MARK: 4. progress

private struct ImportProgressStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var flow: ImportFlow
    @State private var confirmCancel = false

    var body: some View {
        let s = flow.snapshot
        let creating = flow.creating || s?.phase == "creating"
        let f: Double = {
            guard let s else { return 0 }
            if creating, s.step.count == 2, s.step[1] > 0 { return Double(s.step[0]) / Double(s.step[1]) }
            return s.total > 0 ? Double(s.done) / Double(s.total) : 0
        }()
        VStack(spacing: 0) {
            Spacer(minLength: Space.xl)
            OnboardHeader(title: creating ? "Adding to Your Library" : "Finding your songs",
                          line: creating ? "Almost there." : "Each song is matched on YouTube Music.", center: true)
            ZStack {
                Circle().stroke(Palette.elevatedHighlight, lineWidth: 10)
                Circle().trim(from: 0, to: f).stroke(Palette.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: f)
                VStack(spacing: 4) {
                    Text("\(Int((f * 100).rounded()))%").font(Typo.font(44, .bold)).monospacedDigit()
                    if !creating {
                        Text("\((s?.done ?? 0).formatted()) of \((s?.total ?? 0).formatted())").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                    }
                }
            }
            .frame(width: 220, height: 220)
            .padding(.vertical, Space.xxl)
            .accessibilityElement(children: .combine)
            Text(nowLine(s, creating)).font(Typo.font(14)).foregroundStyle(Palette.subdued).lineLimit(1)
                .frame(height: 20)
            Spacer(minLength: Space.xl)
            Spacer(minLength: 0)
            Text("You can keep listening while this runs.").font(Typo.font(13)).foregroundStyle(Palette.dim)
                .padding(.bottom, Space.s)
            if let e = flow.error {
                Text(e).font(Typo.font(13)).foregroundStyle(Palette.negative).multilineTextAlignment(.center)
                    .accessibilityIdentifier("import-error")
                    .padding(.bottom, Space.s)
            }
            OnboardSecondaryButton(title: "Hide") { app.importOpen = false }
                .accessibilityIdentifier("import-hide")
            // Not while the songs are being written: stopping halfway would leave half a playlist.
            if !creating {
                OnboardTextButton(title: flow.cancelling ? "Stopping…" : "Cancel import") { confirmCancel = true }
                    .disabled(flow.cancelling)
                    .accessibilityIdentifier("import-cancel")
            }
            Spacer().frame(height: Space.s)
        }
        .confirmationDialog("Stop the import?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop import", role: .destructive) { Task { await flow.cancel(app) } }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Songs found so far are remembered.")
        }
        .padding(.horizontal, Space.xl)
        .task { await flow.poll(app) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import-progress")
    }

    /// The last song found, so the screen visibly moves.
    private func nowLine(_ s: ImportSnapshot?, _ creating: Bool) -> String {
        guard !creating, let r = s?.recent.first else { return "" }
        return "\(r.title) • \(r.artists)"
    }
}

// MARK: done

private struct ImportDoneStep: View {
    @Bindable var flow: ImportFlow
    let finish: (Bool) -> Void

    var body: some View {
        let s = flow.snapshot
        let results = s?.results ?? []
        let failed = s?.phase == "failed" || s?.phase == "cancelled"
        // Listening history isn't a playlist: its plays go to Recently played and the taste profile.
        let added = results.filter { $0.kind != "history" }.reduce(0) { $0 + $1.added }
        StepLayout {
            VStack(spacing: Space.l) {
                Icon(name: failed ? "info" : "seal-check", fill: true, size: 64).foregroundStyle(failed ? Palette.subdued : Palette.accent)
                    .padding(.top, Space.xl)
                OnboardHeader(title: failed ? "The import stopped" : "You're all set",
                              line: failed ? "Songs found so far are remembered. Try again from Settings."
                                  : added > 0 ? "\(added.formatted()) song\(added == 1 ? "" : "s") are in Your Library." : "Your library is up to date.",
                              center: true)
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                        HStack(spacing: Space.m) {
                            if r.kind == "liked" { LikedCover(size: 48) } else if r.kind == "history" { HistoryTile() } else {
                                ArtImage(url: s?.lists.first { $0.name == r.name }?.cover, px: 144, radius: Radius.xs).frame(width: 48, height: 48)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.kind == "history" ? "Listening history" : r.name).font(Typo.rowTitle).lineLimit(1)
                                Text(resultLine(r)).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: Metrics.rowHeight)
                    }
                }
                .padding(.top, Space.s)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import-done")
        } footer: {
            OnboardPrimaryButton(title: "Go to Your Library") { finish(true) }
                .accessibilityIdentifier("import-go-library")
        }
    }
}

/// A Done row's line. A playlist imported before got the new songs only (`updated`).
func resultLine(_ r: ImportResult) -> String {
    if r.kind == "history" { return "\(r.added) plays in Recently played" }
    if r.kind == "liked", r.added == 0 { return "Already in your Liked Songs" }
    let songs = "\(r.added) song\(r.added == 1 ? "" : "s")"
    let head = r.updated == true ? "Already imported • \(r.added) new song\(r.added == 1 ? "" : "s")" : songs
    return head + (r.missing > 0 ? " • \(r.missing) not found" : "")
}

/// The 48 pt tile for the "Listening history" list.
struct HistoryTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.xs).fill(Palette.elevatedHighlight).frame(width: 48, height: 48)
            .overlay(Icon(name: "clock-counter-clockwise", size: 22).foregroundStyle(Palette.text))
    }
}
