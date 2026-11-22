import Darwin
import Foundation

/// One menu bar process at a time.
///
/// The standalone app and the plugin-managed app share the same bundle
/// identifier and the same status item slot, so a second instance must not
/// start: it would draw a duplicate icon. The lock is an advisory `flock` on a
/// per-user file; the descriptor stays open for the process lifetime and the
/// kernel releases the lock on exit.
enum InstanceLock {
    private static var fileDescriptor: Int32 = -1

    private static let debugEnabled = CommandLine.arguments.contains("--debug-ui")
        || CommandLine.arguments.contains("--show-native-panel")

    private static func debug(_ message: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("[InstanceLock] \(message)\n".utf8))
    }

    /// Try to become the single running instance.
    ///
    /// Returns `true` when the lock was acquired (or when the lock file could
    /// not be opened at all — failing open keeps a permissions accident from
    /// making the app unusable). Returns `false` when another live instance
    /// owns the lock.
    static func acquire() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DSH Flick", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            debug("createDirectory failed: \(error); failing open")
            return true
        }

        let path = directory.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            let code = errno
            debug("open(\(path)) failed: errno=\(code) \(String(cString: strerror(code))); failing open")
            return true
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            debug("flock(\(path)) failed: errno=\(code) \(String(cString: strerror(code)))")
            close(fd)
            return false
        }
        debug("acquired lock: path=\(path) fd=\(fd) pid=\(getpid())")

        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        fileDescriptor = fd
        return true
    }
}
