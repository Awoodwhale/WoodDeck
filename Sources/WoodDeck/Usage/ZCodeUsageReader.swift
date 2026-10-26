import Foundation

// ZCode 在 cli/db/db.sqlite 的 model_usage 表里为每次模型请求记一行，input_tokens 含缓存部分
enum ZCodeUsageReader {
    static func read(locations: DataLocations, now: Date, start: Date) -> UsageReading {
        let database = locations.zcodeHome.appending(path: "cli/db/db.sqlite")
        guard FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) else {
            return UsageReading(entries: [], note: Loc.t("未找到本机 ZCode 记录。", "No local ZCode records were found."),
                                available: false, complete: true, quotas: [], plan: "")
        }
        let since = Int(start.timeIntervalSince1970 * 1000)
        let sql = "SELECT id, model_id, COALESCE(completed_at, started_at), input_tokens, output_tokens, "
            + "cache_read_input_tokens, cache_creation_input_tokens FROM model_usage "
            + "WHERE status <> 'running' AND started_at >= \(since)"
        guard let rows = SQLite.query(path: database, sql: sql) else {
            return UsageReading(entries: [], note: Loc.t("ZCode 记录暂时无法读取。", "The ZCode records cannot be read right now."),
                                available: true, complete: false, quotas: [], plan: "")
        }
        let entries = rows.compactMap { row -> TokenEntry? in
            guard row.count >= 7, !row[0].isEmpty, let millis = Double(row[2]) else { return nil }
            let time = Date(timeIntervalSince1970: millis / 1000)
            func count(_ index: Int) -> Int { max(0, Int(row[index]) ?? 0) }
            let input = count(3)
            let read = min(input, count(5))
            let write = min(input - read, count(6))
            return TokenEntry(key: "zcode:" + row[0], time: time, model: row[1],
                              input: input - read - write, output: count(4), cacheRead: read, cacheWrite: write)
        }
        .filter { $0.time >= start && $0.time <= now && $0.total > 0 }
        .sorted { $0.time < $1.time }
        let note = Loc.t("本机 ZCode \(UsageLog.day(start)) 起 · \(entries.count) 次模型请求",
                         "Local ZCode since \(UsageLog.day(start)) · \(Loc.count(entries.count, "model request"))")
        return UsageReading(entries: entries, note: note, available: true, complete: true, quotas: [], plan: "")
    }
}
