import SwiftUI

struct ExpandedPanelView: View {
    var settings: DeckSettings
    var columns: [AppColumn]
    var music: MusicDisplay
    var page: DeckPage
    var refreshing: Bool
    var lastRefresh: Date?
    var onPageChange: (DeckPage) -> Void
    var onRefresh: () -> Void
    var onSettings: () -> Void
    var onMusicCommand: (MediaCommand) -> Void
    var onSeek: (Double) -> Void
    var onMode: () -> Void
    var onDetails: (UUID) -> Void
    var sessions: [AgentSession] = []
    var onDismissSession: (AgentSession) -> Void = { _ in }
    var onClearFinished: () -> Void = {}
    var onOpenSettings: (() -> Void)?
    var pages: [DeckPage] = [.quota, .sessions, .music]
    // 会话提醒与额度提醒的当前文字，展开时也要能看到
    var alertText: String = ""
    var alertColor: Color = .white

    var body: some View {
        VStack(spacing: 0) {
            header
            if !alertText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 9))
                    Text(alertText)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(alertColor)
                .padding(.horizontal, 14)
                .padding(.bottom, 5)
            }
            Divider().overlay(Color.white.opacity(0.08))
            Group {
                switch page {
                case .quota:
                    QuotaPageView(columns: columns,
                                  onDetails: onDetails,
                                  onOpenSettings: onOpenSettings ?? onSettings)
                case .sessions:
                    SessionsPageView(sessions: sessions,
                                     onDismiss: onDismissSession,
                                     onClearFinished: onClearFinished)
                case .monitor:
                    MonitorPageView(monitor: SystemMonitorModel.shared)
                case .music:
                    MusicPageView(music: music,
                                  showTranslation: settings.showLyricsTranslation,
                                  onCommand: onMusicCommand,
                                  onSeek: onSeek,
                                  onMode: onMode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.palette.panelColor)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if pages.count > 1 {
                PageSwitch(page: page, pages: pages, onChange: onPageChange)
            } else {
                Text(page.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 0)
            if refreshing {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .help(Loc.t("刷新", "Refresh"))
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .help(Loc.t("设置", "Settings"))
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

struct PageSwitch: View {
    var page: DeckPage
    var pages: [DeckPage]
    var onChange: (DeckPage) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pages, id: \.self) { value in
                segment(value)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func segment(_ value: DeckPage) -> some View {
        Button {
            onChange(value)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol(value)).font(.system(size: 9, weight: .semibold))
                Text(value.displayName).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(page == value ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
            .foregroundStyle(page == value ? Color.white : Color.white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private func symbol(_ value: DeckPage) -> String {
        switch value {
        case .quota: "chart.bar.fill"
        case .sessions: "bubble.left.and.bubble.right.fill"
        case .music: "music.note"
        case .monitor: "cpu"
        }
    }
}

struct UsageColumnView: View {
    var column: AppColumn
    var maxMetrics: Int = 3
    var onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.color(column.entry.resolvedTheme))
                    .frame(width: 3, height: 12)
                Text(column.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !column.plan.isEmpty {
                    Text(column.plan)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            if column.quotas.isEmpty && column.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(column.statusLabel.isEmpty ? Loc.t("未连接", "Not connected") : column.statusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(column.status)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(Array(metricRows.prefix(maxMetrics))) { metric in
                    MetricRow(metric: metric, entry: column.entry)
                }
            }

            Spacer(minLength: 0)

            if column.usageAvailable {
                Button(action: onDetails) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(Loc.t("今日", "Today"))
                                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4))
                            Text(TimeFormatting.tokens(column.todayTokens))
                                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                            if let cost = column.todayCost {
                                Text(UsageMetric.money(cost, currency: "USD"))
                                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                            }
                        }
                        HStack(spacing: 4) {
                            Text(Loc.t("七日", "7 days"))
                                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4))
                            Text(TimeFormatting.tokens(column.weekTokens))
                                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                            if let cost = column.weekCost {
                                Text(UsageMetric.money(cost, currency: "USD"))
                                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(column.usageNote)
            } else if !column.usageNote.isEmpty {
                Text(column.usageNote)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var metricRows: [UsageMetric] {
        column.metrics.isEmpty ? column.quotas.map(\.metric) : column.metrics
    }
}

struct MetricRow: View {
    var metric: UsageMetric
    var entry: AppEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(metric.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(metric.valueText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                if !metric.valueSuffix.isEmpty {
                    Text(metric.valueSuffix)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(percentColor)
                        .frame(width: max(0, proxy.size.width * CGFloat(min(max(metric.usedPercent ?? 0, 0), 100) / 100)))
                }
            }
            .frame(height: 3)
            if !resetText.isEmpty {
                Text(resetText)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var percentColor: Color {
        guard let percent = metric.usedPercent else { return Theme.color(entry.resolvedTheme) }
        return Theme.quotaColor(entry, percent: percent)
    }

    private var resetText: String {
        if !metric.resetText.isEmpty { return metric.resetText }
        guard let resetAt = metric.resetAt else { return "" }
        return Loc.remaining(until: resetAt)
    }
}
