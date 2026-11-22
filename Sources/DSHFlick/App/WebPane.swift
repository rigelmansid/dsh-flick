import AppKit
import WebKit
import os

/// Owns the `WKWebView` that renders the DeepSeek Harness web UI and replays
/// the desktop app's signed loopback cookie into WebKit's cookie store.
///
/// The DSH web server authenticates each request with an authority-bound signed
/// cookie; the Electron desktop app already holds one for `127.0.0.1:<port>`.
/// We inject that cookie into the persistent default data store (so the web UI
/// keeps its `localStorage` sessions between panel opens) and load the origin.
/// If the page still reports an unauthorized state, we fall back to writing
/// `document.cookie` on the current origin document and reloading once.
final class WebPane: NSObject {
    private static let logger = Logger(subsystem: "com.rigelmansid.dshflick", category: "web")

    /// The DSH desktop app hosts its web server on loopback only.
    private static let dshHost = "127.0.0.1"

    let webView: WKWebView

    private var connection: DSHConnection?
    private var loadedSignature: String?
    private var didAttemptDocumentCookieFallback = false
    private var didReloadAfterProcessTermination = false
    private var lastHTTPStatusCode: Int?

    override init() {
        let configuration = WKWebViewConfiguration()
        // Persistent store: the DSH UI keeps its current session/workspace in
        // localStorage, so a non-persistent store would lose UI state on every
        // panel open.
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        // Avoid a white flash before the DSH UI paints its own dark surface.
        webView.underPageBackgroundColor = .clear
        self.webView = webView

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Whether the web view already committed a page (used to decide whether a
    /// "new chat" click should wait for the first load).
    var isPageLoaded: Bool {
        webView.url != nil
    }

    // MARK: - Loading

    /// Load the DSH web UI for `connection`.
    ///
    /// - Parameter force: reload even when the same connection is already
    ///   displaying a page. Without forcing, repeated `.connected` states for
    ///   an unchanged cookie/port are no-ops, which avoids flicker.
    func load(connection: DSHConnection, force: Bool = false) {
        let signature = "\(connection.port)|\(connection.cookieName)|\(connection.cookieValue)"
        if !force, loadedSignature == signature, webView.url != nil {
            Self.logger.debug("already loaded port \(connection.port, privacy: .public); skipping reload")
            return
        }

        self.connection = connection
        loadedSignature = signature
        didAttemptDocumentCookieFallback = false
        didReloadAfterProcessTermination = false
        lastHTTPStatusCode = nil

        guard let cookie = Self.makeCookie(for: connection) else {
            Self.logger.error("could not build auth cookie for port \(connection.port, privacy: .public)")
            loadBaseURL()
            return
        }

        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                Self.logger.info("auth cookie injected via cookieStore (port \(connection.port, privacy: .public))")
                self.loadBaseURL()
            }
        }
    }

    /// Reload the current page, or re-run the authenticated load when nothing
    /// has been committed yet.
    func reload() {
        guard let connection else { return }
        if webView.url == nil {
            load(connection: connection, force: true)
            return
        }
        didReloadAfterProcessTermination = false
        webView.reload()
    }

    /// Move keyboard focus into the web view so typing works immediately.
    func focus() {
        guard let window = webView.window else { return }
        if !window.isKeyWindow {
            window.makeKey()
        }
        window.makeFirstResponder(webView)
    }

    private func loadBaseURL() {
        guard let connection else { return }
        var request = URLRequest(url: connection.baseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 25
        Self.logger.info("loading DSH web UI on port \(connection.port, privacy: .public)")
        webView.load(request)
    }

    private static func makeCookie(for connection: DSHConnection) -> HTTPCookie? {
        // SameSite/HttpOnly are not required: the server only parses the raw
        // Cookie header. The cookie must be bound to the loopback authority.
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: connection.cookieName,
            .value: connection.cookieValue,
            .domain: dshHost,
            .path: "/",
        ]
        if connection.isCookieValid {
            properties[.expires] = connection.cookieExpiresAt
        }
        return HTTPCookie(properties: properties)
    }

    // MARK: - Cookie fallback

    /// Last-resort fallback: write the cookie through the origin document and
    /// reload once. Only used when the cookie store injection did not stick.
    private func applyDocumentCookieFallback(reason: String) {
        guard let connection, !didAttemptDocumentCookieFallback else { return }
        didAttemptDocumentCookieFallback = true

        let cookieString = "\(connection.cookieName)=\(connection.cookieValue); path=/; max-age=2592000"
        let script = "document.cookie = \(Self.javaScriptStringLiteral(cookieString));"
        Self.logger.notice(
            "authentication fallback via documentCookie (reason: \(reason, privacy: .public), port: \(connection.port, privacy: .public))"
        )
        webView.evaluateJavaScript(script) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    Self.logger.error("document.cookie fallback failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.webView.reload()
            }
        }
    }

    private static func javaScriptStringLiteral(_ string: String) -> String {
        var escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    // MARK: - New chat

    /// Click the DSH UI's "new chat" affordance.
    ///
    /// - Returns: The clicked element's label when one was found, `nil` when the
    ///   page does not expose a matching control (the caller beeps and shows an
    ///   inline hint).
    @MainActor
    func clickNewChat() async -> String? {
        if let label = await clickElement(script: Self.findNewChatScript) {
            Self.logger.info("clicked new chat element: \(label, privacy: .public)")
            return label
        }
        // A collapsed sidebar may hide the control; try to expand it once.
        if await clickElement(script: Self.expandSidebarScript) != nil {
            Self.logger.info("clicked sidebar expand control; retrying new chat lookup")
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let label = await clickElement(script: Self.findNewChatScript) {
                Self.logger.info("clicked new chat element after expanding sidebar: \(label, privacy: .public)")
                return label
            }
        }
        return nil
    }

    @MainActor
    private func clickElement(script: String) async -> String? {
        guard webView.url != nil else { return nil }
        let result = await evaluateJavaScript(script)
        if let label = result as? String, !label.isEmpty {
            return label
        }
        return nil
    }

    @MainActor
    private func evaluateJavaScript(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    Self.logger.error("evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Injected scripts

    private static let findNewChatScript = #"""
    (function () {
      try {
        var exactPattern = /^(新建会话|新建对话|新对话|新会话|new chat|new session|new conversation)$/i;
        var phrasePattern = /(新建会话|新建对话|新对话|新会话|new chat|new session)/i;
        var loosePattern = /(新建|新对话|新会话|new chat|new session)/i;
        var excludePattern = /(终端|工作区|运行命令|terminal|workspace|settings|设置|重命名|删除|rename|delete)/i;
        var candidates = Array.prototype.slice.call(
          document.querySelectorAll('button,[role="button"],a')
        );
        function normalize(text) {
          return (text || '').replace(/\s+/g, ' ').trim();
        }
        function isVisible(element) {
          if (!element || !element.getBoundingClientRect) { return false; }
          var rect = element.getBoundingClientRect();
          if (rect.width < 2 || rect.height < 2) { return false; }
          var style = window.getComputedStyle(element);
          if (!style) { return false; }
          if (style.visibility === 'hidden' || style.display === 'none') { return false; }
          if (parseFloat(style.opacity) === 0) { return false; }
          return true;
        }
        function describe(element) {
          return {
            aria: normalize(element.getAttribute('aria-label')),
            title: normalize(element.getAttribute('title')),
            text: normalize(element.innerText || element.textContent)
          };
        }
        function isExternalLink(element) {
          if (element.tagName !== 'A') { return false; }
          var href = element.getAttribute('href') || '';
          return /^https?:/i.test(href) && href.indexOf(location.host) === -1;
        }
        function tryClick(element, label) {
          if (element.disabled) { return null; }
          try { element.scrollIntoView({ block: 'nearest' }); } catch (error) {}
          try { element.click(); } catch (error) { return null; }
          return label.slice(0, 120);
        }
        function firstLabel(descriptor) {
          return descriptor.aria || descriptor.title || descriptor.text;
        }
        // The narrow (<520pt) DSH layout renders the sidebar collapsed, so the
        // real "新建会话" button is present in the DOM but visibility:hidden.
        // A programmatic click() still triggers its handler, so exact aria
        // labels are clicked regardless of visibility; fuzzy matches are only
        // considered for visible controls to avoid clicking the wrong thing.
        var exactMatch = function (descriptor) {
          if (exactPattern.test(descriptor.aria)) { return descriptor.aria; }
          if (exactPattern.test(descriptor.title)) { return descriptor.title; }
          if (exactPattern.test(descriptor.text)) { return descriptor.text; }
          return null;
        };
        var phraseMatch = function (descriptor) {
          var combined = [descriptor.aria, descriptor.title, descriptor.text].filter(Boolean).join(' | ');
          if (phrasePattern.test(combined) && !excludePattern.test(combined)) {
            return firstLabel(descriptor);
          }
          return null;
        };
        var looseMatch = function (descriptor) {
          var combined = [descriptor.aria, descriptor.title, descriptor.text].filter(Boolean).join(' | ');
          if (loosePattern.test(combined) && !excludePattern.test(combined)) {
            return firstLabel(descriptor);
          }
          return null;
        };
        var passes = [
          { matcher: exactMatch, requireVisible: false },
          { matcher: phraseMatch, requireVisible: true },
          { matcher: looseMatch, requireVisible: true }
        ];
        for (var pass = 0; pass < passes.length; pass++) {
          var spec = passes[pass];
          for (var index = 0; index < candidates.length; index++) {
            var element = candidates[index];
            if (spec.requireVisible && !isVisible(element)) { continue; }
            if (isExternalLink(element)) { continue; }
            var label = spec.matcher(describe(element));
            if (!label) { continue; }
            var clicked = tryClick(element, label);
            if (clicked) { return clicked; }
          }
        }
        return null;
      } catch (error) {
        return null;
      }
    })()
    """#

    private static let expandSidebarScript = #"""
    (function () {
      try {
        var newChatPattern = /(新建|新对话|新会话|new chat|new session)/i;
        var expandPattern = /(展开|展开侧边栏|打开侧边栏|expand|show sidebar|open sidebar|toggle sidebar|sidebar|侧边栏)/i;
        var candidates = Array.prototype.slice.call(
          document.querySelectorAll('button,[role="button"],a')
        );
        function isVisible(element) {
          if (!element || !element.getBoundingClientRect) { return false; }
          var rect = element.getBoundingClientRect();
          if (rect.width < 2 || rect.height < 2) { return false; }
          var style = window.getComputedStyle(element);
          if (!style) { return false; }
          if (style.visibility === 'hidden' || style.display === 'none') { return false; }
          if (parseFloat(style.opacity) === 0) { return false; }
          return true;
        }
        for (var index = 0; index < candidates.length; index++) {
          var element = candidates[index];
          if (!isVisible(element) || element.disabled) { continue; }
          var aria = element.getAttribute('aria-label') || '';
          var title = element.getAttribute('title') || '';
          var text = (element.innerText || element.textContent || '')
            .replace(/\s+/g, ' ').trim();
          var label = (aria + ' ' + title + ' ' + text).replace(/\s+/g, ' ').trim();
          if (!expandPattern.test(label) || newChatPattern.test(label)) { continue; }
          try { element.click(); } catch (error) { continue; }
          return (aria || title || text || 'expand').slice(0, 120);
        }
        return null;
      } catch (error) {
        return null;
      }
    })()
    """#
}

// MARK: - WKNavigationDelegate

extension WebPane: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "http", "https":
            if isDSHURL(url) {
                decisionHandler(.allow)
            } else {
                // External links open in the user's default browser.
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        case "about", "data", "blob", "javascript":
            decisionHandler(.allow)
        case "mailto", "tel":
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        default:
            decisionHandler(.allow)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            lastHTTPStatusCode = response.statusCode
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let status = lastHTTPStatusCode ?? -1
        Self.logger.info(
            "didFinish \(webView.url?.absoluteString ?? "-", privacy: .public) status=\(status, privacy: .public)"
        )
        if status == 401 {
            applyDocumentCookieFallback(reason: "http-401")
            return
        }
        // Belt and braces: inspect the rendered text for an auth error page.
        let script = "(function(){var b=document.body;return b ? (b.innerText||'').slice(0,1200) : '';})()"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let text = (result as? String) ?? ""
            let lowercased = text.lowercased()
            let unauthorized = lowercased.contains("authentication required")
                || lowercased.contains("unauthorized")
                || (lowercased.contains("401") && text.count < 400)
            if unauthorized, !self.didAttemptDocumentCookieFallback {
                self.applyDocumentCookieFallback(reason: "page-text")
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Self.logger.error("navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Self.logger.error("provisional navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !didReloadAfterProcessTermination else {
            Self.logger.error("web content process terminated again; not reloading")
            return
        }
        didReloadAfterProcessTermination = true
        Self.logger.notice("web content process terminated; reloading once")
        reload()
    }

    private func isDSHURL(_ url: URL) -> Bool {
        guard let connection else { return false }
        return url.host == Self.dshHost
            && (url.port ?? 80) == connection.port
    }
}

// MARK: - WKUIDelegate

extension WebPane: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target=_blank / window.open(): never spawn a second web view, open
        // the destination outside the panel instead.
        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" || scheme == "mailto" {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "DeepSeek Harness"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "DeepSeek Harness"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
