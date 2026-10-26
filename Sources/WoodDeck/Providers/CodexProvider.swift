import Foundation

enum CodexProvider {
    static func fetch(context: ProviderContext, locations: DataLocations, http: HTTPClient) async throws -> ProviderResult {
        guard let auth = Credentials.codexAuth(locations) else {
            throw ProviderError.notConnected(Loc.t("请先登录 Codex", "Sign in to Codex first"))
        }
        var headers = ["Authorization": "Bearer " + auth.accessToken]
        if !auth.accountID.isEmpty { headers["ChatGPT-Account-Id"] = auth.accountID }
        let response = try await http.get("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        try check(response)
        let root = try json(response)
        let quotas = parseQuotas(root, now: context.now)
        guard !quotas.isEmpty else { throw invalidData }
        var result = ProviderResult(metrics: quotas.map(\.metric))
        result.plan = root["plan_type"].text
        result.planSource = Loc.t("Codex 账户", "Codex account")
        return result
    }

    // 两个窗口分别对应 5 小时与每周额度，其它窗口长度按分钟数命名
    private static func parseQuotas(_ root: JSONValue, now: Date) -> [Quota] {
        let limits = root["rate_limit"]
        var result: [Quota] = []
        for field in ["primary_window", "secondary_window"] {
            let window = limits[field]
            guard let used = window["used_percent"].float else { continue }
            let minutes = window["limit_window_seconds"].float.map { Int($0 / 60) }
            var reset = JSONDate.parse(window["reset_at"])
            if reset == nil, let after = window["reset_after_seconds"].float, after >= 0, after < 31_536_000 {
                reset = now.addingTimeInterval(after)
            }
            let label: String
            switch minutes {
            case 300?: label = "5 小时额度"
            case 10080?: label = "每周额度"
            case let value? where value > 0: label = "\(value) 分钟额度"
            default: label = field == "primary_window" ? "主要额度" : "次要额度"
            }
            result.append(Quota(label: label, usedPercent: min(max(used, 0), 100), resetAt: reset, windowMinutes: minutes))
        }
        return result
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
