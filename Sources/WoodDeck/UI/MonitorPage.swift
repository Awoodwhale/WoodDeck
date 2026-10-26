import SwiftUI

// 系统监控页：主表盘只放内存（这里最关注的指标），下面是 CPU 与逐核心、一行网络，
// 最后是默认收起的「内存占用最高的应用」，点击展开前 10 项。
struct MonitorPageView: View {
    @ObservedObject var monitor: SystemMonitorModel
    @State private var showsProcesses: Bool

    init(monitor: SystemMonitorModel, expandedProcesses: Bool = false) {
        self.monitor = monitor
        _showsProcesses = State(initialValue: expandedProcesses)
    }

    var body: some View {
        ScrollView(.vertical) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.visible)
    }

    // 页面内容单独拆出来，便于离屏渲染自检（ImageRenderer 不渲染滚动视图）
    @ViewBuilder
    var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            memoryGauge
            cpuAndNetworkRow
            coreColumns
            processDisclosure
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - 内存（唯一一处内存读数）

    private var memoryGauge: some View {
        let memory = monitor.sample.memory.orNil
        return HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .stroke(memoryColor(memory?.fraction ?? 0).opacity(0.25), lineWidth: 2.5)
                    .frame(width: 26, height: 26)
                Text("M")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(memoryColor(memory?.fraction ?? 0))
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(memory == nil ? "—" : String(format: "%.0f", (memory?.fraction ?? 0) * 100))
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.96))
                Text("%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if let memory {
                Text(String(format: "%.1f / %.0f GB",
                            Double(memory.used) / 1_073_741_824, Double(memory.total) / 1_073_741_824))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            trend
        }
    }

    private func memoryColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: Theme.color("#5B9BFF")
        case ..<0.85: Theme.color("#F0B54A")
        default: Theme.color("#FF6B5E")
        }
    }

    // 最近一分钟的内存走势
    private var trend: some View {
        let values = monitor.memoryHistory
        return GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * step
                    let y = proxy.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Theme.color("#5B9BFF").opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 92, height: 24)
    }

    // MARK: - CPU 与逐核心

    // CPU 与网络并成一行：左边 CPU 占用与核心数，右边网络上下行
    private var cpuAndNetworkRow: some View {
        let cpu = monitor.sample.cpu.orNil
        let network = monitor.sample.network.orNil
        return HStack(spacing: 6) {
            dial(letter: "C", color: coreColor(cpu?.usage ?? 0), size: 20)
            Text(cpu == nil ? "—" : String(format: "%.0f%%", (cpu?.usage ?? 0) * 100))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
            if let cpu, !cpu.cores.isEmpty {
                Text(Loc.t("\(cpu.cores.count) 核", "\(cpu.cores.count) cores"))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer(minLength: 8)
            dial(letter: "N", color: Theme.color("#5B9BFF"), size: 20)
            if let network {
                rate(icon: "arrow.down", value: MonitorPageView.rate(network.receiveBytesPerSecond), color: Theme.color("#5B9BFF"))
                rate(icon: "arrow.up", value: MonitorPageView.rate(network.sendBytesPerSecond), color: Theme.color("#45D1BD"))
            } else {
                Text(monitor.sample.network.reason)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    // 字母环
    private func dial(letter: String, color: Color, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: 2)
                .frame(width: size, height: size)
            Text(letter)
                .font(.system(size: size * 0.47, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private var coreColumns: some View {
        let cores = monitor.sample.cpu.orNil?.cores ?? []
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(cores) { core in
                VStack(spacing: 2) {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(coreColor(core.usage))
                                .frame(height: max(1.5, proxy.size.height * core.usage))
                        }
                    }
                    .frame(height: 18)
                    Text("\(core.id + 1)")
                        .font(.system(size: 7).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.28))
                }
                .frame(maxWidth: 20)
            }
            Spacer(minLength: 0)
        }
    }

    private func coreColor(_ usage: Double) -> Color {
        switch usage {
        case ..<0.5: Theme.color("#45D1BD")
        case ..<0.8: Theme.color("#F0B54A")
        default: Theme.color("#FF6B5E")
        }
    }

    // MARK: - 网络（一行）

    private func rate(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - 应用列表（默认收起，点击展开前 10 项）

    private var processDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showsProcesses.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsProcesses ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 9)
                    Text(Loc.t("内存占用最高的应用", "Top apps by memory"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    if !monitor.sample.processes.isEmpty {
                        Text("\(monitor.sample.processes.count)")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Spacer(minLength: 0)
                    if !showsProcesses, let first = monitor.sample.processes.first {
                        Text("\(first.name) · \(MonitorPageView.memory(first.memory))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.32))
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsProcesses {
                if monitor.sample.processes.isEmpty {
                    Text(Loc.t("还没有读到应用占用", "No app usage read yet"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.leading, 15)
                } else {
                    VStack(spacing: 3) {
                        ForEach(monitor.sample.processes) { process in
                            HStack(spacing: 6) {
                                Text(process.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.78))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(String(format: "%.1f%%", process.cpu * 100))
                                    .font(.system(size: 9.5).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 42, alignment: .trailing)
                                Text(MonitorPageView.memory(process.memory))
                                    .font(.system(size: 9.5).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.35))
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.leading, 15)
                }
            }
        }
    }

    // 内存单位：不足 1 GB 用 MB，超过就用 GB 并保留一位小数
    nonisolated static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        return String(format: "%.0f MB", megabytes)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite else { return "—" }
        switch bytesPerSecond {
        case ..<1024: return String(format: "%.0f B/s", bytesPerSecond)
        case ..<1_048_576: return String(format: "%.1f KB/s", bytesPerSecond / 1024)
        default: return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
    }
}

// 监控数据模型：每秒采样一次，并保留最近一分钟的内存走势
@MainActor
final class SystemMonitorModel: ObservableObject {
    static let shared = SystemMonitorModel()
    @Published private(set) var sample = SystemSample(cpu: .unavailable("尚未采样"),
                                                      memory: .unavailable("尚未采样"),
                                                      network: .unavailable("尚未采样"),
                                                      gpu: .unavailable("尚未采样"),
                                                      processes: [])
    // 最近 60 秒的内存占用，供走势线使用（内存是主表盘关注的指标）
    @Published private(set) var memoryHistory: [Double] = []
    private var timer: Timer?
    private var sampling = false

    // 进程列表只在监控页可见时才有意义
    private(set) var includeProcesses = false

    func start(includeProcesses: Bool, interval: TimeInterval = 1.0) {
        let processesChanged = self.includeProcesses != includeProcesses
        self.includeProcesses = includeProcesses
        guard timer == nil else {
            if processesChanged { tick() }
            return
        }
        tick()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // 采样在后台线程做，避免 proc_listallpids 阻塞主线程；上一次没回来就跳过这一拍
        guard !sampling else { return }
        sampling = true
        let wantsProcesses = includeProcesses
        Task.detached(priority: .utility) {
            let value = SystemSampler.shared.sample(includeProcesses: wantsProcesses, processLimit: 10)
            await MainActor.run {
                self.sample = value
                self.sampling = false
                if let memory = value.memory.orNil {
                    var history = self.memoryHistory
                    history.append(memory.fraction)
                    if history.count > 60 { history.removeFirst(history.count - 60) }
                    self.memoryHistory = history
                }
            }
        }
    }
}
