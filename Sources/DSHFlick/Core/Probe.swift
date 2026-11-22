import AppKit
import Foundation
import WebKit

/// Headless diagnostics: discover the live server, load the authenticated web
/// UI offscreen, dump useful DOM facts and write a PNG snapshot.
///
/// `main.swift` calls `run(snapshotPath:)` synchronously on the main thread.
/// The probe owns an `NSApplication` instance and pumps the main run loop
/// manually instead of calling `NSApp.run()`, so the CLI can exit by itself.
enum Probe {
    // MARK: - Tunables

    private enum Config {
        static let contentSize = NSSize(width: 460, height: 680)
        /// Keep the diagnostics window far outside any screen.
        static let offscreenOrigin = NSPoint(x: -4000, y: -4000)
        static let discoveryTimeout: TimeInterval = 10
        static let navigationTimeout: TimeInterval = 25
        /// Roughly how long the web UI needs to boot and render after load.
        static let bootSettleDelay: TimeInterval = 2.5
        static let scriptTimeout: TimeInterval = 10
        static let snapshotTimeout: TimeInterval = 15
    }

    // MARK: - Entry point

    /// Runs the probe on the main thread (it owns an NSApplication run loop)
    /// and returns a process exit code.
    static func run(snapshotPath: String) -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        switch blockingDiscovery() {
        case .failure(let error):
            printJSON([
                "ok": false,
                "code": error.diagnostic,
                "message": error.errorDescription ?? "unknown error",
            ])
            return 1
        case .success(let connection):
            return runAuthenticatedProbe(connection: connection, snapshotPath: snapshotPath)
        }
    }

    // MARK: - Discovery bridge

    /// Runs the async discovery to completion by pumping the run loop.
    ///
    /// The main thread is deliberately never hard-blocked on a semaphore: the
    /// probe later needs the same run loop for WebKit callbacks, and any
    /// main-queue hop would deadlock a blocking wait.
    private static func blockingDiscovery() -> Result<DSHConnection, DSHDiscoveryError> {
        var result: Result<DSHConnection, DSHDiscoveryError> = .failure(.timedOut)
        var finished = false
        Task.detached(priority: .userInitiated) {
            let discovery = await DSHDiscovery.shared.discover(timeout: Config.discoveryTimeout)
            result = discovery
            finished = true
        }
        let completed = waitUntil(timeout: Config.discoveryTimeout + 10) { finished }
        if !completed {
            log("discovery did not finish within the probe deadline")
            return .failure(.timedOut)
        }
        return result
    }

    // MARK: - Authenticated load

    private static func runAuthenticatedProbe(connection: DSHConnection, snapshotPath: String) -> Int32 {
        log("discovered DSH web server on port \(connection.port)")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: Config.contentSize),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: NSRect(origin: Config.offscreenOrigin, size: Config.contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.backgroundColor = .white
        window.contentView = webView
        window.orderFrontRegardless()

        defer {
            teardown(webView: webView, window: window)
        }

        // 1. Replay the desktop session cookie into the WKWebView cookie store.
        let injected = injectCookie(connection, into: configuration.websiteDataStore.httpCookieStore)
        if !injected {
            log("cookie store injection reported a problem; continuing")
        }
        pump(0.1)

        // 2. Load the origin and wait for the boot document.
        var authPath = "cookieStore"
        var load = loadPage(webView: webView, url: connection.baseURL)
        pump(Config.bootSettleDelay)
        var page = readPageInfo(webView)

        // 3. Fallback: a 401 page still has a writable document.cookie.
        if isAuthFailure(page: page, statusCode: load.statusCode) {
            log("cookie-store session rejected (status \(load.statusCode.map(String.init) ?? "nil")); trying document.cookie")
            let cookieAssignment = "document.cookie = "
                + jsStringLiteral("\(connection.cookieName)=\(connection.cookieValue); path=/; SameSite=Lax")
                + "; true;"
            _ = evaluateJS(webView, cookieAssignment, timeout: 3)
            pump(0.1)
            load = loadPage(webView: webView, url: connection.baseURL)
            pump(Config.bootSettleDelay)
            page = readPageInfo(webView)
            authPath = "documentCookie"
        }

        if isAuthFailure(page: page, statusCode: load.statusCode) {
            printJSON([
                "ok": false,
                "code": "auth-failed",
                "message": "DSH 服务拒绝了回放的登录态（可打开主窗口后重试）",
                "port": connection.port,
                "authPath": authPath,
                "status": load.statusCode ?? 0,
            ])
            return 1
        }

        // A page can briefly be empty right after load; retry once.
        if page == nil {
            pump(2)
            page = readPageInfo(webView)
        }
        guard let finalPage = page else {
            printJSON([
                "ok": false,
                "code": "page-unavailable",
                "message": "无法读取 DSH Web UI 页面内容",
                "port": connection.port,
                "authPath": authPath,
            ])
            return 1
        }

        // 4. Collect DOM facts for the build/verification workstream.
        var dom = readDOMFacts(webView)
        if (dom?["buttonCount"] as? Int ?? 0) == 0 {
            // Single-page app may still be mounting; give it a few more seconds.
            for _ in 0..<8 {
                pump(0.5)
                dom = readDOMFacts(webView)
                if (dom?["buttonCount"] as? Int ?? 0) > 0 { break }
            }
        }

        // 5. Render a PNG of the web content.
        let snapshotWritten = captureSnapshot(webView: webView, to: snapshotPath)
        if !snapshotWritten {
            log("failed to write snapshot to \(snapshotPath)")
        }

        let domObject: Any = dom ?? ["error": "dom-extraction-failed"]
        // Secondary confirmation that we rendered the DSH UI and not an error page.
        let titleMatches = finalPage.title == DSHDesktop.displayName
        var payload: [String: Any] = [
            "ok": true,
            "port": connection.port,
            "authPath": authPath,
            "title": finalPage.title,
            "titleMatches": titleMatches,
            "href": finalPage.href,
            "readyState": finalPage.readyState,
            "bodyText": finalPage.bodyText,
            "status": load.statusCode ?? 0,
            "dom": domObject,
            "snapshot": snapshotPath,
            "snapshotWritten": snapshotWritten,
        ]
        if !snapshotWritten {
            payload["ok"] = false
            payload["code"] = "snapshot-failed"
            printJSON(payload)
            return 1
        }
        printJSON(payload)
        return 0
    }

    // MARK: - Page model

    private struct PageInfo {
        let href: String
        let title: String
        let readyState: String
        let bodyText: String
    }

    private struct PageLoadResult {
        let statusCode: Int?
        let finished: Bool
        let failure: String?
    }

    /// Navigation delegate that records the HTTP status of the main frame and
    /// signals when the navigation settles.
    private final class NavigationObserver: NSObject, WKNavigationDelegate {
        private(set) var isDone = false
        private(set) var lastStatusCode: Int?
        private(set) var failureDescription: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame,
               let httpResponse = navigationResponse.response as? HTTPURLResponse {
                lastStatusCode = httpResponse.statusCode
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isDone = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failureDescription = error.localizedDescription
            isDone = true
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            failureDescription = error.localizedDescription
            isDone = true
        }
    }

    private static func loadPage(webView: WKWebView, url: URL) -> PageLoadResult {
        let observer = NavigationObserver()
        webView.navigationDelegate = observer
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
        let settled = waitUntil(timeout: Config.navigationTimeout) { observer.isDone }
        if !settled {
            log("navigation did not settle within \(Int(Config.navigationTimeout))s")
        }
        return PageLoadResult(
            statusCode: observer.lastStatusCode,
            finished: settled,
            failure: observer.failureDescription
        )
    }

    private static func readPageInfo(_ webView: WKWebView) -> PageInfo? {
        let script = """
        (function() {
            try {
                var body = document.body ? (document.body.innerText || '') : '';
                return JSON.stringify({
                    href: String(location.href || ''),
                    title: String(document.title || ''),
                    readyState: String(document.readyState || ''),
                    bodyText: body.slice(0, 400)
                });
            } catch (error) {
                return JSON.stringify({ href: '', title: '', readyState: '', bodyText: '' });
            }
        })();
        """
        guard let raw = evaluateJS(webView, script, timeout: Config.scriptTimeout) as? String,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return PageInfo(
            href: object["href"] as? String ?? "",
            title: object["title"] as? String ?? "",
            readyState: object["readyState"] as? String ?? "",
            bodyText: object["bodyText"] as? String ?? ""
        )
    }

    /// A page is considered an auth failure when the server answered 401/403 or
    /// its visible text is the DSH "authentication required" notice.
    private static func isAuthFailure(page: PageInfo?, statusCode: Int?) -> Bool {
        if statusCode == 401 || statusCode == 403 { return true }
        guard let page else { return false }
        let body = page.bodyText.lowercased()
        return body.contains("authentication required") || body.contains("401 unauthorized")
    }

    private static func readDOMFacts(_ webView: WKWebView) -> [String: Any]? {
        let script = """
        (function() {
            try {
                var buttons = [];
                var all = document.querySelectorAll('button');
                var limit = Math.min(all.length, 80);
                for (var i = 0; i < limit; i++) {
                    var element = all[i];
                    var text = (element.innerText || element.getAttribute('aria-label') || element.getAttribute('title') || '').trim();
                    if (text.length > 80) { text = text.slice(0, 80); }
                    buttons.push({
                        text: text,
                        aria: (element.getAttribute('aria-label') || '').slice(0, 80),
                        title: (element.getAttribute('title') || '').slice(0, 80),
                        disabled: !!element.disabled
                    });
                }
                var keys = [];
                try {
                    for (var k = 0; k < localStorage.length; k++) { keys.push(localStorage.key(k)); }
                } catch (ignored) {}
                var body = document.body ? (document.body.innerText || '') : '';
                return JSON.stringify({
                    href: String(location.href || ''),
                    title: String(document.title || ''),
                    readyState: String(document.readyState || ''),
                    bodyText: body.slice(0, 400),
                    buttons: buttons,
                    buttonCount: all.length,
                    localStorageKeys: keys
                });
            } catch (error) {
                return JSON.stringify({ error: String(error) });
            }
        })();
        """
        guard let raw = evaluateJS(webView, script, timeout: Config.scriptTimeout) as? String,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return object
    }

    // MARK: - Cookie injection

    private static func injectCookie(_ connection: DSHConnection, into store: WKHTTPCookieStore) -> Bool {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: "127.0.0.1",
            .path: "/",
            .name: connection.cookieName,
            .value: connection.cookieValue,
            .originURL: connection.baseURL,
        ]
        properties[.expires] = connection.cookieExpiresAt
        guard let cookie = HTTPCookie(properties: properties) else {
            log("HTTPCookie could not be constructed from the discovered session")
            return false
        }
        var completed = false
        store.setCookie(cookie) {
            completed = true
        }
        let injected = waitUntil(timeout: 5) { completed }
        if !injected { log("cookie store injection timed out") }
        return injected
    }

    // MARK: - Snapshot

    private static func captureSnapshot(webView: WKWebView, to path: String) -> Bool {
        guard webView.bounds.width > 1, webView.bounds.height > 1 else { return false }

        var capturedImage: NSImage?
        var snapshotDone = false
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.afterScreenUpdates = true
        webView.takeSnapshot(with: snapshotConfiguration) { image, error in
            if let error { log("takeSnapshot failed: \(error.localizedDescription)") }
            capturedImage = image
            snapshotDone = true
        }
        _ = waitUntil(timeout: Config.snapshotTimeout) { snapshotDone }

        var finalImage = capturedImage
        if finalImage == nil {
            // Last resort for WebKit snapshot failures: draw the view hierarchy.
            finalImage = renderViewToImage(webView)
        }
        guard let image = finalImage, let png = pngData(from: image) else {
            log("no bitmap available for snapshot")
            return false
        }
        do {
            let fileURL = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: fileURL, options: .atomic)
            return true
        } catch {
            log("writing snapshot failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func renderViewToImage(_ view: NSView) -> NSImage? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }

    // MARK: - Teardown

    private static func teardown(webView: WKWebView, window: NSWindow) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    // MARK: - Run loop pumping

    /// Pumps the main run loop for `duration` so WebKit callbacks are serviced.
    private static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.05, remaining)))
        }
    }

    @discardableResult
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.05, remaining)))
        }
        return true
    }

    // MARK: - JavaScript helpers

    private static func evaluateJS(_ webView: WKWebView, _ script: String, timeout: TimeInterval) -> Any? {
        var output: Any?
        var completed = false
        webView.evaluateJavaScript(script) { value, error in
            if let error { log("evaluateJavaScript failed: \(error.localizedDescription)") }
            output = value
            completed = true
        }
        _ = waitUntil(timeout: timeout) { completed }
        return output
    }

    /// Escapes an arbitrary string for safe embedding in a JS string literal.
    private static func jsStringLiteral(_ value: String) -> String {
        var escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        escaped = escaped.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    // MARK: - Output

    private static func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            print("{\"ok\":false,\"code\":\"json-encoding-failed\"}")
            return
        }
        print(text)
    }

    /// Diagnostics go to stderr so stdout stays a single JSON document.
    private static func log(_ message: String) {
        let line = "[probe] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
