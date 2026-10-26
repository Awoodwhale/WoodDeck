import Foundation

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var data: Data

    var text: String { String(decoding: data, as: UTF8.self) }

    func json() throws -> JSONValue {
        try JSONValue.parse(data)
    }
}

enum HTTPError: LocalizedError {
    case invalidURL(String)
    case transport(String)
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): "地址无效：\(url)"
        case .transport(let text): text
        case .status(let code, let body): "HTTP \(code)" + (body.isEmpty ? "" : "：\(body)")
        }
    }
}

struct HTTPClient: Sendable {
    var timeout: TimeInterval = 12
    var userAgent: String = "WoodDeck/1.0 (macOS)"

    static let shared = HTTPClient()

    func get(_ url: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await send(method: "GET", url: url, headers: headers, body: nil)
    }

    func post(_ url: String, headers: [String: String] = [:], body: Data? = nil) async throws -> HTTPResponse {
        try await send(method: "POST", url: url, headers: headers, body: body)
    }

    func send(method: String, url: String, headers: [String: String], body: Data?, timeout overrideTimeout: TimeInterval? = nil) async throws -> HTTPResponse {
        guard let parsed = URL(string: url), let scheme = parsed.scheme, scheme == "https" || scheme == "http", parsed.host != nil else {
            throw HTTPError.invalidURL(url)
        }
        var request = URLRequest(url: parsed)
        request.httpMethod = method
        request.timeoutInterval = overrideTimeout ?? timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = body
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var headerFields: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                if let key = key as? String, let value = value as? String { headerFields[key.lowercased()] = value }
            }
            return HTTPResponse(status: http?.statusCode ?? 0, headers: headerFields, data: data)
        } catch let error as URLError {
            throw HTTPError.transport(error.localizedDescription)
        }
    }
}

// 只读的 JSON 取值包装，避免每处都写类型判定
enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(object)
    }

    init(_ any: Any) {
        switch any {
        case let value as NSNull:
            self = .null
            _ = value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init))
        default:
            self = .null
        }
    }

    subscript(key: String) -> JSONValue {
        if case .object(let dictionary) = self, let value = dictionary[key] { return value }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return .null
    }

    var object: [String: JSONValue]? {
        if case .object(let dictionary) = self { return dictionary }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var float: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var int: Int? { float.map { Int($0.rounded()) } }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        default: return nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return ""
        }
    }

    var decimal: Decimal? {
        if let text = self.string, let value = Decimal(string: text) { return value }
        if let value = float { return Decimal(value) }
        return nil
    }

    func firstString(_ keys: String...) -> String {
        for key in keys where !self[key].isNull {
            let text = self[key].text
            if !text.isEmpty { return text }
        }
        return ""
    }
}

enum JSONDate {
    static func parse(_ value: JSONValue) -> Date? {
        switch value {
        case .number(let seconds):
            // 毫秒时间戳与秒时间戳都可能出现
            let normalized = seconds > 100_000_000_000 ? seconds / 1000 : seconds
            return Date(timeIntervalSince1970: normalized)
        case .string(let text):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.timeZone = TimeZone(identifier: "UTC")
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
                fallback.dateFormat = format
                if let date = fallback.date(from: text) { return date }
            }
            return nil
        default:
            return nil
        }
    }
}
