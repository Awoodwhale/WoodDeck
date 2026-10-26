import Foundation

// Antigravity 桌面版与 CLI 为每个会话留一个 SQLite 数据库，消息的用量记在 steps.metadata 里的 protobuf：
//   steps.metadata 里 1 是 created_at(Timestamp)、9 是 model_usage(ModelUsageStats)
//   gen_metadata 里 1 是 chat(ChatModelMetadata)、19 是 response_model
//   ModelUsageStats 里 2 输入、3 输出、4 缓存写入、5 缓存读取、7 message id
// input 不含缓存读取，因此两者都要计
enum AntigravityUsageReader {
    static func read(locations: DataLocations, now: Date, start: Date) -> UsageReading {
        let folders = locations.antigravityDatabases()
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !folders.isEmpty else {
            return UsageReading(entries: [], note: Loc.t("未找到本机 Antigravity 会话记录。", "No local Antigravity session records were found."),
                                available: false, complete: true, quotas: [], plan: "")
        }
        var entries: [String: TokenEntry] = [:]
        var count = 0
        var failed = 0
        for folder in folders {
            for database in UsageLog.directFiles(folder, suffix: ".db") {
                // 最近的消息可能还在预写日志里，它也算进数据库的写入时间
                let wal = URL(filePath: database.path(percentEncoded: false) + "-wal")
                var modified = UsageLog.modified(database)
                if FileManager.default.fileExists(atPath: wal.path(percentEncoded: false)) {
                    modified = max(modified, UsageLog.modified(wal))
                }
                guard modified >= start else { continue }
                count += 1
                guard let parsed = parse(database, start: start) else {
                    failed += 1
                    continue
                }
                for entry in parsed where entries[entry.key] == nil { entries[entry.key] = entry }
            }
        }
        let kept = entries.values
            .filter { $0.time >= start && $0.time <= now }
            .sorted { $0.time < $1.time }
        var note = Loc.t("本机 Antigravity 与 Antigravity CLI \(UsageLog.day(start)) 起 · \(count) 个会话",
                         "Local Antigravity and Antigravity CLI since \(UsageLog.day(start)) · \(Loc.count(count, "session"))")
        if failed > 0 {
            note += Loc.t(" · \(failed) 个会话暂时无法读取", " · \(Loc.count(failed, "session")) cannot be read right now")
        }
        return UsageReading(entries: kept, note: note, available: true, complete: failed == 0, quotas: [], plan: "")
    }

    private static func parse(_ database: URL, start: Date) -> [TokenEntry]? {
        guard let steps = SQLite.query(path: database, sql: "SELECT hex(metadata) FROM steps WHERE metadata IS NOT NULL") else { return nil }
        var models: [String: String] = [:]
        for row in SQLite.query(path: database, sql: "SELECT hex(data) FROM gen_metadata WHERE data IS NOT NULL") ?? [] {
            let chat = field(bytes(row), 1)
            let id = text(field(field(chat, 4), 7))
            let model = text(field(chat, 19))
            if !id.isEmpty && !model.isEmpty { models[id] = model }
        }
        var entries: [TokenEntry] = []
        for row in steps {
            let metadata = bytes(row)
            let usage = field(metadata, 9)
            guard !usage.isEmpty, let seconds = number(field(metadata, 1), 1), seconds <= UInt64(Int.max) else { continue }
            let id = text(field(usage, 7))
            if id.isEmpty { continue }
            let time = Date(timeIntervalSince1970: Double(seconds))
            let entry = TokenEntry(key: "ag:" + id, time: time, model: models[id] ?? "",
                                   input: count(usage, 2), output: count(usage, 3),
                                   cacheRead: count(usage, 5), cacheWrite: count(usage, 4))
            if entry.total > 0 && time >= start { entries.append(entry) }
        }
        return entries
    }

    private static func bytes(_ row: [String]) -> [UInt8] {
        guard let hex = row.first, let data = hexData(hex) else { return [] }
        return data
    }

    private static func hexData(_ text: String) -> [UInt8]? {
        let characters = Array(text.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = hexDigit(characters[index]), let low = hexDigit(characters[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func hexDigit(_ character: UInt8) -> UInt8? {
        switch character {
        case 0x30...0x39: return character - 0x30
        case 0x41...0x46: return character - 0x41 + 10
        case 0x61...0x66: return character - 0x61 + 10
        default: return nil
        }
    }

    private static func count(_ message: [UInt8], _ wanted: Int) -> Int {
        Int(min(number(message, wanted) ?? 0, UInt64(Int.max)))
    }

    private static func text(_ message: [UInt8]) -> String {
        String(decoding: message, as: UTF8.self)
    }

    // 取第一个编号相符的长度限定字段：嵌套消息或字符串
    private static func field(_ message: [UInt8], _ wanted: Int) -> [UInt8] {
        for item in fields(message) where item.number == wanted && item.wire == 2 { return item.data }
        return []
    }

    private static func number(_ message: [UInt8], _ wanted: Int) -> UInt64? {
        for item in fields(message) where item.number == wanted && item.wire == 0 { return item.value }
        return nil
    }

    // 只认变长整数与长度限定两类；格式不对时就此结束
    private static func fields(_ message: [UInt8]) -> [(number: Int, wire: Int, value: UInt64, data: [UInt8])] {
        var result: [(number: Int, wire: Int, value: UInt64, data: [UInt8])] = []
        var index = 0
        while index < message.count {
            guard let key = varint(message, &index) else { break }
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            switch wire {
            case 0:
                guard let value = varint(message, &index) else { return result }
                result.append((number, wire, value, []))
            case 2:
                guard let size = varint(message, &index), size <= UInt64(message.count - index) else { return result }
                let end = index + Int(size)
                result.append((number, wire, 0, Array(message[index..<end])))
                index = end
            case 1:
                index += 8
            case 5:
                index += 4
            default:
                return result
            }
        }
        return result
    }

    private static func varint(_ message: [UInt8], _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift = 0
        while shift < 64 && index < message.count {
            let byte = message[index]
            index += 1
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte < 0x80 { return value }
            shift += 7
        }
        return nil
    }
}
