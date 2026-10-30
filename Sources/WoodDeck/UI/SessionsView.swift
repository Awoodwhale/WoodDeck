import SwiftUI

// 收起形态上的会话提醒：助手图标 + 数量
struct SessionBadge: View {
    var count: Int
    var agent: AgentKind
    var scale: CGFloat

    var body: some View {
        HStack(spacing: 3 * scale) {
            Image(systemName: agent.symbol)
                .font(.system(size: 9.5 * scale, weight: .semibold))
                .foregroundStyle(agent.accent)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 9 * scale, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 5 * scale)
        .padding(.vertical, 2 * scale)
        .background(agent.accent.opacity(0.18), in: Capsule())
        .overlay(Capsule().stroke(agent.accent.opacity(0.35), lineWidth: 0.5))
    }
}

// AI 页会话列表里的一行：点开看对话，右侧叉号把会话从列表里去掉
struct SessionRow: View {
    var session: AgentSession
    var onOpen: () -> Void
    var onDismiss: () -> Void

    @State private var hovering = false

    // 第二行：有会话名称时先写项目名，再接最新消息
    private var detailText: String {
        guard !session.name.isEmpty else { return session.message }
        return session.message.isEmpty ? session.projectName : "\(session.projectName) · \(session.message)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.agent.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(session.agent.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // 会话名称放在最前面，同一项目里的多个会话靠它区分
                    Text(session.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(session.agent.shortName)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer(minLength: 0)
                    Text(session.status.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(session.status.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(session.status.color.opacity(0.14), in: Capsule())
                    Text(session.ageText)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
                if !detailText.isEmpty {
                    Text(detailText)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Loc.t("从列表里去掉", "Remove from the list"))
        }
        .padding(7)
        .background(Color.white.opacity(hovering ? 0.09 : 0.045),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .help(Loc.t("查看完整对话", "Open the full conversation"))
    }
}
