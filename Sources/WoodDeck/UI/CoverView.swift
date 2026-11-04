import SwiftUI

// 封面视图：按标识复用解码结果，换图时上一张淡出、下一张淡入。
// 动画挂在叠放容器上，容器在换图前后都活着，过渡才能生效
struct CoverView: View {
    var data: Data?
    var token: String
    var size: CGFloat
    var cornerRadius: CGFloat
    var placeholderSize: CGFloat = 11
    var placeholderColor: Color = .white

    var body: some View {
        ZStack {
            if let image = CoverCache.shared.image(for: data, token: token) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(token)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(placeholderColor.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: placeholderSize))
                            .foregroundStyle(placeholderColor.opacity(0.3))
                    )
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: IslandTiming.coverFade), value: token)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
