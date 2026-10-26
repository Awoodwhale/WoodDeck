import Foundation

// Claude Code 把每个会话写成 projects/<项目>/<会话>.jsonl。只取 assistant 消息里的 usage，
// 同一条消息在流式写入时可能出现多次，保留 total 更大的那条
enum ClaudeUsageReader {
    // 会话文件只在末尾追加：内容没变的文件直接复用上次的解析结果，避免每分钟重新解析全部记录
    private struct CachedFile {
        var size: Int
        var modified: Date
        var cutoff: Date
        var entries: [TokenEntry]
        var errors: Int
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CachedFile] = [:]

    private static func cached(_ file: URL, cutoff: Date) -> (entries: [TokenEntry], errors: Int)? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let key = file.path(percentEncoded: false)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let hit = cache[key], hit.size == size, hit.modified == modified, hit.cutoff <= cutoff else { return nil }
        return (hit.entries, hit.errors)
    }

    private static func store(_ file: URL, cutoff: Date, entries: [TokenEntry], errors: Int) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        cacheLock.lock()
        cache[file.path(percentEncoded: false)] = CachedFile(size: size, modified: modified, cutoff: cutoff,
                                                             entries: entries, errors: errors)
        cacheLock.unlock()
    }

    static func read(locations: DataLocations, now: Date, start: Date) -> UsageReading {
        let root = locations.claudeProjects()
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            return UsageReading(entries: [], note: Loc.t("未找到本机会话记录。", "No local session records were found."),
                                available: false, complete: true, quotas: [], plan: "")
        }
        var entries: [String: TokenEntry] = [:]
        var count = 0
        var errors = 0
        for file in UsageLog.files(root, suffix: ".jsonl") {
            guard UsageLog.modified(file) >= start else { continue }
            count += 1
            let perFile: (entries: [TokenEntry], errors: Int)
            if let hit = cached(file, cutoff: start) {
                perFile = hit
            } else if let lines = UsageLog.lines(file) {
                var fileEntries: [TokenEntry] = []
                var fileErrors = 0
                for line in lines {
                    switch parse(line, start: start) {
                    case .entry(let entry): fileEntries.append(entry)
                    case .next: continue
                    case .failed: fileErrors += 1
                    }
                }
                store(file, cutoff: start, entries: fileEntries, errors: fileErrors)
                perFile = (fileEntries, fileErrors)
            } else {
                errors += 1
                continue
            }
            errors += perFile.errors
            for entry in perFile.entries {
                if let old = entries[entry.key], entry.total < old.total { continue }
                entries[entry.key] = entry
            }
        }
        let kept = entries.values
            .filter { $0.time >= start && $0.time <= now && $0.total > 0 }
            .sorted { $0.time < $1.time }
        let day = UsageLog.day(start)
        var note = Loc.t("本机 \(day) 起 · \(count) 个记录文件", "This PC since \(day) · \(Loc.count(count, "record file"))")
        if errors > 0 {
            note += Loc.t(" · \(errors) 处记录未能读取", " · \(Loc.count(errors, "record")) could not be read")
        }
        return UsageReading(entries: kept, note: note, available: true, complete: errors == 0, quotas: [], plan: "")
    }

    private enum LineResult {
        case entry(TokenEntry)
        case next
        case failed
    }

    private static func parse(_ line: Data, start: Date) -> LineResult {
        guard line.range(of: Data("\"usage\"".utf8)) != nil else { return .next }
        guard let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else { return .failed }
        let root = JSONValue(object)
        guard root["type"].text == "assistant" else { return .next }
        guard let time = JSONDate.parse(root["timestamp"]), time >= start else { return .next }
        let message = root["message"]
        let usage = message["usage"]
        guard usage.object != nil else { return .next }
        let input = UsageLog.count(usage["input_tokens"])
        let output = UsageLog.count(usage["output_tokens"])
        let read = UsageLog.count(usage["cache_read_input_tokens"])
        // cache_creation 里有一个小时的部分，两者都记在 cacheWrite 上
        let creation = UsageLog.count(usage["cache_creation_input_tokens"])
        var key = message["id"].text
        if key.isEmpty { key = root["uuid"].text }
        if key.isEmpty {
            key = "\(time.timeIntervalSince1970):\(UsageLog.raw(usage))"
        }
        return .entry(TokenEntry(key: "claude:" + key, time: time, model: message["model"].text,
                                 input: input, output: output, cacheRead: read, cacheWrite: creation))
    }
}
