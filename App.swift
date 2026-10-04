// Menu bar item showing CPU load and memory used; clicking it opens a panel with per-core load
// and clock and a memory breakdown. Run the binary with --dump to print one sample and exit.

import AppKit
import SwiftUI

/// Seconds between samples; CPU load and core clocks are averaged over this window.
let sampleInterval: TimeInterval = 2
/// Samples kept for the panel's history graphs.
let historyLength = 90

/// What the panel shows.
struct Snapshot {
    var cores: [Core] = []
    var memory = Memory()
    var loadAverage: [Double] = [0, 0, 0]
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []

    var load: Double { cores.isEmpty ? 0 : cores.map(\.load).reduce(0, +) / Double(cores.count) }
}

@MainActor
@Observable
final class Monitor {
    /// Menu bar text, reassigned only when it changes so the label redraws only then.
    private(set) var barCPU = ""
    private(set) var barMemory = ""
    /// What the panel shows. MenuBarExtra keeps the closed panel's views alive, and laying them
    /// out on every sample cost ~4% CPU, so this is only refreshed while the panel is open.
    private(set) var shown = Snapshot()

    @ObservationIgnored let sampler = Sampler()
    @ObservationIgnored private var latest = Snapshot()
    @ObservationIgnored private var panelOpen = false
    @ObservationIgnored private var timer: Timer?

    init() {
        sample()
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = sampleInterval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // The panel's window becomes key when it opens and resigns key when it closes.
        for (name, open) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.panelOpen = open
                    if open { self.shown = self.latest }
                }
            }
        }
    }

    private func sample() {
        var next = latest
        next.cores = sampler.cores()
        next.memory = sampler.memory()
        var averages = [Double](repeating: 0, count: 3)
        if getloadavg(&averages, 3) == 3 { next.loadAverage = averages }
        next.cpuHistory = Array((next.cpuHistory + [next.load]).suffix(historyLength))
        next.memoryHistory = Array((next.memoryHistory + [next.memory.total > 0 ? next.memory.used / next.memory.total : 0])
            .suffix(historyLength))
        latest = next
        if panelOpen { shown = next }

        let cpu = "\(Int((next.load * 100).rounded()))%"
        let gib = next.memory.used / 1_073_741_824
        let memory = String(format: gib >= 99.95 ? "%.0fG" : "%.1fG", gib)
        if cpu != barCPU { barCPU = cpu }
        if memory != barMemory { barMemory = memory }
    }
}

/// MenuBarExtra keeps only one image and one text from its label, so both symbol + value pairs
/// are drawn into a single template image, which the menu bar tints for light and dark.
private struct MenuBarLabel: View {
    let monitor: Monitor

    var body: some View {
        Image(nsImage: Self.render([
            ("cpu", monitor.barCPU, "100%"),
            ("memorychip", monitor.barMemory, "00.0G"),
        ]))
    }

    /// `widest` reserves a fixed slot for each value so the item does not jitter as digits change.
    private static func render(_ items: [(symbol: String, text: String, widest: String)]) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let iconGap: CGFloat = 3, itemGap: CGFloat = 8, height: CGFloat = 18
        let parts = items.map { item in
            (icon: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig) ?? NSImage(),
             text: item.text as NSString,
             slot: ceil((item.widest as NSString).size(withAttributes: attributes).width))
        }
        let width = parts.map { $0.icon.size.width + iconGap + $0.slot }.reduce(0, +)
            + itemGap * CGFloat(max(parts.count - 1, 0))

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                let icon = part.icon.size
                part.icon.draw(in: NSRect(x: x, y: (height - icon.height) / 2, width: icon.width, height: icon.height))
                x += icon.width + iconGap
                let text = part.text.size(withAttributes: attributes)
                part.text.draw(at: NSPoint(x: x, y: (height - text.height) / 2), withAttributes: attributes)
                x += part.slot + itemGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

@main
struct SysMonApp: App {
    @State private var monitor = Monitor()

    init() {
        if CommandLine.arguments.contains("--dump") { Self.dumpAndExit() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }

    private static func dumpAndExit() -> Never {
        let sampler = Sampler()
        _ = sampler.cores()
        Thread.sleep(forTimeInterval: 1)
        let gib = 1_073_741_824.0
        print("== \(sampler.chip), clocks \(sampler.hasClocks ? "available" : "unavailable")")
        for core in sampler.cores() {
            let mhz = core.mhz.map { String(format: "%4.0f MHz", $0) } ?? "    idle"
            print(String(format: "  %@  user %5.1f%%  sys %5.1f%%  ", core.name, core.user * 100, core.system * 100) + mhz)
        }
        let memory = sampler.memory()
        print(String(format: "  used %.2f of %.0f GB: app %.2f, wired %.2f, compressed %.2f; cached %.2f, free %.2f",
                     memory.used / gib, memory.total / gib, memory.app / gib, memory.wired / gib,
                     memory.compressed / gib, memory.cached / gib, memory.free / gib))
        print(String(format: "  swap %.2f of %.2f GB, pressure ", memory.swapUsed / gib, memory.swapTotal / gib)
              + memory.pressure.rawValue)
        exit(0)
    }
}
