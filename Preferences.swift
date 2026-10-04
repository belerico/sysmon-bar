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

struct Preferences: Codable, Equatable {
    var content = BarContent.both
    var cpuFormat = CPUFormat.load
    var memoryFormat = MemoryFormat.used
    var layout = BarLayout.row
    var showIcons = true
    /// Seconds between samples; CPU load and core clocks are averaged over this window.
    var interval: TimeInterval = 2

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

struct SettingsView: View {
    @Bindable var monitor: Monitor

    var body: some View {
        let prefs = monitor.prefs
        VStack(alignment: .leading, spacing: 8) {
            Label("Settings", systemImage: "gearshape").font(.headline)
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
            Heading("Sampling")
            SettingRow(title: "Refresh") {
                Picker("Refresh", selection: $monitor.prefs.interval) {
                    ForEach(Preferences.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("Shorter is livelier but costs more CPU. Graphs keep the last \(historyLength) samples.")
                .font(.caption)
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(title).frame(width: 76, alignment: .leading)
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
