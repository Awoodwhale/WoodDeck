import CommonCrypto
import Foundation

// Grok Bot 桌面版的每周额度。联网时向账户服务要一份读数，不联网时读桌面版在本机缓存的读数。
enum GrokBotProvider {
    private static let statusURI = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    private static let cacheSuffix = ".weekly-usage.cache"

    static func fetch(context: ProviderContext, locations: DataLocations, http: HTTPClient, online: Bool) async throws -> ProviderResult {
        if !online {
            guard let reading = cachedReading(locations.grokBotProfile, now: context.now) else {
                throw ProviderError.notConnected(Loc.t("请先登录 Grok Bot 桌面版", "Sign in to the Grok Bot desktop app first"))
            }
            return ProviderResult(metrics: metrics(reading),
                                  plan: reading.plan,
                                  planSource: reading.plan.isEmpty ? "" : Loc.t("Grok Bot 桌面版本地缓存", "Grok Bot desktop app local cache"),
                                  warnings: pooledWarning(reading))
        }

        let token = try accessToken(locations)
        let response = try await http.post(statusURI,
                                           headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
                                           body: Data("{}".utf8))
        if response.status == 401 || response.status == 403 {
            throw ProviderError.notConnected(Loc.t("Grok Bot 桌面版的登录已失效，请重新登录",
                                                    "The Grok Bot desktop app sign-in has expired. Sign in again."))
        }
        guard response.status == 200 else {
            throw ProviderError.readFailed(Loc.t("Grok Bot 账户接口暂时不可用。", "The Grok Bot account API is temporarily unavailable."))
        }
        let root: JSONValue
        do {
            root = try response.json()
        } catch {
            throw ProviderError.readFailed(Loc.t("Grok Bot 账户接口返回的内容无法识别。", "The Grok Bot account API returned content that is not recognized."))
        }
        let reading = try statusReading(root)
        return ProviderResult(metrics: metrics(reading),
                              plan: reading.plan,
                              planSource: reading.plan.isEmpty ? "" : Loc.t("Grok Bot 账户", "Grok Bot account"),
                              warnings: pooledWarning(reading))
    }

    private struct Reading {
        var percent: Double?
        var resetAt: Date?
        var plan: String
        var readAt: Date?
        var pooled: Bool
    }

    // sand-secrets.json 里 cursor-accounts 是一段 JSON 文本，active 指向当前账户，令牌按 Chromium 的方式加密
    private static func accessToken(_ locations: DataLocations) throws -> String {
        let file = locations.grokBotProfile.appending(path: "sand-secrets.json")
        guard let secrets = Credentials.readJSON(file) else {
            throw ProviderError.notConnected(Loc.t("请先登录 Grok Bot 桌面版", "Sign in to the Grok Bot desktop app first"))
        }
        let accountsText = secrets["cursor-accounts"].string ?? ""
        guard !accountsText.isEmpty, let data = accountsText.data(using: .utf8), let accounts = try? JSONValue.parse(data) else {
            throw ProviderError.notConnected(Loc.t("请先登录 Grok Bot 桌面版", "Sign in to the Grok Bot desktop app first"))
        }
        let active = accounts["active"].text
        let encrypted = accounts["accounts"][active]["cursor-access-token"].text
        guard !encrypted.isEmpty else {
            throw ProviderError.notConnected(Loc.t("请先登录 Grok Bot 桌面版", "Sign in to the Grok Bot desktop app first"))
        }
        return try decrypt(encrypted)
    }

    private static func decrypt(_ base64: String) throws -> String {
        let key = try safeStorageKey()
        guard let data = Data(base64Encoded: base64), data.count > 3, data.prefix(3).elementsEqual(Data("v10".utf8)) else {
            throw ProviderError.readFailed(Loc.t("Grok Bot 的登录令牌格式无法识别。", "The Grok Bot sign-in token format is not recognized."))
        }
        let cipher = data.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return Int32(kCCParamError) }
            return key.withUnsafeBytes { keyBytes in
                cipher.withUnsafeBytes { cipherBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv,
                            cipherBytes.baseAddress, cipher.count,
                            base, cipher.count + kCCBlockSizeAES128, &moved)
                }
            }
        }
        guard status == kCCSuccess else {
            throw ProviderError.readFailed(Loc.t("Grok Bot 的登录令牌无法解密。", "The Grok Bot sign-in token cannot be decrypted."))
        }
        output.removeSubrange(moved..<output.count)
        guard let text = String(data: output, encoding: .utf8) else {
            throw ProviderError.readFailed(Loc.t("Grok Bot 的登录令牌无法解密。", "The Grok Bot sign-in token cannot be decrypted."))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Chromium 在 macOS 上把主密钥放在钥匙串，令牌用 PBKDF2 派生出的 AES-128-CBC 密钥加密
    private static func safeStorageKey() throws -> Data {
        let service = "Grok Bot Safe Storage"
        var password: String?
        for account in ["Grok Bot", service] {
            if let value = Credentials.keychainPassword(service: service, account: account), !value.isEmpty {
                password = value
                break
            }
        }
        guard let password else {
            throw ProviderError.readFailed(Loc.t("Grok Bot 的登录令牌无法解密。", "The Grok Bot sign-in token cannot be decrypted."))
        }
        let secret = Array(password.utf8)
        let salt = Array("saltysalt".utf8)
        var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { output -> Int32 in
            guard let base = output.bindMemory(to: UInt8.self).baseAddress else { return Int32(kCCParamError) }
            return secret.withUnsafeBufferPointer { secretBuffer -> Int32 in
                guard let secretBase = secretBuffer.baseAddress else { return Int32(kCCParamError) }
                return secretBase.withMemoryRebound(to: Int8.self, capacity: secret.count) { passwordPointer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordPointer, secret.count,
                                         salt, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         base, 16)
                }
            }
        }
        guard status == kCCSuccess else {
            throw ProviderError.readFailed(Loc.t("Grok Bot 的登录令牌无法解密。", "The Grok Bot sign-in token cannot be decrypted."))
        }
        return key
    }

    private static func statusReading(_ root: JSONValue) throws -> Reading {
        let reading = reading(usage: root, percentKey: "usagePercent",
                              resetAt: JSONDate.parse(root["nextResetTimestampUtc"]),
                              plan: root["grokPlanLabel"].text, readAt: nil)
        guard let reading else {
            throw ProviderError.readFailed(Loc.t("Grok Bot 账户接口返回的内容无法识别。", "The Grok Bot account API returned content that is not recognized."))
        }
        return reading
    }

    // value.kind 为 present 时 reading.usage 才是桌面版存下的读数
    private static func cacheReading(_ root: JSONValue) -> Reading? {
        guard root["value"]["kind"].text == "present" else { return nil }
        let value = root["value"]["reading"]
        guard value["usage"].object != nil else { return nil }
        let usage = value["usage"]
        return reading(usage: usage, percentKey: "percentUsed",
                       resetAt: JSONDate.parse(usage["nextResetMs"]),
                       plan: usage["grokPlanLabel"].text,
                       readAt: JSONDate.parse(value["readAtMs"]))
    }

    private static func reading(usage: JSONValue, percentKey: String, resetAt: Date?, plan: String, readAt: Date?) -> Reading? {
        let pooled = usage["usesPooledEnterpriseAllowance"].bool == true
        let percent = usage[percentKey].float
        if !pooled && percent == nil { return nil }
        return Reading(percent: pooled ? nil : percent, resetAt: resetAt,
                       plan: plan.trimmingCharacters(in: .whitespacesAndNewlines),
                       readAt: readAt, pooled: pooled)
    }

    // 桌面版把每周额度缓存为 sand-client-persistence 下的文件，文件名是切片键的小写无填充 base32
    private static func cachedReading(_ profile: URL, now: Date) -> Reading? {
        let directory = profile.appending(path: "sand-client-persistence", directoryHint: .isDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        var newest: Reading?
        for file in files where file.pathExtension == "blob" {
            guard let name = sliceName(file.deletingPathExtension().lastPathComponent), name.hasSuffix(cacheSuffix) else { continue }
            guard let json = Credentials.readJSON(file), var found = cacheReading(json) else { continue }
            if found.readAt == nil { found.readAt = modificationDate(file) }
            guard let time = found.readAt, time <= now.addingTimeInterval(300) else { continue }
            if let kept = newest?.readAt, time <= kept { continue }
            newest = found
        }
        return newest
    }

    private static func sliceName(_ encoded: String) -> String? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var bytes: [UInt8] = []
        var buffer = 0
        var bits = 0
        for character in encoded {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    private static func metrics(_ reading: Reading) -> [UsageMetric] {
        guard let percent = reading.percent else { return [] }
        return [Quota(label: Loc.t("每周额度", "Weekly allowance"),
                      usedPercent: min(max(percent, 0), 100),
                      resetAt: reading.resetAt,
                      windowMinutes: 10080).metric]
    }

    private static func pooledWarning(_ reading: Reading) -> [String] {
        guard reading.pooled else { return [] }
        return [Loc.t("账户使用企业共享额度，没有单独的使用比例", "The account draws on a pooled enterprise allowance, which has no share of its own")]
    }
}
