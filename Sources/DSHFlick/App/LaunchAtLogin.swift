import Foundation
import os

/// Manages a per-user LaunchAgent that starts DSH Flick when the user logs in.
///
/// We deliberately use a plain `~/Library/LaunchAgents` property list instead
/// of `SMAppService`: it needs no bundled helper, it is trivial for users to
/// inspect or delete, and it works for an ad-hoc signed app.
enum LaunchAtLogin {
    private static let logger = Logger(subsystem: "com.rigelmansid.dshflick", category: "launch-at-login")

    /// LaunchAgent label, also used as the property list file name.
    static let label = "com.rigelmansid.dshflick"

    /// Path of the LaunchAgent property list.
    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist", isDirectory: false)
    }

    /// Login items only make sense for a real app bundle; running the loose
    /// `.build/DSHFlick` executable during development hides the menu item.
    static var isSupported: Bool {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return false }
        return Bundle.main.executablePath != nil
    }

    /// Whether the LaunchAgent property list currently exists on disk.
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Install or remove the LaunchAgent property list.
    static func setEnabled(_ enabled: Bool) throws {
        let fileManager = FileManager.default
        if enabled {
            guard isSupported, let executablePath = Bundle.main.executablePath else {
                throw LaunchAtLoginError.notSupported
            }
            try fileManager.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let propertyList: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )
            try data.write(to: agentURL, options: .atomic)
            logger.info("launch at login enabled")
        } else {
            if fileManager.fileExists(atPath: agentURL.path) {
                try fileManager.removeItem(at: agentURL)
            }
            logger.info("launch at login disabled")
        }
    }
}

/// Errors surfaced by `LaunchAtLogin` for the about/menu alerts.
enum LaunchAtLoginError: LocalizedError {
    case notSupported

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "开机自启需要以 App 形式运行 DSH Flick（dist/DSH Flick.app）"
        }
    }
}
