import AppKit
import os

/// The native menu bar surface for DSH Flick.
///
/// `AppController` owns the connection state machine and calls `setState(_:)`;
/// this class only renders that state and forwards user intents back through
/// the `onPanelWillShow` / `onReconnect` / `onOpenDesktop` callbacks.
final class DSHFlickController: NSObject, DSHFlickUI, NSPopoverDelegate {
    private static let logger = Logger(subsystem: "com.rigelmansid.dshflick", category: "menu")

    // MARK: - Temporary UI diagnostics
    //
    // Enabled only when the app is launched with --show-panel / --debug-ui so
    // the build/verify workstream can inspect why a programmatic panel show
    // did or did not work. Writes to /tmp/dshbar-ui-debug.log (and stderr).

    private static let debugEnabled: Bool = CommandLine.arguments.contains("--show-panel")
        || CommandLine.arguments.contains("--show-window")
        || CommandLine.arguments.contains("--debug-ui")

    /// Short state description safe for logs (never includes the cookie value).
    static func describe(_ state: DSHAppState) -> String {
        switch state {
        case .connecting: return "connecting"
        case .connected(let connection): return "connected(port: \(connection.port))"
        case .offline(let error): return "offline(\(error.diagnostic))"
        }
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let line = "[\(Date().timeIntervalSince1970)] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        let url = URL(fileURLWithPath: "/tmp/dshbar-ui-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - DSHFlickUI callbacks

    var onPanelWillShow: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onOpenDesktop: (() -> Void)?

    // MARK: - UI

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let panelController = PanelViewController()
    private var state: DSHAppState = .connecting
    private var hotKey: GlobalHotKey?
    private var escapeKeyMonitor: Any?
    private var contextMenu: NSMenu?
    private var focusWorkItem: DispatchWorkItem?
    private var lastPopoverCloseDate = Date.distantPast
    /// Invisible helper window used to anchor the popover at screen coordinates.
    private var anchorWindow: NSWindow?
    /// Debug-only QA window (see `showPanelInQAWindow`).
    private var qaWindow: NSWindow?
    private var qaPanelController: PanelViewController?

    // MARK: - Lifecycle

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
        configurePopover()
        configureGlobalHotKey()
        configureEscapeKeyMonitor()
        render(.connecting)
        if CommandLine.arguments.contains("--show-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showPanelInQAWindow()
            }
        }
    }

    deinit {
        focusWorkItem?.cancel()
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = BundleArtwork.statusBarIcon() ?? BundleArtwork.symbol(
            name: "bubble.left.and.text.bubble.right",
            pointSize: 15
        )
        button.imagePosition = .imageOnly
        button.appearsDisabled = false
        button.toolTip = "DeepSeek Harness"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        Self.debug("configureStatusItem: visible=\(statusItem.isVisible) window=\(String(describing: button.window))")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showContextMenu()
        } else {
            togglePanelOnMain()
        }
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 460, height: 660)
        popover.delegate = self

        panelController.onNewChat = { [weak self] in self?.newChatRequested() }
        panelController.onReload = { [weak self] in self?.reloadRequested() }
        panelController.onOpenDesktop = { [weak self] in self?.onOpenDesktop?() }
        panelController.onReconnect = { [weak self] in self?.onReconnect?() }

        popover.contentViewController = panelController
        // Force the view load so the web view starts loading in the background
        // before the user ever clicks the status item.
        _ = panelController.view
        // Assigning contentViewController makes NSPopover adopt the view
        // controller view's frame; a freshly loaded view has a zero frame, so
        // both the view frame and contentSize must be pinned explicitly.
        panelController.view.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 460, height: 660)
        )
        popover.contentSize = NSSize(width: 460, height: 660)
        Self.debug(
            "configurePopover: contentSize=\(popover.contentSize) panelViewFrame=\(panelController.view.frame) "
                + "viewWindow=\(String(describing: panelController.view.window))"
        )
    }

    /// Show the popover when hidden, hide it when visible.
    func togglePanel() {
        Self.debug("togglePanel() called, mainThread=\(Thread.isMainThread)")
        DispatchQueue.main.async { [weak self] in
            self?.togglePanelOnMain()
        }
    }

    /// Hide the popover if visible.
    func hidePanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func togglePanelOnMain() {
        Self.debug("togglePanelOnMain: popover.isShown=\(popover.isShown) lastClose=\(lastPopoverCloseDate.timeIntervalSince1970)")
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A transient popover swallows the outside click that dismisses it, but
        // if the click also reaches the status item we must not immediately
        // reopen the panel on the next click.
        if Date().timeIntervalSince(lastPopoverCloseDate) < 0.25 {
            return
        }
        showPanel()
    }

    /// The built-in/primary screen (origin at zero), which is what plain
    /// `screencapture` captures and where QA windows should appear.
    private static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first ?? NSScreen.main
    }

    private static func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let frame = window.frame
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    /// Anchor rectangle (screen coordinates) for the popover.
    ///
    /// `NSStatusItem.button`'s window can be remote-hosted on current macOS
    /// releases, in which case its frame/coordinates do not match the real menu
    /// bar position and `popover.show(relativeTo:of:button)` lands off-screen on
    /// multi-display setups. For a real click the mouse cursor is guaranteed to
    /// sit inside a menu bar, so that is the most reliable anchor; programmatic
    /// shows fall back to the status item's screen rect and finally to the top
    /// right of the main screen.
    private func popoverAnchorRect() -> NSRect? {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        if let screen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           mouse.y >= screen.visibleFrame.maxY - 2 {
            // Cursor is in a menu bar: anchor a 22pt-wide 1pt-high rect under it.
            Self.debug("popoverAnchorRect: using mouse anchor \(mouse) on screen \(screen.frame)")
            return NSRect(x: mouse.x - 11, y: mouse.y - 1, width: 22, height: 1)
        }

        if let button = statusItem.button, let window = button.window {
            let screenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if screenRect.width > 0,
               let screen = screens.first(where: { $0.frame.intersects(screenRect) }),
               screen.frame.contains(NSPoint(x: screenRect.midX, y: screenRect.midY)) {
                Self.debug("popoverAnchorRect: using status button screen rect \(screenRect)")
                return screenRect
            }
            Self.debug("popoverAnchorRect: rejected status button screen rect \(screenRect)")
        }

        // Prefer the screen the mouse is on (programmatic shows happen while the
        // user is looking at / working on that screen), then the AppKit main
        // screen, then the built-in primary screen.
        let mouseScreen = screens.first(where: { $0.frame.contains(mouse) })
        guard let targetScreen = mouseScreen ?? NSScreen.main ?? Self.primaryScreen() else { return nil }
        let menuBarHeight = max(targetScreen.frame.maxY - targetScreen.visibleFrame.maxY, 24)
        let fallback = NSRect(
            x: targetScreen.frame.maxX - 120,
            y: targetScreen.frame.maxY - menuBarHeight,
            width: 22,
            height: menuBarHeight
        )
        Self.debug("popoverAnchorRect: using fallback on screen \(targetScreen.frame) -> \(fallback)")
        return fallback
    }

    /// Position the popover using an invisible borderless helper window placed
    /// at `screenRect`.
    ///
    /// `NSPopover.show(relativeTo:of:preferredEdge:)` only accepts a view, and
    /// `NSStatusItem.button`'s window can be remote-hosted with coordinates that
    /// do not match the real menu bar (observed on multi-display macOS). A
    /// helper window gives a view whose screen frame we control exactly.
    private func presentPopover(relativeToScreenRect screenRect: NSRect) {
        anchorWindow?.orderOut(nil)
        let helper = NSWindow(
            contentRect: screenRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        helper.isOpaque = false
        helper.backgroundColor = .clear
        helper.hasShadow = false
        helper.ignoresMouseEvents = true
        helper.alphaValue = 0
        helper.level = .statusBar
        helper.orderFront(nil)
        anchorWindow = helper
        guard let contentView = helper.contentView else {
            Self.debug("presentPopover: helper window has no content view")
            popover.show(relativeTo: statusItem.button?.bounds ?? .zero, of: statusItem.button ?? NSView(), preferredEdge: .minY)
            return
        }
        Self.debug(
            "presentPopover: helperFrame=\(helper.frame) helperViewBounds=\(contentView.bounds) "
                + "helperWindowNumber=\(helper.windowNumber)"
        )
        popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }

    private func showPanel() {
        guard !popover.isShown else {
            Self.debug("showPanel: aborted, popover already shown")
            return
        }
        guard statusItem.button != nil else {
            Self.debug("showPanel: aborted, statusItem.button is nil")
            return
        }
        Self.debug(
            "showPanel: appActive=\(NSApp.isActive) screenCount=\(NSScreen.screens.count) "
                + "screens=\(NSScreen.screens.map { "\($0.frame) visible=\($0.visibleFrame)" }) "
                + "mainFrame=\(String(describing: NSScreen.main?.frame)) "
                + "mouse=\(NSEvent.mouseLocation) "
                + "buttonWindowFrame=\(String(describing: statusItem.button?.window?.frame)) "
                + "popoverWindowBefore=\(String(describing: popover.contentViewController?.view.window))"
        )
        // Let the controller refresh a stale discovery result before we render.
        onPanelWillShow?()
        NSApp.activate(ignoringOtherApps: true)
        Self.debug("showPanel: after activate appActive=\(NSApp.isActive)")

        if let anchor = popoverAnchorRect() {
            presentPopover(relativeToScreenRect: anchor)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        Self.debug(
            "showPanel: after show isShown=\(popover.isShown) "
                + "popoverViewFrame=\(panelController.view.frame) "
                + "popoverWindow=\(String(describing: popover.contentViewController?.view.window))"
        )
        scheduleWebViewFocus()

        for delay in [0.2, 0.7, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let window = self.popover.contentViewController?.view.window
                let frame = window?.frame
                let onAScreen = NSScreen.screens.contains { $0.frame.intersects(frame ?? .zero) }
                Self.debug(
                    "showPanel +\(delay)s: isShown=\(self.popover.isShown) appActive=\(NSApp.isActive) "
                        + "frame=\(String(describing: frame)) onAScreen=\(onAScreen) "
                        + "visible=\(window?.isVisible ?? false) windowNumber=\(window?.windowNumber ?? -1)"
                )
            }
        }
    }

    /// After the popover has appeared, make its window key and hand keyboard
    /// focus to the web view so the user can type immediately.
    private func scheduleWebViewFocus() {
        focusWorkItem?.cancel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.popover.isShown else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.popover.contentViewController?.view.window?.makeKey()
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.popover.isShown else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.popover.contentViewController?.view.window?.makeKey()
            self.panelController.focusWebView()
        }
        focusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        Self.debug("popoverDidShow")
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        Self.debug("popoverDidClose")
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
        lastPopoverCloseDate = Date()
        focusWorkItem?.cancel()
        focusWorkItem = nil
    }

    // MARK: - Keyboard

    private func configureEscapeKeyMonitor() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.popover.isShown else { return event }
            self.popover.performClose(nil)
            return nil
        }
    }

    // MARK: - Global hot key (⌥⌘D)

    private func configureGlobalHotKey() {
        let modifiers = GlobalHotKey.commandModifier | GlobalHotKey.optionModifier
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.keyCodeD, modifiers: modifiers) { [weak self] in
            DispatchQueue.main.async {
                self?.togglePanelOnMain()
            }
        }
        if hotKey == nil {
            Self.logger.error("could not register the global hot key ⌥⌘D")
        }
    }

    // MARK: - DSHFlickUI state rendering

    func setState(_ state: DSHAppState) {
        DispatchQueue.main.async { [weak self] in
            self?.render(state)
        }
    }

    private func render(_ newState: DSHAppState) {
        state = newState
        panelController.render(newState)
        qaPanelController?.render(newState)

        guard let button = statusItem.button else { return }
        switch newState {
        case .connecting:
            button.appearsDisabled = false
            button.toolTip = "DeepSeek Harness · 正在连接"
        case .connected(let connection):
            button.appearsDisabled = false
            button.toolTip = "DeepSeek Harness · 已连接（端口 \(connection.port)）"
        case .offline(let error):
            button.appearsDisabled = true
            button.toolTip = "DeepSeek Harness · \(error.errorDescription ?? "未连接")"
        }
    }

    // MARK: - QA window (debug only)

    /// Present the same panel content inside a regular window so the UI can be
    /// screenshot/inspected without clicking the status item or relying on
    /// popover placement on multi-display machines.
    ///
    /// Entry point for QA: launch the app with `--show-window` (handled inside
    /// this class) or call this method after `DSHFlickController` is created.
    func showPanelInQAWindow() {
        if qaWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "DSH Flick QA"
            window.isReleasedWhenClosed = false

            let panel = PanelViewController()
            panel.onNewChat = { [weak self] in self?.newChatRequested() }
            panel.onReload = { [weak self] in self?.reloadRequested() }
            panel.onOpenDesktop = { [weak self] in self?.onOpenDesktop?() }
            panel.onReconnect = { [weak self] in self?.onReconnect?() }
            window.contentViewController = panel
            window.setContentSize(NSSize(width: 460, height: 720))
            Self.center(window, on: Self.primaryScreen())

            qaPanelController = panel
            qaWindow = window
            panel.render(state)
        }
        qaWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.debug(
            "showPanelInQAWindow: state=\(Self.describe(state)) frame=\(String(describing: qaWindow?.frame)) "
                + "panelViewFrame=\(String(describing: qaPanelController?.view.frame))"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.qaPanelController?.focusWebView()
        }
    }

    // MARK: - Actions shared by header buttons and the context menu

    private func newChatRequested() {
        if !popover.isShown {
            showPanel()
        }
        let attempt: () -> Void = { [weak self] in
            guard let self else { return }
            let webPane = self.panelController.webPane
            Task { @MainActor in
                if let label = await webPane.clickNewChat() {
                    Self.logger.info("new chat triggered via label: \(label, privacy: .public)")
                } else {
                    NSSound.beep()
                    self.panelController.flashToast("未找到新建对话按钮，可在面板内操作")
                }
            }
        }
        if panelController.webPane.isPageLoaded {
            attempt()
        } else {
            // The web UI may still be loading; give it a moment before probing
            // for the new chat control.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: attempt)
        }
    }

    private func reloadRequested() {
        if case .connected = state {
            panelController.webPane.reload()
        } else {
            onReconnect?()
        }
    }

    // MARK: - Context menu

    @objc private func showContextMenu() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        }
        let menu = buildContextMenu()
        contextMenu = menu
        // Attaching the menu to the status item and performing its click lets
        // AppKit position the menu exactly like a system menu bar menu.
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
        contextMenu = nil
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let panelItem = NSMenuItem(
            title: popover.isShown ? "隐藏 DSH 面板" : "显示 DSH 面板",
            action: #selector(menuTogglePanel),
            keyEquivalent: "d"
        )
        panelItem.keyEquivalentModifierMask = [.command, .option]
        panelItem.target = self
        menu.addItem(panelItem)

        let newChatItem = NSMenuItem(
            title: "新建对话",
            action: #selector(menuNewChat),
            keyEquivalent: "n"
        )
        newChatItem.keyEquivalentModifierMask = [.command]
        newChatItem.target = self
        menu.addItem(newChatItem)

        menu.addItem(.separator())

        let desktopItem = NSMenuItem(
            title: "打开 DeepSeek Harness 主窗口",
            action: #selector(menuOpenDesktop),
            keyEquivalent: ""
        )
        desktopItem.target = self
        menu.addItem(desktopItem)

        let reconnectItem = NSMenuItem(
            title: "重新连接",
            action: #selector(menuReconnect),
            keyEquivalent: ""
        )
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        let reloadItem = NSMenuItem(
            title: "重新加载界面",
            action: #selector(menuReload),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        if LaunchAtLogin.isSupported {
            let loginItem = NSMenuItem(
                title: "开机自启",
                action: #selector(menuToggleLaunchAtLogin),
                keyEquivalent: ""
            )
            loginItem.target = self
            loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
            menu.addItem(loginItem)
            menu.addItem(.separator())
        } else {
            Self.logger.info("launch at login hidden: not running from an app bundle")
        }

        let aboutItem = NSMenuItem(
            title: "关于 DSH Flick",
            action: #selector(menuAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "退出 DSH Flick",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func menuTogglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    @objc private func menuNewChat() {
        newChatRequested()
    }

    @objc private func menuOpenDesktop() {
        onOpenDesktop?()
    }

    @objc private func menuReconnect() {
        onReconnect?()
        if !popover.isShown {
            showPanel()
        }
    }

    @objc private func menuReload() {
        reloadRequested()
    }

    @objc private func menuToggleLaunchAtLogin() {
        let enabling = !LaunchAtLogin.isEnabled
        do {
            try LaunchAtLogin.setEnabled(enabling)
        } catch {
            let alert = NSAlert()
            alert.messageText = enabling ? "无法开启开机自启" : "无法关闭开机自启"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func menuAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
        let alert = NSAlert()
        alert.messageText = "DSH Flick \(version)"
        alert.informativeText = """
        DeepSeek Harness 的菜单栏快捷入口。

        工作原理：在本机发现 DeepSeek Harness 的 Web 服务，并用其持久化的浏览器会话密钥生成本机签名 Cookie（只读、不上传），在菜单栏面板中内嵌显示其 Web 界面；不会修改 DSH 的安装。

        快捷键：⌥⌘D 显示 / 隐藏面板
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        if let icon = NSApp.applicationIconImage {
            alert.icon = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}
