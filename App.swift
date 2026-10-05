// Menu bar item showing CPU load and memory used; clicking it opens a panel with per-core load
// and clock and a memory breakdown. Run the binary with --dump to print one sample and exit.

import AppKit
import SwiftUI

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

    /// Core clocks weighted by each core's load: the speed the work actually ran at.
    var clock: Double? {
        let busy = cores.compactMap { core in core.mhz.map { (load: core.load, mhz: $0) } }
        let weight = busy.map(\.load).reduce(0, +)
        return weight > 0 ? busy.map { $0.load * $0.mhz }.reduce(0, +) / weight : nil
    }
}

/// One symbol + value pair in the menu bar. `widest` reserves a fixed slot for the value so the
/// item does not jitter as digits change.
struct BarItem: Equatable {
    let symbol: String
    let text: String
    let widest: String
}

struct BarLabel: Equatable {
    var items: [BarItem] = []
    var stacked = false
    var showIcons = true
    var font = BarFont.system(.standard)
    var fontSize: CGFloat = 12
}

@MainActor
@Observable
final class Monitor {
    /// What the menu bar shows, reassigned only when it changes so the label redraws only then.
    private(set) var bar = BarLabel()
    /// What the panel shows. MenuBarExtra keeps the closed panel's views alive, and laying them
    /// out on every sample cost ~4% CPU, so this is only refreshed while the panel is open.
    private(set) var shown = Snapshot()
    /// The panel's fonts, rebuilt only when the font settings change.
    private(set) var typeface = Typeface()
    var prefs = Preferences.load() {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            if prefs.interval != oldValue.interval { startTimer() }
            if prefs.font != oldValue.font || prefs.fontSize != oldValue.fontSize {
                typeface = Typeface(prefs.font, size: prefs.fontSize)
            }
            if prefs.pressureAlert != oldValue.pressureAlert, prefs.pressureAlert != .off { alerts.requestPermission() }
            updateBar()
        }
    }

    @ObservationIgnored let sampler = Sampler()
    @ObservationIgnored private let alerts = PressureAlerts()
    @ObservationIgnored private var latest = Snapshot()
    @ObservationIgnored private var panelOpen = false
    @ObservationIgnored private var timer: Timer?

    init() {
        typeface = Typeface(prefs.font, size: prefs.fontSize)
        if prefs.pressureAlert != .off { alerts.requestPermission() }
        sample()
        startTimer()

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

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: prefs.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = prefs.interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
        alerts.check(next.memory, threshold: prefs.pressureAlert)
        updateBar()
    }

    private func updateBar() {
        var items: [BarItem] = []
        if prefs.content != .memory {
            items.append(prefs.cpuFormat == .clock && sampler.hasClocks
                ? BarItem(symbol: "cpu", text: latest.clock.map { String(format: "%.1fGHz", $0 / 1000) } ?? "idle",
                          widest: "0.0GHz")
                : BarItem(symbol: "cpu", text: "\(Int((latest.load * 100).rounded()))%", widest: "100%"))
        }
        if prefs.content != .cpu {
            let memory = latest.memory
            if prefs.memoryFormat == .percent {
                let used = memory.total > 0 ? memory.used / memory.total : 0
                items.append(BarItem(symbol: "memorychip", text: "\(Int((used * 100).rounded()))%", widest: "100%"))
            } else {
                let gib = memory.used / 1_073_741_824
                items.append(BarItem(symbol: "memorychip", text: String(format: gib >= 99.95 ? "%.0fG" : "%.1fG", gib),
                                     widest: "00.0G"))
            }
        }
        let label = BarLabel(items: items, stacked: prefs.layout == .stacked && items.count > 1,
                             showIcons: prefs.showIcons, font: prefs.font, fontSize: prefs.fontSize)
        if label != bar { bar = label }
    }
}

/// MenuBarExtra keeps only one image and one text from its label, so the symbol + value pairs
/// are drawn into a single template image, which the menu bar tints for light and dark.
private struct MenuBarLabel: View {
    let monitor: Monitor

    var body: some View {
        Image(nsImage: Self.render(monitor.bar))
    }

    /// Side by side, or one pair per row in smaller type when stacked.
    private static func render(_ label: BarLabel) -> NSImage {
        let stacked = label.stacked
        var font = label.font.font(size: label.fontSize)
        if stacked {
            // Three quarters of the size, but with digits at most 7 pt tall so the two 10 pt rows
            // keep a gap between them.
            font = label.font.font(size: min(label.fontSize * 0.75, 7 * font.pointSize / font.capHeight))
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: font.pointSize + (stacked ? -0.5 : 1), weight: .medium)
        let iconGap: CGFloat = stacked ? 2 : 3, itemGap: CGFloat = 8
        let parts = label.items.map { item in
            (icon: label.showIcons
                ? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
                : nil,
             text: item.text as NSString,
             slot: ceil((item.widest as NSString).size(withAttributes: attributes).width))
        }
        let widths = parts.map { part in (part.icon.map { $0.size.width + iconGap } ?? 0) + part.slot }
        let width = stacked
            ? widths.max() ?? 0
            : widths.reduce(0, +) + itemGap * CGFloat(max(parts.count - 1, 0))
        let height = stacked ? 20 : max(18, ceil(parts.compactMap { $0.icon?.size.height }.max() ?? 0))
        let rowHeight = stacked ? height / 2 : height

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, part) in parts.enumerated() {
                // The first pair goes on the top row; y grows upwards.
                let y = stacked ? CGFloat(parts.count - 1 - index) * rowHeight : 0
                if stacked { x = 0 }
                if let icon = part.icon {
                    let size = icon.size
                    icon.draw(in: NSRect(x: x, y: y + (rowHeight - size.height) / 2, width: size.width, height: size.height))
                    x += size.width + iconGap
                }
                // Centered on the digits' cap height, which unlike the line height means the same
                // thing in every font. Without .usesLineFragmentOrigin the rect's origin is the baseline.
                let baseline = y + (rowHeight - font.capHeight) / 2
                part.text.draw(with: NSRect(x: x, y: baseline, width: width, height: 0), attributes: attributes)
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
