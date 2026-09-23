import Darwin
import Foundation

/// Minimal description of a running app, captured on the main actor and handed to the sampler.
struct AppSeed: Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    /// Regular (Dock) apps are always listed on their own; background/menu bar apps may be
    /// folded into the app responsible for them.
    let isRegular: Bool
}

struct ProcessEntry: Identifiable, Sendable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    /// Physical footprint in bytes — the same number Activity Monitor shows in its "Memory" column.
    let footprint: UInt64
    /// CPU usage since the previous sample, where 100 = one full core (Activity Monitor's convention).
    let cpu: Double
    let isMain: Bool
    var id: pid_t { pid }
}

struct AppSample: Sendable {
    let seed: AppSeed
    /// Main process first, then helpers sorted by footprint.
    let processes: [ProcessEntry]
}

struct SampleResult: Sendable {
    let apps: [AppSample]
    /// Cumulative CPU time per pid in nanoseconds, fed back into the next sample.
    let cpuTimes: [pid_t: UInt64]
}

struct CPUTicks: Sendable {
    let busy: UInt32
    let total: UInt32

    /// Whole-machine CPU usage between two readings, 0...100.
    func usage(since previous: CPUTicks) -> Double {
        let total = total &- previous.total
        guard total > 0 else { return 0 }
        return min(100, Double(busy &- previous.busy) / Double(total) * 100)
    }
}

enum MemoryPressure: Int32, Sendable {
    case normal = 1, warning = 2, critical = 4
}

struct SystemMemory: Sendable, Equatable {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal
    /// Kernel's "memory free percentage" (what `memory_pressure` prints).
    var freePercent: Int = 100

    /// 0...100, higher is worse. Mirrors the level Activity Monitor's pressure graph tracks.
    var pressurePercent: Int { max(0, min(100, 100 - freePercent)) }
    /// Matches Activity Monitor's "Memory Used" (app + wired + compressed).
    var used: UInt64 { appMemory + wired + compressed }
    var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
}

enum ProcessSampler {
    // Private libsystem SPI that Activity Monitor uses to attribute XPC services
    // (e.g. Safari's WebContent processes, whose parent is launchd) to their app.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsibleFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private static let host = mach_host_self()

    /// rusage CPU times are in mach ticks on Apple Silicon (1:1 on Intel).
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func sample(apps: [AppSeed], previousCPU: [pid_t: UInt64], elapsed: TimeInterval) -> SampleResult {
        let uid = getuid()
        let foldedInto = foldTargets(for: apps)
        let topLevel = apps.filter { foldedInto[$0.pid] == nil }
        let appPIDs = Set(topLevel.map(\.pid))
        // Folded apps keep their friendly name (e.g. "Virtual Machine Service for Claude").
        let seedNames = Dictionary(apps.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })

        var parent: [pid_t: pid_t] = [:]
        var shortNames: [pid_t: String] = [:]
        for pid in allPIDs() {
            guard let info = bsdInfo(pid), info.uid == uid else { continue }
            parent[pid] = info.ppid
            shortNames[pid] = info.name
        }

        var groups: [pid_t: [pid_t]] = [:]
        for pid in parent.keys {
            if appPIDs.contains(pid) {
                groups[pid, default: []].append(pid)
            } else if let owner = owner(of: pid, appPIDs: appPIDs, foldedInto: foldedInto, parent: parent) {
                groups[owner, default: []].append(pid)
            }
        }

        var cpuTimes: [pid_t: UInt64] = [:]
        var samples: [AppSample] = []
        for seed in topLevel {
            var entries: [ProcessEntry] = []
            for pid in groups[seed.pid] ?? [seed.pid] {
                guard let usage = usage(pid) else { continue }
                cpuTimes[pid] = usage.cpuNanos
                var cpu = 0.0
                if let previous = previousCPU[pid], elapsed > 0, usage.cpuNanos >= previous {
                    cpu = Double(usage.cpuNanos - previous) / (elapsed * 1_000_000_000) * 100
                }
                let isMain = pid == seed.pid
                let name = isMain ? seed.name : (seedNames[pid] ?? executableName(pid) ?? shortNames[pid] ?? "\(pid)")
                entries.append(ProcessEntry(
                    pid: pid, ppid: parent[pid] ?? 0, name: name,
                    footprint: usage.footprint, cpu: cpu, isMain: isMain
                ))
            }
            entries.sort { a, b in a.isMain != b.isMain ? a.isMain : a.footprint > b.footprint }
            samples.append(AppSample(seed: seed, processes: entries))
        }
        return SampleResult(apps: samples, cpuTimes: cpuTimes)
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let (user, system, idle, nice) = info.cpu_ticks
        let busy = user &+ system &+ nice
        return CPUTicks(busy: busy, total: busy &+ idle)
    }

    static func systemMemory() -> SystemMemory {
        var memory = SystemMemory()

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(host, &pageSize)
            let page = UInt64(pageSize)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            memory.appMemory = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            memory.wired = UInt64(stats.wire_count) * page
            memory.compressed = UInt64(stats.compressor_page_count) * page
            memory.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            memory.swapUsed = swap.xsu_used
        }

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            memory.pressure = MemoryPressure(rawValue: level) ?? .normal
        }

        var free: Int32 = 0
        var freeSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &free, &freeSize, nil, 0) == 0 {
            memory.freePercent = Int(free)
        }

        return memory
    }

    // MARK: - libproc helpers

    /// Non-regular apps whose responsible process is another listed app — e.g. Claude's
    /// Virtualization XPC service, which registers as its own accessory app — map to that app.
    private static func foldTargets(for apps: [AppSeed]) -> [pid_t: pid_t] {
        guard let responsiblePID else { return [:] }
        let seeds = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var direct: [pid_t: pid_t] = [:]
        for seed in apps where !seed.isRegular {
            let responsible = responsiblePID(seed.pid)
            if responsible != seed.pid, seeds[responsible] != nil { direct[seed.pid] = responsible }
        }
        // Follow chains (A folded into B folded into C) to the top-level app.
        var resolved: [pid_t: pid_t] = [:]
        for pid in direct.keys {
            var target = direct[pid]!
            var hops = 0
            while let next = direct[target], hops < 8 {
                target = next
                hops += 1
            }
            if direct[target] == nil { resolved[pid] = target }
        }
        return resolved
    }

    private static func owner(
        of pid: pid_t, appPIDs: Set<pid_t>, foldedInto: [pid_t: pid_t], parent: [pid_t: pid_t]
    ) -> pid_t? {
        if let target = foldedInto[pid] { return target }
        if let responsiblePID {
            let responsible = responsiblePID(pid)
            if responsible != pid {
                if appPIDs.contains(responsible) { return responsible }
                if let target = foldedInto[responsible] { return target }
            }
        }
        var current = parent[pid] ?? 0
        var depth = 0
        while current > 1, depth < 64 {
            if appPIDs.contains(current) { return current }
            if let target = foldedInto[current] { return target }
            current = parent[current] ?? 0
            depth += 1
        }
        return nil
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private struct BSDInfo {
        let ppid: pid_t
        let uid: uid_t
        let name: String
    }

    private static func bsdInfo(_ pid: pid_t) -> BSDInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return BSDInfo(ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid, name: name)
    }

    private static func usage(_ pid: pid_t) -> (footprint: UInt64, cpuNanos: UInt64)? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        let ticks = usage.ri_user_time + usage.ri_system_time
        let nanos = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        return (usage.ri_phys_footprint, nanos)
    }

    private static func executableName(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        return (path as NSString).lastPathComponent
    }
}

extension UInt64 {
    var memoryString: String {
        let mb = Double(self) / 1_048_576
        if mb < 10 { return String(format: "%.1f MB", mb) }
        if mb < 1000 { return String(format: "%.0f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    /// One decimal for GB so legends fit on one line.
    var shortMemoryString: String {
        let mb = Double(self) / 1_048_576
        if mb < 1000 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    var compactGBString: String {
        String(format: "%.1fG", Double(self) / 1_073_741_824)
    }
}

extension Double {
    var cpuString: String {
        self < 10 ? String(format: "%.1f%%", self) : String(format: "%.0f%%", self)
    }
}
