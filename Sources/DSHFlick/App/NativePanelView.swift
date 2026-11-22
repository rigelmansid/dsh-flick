import SwiftUI

/// Compact native panel shown from the menu bar icon in plugin mode.
///
/// It intentionally contains no WebView: the DSH window already owns the full
/// conversation UI. This panel is the "quick entry" surface: connection state,
/// open the main window, start a session, and jump to a recent session.
struct NativePanelView: View {
    @ObservedObject var model: NativePanelModel

    let onOpenDesktop: () -> Void
    let onNewSession: () -> Void
    let onOpenRecent: (String) -> Void
    let onApprovalAnswer: (NativePendingApproval, NativeApprovalDecision) -> Void
    let onApprovalDetails: (NativePendingApproval) -> Void
    let onReconnect: () -> Void
    let onAbout: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            primaryActions
            if !model.pendingApprovals.isEmpty {
                approvalSection
            }
            recentSection
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: 344, height: model.panelHeight)
        .background(Color.clear)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            if let icon = BundleArtwork.statusBarIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("DeepSeek Harness")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.statusDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.statusLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .connected: return .green
        case .connecting: return .orange
        case .offline: return .red
        }
    }

    // MARK: - Primary actions

    private var primaryActions: some View {
        VStack(spacing: 8) {
            Button(action: onOpenDesktop) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app")
                    Text(NativeL10n.openApp)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: onNewSession) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.bubble")
                    Text(NativeL10n.newSession)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!model.canUseBridge)
        }
    }

    // MARK: - Pending approvals

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(NativeL10n.pendingApprovals)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(model.pendingApprovals.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
                Spacer()
            }

            ScrollView {
                VStack(spacing: NativePanelModel.approvalCardSpacing) {
                    ForEach(model.pendingApprovals) { approval in
                        ApprovalRow(
                            approval: approval,
                            isAnswering: model.answeringApprovalIDs.contains(approval.id),
                            onAllow: { onApprovalAnswer(approval, .allow) },
                            onReject: { onApprovalAnswer(approval, .reject) },
                            onDetails: { onApprovalDetails(approval) }
                        )
                    }
                }
            }
            .frame(height: model.approvalListHeight)
        }
    }

    // MARK: - Recent sessions

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(NativeL10n.recentSessions)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(NativeL10n.refreshHelp)
            }

            Group {
                if model.loadingRecent {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                } else if !model.bridgeReady {
                    Text(bridgeHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                } else if model.recentSessions.isEmpty {
                    Text(NativeL10n.noRecentSessions)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.recentSessions) { session in
                                RecentSessionRow(session: session) {
                                    onOpenRecent(session.id)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }
        }
    }

    private var bridgeHint: String {
        if model.connection == nil {
            return NativeL10n.waitingForConnection
        }
        return NativeL10n.bridgeUnavailableHint
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button(NativeL10n.reconnect, action: onReconnect)
            Button(NativeL10n.about, action: onAbout)
            Spacer()
            Button(model.isManaged ? NativeL10n.hideIcon : NativeL10n.quit, action: onHide)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Approval row

enum NativeApprovalDecision {
    case allow
    case reject
}

private struct ApprovalRow: View {
    let approval: NativePendingApproval
    let isAnswering: Bool
    let onAllow: () -> Void
    let onReject: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(NativeL10n.approvalFrom(approval.title))
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if approval.isSubagent {
                    Text(NativeL10n.subagentTag)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Spacer(minLength: 4)
                Text(approval.toolLabel)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                if !approval.relativeTime.isEmpty {
                    Text(approval.relativeTime)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }

            Text(approval.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(approval.detail)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button(NativeL10n.reject, action: onReject)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAnswering)
                Button(NativeL10n.allowOnce, action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isAnswering)
                Spacer(minLength: 4)
                if isAnswering {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: onDetails) {
                    HStack(spacing: 2) {
                        Text(NativeL10n.viewDetails)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(height: NativePanelModel.approvalCardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 0.6)
        )
    }
}

// MARK: - Recent row

private struct RecentSessionRow: View {
    let session: NativeRecentSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        Text(session.subtitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !session.relativeTime.isEmpty {
                            Text("·")
                            Text(session.relativeTime)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
