import AppKit

/// Small red count badge overlaid on the menu bar status item.
///
/// Kept as a subview instead of a tinted template image so it works in both
/// light and dark menu bars and can show the pending count.
final class ApprovalBadgeView: NSView {
    var count: Int = 0 {
        didSet {
            isHidden = count <= 0
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let diameter = min(bounds.width, bounds.height)
        let circle = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: circle).fill()

        let label = count > 9 ? "9+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: count > 9 ? 6 : 7, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: circle.midX - size.width / 2,
                y: circle.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }
}
