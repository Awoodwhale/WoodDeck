import AppKit

// 自检类命令会启动会话中心，若沿用正式套接字会把正在运行的应用的监听顶掉，
// 这里统一改用临时路径，互不干扰
let diagnosticFlags = ["--watchtest", "--sessiontest", "--conversationtest", "--compacttest",
                       "--renderpages", "--scrolltest", "--popuptest", "--hittest",
                       "--hovercost", "--hoverbreakdown", "--screentest", "--selftest", "--settingstest",
                       "--lyricswichtest", "--lyricfadetest", "--monitortest", "--memunittest",
                       "--marqueetest", "--marqueevisible", "--musicrender", "--monitorrender", "--pagetest",
                       "--shots"]
if ProcessInfo.processInfo.environment["WOODDECK_HOOK_SOCKET"] == nil,
   CommandLine.arguments.contains(where: { diagnosticFlags.contains($0) }) {
    let temp = FileManager.default.temporaryDirectory
        .appending(path: "wooddeck-selftest-\(ProcessInfo.processInfo.processIdentifier).sock")
    setenv("WOODDECK_HOOK_SOCKET", temp.path(percentEncoded: false), 1)
}

// 各助手调用 `WoodDeck --hook <agent>` 时，只发送事件并立刻退出，不启动界面
if HookEmitter.handleIfRequested() {
    exit(0)
}

// 命令行安装或卸载各助手的接入，便于在终端里管理
if let flag = CommandLine.arguments.firstIndex(where: { $0 == "--install-hooks" || $0 == "--uninstall-hooks" }),
   flag + 1 < CommandLine.arguments.count,
   let agent = AgentKind(rawValue: CommandLine.arguments[flag + 1]) {
    if CommandLine.arguments[flag] == "--install-hooks" {
        HookInstaller.install(agent)
        print("已安装 \(agent.displayName) 接入")
    } else {
        HookInstaller.uninstall(agent)
        print("已卸载 \(agent.displayName) 接入")
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--musicrender"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { HoverTest.renderMusic(directory: CommandLine.arguments[index + 1]) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--monitorrender"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { HoverTest.renderMonitor(directory: CommandLine.arguments[index + 1]) }
    exit(0)
}

if CommandLine.arguments.contains("--lyricfadetest") {
    MainActor.assumeIsolated {
        Task {
            await LyricFadeTest.run()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }
    exit(0)
}

if CommandLine.arguments.contains("--lyricswichtest") {
    MainActor.assumeIsolated {
        Task {
            await SelfTest.lyricSwitchTest()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }
    exit(0)
}

if CommandLine.arguments.contains("--memunittest") {
    MainActor.assumeIsolated { SelfTest.memoryUnitTest() }
    exit(0)
}

if CommandLine.arguments.contains("--marqueevisible") {
    MainActor.assumeIsolated { SelfTest.marqueeVisibilityTest() }
    exit(0)
}

if CommandLine.arguments.contains("--marqueetest") {
    MainActor.assumeIsolated { SelfTest.marqueeTest() }
    exit(0)
}

if CommandLine.arguments.contains("--settingschrome") {
    MainActor.assumeIsolated { HoverTest.settingsChromeReport() }
    exit(0)
}

if CommandLine.arguments.contains("--monitortest") {
    MainActor.assumeIsolated {
        Task {
            await SelfTest.monitorTest()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }
    exit(0)
}

if CommandLine.arguments.contains("--watchtest") {
    MainActor.assumeIsolated {
        Task {
            await SelfTest.watchTest()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }
    exit(0)
}

if CommandLine.arguments.contains("--screentest") {
    MainActor.assumeIsolated { SelfTest.screenTest() }
    exit(0)
}

// DSH 会话通知插件的安装与卸载，便于在终端里管理
if let index = CommandLine.arguments.firstIndex(of: "--dsh-hook"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        let action = CommandLine.arguments[index + 1]
        switch action {
        case "install":
            do {
                let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
                try DSHHookInstaller.install(executablePath: binary)
                print("已安装：\(DSHHookInstaller.installedPluginURL?.path(percentEncoded: false) ?? "-")")
            } catch {
                print("安装失败：\(error.localizedDescription)")
                exit(1)
            }
        case "uninstall":
            DSHHookInstaller.uninstall()
            print("已卸载")
        default:
            print("状态：\(DSHHookInstaller.status().label)")
            print("dsh 路径：\(DSHHookInstaller.locateDSH(customPath: SettingsStore.shared.settings.dshPath) ?? "未找到")")
            print("profile：\(DSHHookInstaller.profileDirectory?.path(percentEncoded: false) ?? "未找到")")
        }
    }
    exit(0)
}

// 悬停逻辑自检：不显示窗口、不移动光标
if let index = CommandLine.arguments.firstIndex(of: "--hovertest") {
    let mode = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "notch"
    MainActor.assumeIsolated { HoverTest.run(mode: mode) }
    exit(0)
}

if CommandLine.arguments.contains("--hoverbreakdown") {
    MainActor.assumeIsolated { HoverTest.hoverBreakdownReport() }
    exit(0)
}

if CommandLine.arguments.contains("--hovercost") {
    MainActor.assumeIsolated { HoverTest.hoverCostReport() }
    exit(0)
}

if CommandLine.arguments.contains("--hittest") {
    MainActor.assumeIsolated { HoverTest.hitZoneReport() }
    exit(0)
}

if CommandLine.arguments.contains("--popuptest") {
    MainActor.assumeIsolated { HoverTest.sessionPopupReport() }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--shots"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { ShotRender.run(directory: CommandLine.arguments[index + 1]) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--compacttest"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { HoverTest.renderCompact(directory: CommandLine.arguments[index + 1]) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--abouttest"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { HoverTest.renderAbout(directory: CommandLine.arguments[index + 1]) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--conversationtest"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        SessionCenter.shared.start()
        SessionCenter.shared.refreshInstalledState()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        HoverTest.renderConversation(directory: CommandLine.arguments[index + 1])
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--scrolltest"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { HoverTest.scrollingTextReport(directory: CommandLine.arguments[index + 1]) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--renderpages"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { HoverTest.renderPages(directory: CommandLine.arguments[index + 1]) }
    exit(0)
}

if CommandLine.arguments.contains("--pagetest") {
    MainActor.assumeIsolated { HoverTest.pagesReport() }
    exit(0)
}

// 面板截图自检：展开显示指定页面，不激活
if let index = CommandLine.arguments.firstIndex(of: "--panelshot"), index + 2 < CommandLine.arguments.count {
    let pageName = CommandLine.arguments[index + 1]
    let path = CommandLine.arguments[index + 2]
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let page: DeckPage = pageName == "sessions" ? .sessions : (pageName == "music" ? .music : .quota)
        delegate.showPanelForCapture(page: page)
        Thread.sleep(forTimeInterval: 1.2)
        let id = delegate.panelWindowNumber
        let task = Process()
        task.executableURL = URL(filePath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(id), path]
        try? task.run()
        task.waitUntilExit()
        print("已截图 \(path) 窗口=\(id)")
        delegate.model.shutdown()
    }
    exit(0)
}

// 设置窗口截图自检：显示但不抢焦点，随后自行退出
if CommandLine.arguments.contains("--settingsshot") {
    MainActor.assumeIsolated {
        let window = SettingsWindowController.shared.showForCapture()
        let id = window.windowNumber
        print("窗口 id=\(id) 尺寸=\(Int(window.frame.width))x\(Int(window.frame.height))")
        Thread.sleep(forTimeInterval: 0.8)
        let task = Process()
        task.executableURL = URL(filePath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(id), CommandLine.arguments.last ?? "settings-shot.png"]
        try? task.run()
        task.waitUntilExit()
        window.orderOut(nil)
    }
    exit(0)
}

// 设置窗口自检：离屏创建，不激活、不显示
if CommandLine.arguments.contains("--settingstest") {
    MainActor.assumeIsolated {
        let shown = CommandLine.arguments.contains("shown")
        for line in SettingsWindowController.shared.inspectOffscreen(shown: shown) {
            print(line)
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    // 需要主运行循环来处理界面状态，任务结束后停止循环
    MainActor.assumeIsolated {
        Task {
            await SelfTest.dumpUI()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }
    exit(0)
}

if CommandLine.arguments.contains("--sessiontest") {
    MainActor.assumeIsolated {
        Task {
            await SelfTest.sessionTest()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await SelfTest.run()
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// 收到终止信号时走正常退出流程，保证子进程被结束
func installSignalHandlers() {
    for signalNumber in [SIGTERM, SIGINT] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        signalSources.append(source)
    }
}

var signalSources: [DispatchSourceSignal] = []

MainActor.assumeIsolated {
    installSignalHandlers()
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
