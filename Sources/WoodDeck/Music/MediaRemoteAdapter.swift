import Foundation

// MediaCommand 的编号与 MediaRemote 的取值一致，定义在 Core/Models.swift

struct NowPlaying: Sendable, Equatable {
    var bundleIdentifier: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var playing: Bool
    var artwork: Data?
    var uniqueIdentifier: String
    var shuffleMode: Int?
    var repeatMode: Int?
    // 喜欢状态：只有播放器同时报告支持与当前值时才可用
    var supportsLiked: Bool
    var liked: Bool
}

// 通过有签名的 perl 加载 MediaRemoteAdapter.framework，读取系统「正在播放」并发送控制命令
actor MediaRemoteAdapter {
    private static let perlPath = "/usr/bin/perl"
    private static let scriptName = "mediaremote-adapter.pl"
    private static let frameworkName = "MediaRemoteAdapter.framework"
    private static let testClientName = "MediaRemoteAdapterTestClient"
    private static let commandTimeout: TimeInterval = 5

    private let resources: URL
    private var process: Process?
    private var errorPipe: Pipe?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncStream<NowPlaying?>.Continuation?
    private var stream: AsyncStream<NowPlaying?>
    private var failure: String?
    private var last: NowPlaying?
    private var emitted = false
    private var artworkCache: [String: Data] = [:]
    private var missingArtwork: Set<String> = []
    private var artworkOrder: [String] = []

    init(resources: URL) {
        self.resources = resources
        let pair = AsyncStream<NowPlaying?>.makeStream(bufferingPolicy: .bufferingNewest(4))
        stream = pair.stream
        continuation = pair.continuation
    }

    private var scriptURL: URL { resources.appendingPathComponent(Self.scriptName) }
    private var frameworkURL: URL { resources.appendingPathComponent(Self.frameworkName) }

    func updates() -> AsyncStream<NowPlaying?> { stream }

    func failureReason() -> String? { failure }

    // 启动读取进程。连续失败三次（含两次重试）后抛出真实原因
    func start() async throws {
        if let process, process.isRunning { return }
        failure = nil
        var lastError: Error = ProviderError.readFailed(Loc.t("音乐来源没有启动", "The music source did not start"))
        for attempt in 0...2 {
            do {
                try await launch()
                return
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
        }
        failure = lastError.localizedDescription
        throw lastError
    }

    // 重新启动读取进程，之后重新调用 updates() 取得新的更新序列
    func restart() async throws {
        stop()
        try await start()
    }

    func stop() {
        release()
    }

    func isFunctional() async -> Bool {
        let client = resources.appendingPathComponent(Self.testClientName)
        guard FileManager.default.fileExists(atPath: client.path) else { return false }
        do {
            _ = try await run([client.path, "test"])
            return true
        } catch {
            return false
        }
    }

    func send(_ command: MediaCommand) async throws {
        _ = try await run(["send", String(command.rawValue)])
    }

    func seek(to seconds: Double) async throws {
        let micros = max(0, (seconds * 1_000_000).rounded())
        _ = try await run(["seek", String(Int64(micros))])
    }

    func setShuffle(_ mode: Int) async throws {
        _ = try await run(["shuffle", String(mode)])
    }

    func setRepeat(_ mode: Int) async throws {
        _ = try await run(["repeat", String(mode)])
    }

    private func launch() async throws {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ProviderError.readFailed(Loc.t("缺少 mediaremote-adapter.pl", "mediaremote-adapter.pl is missing"))
        }
        guard FileManager.default.fileExists(atPath: frameworkURL.path) else {
            throw ProviderError.readFailed(Loc.t("缺少 MediaRemoteAdapter.framework", "MediaRemoteAdapter.framework is missing"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.perlPath)
        process.arguments = [scriptURL.path, frameworkURL.path, "stream", "--no-diff", "--debounce=120"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw ProviderError.readFailed(Loc.t("无法启动 perl：\(error.localizedDescription)", "Unable to launch perl: \(error.localizedDescription)"))
        }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        self.process = process
        errorPipe = error
        // 立刻退出说明 adapter 在当前系统上不可用，perl 的错误输出就是原因
        try await Task.sleep(nanoseconds: 150_000_000)
        guard process.isRunning else {
            let detail = readAll(error.fileHandleForReading)
            let code = process.terminationStatus
            self.process = nil
            errorPipe = nil
            throw ProviderError.readFailed(Loc.t(
                "音乐来源进程退出（退出码 \(code)）\(detail.isEmpty ? "" : "：\(detail)")",
                "The music source process exited (code \(code))\(detail.isEmpty ? "" : ": \(detail)")"))
        }
        last = nil
        emitted = false
        consume(output)
    }

    private func consume(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        // 读取必须离开 actor，否则阻塞的管道读取会占住 actor，start() 迟迟不能返回
        reader = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await line in handle.bytes.lines {
                    await self.receive(line)
                }
            } catch {
                await self.note(error.localizedDescription)
            }
            await self.finishFromExit()
        }
    }

    // 子进程结束意味着音乐来源不可用：记录原因并结束 updates
    private func finishFromExit() async {
        reader = nil
        guard let process else { return }
        // 输出通道关闭后进程通常立刻结束，仍在运行就先结束它
        var waited = 0
        while process.isRunning && waited < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        if process.isRunning { process.terminate() }
        var grace = 0
        while process.isRunning && grace < 25 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            grace += 1
        }
        if failure == nil {
            if process.isRunning {
                failure = Loc.t("音乐来源已停止（进程没有结束）", "The music source stopped (the process did not exit)")
            } else {
                let detail = errorPipe.map { readAll($0.fileHandleForReading) } ?? ""
                let code = process.terminationStatus
                failure = Loc.t(
                    "音乐来源已停止（退出码 \(code)）\(detail.isEmpty ? "" : "：\(detail)")",
                    "The music source stopped (code \(code))\(detail.isEmpty ? "" : ": \(detail)")")
            }
        }
        release()
    }

    private func note(_ text: String) {
        if failure == nil { failure = text }
    }

    private func release() {
        reader?.cancel()
        reader = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        errorPipe = nil
        continuation?.finish()
        // 结束后换一条新流，再次 start() 时上层能重新取得更新
        let pair = AsyncStream<NowPlaying?>.makeStream(bufferingPolicy: .bufferingNewest(4))
        stream = pair.stream
        continuation = pair.continuation
        last = nil
        emitted = false
    }

    private func receive(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8), let root = try? JSONValue.parse(data) else { return }
        // 只处理 stream 的数据事件
        if let type = root["type"].string, type != "data" { return }
        let item = nowPlaying(root["payload"])
        // 没有正在播放的媒体时 payload 为空字典，nil 也要发一次，上层才能清空显示
        guard !emitted || item != last else { return }
        emitted = true
        last = item
        continuation?.yield(item)
    }

    private func nowPlaying(_ payload: JSONValue) -> NowPlaying? {
        guard let object = payload.object, !object.isEmpty else { return nil }
        let title = payload["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let bundle = payload["bundleIdentifier"].text
        let artist = payload["artist"].text
        let album = payload["album"].text
        let unique = payload["uniqueIdentifier"].text.isEmpty
            ? payload["contentItemIdentifier"].text
            : payload["uniqueIdentifier"].text
        let rate = payload["playbackRate"].float ?? 1
        let key = unique.isEmpty ? "\(bundle)|\(artist)|\(title)|\(album)" : unique
        return NowPlaying(
            bundleIdentifier: bundle,
            title: title,
            artist: artist,
            album: album,
            duration: max(0, payload["duration"].float ?? 0),
            elapsed: max(0, payload["elapsedTime"].float ?? 0),
            // 系统给出的 timestamp 是采样时刻，新版 adapter 用 epoch 秒，也可能出现日期字符串
            timestamp: JSONDate.parse(payload["timestamp"]) ?? Date(),
            rate: rate,
            playing: payload["playing"].bool ?? (rate > 0),
            artwork: artwork(from: payload, key: key),
            uniqueIdentifier: unique,
            shuffleMode: payload["shuffleMode"].int,
            repeatMode: payload["repeatMode"].int,
            supportsLiked: payload["supportsIsLiked"].bool ?? false,
            liked: payload["isLiked"].bool ?? false)
    }

    // 同一曲目每次更新都会重复整份封面，按曲目标识缓存解码结果
    private func artwork(from payload: JSONValue, key: String) -> Data? {
        if let cached = artworkCache[key] { return cached }
        if missingArtwork.contains(key) { return nil }
        let encoded = payload["artworkData"].string ?? ""
        guard !encoded.isEmpty else { return nil }
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty else {
            missingArtwork.insert(key)
            return nil
        }
        artworkCache[key] = data
        artworkOrder.append(key)
        while artworkOrder.count > 8 {
            let old = artworkOrder.removeFirst()
            artworkCache.removeValue(forKey: old)
            missingArtwork.remove(old)
        }
        return data
    }

    // 控制命令用一次性进程执行，等待真实退出码
    private func run(_ arguments: [String]) async throws -> String {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ProviderError.readFailed(Loc.t("缺少 mediaremote-adapter.pl", "mediaremote-adapter.pl is missing"))
        }
        guard FileManager.default.fileExists(atPath: frameworkURL.path) else {
            throw ProviderError.readFailed(Loc.t("缺少 MediaRemoteAdapter.framework", "MediaRemoteAdapter.framework is missing"))
        }
        let name = arguments.last == "test" ? "test" : (arguments.first ?? "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.perlPath)
        process.arguments = [scriptURL.path, frameworkURL.path] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw ProviderError.readFailed(Loc.t("无法启动 perl：\(error.localizedDescription)", "Unable to launch perl: \(error.localizedDescription)"))
        }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(Self.commandTimeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw ProviderError.readFailed(Loc.t("命令 \(name) 超时", "Command \(name) timed out"))
        }
        let detail = readAll(error.fileHandleForReading)
        let text = readAll(output.fileHandleForReading)
        guard process.terminationStatus == 0 else {
            let reason = detail.isEmpty ? text : detail
            throw ProviderError.readFailed(Loc.t(
                "命令 \(name) 失败（退出码 \(process.terminationStatus)）\(reason.isEmpty ? "" : "：\(reason)")",
                "Command \(name) failed (code \(process.terminationStatus))\(reason.isEmpty ? "" : ": \(reason)")"))
        }
        return text
    }

    private func readAll(_ handle: FileHandle) -> String {
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
