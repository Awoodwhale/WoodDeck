import SwiftUI

struct ModelDetailsView: View {
    @EnvironmentObject private var model: DeckModel
    var columnID: UUID
    @State private var days = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(columnName).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Picker("", selection: $days) {
                    Text(Loc.t("今日", "Today")).tag(1)
                    Text(Loc.t("七日", "7 days")).tag(7)
                    Text(Loc.t("三十日", "30 days")).tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            let rows = model.modelDetails(columnID: columnID, days: days)
            if rows.isEmpty {
                Text(Loc.t("这个范围内没有用量记录。", "No usage records in this range."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn(Loc.t("模型", "Model")) { row in
                        Text(row.model).font(.system(size: 11))
                    }
                    .width(min: 140)
                    TableColumn(Loc.t("输入", "Input")) { row in
                        Text(TimeFormatting.tokens(row.input)).font(.system(size: 11).monospacedDigit())
                    }
                    .width(70)
                    TableColumn(Loc.t("输出", "Output")) { row in
                        Text(TimeFormatting.tokens(row.output)).font(.system(size: 11).monospacedDigit())
                    }
                    .width(70)
                    TableColumn(Loc.t("缓存", "Cached")) { row in
                        Text(TimeFormatting.tokens(row.cached)).font(.system(size: 11).monospacedDigit())
                    }
                    .width(70)
                    TableColumn(Loc.t("费用", "Cost")) { row in
                        Text(row.cost.map { UsageMetric.money($0, currency: "USD") } ?? "—")
                            .font(.system(size: 11).monospacedDigit())
                    }
                    .width(70)
                }
            }

            let note = model.usageNote(forColumn: columnID)
            if !note.isEmpty {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var columnName: String {
        model.settings.apps.first { $0.instanceID == columnID }?.name ?? Loc.t("模型明细", "Model details")
    }
}
