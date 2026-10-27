import SwiftUI

// 额度页：按工具分列，整页可上下滚动
struct QuotaPageView: View {
    var columns: [AppColumn]
    // 面板宽度，用来判断卡片够不够宽把今日与七日并排放
    var panelWidth: Double = 520
    var onDetails: (UUID, Int) -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        ScrollView(.vertical) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.visible)
    }

    // 页面内容单独拆出来，便于离屏渲染自检
    @ViewBuilder
    var content: some View {
        if columns.isEmpty {
            empty
        } else {
            HStack(alignment: .top, spacing: Theme.columnSpacing) {
                ForEach(columns) { column in
                    UsageColumnView(column: column,
                                    maxMetrics: Int.max,
                                    inlineTotals: columnWidth >= 320,
                                    onDetails: { days in onDetails(column.id, days) })
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var columnWidth: Double {
        let count = Double(max(columns.count, 1))
        return (panelWidth - 28 - Theme.columnSpacing * (count - 1)) / count
    }

    private var empty: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
            Text(Loc.t("还没有启用的应用", "No application is enabled yet"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
            Button(Loc.t("打开设置", "Open Settings"), action: onOpenSettings)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }
}

// 会话页：列表整页可滚动，点开某个会话在同一页内看完整对话
struct SessionsPageView: View {
    var sessions: [AgentSession]
    var onDismiss: (AgentSession) -> Void
    var onClearFinished: () -> Void

    @State private var opened: AgentSession?

    var body: some View {
        Group {
            if let session = opened {
                ConversationView(session: session, onBack: { opened = nil })
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var list: some View {
        ScrollView(.vertical) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.visible)
    }

    @ViewBuilder
    var content: some View {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Text(sessions.isEmpty
                         ? Loc.t("没有正在进行的会话", "No active sessions")
                         : Loc.t("\(sessions.count) 个会话", "\(sessions.count) sessions"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                    if !sessions.isEmpty {
                        Button(Loc.t("清除已完成", "Clear finished"), action: onClearFinished)
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .padding(.bottom, 2)

                if sessions.isEmpty {
                    empty
                } else {
                    ForEach(sessions) { session in
                        SessionRow(session: session,
                                   onOpen: { opened = session },
                                   onDismiss: { onDismiss(session) })
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }

    private var empty: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.badge")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.25))
            Text(Loc.t("助手开始工作后，会话会出现在这里", "Sessions appear here once an assistant starts working"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }
}
