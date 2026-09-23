import SwiftUI

extension MemoryPressure {
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        }
    }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// System summary: CPU and memory pressure side by side (each with recent history),
/// then the memory breakdown.
struct SystemSummary: View {
    let monitor: AppMonitor

    private var system: SystemMemory { monitor.system }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                StatBlock(
                    title: "CPU",
                    value: String(format: "%.0f%%", monitor.systemCPU),
                    history: monitor.cpuHistory,
                    color: .teal
                )
                StatBlock(
                    title: "Memory Pressure",
                    value: "\(system.pressurePercent)%",
                    history: monitor.pressureHistory,
                    color: system.pressure.color
                ) {
                    PressureBadge(pressure: system.pressure)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Memory")
                    Spacer()
                    Text("\(system.used.memoryString) of \(system.total.memoryString)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                SystemMemoryBar(system: system)
                HStack(spacing: 10) {
                    legend("App", system.appMemory, .blue)
                    legend("Wired", system.wired, .orange)
                    legend("Compressed", system.compressed, .purple)
                    Spacer(minLength: 0)
                    if system.swapUsed >= 64 * 1_048_576 {
                        Text("Swap \(system.swapUsed.shortMemoryString)")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    private func legend(_ title: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(bytes.shortMemoryString)")
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Big number with a title, an optional trailing accessory, and a history graph underneath.
private struct StatBlock<Accessory: View>: View {
    let title: String
    let value: String
    let history: [Double]
    let color: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                accessory()
            }
            HistoryGraph(values: history, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension StatBlock where Accessory == EmptyView {
    init(title: String, value: String, history: [Double], color: Color) {
        self.init(title: title, value: value, history: history, color: color) { EmptyView() }
    }
}

struct PressureBadge: View {
    let pressure: MemoryPressure

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(pressure.color).frame(width: 6, height: 6)
            Text(pressure.label)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(pressure.color.opacity(0.15), in: Capsule())
    }
}

/// Area chart of recent 0...100 values, newest on the right (like Activity Monitor's graphs).
struct HistoryGraph: View {
    let values: [Double]
    let color: Color
    var capacity = AppMonitor.historyLength

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max(capacity - 1, 1))
            let startX = size.width - CGFloat(values.count - 1) * step
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: startX + CGFloat(index) * step,
                    y: size.height * (1 - CGFloat(min(max(value, 0), 100)) / 100)
                )
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: startX, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.25)))
            context.stroke(line, with: .color(color), lineWidth: 1.5)
        }
        .frame(height: 34)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Stacked bar of app / wired / compressed memory against total RAM.
struct SystemMemoryBar: View {
    let system: SystemMemory

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(system.total), 1)
            HStack(spacing: 0) {
                segment(system.appMemory, .blue, total, geo.size.width)
                segment(system.wired, .orange, total, geo.size.width)
                segment(system.compressed, .purple, total, geo.size.width)
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }

    private func segment(_ bytes: UInt64, _ color: Color, _ total: Double, _ width: CGFloat) -> some View {
        color.frame(width: width * CGFloat(Double(bytes) / total))
    }
}

/// Thin horizontal bar showing a fraction (e.g. an app's share relative to the heaviest app).
struct ShareBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 3
    var showsTrack = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if showsTrack {
                    Capsule().fill(Color.primary.opacity(0.08))
                }
                Capsule()
                    .fill(tint.opacity(showsTrack ? 1 : 0.55))
                    .frame(width: max(2, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

struct AppIcon: View {
    let image: NSImage?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

extension AppUsage {
    /// Fraction of the heaviest app for the given sort metric (name sorts fall back to memory).
    func share(of apps: [AppUsage], by sort: AppSort) -> Double {
        switch sort {
        case .cpu:
            let top = apps.map(\.cpu).max() ?? 0
            return top > 0 ? cpu / top : 0
        case .memory, .name:
            let top = Double(apps.map(\.total).max() ?? 1)
            return Double(total) / max(top, 1)
        }
    }
}
