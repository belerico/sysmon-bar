// Samplers: per-core CPU load (Mach tick counters), per-core clock (IOReport DVFS residencies,
// Apple Silicon only) and memory (VM statistics, counted like Activity Monitor).

import Foundation
import IOKit

enum CoreKind: String, CaseIterable {
    case performance = "P", efficiency = "E", standard = "C"

    var title: String {
        switch self {
        case .performance: "Performance cores"
        case .efficiency: "Efficiency cores"
        case .standard: "Cores"
        }
    }
}

struct Core: Identifiable {
    let id: Int
    let kind: CoreKind
    /// Position within its kind: P0, P1, ...
    let index: Int
    /// Fractions of the last interval.
    var user = 0.0
    var system = 0.0
    /// Average clock while the core was not idle; nil if unknown or idle throughout.
    var mhz: Double?

    var name: String { "\(kind.rawValue)\(index)" }
    var load: Double { user + system }
}

enum Pressure: String {
    case normal = "Normal", warning = "Warning", critical = "Critical"
}

/// Sizes in bytes, split like Activity Monitor's Memory tab.
struct Memory {
    var total = 0.0
    var app = 0.0
    var wired = 0.0
    var compressed = 0.0
    var cached = 0.0
    var swapUsed = 0.0
    var swapTotal = 0.0
    var pressure = Pressure.normal

    /// Activity Monitor's "Memory Used".
    var used: Double { app + wired + compressed }
    var free: Double { max(total - used - cached, 0) }
}

/// CPU load and clocks are averaged over the time since the previous `cores()` call.
final class Sampler {
    let chip = sysctlString("machdep.cpu.brand_string") ?? "CPU"
    let hasClocks: Bool

    private let host = mach_host_self()
    private let kinds: [CoreKind]
    private let clocks = CoreClocks()
    /// Starts at zero so the first sample is the load since boot.
    private var previousTicks: [[UInt32]] = []

    init() {
        let count = ProcessInfo.processInfo.activeProcessorCount
        let efficiency = (sysctlValue("hw.nperflevels", as: Int32.self) ?? 1) > 1
            ? Int(sysctlValue("hw.perflevel1.logicalcpu", as: Int32.self) ?? 0) : 0
        // Apple Silicon numbers the efficiency cores first.
        kinds = (0..<count).map { cpu in
            efficiency == 0 ? .standard : cpu < efficiency ? .efficiency : .performance
        }
        hasClocks = clocks != nil
    }

    var coreCounts: [CoreKind: Int] { kinds.reduce(into: [:]) { $0[$1, default: 0] += 1 } }

    func cores() -> [Core] {
        let ticks = cpuTicks()
        defer { previousTicks = ticks }
        let before = previousTicks.count == ticks.count
            ? previousTicks : ticks.map { $0.map { _ in 0 } }
        let mhz = clocks?.sample() ?? [:]
        let counts = coreCounts
        var seen: [CoreKind: Int] = [:]

        return zip(ticks, before).enumerated().map { cpu, pair in
            let kind = cpu < kinds.count ? kinds[cpu] : .standard
            let index = seen[kind, default: 0]
            seen[kind] = index + 1
            var core = Core(id: cpu, kind: kind, index: index)
            let delta = zip(pair.0, pair.1).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            if total > 0 {
                core.user = (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / total
                core.system = delta[Int(CPU_STATE_SYSTEM)] / total
            }
            core.mhz = mhz[kind].flatMap { $0.count == counts[kind] ? $0[index] : nil }
            return core
        }
    }

    /// User, system, idle and nice ticks per logical CPU.
    private func cpuTicks() -> [[UInt32]] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
    }

    func memory() -> Memory {
        var memory = Memory(total: Double(ProcessInfo.processInfo.physicalMemory))
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let page = Double(getpagesize())
            memory.app = max(Double(stats.internal_page_count) - Double(stats.purgeable_count), 0) * page
            memory.wired = Double(stats.wire_count) * page
            memory.compressed = Double(stats.compressor_page_count) * page
            memory.cached = (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page
        }
        if let swap = sysctlValue("vm.swapusage", as: xsw_usage.self) {
            memory.swapUsed = Double(swap.xsu_used)
            memory.swapTotal = Double(swap.xsu_total)
        }
        memory.pressure = switch sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self) {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
        return memory
    }
}

/// Per-core clocks from the residency IOReport keeps for each DVFS state of each core
/// ("CPU Core Performance States"), weighted by pmgr's frequency table for the core's cluster.
/// Works without root; nil where libIOReport or the tables are missing (Intel).
private final class CoreClocks {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
    ) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private static let idleStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    private let createSamples: CreateSamples
    private let samplesDelta: SamplesDelta
    private let channelName: ChannelName
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    /// MHz of each non-idle DVFS state, lowest first.
    private let tables: [CoreKind: [Double]]
    private var previous: CFDictionary?

    init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannels = load("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let createSubscription = load("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", as: CreateSamples.self),
              let samplesDelta = load("IOReportCreateSamplesDelta", as: SamplesDelta.self),
              let channelName = load("IOReportChannelGetChannelName", as: ChannelName.self),
              let stateCount = load("IOReportStateGetCount", as: StateCount.self),
              let stateName = load("IOReportStateGetNameForIndex", as: StateName.self),
              let stateResidency = load("IOReportStateGetResidency", as: StateResidency.self)
        else { return nil }

        let tables = Self.frequencyTables()
        guard !tables.isEmpty,
              let found = copyChannels("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?
                  .takeRetainedValue(),
              let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, found)
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil) else { return nil }
        subscribed?.release()

        self.createSamples = createSamples
        self.samplesDelta = samplesDelta
        self.channelName = channelName
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        self.subscription = subscription
        self.channels = channels
        self.tables = tables
        previous = createSamples(subscription, channels, nil)?.takeRetainedValue()
    }

    /// MHz of each core of each kind, in core order, since the previous call.
    func sample() -> [CoreKind: [Double?]] {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return [:] }
        defer { previous = current }
        guard let previous,
              let delta = samplesDelta(previous, current, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return [:] }

        var result: [CoreKind: [Double?]] = [:]
        for item in items {
            let channel = item as CFDictionary
            guard let name = channelName(channel)?.takeUnretainedValue() as String? else { continue }
            let kind: CoreKind
            if name.hasPrefix("ECPU") { kind = .efficiency } else if name.hasPrefix("PCPU") { kind = .performance } else { continue }
            guard let table = tables[kind] else { continue }

            var active = 0.0
            var weighted = 0.0
            var level = 0
            for state in 0..<max(stateCount(channel), 0) {
                let label = stateName(channel, state)?.takeUnretainedValue() as String? ?? ""
                if Self.idleStates.contains(label) { continue }
                if level < table.count {
                    let residency = Double(stateResidency(channel, state))
                    active += residency
                    weighted += residency * table[level]
                }
                level += 1
            }
            result[kind, default: []].append(active > 0 ? weighted / active : nil)
        }
        return result
    }

    /// pmgr's DVFS tables hold (frequency, voltage) UInt32 pairs: Hz up to M3, kHz from M4.
    private static func frequencyTables() -> [CoreKind: [Double]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { return [:] }
            defer { IOObjectRelease(entry) }
            var tables: [CoreKind: [Double]] = [:]
            for (kind, key) in [(CoreKind.efficiency, "voltage-states1-sram"), (.performance, "voltage-states5-sram")] {
                guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data, data.count >= 8 else { continue }
                let raw = data.withUnsafeBytes { bytes in
                    stride(from: 0, through: bytes.count - 8, by: 8).map {
                        Double(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                    }
                }
                let toMHz = (raw.max() ?? 0) > 100_000_000 ? 1e-6 : 1e-3
                tables[kind] = raw.map { $0 * toMHz }
            }
            if !tables.isEmpty { return tables }
        }
    }
}

func sysctlValue<T>(_ name: String, as _: T.Type) -> T? {
    var size = MemoryLayout<T>.size
    let value = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
    defer { value.deallocate() }
    guard sysctlbyname(name, value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
    return value.load(as: T.self)
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}
