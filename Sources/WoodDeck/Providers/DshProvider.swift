import Foundation

// DeepSeek Harness 登录的 DeepSeek 平台账户余额，以及它在 Models 页面保存的 API 密钥对应的余额。
enum DshProvider {
    private static let platform = "https://platform.deepseek.com"

    static func fetch(context: ProviderContext, locations: DataLocations, http: HTTPClient) async throws -> ProviderResult {
        guard let account = Credentials.dshAccount(locations), !(account.token.isEmpty && account.apiKey.isEmpty) else {
            throw ProviderError.notConnected(Loc.t("请先在 DeepSeek Harness 中登录 DeepSeek 账户，或保存 API 密钥",
                                                    "Sign in to a DeepSeek account in DeepSeek Harness, or save a DeepSeek API key there."))
        }
        if account.token.isEmpty {
            return try await apiKeyResult(account.apiKey, http: http)
        }
        return try await accountResult(account.token, http: http)
    }

    private static func accountResult(_ token: String, http: HTTPClient) async throws -> ProviderResult {
        let response = try await http.get(platform + "/api/v0/users/get_user_summary",
                                          headers: ["x-dsh-auth-token": token])
        if response.status == 401 { throw expired() }
        guard response.status == 200 else { throw ProviderError.readFailed("HTTP \(response.status)") }
        guard let root = try? response.json() else {
            throw ProviderError.readFailed(Loc.t("DeepSeek 账户接口返回的内容无法识别。", "The DeepSeek account API returned content that is not recognized."))
        }
        // 与 DeepSeek Harness 一致：HTTP 401 或 code 40003 都表示保存的登录已失效
        if root["code"].float == 40003 { throw expired() }
        return ProviderResult(metrics: try summary(root),
                              planSource: Loc.t("DeepSeek Harness · DeepSeek 账户", "DeepSeek Harness · DeepSeek account"),
                              scope: "account")
    }

    private static func expired() -> ProviderError {
        .notConnected(Loc.t("DeepSeek Harness 的登录已失效，请在 DeepSeek Harness 中重新登录",
                            "The DeepSeek Harness sign-in has expired. Sign in again in DeepSeek Harness."))
    }

    // GET /user/balance：每个币种的 total_balance 是赠送余额与充值余额之和
    private static func apiKeyResult(_ apiKey: String, http: HTTPClient) async throws -> ProviderResult {
        let response = try await http.get("https://api.deepseek.com/user/balance",
                                          headers: ["Authorization": "Bearer \(apiKey)"])
        if response.status == 401 {
            throw ProviderError.notConnected(Loc.t("DeepSeek 拒绝了 DeepSeek Harness 中保存的 API 密钥，请在 DeepSeek Harness 中更新",
                                                    "DeepSeek rejected the API key saved in DeepSeek Harness. Update it in DeepSeek Harness."))
        }
        guard response.status == 200 else { throw ProviderError.readFailed("HTTP \(response.status)") }
        guard let body = try? response.json() else {
            throw ProviderError.readFailed(Loc.t("DeepSeek 余额接口返回的内容无法识别。", "The DeepSeek balance API returned content that is not recognized."))
        }
        guard let infos = body["balance_infos"].array else {
            throw ProviderError.readFailed(Loc.t("balance_infos 缺失。", "balance_infos is missing."))
        }
        var metrics: [UsageMetric] = []
        for info in infos {
            let currency = info["currency"].text
            guard currency == "CNY" || currency == "USD" else { continue }
            let total = try amount(info, "total_balance")
            let granted = try amount(info, "granted_balance")
            metrics.append(UsageMetric(kind: .balance, label: "账户余额", metricID: "total:" + currency,
                                       amount: total, currency: currency))
            metrics.append(UsageMetric(kind: .balance, label: "赠送余额", metricID: "granted:" + currency,
                                       amount: granted, currency: currency))
        }
        guard !metrics.isEmpty else {
            throw ProviderError.readFailed(Loc.t("接口没有返回人民币或美元余额。", "The API returned no balance in CNY or USD."))
        }
        let warnings = body["is_available"].bool == false
            ? [Loc.t("余额不足，DeepSeek API 暂时无法调用。", "The balance is insufficient, so the DeepSeek API cannot be called for now.")]
            : []
        return ProviderResult(metrics: metrics,
                              planSource: Loc.t("DeepSeek Harness · DeepSeek API 密钥", "DeepSeek Harness · DeepSeek API key"),
                              scope: "account", warnings: warnings)
    }

    private static func amount(_ info: JSONValue, _ field: String) throws -> Decimal {
        guard let text = info[field].string, let value = decimal(text) else {
            throw ProviderError.readFailed(Loc.t("\(field) 缺失或不是数字。", "\(field) is missing or not a number."))
        }
        return value
    }

    // 两个钱包各截断到分后再相加，与 /user/balance 显示同一组金额
    private static func summary(_ root: JSONValue) throws -> [UsageMetric] {
        guard root["code"].float == 0, root["data"]["biz_code"].float == 0 else {
            throw ProviderError.readFailed(Loc.t("DeepSeek 账户接口返回的内容无法识别。", "The DeepSeek account API returned content that is not recognized."))
        }
        let data = root["data"]["biz_data"]
        guard data["normal_wallets"].array != nil, data["bonus_wallets"].array != nil else {
            throw ProviderError.readFailed(Loc.t("钱包字段缺失。", "The wallet fields are missing."))
        }
        func sums(_ name: String, _ field: String) throws -> [String: Decimal] {
            var result: [String: Decimal] = [:]
            for wallet in data[name].array ?? [] {
                let currency = wallet["currency"].text
                guard currency == "CNY" || currency == "USD" else { continue }
                guard let value = decimal(wallet[field].text) else {
                    throw ProviderError.readFailed(Loc.t("金额字段缺失或不是数字。", "A balance field is missing or is not a number."))
                }
                result[currency] = (result[currency] ?? 0) + value
            }
            return result
        }
        let normal = try sums("normal_wallets", "balance")
        let bonus = try sums("bonus_wallets", "balance")
        let costs = try sums("total_costs", "amount")
        var metrics: [UsageMetric] = []
        for currency in ["CNY", "USD"] where normal[currency] != nil || bonus[currency] != nil {
            let paid = cents(normal[currency] ?? 0)
            let granted = cents(bonus[currency] ?? 0)
            metrics.append(UsageMetric(kind: .balance, label: "账户余额", metricID: "total:" + currency,
                                       amount: paid + granted, currency: currency))
            metrics.append(UsageMetric(kind: .balance, label: "赠送余额", metricID: "granted:" + currency,
                                       amount: granted, currency: currency))
            // 累计消费排在最后，首屏显示两条余额
            if let cost = costs[currency] {
                metrics.append(UsageMetric(kind: .spend, label: "累计消费", metricID: "cost:" + currency,
                                           amount: max(0, cents(cost)), currency: currency))
            }
        }
        guard !metrics.isEmpty else {
            throw ProviderError.readFailed(Loc.t("DeepSeek 账户没有余额记录。", "The DeepSeek account has no balance records."))
        }
        return metrics
    }

    // 截断到分：向零取整，与上游 decimal.Truncate 一致
    private static func cents(_ value: Decimal) -> Decimal {
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, value < 0 ? .up : .down)
        return rounded / 100
    }

    private static func decimal(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }
}
