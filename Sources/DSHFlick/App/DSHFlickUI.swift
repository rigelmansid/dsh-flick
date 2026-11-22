import AppKit

/// The AppKit surface — status item, popover panel, header, web view and
/// offline placeholder — that `AppController` drives.
///
/// Implemented by `DSHFlickController`. The concrete class owns all layout and
/// view code; `AppController` owns the connection state machine only.
protocol DSHFlickUI: AnyObject {
    /// Invoked right before the popover becomes visible. The controller uses
    /// this to refresh stale discovery results before the panel is shown.
    var onPanelWillShow: (() -> Void)? { get set }
    /// Invoked by the "重新连接" menu item.
    var onReconnect: (() -> Void)? { get set }
    /// Invoked by the "打开 DeepSeek Harness 主窗口" menu item.
    var onOpenDesktop: (() -> Void)? { get set }

    /// Render a new connection state. Implementations must hop to the main
    /// thread internally; the controller may call this from any thread.
    func setState(_ state: DSHAppState)

    /// Show the popover when hidden, hide it when visible.
    func togglePanel()

    /// Hide the popover if visible.
    func hidePanel()
}
