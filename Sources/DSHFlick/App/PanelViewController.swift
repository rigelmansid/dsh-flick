import AppKit

/// Popover content: a compact header (status dot, title, subtitle, actions)
/// above a content area that switches between connecting, connected and
/// offline states.
final class PanelViewController: NSViewController {
    var onNewChat: (() -> Void)?
    var onReload: (() -> Void)?
    var onOpenDesktop: (() -> Void)?
    var onReconnect: (() -> Void)?

    /// The authenticated web view; the controller may ask it to reload or to
    /// click the "new chat" control even while the popover is hidden.
    let webPane = WebPane()

    private let statusDot = StatusDotView()
    private let titleLabel = NSTextField(labelWithString: "DeepSeek Harness")
    private let subtitleLabel = NSTextField(labelWithString: "正在连接…")
    private let contentContainer = NSView()
    private let connectingView = ConnectingStateView()
    private let offlineView = OfflineStateView()
    private let toastView = ToastView()

    init() {
        super.init(nibName: nil, bundle: nil)
        offlineView.onOpenDesktop = { [weak self] in self?.onOpenDesktop?() }
        offlineView.onRetry = { [weak self] in self?.onReconnect?() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        view = root
        buildLayout(in: root)
        render(.connecting)
    }

    private func buildLayout(in root: NSView) {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        statusDot.toolTip = "连接状态"

        let newChatButton = IconButton(
            symbol: "plus.bubble",
            tooltip: "新建对话",
            target: self,
            action: #selector(newChatClicked)
        )
        let reloadButton = IconButton(
            symbol: "arrow.clockwise",
            tooltip: "重新加载界面",
            target: self,
            action: #selector(reloadClicked)
        )
        let desktopButton = IconButton(
            symbol: "arrow.up.forward.app",
            tooltip: "在桌面打开 DeepSeek Harness",
            target: self,
            action: #selector(openDesktopClicked)
        )
        let buttonStack = NSStackView(views: [newChatButton, reloadButton, desktopButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 2
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(statusDot)
        header.addSubview(textStack)
        header.addSubview(buttonStack)
        root.addSubview(header)

        let separator = SeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)
        contentContainer.addSubview(webPane.webView)
        contentContainer.addSubview(connectingView)
        contentContainer.addSubview(offlineView)

        root.addSubview(toastView)

        let webView = webPane.webView
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),

            statusDot.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            statusDot.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 9),
            textStack.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 1),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -8),

            buttonStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            buttonStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            connectingView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            connectingView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            connectingView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            connectingView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            offlineView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            offlineView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            offlineView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            offlineView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            toastView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - State rendering

    /// Render a new connection state. Safe to call from any thread.
    func render(_ state: DSHAppState) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.render(state)
            }
            return
        }

        statusDot.update(for: state)
        switch state {
        case .connecting:
            subtitleLabel.stringValue = "正在连接…"
            webPane.webView.isHidden = true
            connectingView.isHidden = false
            offlineView.isHidden = true
        case .connected(let connection):
            subtitleLabel.stringValue = "端口 \(connection.port) · 已连接"
            connectingView.isHidden = true
            offlineView.isHidden = true
            webPane.webView.isHidden = false
            // `WebPane` ignores repeats of the same port/cookie, so state
            // refreshes do not reload (and do not flicker) the page.
            webPane.load(connection: connection)
        case .offline(let error):
            subtitleLabel.stringValue = "离线"
            offlineView.configure(error: error)
            webPane.webView.isHidden = true
            connectingView.isHidden = true
            offlineView.isHidden = false
        }
    }

    // MARK: - Focus and transient messages

    /// Move keyboard focus into the embedded web UI.
    func focusWebView() {
        webPane.focus()
    }

    /// Show a short-lived inline message over the content area.
    func flashToast(_ message: String) {
        toastView.flash(message)
    }

    // MARK: - Header actions

    @objc private func newChatClicked() {
        onNewChat?()
    }

    @objc private func reloadClicked() {
        onReload?()
    }

    @objc private func openDesktopClicked() {
        onOpenDesktop?()
    }
}
