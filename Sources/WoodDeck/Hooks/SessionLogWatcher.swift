import Foundation

// DeepSeek Harness 没有命令式的 hook 配置，这里观察它的会话记录：
// 每个会话写在 sessions/<项目>/<会话>/session.v<N>.jsonl(.zstd) 里，逐行是事件。
// 会话文件会一直追加到几十兆，所以按文件记下已经读到的帧位置与解析出的事件，
// 每次只看新增的那几行，而不是把整份记录重新解压一遍
final class SessionLogWatcher {
    private struct Cache {
        var size: Int
        var modified: Date
        // 已经读到的字节位置，落在帧边界上
        var offset: Int
        // 上次末尾没有换行的半行，等下一次补上
        var tail: Data
        var headerCwd: String
        // 最近一次 session/title 事件里的会话标题
        var title: String
        var events: [WatchedEvent]
    }

    struct WatchedEvent {
        var kind: String
        var tool: String
        var text: String
        var time: Date
        var cwd: String
    }

    private var cache: [String: Cache] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.wooddeck.sessionwatch")
    private let onEvent: (AgentEvent) -> Void
    private var lastSeen: [String: String] = [:]

    // 只留最近这些事件，够判断「最后一条事件是否变化」即可
    private let keepEvents = 400

    init(onEvent: @escaping (AgentEvent) -> Void) {
        self.onEvent = onEvent
    }

    // 插件通过套接字实时上报，这里只是兜底，不必每 3 秒扫一遍目录
    func start(interval: TimeInterval = 8) {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scan()
        }
        self.timer = timer
        scan()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        queue.async { [weak self] in
            self?.scanDsh()
        }
    }

    private func scanDsh() {
        let root = DataLocations.detect().dshHome.appending(path: "sessions", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for file in newestSessionFiles(in: root) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            guard modified >= cutoff else { continue }

            let key = file.path(percentEncoded: false)
            let record = update(file: file, key: key, size: size, modified: modified, previous: cache[key])
            guard let record else { continue }
            cache[key] = record
            guard let last = record.events.last else { continue }

            // 只有最后一条事件变化时才上报，避免重复提醒
            let signature = "\(last.kind)|\(last.tool)|\(Int(last.time.timeIntervalSince1970))"
            if lastSeen[key] == signature { continue }
            lastSeen[key] = signature

            // 目录名就是会话 id（session-<uuid>），与插件上报的一致
            let event = AgentEvent(agent: .dsh,
                                   event: mapKind(last.kind),
                                   session: file.deletingLastPathComponent().lastPathComponent,
                                   cwd: last.cwd.isEmpty ? projectName(of: file, root: root) : last.cwd,
                                   title: "",
                                   name: record.title,
                                   message: last.text,
                                   tool: last.tool,
                                   pid: nil,
                                   timestamp: last.time.timeIntervalSince1970)
            onEvent(event)
        }
        // 清理已消失的会话缓存
        let alive = Set(newestSessionFiles(in: root).map { $0.path(percentEncoded: false) })
        cache = cache.filter { alive.contains($0.key) }
        lastSeen = lastSeen.filter { alive.contains($0.key) }
    }

    // 文件没变就沿用上次的事件；变长只读新增部分；变短就整个重来
    private func update(file: URL, key: String, size: Int, modified: Date, previous: Cache?) -> Cache? {
        if let previous, previous.size == size, previous.modified == modified { return previous }
        var record = previous ?? Cache(size: 0, modified: .distantPast, offset: 0, tail: Data(), headerCwd: "", title: "", events: [])
        if size < record.offset {
            record = Cache(size: 0, modified: .distantPast, offset: 0, tail: Data(), headerCwd: "", title: "", events: [])
        }
        guard let chunk = readAppended(file, from: record.offset) else {
            return record.offset == 0 ? nil : record
        }
        // 第一次读取时才需要从首行取工作目录
        let isFirstChunk = record.offset == 0 && record.headerCwd.isEmpty
        record.offset = chunk.end
        record.size = size
        record.modified = modified

        var content = record.tail
        content.append(chunk.data)
        var lines: [Data] = []
        var lineStart = content.startIndex
        for index in content.indices where content[index] == 0x0A {
            if index > lineStart { lines.append(Data(content[lineStart..<index])) }
            lineStart = content.index(after: index)
        }
        record.tail = lineStart < content.endIndex ? Data(content[lineStart...]) : Data()

        for (index, line) in lines.enumerated() {
            // 会话头（第一行）里记着工作目录，后面的事件常常没有
            if isFirstChunk, index == 0, record.headerCwd.isEmpty {
                if let json = try? JSONValue.parse(line) {
                    let cwd = json["cwd"].text
                    if !cwd.isEmpty { record.headerCwd = cwd }
                }
            }
            guard let event = event(from: line, headerCwd: record.headerCwd) else { continue }
            if event.kind == "session/title", !event.text.isEmpty { record.title = event.text }
            record.events.append(event)
        }
        if record.events.count > keepEvents {
            record.events.removeFirst(record.events.count - keepEvents)
        }
        return record
    }

    // 从指定位置往后读：zstd 文件按帧解压，普通文件直接读剩余字节
    private func readAppended(_ file: URL, from offset: Int) -> (data: Data, end: Int)? {
        if file.lastPathComponent.lowercased().hasSuffix(".zstd") {
            return try? ZstdFile.decompressRange(file, from: offset)
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.readToEnd() else { return nil }
        return (data, offset + data.count)
    }

    private func mapKind(_ kind: String) -> String {
        switch kind {
        case "turn/start", "user/message", "step/start": return "prompt"
        case "tool/call": return "tool_start"
        case "tool/result": return "tool_end"
        case "assistant/message", "step/end": return "tool_end"
        case "turn/end", "job/settled": return "stop"
        case "approval/asked": return "permission_request"
        case "approval/decided": return "permission_resolved"
        case "session/title": return "title"
        case "session/end": return "session_end"
        default: return "activity"
        }
    }

    private func event(from line: Data, headerCwd: String) -> WatchedEvent? {
        guard let json = try? JSONValue.parse(line) else { return nil }
        let kind = json["type"].text
        guard !kind.isEmpty else { return nil }
        let time = JSONDate.parse(json["time"]) ?? Date()
        var tool = ""
        var text = ""
        if kind == "tool/call" {
            tool = json["data"]["name"].text.isEmpty ? json["data"]["tool"].text : json["data"]["name"].text
            text = tool
        } else if kind == "assistant/message" {
            let message = json["data"]["message"]
            let content = message["content"]
            if let items = content.array {
                for item in items where item["type"].text == "text" {
                    text = item["text"].text
                    if !text.isEmpty { break }
                }
            }
            if text.isEmpty { text = content.text }
        } else if kind == "user/message" {
            text = json["data"]["message"]["content"].text
        } else if kind == "session/title" {
            text = json["data"]["title"].text
        } else if kind == "approval/asked" {
            tool = json["data"]["toolName"].text
            text = json["data"]["reason"].text
        } else if kind == "approval/decided" {
            text = json["data"]["outcome"].text
        }
        var cwd = json["cwd"].text.isEmpty ? json["data"]["cwd"].text : json["cwd"].text
        if cwd.isEmpty { cwd = headerCwd }
        return WatchedEvent(kind: kind, tool: tool, text: String(text.prefix(200)), time: time, cwd: cwd)
    }

    private func newestSessionFiles(in root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var byDirectory: [String: (url: URL, version: Int, modified: Date)] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            guard name.hasPrefix("session"), name.contains(".jsonl") else { continue }
            let version = versionNumber(of: name)
            let modified = values?.contentModificationDate ?? .distantPast
            let directory = url.deletingLastPathComponent().path(percentEncoded: false)
            if let existing = byDirectory[directory] {
                if version > existing.version || (version == existing.version && modified > existing.modified) {
                    byDirectory[directory] = (url, version, modified)
                }
            } else {
                byDirectory[directory] = (url, version, modified)
            }
        }
        return byDirectory.values.map(\.url)
    }

    // session.v4.jsonl.zstd 的版本是 4，session.jsonl 视为 0
    private func versionNumber(of name: String) -> Int {
        let parts = name.split(separator: ".")
        for (index, part) in parts.enumerated() {
            guard part == "v", index + 1 < parts.count else { continue }
            let digits = parts[index + 1].prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return 0
    }

    // 会话目录名把路径里的斜杠写成 “--”，这里还原成绝对路径
    private func projectName(of file: URL, root: URL) -> String {
        let path = file.path(percentEncoded: false)
        let rootPath = root.path(percentEncoded: false)
        guard path.count > rootPath.count else { return "" }
        var relative = String(path.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        guard let folder = relative.split(separator: "/").first.map(String.init) else { return "" }
        if folder.hasPrefix("--"), folder.hasSuffix("--") {
            let inner = folder.dropFirst(2).dropLast(2)
            return "/" + inner.replacingOccurrences(of: "--", with: "/")
        }
        return folder
    }
}
