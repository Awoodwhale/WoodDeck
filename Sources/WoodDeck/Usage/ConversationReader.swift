import Foundation

// 对话里的一条消息属于谁
enum ConversationRole: String, Sendable {
    case user
    case assistant
    case tool
    case system
}

struct ConversationMessage: Identifiable, Sendable {
    var id: String
    var role: ConversationRole
    var text: String
    var toolName: String
    var time: Date
}

// 从各助手在本机保存的会话记录里还原完整对话，只读文件
enum ConversationReader {
    static func load(session: AgentSession, limit: Int = 200) -> [ConversationMessage] {
        guard limit > 0 else { return [] }
        switch session.agent {
        case .claude: return claudeTranscript(session, limit: limit)
        case .codex: return codexTranscript(session, limit: limit)
        case .dsh: return dshTranscript(session, limit: limit)
        case .gemini, .opencode: return []
        }
    }
}

// 只保留最后 limit 条，读取长记录时不会一直变大
private struct MessageBuffer {
    let limit: Int
    private var items: [ConversationMessage] = []

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ message: ConversationMessage) {
        items.append(message)
        if items.count > limit * 2 { items.removeFirst(items.count - limit) }
    }

    func result() -> [ConversationMessage] {
        Array(items.suffix(limit))
    }
}

extension ConversationReader {
    // MARK: Claude Code

    private static func claudeTranscript(_ session: AgentSession, limit: Int) -> [ConversationMessage] {
        guard let url = claudeFile(session) else { return [] }
        let lines = textLines(url)
        guard !lines.isEmpty else { return [] }
        var buffer = MessageBuffer(limit: limit)
        let fallback = session.updatedAt
        for (index, line) in lines.enumerated() {
            guard let json = try? JSONValue.parse(line) else { continue }
            if json["isMeta"].bool == true || json["isSidechain"].bool == true { continue }
            let kind = json["type"].text
            guard kind == "user" || kind == "assistant" else { continue }
            let role: ConversationRole = kind == "user" ? .user : .assistant
            let time = JSONDate.parse(json["timestamp"]) ?? fallback
            let content = json["message"]["content"]
            if let text = content.string {
                appendText(&buffer, text: text, role: role, toolName: "", time: time,
                           id: "claude-\(index)-0")
                continue
            }
            guard let items = content.array else { continue }
            for (itemIndex, item) in items.enumerated() {
                let identifier = "claude-\(index)-\(itemIndex)"
                switch item["type"].text {
                case "text":
                    appendText(&buffer, text: item["text"].text, role: role, toolName: "",
                               time: time, id: identifier)
                case "tool_use":
                    buffer.append(ConversationMessage(id: identifier,
                                                      role: .tool,
                                                      text: summary(item["input"]),
                                                      toolName: item["name"].text,
                                                      time: time))
                default:
                    break
                }
            }
        }
        return buffer.result()
    }

    private static func claudeFile(_ session: AgentSession) -> URL? {
        let manager = FileManager.default
        let root = DataLocations.detect().claudeProjects()
        let identifier = identifier(of: session)
        let folders = (try? manager.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
        for folder in folders {
            let candidate = folder.appending(path: identifier + ".jsonl")
            if manager.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        // 会话文件名对不上时，退回到工作目录对应的项目目录里最新的记录
        let cwd = session.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else { return nil }
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let folder = folders.first { $0.lastPathComponent == encoded }
            ?? folders.first { $0.lastPathComponent.replacingOccurrences(of: "-", with: "/") == cwd }
        guard let folder else { return nil }
        return newestFile(in: folder, extension: "jsonl")
    }

    // MARK: DeepSeek Harness

    private static func dshTranscript(_ session: AgentSession, limit: Int) -> [ConversationMessage] {
        guard let url = dshFile(session) else { return [] }
        let lines = textLines(url)
        guard !lines.isEmpty else { return [] }
        var buffer = MessageBuffer(limit: limit)
        var toolNames: [String: String] = [:]
        let fallback = session.updatedAt
        for (index, line) in lines.enumerated() {
            guard let json = try? JSONValue.parse(line) else { continue }
            let kind = json["type"].text
            let data = json["data"]
            let time = JSONDate.parse(json["time"]) ?? fallback
            switch kind {
            case "user/message":
                let content = data["message"]["content"].isNull ? data["content"] : data["message"]["content"]
                appendText(&buffer, text: contentText(content), role: .user, toolName: "",
                           time: time, id: "dsh-\(index)")
            case "assistant/message":
                appendText(&buffer, text: contentText(data["message"]["content"]), role: .assistant,
                           toolName: "", time: time, id: "dsh-\(index)")
            case "tool/call":
                let name = data["name"].text.isEmpty ? data["tool"].text : data["name"].text
                let callID = data["callId"].text
                if !callID.isEmpty { toolNames[callID] = name }
                buffer.append(ConversationMessage(id: "dsh-\(index)",
                                                  role: .tool,
                                                  text: summary(data["arguments"]),
                                                  toolName: name,
                                                  time: time))
            case "tool/result":
                let callID = data["message"]["toolCallId"].text.isEmpty
                    ? data["toolCallId"].text
                    : data["message"]["toolCallId"].text
                let content = data["message"]["content"].isNull ? data["content"] : data["message"]["content"]
                appendText(&buffer, text: contentText(content), role: .tool,
                           toolName: toolNames[callID] ?? "", time: time, id: "dsh-\(index)")
            default:
                break
            }
        }
        return buffer.result()
    }

    private static func dshFile(_ session: AgentSession) -> URL? {
        let manager = FileManager.default
        let root = DataLocations.detect().dshHome.appending(path: "sessions", directoryHint: .isDirectory)
        guard manager.fileExists(atPath: root.path(percentEncoded: false)) else { return nil }
        let name = identifier(of: session)
        guard !name.isEmpty else { return nil }
        let projects = (try? manager.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles])) ?? []
        for project in projects {
            let directory = project.appending(path: name, directoryHint: .isDirectory)
            if let file = newestSessionFile(in: directory) { return file }
        }
        return nil
    }

    private static func newestSessionFile(in directory: URL) -> URL? {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
        var best: (url: URL, version: Int, modified: Date)?
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("session"), name.contains(".jsonl") else { continue }
            let version = versionNumber(of: name)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let current = best {
                if version > current.version || (version == current.version && modified > current.modified) {
                    best = (file, version, modified)
                }
            } else {
                best = (file, version, modified)
            }
        }
        return best?.url
    }

    // session.v4.jsonl.zstd 的版本是 4，session.jsonl 视为 0
    private static func versionNumber(of name: String) -> Int {
        let parts = name.split(separator: ".")
        for (index, part) in parts.enumerated() {
            guard part == "v", index + 1 < parts.count else { continue }
            let digits = parts[index + 1].prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return 0
    }

    // MARK: Codex

    private static func codexTranscript(_ session: AgentSession, limit: Int) -> [ConversationMessage] {
        guard let url = codexFile(session) else { return [] }
        let lines = textLines(url)
        guard !lines.isEmpty else { return [] }
        var buffer = MessageBuffer(limit: limit)
        let fallback = session.updatedAt
        for (index, line) in lines.enumerated() {
            guard let json = try? JSONValue.parse(line) else { continue }
            let kind = json["type"].text
            guard kind == "event_msg" || kind == "response_item" else { continue }
            let payload = json["payload"]
            let time = JSONDate.parse(json["timestamp"]) ?? fallback
            switch payload["type"].text {
            case "message":
                let role: ConversationRole
                switch payload["role"].text {
                case "user": role = .user
                case "assistant": role = .assistant
                default: role = .system
                }
                appendText(&buffer, text: contentText(payload["content"]), role: role,
                           toolName: "", time: time, id: "codex-\(index)")
            case "function_call":
                buffer.append(ConversationMessage(id: "codex-\(index)",
                                                  role: .tool,
                                                  text: summary(payload["arguments"]),
                                                  toolName: payload["name"].text,
                                                  time: time))
            default:
                break
            }
        }
        return buffer.result()
    }

    private static func codexFile(_ session: AgentSession) -> URL? {
        let manager = FileManager.default
        let root = DataLocations.detect().codexHome.appending(path: "sessions", directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, modified))
        }
        guard !files.isEmpty else { return nil }
        files.sort { $0.modified > $1.modified }
        let cwd = session.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else { return files.first?.url }
        for file in files where firstLineCwd(file.url) == cwd { return file.url }
        // 首行没有工作目录时，在文件开头一段里查找
        for file in files where headContains(file.url, text: cwd) { return file.url }
        return files.first?.url
    }

    private static func firstLineCwd(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let newline = data.firstIndex(of: 0x0A) else { return "" }
        let line = data[data.startIndex..<newline]
        guard let json = try? JSONValue.parse(line) else { return "" }
        return json["payload"]["cwd"].text
    }

    private static func headContains(_ url: URL, text: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let content = String(data: data, encoding: .utf8) else { return false }
        return content.contains(text)
    }

    // MARK: 通用读取

    private static func identifier(of session: AgentSession) -> String {
        guard let separator = session.id.firstIndex(of: ":") else { return session.id }
        return String(session.id[session.id.index(after: separator)...])
    }

    private static func textLines(_ url: URL) -> [Data] {
        if url.lastPathComponent.lowercased().hasSuffix(".zstd") {
            return (try? ZstdFile.lines(url)) ?? []
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).map(Data.init)
    }

    private static func newestFile(in directory: URL, extension suffix: String) -> URL? {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
        var best: (url: URL, modified: Date)?
        for file in files where file.pathExtension == suffix {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let current = best {
                if modified > current.modified { best = (file, modified) }
            } else {
                best = (file, modified)
            }
        }
        return best?.url
    }

    private static func appendText(_ buffer: inout MessageBuffer,
                                   text: String,
                                   role: ConversationRole,
                                   toolName: String,
                                   time: Date,
                                   id: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        buffer.append(ConversationMessage(id: id, role: role, text: text, toolName: toolName, time: time))
    }

    // 消息正文：字符串，或内容数组里的文本项
    private static func contentText(_ content: JSONValue) -> String {
        if let text = content.string { return text }
        guard let items = content.array else { return "" }
        var parts: [String] = []
        for item in items {
            switch item["type"].text {
            case "text", "input_text", "output_text":
                let text = item["text"].text
                if !text.isEmpty { parts.append(text) }
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    // 工具参数摘要：先取常用字段，其余参数拼成 键=值
    private static func summary(_ value: JSONValue) -> String {
        if let dictionary = value.object {
            for key in ["command", "cmd", "file_path", "path", "pattern", "query", "url", "prompt", "description"] {
                let text = dictionary[key]?.string ?? dictionary[key]?.text ?? ""
                if !text.isEmpty { return clipped(text) }
            }
            let parts = dictionary.keys.sorted().compactMap { key -> String? in
                let text = compactText(dictionary[key] ?? .null)
                return text.isEmpty ? nil : "\(key)=\(text)"
            }
            if !parts.isEmpty { return clipped(parts.joined(separator: " ")) }
        }
        if let text = value.string { return clipped(text) }
        return clipped(compactText(value))
    }

    private static func compactText(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return number == number.rounded() ? String(Int(number)) : String(number)
        case .string(let text):
            return text
        case .array(let items):
            return "[" + items.map(compactText).joined(separator: ", ") + "]"
        case .object(let dictionary):
            let pairs = dictionary.keys.sorted().map { key in
                "\(key): \(compactText(dictionary[key] ?? .null))"
            }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }

    private static func clipped(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        guard single.count > 300 else { return single }
        return String(single.prefix(300)) + "…"
    }
}
