import AppKit
import Foundation

/// Lifecycle ownership for the plugin-managed menu bar app.
///
/// The DSH plugin spawns this binary with `--managed` and keeps a pipe on the
/// child's stdin. The app exits when that pipe reaches EOF (the Host process
/// died or closed it) and, as a second line of defence, when the parent process
/// disappears. That makes the icon disappear with DeepSeek Harness even after a
/// crash or a force-quit, without leaving a launch agent behind.
///
/// Standalone launches do not pass `--managed`, so all of this is a no-op for
/// the normal app.
enum ManagedLifecycle {
    static var isManaged: Bool {
        CommandLine.arguments.contains("--managed")
    }

    private static let readerQueue = DispatchQueue(
        label: "com.rigelmansid.dshflick.managed-lifecycle",
        qos: .utility
    )
    private static var parentTimer: Timer?

    static func startIfNeeded() {
        guard isManaged else { return }
        startStdinWatcher()
        startParentWatcher()
    }

    // MARK: - stdin EOF

    private static func startStdinWatcher() {
        readerQueue.async {
            while true {
                let data = FileHandle.standardInput.availableData
                if data.isEmpty {
                    // EOF: the DSH Host process closed the pipe or died.
                    break
                }
                // Reserved for future one-line commands; for now commands flow
                // over the bridge API instead of stdin.
            }
            DispatchQueue.main.async {
                terminateBecause("stdin closed")
            }
        }
    }

    // MARK: - Parent PID

    private static func startParentWatcher() {
        let originalParent = getppid()
        DispatchQueue.main.async {
            parentTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                let currentParent = getppid()
                if currentParent == 1 || currentParent != originalParent {
                    terminateBecause("parent process exited")
                }
            }
        }
    }

    private static func terminateBecause(_ reason: String) {
        guard NSApp != nil else { return }
        let line = "[DSHFlick] managed lifecycle: \(reason); terminating\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        NSApp.terminate(nil)
    }
}
