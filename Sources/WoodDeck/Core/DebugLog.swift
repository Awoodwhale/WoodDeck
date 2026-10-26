import Foundation

// 调试日志：只有设置环境变量 WOODDECK_DEBUG 时才写入
enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["WOODDECK_DEBUG"] == "1"

    static func write(_ text: String) {
        guard enabled else { return }
        let url = DataLocations.detect().support.appending(path: "debug.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
