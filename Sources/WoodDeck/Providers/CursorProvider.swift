import Foundation

enum CursorProvider {
    static func fetch(context: ProviderContext, locations: DataLocations, http: HTTPClient) async throws -> ProviderResult {
        guard let token = Credentials.cursorAccessToken(locations) else {
            throw ProviderError.notConnected(Loc.t("请打开 Cursor 并确认已登录", "Open Cursor and make sure you are signed in."))
        }
        var quotas: [Quota] = []
        var plan = ""
        if let root = try await periodUsage(token: token, http: http) {
            quotas = parseQuotas(root)
            plan = root["membershipType"].text.trimmingCharacters(in: .whitespaces)
        }
        // 较旧的客户端会话只认网页版用量摘要，用量摘要也提供套餐名称
        if quotas.isEmpty || plan.isEmpty {
            do {
                let subject = try subject(from: token)
                let response = try await http.get("https://cursor.com/api/usage-summary", headers: [
                    "Cookie": "WorkosCursorSessionToken=" + escape(subject + "::" + token)
                ])
                try check(response)
                let root = try json(response)
                if quotas.isEmpty { quotas = parseQuotas(root) }
                plan = root["membershipType"].text.trimmingCharacters(in: .whitespaces)
            } catch {
                if quotas.isEmpty { throw error }
            }
        }
        guard !quotas.isEmpty else { throw invalidData }
        var result = ProviderResult(metrics: quotas.map(\.metric))
        if !plan.isEmpty {
            result.plan = plan
            result.planSource = Loc.t("Cursor 账户", "Cursor account")
        }
        return result
    }

    // Connect 协议的当前账期用量接口，请求体是空消息的 JSON 形式。请求本身失败时交给网页版用量摘要
    private static func periodUsage(token: String, http: HTTPClient) async throws -> JSONValue? {
        let response: HTTPResponse
        do {
            response = try await http.post("https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                                           headers: [
                                               "Authorization": "Bearer " + token,
                                               "Content-Type": "application/json; charset=utf-8"
                                           ],
                                           body: Data("{}".utf8))
        } catch {
            return nil
        }
        guard (200...299).contains(response.status) else { return nil }
        return try json(response)
    }

    private static func parseQuotas(_ root: JSONValue) -> [Quota] {
        var plan = root["planUsage"]
        if plan.object == nil { plan = root["individualUsage"]["plan"] }
        let reset = JSONDate.parse(root["billingCycleEnd"])
        var result: [Quota] = []
        for (key, label) in [("autoPercentUsed", "Cursor 模型"), ("apiPercentUsed", "其他模型")] {
            if let percent = plan[key].float {
                result.append(Quota(label: label, usedPercent: min(max(percent, 0), 100), resetAt: reset, windowMinutes: nil))
            }
        }
        if result.isEmpty, let total = plan["totalPercentUsed"].float {
            result.append(Quota(label: "账期额度", usedPercent: min(max(total, 0), 100), resetAt: reset, windowMinutes: nil))
        }
        return result
    }

    // 登录令牌是 JWT，载荷里的 sub 是网页版用量摘要需要的会话标识
    private static func subject(from token: String) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw invalidData }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { throw invalidData }
        let root: JSONValue
        do { root = try JSONValue.parse(data) } catch { throw invalidData }
        let subject = root["sub"].text
        guard !subject.isEmpty else { throw invalidData }
        return subject
    }

    private static func escape(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var escaped = ""
        for byte in text.utf8 {
            let character = Character(UnicodeScalar(byte))
            if allowed.contains(character) {
                escaped.append(character)
            } else {
                escaped += String(format: "%%%02X", byte)
            }
        }
        return escaped
    }

    private static var invalidData: ProviderError {
        ProviderError.readFailed(Loc.t("数据格式发生变化，暂时无法读取配额", "The data format has changed, so the quota cannot be read for now."))
    }

    private static func check(_ response: HTTPResponse) throws {
        switch response.status {
        case 200...299:
            return
        case 401, 403:
            throw ProviderError.notConnected(Loc.t("登录已失效或账户接口拒绝访问，请在原应用重新登录",
                                                   "The sign-in has expired or the account API refused access. Sign in again in the original app."))
        case 429:
            throw ProviderError.readFailed(Loc.t("请求频繁，稍后自动重试", "Too many requests. Retrying automatically later."))
        default:
            throw ProviderError.readFailed(Loc.t("账户接口暂时不可用", "The account API is temporarily unavailable."))
        }
    }

    private static func json(_ response: HTTPResponse) throws -> JSONValue {
        do { return try response.json() } catch { throw invalidData }
    }
}
