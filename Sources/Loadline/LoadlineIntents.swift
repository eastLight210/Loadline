import AppIntents
import AppKit

// Siri, Spotlight, and Shortcuts reach Loadline through these intents. They read the same
// AppMonitor the UI uses, registered with AppDependencyManager in LoadlineApp.init.

// MARK: - Entities

/// A running app as Siri sees it. Identified by bundle ID so a reference like "Chrome" stays
/// valid across relaunches; apps without one fall back to their pid.
struct RunningAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Running App")
    static let defaultQuery = RunningAppQuery()

    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "CPU (%)") var cpu: Double
    // "Memory", "Quit", "Force Quit", and "Cancel" are also SwiftUI literals in the unlocalized UI, so
    // their Korean lives in AppIntents.strings instead of Localizable.strings, where the UI would pick it up.
    @Property(title: LocalizedStringResource("Memory", table: "AppIntents")) var memory: Measurement<UnitInformationStorage>
    @Property(title: "Processes") var processCount: Int
    let iconData: Data?

    init(_ app: AppUsage) {
        id = app.entityID
        iconData = app.icon?.pngData
        name = app.name
        cpu = app.cpu
        memory = Measurement(value: Double(app.total), unit: .bytes)
        processCount = app.processes.count
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "CPU \(cpu.cpuString) · \(UInt64(memory.value).memoryString)",
            image: iconData.map { .init(data: $0) }
        )
    }
}

struct RunningAppQuery: EntityStringQuery {
    @Dependency private var monitor: AppMonitor

    @MainActor
    func entities(for identifiers: [String]) async throws -> [RunningAppEntity] {
        await monitor.waitForSample()
        return monitor.apps.filter { identifiers.contains($0.entityID) }.map(RunningAppEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [RunningAppEntity] {
        await monitor.waitForSample()
        return monitor.apps
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(RunningAppEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [RunningAppEntity] {
        await monitor.waitForSample()
        return monitor.apps.sorted(by: .memory).prefix(10).map(RunningAppEntity.init)
    }
}

enum LoadMetric: String, AppEnum {
    case cpu, memory

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Metric")
    static let caseDisplayRepresentations: [LoadMetric: DisplayRepresentation] = [
        .cpu: "CPU",
        .memory: DisplayRepresentation(title: LocalizedStringResource("Memory", table: "AppIntents")),
    ]

    var sort: AppSort { self == .cpu ? .cpu : .memory }
}

// MARK: - Intents

struct GetTopAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Top Apps"
    static let description = IntentDescription("Lists the apps using the most CPU or memory.")

    @Parameter(title: "Metric", default: .memory) var metric: LoadMetric
    @Parameter(title: "Count", default: 3, inclusiveRange: (1, 20)) var count: Int

    @Dependency private var monitor: AppMonitor

    static var parameterSummary: some ParameterSummary {
        Summary("Get the top \(\.$count) apps by \(\.$metric)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[RunningAppEntity]> & ProvidesDialog {
        await monitor.waitForSample()
        let top = Array(monitor.apps.sorted(by: metric.sort).prefix(count))
        guard let first = top.first else {
            return .result(value: [], dialog: "No apps are running.")
        }
        let dialog: IntentDialog = switch metric {
        case .cpu: "\(first.name) is using the most CPU at \(first.cpu.cpuString)."
        case .memory: "\(first.name) is using the most memory at \(first.total.memoryString)."
        }
        return .result(value: top.map(RunningAppEntity.init), dialog: dialog)
    }
}

struct GetSystemLoadIntent: AppIntent {
    static let title: LocalizedStringResource = "Get System Load"
    static let description = IntentDescription("Reports overall CPU usage, memory used, and memory pressure.")

    @Dependency private var monitor: AppMonitor

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        await monitor.waitForSample()
        let system = monitor.system
        let cpu = monitor.systemCPU.cpuString
        let used = system.used.memoryString
        let total = system.total.memoryString
        let pressure = "\(system.pressurePercent)%"
        let summary = "CPU \(cpu), memory used \(used) of \(total), pressure \(pressure)"
        return .result(
            value: summary,
            dialog: "CPU is at \(cpu). Memory used is \(used) of \(total), with \(pressure) pressure."
        )
    }
}

struct QuitRunningAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit App"
    static let description = IntentDescription("Quits a running app, or force quits it.")

    @Parameter(title: "App") var app: RunningAppEntity
    @Parameter(title: LocalizedStringResource("Force Quit", table: "AppIntents"), default: false) var force: Bool

    @Dependency private var monitor: AppMonitor

    static var parameterSummary: some ParameterSummary {
        Summary("Quit \(\.$app)") {
            \.$force
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await monitor.waitForSample()
        guard let target = monitor.apps.first(where: { $0.entityID == app.id }) else {
            return .result(dialog: "\(app.name) isn't running.")
        }
        let acceptLabel = force
            ? LocalizedStringResource("Force Quit", table: "AppIntents")
            : LocalizedStringResource("Quit", table: "AppIntents")
        try await requestConfirmation(
            actionName: .custom(
                acceptLabel: acceptLabel, acceptAlternatives: [],
                denyLabel: LocalizedStringResource("Cancel", table: "AppIntents"), denyAlternatives: [],
                destructive: true
            ),
            dialog: force ? "Force quit \(target.name)?" : "Quit \(target.name)?"
        )
        monitor.quit(target, force: force)
        return .result(dialog: force ? "Force quit \(target.name)." : "Quit \(target.name).")
    }
}

// MARK: - App Shortcuts

struct LoadlineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetTopAppsIntent(),
            phrases: [
                "What's using the most \(\.$metric) in \(.applicationName)",
                "Show top apps in \(.applicationName)",
            ],
            shortTitle: "Top Apps",
            systemImageName: "list.number"
        )
        AppShortcut(
            intent: GetSystemLoadIntent(),
            phrases: [
                "How's my Mac doing in \(.applicationName)",
                "Check system load with \(.applicationName)",
            ],
            shortTitle: "System Load",
            systemImageName: "gauge.medium"
        )
        AppShortcut(
            intent: QuitRunningAppIntent(),
            phrases: [
                "Quit \(\.$app) with \(.applicationName)",
            ],
            shortTitle: "Quit App",
            systemImageName: "xmark.circle"
        )
    }
}

// MARK: - Helpers

extension AppUsage {
    var entityID: String { bundleID ?? "pid:\(pid)" }
}

extension AppMonitor {
    /// When Siri launches Loadline in the background, the first sample may not have landed yet
    /// and CPU needs two samples to mean anything. Waits up to ~3 s for both.
    func waitForSample() async {
        for _ in 0..<30 where cpuHistory.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
