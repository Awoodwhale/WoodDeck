import Foundation
import JavaScriptCore
import Synchronization

// JavaScriptCore 把这个函数声明在未随 SDK 发布的头文件里，框架本身导出它，用于限制脚本的执行时间
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func setExecutionTimeLimit(_ group: JSContextGroupRef?, _ limit: Double,
                                   _ callback: (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool)?,
                                   _ context: UnsafeMutableRawPointer?)

@_silgen_name("JSContextGroupClearExecutionTimeLimit")
private func clearExecutionTimeLimit(_ group: JSContextGroupRef?)

private enum Limits {
    static let requests = 16
    static let body = 1_000_000
    static let script = 128_000
    static let memory = 16_000
    static let seconds: TimeInterval = 10
    static let logs = 30
}

// 请求过程中的本地错误，文本直接交给脚本里的 Error
private struct SandboxFailure: Error {
    var text: String
}

// 指标字段不合格的原因，作为警告显示
private struct MetricFailure: Error {
    var text: String
}

private final class ResponseBox: @unchecked Sendable {
    var value: Result<HTTPResponse, Error>?
}

// 脚本要求下次运行时重新收到的状态，按站点与脚本区分
private enum ScriptMemory {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var values: [String: String] = [:]

    static func value(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    static func keep(_ value: String?, _ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

private extension JSONValue {
    // 还原成 JSONSerialization 可以写出的对象
    var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let items): items.map(\.anyValue)
        case .object(let object): object.mapValues(\.anyValue)
        }
    }
}

enum ScriptProvider {
    static func run(script: String, site: String, secret: String, language: String, now: Date, http: HTTPClient) async throws -> ProviderResult {
        if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProviderError.readFailed("请填写 fetchUsage(ctx) 函数。")
        }
        if script.utf16.count > Limits.script {
            throw ProviderError.readFailed("脚本最多为 128,000 个字符。")
        }
        let key = site + script
        let session = ScriptSession(script: script, site: site, secret: secret, language: language, now: now,
                                    http: http, memory: ScriptMemory.value(key))
        let output = try await session.execute()
        var result = try MetricParser.parse(output.json)
        if let kept = output.memory, kept.utf16.count <= Limits.memory {
            ScriptMemory.keep(kept, key)
        } else {
            if output.memory != nil { result.warnings.append("memory 超过 16 KB，未保留。") }
            ScriptMemory.keep(nil, key)
        }
        return session.redacted(result)
    }
}

// 一次脚本运行的沙盒。JavaScriptCore 只能同步求值，所以整个运行放在单独的线程上，
// 脚本里的每次请求在同一线程上用信号量与 RunLoop 等待异步的 HTTP 结果。
// 状态只在那个线程上读写，超时标记用原子量，因此可以交给线程使用。
private final class ScriptSession: @unchecked Sendable {
    private let script: String
    private let site: String
    private let secret: String
    private let language: String
    private let now: Date
    private let http: HTTPClient
    private let memory: String?
    private let deadline: Date
    private let terminated = Atomic(false)
    private var requests = 0
    private var logs = 0

    init(script: String, site: String, secret: String, language: String, now: Date, http: HTTPClient, memory: String?) {
        self.script = script
        self.site = site
        self.secret = secret
        self.language = language
        self.now = now
        self.http = http
        self.memory = memory
        self.deadline = Date().addingTimeInterval(Limits.seconds)
    }

    func execute() async throws -> (json: String, memory: String?) {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { [self] in
                do {
                    continuation.resume(returning: try evaluate())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "ScriptProvider"
            thread.start()
        }
    }

    // 把脚本返回内容里的密钥替换掉，避免出现在界面与日志里
    func redacted(_ result: ProviderResult) -> ProviderResult {
        var output = result
        output.plan = redact(result.plan)
        output.scope = redact(result.scope)
        output.details = [:]
        for (key, value) in result.details { output.details[redact(key)] = redact(value) }
        output.warnings = result.warnings.map(redact)
        output.metrics = result.metrics.map { metric in
            var copy = metric
            copy.label = redact(metric.label)
            copy.metricID = redact(metric.metricID)
            copy.currency = redact(metric.currency)
            copy.unit = redact(metric.unit)
            copy.value = redact(metric.value)
            copy.suffix = redact(metric.suffix)
            copy.note = redact(metric.note)
            copy.resetText = redact(metric.resetText)
            return copy
        }
        return output
    }

    private func evaluate() throws -> (json: String, memory: String?) {
        guard let context = JSContext() else { throw ProviderError.readFailed("JavaScript 沙盒初始化失败。") }
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        setExecutionTimeLimit(group, Limits.seconds, terminateCallback, Unmanaged.passUnretained(self).toOpaque())
        defer { clearExecutionTimeLimit(group) }

        let send: @convention(block) (String, String) -> String = { [self] method, argument in
            self.send(method, argument)
        }
        let logger: @convention(block) (String) -> Void = { [self] text in
            self.log(text)
        }
        context.setObject(send, forKeyedSubscript: "__request" as NSString)
        context.setObject(logger, forKeyedSubscript: "__log" as NSString)
        context.setObject(try contextJSON(), forKeyedSubscript: "__context" as NSString)

        context.exception = nil
        context.evaluateScript(Self.wrapper(script: script))
        if let exception = context.exception { throw failure(exception) }

        // 脚本里的 await 在求值返回时已由 JavaScriptCore 排空微任务，这里再取回结果
        while true {
            if Date() >= deadline { throw ProviderError.readFailed("脚本超过 10 秒。") }
            context.exception = nil
            let value = context.evaluateScript("__finish()")
            if let exception = context.exception { throw failure(exception) }
            let envelope = try Self.envelope(value?.toString())
            if envelope.pending {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                continue
            }
            if let error = envelope.error { throw ProviderError.readFailed(redact(error)) }
            guard let json = envelope.value else {
                throw ProviderError.readFailed("fetchUsage 必须返回数组，每一项是一条配额。")
            }
            if json.utf8.count > Limits.body { throw ProviderError.readFailed("返回内容超过 1 MB。") }
            return (json, envelope.memory)
        }
    }

    private func contextJSON() throws -> String {
        var payload: [String: Any] = [
            "site": site,
            "secrets": ["key": secret],
            "language": language,
            "now": Self.timestamp(now),
            "memory": [String: Any]()
        ]
        if let memory, let data = memory.data(using: .utf8), case .object(let object) = try? JSONValue.parse(data) {
            payload["memory"] = object.mapValues(\.anyValue)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else {
            throw ProviderError.readFailed("脚本上下文无法序列化。")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func failure(_ exception: JSValue) -> ProviderError {
        if terminated.load(ordering: .relaxed) { return .readFailed("脚本超过 10 秒。") }
        let message: JSValue! = exception.objectForKeyedSubscript("message")
        if let message, !message.isUndefined, !message.isNull {
            let described: String? = message.toString()
            if let described, !described.isEmpty { return .readFailed(redact(described)) }
        }
        let described: String? = exception.toString()
        return .readFailed(redact(described ?? "脚本出错。"))
    }

    private func send(_ method: String, _ argument: String) -> String {
        requests += 1
        if requests > Limits.requests { return Self.failureText("一次刷新最多请求 16 次。") }
        do {
            return try perform(method, argument)
        } catch let failure as SandboxFailure {
            return Self.failureText(failure.text)
        } catch {
            return Self.failureText("无法读取接口，请检查地址、网络和凭据。")
        }
    }

    private func perform(_ method: String, _ argument: String) throws -> String {
        guard let data = argument.data(using: .utf8), let root = try? JSONValue.parse(data), root.object != nil else {
            throw SandboxFailure(text: "请求参数无效。")
        }
        let url: URL
        do {
            url = try ProviderCatalog.validateURL(root["url"].string ?? "")
        } catch let error as ProviderError {
            throw SandboxFailure(text: error.errorDescription ?? "站点地址无效。")
        }

        let options = root["options"]
        var headers: [String: String] = [:]
        if let object = options["headers"].object {
            for (name, value) in object {
                guard case .string(let text) = value else { throw SandboxFailure(text: "请求头无效。") }
                if name.caseInsensitiveCompare("Host") == .orderedSame || name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                    throw SandboxFailure(text: "请求头无效。")
                }
                if text.contains("\r") || text.contains("\n") { throw SandboxFailure(text: "请求头不能包含换行。") }
                headers[name] = text
            }
        }

        let milliseconds = min(max(options["timeout"].int ?? 8000, 100), 10000)
        let timeout = TimeInterval(milliseconds) / 1000
        let limit = min(deadline, Date().addingTimeInterval(timeout))

        var body: Data?
        if method == "POST" {
            let value = options["body"]
            if !value.isNull {
                let text: String
                let plainText: Bool
                switch value {
                case .string(let string):
                    text = string
                    plainText = true
                case .array, .object:
                    guard let encoded = try? JSONSerialization.data(withJSONObject: value.anyValue, options: [.fragmentsAllowed]) else {
                        throw SandboxFailure(text: "请求正文无效。")
                    }
                    text = String(decoding: encoded, as: UTF8.self)
                    plainText = false
                default:
                    text = value.text
                    plainText = true
                }
                if text.utf8.count > Limits.body { throw SandboxFailure(text: "请求正文超过 1 MB。") }
                body = Data(text.utf8)
                if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                    headers["Content-Type"] = plainText ? "text/plain; charset=utf-8" : "application/json"
                }
            }
        }

        let response = try wait(until: limit) {
            try await self.http.send(method: method, url: url.absoluteString, headers: headers, body: body, timeout: timeout)
        }
        if response.data.count > Limits.body { throw SandboxFailure(text: "响应超过 1 MB。") }
        let payload: [String: Any] = ["status": response.status, "headers": response.headers, "body": response.text]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else {
            throw SandboxFailure(text: "响应无法读取。")
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    // 在后台任务上发出请求，当前线程用信号量与 RunLoop 等待它结束
    private func wait(until limit: Date, _ work: @escaping () async throws -> HTTPResponse) throws -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            do {
                box.value = .success(try await work())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            let remaining = limit.timeIntervalSinceNow
            if remaining <= 0 { throw SandboxFailure(text: "读取超时或已取消。") }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: min(remaining, 0.01)))
        }
        guard let result = box.value else { throw SandboxFailure(text: "读取超时或已取消。") }
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            if let http = error as? HTTPError, case .transport = http {
                throw SandboxFailure(text: "无法连接到站点。")
            }
            throw SandboxFailure(text: "无法读取接口，请检查地址、网络和凭据。")
        }
    }

    private func log(_ text: String) {
        guard logs < Limits.logs else { return }
        logs += 1
        FileHandle.standardError.write(Data("脚本日志：\(redact(text))\n".utf8))
    }

    private func redact(_ text: String) -> String {
        var output = text
        if !secret.isEmpty {
            let hidden = "[密钥已隐藏]"
            output = output.replacingOccurrences(of: secret, with: hidden)
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            if let escaped = secret.addingPercentEncoding(withAllowedCharacters: allowed), escaped != secret {
                output = output.replacingOccurrences(of: escaped, with: hidden)
            }
        }
        return output.count > 500 ? String(output.prefix(500)) : output
    }

    func markTerminated() { terminated.store(true, ordering: .relaxed) }

    private struct Envelope {
        var pending = false
        var error: String?
        var value: String?
        var memory: String?
    }

    private static func envelope(_ text: String?) throws -> Envelope {
        guard let text, let data = text.data(using: .utf8), let json = try? JSONValue.parse(data), let object = json.object else {
            throw ProviderError.readFailed("脚本没有返回结果。")
        }
        return Envelope(pending: object["pending"]?.bool == true, error: object["error"]?.string,
                        value: object["value"]?.string, memory: object["memory"]?.string)
    }

    private static func failureText(_ text: String) -> String {
        let payload: [String: Any] = ["error": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else {
            return "{\"error\":\"请求失败。\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    // 与上游一致的本地时间带偏移表示，脚本用 slice(0, 10) 与 slice(-6) 取日期和时区
    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let absolute = abs(seconds)
        let offset = String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
        return formatter.string(from: date) + offset
    }

    private static func wrapper(script: String) -> String {
        prefix + "\n" + script + "\n" + suffix
    }

    private static let prefix = """
    (function (send, logger) {
      const ctx = JSON.parse(__context);
      delete globalThis.__request; delete globalThis.__log; delete globalThis.__context;
      async function request(method, url, options) {
        const response = JSON.parse(send(method, JSON.stringify({ url: url, options: options || {} })));
        if (response.error) throw new Error(response.error);
        return { status: response.status, headers: response.headers,
          text: function () { return response.body; }, json: function () { return JSON.parse(response.body); } };
      }
      ctx.http = Object.freeze({ get: (url, options) => request("GET", url, options), post: (url, options) => request("POST", url, options) });
      ctx.log = function (text) { logger(String(text)); };
      const console = Object.freeze({ log: ctx.log, info: ctx.log, warn: ctx.log, error: ctx.log, debug: ctx.log });
      Object.freeze(ctx.secrets); Object.freeze(ctx);
      let __done = false, __failed = false, __error = undefined, __value = undefined, __memory = null;
      const fetcher = (function () {
    """

    private static let suffix = """
        if (typeof fetchUsage !== "function") throw new Error("脚本必须定义 fetchUsage(ctx)。");
        return fetchUsage;
      })();
      Promise.resolve().then(function () { return fetcher(ctx); }).then(function (result) {
        try {
          __value = JSON.stringify(result);
          if (result && typeof result === "object" && !Array.isArray(result) && result.memory && typeof result.memory === "object") {
            __memory = JSON.stringify(result.memory);
          }
        } catch (error) { __failed = true; __error = error; }
        __done = true;
      }, function (error) { __failed = true; __error = error; __done = true; });
      globalThis.__finish = function () {
        if (!__done) return JSON.stringify({ pending: true });
        if (__failed) return JSON.stringify({ error: __error && __error.message !== undefined ? String(__error.message) : String(__error) });
        if (typeof __value !== "string") return JSON.stringify({ error: "fetchUsage 必须返回数组，每一项是一条配额。" });
        return JSON.stringify({ value: __value, memory: __memory });
      };
    })(__request, __log);
    """
}

private let terminateCallback: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool = { _, info in
    guard let info else { return true }
    Unmanaged<ScriptSession>.fromOpaque(info).takeUnretainedValue().markTerminated()
    return true
}

// 脚本返回值解析：数组形式是文本指标，对象形式是带类型的指标
private enum MetricParser {
    static func parse(_ text: String) throws -> ProviderResult {
        guard let data = text.data(using: .utf8), let root = try? JSONValue.parse(data) else {
            throw ProviderError.readFailed("脚本返回的内容不是有效的 JSON。")
        }
        if let items = root.array { return try parseText(items) }
        guard let items = root["metrics"].array else {
            throw ProviderError.readFailed("fetchUsage 必须返回数组，每一项是一条配额。")
        }
        var metrics: [UsageMetric] = []
        var warnings: [String] = []
        for (index, item) in items.enumerated() {
            if index >= 100 {
                warnings.append("最多显示 100 项指标。")
                break
            }
            do {
                metrics.append(try parseMetric(item, index: index))
            } catch {
                warnings.append("metrics[\(index)].\(reason(of: error))")
            }
        }
        if metrics.isEmpty {
            throw ProviderError.readFailed(warnings.first ?? "metrics 为空，未返回可显示的额度。")
        }
        var details: [String: String] = [:]
        if let object = root["details"].object {
            for (key, value) in object.prefix(30) { details[short(key)] = short(plain(value)) }
        }
        if let extra = root["warnings"].array {
            for item in extra.prefix(10) where item.string != nil {
                warnings.append(short(item.string ?? ""))
            }
        }
        return ProviderResult(metrics: metrics, plan: short(scalar(root["plan"])), scope: scalar(root["scope"]),
                              details: details, warnings: warnings)
    }

    private static func parseText(_ items: [JSONValue]) throws -> ProviderResult {
        if items.isEmpty { throw ProviderError.readFailed("返回的数组为空，至少需要一项。") }
        var metrics: [UsageMetric] = []
        var warnings: [String] = []
        for (index, item) in items.enumerated() {
            if index >= 100 {
                warnings.append("最多显示 100 项。")
                break
            }
            do {
                metrics.append(try parseTextItem(item, index: index))
            } catch {
                warnings.append("第 \(index + 1) 项：\(reason(of: error))")
            }
        }
        if metrics.isEmpty { throw ProviderError.readFailed(warnings.first ?? "返回的数组为空，至少需要一项。") }
        return ProviderResult(metrics: metrics, warnings: warnings)
    }

    private static func parseTextItem(_ item: JSONValue, index: Int) throws -> UsageMetric {
        guard item.object != nil else { throw MetricFailure(text: "必须是对象。") }
        func string(_ key: String, required: Bool = false) throws -> String {
            let value = item[key]
            if value.isNull {
                if required { throw MetricFailure(text: "\(key) 为必填项。") }
                return ""
            }
            guard case .string(let raw) = value else { throw MetricFailure(text: "\(key) 必须是字符串。") }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if required && trimmed.isEmpty { throw MetricFailure(text: "\(key) 为必填项，不能为空。") }
            return short(trimmed)
        }
        let title = try string("title", required: true)
        var percent: Double?
        let number = item["percent"]
        if !number.isNull {
            guard case .number(let value) = number, value.isFinite else {
                throw MetricFailure(text: "percent 必须是数字。")
            }
            if value < 0 || value > 100 { throw MetricFailure(text: "percent 必须在 0 到 100 之间。") }
            percent = value
        }
        return UsageMetric(kind: .text, label: title, metricID: String(index), percent: percent,
                           value: try string("value"), suffix: try string("suffix"),
                           note: try string("note"), resetText: try string("resetAt"))
    }

    private static func parseMetric(_ item: JSONValue, index: Int) throws -> UsageMetric {
        let kind: MetricKind
        switch scalar(item["kind"]) {
        case "percent": kind = .percent
        case "balance": kind = .balance
        case "spend": kind = .spend
        case "count": kind = .count
        default: throw MetricFailure(text: "kind 必须是 percent、balance、spend 或 count。")
        }
        let label = scalar(item["label"])
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw MetricFailure(text: "label 缺失。") }

        func number(_ key: String, required: Bool = false) throws -> Decimal? {
            let value = item[key]
            if value.isNull {
                if required { throw MetricFailure(text: "\(key) 缺失或不是有效数字。") }
                return nil
            }
            guard case .number(let raw) = value, raw.isFinite, abs(raw) <= 1e18 else {
                throw MetricFailure(text: "\(key) 缺失或不是有效数字。")
            }
            return Decimal(raw)
        }
        func date(_ key: String) throws -> Date? {
            let value = item[key]
            if value.isNull { return nil }
            if case .number(let milliseconds) = value {
                if abs(milliseconds) < 8.64e15 { return Date(timeIntervalSince1970: milliseconds / 1000) }
                throw MetricFailure(text: "\(key) 必须是 ISO 时间或毫秒时间戳。")
            }
            if case .string = value, let parsed = JSONDate.parse(value) { return parsed }
            throw MetricFailure(text: "\(key) 必须是 ISO 时间或毫秒时间戳。")
        }
        func flag(_ key: String) throws -> Bool {
            switch item[key] {
            case .null: return false
            case .bool(let value): return value
            default: throw MetricFailure(text: "\(key) 必须是布尔值。")
            }
        }

        let percent = try number("percent", required: kind == .percent)
        let amount = try number("amount", required: kind == .balance || kind == .spend)
        let total = try number("total", required: kind == .count)
        let used = try number("used", required: kind == .count)
        let window = try number("window")
        if let window {
            let minutes = NSDecimalNumber(decimal: window).doubleValue
            if minutes <= 0 || minutes > 5_256_000 || minutes != minutes.rounded() {
                throw MetricFailure(text: "window 必须是正整数分钟。")
            }
        }
        if let percent, percent < 0 { throw MetricFailure(text: "额度或已用量不能为负数。") }
        if let total, total < 0 { throw MetricFailure(text: "额度或已用量不能为负数。") }
        if let used, used < 0 { throw MetricFailure(text: "额度或已用量不能为负数。") }
        if kind == .spend, let amount, amount < 0 { throw MetricFailure(text: "额度或已用量不能为负数。") }
        if kind == .count, let total, total == 0 { throw MetricFailure(text: "total 必须大于 0。") }

        let identifier = scalar(item["id"])
        return UsageMetric(kind: kind, label: short(label),
                           metricID: identifier.isEmpty ? String(index) : short(identifier),
                           window: window.map { Int(truncating: NSDecimalNumber(decimal: $0)) },
                           percent: percent.map { NSDecimalNumber(decimal: $0).doubleValue },
                           amount: amount, total: total, used: used,
                           currency: short(scalar(item["currency"])), unit: short(scalar(item["unit"])),
                           unlimited: try flag("unlimited"),
                           resetAt: try date("resetAt"), expiresAt: try date("expiresAt"),
                           atLeast: try flag("atLeast"))
    }

    // 只有字符串字段能当作文本，其它类型与上游一样视为空
    private static func scalar(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return ""
    }

    // 详情里的任意值按其 JSON 文本显示
    private static func plain(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .bool, .number, .string: return value.text
        case .array, .object:
            guard let data = try? JSONSerialization.data(withJSONObject: value.anyValue, options: [.fragmentsAllowed]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func short(_ text: String) -> String {
        text.count > 500 ? String(text.prefix(500)) : text
    }

    private static func reason(of error: Error) -> String {
        if let failure = error as? MetricFailure { return failure.text }
        if let provider = error as? ProviderError { return provider.errorDescription ?? "" }
        return error.localizedDescription
    }
}
