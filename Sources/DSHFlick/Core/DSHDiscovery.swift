import Foundation
import CryptoKit

/// Discovers the live DeepSeek Harness web server and an authentication cookie
/// that its loopback HTTP server accepts.
///
/// The Electron desktop app hosts the DSH web UI on a dynamically chosen
/// loopback port. Two discovery strategies are supported:
///
/// 1. **Minted cookie (DSH 0.2.2-rc.3 and newer).** The desktop shell no longer
///    persists `dsh-auth-*` cookies in its Chromium cookie store; it keeps the
///    `Set-Cookie` value in its own process instead. What it *does* persist is
///    the browser-session signing secret in `~/.dsh/.credentials.yaml`
///    (`client-connection/browser-session`). The cookie is a signed envelope
///    `v1.<base64url(json)>.<base64url(hmac-sha256)>` bound to the loopback
///    authority (`127.0.0.1:<port>`) with a 30-day maximum lifetime. Using the
///    persisted secret we can mint an equally valid cookie locally, without
///    touching the DSH installation. The port itself is found by enumerating
///    the user's loopback listeners and probing `GET /` for DSH's unauthenticated
///    `401 dsh web authentication required` marker.
///
/// 2. **Legacy cookie replay (DSH 0.2.2-rc.2 and older).** Older desktop releases
///    stored one signed authority cookie per loopback port in their Chromium
///    cookie store, named `dsh-auth-<base64url(sha256("127.0.0.1:<port>"))>`.
///    Deriving that name for all possible ports and matching it against the
///    cookie store reveals the live port; a single authenticated `GET /`
///    confirms it.
///
/// The credential/secret material is only read and used locally; it is never
/// logged, printed or transmitted anywhere except to the loopback DSH server.
final class DSHDiscovery {
    static let shared = DSHDiscovery()

    private init() {}

    /// Last cookie successfully accepted by a live DSH server. Reusing it keeps
    /// `DSHConnection` stable across discovery passes, so the WebPane does not
    /// reload the whole UI every time the panel re-validates an existing port.
    private let cookieCacheLock = NSLock()
    private var cookieCache: (authority: String, cookie: MintedCookie)?

    // MARK: - Configuration

    private enum Config {
        static let host = "127.0.0.1"
        static let cookieNamePrefix = "dsh-auth-"
        /// Marker injected by the DSH web server into its boot HTML. A 200
        /// response that does not contain it is some other local service.
        static let bootMarker = "__DSH_BOOT__"
        /// Text rendered by the DSH server for unauthenticated requests.
        static let authRequiredMarker = "dsh web authentication required"
        /// Absolute lifetime for a self-minted cookie. The server's default
        /// maximum is 30 days (`cookieMaxAgeDays`), so stay just below it.
        static let mintedCookieLifetime: TimeInterval = 29 * 24 * 60 * 60
        /// Shorter retry lifetimes, used when a DSH configuration narrows the
        /// maximum cookie age below the default.
        static let mintedCookieFallbackLifetimes: [TimeInterval] = [
            24 * 60 * 60,
            60 * 60,
        ]
        static let sqlite3Path = "/usr/bin/sqlite3"
        static let lsofPath = "/usr/sbin/lsof"
        static let netstatPath = "/usr/sbin/netstat"
        static let minimumPort = 1024
        static let maximumPort = 65535
        /// Chromium stores cookie timestamps as microseconds since 1601-01-01 UTC.
        static let chromiumEpochOffset: TimeInterval = 11_644_473_600
        /// Upper bound for one authenticated HTTP verification request.
        static let maximumProbeTimeout: TimeInterval = 3
        /// Short bound for the unauthenticated listener scan: the DSH 401
        /// marker arrives on loopback within milliseconds, so there is no need
        /// to wait for unrelated local services to answer.
        static let unauthenticatedProbeTimeout: TimeInterval = 0.75
        /// Fallback lifetime for session cookies (`expires_utc == 0`).
        static let sessionCookieLifetime: TimeInterval = 24 * 60 * 60
    }

    // MARK: - Internal models

    /// One authenticated-cookie row read from the desktop app's cookie store.
    private struct CookieRecord {
        let name: String
        let value: String
        let expiresAt: Date
        let lastAccessAt: Date
        let isExpired: Bool
    }

    /// A cookie paired with the loopback port its name was derived from.
    private struct PortCandidate {
        let port: Int
        let cookie: CookieRecord
    }

    /// A cookie minted locally from the persisted browser-session secret.
    private struct MintedCookie {
        let name: String
        let value: String
        let expiresAt: Date
    }

    private struct CookieScan {
        var records: [CookieRecord] = []
        /// File exists at least for one known cookie-store location.
        var foundDatabase = false
        /// Human readable reason when every known store failed to be read.
        var errorDetail: String?
    }

    private enum ProbeOutcome {
        case success
        /// Reachable DSH server, but it rejected the presented cookie.
        case authRejected
        /// Connection refused / host down.
        case unreachable
        /// A local HTTP server responded, but it is not the DSH host.
        case notDSH
        /// The request did not finish inside the time budget.
        case timedOut
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Internal storage-read failure; carries a non-sensitive detail string.
    private struct StorageError: Error {
        let detail: String
    }

    // MARK: - Public API

    /// Run one discovery pass.
    ///
    /// Cheap failure paths (desktop not running) return immediately. The
    /// `timeout` bounds the end-to-end port probing, not credential parsing.
    func discover(timeout: TimeInterval = 8) async -> Result<DSHConnection, DSHDiscoveryError> {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(max(1, timeout))

        // Fast path: no desktop app means no web server and no fresh cookie.
        guard DSHDesktop.isRunning else {
            return .failure(.desktopNotRunning)
        }

        // Preferred: mint a signed cookie from the durable browser-session
        // secret. This is the only strategy that works on DSH >= 0.2.2-rc.3.
        if let secret = browserSessionSecret() {
            let result = await discoverWithMintedCookie(
                secret: secret,
                startedAt: startedAt,
                deadline: deadline
            )
            switch result {
            case .success:
                return result
            case .failure(let error):
                // A rejected cookie may mean the secret just rotated; the
                // legacy cookie store is worth one attempt before giving up.
                if error == .noAuthCookie {
                    return await discoverLegacy(startedAt: startedAt, deadline: deadline)
                }
                return result
            }
        }

        return await discoverLegacy(startedAt: startedAt, deadline: deadline)
    }

    /// Poll discovery until a connection appears or the timeout elapses.
    ///
    /// Transient errors are remembered; when the timeout hits, the most
    /// informative one seen is returned instead of a bare `.timedOut`.
    func waitForConnection(
        timeout: TimeInterval = 45,
        interval: TimeInterval = 0.7
    ) async -> Result<DSHConnection, DSHDiscoveryError> {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: DSHDiscoveryError?
        var lastMeaningfulError: DSHDiscoveryError?

        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }

            let passTimeout = min(max(remaining, 0.5), 3)
            let result = await discover(timeout: passTimeout)
            switch result {
            case .success(let connection):
                return .success(connection)
            case .failure(let error):
                lastError = error
                switch error {
                case .desktopNotRunning, .timedOut:
                    // Expected while the desktop app is still starting up;
                    // keep the last richer error if there was one.
                    break
                default:
                    lastMeaningfulError = error
                }
            }

            let timeLeft = deadline.timeIntervalSinceNow
            if timeLeft <= 0 { break }
            let sleepNanoseconds = UInt64(min(interval, timeLeft) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: max(sleepNanoseconds, 50_000_000))
            } catch {
                return .failure(lastMeaningfulError ?? lastError ?? .timedOut)
            }
        }

        return .failure(lastMeaningfulError ?? lastError ?? .timedOut)
    }

    // MARK: - Minted cookie (DSH >= 0.2.2-rc.3)

    /// Reads the browser-session signing secret from the DSH credentials file.
    /// Returns `nil` when no such record exists (older DSH versions).
    private func browserSessionSecret() -> Data? {
        guard let text = try? String(contentsOf: credentialsFileURL(), encoding: .utf8) else {
            return nil
        }
        guard let encoded = Self.extractBrowserSessionSecret(from: text) else { return nil }
        return Self.decodeBase64URL(encoded)
    }

    /// `~/.dsh/.credentials.yaml`, honouring a `DSH_HOME` override when the
    /// file actually exists there.
    private func credentialsFileURL() -> URL {
        let fileManager = FileManager.default
        let homeCredentials = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true)
            .appendingPathComponent(".credentials.yaml")

        guard let rawHome = ProcessInfo.processInfo.environment["DSH_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !rawHome.isEmpty else {
            return homeCredentials
        }
        let custom = URL(fileURLWithPath: rawHome, isDirectory: true)
        let candidates = [
            custom.appendingPathComponent(".credentials.yaml"),
            custom.appendingPathComponent("dsh", isDirectory: true)
                .appendingPathComponent(".credentials.yaml"),
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        return homeCredentials
    }

    /// Extracts `records["client-connection/browser-session"].payload.secret`
    /// from the small YAML document without pulling in a YAML dependency.
    private static func extractBrowserSessionSecret(from text: String) -> String? {
        var recordIndent: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = String(line)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = content.prefix(while: { $0 == " " }).count

            if let baseIndent = recordIndent {
                if indent > baseIndent {
                    guard trimmed.hasPrefix("secret:") else { continue }
                    var value = String(trimmed.dropFirst("secret:".count))
                        .trimmingCharacters(in: .whitespaces)
                    if let commentIndex = value.firstIndex(of: "#") {
                        // base64url never contains '#', so this is a YAML comment.
                        value = String(value[value.startIndex..<commentIndex])
                            .trimmingCharacters(in: .whitespaces)
                    }
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    return value.isEmpty ? nil : value
                }
                recordIndent = nil
            }

            if trimmed.hasPrefix("client-connection/browser-session:") {
                recordIndent = indent
            }
        }
        return nil
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func discoverWithMintedCookie(
        secret: Data,
        startedAt: Date,
        deadline: Date
    ) async -> Result<DSHConnection, DSHDiscoveryError> {
        guard Date() < deadline else { return .failure(.timedOut) }

        let ports = await listenerPorts()
        guard !ports.isEmpty else { return .failure(.webServerNotFound) }

        let session = makeProbeSession()
        defer { session.invalidateAndCancel() }

        let remainingForProbe = deadline.timeIntervalSinceNow
        guard remainingForProbe > 0.05 else { return .failure(.timedOut) }
        let probeTimeout = min(Config.unauthenticatedProbeTimeout, max(0.4, remainingForProbe))

        // Identify which loopback listeners are DSH servers. Probing all
        // candidates concurrently keeps discovery fast even when unrelated
        // local services do not answer promptly.
        var dshPorts: [Int] = []
        await withTaskGroup(of: Int?.self) { group in
            for port in ports {
                group.addTask {
                    await Self.probeUnauthenticated(
                        port: port,
                        timeout: probeTimeout,
                        session: session
                    ) ? port : nil
                }
            }
            for await discovered in group {
                if let port = discovered { dshPorts.append(port) }
            }
        }
        guard !dshPorts.isEmpty else { return .failure(.webServerNotFound) }

        // Preserve the candidate order produced by listenerPorts() (DSH-named
        // processes first), which matters when more than one DSH host is up.
        let rank = Dictionary(uniqueKeysWithValues: ports.enumerated().map { ($1, $0) })
        dshPorts.sort { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }

        let lifetimeLadder = [Config.mintedCookieLifetime] + Config.mintedCookieFallbackLifetimes
        for port in dshPorts {
            let authority = "\(Config.host):\(port)"
            var pendingLifetimes = lifetimeLadder
            var cached = cachedCookie(for: authority)
            while true {
                let cookie: MintedCookie
                let usedCachedCookie: Bool
                if let cachedCookie = cached {
                    cookie = cachedCookie
                    usedCachedCookie = true
                    cached = nil
                } else {
                    guard let lifetime = pendingLifetimes.first else { break }
                    pendingLifetimes.removeFirst()
                    guard let minted = mintCookie(secret: secret, authority: authority, lifetime: lifetime) else {
                        return .failure(.noAuthCookie)
                    }
                    cookie = minted
                    usedCachedCookie = false
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0.05 else { return .failure(.timedOut) }
                let outcome = await probe(
                    port: port,
                    cookieName: cookie.name,
                    cookieValue: cookie.value,
                    using: session,
                    timeout: min(Config.maximumProbeTimeout, max(0.5, remaining))
                )
                switch outcome {
                case .success:
                    storeCachedCookie(cookie, authority: authority)
                    return .success(
                        DSHConnection(
                            port: port,
                            cookieName: cookie.name,
                            cookieValue: cookie.value,
                            cookieExpiresAt: cookie.expiresAt,
                            discoveredAt: startedAt
                        )
                    )
                case .authRejected:
                    if usedCachedCookie {
                        // The persisted signing secret may have rotated.
                        clearCachedCookie()
                    }
                    // Lifetime may exceed this installation's configured
                    // maximum; try the next, shorter lifetime.
                    continue
                case .timedOut:
                    return .failure(.timedOut)
                case .unreachable, .notDSH:
                    break
                }
            }
        }
        return .failure(.noAuthCookie)
    }

    // MARK: Cookie cache

    private func cachedCookie(for authority: String) -> MintedCookie? {
        cookieCacheLock.lock()
        defer { cookieCacheLock.unlock() }
        guard let entry = cookieCache,
              entry.authority == authority,
              entry.cookie.expiresAt > Date().addingTimeInterval(60) else {
            return nil
        }
        return entry.cookie
    }

    private func storeCachedCookie(_ cookie: MintedCookie, authority: String) {
        cookieCacheLock.lock()
        cookieCache = (authority, cookie)
        cookieCacheLock.unlock()
    }

    private func clearCachedCookie() {
        cookieCacheLock.lock()
        cookieCache = nil
        cookieCacheLock.unlock()
    }

    /// Builds the signed `v1.<payload>.<signature>` cookie the DSH server
    /// expects for `authority`, using the persisted HMAC secret.
    private func mintCookie(secret: Data, authority: String, lifetime: TimeInterval) -> MintedCookie? {
        let issuedAt = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        let expiresAt = issuedAt + Int64((lifetime * 1000).rounded())
        let payload: [String: Any] = [
            "version": 1,
            "authority": authority,
            "issuedAt": issuedAt,
            "expiresAt": expiresAt,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        let body = Self.base64URL(json)
        let key = SymmetricKey(data: secret)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        let value = "v1.\(body).\(Self.base64URL(Data(signature)))"
        let name = Config.cookieNamePrefix
            + Self.base64URL(Data(SHA256.hash(data: Data(authority.utf8))))
        return MintedCookie(
            name: name,
            value: value,
            expiresAt: Date(timeIntervalSince1970: Double(expiresAt) / 1000)
        )
    }

    /// Loopback TCP ports currently in `LISTEN`, DSH-named processes first.
    private func listenerPorts() async -> [Int] {
        var ports: [Int] = []
        if let hint = advertisedPort() {
            ports.append(hint)
        }
        let fromLsof = await lsofListenerPorts()
        if fromLsof.isEmpty {
            ports.append(contentsOf: await netstatListenerPorts())
        } else {
            ports.append(contentsOf: fromLsof)
        }
        var seen = Set<Int>()
        return ports.filter { seen.insert($0).inserted }
    }

    /// Parses `lsof -Fpcn` output; field letters are `p` (pid), `c` (command),
    /// `n` (address). Only loopback listeners are returned.
    private func lsofListenerPorts() async -> [Int] {
        let result = await runProcess(
            Config.lsofPath,
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]
        )
        guard case .success(let processResult) = result, processResult.status == 0 else {
            return []
        }
        let output = String(decoding: processResult.stdout, as: UTF8.self)
        var command = ""
        var preferred: [Int] = []
        var others: [Int] = []
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let kind = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch kind {
            case "p":
                command = ""
            case "c":
                command = value
            case "n":
                guard Self.isLoopbackListenerAddress(value),
                      let port = Self.listenerPort(fromAddress: value) else { continue }
                if Self.commandLooksLikeDSH(command) {
                    preferred.append(port)
                } else {
                    others.append(port)
                }
            default:
                break
            }
        }
        var seen = Set<Int>()
        return (preferred + others).filter { seen.insert($0).inserted }
    }

    /// Fallback for systems where lsof is unavailable: parse `netstat -anv`.
    private func netstatListenerPorts() async -> [Int] {
        let result = await runProcess(Config.netstatPath, ["-anv", "-p", "tcp"])
        guard case .success(let processResult) = result, processResult.status == 0 else {
            return []
        }
        let output = String(decoding: processResult.stdout, as: UTF8.self)
        var ports: [Int] = []
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 6, fields.contains("LISTEN") else { continue }
            let address = String(fields[3])
            guard Self.isLoopbackListenerAddress(address),
                  let port = Self.listenerPort(fromAddress: address) else { continue }
            ports.append(port)
        }
        var seen = Set<Int>()
        return ports.filter { seen.insert($0).inserted }
    }

    /// Trailing port digits of `127.0.0.1:53467`, `*:54822`, `::1.53467`, …
    private static func listenerPort(fromAddress address: String) -> Int? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = text.reversed().prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let port = Int(String(digits.reversed())) else { return nil }
        return (1...65535).contains(port) ? port : nil
    }

    private static func isLoopbackListenerAddress(_ address: String) -> Bool {
        let lowered = address.lowercased()
        let prefixes = [
            "127.0.0.1:", "127.0.0.1.",
            "localhost:", "localhost.",
            "[::1]:", "::1.",
            "[::]:", "[::].",
            "*:", "*.",
            "0.0.0.0:", "0.0.0.0.",
        ]
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    private static func commandLooksLikeDSH(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return lowered.contains("deepseek") || lowered.contains("dsh")
    }

    /// Unauthenticated `GET /`: DSH answers with its private 401 marker. A 200
    /// boot document (auth disabled) also identifies a DSH server.
    private static func probeUnauthenticated(
        port: Int,
        timeout: TimeInterval,
        session: URLSession
    ) async -> Bool {
        guard let url = URL(string: "http://\(Config.host):\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("DSHFlick/0.2 (macOS; loopback discovery)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(4096), as: UTF8.self)
            if statusCode == 401, body.contains(Config.authRequiredMarker) { return true }
            if statusCode == 200, body.contains(Config.bootMarker) { return true }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Legacy cookie store (DSH <= 0.2.2-rc.2)

    private func discoverLegacy(
        startedAt: Date,
        deadline: Date
    ) async -> Result<DSHConnection, DSHDiscoveryError> {
        let scan = await loadCookieRecords()
        if scan.records.isEmpty {
            if let detail = scan.errorDetail {
                return .failure(.cookieDatabaseUnreadable(detail))
            }
            return .failure(.noAuthCookie)
        }

        guard Date() < deadline else { return .failure(.timedOut) }

        let candidates = derivePortCandidates(from: scan.records)
        guard !candidates.isEmpty else {
            // Cookie rows exist but none belongs to a live loopback port we
            // could verify (all expired, or all from older runs).
            return .failure(.noAuthCookie)
        }

        let session = makeProbeSession()
        defer { session.invalidateAndCancel() }

        var sawAuthRejected = false
        var firstUnreachablePort: Int?
        var firstNotDSHPort: Int?
        var sawTimeout = false

        for candidate in candidates {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0.05 {
                sawTimeout = true
                break
            }
            let probeTimeout = min(Config.maximumProbeTimeout, max(0.5, remaining))
            let outcome = await probe(
                port: candidate.port,
                cookieName: candidate.cookie.name,
                cookieValue: candidate.cookie.value,
                using: session,
                timeout: probeTimeout
            )
            switch outcome {
            case .success:
                return .success(
                    DSHConnection(
                        port: candidate.port,
                        cookieName: candidate.cookie.name,
                        cookieValue: candidate.cookie.value,
                        cookieExpiresAt: candidate.cookie.expiresAt,
                        discoveredAt: startedAt
                    )
                )
            case .authRejected:
                sawAuthRejected = true
            case .unreachable:
                if firstUnreachablePort == nil { firstUnreachablePort = candidate.port }
            case .notDSH:
                if firstNotDSHPort == nil { firstNotDSHPort = candidate.port }
            case .timedOut:
                sawTimeout = true
            }
        }

        // Turn the collected outcomes into the most informative error.
        if sawAuthRejected { return .failure(.noAuthCookie) }
        if let port = firstUnreachablePort { return .failure(.serverUnreachable(port: port)) }
        if let port = firstNotDSHPort { return .failure(.notDSHServer(port: port)) }
        if sawTimeout { return .failure(.timedOut) }
        return .failure(.serverUnreachable(port: candidates[0].port))
    }

    /// Reads `dsh-auth-*` cookies for loopback from the desktop app's Chromium
    /// cookie database. Only the root store and per-partition stores that exist
    /// are consulted; all reads are strictly read-only.
    private func loadCookieRecords() async -> CookieScan {
        var scan = CookieScan()
        for databaseURL in cookieDatabaseCandidates() {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
            scan.foundDatabase = true
            switch await readCookieRecords(from: databaseURL) {
            case .success(let records):
                if !records.isEmpty {
                    scan.records = records
                    scan.errorDetail = nil
                    return scan
                }
            case .failure(let storageError):
                // Keep the first error; a later partition may still work.
                if scan.errorDetail == nil { scan.errorDetail = storageError.detail }
            }
        }
        return scan
    }

    /// Known Chromium cookie-store locations of the desktop app, most
    /// authoritative first.
    private func cookieDatabaseCandidates() -> [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let desktop = support.appendingPathComponent("@deepseek-ai/dsh-desktop", isDirectory: true)
        var urls: [URL] = [desktop.appendingPathComponent("Cookies")]

        let partitions = desktop.appendingPathComponent("Partitions", isDirectory: true)
        if let children = try? FileManager.default.contentsOfDirectory(
            at: partitions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                urls.append(child.appendingPathComponent("Cookies"))
            }
        }
        return urls
    }

    private func readCookieRecords(from databaseURL: URL) async -> Result<[CookieRecord], StorageError> {
        // Selecting only name/length-relevant columns; cookie values are never
        // logged anywhere in this file.
        let sql = "SELECT name, value, expires_utc, last_access_utc "
            + "FROM cookies "
            + "WHERE host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%';"
        let arguments = ["-readonly", "-cmd", ".timeout 2000", "-separator", "|", databaseURL.path, sql]
        let result = await runProcess(Config.sqlite3Path, arguments)

        switch result {
        case .failure(let storageError):
            return await readCookieRecordsFromTemporaryCopy(
                databaseURL: databaseURL,
                originalError: storageError.detail
            )
        case .success(let processResult):
            guard processResult.status == 0 else {
                let stderr = String(decoding: processResult.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderr.isEmpty ? "sqlite3 退出码 \(processResult.status)" : String(stderr.prefix(200))
                return await readCookieRecordsFromTemporaryCopy(
                    databaseURL: databaseURL,
                    originalError: detail
                )
            }
            let output = String(decoding: processResult.stdout, as: UTF8.self)
            return .success(parseCookieRows(output))
        }
    }

    /// Chromium keeps the cookie database open (and possibly locked) while
    /// Electron runs. If a direct read-only query fails, query a copy instead.
    private func readCookieRecordsFromTemporaryCopy(
        databaseURL: URL,
        originalError: String
    ) async -> Result<[CookieRecord], StorageError> {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("dsh-flick-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let copyURL = temporaryDirectory.appendingPathComponent("Cookies")
            try fileManager.copyItem(at: databaseURL, to: copyURL)
            // Report of accompanying sidecar files is harmless; copy whatever exists.
            for suffix in ["-journal", "-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
                if fileManager.fileExists(atPath: sidecar.path) {
                    try? fileManager.copyItem(
                        at: sidecar,
                        to: URL(fileURLWithPath: copyURL.path + suffix)
                    )
                }
            }
            let sql = "SELECT name, value, expires_utc, last_access_utc "
                + "FROM cookies "
                + "WHERE host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%';"
            let arguments = ["-readonly", "-cmd", ".timeout 2000", "-separator", "|", copyURL.path, sql]
            switch await runProcess(Config.sqlite3Path, arguments) {
            case .failure(let storageError):
                return .failure(storageError)
            case .success(let processResult):
                guard processResult.status == 0 else {
                    return .failure(StorageError(detail: originalError))
                }
                let output = String(decoding: processResult.stdout, as: UTF8.self)
                return .success(parseCookieRows(output))
            }
        } catch {
            return .failure(StorageError(detail: originalError))
        }
    }

    private func parseCookieRows(_ output: String) -> [CookieRecord] {
        var records: [CookieRecord] = []
        let now = Date()
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let name = String(fields[0])
            let value = String(fields[1])
            guard name.hasPrefix(Config.cookieNamePrefix), !value.isEmpty else { continue }
            let expiresMicroseconds = Int64(fields[2].trimmingCharacters(in: .whitespaces)) ?? 0
            let lastAccessMicroseconds = Int64(fields[3].trimmingCharacters(in: .whitespaces)) ?? 0
            let expiresAt = expiryDate(chromiumMicroseconds: expiresMicroseconds)
            let lastAccessAt = date(
                chromiumMicroseconds: lastAccessMicroseconds,
                fallback: expiresAt
            )
            records.append(
                CookieRecord(
                    name: name,
                    value: value,
                    expiresAt: expiresAt,
                    lastAccessAt: lastAccessAt,
                    isExpired: expiresAt <= now
                )
            )
        }
        return records
    }

    private func expiryDate(chromiumMicroseconds microseconds: Int64) -> Date {
        guard microseconds > 0 else {
            // Session cookie: valid while the desktop app keeps its session.
            return Date().addingTimeInterval(Config.sessionCookieLifetime)
        }
        let unixSeconds = Double(microseconds) / 1_000_000 - Config.chromiumEpochOffset
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private func date(chromiumMicroseconds microseconds: Int64, fallback: Date) -> Date {
        guard microseconds > 0 else { return fallback }
        let unixSeconds = Double(microseconds) / 1_000_000 - Config.chromiumEpochOffset
        return Date(timeIntervalSince1970: unixSeconds)
    }

    // MARK: - Legacy port derivation

    /// Maps the loopback port onto its cookie and returns the candidates in the
    /// order worth verifying: unexpired first, then most recently valid.
    private func derivePortCandidates(from records: [CookieRecord]) -> [PortCandidate] {
        // Deduplicate by cookie name, keeping the best row for each authority.
        var bestByName: [String: CookieRecord] = [:]
        for record in records {
            if let existing = bestByName[record.name] {
                if record.isExpired != existing.isExpired {
                    if record.isExpired { continue }
                } else if record.expiresAt <= existing.expiresAt {
                    continue
                }
            }
            bestByName[record.name] = record
        }

        var portByName: [String: Int] = [:]

        // Cheap optimization: the host process advertises the live port through
        // DSH_WEB_URL; trust it only after the derived cookie name validates it.
        if let hintedPort = advertisedPort(),
           bestByName[cookieName(forPort: hintedPort)] != nil {
            portByName[cookieName(forPort: hintedPort)] = hintedPort
        }

        if portByName.count < bestByName.count {
            let wanted = Set(bestByName.keys).subtracting(portByName.keys)
            var outstanding = wanted.count
            for port in Config.minimumPort...Config.maximumPort {
                let name = cookieName(forPort: port)
                guard wanted.contains(name) else { continue }
                portByName[name] = port
                outstanding -= 1
                if outstanding == 0 { break }
            }
        }

        var candidates = bestByName.compactMap { name, record -> PortCandidate? in
            guard let port = portByName[name], !record.isExpired else { return nil }
            return PortCandidate(port: port, cookie: record)
        }
        candidates.sort { lhs, rhs in
            if lhs.cookie.expiresAt != rhs.cookie.expiresAt {
                return lhs.cookie.expiresAt > rhs.cookie.expiresAt
            }
            if lhs.cookie.lastAccessAt != rhs.cookie.lastAccessAt {
                return lhs.cookie.lastAccessAt > rhs.cookie.lastAccessAt
            }
            return lhs.port > rhs.port
        }
        return candidates
    }

    /// Deterministic cookie name the DSH server expects for a loopback authority.
    private func cookieName(forPort port: Int) -> String {
        let authority = "\(Config.host):\(port)"
        return Config.cookieNamePrefix
            + Self.base64URL(Data(SHA256.hash(data: Data(authority.utf8))))
    }

    /// Parses the `DSH_WEB_URL` hint exported by the desktop host, when present
    /// and loopback-only.
    private func advertisedPort() -> Int? {
        guard let raw = ProcessInfo.processInfo.environment["DSH_WEB_URL"] else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        func portIsUsable(_ port: Int) -> Bool { (1...65535).contains(port) }
        func hostIsLoopback(_ host: String) -> Bool {
            host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        }

        if let url = URL(string: value), let port = url.port {
            guard portIsUsable(port) else { return nil }
            if let host = url.host, !hostIsLoopback(host) { return nil }
            return port
        }
        // Tolerate "127.0.0.1:62697" without a scheme.
        if let colonIndex = value.lastIndex(of: ":") {
            let host = String(value[value.startIndex..<colonIndex])
            let portText = String(value[value.index(after: colonIndex)...])
            if let port = Int(portText), portIsUsable(port), hostIsLoopback(host) {
                return port
            }
        }
        if let port = Int(value), portIsUsable(port) { return port }
        return nil
    }

    // MARK: - Verification

    private func makeProbeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = Config.maximumProbeTimeout
        configuration.timeoutIntervalForResource = Config.maximumProbeTimeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }

    /// One authenticated `GET /`; success requires a DSH boot document.
    private func probe(
        port: Int,
        cookieName: String,
        cookieValue: String,
        using session: URLSession,
        timeout: TimeInterval
    ) async -> ProbeOutcome {
        guard let url = URL(string: "http://\(Config.host):\(port)/") else {
            return .notDSH
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("\(cookieName)=\(cookieValue)", forHTTPHeaderField: "Cookie")
        request.setValue("DSHFlick/0.2 (macOS; loopback discovery)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 200 {
                let body = String(decoding: data, as: UTF8.self)
                return body.contains(Config.bootMarker) ? .success : .notDSH
            }
            if statusCode == 401 || statusCode == 403 {
                let body = String(decoding: data, as: UTF8.self)
                if body.contains("dsh web") || body.contains(Config.authRequiredMarker) {
                    return .authRejected
                }
                return .notDSH
            }
            if statusCode == 0 { return .notDSH }
            return .notDSH
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                return .timedOut
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed,
                 .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection,
                 .badServerResponse, .resourceUnavailable:
                return .unreachable
            default:
                return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    // MARK: - Process helpers

    private func runProcess(
        _ executablePath: String,
        _ arguments: [String]
    ) async -> Result<ProcessResult, StorageError> {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .failure(StorageError(detail: "\(executablePath) 不可用"))
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(StorageError(detail: "无法启动 \(executablePath)：\(error.localizedDescription)")))
                    return
                }
                // The query output is tiny (a handful of short rows), so reading
                // the tail after exit is safe from pipe-buffer deadlocks.
                process.waitUntilExit()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: .success(
                        ProcessResult(status: process.terminationStatus, stdout: stdoutData, stderr: stderrData)
                    )
                )
            }
        }
    }
}
