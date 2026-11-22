import AppKit
import QuartzCore

// MARK: - Bundled artwork

/// Loads artwork that ships in the app bundle's `Contents/Resources`.
///
/// The brand assets (`MenuIcon.png`, `MenuIcon@2x.png`, `MenuIcon@3x.png`) are
/// produced by the build workstream. When they are missing — for example when
/// running the loose `.build/DSHFlick` executable during development — every
/// caller degrades gracefully to an SF Symbol.
enum BundleArtwork {
    private static let statusBarPointSize = NSSize(width: 18, height: 18)

    /// 18pt template image assembled from the 1x/2x/3x menu bar PNGs.
    static func statusBarIcon() -> NSImage? {
        let image = NSImage(size: statusBarPointSize)
        var addedRepresentation = false
        for suffix in ["@3x", "@2x", ""] {
            guard
                let url = Bundle.main.url(forResource: "MenuIcon\(suffix)", withExtension: "png"),
                let data = try? Data(contentsOf: url),
                let representation = NSBitmapImageRep(data: data)
            else { continue }
            representation.size = statusBarPointSize
            image.addRepresentation(representation)
            addedRepresentation = true
        }
        guard addedRepresentation else { return nil }
        image.isTemplate = true
        return image
    }

    /// Large template version of the menu bar mark for the offline empty state.
    static func largeIcon(pointSize: CGFloat) -> NSImage? {
        for suffix in ["@3x", "@2x", ""] {
            guard
                let url = Bundle.main.url(forResource: "MenuIcon\(suffix)", withExtension: "png"),
                let data = try? Data(contentsOf: url),
                let representation = NSBitmapImageRep(data: data)
            else { continue }
            let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
            representation.size = image.size
            image.addRepresentation(representation)
            image.isTemplate = true
            return image
        }
        return nil
    }

    /// Template SF Symbol image at the requested point size.
    static func symbol(name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "DeepSeek Harness")?
                .withSymbolConfiguration(configuration)
        else { return nil }
        image.isTemplate = true
        return image
    }
}

// MARK: - Status dot

/// Small colored dot in the panel header that mirrors the connection state.
final class StatusDotView: NSView {
    private var fillColor: NSColor = .systemGray

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: 9).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.backgroundColor = fillColor.cgColor
    }

    func update(for state: DSHAppState) {
        switch state {
        case .connected:
            fillColor = .systemGreen
            stopPulsing()
        case .connecting:
            fillColor = .systemOrange
            startPulsing()
        case .offline:
            fillColor = .systemRed
            stopPulsing()
        }
        layer?.backgroundColor = fillColor.cgColor
        needsLayout = true
    }

    private func startPulsing() {
        guard layer?.animation(forKey: "pulse") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.35
        animation.duration = 0.75
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer?.add(animation, forKey: "pulse")
    }

    private func stopPulsing() {
        layer?.removeAnimation(forKey: "pulse")
        layer?.opacity = 1
    }
}

// MARK: - Icon button

/// Borderless SF Symbol button with a hover highlight and a pointing-hand cursor.
final class IconButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    init(symbol: String, tooltip: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = BundleArtwork.symbol(name: symbol, pointSize: 13, weight: .medium)
        contentTintColor = .secondaryLabelColor
        self.toolTip = tooltip
        self.target = target
        self.action = action
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        contentTintColor = hovered ? .labelColor : .secondaryLabelColor
        layer?.backgroundColor = hovered ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
    }
}

// MARK: - Separator

/// One-pixel hairline that follows the current appearance.
final class SeparatorView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Toast

/// Small transient message shown over the content area (e.g. when the
/// "new chat" button cannot be located inside the web UI).
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor

        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: labelSize.width + 24, height: labelSize.height + 12)
    }

    func flash(_ message: String, duration: TimeInterval = 2.2) {
        hideWorkItem?.cancel()
        label.stringValue = message
        invalidateIntrinsicContentSize()
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.isHidden = true
            })
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
}

// MARK: - Connecting state

/// Spinner + copy shown while discovery runs.
final class ConnectingStateView: NSView {
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let titleLabel = NSTextField(labelWithString: "正在连接 DeepSeek Harness…")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let hintLabel = NSTextField(labelWithString: "正在查找本机 DSH 服务")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center

        let stack = NSStackView(views: [spinner, titleLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(14, after: spinner)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Offline state

/// Native empty state shown when discovery could not reach the DSH web server.
final class OfflineStateView: NSView {
    var onOpenDesktop: (() -> Void)?
    var onRetry: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "打开 DeepSeek Harness 后会自动连接")
    private let launchButton = NSButton(title: "启动 DeepSeek Harness", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.image = BundleArtwork.largeIcon(pointSize: 64)
            ?? BundleArtwork.symbol(name: "bubble.left.and.text.bubble.right", pointSize: 54)
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.preferredMaxLayoutWidth = 300
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center

        launchButton.target = self
        launchButton.action = #selector(launchClicked)
        launchButton.bezelStyle = .rounded
        launchButton.controlSize = .large
        launchButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        launchButton.keyEquivalent = "\r"

        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .large
        retryButton.font = .systemFont(ofSize: 12.5)

        let buttonRow = NSStackView(views: [launchButton, retryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [iconView, titleLabel, hintLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: iconView)
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(20, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 20),
        ])
    }

    func configure(error: DSHDiscoveryError) {
        titleLabel.stringValue = error.errorDescription ?? "未连接 DeepSeek Harness"
        launchButton.isHidden = !error.isFixableByLaunchingDesktop
    }

    @objc private func launchClicked() {
        onOpenDesktop?()
    }

    @objc private func retryClicked() {
        onRetry?()
    }
}
