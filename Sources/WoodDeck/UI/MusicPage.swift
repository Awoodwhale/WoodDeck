import SwiftUI

// 音乐页：按 BrimDeck 1.2.1 的版式还原。
// 上部：左侧封面（圆角约为边长的 8%），右侧标题、歌手与最多三行歌词（当前、下一句、上一句）。
// 下部：一条与封面同宽起的进度条，两端下方是已播与总时长；再下面是播放控制，播放模式在最左，播放键居中。
struct MusicPageView: View {
    var music: MusicDisplay
    var showTranslation: Bool = false
    var onCommand: (MediaCommand) -> Void
    var onSeek: (Double) -> Void
    var onMode: () -> Void

    @State private var seeking: Double?

    private var side: CGFloat { 18 }
    private var gap: CGFloat { 20 }

    var body: some View {
        Group {
            if music.hasTrack {
                content
            } else {
                placeholder
            }
        }
        .padding(.horizontal, side)
        .padding(.vertical, 10)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.25))
            Text(music.available ? Loc.t("没有正在播放的音乐", "Nothing is playing") : Loc.t("音乐来源不可用", "Music source unavailable"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
            if !music.available {
                Text(Loc.t("读取系统媒体信息需要 mediaremote 适配器，详见设置 › 音乐",
                           "Reading system media needs the mediaremote adapter; see Settings › Music"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        // 底部进度与控制在任何高度都必须完整可见：先给它们固定高度，
        // 剩下的空间才交给封面，封面因此随面板高度自适应
        GeometryReader { proxy in
            let progressHeight: CGFloat = 4 + 3 + 13   // 进度条 + 间距 + 时间行
            let controlsHeight: CGFloat = 24
            let spacing: CGFloat = 8
            let reserved = progressHeight + controlsHeight + spacing * 2
            let available = proxy.size.height
            let cover = max(30, min(96, available - reserved))
            VStack(alignment: .leading, spacing: spacing) {
                upper(coverSize: cover)
                    .frame(height: cover, alignment: .top)
                progressView
                    .frame(height: progressHeight)
                controlRow
                    .frame(height: controlsHeight)
            }
            .frame(width: proxy.size.width, height: available, alignment: .top)
        }
    }

    // 上部：封面与文字并排
    private func upper(coverSize: CGFloat) -> some View {
        // 与上游一致：先扣掉标题与歌手占的高度，再看剩余空间能放几行歌词（上限 3 行）。
        // 这样封面矮的时候少画几行，不会顶到下方的进度条
        let titleLine: CGFloat = 18
        let artistLine: CGFloat = 16
        let middleGap: CGFloat = 2
        let lyricLine: CGFloat = 15
        let room = max(0, coverSize - titleLine - artistLine - middleGap)
        let lyricLines = min(3, max(0, Int(room / lyricLine)))
        return HStack(alignment: .top, spacing: gap) {
            artwork(coverSize: coverSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(music.title.isEmpty ? Loc.t("未知曲目", "Unknown track") : music.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(music.artist.isEmpty ? music.album : music.artist)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if !music.sourceName.isEmpty {
                        Text("·")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                        Text(music.sourceName)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if music.canLike {
                        // 只有播放器既能读出也能修改喜欢状态时才提供红心
                        Button { onCommand(.like) } label: {
                            Image(systemName: music.liked ? "heart.fill" : "heart")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(music.liked ? Theme.color("#EC4141") : Color.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .help(Loc.t("喜欢", "Like"))
                    }
                }
                lyricsView(maxLines: lyricLines)
                Spacer(minLength: 0)
            }
            .frame(height: coverSize, alignment: .top)
            .clipped()
        }
    }

    private func artwork(coverSize: CGFloat) -> some View {
        Group {
            if let data = music.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: coverRadius(coverSize), style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(RoundedRectangle(cornerRadius: coverRadius(coverSize), style: .continuous))
    }

    // 圆角约为边长的 8%，与上游一致
    private func coverRadius(_ size: CGFloat) -> CGFloat {
        min(16, max(5, (size * 0.08).rounded()))
    }

    // 歌词：当前句最亮，随后依次是可选的翻译、下一句、上一句，填到可用行数为止
    @ViewBuilder
    private func lyricsView(maxLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if maxLines <= 0 {
                EmptyView()
            } else if music.lyrics.isEmpty {
                LyricCrossfadeText(text: music.album.isEmpty ? " " : music.album,
                                   font: .system(size: 11.5),
                                   color: Theme.lyric.opacity(0.32),
                                   rise: 0)
            } else {
                lyricRows(maxLines: maxLines)
            }
        }
        // 当前句换行时整块做淡入淡出，避免歌词硬切
        .animation(.easeInOut(duration: 0.26), value: lyricKey)
    }

    // 参与过渡判断的歌词内容：任一行的文字变化都触发淡入淡出
    private var lyricKey: String {
        [music.currentLyric, music.currentTranslation, music.nextLyric, music.previousLyric]
            .joined(separator: "\u{1F}")
    }

    // 按顺序填充歌词行：当前 → 翻译 → 下一句 → 上一句，最多 maxLines 行
    @ViewBuilder
    private func lyricRows(maxLines: Int) -> some View {
        LyricCrossfadeText(text: music.currentLyric.isEmpty ? " " : music.currentLyric,
                           font: .system(size: 12.5, weight: .medium),
                           color: Theme.lyric.opacity(0.95),
                           rise: 4)
        if maxLines >= 2, showTranslation, !music.currentTranslation.isEmpty {
            LyricCrossfadeText(text: music.currentTranslation,
                               font: .system(size: 11),
                               color: Theme.lyric.opacity(0.55),
                               rise: 2)
            if maxLines >= 3, !music.nextLyric.isEmpty {
                nextLine
            }
        } else if maxLines >= 2, !music.nextLyric.isEmpty {
            nextLine
            if maxLines >= 3, !music.previousLyric.isEmpty {
                previousLine
            }
        }
    }

    private var nextLine: some View {
        LyricCrossfadeText(text: music.nextLyric,
                           font: .system(size: 11.5),
                           color: Theme.lyric.opacity(0.42),
                           rise: 2)
    }

    private var previousLine: some View {
        LyricCrossfadeText(text: music.previousLyric,
                           font: .system(size: 11),
                           color: Theme.lyric.opacity(0.26),
                           rise: 2)
    }

    // 进度条：两端下方分别是已播与总时长
    private var progressView: some View {
        VStack(spacing: 3) {
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                let fraction = seeking ?? music.liveProgress(at: timeline.date)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(Color.white.opacity(0.78))
                            .frame(width: max(0, proxy.size.width * fraction))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard music.canSeek, proxy.size.width > 0 else { return }
                                seeking = min(max(value.location.x / proxy.size.width, 0), 1)
                            }
                            .onEnded { value in
                                guard music.canSeek, proxy.size.width > 0 else { seeking = nil; return }
                                let target = min(max(value.location.x / proxy.size.width, 0), 1)
                                seeking = nil
                                onSeek(target * music.duration)
                            }
                    )
                }
                .frame(height: 4)
            }
            .frame(height: 4)
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                HStack {
                    Text(TimeFormatting.duration((seeking ?? music.liveProgress(at: timeline.date)) * music.duration))
                    Spacer(minLength: 0)
                    Text(TimeFormatting.duration(music.duration))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // 控制行：播放模式在最左，播放键在整行居中，上一首与下一首分列两侧
    private var controlRow: some View {
        HStack(spacing: 0) {
            modeButton
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 18) {
                control("backward.fill", size: 13, enabled: music.canPrevious) { onCommand(.previous) }
                control(music.playing ? "pause.fill" : "play.fill", size: 17, enabled: music.canToggle) {
                    onCommand(.toggle)
                }
                control("forward.fill", size: 13, enabled: music.canNext) { onCommand(.next) }
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 22, height: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // 播放模式：列表循环 / 单曲循环 / 随机 / 顺序，按播放器报告的能力循环
    private var modeButton: some View {
        Button(action: onMode) {
            HStack(spacing: 4) {
                Image(systemName: modeIcon)
                    .font(.system(size: 11, weight: .medium))
                Text(modeLabel)
                    .font(.system(size: 10))
            }
            .foregroundStyle(music.canChangeMode ? Color.white.opacity(0.7) : Color.white.opacity(0.25))
            .frame(height: 16)
        }
        .buttonStyle(.plain)
        .disabled(!music.canChangeMode)
        .help(music.canChangeMode
              ? Loc.t("切换播放模式（\(modeLabel)）", "Change playback mode (\(modeLabel))")
              : Loc.t("这个播放器不提供播放模式控制", "This player does not expose playback mode"))
    }

    private var modeIcon: String {
        if music.shuffle { return "shuffle" }
        switch music.repeatMode {
        case 1: return "repeat"
        case 2, 3: return "repeat.1"
        default: return "repeat"
        }
    }

    private var modeLabel: String {
        if music.shuffle { return Loc.t("随机播放", "Shuffle") }
        switch music.repeatMode {
        case 1: return Loc.t("列表循环", "Repeat all")
        case 2: return Loc.t("单曲循环", "Repeat one")
        case 3: return Loc.t("顺序播放", "In order")
        default: return Loc.t("列表循环", "Repeat all")
        }
    }

    private func control(_ icon: String, size: CGFloat = 11, active: Bool = false, enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.white.opacity(enabled ? 0.8 : 0.22))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
