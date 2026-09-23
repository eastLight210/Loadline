import SwiftUI

@main
struct QuitAppsApp: App {
    @State private var monitor = AppMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("QuitApps", id: "main") {
            MainWindowView()
                .environment(monitor)
        }
        .defaultSize(width: 680, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    let monitor: AppMonitor
    @AppStorage(SettingsKey.menuBarDisplay) private var display: MenuBarDisplay = .pressureAndCPU

    var body: some View {
        HStack(spacing: 3) {
            switch display {
            case .pressureAndCPU:
                // A status item shows at most one image and one text, drops symbols embedded in
                // text, and ignores symbol tints — so tinted modes draw the label into one image.
                Image(nsImage: MenuBarImage.label([cpuSegment, pressureSegment(showsText: true)]))
            case .pressure:
                Image(nsImage: MenuBarImage.label([pressureSegment(showsText: true)]))
            case .iconOnly:
                Image(nsImage: MenuBarImage.label([pressureSegment(showsText: false)]))
            case .memory:
                Image(systemName: "memorychip")
                Text(monitor.system.used.compactGBString)
            case .cpu:
                Image(systemName: "cpu")
                Text(monitor.systemCPU.cpuString)
            }
        }
        .monospacedDigit()
    }

    private func pressureSegment(showsText: Bool) -> MenuBarImage.Segment {
        MenuBarImage.Segment(
            symbol: "memorychip",
            text: showsText ? "\(monitor.system.pressurePercent)%" : nil,
            tint: monitor.system.pressure.nsColor
        )
    }

    private var cpuSegment: MenuBarImage.Segment {
        MenuBarImage.Segment(symbol: "cpu", text: String(format: "%.0f%%", monitor.systemCPU), tint: nil)
    }
}

/// Non-template menu bar images, e.g. `[cpu] 14%  [memorychip] 33%`. Colors like `labelColor`
/// are resolved inside the drawing handler, so they follow the menu bar's light/dark appearance.
enum MenuBarImage {
    struct Segment {
        let symbol: String
        let text: String?
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
                text: segment.text.map { ($0 as NSString).size(withAttributes: measure) } ?? .zero
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
