import Foundation

// Antigravity 桌面版把语言服务作为独立进程启动，命令行里带 --csrf_token，它在 127.0.0.1 上监听端口。
// 配额从这个本机服务读取：先取 GetUserStatus，再用 RetrieveUserQuotaSummary 的结果覆盖。
enum AntigravityProvider {
    static func fetch(context: ProviderContext, locations: DataLocations, http: HTTPClient) async throws -> ProviderResult {
        let endpoints = try await endpoints()
        guard !endpoints.isEmpty else {
            throw ProviderError.notConnected(Loc.t("请先启动 Antigravity 桌面版", "Start the Antigravity desktop app first"))
        }
        for endpoint in endpoints {
            var status: JSONValue
            do {
                status = try await localCall(endpoint, method: "GetUserStatus")
            } catch {
                continue
            }
            var found = quotas(status)
            if let summary = try? await localCall(endpoint, method: "RetrieveUserQuotaSummary") {
                let authoritative = quotas(summary)
                if !authoritative.isEmpty { found = authoritative }
            }
            guard !found.isEmpty else { continue }
            let name = plan(status)
            return ProviderResult(metrics: found.map(\.metric),
                                  plan: name,
                                  planSource: name.isEmpty ? "" : Loc.t("Antigravity 本地账户服务", "Antigravity local account service"))
        }
        throw ProviderError.notConnected(Loc.t("请先启动 Antigravity 桌面版", "Start the Antigravity desktop app first"))
    }

    private struct Endpoint {
        var port: Int
        var scheme: String
        var token: String
    }

    // 进程参数从 ps 的输出解析；监听端口从 lsof 的监听表取，与上游按进程取监听端口的做法一致
    private static func endpoints() async throws -> [Endpoint] {
        let listing = try await run("/bin/ps", ["-axo", "pid=,args="])
        var found: [Endpoint] = []
        for line in listing.split(separator: "\n") {
            let content = line.drop(while: { $0 == " " })
            guard let separator = content.firstIndex(of: " "), let pid = Int(content[..<separator]) else { continue }
            let command = String(content[content.index(after: separator)...])
            guard command.lowercased().contains("antigravity"), let token = csrfToken(command) else { continue }
            for port in try await listeningPorts(pid: pid) {
                found.append(Endpoint(port: port, scheme: "https", token: token))
                found.append(Endpoint(port: port, scheme: "http", token: token))
            }
        }
        return found
    }

    private static func csrfToken(_ command: String) -> String? {
        let pattern = "--csrf_token(?:=|\\s+)\"?([^\\s\"]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = expression.firstMatch(in: command, range: range), match.numberOfRanges > 1,
              let tokenRange = Range(match.range(at: 1), in: command) else { return nil }
        let token = String(command[tokenRange])
        return token.isEmpty ? nil : token
    }

    private static func listeningPorts(pid: Int) async throws -> [Int] {
        let table = try await run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"])
        var ports: [Int] = []
        for line in table.split(separator: "\n") where line.hasPrefix("n") {
            let name = line.dropFirst()
            guard let colon = name.lastIndex(of: ":") else { continue }
            guard let port = Int(name[name.index(after: colon)...]), !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw ProviderError.readFailed(Loc.t("无法运行 \(tool)。", "Cannot run \(tool)."))
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    // 本机服务用自签名证书，只有 127.0.0.1 上的这个端口接受它的证书
    private final class LoopbackTrust: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  challenge.protectionSpace.host == "127.0.0.1",
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private static func localCall(_ endpoint: Endpoint, method: String) async throws -> JSONValue {
        let address = "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method)"
        guard let url = URL(string: address) else {
            throw ProviderError.readFailed(Loc.t("本机服务地址无效。", "The local service address is invalid."))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(endpoint.token, forHTTPHeaderField: "x-codeium-csrf-token")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: LoopbackTrust(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ProviderError.readFailed(Loc.t("本机用量服务没有响应。", "The local usage service did not answer."))
        }
        return try JSONValue.parse(data)
    }

    // groups[].buckets[] 的 remainingFraction 是剩余比例，换算成已用百分比
    private static func quotas(_ root: JSONValue) -> [Quota] {
        var result: [Quota] = []
        var groups = root["response"]["groups"]
        if groups.array == nil { groups = root["groups"] }
        for group in groups.array ?? [] {
            for bucket in group["buckets"].array ?? [] {
                guard let fraction = bucket["remainingFraction"].float else { continue }
                let id = bucket["bucketId"].text
                result.append(Quota(label: bucketLabel(id),
                                    usedPercent: (1 - min(max(fraction, 0), 1)) * 100,
                                    resetAt: JSONDate.parse(bucket["resetTime"]),
                                    windowMinutes: bucketWindow(id)))
            }
        }
        if !result.isEmpty { return result }
        let configs = root["userStatus"]["cascadeModelConfigData"]["clientModelConfigs"]
        for model in configs.array ?? [] {
            guard let fraction = model["quotaInfo"]["remainingFraction"].float else { continue }
            result.append(Quota(label: model["label"].text,
                                usedPercent: (1 - min(max(fraction, 0), 1)) * 100,
                                resetAt: JSONDate.parse(model["quotaInfo"]["resetTime"]),
                                windowMinutes: nil))
        }
        return result
    }

    private static func bucketLabel(_ id: String) -> String {
        switch id {
        case "gemini-5h": return "Gemini · 5 小时"
        case "gemini-weekly": return "Gemini · 每周"
        case "3p-5h": return "Claude · 5 小时"
        case "3p-weekly": return "Claude · 每周"
        default: return id
        }
    }

    private static func bucketWindow(_ id: String) -> Int? {
        switch id {
        case "gemini-5h", "3p-5h": return 300
        case "gemini-weekly", "3p-weekly": return 10080
        default: return nil
        }
    }

    private static func plan(_ root: JSONValue) -> String {
        let status = root["userStatus"]
        let tier = status["userTier"]["name"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tier.isEmpty { return tier }
        return status["planStatus"]["planInfo"]["planName"].text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
