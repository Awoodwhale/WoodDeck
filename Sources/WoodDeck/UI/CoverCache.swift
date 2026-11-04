import AppKit

// 封面解码结果的缓存。界面每 0.2 秒重算一次，若每次都重新解码几百 KB 的封面代价太大，
// 这里按封面的标识保留最近几张，命中时直接复用同一个对象
@MainActor
final class CoverCache {
    static let shared = CoverCache()

    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 6

    func image(for data: Data?, token: String) -> NSImage? {
        guard let data, !token.isEmpty else { return nil }
        if let cached = images[token] { return cached }
        guard let image = NSImage(data: data) else { return nil }
        images[token] = image
        order.append(token)
        while order.count > limit {
            images.removeValue(forKey: order.removeFirst())
        }
        return image
    }

    func clear() {
        images.removeAll()
        order.removeAll()
    }
}
