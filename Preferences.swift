// User settings, persisted in UserDefaults, and the settings view shown inside the panel.
// They live in the panel rather than a window of their own: Monitor tells that the panel is open
// from its window becoming key, which a second window would confuse.

import SwiftUI

protocol Choice: Codable, Hashable, CaseIterable where AllCases: RandomAccessCollection {
    var label: String { get }
}

enum BarContent: String, Choice {
    case both, cpu, memory

    var label: String {
        switch self {
        case .both: "Both"
        case .cpu: "CPU"
        case .memory: "Memory"
        }
    }
}

enum CPUFormat: String, Choice {
    case load, clock

    var label: String {
        switch self {
        case .load: "Load %"
        case .clock: "Clock"
        }
    }
}

enum MemoryFormat: String, Choice {
    case used, percent

    var label: String {
        switch self {
        case .used: "GB used"
        case .percent: "Percent"
        }
    }
}

enum BarLayout: String, Choice {
    case row, stacked

    var label: String {
        switch self {
        case .row: "One row"
        case .stacked: "Stacked"
        }
    }
}

enum SystemDesign: String, Choice {
    case standard, rounded, monospaced, serif

    var label: String {
        switch self {
        case .standard: "System"
        case .rounded: "System Rounded"
        case .monospaced: "System Mono"
        case .serif: "System Serif"
        }
    }

    var design: NSFontDescriptor.SystemDesign {
        switch self {
        case .standard: .default
        case .rounded: .rounded
        case .monospaced: .monospaced
        case .serif: .serif
        }
    }
}

/// The panel's typeface: a design of the system font, or an installed family.
enum PanelFont: Codable, Hashable {
    case system(SystemDesign)
    case family(String)

    /// With fixed-width digits so the values do not wobble as they change. Families without bold
    /// get regular; a family since uninstalled falls back to the system font.
    func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base: NSFont? = switch self {
        case .system(let design):
            NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(design.design)
                .flatMap { NSFont(descriptor: $0, size: size) }
        case .family(let name):
            // NSFontManager weights run 0-15: 5 is regular, 9 bold.
            NSFontManager.shared.font(withFamily: name, traits: [], weight: weight == .bold ? 9 : 5, size: size)
        }
        guard let base else { return .monospacedDigitSystemFont(ofSize: size, weight: weight) }
        let digits = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: digits, size: size) ?? base
    }
}

enum PressureAlert: String, Choice {
    case off, warning, critical

    var label: String {
        switch self {
        case .off: "Off"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    /// The lowest pressure announced.
    var level: Pressure? {
        switch self {
        case .off: nil
        case .warning: .warning
        case .critical: .critical
        }
    }
}

struct Preferences: Codable, Equatable {
    var content = BarContent.both
    var cpuFormat = CPUFormat.load
    var memoryFormat = MemoryFormat.used
    var layout = BarLayout.row
    var showIcons = true
    var font = PanelFont.system(.standard)
    /// The panel scales macOS's text sizes by this over 12 pt.
    var fontSize: CGFloat = 12
    /// Seconds between samples; CPU load and core clocks are averaged over this window.
    var interval: TimeInterval = 2
    var pressureAlert = PressureAlert.warning

    static let fontSizes: ClosedRange<CGFloat> = 9...16
    static let intervals: [TimeInterval] = [1, 2, 5]
    private static let key = "settings"

    /// Falls back to the defaults if nothing is stored or the stored settings do not decode.
    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// In an extension so the struct keeps its implicit initializers.
extension Preferences {
    /// Keys missing or unreadable in the stored settings, e.g. ones added by a later version,
    /// take their defaults instead of failing the whole decode and resetting everything.
    init(from decoder: Decoder) throws {
        self.init()
        let stored = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? stored.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        content = value(.content, content)
        cpuFormat = value(.cpuFormat, cpuFormat)
        memoryFormat = value(.memoryFormat, memoryFormat)
        layout = value(.layout, layout)
        showIcons = value(.showIcons, showIcons)
        font = value(.font, font)
        fontSize = value(.fontSize, fontSize)
        interval = value(.interval, interval)
        pressureAlert = value(.pressureAlert, pressureAlert)
    }
}

struct SettingsView: View {
    @Bindable var monitor: Monitor

    /// Read once: fonts installed while the app runs show up after a restart.
    private static let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        let prefs = monitor.prefs
        VStack(alignment: .leading, spacing: 8) {
            HeadlineLabel(title: "Settings", symbol: "gearshape").textStyle(.headline)
            Heading("Menu bar")
            ChoiceRow(title: "Show", selection: $monitor.prefs.content)
            ChoiceRow(title: "CPU as", selection: $monitor.prefs.cpuFormat)
                .disabled(prefs.content == .memory || !monitor.sampler.hasClocks)
            ChoiceRow(title: "Memory as", selection: $monitor.prefs.memoryFormat)
                .disabled(prefs.content == .cpu)
            ChoiceRow(title: "Layout", selection: $monitor.prefs.layout)
                .disabled(prefs.content != .both)
            SettingRow(title: "Icons") {
                Toggle("Icons", isOn: $monitor.prefs.showIcons)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Heading("Text")
            SettingRow(title: "Font") {
                Picker("Font", selection: $monitor.prefs.font) {
                    ForEach(SystemDesign.allCases, id: \.self) { Text($0.label).tag(PanelFont.system($0)) }
                    Divider()
                    ForEach(Self.families, id: \.self) { Text($0).tag(PanelFont.family($0)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            SettingRow(title: "Size") {
                Stepper("\(Int(prefs.fontSize)) pt", value: $monitor.prefs.fontSize, in: Preferences.fontSizes)
            }
            Text("For this panel; the menu bar keeps the system font.")
                .textStyle(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Heading("Sampling")
            SettingRow(title: "Refresh") {
                Picker("Refresh", selection: $monitor.prefs.interval) {
                    ForEach(Preferences.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("Shorter is livelier but costs more CPU. Graphs keep the last \(historyLength) samples.")
                .textStyle(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Heading("Alerts")
            ChoiceRow(title: "Pressure", selection: $monitor.prefs.pressureAlert)
            Text("Notifies when memory pressure reaches this level, at most once per level every \(Int(PressureAlerts.cooldown / 60)) minutes.")
                .textStyle(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Heading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textStyle(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control
    @Environment(\.typeface) private var typeface

    var body: some View {
        HStack {
            Text(title).frame(width: 76 * typeface.scale, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }
}

private struct ChoiceRow<Value: Choice>: View {
    let title: String
    @Binding var selection: Value

    var body: some View {
        SettingRow(title: title) {
            Picker(title, selection: $selection) {
                ForEach(Value.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
