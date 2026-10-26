import Foundation

// DeepSeek Harness 没有命令式的 hook 配置，这里观察它的会话记录：
// 每个会话写在 sessions/<项目>/<会话>/session.v<N>.jsonl(.zstd) 里，逐行是事件
final class SessionLogWatcher {
    private struct Cache {
        var size: Int
        var modified: Date
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
            let events: [WatchedEvent]
            if let hit = cache[key], hit.size == size, hit.modified == modified {
                events = hit.events
            } else {
                events = readEvents(file)
                cache[key] = Cache(size: size, modified: modified, events: events)
            }
            guard let last = events.last else { continue }

            // 只有最后一条事件变化时才上报，避免重复提醒
            let signature = "\(last.kind)|\(last.tool)|\(Int(last.time.timeIntervalSince1970))"
            if lastSeen[key] == signature { continue }
            lastSeen[key] = signature

            let event = AgentEvent(agent: .dsh,
                                   event: mapKind(last.kind),
                                   session: file.deletingLastPathComponent().lastPathComponent,
                                   cwd: last.cwd.isEmpty ? projectName(of: file, root: root) : last.cwd,
                                   title: "",
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

    private func mapKind(_ kind: String) -> String {
        switch kind {
        case "turn/start", "user/message", "step/start": return "prompt"
        case "tool/call": return "tool_start"
        case "tool/result": return "tool_end"
        case "assistant/message", "step/end": return "tool_end"
        case "turn/end", "job/settled": return "stop"
        case "permission/request": return "permission_request"
        case "session/end": return "session_end"
        default: return "activity"
        }
    }

    private func readEvents(_ file: URL) -> [WatchedEvent] {
        let lines: [Data]
        if file.lastPathComponent.lowercased().hasSuffix(".zstd") {
            lines = (try? ZstdFile.lines(file)) ?? []
        } else {
            guard let data = try? Data(contentsOf: file) else { return [] }
            lines = data.split(separator: 0x0A).map(Data.init)
        }
        var events: [WatchedEvent] = []
        // 会话头（第一行）里记着工作目录，最后一行往往没有
        var headerCwd = ""
        if let first = lines.first, let json = try? JSONValue.parse(first) {
            headerCwd = json["cwd"].text
        }
        for line in lines.suffix(400) {
            guard let json = try? JSONValue.parse(line) else { continue }
            let kind = json["type"].text
            guard !kind.isEmpty else { continue }
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
            }
            var cwd = json["cwd"].text.isEmpty ? json["data"]["cwd"].text : json["cwd"].text
            if cwd.isEmpty { cwd = headerCwd }
            events.append(WatchedEvent(kind: kind, tool: tool, text: String(text.prefix(200)), time: time, cwd: cwd))
        }
        return events
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
