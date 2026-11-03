import AppKit
import Foundation

// 封面的自检：换歌时封面必须跟着换，适配器单独问一次能取到封面
@MainActor
enum ArtworkTest {
    static func run(arguments: [String]) async {
        if arguments.contains("watch") {
            await watch(seconds: double(after: "watch", in: arguments) ?? 600)
            return
        }
        await logic()
        await cacheCheck()
        await adapterCheck()
    }

    // 换歌那一条事件没有封面时，不能沿用上一首的封面
    private static func logic() async {
        print("—— 封面跟着曲目走")
        guard let first = imageData("docs/icon.png"), let second = imageData("docs/monitor.png") else {
            print("  缺少自检用的图片 ✗")
            return
        }
        let model = DeckModel.shared
        var trackA = sample(title: "自检曲目甲", artwork: first)
        model.applyNowPlayingForTest(trackA)
        print("  第一首的封面：\(model.music.artwork?.count ?? 0) 字节")
        let keptFirst = model.music.artwork == first
        print("  第一首的封面已生效：\(keptFirst ? "是 ✓" : "否 ✗")")

        var trackB = trackA
        trackB.title = "自检曲目乙"
        trackB.uniqueIdentifier = "self-test-b"
        trackB.artwork = nil
        model.applyNowPlayingForTest(trackB)
        print("  换成第二首且这条事件没有封面：\(model.music.artwork?.count ?? 0) 字节")
        print("  上一首的封面已清掉：\(model.music.artwork == nil ? "是 ✓" : "否 ✗")")

        trackA.uniqueIdentifier = "self-test-a"
        model.applyNowPlayingForTest(trackA)
        var trackC = trackB
        trackC.artwork = second
        model.applyNowPlayingForTest(trackC)
        print("  第二首的封面到达后：\(model.music.artwork?.count ?? 0) 字节")
        print("  第二首的封面已生效：\(model.music.artwork == second ? "是 ✓" : "否 ✗")")
    }

    // 缓存不能把同一曲目的旧封面一直当成答案
    private static func cacheCheck() async {
        print("—— 缓存不会挡住后续的封面")
        guard let first = imageData("docs/icon.png"), let second = imageData("docs/monitor.png") else {
            print("  缺少自检用的图片 ✗")
            return
        }
        let adapter = MediaRemoteAdapter(resources: MediaRemoteResources.directory)
        let key = "self-test-key"
        let old = await adapter.artworkForTest(payloadJSON: payload(first), key: key)
        let fresh = await adapter.artworkForTest(payloadJSON: payload(second), key: key)
        print("  报文里先给 \(old?.count ?? 0) 字节，再给 \(fresh?.count ?? 0) 字节")
        print("  后一次的封面覆盖了前一次：\(fresh == second ? "是 ✓" : "否 ✗")")
        let missing = await adapter.artworkForTest(payloadJSON: "{}", key: key)
        print("  报文里不带封面时沿用缓存：\(missing == second ? "是 ✓" : "否 ✗")")
    }

    private static func payload(_ image: Data) -> String {
        "{\"artworkData\":\"\(image.base64EncodedString())\"}"
    }

    // 单独问一次适配器，确认能拿到当前曲目的封面
    private static func adapterCheck() async {
        print("—— 适配器单独查一次封面")
        let adapter = MediaRemoteAdapter(resources: MediaRemoteResources.directory)
        guard let fresh = try? await adapter.current() else {
            print("  查询失败 ✗")
            return
        }
        let bytes = fresh.artwork?.count ?? 0
        print("  当前曲目：\(fresh.title) · \(fresh.artist)")
        print("  一次性查询取到的封面：\(bytes) 字节")
        print("  能取到封面：\(bytes > 0 ? "是 ✓" : "否 ✗")")
    }

    // 跟着真实的播放走，换歌时打印封面字节数的变化
    private static func watch(seconds: Double) async {
        let model = DeckModel.shared
        model.start()
        var last = ""
        let deadline = Date().addingTimeInterval(seconds)
        report("—— 观察换歌时的封面（\(Int(seconds)) 秒）")
        while Date() < deadline {
            let line = "\(model.music.title)|\(model.music.artwork?.count ?? 0)"
            if line != last {
                last = line
                report(String(format: "%@  %@  封面 %d 字节",
                              TimeFormatting.clock(Date(), hour24: true, style: .minimal),
                              model.music.title,
                              model.music.artwork?.count ?? 0))
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // 观察模式要一边跑一边看见输出，标准输出重定向到文件时会攒着，这里直接写标准错误
    private static func report(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func sample(title: String, artwork: Data?) -> NowPlaying {
        NowPlaying(bundleIdentifier: "com.netease.163music",
                   title: title,
                   artist: "自检歌手",
                   album: "自检专辑",
                   duration: 200,
                   elapsed: 10,
                   timestamp: Date(),
                   rate: 1,
                   playing: true,
                   artwork: artwork,
                   uniqueIdentifier: "",
                   shuffleMode: nil,
                   repeatMode: nil,
                   supportsLiked: false,
                   liked: false)
    }

    private static func imageData(_ path: String) -> Data? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
        return try? Data(contentsOf: url)
    }

    private static func double(after flag: String, in arguments: [String]) -> Double? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return Double(arguments[index + 1])
    }
}
