import SwiftUI

extension DeckModel {
    func setting<T>(_ keyPath: WritableKeyPath<DeckSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func intSetting(_ keyPath: WritableKeyPath<DeckSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(self.settings[keyPath: keyPath]) },
                set: { value in self.update { $0[keyPath: keyPath] = Int(value.rounded()) } })
    }
}

// 可直接输入的数值框：回车或失去焦点时提交，输入非法时回到当前值，超范围时夹到边界
struct SettingsNumberField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var suffix: String

    private let fieldWidth: CGFloat = 72
    private let suffixWidth: CGFloat = 34

    // 直接绑定到数值本身：滑块与输入框共用同一个真值，不再有本地文本副本，
    // 因此不会出现「拖动滑块后输入框内容被旧文本覆盖」这类冲突
    private var decimals: Int { step < 1 ? 1 : 0 }

    private var format: FloatingPointFormatStyle<Double> {
        FloatingPointFormatStyle<Double>.number
            .grouping(.never)
            .precision(.fractionLength(decimals))
    }

    private var clamped: Binding<Double> {
        Binding(get: { value },
                set: { newValue in
                    guard newValue.isFinite else { return }
                    let limited = min(max(newValue, range.lowerBound), range.upperBound)
                    let factor = pow(10, Double(decimals))
                    value = (limited * factor).rounded() / factor
                })
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: clamped, format: format)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(width: fieldWidth)
            Text(suffix)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: suffixWidth, alignment: .leading)
        }
        .frame(width: fieldWidth + 6 + suffixWidth, alignment: .trailing)
    }
}
