import AppKit
import os
import SwiftUI

/// Lightweight menu bar surface used when DSH launches the app as a managed
/// sidecar (`--managed --native-menu`).
///
/// It deliberately does not embed the DSH web UI: the main window already owns
/// the conversation surface. This controller owns the status item, the compact
/// native panel, recent-session data from the DSH plugin, and the actions that
/// are forwarded to the DSH page through the plugin bridge.
final class NativeMenuController: NSObject, DSHFlickUI, NSPopoverDelegate {
    private static let logger = Logger(subsystem: "com.rigelmansid.dshflick", category: "native-menu")
    private static let debugEnabled = CommandLine.arguments.contains("--show-native-panel")
        || CommandLine.arguments.contains("--debug-ui")

    private static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let line = "[NativeMenu] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - DSHFlickUI

    var onPanelWillShow: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onOpenDesktop: (() -> Void)?

    // MARK: - State

    private let managed: Bool
    private let model = NativePanelModel()
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var hostingController: NSHostingController<NativePanelView>!

    private var hotKey: GlobalHotKey?
    private var escapeKeyMonitor: Any?
    private var anchorWindow: NSWindow?
    private var contextMenu: NSMenu?
    private var lastPopoverCloseDate = Date.distantPast
    private var bridgeGeneration = 0
    private var approvalsGeneration = 0
    private var approvalsInFlight = false
    private var approvalTimer: Timer?
    private var badgeView: ApprovalBadgeView?
    private var lastAutoOpenedApprovalIDs: Set<String> = []
    private var activateOnNextShow = true

    // MARK: - Lifecycle

    init(managed: Bool) {
        self.managed = managed
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        model.isManaged = managed
        configureStatusItem()
        configurePopover()
        configureGlobalHotKey()
        configureEscapeKeyMonitor()
        startApprovalPolling()
        render(.connecting)
        Self.debug("init: managed=\(managed) statusVisible=\(statusItem.isVisible) button=\(statusItem.button != nil) image=\(statusItem.button?.image != nil) window=\(String(describing: statusItem.button?.window))")

        if CommandLine.arguments.contains("--show-native-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.togglePanelOnMain()
            }
        }
    }

    deinit {
        approvalTimer?.invalidate()
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
        anchorWindow?.orderOut(nil)
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

        let badge = ApprovalBadgeView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 11),
            badge.heightAnchor.constraint(equalToConstant: 11),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 1),
            badge.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
        ])
        badgeView = badge
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
        popover.delegate = self
        popover.contentSize = NSSize(width: 344, height: 430)

        let root = NativePanelView(
            model: model,
            onOpenDesktop: { [weak self] in self?.openDesktop() },
            onNewSession: { [weak self] in self?.newSession() },
            onOpenRecent: { [weak self] id in self?.openRecent(id) },
            onApprovalAnswer: { [weak self] approval, decision in
                self?.answerApproval(approval, decision: decision)
            },
            onApprovalDetails: { [weak self] approval in
                self?.openApprovalDetails(approval)
            },
            onReconnect: { [weak self] in self?.reconnect() },
            onAbout: { [weak self] in self?.showAbout() },
            onHide: { [weak self] in self?.hideIcon() }
        )
        hostingController = NSHostingController(rootView: root)
        hostingController.view.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 344, height: 430)
        )
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 344, height: 430)
    }

    func togglePanel() {
        DispatchQueue.main.async { [weak self] in
            self?.togglePanelOnMain()
        }
    }

    func hidePanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func togglePanelOnMain() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if Date().timeIntervalSince(lastPopoverCloseDate) < 0.25 {
            return
        }
        showPanel()
    }

    private func showPanel(activating: Bool = true) {
        guard !popover.isShown, statusItem.button != nil else {
            Self.debug("showPanel: skipped shown=\(popover.isShown) button=\(statusItem.button != nil)")
            return
        }
        activateOnNextShow = activating
        popover.behavior = activating ? .transient : .semitransient
        updatePanelSize()
        onPanelWillShow?()
        refreshBridge()
        refreshApprovals()
        if activating {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let anchor = popoverAnchorRect() {
            Self.debug("showPanel: anchor=\(anchor)")
            presentPopover(relativeToScreenRect: anchor)
        } else if let button = statusItem.button {
            Self.debug("showPanel: fallback to status button")
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
        Self.debug("showPanel: after show isShown=\(popover.isShown) window=\(String(describing: popover.contentViewController?.view.window)) activating=\(activating)")

        guard activating else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.popover.isShown else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Screen rectangle the popover should hang below.
    ///
    /// `NSStatusItem.button`'s window is remote-hosted on recent macOS releases,
    /// so its coordinates are unreliable on multi-display setups. The mouse
    /// position is the most reliable anchor for a real click; programmatic QA
    /// shows fall back to the status button rect and finally the top-right of
    /// the main screen.
    private func popoverAnchorRect() -> NSRect? {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        if let screen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           mouse.y >= screen.visibleFrame.maxY - 2 {
            return NSRect(x: mouse.x - 11, y: mouse.y - 1, width: 22, height: 1)
        }

        if let button = statusItem.button, let window = button.window {
            let screenRect = window.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            if screenRect.width > 0,
               let screen = screens.first(where: { $0.frame.intersects(screenRect) }),
               screen.frame.contains(NSPoint(x: screenRect.midX, y: screenRect.midY)) {
                return screenRect
            }
        }

        let mouseScreen = screens.first(where: { $0.frame.contains(mouse) })
        guard let targetScreen = mouseScreen ?? NSScreen.main else { return nil }
        let menuBarHeight = max(targetScreen.frame.maxY - targetScreen.visibleFrame.maxY, 24)
        return NSRect(
            x: targetScreen.frame.maxX - 120,
            y: targetScreen.frame.maxY - menuBarHeight,
            width: 22,
            height: menuBarHeight
        )
    }

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
            popover.show(
                relativeTo: statusItem.button?.bounds ?? .zero,
                of: statusItem.button ?? NSView(),
                preferredEdge: .minY
            )
            return
        }
        popover.show(
            relativeTo: contentView.bounds,
            of: contentView,
            preferredEdge: .minY
        )
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        guard activateOnNextShow else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
        lastPopoverCloseDate = Date()
    }

    // MARK: - Keyboard

    private func configureEscapeKeyMonitor() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.popover.isShown else { return event }
            self.popover.performClose(nil)
            return nil
        }
    }

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

    // MARK: - DSHFlickUI state

    func setState(_ state: DSHAppState) {
        DispatchQueue.main.async { [weak self] in
            self?.render(state)
        }
    }

    private func render(_ newState: DSHAppState) {
        model.state = newState
        Self.debug("render: \(newState)")
        if case .connected = newState {
            refreshBridge()
            refreshApprovals()
        } else {
            approvalsGeneration += 1
            model.pendingApprovals = []
            model.answeringApprovalIDs = []
            updateApprovalBadge()
            updatePanelSize()
        }
        updateStatusTooltip()
    }

    /// Update the status-item tooltip with connection state plus pending count.
    private func updateStatusTooltip() {
        guard let button = statusItem.button else { return }
        let base: String
        switch model.state {
        case .connecting:
            button.appearsDisabled = false
            base = NativeL10n.tooltipConnecting
        case .connected(let connection):
            button.appearsDisabled = false
            base = NativeL10n.tooltipConnected(port: connection.port)
        case .offline(let error):
            button.appearsDisabled = true
            base = NativeL10n.tooltipOffline(error.errorDescription ?? NativeL10n.offline)
        }
        let count = model.pendingApprovals.count
        button.toolTip = count > 0 ? base + " " + NativeL10n.pendingApprovalsTooltip(count) : base
    }

    // MARK: - Bridge data

    /// Fetch bridge status and recent sessions for the current connection.
    private func refreshBridge() {
        guard let connection = model.connection else {
            bridgeGeneration += 1
            model.bridgeReady = false
            model.recentSessions = []
            model.loadingRecent = false
            return
        }

        bridgeGeneration += 1
        let generation = bridgeGeneration
        model.loadingRecent = true

        let api = BridgeAPI(connection: connection)
        Task {
            do {
                let ping = try await api.ping()
                let items = ping.ok ? try await api.recent(limit: 5) : []
                let sessions = items.map { item in
                    NativeRecentSession(
                        id: item.id,
                        title: Self.displayTitle(item.title),
                        detail: item.detail,
                        createdAt: Self.date(from: item.createdAt)
                    )
                }
                await MainActor.run {
                    guard generation == self.bridgeGeneration else { return }
                    self.model.bridgeReady = ping.ok
                    self.model.recentSessions = sessions
                    self.model.loadingRecent = false
                    if ping.ok {
                        self.refreshApprovals()
                    }
                }
            } catch {
                await MainActor.run {
                    guard generation == self.bridgeGeneration else { return }
                    self.model.bridgeReady = false
                    self.model.recentSessions = []
                    self.model.loadingRecent = false
                }
            }
        }
    }

    private static func displayTitle(_ title: String?) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NativeL10n.untitledSession
        }
        return title
    }

    private static func date(from value: Double?) -> Date? {
        guard let value else { return nil }
        // DSH headers use millisecond epoch; accept seconds too.
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Approvals

    private func startApprovalPolling() {
        approvalTimer?.invalidate()
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.refreshApprovals()
        }
        RunLoop.main.add(timer, forMode: .common)
        approvalTimer = timer
    }

    private func refreshApprovals() {
        guard let connection = model.connection, model.bridgeReady, !approvalsInFlight else {
            return
        }
        approvalsInFlight = true
        approvalsGeneration += 1
        let generation = approvalsGeneration
        let port = connection.port

        Task {
            do {
                let result = try await BridgeAPI(connection: connection).approvals()
                await MainActor.run {
                    guard generation == self.approvalsGeneration,
                          self.model.connection?.port == port
                    else {
                        self.approvalsInFlight = false
                        return
                    }
                    self.approvalsInFlight = false
                    self.applyApprovals(result.items, autoOpen: result.autoOpen)
                }
            } catch {
                await MainActor.run {
                    self.approvalsInFlight = false
                }
            }
        }
    }

    private func applyApprovals(_ items: [BridgeApprovalItem], autoOpen: Bool) {
        let mapped = items.map(NativePendingApproval.init)
        let previousIDs = Set(model.pendingApprovals.map(\.id))
        let currentIDs = Set(mapped.map(\.id))
        let newIDs = currentIDs.subtracting(previousIDs)

        model.pendingApprovals = mapped
        model.autoOpenApprovals = autoOpen
        model.answeringApprovalIDs.formIntersection(currentIDs)
        updateApprovalBadge()
        updatePanelSize()

        if mapped.isEmpty {
            lastAutoOpenedApprovalIDs.removeAll()
        }

        guard autoOpen,
              !newIDs.isEmpty,
              !popover.isShown,
              !newIDs.isSubset(of: lastAutoOpenedApprovalIDs),
              !DSHDesktop.hasVisibleWindow
        else { return }

        lastAutoOpenedApprovalIDs.formUnion(currentIDs)
        // Approval pop-ups are interactive: activating the accessory app makes
        // the panel key so the first click on Allow/Reject is honored.
        showPanel(activating: true)
    }

    private func updateApprovalBadge() {
        badgeView?.count = model.pendingApprovals.count
        updateStatusTooltip()
    }

    private func updatePanelSize() {
        let size = NSSize(width: 344, height: model.panelHeight)
        if abs(popover.contentSize.height - size.height) > 0.5 {
            popover.contentSize = size
        }
        if hostingController.view.frame.size != size {
            hostingController.view.frame = NSRect(origin: .zero, size: size)
        }
    }

    private func answerApproval(_ approval: NativePendingApproval, decision: NativeApprovalDecision) {
        guard !model.answeringApprovalIDs.contains(approval.id) else { return }
        guard let connection = model.connection, model.bridgeReady else {
            showBridgeUnavailableAlert()
            return
        }

        model.answeringApprovalIDs.insert(approval.id)
        let decisionValue = decision == .allow ? "allowed-once" : "rejected"
        Task {
            do {
                try await BridgeAPI(connection: connection).answerApproval(
                    key: approval.approvalKey,
                    decision: decisionValue,
                    clientId: approval.clientId
                )
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.model.answeringApprovalIDs.remove(approval.id)
                        self?.refreshApprovals()
                    }
                }
            } catch {
                await MainActor.run {
                    self.model.answeringApprovalIDs.remove(approval.id)
                    if let apiError = error as? BridgeAPIError, case .http(409) = apiError {
                        self.refreshApprovals()
                        return
                    }
                    self.showError(error.localizedDescription)
                    self.refreshApprovals()
                }
            }
        }
    }

    private func openApprovalDetails(_ approval: NativePendingApproval) {
        openRecent(approval.sessionId)
    }

    // MARK: - Actions

    private func openDesktop() {
        if DSHDesktop.isRunning {
            _ = DSHDesktop.activateOrLaunch()
        } else {
            onOpenDesktop?()
        }
        popover.performClose(nil)
    }

    private func newSession() {
        DSHDesktop.activateOrLaunch()
        guard let connection = model.connection, model.bridgeReady else {
            showBridgeUnavailableAlert()
            return
        }
        Task {
            do {
                try await BridgeAPI(connection: connection).send(action: "new-session")
                await MainActor.run {
                    self.popover.performClose(nil)
                }
            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func openRecent(_ sessionId: String) {
        DSHDesktop.activateOrLaunch()
        guard let connection = model.connection, model.bridgeReady else {
            showBridgeUnavailableAlert()
            return
        }
        Task {
            do {
                try await BridgeAPI(connection: connection).send(
                    action: "open-session",
                    sessionId: sessionId
                )
                await MainActor.run {
                    self.popover.performClose(nil)
                }
            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func reconnect() {
        onReconnect?()
        refreshBridge()
        refreshApprovals()
        if !popover.isShown {
            showPanel()
        }
    }

    private func hideIcon() {
        // Exit 0 tells the DSH plugin this was a deliberate user action, so it
        // does not respawn the icon during this DSH run.
        NSApp.terminate(nil)
    }

    private func showBridgeUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = NativeL10n.bridgeNotReadyTitle
        alert.informativeText = NativeL10n.bridgeNotReadyBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: NativeL10n.ok)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = NativeL10n.actionFailedTitle
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: NativeL10n.ok)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DSH Flick \(model.version)"
        alert.informativeText = String(
            format: NativeL10n.aboutBody,
            managed ? NativeL10n.modePlugin : NativeL10n.modeStandalone,
            model.statusLabel,
            model.statusDetail,
            model.bridgeReady ? NativeL10n.bridgeConnected : NativeL10n.bridgeDisconnected
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: NativeL10n.ok)
        if let icon = NSApp.applicationIconImage {
            alert.icon = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Context menu

    @objc private func showContextMenu() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        }
        let menu = buildContextMenu()
        contextMenu = menu
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
        contextMenu = nil
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: NativeL10n.openMainWindow,
            action: #selector(menuOpenDesktop),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let newItem = NSMenuItem(
            title: NativeL10n.menuNewSession,
            action: #selector(menuNewSession),
            keyEquivalent: "n"
        )
        newItem.keyEquivalentModifierMask = [.command]
        newItem.target = self
        newItem.isEnabled = model.canUseBridge
        menu.addItem(newItem)

        let recentItem = NSMenuItem(title: NativeL10n.menuRecentSessions, action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if model.recentSessions.isEmpty {
            let empty = NSMenuItem(title: NativeL10n.menuNoRecentSessions, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for session in model.recentSessions {
                let item = NSMenuItem(
                    title: session.title,
                    action: #selector(menuOpenRecent(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                item.toolTip = session.subtitle
                recentMenu.addItem(item)
            }
        }
        recentItem.submenu = recentMenu
        recentItem.isEnabled = !model.recentSessions.isEmpty
        menu.addItem(recentItem)

        menu.addItem(.separator())

        let reconnectItem = NSMenuItem(
            title: NativeL10n.reconnect,
            action: #selector(menuReconnect),
            keyEquivalent: ""
        )
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: NativeL10n.menuAbout,
            action: #selector(menuAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let hideItem = NSMenuItem(
            title: managed ? NativeL10n.menuHideIcon : NativeL10n.menuQuit,
            action: #selector(menuHide),
            keyEquivalent: "q"
        )
        hideItem.keyEquivalentModifierMask = [.command]
        hideItem.target = self
        menu.addItem(hideItem)

        return menu
    }

    @objc private func menuOpenDesktop() {
        openDesktop()
    }

    @objc private func menuNewSession() {
        newSession()
    }

    @objc private func menuOpenRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openRecent(id)
    }

    @objc private func menuReconnect() {
        reconnect()
    }

    @objc private func menuAbout() {
        showAbout()
    }

    @objc private func menuHide() {
        hideIcon()
    }
}
