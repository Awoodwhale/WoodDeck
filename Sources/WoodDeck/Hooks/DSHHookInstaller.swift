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

    // 一个 dsh profile：目录名与所在位置，各自有一份 cordis.patch.yml
    struct Profile: Identifiable, Equatable {
        var name: String
        var directory: URL
        var id: String { name }
    }

    static var dshHome: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let value = ProcessInfo.processInfo.environment["DSH_HOME"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return home.appending(path: ".dsh", directoryHint: .isDirectory)
    }

    // 检测到的 profile：目录下有 cordis.patch.yml 的那些，web 排在最前
    static var profiles: [Profile] {
        let root = dshHome.appending(path: "profiles", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var found: [Profile] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || name == "node_modules" { continue }
            guard FileManager.default.fileExists(atPath: entry.appending(path: "cordis.patch.yml").path(percentEncoded: false)) else { continue }
            found.append(Profile(name: name, directory: entry))
        }
        return found.sorted { lhs, rhs in
            if lhs.name == "web" { return rhs.name != "web" }
            if rhs.name == "web" { return false }
            return lhs.name < rhs.name
        }
    }

    // names 为空表示检测到的全部 profile
    static func selectedProfiles(_ names: [String]) -> [Profile] {
        let all = profiles
        guard !names.isEmpty else { return all }
        return all.filter { names.contains($0.name) }
    }

    static func status(in profile: Profile) -> Status {
        let patch = profile.directory.appending(path: "cordis.patch.yml")
        guard let text = try? String(contentsOf: patch, encoding: .utf8) else {
            return .failed(Loc.t("读不到 cordis.patch.yml", "cordis.patch.yml could not be read"))
        }
        return text.contains(entryID) ? .installed : .notInstalled
    }

    // 全部选中的 profile 加起来的状态：只要有一个装了就算已启用
    static func status(names: [String]) -> Status {
        let targets = selectedProfiles(names)
        guard !targets.isEmpty else {
            return .failed(Loc.t("没有找到 DSH 的 profile 目录", "The DSH profile directory was not found"))
        }
        let states = targets.map { status(in: $0) }
        if states.contains(.installed) { return .installed }
        for state in states {
            if case .failed(let text) = state { return .failed(text) }
        }
        return .notInstalled
    }

    static func anyInstalled(names: [String]) -> Bool {
        selectedProfiles(names).contains { status(in: $0) == .installed }
    }

    static func pluginURL(in profile: Profile) -> URL {
        profile.directory.appending(path: pluginDirectoryName).appending(path: "index.mjs")
    }

    // 插件源码：应用包里自带一份。直接运行编译出的可执行文件（自检）时没有应用包，才读源码树。
    // 应用包内绝不去读源码树：源码可能在「下载」等受保护的目录里，读取会被系统授权弹窗卡住主线程
    static func pluginSource() throws -> String {
        let candidate: URL
        if Bundle.main.bundleIdentifier != nil {
            guard let resources = Bundle.main.resourceURL else {
                throw ProviderError.message(Loc.t("应用包缺少资源目录", "The app bundle has no resources directory"))
            }
            candidate = resources.appending(path: "dsh-plugin/index.mjs")
        } else {
            candidate = URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Resources/dsh-plugin/index.mjs")
        }
        if let text = try? String(contentsOf: candidate, encoding: .utf8), !text.isEmpty {
            return text
        }
        throw ProviderError.message(Loc.t("没有找到插件源码 \(candidate.path)", "The plugin source was not found at \(candidate.path)"))
    }

    @discardableResult
    static func install(executablePath: String, names: [String]) throws -> [Profile] {
        let targets = selectedProfiles(names)
        guard !targets.isEmpty else {
            throw ProviderError.message(Loc.t("没有找到 DSH 的 profile 目录，请先运行一次 dsh", "The DSH profile directory was not found; run dsh once first"))
        }
        let plugin = try pluginSource()
        for profile in targets {
            try install(plugin: plugin, executablePath: executablePath, in: profile)
        }
        return targets
    }

    private static func install(plugin: String, executablePath: String, in profile: Profile) throws {
        let patchFile = profile.directory.appending(path: "cordis.patch.yml")

        // 1. 写入插件
        let directory = profile.directory.appending(path: pluginDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try plugin.write(to: directory.appending(path: "index.mjs"), atomically: true, encoding: .utf8)

        // 2. 备份并追加挂载条目
        let original = (try? String(contentsOf: patchFile, encoding: .utf8)) ?? ""
        let backup = profile.directory.appending(path: "cordis.patch.yml.bak-wooddeck")
        if !FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) {
            try? original.write(to: backup, atomically: true, encoding: .utf8)
        }
        var text = replacingEmptyArray(in: removingBlock(from: original))
        if !text.hasSuffix("\n"), !text.isEmpty { text += "\n" }
        text += try block(executablePath: executablePath)
        try text.write(to: patchFile, atomically: true, encoding: .utf8)

        // 3. 校验：解析失败就恢复原文件
        do {
            _ = try Yams.load(yaml: text)
        } catch {
            try? original.write(to: patchFile, atomically: true, encoding: .utf8)
            throw ProviderError.message(Loc.t("\(profile.name) 的 cordis.patch.yml 校验失败，已恢复原文件：\(error.localizedDescription)",
                                              "cordis.patch.yml in \(profile.name) failed validation and was restored: \(error.localizedDescription)"))
        }
    }

    @discardableResult
    static func uninstall(names: [String]) -> [Profile] {
        let targets = selectedProfiles(names)
        for profile in targets {
            let patchFile = profile.directory.appending(path: "cordis.patch.yml")
            if let original = try? String(contentsOf: patchFile, encoding: .utf8) {
                let text = restoringEmptyArray(in: removingOrphanComments(from: removingBlock(from: original)))
                try? text.write(to: patchFile, atomically: true, encoding: .utf8)
            }
            try? FileManager.default.removeItem(at: profile.directory.appending(path: pluginDirectoryName))
        }
        return targets
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

    // 文件内容可能是空数组 `[]`：直接追加条目会得到非法 YAML，先去掉那一行
    private static func replacingEmptyArray(in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var emptyArrayIndex: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            guard trimmed == "[]" else { return text }
            emptyArrayIndex = index
        }
        guard let emptyArrayIndex else { return text }
        lines.remove(at: emptyArrayIndex)
        return lines.joined(separator: "\n")
    }

    // 卸载后如果只剩注释，补回空数组，文件仍然是合法的 YAML 数组
    private static func restoringEmptyArray(in text: String) -> String {
        let hasContent = text.components(separatedBy: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed != "---"
        }
        guard !hasContent else { return text }
        var result = text
        if !result.hasSuffix("\n") { result += "\n" }
        return result + "[]\n"
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
