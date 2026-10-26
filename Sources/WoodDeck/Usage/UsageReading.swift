import Foundation

struct UsageReading {
    var entries: [TokenEntry]
    var note: String
    var available: Bool
    var complete: Bool
    var quotas: [Quota]
    var plan: String
}

// 各会话记录来源共用的文件枚举、分行与取值
enum UsageLog {
    // 递归列出目录下指定后缀的文件；跳过符号链接，结果按路径排序
    static func files(_ root: URL, suffix: String) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let wanted = suffix.lowercased()
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  url.lastPathComponent.lowercased().hasSuffix(wanted) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    // 只列目录下的一层文件，用于会话数据库所在的文件夹
    static func directFiles(_ folder: URL, suffix: String) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        let wanted = suffix.lowercased()
        return children.filter {
            guard let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true && $0.lastPathComponent.lowercased().hasSuffix(wanted)
        }.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    // 文件按行分开，末尾没有换行的半行留空
    static func lines(_ url: URL) -> [Data]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return split(data)
    }

    static func split(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            if index > start { lines.append(Data(data[start..<index])) }
            start = data.index(after: index)
        }
        return lines
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // 备注里使用的日期，取本地日历日
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // Token 计数取值：非数字按 0，负数按 0
    static func count(_ value: JSONValue) -> Int {
        min(max(value.int ?? 0, 0), 1_000_000_000_000_000)
    }

    // 把 JSON 取值规整成文本，用于组成去重用的 key
    static func raw(_ value: JSONValue) -> String {
        let object = any(value)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func any(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .number(let number): return number
        case .string(let text): return text
        case .array(let items): return items.map(any)
        case .object(let fields): return fields.mapValues(any)
        }
    }
}
