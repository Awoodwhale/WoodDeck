import Foundation
import Yams

// DeepSeek Harness 的会话通知插件：检测本机是否装了 dsh，把插件放进 profile 并挂到 cordis.patch.yml
@MainActor
enum DSHHookInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed
        case failed(String)

        var label: String {
            switch self {
            case .notInstalled: Loc.t("未启用", "Not enabled")
            case .installed: Loc.t("已启用", "Enabled")
            case .failed(let text): text
            }
        }
    }

    static let pluginDirectoryName = "dsh-wooddeck-hook"
    static let entryID = "wooddeck-hook"
    private static let startMarker = "# WoodDeck: DSH 会话通知插件，由 WoodDeck 设置页维护"
    private static let endMarker = "# WoodDeck: 以上由 WoodDeck 维护"

    // 常见的 dsh 安装位置；也支持用户在设置里指定
    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
            home.appending(path: ".local/bin/dsh").path(percentEncoded: false),
            home.appending(path: "Library/pnpm/bin/dsh").path(percentEncoded: false),
            home.appending(path: ".npm-global/bin/dsh").path(percentEncoded: false)
        ]
    }

    static func locateDSH(customPath: String) -> String? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return FileManager.default.isExecutableFile(atPath: trimmed) ? trimmed : nil
        }
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // DSH 的 profile 目录里有 cordis.patch.yml；优先 web，否则找第一个有该文件的
    static var profileDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"].flatMap { value in
            value.hasPrefix("/") ? URL(filePath: value, directoryHint: .isDirectory) : nil
        } ?? home.appending(path: ".dsh", directoryHint: .isDirectory)
        let profiles = dshHome.appending(path: "profiles", directoryHint: .isDirectory)
        let preferred = profiles.appending(path: "web", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: preferred.appending(path: "cordis.patch.yml").path(percentEncoded: false)) {
            return preferred
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries.first { FileManager.default.fileExists(atPath: $0.appending(path: "cordis.patch.yml").path(percentEncoded: false)) }
    }

    static var patchFile: URL? {
        profileDirectory?.appending(path: "cordis.patch.yml")
    }

    static func status() -> Status {
        guard let patchFile, let text = try? String(contentsOf: patchFile, encoding: .utf8) else {
            return .failed(Loc.t("没有找到 DSH 的 profile 目录", "The DSH profile directory was not found"))
        }
        if text.contains(entryID) {
            return FileManager.default.isExecutableFile(atPath: installedPluginURL?.path(percentEncoded: false) ?? "")
                ? .installed
                : .installed
        }
        return .notInstalled
    }

    static var installedPluginURL: URL? {
        profileDirectory?.appending(path: pluginDirectoryName).appending(path: "index.mjs")
    }

    // 插件源码：优先用应用包里的副本，开发期回退到源码树
    static func pluginSource() throws -> String {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appending(path: "dsh-plugin/index.mjs"))
        }
        let source = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/dsh-plugin/index.mjs")
        candidates.append(source)
        for candidate in candidates {
            if let text = try? String(contentsOf: candidate, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        throw ProviderError.message(Loc.t("没有找到插件源码 dsh-plugin/index.mjs", "The plugin source dsh-plugin/index.mjs was not found"))
    }

    static func install(executablePath: String) throws {
        guard let profileDirectory else {
            throw ProviderError.message(Loc.t("没有找到 DSH 的 profile 目录，请先运行一次 dsh", "The DSH profile directory was not found; run dsh once first"))
        }
        guard let patchFile else {
            throw ProviderError.message(Loc.t("没有找到 cordis.patch.yml", "cordis.patch.yml was not found"))
        }

        // 1. 写入插件
        let directory = profileDirectory.appending(path: pluginDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plugin = try pluginSource()
        try plugin.write(to: directory.appending(path: "index.mjs"), atomically: true, encoding: .utf8)

        // 2. 备份并追加挂载条目
        let original = (try? String(contentsOf: patchFile, encoding: .utf8)) ?? ""
        let backup = patchFile.deletingLastPathComponent().appending(path: "cordis.patch.yml.bak-wooddeck")
        if !FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) {
            try? original.write(to: backup, atomically: true, encoding: .utf8)
        }
        var text = removingBlock(from: original)
        if !text.hasSuffix("\n"), !text.isEmpty { text += "\n" }
        text += try block(executablePath: executablePath)
        try text.write(to: patchFile, atomically: true, encoding: .utf8)

        // 3. 校验：解析失败就回滚
        do {
            _ = try Yams.load(yaml: text)
        } catch {
            try? original.write(to: patchFile, atomically: true, encoding: .utf8)
            throw ProviderError.message(Loc.t("cordis.patch.yml 校验失败，已恢复原文件：\(error.localizedDescription)",
                                              "cordis.patch.yml failed validation and was restored: \(error.localizedDescription)"))
        }
        SettingsStore.shared.update { $0.dshHookEnabled = true }
    }

    static func uninstall() {
        guard let patchFile, let original = try? String(contentsOf: patchFile, encoding: .utf8) else { return }
        let text = removingOrphanComments(from: removingBlock(from: original))
        try? text.write(to: patchFile, atomically: true, encoding: .utf8)
        if let directory = profileDirectory?.appending(path: pluginDirectoryName) {
            try? FileManager.default.removeItem(at: directory)
        }
        SettingsStore.shared.update { $0.dshHookEnabled = false }
    }

    // 生成挂载条目；路径里可能带空格，用单引号包住
    private static func block(executablePath: String) throws -> String {
        let quoted = executablePath.replacingOccurrences(of: "'", with: "''")
        return """
        \(startMarker)
        - insert:
            - id: \(entryID)
              name: './\(pluginDirectoryName)/index.mjs'
              config:
                binaryPath: '\(quoted)'
        \(endMarker)

        """
    }

    // 删除已有条目：既包括带标记的段落，也包括手工添加过的同 id 条目，保证重复安装不会重复挂载
    private static func removingBlock(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        while let start = lines.firstIndex(where: { $0.hasPrefix(startMarker) }) {
            if let end = lines[start...].firstIndex(where: { $0.hasPrefix(endMarker) }) {
                lines.removeSubrange(start...end)
            } else {
                lines.removeSubrange(start..<lines.count)
            }
        }

        while let idIndex = lines.firstIndex(where: isOurEntryLine) {
            var start = idIndex
            while start > 0, !lines[start].hasPrefix("- insert:") {
                start -= 1
            }
            guard lines[start].hasPrefix("- insert:") else {
                lines.remove(at: idIndex)
                continue
            }
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("- ") {
                end += 1
            }
            lines.removeSubrange(start..<end)
            // 相邻的多余空行只留一个
            while start < lines.count, start > 0, lines[start].isEmpty, lines[start - 1].isEmpty {
                lines.remove(at: start)
            }
        }
        return lines.joined(separator: "\n")
    }

    // 手工添加过的说明注释也一并清掉，避免卸载后留下孤立的注释
    private static func removingOrphanComments(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") && (trimmed.contains("WoodDeck") || trimmed.contains("dsh-wooddeck-hook")) {
                skipping = true
                continue
            }
            if skipping {
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                skipping = false
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    private static func isOurEntryLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- id: \(entryID)") || trimmed.hasPrefix("id: \(entryID)")
    }
}
