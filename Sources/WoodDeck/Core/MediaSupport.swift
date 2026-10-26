import Foundation

// mediaremote 适配器的资源位置：应用包内优先，开发期回退到仓库目录
enum MediaRemoteResources {
    static var directory: URL {
        let name = "MediaRemoteAdapter"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name))
        }
        // 直接运行可执行文件时，回退到源码树中的资源目录
        let source = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent(name)
        candidates.append(source)
        for candidate in candidates {
            let script = candidate.appendingPathComponent("mediaremote-adapter.pl")
            if FileManager.default.fileExists(atPath: script.path(percentEncoded: false)) {
                return candidate
            }
        }
        return candidates.first ?? source
    }

    static func isPresent() -> Bool {
        let script = directory.appendingPathComponent("mediaremote-adapter.pl")
        return FileManager.default.fileExists(atPath: script.path(percentEncoded: false))
    }
}

extension NowPlaying {
    // 按采样时间与播放速率推算当前位置
    var effectiveRate: Double {
        rate.isFinite && rate > 0 ? rate : 1
    }

    func position(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        let elapsedSinceSample = max(0, now.timeIntervalSince(timestamp))
        let advance = playing ? elapsedSinceSample * effectiveRate : 0
        return min(max(elapsed + advance, 0), duration)
    }
}
