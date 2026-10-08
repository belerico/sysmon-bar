// The panel shown when the menu bar item is clicked: per-core load and clock, memory breakdown.

import SwiftUI

// Activity Monitor's colors for CPU time.
private let userColor = Color.blue
private let systemColor = Color.red
private let appColor = Color.teal
private let wiredColor = Color.orange
private let compressedColor = Color.purple
private let cachedColor = Color.gray

/// The panel's text styles in the chosen font, at macOS's sizes scaled by the chosen size over the
/// 12 pt default.
struct Typeface {
    /// macOS's sizes and weights for the styles the panel uses.
    private static let styles: [Font.TextStyle: (size: CGFloat, weight: NSFont.Weight)] = [
        .body: (13, .regular), .headline: (13, .bold), .subheadline: (11, .regular), .caption: (10, .regular),
    ]

    private var fonts: [Font.TextStyle: Font] = [:]
    /// How much wider text sets than in the default font and size, to widen fixed widths along.
    /// Never below 1: buttons, swatches and spacing do not shrink with smaller text.
    private(set) var scale: CGFloat = 1

    init(_ font: PanelFont = .system(.standard), size: CGFloat = 12) {
        for (style, base) in Self.styles {
            fonts[style] = Font(font.font(size: base.size * size / 12, weight: base.weight) as CTFont)
        }
        let sample = "Compressed 10.4 GB 3.20 GHz 100%" as NSString
        func width(_ font: NSFont) -> CGFloat { sample.size(withAttributes: [.font: font]).width }
        scale = max(1, width(font.font(size: 13 * size / 12, weight: .regular))
            / width(PanelFont.system(.standard).font(size: 13, weight: .regular)))
    }

    func font(_ style: Font.TextStyle) -> Font { fonts[style] ?? .body }
}

private struct TypefaceKey: EnvironmentKey {
    static let defaultValue = Typeface()
}

extension EnvironmentValues {
    var typeface: Typeface {
        get { self[TypefaceKey.self] }
        set { self[TypefaceKey.self] = newValue }
    }
}

extension View {
    /// One of the panel's text styles, in the chosen font and size, always with fixed-width digits.
    func textStyle(_ style: Font.TextStyle) -> some View { modifier(TextStyle(style: style)) }
}

private struct TextStyle: ViewModifier {
    @Environment(\.typeface) private var typeface
    let style: Font.TextStyle

    func body(content: Content) -> some View { content.font(typeface.font(style)) }
}

struct PanelView: View {
    let monitor: Monitor
    @State private var showingSettings = false

    var body: some View {
        let snapshot = monitor.shown
        VStack(alignment: .leading, spacing: 12) {
            if showingSettings {
                SettingsView(monitor: monitor)
            } else {
                CPUSection(snapshot: snapshot, hasClocks: monitor.sampler.hasClocks)
                Divider()
                MemorySection(memory: snapshot.memory, history: snapshot.memoryHistory)
            }
            Divider()
            HStack {
                Text("\(monitor.sampler.chip) · every \(Int(monitor.prefs.interval)) s")
                Spacer()
                Button(showingSettings ? "Done" : "Settings") { showingSettings.toggle() }
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .textStyle(.caption)
            .foregroundStyle(.secondary)
        }
        .textStyle(.body)
        .padding(14)
        .frame(width: 320 * monitor.typeface.scale)
        .environment(\.typeface, monitor.typeface)
    }
}

private struct CPUSection: View {
    let snapshot: Snapshot
    let hasClocks: Bool

    var body: some View {
        let cores = snapshot.cores
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "CPU", symbol: "cpu", value: percent(snapshot.load))
            HistoryGraph(values: snapshot.cpuHistory, color: userColor)
            HStack(spacing: 12) {
                Swatch(color: userColor, label: "User", value: percent(mean(cores.map(\.user))))
                Swatch(color: systemColor, label: "System", value: percent(mean(cores.map(\.system))))
                Spacer()
                Text("Load " + snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))
                    .foregroundStyle(.secondary)
            }
            .textStyle(.caption)
            ForEach(CoreKind.allCases, id: \.self) { kind in
                let group = cores.filter { $0.kind == kind }
                if !group.isEmpty {
                    Cluster(kind: kind, cores: group, hasClocks: hasClocks)
                }
            }
        }
    }
}

private struct Cluster: View {
    let kind: CoreKind
    let cores: [Core]
    let hasClocks: Bool
    @Environment(\.typeface) private var typeface

    var body: some View {
        let clocks = cores.compactMap(\.mhz)
        let scale = typeface.scale
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(kind.title) · \(percent(mean(cores.map(\.load))))")
                Spacer()
                if hasClocks {
                    Text(clocks.isEmpty ? "idle" : "avg " + gigahertz(mean(clocks)))
                }
            }
            .textStyle(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            ForEach(cores) { core in
                HStack(spacing: 8) {
                    Text(core.name)
                        .frame(width: 22 * scale, alignment: .leading)
                        .foregroundStyle(.secondary)
                    LoadBar(user: core.user, system: core.system)
                    Text(percent(core.load))
                        .frame(width: 34 * scale, alignment: .trailing)
                    if hasClocks {
                        Text(core.mhz.map(gigahertz) ?? "idle")
                            .frame(width: 58 * scale, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                .textStyle(.subheadline)
            }
        }
    }
}

private struct MemorySection: View {
    let memory: Memory
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "Memory", symbol: "memorychip",
                value: String(format: "%.1f / %.0f GB", memory.used / gib, memory.total / gib)
            )
            HistoryGraph(values: history, color: appColor)
            StackedBar(total: memory.total, segments: [
                (memory.app, appColor), (memory.wired, wiredColor),
                (memory.compressed, compressedColor), (memory.cached, cachedColor.opacity(0.5)),
            ])
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Swatch(color: appColor, label: "App", value: bytes(memory.app))
                    Swatch(color: wiredColor, label: "Wired", value: bytes(memory.wired))
                }
                GridRow {
                    Swatch(color: compressedColor, label: "Compressed", value: bytes(memory.compressed))
                    Swatch(color: cachedColor.opacity(0.5), label: "Cached", value: bytes(memory.cached))
                }
                GridRow {
                    Swatch(color: .primary.opacity(0.1), label: "Free", value: bytes(memory.free))
                    Swatch(color: pressureColor, label: "Pressure", value: memory.pressure.rawValue)
                }
            }
            .textStyle(.caption)
            HStack {
                Text("Swap").foregroundStyle(.secondary)
                Spacer()
                Text(memory.swapTotal > 0 ? "\(bytes(memory.swapUsed)) of \(bytes(memory.swapTotal))" : "off")
            }
            .textStyle(.caption)
        }
    }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let symbol: String
    let value: String

    var body: some View {
        HStack {
            HeadlineLabel(title: title, symbol: symbol)
            Spacer()
            Text(value)
        }
        .textStyle(.headline)
    }
}

/// A title in the chosen font with its symbol at macOS's headline size: icons keep their size
/// whatever the text size.
struct HeadlineLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label { Text(title) } icon: { Image(systemName: symbol).font(.headline) }
    }
}

private struct Swatch: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// User time then system time, like Activity Monitor's CPU graph.
private struct LoadBar: View {
    let user: Double
    let system: Double

    var body: some View {
        StackedBar(total: 1, segments: [(user, userColor), (system, systemColor)], height: 6)
    }
}

private struct StackedBar: View {
    let total: Double
    let segments: [(value: Double, color: Color)]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    let width = total > 0 ? geometry.size.width * min(max(segments[index].value / total, 0), 1) : 0
                    Rectangle().fill(segments[index].color).frame(width: width)
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.3), value: segments.map(\.value))
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.08))
        .clipShape(Capsule())
    }
}

/// Fractions in 0...1, oldest first, right-aligned so the graph fills in from the right.
private struct HistoryGraph: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(historyLength - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width - CGFloat(values.count - 1 - index) * step,
                        y: size.height * (1 - min(max(value, 0), 1)))
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.2)))
            context.stroke(line, with: .color(color), lineWidth: 1.2)
        }
        .frame(height: 34)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
    }
}

private let gib = 1_073_741_824.0

private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

private func gigahertz(_ mhz: Double) -> String { String(format: "%.2f GHz", mhz / 1000) }

private func bytes(_ value: Double) -> String {
    value >= gib ? String(format: "%.1f GB", value / gib) : String(format: "%.0f MB", value / 1_048_576)
}
