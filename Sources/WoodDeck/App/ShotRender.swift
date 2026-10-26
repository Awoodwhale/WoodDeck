import AppKit
import SwiftUI

// 生成文档用的界面截图：把视图放进离屏窗口真实排版后取位图。
// ImageRenderer 无法渲染走马灯与律动条这类 CALayer 内容，会画成占位图形，所以不能用它
@MainActor
enum ShotRender {
    static func run(directory: String) {
        let folder = URL(filePath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = DeckModel.shared
        model.start()
        SystemMonitorModel.shared.start(includeProcesses: true, interval: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(7))

        let content = model.compactContent()
        closed(content: content, to: folder.appending(path: "closed.png"))
        music(model.music, to: folder.appending(path: "music.png"))
        monitor(to: folder.appending(path: "monitor.png"))
        settings(to: folder.appending(path: "settings.png"))
        print("截图目录：\(folder.path(percentEncoded: false))")
    }

    private struct ClosedShot: View {
        var content: CompactContent

        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(white: 0.20), Color(white: 0.07)],
                               startPoint: .top,
                               endPoint: .bottom)
                CompactIslandView(content: content)
                    .frame(width: 393, height: 32)
                    .padding(.top, 26)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private static func closed(content: CompactContent, to url: URL) {
        let size = CGSize(width: 640, height: 170)
        save(ClosedShot(content: content).frame(width: size.width, height: size.height), size: size, to: url)
    }

    private static func music(_ display: MusicDisplay, to url: URL) {
        let size = CGSize(width: 520, height: 200)
        let view = MusicPageView(music: display,
                                 showTranslation: true,
                                 onCommand: { _ in },
                                 onSeek: { _ in },
                                 onMode: {})
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.06))
        save(view, size: size, to: url)
    }

    private static func monitor(to url: URL) {
        let size = CGSize(width: 520, height: 130)
        let view = MonitorPageView(monitor: SystemMonitorModel.shared)
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.06))
        save(view, size: size, to: url)
    }

    private static func settings(to url: URL) {
        let size = CGSize(width: 800, height: 620)
        let view = SettingsView()
            .environmentObject(DeckModel.shared)
            .frame(width: size.width, height: size.height)
        save(view, size: size, to: url)
    }

    private static func save(_ view: some View, size: CGSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("\(url.lastPathComponent)：取不到位图")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("\(url.lastPathComponent)：编码失败")
            return
        }
        try? png.write(to: url)
        print("\(url.lastPathComponent)：\(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
