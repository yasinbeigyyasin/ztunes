// Device sync (docs/SYNC.md): the core's status and pairing shapes, the real core's calls, the
// mock's answers, and the pure wording/logic the screens use (DeviceSyncText, PairingError,
// CodeEntry). The words match the Mac's (`ui/src/lib/devices.ts`) with Mac and iPhone swapped.
import Foundation

// MARK: models (docs/SYNC.md §7)

struct SyncPeer: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var platform: String
    /// Seconds since 1970.
    var lastSeen: Double
    var lan: Bool
}

struct SyncPairing: Codable, Hashable {
    var code: String
    /// The `spotless://pair?…` payload to draw as a QR.
    var qr: String
    /// Seconds since 1970.
    var expiresAt: Double
}

/// `sync_start_pairing`.
struct SyncPairingStart: Codable, Hashable {
    var code: String
    var qr: String
    var expiresAt: Double
    var port: Int
    var addrs: [String]
    var pairing: SyncPairing { SyncPairing(code: code, qr: qr, expiresAt: expiresAt) }
}

struct SyncRelay: Codable, Hashable {
    var enabled: Bool
    var ok: Bool?
}

struct SyncStatus: Codable, Hashable {
    var paired: Bool
    var deviceId: String
    var deviceName: String
    var platform: String
    var pairId: String?
    var peers: [SyncPeer]
    /// This device's changes not yet delivered to any peer.
    var pending: Int
    /// Seconds since 1970.
    var lastSync: Double?
    var lastError: String?
    var relay: SyncRelay
    var lanPort: Int?
    var pairing: SyncPairing?
    var syncing: Bool
    var active: Bool

    static let unlinked = SyncStatus(paired: false, deviceId: "", deviceName: "iPhone", platform: "ios", pairId: nil, peers: [],
                                     pending: 0, lastSync: nil, lastError: nil, relay: SyncRelay(enabled: true, ok: nil),
                                     lanPort: nil, pairing: nil, syncing: false, active: true)
}

// MARK: real core

extension RealCoreClient {
    func syncStatus() async throws -> SyncStatus { try await call("sync_status") }
    func syncStartPairing() async throws -> SyncPairingStart { try await call("sync_start_pairing") }
    func syncCancelPairing() async throws -> SyncStatus { try await call("sync_cancel_pairing") }
    func syncJoin(code: String?, qr: String?, host: String?, port: Int?) async throws -> SyncStatus {
        try await call("sync_join", ["code": code, "qr": qr, "host": host, "port": port])
    }
    func syncUnpair() async throws -> SyncStatus { try await call("sync_unpair") }
    func syncNow() async throws -> SyncStatus { try await call("sync_now") }
    func syncSetActive(_ active: Bool) async throws -> SyncStatus { try await call("sync_set_active", ["active": active]) }
}

// MARK: mock

/// The mock's sync state. `code` is fixed so screenshots are stable.
struct MockSyncState {
    static let code = "482913"
    static let qr = "spotless://pair?v=1&code=482913&addr=192.168.1.20%3A47615&dev=5f2c9a7e0b1d4c3a&name=iPhone"
    var status = SyncStatus.unlinked
    /// The next `sync_join` fails with this core error (tests, screenshots).
    var joinError: String?
}

extension MockCoreClient {
    private func syncChanged() -> SyncStatus {
        let s = withLock { sync.status }
        struct Payload: Encodable { var status: SyncStatus; var entities: [String] }
        emit("sync-changed", Payload(status: s, entities: []))
        return s
    }

    func syncStatus() async throws -> SyncStatus { withLock { sync.status } }

    func syncStartPairing() async throws -> SyncPairingStart {
        let start = SyncPairingStart(code: MockSyncState.code, qr: MockSyncState.qr, expiresAt: Date().timeIntervalSince1970 + 300,
                                     port: 47615, addrs: ["192.168.1.20"])
        withLock { sync.status.pairing = start.pairing; sync.status.lanPort = 47615 }
        _ = syncChanged()
        return start
    }

    func syncCancelPairing() async throws -> SyncStatus {
        withLock { sync.status.pairing = nil }
        return syncChanged()
    }

    func syncJoin(code: String?, qr: String?, host: String?, port: Int?) async throws -> SyncStatus {
        await pause()
        if let e = withLock({ sync.joinError }) { throw CoreFailure(message: e) }
        let digits = (code ?? qr.flatMap { CodeEntry.read($0).digits } ?? "").filter(\.isNumber)
        guard digits.count == 6 else { throw CoreFailure(message: "bad_code") }
        if digits == "000000" { throw CoreFailure(message: "wrong_code:2") }
        mockSyncLink()
        return syncChanged()
    }

    func syncUnpair() async throws -> SyncStatus {
        withLock { sync.status = .unlinked }
        return syncChanged()
    }

    func syncNow() async throws -> SyncStatus {
        withLock { sync.status.lastSync = Date().timeIntervalSince1970; sync.status.lastError = nil; sync.status.pending = 0 }
        return syncChanged()
    }

    func syncSetActive(_ active: Bool) async throws -> SyncStatus {
        withLock { sync.status.active = active }
        return try await syncStatus()
    }

    /// Linked with a Mac (tests and screenshots): `pending` changes waiting, and a last error.
    func mockSyncLink(pending: Int = 0, error: String? = nil, lastSyncAgo: Double = 5) {
        let now = Date().timeIntervalSince1970
        withLock {
            sync.status.paired = true
            sync.status.pairId = "9b1e6f3c2d7a4e85"
            sync.status.pairing = nil
            sync.status.peers = [SyncPeer(id: "a41c7e2b90d35f68", name: "MacBook Pro", platform: "mac", lastSeen: now - lastSyncAgo, lan: true)]
            sync.status.pending = pending
            sync.status.lastError = error
            sync.status.lastSync = now - lastSyncAgo
        }
    }

    /// The device showing the code has been joined (tests): a new peer and the code withdrawn.
    func mockSyncJoinedByPeer() {
        mockSyncLink()
        _ = syncChanged()
    }

    /// The device showing the code saw its last wrong try (tests).
    func mockSyncCodeWithdrawn() {
        withLock { sync.status.pairing = nil }
        _ = syncChanged()
    }
}

// MARK: wording and logic (pure; DeviceSyncTests)

enum DeviceSyncText {
    /// The kind of device you'd link from here.
    static let other = "Mac"

    static func menuTitle(paired: Bool) -> String { paired ? "Linked devices" : "Link your \(other)" }

    static let notLinked = "Not linked"
    static let notLinkedLine = "Link your \(other) to keep your library, playlists, history, podcasts and settings in sync."
    static let errorLine = "Can't reach your other device or the sync service right now. Changes will go through when it's back."
    static let unlinkMessage = "Your devices stop syncing. Everything stays on both devices."
    static let introTitle = "Link your \(other)"
    static let introBody = "Open Ztunes on your \(other) and go to Settings › Devices › Link a device. Then show a code on one device and enter it on the other."
    static let localNetworkLine = "Ztunes will ask to find devices on your local network. Allow it so your devices can link."
    static let successBody = "Everything now stays in sync between your devices: library, playlists, history, podcasts and settings. Downloads stay on each device."
    static let welcomeTitle = "Using Ztunes on your \(other) too?"
    static let welcomeLine = "Link them to keep everything in sync."
    static let hint = "Have Ztunes on your \(other)? Link it to keep everything in sync."

    /// "A", "A and B", "A, B and 2 more".
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    static func title(_ s: SyncStatus) -> String {
        guard s.paired else { return notLinked }
        let n = names(s.peers.map(\.name))
        return n.isEmpty ? "Linked" : "Linked with \(n)"
    }

    /// "Syncing…", "Synced 2 min ago", "Waiting for connection".
    static func statusLine(_ s: SyncStatus, now: Double) -> String {
        if s.syncing { return "Syncing…" }
        if s.lastError != nil { return "Waiting for connection" }
        if let t = s.lastSync { return "Synced " + ago(now - t) }
        return "Waiting for connection"
    }

    static func ago(_ secs: Double) -> String {
        let s = max(0, Int(secs))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        let d = s / 86400
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }

    static func pending(_ n: Int) -> String? {
        n <= 0 ? nil : n == 1 ? "1 change waiting to sync" : "\(n.formatted()) changes waiting to sync"
    }

    /// "4:59".
    static func countdown(_ secondsLeft: Double) -> String {
        let s = max(0, Int(secondsLeft.rounded(.up)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "482 913".
    static func code(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    static func unlinkTitle(_ peers: [SyncPeer]) -> String {
        let n = names(peers.map(\.name))
        return n.isEmpty ? "Unlink this device?" : "Unlink \(n)?"
    }
}

/// A failed link, in plain words.
struct PairingError: Equatable {
    enum Kind: Equatable { case wrongCode, lastTry, expired, badCode, unreachable, localNetwork, other }
    var kind: Kind
    var message: String

    static let localNetwork = PairingError(kind: .localNetwork,
                                           message: "Ztunes can't reach your local network. Allow it in Settings › Ztunes › Local Network.")
    static let unreachable = PairingError(kind: .unreachable, message: "Your devices can't see each other. Make sure both are on the same Wi-Fi.")

    /// The core's error (`wrong_code:2`, `not_pairing`, `no_host`, an io error) as a sentence.
    static func from(_ raw: String) -> PairingError {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = r.lowercased()
        if l.hasPrefix("wrong_code:"), let n = Int(l.dropFirst("wrong_code:".count)) {
            if n <= 0 {
                return PairingError(kind: .lastTry, message: "That code didn't match, and that was the last try. Show a new code on your other device.")
            }
            return PairingError(kind: .wrongCode, message: "That code didn't match. \(n) \(n == 1 ? "try" : "tries") left.")
        }
        if l == "wrong_code" || l == "pake" { return PairingError(kind: .wrongCode, message: "That code didn't match.") }
        if l == "not_pairing" { return PairingError(kind: .expired, message: "This code has expired. Show a new code on your other device.") }
        if l == "bad_code" { return PairingError(kind: .badCode, message: "Enter all 6 digits.") }
        if l.contains("os error 65") || l.contains("no route to host") { return .localNetwork }
        let unreachable = ["no_host", "timeout", "timed out", "closed", "refused", "unreachable", "os error 60", "os error 61",
                           "os error 64", "network is down", "host is down"]
        if unreachable.contains(where: l.contains) { return .unreachable }
        return PairingError(kind: .other, message: "Couldn't link your devices. Try again.")
    }
}

/// What was typed or pasted into the code boxes.
enum CodeEntry {
    /// Digits (at most 6), or a whole `spotless://pair` link (its code as the digits).
    static func read(_ raw: String) -> (digits: String, qr: String?) {
        if let qr = pairLink(in: raw) {
            let code = URLComponents(string: qr)?.queryItems?.first { $0.name == "code" }?.value ?? ""
            return (String(code.filter(\.isNumber).prefix(6)), qr)
        }
        return (String(raw.filter { $0.isASCII && $0.isNumber }.prefix(6)), nil)
    }

    /// The first `spotless://pair?…` (or `encore://pair?…`) link in `text`, as `spotless://`.
    static func pairLink(in text: String) -> String? {
        for scheme in ["spotless://pair?", "encore://pair?"] {
            guard let r = text.range(of: scheme, options: .caseInsensitive) else { continue }
            let tail = text[r.upperBound...].prefix { !$0.isWhitespace }
            return "spotless://pair?" + tail
        }
        return nil
    }
}
