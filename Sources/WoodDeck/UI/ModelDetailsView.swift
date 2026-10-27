import SwiftUI

// 模型明细：表头、模型行、固定的合计行；宽度够时展开输入与缓存两列
struct ModelDetailsView: View {
    @EnvironmentObject private var model: DeckModel
    var columnID: UUID
    var initialDays: Int

    @State private var days: Int
    @State private var hovered: String?

    init(columnID: UUID, initialDays: Int = 7) {
        self.columnID = columnID
        self.initialDays = initialDays
        _days = State(initialValue: initialDays)
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 560
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                table(wide: wide)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(columnName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Picker("", selection: $days) {
                Text(Loc.t("今日", "Today")).tag(1)
                Text(Loc.t("七日", "7 days")).tag(7)
                Text(Loc.t("三十日", "30 days")).tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
    }

    private func table(wide: Bool) -> some View {
        let rows = model.modelDetails(columnID: columnID, days: days)
        var total = ModelDetailRow(model: "", input: 0, output: 0, cacheWrite: 0,
                                   cacheRead: 0, cost: nil, unpriced: 0, requests: 0)
        for row in rows {
            total.input += row.input
            total.output += row.output
            total.cacheWrite += row.cacheWrite
            total.cacheRead += row.cacheRead
            total.requests += row.requests
            total.unpriced += row.unpriced
            if let cost = row.cost {
                total.cost = (total.cost ?? 0) + cost
            }
        }
        // 一条都没匹配到单价时不画费用列，留给 tooltip 说明
        let priced = rows.contains { $0.cost != nil }
        return VStack(spacing: 0) {
            headerRow(wide: wide, showCost: priced)
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
            if rows.isEmpty {
                Text(Loc.t("这个范围内没有用量记录。", "No usage records in this range."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            dataRow(row, wide: wide, showCost: priced, divided: index > 0)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
            totalRow(total, count: rows.count, wide: wide, showCost: priced)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func headerRow(wide: Bool, showCost: Bool) -> some View {
        HStack(spacing: 0) {
            Text(Loc.t("模型", "Model"))
                .frame(maxWidth: .infinity, alignment: .leading)
            if wide {
                headerCell(Loc.t("输入", "Input"))
                headerCell(Loc.t("缓存写入", "Cache write"))
                headerCell(Loc.t("缓存读取", "Cache read"))
                headerCell(Loc.t("输出", "Output"))
            }
            headerCell(Loc.t("合计", "Total"))
            if showCost {
                headerCell(Loc.t("费用", "Cost"))
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 6)
    }

    private func headerCell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 62, alignment: .trailing)
            .padding(.leading, 8)
    }

    private func dataRow(_ row: ModelDetailRow, wide: Bool, showCost: Bool, divided: Bool) -> some View {
        HStack(spacing: 0) {
            Text(row.model)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(priceNote(row))
            if wide {
                numberCell(TimeFormatting.tokens(row.input), tip: TimeFormatting.exactTokens(row.input))
                numberCell(TimeFormatting.tokens(row.cacheWrite), tip: TimeFormatting.exactTokens(row.cacheWrite))
                numberCell(TimeFormatting.tokens(row.cacheRead), tip: TimeFormatting.exactTokens(row.cacheRead))
                numberCell(TimeFormatting.tokens(row.output), tip: TimeFormatting.exactTokens(row.output))
            }
            numberCell(TimeFormatting.tokens(row.tokens), weight: .medium, tip: breakdownNote(row))
            if showCost {
                numberCell(costText(row.cost, unpriced: row.unpriced), weight: .semibold, tip: costNote(row))
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(hovered == row.id ? 0.05 : 0))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(divided ? 0.07 : 0))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = row.id
            } else if hovered == row.id {
                hovered = nil
            }
        }
    }

    private func totalRow(_ total: ModelDetailRow, count: Int, wide: Bool, showCost: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(Loc.t("合计", "Total"))
                    .font(.system(size: 11, weight: .medium))
                Text(summary(count: count))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if wide {
                numberCell(TimeFormatting.tokens(total.input), weight: .semibold,
                           tip: TimeFormatting.exactTokens(total.input))
                numberCell(TimeFormatting.tokens(total.cacheWrite), weight: .semibold,
                           tip: TimeFormatting.exactTokens(total.cacheWrite))
                numberCell(TimeFormatting.tokens(total.cacheRead), weight: .semibold,
                           tip: TimeFormatting.exactTokens(total.cacheRead))
                numberCell(TimeFormatting.tokens(total.output), weight: .semibold,
                           tip: TimeFormatting.exactTokens(total.output))
            }
            numberCell(TimeFormatting.tokens(total.tokens), weight: .semibold, tip: breakdownNote(total))
            if showCost {
                numberCell(costText(total.cost, unpriced: total.unpriced), weight: .semibold, tip: costTotalNote(total))
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 6)
    }

    private func numberCell(_ text: String, weight: Font.Weight = .regular, tip: String = "") -> some View {
        Text(text)
            .font(.system(size: 11, weight: weight).monospacedDigit())
            .lineLimit(1)
            .frame(width: 62, alignment: .trailing)
            .padding(.leading, 8)
            .help(tip)
    }

    private func costText(_ cost: Decimal?, unpriced: Int) -> String {
        guard let cost else { return "—" }
        let money = UsageMetric.money(cost, currency: "USD")
        return unpriced > 0 ? money + " +" : money
    }

    private func summary(count: Int) -> String {
        let period = switch days {
        case 1: Loc.t("今日", "Today")
        case 7: Loc.t("七日", "7 days")
        default: Loc.t("三十日", "30 days")
        }
        return Loc.t("\(period) · \(count) 项", "\(period) · \(count) items")
    }

    private func breakdownNote(_ row: ModelDetailRow) -> String {
        Loc.t("""
        输入 \(TimeFormatting.exactTokens(row.input)) · 缓存写入 \(TimeFormatting.exactTokens(row.cacheWrite))
        缓存读取 \(TimeFormatting.exactTokens(row.cacheRead)) · 输出 \(TimeFormatting.exactTokens(row.output))
        合计 \(TimeFormatting.exactTokens(row.tokens))
        """, """
        Input \(TimeFormatting.exactTokens(row.input)) · cache write \(TimeFormatting.exactTokens(row.cacheWrite))
        Cache read \(TimeFormatting.exactTokens(row.cacheRead)) · output \(TimeFormatting.exactTokens(row.output))
        Total \(TimeFormatting.exactTokens(row.tokens))
        """)
    }

    private func costNote(_ row: ModelDetailRow) -> String {
        guard row.cost != nil else {
            return Loc.t("\(row.requests) 次请求都没有匹配到单价", "No price matched any of the \(row.requests) requests")
        }
        var lines = [Loc.t("\(row.requests) 次请求", "\(row.requests) requests")]
        if row.unpriced > 0 {
            lines.append(Loc.t("另有 \(row.unpriced) 次没有匹配到单价", "\(row.unpriced) more have no price"))
        }
        lines.append(Loc.t("单价来自 OpenRouter 目录", "Prices from the OpenRouter catalog"))
        return lines.joined(separator: "\n")
    }

    private func costTotalNote(_ total: ModelDetailRow) -> String {
        guard total.unpriced == 0 else {
            return Loc.t("\(total.unpriced) 次请求没有匹配到单价，金额不含这些请求",
                         "\(total.unpriced) requests have no price; the amount excludes them")
        }
        return Loc.t("\(total.requests) 次请求", "\(total.requests) requests")
    }

    // 单价表：每百万 Token 的美元金额
    private func priceNote(_ row: ModelDetailRow) -> String {
        guard let price = Pricing.match(row.model) else { return row.model }
        func perMillion(_ value: Decimal) -> String {
            var rounded = Decimal()
            var amount = value * 1_000_000
            NSDecimalRound(&rounded, &amount, 2, .plain)
            return "$" + NSDecimalNumber(decimal: rounded).stringValue
        }
        return """
        \(row.model)
        \(Loc.t("输入 \(perMillion(price.input)) / 百万", "Input \(perMillion(price.input)) / million"))
        \(Loc.t("输出 \(perMillion(price.output)) / 百万", "Output \(perMillion(price.output)) / million"))
        \(Loc.t("缓存读取 \(perMillion(price.cacheRead)) / 百万", "Cache read \(perMillion(price.cacheRead)) / million"))
        \(Loc.t("缓存写入 \(perMillion(price.cacheWrite)) / 百万", "Cache write \(perMillion(price.cacheWrite)) / million"))
        """
    }

    private var columnName: String {
        model.settings.apps.first { $0.instanceID == columnID }?.name ?? Loc.t("模型明细", "Model details")
    }
}
