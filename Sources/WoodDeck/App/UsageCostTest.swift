import Foundation

// 量一遍 DSH 用量读取的耗时：第一次是冷启动全量解压解析，第二次走文件缓存，
// 两次的请求数必须一致，否则说明增量读取漏了内容
enum UsageCostTest {
    static func run() {
        let locations = DataLocations.detect()
        let now = Date()
        let start = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now)
        let root = locations.dshHome.appending(path: "sessions", directoryHint: .isDirectory)

        var files = 0
        var bytes = 0
        let decompressBegin = Date()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent.lowercased()
                guard name.hasPrefix("session"), name.hasSuffix(".zstd") else { continue }
                guard UsageLog.modified(url) >= start else { continue }
                guard let lines = try? ZstdFile.lines(url) else { continue }
                files += 1
                for line in lines { bytes += line.count }
            }
        }
        let decompress = Date().timeIntervalSince(decompressBegin) * 1000

        let coldBegin = Date()
        let cold = DshUsageReader.read(locations: locations, now: now, start: start)
        let coldCost = Date().timeIntervalSince(coldBegin) * 1000

        let warmBegin = Date()
        let warm = DshUsageReader.read(locations: locations, now: now, start: start)
        let warmCost = Date().timeIntervalSince(warmBegin) * 1000

        print("会话文件 \(files) 个，解压后 \(String(format: "%.1f", Double(bytes) / 1048576)) MB，纯解压 \(String(format: "%.1f", decompress)) 毫秒")
        print("首次读取 \(String(format: "%.1f", coldCost)) 毫秒 · 缓存读取 \(String(format: "%.3f", warmCost)) 毫秒")
        print("请求数 首次 \(cold.entries.count) · 缓存 \(warm.entries.count) \(cold.entries.count == warm.entries.count ? "一致 ✓" : "不一致 ✗")")
        print(cold.note)
    }
}
