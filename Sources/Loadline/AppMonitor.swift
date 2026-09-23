import AppKit
import Observation
import ServiceManagement

struct AppUsage: Identifiable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let bundleURL: URL?
    let icon: NSImage?
    let processes: [ProcessEntry]
    let total: UInt64
    let cpu: Double

    var id: pid_t { pid }
    var helperCount: Int { max(processes.count - 1, 0) }
}

enum AppSort: String, CaseIterable, Identifiable {
    case cpu, memory, name
    var id: Self { self }

    var title: String {
        switch self {
        case .memory: "Memory"
        case .cpu: "CPU"
        case .name: "Name"
        }
    }
}

extension Array where Element == AppUsage {
    func sorted(by sort: AppSort) -> [AppUsage] {
        switch sort {
        case .memory: sorted { $0.total > $1.total }
        case .cpu: sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.total > $1.total }
        case .name: sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case pressureAndCPU, pressure, memory, cpu, iconOnly
    var id: Self { self }

    var title: String {
        switch self {
        case .pressureAndCPU: "CPU + Pressure"
        case .pressure: "Memory Pressure"
        case .memory: "Memory Used"
        case .cpu: "CPU Usage"
        case .iconOnly: "Icon Only"
        }
    }
}

enum SettingsKey {
    static let refreshInterval = "refreshInterval"
    static let includeAccessoryApps = "includeAccessoryApps"
    static let menuBarDisplay = "menuBarDisplay"
    static let popoverSort = "popoverSort"
}

@MainActor
@Observable
final class AppMonitor {
    private(set) var apps: [AppUsage] = []
    private(set) var system = SystemMemory()
    /// Whole-machine CPU usage, 0...100.
    private(set) var systemCPU: Double = 0
    /// Recent pressure percentages, oldest first.
    private(set) var pressureHistory: [Double] = []
    /// Recent whole-machine CPU percentages, oldest first.
    private(set) var cpuHistory: [Double] = []
    static let historyLength = 60
    /// Sort order for the menu bar popover's app list (persisted by hand, not via @AppStorage).
    private(set) var popoverSort: AppSort = .memory
    /// Apps we've asked to quit and that haven't disappeared yet.
    private(set) var quitting: Set<pid_t> = []

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var iconCache: [pid_t: NSImage] = [:]
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var cpuTimes: [pid_t: UInt64] = [:]
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastTicks: CPUTicks?

    var totalAppMemory: UInt64 { apps.reduce(0) { $0 + $1.total } }

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.refreshInterval: 3.0,
            SettingsKey.includeAccessoryApps: false,
            SettingsKey.menuBarDisplay: MenuBarDisplay.pressureAndCPU.rawValue,
            SettingsKey.popoverSort: AppSort.memory.rawValue,
        ])
        popoverSort = AppSort(rawValue: UserDefaults.standard.string(forKey: SettingsKey.popoverSort) ?? "") ?? .memory
        start()
    }

    func setPopoverSort(_ sort: AppSort) {
        popoverSort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: SettingsKey.popoverSort)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let isFirst = self?.lastSample == nil
                await self?.refresh()
                // CPU needs two samples, so take the second one quickly.
                let interval = isFirst ? 1 : max(1, UserDefaults.standard.double(forKey: SettingsKey.refreshInterval))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let includeAccessory = UserDefaults.standard.bool(forKey: SettingsKey.includeAccessoryApps)
        let me = getpid()
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != me, !app.isTerminated else { return false }
            switch app.activationPolicy {
            case .regular: return true
            case .accessory: return includeAccessory
            default: return false
            }
        }
        let seeds = running.map {
            AppSeed(
                pid: $0.processIdentifier,
                name: $0.localizedName ?? $0.bundleIdentifier ?? "\($0.processIdentifier)",
                bundleID: $0.bundleIdentifier,
                isRegular: $0.activationPolicy == .regular
            )
        }

        let now = Date()
        let elapsed = lastSample.map { now.timeIntervalSince($0) } ?? 0
        let previousCPU = cpuTimes
        let (result, memory, ticks) = await Task.detached(priority: .utility) {
            (
                ProcessSampler.sample(apps: seeds, previousCPU: previousCPU, elapsed: elapsed),
                ProcessSampler.systemMemory(),
                ProcessSampler.cpuTicks()
            )
        }.value
        cpuTimes = result.cpuTimes
        lastSample = now
        if let ticks {
            if let lastTicks {
                systemCPU = ticks.usage(since: lastTicks)
                append(systemCPU, to: &cpuHistory)
            }
            lastTicks = ticks
        }

        var icons: [pid_t: NSImage] = [:]
        var urls: [pid_t: URL] = [:]
        for app in running {
            icons[app.processIdentifier] = iconCache[app.processIdentifier] ?? app.icon
            urls[app.processIdentifier] = app.bundleURL
        }
        iconCache = icons

        apps = result.apps
            .filter { !$0.processes.isEmpty }
            .map { sample in
                AppUsage(
                    pid: sample.seed.pid,
                    name: sample.seed.name,
                    bundleID: sample.seed.bundleID,
                    bundleURL: urls[sample.seed.pid],
                    icon: icons[sample.seed.pid],
                    processes: sample.processes,
                    total: sample.processes.reduce(0) { $0 + $1.footprint },
                    cpu: sample.processes.reduce(0) { $0 + $1.cpu }
                )
            }
            .sorted { $0.total > $1.total }
        system = memory
        append(Double(memory.pressurePercent), to: &pressureHistory)
        quitting.formIntersection(apps.map(\.pid))
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    // MARK: - Actions

    func quit(_ app: AppUsage, force: Bool = false) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        quitting.insert(app.pid)
        if force {
            running.forceTerminate()
        } else {
            running.terminate()
        }
        refreshSoon()
    }

    func terminateProcess(_ pid: pid_t, force: Bool = false) {
        kill(pid, force ? SIGKILL : SIGTERM)
        refreshSoon()
    }

    func activate(_ app: AppUsage) {
        NSRunningApplication(processIdentifier: app.pid)?.activate()
    }

    func revealInFinder(_ app: AppUsage) {
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func refreshSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            await refresh()
            // Apps may show a "save changes?" sheet; re-check a bit later too.
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Loadline: launch at login change failed: \(error)")
            }
        }
    }
}

/// Tracks whether ⌥ is held so quit buttons can switch to force-quit.
@MainActor
@Observable
final class ModifierWatcher {
    private(set) var optionDown = false
    @ObservationIgnored private var monitor: Any?

    func start() {
        optionDown = NSEvent.modifierFlags.contains(.option)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let down = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { self?.optionDown = down }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        optionDown = false
    }
}
