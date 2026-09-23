import SwiftUI

struct MenuBarView: View {
    @Environment(AppMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var modifiers = ModifierWatcher()
    /// Measured height of the app list; the popover sizes to content, so the ScrollView needs an explicit height.
    @State private var listHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 400

    @AppStorage(SettingsKey.menuBarDisplay) private var menuBarDisplay: MenuBarDisplay = .pressureAndCPU
    @AppStorage(SettingsKey.includeAccessoryApps) private var includeAccessory = false
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval = 3.0

    private var sort: AppSort { monitor.popoverSort }

    var body: some View {
        VStack(spacing: 0) {
            SystemSummary(monitor: monitor)
                .padding(12)

            Divider()

            HStack(spacing: MenuAppRow.columnSpacing) {
                Text("Apps")
                    .foregroundStyle(.secondary)
                Spacer()
                columnHeader("CPU", sort: .cpu, width: MenuAppRow.cpuWidth)
                columnHeader("Memory", sort: .memory, width: MenuAppRow.memoryWidth)
                Color.clear.frame(width: MenuAppRow.quitWidth, height: 1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            if monitor.apps.isEmpty {
                Text("Loading running apps…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                let apps = monitor.apps.sorted(by: sort)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(apps) { app in
                            MenuAppRow(
                                app: app,
                                sort: sort,
                                share: app.share(of: apps, by: sort),
                                forceMode: modifiers.optionDown,
                                isQuitting: monitor.quitting.contains(app.pid)
                            ) {
                                monitor.quit(app, force: modifiers.optionDown)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), maxListHeight))
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider()

            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            modifiers.start()
            Task { await monitor.refresh() }
        }
        .onDisappear { modifiers.stop() }
        .onChange(of: includeAccessory) { Task { await monitor.refresh() } }
    }

    private func columnHeader(_ title: String, sort column: AppSort, width: CGFloat) -> some View {
        Button {
            monitor.setPopoverSort(column)
        } label: {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(sort == column ? 1 : 0)
            }
            .foregroundStyle(sort == column ? .primary : .secondary)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
    }

    private var footer: some View {
        HStack {
            Text("\(monitor.apps.count) apps · \(monitor.totalAppMemory.memoryString)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button {
                openWindow(id: "main")
                NSApp.activate()
                dismiss()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Show Details")

            Menu {
                Picker("Menu Bar Shows", selection: $menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Include Menu Bar Apps", isOn: $includeAccessory)
                Picker("Refresh Every", selection: $refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Toggle("Launch at Login", isOn: Binding(
                    get: { monitor.launchAtLogin },
                    set: { monitor.launchAtLogin = $0 }
                ))
                Divider()
                Button("Quit Loadline") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

struct MenuAppRow: View {
    static let memoryWidth: CGFloat = 70
    static let cpuWidth: CGFloat = 48
    static let quitWidth: CGFloat = 18
    static let columnSpacing: CGFloat = 8

    let app: AppUsage
    let sort: AppSort
    let share: Double
    let forceMode: Bool
    let isQuitting: Bool
    let onQuit: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Self.columnSpacing) {
            AppIcon(image: app.icon, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(app.name).lineLimit(1)
                    if app.helperCount > 0 {
                        Text("+\(app.helperCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                ShareBar(fraction: share, tint: sort == .cpu ? .teal : (share > 0.66 ? .red : .accentColor))
            }
            Spacer(minLength: 0)
            Text(app.cpu.cpuString)
                .foregroundStyle(sort == .cpu ? .primary : .secondary)
                .frame(width: Self.cpuWidth, alignment: .trailing)
            Text(app.total.memoryString)
                .foregroundStyle(sort == .memory ? .primary : .secondary)
                .frame(width: Self.memoryWidth, alignment: .trailing)

            ZStack {
                if isQuitting {
                    ProgressView().controlSize(.small)
                } else if hovering {
                    Button(action: onQuit) {
                        Image(systemName: forceMode ? "xmark.octagon.fill" : "xmark.circle.fill")
                            .foregroundStyle(forceMode ? .red : .secondary)
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .help(forceMode ? "Force Quit" : "Quit (hold ⌥ to force quit)")
                }
            }
            .frame(width: Self.quitWidth)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
