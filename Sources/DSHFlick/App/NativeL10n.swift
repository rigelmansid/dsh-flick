import Foundation

/// Minimal localization for the plugin-mode native panel.
///
/// The standalone full panel follows DSH's own Web UI language; the native
/// panel follows the macOS preferred language. Only the two languages shipped
/// in the plugin manifest are covered here.
enum NativeL10n {
    static let isChinese: Bool = {
        // The plugin Host passes the DSH profile's locale preference so the
        // panel matches the DSH UI, even when the Electron process itself runs
        // with a different AppleLanguages environment.
        if let override = ProcessInfo.processInfo.environment["DSH_FLICK_LANGUAGE"],
           !override.isEmpty {
            return override.lowercased().hasPrefix("zh")
        }
        let language = Locale.preferredLanguages.first?.lowercased() ?? ""
        return language.hasPrefix("zh")
    }()

    static func text(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }

    static var connecting: String { text("连接中", "Connecting") }
    static var connected: String { text("已连接", "Connected") }
    static var offline: String { text("未连接", "Offline") }
    static var discovering: String { text("正在发现本地服务…", "Discovering local service…") }

    static var openApp: String { text("打开 DeepSeek Harness", "Open DeepSeek Harness") }
    static var newSession: String { text("新建会话", "New session") }
    static var recentSessions: String { text("最近会话", "Recent sessions") }
    static var noRecentSessions: String { text("暂无最近会话", "No recent sessions") }
    static var pendingApprovals: String { text("待审批", "Approvals") }
    static var allowOnce: String { text("允许一次", "Allow once") }
    static var reject: String { text("拒绝", "Reject") }
    static var viewDetails: String { text("查看详情", "View details") }
    static var subagentTag: String { text("子代理", "Subagent") }
    static var approvalToolFallback: String { text("工具", "Tool") }
    static var approvalSubmitFailed: String { text("审批提交失败", "Could not submit approval") }
    static var approvalStale: String {
        text("这条审批已经结束，列表已刷新。", "This approval is no longer pending. The list has been refreshed.")
    }

    static func approvalFrom(_ session: String) -> String {
        text("来自：\(session)", "From: \(session)")
    }

    static func approvalFallback(tool: String?) -> String {
        let name = tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return text("有工具请求权限", "A tool requests permission")
        }
        return text("工具“\(name)”请求权限", "Tool “\(name)” requests permission")
    }

    static func pendingApprovalsTooltip(_ count: Int) -> String {
        text("· \(count) 个待审批", "· \(count) pending approval\(count == 1 ? "" : "s")")
    }

    static var refreshHelp: String { text("刷新连接和最近会话", "Refresh connection and recent sessions") }
    static var reconnect: String { text("重新连接", "Reconnect") }
    static var about: String { text("关于", "About") }
    static var hideIcon: String { text("隐藏图标", "Hide icon") }
    static var quit: String { text("退出", "Quit") }
    static var untitledSession: String { text("未命名会话", "Untitled session") }
    static var recentSession: String { text("最近会话", "Recent session") }

    static var waitingForConnection: String {
        text("等待连接 DeepSeek Harness…", "Waiting for DeepSeek Harness…")
    }

    static var bridgeUnavailableHint: String {
        text(
            "DSH 插件桥接未连接；最近会话和新会话暂不可用，可直接在 DSH 主窗口中操作。",
            "The DSH plugin bridge is not connected. Recent sessions and new sessions are unavailable; use the DSH window instead."
        )
    }

    static var bridgeNotReadyTitle: String { text("DSH 插件桥接尚未连接", "DSH plugin bridge is not ready") }
    static var bridgeNotReadyBody: String {
        text(
            "菜单栏图标已经连上了 DeepSeek Harness，但插件页面桥接还没有就绪。请稍等片刻后重试，或直接打开 DSH 主窗口操作。",
            "The menu bar icon is connected to DeepSeek Harness, but the plugin page bridge is not ready yet. Try again in a moment, or use the DSH window."
        )
    }
    static var actionFailedTitle: String { text("操作失败", "Action failed") }
    static var ok: String { text("好", "OK") }

    static var openMainWindow: String { text("打开 DeepSeek Harness 主窗口", "Open DeepSeek Harness") }
    static var menuRecentSessions: String { text("最近会话", "Recent sessions") }
    static var menuNoRecentSessions: String { text("暂无最近会话", "No recent sessions") }
    static var menuAbout: String { text("关于 DSH Flick", "About DSH Flick") }
    static var menuHideIcon: String { text("隐藏图标", "Hide icon") }
    static var menuQuit: String { text("退出 DSH Flick", "Quit DSH Flick") }
    static var menuNewSession: String { text("新建会话", "New session") }

    static var aboutBody: String {
        text(
            """
            DeepSeek Harness 的 macOS 菜单栏快捷入口。

            模式：%@
            状态：%@ · %@
            桥接：%@

            快捷键：⌥⌘D 显示 / 隐藏面板
            插件模式下，关闭 DeepSeek Harness 会同时结束本图标。
            """,
            """
            A macOS menu bar shortcut for DeepSeek Harness.

            Mode: %@
            Status: %@ · %@
            Bridge: %@

            Shortcut: ⌥⌘D toggles the panel.
            In plugin mode, quitting DeepSeek Harness also removes this icon.
            """
        )
    }

    static var tooltipConnecting: String { text("DeepSeek Harness · 正在连接", "DeepSeek Harness · connecting") }
    static func tooltipConnected(port: Int) -> String {
        text("DeepSeek Harness · 已连接（端口 \(port)）", "DeepSeek Harness · connected (port \(port))")
    }
    static func tooltipOffline(_ reason: String) -> String {
        text("DeepSeek Harness · \(reason)", "DeepSeek Harness · \(reason)")
    }

    static var modePlugin: String { text("由 DSH 插件托管", "Managed by the DSH plugin") }
    static var modeStandalone: String { text("独立运行", "Standalone") }
    static var bridgeConnected: String { text("已连接", "Connected") }
    static var bridgeDisconnected: String { text("未连接", "Not connected") }
}
