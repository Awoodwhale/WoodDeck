import CryptoKit
import Foundation

// ZCode 一个来源合并三份额度：登录账户的 Coding Plan（智谱或 Z.ai 的套餐额度）、Start Plan 的活动额度、
// 以及 ZCode 自己的每日 MCP 调用额度。凭据在 ~/.zcode 下，每个值以 enc:v1: 开头时用账户密钥解密。
enum ZCodeProvider {
    static func fetch(context: ProviderContext, locations: DataLocations, http: HTTPClient) async throws -> ProviderResult {
        guard let account = try account(locations), !(account.apiKey.isEmpty && account.jwt.isEmpty) else {
            throw ProviderError.notConnected(Loc.t("请先登录 ZCode", "Sign in to ZCode first."))
        }

        var warnings: [String] = []
        var coding: (plan: String, metrics: [UsageMetric])?
        var codingFailure: Error?
        if !account.apiKey.isEmpty {
            do {
                coding = try await codingPlan(account, now: context.now, http: http)
            } catch {
                codingFailure = error
                warnings.append(Loc.t("Coding Plan 读取失败：\(message(error))", "Reading the Coding Plan failed: \(message(error))"))
            }
        }

        var start = (plan: "", metrics: [UsageMetric]())
        if !account.jwt.isEmpty && !account.deviceMid.isEmpty {
            do {
                start = try await startPlan(account, now: context.now, http: http)
            } catch {
                warnings.append(Loc.t("Start Plan 读取失败：\(message(error))", "Reading the Start Plan failed: \(message(error))"))
            }
        }

        var mcp: UsageMetric?
        if !account.jwt.isEmpty && !account.accessToken.isEmpty {
            do {
                mcp = try await mcpMetric(account, http: http)
            } catch {
                warnings.append(Loc.t("MCP 额度读取失败：\(message(error))", "Reading the MCP allowance failed: \(message(error))"))
            }
        }

        if coding == nil && start.metrics.isEmpty && mcp == nil {
            if let codingFailure { throw codingFailure }
            throw ProviderError.notConnected(Loc.t("ZCode 账户没有可用的 Coding Plan 或 Start Plan",
                                                    "The ZCode account has no active Coding Plan or Start Plan."))
        }

        // 滚动窗口按窗口长度排在前面，Start Plan 的额度排在工具调用额度之前
        var metrics: [UsageMetric] = []
        if let coding { metrics += coding.metrics.filter { $0.window != nil } }
        metrics += start.metrics
        if let coding { metrics += coding.metrics.filter { $0.window == nil } }
        if let mcp { metrics.append(mcp) }

        var plan = start.plan
        if let coding, !coding.plan.isEmpty { plan = coding.plan }
        var details: [String: String] = [:]
        if !start.plan.isEmpty { details["Start Plan"] = start.plan }
        return ProviderResult(metrics: metrics, plan: plan,
                              planSource: Loc.t("ZCode 账户", "ZCode account"),
                              scope: "plan", details: details, warnings: warnings)
    }

    private struct Account {
        var family: String
        var apiKey: String
        var jwt: String
        var accessToken: String
        var deviceMid: String
    }

    private static func account(_ locations: DataLocations) throws -> Account? {
        let file = locations.zcodeHome.appending(path: "v2/credentials.json")
        guard let json = Credentials.readJSON(file), let values = json.object else { return nil }
        let key = credentialKey(locations)
        func value(_ name: String) throws -> String {
            guard let text = values[name]?.string, !text.isEmpty else { return "" }
            return try decrypt(text, key: key).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var family = try value("oauth:active_provider")
        let prefix = "account-provider:coding-plan:account:"
        let names = values.keys.filter { $0.hasPrefix(prefix) && $0.hasSuffix(":api-key") }
        func keyName(_ region: String) -> String? { names.first { $0.contains(":\(region)-individual-coding-plan:") } }
        // ZCode 一次只登录一个区域，旧区域的套餐密钥可能还留着
        if family != "bigmodel" && family != "zai" {
            family = keyName("bigmodel") == nil && keyName("zai") != nil ? "zai" : "bigmodel"
        }
        let apiKeyName = keyName(family)
        let apiKey = try apiKeyName.map { try value($0) } ?? ""
        let jwt = try value("zcodejwttoken")
        let accessToken = try value("oauth:\(family):access_token")
        return Account(family: family, apiKey: apiKey, jwt: jwt, accessToken: accessToken, deviceMid: deviceMid(locations.zcodeHome))
    }

    // 主密钥是 SHA-256(zcode-credential-fallback:<平台>:<用户目录>:<用户名>)，ZCODE_CREDENTIAL_SECRET 可以覆盖
    private static func credentialKey(_ locations: DataLocations) -> Data {
        let custom = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"] ?? ""
        let secret = custom.isEmpty
            ? "zcode-credential-fallback:darwin:\(locations.home.path(percentEncoded: false)):\(NSUserName())"
            : custom
        return Data(SHA256.hash(data: Data(secret.utf8)))
    }

    // Start Plan 的余额接口要求 ZCode 的设备标识，它在 v2/telemetry-state.json 里
    private static func deviceMid(_ home: URL) -> String {
        guard let json = Credentials.readJSON(home.appending(path: "v2/telemetry-state.json")) else { return "" }
        guard let id = UUID(uuidString: json["deviceMid"].text) else { return "" }
        return id.uuidString.lowercased()
    }

    private static func decrypt(_ text: String, key: Data) throws -> String {
        let prefix = "enc:v1:"
        guard text.hasPrefix(prefix) else { return text }
        let parts = text.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = base64url(String(parts[0])),
              let tag = base64url(String(parts[1])),
              let cipher = base64url(String(parts[2])),
              let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else {
            throw ProviderError.readFailed(Loc.t("ZCode 凭据无法解密。", "The ZCode credentials cannot be decrypted."))
        }
        guard let plainText = String(data: plain, encoding: .utf8) else {
            throw ProviderError.readFailed(Loc.t("ZCode 凭据格式无法识别。", "The ZCode credential format is not recognized."))
        }
        return plainText
    }

    private static func base64url(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 { value += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: value)
    }

    // Coding Plan 的套餐额度接口。窗口按 unit 区分：unit 3 是小时窗口（number 为小时数），unit 6 是每周
    private static func codingPlan(_ account: Account, now: Date, http: HTTPClient) async throws -> (plan: String, metrics: [UsageMetric]) {
        let host = account.family == "zai" ? "https://api.z.ai" : "https://open.bigmodel.cn"
        let response = try await http.get(host + "/api/monitor/usage/quota/limit",
                                          headers: ["Authorization": account.apiKey])
        if response.status == 401 {
            throw ProviderError.notConnected(Loc.t("ZCode 的 Coding Plan 凭据已失效，请在 ZCode 中重新登录",
                                                    "The Coding Plan credentials of ZCode have expired. Sign in again in ZCode."))
        }
        if response.status == 403 {
            throw ProviderError.readFailed(Loc.t("账户接口拒绝访问", "The account API refused access."))
        }
        if response.status == 429 {
            throw ProviderError.readFailed(Loc.t("请求频繁，稍后自动重试", "Too many requests. Retrying automatically later."))
        }
        guard response.status == 200 else { throw ProviderError.readFailed("HTTP \(response.status)") }
        guard let body = try? response.json() else {
            throw ProviderError.readFailed(Loc.t("套餐接口返回的内容无法识别。", "The plan API returned content that is not recognized."))
        }
        let code = body["code"].isNull ? nil : body["code"].text
        if body["success"].bool == false || (code != nil && code != "0" && code != "200") {
            let text = body["msg"].text
            throw ProviderError.readFailed(text.isEmpty
                ? Loc.t("套餐查询失败，请检查凭据或套餐权限。", "The plan query failed. Check the credentials or the plan's permissions.")
                : text)
        }
        let data = body["data"]
        guard let limits = data["limits"].array else {
            throw ProviderError.readFailed(Loc.t("data.limits 缺失。", "data.limits is missing."))
        }
        if limits.isEmpty {
            throw ProviderError.readFailed(Loc.t("接口没有返回套餐额度，团队套餐暂不支持。", "The API returned no plan quota. Team plans are not supported yet."))
        }
        let level = data["level"].string?.trimmingCharacters(in: .whitespaces) ?? ""
        var metrics: [UsageMetric] = []
        for (index, limit) in limits.enumerated() {
            let type = limit["type"].text.uppercased()
            let reset = limit["nextResetTime"].float.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            if type == "TIME_LIMIT" {
                if let usage = limit["usage"].float, usage > 0 {
                    metrics.append(UsageMetric(kind: .count, label: "工具调用", metricID: "tools",
                                               total: Decimal(usage), used: Decimal(limit["currentValue"].float ?? 0),
                                               unit: "次", resetAt: reset))
                }
                continue
            }
            guard type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" else { continue }
            let unit = limit["unit"].float
            let number = limit["number"].float
            var label = "套餐额度"
            var window: Int?
            if unit == 3, let number, number > 0 {
                label = "\(Int(number)) 小时"
                window = Int(number) * 60
            } else if unit == 6 {
                label = "每周"
                window = 10080
            }
            // 积分套餐报确切积分，旧套餐只报一个取整的比例
            let credits = type == "CREDIT_LIMIT" && (limit["usage"].float ?? 0) > 0 && limit["currentValue"].float != nil
            let percentage = limit["percentage"].float
            if !credits && percentage == nil { continue }
            // 超出窗口长度的重置时间不是真的重置时间
            var resetAt = reset
            if let reset, let window, reset > now.addingTimeInterval(Double(window) * 60) { resetAt = nil }
            let metricID = "\(type):\(integerText(unit)):\(integerText(number)):\(index)"
            if credits {
                metrics.append(UsageMetric(kind: .count, label: label, metricID: metricID, window: window,
                                           total: Decimal(limit["usage"].float ?? 0),
                                           used: Decimal(limit["currentValue"].float ?? 0),
                                           unit: "积分", resetAt: resetAt))
            } else {
                metrics.append(UsageMetric(kind: .percent, label: label, metricID: metricID, window: window,
                                           percent: min(max(percentage ?? 0, 0), 100), resetAt: resetAt))
            }
        }
        if metrics.isEmpty {
            throw ProviderError.readFailed(Loc.t("没有可识别的套餐额度。", "No recognizable plan quota was returned."))
        }
        let plan = level.isEmpty ? "" : level.prefix(1).uppercased() + level.dropFirst()
        return (plan, metrics)
    }

    // Start Plan 的活动额度：data.plans[] 是套餐，data.balances[] 每个授予一条额度
    private static func startPlan(_ account: Account, now: Date, http: HTTPClient) async throws -> (plan: String, metrics: [UsageMetric]) {
        let response = try await http.send(method: "GET", url: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance",
                                           headers: ["Authorization": "Bearer \(account.jwt)", "X-Device-Mid": account.deviceMid],
                                           body: nil, timeout: 45)
        guard response.status == 200 else { throw ProviderError.readFailed("HTTP \(response.status)") }
        guard let root = try? response.json() else {
            throw ProviderError.readFailed(Loc.t("Start Plan 接口返回的内容无法识别。", "The Start Plan API returned content that is not recognized."))
        }
        guard (root["code"].float ?? -1) == 0, root["data"]["plans"].array != nil else {
            throw ProviderError.readFailed(Loc.t("Start Plan 接口返回的内容无法识别。", "The Start Plan API returned content that is not recognized."))
        }
        let data = root["data"]
        let plans = (data["plans"].array ?? []).filter { plan in
            guard plan["status"].text.lowercased() == "active" else { return false }
            if let end = JSONDate.parse(plan["ends_at"]) { return end > now }
            return true
        }
        var periods: [String: String] = [:]
        for plan in plans {
            for entitlement in plan["entitlements"].array ?? [] {
                let id = entitlement["entitlement_id"].text
                if periods[id] == nil { periods[id] = entitlement["period"].text }
            }
        }
        let active = Set(plans.map { $0["user_plan_id"].text })
        var metrics: [UsageMetric] = []
        for balance in data["balances"].array ?? [] {
            guard active.contains(balance["user_plan_id"].text) else { continue }
            guard let total = balance["total_units"].float, total > 0 else { continue }
            let expires = JSONDate.parse(balance["expires_at"]) ?? JSONDate.parse(balance["period_end"])
            if let expires, expires <= now { continue }
            let used = balance["used_units"].float ?? (total - (balance["remaining_units"].float ?? total))
            let entitlement = balance["entitlement_id"].text
            let periodEnd = JSONDate.parse(balance["period_end"])
            let type = balance["unit_type"].text
            let showName = balance["show_name"].text
            // 周期性额度在周期结束时重置，一次性授予只会过期
            var resetAt: Date?
            if let period = periods[entitlement], !period.isEmpty, period != "one_time",
               let periodEnd, let expires, periodEnd < expires {
                resetAt = periodEnd
            }
            metrics.append(UsageMetric(kind: .count,
                                       label: showName.isEmpty ? entitlement : showName,
                                       metricID: "start-plan:" + entitlement,
                                       total: Decimal(total),
                                       used: Decimal(min(max(used, 0), total)),
                                       unit: type == "token" ? "令牌" : type,
                                       resetAt: resetAt,
                                       expiresAt: expires))
        }
        let name = plans.compactMap { plan -> String? in
            let text = plan["name"].text
            return text.isEmpty ? nil : text
        }.first ?? ""
        return (name, metrics)
    }

    // ZCode 自己的 MCP 额度，每天刷新一次
    private static func mcpMetric(_ account: Account, http: HTTPClient) async throws -> UsageMetric {
        let response = try await http.send(method: "GET", url: "https://zcode.z.ai/api/v1/mcp/usage",
                                           headers: ["Authorization": "Bearer \(account.jwt)",
                                                     "X-Bigmodel-Authorization": "Bearer \(account.accessToken)",
                                                     "Bigmodel-Target-Type": "PERSONAL"],
                                           body: nil, timeout: 45)
        guard response.status == 200 else { throw ProviderError.readFailed("HTTP \(response.status)") }
        guard let root = try? response.json() else {
            throw ProviderError.readFailed(Loc.t("MCP 额度接口返回的内容无法识别。", "The MCP allowance API returned content that is not recognized."))
        }
        guard (root["code"].float ?? -1) == 0 else {
            throw ProviderError.readFailed(Loc.t("MCP 额度接口返回的内容无法识别。", "The MCP allowance API returned content that is not recognized."))
        }
        let data = root["data"]
        let usage = data["total_usage"]
        guard let limit = usage["limit"].float, limit > 0, let used = usage["used"].float else {
            throw ProviderError.readFailed(Loc.t("MCP 额度接口返回的内容无法识别。", "The MCP allowance API returned content that is not recognized."))
        }
        return UsageMetric(kind: .count, label: "ZCode MCP", metricID: "zcode-mcp",
                           total: Decimal(limit), used: Decimal(max(0, used)), unit: "次",
                           resetAt: JSONDate.parse(data["next_refresh_at"]))
    }

    private static func integerText(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
