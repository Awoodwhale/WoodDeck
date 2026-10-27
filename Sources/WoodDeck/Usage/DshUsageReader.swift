import Foundation

// DeepSeek Harness 把每个会话写成 sessions/<项目>/<会话>/session.v<N>.jsonl.zstd，一批写入一帧。
// 同一个目录里留着旧格式的文件，只读版本最高的那个；模型请求记在 assistant/message 事件里。
// 会话文件动辄几十兆，每次刷新全部重读会把 CPU 占满，所以按文件记下已解析到的帧位置与结果：
// 内容没变的文件直接复用，变长的文件只解压新增的帧
enum DshUsageReader {
    struct FileRecord {
        var size: Int64
        var modified: Date
        // 已经解析到的字节位置，落在帧边界上
        var offset: Int
        // 上一个数据块末尾没有换行的半行，等下一次补上
        var tail: Data
        var entries: [String: TokenEntry]
        var errors: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var records: [String: FileRecord] = [:]

    private static let messageMarker = Data("\"assistant/message\"".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)

    static func read(locations: DataLocations, now: Date, start: Date) -> UsageReading {
        let root = locations.dshHome.appending(path: "sessions", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            return UsageReading(entries: [], note: Loc.t("未找到本机 DeepSeek Harness 会话记录。", "No local DeepSeek Harness session records were found."),
                                available: false, complete: true, quotas: [], plan: "")
        }
        lock.lock()
        let previous = records
        lock.unlock()

        var next: [String: FileRecord] = [:]
        var entries: [String: TokenEntry] = [:]
        var count = 0
        var errors = 0
        for file in currentSessions(root) {
            let stamp = UsageLog.stamp(file)
            guard stamp.modified >= start else { continue }
            let path = file.path(percentEncoded: false)
            guard let record = update(file: file, path: path, stamp: stamp, previous: previous[path]) else {
                errors += 1
                continue
            }
            count += 1
            next[path] = record
            errors += record.errors
            // 分支会话会复制父会话的事件，同一个 message id 只记一次
            for (key, entry) in record.entries where entries[key] == nil { entries[key] = entry }
        }
        lock.lock()
        records = next
        lock.unlock()

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

    // 文件没变就沿用上次结果；变长就只解压新增的帧；变短或换了文件就整个重读
    private static func update(file: URL, path: String, stamp: (size: Int64, modified: Date),
                               previous: FileRecord?) -> FileRecord? {
        if let previous, previous.size == stamp.size, previous.modified == stamp.modified { return previous }
        var record = previous ?? FileRecord(size: 0, modified: .distantPast, offset: 0, tail: Data(), entries: [:], errors: 0)
        if stamp.size < Int64(record.offset) {
            record = FileRecord(size: 0, modified: .distantPast, offset: 0, tail: Data(), entries: [:], errors: 0)
        }
        let compressed = file.lastPathComponent.lowercased().hasSuffix(".zstd")
        var content: Data
        if compressed {
            let chunk: (data: Data, end: Int)
            do {
                chunk = try ZstdFile.decompressRange(file, from: record.offset)
            } catch {
                return record.offset == 0 ? nil : record
            }
            record.offset = chunk.end
            content = chunk.data
        } else {
            guard let plain = try? Data(contentsOf: file) else { return record.offset == 0 ? nil : record }
            record.offset = plain.count
            content = plain
        }
        record.size = stamp.size
        record.modified = stamp.modified

        // 上次留下的半行接在这一次的数据前面
        if !record.tail.isEmpty {
            var joined = record.tail
            joined.append(content)
            content = joined
            record.tail = Data()
        }
        var lines: [Data] = []
        var lineStart = content.startIndex
        for index in content.indices where content[index] == 0x0A {
            if index > lineStart { lines.append(Data(content[lineStart..<index])) }
            lineStart = content.index(after: index)
        }
        if lineStart < content.endIndex { record.tail = Data(content[lineStart...]) }

        for line in lines {
            switch parse(line, path: path) {
            case .entry(let entry):
                if record.entries[entry.key] == nil { record.entries[entry.key] = entry }
            case .next:
                continue
            case .failed:
                record.errors += 1
            }
        }
        return record
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

    // 先按字节筛掉不可能含模型请求的行，再只取用得到的字段。
    // 整行建成 JSONValue 树的开销比这大几十倍，会话文件几十兆时会把 CPU 占满
    private static func parse(_ line: Data, path: String) -> LineResult {
        guard line.range(of: messageMarker) != nil, line.range(of: usageMarker) != nil else { return .next }
        guard let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) as? [String: Any],
              text(object["type"]) == "assistant/message",
              let data = object["data"] as? [String: Any],
              let usage = data["usage"] as? [String: Any],
              let time = date(object["time"]) else { return .next }
        let message = data["message"] as? [String: Any] ?? [:]
        var id = text(message["id"])
        if id.isEmpty { id = "\(path):\(text(object["seq"]))" }
        let source = message["source"] as? [String: Any] ?? [:]
        return .entry(TokenEntry(key: "dsh:" + id, time: time, model: text(source["model"]),
                                 input: tally(usage["inputTokens"]), output: tally(usage["outputTokens"]),
                                 cacheRead: tally(usage["cacheReadTokens"]), cacheWrite: tally(usage["cacheWriteTokens"])))
    }

    private static func text(_ any: Any?) -> String {
        switch any {
        case let value as String:
            return value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            let number = value.doubleValue
            return number == number.rounded() ? String(Int(number)) : String(number)
        default:
            return ""
        }
    }

    private static func tally(_ any: Any?) -> Int {
        let number: Double
        switch any {
        case let value as NSNumber:
            number = value.doubleValue
        case let value as String:
            number = Double(value) ?? 0
        default:
            return 0
        }
        return min(max(Int(number.rounded()), 0), 1_000_000_000_000_000)
    }

    private static func date(_ any: Any?) -> Date? {
        switch any {
        case let value as NSNumber:
            let seconds = value.doubleValue
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        case let value as String:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        default:
            return nil
        }
    }
}
