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

extension AppUsage {
    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || processes.contains { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

extension Array where Element == AppUsage {
    /// Apps whose name or any process name contains the query; everything when it's empty.
    func matching(_ query: String) -> [AppUsage] {
        query.isEmpty ? self : filter { $0.matches(query) }
    }

    func sorted(by sort: AppSort) -> [AppUsage] {
        switch sort {
        case .memory: sorted { $0.total > $1.total }
        case .cpu: sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.total > $1.total }
        case .name: sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

extension Array where Element == ProcessEntry {
    /// Main process stays first; helpers follow the given order.
    func sorted(by sort: AppSort) -> [ProcessEntry] {
        sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            switch sort {
            case .memory: return a.footprint > b.footprint
            case .cpu: return a.cpu != b.cpu ? a.cpu > b.cpu : a.footprint > b.footprint
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case pinwheel, pressureAndCPU, pressure, memory, cpu
    var id: Self { self }

    var title: String {
        switch self {
        case .pinwheel: "CPU + Memory Pinwheel"
        case .pressureAndCPU: "CPU + Pressure"
        case .pressure: "Memory Pressure"
        case .memory: "Memory Used"
        case .cpu: "CPU Usage"
        }
    }
}

enum SettingsKey {
    static let refreshInterval = "refreshInterval"
    static let includeAccessoryApps = "includeAccessoryApps"
    static let menuBarDisplay = "menuBarDisplay"
    static let menuBarNumericDisplay = "menuBarNumericDisplay"
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
    /// Helper processes we've signalled and that haven't disappeared yet.
    private(set) var endingProcesses: Set<pid_t> = []
    /// True while every display is asleep; sampling and the pinwheel animation pause.
    private(set) var displaysAsleep = false
    /// How often the per-app process scan runs while no app list is on screen. System-wide
    /// CPU and memory (what the menu bar shows) still update at the refresh interval.
    static let backgroundProcessInterval: TimeInterval = 15

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var iconCache: [pid_t: NSImage] = [:]
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var cpuTimes: [pid_t: UInt64] = [:]
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var processSampleCount = 0
    /// Open popovers/windows that list apps; while any is visible the process scan runs at full rate.
    @ObservationIgnored private var appListViewers = 0
    @ObservationIgnored private var lastTicks: CPUTicks?

    var totalAppMemory: UInt64 { apps.reduce(0) { $0 + $1.total } }

    init() {
        if let display = UserDefaults.standard.string(forKey: SettingsKey.menuBarDisplay),
           ["waveforms", "iconOnly"].contains(display) {
            UserDefaults.standard.set(MenuBarDisplay.pinwheel.rawValue, forKey: SettingsKey.menuBarDisplay)
        }
        UserDefaults.standard.register(defaults: [
            SettingsKey.refreshInterval: 3.0,
            SettingsKey.includeAccessoryApps: false,
            SettingsKey.menuBarDisplay: MenuBarDisplay.pinwheel.rawValue,
            SettingsKey.popoverSort: AppSort.memory.rawValue,
        ])
        popoverSort = AppSort(rawValue: UserDefaults.standard.string(forKey: SettingsKey.popoverSort) ?? "") ?? .memory
        observeDisplaySleep()
        start()
    }

    private func observeDisplaySleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysAsleep = true }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysAsleep = false
                Task { await self?.refresh() }
            }
        }
    }

    /// Call when a view listing apps appears; pair with `appListDidDisappear()`.
    func appListDidAppear() {
        appListViewers += 1
        guard appListViewers == 1 else { return }
        Task {
            await refresh()
            // The background scan may be up to 15 s old, so take a fresh CPU baseline quickly.
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
    }

    func appListDidDisappear() {
        appListViewers = max(0, appListViewers - 1)
    }

    func setPopoverSort(_ sort: AppSort) {
        popoverSort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: SettingsKey.popoverSort)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.tick() else { return }
                // Tolerance lets macOS coalesce this wakeup with others.
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 10))
            }
        }
    }

    /// One pass of the sampling loop; returns how long to wait before the next one.
    private func tick() async -> TimeInterval {
        let interval = max(1, UserDefaults.standard.double(forKey: SettingsKey.refreshInterval))
        guard !displaysAsleep else { return interval }
        let processAge = lastSample.map { Date().timeIntervalSince($0) } ?? .infinity
        // Per-app CPU needs two scans, so the first two always run.
        let wantsProcesses = appListViewers > 0 || processSampleCount < 2
            || processAge >= Self.backgroundProcessInterval - interval / 2
        await refresh(includingProcesses: wantsProcesses)
        // CPU needs two samples, so take the second one quickly.
        return cpuHistory.isEmpty || processSampleCount < 2 ? 1 : interval
    }

    /// Samples system-wide CPU and memory, plus every app's processes unless `includingProcesses`
    /// is false (the menu bar alone needs only the system-wide numbers).
    func refresh(includingProcesses: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard includingProcesses else {
            let (memory, ticks) = await Task.detached(priority: .utility) {
                (ProcessSampler.systemMemory(), ProcessSampler.cpuTicks())
            }.value
            apply(memory: memory, ticks: ticks)
            return
        }

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
        processSampleCount += 1

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
        apply(memory: memory, ticks: ticks)
        quitting.formIntersection(apps.map(\.pid))
        endingProcesses.formIntersection(apps.flatMap { $0.processes.map(\.pid) })
    }

    private func apply(memory: SystemMemory, ticks: CPUTicks?) {
        if let ticks {
            if let lastTicks {
                systemCPU = ticks.usage(since: lastTicks)
                append(systemCPU, to: &cpuHistory)
            }
            lastTicks = ticks
        }
        system = memory
        append(Double(memory.pressurePercent), to: &pressureHistory)
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

    /// Returns false when the signal couldn't be sent (e.g. the process belongs to another user).
    @discardableResult
    func terminateProcess(_ pid: pid_t, force: Bool = false) -> Bool {
        guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else { return false }
        endingProcesses.insert(pid)
        refreshSoon()
        return true
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
