import AppKit
import CoreGraphics

/// Locating, launching and activating the DeepSeek Harness desktop app.
enum DSHDesktop {
    /// Bundle identifier of the Electron desktop host.
    static let bundleIdentifier = "com.deepseek.dsh"
    /// Human readable name used in log/UI messages.
    static let displayName = "DeepSeek Harness"
    /// Standard install location, used when Launch Services cannot resolve the
    /// bundle identifier (for example in a freshly copied app bundle).
    private static let fallbackApplicationPath = "/Applications/DeepSeek Harness.app"

    /// Whether the Electron desktop app is currently running.
    static var isRunning: Bool {
        runningApplication != nil
    }

    /// The running desktop app, if any.
    static var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    /// Whether any real DeepSeek Harness window is currently on screen.
    ///
    /// Minimized windows and windows on another Space/full-screen Space are not
    /// returned by `optionOnScreenOnly`, which is exactly the "main UI is not
    /// visible" state the approval popover cares about. Owner PID and bounds do
    /// not require Screen Recording permission.
    static var hasVisibleWindow: Bool {
        guard let application = runningApplication else { return false }
        let pid = application.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard
                let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                owner == pid,
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let alpha = window[kCGWindowAlpha as String] as? Double,
                alpha > 0.01,
                let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }
            if bounds.width >= 200, bounds.height >= 100 {
                return true
            }
        }
        return false
    }

    /// Location of the desktop app bundle, when it can be found.
    static var applicationURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        let fallbackURL = URL(fileURLWithPath: fallbackApplicationPath)
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return fallbackURL
        }
        return nil
    }

    /// Whether the desktop app bundle can be found on this machine.
    static var isInstalled: Bool {
        applicationURL != nil
    }

    /// Bring the running desktop app forward, or launch it from the standard
    /// application location when it is not running.
    ///
    /// Returns `true` when the app was activated or a launch was requested.
    /// Launching is asynchronous by nature, so callers should poll for the web
    /// server afterwards (see `DSHDiscovery.waitForConnection`).
    @discardableResult
    static func activateOrLaunch() -> Bool {
        if let application = runningApplication {
            if application.isHidden {
                application.unhide()
            }
            // Electron may ignore a plain `activate` when its primary window
            // was closed; `dsh://open` runs the desktop shell's own
            // `focusPrimaryWindow()`, which recreates the window when needed.
            _ = application.activate(options: [.activateAllWindows])
            openPrimaryWindow()
            return true
        }

        guard let bundleURL = applicationURL else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                NSLog("[DSHFlick] Failed to launch %@: %@", displayName, error.localizedDescription)
            }
        }
        return true
    }

    /// Ask the running Electron shell to focus (or recreate) its primary window.
    private static func openPrimaryWindow() {
        guard let url = URL(string: "dsh://open") else { return }
        NSWorkspace.shared.open(url)
    }
}
