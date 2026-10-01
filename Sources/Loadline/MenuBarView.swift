import SwiftUI

struct MenuBarView: View {
    @Environment(AppMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var modifiers = ModifierWatcher()
    /// Measured height of the app list; the popover sizes to content, so the ScrollView needs an explicit height.
    @State private var listHeight: CGFloat = 0
    /// App whose processes are shown inline; only one at a time.
    @State private var expandedApp: pid_t?
    @State private var search = ""
    /// Not focused on open: the field takes focus only on click or ⌘F.
    @FocusState private var searchFocused: Bool
    /// List height captured when a search starts. The popover window doesn't shrink while open (the
    /// content just floats in the middle of it), so results keep this height instead of resizing.
    @State private var searchListHeight: CGFloat?
    private let maxListHeight: CGFloat = 400

    @AppStorage(SettingsKey.includeAccessoryApps) private var includeAccessory = false

    private var sort: AppSort { monitor.popoverSort }

    var body: some View {
        VStack(spacing: 0) {
            SystemSummary(monitor: monitor)
                .padding(12)

            Divider()

            searchField
                .padding(.horizontal, 12)
                .padding(.top, 8)

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
            } else if visibleApps.isEmpty {
                Text("No Matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: searchListHeight ?? 80, maxHeight: searchListHeight ?? 80)
            } else {
                let apps = visibleApps
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(apps) { app in
                                MenuAppRow(
                                    app: app,
                                    sort: sort,
                                    share: app.share(of: apps, by: sort),
                                    forceMode: modifiers.optionDown,
                                    isQuitting: monitor.quitting.contains(app.pid),
                                    isExpanded: expandedApp == app.pid,
                                    onToggle: { toggle(app, proxy: proxy) }
                                ) {
                                    monitor.quit(app, force: modifiers.optionDown)
                                }
                                if expandedApp == app.pid {
                                    ForEach(app.processes.sorted(by: sort)) { process in
                                        MenuProcessRow(
                                            process: process,
                                            forceMode: modifiers.optionDown,
                                            isEnding: monitor.endingProcesses.contains(process.pid)
                                        )
                                        // Main process shares the app's pid, so give rows their own id space.
                                        .id(ProcessRowID(pid: process.pid))
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 4)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .frame(height: searchListHeight ?? displayedListHeight, alignment: .top)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }

            Divider()

            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            // A popover window hands focus to its first text field when it becomes key; undo that.
            DispatchQueue.main.async { searchFocused = false }
            modifiers.start()
            Task { await monitor.refresh() }
        }
        .onDisappear {
            modifiers.stop()
            expandedApp = nil
            search = ""
            searchFocused = false
            searchListHeight = nil
        }
        .onChange(of: search) {
            if search.isEmpty {
                searchListHeight = nil
            } else if searchListHeight == nil {
                searchListHeight = displayedListHeight
            }
            expandForSearch()
        }
        .onChange(of: includeAccessory) { Task { await monitor.refresh() } }
    }

    private var displayedListHeight: CGFloat {
        min(max(listHeight, 1), maxListHeight)
    }

    private var visibleApps: [AppUsage] {
        monitor.apps.matching(search).sorted(by: sort)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search apps or processes", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    // First Esc clears the query; with nothing to clear it closes the popover as usual.
                    guard !search.isEmpty else { return .ignored }
                    search = ""
                    return .handled
                }
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .background {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
    }

    /// When the top result matched only through one of its processes, show them so the match is visible.
    private func expandForSearch() {
        let apps = visibleApps
        if let expandedApp, apps.contains(where: { $0.pid == expandedApp }) { return }
        let first = apps.first
        let processOnly = !search.isEmpty && first.map { !$0.name.localizedCaseInsensitiveContains(search) } == true
        expandedApp = processOnly ? first?.pid : nil
    }

    private func toggle(_ app: AppUsage, proxy: ScrollViewProxy) {
        let expanding = expandedApp != app.pid
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedApp = expanding ? app.pid : nil
        }
        guard expanding, let last = app.processes.sorted(by: sort).last else { return }
        // Once the rows exist, bring them into view: last process first, then the app row,
        // so a group taller than the list still starts at its app row.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(ProcessRowID(pid: last.pid))
                proxy.scrollTo(app.pid)
            }
        }
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
            Group {
                if search.isEmpty {
                    Text("\(monitor.apps.count) apps · \(monitor.totalAppMemory.memoryString)")
                } else {
                    Text("\(visibleApps.count) of \(monitor.apps.count) apps")
                }
            }
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

            SettingsMenu()
        }
    }
}

/// Kept as its own view so it reads no sampled data: if the menu's contents were rebuilt on
/// every refresh, an open menu would reset (submenus collapse) while the user is choosing.
private struct SettingsMenu: View {
    @Environment(AppMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.includeAccessoryApps) private var includeAccessory = false
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval = 3.0

    var body: some View {
        Menu {
            Button("Menu Bar Appearance…") {
                openWindow(id: "menu-bar-appearance")
                NSApp.activate()
                dismiss()
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
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
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
    let isExpanded: Bool
    let onToggle: () -> Void
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
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
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
        .background(hovering ? Color.primary.opacity(0.06) : (isExpanded ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if app.helperCount > 0 { onToggle() } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: isExpanded ? "Hide Processes" : "Show Processes") {
            if app.helperCount > 0 { onToggle() }
        }
    }
}

private struct ProcessRowID: Hashable {
    let pid: pid_t
}

private struct MenuProcessRow: View {
    @Environment(AppMonitor.self) private var monitor
    let process: ProcessEntry
    let forceMode: Bool
    let isEnding: Bool

    @State private var hovering = false
    /// Set briefly when the signal couldn't be sent, so the click doesn't silently do nothing.
    @State private var failed = false

    var body: some View {
        HStack(spacing: MenuAppRow.columnSpacing) {
            Image(systemName: process.isMain ? "app.fill" : "gearshape.2")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("PID \(process.pid)")
            Spacer(minLength: 0)
            Text(process.cpu.cpuString)
                .frame(width: MenuAppRow.cpuWidth, alignment: .trailing)
            Text(process.footprint.memoryString)
                .frame(width: MenuAppRow.memoryWidth, alignment: .trailing)
            ZStack {
                // Main process has no end button: quitting the app is the app row's job.
                if isEnding {
                    ProgressView().controlSize(.mini)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                        .help("Couldn't end this process (not permitted)")
                } else if hovering && !process.isMain {
                    Button {
                        if !monitor.terminateProcess(process.pid, force: forceMode) {
                            failed = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                failed = false
                            }
                        }
                    } label: {
                        Image(systemName: forceMode ? "xmark.octagon.fill" : "xmark.circle.fill")
                            .foregroundStyle(forceMode ? .red : .secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .help(forceMode ? "Force End Process" : "End Process (hold ⌥ to force)")
                }
            }
            .frame(width: MenuAppRow.quitWidth)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.leading, 40)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background(hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.04))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
