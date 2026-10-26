import Foundation

// Codex 把每个会话写成 sessions/<年>/<月>/<日>/rollout-*.jsonl，event_msg 里的 token_count 带本次用量与额度快照
enum CodexUsageReader {
    static func read(locations: DataLocations, now: Date, start: Date) -> UsageReading {
        var entries: [String: TokenEntry] = [:]
        var count = 0
        var errors = 0
        var available = false
        var latest: (time: Date, limits: JSONValue)?
        for folder in ["sessions", "archived_sessions"] {
            let root = locations.codexHome.appending(path: folder, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { continue }
            available = true
            for file in UsageLog.files(root, suffix: ".jsonl") {
                guard UsageLog.modified(file) >= start else { continue }
                count += 1
                guard let lines = UsageLog.lines(file) else {
                    errors += 1
                    continue
                }
                var model = "unknown"
                var lastTotal = ""
                var fileQuota: (time: Date, limits: JSONValue)?
                for line in lines {
                    switch parse(line, start: start, model: &model, lastTotal: &lastTotal, quota: &fileQuota) {
                    case .entry(let entry):
                        if let old = entries[entry.key], entry.total < old.total { continue }
                        entries[entry.key] = entry
                    case .next:
                        continue
                    case .failed:
                        errors += 1
                    }
                }
                if let fileQuota, latest.map({ fileQuota.time >= $0.time }) ?? true { latest = fileQuota }
            }
        }
        guard available else {
            return UsageReading(entries: [], note: Loc.t("未找到本机会话记录。", "No local session records were found."),
                                available: false, complete: true, quotas: [], plan: "")
        }
        let kept = entries.values
            .filter { $0.time >= start && $0.time <= now && $0.total > 0 }
            .sorted { $0.time < $1.time }
        var note = Loc.t("本机 \(UsageLog.day(start)) 起 · \(count) 个记录文件",
                         "This PC since \(UsageLog.day(start)) · \(Loc.count(count, "record file"))")
        if errors > 0 {
            note += Loc.t(" · \(errors) 处记录未能读取", " · \(Loc.count(errors, "record")) could not be read")
        }
        let quotas = latest.map { quotaParser($0.limits, now: now) } ?? []
        let plan = latest.map { $0.limits["plan_type"].text } ?? ""
        return UsageReading(entries: kept, note: note, available: true, complete: errors == 0, quotas: quotas, plan: plan)
    }

    private enum LineResult {
        case entry(TokenEntry)
        case next
        case failed
    }

    private static func parse(_ line: Data, start: Date, model: inout String, lastTotal: inout String,
                              quota: inout (time: Date, limits: JSONValue)?) -> LineResult {
        guard line.range(of: Data("\"token_count\"".utf8)) != nil
            || line.range(of: Data("\"turn_context\"".utf8)) != nil else { return .next }
        guard let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else { return .failed }
        let root = JSONValue(object)
        let time = JSONDate.parse(root["timestamp"])
        let type = root["type"].text
        let payload = root["payload"]
        if type == "turn_context" {
            model = payload["model"].text
            return .next
        }
        guard type == "event_msg", payload["type"].text == "token_count", let time else { return .next }
        let limits = payload["rate_limits"]
        if limits.object != nil, ["", "codex"].contains(limits["limit_id"].text),
           quota == nil || time >= quota!.time {
            quota = (time, limits)
        }
        let info = payload["info"]
        let cumulative = info["total_token_usage"]
        if cumulative.object != nil {
            let identity = UsageLog.raw(cumulative)
            if identity == lastTotal { return .next }
            lastTotal = identity
        }
        let usage = info["last_token_usage"]
        guard usage.object != nil, time >= start else { return .next }
        let input = UsageLog.count(usage["input_tokens"])
        let cached = min(input, UsageLog.count(usage["cached_input_tokens"]))
        let write = UsageLog.count(usage["cache_write_input_tokens"])
        let output = UsageLog.count(usage["output_tokens"])
        // 时间与累计用量、本次用量一起区分被复制到分支会话里的历史记录
        let key = "codex:\(time.timeIntervalSince1970):\(UsageLog.raw(cumulative)):\(UsageLog.raw(usage))"
        return .entry(TokenEntry(key: key, time: time, model: model,
                                 input: input - cached, output: output, cacheRead: cached, cacheWrite: write))
    }

    // 与上游 QuotaParser.Codex 一致：本地快照里 primary/secondary 两个窗口
    private static func quotaParser(_ limits: JSONValue, now: Date) -> [Quota] {
        var result: [Quota] = []
        for (field, fallback) in [("primary", "主要额度"), ("secondary", "次要额度")] {
            let window = limits[field]
            guard let used = window["used_percent"].float else { continue }
            let minutes = window["window_minutes"].int
            var reset = JSONDate.parse(window["resets_at"])
            if reset == nil, let after = window["reset_after_seconds"].float, after >= 0, after < 31_536_000 {
                reset = now.addingTimeInterval(after)
            }
            let label: String
            switch minutes {
            case 300?: label = "5 小时额度"
            case 10_080?: label = "每周额度"
            case .some(let value) where value > 0: label = "\(value) 分钟额度"
            default: label = fallback
            }
            result.append(Quota(label: label, usedPercent: min(max(used, 0), 100), resetAt: reset, windowMinutes: minutes))
        }
        return result
    }
}
