import SwiftUI

// 歌词行：文本变化时旧句淡出、新句从下方轻微上移淡入，两句在叠放容器里重叠，行高不变
struct LyricCrossfadeText: View {
    let text: String
    let font: Font
    let color: Color
    var rise: CGFloat = 4
    var duration: Double = 0.26

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text.isEmpty ? " " : text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .id(text)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: rise)),
                    removal: .opacity
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: duration), value: text)
    }
}
