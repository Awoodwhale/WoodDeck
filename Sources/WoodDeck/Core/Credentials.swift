import Foundation
import Security
import SQLite3
import Yams

// 各应用已有的登录状态。只读取，不修改也不续期
enum Credentials {
    static func readJSON(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue.parse(data)
    }

    static func keychainPassword(service: String, account: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account } else { query[kSecAttrAccount as String] = kSecMatchLimitAll }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Claude Code 在 macOS 上把登录放在钥匙串，也保留了旧的 JSON 文件
    static func claudeCodeAccessToken(_ locations: DataLocations) -> String? {
        let file = locations.claudeHome.appending(path: ".credentials.json")
        if let json = readJSON(file), let token = oauthToken(json) { return token }
        for service in ["Claude Code-credentials", "Claude Code"] {
            if let text = keychainPassword(service: service), let data = text.data(using: .utf8),
               let json = try? JSONValue.parse(data), let token = oauthToken(json) { return token }
        }
        return nil
    }

    private static func oauthToken(_ json: JSONValue) -> String? {
        let candidates = [json["claudeAiOauth"]["accessToken"], json["accessToken"], json["access_token"]]
        for candidate in candidates {
            let text = candidate.text
            if !text.isEmpty { return text }
        }
        return nil
    }

    struct CodexAuth {
        var accessToken: String
        var accountID: String
    }

    static func codexAuth(_ locations: DataLocations) -> CodexAuth? {
        guard let json = readJSON(locations.codexHome.appending(path: "auth.json")) else { return nil }
        let token = json["tokens"]["access_token"].text
        guard !token.isEmpty else { return nil }
        return CodexAuth(accessToken: token, accountID: json["tokens"]["account_id"].text)
    }

    // Cursor 的登录保存在 VS Code 兼容的 SQLite 数据库中
    static func cursorAccessToken(_ locations: DataLocations) -> String? {
        let path = locations.cursorDatabase
        guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else { return nil }
        return SQLite.readText(path: path, sql: "SELECT value FROM ItemTable WHERE key = ?", arguments: ["cursorAuth/accessToken"])
    }

    struct DshAccount {
        var token: String
        var apiKey: String
    }

    // DeepSeek Harness 的 .credentials.yaml：refs 里是保存的 API 密钥，records 里是登录得到的授权
    static func dshAccount(_ locations: DataLocations) -> DshAccount? {
        let path = locations.dshHome.appending(path: ".credentials.yaml")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        guard let root = (try? Yams.load(yaml: text)) as? [String: Any] else { return nil }
        func find(_ keys: String...) -> String? {
            var current: Any? = root
            for key in keys {
                guard let dictionary = current as? [String: Any] else { return nil }
                current = dictionary[key]
            }
            switch current {
            case let value as String: return value
            case let value as NSNumber: return value.stringValue
            default: return nil
            }
        }
        var grant: String?
        let kind = find("records", "deepseek-account-platform/default", "kind")
        let issuer = (find("records", "deepseek-account-platform/default", "payload", "issuer") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if kind == "grant", issuer == "https://platform.deepseek.com" {
            grant = find("records", "deepseek-account-platform/default", "payload", "token")
        }
        let apiKey = find("refs", "DEEPSEEK_API_KEY") ?? ""
        let token = (grant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty && apiKey.isEmpty { return nil }
        return DshAccount(token: token, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Claude 桌面版在本机记录的额度历史，关闭联网读取的行使用它
    static func claudeDesktopUsageHistory(_ locations: DataLocations) -> (json: JSONValue, time: Date)? {
        let profile = locations.claudeDesktopProfile
        let candidates = [
            profile.appending(path: "plan-usage-history.json"),
            profile.appending(path: "usage-history.json")
        ]
        for url in candidates {
            guard let json = Credentials.readJSON(url) else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date) ?? Date()
            return (json, modified)
        }
        return nil
    }
}

// 只读的 SQLite 查询
enum SQLite {
    static func readText(path: URL, sql: String, arguments: [String] = []) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path(percentEncoded: false), &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    static func query(path: URL, sql: String) -> [[String]]? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path(percentEncoded: false), &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        let columns = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for index in 0..<columns {
                if let text = sqlite3_column_text(statement, index) {
                    row.append(String(cString: text))
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }
        return rows
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
