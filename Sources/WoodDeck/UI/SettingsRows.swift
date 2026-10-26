import SwiftUI

// 设置页统一的一行：图标、标题、说明，右侧放控件
struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    let description: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let description {
                    Text(description).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            content()
        }
        .padding(.vertical, 4)
    }
}

// 行尾的开关
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!enabled)
    }
}

// 行尾的选择菜单
struct SettingsPickerRow<Selection: Hashable, Content: View>: View {
    var icon: String
    var title: String
    var description: String?
    @Binding var selection: Selection
    var width: CGFloat = 172
    var isSegmented = false
    @ViewBuilder let options: () -> Content

    var body: some View {
        SettingRow(icon: icon, title: title, description: description) {
            if isSegmented {
                Picker("", selection: $selection) { options() }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: width)
            } else {
                Picker("", selection: $selection) { options() }
                    .labelsHidden()
                    .frame(width: width)
            }
        }
    }
}

// 一条滑块：数值框在旁边，可以直接输入
struct SettingsSliderItem {
    var title: String
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var step: Double = 1
    var suffix: String = ""
}

// 同一组滑块放在一行里，组内不出现分隔线
struct SettingsSliderGroup: View {
    var icon: String
    var title: String
    var description: String?
    var items: [SettingsSliderItem]

    var body: some View {
        SettingRow(icon: icon, title: title, description: description) {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(items, id: \.title) { item in
                    SettingsSliderLine(item: item, showsLabel: items.count > 1)
                }
            }
        }
    }
}

struct SettingsSliderLine: View {
    var item: SettingsSliderItem
    var showsLabel: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsLabel {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)
            }
            Slider(value: item.value, in: item.range, step: item.step)
                .frame(width: 120)
            SettingsNumberField(value: item.value, range: item.range, step: item.step, suffix: item.suffix)
        }
    }
}
