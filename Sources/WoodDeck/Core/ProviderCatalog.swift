import Foundation

// 站点地址的规整与校验，手动填写的来源共用
enum ProviderCatalog {
    static let frontendPages = ["console", "dashboard", "panel", "login", "pricing", "keys"]

    static func normalizeSite(_ site: String, removeV1: Bool = true) -> String {
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if removeV1, let url = URL(string: text), let scheme = url.scheme, scheme == "http" || scheme == "https" {
            let segments = url.path.split(separator: "/").map(String.init)
            if let page = segments.firstIndex(where: { frontendPages.contains($0.lowercased()) }) {
                let authority = "\(scheme)://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
                text = authority + segments[..<page].map { "/" + $0 }.joined()
            }
        }
        if removeV1, text.lowercased().hasSuffix("/v1") {
            text = String(text.dropLast(3))
            while text.hasSuffix("/") { text.removeLast() }
        }
        return text
    }

    static func validateURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil, !(url.host ?? "").isEmpty else {
            throw ProviderError.message(Loc.t("请填写有效的 HTTP 或 HTTPS 站点地址，不要包含账户、密码或片段。",
                                              "Enter a valid HTTP or HTTPS site address without a user name, password or fragment."))
        }
        return url
    }
}
