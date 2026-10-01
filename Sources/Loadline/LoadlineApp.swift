import AppIntents
import SwiftUI

@main
struct LoadlineApp: App {
    @State private var monitor: AppMonitor

    init() {
        _ = Updater.shared
        let monitor = AppMonitor()
        _monitor = State(initialValue: monitor)
        // Lets App Intents (Siri, Shortcuts, Spotlight) read the same live samples as the UI.
        AppDependencyManager.shared.add(dependency: monitor)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("Menu Bar Appearance", id: "menu-bar-appearance") {
            MenuBarAppearanceView(monitor: monitor)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .defaultPosition(.center)

        Window("Loadline", id: "main") {
            MainWindowView()
                .environment(monitor)
        }
        .defaultSize(width: 680, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    let monitor: AppMonitor
    @AppStorage(SettingsKey.menuBarDisplay) private var display: MenuBarDisplay = .pinwheel

    var body: some View {
        // A status item shows at most one image and one text, drops symbols embedded in text,
        // and ignores symbol tints — so every mode draws the label into one image. That also
        // lets the numbers keep a fixed width instead of nudging neighboring items as they change.
        switch display {
        case .pinwheel:
            PinwheelMenuBarLabel(monitor: monitor)
        case .pressureAndCPU:
            Image(nsImage: MenuBarImage.label([cpuSegment, pressureSegment]))
        case .pressure:
            Image(nsImage: MenuBarImage.label([pressureSegment]))
        case .memory:
            Image(nsImage: MenuBarImage.label([MenuBarImage.Segment(
                symbol: "memorychip", text: monitor.system.used.compactGBString, reserve: "00.0G", tint: nil
            )]))
        case .cpu:
            Image(nsImage: MenuBarImage.label([cpuSegment]))
        }
    }

    private var pressureSegment: MenuBarImage.Segment {
        MenuBarImage.Segment(
            symbol: "memorychip",
            text: "\(monitor.system.pressurePercent)%",
            reserve: "00%",
            tint: monitor.system.pressure.nsColor
        )
    }

    private var cpuSegment: MenuBarImage.Segment {
        MenuBarImage.Segment(symbol: "cpu", text: String(format: "%.0f%%", monitor.systemCPU), reserve: "00%", tint: nil)
    }
}

private struct PinwheelMenuBarLabel: View {
    let monitor: AppMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0

    var body: some View {
        Image(nsImage: MenuBarImage.pinwheel(angle: angle, level: monitor.system.pressure))
            .accessibilityLabel("CPU and memory pressure")
            .accessibilityValue(monitor.cpuHistory.isEmpty
                ? "Collecting samples"
                : "CPU \(Int(monitor.systemCPU)) percent, memory pressure \(monitor.system.pressurePercent) percent, \(monitor.system.pressure.label)")
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                let clock = ContinuousClock()
                var previous = clock.now
                var motion = PinwheelMotion(angle: angle)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1.0 / 30)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    let now = clock.now
                    let duration = previous.duration(to: now).components
                    previous = now
                    // Avoid a jump after sleep or a delayed frame. Sampling remains independent.
                    let elapsed = min(0.25, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                    motion.advance(cpu: monitor.systemCPU, elapsed: elapsed)
                    angle = motion.angle
                }
            }
    }
}

/// Integrates rotation so CPU changes alter speed without resetting the phase.
private struct PinwheelMotion {
    var angle = 0.0
    private var revolutionsPerSecond = 0.08

    init(angle: Double = 0) { self.angle = angle }

    mutating func advance(cpu: Double, elapsed: Double) {
        let load = cpu.isFinite ? min(100, max(0, cpu)) : 0
        let target = 0.08 + 0.92 * load / 100
        revolutionsPerSecond += (target - revolutionsPerSecond) * (1 - exp(-elapsed / 0.8))
        angle = (angle + 360 * revolutionsPerSecond * elapsed).truncatingRemainder(dividingBy: 360)
    }
}

/// Non-template menu bar images, e.g. `[cpu] 14%  [memorychip] 33%`. Colors like `labelColor`
/// are resolved inside the drawing handler, so they follow the menu bar's light/dark appearance.
enum MenuBarImage {
    /// A solid four-blade rotor uses the full icon height and stays legible as it turns.
    static func pinwheel(angle: Double, level: MemoryPressure) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { _ in
            level.nsColor.setFill()
            for blade in 0..<4 {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0.8, y: 1.2))
                path.line(to: NSPoint(x: 2.3, y: 8.3))
                path.curve(to: NSPoint(x: 7.7, y: 4.7),
                           controlPoint1: NSPoint(x: 5.6, y: 8.3),
                           controlPoint2: NSPoint(x: 7.7, y: 6.5))
                path.line(to: NSPoint(x: 1.2, y: -0.8))
                path.close()
                let transform = NSAffineTransform()
                transform.translateX(by: 10, yBy: 10)
                transform.rotate(byDegrees: CGFloat(angle) + CGFloat(blade) * 90)
                path.transform(using: transform as AffineTransform)
                path.fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 8.5, y: 8.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    struct Segment {
        let symbol: String
        let text: String?
        /// Text whose width is kept even when `text` is narrower, so the label doesn't resize
        /// as values change digit counts. Wider text still grows the label.
        var reserve: String? = nil
        /// nil draws the symbol in the menu bar's text color.
        let tint: NSColor?
    }

    static func label(_ segments: [Segment]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        let measure: [NSAttributedString.Key: Any] = [.font: font]
        let sizes = segments.map { segment in
            (
                symbol: NSImage(systemSymbolName: segment.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)?.size ?? NSSize(width: 15, height: 15),
                text: segment.text.map { text in
                    let size = (text as NSString).size(withAttributes: measure)
                    let reserved = segment.reserve.map { ($0 as NSString).size(withAttributes: measure).width } ?? 0
                    return NSSize(width: max(size.width, reserved), height: size.height)
                } ?? .zero
            )
        }

        let gap: CGFloat = 3
        let groupGap: CGFloat = 8
        let height = sizes.map { max($0.symbol.height, $0.text.height) }.max() ?? 16
        let width = sizes.map { $0.symbol.width + ($0.text.width > 0 ? gap + $0.text.width : 0) }.reduce(0, +)
            + groupGap * CGFloat(max(segments.count - 1, 0))

        let image = NSImage(size: NSSize(width: ceil(width), height: ceil(height)), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            var x: CGFloat = 0
            for (segment, size) in zip(segments, sizes) {
                let tint = symbolConfig.applying(NSImage.SymbolConfiguration(paletteColors: [segment.tint ?? .labelColor]))
                if let symbol = NSImage(systemSymbolName: segment.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(tint) {
                    symbol.draw(in: NSRect(
                        x: x, y: (rect.height - size.symbol.height) / 2,
                        width: size.symbol.width, height: size.symbol.height
                    ))
                }
                x += size.symbol.width
                if let text = segment.text {
                    x += gap
                    (text as NSString).draw(at: NSPoint(x: x, y: (rect.height - size.text.height) / 2), withAttributes: attributes)
                    x += size.text.width
                }
                x += groupGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
