import AppKit
import Combine

// MARK: - Native panel state

struct NativePendingApproval: Identifiable, Equatable {
    let id: String
    let approvalKey: String
    let clientId: String?
    let sessionId: String
    let sessionTitle: String?
    let cwd: String?
    let toolName: String?
    let reason: String?
    let displayReason: [String: String]?
    let isSubagent: Bool
    let createdAt: Date?

    init(item: BridgeApprovalItem) {
        approvalKey = item.key
        id = "\(item.clientId ?? "local"):\(item.key)"
        clientId = item.clientId
        sessionId = item.sessionId
        sessionTitle = item.sessionTitle
        cwd = item.cwd
        toolName = item.toolName
        reason = item.reason
        displayReason = item.displayReason
        isSubagent = item.isSubagent ?? false
        createdAt = NativePendingApproval.date(from: item.firstSeenAt ?? item.createdAt)
    }

    private static func date(from value: Double?) -> Date? {
        guard let value else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    var title: String {
        if let sessionTitle, !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sessionTitle
        }
        if let cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return NativeL10n.untitledSession
    }

    var detail: String {
        if let displayReason {
            let preferred = NativeL10n.isChinese ? "zh" : "en"
            if let text = displayReason[preferred], !text.isEmpty { return text }
            if let text = displayReason["en"], !text.isEmpty { return text }
            if let text = displayReason.values.first, !text.isEmpty { return text }
        }
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return reason
        }
        return NativeL10n.approvalFallback(tool: toolName)
    }

    var toolLabel: String {
        guard let toolName, !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NativeL10n.approvalToolFallback
        }
        return toolName
    }

    var relativeTime: String {
        guard let createdAt else { return "" }
        return NativePanelModel.relativeFormatter.localizedString(
            for: createdAt,
            relativeTo: Date()
        )
    }
}

struct NativeRecentSession: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
    let createdAt: Date?

    var subtitle: String {
        if let detail, !detail.isEmpty { return detail }
        return NativeL10n.recentSession
    }

    var relativeTime: String {
        guard let createdAt else { return "" }
        return NativePanelModel.relativeFormatter.localizedString(
            for: createdAt,
            relativeTo: Date()
        )
    }
}

/// Observable view state for the native panel.
///
/// `NativeMenuController` owns this and is the only writer; SwiftUI observes
/// it. All updates happen on the main thread.
final class NativePanelModel: ObservableObject {
    @Published var state: DSHAppState = .connecting
    @Published var recentSessions: [NativeRecentSession] = []
    @Published var pendingApprovals: [NativePendingApproval] = []
    @Published var autoOpenApprovals = true
    @Published var answeringApprovalIDs: Set<String> = []
    @Published var bridgeReady = false
    @Published var loadingRecent = false
    @Published var isManaged = false

    // MARK: - Panel geometry

    static let basePanelHeight: CGFloat = 430
    static let maxPanelHeight: CGFloat = 760
    static let approvalHeaderHeight: CGFloat = 18
    static let approvalCardHeight: CGFloat = 108
    static let approvalCardSpacing: CGFloat = 8
    static let approvalSectionGap: CGFloat = 12

    var approvalListHeight: CGFloat {
        guard !pendingApprovals.isEmpty else { return 0 }
        let count = CGFloat(pendingApprovals.count)
        let desired = count * Self.approvalCardHeight
            + max(0, count - 1) * Self.approvalCardSpacing
        let available = Self.maxPanelHeight - Self.basePanelHeight
            - Self.approvalSectionGap - Self.approvalHeaderHeight - 6
        return min(desired, max(0, available))
    }

    var panelHeight: CGFloat {
        guard !pendingApprovals.isEmpty else { return Self.basePanelHeight }
        let wanted = Self.basePanelHeight + Self.approvalSectionGap
            + Self.approvalHeaderHeight + 6 + approvalListHeight
        return min(wanted, Self.maxPanelHeight)
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale.current
        return formatter
    }()

    var connection: DSHConnection? {
        if case .connected(let connection) = state { return connection }
        return nil
    }

    var statusLabel: String {
        switch state {
        case .connecting: return NativeL10n.connecting
        case .connected: return NativeL10n.connected
        case .offline: return NativeL10n.offline
        }
    }

    var statusDetail: String {
        switch state {
        case .connecting:
            return NativeL10n.discovering
        case .connected(let connection):
            return "127.0.0.1:\(connection.port)"
        case .offline(let error):
            return error.errorDescription ?? NativeL10n.offline
        }
    }

    var canUseBridge: Bool {
        bridgeReady && connection != nil
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
