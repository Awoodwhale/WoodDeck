import Foundation

// 本机各应用的数据位置。环境变量优先，其次为用户目录下的固定位置
struct DataLocations: Sendable {
    var home: URL
    var claudeHome: URL
    var codexHome: URL
    var zcodeHome: URL
    var dshHome: URL
    var cursorDatabase: URL
    var claudeDesktopProfile: URL
    var grokBotProfile: URL
    var antigravityHome: URL
    var support: URL

    static func detect() -> DataLocations {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)

        func overridden(_ key: String, fallback: URL) -> URL {
            guard let value = env[key], value.hasPrefix("/") else { return fallback }
            return URL(filePath: value, directoryHint: .isDirectory)
        }

        return DataLocations(
            home: home,
            claudeHome: overridden("CLAUDE_CONFIG_DIR", fallback: home.appending(path: ".claude", directoryHint: .isDirectory)),
            codexHome: overridden("CODEX_HOME", fallback: home.appending(path: ".codex", directoryHint: .isDirectory)),
            zcodeHome: overridden("ZCODE_HOME", fallback: home.appending(path: ".zcode", directoryHint: .isDirectory)),
            dshHome: overridden("DSH_HOME", fallback: home.appending(path: ".dsh", directoryHint: .isDirectory)),
            cursorDatabase: appSupport.appending(path: "Cursor/User/globalStorage/state.vscdb"),
            claudeDesktopProfile: appSupport.appending(path: "Claude", directoryHint: .isDirectory),
            grokBotProfile: appSupport.appending(path: "Grok Bot", directoryHint: .isDirectory),
            antigravityHome: home.appending(path: ".gemini", directoryHint: .isDirectory),
            support: appSupport.appending(path: "WoodDeck", directoryHint: .isDirectory)
        )
    }

    func claudeProjects() -> URL { claudeHome.appending(path: "projects", directoryHint: .isDirectory) }

    // Antigravity 桌面版与 CLI 的会话数据库所在目录
    func antigravityDatabases() -> [URL] {
        var found: [URL] = []
        let candidates = [
            antigravityHome.appending(path: "antigravity/conversations", directoryHint: .isDirectory),
            antigravityHome.appending(path: "antigravity-cli/conversations", directoryHint: .isDirectory),
            antigravityHome.appending(path: "antigravity", directoryHint: .isDirectory)
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            found.append(candidate)
        }
        return found
    }

    // 应用自身的数据目录
    func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

enum SupportFiles {
    static var directory: URL { DataLocations.detect().support }
    static var settings: URL { directory.appending(path: "settings.json") }
    static var modelPrices: URL { directory.appending(path: "model-prices.json") }
    static var manualModelPrices: URL { directory.appending(path: "manual-model-prices.json") }
    static var crashLog: URL { directory.appending(path: "crash.log") }

    static func writeCrash(_ text: String) {
        let url = crashLog
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
