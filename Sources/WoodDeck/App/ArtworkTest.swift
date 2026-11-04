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

    // 换歌那一条事件没有封面时先留住当前封面，等适配器问到的封面来替换
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
        print("  这条事件没有封面时先留住上一张：\(model.music.artwork == first ? "是 ✓" : "否 ✗")")

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

    // 单独问适配器，确认能拿到当前曲目的封面。
    // 换歌之后的一小段时间里系统还没把封面交出来，查询会得到空答复，
    // 应用为此会补问几次，这里也按同样的节奏补问
    private static func adapterCheck() async {
        print("—— 适配器单独查一次封面")
        let adapter = MediaRemoteAdapter(resources: MediaRemoteResources.directory)
        var attempts: [Int] = []
        for round in 1...4 {
            guard let fresh = try? await adapter.current() else {
                print("  查询失败 ✗")
                return
            }
            let bytes = fresh.artwork?.count ?? 0
            attempts.append(bytes)
            print("  第 \(round) 次查询：\(fresh.title) · \(fresh.artist)，封面 \(bytes) 字节")
            if bytes > 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        let got = attempts.contains { $0 > 0 }
        print("  能取到封面：\(got ? "是 ✓" : "否 ✗")（各次 \(attempts.map(String.init).joined(separator: " / ")) 字节）")
    }

    // 跟着真实的播放走，换歌时打印封面字节数的变化
    private static func watch(seconds: Double) async {
        let model = DeckModel.shared
        model.start()
        var last = ""
        let deadline = Date().addingTimeInterval(seconds)
        report("—— 观察换歌时的封面（\(Int(seconds)) 秒）")
        while Date() < deadline {
            let line = "\(model.music.title)|\(model.music.artwork?.count ?? 0)|\(model.music.artworkToken)"
            if line != last {
                last = line
                report(String(format: "%@  %@  封面 %d 字节 标识 %@",
                              TimeFormatting.clock(Date(), hour24: true, style: .minimal),
                              model.music.title,
                              model.music.artwork?.count ?? 0,
                              model.music.artworkToken.isEmpty ? "（空）" : model.music.artworkToken))
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
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
