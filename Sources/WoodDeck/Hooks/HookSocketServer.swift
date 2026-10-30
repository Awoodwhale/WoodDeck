import Foundation

// 助手通过本机 Unix 套接字把事件推给应用；不占用端口，也不经过网络
enum HookSocket {
    static var directory: URL { SupportFiles.directory.appending(path: "hooks", directoryHint: .isDirectory) }
    // 测试或多实例场景可以用环境变量指定独立路径
    static var path: URL {
        if let custom = ProcessInfo.processInfo.environment["WOODDECK_HOOK_SOCKET"], custom.hasPrefix("/") {
            return URL(filePath: custom)
        }
        return directory.appending(path: "sessions.sock")
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// 监听套接字并把事件交给上层
final class HookSocketServer {
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.wooddeck.hooks.accept")
    private let readQueue = DispatchQueue(label: "com.wooddeck.hooks.read", attributes: .concurrent)
    private let handler: (AgentEvent) -> Void

    init(handler: @escaping (AgentEvent) -> Void) {
        self.handler = handler
    }

    // 尝试连接一次，判断是否已有实例在监听
    static func hasListener(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = path.withCString { source in
                    strncpy(destination, source, capacity - 1)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return result == 0
    }

    func start() {
        stop()
        do {
            try HookSocket.prepare()
        } catch {
            SupportFiles.writeCrash("hook 目录创建失败：\(error.localizedDescription)")
            return
        }
        let path = HookSocket.path.path(percentEncoded: false)
        // 已经有实例在监听时绝不能删掉这个路径：unlink 会让老实例变成找不到的孤儿监听，
        // 之后所有 hook 都连不上，表现为「助手明明在跑却没有会话」
        if HookSocketServer.hasListener(at: path) {
            SupportFiles.writeCrash("已有实例在监听 hook 套接字，本实例跳过监听")
            return
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            SupportFiles.writeCrash("hook 套接字创建失败")
            return
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            SupportFiles.writeCrash("hook 套接字路径过长")
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                _ = strncpy(chars, path, capacity - 1)
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else {
            close(fd)
            SupportFiles.writeCrash("hook 套接字绑定失败：\(errno)")
            return
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            SupportFiles.writeCrash("hook 套接字监听失败：\(errno)")
            return
        }
        // 监听套接字设为非阻塞，accept 在没有连接时立刻返回，避免占住队列
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // 只允许当前用户访问
        chmod(path, 0o600)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 {
            close(listener)
            listener = -1
        }
        unlink(HookSocket.path.path(percentEncoded: false))
    }

    private func acceptConnections() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            // 接受的连接会继承监听套接字的非阻塞标志，这里改回阻塞，读取会等到数据或对端关闭
            let clientFlags = fcntl(client, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
            }
            readQueue.async { [weak self] in
                self?.read(from: client)
            }
        }
    }

    private func read(from client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        // 事件很小，最多读 256 KB 防止异常输入占满内存
        while data.count < 262_144 {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.contains(0x0A) { break }
        }
        guard !data.isEmpty else { return }
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let event = HookPayload.parse(Data(line)) else {
                continue
            }
            handler(event)
        }
    }
}

// 把各助手推来的原始 JSON 归一成统一事件
enum HookPayload {
    static func parse(_ data: Data) -> AgentEvent? {
        guard let json = try? JSONValue.parse(data) else { return nil }
        return from(json)
    }

    static func from(_ json: JSONValue) -> AgentEvent? {
        // WoodDeck 自己的协议优先
        if let agent = AgentKind(rawValue: json["agent"].text) {
            return AgentEvent(agent: agent,
                              event: json["event"].text,
                              session: json["session"].text,
                              cwd: json["cwd"].text,
                              title: json["title"].text,
                              name: json["name"].text,
                              message: json["message"].text,
                              tool: json["tool"].text,
                              pid: json["pid"].int,
                              timestamp: json["timestamp"].float)
        }
        return nil
    }
}
