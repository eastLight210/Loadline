import SwiftUI

struct MainWindowView: View {
    @Environment(AppMonitor.self) private var monitor
    @State private var search = ""
    @State private var sort: AppSort = .memory
    @State private var expanded: Set<pid_t> = []
    @State private var forceQuitTarget: AppUsage?

    private var visibleApps: [AppUsage] {
        let filtered = search.isEmpty ? monitor.apps : monitor.apps.filter { app in
            app.name.localizedCaseInsensitiveContains(search)
                || app.processes.contains { $0.name.localizedCaseInsensitiveContains(search) }
        }
        return filtered.sorted(by: sort)
    }

    var body: some View {
        VStack(spacing: 0) {
            SystemSummary(monitor: monitor)
                .padding()

            Divider()

            let apps = visibleApps
            List {
                ForEach(apps) { app in
                    AppRow(
                        app: app,
                        sort: sort,
                        share: app.share(of: apps, by: sort),
                        isQuitting: monitor.quitting.contains(app.pid),
                        isExpanded: expanded.contains(app.pid),
                        onToggle: { toggle(app.pid) },
                        onForceQuit: { forceQuitTarget = app }
                    )
                    if expanded.contains(app.pid) {
                        let appMax = Double(app.processes.map(\.footprint).max() ?? 1)
                        ForEach(app.processes) { process in
                            ProcessRow(process: process, share: Double(process.footprint) / max(appMax, 1))
                                .padding(.leading, 26)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Text("\(apps.count) apps · \(apps.reduce(0) { $0 + $1.total }.memoryString) total")
                    .monospacedDigit()
                Spacer()
                Text("⌥-click or right-click to force quit")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .searchable(text: $search, prompt: "Search apps or processes")
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(AppSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
        }
        .confirmationDialog(
            "Force quit \(forceQuitTarget?.name ?? "")?",
            isPresented: Binding(get: { forceQuitTarget != nil }, set: { if !$0 { forceQuitTarget = nil } }),
            presenting: forceQuitTarget
        ) { app in
            Button("Force Quit", role: .destructive) { monitor.quit(app, force: true) }
        } message: { _ in
            Text("Any unsaved changes will be lost.")
        }
    }

    private func toggle(_ pid: pid_t) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(pid) {
                expanded.remove(pid)
            } else {
                expanded.insert(pid)
            }
        }
    }
}

private struct AppRow: View {
    @Environment(AppMonitor.self) private var monitor
    let app: AppUsage
    let sort: AppSort
    let share: Double
    let isQuitting: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide processes" : "Show processes")
            AppIcon(image: app.icon, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).fontWeight(.medium)
                    Text(app.processes.count == 1 ? "1 process" : "\(app.processes.count) processes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ShareBar(fraction: share, tint: sort == .cpu ? .teal : (share > 0.66 ? .red : .accentColor))
                    .frame(maxWidth: 220)
            }
            Spacer()
            Text(app.cpu.cpuString)
                .monospacedDigit()
                .foregroundStyle(sort == .cpu ? .primary : .secondary)
                .frame(minWidth: 56, alignment: .trailing)
            Text(app.total.memoryString)
                .monospacedDigit()
                .foregroundStyle(sort == .cpu ? .secondary : .primary)
                .frame(minWidth: 80, alignment: .trailing)
            if isQuitting {
                ProgressView().controlSize(.small).frame(width: 60)
            } else {
                Button("Quit") {
                    monitor.quit(app, force: NSEvent.modifierFlags.contains(.option))
                }
                .controlSize(.small)
                .frame(width: 60)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button("Switch to App") { monitor.activate(app) }
            Button("Show in Finder") { monitor.revealInFinder(app) }
                .disabled(app.bundleURL == nil)
            Divider()
            Button("Quit") { monitor.quit(app) }
            Button("Force Quit…", role: .destructive, action: onForceQuit)
        }
    }
}

private struct ProcessRow: View {
    @Environment(AppMonitor.self) private var monitor
    let process: ProcessEntry
    let share: Double
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: process.isMain ? "app.fill" : "gearshape.2")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name).lineLimit(1).truncationMode(.middle)
                ShareBar(fraction: share, tint: .secondary)
                    .frame(maxWidth: 160)
            }
            Text("PID \(String(process.pid))")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Spacer()
            Text(process.cpu.cpuString)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
            Text(process.footprint.memoryString)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .trailing)
            Group {
                if hovering && !process.isMain {
                    Button {
                        monitor.terminateProcess(process.pid, force: NSEvent.modifierFlags.contains(.option))
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("End this process (hold ⌥ to force)")
                }
            }
            .frame(width: 60)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(process.pid), forType: .string)
            }
            if !process.isMain {
                Divider()
                Button("End Process (SIGTERM)") { monitor.terminateProcess(process.pid) }
                Button("Force End Process (SIGKILL)", role: .destructive) {
                    monitor.terminateProcess(process.pid, force: true)
                }
            }
        }
    }
}
