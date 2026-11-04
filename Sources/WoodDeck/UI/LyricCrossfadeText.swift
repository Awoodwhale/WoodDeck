import SwiftUI

// 一行会变的文字。换内容时旧字淡出、新字同时淡入：
// 两层叠在同一位置做交叉淡入，画面上始终有等量的字，既不空白也不变暗
struct LyricCrossfadeText: View {
    let text: String
    let font: Font
    let color: Color
    // 淡入时从下方浮上来的距离
    var rise: CGFloat = 4
    var duration: Double = 0.26
    // 是否占满可用宽度：歌词与曲名要占满，跟在别的文字后面的那一小段不占
    var expands: Bool = true
    // 换内容时是否做淡出淡入
    var animates: Bool = true

    @State private var shown: String = ""
    @State private var previous: String = ""
    @State private var shownOpacity: Double = 1
    @State private var previousOpacity: Double = 0
    @State private var generation = 0

    var body: some View {
        ZStack(alignment: .leading) {
            if !previous.isEmpty {
                Text(previous)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .opacity(previousOpacity)
            }
            Text(shown.isEmpty ? " " : shown)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .opacity(shownOpacity)
                .offset(y: (1 - shownOpacity) * rise)
        }
        .onAppear { shown = text }
        .onChange(of: text) { _, value in swap(to: value) }
        .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
    }

    private func swap(to value: String) {
        guard value != shown else { return }
        generation += 1
        guard animates else {
            shown = value
            previous = ""
            shownOpacity = 1
            previousOpacity = 0
            return
        }
        let token = generation
        let outgoing = shown
        previous = outgoing
        shown = value
        // 旧字接着当前的不透明度起步，新字从零起步，两段同时过渡，
        // 中途任何一帧都有一层是清楚的
        previousOpacity = outgoing.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1
        shownOpacity = 0
        withAnimation(.easeInOut(duration: duration)) {
            previousOpacity = 0
            shownOpacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard token == generation else { return }
            previous = ""
        }
    }
}
