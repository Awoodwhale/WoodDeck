import SwiftUI

// 额度卡片底部的一段时间的用量：标题、Token 数、费用与箭头，整行可点开对应时段的模型明细
struct UsageTotalsView: View {
    var todayTokens: Int
    var weekTokens: Int
    var todayCost: Decimal?
    var weekCost: Decimal?
    // 宽度够时今日与七日并排，否则上下两行
    var inline: Bool
    var onOpen: (Int) -> Void

    @State private var hovered: Int?

    private static let captionWidth: CGFloat = Loc.isChinese ? 24 : 34

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.bottom, inline ? 5 : 4)
            if inline {
                HStack(spacing: 10) {
                    row(label: Loc.t("今日", "Today"), tokens: todayTokens, cost: todayCost, days: 1)
                    Spacer(minLength: 8)
                    row(label: Loc.t("七日", "Week"), tokens: weekTokens, cost: weekCost, days: 7)
                }
            } else {
                VStack(spacing: 1) {
                    row(label: Loc.t("今日", "Today"), tokens: todayTokens, cost: todayCost, days: 1)
                    row(label: Loc.t("七日", "Week"), tokens: weekTokens, cost: weekCost, days: 7)
                }
            }
        }
        .padding(.top, 6)
    }

    private func row(label: String, tokens: Int, cost: Decimal?, days: Int) -> some View {
        Button {
            onOpen(days)
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: Self.captionWidth, alignment: .trailing)
                Text(TimeFormatting.tokens(tokens))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 4)
                if let cost {
                    Text(UsageMetric.money(cost, currency: "USD"))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovered == days ? 0.6 : 0.28))
            }
            .padding(.horizontal, 5)
            .frame(height: 19)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(hovered == days ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = days
            } else if hovered == days {
                hovered = nil
            }
        }
        .help(Loc.t("\(TimeFormatting.exactTokens(tokens)) Token · 查看明细",
                    "\(TimeFormatting.exactTokens(tokens)) tokens · show details"))
    }
}
