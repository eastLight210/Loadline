import SwiftUI

/// Uses the real status-item label so the preview reflects live samples and animation.
struct MenuBarAppearanceView: View {
    let monitor: AppMonitor
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.menuBarDisplay) private var display: MenuBarDisplay = .pinwheel
    @AppStorage(SettingsKey.menuBarNumericDisplay) private var numericDisplay: MenuBarDisplay = .pressureAndCPU

    private enum Style: String, CaseIterable, Identifiable {
        case pinwheel = "Pinwheel", numbers = "Numbers"
        var id: Self { self }
    }

    private static let numericDisplays: [MenuBarDisplay] = [.pressureAndCPU, .cpu, .pressure, .memory]

    private var style: Binding<Style> {
        Binding {
            switch display {
            case .pinwheel: .pinwheel
            default: .numbers
            }
        } set: { style in
            if Self.numericDisplays.contains(display) { numericDisplay = display }
            switch style {
            case .pinwheel: display = .pinwheel
            case .numbers:
                display = Self.numericDisplays.contains(numericDisplay) ? numericDisplay : .pressureAndCPU
            }
        }
    }

    private var metrics: Binding<MenuBarDisplay> {
        Binding { display } set: { choice in
            display = choice
            numericDisplay = choice
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Live Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MenuBarLabel(monitor: monitor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Live menu bar preview")
            }

            Picker("Style", selection: style) {
                ForEach(Style.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Group {
                switch style.wrappedValue {
                case .pinwheel:
                    Text("Rotation speed shows CPU usage. Green means normal memory pressure, yellow means elevated, and red means critical.")
                        .foregroundStyle(.secondary)
                case .numbers:
                    Picker("Show", selection: metrics) {
                        ForEach(Self.numericDisplays) { mode in
                            Text(mode == .pressureAndCPU ? "CPU + Memory Pressure" : mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Text("Changes apply immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 300)
    }
}
