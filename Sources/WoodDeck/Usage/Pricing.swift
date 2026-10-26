import Foundation

// 单价为每 token 的美元金额，与 OpenRouter 目录里的数值一致
struct ModelPrice: Codable, Sendable, Hashable {
    var id: String
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheWrite: Decimal
}

enum PricingError: LocalizedError {
    case catalog(String)

    var errorDescription: String? {
        switch self {
        case .catalog(let text): text
        }
    }
}

// 远程目录与手动填写的单价合在一起查找。目录里没有单独的缓存价格时，缓存读取按 0 计、
// 缓存写入按输入单价计；手动填写的条目优先于远程目录里的同名模型
enum Pricing {
    static let source = "https://openrouter.ai/api/v1/models"

    nonisolated(unsafe) private static var remote: [String: ModelPrice] = [:]
    nonisolated(unsafe) private static var manualPrices: [String: ModelPrice] = [:]
    nonisolated(unsafe) private static var lookup: [String: ModelPrice] = [:]
    nonisolated(unsafe) private static var tierWords: [String: Set<String>] = [:]
    nonisolated(unsafe) private static var loaded = false

    private struct PriceFile: Codable {
        var updatedAt: Date
        var models: [ModelPrice]
    }

    // 当前可用的单价，键为模型 ID
    static func load() -> [String: ModelPrice] {
        ensureLoaded()
        return mergedPrices().values.reduce(into: [String: ModelPrice]()) { result, price in
            result[price.id] = price
        }
    }

    static func syncFromOpenRouter(http: HTTPClient) async throws -> [String: ModelPrice] {
        ensureLoaded()
        let response = try await http.get(source)
        guard response.status == 200 else { throw HTTPError.status(response.status, "") }
        for price in try parseCatalog(try response.json()) {
            remote[normalize(price.id)] = price
        }
        rebuild()
        saveCatalog()
        return load()
    }

    static func cost(entry: TokenEntry) -> Decimal? {
        let price = match(entry.model)
            ?? (entry.key.hasPrefix("ag:") ? matchAntigravityBase(entry.model) : nil)
        guard let price else { return nil }
        return Decimal(entry.input) * price.input
            + Decimal(entry.output) * price.output
            + Decimal(entry.cacheRead) * price.cacheRead
            + Decimal(entry.cacheWrite) * price.cacheWrite
    }

    static var manual: [String: ModelPrice] {
        ensureLoaded()
        return manualPrices.values.reduce(into: [String: ModelPrice]()) { result, price in
            result[price.id] = price
        }
    }

    static func addManual(_ price: ModelPrice) {
        ensureLoaded()
        let id = price.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var stored = price
        stored.id = id
        manualPrices[normalize(id)] = stored
        rebuild()
        saveManual()
    }

    static func removeManual(_ id: String) {
        ensureLoaded()
        manualPrices.removeValue(forKey: normalize(id))
        rebuild()
        saveManual()
    }

    // 精确匹配，其次把带日期后缀的快照退回同名的基础模型；变体模型各自独立
    static func match(_ model: String) -> ModelPrice? {
        ensureLoaded()
        let key = normalize(model)
        if let exact = lookup[key] { return exact }
        let undated = key.replacingOccurrences(of: "-[0-9]{8}$", with: "", options: .regularExpression)
        guard undated != key else { return nil }
        return lookup[undated]
    }

    private static func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: SupportFiles.modelPrices),
           let file = try? decoder.decode(PriceFile.self, from: data) {
            for price in file.models where !price.id.isEmpty {
                remote[normalize(price.id)] = price
            }
        }
        if let data = try? Data(contentsOf: SupportFiles.manualModelPrices),
           let prices = try? decoder.decode([ModelPrice].self, from: data) {
            for price in prices where !price.id.isEmpty {
                manualPrices[normalize(price.id)] = price
            }
        }
        rebuild()
    }

    private static func parseCatalog(_ catalog: JSONValue) throws -> [ModelPrice] {
        var models: [ModelPrice] = []
        for item in catalog["data"].array ?? [] {
            let id = item["id"].text
            guard !id.trimmingCharacters(in: .whitespaces).isEmpty, id.contains("/") else { continue }
            let pricing = item["pricing"]
            guard let input = readPrice(pricing["prompt"]), let output = readPrice(pricing["completion"]) else { continue }
            models.append(ModelPrice(id: id, input: input, output: output,
                                     cacheRead: readPrice(pricing["input_cache_read"]) ?? 0,
                                     cacheWrite: readPrice(pricing["input_cache_write"]) ?? input))
        }
        guard !models.isEmpty else {
            throw PricingError.catalog(Loc.t("价格目录里没有可用的单价。", "No usable model prices were returned."))
        }
        return models
    }

    private static func readPrice(_ value: JSONValue) -> Decimal? {
        guard let price = value.decimal, price >= 0, price <= 1000 else { return nil }
        return price
    }

    // 模型名规整：小写，Claude 的版本号点号换成连字符，与目录里的写法一致
    private static func normalize(_ model: String) -> String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("claude-") || value.hasPrefix("anthropic/claude-") else { return value }
        return value.replacingOccurrences(of: "(?<=[0-9])\\.(?=[0-9])", with: "-", options: .regularExpression)
    }

    // 去掉提供方前缀后的模型名
    private static func bareID(_ id: String) -> String {
        let key = normalize(id)
        guard let slash = key.firstIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }

    private static func mergedPrices() -> [String: ModelPrice] {
        var merged: [String: ModelPrice] = [:]
        for (key, price) in remote where manualPrices[key] == nil && manualPrices[bareID(price.id)] == nil {
            merged[key] = price
        }
        for (key, price) in manualPrices { merged[key] = price }
        return merged
    }

    private static func rebuild() {
        let merged = mergedPrices()
        var table: [String: ModelPrice] = [:]
        for (key, price) in merged { table[key] = price }
        // 唯一的裸名可以直接查到对应模型，出现同名的多个提供方时不做别名
        var aliases: [String: [ModelPrice]] = [:]
        for price in merged.values { aliases[bareID(price.id), default: []].append(price) }
        for (bare, prices) in aliases where prices.count == 1 {
            if table[bare] != nil { continue }
            table[bare] = prices[0]
        }
        // 手动填写的裸名同样保护远程目录里的同名模型
        for price in remote.values {
            guard let manual = manualPrices[bareID(price.id)] else { continue }
            let key = normalize(price.id)
            if table[key] == nil { table[key] = manual }
        }
        lookup = table
        tierWords = tiers(merged.values)
    }

    // 每个模型族（gemini、claude-opus、gpt-oss）里版本号之后代表不同模型的词，如 gemini-3.5-flash-lite 的 lite
    private static func tiers(_ prices: Dictionary<String, ModelPrice>.Values) -> [String: Set<String>] {
        var words: [String: Set<String>] = [:]
        for price in prices {
            var id = bareID(price.id)
            if let colon = id.firstIndex(of: ":") { id = String(id[..<colon]) }
            let segments = id.split(separator: "-").map(String.init)
            guard let shape = shape(segments) else { continue }
            for word in segments[(shape.version + 1)...] where !word.isEmpty && word.first?.isNumber == false {
                words[shape.family, default: []].insert(word)
            }
        }
        return words
    }

    // 模型族是版本号之前的词，版本号是第一个以数字开头的词
    private static func shape(_ segments: [String]) -> (family: String, version: Int)? {
        guard segments.count > 1 else { return nil }
        for index in 1..<segments.count where segments[index].first?.isNumber == true {
            return (segments[..<index].joined(separator: "-"), index)
        }
        return nil
    }

    // Antigravity 会在模型名后面加推理档位等词，如 claude-opus-4-6-thinking、gemini-3.8-flash-control，
    // 目录里只有基础模型，因此取最长的基础模型前缀。版本号之前的切分丢弃，版本号之后出现的
    // 目录同族档位词（lite、mini 等）说明是另一个已定价的模型，此时不给价格
    private static func matchAntigravityBase(_ model: String) -> ModelPrice? {
        let key = normalize(model)
        var vendor = ""
        var rest = key
        if let slash = key.firstIndex(of: "/") {
            vendor = String(key[...slash])
            rest = String(key[key.index(after: slash)...])
        }
        let segments = rest.split(separator: "-").map(String.init)
        guard let shape = shape(segments) else { return nil }
        for length in stride(from: segments.count, through: shape.version + 1, by: -1) {
            if length < segments.count {
                guard let first = segments[length].first, !first.isNumber else { continue }
            }
            let candidate = vendor + segments[..<length].joined(separator: "-")
            var price = length < segments.count ? match(candidate) : nil
            if price == nil, candidate.range(of: "^(google/)?gemini-[0-9][0-9.]*-pro$", options: .regularExpression) != nil {
                price = match(candidate + "-preview")
            }
            guard let price else { continue }
            if let words = tierWords[shape.family], segments[length...].contains(where: words.contains) { return nil }
            return price
        }
        return nil
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func saveCatalog() {
        let file = PriceFile(updatedAt: Date(), models: remote.values.sorted { $0.id < $1.id })
        guard let data = try? encoder.encode(file) else { return }
        write(data, to: SupportFiles.modelPrices)
    }

    private static func saveManual() {
        guard let data = try? encoder.encode(manualPrices.values.sorted { $0.id < $1.id }) else { return }
        write(data, to: SupportFiles.manualModelPrices)
    }
}
