import Foundation

// 手动填写的来源统一走脚本引擎：自定义来源使用用户编写的脚本，其余来源使用随应用附带的内建脚本
enum ConfiguredProvider {
    static func fetch(entry: AppEntry, secret: String, http: HTTPClient, now: Date) async throws -> ProviderResult {
        if secret.isEmpty { throw ProviderError.message("请填写 API 密钥") }
        let site = try siteAddress(entry)
        let script = try scriptSource(entry)
        return try await ScriptProvider.run(script: script, site: site, secret: secret,
                                            language: Loc.language, now: now, http: http)
    }

    static func test(entry: AppEntry, secret: String, http: HTTPClient, now: Date) async throws -> (result: ProviderResult, elapsed: TimeInterval) {
        let start = Date()
        let result = try await fetch(entry: entry, secret: secret, http: http, now: now)
        return (result, Date().timeIntervalSince(start))
    }

    private static func scriptSource(_ entry: AppEntry) throws -> String {
        if entry.quotaSource == .custom { return entry.script }
        guard let script = ProviderScripts.builtIn(entry.quotaSource) else {
            throw ProviderError.readFailed("这个来源没有内置换算脚本。")
        }
        return script
    }

    private static func siteAddress(_ entry: AppEntry) throws -> String {
        guard entry.quotaSource.needsSite else { return entry.site }
        let site = entry.site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty else { throw ProviderError.message("请填写站点地址") }
        _ = try ProviderCatalog.validateURL(site)
        return site
    }
}
