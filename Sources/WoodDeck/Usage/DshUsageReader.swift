import Foundation

// DeepSeek Harness 把每个会话写成 sessions/<项目>/<会话>/session.v<N>.jsonl.zstd，一批写入一帧。
// 同一个目录里留着旧格式的文件，只读版本最高的那个；模型请求记在 assistant/message 事件里
enum DshUsageReader {
    static func read(locations: DataLocations, now: Date, start: Date) -> UsageReading {
        let root = locations.dshHome.appending(path: "sessions", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            return UsageReading(entries: [], note: Loc.t("未找到本机 DeepSeek Harness 会话记录。", "No local DeepSeek Harness session records were found."),
                                available: false, complete: true, quotas: [], plan: "")
        }
        var entries: [String: TokenEntry] = [:]
        var count = 0
        var errors = 0
        for file in currentSessions(root) {
            guard UsageLog.modified(file) >= start else { continue }
            count += 1
            let lines: [Data]
            if file.lastPathComponent.lowercased().hasSuffix(".zstd") {
                guard let decompressed = try? ZstdFile.lines(file) else {
                    errors += 1
                    continue
                }
                lines = decompressed
            } else {
                guard let plain = UsageLog.lines(file) else {
                    errors += 1
                    continue
                }
                lines = plain
            }
            let path = file.path(percentEncoded: false)
            for line in lines {
                switch parse(line, path: path, start: start) {
                case .entry(let entry):
                    // 分支会话会复制父会话的事件，同一个 message id 只记一次
                    if entries[entry.key] == nil { entries[entry.key] = entry }
                case .next:
                    continue
                case .failed:
                    errors += 1
                }
            }
        }
        let kept = entries.values
            .filter { $0.time >= start && $0.time <= now && $0.total > 0 }
            .sorted { $0.time < $1.time }
        var note = Loc.t("本机 DeepSeek Harness \(UsageLog.day(start)) 起 · \(count) 个会话 · \(kept.count) 次模型请求",
                         "Local DeepSeek Harness since \(UsageLog.day(start)) · \(Loc.count(count, "session")) · \(Loc.count(kept.count, "model request"))")
        if errors > 0 {
            note += Loc.t(" · \(errors) 处记录未能读取", " · \(Loc.count(errors, "record")) could not be read")
        }
        return UsageReading(entries: kept, note: note, available: true, complete: errors == 0, quotas: [], plan: "")
    }

    // 每个会话目录只保留版本最高的会话文件，版本相同取最近写入的那个
    private static func currentSessions(_ root: URL) -> [URL] {
        var newest: [String: (url: URL, version: Int, modified: Date)] = [:]
        for url in UsageLog.files(root, suffix: "") {
            guard let version = generation(url.lastPathComponent) else { continue }
            let folder = url.deletingLastPathComponent().path(percentEncoded: false)
            let modified = UsageLog.modified(url)
            if let current = newest[folder], current.version > version || (current.version == version && current.modified >= modified) { continue }
            newest[folder] = (url, version, modified)
        }
        return newest.values.map(\.url).sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    // session.v4.jsonl.zstd 的版本是 4，session.jsonl 的版本是 0
    private static func generation(_ name: String) -> Int? {
        guard name.hasPrefix("session") else { return nil }
        var rest = name.dropFirst("session".count)
        var version = 0
        if rest.hasPrefix(".v") {
            rest = rest.dropFirst(2)
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, let parsed = Int(digits) else { return nil }
            version = parsed
            rest = rest.dropFirst(digits.count)
        }
        guard rest.hasPrefix(".jsonl") else { return nil }
        rest = rest.dropFirst(".jsonl".count)
        guard rest.isEmpty || rest.lowercased() == ".zstd" else { return nil }
        return version
    }

    private enum LineResult {
        case entry(TokenEntry)
        case next
        case failed
    }

    private static func parse(_ line: Data, path: String, start: Date) -> LineResult {
        guard line.range(of: Data("\"assistant/message\"".utf8)) != nil,
              line.range(of: Data("\"usage\"".utf8)) != nil else { return .next }
        guard let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else { return .failed }
        let root = JSONValue(object)
        let data = root["data"]
        let usage = data["usage"]
        guard root["type"].text == "assistant/message", usage.object != nil,
              let time = JSONDate.parse(root["time"]), time >= start else { return .next }
        let message = data["message"]
        var id = message["id"].text
        if id.isEmpty { id = "\(path):\(root["seq"].text)" }
        return .entry(TokenEntry(key: "dsh:" + id, time: time, model: message["source"]["model"].text,
                                 input: UsageLog.count(usage["inputTokens"]), output: UsageLog.count(usage["outputTokens"]),
                                 cacheRead: UsageLog.count(usage["cacheReadTokens"]), cacheWrite: UsageLog.count(usage["cacheWriteTokens"])))
    }
}
