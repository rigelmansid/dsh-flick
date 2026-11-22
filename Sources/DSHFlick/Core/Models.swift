import Foundation

/// A live, authenticated connection to the DeepSeek Harness web server that
/// the desktop app hosts on loopback.
///
/// The web server authenticates every request with an authority-bound signed
/// cookie whose *name* is `dsh-auth-<base64url(sha256("host:port"))>` and whose
/// value is a signed `v1.<payload>.<signature>` envelope. On current DSH
/// releases the companion app mints that cookie locally from the browser-session
/// signing secret persisted in `~/.dsh/.credentials.yaml`; on older releases it
/// replays the cookie the Electron app stored in its Chromium cookie database.
struct DSHConnection: Equatable {
    /// TCP port the desktop host is listening on (`DSH_WEB_URL`).
    let port: Int
    /// Deterministic cookie name derived from the loopback authority.
    let cookieName: String
    /// Signed `v1.<payload>.<signature>` browser-session value.
    let cookieValue: String
    /// Absolute cookie expiry reported by the cookie store.
    let cookieExpiresAt: Date
    /// When the discovery pass that produced this value ran.
    let discoveredAt: Date

    var baseURL: URL {
        // force-unwrap is safe: the scheme/host are constants and port is 1...65535.
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    var authority: String { "127.0.0.1:\(port)" }

    /// True while the signed browser cookie is inside its lifetime.
    var isCookieValid: Bool { cookieExpiresAt > Date() }
}

enum DSHDiscoveryError: Error, LocalizedError, Equatable {
    case desktopNotRunning
    case noAuthCookie
    case cookieDatabaseUnreadable(String)
    case webServerNotFound
    case serverUnreachable(port: Int)
    case notDSHServer(port: Int)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .desktopNotRunning:
            return "DeepSeek Harness 未运行"
        case .noAuthCookie:
            return "未找到登录态，请先打开一次 DeepSeek Harness 主窗口"
        case .cookieDatabaseUnreadable(let detail):
            return "无法读取 DSH 登录态：\(detail)"
        case .webServerNotFound:
            return "未找到 DeepSeek Harness 本地服务，请打开一次主窗口"
        case .serverUnreachable(let port):
            return "无法连接 DSH 服务（端口 \(port)）"
        case .notDSHServer(let port):
            return "端口 \(port) 不是 DeepSeek Harness 服务"
        case .timedOut:
            return "连接 DeepSeek Harness 超时"
        }
    }

    /// Short, non-sensitive machine-readable code for CLI/probe output and logs.
    var diagnostic: String {
        switch self {
        case .desktopNotRunning: return "desktop-not-running"
        case .noAuthCookie: return "no-auth-cookie"
        case .cookieDatabaseUnreadable: return "cookie-database-unreadable"
        case .webServerNotFound: return "web-server-not-found"
        case .serverUnreachable: return "server-unreachable"
        case .notDSHServer: return "not-dsh-server"
        case .timedOut: return "timed-out"
        }
    }

    /// Whether the user can fix this by opening the desktop app.
    var isFixableByLaunchingDesktop: Bool {
        switch self {
        case .desktopNotRunning, .noAuthCookie, .serverUnreachable, .webServerNotFound:
            return true
        case .cookieDatabaseUnreadable, .notDSHServer, .timedOut:
            return false
        }
    }
}

/// Everything the menu bar surface needs in order to render.
enum DSHAppState: Equatable {
    case connecting
    case connected(DSHConnection)
    case offline(DSHDiscoveryError)
}
