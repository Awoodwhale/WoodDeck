import AppKit
import Darwin
import Foundation

// 一项读数：要么有值，要么给出读不到的原因。界面对不可用的读数显示短横线，绝不填 0
struct Reading<Value> {
    private var value: Value?
    var reason: String

    static func of(_ value: Value) -> Reading { Reading(value: value, reason: "") }
    static func unavailable(_ reason: String) -> Reading { Reading(value: nil, reason: reason) }

    var hasValue: Bool { value != nil }
    var orNil: Value? { value }
}

// 单个逻辑核心的占用
struct CoreSample: Identifiable {
    var id: Int
    var usage: Double
}

struct CpuSample {
    var cores: [CoreSample]
    var usage: Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0) { $0 + $1.usage } / Double(cores.count)
    }
}

struct MemorySample {
    var used: UInt64
    var total: UInt64
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkSample {
    var receiveBytesPerSecond: Double
    var sendBytesPerSecond: Double
}

struct ProcessSample: Identifiable {
    var id: Int32
    var name: String
    var cpu: Double
    var memory: UInt64
}

// 一次完整的采样
struct SystemSample {
    var cpu: Reading<CpuSample>
    var memory: Reading<MemorySample>
    var network: Reading<NetworkSample>
    var gpu: Reading<Double>
    var processes: [ProcessSample]
    var at: Date = Date()
}

// 采集 CPU、内存、网络与占用最高的应用。两次采样之间保存上一次的计数，用差值算速率
final class SystemSampler {
    static let shared = SystemSampler()

    private var previousCpuTicks: [UInt32] = []
    private var previousNetwork: (receive: UInt64, send: UInt64, at: Date)?
    private var previousProcessTime: [Int32: UInt64] = [:]
    private var previousProcessAt: Date?

    private init() {}

    // GPU 在 macOS 没有公开的通用占用接口，这里如实说明
    private static let gpuReason = "macOS 没有公开的 GPU 占用接口"

    // 进程枚举要遍历所有 pid 并读 rusage，是这里最贵的一步；
    // 只有真正展示进程列表时才做，收起形态的读数与主表盘都用不到它
    func sample(includeProcesses: Bool = false, processLimit: Int = 10) -> SystemSample {
        SystemSample(cpu: readCpu(),
                     memory: readMemory(),
                     network: readNetwork(),
                     gpu: .unavailable(Self.gpuReason),
                     processes: includeProcesses ? readProcesses(limit: processLimit) : [])
    }

    // MARK: - CPU

    private func readCpu() -> Reading<CpuSample> {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            return .unavailable("读取 CPU 计数失败")
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount))
        let states = Int(CPU_STATE_MAX)
        var current: [UInt32] = []
        current.reserveCapacity(Int(processorCount) * states)
        for index in 0..<Int(processorCount) * states {
            current.append(UInt32(bitPattern: ticks[index]))
        }

        var cores: [CoreSample] = []
        let hasPrevious = previousCpuTicks.count == current.count
        for core in 0..<Int(processorCount) {
            let base = core * states
            let user = current[base + Int(CPU_STATE_USER)]
            let system = current[base + Int(CPU_STATE_SYSTEM)]
            let nice = current[base + Int(CPU_STATE_NICE)]
            let idle = current[base + Int(CPU_STATE_IDLE)]
            let busy = user &+ system &+ nice
            var usage = 0.0
            if hasPrevious {
                let previousBusy = previousCpuTicks[base + Int(CPU_STATE_USER)]
                    &+ previousCpuTicks[base + Int(CPU_STATE_SYSTEM)]
                    &+ previousCpuTicks[base + Int(CPU_STATE_NICE)]
                let previousIdle = previousCpuTicks[base + Int(CPU_STATE_IDLE)]
                let deltaBusy = Double(busy &- previousBusy)
                let deltaIdle = Double(idle &- previousIdle)
                let delta = deltaBusy + deltaIdle
                if delta > 0 { usage = min(1, max(0, deltaBusy / delta)) }
            }
            cores.append(CoreSample(id: core, usage: usage))
        }
        previousCpuTicks = current
        return .of(CpuSample(cores: cores))
    }

    // MARK: - 内存

    private func readMemory() -> Reading<MemorySample> {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .unavailable("读取内存统计失败") }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        return .of(MemorySample(used: min(used, total), total: total))
    }

    // MARK: - 网络

    private func readNetwork() -> Reading<NetworkSample> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return .unavailable("读取网络计数失败")
        }
        defer { freeifaddrs(head) }
        var receive: UInt64 = 0
        var send: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            // 只看启用的、非回环、非点对点接口
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
            guard let data = current.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            receive &+= UInt64(stats.ifi_ibytes)
            send &+= UInt64(stats.ifi_obytes)
        }
        let now = Date()
        defer { previousNetwork = (receive, send, now) }
        guard let previous = previousNetwork else {
            return .of(NetworkSample(receiveBytesPerSecond: 0, sendBytesPerSecond: 0))
        }
        let interval = now.timeIntervalSince(previous.at)
        guard interval > 0.2 else {
            return .of(NetworkSample(receiveBytesPerSecond: 0, sendBytesPerSecond: 0))
        }
        // 计数回绕时按 0 处理
        let receiveDelta = receive >= previous.receive ? receive - previous.receive : 0
        let sendDelta = send >= previous.send ? send - previous.send : 0
        return .of(NetworkSample(receiveBytesPerSecond: Double(receiveDelta) / interval,
                                 sendBytesPerSecond: Double(sendDelta) / interval))
    }

    // MARK: - 占用最高的应用

    private func readProcesses(limit: Int) -> [ProcessSample] {
        let now = Date()
        let interval = previousProcessAt.map { now.timeIntervalSince($0) } ?? 0
        defer {
            previousProcessAt = now
        }

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [] }

        var current: [Int32: UInt64] = [:]
        var samples: [ProcessSample] = []
        var names: [Int32: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            names[application.processIdentifier] = application.localizedName ?? ""
        }

        for index in 0..<Int(filled) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
                }
            }
            guard result == 0 else { continue }
            let cpuTime = usage.ri_user_time &+ usage.ri_system_time
            current[pid] = cpuTime
            let memory = UInt64(usage.ri_phys_footprint)
            var cpu = 0.0
            if interval > 0.05, let previous = previousProcessTime[pid], cpuTime >= previous {
                cpu = Double(cpuTime - previous) / 1_000_000_000 / interval
            }
            let name = Self.appName(from: names[pid] ?? processName(pid))
            guard !name.isEmpty else { continue }
            samples.append(ProcessSample(id: pid, name: name, cpu: cpu, memory: memory))
        }
        previousProcessTime = current
        // 按应用合并同名进程，取占用最高的几项
        var folded: [String: ProcessSample] = [:]
        for sample in samples {
            if var existing = folded[sample.name] {
                existing.cpu += sample.cpu
                existing.memory += sample.memory
                folded[sample.name] = existing
            } else {
                folded[sample.name] = sample
            }
        }
        // 按内存占用排序：内存是这里更受关注的指标
        return folded.values
            .sorted { $0.memory == $1.memory ? $0.cpu > $1.cpu : $0.memory > $1.memory }
            .prefix(max(1, limit))
            .map { $0 }
    }

    // 把各种 Helper 归到所属应用：Microsoft Edge Helper (Renderer) → Microsoft Edge。
    // 与上游一致，同一应用的多个进程合并成一条
    static func appName(from raw: String) -> String {
        var name = raw
        for marker in [" Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)", " Helper (Alerts)",
                       " Helper", " Renderer", " (Renderer)", " (GPU)"] {
            if let range = name.range(of: marker) {
                name = String(name[..<range.lowerBound])
            }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }
}
