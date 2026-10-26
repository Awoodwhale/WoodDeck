import SwiftUI
import MarkdownUI

// 单个会话的完整对话：助手输出在左、用户输入在右，工具调用默认折叠
struct ConversationView: View {
    var session: AgentSession
    var onBack: () -> Void

    @State private var messages: [ConversationMessage] = []
    @State private var loaded = false

    private let limit = 200
    private let bottomID = "conversation-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content
        }
        .task(id: session.id) {
            messages = []
            loaded = false
            let session = session
            let values = await Task.detached(priority: .userInitiated) {
                ConversationReader.load(session: session, limit: limit)
            }.value
            messages = values
            loaded = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(Loc.t("返回", "Back"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Loc.t("回到会话列表", "Back to the session list"))

            Image(systemName: session.agent.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(session.agent.accent)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.projectName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(session.agent.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(session.status.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(session.status.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(session.status.color.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text(Loc.t("正在读取对话记录", "Reading the conversation"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if messages.isEmpty {
            placeholder
        } else {
            transcript
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.25))
            Text(emptyText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyText: String {
        switch session.agent {
        case .gemini, .opencode:
            return Loc.t("这个助手没有可读取的本地对话记录", "This assistant keeps no readable local conversation")
        case .claude, .codex, .dsh:
            return Loc.t("没有找到这个会话的本地对话记录", "No local conversation record was found for this session")
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if messages.count >= limit {
                        Text(Loc.t("只显示最近 \(limit) 条消息", "Showing the latest \(limit) messages"))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(messages) { message in
                        ConversationBubble(message: message, accent: session.agent.accent)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

// 一条消息：助手在左、用户在右；工具调用收成一行，点开看参数与结果
struct ConversationBubble: View {
    var message: ConversationMessage
    var accent: Color

    // 工具调用默认折叠
    @State private var expanded = false

    var body: some View {
        switch message.role {
        case .user:
            userRow
        case .assistant, .system:
            assistantRow
        case .tool:
            toolRow
        }
    }

    // 用户输入：右侧
    private var userRow: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Loc.t("你", "You"))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                Text(message.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Theme.color("#3A4A6B").opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // 助手输出：左侧，正文用 markdown 渲染
    private var assistantRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(message.role == .system ? Loc.t("系统", "System") : Loc.t("助手", "Assistant"))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(message.role == .system ? Color.white.opacity(0.3) : accent)
                    Text(message.time.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.22))
                }
                if message.text.isEmpty {
                    Text(Loc.t("（没有文本内容）", "(no text content)"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                } else {
                    Markdown(message.text)
                        .markdownTheme(.deckCompact(accent: accent))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Spacer(minLength: 40)
        }
    }

    // 工具调用：默认折叠成一行，点击展开参数与结果
    private var toolRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(width: 8)
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.color("#E5C890").opacity(0.9))
                        Text(message.toolName.isEmpty ? Loc.t("工具调用", "Tool call") : message.toolName)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        if !expanded {
                            Text(summary)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.32))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(message.time.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    ScrollView(.vertical) {
                        Text(message.text)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 5)
                    }
                    .frame(maxHeight: 130)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
            )
            Spacer(minLength: 24)
        }
    }

    // 折叠时显示的一行摘要：取第一行非空文本
    private var summary: String {
        let firstLine = message.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return String(firstLine.replacingOccurrences(of: "  ", with: " ").prefix(80))
    }
}

extension MarkdownUI.Theme {
    // 面板里用的紧凑 markdown 主题
    static func deckCompact(accent: Color) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                FontSize(10.5)
                ForegroundColor(.white.opacity(0.85))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(9.5)
                ForegroundColor(.white.opacity(0.9))
                BackgroundColor(Color.white.opacity(0.07))
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(accent) }
            .paragraph { configuration in
                configuration.label.markdownMargin(top: 0, bottom: 4)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(13)
                        ForegroundColor(.white.opacity(0.95))
                    }
                    .markdownMargin(top: 6, bottom: 3)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(12)
                        ForegroundColor(.white.opacity(0.95))
                    }
                    .markdownMargin(top: 5, bottom: 3)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(11)
                        ForegroundColor(.white.opacity(0.95))
                    }
                    .markdownMargin(top: 4, bottom: 2)
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: 0, bottom: 2)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(9.5)
                            ForegroundColor(.white.opacity(0.85))
                        }
                        .padding(7)
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .markdownMargin(top: 2, bottom: 5)
            }
            .blockquote { configuration in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 2)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.white.opacity(0.6)) }
                }
                .markdownMargin(top: 2, bottom: 4)
            }
    }
}
