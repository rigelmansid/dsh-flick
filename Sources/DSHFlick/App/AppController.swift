import AppKit
import Foundation

/// Connection state machine shared by the menu bar surface and discovery.
///
/// Responsibilities:
/// * run discovery at launch, before the panel is shown, and on reconnects;
/// * react to the desktop app appearing or disappearing;
/// * launch/activate the desktop app and wait for its web server;
/// * never let a stale discovery result overwrite a newer one.
final class AppController {
    private let ui: DSHFlickUI
    private var state: DSHAppState = .connecting
    private var refreshGeneration = 0
    private var isRefreshing = false
    private var pollGeneration = 0

    init(ui: DSHFlickUI) {
        self.ui = ui
    }

    func start() {
        ui.onPanelWillShow = { [weak self] in
            DispatchQueue.main.async { self?.panelWillShow() }
        }
        ui.onReconnect = { [weak self] in
            DispatchQueue.main.async { self?.refresh(force: true) }
        }
        ui.onOpenDesktop = { [weak self] in
            DispatchQueue.main.async { self?.openDesktop() }
        }
        observeWorkspace()
        refresh(force: true)
    }

    // MARK: - Refresh

    /// Re-run discovery. Forced refreshes always start; non-forced refreshes
    /// are coalesced while one is already in flight.
    private func refresh(force: Bool) {
        if isRefreshing && !force { return }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        if case .connected = state {
            // Keep the current panel while re-checking a live connection.
        } else {
            state = .connecting
            ui.setState(.connecting)
        }
        Task.detached { [weak self] in
            let result = await DSHDiscovery.shared.discover()
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
                self.isRefreshing = false
                self.apply(result)
            }
        }
    }

    private func apply(_ result: Result<DSHConnection, DSHDiscoveryError>) {
        switch result {
        case .success(let connection):
            state = .connected(connection)
            ui.setState(.connected(connection))
        case .failure(let error):
            state = .offline(error)
            ui.setState(.offline(error))
        }
    }

    /// Called just before the popover shows: reconnect stale sessions, and
    /// otherwise simply surface the current state.
    private func panelWillShow() {
        switch state {
        case .connected(let connection):
            if Date().timeIntervalSince(connection.discoveredAt) > 30 {
                refresh(force: true)
            }
        case .connecting:
            break
        case .offline(let error):
            if error.isFixableByLaunchingDesktop {
                refresh(force: true)
            }
        }
    }

    // MARK: - Desktop app

    private func openDesktop() {
        // Invalidate any in-flight discovery before polling for the launched app.
        refreshGeneration += 1
        pollGeneration += 1
        let generation = pollGeneration
        guard DSHDesktop.activateOrLaunch() else {
            apply(.failure(.desktopNotRunning))
            return
        }
        state = .connecting
        ui.setState(.connecting)
        Task.detached { [weak self] in
            let result = await DSHDiscovery.shared.waitForConnection(timeout: 45, interval: 0.7)
            DispatchQueue.main.async {
                guard let self, generation == self.pollGeneration else { return }
                self.isRefreshing = false
                self.apply(result)
            }
        }
    }

    // MARK: - Desktop lifecycle observations

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.bundleIdentifier == DSHDesktop.bundleIdentifier
                else { return }
                self?.refresh(force: true)
            }
        }
    }
}
