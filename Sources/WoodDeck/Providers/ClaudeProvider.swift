import Foundation

enum ClaudeProvider {
    static func fetch(context: ProviderContext, locations: DataLocations, http: HTTPClient, online: Bool) async throws -> ProviderResult {
        let local = localPlan(locations: locations)
        guard online else { return try localQuota(locations: locations, now: context.now, local: local) }
        guard let token = Credentials.claudeCodeAccessToken(locations) else {
            throw ProviderError.notConnected(Loc.t("请先登录 Claude Code 或 Claude 桌面版，然后刷新配额",
                                                   "Sign in to Claude Code or the Claude desktop app, then refresh the quota."))
        }
        let headers = [
            "Authorization": "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20"
        ]
        // 套餐与配额同时询问：网络缓慢或不可达时只等待一次
        async let accountPlan = readPlan(token: token, http: http)
        let response = try await http.get("https://api.anthropic.com/api/oauth/usage", headers: headers)
        try check(response)
        let quotas = parseQuotas(try json(response))
        guard !quotas.isEmpty else { throw invalidData }
        var result = ProviderResult(metrics: quotas.map(\.metric))
        let live = await accountPlan
        if !live.isEmpty {
            result.plan = live
            result.planSource = Loc.t("Claude 账户", "Claude account")
            return result
        }
        var credential = signInPlan(locations: locations)
        if credential.plan.lowercased() == "max", local.plan.hasPrefix("Max ") { credential.plan = local.plan }
        let plan = local.plan.isEmpty ? credential.plan : local.plan
        if plan == credential.plan || local.source.isEmpty {
            result.planSource = plan.isEmpty ? "" : credential.source + Loc.t(" 登录记录", " sign-in record")
        } else {
            result.planSource = local.source
        }
        result.plan = plan
        return result
    }

    // 只读 Claude 桌面版在本机记录的额度历史，不读取登录也不发请求；重置时间不在这份记录里
    private static func localQuota(locations: DataLocations, now: Date, local: (plan: String, source: String)) throws -> ProviderResult {
        guard let history = Credentials.claudeDesktopUsageHistory(locations),
              let sample = latestSample(history.json),
              sample.time <= now.addingTimeInterval(300) else {
            throw ProviderError.notConnected(Loc.t("Claude 桌面版尚未在本机记录额度",
                                                   "The Claude desktop app has not recorded a quota on this PC yet."))
        }
        let quotas = [
            Quota(label: "5 小时额度", usedPercent: sample.fiveHour, resetAt: nil, windowMinutes: 300),
            Quota(label: "每周额度", usedPercent: sample.sevenDay, resetAt: nil, windowMinutes: 10080)
        ]
        var result = ProviderResult(metrics: quotas.map(\.metric))
        result.plan = local.plan
        result.planSource = local.source
        return result
    }

    // 桌面版保存的样本以 t 为时间、u.fh 与 u.sd 为五小时与每周的使用比例
    private static func latestSample(_ root: JSONValue) -> (time: Date, fiveHour: Double, sevenDay: Double)? {
        var latest: (time: Date, fiveHour: Double, sevenDay: Double)?
        for sample in root["samples"].array ?? [] {
            let usage = sample["u"]
            guard let time = JSONDate.parse(sample["t"]), let fiveHour = usage["fh"].float, let sevenDay = usage["sd"].float else { continue }
            if let current = latest, time <= current.time { continue }
            latest = (time, clamp(fiveHour), clamp(sevenDay))
        }
        return latest
    }

    private static func parseQuotas(_ root: JSONValue) -> [Quota] {
        var result: [Quota] = []
        func add(_ label: String, _ percent: Double?, _ reset: Date?, _ window: Int?) {
            guard let percent, percent >= 0, !result.contains(where: { $0.label == label }) else { return }
            result.append(Quota(label: label, usedPercent: percent, resetAt: reset, windowMinutes: window))
        }
        for (key, label, window) in [("five_hour", "5 小时额度", 300), ("seven_day", "每周额度", 10080)] {
            add(label, root[key]["utilization"].float, JSONDate.parse(root[key]["resets_at"]), window)
        }
        // 现版客户端从 limits 读取服务端下发的各项额度，缺少的项不补零
        for limit in root["limits"].array ?? [] {
            let kind = limit["kind"].text
            let group = limit["group"].text
            let model = limit["scope"]["model"]["display_name"].text
            let surface = limit["scope"]["surface"]["display_name"].text
            if kind == "session" {
                add("5 小时额度", limit["percent"].float, JSONDate.parse(limit["resets_at"]), 300)
            } else if kind == "weekly_all" {
                add("每周额度", limit["percent"].float, JSONDate.parse(limit["resets_at"]), 10080)
            } else if !(model.isEmpty ? surface : model).isEmpty {
                let name = model.isEmpty ? surface : model
                let weekly = group == "weekly" || kind == "weekly_scoped"
                add(name + (weekly ? " 每周" : ""), limit["percent"].float, JSONDate.parse(limit["resets_at"]), weekly ? 10080 : nil)
            }
        }
        for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            if !result.contains(where: { $0.label.lowercased().hasPrefix(name.lowercased()) }) {
                add(name + " 每周", root[key]["utilization"].float, JSONDate.parse(root[key]["resets_at"]), 10080)
            }
        }
        return result
    }

    // 账户接口需要 profile 授权范围，部分登录没有这个范围；请求失败时套餐改从本机记录读取
    private static func readPlan(token: String, http: HTTPClient) async -> String {
        let headers = [
            "Authorization": "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20"
        ]
        do {
            let response = try await http.get("https://api.anthropic.com/api/oauth/profile", headers: headers)
            guard (200...299).contains(response.status) else { return "" }
            return organizationPlan(try json(response))
        } catch {
            return ""
        }
    }

    // 本机账户记录：Claude Code 每次启动都会刷新它，套餐变化比登录记录里的副本更及时
    private static func localPlan(locations: DataLocations) -> (plan: String, source: String) {
        let primary = locations.claudeHome.appending(path: ".claude.json")
        var profile = primary
        if !FileManager.default.fileExists(atPath: primary.path(percentEncoded: false)) {
            let defaultHome = locations.home.appending(path: ".claude", directoryHint: .isDirectory)
            guard locations.claudeHome.standardizedFileURL == defaultHome.standardizedFileURL else { return ("", "") }
            profile = locations.home.appending(path: ".claude.json")
        }
        guard let root = Credentials.readJSON(profile) else { return ("", "") }
        let plan = claudeProfilePlan(root)
        return (plan, plan.isEmpty ? "" : Loc.t("Claude 本地账户记录", "Claude local account record"))
    }

    private static func claudeProfilePlan(_ root: JSONValue) -> String {
        claudeTier(root["oauthAccount"]["organizationRateLimitTier"].text, "")
    }

    // 登录凭据旁的套餐副本只在重新签发登录时更新
    private static func signInPlan(locations: DataLocations) -> (plan: String, source: String) {
        let source = "Claude Code"
        let file = locations.claudeHome.appending(path: ".credentials.json")
        var roots: [JSONValue] = []
        if let root = Credentials.readJSON(file) { roots.append(root) }
        if let text = Credentials.keychainPassword(service: "Claude Code-credentials"),
           let data = text.data(using: .utf8),
           let root = try? JSONValue.parse(data) {
            roots.append(root)
        }
        for root in roots {
            let oauth = root["claudeAiOauth"]
            let plan = claudeTier(oauth["rateLimitTier"].text, oauth["subscriptionType"].text)
            if !plan.isEmpty { return (plan, source) }
        }
        return ("", source)
    }

    private static func organizationPlan(_ root: JSONValue) -> String {
        let organization = root["organization"]
        let plan = claudeTier(organization["rate_limit_tier"].text, "")
        if !plan.isEmpty { return plan }
        switch organization["organization_type"].text {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return ""
        }
    }

    // claude_max_20x 一类分层写成 Max 20x，其余情况用订阅类型
    private static func claudeTier(_ tier: String, _ subscription: String) -> String {
        let text = tier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "(?:^|_)claude_max_[0-9]+x$", options: .regularExpression) {
            let suffix = String(text[range]).split(separator: "_").last.map(String.init) ?? ""
            if !suffix.isEmpty { return "Max " + suffix }
        }
        return subscription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clamp(_ percent: Double) -> Double { min(max(percent, 0), 100) }

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
